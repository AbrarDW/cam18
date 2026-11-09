import CoreImage
import Foundation
import XCTest
@testable import Cam18

enum TestSupport {
    nonisolated(unsafe) static let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
    nonisolated(unsafe) static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private final class Token {}

    static func sampleURL(_ name: String) throws -> URL {
        let bundle = Bundle(for: Token.self)
        guard let url = bundle.url(forResource: name, withExtension: "jpg") else {
            throw XCTSkip("Sample image \(name).jpg is missing from the test bundle")
        }
        return url
    }

    static func sample(_ name: String) throws -> CIImage {
        let url = try sampleURL(name)
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            XCTFail("Couldn't decode \(name)")
            throw XCTSkip("undecodable sample")
        }
        return image
    }

    /// Where rendered samples go. CI sets TEST_RUNNER_SAMPLE_OUTPUT_DIR, which
    /// xcodebuild passes to the test process as SAMPLE_OUTPUT_DIR.
    static let outputDirectory: URL = {
        let env = ProcessInfo.processInfo.environment["SAMPLE_OUTPUT_DIR"]
        let url = env.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Cam18Samples", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func writePNG(_ image: CIImage, name: String) {
        let url = outputDirectory.appendingPathComponent(name).appendingPathExtension("png")
        do {
            try context.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: sRGB)
        } catch {
            print("Couldn't write \(url.path): \(error)")
        }
    }

    /// Renders an image to float RGBA pixels in sRGB.
    static func pixels(_ image: CIImage, in rect: CGRect? = nil) -> [Float] {
        let r = (rect ?? image.extent).integral
        let w = Int(r.width), h = Int(r.height)
        var buffer = [Float](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { ptr in
            context.render(image, toBitmap: ptr.baseAddress!, rowBytes: w * 16, bounds: r,
                           format: .RGBAf, colorSpace: sRGB)
        }
        return buffer
    }

    /// Mean absolute difference over RGB.
    static func meanAbsDiff(_ a: CIImage, _ b: CIImage, in rect: CGRect? = nil) -> Double {
        let pa = pixels(a, in: rect), pb = pixels(b, in: rect)
        precondition(pa.count == pb.count)
        var sum = 0.0, n = 0
        for i in stride(from: 0, to: pa.count, by: 4) {
            for c in 0..<3 { sum += Double(abs(pa[i + c] - pb[i + c])); n += 1 }
        }
        return n > 0 ? sum / Double(n) : 0
    }

    /// Mean of local high-frequency energy (|pixel - right neighbor|) as a
    /// simple sharpness measure.
    static func sharpness(_ image: CIImage, in rect: CGRect) -> Double {
        let r = rect.integral
        let w = Int(r.width), h = Int(r.height)
        let p = pixels(image, in: r)
        var sum = 0.0, n = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                let i = (y * w + x) * 4, j = i + 4
                sum += Double(abs(p[i] - p[j]) + abs(p[i + 1] - p[j + 1]) + abs(p[i + 2] - p[j + 2]))
                n += 1
            }
        }
        return n > 0 ? sum / Double(n) : 0
    }

    /// Scales an image to `width` pixels wide, anchored at the origin.
    static func scaled(_ image: CIImage, toWidth width: CGFloat) -> CIImage {
        let e = image.extent
        let s = width / e.width
        return image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
            .cropped(to: CGRect(x: 0, y: 0, width: (e.width * s).rounded(.down), height: (e.height * s).rounded(.down)))
    }
}
