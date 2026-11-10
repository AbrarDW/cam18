import PhotosUI
import SwiftUI

/// Identifies a library photo opened in the editor.
struct EditableAsset: Identifiable, Hashable {
    let id: String // PHAsset local identifier
}

struct ContentView: View {
    @State private var model: CameraModel
    @AppStorage(AppSettings.bakeInLookKey) private var bakeInLook = false
    @AppStorage(AppSettings.showGridKey) private var showGrid = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var editing: EditableAsset?
    @Environment(\.scenePhase) private var scenePhase

    /// When set, this picture stands in for the live camera and the camera
    /// isn't started. Used to take screenshots of the UI in the simulator.
    private let demoImage: UIImage?

    init(demoImage: UIImage? = nil, demoPanel: Panel? = nil) {
        self.demoImage = demoImage
        let model = CameraModel()
        if let demoPanel {
            model.selectedPanel = demoPanel
            model.panelOpen = true
        }
        _model = State(initialValue: model)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                viewfinder
                Spacer(minLength: 0)
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                tray
            }

            if let toast = model.toast {
                VStack {
                    Text(toast)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.top, 64)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .animation(.snappy(duration: 0.25), value: model.toast)
        .task {
            if demoImage == nil { await model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard demoImage == nil else { return }
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
        HStack(spacing: 8) {
            ModeBadge(bakeInLook: $bakeInLook)
            Spacer()
            AspectMenu(aspect: $model.recipe.aspect)
            GridToggle(isOn: $showGrid)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// The camera's full 4:3 frame. Other aspect ratios are drawn centered
    /// inside it, so the framing never jumps when the tray opens.
    private var viewfinder: some View {
        ZStack {
            if let demoImage {
                Image(uiImage: demoImage).resizable().scaledToFit()
            } else {
                switch model.status {
                case .running, .idle:
                    PreviewView(renderer: model.renderer)
                case .needsPermission:
                    messageView("Camera access is off", detail: "Allow camera access for Cam18 in Settings.")
                case .unavailable(let message):
                    messageView("Camera unavailable", detail: message)
                }
            }

            if showGrid {
                GeometryReader { geo in
                    let frame = model.recipe.aspect.cropRect(in: CGRect(origin: .zero, size: geo.size))
                    GridOverlay()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
            }

            if model.shutterFlash {
                Color.black.opacity(0.6).allowsHitTesting(false)
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: 18))
        .overlay(alignment: .bottom) {
            if model.availableLenses.count > 1, !model.panelOpen {
                LensPicker(lenses: model.availableLenses, selected: model.lens) { model.select(lens: $0) }
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
    }

    /// Floating controls: the open section's sliders, presets, the section
    /// picker and the shutter row.
    private var tray: some View {
        VStack(spacing: 10) {
            if model.panelOpen {
                PanelControls(panel: model.selectedPanel, recipe: $model.recipe) { model.select(style: $0) }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .glassCard()
                    .padding(.horizontal, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            PresetStrip(store: model.presets, recipe: model.recipe) { model.apply($0) }

            PanelPicker(selected: $model.selectedPanel, isOpen: $model.panelOpen, recipe: model.recipe)

            shutterRow
        }
        .padding(.bottom, 8)
    }

    private var shutterRow: some View {
        HStack {
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Image(systemName: "photo.on.rectangle")
                    .font(.title3)
                    .frame(width: 54, height: 54)
                    .foregroundStyle(.white)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .accessibilityLabel("Edit a photo from the library")

            Spacer()
            ShutterButton(isBusy: model.isCapturing) { model.capture() }
                .disabled(model.status != .running)
                .overlay(alignment: .top) {
                    if model.isSaving {
                        ProgressView().tint(.white).offset(y: -26)
                    }
                }
            Spacer()

            Button {
                if let id = model.lastAssetID { editing = EditableAsset(id: id) }
            } label: {
                Group {
                    if let thumbnail = model.lastThumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo").font(.title3).foregroundStyle(.white.opacity(0.35))
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(.rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.5), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .disabled(model.lastAssetID == nil)
            .accessibilityLabel("Edit the last photo")
        }
        .padding(.horizontal, 30)
        .padding(.top, 2)
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
