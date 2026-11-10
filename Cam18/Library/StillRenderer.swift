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

    /// Decodes encoded photo data (HEIC/JPEG) into an upright CIImage.
    func uprightImage(from data: Data) throws -> CIImage {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw RenderError.unreadableImage
        }
        return image
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
