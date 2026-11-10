import CoreImage
import Foundation

/// The fine adjustments in the Adjust section. Every one runs from −1 to +1
/// with 0 meaning "no change".
enum Adjustment: String, CaseIterable, Identifiable, Sendable {
    case exposure, contrast, highlights, shadows, fade
    case saturation, warmth, tint
    case vignette, sharpness

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .exposure: "Exposure"
        case .contrast: "Contrast"
        case .highlights: "Highlights"
        case .shadows: "Shadows"
        case .fade: "Fade"
        case .saturation: "Saturation"
        case .warmth: "Warmth"
        case .tint: "Tint"
        case .vignette: "Vignette"
        case .sharpness: "Sharpness"
        }
    }

    enum Group: String, CaseIterable, Identifiable, Sendable {
        case light = "Light", color = "Colour", finish = "Finish"
        var id: String { rawValue }
        var adjustments: [Adjustment] {
            switch self {
            case .light: [.exposure, .contrast, .highlights, .shadows, .fade]
            case .color: [.saturation, .warmth, .tint]
            case .finish: [.vignette, .sharpness]
            }
        }
    }
}

/// Renders the Adjust section. Works on perceptual (sRGB-gamma) values.
enum AdjustLook {
    static func apply(to image: CIImage, recipe: StyleRecipe, unit: Double) -> CIImage {
        let extent = image.extent
        var out = image
        func value(_ a: Adjustment) -> Double { recipe.adjustment(a) }
        func isSet(_ a: Adjustment) -> Bool { abs(value(a)) > 0.001 }

        // Exposure: ±1 is about one stop (a linear gain, expressed in gamma space).
        if isSet(.exposure) {
            let g = pow(pow(2.0, value(.exposure)), 1 / 2.2)
            out = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: g, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: g, w: 0),
            ])
        }

        // Highlights, shadows and fade share one tone curve.
        if isSet(.highlights) || isSet(.shadows) || isSet(.fade) {
            let h = value(.highlights), s = value(.shadows), f = value(.fade)
            let black = max(f, 0) * 0.12
            let crush = min(f, 0) * 0.05
            out = out.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: black),
                "inputPoint1": CIVector(x: 0.25, y: (0.25 + s * 0.09 + black * 0.6 + crush).clamped(to: 0...1)),
                "inputPoint2": CIVector(x: 0.5, y: 0.5 + s * 0.02 + h * 0.02 + black * 0.25),
                "inputPoint3": CIVector(x: 0.75, y: (0.75 + h * 0.09).clamped(to: 0...1)),
                "inputPoint4": CIVector(x: 1, y: 1 + min(h, 0) * 0.05),
            ])
        }

        if isSet(.contrast) || isSet(.saturation) {
            let s = value(.saturation)
            out = out.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1 + (s > 0 ? s * 0.6 : s),
                kCIInputBrightnessKey: 0,
                kCIInputContrastKey: 1 + value(.contrast) * 0.35,
            ])
        }

        // Warmth: amber ↔ blue. Tint: magenta ↔ green.
        if isSet(.warmth) || isSet(.tint) {
            let w = value(.warmth), t = value(.tint)
            out = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 + w * 0.10 + t * 0.03, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 - t * 0.08, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - w * 0.12 + t * 0.03, w: 0),
            ])
        }

        if isSet(.sharpness) {
            let s = value(.sharpness)
            if s > 0 {
                out = out.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
                    kCIInputRadiusKey: 1.4 * unit,
                    kCIInputIntensityKey: s * 0.9,
                ]).cropped(to: extent)
            } else {
                out = out.cropped(to: extent).edgeSafeBlur(radius: -s * 2.2 * unit)
            }
        }

        // Vignette: positive darkens the corners, negative lightens them.
        if isSet(.vignette) {
            let v = value(.vignette)
            let half = Double(hypot(extent.width, extent.height)) / 2
            let edge = abs(v) * 0.6
            let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                "inputRadius0": 0.45 * half,
                "inputRadius1": half,
                "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 1),
                "inputColor1": CIColor(red: edge, green: edge, blue: edge, alpha: 1),
            ])?.outputImage
            guard let mask = gradient?.cropped(to: extent) else { return out.cropped(to: extent) }
            let target = CIImage(color: v > 0 ? .black : .white).cropped(to: extent)
            out = target.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: out.cropped(to: extent),
                kCIInputMaskImageKey: mask,
            ])
        }
        return out.cropped(to: extent)
    }
}
