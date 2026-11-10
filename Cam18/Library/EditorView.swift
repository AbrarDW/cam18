import CoreImage
import Photos
import SwiftUI

/// Reopens a photo from the library and lets you change or remove its look
/// and its aspect ratio.
/// For photos Cam18 saved in editable mode, this starts from the untouched
/// original and the saved recipe.
struct EditorView: View {
    let localIdentifier: String

    @Environment(\.dismiss) private var dismiss
    @State private var asset: PHAsset?
    @State private var original: CIImage?      // full resolution, upright
    @State private var proxy: CIImage?         // downscaled for the on-screen preview
    @State private var personMask: CIImage?
    @State private var recipe = StyleRecipe.neutral
    @State private var hadCam18Edit = false
    @State private var panel: Panel = .style
    @State private var panelOpen = true
    @State private var rendered: UIImage?
    @State private var renderTask: Task<Void, Never>?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showOriginal = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                ZStack {
                    Color.black
                    if let rendered {
                        Image(uiImage: rendered).resizable().scaledToFit()
                    } else if errorMessage == nil {
                        ProgressView()
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.secondary).padding()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onLongPressGesture(minimumDuration: 0.1, maximumDistance: 40) {} onPressingChanged: { pressing in
                    showOriginal = pressing
                    scheduleRender()
                }
                .accessibilityHint("Touch and hold to compare with the original")

                if original != nil, !hadCam18Edit {
                    Label("This photo has no saved Cam18 look (it was baked in, or taken elsewhere), so changes go on top of what you see.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Picker("Aspect ratio", selection: $recipe.aspect) {
                    ForEach(AspectRatio.allCases) { ratio in
                        Text(ratio == .full ? "Full" : ratio.label).tag(ratio)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                if panelOpen {
                    PanelControls(panel: panel, recipe: $recipe) { style in
                        AppSettings.select(style, in: &recipe)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .glassCard()
                    .padding(.horizontal, 10)
                }
                PanelPicker(selected: $panel, isOpen: $panelOpen, recipe: recipe)
                    .padding(.bottom, 8)
            }
            .background(Color.black)
            .navigationTitle("Edit Look")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(original == nil || isSaving)
                }
                ToolbarItem(placement: .bottomBar) {
                    if hadCam18Edit || !recipe.isNeutral {
                        Button("Remove Look", role: .destructive) {
                            // Keep the crop: it's a framing choice, not part of the look.
                            var cleared = StyleRecipe.neutral
                            cleared.aspect = recipe.aspect
                            recipe = cleared
                        }
                    }
                }
            }
            .overlay { if isSaving { ProgressView("Saving…").padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        }
        .task { await load() }
        .onChange(of: recipe) { _, _ in scheduleRender() }
        .onChange(of: panel) { _, panel in
            if let look = panel.look { recipe.primaryLook = look }
        }
    }

    // MARK: Loading and rendering

    private func load() async {
        do {
            try await PhotoSaver.ensureAuthorized()
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
                errorMessage = "This photo isn't available."
                return
            }
            self.asset = asset
            let boxedAsset = UncheckedSendable(asset)
            let loaded = try await Task.detached(priority: .userInitiated) { () -> UncheckedSendable<(CIImage, CIImage, StyleRecipe?)> in
                let (image, recipe) = try await PhotoSaver.shared.loadForEditing(boxedAsset.value)
                return UncheckedSendable((image, EditorView.makeProxy(image), recipe))
            }.value
            original = loaded.value.0
            proxy = loaded.value.1
            if let saved = loaded.value.2 {
                recipe = saved
                hadCam18Edit = true
                panel = Panel.allCases.first { $0.isActive(in: saved) } ?? .style
            } else {
                recipe = StyleRecipe(look: .film, intensity: 0)
            }
            scheduleRender()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A screen-sized copy of the photo, rendered once so slider changes don't
    /// have to decode (or, for RAW, develop) the full photo every time.
    nonisolated static func makeProxy(_ image: CIImage) -> CIImage {
        let e = image.extent
        let scale = min(1, 1600 / max(e.width, e.height))
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = CGRect(x: 0, y: 0, width: (e.width * scale).rounded(.down), height: (e.height * scale).rounded(.down))
        if bounds.width >= 1, bounds.height >= 1,
           let space = CGColorSpace(name: CGColorSpace.displayP3),
           let cg = StillRenderer.shared.context.createCGImage(scaled, from: bounds, format: .RGBA8, colorSpace: space) {
            return CIImage(cgImage: cg)
        }
        return scaled
    }

    private func scheduleRender() {
        guard let proxy else { return }
        renderTask?.cancel()
        let recipe = showOriginal ? StyleRecipe.neutral : self.recipe
        let needsMask = recipe.softSkinIntensity > 0 && personMask == nil
        let boxed = UncheckedSendable((proxy, personMask))
        renderTask = Task {
            try? await Task.sleep(for: .milliseconds(30))
            if Task.isCancelled { return }
            let result = await Task.detached(priority: .userInitiated) { () -> UncheckedSendable<(UIImage?, CIImage?)> in
                let context = StillRenderer.shared.context
                var mask = boxed.value.1
                if needsMask {
                    mask = PersonSegmenter.mask(for: boxed.value.0, quality: .accurate, context: context)
                }
                let out = StylePipeline.render(boxed.value.0, recipe: recipe,
                                               options: RenderOptions(isPreview: false, personMask: mask))
                let cg = context.createCGImage(out, from: out.extent)
                return UncheckedSendable((cg.map { UIImage(cgImage: $0) }, mask))
            }.value
            if Task.isCancelled { return }
            if let image = result.value.0 { rendered = image }
            if needsMask { personMask = result.value.1 }
        }
    }

    private func save() {
        guard let asset else { return }
        isSaving = true
        let recipe = self.recipe
        let boxedAsset = UncheckedSendable(asset)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try await PhotoSaver.shared.applyEdit(to: boxedAsset.value, recipe: recipe)
                }.value
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
