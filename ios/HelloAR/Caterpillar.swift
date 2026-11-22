import RealityKit
import simd
import Foundation

// The caterpillar (installations card 27: "a caterpillar of yourself that grows
// a segment per step along your real route").
//
// GROWING (GO): every 15 cm of your walk adds the next chakra solid.
// CRAWLING (STOP): the body slides forward along the route you walked. The head
//   leads, arcs back through the air to where you started, and the creature
//   circles its own walk for ever: an ouroboros of your route.
// ALWAYS: a swell runs tail to head (peristalsis) and lifts a small hump, and
//   the crawl surges on the swell, inchworm fashion. Each element keeps a
//   little of its nature: earth sits still, water bobs, fire flickers, air
//   drifts, ether tumbles, Ajna blinks, the crown disc spins and breathes.
final class Caterpillar {
    let root = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
    private(set) var path: [SIMD3<Float>] = []
    private var segments: [(entity: ModelEntity, kind: Int)] = []
    private var loop: [SIMD3<Float>] = []
    private var crawl: Double = 0          // how far the body has slid along the loop, in segments
    private(set) var crawling = false
    private lazy var chakras = Chakra.all()

    static let spacing: Float = 0.15       // metres between segments
    static let waveHz = 0.7                // the swell
    static let crawlSpeed = 2.2            // segments per second at the top of a surge

    var count: Int { segments.count }

    /// Add the next segment at p. Returns the chakra's name.
    func grow(at p: SIMD3<Float>) -> String {
        if crawling { stopCrawling() }
        let kind = segments.count % chakras.count
        let c = chakras[kind]
        let e = ModelEntity(mesh: c.mesh, materials: [c.material])
        e.position = p
        root.addChild(e)
        segments.append((entity: e, kind: kind))
        path.append(p)
        return c.name
    }

    func startCrawling() {
        guard segments.count >= 8, let last = path.last, let first = path.first else { return }
        loop = path + Self.returnLeg(from: last, to: first)
        crawl = 0
        crawling = true
    }

    /// Back to where each segment was laid (used when GO is pressed again).
    func stopCrawling() {
        crawling = false
        crawl = 0
    }

    func clear() {
        for s in segments { s.entity.removeFromParent() }
        segments.removeAll()
        path.removeAll()
        loop.removeAll()
        stopCrawling()
    }

    func update(time t: Double, deltaTime dt: Double) {
        guard !segments.isEmpty else { return }
        let omega = 2 * Double.pi * Self.waveHz
        if crawling && !loop.isEmpty {
            let surge = 0.25 + 0.75 * max(0, sin(omega * t))
            crawl += dt * Self.crawlSpeed * surge
            let n = Double(loop.count)
            if crawl >= n { crawl -= n }
        }
        let tf = Float(t)
        for (i, seg) in segments.enumerated() {
            let fi = Float(i)
            let phase = omega * t - 0.55 * Double(i)          // travels tail -> head
            let swell = Float(pow(max(0, sin(phase)), 2))     // 0...1
            var p = crawling ? point(at: Double(i) + crawl) : path[i]
            p.y += 0.05 * swell                               // the hump
            var s = SIMD3<Float>(repeating: 1 + 0.35 * swell)
            var q = simd_quatf(angle: tf * 0.6 + fi * 0.9, axis: SIMD3<Float>(0, 1, 0))

            switch seg.kind {
            case 1: // water: bobs
                p.y += 0.012 * sinf(2.2 * tf + fi)
            case 2: // fire: flickers
                s *= 1 + 0.10 * sinf(13 * tf + fi) * sinf(7.3 * tf + 2 * fi)
            case 3: // air: drifts up and down, slowly
                p.y += 0.03 * sinf(0.8 * tf + 0.5 * fi)
            case 4: // ether: tumbles on every axis
                let axis = simd_normalize(SIMD3<Float>(1, 0.4, 0.7))
                q = q * simd_quatf(angle: 1.3 * tf + fi, axis: axis)
            case 5: // Ajna: blinks
                s *= 0.8 + 0.6 * powf(max(0, sinf(1.6 * tf + fi)), 12)
            case 6: // crown: spins and breathes open
                q = simd_quatf(angle: 2.5 * tf + fi, axis: SIMD3<Float>(0, 1, 0))
                let open = 1 + 0.2 * sinf(1.1 * tf + fi)
                s.x *= open
                s.z *= open
            default: // earth: still
                break
            }

            seg.entity.position = p
            seg.entity.orientation = q
            seg.entity.scale = s
        }
    }

    // MARK: path

    private func point(at u: Double) -> SIMD3<Float> {
        let n = loop.count
        var w = u.truncatingRemainder(dividingBy: Double(n))
        if w < 0 { w += Double(n) }
        let i0 = Int(w) % n
        let i1 = (i0 + 1) % n
        let f = Float(w - Double(Int(w)))
        return simd_mix(loop[i0], loop[i1], SIMD3<Float>(repeating: f))
    }

    /// From the head back to the tail's start: a straight line lifted into an arch.
    static func returnLeg(from a: SIMD3<Float>, to b: SIMD3<Float>) -> [SIMD3<Float>] {
        let d = simd_distance(a, b)
        let m = max(1, Int(d / spacing))
        let arch = min(0.6, 0.15 * d)
        return (1..<m).map { k in
            let f = Float(k) / Float(m)
            var p = simd_mix(a, b, SIMD3<Float>(repeating: f))
            p.y += arch * sinf(Float.pi * f)
            return p
        }
    }
}
