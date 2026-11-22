import SwiftUI
import RealityKit
import ARKit
import Combine

// Hello AR, build 5: the caterpillar crawls.
// - The heart: a translucent green sphere (Anahata), 1 m across, 1.5 m ahead,
//   beating at 72 bpm. Two shells (outside + inside) so it renders cleanly
//   from both sides. Tap empty space to re-place it 1.5 m in front of you.
// - The caterpillar: press GO and walk. Every 15 cm a glowing chakra solid
//   grows, root to crown and round again (Chakra.swift). Press STOP and it
//   comes alive: it breathes, then crawls the route you walked and loops home
//   (Caterpillar.swift). GO again snaps it back and keeps growing. CLEAR wipes it.
//
// Positions are relative to where the phone was at launch (ARKit world
// tracking). Nothing reads GPS yet.

final class ARStatus: ObservableObject {
    @Published var tracking = "starting…"
    @Published var trailing = false
    @Published var trailCount = 0
    @Published var lastChakra = ""
    @Published var crawling = false
    var clearRequests = 0
}

struct ContentView: View {
    @StateObject private var status = ARStatus()

    var body: some View {
        ZStack(alignment: .bottom) {
            ARViewContainer(status: status)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    Button {
                        status.trailing.toggle()
                    } label: {
                        Text(status.trailing ? "STOP" : "GO")
                            .font(.system(size: 30, weight: .heavy, design: .rounded))
                            .frame(width: 150, height: 76)
                            .foregroundStyle(.white)
                            .background(status.trailing ? Color.red : Color.green,
                                        in: RoundedRectangle(cornerRadius: 22))
                    }
                    Button {
                        status.trailing = false
                        status.clearRequests += 1
                    } label: {
                        Text("CLEAR")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .frame(width: 96, height: 76)
                            .foregroundStyle(.white)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 22))
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("ARToronto · hello AR").font(.headline)
                    Text("tracking: \(status.tracking)")
                    Text("caterpillar: \(status.trailCount) · \(stateText)")
                    Text("build \(BuildInfo.label)")
                }
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.white)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }

    private var stateText: String {
        if status.trailing { return "growing \(status.lastChakra)" }
        if status.crawling { return "crawling" }
        if status.trailCount > 0 { return "resting (8+ to crawl)" }
        return "press GO and walk"
    }
}

struct ARViewContainer: UIViewRepresentable {
    let status: ARStatus

    func makeCoordinator() -> Coordinator { Coordinator(status: status) }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        let coordinator = context.coordinator
        coordinator.arView = arView

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.worldAlignment = .gravity
        arView.session.delegate = coordinator
        arView.session.run(config)

        let anchor = AnchorEntity(world: SIMD3<Float>(0, 0, -1.5))
        let heart = Coordinator.makeHeart()
        anchor.addChild(heart)
        arView.scene.addAnchor(anchor)
        coordinator.anchor = anchor
        coordinator.heart = heart

        arView.scene.addAnchor(coordinator.caterpillar.root)

        coordinator.updates = arView.scene.subscribe(to: SceneEvents.Update.self) { event in
            coordinator.update(deltaTime: event.deltaTime)
        }

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap))
        arView.addGestureRecognizer(tap)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    final class Coordinator: NSObject, ARSessionDelegate {
        let status: ARStatus
        weak var arView: ARView?
        var anchor: AnchorEntity?
        var heart: Entity?
        var updates: Cancellable?
        let caterpillar = Caterpillar()
        private var time: Double = 0

        private var lastDrop: SIMD3<Float>?
        private var handledClears = 0
        private var wasTrailing = false
        private static let dropBelowPhone: Float = 0.10 // so solids don't sit on the lens
        private static let maxSegments = 800

        init(status: ARStatus) { self.status = status }

        // MARK: heart

        static func makeHeart() -> Entity {
            let heart = Entity()
            let sortGroup = ModelSortGroup(depthPass: nil)
            // Inside shell first (back faces only), then the outside shell (front
            // faces only). Each is convex and one-sided, so neither overlaps itself.
            let inner = shell(culling: .front, opacity: 0.30)
            inner.components.set(ModelSortGroupComponent(group: sortGroup, order: 0))
            let outer = shell(culling: .back, opacity: 0.40)
            outer.components.set(ModelSortGroupComponent(group: sortGroup, order: 1))
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

        // MARK: per-frame

        func update(deltaTime: Double) {
            time += deltaTime
            beat()

            if status.clearRequests != handledClears {
                handledClears = status.clearRequests
                caterpillar.clear()
                lastDrop = nil
                status.trailCount = 0
                status.lastChakra = ""
                status.crawling = false
            }

            // GO -> STOP: it comes alive. STOP -> GO: snap back and keep growing.
            if wasTrailing && !status.trailing {
                caterpillar.startCrawling()
                status.crawling = caterpillar.crawling
            } else if !wasTrailing && status.trailing {
                caterpillar.stopCrawling()
                status.crawling = false
                lastDrop = caterpillar.path.last
            }
            wasTrailing = status.trailing

            if status.trailing, let frame = arView?.session.currentFrame,
               case .normal = frame.camera.trackingState,
               caterpillar.count < Self.maxSegments {
                let c = frame.camera.transform.columns.3
                let p = SIMD3<Float>(c.x, c.y - Self.dropBelowPhone, c.z)
                if lastDrop == nil || simd_distance(lastDrop!, p) >= Caterpillar.spacing {
                    status.lastChakra = caterpillar.grow(at: p)
                    status.trailCount = caterpillar.count
                    lastDrop = p
                }
            }

            caterpillar.update(time: time, deltaTime: deltaTime)
        }

        private func beat() {
            let bpm = 72.0
            let phase = (time * bpm / 60).truncatingRemainder(dividingBy: 1)
            let lub = exp(-pow((phase - 0.10) / 0.05, 2))
            let dub = 0.6 * exp(-pow((phase - 0.30) / 0.05, 2))
            let s = Float(1 + 0.08 * (lub + dub))
            heart?.scale = SIMD3<Float>(repeating: s)
        }

        // MARK: input + tracking

        @objc func handleTap() {
            guard let arView, let anchor,
                  let camera = arView.session.currentFrame?.camera else { return }
            var offset = matrix_identity_float4x4
            offset.columns.3.z = -1.5
            let world = camera.transform * offset
            anchor.transform = Transform(matrix: world)
            anchor.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
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
            DispatchQueue.main.async { self.status.tracking = text }
        }
    }
}
