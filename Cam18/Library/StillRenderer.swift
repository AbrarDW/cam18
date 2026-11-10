import CoreImage
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Renders full-resolution stills through `StylePipeline` and encodes them,
/// keeping the camera's metadata.
final class StillRenderer: @unchecked Sendable {
    static let shared = StillRenderer()

    let context: CIContext

    init(context: CIContext? = nil) {
        self.context = context ?? CIContext(options: [
            .name: "Cam18.stills",
            .cacheIntermediates: false,
            .workingFormat: CIFormat.RGBAh,
        ])
    }

    enum RenderError: LocalizedError {
        case unreadableImage
        case renderFailed
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .unreadableImage: "The photo couldn't be read."
            case .renderFailed: "The look couldn't be rendered."
            case .encodeFailed: "The photo couldn't be encoded."
            }
        }
    }

    /// Decodes photo data into an upright CIImage. RAW (DNG) data is developed
    /// here with noise reduction, sharpening and local tone mapping switched
    /// off; HEIC/JPEG data is decoded as it is.
    func uprightImage(from data: Data) throws -> CIImage {
        if Self.isRAW(data), let filter = CIRAWFilter(imageData: data, identifierHint: nil),
           let image = Self.develop(filter) {
            return image
        }
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw RenderError.unreadableImage
        }
        return image
    }

    /// Loads an image file upright. `orientation` is the EXIF orientation to
    /// apply to a non-RAW file; RAW files carry their own.
    func uprightImage(contentsOf url: URL, orientation: Int32) throws -> CIImage {
        if Self.isRAW(url), let filter = CIRAWFilter(imageURL: url), let image = Self.develop(filter) {
            return image
        }
        guard let image = CIImage(contentsOf: url) else { throw RenderError.unreadableImage }
        return image.oriented(forExifOrientation: orientation)
    }

    /// Cam18's RAW development: demosaic and colour only. Everything Apple
    /// would add to make the picture look "finished" is turned down to zero,
    /// except a little colour-noise cleanup, without which every photo shows
    /// coloured speckles.
    static func develop(_ filter: CIRAWFilter) -> CIImage? {
        if filter.isLuminanceNoiseReductionSupported { filter.luminanceNoiseReductionAmount = 0 }
        if filter.isColorNoiseReductionSupported { filter.colorNoiseReductionAmount = 0.25 }
        if filter.isSharpnessSupported { filter.sharpnessAmount = 0 }
        if filter.isLocalToneMapSupported { filter.localToneMapAmount = 0 }
        filter.extendedDynamicRangeAmount = 0
        guard let image = filter.outputImage, !image.extent.isInfinite, !image.extent.isEmpty else { return nil }
        // Later stages expect the origin at zero.
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    static func isRAW(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return isRAW(source)
    }

    static func isRAW(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return isRAW(source)
    }

    private static func isRAW(_ source: CGImageSource) -> Bool {
        guard let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier) else { return false }
        return type.conforms(to: .rawImage)
    }

    /// Runs the pipeline at full resolution, computing a person mask first
    /// when Soft Skin is on.
    func render(_ upright: CIImage, recipe: StyleRecipe) -> CIImage {
        var options = RenderOptions(isPreview: false)
        if recipe.softSkinIntensity > 0 {
            options.personMask = PersonSegmenter.mask(for: upright, quality: .accurate, context: context)
        }
        return StylePipeline.render(upright, recipe: recipe, options: options)
    }

    /// Encodes `image` with the given metadata. Orientation is reset to "up"
    /// because the pixels are already upright. Adds the look to the metadata.
    func encode(_ image: CIImage, type: UTType = .heic, metadata: [String: Any], recipe: StyleRecipe?,
                quality: Double = 0.9) throws -> Data {
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.displayP3)!
        guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw RenderError.renderFailed
        }
        let props = Self.outputMetadata(from: metadata, recipe: recipe, quality: quality)
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else {
            throw RenderError.encodeFailed
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.encodeFailed }
        return out as Data
    }

    static func outputMetadata(from metadata: [String: Any], recipe: StyleRecipe?, quality: Double) -> [String: Any] {
        var props = metadata
        // Pixel geometry is decided by the encoder.
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                    kCGImagePropertyColorModel, kCGImagePropertyProfileName] {
            props.removeValue(forKey: key as String)
        }
        props[kCGImagePropertyOrientation as String] = 1
        var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        tiff[kCGImagePropertyTIFFSoftware as String] = "Cam18"
        props[kCGImagePropertyTIFFDictionary as String] = tiff
        if let recipe, !recipe.isNeutral {
            var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            exif[kCGImagePropertyExifUserComment as String] = "Cam18 look: \(recipe.summary)"
            props[kCGImagePropertyExifDictionary as String] = exif
        }
        props[kCGImageDestinationLossyCompressionQuality as String] = quality
        return props
    }

    /// A small styled, upright thumbnail of a captured photo for the camera UI.
    func thumbnail(from data: Data, recipe: StyleRecipe, maxPixelSize: Int = 240) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let styled = StylePipeline.render(CIImage(cgImage: small), recipe: recipe)
        guard let cg = context.createCGImage(styled, from: styled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Reads the metadata dictionary from encoded image data.
    static func metadata(of data: Data) -> [String: Any] {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else {
            return [:]
        }
        return props
    }
}
