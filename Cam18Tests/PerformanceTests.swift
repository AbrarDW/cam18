import CoreImage
import XCTest
@testable import Cam18

/// Measures the live-preview path: a camera-sized frame fitted to a
/// phone-sized drawable and run through a heavy recipe.
final class PerformanceTests: XCTestCase {
    func testPreviewPathPerformance() throws {
        let sample = try TestSupport.sample("portrait")
        // A 4:3 frame at the size AVCaptureSession.Preset.photo previews deliver.
        let s = 1440 / sample.extent.width
        let frame = sample.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let renderer = PreviewRenderer()
        var recipe = StyleRecipe(look: .film, intensity: 0.8)
        recipe.glowIntensity = 0.5
        recipe.grainAmount = 0.4
        recipe.toneColorIntensity = 1
        recipe.tone = 0.3
        let drawable = CGSize(width: 1206, height: 1608)
        let context = renderer.context
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

        var frameIndex: UInt64 = 0
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<10 {
                frameIndex += 1
                let image = renderer.previewImage(for: frame, recipe: recipe, mask: nil,
                                                  frameIndex: frameIndex, size: drawable)
                _ = context.createCGImage(image, from: CGRect(origin: .zero, size: drawable),
                                          format: .BGRA8, colorSpace: colorSpace)
            }
        }
    }

    func testPreviewFitKeepsAspectAndCenters() {
        let frame = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1080, height: 1440))
        let fitted = PreviewRenderer.fit(frame, into: CGSize(width: 1206, height: 2622))
        XCTAssertEqual(fitted.extent.width, 1206, accuracy: 1)
        XCTAssertEqual(fitted.extent.height, 1608, accuracy: 1)
        XCTAssertEqual(fitted.extent.midY, 2622 / 2, accuracy: 1)
    }
}
