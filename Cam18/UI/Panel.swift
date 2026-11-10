import Foundation

/// A section of controls in the tray: the colour style, the fine adjustments,
/// or one of the looks.
enum Panel: String, CaseIterable, Identifiable, Sendable {
    case style, adjust, film, glow, softSkin, grain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .style: "Style"
        case .adjust: "Adjust"
        case .film: "Film"
        case .glow: "Glow"
        case .softSkin: "Soft Skin"
        case .grain: "Grain"
        }
    }

    var symbolName: String {
        switch self {
        case .style: "swatchpalette"
        case .adjust: "slider.horizontal.3"
        case .film: Look.film.symbolName
        case .glow: Look.glow.symbolName
        case .softSkin: Look.softSkin.symbolName
        case .grain: Look.grain.symbolName
        }
    }

    /// The single look this section controls, if it is one.
    var look: Look? {
        switch self {
        case .style: .toneColor
        case .adjust: nil
        case .film: .film
        case .glow: .glow
        case .softSkin: .softSkin
        case .grain: .grain
        }
    }

    /// True when something in this section is switched on.
    func isActive(in recipe: StyleRecipe) -> Bool {
        switch self {
        case .style: recipe.isStyleActive || recipe.toneColorIntensity > 0.0001
        case .adjust: recipe.hasAdjustments
        case .film: recipe.filmIntensity > 0.0001
        case .glow: recipe.glowIntensity > 0.0001
        case .softSkin: recipe.softSkinIntensity > 0.0001
        case .grain: recipe.grainAmount > 0.0001
        }
    }

    /// Switches off everything in this section.
    func reset(_ recipe: inout StyleRecipe) {
        switch self {
        case .style:
            recipe.colorStyle = .standard
            recipe.styleIntensity = 1
            recipe.tone = 0
            recipe.color = 0
            recipe.toneColorIntensity = 0
        case .adjust:
            recipe.resetAdjustments()
        case .film, .glow, .softSkin, .grain:
            if let look { recipe.setIntensity(0, for: look) }
        }
    }
}
