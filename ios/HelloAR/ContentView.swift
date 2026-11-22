// ARToronto: STREET and BODY modes.
import SwiftUI
import RealityKit
import ARKit
import Combine
import UniformTypeIdentifiers

final class AppState: ObservableObject {
    enum Mode: String, CaseIterable { case street = "STREET", body = "BODY" }
    enum Pick { case site, avatar, splat }

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
    @Published var liveFPS = 1.0

    @Published var procession = true
    @Published var capturedWalk = true
    @Published var procCount = 5
    @Published var procSpacing: Float = 1.5
    @Published var procSpeed: Float = 0.9
    @Published var walkText = "none (GO, walk, STOP with a site loaded)"
    @Published var occlusion = ""
    var avatarModel: AvatarModel?
    var avatarVersion = 0
    var walkPoints: [SIMD3<Float>] = []

    struct Loupe {
        let image: CGImage
        let scale: CGFloat
        let tap: CGPoint
        let origin: SIMD3<Float>
        let d0: SIMD3<Float>
        let dx: SIMD3<Float>
        let dy: SIMD3<Float>
    }
    @Published var loupe: Loupe?
    @Published var loupeOffset = CGSize.zero

    let placer = SitePlacer()
    let figure = BlockFigure()
    let walker = Walker()
    let look = LookClient()
    let splat = SplatProbe()
    @Published var splatText = ""
    @Published var splatVisible = true
    let dragon = Dragon()
    @Published var dragonMode = Dragon.Mode.auto
    @Published var dragonText = ""
    var fireRequests = 0
    weak var arView: ARView?
    var siteFile: SiteFile?
    var forgetWalk = false
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
                LookBar(look: state.look, app: "artoronto", fps: state.liveFPS, info: lookInfo) { done in
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

            if let loupe = state.loupe {
                LoupeView(loupe: loupe, offset: $state.loupeOffset) { set in
                    if set {
                        let o = state.loupeOffset
                        let d = loupe.d0 + loupe.dx * Float(o.width) + loupe.dy * Float(o.height)
                        state.placer.nudgeTap(origin: loupe.origin, direction: simd_normalize(d))
                    }
                    state.loupe = nil
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 70)
            }
        }
        .fileImporter(isPresented: $state.picking, allowedContentTypes: [.json, .data, .item]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let saved = state.pick == .site ? Self.savedSite : (state.pick == .avatar ? Self.savedAvatar : Self.savedSplat)
            try? FileManager.default.removeItem(at: saved)
            let from = (try? FileManager.default.copyItem(at: url, to: saved)) != nil ? saved : url
            switch state.pick {
            case .site: loadSite(from: from)
            case .avatar: loadAvatar(from: from, label: url.lastPathComponent)
            case .splat: state.splat.load(url: from, label: url.lastPathComponent)
            }
        }
        .onAppear {
            let fm = FileManager.default
            if fm.fileExists(atPath: Self.savedAvatar.path) { loadAvatar(from: Self.savedAvatar, label: "last avatar") }
            if fm.fileExists(atPath: Self.savedSite.path) { loadSite(from: Self.savedSite) }
            if fm.fileExists(atPath: Self.savedSplat.path) { state.splat.load(url: Self.savedSplat, label: "last splat") }
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
            HStack(spacing: 8) {
                button("🐉 \(state.dragonMode.rawValue)", state.dragonMode == .off ? .gray : .orange) {
                    let all = Dragon.Mode.allCases
                    state.dragonMode = all[(all.firstIndex(of: state.dragonMode)! + 1) % all.count]
                }
                button("🔥 FIRE", .red) { state.fireRequests += 1 }
            }
        }
    }

    private var menu: some View {
        Menu {
            Picker("Mode", selection: $state.mode) {
                ForEach(AppState.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Divider()
            Picker("Dragon", selection: $state.dragonMode) {
                ForEach(Dragon.Mode.allCases, id: \.self) { Text("Dragon \($0.rawValue)").tag($0) }
            }
            Toggle("Figure follows me", isOn: $state.follower)
            Toggle("Wear avatar", isOn: $state.wear)
            Toggle("Heart", isOn: $state.heart)
            Toggle("Procession", isOn: $state.procession)
            Toggle("Captured walk (CMU)", isOn: $state.capturedWalk)
            Picker("Figures", selection: $state.procCount) {
                ForEach([1, 3, 5, 8], id: \.self) { Text("\($0) figures").tag($0) }
            }
            Picker("Spacing", selection: $state.procSpacing) {
                ForEach([Float(1.0), 1.5, 2.0, 3.0], id: \.self) { Text(String(format: "%.1f m apart", $0)).tag($0) }
            }
            Picker("Speed", selection: $state.procSpeed) {
                ForEach([Float(0.6), 0.9, 1.2], id: \.self) { Text(String(format: "%.1f m/s", $0)).tag($0) }
            }
            Button("Forget saved walk") { state.walkPoints = []; state.walkText = "cleared"; state.clearRequests += 1; state.forgetWalk = true }
            Picker("LIVE frames", selection: $state.liveFPS) {
                Text("LIVE 0.5 / s").tag(0.5)
                Text("LIVE 1 / s").tag(1.0)
                Text("LIVE 2 / s").tag(2.0)
            }
            Divider()
            Button("Load site…") { state.pick = .site; state.picking = true }
            Button("Load avatar…") { state.pick = .avatar; state.picking = true }
            Button("Load splat…") { state.pick = .splat; state.picking = true }
            Button("Place splat here") { state.splat.replace() }
            Toggle("Splat visible", isOn: $state.splatVisible)
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
                Text("walk: \(state.walkText)")
                if !state.occlusion.isEmpty { Text("occlusion: \(state.occlusion)") }
            } else {
                Text(ARBodyTrackingConfiguration.isSupported ? "body: \(state.body)" : "body tracking not supported on this phone")
            }
            if !state.dragonText.isEmpty { Text("dragon: \(state.dragonText)") }
            Text("avatar: \(state.avatar)")
            if !state.splatText.isEmpty { Text("splat: \(state.splatText)") }
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
         "walk": state.walkText, "occlusion": state.occlusion, "splat": state.splatText,
         "dragon": "\(state.dragonMode.rawValue) · \(state.dragonText)",
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
    private static var savedSplat: URL { documents.appendingPathComponent("probe.splat") }

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
            state.avatarModel = model
            state.avatarVersion += 1
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
        arView.scene.addAnchor(state.dragon.root)
        if let a = state.figure.root as? AnchorEntity { arView.scene.addAnchor(a) }

        state.placer.onStatus = { text in DispatchQueue.main.async { state.site = text } }
        state.placer.onRestart = { state.trailing = false; state.clearRequests += 1 }
        state.placer.onAnchor = { anchor in
            c.procession.root.removeFromParent()
            anchor.addChild(c.procession.root)
            c.loadWalk()
        }
        state.placer.onOcclusion = { text in DispatchQueue.main.async { state.occlusion = text } }
        state.splat.arView = arView
        state.splat.onStatus = { text in DispatchQueue.main.async { state.splatText = text } }
        arView.renderCallbacks.postProcess = { ctx in state.splat.postProcess(ctx) }
        state.placer.arView = arView
        state.placer.onNudged = { [weak arView] in
            arView?.snapshot(saveToHDR: false) { image in
                state.look.send(kind: "look", app: "artoronto", note: "auto: nudge result",
                                info: ["mode": state.mode.rawValue, "site": state.site, "build": BuildInfo.label],
                                image: image, maxWidth: 1290)
            }
        }

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
        let procession = Procession()
        private var builtCount = -1
        private var builtVersion = -1
        private var lastWalkPoint: SIMD3<Float>?
        private var mode: AppState.Mode?
        private var time: Double = 0
        private var lastDrop: SIMD3<Float>?
        private var handledClears = 0
        private var wasTrailing = false
        private var lastHud: CFTimeInterval = 0
        private var handledFire = 0
        private var floorCache: (y: Float, at: Double) = (0, -1)
        private var bodyLeader: (floor: SIMD3<Float>, head: SIMD3<Float>, at: Double)?
        private var lastDragonText = ""
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
            state.dragon.reset()
            bodyLeader = nil
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
            updateDragon(dt: Float(dt))
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
                finishWalk()
            } else if !wasTrailing && state.trailing {
                state.walkPoints = []
                lastWalkPoint = nil
                caterpillar.stopCrawling()
                state.crawling = false
                lastDrop = caterpillar.path.last
            }
            wasTrailing = state.trailing

            let c = frame.camera.transform.columns.3
            let cam = SIMD3<Float>(c.x, c.y, c.z)
            if case .normal = frame.camera.trackingState {
                walker.record(floor: SIMD3(cam.x, cam.y - Self.phoneHeight, cam.z))
                if state.trailing { recordWalk(camera: cam, frame: frame) }
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
            updateProcession(dt: Float(dt))
            state.placer.nudgeTick(camera: cam)
            state.splat.visible = state.splatVisible
            if state.splat.needsPlacement { placeSplat(camera: cam) }

            if state.follower, let pose = walker.step(dt: Float(dt), camera: cam) {
                figure.update(walker: pose.joints, headMatrix: pose.head)
            } else if !state.follower {
                figure.root.isEnabled = false
            }
        }

        private func updateDragon(dt: Float) {
            let fire = state.fireRequests != handledFire
            handledFire = state.fireRequests
            guard let frame = arView?.session.currentFrame else { return }
            let t = frame.camera.transform
            let cam = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let fwd = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
            var leaderFloor: SIMD3<Float>, leaderHead: SIMD3<Float>, viewer: SIMD3<Float>?
            if mode == .body, let b = bodyLeader, time - b.at < 1.5 {
                leaderFloor = b.floor; leaderHead = b.head; viewer = cam
            } else {
                if time - floorCache.at > 0.3 { floorCache = (floorBelow(cam), time) }
                leaderFloor = SIMD3(cam.x, floorCache.y, cam.z); leaderHead = cam; viewer = nil
            }
            state.dragon.update(dt: dt, mode: state.dragonMode, leaderFloor: leaderFloor, leaderHead: leaderHead,
                                viewer: viewer, camera: cam, cameraForward: fwd, fire: fire)
            let text = state.dragon.status
            if text != lastDragonText {
                lastDragonText = text
                DispatchQueue.main.async { self.state.dragonText = text }
            }
        }

        private var splatAnchor: AnchorEntity?

        private func placeSplat(camera cam: SIMD3<Float>) {
            guard let arView, let frame = arView.session.currentFrame else { return }
            let holder = state.splat.holder
            holder.removeFromParent()
            if let a = splatAnchor { arView.scene.removeAnchor(a); splatAnchor = nil }
            if !state.splat.inFront, let start = procession.start, procession.root.isAnchored {
                procession.root.addChild(holder)
                holder.position = start.point
                holder.orientation = simd_quatf(from: SIMD3(0, 0, -1), to: start.direction)
                state.splat.note("placed at the start of the saved walk")
            } else {
                var fwd = -SIMD3<Float>(frame.camera.transform.columns.2.x, 0, frame.camera.transform.columns.2.z)
                fwd = simd_length(fwd) > 1e-4 ? simd_normalize(fwd) : SIMD3(0, 0, -1)
                var p = cam + fwd * 2.5
                p.y = floorBelow(cam)
                let a = AnchorEntity(world: p)
                arView.scene.addAnchor(a)
                a.addChild(holder)
                holder.orientation = simd_quatf(from: SIMD3(0, 0, -1), to: -fwd)
                splatAnchor = a
                state.splat.note("placed 2.5 m in front of you")
            }
            state.splat.placed()
        }

        private func walkKey() -> String { "walk:" + (state.siteFile?.name ?? "") }

        private func floorBelow(_ cam: SIMD3<Float>) -> Float {
            guard let session = arView?.session else { return cam.y - Self.phoneHeight }
            let q = ARRaycastQuery(origin: cam, direction: SIMD3(0, -1, 0), allowing: .estimatedPlane, alignment: .horizontal)
            if let hit = session.raycast(q).first {
                let y = hit.worldTransform.columns.3.y
                if cam.y - y > 0.4 && cam.y - y < 2.4 { return y }
            }
            return cam.y - Self.phoneHeight
        }

        private func recordWalk(camera cam: SIMD3<Float>, frame: ARFrame) {
            guard state.siteFile != nil else { return }
            let floor = SIMD3<Float>(cam.x, floorBelow(cam), cam.z)
            if let last = lastWalkPoint, simd_distance(last, floor) < 0.1 { return }
            lastWalkPoint = floor
            if let local = state.placer.toSite(floor) { state.walkPoints.append(local) }
            state.walkText = String(format: "recording · %d points", state.walkPoints.count)
        }

        private func finishWalk() {
            guard state.siteFile != nil, state.walkPoints.count >= 10 else { return }
            procession.setPath(state.walkPoints)
            let flat = state.walkPoints.flatMap { [Double($0.x), Double($0.y), Double($0.z)] }
            UserDefaults.standard.set(flat, forKey: walkKey())
            state.walkText = String(format: "%.1f m saved to the site", procession.length)
        }

        func loadWalk() {
            let flat = UserDefaults.standard.array(forKey: walkKey()) as? [Double] ?? []
            guard flat.count >= 30 else { return }
            var pts: [SIMD3<Float>] = []
            var i = 0
            while i + 2 < flat.count { pts.append(SIMD3(Float(flat[i]), Float(flat[i + 1]), Float(flat[i + 2]))); i += 3 }
            state.walkPoints = pts
            procession.setPath(pts)
            DispatchQueue.main.async {
                self.state.walkText = String(format: "%.1f m, restored from last time", self.procession.length)
            }
        }

        private func updateProcession(dt: Float) {
            if state.forgetWalk {
                state.forgetWalk = false
                UserDefaults.standard.removeObject(forKey: walkKey())
                procession.clear()
            }
            procession.root.isEnabled = state.procession
            guard state.procession else { return }
            if builtCount != state.procCount || builtVersion != state.avatarVersion {
                procession.count = state.procCount
                procession.rebuild(model: state.avatarModel)
                builtCount = state.procCount
                builtVersion = state.avatarVersion
            }
            procession.gait.captured = state.capturedWalk
            walker.captured = state.capturedWalk
            procession.spacing = state.procSpacing
            procession.speed = state.procSpeed
            procession.update(dt: dt, wear: state.wear)
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
            if body.isTracked {
                var feet: [Float] = []
                for name in ["left_toes_joint", "right_toes_joint", "left_foot_joint", "right_foot_joint"] {
                    if let m = body.skeleton.modelTransform(for: ARSkeleton.JointName(rawValue: name)) {
                        feet.append((body.transform * m).columns.3.y)
                    }
                }
                let hips = body.transform.columns.3
                var head = SIMD3<Float>(hips.x, hips.y + 0.6, hips.z)
                if let m = body.skeleton.modelTransform(for: .head) {
                    let w = (body.transform * m).columns.3
                    head = SIMD3(w.x, w.y, w.z)
                }
                let floorY = (feet.min() ?? hips.y - 0.9) - 0.03
                bodyLeader = (SIMD3(hips.x, floorY, hips.z), head, time)
            }

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
                let p = gesture.location(in: arView)
                guard let r0 = arView.ray(through: p),
                      let rx = arView.ray(through: CGPoint(x: p.x + 1, y: p.y)),
                      let ry = arView.ray(through: CGPoint(x: p.x, y: p.y + 1)) else { return }
                let d0 = simd_normalize(r0.direction)
                let dx = simd_normalize(rx.direction) - d0
                let dy = simd_normalize(ry.direction) - d0
                arView.snapshot(saveToHDR: false) { image in
                    guard let image, let cg = image.cgImage else {
                        self.state.placer.nudgeTap(origin: r0.origin, direction: d0)
                        return
                    }
                    self.state.loupeOffset = .zero
                    self.state.loupe = AppState.Loupe(image: cg, scale: CGFloat(cg.width) / max(arView.bounds.width, 1), tap: p,
                                                      origin: r0.origin, d0: d0, dx: dx, dy: dy)
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

struct LoupeView: View {
    let loupe: AppState.Loupe
    @Binding var offset: CGSize
    let done: (Bool) -> Void
    @State private var base = CGSize.zero
    private let span: CGFloat = 80
    private let zoom: CGFloat = 3

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if let crop = crop() {
                    Image(decorative: crop, scale: loupe.scale)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: span * zoom, height: span * zoom)
                }
                Rectangle().fill(Color.yellow).frame(width: 1.5, height: 34)
                Rectangle().fill(Color.yellow).frame(width: 34, height: 1.5)
            }
            .frame(width: span * zoom, height: span * zoom)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yellow, lineWidth: 2))
            .gesture(DragGesture()
                .onChanged { g in
                    offset = CGSize(width: base.width - g.translation.width / zoom,
                                    height: base.height - g.translation.height / zoom)
                }
                .onEnded { _ in base = offset })
            Text("drag to put the cross on the peak").font(.system(size: 11)).foregroundStyle(.white)
            HStack(spacing: 10) {
                Button { done(false) } label: {
                    Text("CANCEL").font(.system(size: 13, weight: .bold, design: .rounded))
                        .frame(width: 100, height: 36).foregroundStyle(.white)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                }
                Button { done(true) } label: {
                    Text("SET").font(.system(size: 14, weight: .heavy, design: .rounded))
                        .frame(width: 100, height: 36).foregroundStyle(.black)
                        .background(Color.yellow, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(10)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
        .onAppear { base = offset }
    }

    private func crop() -> CGImage? {
        let s = loupe.scale
        let cx = (loupe.tap.x + offset.width) * s, cy = (loupe.tap.y + offset.height) * s
        let half = span * s / 2
        let r = CGRect(x: cx - half, y: cy - half, width: half * 2, height: half * 2)
            .intersection(CGRect(x: 0, y: 0, width: loupe.image.width, height: loupe.image.height))
        return r.isEmpty ? nil : loupe.image.cropping(to: r.integral)
    }
}
