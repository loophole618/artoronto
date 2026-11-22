// A procession of walking figures moving forward along a recorded path, in the site's frame.
import Foundation
import RealityKit
import simd

final class Procession {
    let root = Entity()
    let gait = Walker()
    private(set) var path: [SIMD3<Float>] = []
    private var cum: [Float] = []
    private var figures: [BlockFigure] = []
    private var t: Float = 0

    var count = 5
    var spacing: Float = 1.5
    var speed: Float = 0.9

    var length: Float { cum.last ?? 0 }

    func frame(at s: Float) -> (point: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard path.count > 1, s <= length else { return nil }
        var d = point(at: s + 0.25) - point(at: s - 0.25)
        d.y = 0
        guard simd_length(d) > 1e-4 else { return nil }
        return (point(at: s), simd_normalize(d))
    }

    var start: (point: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard path.count > 1 else { return nil }
        var d = point(at: 0.5) - path[0]
        d.y = 0
        return simd_length(d) > 1e-4 ? (path[0], simd_normalize(d)) : nil
    }
    var figureCount: Int { figures.count }

    func setPath(_ points: [SIMD3<Float>]) {
        path = []; cum = []
        for p in points {
            if let last = path.last {
                let d = simd_distance(last, p)
                guard d >= 0.05 else { continue }
                path.append(p); cum.append(cum.last! + d)
            } else {
                path.append(p); cum.append(0)
            }
        }
        t = 0
    }

    func clear() {
        setPath([])
        figures.forEach { $0.root.isEnabled = false }
    }

    func rebuild(model: AvatarModel?) {
        figures.forEach { $0.root.removeFromParent() }
        figures = (0..<count).map { _ in
            let f = BlockFigure(anchored: false)
            if let model { f.dress(with: model) }
            root.addChild(f.root)
            return f
        }
        if let model { gait.useSkeleton(from: model) }
    }

    func update(dt: Float, wear: Bool) {
        guard length > 0.5, !figures.isEmpty else {
            figures.forEach { $0.root.isEnabled = false }
            return
        }
        t += dt
        let cycle = max(length + spacing, spacing * Float(figures.count))
        for (i, f) in figures.enumerated() {
            f.wear = wear
            var s = (t * speed - Float(i) * spacing).truncatingRemainder(dividingBy: cycle)
            if s < 0 { s += cycle }
            guard s <= length else { f.root.isEnabled = false; continue }
            var fwd = point(at: s + 0.25) - point(at: s - 0.25)
            fwd.y = 0
            fwd = simd_length(fwd) > 1e-4 ? simd_normalize(fwd) : SIMD3(0, 0, -1)
            let pose = gait.pose(at: point(at: s), forward: fwd, phase: s / gait.cycleLength * 2 * .pi, amount: 1)
            f.update(walker: pose.joints, headMatrix: pose.head)
        }
    }

    private func point(at d: Float) -> SIMD3<Float> {
        guard let total = cum.last, path.count > 1 else { return path.first ?? .zero }
        let d = min(max(d, 0), total)
        var lo = 0, hi = cum.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if cum[mid] <= d { lo = mid } else { hi = mid } }
        let span = cum[hi] - cum[lo]
        let k = span > 0 ? (d - cum[lo]) / span : 0
        return path[lo] + (path[hi] - path[lo]) * k
    }
}
