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
}
