import SwiftUI
import RealityKit
import ARKit
import Combine

// Hello AR: one translucent green sphere (the Anahata colour), 1 m across,
// floating 1.5 m ahead at eye height, beating at 72 bpm.
// Walk into it: back faces are drawn, so the inside is visible.
// Tap anywhere to re-place it 1.5 m in front of you.

final class ARStatus: ObservableObject {
    @Published var tracking = "starting…"
}

struct ContentView: View {
    @StateObject private var status = ARStatus()

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ARViewContainer(status: status)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 4) {
                Text("ARToronto · hello AR").font(.headline)
                Text("tracking: \(status.tracking)")
                Text("build \(BuildInfo.label)")
                Text("tap to re-place the sphere")
            }
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.white)
            .padding(10)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            .padding()
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

        // The sphere sits in world space; the origin is where the phone was at launch.
        let anchor = AnchorEntity(world: SIMD3<Float>(0, 0, -1.5))
        anchor.addChild(Coordinator.makeSphere())
        arView.scene.addAnchor(anchor)
        coordinator.anchor = anchor

        // Heartbeat: scale the sphere every frame.
        coordinator.updates = arView.scene.subscribe(to: SceneEvents.Update.self) { event in
            coordinator.beat(deltaTime: event.deltaTime)
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
        var updates: Cancellable?
        private var time: Double = 0

        init(status: ARStatus) { self.status = status }

        static func makeSphere() -> ModelEntity {
            var material = PhysicallyBasedMaterial()
            let green = UIColor(red: 0.20, green: 0.85, blue: 0.45, alpha: 1)
            material.baseColor = .init(tint: green)
            material.emissiveColor = .init(color: green)
            material.emissiveIntensity = 0.6
            material.blending = .transparent(opacity: .init(floatLiteral: 0.45))
            material.faceCulling = .none   // see it from inside too
            return ModelEntity(mesh: .generateSphere(radius: 0.5), materials: [material])
        }

        func beat(deltaTime: Double) {
            time += deltaTime
            let bpm = 72.0
            let phase = (time * bpm / 60).truncatingRemainder(dividingBy: 1)
            // A double thump (lub-dub), then rest.
            let lub = exp(-pow((phase - 0.10) / 0.05, 2))
            let dub = 0.6 * exp(-pow((phase - 0.30) / 0.05, 2))
            let s = Float(1 + 0.08 * (lub + dub))
            anchor?.children.first?.scale = SIMD3<Float>(repeating: s)
        }

        @objc func handleTap() {
            guard let arView, let anchor,
                  let camera = arView.session.currentFrame?.camera else { return }
            // 1.5 m along the camera's view direction.
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
