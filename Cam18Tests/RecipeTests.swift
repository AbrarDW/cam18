import Photos
import XCTest
@testable import Cam18

final class RecipeTests: XCTestCase {
    func testRoundTrip() throws {
        var recipe = StyleRecipe(look: .film, intensity: 0.7)
        recipe.tone = -0.4
        recipe.color = 0.25
        recipe.toneColorIntensity = 1
        recipe.grainAmount = 0.3
        recipe.grainSize = 0.8
        recipe.grainSeed = 123_456
        recipe.softSkinIntensity = 0.5
        recipe.glowIntensity = 0.2
        recipe.colorStyle = .amber
        recipe.styleIntensity = 0.8
        recipe.aspect = .r16x9
        recipe.setAdjustment(0.4, for: .exposure)
        recipe.setAdjustment(-0.6, for: .vignette)

        let data = try recipe.encoded()
        let decoded = try StyleRecipe.decode(from: data)
        XCTAssertEqual(decoded, recipe)
        XCTAssertEqual(decoded.version, StyleRecipe.currentVersion)
    }

    func testEncodingIsStable() throws {
        let a = try StyleRecipe(look: .glow, intensity: 0.5).encoded()
        let b = try StyleRecipe(look: .glow, intensity: 0.5).encoded()
        XCTAssertEqual(a, b, "Sorted keys keep adjustment data byte-stable")
    }

    func testFutureVersionIsRejected() {
        let json = #"{"version": 99, "filmIntensity": 0.5}"#.data(using: .utf8)!
        XCTAssertThrowsError(try StyleRecipe.decode(from: json)) { error in
            XCTAssertEqual(error as? StyleRecipe.RecipeError, .unsupportedVersion(99))
        }
    }

    func testMissingFieldsUseDefaults() throws {
        let json = #"{"version": 1, "filmIntensity": 0.4}"#.data(using: .utf8)!
        let recipe = try StyleRecipe.decode(from: json)
        XCTAssertEqual(recipe.filmIntensity, 0.4)
        XCTAssertEqual(recipe.glowIntensity, 0)
        XCTAssertEqual(recipe.grainSize, 0.35)
        XCTAssertEqual(recipe.primaryLook, .film)
    }

    func testOutOfRangeValuesAreClamped() throws {
        let json = #"{"version": 1, "filmIntensity": 3, "tone": -9, "color": 2, "grainSize": -1, "primaryLook": "bogus"}"#
            .data(using: .utf8)!
        let recipe = try StyleRecipe.decode(from: json)
        XCTAssertEqual(recipe.filmIntensity, 1)
        XCTAssertEqual(recipe.tone, -1)
        XCTAssertEqual(recipe.color, 1)
        XCTAssertEqual(recipe.grainSize, 0)
        XCTAssertEqual(recipe.primaryLook, .film)
    }

    func testNeutralAndSummary() {
        XCTAssertTrue(StyleRecipe.neutral.isNeutral)
        XCTAssertEqual(StyleRecipe.neutral.summary, "Original")
        var r = StyleRecipe(look: .film, intensity: 0.7)
        r.grainAmount = 0.3
        XCTAssertFalse(r.isNeutral)
        XCTAssertEqual(r.activeLooks, [.film, .grain])
        XCTAssertEqual(r.summary, "Film 70%, Grain 30%")
    }

    func testSetIntensityClamps() {
        var r = StyleRecipe()
        for look in Look.allCases {
            r.setIntensity(1.5, for: look)
            XCTAssertEqual(r.intensity(for: look), 1)
            r.setIntensity(-1, for: look)
            XCTAssertEqual(r.intensity(for: look), 0)
        }
    }

    func testAdjustmentDataRoundTrip() throws {
        let recipe = StyleRecipe(look: .softSkin, intensity: 0.6)
        let adjustment = PHAdjustmentData(formatIdentifier: StyleRecipe.formatIdentifier,
                                          formatVersion: StyleRecipe.formatVersion,
                                          data: try recipe.encoded())
        XCTAssertTrue(PhotoSaver.canHandle(adjustment))
        XCTAssertEqual(try StyleRecipe.decode(from: adjustment.data), recipe)

        let foreign = PHAdjustmentData(formatIdentifier: "com.example.other", formatVersion: "1", data: Data())
        XCTAssertFalse(PhotoSaver.canHandle(foreign))
    }

    func testBakeInLookDefaultsOffAndLastRecipePersists() throws {
        let suite = "cam18.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(defaults.bool(forKey: AppSettings.bakeInLookKey), "Bake in look must default to off")

        var recipe = StyleRecipe(look: .grain, intensity: 0.45)
        recipe.grainSize = 0.9
        AppSettings.saveLastRecipe(recipe, defaults)
        XCTAssertEqual(AppSettings.loadLastRecipe(defaults), recipe)
    }

    // MARK: Version 2: colour style, adjustments, aspect ratio

    func testVersion1RecipesStillOpen() throws {
        let json = #"{"version": 1, "filmIntensity": 0.4, "tone": 0.3, "toneColorIntensity": 1}"#.data(using: .utf8)!
        let recipe = try StyleRecipe.decode(from: json)
        XCTAssertEqual(recipe.colorStyle, .standard)
        XCTAssertFalse(recipe.isStyleActive)
        XCTAssertEqual(recipe.aspect, .full)
        XCTAssertFalse(recipe.hasAdjustments)
        XCTAssertEqual(recipe.tone, 0.3)
        XCTAssertEqual(recipe.filmIntensity, 0.4)
    }

    func testUnknownStyleAspectAndAdjustmentsAreDropped() throws {
        let json = #"{"version": 2, "colorStyle": "bogus", "aspect": "7:5", "styleIntensity": 4, "adjustments": {"exposure": 9, "nonsense": 0.5, "tint": 0}}"#
            .data(using: .utf8)!
        let recipe = try StyleRecipe.decode(from: json)
        XCTAssertEqual(recipe.colorStyle, .standard)
        XCTAssertEqual(recipe.aspect, .full)
        XCTAssertEqual(recipe.styleIntensity, 1)
        XCTAssertEqual(recipe.adjustment(.exposure), 1)
        XCTAssertEqual(recipe.adjustments.count, 1, "Unknown and zero adjustments shouldn't be kept")
    }

    func testAdjustmentsClampAndZeroIsNotStored() {
        var r = StyleRecipe()
        r.setAdjustment(3, for: .contrast)
        XCTAssertEqual(r.adjustment(.contrast), 1)
        XCTAssertTrue(r.hasAdjustments)
        XCTAssertFalse(r.isNeutral)
        r.setAdjustment(0, for: .contrast)
        XCTAssertEqual(r, StyleRecipe(), "Setting an adjustment back to zero must restore equality")
        r.setAdjustment(-0.5, for: .warmth)
        r.resetAdjustments()
        XCTAssertTrue(r.isNeutral)
    }

    func testStyleAndCropCountAsChanges() {
        var styled = StyleRecipe()
        styled.colorStyle = .amber
        styled.styleIntensity = 0.8
        XCTAssertTrue(styled.hasLook)
        XCTAssertEqual(styled.summary, "Amber 80%")
        styled.styleIntensity = 0
        XCTAssertTrue(styled.isNeutral, "A style at 0% changes nothing")

        var cropped = StyleRecipe()
        cropped.aspect = .square
        XCTAssertFalse(cropped.hasLook)
        XCTAssertFalse(cropped.isNeutral, "A crop alone must still be saved as an edit")
    }

    func testMatchesIgnoresBookkeeping() {
        var a = StyleRecipe(look: .film, intensity: 0.7)
        var b = a
        b.grainSeed = 55
        b.primaryLook = .grain
        XCTAssertTrue(a.matches(b))
        a.aspect = .r3x2
        XCTAssertFalse(a.matches(b))
    }

    func testAspectRatioCropRects() {
        let landscape = CGRect(x: 0, y: 0, width: 4032, height: 3024)
        let portrait = CGRect(x: 0, y: 0, width: 3024, height: 4032)
        XCTAssertEqual(AspectRatio.full.cropRect(in: landscape), landscape)
        XCTAssertEqual(AspectRatio.r16x9.cropRect(in: landscape), CGRect(x: 0, y: 378, width: 4032, height: 2268))
        XCTAssertEqual(AspectRatio.r16x9.cropRect(in: portrait), CGRect(x: 378, y: 0, width: 2268, height: 4032))
        XCTAssertEqual(AspectRatio.r3x2.cropRect(in: landscape), CGRect(x: 0, y: 168, width: 4032, height: 2688))
        XCTAssertEqual(AspectRatio.square.cropRect(in: portrait), CGRect(x: 0, y: 504, width: 3024, height: 3024))
        // Already the right shape: unchanged, so cropping twice is harmless.
        for ratio in AspectRatio.allCases {
            let once = ratio.cropRect(in: CGRect(x: 0, y: 0, width: 1001, height: 757))
            XCTAssertEqual(ratio.cropRect(in: once), once)
        }
    }

    func testColorStyleMapsStayInRangeAndStandardIsIdentity() {
        let probes: [SIMD3<Double>] = [.init(0, 0, 0), .init(1, 1, 1), .init(0.5, 0.5, 0.5),
                                       .init(1, 0, 0), .init(0.1, 0.8, 0.3), .init(0.9, 0.7, 0.2)]
        for style in ColorStyle.allCases {
            for p in probes {
                let out = style.map(p)
                for v in [out.x, out.y, out.z] {
                    XCTAssertTrue(v.isFinite && v >= 0 && v <= 1, "\(style) out of range for \(p)")
                }
                if style == .standard {
                    XCTAssertEqual(out.x, p.x, accuracy: 1e-9)
                    XCTAssertEqual(out.y, p.y, accuracy: 1e-9)
                    XCTAssertEqual(out.z, p.z, accuracy: 1e-9)
                }
            }
            if style.parameters.mono {
                let out = style.map(.init(0.9, 0.2, 0.4))
                XCTAssertEqual(out.x, out.y, accuracy: 1e-9)
                XCTAssertEqual(out.y, out.z, accuracy: 1e-9)
            }
        }
        XCTAssertEqual(ColorStyle.amber.makeCubeData().count,
                       ColorStyle.cubeDimension * ColorStyle.cubeDimension * ColorStyle.cubeDimension * 16)
    }

    func testEachStyleRemembersItsIntensity() throws {
        let suite = "cam18.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var recipe = StyleRecipe()
        AppSettings.select(.amber, in: &recipe, defaults)
        XCTAssertEqual(recipe.colorStyle, .amber)
        XCTAssertEqual(recipe.styleIntensity, 1, "A style starts at full strength")
        recipe.styleIntensity = 0.4
        AppSettings.select(.rose, in: &recipe, defaults)
        XCTAssertEqual(recipe.styleIntensity, 1)
        recipe.styleIntensity = 0.7
        AppSettings.select(.amber, in: &recipe, defaults)
        XCTAssertEqual(recipe.styleIntensity, 0.4, accuracy: 1e-9)
        AppSettings.select(.rose, in: &recipe, defaults)
        XCTAssertEqual(recipe.styleIntensity, 0.7, accuracy: 1e-9)
    }

    // MARK: Presets

    @MainActor
    func testPresetsPersistAndCanBeEdited() throws {
        let suite = "cam18.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = PresetStore(defaults: defaults)
        XCTAssertEqual(store.presets.map(\.name), PresetStore.starters.map(\.name), "Starters on first run")

        var recipe = StyleRecipe(look: .glow, intensity: 0.5)
        recipe.colorStyle = .tealOrange
        recipe.aspect = .r16x9
        recipe.setAdjustment(0.3, for: .contrast)
        recipe.grainSeed = 777
        let saved = store.add(name: "  Night out  ", recipe: recipe)
        XCTAssertEqual(saved.name, "Night out")
        XCTAssertEqual(saved.recipe.grainSeed, 0, "Presets don't keep the per-photo grain seed")
        XCTAssertEqual(store.preset(matching: recipe)?.id, saved.id)

        store.rename(saved.id, to: "")
        XCTAssertEqual(store.presets.last?.name, "My preset")
        store.rename(saved.id, to: "Night")
        var changed = recipe
        changed.aspect = .square
        store.update(saved.id, recipe: changed)

        // A second store on the same defaults sees everything.
        let reloaded = PresetStore(defaults: defaults)
        XCTAssertEqual(reloaded.presets, store.presets)
        XCTAssertEqual(reloaded.presets.last?.name, "Night")
        XCTAssertEqual(reloaded.presets.last?.recipe.aspect, .square)
        XCTAssertEqual(reloaded.presets.last?.recipe.colorStyle, .tealOrange)
        XCTAssertEqual(reloaded.presets.last?.recipe.adjustment(.contrast) ?? 0, 0.3, accuracy: 1e-9)

        for preset in reloaded.presets { reloaded.delete(preset.id) }
        XCTAssertTrue(PresetStore(defaults: defaults).presets.isEmpty, "Deleted starters must not come back")
    }
}
