import CoreImage
import Foundation

/// Loads the custom Core Image kernels from the app's `default.metallib`.
/// If loading fails (it shouldn't), each look falls back to built-in filters
/// so the app still works; the unit tests assert that the kernels load.
final class Kernels: @unchecked Sendable {
    static let shared = Kernels()

    let grain: CIColorKernel?
    let highlights: CIColorKernel?
    let screenTint: CIColorKernel?
    let splitTone: CIColorKernel?
    let skinMask: CIColorKernel?
    let mix: CIColorKernel?
    let bilateral: CIKernel?
    let loadError: String?

    var allLoaded: Bool {
        grain != nil && highlights != nil && screenTint != nil && splitTone != nil
            && skinMask != nil && mix != nil && bilateral != nil
    }

    private final class BundleToken {}

    private init() {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "default", withExtension: "metallib")
                ?? Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else {
            grain = nil; highlights = nil; screenTint = nil; splitTone = nil
            skinMask = nil; mix = nil; bilateral = nil
            loadError = "default.metallib not found"
            return
        }
        var errors: [String] = []
        func color(_ name: String) -> CIColorKernel? {
            do { return try CIColorKernel(functionName: name, fromMetalLibraryData: data) }
            catch { errors.append("\(name): \(error)"); return nil }
        }
        grain = color("cam18_grain")
        highlights = color("cam18_highlights")
        screenTint = color("cam18_screenTint")
        splitTone = color("cam18_splitTone")
        skinMask = color("cam18_skinMask")
        mix = color("cam18_mix")
        do {
            bilateral = try CIKernel(functionName: "cam18_bilateral", fromMetalLibraryData: data)
        } catch {
            errors.append("cam18_bilateral: \(error)")
            bilateral = nil
        }
        loadError = errors.isEmpty ? nil : errors.joined(separator: "; ")
    }
}

extension CIImage {
    /// Mixes `self` toward `other` by `amount` (0 keeps self, 1 gives other).
    func mixed(with other: CIImage, amount: Double) -> CIImage {
        let a = amount.clamped(to: 0...1)
        if a <= 0.0001 { return self }
        if a >= 0.9999 { return other.cropped(to: extent) }
        if let k = Kernels.shared.mix,
           let out = k.apply(extent: extent, arguments: [self, other, Float(a)]) {
            return out
        }
        return applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: other,
            kCIInputTimeKey: a,
        ]).cropped(to: extent)
    }

    /// Gaussian blur that doesn't darken edges and keeps the original extent.
    func edgeSafeBlur(radius: Double) -> CIImage {
        guard radius > 0.01 else { return self }
        return clampedToExtent()
            .applyingGaussianBlur(sigma: radius)
            .cropped(to: extent)
    }
}
