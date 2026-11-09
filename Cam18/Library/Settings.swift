import Foundation

/// User preferences. Views read these through `@AppStorage` with the same keys.
enum AppSettings {
    /// When true, photos are saved as a plain rendered HEIC with the look
    /// baked in. When false (the default), the original is kept and the look
    /// is stored as an editable recipe.
    static let bakeInLookKey = "bakeInLook"
    /// The last recipe used in the camera, as JSON.
    static let lastRecipeKey = "lastRecipe"
    static let selectedLookKey = "selectedLook"

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
}
