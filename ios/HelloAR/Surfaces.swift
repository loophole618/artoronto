// What Firepearl can stand on: the floor, seats (chairs, couch cushions), tables and bed-sized surfaces,
// from ARKit's classified horizontal planes.
import ARKit
import simd

final class Surfaces {
    enum Kind: String { case seat, bed, table, ledge }

    struct Plane {
        let id: UUID
        let classification: String   // floor / seat / table / ceiling / other
        let transform: simd_float4x4
        let center: SIMD3<Float>     // in the anchor's frame
        let width: Float             // along the rectangle's x
        let depth: Float             // along the rectangle's z
        let rotation: Float          // the rectangle's turn about the anchor's y
        var y: Float { (transform * SIMD4<Float>(center, 1)).y }
        var area: Float { width * depth }
        var worldCenter: SIMD3<Float> { let c = transform * SIMD4<Float>(center, 1); return SIMD3(c.x, c.y, c.z) }
    }

    struct Perch {
        let plane: Plane
        let kind: Kind
        let spot: SIMD3<Float>
    }

    private(set) var planes: [UUID: Plane] = [:]

    func clear() { planes.removeAll() }

    func update(_ anchors: [ARAnchor]) {
        for case let a as ARPlaneAnchor in anchors where a.alignment == .horizontal {
            let cls: String
            switch a.classification {
            case .floor: cls = "floor"
            case .seat: cls = "seat"
            case .table: cls = "table"
            case .ceiling: cls = "ceiling"
            default: cls = "other"
            }
            planes[a.identifier] = Plane(id: a.identifier, classification: cls, transform: a.transform, center: a.center,
                                         width: a.planeExtent.width, depth: a.planeExtent.height,
                                         rotation: a.planeExtent.rotationOnYAxis)
        }
    }

    func remove(_ anchors: [ARAnchor]) {
        for a in anchors where a is ARPlaneAnchor { planes[a.identifier] = nil }
    }

    /// The floor under a point (the phone, say): the nearest floor plane below it. Sitting on the couch doesn't fool it.
    func floor(below p: SIMD3<Float>) -> Float? {
        var best: Float?
        for pl in planes.values where pl.classification == "floor" {
            let drop = p.y - pl.y
            guard drop > 0.3, drop < 2.6, horizontalDistance(p, to: pl) < 2.5 else { continue }
            if best == nil || pl.y > best! { best = pl.y }
        }
        return best
    }

    /// What a raised surface is, judged by its label, height above the floor and size; nil if she shouldn't perch there.
    func kind(of pl: Plane, floorY: Float) -> Kind? {
        let h = pl.y - floorY
        guard h > 0.2, h < 1.25, pl.classification != "ceiling", pl.classification != "floor" else { return nil }
        switch pl.classification {
        case "seat": return .seat
        case "table": return .table
        default:
            if pl.area > 1.4 && h < 0.85 { return .bed }
            return pl.area > 0.12 ? .ledge : nil
        }
    }

    /// The best spot to perch near someone: on a surface within reach, beside them (not on their lap).
    func perch(near person: SIMD3<Float>, from dragon: SIMD3<Float>, floorY: Float) -> Perch? {
        var best: (Perch, Float)?
        for pl in planes.values {
            guard let k = kind(of: pl, floorY: floorY) else { continue }
            guard pl.width > 0.3, pl.depth > 0.3 else { continue }
            var spot = closestInside(pl, to: person, inset: 0.15)
            var away = SIMD3<Float>(spot.x - person.x, 0, spot.z - person.z)
            if simd_length(away) < 0.4 {
                // too close to her: slide along the surface away from her
                away = simd_length(away) > 1e-3 ? simd_normalize(away) : simd_normalize(SIMD3<Float>(pl.worldCenter.x - person.x, 0, pl.worldCenter.z - person.z) + SIMD3(1e-3, 0, 0))
                spot = closestInside(pl, to: person + away * 0.45, inset: 0.15)
            }
            let toHer = simd_length(SIMD2<Float>(spot.x - person.x, spot.z - person.z))
            let toMe = simd_distance(spot, dragon)
            guard toHer < 1.6, toMe < 5 else { continue }
            let preference: Float
            switch k {
            case .seat: preference = 0
            case .bed: preference = 0.1
            case .ledge: preference = 0.3
            case .table: preference = 0.5
            }
            let score = preference + toHer
            if best == nil || score < best!.1 { best = (Perch(plane: pl, kind: k, spot: spot), score) }
        }
        return best?.0
    }

    /// Keeps a walking dragon out of couches and beds (raised seat/bed surfaces); tables she can walk under.
    func pushOut(_ p: SIMD3<Float>, floorY: Float) -> SIMD3<Float> {
        var q = p
        for pl in planes.values {
            guard let k = kind(of: pl, floorY: floorY), k == .seat || k == .bed else { continue }
            var l = local(pl, q)
            let hx = pl.width / 2 + 0.12, hz = pl.depth / 2 + 0.12
            guard abs(l.x) < hx, abs(l.y) < hz else { continue }
            if hx - abs(l.x) < hz - abs(l.y) { l.x = l.x < 0 ? -hx : hx } else { l.y = l.y < 0 ? -hz : hz }
            let w = world(pl, l)
            q.x = w.x
            q.z = w.z
        }
        return q
    }

    func summary(floorY: Float?) -> String {
        guard let floorY else { return planes.isEmpty ? "looking…" : "\(planes.count) planes, no floor yet" }
        var counts: [Kind: Int] = [:]
        for pl in planes.values { if let k = kind(of: pl, floorY: floorY) { counts[k, default: 0] += 1 } }
        let parts = [Kind.seat, .bed, .table, .ledge].compactMap { k in counts[k].map { "\($0) \(k.rawValue)\($0 > 1 ? "s" : "")" } }
        return "floor ✓" + (parts.isEmpty ? "" : " · " + parts.joined(separator: " · "))
    }

    // MARK: - rectangle geometry (plane frame: x along width, y holds z along depth)

    private func local(_ pl: Plane, _ p: SIMD3<Float>) -> SIMD2<Float> {
        let l = pl.transform.inverse * SIMD4<Float>(p, 1)
        let dx = l.x - pl.center.x, dz = l.z - pl.center.z
        let c = cosf(-pl.rotation), s = sinf(-pl.rotation)
        return SIMD2(dx * c + dz * s, -dx * s + dz * c)
    }

    private func world(_ pl: Plane, _ r: SIMD2<Float>) -> SIMD3<Float> {
        let c = cosf(pl.rotation), s = sinf(pl.rotation)
        let dx = r.x * c + r.y * s, dz = -r.x * s + r.y * c
        let w = pl.transform * SIMD4<Float>(pl.center.x + dx, pl.center.y, pl.center.z + dz, 1)
        return SIMD3(w.x, w.y, w.z)
    }

    private func closestInside(_ pl: Plane, to p: SIMD3<Float>, inset: Float) -> SIMD3<Float> {
        var l = local(pl, p)
        let hx = max(0, pl.width / 2 - inset), hz = max(0, pl.depth / 2 - inset)
        l.x = min(max(l.x, -hx), hx)
        l.y = min(max(l.y, -hz), hz)
        return world(pl, l)
    }

    private func horizontalDistance(_ p: SIMD3<Float>, to pl: Plane) -> Float {
        let q = closestInside(pl, to: p, inset: 0)
        return simd_length(SIMD2<Float>(q.x - p.x, q.z - p.z))
    }
}
