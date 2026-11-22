// ARToronto: STREET and BODY modes.
import SwiftUI
import RealityKit
import ARKit
import Combine
import UniformTypeIdentifiers

final class AppState: ObservableObject {
    enum Mode: String, CaseIterable { case street = "STREET", body = "BODY" }
    enum Pick { case site, avatar }

    @Published var mode = Mode.street
    @Published var panelOpen = true

    @Published var tracking = "starting…"
    @Published var trailing = false
    @Published var trailCount = 0
    @Published var lastChakra = ""
    @Published var crawling = false
    @Published var site = "none"
    @Published var follower = true
    @Published var heart = true
    var clearRequests = 0

    @Published var body = "looking for a person…"
    @Published var placement = BlockFigure.Placement.beside
    @Published var size: Float = 1
    @Published var occlude = true

    @Published var avatar = "none"
    @Published var wear = true

    @Published var picking = false
    var pick = Pick.site

    let placer = SitePlacer()
    let figure = BlockFigure()
    let walker = Walker()
    let look = LookClient()
    weak var arView: ARView?
    var siteFile: SiteFile?
}

struct ContentView: View {
    @StateObject private var state = AppState()

    var body: some View {
        ZStack(alignment: .bottom) {
            ARViewContainer(state: state).ignoresSafeArea()

            VStack(alignment: .trailing, spacing: 8) {
                if state.panelOpen {
                    controls
                    hud
                }
                LookBar(look: state.look, app: "artoronto", info: lookInfo) { done in
                    if let v = state.arView { v.snapshot(saveToHDR: false) { done($0) } } else { done(nil) }
                }
                Button { state.panelOpen.toggle() } label: {
                    Image(systemName: state.panelOpen ? "chevron.down" : "slider.horizontal.3")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.45), in: Circle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .fileImporter(isPresented: $state.picking, allowedContentTypes: [.json, .data, .item]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let saved = state.pick == .site ? Self.savedSite : Self.savedAvatar
            try? FileManager.default.removeItem(at: saved)
            let from = (try? FileManager.default.copyItem(at: url, to: saved)) != nil ? saved : url
            if state.pick == .site { loadSite(from: from) } else { loadAvatar(from: from, label: url.lastPathComponent) }
        }
        .onAppear {
            let fm = FileManager.default
            if fm.fileExists(atPath: Self.savedAvatar.path) { loadAvatar(from: Self.savedAvatar, label: "last avatar") }
            if fm.fileExists(atPath: Self.savedSite.path) { loadSite(from: Self.savedSite) }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                menu
                if state.mode == .street {
                    button(state.trailing ? "STOP" : "GO", state.trailing ? .red : .green) { state.trailing.toggle() }
                    button("CLEAR", .gray) {
                        state.trailing = false
                        state.clearRequests += 1
                    }
                } else {
                    button(state.placement.rawValue, .orange) {
                        state.placement = state.placement == .beside ? .on : .beside
                    }
                    button(sizeText, .teal) {
                        state.size = state.size == 1 ? 2 : (state.size == 2 ? 0.5 : 1)
                    }
                }
            }
            HStack(spacing: 8) {
                if state.mode == .street {
                    button("SITE ⇩", .red) { state.pick = .site; state.picking = true }
                    button("NUDGE ✛", .yellow, text: .black) { state.placer.startNudge() }
                    button(state.follower ? "FOLLOW ✓" : "FOLLOW ✗", state.follower ? .pink : .gray) { state.follower.toggle() }
                } else {
                    button(state.occlude ? "OCCLUDE ✓" : "OCCLUDE ✗", state.occlude ? .purple : .gray) { state.occlude.toggle() }
                    button("AVATAR ⇩", .indigo) { state.pick = .avatar; state.picking = true }
                    button(state.wear ? "WEAR ✓" : "WEAR ✗", state.wear ? .pink : .gray) { state.wear.toggle() }
                }
            }
        }
    }

    private var menu: some View {
        Menu {
            Picker("Mode", selection: $state.mode) {
                ForEach(AppState.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Divider()
            Toggle("Figure follows me", isOn: $state.follower)
            Toggle("Wear avatar", isOn: $state.wear)
            Toggle("Heart", isOn: $state.heart)
            Divider()
            Button("Load site…") { state.pick = .site; state.picking = true }
            Button("Load avatar…") { state.pick = .avatar; state.picking = true }
            Button("Reset nudge") { state.placer.resetNudge() }
        } label: {
            Text("☰ \(state.mode.rawValue)")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 36)
                .foregroundStyle(.white)
                .background(Color.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: 2) {
            if state.mode == .street {
                Text("tracking: \(state.tracking)")
                Text("caterpillar: \(state.trailCount) · \(streetText)")
                Text("site: \(state.site)")
            } else {
                Text(ARBodyTrackingConfiguration.isSupported ? "body: \(state.body)" : "body tracking not supported on this phone")
            }
            Text("avatar: \(state.avatar)")
            Text("ARToronto · build \(BuildInfo.label)")
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var streetText: String {
        if state.trailing { return "growing \(state.lastChakra)" }
        if state.crawling { return "crawling" }
        if state.trailCount > 0 { return "resting (8+ to crawl)" }
        return "press GO and walk"
    }

    private var sizeText: String {
        state.size == 2 ? "SIZE 2×" : (state.size == 0.5 ? "SIZE ½×" : "SIZE 1×")
    }

    private func lookInfo() -> [String: String] {
        ["mode": state.mode.rawValue, "tracking": state.tracking, "site": state.site,
         "caterpillar": "\(state.trailCount) · \(streetText)", "follower": "\(state.follower)",
         "body": state.body, "placement": state.placement.rawValue, "size": "\(state.size)",
         "occlude": "\(state.occlude)", "wear": "\(state.wear)", "avatar": state.avatar,
         "build": BuildInfo.label]
    }

    private func button(_ title: String, _ color: Color, text: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 36)
                .foregroundStyle(text)
                .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private static var savedSite: URL { documents.appendingPathComponent("site.json") }
    private static var savedAvatar: URL { documents.appendingPathComponent("avatar.gltf") }

    private func loadSite(from url: URL) {
        do {
            let site = try JSONDecoder().decode(SiteFile.self, from: Data(contentsOf: url))
            state.siteFile = site
            state.site = site.name
            if state.mode == .street { state.placer.load(site) }
        } catch {
            state.site = "couldn't read \(url.lastPathComponent)"
        }
    }

    private func loadAvatar(from url: URL, label: String) {
        do {
            let model = try AvatarModel.load(url: url)
            state.figure.dress(with: model)
            state.walker.useSkeleton(from: model)
            let n = state.figure.wornPartCount
            state.avatar = n > 0 ? "\(label) · \(n) parts" : "\(label): no body parts found"
        } catch {
            state.avatar = "couldn't read \(label)"
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    let state: AppState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        let c = context.coordinator
        c.arView = arView
        state.arView = arView
        arView.session.delegate = c

        let heartAnchor = AnchorEntity(world: SIMD3<Float>(0, 0, -1.5))
        let heart = Coordinator.makeHeart()
        heartAnchor.addChild(heart)
        arView.scene.addAnchor(heartAnchor)
        c.heartAnchor = heartAnchor
        c.heart = heart
        arView.scene.addAnchor(c.caterpillar.root)
        arView.scene.addAnchor(state.figure.root)

        state.placer.onStatus = { text in DispatchQueue.main.async { state.site = text } }
        state.placer.onRestart = { state.trailing = false; state.clearRequests += 1 }
        state.placer.arView = arView

        c.updates = arView.scene.subscribe(to: SceneEvents.Update.self) { event in
            c.update(deltaTime: event.deltaTime)
        }
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tap)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    final class Coordinator: NSObject, ARSessionDelegate {
        let state: AppState
        weak var arView: ARView?
        var heartAnchor: AnchorEntity?
        var heart: Entity?
        var updates: Cancellable?
        let caterpillar = Caterpillar()
        private var mode: AppState.Mode?
        private var time: Double = 0
        private var lastDrop: SIMD3<Float>?
        private var handledClears = 0
        private var wasTrailing = false
        private var lastHud: CFTimeInterval = 0
        private static let phoneHeight: Float = 1.4
        private static let dropBelowPhone: Float = 0.35
        private static let maxSegments = 800

        init(state: AppState) { self.state = state }

        var figure: BlockFigure { state.figure }
        var walker: Walker { state.walker }

        func run(_ m: AppState.Mode) {
            guard let arView else { return }
            mode = m
            figure.reset()
            walker.clear()
            caterpillar.clear()
            lastDrop = nil
            state.trailing = false
            state.trailCount = 0
            state.crawling = false
            switch m {
            case .body:
                guard ARBodyTrackingConfiguration.isSupported else { return }
                let config = ARBodyTrackingConfiguration()
                config.automaticSkeletonScaleEstimationEnabled = true
                arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
                state.body = "looking for a person…"
            case .street:
                if let site = state.siteFile {
                    state.placer.load(site)
                } else {
                    let config = ARWorldTrackingConfiguration()
                    config.planeDetection = [.horizontal]
                    config.worldAlignment = .gravity
                    arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
                }
            }
        }

        func update(deltaTime dt: Double) {
            time += dt
            if mode != state.mode { run(state.mode) }
            figure.wear = state.wear
            heart?.isEnabled = mode == .street && state.heart
            beat()
            guard mode == .street, let frame = arView?.session.currentFrame else { return }

            if state.clearRequests != handledClears {
                handledClears = state.clearRequests
                caterpillar.clear()
                lastDrop = nil
                state.trailCount = 0
                state.lastChakra = ""
                state.crawling = false
            }
            if wasTrailing && !state.trailing {
                caterpillar.startCrawling()
                state.crawling = caterpillar.crawling
            } else if !wasTrailing && state.trailing {
                caterpillar.stopCrawling()
                state.crawling = false
                lastDrop = caterpillar.path.last
            }
            wasTrailing = state.trailing

            let c = frame.camera.transform.columns.3
            let cam = SIMD3<Float>(c.x, c.y, c.z)
            if case .normal = frame.camera.trackingState {
                walker.record(floor: SIMD3(cam.x, cam.y - Self.phoneHeight, cam.z))
                if state.trailing, caterpillar.count < Self.maxSegments {
                    let p = SIMD3<Float>(cam.x, cam.y - Self.dropBelowPhone, cam.z)
                    if lastDrop == nil || simd_distance(lastDrop!, p) >= Caterpillar.spacing {
                        state.lastChakra = caterpillar.grow(at: p)
                        state.trailCount = caterpillar.count
                        lastDrop = p
                    }
                }
            }
            caterpillar.update(time: time, deltaTime: dt)

            if state.follower, let pose = walker.step(dt: Float(dt), camera: cam) {
                figure.update(walker: pose.joints, headMatrix: pose.head)
            } else if !state.follower {
                figure.root.isEnabled = false
            }
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            guard mode == .body, let body = anchors.compactMap({ $0 as? ARBodyAnchor }).first else { return }
            figure.placement = state.placement
            figure.size = state.size
            figure.occlude = state.occlude
            var right = SIMD3<Float>(1, 0, 0)
            var camPos = SIMD3<Float>(0, 0, 0)
            if let cam = session.currentFrame?.camera.transform {
                right = SIMD3<Float>(cam.columns.0.x, cam.columns.0.y, cam.columns.0.z)
                camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
            }
            figure.cameraPosition = camPos
            figure.depthScale = 1
            figure.update(from: body, cameraRight: right)

            let now = CACurrentMediaTime()
            guard now - lastHud > 0.2 else { return }
            lastHud = now
            let hips = SIMD3<Float>(body.transform.columns.3.x, body.transform.columns.3.y, body.transform.columns.3.z)
            let text = body.isTracked
                ? String(format: "tracked · scale %.2f · %.2f m", body.estimatedScaleFactor, simd_distance(hips, camPos))
                : "lost, step back into view"
            DispatchQueue.main.async { self.state.body = text }
        }

        func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
            if mode == .body, anchors.contains(where: { $0 is ARBodyAnchor }) {
                figure.reset()
                DispatchQueue.main.async { self.state.body = "looking for a person…" }
            }
        }

        func session(_ session: ARSession, didChange geoTrackingStatus: ARGeoTrackingStatus) {
            state.placer.geoTrackingChanged(geoTrackingStatus)
        }

        func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
            let text: String
            switch camera.trackingState {
            case .normal: text = "normal"
            case .notAvailable: text = "not available"
            case .limited(let reason):
                switch reason {
                case .initializing: text = "limited (initializing)"
                case .excessiveMotion: text = "limited (moving too fast)"
                case .insufficientFeatures: text = "limited (too few features)"
                case .relocalizing: text = "limited (relocalizing)"
                @unknown default: text = "limited"
                }
            }
            DispatchQueue.main.async { self.state.tracking = text }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let arView, mode == .street else { return }
            if state.placer.nudging {
                if let ray = arView.ray(through: gesture.location(in: arView)) {
                    state.placer.nudgeTap(origin: ray.origin, direction: ray.direction)
                }
                return
            }
            guard let heartAnchor, let camera = arView.session.currentFrame?.camera else { return }
            var offset = matrix_identity_float4x4
            offset.columns.3.z = -1.5
            heartAnchor.transform = Transform(matrix: camera.transform * offset)
            heartAnchor.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        }

        static func makeHeart() -> Entity {
            let heart = Entity()
            let group = ModelSortGroup(depthPass: nil)
            let inner = shell(culling: .front, opacity: 0.30)
            inner.components.set(ModelSortGroupComponent(group: group, order: 0))
            let outer = shell(culling: .back, opacity: 0.40)
            outer.components.set(ModelSortGroupComponent(group: group, order: 1))
            heart.addChild(inner)
            heart.addChild(outer)
            return heart
        }

        private static func shell(culling: PhysicallyBasedMaterial.FaceCulling, opacity: Float) -> ModelEntity {
            var material = PhysicallyBasedMaterial()
            let green = UIColor(red: 0.20, green: 0.85, blue: 0.45, alpha: 1)
            material.baseColor = .init(tint: green)
            material.emissiveColor = .init(color: green)
            material.emissiveIntensity = 0.6
            material.blending = .transparent(opacity: .init(floatLiteral: opacity))
            material.faceCulling = culling
            return ModelEntity(mesh: .generateSphere(radius: 0.5), materials: [material])
        }

        private func beat() {
            let phase = (time * 72.0 / 60).truncatingRemainder(dividingBy: 1)
            let lub = exp(-pow((phase - 0.10) / 0.05, 2))
            let dub = 0.6 * exp(-pow((phase - 0.30) / 0.05, 2))
            heart?.scale = SIMD3<Float>(repeating: Float(1 + 0.08 * (lub + dub)))
        }
    }
}
