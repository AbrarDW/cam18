import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Cam18

final class PipelineTests: XCTestCase {
    static let samples = ["scene", "portrait"]
    static let levels: [Double] = [0, 0.5, 1]
    /// The synthetic portrait's face, in Core Image (bottom-up) coordinates.
    static let portraitFace = CGRect(x: 480, y: 420, width: 240, height: 200)

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
                        // Soft Skin only touches the face, so judge it there
                        // rather than averaged over the whole frame.
                        let changed = look == .softSkin
                            ? TestSupport.meanAbsDiff(image, out, in: Self.portraitFace)
                            : diff
                        XCTAssertGreaterThan(changed, 0.002, "\(name)/\(look) at 100% should change the image")
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

    // MARK: Colour styles

    /// Renders every colour style at 100% on every sample, checks size and
    /// range, and writes a contact sheet of all styles for the CI artifact.
    func testEachColorStyle() throws {
        for name in Self.samples {
            let image = try TestSupport.sample(name)
            var tiles: [CIImage] = []
            for style in ColorStyle.allCases {
                var recipe = StyleRecipe()
                recipe.colorStyle = style
                let out = StylePipeline.render(image, recipe: recipe)
                XCTAssertEqual(out.extent, image.extent, "\(name)/\(style) changed size")
                let px = TestSupport.pixels(out)
                XCTAssertFalse(px.contains { !$0.isFinite }, "\(name)/\(style) produced NaN/Inf")
                XCTAssertGreaterThanOrEqual(px.min() ?? 0, -0.01, "\(name)/\(style) below range")
                XCTAssertLessThanOrEqual(px.max() ?? 0, 1.01, "\(name)/\(style) above range")

                let diff = TestSupport.meanAbsDiff(image, out)
                if style == .standard {
                    XCTAssertLessThan(diff, 0.002, "Standard must leave the image alone")
                } else {
                    XCTAssertGreaterThan(diff, 0.004, "\(name)/\(style) should change the image")
                    recipe.styleIntensity = 0.5
                    let half = TestSupport.meanAbsDiff(image, StylePipeline.render(image, recipe: recipe))
                    XCTAssertLessThan(half, diff, "\(name)/\(style) should be weaker at 50%")
                    XCTAssertGreaterThan(half, 0.001)
                }
                tiles.append(TestSupport.scaled(out, toWidth: 400))
            }
            let rows = stride(from: 0, to: tiles.count, by: 4).map { Array(tiles[$0..<min($0 + 4, tiles.count)]) }
            TestSupport.writePNG(contactSheet(rows), name: "\(name)-styles-contact-sheet")
        }
    }

    func testMonoStylesRemoveColor() throws {
        let image = try TestSupport.sample("scene")
        var recipe = StyleRecipe()
        recipe.colorStyle = .mono
        let px = TestSupport.pixels(TestSupport.scaled(StylePipeline.render(image, recipe: recipe), toWidth: 200))
        var spread = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            spread = max(spread, Double(max(px[i], px[i + 1], px[i + 2]) - min(px[i], px[i + 1], px[i + 2])))
        }
        XCTAssertLessThan(spread, 0.03, "Mono should have no colour left")
    }

    // MARK: Adjustments

    /// Renders every adjustment at −100 and +100, checks size and range and
    /// that the two ends differ, and writes a contact sheet (− on the left).
    func testEachAdjustment() throws {
        let image = try TestSupport.sample("portrait")
        var rows: [[CIImage]] = []
        for adjustment in Adjustment.allCases {
            var row: [CIImage] = []
            var ends: [CIImage] = []
            for value in [-1.0, 1.0] {
                var recipe = StyleRecipe()
                recipe.setAdjustment(value, for: adjustment)
                let out = StylePipeline.render(image, recipe: recipe)
                XCTAssertEqual(out.extent, image.extent, "\(adjustment) changed size")
                let px = TestSupport.pixels(out)
                XCTAssertFalse(px.contains { !$0.isFinite }, "\(adjustment) produced NaN/Inf")
                XCTAssertGreaterThanOrEqual(px.min() ?? 0, -0.01, "\(adjustment) below range")
                XCTAssertLessThanOrEqual(px.max() ?? 0, 1.01, "\(adjustment) above range")
                XCTAssertGreaterThan(TestSupport.meanAbsDiff(image, out), 0.0003,
                                     "\(adjustment) at \(value) should change the image")
                ends.append(out)
                row.append(TestSupport.scaled(out, toWidth: 400))
            }
            XCTAssertGreaterThan(TestSupport.meanAbsDiff(ends[0], ends[1]), 0.0006,
                                 "\(adjustment): −100 and +100 should differ")
            rows.append(row)
        }
        TestSupport.writePNG(contactSheet(rows), name: "portrait-adjustments-contact-sheet")
    }

    func testAdjustmentDirections() throws {
        let image = try TestSupport.sample("scene")
        func mean(_ adjustment: Adjustment, _ value: Double) -> (r: Double, g: Double, b: Double) {
            var recipe = StyleRecipe()
            recipe.setAdjustment(value, for: adjustment)
            let px = TestSupport.pixels(TestSupport.scaled(StylePipeline.render(image, recipe: recipe), toWidth: 200))
            var r = 0.0, g = 0.0, b = 0.0
            for i in stride(from: 0, to: px.count, by: 4) {
                r += Double(px[i]); g += Double(px[i + 1]); b += Double(px[i + 2])
            }
            let n = Double(px.count / 4)
            return (r / n, g / n, b / n)
        }
        func luma(_ m: (r: Double, g: Double, b: Double)) -> Double { (m.r + m.g + m.b) / 3 }

        XCTAssertGreaterThan(luma(mean(.exposure, 1)), luma(mean(.exposure, -1)) + 0.05)
        XCTAssertGreaterThan(luma(mean(.shadows, 1)), luma(mean(.shadows, -1)))
        XCTAssertGreaterThan(luma(mean(.highlights, 1)), luma(mean(.highlights, -1)))
        XCTAssertGreaterThan(luma(mean(.vignette, -1)), luma(mean(.vignette, 1)), "Positive vignette darkens")
        let warm = mean(.warmth, 1), cool = mean(.warmth, -1)
        XCTAssertGreaterThan(warm.r - warm.b, cool.r - cool.b, "Positive warmth shifts toward amber")
    }

    // MARK: Aspect ratio

    /// A crop-only recipe returns exactly the centre of the photo in the
    /// requested shape, for landscape and portrait photos.
    func testCropGivesRequestedShape() throws {
        let landscape = try TestSupport.sample("scene")
        let portrait = landscape.oriented(.right)
        let portraitAtZero = portrait.transformed(by: CGAffineTransform(translationX: -portrait.extent.minX,
                                                                        y: -portrait.extent.minY))
        for (label, image) in [("landscape", landscape), ("portrait", portraitAtZero)] {
            for aspect in AspectRatio.allCases {
                var recipe = StyleRecipe()
                recipe.aspect = aspect
                let out = StylePipeline.render(image, recipe: recipe)
                let e = out.extent
                guard let ratio = aspect.ratio else {
                    XCTAssertEqual(e, image.extent)
                    continue
                }
                XCTAssertEqual(e.origin, .zero, "\(label)/\(aspect) should start at the origin")
                XCTAssertEqual(Double(max(e.width, e.height) / min(e.width, e.height)), ratio, accuracy: 0.01,
                               "\(label)/\(aspect) has the wrong shape")
                if aspect != .square {
                    XCTAssertEqual(e.width > e.height, image.extent.width > image.extent.height,
                                   "\(label)/\(aspect) should keep the photo's orientation")
                }
                let crop = aspect.cropRect(in: image.extent)
                let expected = image.cropped(to: crop)
                    .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                XCTAssertLessThan(TestSupport.meanAbsDiff(expected, out, in: e), 0.002,
                                  "\(label)/\(aspect) should be the centre of the photo")
                // Cropping an already-cropped photo changes nothing.
                XCTAssertEqual(StylePipeline.render(out, recipe: recipe).extent, e)
                if label == "landscape" {
                    recipe.filmIntensity = 0.7
                    let styled = StylePipeline.render(image, recipe: recipe)
                    XCTAssertEqual(styled.extent, e, "Looks must not change the cropped size")
                    TestSupport.writePNG(TestSupport.scaled(styled, toWidth: 600),
                                         name: "scene-aspect-\(aspect.rawValue.replacingOccurrences(of: ":", with: "x"))")
                }
            }
        }
    }

    /// The person mask describes the whole photo; after a crop the pipeline
    /// must use only the part that covers the cropped area.
    func testPersonMaskFollowsCrop() {
        let full = CGRect(x: 0, y: 0, width: 1200, height: 900)
        // A quarter-size mask, as Vision would return.
        let mask = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 225))
        let crop = AspectRatio.square.cropRect(in: full)
        XCTAssertEqual(crop, CGRect(x: 150, y: 0, width: 900, height: 900))
        let cropped = StylePipeline.cropMask(mask, from: full, to: crop)
        XCTAssertEqual(cropped.extent.minX, 37.5, accuracy: 1)
        XCTAssertEqual(cropped.extent.minY, 0, accuracy: 1)
        XCTAssertEqual(cropped.extent.width, 225, accuracy: 1)
        XCTAssertEqual(cropped.extent.height, 225, accuracy: 1)
        XCTAssertEqual(StylePipeline.cropMask(mask, from: full, to: full).extent, mask.extent)
    }

    /// The viewfinder shows the cropped framing: bars outside it are black.
    func testPreviewShowsCrop() {
        let size = CGSize(width: 300, height: 400)
        let frame = CIImage(color: .red).cropped(to: CGRect(origin: .zero, size: size))
        var recipe = StyleRecipe()
        recipe.aspect = .square
        let image = PreviewRenderer().previewImage(for: frame, recipe: recipe, mask: nil, frameIndex: 1, size: size)
        let bar = TestSupport.pixels(image, in: CGRect(x: 100, y: 10, width: 20, height: 20))
        let center = TestSupport.pixels(image, in: CGRect(x: 140, y: 190, width: 20, height: 20))
        XCTAssertLessThan(bar[0], 0.05, "Outside the square crop should be black")
        XCTAssertGreaterThan(center[0], 0.8, "Inside the crop shows the camera")
        let edge = TestSupport.pixels(image, in: CGRect(x: 140, y: 60, width: 20, height: 20))
        XCTAssertGreaterThan(edge[0], 0.8, "The square should span y 50...350")
    }

    /// Everything together: style, pad, adjustments, looks and a crop.
    func testFullRecipe() throws {
        let image = try TestSupport.sample("portrait")
        var recipe = StyleRecipe(look: .film, intensity: 0.5)
        recipe.colorStyle = .amber
        recipe.styleIntensity = 0.8
        recipe.tone = 0.3; recipe.color = 0.2; recipe.toneColorIntensity = 1
        for adjustment in Adjustment.allCases { recipe.setAdjustment(0.4, for: adjustment) }
        recipe.glowIntensity = 0.3
        recipe.softSkinIntensity = 0.5
        recipe.grainAmount = 0.4
        recipe.grainSeed = 11
        recipe.aspect = .r3x2
        let out = StylePipeline.render(image, recipe: recipe)
        XCTAssertEqual(out.extent, AspectRatio.r3x2.cropRect(in: image.extent).offsetBy(
            dx: -AspectRatio.r3x2.cropRect(in: image.extent).minX,
            dy: -AspectRatio.r3x2.cropRect(in: image.extent).minY))
        let px = TestSupport.pixels(out)
        XCTAssertFalse(px.contains { !$0.isFinite })
        XCTAssertGreaterThanOrEqual(px.min() ?? 0, -0.01)
        XCTAssertLessThanOrEqual(px.max() ?? 0, 1.01)
        TestSupport.writePNG(out, name: "portrait-full-recipe")
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
