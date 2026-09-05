#if os(iOS)
import CoreImage
import MetalKit
import UIKit

@MainActor
public final class MetalVideoView: MTKView, MTKViewDelegate {
    public let mailbox: LatestFrameMailbox
    private let imageContext: CIContext
    private let commandQueue: MTLCommandQueue?
    public var zoom: CGFloat = 1
    private var lastFrame: CVPixelBuffer?
    private var needsRedraw = false

    public init(mailbox: LatestFrameMailbox) {
        self.mailbox = mailbox
        let metalDevice = MTLCreateSystemDefaultDevice()
        self.imageContext = metalDevice.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) } ?? CIContext(options: [.cacheIntermediates: false])
        self.commandQueue = metalDevice?.makeCommandQueue()
        super.init(frame: .zero, device: metalDevice)
        configure()
    }

    required init(coder: NSCoder) {
        mailbox = LatestFrameMailbox()
        let metalDevice = MTLCreateSystemDefaultDevice()
        imageContext = metalDevice.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) } ?? CIContext(options: [.cacheIntermediates: false])
        commandQueue = metalDevice?.makeCommandQueue()
        super.init(coder: coder)
        device = metalDevice
        configure()
    }

    private func configure() {
        delegate = self
        framebufferOnly = false
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 60
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.maximumDrawableCount = 2
            metalLayer.presentsWithTransaction = false
        }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { needsRedraw = true }

    public func setZoom(_ value: CGFloat) {
        guard zoom != value else { return }
        zoom = value
        needsRedraw = true
    }

    public func draw(in view: MTKView) {
        let incoming = mailbox.take()
        guard incoming != nil || needsRedraw else { return }
        if let incoming { lastFrame = incoming }
        guard let frame = lastFrame,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer() else { return }
        let image = CIImage(cvPixelBuffer: frame)
        let source = image.extent
        let target = CGRect(origin: .zero, size: drawableSize)
        needsRedraw = false
        let scale = min(target.width / source.width, target.height / source.height) * zoom
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = (target.width - scaled.extent.width) / 2
        let y = (target.height - scaled.extent.height) / 2
        imageContext.render(
            scaled.transformed(by: .init(translationX: x, y: y))
                .composited(over: CIImage(color: .black).cropped(to: target)),
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: target,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
#endif
