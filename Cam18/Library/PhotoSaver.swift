import CoreImage
import Foundation
import Photos
import UniformTypeIdentifiers

/// Carries a non-Sendable value across a `@Sendable` boundary when we know
/// it's only touched by one party at a time.
struct UncheckedSendable<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Saves photos through PhotoKit in one of two ways:
/// Photos arrive either as RAW (DNG, the sensor data with none of Apple's
/// processing) or as the camera's processed HEIC.
/// - **Editable** (default): the untouched original is saved, then an edit is
///   applied with the rendered look and the JSON recipe as `PHAdjustmentData`.
///   Cam18 can reopen the recipe, and Revert in Photos restores the original.
/// - **Baked**: a single rendered HEIC with camera EXIF and the look name. No
///   original and no recipe are kept.
final class PhotoSaver: @unchecked Sendable {
    static let shared = PhotoSaver()

    private let renderer: StillRenderer
    private let library: PHPhotoLibrary

    init(renderer: StillRenderer = .shared, library: PHPhotoLibrary = .shared()) {
        self.renderer = renderer
        self.library = library
    }

    enum SaveError: LocalizedError {
        case notAuthorized
        case assetMissing
        case editingInputUnavailable

        var errorDescription: String? {
            switch self {
            case .notAuthorized: "Cam18 needs access to your photo library. You can allow it in Settings."
            case .assetMissing: "The saved photo couldn't be found."
            case .editingInputUnavailable: "The photo couldn't be opened for editing."
            }
        }
    }

    // MARK: Authorization

    static func ensureAuthorized() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else { throw SaveError.notAuthorized }
    }

    // MARK: Saving new photos

    /// Saves a captured photo. Returns the new asset's local identifier.
    @discardableResult
    func save(photoData: Data, recipe: StyleRecipe, bakeInLook: Bool) async throws -> String {
        try await Self.ensureAuthorized()
        if bakeInLook {
            return try await saveBaked(photoData: photoData, recipe: recipe)
        } else {
            return try await saveEditable(photoData: photoData, recipe: recipe)
        }
    }

    func saveBaked(photoData: Data, recipe: StyleRecipe) async throws -> String {
        let upright = try renderer.uprightImage(from: photoData)
        let rendered = renderer.render(upright, recipe: recipe)
        let metadata = StillRenderer.metadata(of: photoData)
        let heic = try renderer.encode(rendered, type: .heic, metadata: metadata, recipe: recipe)
        return try await createAsset(data: heic)
    }

    func saveEditable(photoData: Data, recipe: StyleRecipe) async throws -> String {
        let identifier = try await createAsset(data: photoData)
        // A RAW original always gets Cam18's rendering on top, even with no
        // look, so Photos shows our development instead of its own.
        guard !recipe.isNeutral || StillRenderer.isRAW(photoData) else { return identifier }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw SaveError.assetMissing
        }
        try await applyEdit(to: asset, recipe: recipe)
        return identifier
    }

    private func createAsset(data: Data) async throws -> String {
        let holder = IdentifierHolder()
        try await library.performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
            holder.set(request.placeholderForCreatedAsset?.localIdentifier)
        }
        guard let id = holder.get() else { throw SaveError.assetMissing }
        return id
    }

    // MARK: Editing

    static func canHandle(_ adjustment: PHAdjustmentData) -> Bool {
        adjustment.formatIdentifier == StyleRecipe.formatIdentifier
            && adjustment.formatVersion == StyleRecipe.formatVersion
    }

    /// Loads the original image (if Cam18 made the current edit) or the current
    /// rendition (otherwise), plus the saved recipe if there is one.
    func loadForEditing(_ asset: PHAsset) async throws -> (image: CIImage, recipe: StyleRecipe?) {
        let input = try await contentEditingInput(for: asset)
        guard let url = input.value.fullSizeImageURL,
              let image = try? renderer.uprightImage(contentsOf: url,
                                                     orientation: input.value.fullSizeImageOrientation) else {
            throw SaveError.editingInputUnavailable
        }
        var recipe: StyleRecipe?
        if let adj = input.value.adjustmentData, Self.canHandle(adj) {
            recipe = try? StyleRecipe.decode(from: adj.data)
        }
        return (image, recipe)
    }

    /// Applies (or replaces) a Cam18 edit on an asset. A neutral recipe reverts
    /// the asset to its original instead.
    func applyEdit(to asset: PHAsset, recipe: StyleRecipe) async throws {
        try await Self.ensureAuthorized()
        let input = try await contentEditingInput(for: asset)
        let isRAW = input.value.fullSizeImageURL.map { StillRenderer.isRAW($0) } ?? false
        if recipe.isNeutral && !isRAW {
            try await revertToOriginal(asset)
            return
        }
        guard let url = input.value.fullSizeImageURL,
              let upright = try? renderer.uprightImage(contentsOf: url,
                                                       orientation: input.value.fullSizeImageOrientation) else {
            throw SaveError.editingInputUnavailable
        }
        let metadata = (try? Data(contentsOf: url)).map(StillRenderer.metadata(of:)) ?? upright.properties
        let rendered = renderer.render(upright, recipe: recipe)

        let output = PHContentEditingOutput(contentEditingInput: input.value)
        let type: UTType = output.supportedRenderedContentTypes.contains(.heic) ? .heic : .jpeg
        let data = try renderer.encode(rendered, type: type, metadata: metadata, recipe: recipe)
        let renderedURL = try output.renderedContentURL(for: type)
        try data.write(to: renderedURL, options: .atomic)
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: StyleRecipe.formatIdentifier,
            formatVersion: StyleRecipe.formatVersion,
            data: try recipe.encoded()
        )

        let boxedOutput = UncheckedSendable(output)
        let boxedAsset = UncheckedSendable(asset)
        try await library.performChanges {
            let request = PHAssetChangeRequest(for: boxedAsset.value)
            request.contentEditingOutput = boxedOutput.value
        }
    }

    func revertToOriginal(_ asset: PHAsset) async throws {
        let boxedAsset = UncheckedSendable(asset)
        try await library.performChanges {
            PHAssetChangeRequest(for: boxedAsset.value).revertAssetContentToOriginal()
        }
    }

    private func contentEditingInput(for asset: PHAsset) async throws -> UncheckedSendable<PHContentEditingInput> {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        options.canHandleAdjustmentData = { PhotoSaver.canHandle($0) }
        let result: UncheckedSendable<PHContentEditingInput>? = await withCheckedContinuation { cont in
            asset.requestContentEditingInput(with: options) { input, _ in
                cont.resume(returning: input.map { UncheckedSendable($0) })
            }
        }
        guard let result else { throw SaveError.editingInputUnavailable }
        return result
    }
}

/// Thread-safe holder for the identifier produced inside a change block.
private final class IdentifierHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ v: String?) { lock.lock(); value = v; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}
