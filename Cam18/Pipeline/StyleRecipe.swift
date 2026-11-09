import Foundation

/// The looks offered in the camera. Each one maps to a layer in `StyleRecipe`.
enum Look: String, Codable, CaseIterable, Identifiable, Sendable {
    case toneColor
    case film
    case glow
    case softSkin
    case grain

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .toneColor: "Tone & Color"
        case .film: "Film"
        case .glow: "Glow"
        case .softSkin: "Soft Skin"
        case .grain: "Grain"
        }
    }

    var symbolName: String {
        switch self {
        case .toneColor: "circle.lefthalf.filled"
        case .film: "film"
        case .glow: "sun.max"
        case .softSkin: "face.smiling"
        case .grain: "circle.dotted"
        }
    }
}

/// Everything needed to reproduce a look on a photo. Stored as JSON inside
/// `PHAdjustmentData` so a photo can be reopened and re-edited later.
///
/// Every layer has an intensity in 0...1, where 0 means the layer is off. The
/// layers stack in a fixed order (see `StylePipeline`), so a recipe can combine,
/// say, Film with a little Grain.
struct StyleRecipe: Codable, Equatable, Sendable {
    static let currentVersion = 1
    /// Identifies Cam18 recipes inside `PHAdjustmentData`.
    static let formatIdentifier = "com.cam18.recipe"
    static let formatVersion = "1"

    var version: Int = StyleRecipe.currentVersion

    /// Tone & Color pad. `tone` is the vertical axis (−1 flat and lifted,
    /// +1 punchy), `color` the horizontal axis (−1 muted and cool, +1 rich and warm).
    var tone: Double = 0
    var color: Double = 0
    var toneColorIntensity: Double = 0

    var filmIntensity: Double = 0
    var glowIntensity: Double = 0
    var softSkinIntensity: Double = 0

    var grainAmount: Double = 0
    /// Grain cell size relative to the image, 0 (fine) ... 1 (coarse).
    var grainSize: Double = 0.35
    /// Seed for still-image grain, so a re-edit reproduces the same pattern.
    var grainSeed: UInt32 = 0

    /// The look that was last selected in the UI (purely informational).
    var primaryLook: Look = .film

    static let neutral = StyleRecipe()

    init() {}

    init(look: Look, intensity: Double) {
        primaryLook = look
        setIntensity(intensity, for: look)
    }

    func intensity(for look: Look) -> Double {
        switch look {
        case .toneColor: toneColorIntensity
        case .film: filmIntensity
        case .glow: glowIntensity
        case .softSkin: softSkinIntensity
        case .grain: grainAmount
        }
    }

    mutating func setIntensity(_ value: Double, for look: Look) {
        let v = value.clamped(to: 0...1)
        switch look {
        case .toneColor: toneColorIntensity = v
        case .film: filmIntensity = v
        case .glow: glowIntensity = v
        case .softSkin: softSkinIntensity = v
        case .grain: grainAmount = v
        }
    }

    /// True when the recipe changes nothing.
    var isNeutral: Bool {
        Look.allCases.allSatisfy { intensity(for: $0) <= 0.0001 }
    }

    /// Looks that are switched on, in pipeline order.
    var activeLooks: [Look] {
        [.softSkin, .toneColor, .film, .glow, .grain].filter { intensity(for: $0) > 0.0001 }
    }

    /// A short human-readable summary, e.g. "Film 70%, Grain 30%".
    var summary: String {
        let parts = activeLooks.map { "\($0.displayName) \(Int((intensity(for: $0) * 100).rounded()))%" }
        return parts.isEmpty ? "Original" : parts.joined(separator: ", ")
    }

    /// Clamps every value into range. Used after decoding untrusted data.
    func sanitized() -> StyleRecipe {
        var r = self
        r.tone = tone.clamped(to: -1...1)
        r.color = color.clamped(to: -1...1)
        r.toneColorIntensity = toneColorIntensity.clamped(to: 0...1)
        r.filmIntensity = filmIntensity.clamped(to: 0...1)
        r.glowIntensity = glowIntensity.clamped(to: 0...1)
        r.softSkinIntensity = softSkinIntensity.clamped(to: 0...1)
        r.grainAmount = grainAmount.clamped(to: 0...1)
        r.grainSize = grainSize.clamped(to: 0...1)
        return r
    }

    // MARK: Coding

    enum RecipeError: Error, Equatable {
        case unsupportedVersion(Int)
    }

    private enum CodingKeys: String, CodingKey {
        case version, tone, color, toneColorIntensity, filmIntensity, glowIntensity
        case softSkinIntensity, grainAmount, grainSize, grainSeed, primaryLook
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        guard version >= 1, version <= StyleRecipe.currentVersion else {
            throw RecipeError.unsupportedVersion(version)
        }
        self.version = version
        // Every field other than version is optional so older or partial
        // recipes still open.
        tone = try c.decodeIfPresent(Double.self, forKey: .tone) ?? 0
        color = try c.decodeIfPresent(Double.self, forKey: .color) ?? 0
        toneColorIntensity = try c.decodeIfPresent(Double.self, forKey: .toneColorIntensity) ?? 0
        filmIntensity = try c.decodeIfPresent(Double.self, forKey: .filmIntensity) ?? 0
        glowIntensity = try c.decodeIfPresent(Double.self, forKey: .glowIntensity) ?? 0
        softSkinIntensity = try c.decodeIfPresent(Double.self, forKey: .softSkinIntensity) ?? 0
        grainAmount = try c.decodeIfPresent(Double.self, forKey: .grainAmount) ?? 0
        grainSize = try c.decodeIfPresent(Double.self, forKey: .grainSize) ?? 0.35
        grainSeed = try c.decodeIfPresent(UInt32.self, forKey: .grainSeed) ?? 0
        primaryLook = (try? c.decodeIfPresent(Look.self, forKey: .primaryLook)) ?? .film
        self = sanitized()
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(from data: Data) throws -> StyleRecipe {
        try JSONDecoder().decode(StyleRecipe.self, from: data)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        guard isFinite else { return range.lowerBound }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
