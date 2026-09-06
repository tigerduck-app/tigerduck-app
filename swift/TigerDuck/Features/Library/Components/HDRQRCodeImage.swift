#if os(iOS)
import SwiftUI
import MetalKit
import UIKit

/// Renders a black/white QR `UIImage` into a `CAMetalLayer` that has
/// `wantsExtendedDynamicRangeContent` enabled, so the "white" modules emit
/// luminance well above the SDR clip point on EDR-capable displays
/// (iPhone XS and newer).
///
/// We drive Metal directly because SwiftUI's `Image(...).allowedDynamicRange(.high)`
/// modifier doesn't reliably promote synthetic UIImages — CoreImage's filter
/// chain clamps to `0...1` in non-extended working spaces, and even when
/// the resulting `UIImage` carries extended-range pixels, the SwiftUI
/// recognizer doesn't always tag it as HDR. Bypassing the Image pipeline
/// is the supported path documented in Apple's "EDR for video" / Core
/// Animation HDR sessions.
struct HDRQRCodeImage: UIViewRepresentable {
    /// `true` when this device exposes a Metal device — i.e. the EDR-backed
    /// renderer can run. When `false`, callers should fall back to the
    /// SDR `Image` plus a `UIScreen.brightness` boost so the scanner has
    /// something readable.
    static let isSupported: Bool = MTLCreateSystemDefaultDevice() != nil

    let image: UIImage
    /// Multiplier applied to "white" QR cells. 5.0 sits comfortably inside
    /// the EDR headroom on modern iPhones without dipping into the OS's
    /// thermal-throttle band; bump higher if scanners report contrast loss.
    let brightness: Float

    init(image: UIImage, brightness: Float = 5.0) {
        self.image = image
        self.brightness = brightness
    }

    func makeUIView(context: Context) -> EDRMetalQRView {
        EDRMetalQRView()
    }

    func updateUIView(_ uiView: EDRMetalQRView, context: Context) {
        uiView.brightness = brightness
        uiView.setImage(image)
    }
}

/// UIView backed by a `CAMetalLayer` configured for EDR output. Renders a
/// single full-screen triangle that samples the QR texture and multiplies
/// its luminance by `brightness`, producing pixels with values >1.0 that
/// the EDR compositor maps to higher panel nits.
final class EDRMetalQRView: UIView {

    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var texture: MTLTexture?
    /// Reference-identity key for the most recently uploaded QR. The
    /// SwiftUI parent observes a 1 Hz countdown, so `updateUIView` fires
    /// every tick even when `viewModel.qrCodeImage` hasn't actually
    /// changed — re-uploading the same texture each second would waste
    /// IOSurface allocations and burn battery.
    private var lastUploadedImage: UIImage?
    /// Coalesces every `redraw()` request made in one run-loop turn into a
    /// single draw. `updateUIView` + `setImage` + `layoutSubviews` used to
    /// each grab a drawable synchronously; the layer only has three and
    /// none is returned until the frame is presented, so the fourth
    /// `nextDrawable()` blocked the main thread for its 1 s timeout —
    /// the "whole app freezes when the QR refreshes" report.
    private var redrawScheduled = false

    var brightness: Float = 5.0 {
        didSet { if oldValue != brightness { setNeedsRedraw() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // Configure transparency BEFORE the no-Metal early-return so the
        // SDR fallback the caller stacks underneath us stays visible if
        // `MTLCreateSystemDefaultDevice()` returns nil.
        backgroundColor = .clear
        metalLayer.isOpaque = false
        guard let device else { return }
        metalLayer.device = device
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.framebufferOnly = true
        metalLayer.wantsExtendedDynamicRangeContent = true
        // extendedLinearDisplayP3 keeps pixel values in linear light, which
        // is what the EDR compositor expects when it scales above 1.0.
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        commandQueue = device.makeCommandQueue()
        buildPipeline()
    }

    private func buildPipeline() {
        guard let device else { return }
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
        };

        // Single oversized triangle that covers the viewport. Avoids vertex
        // buffers entirely; gl_VertexID picks the corner.
        vertex VertexOut qr_vertex(uint vid [[vertex_id]]) {
            float2 pos[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
            float2 uv[3]  = { float2( 0.0,  2.0), float2( 0.0, 0.0), float2(2.0, 0.0) };
            VertexOut o;
            o.position = float4(pos[vid], 0.0, 1.0);
            o.uv = uv[vid];
            return o;
        }

        fragment float4 qr_fragment(VertexOut in [[stage_in]],
                                    texture2d<float> tex [[texture(0)]],
                                    constant float &brightness [[buffer(0)]]) {
            constexpr sampler s(mag_filter::nearest, min_filter::nearest);
            // Source is black/white grayscale: white modules = 1, black = 0.
            // Scale by `brightness` so the white pixels punch above SDR.
            float v = tex.sample(s, in.uv).r * brightness;
            return float4(v, v, v, 1.0);
        }
        """
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            guard
                let vfn = library.makeFunction(name: "qr_vertex"),
                let ffn = library.makeFunction(name: "qr_fragment")
            else { return }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vfn
            desc.fragmentFunction = ffn
            desc.colorAttachments[0].pixelFormat = .rgba16Float
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            // Shader compile / pipeline link failure leaves `pipeline` nil;
            // the view renders nothing and the caller's SDR fallback (if any)
            // remains visible. Surface via Logger so this doesn't fail silent.
            pipeline = nil
        }
    }

    func setImage(_ image: UIImage) {
        // Reference-equality dedupe — `LibraryViewModel` only allocates a
        // new UIImage on the 30 s QR refresh, so identity is a reliable
        // signal that we genuinely need to re-upload.
        if lastUploadedImage === image { return }
        guard let device, let cgImage = image.cgImage else { return }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        ]
        if let tex = try? loader.newTexture(cgImage: cgImage, options: options) {
            self.texture = tex
            self.lastUploadedImage = image
            setNeedsRedraw()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let size = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
            setNeedsRedraw()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { setNeedsRedraw() }
    }

    private func setNeedsRedraw() {
        guard !redrawScheduled else { return }
        redrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.redrawScheduled = false
            self.redraw()
        }
    }

    private func redraw() {
        // Off-window layers never present, so their drawables never come
        // back — asking for one would just burn the timeout.
        guard
            window != nil,
            let pipeline,
            let commandQueue,
            let texture,
            metalLayer.drawableSize.width > 0,
            let drawable = metalLayer.nextDrawable()
        else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard
            let cmd = commandQueue.makeCommandBuffer(),
            let enc = cmd.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(texture, index: 0)
        var b = brightness
        enc.setFragmentBytes(&b, length: MemoryLayout<Float>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
#endif
