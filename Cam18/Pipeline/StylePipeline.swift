import CoreImage
import Foundation

/// Per-render inputs that aren't part of the saved recipe.
struct RenderOptions: @unchecked Sendable {
    /// Preview renders animate grain; stills use the recipe's seed.
    var isPreview: Bool = false
    /// Frame counter used to animate preview grain.
    var frameIndex: UInt64 = 0
    /// Person segmentation mask (white = person) in any size; it's stretched to
    /// the image. `nil` means "not available", and Soft Skin then uses the
    /// skin-tone mask alone.
    var personMask: CIImage?

    init(isPreview: Bool = false, frameIndex: UInt64 = 0, personMask: CIImage? = nil) {
        self.isPreview = isPreview
        self.frameIndex = frameIndex
        self.personMask = personMask
    }
}

/// Turns a recipe and an image into the styled image. The same code renders
/// the live preview (at reduced resolution) and full-resolution stills; every
/// spatial parameter is expressed relative to the image size so both match.
enum StylePipeline {
    /// Size-relative unit: 1 unit = 1/1000 of the image's short side.
    static func unit(for extent: CGRect) -> Double {
        max(Double(min(extent.width, extent.height)) / 1000.0, 0.05)
    }

    static func render(_ input: CIImage, recipe: StyleRecipe, options: RenderOptions = .init()) -> CIImage {
        let recipe = recipe.sanitized()
        let extent = input.extent
        guard !recipe.isNeutral, extent.width >= 1, extent.height >= 1, !extent.isInfinite else {
            return input
        }
        let u = unit(for: extent)

        // Work in perceptual (gamma-encoded) values so tone curves and the
        // kernels' luminance thresholds behave like a photographer expects.
        var image = input.applyingFilter("CILinearToSRGBToneCurve")

        if recipe.softSkinIntensity > 0 {
            image = SoftSkinLook.apply(to: image, intensity: recipe.softSkinIntensity,
                                       personMask: options.personMask, unit: u)
        }
        if recipe.toneColorIntensity > 0 {
            image = ToneColorLook.apply(to: image, tone: recipe.tone, color: recipe.color,
                                        intensity: recipe.toneColorIntensity)
        }
        if recipe.filmIntensity > 0 {
            image = FilmLook.apply(to: image, intensity: recipe.filmIntensity, unit: u)
        }
        if recipe.glowIntensity > 0 {
            image = GlowLook.apply(to: image, intensity: recipe.glowIntensity, unit: u)
        }
        if recipe.grainAmount > 0 {
            let seed: UInt32 = options.isPreview
                ? UInt32(truncatingIfNeeded: options.frameIndex &* 2_654_435_761)
                : recipe.grainSeed
            image = Grain.apply(to: image, amount: recipe.grainAmount, size: recipe.grainSize,
                                seed: seed, unit: u)
        }

        // Vibrance, color matrices and screen blends can overshoot slightly;
        // keep the result in SDR range so it clips the same everywhere.
        return image
            .applyingFilter("CIColorClamp")
            .applyingFilter("CISRGBToneCurveToLinear")
            .cropped(to: extent)
            .settingProperties(input.properties)
    }
}
