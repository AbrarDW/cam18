@preconcurrency import AVFoundation
import Observation
import SwiftUI

/// UI-facing camera state. Owns the capture session and the preview renderer.
@MainActor
@Observable
final class CameraModel {
    enum Status: Equatable {
        case idle
        case running
        case needsPermission
        case unavailable(String)
    }

    @ObservationIgnored let session = CameraSession()
    @ObservationIgnored let renderer = PreviewRenderer()
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    @ObservationIgnored let presets = PresetStore()

    var recipe: StyleRecipe {
        didSet {
            renderer.setRecipe(recipe)
            AppSettings.saveLastRecipe(recipe)
        }
    }
    /// The section of controls that's selected in the tray.
    var selectedPanel: Panel {
        didSet {
            if let look = selectedPanel.look { recipe.primaryLook = look }
            UserDefaults.standard.set(selectedPanel.rawValue, forKey: AppSettings.selectedPanelKey)
        }
    }
    /// Whether the selected section's sliders are showing.
    var panelOpen = false
    var lens: Lens = .wide {
        didSet { UserDefaults.standard.set(lens.rawValue, forKey: AppSettings.lensKey) }
    }
    var availableLenses: [Lens] = []
    var status: Status = .idle
    var isCapturing = false
    var isSaving = false
    var shutterFlash = false
    var toast: String?
    /// Whether the current lens can capture RAW.
    var rawAvailable = false
    /// The most recent photo taken this session, for the thumbnail button.
    var lastAssetID: String?
    var lastThumbnail: UIImage?

    init() {
        let defaults = UserDefaults.standard
        let recipe = AppSettings.loadLastRecipe()
        self.recipe = recipe
        self.selectedPanel = defaults.string(forKey: AppSettings.selectedPanelKey)
            .flatMap(Panel.init(rawValue:)) ?? .style
        if let saved = defaults.string(forKey: AppSettings.lensKey).flatMap(Lens.init(rawValue:)) {
            lens = saved
        }
        renderer.setRecipe(recipe)
    }

    // MARK: Settings

    func select(style: ColorStyle) {
        var r = recipe
        AppSettings.select(style, in: &r)
        recipe = r
    }

    func apply(_ preset: Preset) {
        var r = preset.recipe
        r.primaryLook = recipe.primaryLook
        recipe = r
    }

    /// Switches off everything in the selected section.
    func resetSelectedPanel() {
        var r = recipe
        selectedPanel.reset(&r)
        recipe = r
    }

    // MARK: Camera

    func start() async {
        guard status != .running else { session.start(); return }
        guard await CameraSession.requestAccess() else {
            status = .needsPermission
            return
        }
        availableLenses = CameraSession.availableLenses
        guard !availableLenses.isEmpty else {
            status = .unavailable("No camera on this device. Use the library button to edit photos.")
            return
        }
        if !availableLenses.contains(lens) { lens = availableLenses.contains(.wide) ? .wide : availableLenses[0] }
        do {
            try await session.configure(lens: lens, delegate: renderer)
            updateRotationCoordinator()
            session.start()
            status = .running
            rawAvailable = await session.supportsRAW()
        } catch {
            status = .unavailable(error.localizedDescription)
        }
    }

    func stop() {
        session.stop()
    }

    func select(lens newLens: Lens) {
        guard newLens != lens, status == .running else { return }
        let previous = lens
        lens = newLens
        renderer.setFrozen(true)
        Task {
            do {
                try await session.switchLens(to: newLens)
            } catch {
                lens = previous
                showToast(error.localizedDescription)
            }
            updateRotationCoordinator()
            rawAvailable = await session.supportsRAW()
            renderer.setFrozen(false)
        }
    }

    private func updateRotationCoordinator() {
        guard let device = lens.device else { rotationCoordinator = nil; return }
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
    }

    func setIntensity(_ value: Double, for look: Look) {
        recipe.setIntensity(value, for: look)
    }

    func capture() {
        guard status == .running, !isCapturing else { return }
        isCapturing = true
        shutterFlash = true
        Task { try? await Task.sleep(for: .milliseconds(120)); shutterFlash = false }

        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        var seeded = self.recipe
        seeded.grainSeed = UInt32.random(in: 0...UInt32.max)
        let recipe = seeded
        let bake = AppSettings.bakeInLook
        let raw = AppSettings.captureRAW && rawAvailable
        let session = self.session

        Task {
            do {
                let data = try await session.capturePhoto(rotationAngle: angle, raw: raw)
                isCapturing = false
                isSaving = true
                defer { isSaving = false }
                let saved = try await Task.detached(priority: .userInitiated) { () -> (String, UncheckedSendable<UIImage?>) in
                    let id = try await PhotoSaver.shared.save(photoData: data, recipe: recipe, bakeInLook: bake)
                    let thumbnail = StillRenderer.shared.thumbnail(from: data, recipe: recipe)
                    return (id, UncheckedSendable(thumbnail))
                }.value
                AppSettings.rememberStyleIntensity(of: recipe)
                lastAssetID = saved.0
                if let thumbnail = saved.1.value { lastThumbnail = thumbnail }
                showToast((raw ? "RAW · " : "") + (bake ? "Saved with look baked in" : "Saved · look editable"))
            } catch {
                isCapturing = false
                showToast(error.localizedDescription)
            }
        }
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { toast = nil }
        }
    }
}
