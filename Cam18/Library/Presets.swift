import Foundation
import Observation

/// A named set of settings: colour style, looks, adjustments and aspect ratio.
struct Preset: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var recipe: StyleRecipe
}

/// The saved presets, kept as JSON in user defaults. A few starters are
/// installed the first time the app runs.
@MainActor
@Observable
final class PresetStore {
    static let key = "presets"
    static let maxNameLength = 24

    private(set) var presets: [Preset]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Preset].self, from: data) {
            presets = saved
        } else {
            presets = Self.starters
            persist()
        }
    }

    /// The preset whose settings equal `recipe`, if any.
    func preset(matching recipe: StyleRecipe) -> Preset? {
        presets.first { $0.recipe.matches(recipe) }
    }

    @discardableResult
    func add(name: String, recipe: StyleRecipe) -> Preset {
        let preset = Preset(name: Self.cleaned(name), recipe: Self.stored(recipe))
        presets.append(preset)
        persist()
        return preset
    }

    func rename(_ id: Preset.ID, to name: String) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].name = Self.cleaned(name)
        persist()
    }

    /// Replaces a preset's settings with `recipe`, keeping its name.
    func update(_ id: Preset.ID, recipe: StyleRecipe) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].recipe = Self.stored(recipe)
        persist()
    }

    func delete(_ id: Preset.ID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: Self.key)
        }
    }

    static func cleaned(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "My preset" : String(trimmed.prefix(maxNameLength))
    }

    /// Presets don't keep the per-photo grain seed.
    private static func stored(_ recipe: StyleRecipe) -> StyleRecipe {
        var r = recipe.sanitized()
        r.grainSeed = 0
        r.version = StyleRecipe.currentVersion
        return r
    }

    static var starters: [Preset] {
        var golden = StyleRecipe()
        golden.colorStyle = .warmGold
        golden.styleIntensity = 0.8
        golden.glowIntensity = 0.25

        var film = StyleRecipe(look: .film, intensity: 0.7)
        film.grainAmount = 0.3
        film.aspect = .r3x2

        var portrait = StyleRecipe(look: .softSkin, intensity: 0.6)
        portrait.colorStyle = .rose
        portrait.styleIntensity = 0.6
        portrait.glowIntensity = 0.2

        var mono = StyleRecipe(look: .grain, intensity: 0.5)
        mono.colorStyle = .monoContrast

        return [
            Preset(name: "Golden Hour", recipe: golden),
            Preset(name: "Classic Film", recipe: film),
            Preset(name: "Soft Portrait", recipe: portrait),
            Preset(name: "Mono Grain", recipe: mono),
        ]
    }
}
