import CoreImage

/// Soft Skin: edge-preserving smoothing applied only where a skin-tone mask
/// and Vision's person segmentation agree, so eyes, hair and the background
/// stay sharp.
enum SoftSkinLook {
    static func apply(to image: CIImage, intensity: Double, personMask: CIImage?, unit: Double) -> CIImage {
        let extent = image.extent
        let mask = skinMask(for: image, personMask: personMask, unit: unit)

        let radius = 6 * unit
        let smoothed: CIImage
        if let k = Kernels.shared.bilateral,
           let s = k.apply(extent: extent,
                           roiCallback: { _, rect in rect.insetBy(dx: -radius - 2, dy: -radius - 2) },
                           arguments: [image.clampedToExtent(), Float(radius), Float(0.09)]) {
            smoothed = s.cropped(to: extent)
        } else {
            smoothed = image.edgeSafeBlur(radius: radius * 0.5)
        }
        // A touch of brightness lift on skin, as soft light would give.
        let lifted = smoothed.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: 0.012, kCIInputContrastKey: 0.97, kCIInputSaturationKey: 0.98,
        ])

        let masked = lifted.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask,
        ]).cropped(to: extent)
        return image.mixed(with: masked, amount: intensity)
    }

    /// The combined mask (white = smooth here), at the image's extent.
    static func skinMask(for image: CIImage, personMask: CIImage?, unit: Double) -> CIImage {
        let extent = image.extent
        let person: CIImage
        if let personMask, personMask.extent.width > 0, personMask.extent.height > 0 {
            person = scaled(personMask, to: extent).edgeSafeBlur(radius: 2 * unit)
        } else {
            person = CIImage(color: .white).cropped(to: extent)
        }
        if let k = Kernels.shared.skinMask,
           let m = k.apply(extent: extent, arguments: [image, person]) {
            // Feather so the transition into skin is invisible.
            return m.edgeSafeBlur(radius: 3 * unit)
        }
        return person
    }

    static func scaled(_ mask: CIImage, to extent: CGRect) -> CIImage {
        let m = mask.extent
        let t = CGAffineTransform(translationX: -m.minX, y: -m.minY)
            .concatenating(CGAffineTransform(scaleX: extent.width / m.width, y: extent.height / m.height))
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return mask.samplingLinear().transformed(by: t).cropped(to: extent)
    }
}
