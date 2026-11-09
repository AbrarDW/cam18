import CoreImage
import CoreVideo
import ImageIO
import Vision

/// Wraps `VNGeneratePersonSegmentationRequest` for Soft Skin.
enum PersonSegmenter {
    enum Quality { case fast, balanced, accurate }

    /// Returns a grayscale mask (white = person) for a pixel buffer, or nil if
    /// Vision fails. A mask with no person in it is all black.
    static func mask(for pixelBuffer: CVPixelBuffer, quality: Quality = .balanced) -> CIImage? {
        let request = makeRequest(quality)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        return perform(request, handler)
    }

    /// Returns a mask for an arbitrary image. Large stills are downscaled first,
    /// since the mask is low resolution anyway.
    static func mask(for image: CIImage, quality: Quality = .accurate, context: CIContext) -> CIImage? {
        let extent = image.extent
        let maxSide: CGFloat = 2048
        let scale = min(1, maxSide / max(extent.width, extent.height))
        let small = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(small, from: small.extent) else { return nil }
        let request = makeRequest(quality)
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        return perform(request, handler)
    }

    private static func makeRequest(_ quality: Quality) -> VNGeneratePersonSegmentationRequest {
        let request = VNGeneratePersonSegmentationRequest()
        switch quality {
        case .fast: request.qualityLevel = .fast
        case .balanced: request.qualityLevel = .balanced
        case .accurate: request.qualityLevel = .accurate
        }
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }

    private static func perform(_ request: VNGeneratePersonSegmentationRequest,
                                _ handler: VNImageRequestHandler) -> CIImage? {
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        return CIImage(cvPixelBuffer: buffer)
    }
}
