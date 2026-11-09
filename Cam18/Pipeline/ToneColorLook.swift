import CoreImage

/// The Tone & Color pad: tone (contrast and black level) by color
/// (saturation/vibrance and warmth).
enum ToneColorLook {
    static func apply(to image: CIImage, tone: Double, color: Double, intensity: Double) -> CIImage {
        let t = (tone * intensity).clamped(to: -1...1)
        let c = (color * intensity).clamped(to: -1...1)
        let extent = image.extent
        var out = image

        // Tone: positive = S-curve with deeper blacks; negative = flatter with
        // lifted blacks and softer highlights.
        if abs(t) > 0.001 {
            let black = t < 0 ? -t * 0.10 : 0
            let white = t < 0 ? 1 + t * 0.06 : 1
            let s = t > 0 ? t * 0.07 : t * 0.03
            out = out.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: black),
                "inputPoint1": CIVector(x: 0.25, y: (0.25 - s + black * 0.6).clamped(to: 0...1)),
                "inputPoint2": CIVector(x: 0.5, y: 0.5 + black * 0.25),
                "inputPoint3": CIVector(x: 0.75, y: (0.75 + s).clamped(to: 0...1)),
                "inputPoint4": CIVector(x: 1, y: white),
            ])
        }

        // Color: vibrance + saturation, plus a temperature shift.
        if abs(c) > 0.001 {
            out = out
                .applyingFilter("CIVibrance", parameters: ["inputAmount": c * 0.6])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 1 + c * 0.25,
                    kCIInputBrightnessKey: 0,
                    kCIInputContrastKey: 1,
                ])
            // Warm for positive, cool for negative.
            let r = 1 + c * 0.04, b = 1 - c * 0.05
            out = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            ])
        }
        return out.cropped(to: extent)
    }
}
