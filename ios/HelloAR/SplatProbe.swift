// Gaussian splats over the AR view: MetalSplatter draws into a transparent layer each frame,
// which is laid over RealityKit's image in the post-process pass.
import Foundation
import Metal
import RealityKit
import ARKit
import MetalSplatter
import SplatIO

final class SplatProbe {
    let holder = Entity()
    weak var arView: ARView?
    var visible = true
    var onStatus: ((String) -> Void)?
    private(set) var needsPlacement = false

    private var points: [SplatPoint]?
    private var name = ""
    private var renderer: SplatRenderer?
    private var rendererFormat: MTLPixelFormat = .invalid
    private var chunkAdded = false
    private var overlay: MTLTexture?
    private var composite: MTLRenderPipelineState?
    private var lastFrame: CFTimeInterval = 0
    private var frameTimes: [Double] = []
    private var sortMs: Double = 0
    private var lastReport: CFTimeInterval = 0

    func load(url: URL, label: String) {
        name = label
        onStatus?("\(label): reading…")
        Task {
            do {
                let reader = try AutodetectSceneReader(url)
                let pts = try await reader.readAll()
                await MainActor.run {
                    self.points = pts
                    self.chunkAdded = false
                    self.renderer = nil
                    self.needsPlacement = true
                    self.onStatus?("\(label): \(pts.count) splats loaded")
                }
            } catch {
                await MainActor.run { self.onStatus?("\(label): couldn't read (\(error.localizedDescription))") }
            }
        }
    }

    func placed() { needsPlacement = false }
    func replace() { if points != nil { needsPlacement = true } }

    func postProcess(_ ctx: ARView.PostProcessContext) {
        let target = ctx.targetColorTexture
        if let blit = ctx.commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: ctx.sourceColorTexture, to: target)
            blit.endEncoding()
        }
        guard visible, let points, let arView, let frame = arView.session.currentFrame,
              holder.isAnchored else { return }

        if renderer == nil || rendererFormat != target.pixelFormat {
            do {
                let r = try SplatRenderer(device: ctx.device, colorFormat: target.pixelFormat, depthFormat: .invalid,
                                          sampleCount: 1, maxViewCount: 1, maxSimultaneousRenders: 3)
                r.onSortComplete = { [weak self] t in self?.sortMs = t * 1000 }
                renderer = r
                rendererFormat = target.pixelFormat
                chunkAdded = false
            } catch {
                onStatus?("splat renderer failed: \(error.localizedDescription)")
                return
            }
        }
        guard let renderer else { return }
        if !chunkAdded {
            chunkAdded = true
            let device = ctx.device
            Task {
                if let chunk = try? SplatChunk(device: device, from: points) { await renderer.addChunk(chunk) }
            }
            return
        }
        guard renderer.isReadyToRender else { return }

        if overlay == nil || overlay!.width != target.width || overlay!.height != target.height
            || overlay!.pixelFormat != target.pixelFormat {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: target.pixelFormat, width: target.width,
                                                             height: target.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            overlay = ctx.device.makeTexture(descriptor: d)
            composite = Self.makeComposite(device: ctx.device, format: target.pixelFormat)
        }
        guard let overlay, let composite else { return }

        let size = arView.bounds.size
        let projection = frame.camera.projectionMatrix(for: .portrait, viewportSize: size, zNear: 0.05, zFar: 200)
        let view = frame.camera.viewMatrix(for: .portrait)
        let model = holder.transformMatrix(relativeTo: nil)
        let viewport = MTLViewport(originX: 0, originY: 0, width: Double(target.width), height: Double(target.height),
                                   znear: 0, zfar: 1)
        let vd = SplatRenderer.ViewportDescriptor(viewport: viewport, projectionMatrix: projection,
                                                  viewMatrix: view * model,
                                                  screenSize: SIMD2(target.width, target.height))
        do {
            let drew = try renderer.render(viewports: [vd], colorTexture: overlay, colorStoreAction: .store,
                                           depthTexture: nil, rasterizationRateMap: nil, renderTargetArrayLength: 0,
                                           to: ctx.commandBuffer)
            guard drew else { return }
        } catch {
            return
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        if let enc = ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            enc.setRenderPipelineState(composite)
            enc.setFragmentTexture(overlay, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        let now = CACurrentMediaTime()
        if lastFrame > 0 { frameTimes.append(now - lastFrame) }
        lastFrame = now
        if frameTimes.count > 60 { frameTimes.removeFirst(frameTimes.count - 60) }
        if now - lastReport > 1, !frameTimes.isEmpty {
            lastReport = now
            let fps = Double(frameTimes.count) / frameTimes.reduce(0, +)
            let text = String(format: "%@ · %d splats · %.0f fps · sort %.0f ms", name, points.count, fps, sortMs)
            DispatchQueue.main.async { self.onStatus?(text) }
        }
    }

    private static func makeComposite(device: MTLDevice, format: MTLPixelFormat) -> MTLRenderPipelineState? {
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 pos [[position]]; float2 uv; };
        vertex V fsq(uint vid [[vertex_id]]) {
            float2 p = float2((vid << 1) & 2, vid & 2);
            V o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); o.uv = float2(p.x, 1.0 - p.y); return o;
        }
        fragment float4 over(V in [[stage_in]], texture2d<float> t [[texture(0)]]) {
            constexpr sampler s(filter::linear);
            return t.sample(s, in.uv);
        }
        """
        guard let lib = try? device.makeLibrary(source: src, options: nil) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "fsq")
        d.fragmentFunction = lib.makeFunction(name: "over")
        let c = d.colorAttachments[0]!
        c.pixelFormat = format
        c.isBlendingEnabled = true
        c.rgbBlendOperation = .add
        c.alphaBlendOperation = .add
        c.sourceRGBBlendFactor = .one
        c.sourceAlphaBlendFactor = .one
        c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: d)
    }
}
