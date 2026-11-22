// Site overlay from a JSON file, placed by location anchors or GPS + compass; NUDGE.
import Foundation
import RealityKit
import ARKit
import CoreLocation
import UIKit

struct SiteFile: Decodable {
    struct Benchmark: Decodable {
        let name: String
        let lat: Double
        let lon: Double
        let height_m: Double
    }
    let name: String
    let height_m: Double
    let color: [Double]?
    let opacity: Double?
    let lot: [[Double]]?
    let envelope: [[Double]]
    let benchmark: Benchmark?

    var centre: CLLocationCoordinate2D {
        let pts = envelope
        return CLLocationCoordinate2D(latitude: pts.map { $0[0] }.reduce(0, +) / Double(pts.count),
                                      longitude: pts.map { $0[1] }.reduce(0, +) / Double(pts.count))
    }

    static func en(_ p: [Double], from origin: CLLocationCoordinate2D) -> SIMD2<Float> {
        let k = 111_320 * cos(origin.latitude * .pi / 180)
        return SIMD2(Float((p[1] - origin.longitude) * k), Float((p[0] - origin.latitude) * 110_574))
    }
}

enum SiteModel {
    static func make(_ site: SiteFile) -> Entity {
        let root = Entity()
        let c = site.centre
        let rgb = site.color ?? [1, 0, 0]
        let colour = UIColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
        let opacity = Float(site.opacity ?? 0.2)

        let ring = site.envelope.map { SiteFile.en($0, from: c) }.map { SIMD3<Float>($0.x, 0, -$0.y) }
        let h = Float(site.height_m)
        if let mesh = prism(ring, height: h) {
            let group = ModelSortGroup(depthPass: nil)
            for (order, cull) in [(Int32(0), PhysicallyBasedMaterial.FaceCulling.front), (1, .back)] {
                var m = PhysicallyBasedMaterial()
                m.baseColor = .init(tint: colour)
                m.emissiveColor = .init(color: colour)
                m.emissiveIntensity = 0.4
                m.blending = .transparent(opacity: .init(floatLiteral: opacity))
                m.faceCulling = cull
                let e = ModelEntity(mesh: mesh, materials: [m])
                e.components.set(ModelSortGroupComponent(group: group, order: order))
                root.addChild(e)
            }
        }
        var edgeMat = UnlitMaterial(color: colour)
        edgeMat.blending = .transparent(opacity: .init(floatLiteral: 0.9))
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            root.addChild(bar(a, b, 0.04, edgeMat))
            root.addChild(bar(a + [0, h, 0], b + [0, h, 0], 0.04, edgeMat))
            root.addChild(bar(a, a + [0, h, 0], 0.04, edgeMat))
        }
        if let b = site.benchmark {
            let p = benchmarkPosition(site, b)
            let yellow = UnlitMaterial(color: .yellow)
            let ball = ModelEntity(mesh: .generateSphere(radius: 0.12), materials: [yellow])
            ball.position = p
            root.addChild(ball)
            root.addChild(bar(SIMD3(p.x, 0, p.z), p, 0.02, yellow))
        }
        if let lot = site.lot {
            let lr = lot.map { SiteFile.en($0, from: c) }.map { SIMD3<Float>($0.x, 0.02, -$0.y) }
            let white = UnlitMaterial(color: .white)
            for i in lr.indices { root.addChild(bar(lr[i], lr[(i + 1) % lr.count], 0.05, white)) }
        }
        return root
    }

    static func benchmarkPosition(_ site: SiteFile, _ b: SiteFile.Benchmark) -> SIMD3<Float> {
        let e = SiteFile.en([b.lat, b.lon], from: site.centre)
        return SIMD3(e.x, Float(b.height_m), -e.y)
    }

    private static func bar(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float, _ m: RealityKit.Material) -> ModelEntity {
        let d = b - a, len = max(simd_length(d), 0.001)
        let e = ModelEntity(mesh: .generateBox(size: 1), materials: [m])
        e.transform = Transform(scale: SIMD3(t, len, t),
                                rotation: simd_quatf(from: SIMD3(0, 1, 0), to: d / len),
                                translation: (a + b) / 2)
        return e
    }

    private static func prism(_ ring: [SIMD3<Float>], height h: Float) -> MeshResource? {
        guard ring.count >= 3 else { return nil }
        let centre = ring.reduce(SIMD3<Float>(0, 0, 0), +) / Float(ring.count) + SIMD3(0, h / 2, 0)
        var pos: [SIMD3<Float>] = [], nor: [SIMD3<Float>] = [], idx: [UInt32] = []
        func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            var n = simd_cross(b - a, c - a)
            var (p, q) = (b, c)
            if simd_dot(n, (a + b + c) / 3 - centre) < 0 { n = -n; (p, q) = (c, b) }
            n = simd_normalize(n)
            let base = UInt32(pos.count)
            pos += [a, p, q]; nor += [n, n, n]; idx += [base, base + 1, base + 2]
        }
        let up = SIMD3<Float>(0, h, 0)
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            tri(a, b, b + up); tri(a, b + up, a + up)
        }
        for i in 1..<(ring.count - 1) {
            tri(ring[0] + up, ring[i] + up, ring[i + 1] + up)
            tri(ring[0], ring[i], ring[i + 1])
        }
        var d = MeshDescriptor(name: "envelope")
        d.positions = MeshBuffers.Positions(pos)
        d.normals = MeshBuffers.Normals(nor)
        d.primitives = .triangles(idx)
        return try? MeshResource.generate(from: [d])
    }
}

final class SitePlacer: NSObject, CLLocationManagerDelegate {
    weak var arView: ARView? {
        didSet { if arView != nil, let s = pending { pending = nil; load(s) } }
    }
    private var pending: SiteFile?
    var onStatus: ((String) -> Void)?
    var onRestart: (() -> Void)?
    var onNudged: (() -> Void)?

    private var site: SiteFile?
    private var model: Entity?
    private var anchor: AnchorEntity?
    private var geoAnchor: ARGeoAnchor?
    private let location = CLLocationManager()
    private var mode = ""
    private var bestAccuracy: Double = .infinity

    private(set) var offset = SIMD3<Float>(0, 0, 0)
    private var rays: [(SIMD3<Float>, SIMD3<Float>)] = []
    private(set) var nudging = false
    private var sightLine: AnchorEntity?
    private var lastAngleText: CFTimeInterval = 0

    private func clearSightLine() {
        if let sightLine { arView?.scene.removeAnchor(sightLine) }
        sightLine = nil
    }

    private func showSightLine(from o: SIMD3<Float>, along d: SIMD3<Float>) {
        clearSightLine()
        let a = AnchorEntity(world: o)
        let len: Float = 40
        let line = ModelEntity(mesh: .generateBox(size: 1), materials: [UnlitMaterial(color: .yellow)])
        line.transform = Transform(scale: SIMD3(0.012, len, 0.012),
                                   rotation: simd_quatf(from: SIMD3(0, 1, 0), to: d),
                                   translation: d * (len / 2 + 0.3))
        a.addChild(line)
        arView?.scene.addAnchor(a)
        sightLine = a
    }

    func nudgeTick(camera: SIMD3<Float>) {
        guard nudging, rays.count == 1, let site, let b = site.benchmark, let anchor else { return }
        let now = CACurrentMediaTime()
        guard now - lastAngleText > 0.25 else { return }
        lastAngleText = now
        let (o1, d1) = rays[0]
        let guess = anchor.convert(position: SiteModel.benchmarkPosition(site, b) + offset, to: nil)
        let target = o1 + d1 * max(simd_dot(guess - o1, d1), 1)
        let toTarget = target - camera
        guard simd_length(toTarget) > 0.5 else { return }
        let angle = acos(min(1, abs(simd_dot(d1, simd_normalize(toTarget))))) * 180 / .pi
        let verdict = angle < 3 ? "keep walking along the house" : (angle < 10 ? "ok, more is better" : "good, tap the \(b.name) now")
        onStatus?(String(format: "NUDGE sighting 2 of 2 · angle %.0f° · %@", angle, verdict))
    }

    private var offsetKey: String { "siteOffset:" + (site?.name ?? "") }

    private func loadOffset() {
        let v = UserDefaults.standard.array(forKey: offsetKey) as? [Double] ?? [0, 0]
        offset = SIMD3(Float(v[0]), 0, Float(v.count > 1 ? v[1] : 0))
        model?.position = offset
    }

    func startNudge() {
        guard let site, let b = site.benchmark, anchor != nil else {
            onStatus?("NUDGE needs a placed site with a benchmark"); return
        }
        nudging = true
        rays = []
        clearSightLine()
        onStatus?("NUDGE sighting 1 of 2: tap the real \(b.name) (the yellow ball is where the data puts it)")
    }

    func resetNudge() {
        UserDefaults.standard.removeObject(forKey: offsetKey)
        nudging = false
        rays = []
        clearSightLine()
        loadOffset()
        onStatus?("\(site?.name ?? "site"): nudge cleared")
    }

    func nudgeTap(origin: SIMD3<Float>, direction: SIMD3<Float>) {
        guard nudging, let site, let b = site.benchmark, let anchor else { return }
        rays.append((origin, simd_normalize(direction)))
        guard rays.count == 2 else {
            showSightLine(from: origin, along: simd_normalize(direction))
            onStatus?("NUDGE sighting 1 of 2 ✓ · walk 3-5 m along the house, then tap the SAME \(b.name) again")
            return
        }
        clearSightLine()
        let (o1, d1) = rays[0], (o2, d2) = rays[1]
        rays = []
        let bb = simd_dot(d1, d2)
        let angle = acos(min(1, abs(bb))) * 180 / .pi
        guard angle > 3 else {
            onStatus?(String(format: "NUDGE: the two sight lines are only %.1f° apart; walk further sideways and start again", angle))
            nudging = false
            return
        }
        let w0 = o1 - o2
        let d = simd_dot(d1, w0), e = simd_dot(d2, w0), denom = 1 - bb * bb
        let s = (bb * e - d) / denom, t = (e - bb * d) / denom
        let p1 = o1 + d1 * s, p2 = o2 + d2 * t
        let real = anchor.convert(position: (p1 + p2) / 2, from: nil)
        let walked = simd_distance(o1, o2)
        guard walked >= 1.5 else {
            onStatus?(String(format: "NUDGE: you moved only %.1f m between taps; walk 3-5 m along the house and start again", walked))
            nudging = false
            return
        }
        guard s > 3, t > 3, real.y > 4, real.y < 20 else {
            onStatus?(String(format: "NUDGE: the sight lines meet %.1f m up, %.1f / %.1f m away; that's not the peak, start again", real.y, s, t))
            nudging = false
            return
        }
        let predicted = SiteModel.benchmarkPosition(site, b) + offset
        offset.x += real.x - predicted.x
        offset.z += real.z - predicted.z
        model?.position = offset
        UserDefaults.standard.set([Double(offset.x), Double(offset.z)], forKey: offsetKey)
        nudging = false
        onStatus?(String(format: "%@: nudged %.2f m E, %.2f m N · %@ measured %.1f m up (file says %.1f) · lines %.2f m apart, %.0f°",
                         site.name, offset.x, -offset.z, b.name, real.y, b.height_m, simd_distance(p1, p2), angle))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.onNudged?() }
    }

    static let phoneHeight: Float = 1.4

    func load(_ site: SiteFile) {
        guard arView != nil else { pending = site; return }
        self.site = site
        clear()
        model = SiteModel.make(site)
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.requestWhenInUseAuthorization()
        location.startUpdatingLocation()
        onStatus?("\(site.name): checking Apple location anchors…")

        guard ARGeoTrackingConfiguration.isSupported else { startCompassMode(reason: "no geo tracking on this phone"); return }
        ARGeoTrackingConfiguration.checkAvailability(at: site.centre) { available, _ in
            DispatchQueue.main.async {
                if available { self.startGeoMode() } else { self.startCompassMode(reason: "Apple has no location anchors here") }
            }
        }
    }

    private func clear() {
        if let anchor { arView?.scene.removeAnchor(anchor) }
        if let geoAnchor { arView?.session.remove(anchor: geoAnchor) }
        anchor = nil; geoAnchor = nil; bestAccuracy = .infinity
    }

    private func startGeoMode() {
        guard let arView, let site, let model else { return }
        mode = "geo"
        let config = ARGeoTrackingConfiguration()
        config.planeDetection = [.horizontal]
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        onRestart?()
        let ga = ARGeoAnchor(coordinate: site.centre)
        arView.session.add(anchor: ga)
        let a = AnchorEntity(anchor: ga)
        a.addChild(model)
        loadOffset()
        arView.scene.addAnchor(a)
        geoAnchor = ga; anchor = a
        onStatus?("\(site.name): Apple location anchor, localizing… (point at the buildings)")
    }

    func geoTrackingChanged(_ status: ARGeoTrackingStatus) {
        guard mode == "geo", let site else { return }
        let state: String
        switch status.state {
        case .localized: state = "localized ✓"
        case .localizing: state = "localizing… point at the buildings"
        case .initializing: state = "initializing…"
        case .notAvailable: state = "not available"
        @unknown default: state = "?"
        }
        let acc: String
        switch status.accuracy {
        case .high: acc = "high"
        case .medium: acc = "medium"
        case .low: acc = "low"
        default: acc = "—"
        }
        onStatus?("\(site.name): Apple anchor \(state) · accuracy \(acc)")
    }

    private func startCompassMode(reason: String) {
        guard let arView, let site else { return }
        mode = "compass"
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.worldAlignment = .gravityAndHeading
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        onRestart?()
        onStatus?("\(site.name): GPS + compass (\(reason)), waiting for a fix…")
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard mode == "compass", let site, let model, let arView,
              let fix = locations.last, fix.horizontalAccuracy > 0,
              let cam = arView.session.currentFrame?.camera.transform else { return }
        guard fix.horizontalAccuracy < bestAccuracy * 0.8 else { return }
        bestAccuracy = fix.horizontalAccuracy
        let off = SiteFile.en([site.centre.latitude, site.centre.longitude], from: fix.coordinate)
        let phone = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
        let at = phone + SIMD3<Float>(off.x, -Self.phoneHeight, -off.y)
        if anchor == nil {
            let a = AnchorEntity(world: at)
            a.addChild(model)
            loadOffset()
            arView.scene.addAnchor(a)
            anchor = a
        } else {
            anchor?.position = at
        }
        let dist = Int(simd_length(off).rounded())
        onStatus?("\(site.name): GPS ±\(Int(fix.horizontalAccuracy)) m + compass · \(dist) m away")
    }
}
