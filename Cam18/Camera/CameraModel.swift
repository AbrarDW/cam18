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

    var recipe: StyleRecipe {
        didSet {
            renderer.setRecipe(recipe)
            AppSettings.saveLastRecipe(recipe)
        }
    }
    var selectedLook: Look {
        didSet {
            recipe.primaryLook = selectedLook
            UserDefaults.standard.set(selectedLook.rawValue, forKey: AppSettings.selectedLookKey)
        }
    }
    var lens: Lens = .wide
    var availableLenses: [Lens] = []
    var status: Status = .idle
    var isCapturing = false
    var isSaving = false
    var shutterFlash = false
    var toast: String?

    init() {
        let recipe = AppSettings.loadLastRecipe()
        self.recipe = recipe
        self.selectedLook = UserDefaults.standard.string(forKey: AppSettings.selectedLookKey)
            .flatMap(Look.init(rawValue:)) ?? recipe.primaryLook
        renderer.setRecipe(recipe)
    }

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
        var recipe = self.recipe
        recipe.grainSeed = UInt32.random(in: 0...UInt32.max)
        let bake = AppSettings.bakeInLook
        let session = self.session

        Task {
            do {
                let data = try await session.capturePhoto(rotationAngle: angle)
                isCapturing = false
                isSaving = true
                defer { isSaving = false }
                _ = try await Task.detached(priority: .userInitiated) {
                    try await PhotoSaver.shared.save(photoData: data, recipe: recipe, bakeInLook: bake)
                }.value
                showToast(bake ? "Saved with look baked in" : "Saved · look editable")
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
