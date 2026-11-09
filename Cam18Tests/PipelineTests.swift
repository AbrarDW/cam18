import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Cam18

final class PipelineTests: XCTestCase {
    static let samples = ["scene", "portrait"]
    static let levels: [Double] = [0, 0.5, 1]

    func testKernelsLoad() {
        XCTAssertTrue(Kernels.shared.allLoaded, Kernels.shared.loadError ?? "unknown error")
    }

    func testNeutralRecipeIsIdentity() throws {
        let image = try TestSupport.sample("scene")
        let out = StylePipeline.render(image, recipe: .neutral)
        XCTAssertEqual(out.extent, image.extent)
        XCTAssertLessThan(TestSupport.meanAbsDiff(image, out), 0.002)
    }

    /// Renders every look at 0%, 50% and 100% on every sample, checks size and
    /// value range, and writes the results (plus a contact sheet per sample)
    /// for the CI artifact.
    func testEachLookAtEachLevel() throws {
        for name in Self.samples {
            let image = try TestSupport.sample(name)
            var tiles: [[CIImage]] = []

            for look in Look.allCases {
                var row: [CIImage] = []
                var previousDiff = -1.0
                for level in Self.levels {
                    var recipe = StyleRecipe(look: look, intensity: level)
                    if look == .toneColor { recipe.tone = 0.6; recipe.color = 0.5 }
                    recipe.grainSeed = 42
                    let out = StylePipeline.render(image, recipe: recipe)

                    XCTAssertEqual(out.extent, image.extent, "\(name)/\(look) changed size")
                    let px = TestSupport.pixels(out)
                    XCTAssertFalse(px.contains { !$0.isFinite }, "\(name)/\(look) produced NaN/Inf")
                    let minV = px.min() ?? 0, maxV = px.max() ?? 0
                    XCTAssertGreaterThanOrEqual(minV, -0.01, "\(name)/\(look) below range")
                    XCTAssertLessThanOrEqual(maxV, 1.01, "\(name)/\(look) above range")

                    let diff = TestSupport.meanAbsDiff(image, out)
                    let noSkinInScene = look == .softSkin && name == "scene"
                    if level == 0 {
                        XCTAssertLessThan(diff, 0.002, "\(name)/\(look) at 0% should be unchanged")
                    } else if !noSkinInScene {
                        XCTAssertGreaterThan(diff, previousDiff, "\(name)/\(look) should strengthen with intensity")
                    }
                    if level == 1 && !noSkinInScene {
                        XCTAssertGreaterThan(diff, 0.002, "\(name)/\(look) at 100% should change the image")
                    }
                    previousDiff = diff

                    TestSupport.writePNG(out, name: "\(name)-\(look.rawValue)-\(Int(level * 100))")
                    row.append(TestSupport.scaled(out, toWidth: 400))
                }
                tiles.append(row)
            }
            TestSupport.writePNG(contactSheet(tiles), name: "\(name)-contact-sheet")
        }
    }

    func testCombinedRecipe() throws {
        let image = try TestSupport.sample("portrait")
        var recipe = StyleRecipe(look: .film, intensity: 0.8)
        recipe.tone = -0.3; recipe.color = 0.4; recipe.toneColorIntensity = 1
        recipe.glowIntensity = 0.4
        recipe.softSkinIntensity = 0.7
        recipe.grainAmount = 0.5
        recipe.grainSeed = 7
        let out = StylePipeline.render(image, recipe: recipe)
        XCTAssertEqual(out.extent, image.extent)
        XCTAssertFalse(TestSupport.pixels(out).contains { !$0.isFinite })
        TestSupport.writePNG(out, name: "portrait-combined")
    }

    func testGrainIsDeterministicForStillsAndAnimatedInPreview() throws {
        let image = try TestSupport.sample("scene")
        var recipe = StyleRecipe(look: .grain, intensity: 1)
        recipe.grainSeed = 99
        let a = StylePipeline.render(image, recipe: recipe)
        let b = StylePipeline.render(image, recipe: recipe)
        XCTAssertLessThan(TestSupport.meanAbsDiff(a, b), 1e-5, "Same seed must give the same grain")

        let p1 = StylePipeline.render(image, recipe: recipe, options: RenderOptions(isPreview: true, frameIndex: 1))
        let p2 = StylePipeline.render(image, recipe: recipe, options: RenderOptions(isPreview: true, frameIndex: 2))
        XCTAssertGreaterThan(TestSupport.meanAbsDiff(p1, p2), 0.002, "Preview grain should animate")
    }

    /// Soft Skin must smooth the face but leave the background, hair and eyes
    /// sharp. Uses a hand-made person mask (the synthetic portrait has no real
    /// person for Vision to find).
    func testSoftSkinOnlyTouchesSkin() throws {
        let image = try TestSupport.sample("portrait")
        let e = image.extent
        // Ellipse-ish person mask: a white rect over the head/neck area.
        let person = CIImage(color: .black).cropped(to: e)
        let head = CIImage(color: .white).cropped(to: CGRect(x: e.width * 0.3, y: e.height * 0.2,
                                                             width: e.width * 0.4, height: e.height * 0.75))
        let mask = head.composited(over: person)

        let recipe = StyleRecipe(look: .softSkin, intensity: 1)
        let out = StylePipeline.render(image, recipe: recipe, options: RenderOptions(personMask: mask))

        // CI coordinates are bottom-up: the face center is ~58% up.
        let cheek = CGRect(x: e.width * 0.42, y: e.height * 0.52, width: 60, height: 40)
        let background = CGRect(x: 40, y: e.height * 0.55, width: 120, height: 120)
        let eye = CGRect(x: e.width * 0.5 - 100, y: e.height * 0.58, width: 60, height: 30)

        let cheekBefore = TestSupport.sharpness(image, in: cheek)
        let cheekAfter = TestSupport.sharpness(out, in: cheek)
        XCTAssertLessThan(cheekAfter, cheekBefore * 0.8, "Skin should be smoothed")

        XCTAssertLessThan(TestSupport.meanAbsDiff(image, out, in: background), 0.003, "Background must stay untouched")
        let eyeDiff = TestSupport.meanAbsDiff(image, out, in: eye)
        XCTAssertLessThan(eyeDiff, 0.03, "Eyes should stay essentially sharp")

        TestSupport.writePNG(SoftSkinLook.skinMask(for: image.applyingFilter("CILinearToSRGBToneCurve"),
                                                   personMask: mask, unit: StylePipeline.unit(for: e)),
                             name: "portrait-softskin-mask")
    }

    /// The preview renders at a much smaller size. Because every spatial
    /// parameter is relative to the image size, a downscaled full-resolution
    /// render should match a render of the downscaled input.
    func testPreviewMatchesStillAtDifferentResolutions() throws {
        let image = try TestSupport.sample("scene")
        for look in [Look.film, .glow, .toneColor] {
            let recipe = StyleRecipe(look: look, intensity: 1)
            let full = StylePipeline.render(image, recipe: recipe)
            let fullDown = TestSupport.scaled(full, toWidth: 400)
            let small = StylePipeline.render(TestSupport.scaled(image, toWidth: 400), recipe: recipe)
            let rect = CGRect(x: 0, y: 0, width: 400, height: 299)
            let diff = TestSupport.meanAbsDiff(fullDown, small, in: rect)
            XCTAssertLessThan(diff, 0.02, "\(look) preview/still mismatch \(diff)")
        }
    }

    /// Baked photos keep the camera's EXIF, are upright and record the look.
    func testBakedEncodeKeepsCameraMetadata() throws {
        let source = try TestSupport.sample("scene")
        // Fake a camera JPEG with EXIF and a rotated orientation.
        let exif: [String: Any] = [
            kCGImagePropertyExifFNumber as String: 1.78,
            kCGImagePropertyExifISOSpeedRatings as String: [64],
            kCGImagePropertyExifLensModel as String: "Test Lens 6.9mm f/1.78",
        ]
        let tiff: [String: Any] = [kCGImagePropertyTIFFMake as String: "Apple",
                                   kCGImagePropertyTIFFModel as String: "iPhone 17 Pro"]
        let props: [String: Any] = [kCGImagePropertyExifDictionary as String: exif,
                                    kCGImagePropertyTIFFDictionary as String: tiff,
                                    kCGImagePropertyOrientation as String: 6]
        let cg = try XCTUnwrap(TestSupport.context.createCGImage(source, from: source.extent))
        let jpeg = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let renderer = StillRenderer(context: TestSupport.context)
        let upright = try renderer.uprightImage(from: jpeg as Data)
        XCTAssertEqual(upright.extent.width, source.extent.height, "Orientation 6 should rotate to portrait")

        let recipe = StyleRecipe(look: .film, intensity: 0.7)
        let rendered = renderer.render(upright, recipe: recipe)
        let metadata = StillRenderer.metadata(of: jpeg as Data)

        var output: Data
        do {
            output = try renderer.encode(rendered, type: .heic, metadata: metadata, recipe: recipe)
        } catch {
            // Some simulator hosts lack a HEIC encoder; the metadata path is the same.
            output = try renderer.encode(rendered, type: .jpeg, metadata: metadata, recipe: recipe)
        }
        let saved = StillRenderer.metadata(of: output)
        XCTAssertEqual(saved[kCGImagePropertyOrientation as String] as? Int, 1)
        let savedExif = try XCTUnwrap(saved[kCGImagePropertyExifDictionary as String] as? [String: Any])
        XCTAssertEqual(savedExif[kCGImagePropertyExifFNumber as String] as? Double ?? 0, 1.78, accuracy: 0.01)
        XCTAssertEqual(savedExif[kCGImagePropertyExifLensModel as String] as? String, "Test Lens 6.9mm f/1.78")
        let comment = savedExif[kCGImagePropertyExifUserComment as String] as? String ?? ""
        XCTAssertTrue(comment.contains("Film"), "Look name should be recorded, got \(comment)")
        let savedTiff = saved[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual(savedTiff?[kCGImagePropertyTIFFModel as String] as? String, "iPhone 17 Pro")
    }

    // MARK: Helpers

    private func contactSheet(_ rows: [[CIImage]]) -> CIImage {
        var sheet = CIImage.empty()
        let gap: CGFloat = 8
        guard let tile = rows.first?.first?.extent.size else { return sheet }
        let height = CGFloat(rows.count) * (tile.height + gap)
        for (r, row) in rows.enumerated() {
            for (c, img) in row.enumerated() {
                let x = CGFloat(c) * (tile.width + gap)
                let y = height - CGFloat(r + 1) * (tile.height + gap)
                sheet = img.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: sheet)
            }
        }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(rows[0].count) * (tile.width + gap) - gap, height: height - gap)
        return sheet.composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
    }
}
