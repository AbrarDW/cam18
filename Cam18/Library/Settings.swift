import Foundation

/// User preferences. Views read these through `@AppStorage` with the same keys.
enum AppSettings {
    /// When true, photos are saved as a plain rendered HEIC with the look
    /// baked in. When false (the default), the original is kept and the look
    /// is stored as an editable recipe.
    static let bakeInLookKey = "bakeInLook"
    /// The last recipe used in the camera, as JSON. Includes the aspect ratio.
    static let lastRecipeKey = "lastRecipe"
    static let selectedPanelKey = "selectedPanel"
    static let lensKey = "lens"
    static let showGridKey = "showGrid"
    /// Intensity last used with each colour style, by style raw value.
    static let styleIntensitiesKey = "styleIntensities"

    /// When true (the default), photos are captured as RAW sensor data and
    /// developed by Cam18. When false, the camera's processed photo is used.
    static let captureRAWKey = "captureRAW"

    static var captureRAW: Bool {
        UserDefaults.standard.object(forKey: captureRAWKey) as? Bool ?? true
    }

    static var bakeInLook: Bool {
        get { UserDefaults.standard.bool(forKey: bakeInLookKey) }
        set { UserDefaults.standard.set(newValue, forKey: bakeInLookKey) }
    }

    static func loadLastRecipe(_ defaults: UserDefaults = .standard) -> StyleRecipe {
        guard let data = defaults.data(forKey: lastRecipeKey),
              let recipe = try? StyleRecipe.decode(from: data) else {
            var r = StyleRecipe(look: .film, intensity: 0.6)
            r.tone = 0.2
            r.color = 0.1
            return r
        }
        return recipe
    }

    static func saveLastRecipe(_ recipe: StyleRecipe, _ defaults: UserDefaults = .standard) {
        if let data = try? recipe.encoded() {
            defaults.set(data, forKey: lastRecipeKey)
        }
    }

    // MARK: Colour style memory

    /// Switches `recipe` to `style`. Each style remembers the intensity it was
    /// last used at, so coming back to a style restores it.
    static func select(_ style: ColorStyle, in recipe: inout StyleRecipe, _ defaults: UserDefaults = .standard) {
        guard style != recipe.colorStyle else { return }
        rememberStyleIntensity(of: recipe, defaults)
        let saved = defaults.dictionary(forKey: styleIntensitiesKey) as? [String: Double] ?? [:]
        recipe.colorStyle = style
        let remembered = (saved[style.rawValue] ?? 1).clamped(to: 0...1)
        // A style that was left at zero would look like a dead button.
        recipe.styleIntensity = remembered > 0.02 ? remembered : 1
    }

    static func rememberStyleIntensity(of recipe: StyleRecipe, _ defaults: UserDefaults = .standard) {
        guard recipe.colorStyle != .standard else { return }
        var saved = defaults.dictionary(forKey: styleIntensitiesKey) as? [String: Double] ?? [:]
        saved[recipe.colorStyle.rawValue] = recipe.styleIntensity
        defaults.set(saved, forKey: styleIntensitiesKey)
    }
}
