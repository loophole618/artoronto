// CITY scale: Toronto lots and zoning around the phone, from the City's open data. Point the phone to pick a lot.
import Foundation
import RealityKit
import ARKit
import CoreLocation
import UIKit

/// One lot, in metres around the layer's origin: x east, y north.
struct CityLot {
    let id: Int
    let rings: [[SIMD2<Float>]]
    let point: SIMD2<Float>
    var address = ""
    var zone = ""
    var zoneText = ""
    var height: Float?
    var heightText = ""
    /// Left out of city-wide By-law 569-2013 ("Zoning Not Part of This By-law"): still under a former by-law.
    var excluded = false
    var formerBylaw = ""   // e.g. "438-86", from "Zoning Former Municipality By-laws"
    var refZone = ""       // what the 569-2013 map shows there for reference, e.g. "R (d1.0) (x810)"

    /// The lines a label shows: address, zoning, height (and the 569-2013 reference for an excluded lot).
    var lines: [String] {
        var out = [address.isEmpty ? "lot \(id)" : address]
        if !zoneText.isEmpty {
            out.append(zoneText)
        } else if excluded {
            out.append("NOT IN 569-2013" + (formerBylaw.isEmpty ? "" : " · By-law \(formerBylaw)"))
            if !refZone.isEmpty { out.append("569 map shows \(refZone)") }
        } else {
            out.append(formerBylaw.isEmpty ? "no zoning found" : "By-law \(formerBylaw) only")
        }
        out.append(heightText.isEmpty ? "no height overlay" : heightText)
        return out
    }

    var label: String { lines.joined(separator: " · ") }
}

enum CityError: LocalizedError {
    case bad(String)
    var errorDescription: String? { switch self { case .bad(let s): return s } }
}

/// The City of Toronto's public ArcGIS layers (the same ones Skyewriter's "Toronto Online" provider reads).
enum CityData {
    static let root = "https://gis.toronto.ca/arcgis/rest/services"
    static let parcels = root + "/cot_geospatial27/MapServer/36"
    static let zoning = root + "/cot_geospatial11/FeatureServer/3"
    static let heights = root + "/cot_geospatial11/FeatureServer/9"
    static let addresses = root + "/cot_geospatial27/MapServer/101"
    static let notPart = root + "/cot_geospatial11/FeatureServer/12"   // Zoning Not Part of This By-law
    static let former = root + "/cot_geospatial11/FeatureServer/8"     // Zoning Former Municipality By-laws

    /// The City publishes NAD83(CSRS) coordinates as if they were WGS84; Apple's anchors are WGS84 (ITRF2014).
    /// At epoch 2026.9 the shift is 0.81 m west and 1.07 m north (pyproj at 480 Brock, the same to a few cm city-wide).
    static let datumShift = SIMD2<Float>(-0.81, 1.07)

    /// Metres per degree of longitude and latitude on the WGS84 ellipsoid.
    static func metresPerDegree(_ lat: Double) -> (lon: Double, lat: Double) {
        let p = lat * .pi / 180
        return (111_412.84 * cos(p) - 93.5 * cos(3 * p),
                111_132.954 - 559.822 * cos(2 * p) + 1.175 * cos(4 * p))
    }

    struct Feature {
        let props: [String: Any]
        let rings: [[[Double]]]   // outer rings of [lon, lat]
    }

    static func box(_ c: CLLocationCoordinate2D, _ r: Double) -> String {
        let k = metresPerDegree(c.latitude)
        let dlon = r / k.lon, dlat = r / k.lat
        return String(format: "%.7f,%.7f,%.7f,%.7f", c.longitude - dlon, c.latitude - dlat, c.longitude + dlon, c.latitude + dlat)
    }

    /// The box that covers every parcel found (a big lot reaches past the search box, and its
    /// address point or zone can lie outside it), capped at `cap` metres around `c`.
    static func cover(_ parcels: [Feature], around c: CLLocationCoordinate2D, radius r: Double, cap: Double) -> String {
        let k = metresPerDegree(c.latitude)
        var lo = (c.longitude - r / k.lon, c.latitude - r / k.lat), hi = (c.longitude + r / k.lon, c.latitude + r / k.lat)
        for f in parcels {
            for ring in f.rings {
                for p in ring where p.count >= 2 {
                    lo = (min(lo.0, p[0]), min(lo.1, p[1]))
                    hi = (max(hi.0, p[0]), max(hi.1, p[1]))
                }
            }
        }
        lo = (max(lo.0, c.longitude - cap / k.lon), max(lo.1, c.latitude - cap / k.lat))
        hi = (min(hi.0, c.longitude + cap / k.lon), min(hi.1, c.latitude + cap / k.lat))
        return String(format: "%.7f,%.7f,%.7f,%.7f", lo.0, lo.1, hi.0, hi.1)
    }

    static func query(_ layer: String, fields: String, box: String) async throws -> [Feature] {
        var u = URLComponents(string: layer + "/query")!
        u.queryItems = [
            URLQueryItem(name: "where", value: "1=1"),
            URLQueryItem(name: "geometry", value: box),
            URLQueryItem(name: "geometryType", value: "esriGeometryEnvelope"),
            URLQueryItem(name: "inSR", value: "4326"),
            URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            URLQueryItem(name: "outFields", value: fields),
            URLQueryItem(name: "outSR", value: "4326"),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "resultRecordCount", value: "2000"),
            URLQueryItem(name: "f", value: "geojson"),
        ]
        guard let url = u.url else { throw CityError.bad("bad URL") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CityError.bad("not JSON") }
        if let err = json["error"] as? [String: Any] { throw CityError.bad(err["message"] as? String ?? "server error") }
        let feats = json["features"] as? [[String: Any]] ?? []
        return feats.map { f in
            let props = f["properties"] as? [String: Any] ?? [:]
            var rings: [[[Double]]] = []
            if let g = f["geometry"] as? [String: Any] {
                switch g["type"] as? String ?? "" {
                case "Polygon":
                    if let c = g["coordinates"] as? [[[Double]]], let outer = c.first { rings = [outer] }
                case "MultiPolygon":
                    if let c = g["coordinates"] as? [[[[Double]]]] { rings = c.compactMap { $0.first } }
                case "Point":
                    if let c = g["coordinates"] as? [Double] { rings = [[c]] }
                default: break
                }
            }
            return Feature(props: props, rings: rings)
        }
    }

    /// Lots inside the box around `c`, each tagged with its zone, height overlay and address.
    static func load(around c: CLLocationCoordinate2D, radius: Double) async throws -> [CityLot] {
        let pf = try await query(parcels, fields: "OBJECTID,PARCELID,FEATURE_TYPE,DATE_EXPIRY", box: box(c, radius))
        let b = cover(pf, around: c, radius: radius, cap: 400)
        async let z = query(zoning, fields: "ZN_ZONE,ZN_STRING", box: b)
        async let h = query(heights, fields: "HT_HEIGHT,HT_STORIES,HT_STRING", box: b)
        async let a = query(addresses, fields: "ADDRESS_FULL,LO_NUM,CLASS_FAMILY_DESC", box: b)
        async let n = query(notPart, fields: "ZN_ZONE,ZN_STRING,ZN_FSI_DENSITY,ZN_EXCPTN_NO", box: b)
        async let fb = query(former, fields: "BL_NO,DISPLAY_LABEL", box: b)
        let zf = (try? await z) ?? []
        let hf = (try? await h) ?? []
        let af = (try? await a) ?? []
        let nf = (try? await n) ?? []
        let ff = (try? await fb) ?? []

        let k = metresPerDegree(c.latitude)
        func local(_ ll: [Double]) -> SIMD2<Float> {
            SIMD2(Float((ll[0] - c.longitude) * k.lon), Float((ll[1] - c.latitude) * k.lat)) + datumShift
        }
        func rings(_ f: Feature) -> [[SIMD2<Float>]] {
            f.rings.map { Geo.clean($0.filter { $0.count >= 2 }.map(local)) }.filter { $0.count >= 3 }
        }

        let zones = zf.compactMap { f -> (rings: [[SIMD2<Float>]], area: Float, zone: String, text: String)? in
            let r = rings(f)
            guard !r.isEmpty else { return nil }
            return (r, r.map(Geo.area).reduce(0, +), f.props["ZN_ZONE"] as? String ?? "", f.props["ZN_STRING"] as? String ?? "")
        }
        let overlays = hf.compactMap { f -> (rings: [[SIMD2<Float>]], area: Float, height: Float?, text: String)? in
            let r = rings(f)
            guard !r.isEmpty else { return nil }
            let ht = (f.props["HT_HEIGHT"] as? Double).map { Float($0) }
            var text = f.props["HT_STRING"] as? String ?? ""
            if let st = f.props["HT_STORIES"] as? Double, st > 0 { text += String(format: " · %.0f storeys", st) }
            return (r, r.map(Geo.area).reduce(0, +), ht, text)
        }
        let excluded = nf.compactMap { f -> (rings: [[SIMD2<Float>]], area: Float, ref: String)? in
            let r = rings(f)
            guard !r.isEmpty else { return nil }
            var ref = (f.props["ZN_STRING"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if ref.isEmpty, let zn = f.props["ZN_ZONE"] as? String, !zn.isEmpty {
                ref = zn
                if let d = f.props["ZN_FSI_DENSITY"] as? Double, d > 0 { ref += String(format: " (d%.1f)", d) }
                if let x = f.props["ZN_EXCPTN_NO"] as? Int, x > 0 { ref += " (x\(x))" }
            }
            return (r, r.map(Geo.area).reduce(0, +), ref)
        }
        let formers = ff.compactMap { f -> (rings: [[SIMD2<Float>]], area: Float, bylaw: String)? in
            let r = rings(f)
            guard !r.isEmpty else { return nil }
            return (r, r.map(Geo.area).reduce(0, +), f.props["BL_NO"] as? String ?? "")
        }
        let points = af.compactMap { f -> (p: SIMD2<Float>, name: String, num: Int, land: Bool)? in
            guard let ll = f.rings.first?.first, ll.count >= 2 else { return nil }
            return (local(ll), f.props["ADDRESS_FULL"] as? String ?? "", f.props["LO_NUM"] as? Int ?? 0,
                    (f.props["CLASS_FAMILY_DESC"] as? String ?? "").contains("Land"))
        }

        let now = Date().timeIntervalSince1970 * 1000
        var lots: [CityLot] = []
        for f in pf {
            if let exp = f.props["DATE_EXPIRY"] as? Double, exp < now { continue }
            let r = rings(f)
            guard let biggest = r.max(by: { Geo.area($0) < Geo.area($1) }) else { continue }
            let id = (f.props["PARCELID"] as? Int) ?? (f.props["OBJECTID"] as? Int) ?? lots.count
            var lot = CityLot(id: id, rings: r, point: Geo.inside(biggest))
            if let zn = zones.filter({ $0.rings.contains { Geo.contains($0, lot.point) } }).min(by: { $0.area < $1.area }) {
                lot.zone = zn.zone
                lot.zoneText = zn.text
            }
            if lot.zoneText.isEmpty,
               let ex = excluded.filter({ $0.rings.contains { Geo.contains($0, lot.point) } }).min(by: { $0.area < $1.area }) {
                lot.excluded = true
                lot.refZone = ex.ref
                lot.zone = "EXCLUDED"
            }
            if lot.zoneText.isEmpty,
               let fm = formers.filter({ $0.rings.contains { Geo.contains($0, lot.point) } }).min(by: { $0.area < $1.area }) {
                lot.formerBylaw = fm.bylaw
            }
            if let ht = overlays.filter({ $0.rings.contains { Geo.contains($0, lot.point) } }).min(by: { $0.area < $1.area }) {
                lot.height = ht.height
                lot.heightText = ht.text
            }
            let here = points.filter { pt in r.contains { Geo.contains($0, pt.p) } }
                .sorted { ($0.land ? 0 : 1, $0.num) < ($1.land ? 0 : 1, $1.num) }
            if let first = here.first {
                lot.address = first.name + (here.count > 1 ? " +\(here.count - 1)" : "")
            }
            lots.append(lot)
        }
        return lots
    }
}

/// Plane geometry for lots, in metres.
enum Geo {
    static func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }

    static func signedArea(_ r: [SIMD2<Float>]) -> Float {
        var s: Float = 0
        for i in r.indices { s += cross(r[i], r[(i + 1) % r.count]) }
        return s / 2
    }

    static func area(_ r: [SIMD2<Float>]) -> Float { abs(signedArea(r)) }

    /// Even-odd point in polygon.
    static func contains(_ r: [SIMD2<Float>], _ p: SIMD2<Float>) -> Bool {
        var inside = false
        var j = r.count - 1
        for i in r.indices {
            let a = r[i], b = r[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Drops the closing vertex, near-duplicates and straight-through vertices.
    static func clean(_ ring: [SIMD2<Float>]) -> [SIMD2<Float>] {
        var r: [SIMD2<Float>] = []
        for p in ring where r.last.map({ simd_distance($0, p) > 0.02 }) ?? true { r.append(p) }
        if r.count > 1, simd_distance(r[0], r[r.count - 1]) <= 0.02 { r.removeLast() }
        var changed = true
        while changed && r.count > 3 {
            changed = false
            for i in r.indices {
                let a = r[(i + r.count - 1) % r.count], b = r[i], c = r[(i + 1) % r.count]
                if abs(cross(b - a, c - b)) < 0.0005 { r.remove(at: i); changed = true; break }
            }
        }
        return r
    }

    /// A point inside the ring: the centroid if it's inside, else the middle of the first span across the middle.
    static func inside(_ r: [SIMD2<Float>]) -> SIMD2<Float> {
        let a = signedArea(r)
        var c = SIMD2<Float>(0, 0)
        if abs(a) > 1e-4 {
            for i in r.indices {
                let p = r[i], q = r[(i + 1) % r.count]
                c += (p + q) * cross(p, q)
            }
            c /= 6 * a
            if contains(r, c) { return c }
        }
        let ys = r.map { $0.y }
        let y = (ys.min()! + ys.max()!) / 2
        var xs: [Float] = []
        var j = r.count - 1
        for i in r.indices {
            let p = r[i], q = r[j]
            if (p.y > y) != (q.y > y) { xs.append(p.x + (y - p.y) * (q.x - p.x) / (q.y - p.y)) }
            j = i
        }
        xs.sort()
        return xs.count >= 2 ? SIMD2((xs[0] + xs[1]) / 2, y) : r[0]
    }

    /// Ear clipping. Returns triangles as index triples into `r`, counter-clockwise in plan.
    static func triangulate(_ r: [SIMD2<Float>]) -> [Int] {
        var idx = Array(r.indices)
        if signedArea(r) < 0 { idx.reverse() }
        func inTri(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
            cross(b - a, p - a) >= 0 && cross(c - b, p - b) >= 0 && cross(a - c, p - c) >= 0
        }
        var out: [Int] = []
        while idx.count > 3 {
            var clipped = false
            for i in idx.indices {
                let a = idx[(i + idx.count - 1) % idx.count], b = idx[i], c = idx[(i + 1) % idx.count]
                if cross(r[b] - r[a], r[c] - r[b]) <= 0 { continue }
                if idx.contains(where: { $0 != a && $0 != b && $0 != c && inTri(r[$0], r[a], r[b], r[c]) }) { continue }
                out += [a, b, c]
                idx.remove(at: i)
                clipped = true
                break
            }
            if !clipped { break }
        }
        if idx.count == 3 { out += idx } else if idx.count > 3 {
            for i in 1..<(idx.count - 1) { out += [idx[0], idx[i], idx[i + 1]] }
        }
        return out
    }

    /// Distance along the ray to where it first meets the lot's prism (0...h), or nil.
    /// A lot you're standing in only counts where you point down at its ground.
    static func hit(_ lot: CityLot, o: SIMD2<Float>, u0: Float, d: SIMD2<Float>, du: Float, h: Float, maxT: Float) -> Float? {
        var best: Float?
        func take(_ t: Float) { if t > 0.3, t < maxT, t < (best ?? .infinity) { best = t } }
        let standing = lot.rings.contains { contains($0, o) }
        for r in lot.rings {
            if !standing {
                for i in r.indices {
                    let a = r[i], e = r[(i + 1) % r.count] - a
                    let den = cross(d, e)
                    if abs(den) < 1e-6 { continue }
                    let w = a - o
                    let t = cross(w, e) / den, s = cross(w, d) / den
                    if s >= 0, s <= 1 {
                        let u = u0 + du * t
                        if u >= 0, u <= h { take(t) }
                    }
                }
            }
            if abs(du) > 1e-5 {
                for y in standing ? [Float(0)] : [Float(0), h] {
                    let t = (y - u0) / du
                    if t > 0.3, contains(r, o + d * t) { take(t) }
                }
            }
        }
        return best
    }
}

/// Meshes for the city layer. Local frame: x east, y up, z south (plan point (e, n) sits at (e, y, -n)).
enum CityModel {
    static func p3(_ p: SIMD2<Float>, _ y: Float) -> SIMD3<Float> { SIMD3(p.x, y, -p.y) }

    final class Builder {
        var pos: [SIMD3<Float>] = [], nor: [SIMD3<Float>] = [], idx: [UInt32] = []
        /// One triangle, wound so it faces along `n`.
        func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ n: SIMD3<Float>) {
            let (p, q) = simd_dot(simd_cross(b - a, c - a), n) >= 0 ? (b, c) : (c, b)
            let base = UInt32(pos.count)
            pos += [a, p, q]
            nor += [n, n, n]
            idx += [base, base + 1, base + 2]
        }
        func mesh(_ name: String) -> MeshResource? {
            guard !idx.isEmpty else { return nil }
            var d = MeshDescriptor(name: name)
            d.positions = MeshBuffers.Positions(pos)
            d.normals = MeshBuffers.Normals(nor)
            d.primitives = .triangles(idx)
            return try? MeshResource.generate(from: [d])
        }
    }

    /// Every lot line as one flat ribbon mesh on the ground.
    static func lines(_ lots: [CityLot]) -> Entity {
        let b = Builder()
        let up = SIMD3<Float>(0, 1, 0), w: Float = 0.03, y: Float = 0.05
        for lot in lots {
            for r in lot.rings {
                for i in r.indices {
                    let a = r[i], c = r[(i + 1) % r.count]
                    let len = simd_distance(a, c)
                    guard len > 0.05 else { continue }
                    let u = (c - a) / len, s = SIMD2<Float>(-u.y, u.x) * w
                    let p0 = p3(a - s, y), p1 = p3(a + s, y), p2 = p3(c + s, y), q = p3(c - s, y)
                    b.tri(p0, p1, p2, up)
                    b.tri(p0, p2, q, up)
                }
            }
        }
        var m = UnlitMaterial(color: .white)
        m.blending = .transparent(opacity: .init(floatLiteral: 0.55))
        guard let mesh = b.mesh("lot-lines") else { return Entity() }
        return ModelEntity(mesh: mesh, materials: [m])
    }

    /// Toronto zoning-map colours, roughly: residential yellow, mixed-use red, employment purple,
    /// institutional blue, open space green, utility grey.
    static func colour(_ zone: String) -> UIColor {
        let z = zone.uppercased()
        if z == "EXCLUDED" { return UIColor(red: 1.0, green: 0.25, blue: 0.85, alpha: 1) }   // outside 569-2013: magenta
        if z.hasPrefix("CR") || z == "CL" { return UIColor(red: 1.0, green: 0.30, blue: 0.35, alpha: 1) }
        if z.hasPrefix("R") { return UIColor(red: 1.0, green: 0.80, blue: 0.15, alpha: 1) }
        if z.hasPrefix("E") { return UIColor(red: 0.70, green: 0.40, blue: 1.0, alpha: 1) }
        if z.hasPrefix("I") { return UIColor(red: 0.30, green: 0.60, blue: 1.0, alpha: 1) }
        if z.hasPrefix("O") { return UIColor(red: 0.30, green: 0.85, blue: 0.40, alpha: 1) }
        if z.hasPrefix("U") { return UIColor(white: 0.7, alpha: 1) }
        return UIColor(white: 1.0, alpha: 1)
    }

    /// The pointed-at lot: the zoning height box (or a flat plate when there is no height overlay),
    /// its edges, and a label. Returns the root and the label (which faces the viewer each frame).
    static func highlight(_ lot: CityLot) -> (Entity, Entity) {
        let root = Entity()
        let colour = colour(lot.zone)
        let h = max(lot.height ?? 0, 0.06)
        for r in lot.rings {
            if let mesh = prism(r, height: h) {
                let group = ModelSortGroup(depthPass: nil)
                for (order, cull) in [(Int32(0), PhysicallyBasedMaterial.FaceCulling.front), (1, .back)] {
                    var m = PhysicallyBasedMaterial()
                    m.baseColor = .init(tint: colour)
                    m.emissiveColor = .init(color: colour)
                    m.emissiveIntensity = 0.4
                    m.blending = .transparent(opacity: .init(floatLiteral: 0.25))
                    m.faceCulling = cull
                    let e = ModelEntity(mesh: mesh, materials: [m])
                    e.components.set(ModelSortGroupComponent(group: group, order: order))
                    root.addChild(e)
                }
            }
            var edge = UnlitMaterial(color: colour)
            edge.blending = .transparent(opacity: .init(floatLiteral: 0.9))
            for i in r.indices {
                let a = p3(r[i], 0.06), b = p3(r[(i + 1) % r.count], 0.06)
                root.addChild(SiteModel.bar(a, b, 0.06, edge))
                if lot.height != nil {
                    root.addChild(SiteModel.bar(a + [0, h - 0.06, 0], b + [0, h - 0.06, 0], 0.04, edge))
                    if r.count <= 24 { root.addChild(SiteModel.bar(a, a + [0, h - 0.06, 0], 0.03, edge)) }
                }
            }
        }
        let label = makeLabel(lot.lines)
        label.position = p3(lot.point, max(lot.height ?? 0, 3) + 1.2)
        root.addChild(label)
        return (root, label)
    }

    /// Text lines on a dark card, facing +z; the caller turns it toward the viewer.
    static func makeLabel(_ lines: [String]) -> Entity {
        let root = Entity()
        let white = UnlitMaterial(color: .white)
        var y: Float = 0
        var width: Float = 0
        var parts: [(ModelEntity, Float)] = []
        for (i, line) in lines.enumerated() {
            let size: CGFloat = i == 0 ? 0.42 : 0.30
            let mesh = MeshResource.generateText(line, extrusionDepth: 0.005,
                                                 font: .systemFont(ofSize: size, weight: i == 0 ? .bold : .regular),
                                                 containerFrame: .zero, alignment: .center, lineBreakMode: .byTruncatingTail)
            let e = ModelEntity(mesh: mesh, materials: [white])
            let bb = mesh.bounds
            width = max(width, bb.extents.x)
            y -= Float(size) * 1.25
            parts.append((e, y))
            e.position = SIMD3(-bb.center.x, y - bb.center.y, 0.01)
            root.addChild(e)
        }
        for (e, _) in parts { e.position.y -= y / 2 }
        var card = UnlitMaterial(color: .black)
        card.blending = .transparent(opacity: .init(floatLiteral: 0.55))
        let back = ModelEntity(mesh: .generatePlane(width: width + 0.4, height: -y + 0.3), materials: [card])
        root.addChild(back)
        return root
    }

    /// A closed prism over the ring, 0...h, with proper caps for concave lots.
    static func prism(_ ring: [SIMD2<Float>], height h: Float) -> MeshResource? {
        let r = Geo.clean(ring)
        guard r.count >= 3 else { return nil }
        let b = Builder()
        let ccw = Geo.signedArea(r) > 0
        for i in r.indices {
            let a = r[i], c = r[(i + 1) % r.count]
            let e = c - a
            guard simd_length(e) > 1e-4 else { continue }
            let out2 = simd_normalize(ccw ? SIMD2(e.y, -e.x) : SIMD2(-e.y, e.x))
            let n = SIMD3<Float>(out2.x, 0, -out2.y)
            b.tri(p3(a, 0), p3(c, 0), p3(c, h), n)
            b.tri(p3(a, 0), p3(c, h), p3(a, h), n)
        }
        let t = Geo.triangulate(r)
        var i = 0
        while i + 2 < t.count {
            let a = r[t[i]], c = r[t[i + 1]], d = r[t[i + 2]]
            b.tri(p3(a, h), p3(c, h), p3(d, h), SIMD3(0, 1, 0))
            b.tri(p3(a, 0), p3(c, 0), p3(d, 0), SIMD3(0, -1, 0))
            i += 3
        }
        return b.mesh("lot")
    }
}

/// Loads the lots around the phone, places them by Apple location anchors (or GPS + compass),
/// and highlights whichever lot the phone is pointing at.
final class CityLayer: NSObject, CLLocationManagerDelegate {
    weak var arView: ARView?
    var onStatus: ((String) -> Void)?
    var onPoint: ((String) -> Void)?
    /// The placement badge: text and level (0 waiting, 1 localizing, 2 localized, 3 approximate, 4 failed).
    var onBadge: ((String, Int) -> Void)?
    let radius: Double = 100
    static let reach: Float = 150
    static let phoneHeight: Float = 1.4
    var linesVisible = true {
        didSet { if linesVisible != oldValue { lines?.isEnabled = linesVisible } }
    }

    private let location = CLLocationManager()
    private var running = false
    private var mode = ""          // "geo" or "compass", once known
    private var placeText = ""
    /// Apple location anchors say "localized". Until then the lots sit where GPS guessed, metres off,
    /// so nothing is picked (David, 2026-11-28: the porch picked the neighbours before localizing).
    private(set) var localized = false
    private var countText = ""
    private var origin: CLLocationCoordinate2D?
    private var bestFix: CLLocation?
    private var compassAccuracy = Double.infinity
    private var lots: [CityLot] = []
    private var anchor: AnchorEntity?
    private var geoAnchor: ARGeoAnchor?
    private var root: Entity?
    private var lines: Entity?
    private var highlight: Entity?
    private var label: Entity?
    private var pointed: Int?
    private var pointedT: Float = 0
    private var fetching = false
    private var failedAt: CFTimeInterval = -100
    private var generation = 0
    private var lastTick: CFTimeInterval = 0
    private var lastPointText: CFTimeInterval = 0

    func start() {
        guard let arView, !running else { return }
        running = true
        generation += 1
        mode = ""; placeText = "checking Apple location anchors…"; countText = "waiting for GPS"
        localized = false
        badge("WAITING FOR GPS", 0)
        lots = []; origin = nil; bestFix = nil; pointed = nil
        arView.environment.sceneUnderstanding.options.remove(.occlusion)
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.requestWhenInUseAuthorization()
        location.startUpdatingLocation()
        refreshStatus()
        onPoint?("nothing yet")
        guard ARGeoTrackingConfiguration.isSupported else { startCompass("no geo tracking on this phone"); return }
        ARGeoTrackingConfiguration.checkAvailability { available, _ in
            DispatchQueue.main.async {
                guard self.running else { return }
                if available { self.startGeo() } else { self.startCompass("Apple has no location anchors here") }
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        generation += 1
        fetching = false
        location.stopUpdatingLocation()
        removeAnchor()
        lots = []
        mode = ""
    }

    /// Load again around where the phone is now.
    func reload() {
        guard running, !fetching, let fix = bestFix else { return }
        fetch(around: fix.coordinate)
    }

    private func status(_ s: String) { DispatchQueue.main.async { self.onStatus?(s) } }

    private var lastBadge = ""
    private func badge(_ text: String, _ level: Int) {
        guard text != lastBadge else { return }
        lastBadge = text
        DispatchQueue.main.async { self.onBadge?(text, level) }
    }

    private func refreshStatus() { status("Toronto · \(placeText) · \(countText)") }

    private func startGeo() {
        guard let arView else { return }
        mode = "geo"
        let config = ARGeoTrackingConfiguration()
        config.planeDetection = [.horizontal]
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        placeText = "Apple anchor, initializing…"
        badge("LOCALIZING… point at the buildings", 1)
        refreshStatus()
        placeAnchor()
    }

    private func startCompass(_ reason: String) {
        guard let arView else { return }
        mode = "compass"
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.worldAlignment = .gravityAndHeading
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        placeText = "GPS + compass (\(reason))"
        badge("APPROXIMATE · GPS + compass", 3)
        refreshStatus()
        placeAnchor()
    }

    func geoTrackingChanged(_ s: ARGeoTrackingStatus) {
        guard running, mode == "geo" else { return }
        let state: String
        switch s.state {
        case .localized: state = "localized ✓"
        case .localizing: state = "localizing… point at the buildings"
        case .initializing: state = "initializing…"
        case .notAvailable: state = "not available"
        @unknown default: state = "?"
        }
        let acc: String
        switch s.accuracy {
        case .high: acc = "high"
        case .medium: acc = "medium"
        case .low: acc = "low"
        default: acc = "—"
        }
        placeText = "Apple anchor \(state) · accuracy \(acc)"
        localized = s.state == .localized
        switch s.state {
        case .localized: badge("LOCALIZED ✓ · accuracy \(acc)", 2)
        case .notAvailable: badge("NO APPLE ANCHORS HERE", 4)
        default: badge("LOCALIZING… point at the buildings", 1)
        }
        refreshStatus()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard running, let fix = locations.last, fix.horizontalAccuracy > 0 else { return }
        if let best = bestFix, fix.horizontalAccuracy > best.horizontalAccuracy, fix.timestamp.timeIntervalSince(best.timestamp) < 10 {
            // keep the sharper fix from a moment ago
        } else {
            bestFix = fix
        }
        let now = CACurrentMediaTime()
        if !fetching, fix.horizontalAccuracy <= 30, now - failedAt > 10 {
            if origin == nil {
                fetch(around: fix.coordinate)
            } else if let o = origin,
                      CLLocation(latitude: o.latitude, longitude: o.longitude).distance(from: fix) > radius * 0.6 {
                fetch(around: fix.coordinate)   // walked toward the edge of what's loaded
            }
        }
        if origin == nil && !fetching {
            countText = "waiting for GPS (±\(Int(fix.horizontalAccuracy)) m)"
            refreshStatus()
        }
        if mode == "compass" { compassPlace(fix) }
    }

    private func fetch(around c: CLLocationCoordinate2D) {
        fetching = true
        let gen = generation
        countText = "loading lots and zoning within \(Int(radius)) m…"
        refreshStatus()
        let r = radius
        Task {
            do {
                let lots = try await CityData.load(around: c, radius: r)
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }
                    self.fetching = false
                    self.install(lots, origin: c)
                }
            } catch {
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }
                    self.fetching = false
                    self.failedAt = CACurrentMediaTime()
                    self.countText = "couldn't load the City's map (\(error.localizedDescription)), retrying"
                    self.refreshStatus()
                }
            }
        }
    }

    private func install(_ lots: [CityLot], origin c: CLLocationCoordinate2D) {
        self.lots = lots
        origin = c
        let zoned = lots.filter { $0.height != nil }.count
        countText = "\(lots.count) lots within \(Int(radius)) m (\(zoned) with a height)"
        refreshStatus()
        placeAnchor()
    }

    private func removeAnchor() {
        if let anchor { arView?.scene.removeAnchor(anchor) }
        if let geoAnchor { arView?.session.remove(anchor: geoAnchor) }
        anchor = nil; geoAnchor = nil; root = nil; lines = nil; highlight = nil; label = nil; pointed = nil
    }

    /// Builds the lot lines under a fresh anchor at the load origin, once both the data and the tracking mode are ready.
    private func placeAnchor() {
        guard let arView, let origin, !lots.isEmpty, !mode.isEmpty else { return }
        removeAnchor()
        let r = Entity()
        let l = CityModel.lines(lots)
        l.isEnabled = linesVisible
        r.addChild(l)
        root = r; lines = l
        if mode == "geo" {
            let ga = ARGeoAnchor(coordinate: origin)
            arView.session.add(anchor: ga)
            let a = AnchorEntity(anchor: ga)
            a.addChild(r)
            arView.scene.addAnchor(a)
            geoAnchor = ga; anchor = a
        } else {
            let a = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
            a.addChild(r)
            arView.scene.addAnchor(a)
            anchor = a
            compassAccuracy = .infinity
            if let f = bestFix { compassPlace(f) }
        }
        onPoint?("aim the phone at a lot")
    }

    /// GPS + compass: put the origin where the best fix so far says it is, relative to the phone.
    private func compassPlace(_ fix: CLLocation) {
        guard let anchor, let origin, let cam = arView?.session.currentFrame?.camera.transform,
              fix.horizontalAccuracy < compassAccuracy * 0.8 else { return }
        compassAccuracy = fix.horizontalAccuracy
        let k = CityData.metresPerDegree(fix.coordinate.latitude)
        let e = Float((origin.longitude - fix.coordinate.longitude) * k.lon)
        let n = Float((origin.latitude - fix.coordinate.latitude) * k.lat)
        let phone = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
        anchor.position = phone + SIMD3<Float>(e, -Self.phoneHeight, -n)
        placeText = "GPS ±\(Int(fix.horizontalAccuracy)) m + compass"
        badge("APPROXIMATE · GPS ±\(Int(fix.horizontalAccuracy)) m + compass", 3)
        refreshStatus()
    }

    /// Each frame: cast the phone's line of sight through the lots and highlight the first one it meets.
    func tick(camera: simd_float4x4) {
        guard running, let anchor, let root, !lots.isEmpty else { return }
        let o = SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let d = -SIMD3<Float>(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
        let lo = anchor.convert(position: o, from: nil)
        let ld = simd_normalize(anchor.convert(direction: d, from: nil))
        if let label {
            let toEye = lo - label.position(relativeTo: anchor)
            label.orientation = simd_quatf(angle: atan2(toEye.x, toEye.z), axis: SIMD3(0, 1, 0))
            label.scale = SIMD3(repeating: max(1, simd_length(toEye) / 15))
        }
        let now = CACurrentMediaTime()
        guard now - lastTick > 0.1 else { return }
        lastTick = now

        if mode == "geo" && !localized {
            if pointed != nil { highlight?.removeFromParent(); highlight = nil; label = nil; pointed = nil }
            if now - lastPointText > 0.5 {
                lastPointText = now
                DispatchQueue.main.async { self.onPoint?("waiting for Apple to localize (point at the buildings)") }
            }
            return
        }
        let o2 = SIMD2<Float>(lo.x, -lo.z), d2 = SIMD2<Float>(ld.x, -ld.z)
        var best: (i: Int, t: Float)?
        for (i, lot) in lots.enumerated() {
            let h = max(lot.height ?? 10, 4)
            if let t = Geo.hit(lot, o: o2, u0: lo.y, d: d2, du: ld.y, h: h, maxT: best?.t ?? Self.reach) {
                best = (i, t)
            }
        }
        if best?.i != pointed {
            pointed = best?.i
            highlight?.removeFromParent(); highlight = nil; label = nil
            if let i = pointed {
                let (h, l) = CityModel.highlight(lots[i])
                root.addChild(h)
                highlight = h; label = l
            }
            lastPointText = 0
        }
        if let b = best { pointedT = b.t }
        if now - lastPointText > 0.5 {
            lastPointText = now
            let text = pointed.map { String(format: "%@ · %.0f m", lots[$0].label, pointedT) } ?? "nothing (aim at a lot within \(Int(Self.reach)) m)"
            DispatchQueue.main.async { self.onPoint?(text) }
        }
    }
}
