@preconcurrency import AVFoundation
import CoreImage
import Metal
import QuartzCore
import UIKit

/// Live preview: receives camera frames, runs them through `StylePipeline`
/// at screen resolution and draws them into a Metal layer, all on the video
/// queue. Person masks for Soft Skin are computed on a separate queue every
/// few frames, only while Soft Skin is on.
final class PreviewRenderer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    let context: CIContext
    private let visionQueue = DispatchQueue(label: "cam18.vision", qos: .userInitiated)

    private let lock = NSLock()
    private var metalLayer: CAMetalLayer?
    private var recipe = StyleRecipe.neutral
    private var personMask: CIImage?
    private var segmentationBusy = false
    private var frameIndex: UInt64 = 0
    private var isFrozen = false

    /// Frames between person-segmentation updates in the preview.
    static let segmentationInterval: UInt64 = 4

    override init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.commandQueue = device?.makeCommandQueue()
        if let device {
            context = CIContext(mtlDevice: device, options: [
                .name: "Cam18.preview",
                .cacheIntermediates: false,
                .workingFormat: CIFormat.RGBAh,
            ])
        } else {
            context = CIContext()
        }
        super.init()
    }

    /// Called on the main thread when the preview view is created.
    func attach(_ layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        layer.isOpaque = true
        lock.lock(); metalLayer = layer; lock.unlock()
    }

    func setRecipe(_ recipe: StyleRecipe) {
        lock.lock()
        self.recipe = recipe
        if recipe.softSkinIntensity <= 0 { personMask = nil }
        lock.unlock()
    }

    /// Freezes the preview briefly, e.g. while switching lenses.
    func setFrozen(_ frozen: Bool) {
        lock.lock(); isFrozen = frozen; personMask = nil; lock.unlock()
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lock.lock()
        let layer = metalLayer
        let recipe = self.recipe
        let mask = personMask
        let frozen = isFrozen
        frameIndex &+= 1
        let frame = frameIndex
        let needsMask = recipe.softSkinIntensity > 0 && !segmentationBusy
            && frame % Self.segmentationInterval == 0
        if needsMask { segmentationBusy = true }
        lock.unlock()

        if needsMask {
            let boxed = UncheckedSendable(pixelBuffer)
            visionQueue.async { [weak self] in
                let m = PersonSegmenter.mask(for: boxed.value, quality: .balanced)
                guard let self else { return }
                self.lock.lock()
                self.personMask = m
                self.segmentationBusy = false
                self.lock.unlock()
            }
        }

        guard !frozen, let layer else { return }
        draw(CIImage(cvPixelBuffer: pixelBuffer), recipe: recipe, mask: mask, frameIndex: frame, into: layer)
    }

    // MARK: Drawing

    /// Fits a camera frame into `size` (aspect-fit, centered) and returns the
    /// fitted image plus its placement rect.
    static func fit(_ image: CIImage, into size: CGSize) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0, size.width > 0, size.height > 0 else { return image }
        let scale = min(size.width / e.width, size.height / e.height)
        let w = e.width * scale, h = e.height * scale
        let t = CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let scaled = image.samplingLinear().transformed(by: t)
            .cropped(to: CGRect(x: 0, y: 0, width: w.rounded(.down), height: h.rounded(.down)))
        return scaled.transformed(by: CGAffineTransform(
            translationX: ((size.width - w) / 2).rounded(), y: ((size.height - h) / 2).rounded()))
    }

    /// Runs the preview path once and returns the styled, fitted image. Used by
    /// `draw` and by the preview performance test.
    func previewImage(for frame: CIImage, recipe: StyleRecipe, mask: CIImage?, frameIndex: UInt64,
                      size: CGSize) -> CIImage {
        let fitted = Self.fit(frame, into: size)
        let origin = fitted.extent.origin
        let atZero = fitted.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        let styled = StylePipeline.render(atZero, recipe: recipe,
                                          options: RenderOptions(isPreview: true, frameIndex: frameIndex,
                                                                 personMask: mask))
        let background = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        return styled.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
            .composited(over: background)
    }

    private func draw(_ frame: CIImage, recipe: StyleRecipe, mask: CIImage?, frameIndex index: UInt64,
                      into layer: CAMetalLayer) {
        let size = layer.drawableSize
        guard size.width > 0, size.height > 0,
              let commandQueue,
              let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let image = previewImage(for: frame, recipe: recipe, mask: mask, frameIndex: index, size: size)
        let destination = CIRenderDestination(
            width: Int(size.width), height: Int(size.height),
            pixelFormat: layer.pixelFormat, commandBuffer: commandBuffer,
            mtlTextureProvider: { drawable.texture })
        destination.colorSpace = layer.colorspace
        do {
            _ = try context.startTask(toRender: image, to: destination)
        } catch {
            return
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// A view backed by a CAMetalLayer that the preview renderer draws into.
final class PreviewMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = traitCollection.displayScale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}
