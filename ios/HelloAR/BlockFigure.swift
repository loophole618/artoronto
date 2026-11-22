// A figure of rigid parts posed from skeleton joints (tracked or generated).
import RealityKit
import ARKit
import UIKit
import simd
import os

let appLog = Logger(subsystem: "com.loophole618.artoronto", category: "app")

final class BlockFigure {
    let root = AnchorEntity(world: SIMD3<Float>(0, 0, 0))

    enum Placement: String { case beside = "BESIDE", on = "ON" }
    var placement: Placement = .beside
    var size: Float = 1
    var occlude = true
    var depthScale: Float = 1
    var cameraPosition = SIMD3<Float>(0, 0, 0)

    static let follow: Float = 0.35
    static let followSide: Float = 0.08

    private struct Limb {
        let entity: ModelEntity
        let from: String
        let to: String
        let thickness: Float
    }
    private var limbs: [Limb] = []
    private var shadows: [Limb] = []
    private let torso: ModelEntity
    private let head: ModelEntity
    private let hands: [ModelEntity]
    private let shadowTorso: ModelEntity
    private let shadowHead: ModelEntity

    var wear = true
    private struct Worn {
        let entity: ModelEntity
        let spec: PartSpec
        let restLength: Float
    }
    private struct PartSpec {
        let part: String
        let rest: (String, String, String)
        let live: (String, String, String)
        let stretch: Bool
    }
    private static let specs: [PartSpec] = {
        var s = [
            PartSpec(part: "LowerTorso", rest: ("RootRig", "RootRig", "NeckRig"),
                     live: ("hips_joint", "hips_joint", "neck_1_joint"), stretch: true),
            PartSpec(part: "UpperTorso", rest: ("RootRig", "RootRig", "NeckRig"),
                     live: ("hips_joint", "hips_joint", "neck_1_joint"), stretch: true),
        ]
        for (R, a) in [("Left", "left"), ("Right", "right")] {
            s += [
                PartSpec(part: "\(R)UpperArm", rest: ("\(R)ShoulderRig", "\(R)ShoulderRig", "\(R)ElbowRig"),
                         live: ("\(a)_arm_joint", "\(a)_arm_joint", "\(a)_forearm_joint"), stretch: true),
                PartSpec(part: "\(R)LowerArm", rest: ("\(R)ElbowRig", "\(R)ElbowRig", "\(R)WristRig"),
                         live: ("\(a)_forearm_joint", "\(a)_forearm_joint", "\(a)_hand_joint"), stretch: true),
                PartSpec(part: "\(R)Hand", rest: ("\(R)WristRig", "\(R)ElbowRig", "\(R)WristRig"),
                         live: ("\(a)_hand_joint", "\(a)_forearm_joint", "\(a)_hand_joint"), stretch: false),
                PartSpec(part: "\(R)UpperLeg", rest: ("\(R)HipRig", "\(R)HipRig", "\(R)KneeRig"),
                         live: ("\(a)_upLeg_joint", "\(a)_upLeg_joint", "\(a)_leg_joint"), stretch: true),
                PartSpec(part: "\(R)LowerLeg", rest: ("\(R)KneeRig", "\(R)KneeRig", "\(R)AnkleRig"),
                         live: ("\(a)_leg_joint", "\(a)_leg_joint", "\(a)_foot_joint"), stretch: true),
                PartSpec(part: "\(R)Foot", rest: ("\(R)AnkleRig", "FORWARD", "FORWARD"),
                         live: ("\(a)_foot_joint", "\(a)_foot_joint", "\(a)_toes_joint"), stretch: false),
            ]
        }
        return s
    }()
    private var worn: [Worn] = []
    private var lastLog: CFTimeInterval = 0
    private var restTorso: Float = 1
    var wornPartCount: Int { worn.count }

    private var smoothed: [String: SIMD3<Float>] = [:]
    private var smoothedHead: simd_quatf?
    private var smoothedSide: SIMD3<Float>?

    private static let jointNames = [
        "hips_joint", "neck_1_joint", "head_joint",
        "left_arm_joint", "left_forearm_joint", "left_hand_joint",
        "right_arm_joint", "right_forearm_joint", "right_hand_joint",
        "left_upLeg_joint", "left_leg_joint", "left_foot_joint", "left_toes_joint",
        "right_upLeg_joint", "right_leg_joint", "right_foot_joint", "right_toes_joint",
    ]

    init() {
        let cream = UIColor(red: 1.00, green: 0.92, blue: 0.75, alpha: 1)
        let coral = UIColor(red: 1.00, green: 0.42, blue: 0.32, alpha: 1)
        let teal = UIColor(red: 0.15, green: 0.70, blue: 0.75, alpha: 1)
        let indigo = UIColor(red: 0.25, green: 0.30, blue: 0.70, alpha: 1)
        let ink = UIColor(red: 0.15, green: 0.15, blue: 0.20, alpha: 1)

        torso = Self.block(coral)
        head = BlockHead.make()
        hands = [Self.block(cream), Self.block(cream)]
        shadowTorso = Self.shadowBox()
        shadowHead = ModelEntity(mesh: .generateSphere(radius: 0.5), materials: [OcclusionMaterial()])
        root.addChild(torso)
        root.addChild(head)
        hands.forEach { root.addChild($0) }

        let parts: [(String, String, Float, UIColor)] = [
            ("left_arm_joint", "left_forearm_joint", 0.11, teal),
            ("left_forearm_joint", "left_hand_joint", 0.10, teal),
            ("right_arm_joint", "right_forearm_joint", 0.11, teal),
            ("right_forearm_joint", "right_hand_joint", 0.10, teal),
            ("left_upLeg_joint", "left_leg_joint", 0.14, indigo),
            ("left_leg_joint", "left_foot_joint", 0.12, indigo),
            ("right_upLeg_joint", "right_leg_joint", 0.14, indigo),
            ("right_leg_joint", "right_foot_joint", 0.12, indigo),
            ("left_foot_joint", "left_toes_joint", 0.09, ink),
            ("right_foot_joint", "right_toes_joint", 0.09, ink),
        ]
        for (a, b, t, c) in parts {
            let e = Self.block(c)
            root.addChild(e)
            limbs.append(Limb(entity: e, from: a, to: b, thickness: t))
        }

        root.addChild(shadowTorso)
        root.addChild(shadowHead)
        let shadowParts: [(String, String, Float)] = [
            ("left_arm_joint", "left_forearm_joint", 0.09),
            ("left_forearm_joint", "left_hand_joint", 0.07),
            ("right_arm_joint", "right_forearm_joint", 0.09),
            ("right_forearm_joint", "right_hand_joint", 0.07),
            ("left_upLeg_joint", "left_leg_joint", 0.13),
            ("left_leg_joint", "left_foot_joint", 0.10),
            ("right_upLeg_joint", "right_leg_joint", 0.13),
            ("right_leg_joint", "right_foot_joint", 0.10),
        ]
        for (a, b, t) in shadowParts {
            let e = Self.shadowBox()
            root.addChild(e)
            shadows.append(Limb(entity: e, from: a, to: b, thickness: t))
        }
        root.isEnabled = false
    }

    private static func block(_ color: UIColor) -> ModelEntity {
        let m = SimpleMaterial(color: color, roughness: 0.55, isMetallic: false)
        return ModelEntity(mesh: .generateBox(size: 1, cornerRadius: 0.08), materials: [m])
    }

    private static func shadowBox() -> ModelEntity {
        ModelEntity(mesh: .generateBox(size: 1, cornerRadius: 0.2), materials: [OcclusionMaterial()])
    }

    func dress(with model: AvatarModel) {
        worn.forEach { $0.entity.removeFromParent() }
        worn = []
        guard let hips = model.joints["RootRig"], let neck = model.joints["NeckRig"],
              let ls = model.joints["LeftShoulderRig"], let rs = model.joints["RightShoulderRig"] else { return }
        let up = simd_normalize(neck - hips)
        let across = ls - rs
        let forward = simd_normalize(simd_cross(across, up))
        restTorso = simd_length(neck - hips)
        appLog.notice("app: dress joints=\(model.joints.count) parts=\(model.parts.count) restTorso=\(self.restTorso)")

        var textures: [Int: TextureResource] = [:]
        for spec in Self.specs {
            guard let part = model.parts[spec.part], !part.positions.isEmpty,
                  let origin = model.joints[spec.rest.0] else { continue }
            var dir = forward, length: Float = 1
            if spec.rest.1 != "FORWARD" {
                guard let a = model.joints[spec.rest.1], let b = model.joints[spec.rest.2] else { continue }
                dir = b - a
                length = simd_length(dir)
            }
            let hint = spec.part.contains("Torso") ? across : Self.limbHint(dir, facing: forward, across: across)
            let toLocal = Self.basis(y: dir, xHint: hint).transpose
            var d = MeshDescriptor(name: spec.part)
            d.positions = MeshBuffers.Positions(part.positions.map { toLocal * ($0 - origin) })
            if !part.normals.isEmpty { d.normals = MeshBuffers.Normals(part.normals.map { toLocal * $0 }) }
            if !part.uvs.isEmpty { d.textureCoordinates = MeshBuffers.TextureCoordinates(part.uvs) }
            d.primitives = .triangles(part.indices)
            guard let mesh = try? MeshResource.generate(from: [d]) else { continue }

            var mat = UnlitMaterial()
            if let ti = part.texture, let cg = model.images[ti] {
                if textures[ti] == nil { textures[ti] = try? TextureResource.generate(from: cg, options: .init(semantic: .color)) }
                if let tex = textures[ti] { mat.color = .init(tint: .white, texture: .init(tex)) }
            } else {
                mat.color = .init(tint: .lightGray)
            }
            let e = ModelEntity(mesh: mesh, materials: [mat])
            root.addChild(e)
            worn.append(Worn(entity: e, spec: spec, restLength: max(length, 1e-4)))
            let b = mesh.bounds
            appLog.notice("app: part \(spec.part, privacy: .public) verts=\(part.positions.count) tris=\(part.indices.count / 3) restLen=\(length) tex=\(part.texture != nil) boundsMin=\(b.min.debugDescription, privacy: .public) boundsMax=\(b.max.debugDescription, privacy: .public)")
        }
    }

    func reset() {
        smoothed.removeAll()
        smoothedHead = nil
        smoothedSide = nil
        root.isEnabled = false
    }

    func update(from body: ARBodyAnchor, cameraRight: SIMD3<Float>) {
        guard body.isTracked else { reset(); return }
        let rootT = body.transform
        var raw: [String: SIMD3<Float>] = [:]
        for name in Self.jointNames {
            guard let m = body.skeleton.modelTransform(for: ARSkeleton.JointName(rawValue: name)) else { continue }
            let w = rootT * m
            let t = SIMD3<Float>(w.columns.3.x, w.columns.3.y, w.columns.3.z)
            raw[name] = cameraPosition + (t - cameraPosition) * depthScale
        }
        pose(raw: raw, headMatrix: body.skeleton.modelTransform(for: .head).map { rootT * $0 },
             cameraRight: cameraRight, scaleHint: Float(body.estimatedScaleFactor), tracked: true)
    }

    func update(walker joints: [String: SIMD3<Float>], headMatrix: simd_float4x4) {
        pose(raw: joints, headMatrix: headMatrix, cameraRight: SIMD3<Float>(1, 0, 0), scaleHint: 1, tracked: false)
    }

    private func pose(raw: [String: SIMD3<Float>], headMatrix: simd_float4x4?, cameraRight: SIMD3<Float>,
                      scaleHint: Float, tracked: Bool) {
        root.isEnabled = true
        let shouldLog = CACurrentMediaTime() - lastLog > 1
        if shouldLog { lastLog = CACurrentMediaTime() }
        let size: Float = tracked ? self.size : 1
        let placement: Placement = tracked ? self.placement : .on

        var world: [String: SIMD3<Float>] = [:]
        for (name, t) in raw {
            let s = tracked ? (smoothed[name].map { $0 + (t - $0) * Self.follow } ?? t) : t
            smoothed[name] = s
            world[name] = s
        }
        guard let hips = world["hips_joint"] else { return }

        let footY = min(world["left_foot_joint"]?.y ?? hips.y - 0.9, world["right_foot_joint"]?.y ?? hips.y - 0.9)
        let pivot = SIMD3<Float>(hips.x, footY, hips.z)
        var flatRight = SIMD3<Float>(cameraRight.x, 0, cameraRight.z)
        flatRight = simd_length(flatRight) > 1e-3 ? simd_normalize(flatRight) : SIMD3<Float>(1, 0, 0)
        var side = smoothedSide.map { $0 + (flatRight - $0) * Self.followSide } ?? flatRight
        side = simd_length(side) > 1e-3 ? simd_normalize(side) : flatRight
        smoothedSide = side
        let offset: SIMD3<Float> = placement == .beside ? side * (0.9 * max(size, 1)) : .zero

        func p(_ name: String) -> SIMD3<Float>? {
            guard let w = world[name] else { return nil }
            return pivot + (w - pivot) * size + offset
        }

        let lShoulder = p("left_arm_joint"), rShoulder = p("right_arm_joint")
        let across = (lShoulder != nil && rShoulder != nil) ? (lShoulder! - rShoulder!) : SIMD3<Float>(1, 0, 0)
        var facing = SIMD3<Float>(0, 0, -1)
        if let h = p("hips_joint"), let n = p("neck_1_joint") {
            let f = simd_cross(across, n - h)
            if simd_length(f) > 1e-4 { facing = simd_normalize(f) }
        }
        func twist(_ dir: SIMD3<Float>) -> SIMD3<Float> { Self.limbHint(dir, facing: facing, across: across) }

        if let a = p("hips_joint"), let b = p("neck_1_joint") {
            place(torso, from: a, to: b, width: 0.34 * size, depth: 0.18 * size, side: across)
            let headSide = 0.25 * size
            var up = b - a
            if let h = p("head_joint") { up = h - b }
            up = simd_length(up) > 1e-4 ? simd_normalize(up) : SIMD3<Float>(0, 1, 0)
            var q = smoothedHead ?? simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            if let w = headMatrix {
                let cols = [w.columns.0, w.columns.1, w.columns.2].map { simd_normalize(SIMD3<Float>($0.x, $0.y, $0.z)) }
                func nearest(_ t: SIMD3<Float>) -> SIMD3<Float> {
                    var best = cols[0], score: Float = -2
                    for c in cols { for v in [c, -c] where simd_dot(v, t) > score { best = v; score = simd_dot(v, t) } }
                    return best
                }
                let facing = simd_normalize(simd_cross(across, b - a))
                let hy = nearest(up)
                var hz = nearest(facing)
                if abs(simd_dot(hy, hz)) > 0.5 { hz = facing }
                let hx = simd_normalize(simd_cross(hy, hz))
                let rot = simd_quatf(simd_float3x3(hx, hy, simd_cross(hx, hy)))
                q = tracked ? (smoothedHead.map { simd_slerp($0, rot, Self.follow) } ?? rot) : rot
                smoothedHead = q
            }
            head.transform = Transform(scale: SIMD3<Float>(repeating: headSide),
                                       rotation: q,
                                       translation: b + up * (0.5 * headSide + 0.01 * size))
        }
        for (i, (f, hnd)) in [("left_forearm_joint", "left_hand_joint"), ("right_forearm_joint", "right_hand_joint")].enumerated() {
            if let a = p(f), let b = p(hnd) {
                let dir = simd_normalize(b - a)
                hands[i].transform = Transform(scale: SIMD3<Float>(repeating: 0.10 * size),
                                               rotation: Self.frame(y: dir, xHint: twist(dir)),
                                               translation: b + dir * 0.05 * size)
            }
        }
        for limb in limbs {
            guard let a = p(limb.from), let b = p(limb.to) else { continue }
            place(limb.entity, from: a, to: b, width: limb.thickness * size, depth: limb.thickness * size, side: twist(b - a))
        }

        let wearing = wear && !worn.isEmpty
        torso.isEnabled = !wearing
        hands.forEach { $0.isEnabled = !wearing }
        limbs.forEach { $0.entity.isEnabled = !wearing }
        worn.forEach { $0.entity.isEnabled = wearing }
        if shouldLog {
            appLog.notice("app: tick wear=\(self.wear) worn=\(self.worn.count) wearing=\(wearing) head=\(self.head.position(relativeTo: nil).debugDescription, privacy: .public) headOn=\(self.head.isEnabled)")
        }
        if wearing {
            var g: Float = 1
            if let a = p("hips_joint"), let b = p("neck_1_joint") { g = simd_length(b - a) / restTorso }
            for w in worn {
                guard let o = p(w.spec.live.0), let a = p(w.spec.live.1), let b = p(w.spec.live.2) else {
                    w.entity.isEnabled = false
                    continue
                }
                let dir = b - a
                let along = w.spec.stretch ? simd_length(dir) / w.restLength : g
                let hint = w.spec.part.contains("Torso") ? across : twist(dir)
                w.entity.transform = Transform(scale: SIMD3<Float>(g, along, g),
                                               rotation: Self.frame(y: dir, xHint: hint),
                                               translation: o)
                if shouldLog && (w.spec.part == "UpperTorso" || w.spec.part == "LeftUpperArm" || w.spec.part == "LeftFoot") {
                    let vb = w.entity.visualBounds(relativeTo: nil)
                    appLog.notice("app: pose \(w.spec.part, privacy: .public) on=\(w.entity.isEnabled) active=\(w.entity.isActive) g=\(g) along=\(along) at=\(o.debugDescription, privacy: .public) vb=\(vb.min.debugDescription, privacy: .public)..\(vb.max.debugDescription, privacy: .public)")
                }
            }
        }

        let shadowOn = occlude && tracked
        shadowTorso.isEnabled = shadowOn
        shadowHead.isEnabled = shadowOn
        shadows.forEach { $0.entity.isEnabled = shadowOn }
        guard shadowOn else { return }
        let k = min(max(scaleHint, 0.6), 1.2)
        let realAcross: SIMD3<Float> = {
            if let l = world["left_arm_joint"], let r = world["right_arm_joint"] { return l - r }
            return SIMD3<Float>(1, 0, 0)
        }()
        if let a = world["hips_joint"], let b = world["neck_1_joint"] {
            place(shadowTorso, from: a, to: b, width: 0.30 * k, depth: 0.17 * k, side: realAcross)
        }
        if let h = world["head_joint"] {
            shadowHead.transform = Transform(scale: SIMD3<Float>(repeating: 0.19 * k), rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)), translation: h)
        }
        for s in shadows {
            guard let a = world[s.from], let b = world[s.to] else { continue }
            place(s.entity, from: a, to: b, width: s.thickness * k, depth: s.thickness * k, side: realAcross)
        }
    }

    private func place(_ e: ModelEntity, from a: SIMD3<Float>, to b: SIMD3<Float>,
                       width: Float, depth: Float, side: SIMD3<Float>) {
        let d = b - a
        let len = max(simd_length(d), 0.01)
        e.transform = Transform(scale: SIMD3<Float>(width, len, depth),
                                rotation: Self.frame(y: d, xHint: side),
                                translation: (a + b) / 2)
    }

    static func limbHint(_ dir: SIMD3<Float>, facing: SIMD3<Float>, across: SIMD3<Float>) -> SIMD3<Float> {
        guard simd_length(dir) > 1e-5, simd_length(across) > 1e-5 else { return across }
        let h = simd_cross(facing, simd_normalize(dir))
        let w = min(simd_length(h) / 0.5, 1)
        return h * w + simd_normalize(across) * (1 - w)
    }

    static func frame(y: SIMD3<Float>, xHint: SIMD3<Float>) -> simd_quatf {
        simd_quatf(basis(y: y, xHint: xHint))
    }

    static func basis(y: SIMD3<Float>, xHint: SIMD3<Float>) -> simd_float3x3 {
        let yN = simd_length(y) > 1e-5 ? simd_normalize(y) : SIMD3<Float>(0, 1, 0)
        var x = xHint - simd_dot(xHint, yN) * yN
        if simd_length(x) < 1e-4 {
            let alt: SIMD3<Float> = abs(yN.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 0, 1)
            x = alt - simd_dot(alt, yN) * yN
        }
        x = simd_normalize(x)
        let z = simd_cross(x, yN)
        return simd_float3x3(x, yN, z)
    }
}

enum BlockHead {
    static func make() -> ModelEntity {
        var side = UnlitMaterial(), front = UnlitMaterial()
        if let t = texture(face: false) { side.color = .init(tint: .white, texture: .init(t)) }
        if let t = texture(face: true) { front.color = .init(tint: .white, texture: .init(t)) }
        guard let mesh = try? MeshResource.generate(from: [faces(front: false), faces(front: true)]) else {
            return ModelEntity(mesh: .generateBox(size: 1), materials: [side])
        }
        return ModelEntity(mesh: mesh, materials: [side, front])
    }

    private static func faces(front: Bool) -> MeshDescriptor {
        let all: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            ([0, 0, 1], [1, 0, 0], [0, 1, 0]),
            ([1, 0, 0], [0, 0, -1], [0, 1, 0]),
            ([-1, 0, 0], [0, 0, 1], [0, 1, 0]),
            ([0, 1, 0], [1, 0, 0], [0, 0, -1]),
            ([0, -1, 0], [1, 0, 0], [0, 0, 1]),
            ([0, 0, -1], [-1, 0, 0], [0, 1, 0]),
        ]
        var pos: [SIMD3<Float>] = [], nor: [SIMD3<Float>] = [], uv: [SIMD2<Float>] = [], idx: [UInt32] = []
        for (k, (n, u, v)) in all.enumerated() where (k == 0) == front {
            let base = UInt32(pos.count)
            for (a, b) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
                pos.append(n * 0.5 + u * (0.5 * a) + v * (0.5 * b))
                nor.append(n)
                uv.append(SIMD2((a + 1) / 2, (b + 1) / 2))
            }
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        var d = MeshDescriptor(name: front ? "headFront" : "headSides")
        d.positions = MeshBuffers.Positions(pos)
        d.normals = MeshBuffers.Normals(nor)
        d.textureCoordinates = MeshBuffers.TextureCoordinates(uv)
        d.primitives = .triangles(idx)
        d.materials = .allFaces(front ? 1 : 0)
        return d
    }

    private static func texture(face: Bool) -> TextureResource? {
        let px = 256, cell = px / 8
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let pale: [(CGFloat, CGFloat, CGFloat)] = [
            (0.96, 0.97, 0.94), (0.93, 0.96, 0.90), (0.86, 0.93, 0.76), (0.78, 0.90, 0.64), (0.90, 0.95, 0.84),
        ]
        var seed: UInt32 = face ? 7 : 3
        func next() -> Int { seed = seed &* 1_664_525 &+ 1_013_904_223; return Int(seed >> 24) }
        let dark: Set<Int> = face ? [2 * 8 + 1, 2 * 8 + 2, 2 * 8 + 5, 2 * 8 + 6,
                                     3 * 8 + 1, 3 * 8 + 2, 3 * 8 + 5, 3 * 8 + 6,
                                     4 * 8 + 3, 4 * 8 + 4,
                                     5 * 8 + 2, 5 * 8 + 3, 5 * 8 + 4, 5 * 8 + 5,
                                     6 * 8 + 2, 6 * 8 + 3, 6 * 8 + 4, 6 * 8 + 5,
                                     7 * 8 + 2, 7 * 8 + 5] : []
        for row in 0..<8 {
            for col in 0..<8 {
                let c = pale[next() % pale.count]
                if dark.contains(row * 8 + col) { ctx.setFillColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1) }
                else { ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1) }
                ctx.fill(CGRect(x: col * cell, y: (7 - row) * cell, width: cell, height: cell))
            }
        }
        guard let image = ctx.makeImage() else { return nil }
        return try? TextureResource.generate(from: image, options: .init(semantic: .color))
    }
}
