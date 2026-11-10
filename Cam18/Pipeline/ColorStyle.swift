import CoreImage
import Foundation
import simd

/// A colour style: a base colour rendering picked from a strip, like choosing
/// a film stock. Each style is a 3-D lookup table (LUT) generated in code from
/// a handful of parameters, so there are no LUT files to ship.
enum ColorStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case warmGold, amber, rose, coolBlue, tealOrange
    case vivid, faded, moody, pastel
    case mono, monoContrast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: "Standard"
        case .warmGold: "Warm Gold"
        case .amber: "Amber"
        case .rose: "Rose"
        case .coolBlue: "Cool Blue"
        case .tealOrange: "Teal & Orange"
        case .vivid: "Vivid"
        case .faded: "Faded"
        case .moody: "Moody"
        case .pastel: "Pastel"
        case .mono: "Mono"
        case .monoContrast: "Mono Contrast"
        }
    }

    /// The numbers that define a style. All values are in perceptual
    /// (sRGB-gamma) space, where the pipeline applies looks.
    struct Parameters: Sendable {
        /// Added to the shadows / highlights.
        var shadow = SIMD3<Double>(0, 0, 0)
        var highlight = SIMD3<Double>(0, 0, 0)
        /// Per-channel gain (white balance and overall brightness).
        var gain = SIMD3<Double>(1, 1, 1)
        var saturation = 1.0
        /// S-curve strength, −0.4 (flat) ... 0.4 (punchy).
        var contrast = 0.0
        /// Black lift, 0 ... 0.2.
        var fade = 0.0
        var mono = false
    }

    var parameters: Parameters {
        switch self {
        case .standard:
            Parameters()
        case .warmGold:
            Parameters(shadow: .init(0.010, 0.000, -0.010), highlight: .init(0.030, 0.015, -0.030),
                       gain: .init(1.05, 1.00, 0.90), saturation: 1.05, contrast: 0.05)
        case .amber:
            Parameters(shadow: .init(0.020, 0.005, -0.020), highlight: .init(0.040, 0.010, -0.040),
                       gain: .init(1.08, 0.99, 0.84), saturation: 0.95, contrast: 0.08, fade: 0.02)
        case .rose:
            Parameters(shadow: .init(0.015, -0.010, 0.015), highlight: .init(0.030, -0.005, 0.010),
                       gain: .init(1.05, 0.97, 0.99), saturation: 0.97, fade: 0.03)
        case .coolBlue:
            Parameters(shadow: .init(-0.020, 0.000, 0.030), highlight: .init(-0.010, 0.005, 0.020),
                       gain: .init(0.93, 1.00, 1.07), saturation: 0.95, contrast: 0.05)
        case .tealOrange:
            Parameters(shadow: .init(-0.040, 0.015, 0.035), highlight: .init(0.050, 0.015, -0.040),
                       saturation: 1.08, contrast: 0.12)
        case .vivid:
            Parameters(saturation: 1.35, contrast: 0.18)
        case .faded:
            Parameters(highlight: .init(0.010, 0.005, -0.010), saturation: 0.75, contrast: -0.15, fade: 0.10)
        case .moody:
            Parameters(shadow: .init(-0.010, 0.000, 0.015), gain: .init(0.93, 0.93, 0.93),
                       saturation: 0.70, contrast: 0.25, fade: 0.02)
        case .pastel:
            Parameters(highlight: .init(0.020, 0.000, 0.020), gain: .init(1.03, 1.03, 1.03),
                       saturation: 0.80, contrast: -0.20, fade: 0.07)
        case .mono:
            Parameters(contrast: 0.05, mono: true)
        case .monoContrast:
            Parameters(contrast: 0.35, mono: true)
        }
    }

    /// Maps one perceptual RGB colour (0...1) through the style.
    func map(_ input: SIMD3<Double>) -> SIMD3<Double> {
        typealias V = SIMD3<Double>
        let zero = V(repeating: 0), one = V(repeating: 1), half = V(repeating: 0.5)
        let p = parameters
        var c: V = simd_clamp(input, zero, one) * p.gain

        let grey = V(repeating: ColorStyle.luma(c))
        if p.mono {
            c = grey
        } else {
            c = grey + (c - grey) * p.saturation
        }
        c = simd_clamp(c, zero, one)

        // S-curve around the midpoint; stays monotonic for |contrast| < 0.5.
        let bend: V = (c - half) * c * (one - c)
        c = c + bend * (p.contrast * 4)

        // Lift the blacks without moving white.
        let inv: V = one - c
        c = c + inv * inv * p.fade

        if !p.mono {
            let l = ColorStyle.luma(c)
            let sw = 1 - ColorStyle.smoothstep(0, 0.55, l)
            let hw = ColorStyle.smoothstep(0.45, 1, l)
            c = c + p.shadow * sw + p.highlight * hw
        }
        return simd_clamp(c, zero, one)
    }

    /// A representative colour for the style's chip in the UI: what the style
    /// does to a warm mid-grey.
    var swatch: SIMD3<Double> { map(.init(0.62, 0.50, 0.42)) }

    // MARK: Lookup tables

    static let cubeDimension = 32

    /// Float RGBA cube data for `CIColorCube`, red varying fastest.
    func makeCubeData() -> Data {
        let n = ColorStyle.cubeDimension
        var values = [Float](repeating: 1, count: n * n * n * 4)
        let scale = 1.0 / Double(n - 1)
        var i = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let out = map(.init(Double(r) * scale, Double(g) * scale, Double(b) * scale))
                    values[i] = Float(out.x)
                    values[i + 1] = Float(out.y)
                    values[i + 2] = Float(out.z)
                    values[i + 3] = 1
                    i += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static let cubes: [ColorStyle: Data] = {
        var result: [ColorStyle: Data] = [:]
        for style in ColorStyle.allCases where style != .standard {
            result[style] = style.makeCubeData()
        }
        return result
    }()

    /// Applies the style to a perceptual-space image, mixed in by `intensity`.
    func apply(to image: CIImage, intensity: Double) -> CIImage {
        guard self != .standard, intensity > 0.0001, let data = ColorStyle.cubes[self] else { return image }
        let styled = image.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": ColorStyle.cubeDimension,
            "inputCubeData": data,
        ]).cropped(to: image.extent)
        return image.mixed(with: styled, amount: intensity)
    }

    // MARK: Helpers

    private static func luma(_ c: SIMD3<Double>) -> Double {
        simd_dot(c, .init(0.2126, 0.7152, 0.0722))
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = ((x - a) / (b - a)).clamped(to: 0...1)
        return t * t * (3 - 2 * t)
    }
}
