import CoreImage

/// Film grain: animated in the preview, seeded for stills, strongest in the
/// midtones. `size` 0...1 maps to a cell size relative to the image.
enum Grain {
    /// Cell size in size-relative units (1/1000 of the short side).
    static func cellSize(for size: Double, unit: Double) -> Double {
        (0.6 + size.clamped(to: 0...1) * 2.4) * unit
    }

    static func apply(to image: CIImage, amount: Double, size: Double, seed: UInt32, unit: Double) -> CIImage {
        let extent = image.extent
        let cell = cellSize(for: size, unit: unit)
        // Keep the seed in a range a float represents exactly.
        let seedValue = Float(seed % 4096)
        if let k = Kernels.shared.grain,
           let out = k.apply(extent: extent, arguments: [image, Float(amount), Float(cell), seedValue]) {
            return out
        }
        // Fallback: Core Image random noise, scaled and overlaid.
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .transformed(by: CGAffineTransform(translationX: CGFloat(seed % 997), y: CGFloat(seed % 991))
                .scaledBy(x: max(cell, 1), y: max(cell, 1)))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount * 0.18)),
            ])
            .cropped(to: extent)
        return noise.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
            .cropped(to: extent)
    }
}
