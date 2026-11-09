import CoreImage

/// Glow: soft highlight threshold, a large blur, screen-blended back, plus a
/// slight overall soften.
enum GlowLook {
    static var neutralTint: CIVector { CIVector(x: 1.0, y: 0.97, z: 0.92) }

    static func apply(to image: CIImage, intensity: Double, unit: Double) -> CIImage {
        let extent = image.extent

        // Slight overall soften.
        let softened = image.mixed(with: image.edgeSafeBlur(radius: 1.6 * unit), amount: 0.35)

        let bright: CIImage
        if let k = Kernels.shared.highlights,
           let h = k.apply(extent: extent, arguments: [image, Float(0.55), Float(0.35)]) {
            bright = h
        } else {
            bright = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: -0.4, kCIInputContrastKey: 1.8, kCIInputSaturationKey: 1,
            ])
        }
        // Two blur sizes: a tight bloom and a wide haze.
        let near = bright.edgeSafeBlur(radius: 8 * unit)
        let far = bright.edgeSafeBlur(radius: 30 * unit)
        let bloom = near.mixed(with: far, amount: 0.55)

        var out = softened
        if let k = Kernels.shared.screenTint,
           let o = k.apply(extent: extent, arguments: [softened, bloom, neutralTint, Float(0.9)]) {
            out = o
        } else {
            out = bloom.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: softened])
        }
        return image.mixed(with: out.cropped(to: extent), amount: intensity)
    }
}
