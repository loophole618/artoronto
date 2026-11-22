// A generated walk that follows your path.
import Foundation
import simd

final class Walker {
    static let lag: Float = 1.6
    static let maxSpeed: Float = 1.8
    static let stride: Float = 1.1

    private(set) var rest: [String: SIMD3<Float>] = Walker.defaultSkeleton

    private var path: [SIMD3<Float>] = []
    private var cum: [Float] = []
    private var s: Float = 0
    private var phase: Float = 0
    private var amount: Float = 0
    private var facing = SIMD3<Float>(0, 0, -1)

    func clear() {
        path = []; cum = []; s = 0; phase = 0; amount = 0
    }

    func record(floor p: SIMD3<Float>) {
        if let last = path.last {
            let d = simd_distance(last, p)
            guard d >= 0.05 else { return }
            path.append(p); cum.append(cum.last! + d)
        } else {
            path.append(p); cum.append(0)
        }
        if path.count > 6000 {
            let drop = 1000
            let shift = cum[drop]
            path.removeFirst(drop); cum.removeFirst(drop)
            cum = cum.map { $0 - shift }
            s = max(0, s - shift)
        }
    }

    func step(dt: Float, camera: SIMD3<Float>) -> (joints: [String: SIMD3<Float>], head: simd_float4x4)? {
        guard path.count >= 2, let total = cum.last else { return nil }
        let target = max(0, total - Self.lag)
        let ds = max(0, min(target - s, Self.maxSpeed * dt))
        s += ds
        let speed = dt > 0 ? ds / dt : 0
        amount += (min(speed / 1.0, 1) - amount) * min(1, 6 * dt)
        phase += ds / Self.stride * 2 * .pi

        let pos = point(at: s)
        var want = point(at: s + 0.2) - point(at: max(0, s - 0.2))
        if amount < 0.25 { want = camera - pos }
        want.y = 0
        if simd_length(want) > 1e-3 {
            facing = simd_normalize(facing + (simd_normalize(want) - facing) * min(1, 4 * dt))
        }
        let fwd = simd_normalize(SIMD3(facing.x, 0, facing.z))
        return pose(at: pos, forward: fwd, phase: phase, amount: amount)
    }

    func pose(at pos: SIMD3<Float>, forward fwd: SIMD3<Float>, phase: Float, amount: Float)
        -> (joints: [String: SIMD3<Float>], head: simd_float4x4) {
        let up = SIMD3<Float>(0, 1, 0)
        let left = simd_cross(up, fwd)
        var joints: [String: SIMD3<Float>] = [:]
        for (name, l) in posed(phase: phase, amount: amount) {
            joints[name] = pos + left * l.x + up * l.y + fwd * l.z
        }
        var head = simd_float4x4(SIMD4(left, 0), SIMD4(up, 0), SIMD4(fwd, 0), SIMD4(pos, 1))
        if let h = joints["head_joint"] { head.columns.3 = SIMD4(h, 1) }
        return (joints, head)
    }

    private func point(at d: Float) -> SIMD3<Float> {
        guard let total = cum.last else { return .zero }
        let d = min(max(d, 0), total)
        var lo = 0, hi = cum.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if cum[mid] <= d { lo = mid } else { hi = mid } }
        let span = cum[hi] - cum[lo]
        let t = span > 0 ? (d - cum[lo]) / span : 0
        return path[lo] + (path[hi] - path[lo]) * t
    }

    private func posed(phase: Float, amount a: Float) -> [String: SIMD3<Float>] {
        var j = rest
        func swing(_ v: SIMD3<Float>, _ th: Float) -> SIMD3<Float> {
            SIMD3(v.x, v.y * cos(th) + v.z * sin(th), -v.y * sin(th) + v.z * cos(th))
        }
        for (side, off) in [("left", Float(0)), ("right", Float.pi)] {
            let ph = phase + off
            if let hip = rest["\(side)_upLeg_joint"], let knee0 = rest["\(side)_leg_joint"],
               let ankle0 = rest["\(side)_foot_joint"], let toes0 = rest["\(side)_toes_joint"] {
                let thigh = 0.42 * a * sin(ph)
                let bend = 0.8 * a * max(0, sin(ph + 1.1))
                let knee = hip + swing(knee0 - hip, thigh)
                let ankle = knee + swing(ankle0 - knee0, thigh - bend)
                j["\(side)_leg_joint"] = knee
                j["\(side)_foot_joint"] = ankle
                j["\(side)_toes_joint"] = ankle + swing(toes0 - ankle0, 0.25 * (thigh - bend))
            }
            if let sh = rest["\(side)_arm_joint"], let el0 = rest["\(side)_forearm_joint"], let wr0 = rest["\(side)_hand_joint"] {
                let arm = -0.38 * a * sin(ph)
                let elbow = sh + swing(el0 - sh, arm)
                j["\(side)_forearm_joint"] = elbow
                j["\(side)_hand_joint"] = elbow + swing(wr0 - el0, arm + 0.15 + 0.3 * a)
            }
        }
        let bob = 0.025 * a * cos(2 * phase)
        for k in j.keys { j[k]!.y += bob }
        return j
    }

    func useSkeleton(from model: AvatarModel) {
        let J = model.joints
        guard let root = J["RootRig"], let neck = J["NeckRig"],
              let ls = J["LeftShoulderRig"], let rs = J["RightShoulderRig"],
              let la = J["LeftAnkleRig"], let ra = J["RightAnkleRig"] else { return }
        let up = SIMD3<Float>(0, 1, 0)
        var left = ls - rs; left.y = 0; left = simd_normalize(left)
        let fwd = simd_cross(left, up)
        let floorY = model.parts["LeftFoot"]?.positions.map(\.y).min() ?? (min(la.y, ra.y) - 0.3)
        let scale = 0.8 / max(root.y - floorY, 0.01)
        func local(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let r = p - SIMD3(root.x, floorY, root.z)
            return SIMD3(simd_dot(r, left), simd_dot(r, up), simd_dot(r, fwd)) * scale
        }
        let names: [String: String] = [
            "hips_joint": "RootRig", "neck_1_joint": "NeckRig",
            "left_arm_joint": "LeftShoulderRig", "left_forearm_joint": "LeftElbowRig", "left_hand_joint": "LeftWristRig",
            "right_arm_joint": "RightShoulderRig", "right_forearm_joint": "RightElbowRig", "right_hand_joint": "RightWristRig",
            "left_upLeg_joint": "LeftHipRig", "left_leg_joint": "LeftKneeRig", "left_foot_joint": "LeftAnkleRig",
            "right_upLeg_joint": "RightHipRig", "right_leg_joint": "RightKneeRig", "right_foot_joint": "RightAnkleRig",
        ]
        var sk: [String: SIMD3<Float>] = [:]
        for (ar, rb) in names { if let p = J[rb] { sk[ar] = local(p) } }
        guard sk.count == names.count else { return }
        let footLen = 0.45 * simd_distance(sk["left_leg_joint"]!, sk["left_foot_joint"]!)
        for side in ["left", "right"] {
            let ankle = sk["\(side)_foot_joint"]!
            sk["\(side)_toes_joint"] = SIMD3(ankle.x, max(0.02, ankle.y - 0.6 * footLen), ankle.z + footLen)
        }
        sk["head_joint"] = sk["neck_1_joint"]! + SIMD3(0, 0.6 * simd_distance(sk["hips_joint"]!, sk["neck_1_joint"]!), 0)
        rest = sk
    }

    static let defaultSkeleton: [String: SIMD3<Float>] = [
        "hips_joint": [0, 0.80, 0], "neck_1_joint": [0, 1.25, 0], "head_joint": [0, 1.40, 0],
        "left_arm_joint": [0.17, 1.22, 0], "left_forearm_joint": [0.19, 0.97, 0], "left_hand_joint": [0.20, 0.75, 0.02],
        "right_arm_joint": [-0.17, 1.22, 0], "right_forearm_joint": [-0.19, 0.97, 0], "right_hand_joint": [-0.20, 0.75, 0.02],
        "left_upLeg_joint": [0.09, 0.78, 0], "left_leg_joint": [0.09, 0.42, 0.01], "left_foot_joint": [0.09, 0.07, 0],
        "left_toes_joint": [0.09, 0.02, 0.13],
        "right_upLeg_joint": [-0.09, 0.78, 0], "right_leg_joint": [-0.09, 0.42, 0.01], "right_foot_joint": [-0.09, 0.07, 0],
        "right_toes_joint": [-0.09, 0.02, 0.13],
    ]
}
