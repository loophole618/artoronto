import SwiftUI
import RealityKit
import ARKit
import Combine

// Hello AR, build 2.
// - The heart: a translucent green sphere (Anahata), 1 m across, 1.5 m ahead,
//   beating at 72 bpm. Two shells (outside + inside) so it renders cleanly
//   from both sides. Tap empty space to re-place it 1.5 m in front of you.
// - The trail: press GO and walk. A little sphere drops every 12 cm,
//   just below the phone, hue drifting as you go. Press STOP, turn round,
//   and see your path hanging in the air. CLEAR wipes it.
//
// Positions are relative to where the phone was at launch (ARKit world
// tracking). Nothing reads GPS yet.

final class ARStatus: ObservableObject {
    @Published var tracking = "starting…"
    @Published var trailing = false
    @Published var trailCount = 0
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
                    Text("trail: \(status.trailCount) \(status.trailing ? "· dropping" : "")")
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
        private var time: Double = 0

        // Trail
        private var trailAnchor: AnchorEntity?
        private var lastDrop: SIMD3<Float>?
        private var handledClears = 0
        private lazy var dotMesh = MeshResource.generateSphere(radius: 0.02)
        private static let dropSpacing: Float = 0.12   // metres between dots
        private static let dropBelowPhone: Float = 0.10 // so dots don't sit on the lens
        private static let maxDots = 3000

        init(status: ARStatus) { self.status = status }

        // MARK: heart

        static func makeHeart() -> Entity {
            let heart = Entity()
            let sortGroup = ModelSortGroup(depthPass: nil)
            // Inside shell first (draws only back faces: visible from inside, and the
            // far wall from outside), then the outside shell (front faces only).
            // Each shell is convex and one-sided, so it can't overlap itself.
            // That overlap caused build 1's sawtooth edge and streaks.
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
            beat(deltaTime: deltaTime)

            if status.clearRequests != handledClears {
                handledClears = status.clearRequests
                clearTrail()
            }

            guard status.trailing else { lastDrop = nil; return }
            guard let frame = arView?.session.currentFrame,
                  case .normal = frame.camera.trackingState else { return }
            let c = frame.camera.transform.columns.3
            let p = SIMD3<Float>(c.x, c.y - Self.dropBelowPhone, c.z)
            if let last = lastDrop, simd_distance(last, p) < Self.dropSpacing { return }
            dropDot(at: p)
        }

        private func beat(deltaTime: Double) {
            time += deltaTime
            let bpm = 72.0
            let phase = (time * bpm / 60).truncatingRemainder(dividingBy: 1)
            let lub = exp(-pow((phase - 0.10) / 0.05, 2))
            let dub = 0.6 * exp(-pow((phase - 0.30) / 0.05, 2))
            let s = Float(1 + 0.08 * (lub + dub))
            heart?.scale = SIMD3<Float>(repeating: s)
        }

        // MARK: trail

        private func dropDot(at p: SIMD3<Float>) {
            guard let arView, status.trailCount < Self.maxDots else { return }
            if trailAnchor == nil {
                let a = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
                arView.scene.addAnchor(a)
                trailAnchor = a
            }
            let n = status.trailCount
            let hue = CGFloat((Double(n) * 0.006).truncatingRemainder(dividingBy: 1))
            let color = UIColor(hue: hue, saturation: 0.75, brightness: 1, alpha: 1)
            let dot = ModelEntity(mesh: dotMesh, materials: [UnlitMaterial(color: color)])
            dot.position = p
            trailAnchor?.addChild(dot)
            lastDrop = p
            status.trailCount = n + 1
        }

        private func clearTrail() {
            trailAnchor?.removeFromParent()
            trailAnchor = nil
            lastDrop = nil
            status.trailCount = 0
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
