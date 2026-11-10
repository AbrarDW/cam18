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

    /// Crops `mask`, which covers the whole of `full`, down to the part that
    /// covers `crop`. Masks can be any size, so this works in proportions.
    static func cropMask(_ mask: CIImage, from full: CGRect, to crop: CGRect) -> CIImage {
        let m = mask.extent
        guard full.width > 0, full.height > 0, !m.isInfinite, crop != full else { return mask }
        let sx = m.width / full.width, sy = m.height / full.height
        return mask.cropped(to: CGRect(x: m.minX + (crop.minX - full.minX) * sx,
                                       y: m.minY + (crop.minY - full.minY) * sy,
                                       width: crop.width * sx, height: crop.height * sy))
    }

    /// Crops to the recipe's aspect ratio, then applies the looks. A cropped
    /// result has its origin at zero; an uncropped one keeps the input's extent.
    /// `options.personMask` always describes the uncropped input.
    static func render(_ input: CIImage, recipe: StyleRecipe, options: RenderOptions = .init()) -> CIImage {
        let recipe = recipe.sanitized()
        let full = input.extent
        guard full.width >= 1, full.height >= 1, !full.isInfinite else { return input }

        var source = input
        var personMask = options.personMask
        let crop = recipe.aspect.cropRect(in: full)
        if crop != full {
            source = input.cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            personMask = personMask.map { cropMask($0, from: full, to: crop) }
        }
        guard recipe.hasLook else {
            return crop == full ? input : source.settingProperties(input.properties)
        }
        let extent = source.extent
        let u = unit(for: extent)

        // Work in perceptual (gamma-encoded) values so tone curves and the
        // kernels' luminance thresholds behave like a photographer expects.
        var image = source.applyingFilter("CILinearToSRGBToneCurve")

        if recipe.softSkinIntensity > 0 {
            image = SoftSkinLook.apply(to: image, intensity: recipe.softSkinIntensity,
                                       personMask: personMask, unit: u)
        }
        if recipe.isStyleActive {
            image = recipe.colorStyle.apply(to: image, intensity: recipe.styleIntensity)
        }
        if recipe.toneColorIntensity > 0 {
            image = ToneColorLook.apply(to: image, tone: recipe.tone, color: recipe.color,
                                        intensity: recipe.toneColorIntensity)
        }
        if recipe.hasAdjustments {
            image = AdjustLook.apply(to: image, recipe: recipe, unit: u)
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
