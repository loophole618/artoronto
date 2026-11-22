// Gaussian splats over the AR view: MetalSplatter draws into a transparent layer each frame,
// which is laid over RealityKit's image in the post-process pass.
import Foundation
import UIKit
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
    private(set) var onWalk = false
    private var world: (matrix: simd_float4x4, anchored: Bool) = (matrix_identity_float4x4, false)
    private let worldLock = NSLock()
    private var pendingCapture: ((CGImage?) -> Void)?
    private var capturePipe: MTLRenderPipelineState?

    /// The splat layer of the next frame, for LOOK and LIVE (ARView.snapshot doesn't include it).
    func captureOverlay(_ done: @escaping (CGImage?) -> Void) {
        worldLock.lock(); pendingCapture = done; worldLock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if let cb = self?.takeCapture() { cb(nil) }
        }
    }

    private func takeCapture() -> ((CGImage?) -> Void)? {
        worldLock.lock(); defer { worldLock.unlock() }
        let c = pendingCapture; pendingCapture = nil
        return c
    }

    static func compose(_ base: UIImage?, _ overlay: CGImage?) -> UIImage? {
        guard let base, let overlay else { return base }
        let format = UIGraphicsImageRendererFormat()
        format.scale = base.scale
        let rect = CGRect(origin: .zero, size: base.size)
        return UIGraphicsImageRenderer(size: base.size, format: format).image { _ in
            base.draw(in: rect)
            UIImage(cgImage: overlay).draw(in: rect)
        }
    }

    /// Called from the scene update: RealityKit transforms may only be read on its own thread.
    func sync() {
        let m = holder.transformMatrix(relativeTo: nil), a = holder.isAnchored
        worldLock.lock(); world = (m, a); worldLock.unlock()
    }

    private var points: [SplatPoint]?
    private var original: [SplatPoint]?
    private var name = ""
    private(set) var figures = 1
    private(set) var every: Float = 0
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
                    self.original = pts
                    self.points = pts
                    self.parseLayout(label)
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

    private(set) var inFront = false
    private var placement = ""
    private var stage = ""

    func placed(onWalk: Bool) { needsPlacement = false; inFront = false; self.onWalk = onWalk }
    func moveToWalk() { if points != nil, !onWalk { needsPlacement = true } }

    /// "strobe-n16-every0.60.splat": 16 equal figures, one every 0.60 m along the walk.
    private func parseLayout(_ label: String) {
        figures = 1; every = 0
        guard let n = label.range(of: #"n(\d+)"#, options: .regularExpression),
              let e = label.range(of: #"every(\d+\.?\d*)"#, options: .regularExpression),
              let nv = Int(label[n].dropFirst()), let ev = Float(label[e].dropFirst(5)), nv > 1 else { return }
        figures = nv; every = ev
    }

    /// Stand the figures along a path: frame(s) gives the point and walking direction s metres in.
    func arrange(along frame: (Float) -> (point: SIMD3<Float>, direction: SIMD3<Float>)?) {
        guard let original, figures > 1 else { return }
        let per = original.count / figures
        var out: [SplatPoint] = []
        out.reserveCapacity(original.count)
        var placedFigures = 0
        for k in 0..<figures {
            guard let f = frame(Float(k) * every) else { continue }
            let r = simd_quatf(from: SIMD3(0, 0, -1), to: simd_normalize(f.direction))
            for i in (k * per)..<min((k + 1) * per, original.count) {
                var p = original[i]
                p.position = r.act(p.position) + f.point
                p.rotation = r * p.rotation
                out.append(p)
            }
            placedFigures += 1
        }
        points = out
        chunkAdded = false
        note(String(format: "%d figures every %.2f m along the walk", placedFigures, every))
    }
    func replace() { if points != nil { inFront = true; needsPlacement = true } }

    func note(_ where_: String) {
        placement = where_
        appLog.notice("app: splat \(where_, privacy: .public)")
        onStatus?("\(name): \(where_)")
    }

    private func step(_ s: String) {
        guard s != stage else { return }
        stage = s
        appLog.notice("app: splat stage \(s, privacy: .public)")
        let text = "\(name): \(s) · \(placement)"
        DispatchQueue.main.async { self.onStatus?(text) }
    }

    func postProcess(_ ctx: ARView.PostProcessContext) {
        let target = ctx.targetColorTexture
        if let blit = ctx.commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: ctx.sourceColorTexture, to: target)
            blit.endEncoding()
        }
        var captured = false
        defer {
            if !captured, let cb = takeCapture() { DispatchQueue.main.async { cb(nil) } }
        }
        guard visible, let points, let arView, let frame = arView.session.currentFrame else { return }
        worldLock.lock(); let w = world; worldLock.unlock()
        guard w.anchored else { step("waiting: its anchor isn't placed yet"); return }

        if renderer == nil || rendererFormat != target.pixelFormat {
            do {
                let r = try SplatRenderer(device: ctx.device, colorFormat: target.pixelFormat, depthFormat: .invalid,
                                          sampleCount: 1, maxViewCount: 1, maxSimultaneousRenders: 3)
                r.onSortComplete = { [weak self] t in self?.sortMs = t * 1000 }
                renderer = r
                rendererFormat = target.pixelFormat
                chunkAdded = false
                step("renderer ready (\(target.pixelFormat.rawValue), \(target.width)x\(target.height))")
            } catch {
                step("renderer failed: \(error.localizedDescription)")
                return
            }
        }
        guard let renderer else { return }
        if !chunkAdded {
            chunkAdded = true
            let device = ctx.device
            Task {
                do {
                    let chunk = try SplatChunk(device: device, from: points)
                    await renderer.removeAllChunks()
                    await renderer.addChunk(chunk)
                    self.step("chunk added")
                } catch {
                    self.step("chunk failed: \(error.localizedDescription)")
                }
            }
            return
        }
        guard renderer.isReadyToRender else { step("renderer busy"); return }

        if overlay == nil || overlay!.width != target.width || overlay!.height != target.height
            || overlay!.pixelFormat != target.pixelFormat {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: target.pixelFormat, width: target.width,
                                                             height: target.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            overlay = ctx.device.makeTexture(descriptor: d)
            composite = Self.makeComposite(device: ctx.device, format: target.pixelFormat)
        }
        guard let overlay, let composite else { step(composite == nil ? "composite shader failed" : "no overlay texture"); return }

        let size = arView.bounds.size
        let projection = frame.camera.projectionMatrix(for: .portrait, viewportSize: size, zNear: 0.05, zFar: 200)
        let view = frame.camera.viewMatrix(for: .portrait)
        let model = w.matrix
        let viewport = MTLViewport(originX: 0, originY: 0, width: Double(target.width), height: Double(target.height),
                                   znear: 0, zfar: 1)
        let vd = SplatRenderer.ViewportDescriptor(viewport: viewport, projectionMatrix: projection,
                                                  viewMatrix: view * model,
                                                  screenSize: SIMD2(target.width, target.height))
        do {
            let drew = try renderer.render(viewports: [vd], colorTexture: overlay, colorStoreAction: .store,
                                           depthTexture: nil, rasterizationRateMap: nil, renderTargetArrayLength: 0,
                                           to: ctx.commandBuffer)
            guard drew else { step("render skipped (sorting?)"); return }
        } catch {
            step("render error: \(error.localizedDescription)")
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
        if let cb = takeCapture() {
            captured = true
            encodeCapture(ctx, overlay: overlay, done: cb)
        }

        let now = CACurrentMediaTime()
        if lastFrame > 0 { frameTimes.append(now - lastFrame) }
        lastFrame = now
        if frameTimes.count > 60 { frameTimes.removeFirst(frameTimes.count - 60) }
        if now - lastReport > 1, !frameTimes.isEmpty {
            lastReport = now
            let fps = Double(frameTimes.count) / frameTimes.reduce(0, +)
            let text = String(format: "%@ · %d splats · %.0f fps · sort %.0f ms · %@", name, points.count, fps, sortMs, placement)
            appLog.notice("app: splat \(text, privacy: .public)")
            DispatchQueue.main.async { self.onStatus?(text) }
        }
    }

    private func encodeCapture(_ ctx: ARView.PostProcessContext, overlay: MTLTexture, done: @escaping (CGImage?) -> Void) {
        let fail = { DispatchQueue.main.async { done(nil) } }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: overlay.width,
                                                         height: overlay.height, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .shared
        if capturePipe == nil { capturePipe = Self.makeComposite(device: ctx.device, format: .bgra8Unorm_srgb, blend: false) }
        let pass = MTLRenderPassDescriptor()
        guard let tex = ctx.device.makeTexture(descriptor: d), let capturePipe else { fail(); return }
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { fail(); return }
        enc.setRenderPipelineState(capturePipe)
        enc.setFragmentTexture(overlay, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        ctx.commandBuffer.addCompletedHandler { _ in
            let w = tex.width, h = tex.height, row = w * 4
            var bytes = [UInt8](repeating: 0, count: row * h)
            tex.getBytes(&bytes, bytesPerRow: row, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            let image = CGDataProvider(data: Data(bytes) as CFData).flatMap {
                CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: $0,
                        decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            }
            DispatchQueue.main.async { done(image) }
        }
    }

    private static func makeComposite(device: MTLDevice, format: MTLPixelFormat, blend: Bool = true) -> MTLRenderPipelineState? {
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
        c.isBlendingEnabled = blend
        c.rgbBlendOperation = .add
        c.alphaBlendOperation = .add
        c.sourceRGBBlendFactor = .one
        c.sourceAlphaBlendFactor = .one
        c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: d)
    }
}
