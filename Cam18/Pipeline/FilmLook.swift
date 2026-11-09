import CoreImage

/// Film: filmic tone curve (lifted blacks, rolled-off highlights), split
/// toning, light desaturation and halation (bright areas blurred, tinted
/// warm red-orange and blended back).
enum FilmLook {
    static var shadowTint: CIVector { CIVector(x: -0.020, y: 0.012, z: 0.030) }   // teal
    static var highlightTint: CIVector { CIVector(x: 0.035, y: 0.012, z: -0.030) } // warm
    static var halationTint: CIVector { CIVector(x: 1.0, y: 0.38, z: 0.18) }

    static func apply(to image: CIImage, intensity: Double, unit: Double) -> CIImage {
        let extent = image.extent

        // 1. Filmic curve.
        var film = image.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0.06),
            "inputPoint1": CIVector(x: 0.22, y: 0.22),
            "inputPoint2": CIVector(x: 0.5, y: 0.52),
            "inputPoint3": CIVector(x: 0.78, y: 0.80),
            "inputPoint4": CIVector(x: 1, y: 0.94),
        ])

        // 2. Split toning.
        if let k = Kernels.shared.splitTone,
           let toned = k.apply(extent: extent, arguments: [film, shadowTint, highlightTint, Float(1)]) {
            film = toned
        }

        // 3. Light desaturation.
        film = film.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.86,
            kCIInputBrightnessKey: 0,
            kCIInputContrastKey: 1,
        ])

        // 4. Halation from the original highlights.
        film = halation(base: film, source: image, unit: unit, strength: 0.55)

        return image.mixed(with: film.cropped(to: extent), amount: intensity)
    }

    static func halation(base: CIImage, source: CIImage, unit: Double, strength: Double) -> CIImage {
        let extent = base.extent
        let bright: CIImage
        if let k = Kernels.shared.highlights,
           let h = k.apply(extent: extent, arguments: [source, Float(0.72), Float(0.2)]) {
            bright = h
        } else {
            bright = source.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: -0.6, kCIInputContrastKey: 2.5, kCIInputSaturationKey: 1,
            ])
        }
        let glow = bright.edgeSafeBlur(radius: 9 * unit)
        if let k = Kernels.shared.screenTint,
           let out = k.apply(extent: extent, arguments: [base, glow, halationTint, Float(strength)]) {
            return out
        }
        return glow.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: base])
            .cropped(to: extent)
    }
}
