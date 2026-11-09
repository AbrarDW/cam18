import PhotosUI
import SwiftUI

/// Identifies a library photo opened in the editor.
struct EditableAsset: Identifiable, Hashable {
    let id: String // PHAsset local identifier
}

struct ContentView: View {
    @State private var model = CameraModel()
    @AppStorage(AppSettings.bakeInLookKey) private var bakeInLook = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var editing: EditableAsset?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                viewfinder
                controls
            }

            if let toast = model.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 230)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await model.start() }
            case .background: model.stop()
            default: break
            }
        }
        .onChange(of: pickerItem) { _, item in
            if let id = item?.itemIdentifier { editing = EditableAsset(id: id) }
            pickerItem = nil
        }
        .sheet(item: $editing) { asset in
            EditorView(localIdentifier: asset.id)
        }
    }

    // MARK: Sections

    private var topBar: some View {
        HStack {
            ModeBadge(bakeInLook: bakeInLook)
            Spacer()
            Toggle(isOn: $bakeInLook) {
                Text("Bake in look").font(.footnote.weight(.medium))
            }
            .toggleStyle(.switch)
            .fixedSize()
            .tint(.orange)
            .accessibilityHint("When off, the original is kept and the look stays editable.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var viewfinder: some View {
        ZStack(alignment: .bottom) {
            switch model.status {
            case .running, .idle:
                PreviewView(renderer: model.renderer)
            case .needsPermission:
                messageView("Camera access is off", detail: "Allow camera access for Cam18 in Settings.")
            case .unavailable(let message):
                messageView("Camera unavailable", detail: message)
            }

            if model.shutterFlash {
                Color.black.opacity(0.6).allowsHitTesting(false)
            }

            if model.availableLenses.count > 1 {
                LensPicker(lenses: model.availableLenses, selected: model.lens) { model.select(lens: $0) }
                    .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var controls: some View {
        VStack(spacing: 12) {
            LookControls(look: model.selectedLook, recipe: $model.recipe)
                .frame(height: model.selectedLook == .toneColor ? 132 : 72)
                .padding(.horizontal, 20)

            LookPicker(selected: $model.selectedLook, recipe: model.recipe)

            HStack {
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title2)
                        .frame(width: 56, height: 56)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel("Edit a photo")

                Spacer()
                ShutterButton(isBusy: model.isCapturing) { model.capture() }
                    .disabled(model.status != .running)
                Spacer()

                Button {
                    var r = model.recipe
                    r.setIntensity(0, for: model.selectedLook)
                    model.recipe = r
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.title3)
                        .frame(width: 56, height: 56)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .accessibilityLabel("Reset \(model.selectedLook.displayName)")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .overlay(alignment: .top) {
                if model.isSaving {
                    ProgressView().tint(.white).offset(y: -18)
                }
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private func messageView(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.fill").font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Hosts the Metal-backed preview view.
struct PreviewView: UIViewRepresentable {
    let renderer: PreviewRenderer

    func makeUIView(context: Context) -> PreviewMetalView {
        let view = PreviewMetalView()
        view.backgroundColor = .black
        renderer.attach(view.metalLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewMetalView, context: Context) {}
}
