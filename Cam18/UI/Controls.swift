import SwiftUI

// MARK: Glass styling

extension View {
    /// A capsule chip: Liquid Glass normally, solid white when selected.
    @ViewBuilder
    func chip(selected: Bool = false) -> some View {
        if selected {
            self.foregroundStyle(Color.black).background(Color.white, in: Capsule())
        } else {
            self.foregroundStyle(Color.white).contentShape(Capsule())
                .glassEffect(.regular.interactive(), in: .capsule)
        }
    }

    /// A floating glass card for a group of controls.
    func glassCard(cornerRadius: CGFloat = 26) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

// MARK: Top bar

/// Shows how the next photo will be saved, and switches between the two
/// modes when tapped.
struct ModeBadge: View {
    @Binding var bakeInLook: Bool

    var body: some View {
        Button {
            bakeInLook.toggle()
        } label: {
            Label(bakeInLook ? "BAKED" : "EDITABLE",
                  systemImage: bakeInLook ? "lock.fill" : "slider.horizontal.3")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12).frame(height: 36)
                .foregroundStyle(bakeInLook ? Color.black : Color.white)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .modifier(BadgeBackground(highlighted: bakeInLook))
        .sensoryFeedback(.selection, trigger: bakeInLook)
        .accessibilityLabel(bakeInLook ? "Look will be baked in" : "Look will stay editable")
        .accessibilityHint("Switches between keeping the original and baking the look in.")
    }

    private struct BadgeBackground: ViewModifier {
        let highlighted: Bool
        func body(content: Content) -> some View {
            if highlighted {
                content.background(Color.orange, in: Capsule())
            } else {
                content.glassEffect(.regular.interactive(), in: .capsule)
            }
        }
    }
}

/// Menu for the photo's shape.
struct AspectMenu: View {
    @Binding var aspect: AspectRatio
    var fullLabel = "4:3"

    var body: some View {
        Menu {
            Picker("Aspect ratio", selection: $aspect) {
                ForEach(AspectRatio.allCases) { ratio in
                    Text(ratio == .full ? fullLabel : ratio.label).tag(ratio)
                }
            }
        } label: {
            Label(aspect == .full ? fullLabel : aspect.label, systemImage: "aspectratio")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12).frame(height: 36)
                .chip()
        }
        .sensoryFeedback(.selection, trigger: aspect)
        .accessibilityLabel("Aspect ratio")
        .accessibilityValue(aspect == .full ? fullLabel : aspect.label)
    }
}

struct GridToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: "grid")
                .font(.footnote.weight(.bold))
                .frame(width: 36, height: 36)
                .chip(selected: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Grid lines")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Rule-of-thirds lines over the framed area.
struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                for i in 1...2 {
                    let x = geo.size.width * CGFloat(i) / 3
                    let y = geo.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: geo.size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: Presets

/// Saved presets: tap to apply, touch and hold to update, rename or delete.
/// The "+" chip saves the current settings as a new preset.
struct PresetStrip: View {
    let store: PresetStore
    let recipe: StyleRecipe
    let onApply: (Preset) -> Void

    @State private var naming: NamingTarget?
    @State private var name = ""

    private enum NamingTarget: Identifiable {
        case new
        case rename(Preset)
        var id: String {
            switch self {
            case .new: "new"
            case .rename(let p): p.id.uuidString
            }
        }
    }

    var body: some View {
        let active = store.preset(matching: recipe)?.id
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    name = ""
                    naming = .new
                } label: {
                    Label("Save", systemImage: "plus")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).frame(height: 34)
                        .chip()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Save current settings as a preset")

                ForEach(store.presets) { preset in
                    Button {
                        onApply(preset)
                    } label: {
                        Text(preset.name)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 14).frame(height: 34)
                            .chip(selected: preset.id == active)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(preset.id == active ? .isSelected : [])
                    .contextMenu {
                        Button("Update with Current Settings", systemImage: "arrow.triangle.2.circlepath") {
                            store.update(preset.id, recipe: recipe)
                        }
                        Button("Rename", systemImage: "pencil") {
                            name = preset.name
                            naming = .rename(preset)
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            store.delete(preset.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .sensoryFeedback(.selection, trigger: active)
        .alert(alertTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $name)
            Button("Save") {
                switch naming {
                case .new: store.add(name: name, recipe: recipe)
                case .rename(let preset): store.rename(preset.id, to: name)
                case nil: break
                }
                naming = nil
            }
            Button("Cancel", role: .cancel) { naming = nil }
        } message: {
            Text("Presets keep the style, looks, adjustments and aspect ratio.")
        }
    }

    private var alertTitle: String {
        if case .rename = naming { return "Rename Preset" }
        return "Save Preset"
    }
}

// MARK: Sections

/// Horizontal list of control sections. A dot marks sections that are
/// switched on. Tapping the selected section shows or hides its controls.
struct PanelPicker: View {
    @Binding var selected: Panel
    @Binding var isOpen: Bool
    let recipe: StyleRecipe

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Panel.allCases) { panel in
                    let isSelected = selected == panel && isOpen
                    Button {
                        withAnimation(.snappy(duration: 0.28)) {
                            if selected == panel {
                                isOpen.toggle()
                            } else {
                                selected = panel
                                isOpen = true
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: panel.symbolName)
                            Text(panel.title)
                            if panel.isActive(in: recipe) {
                                Circle().fill(Color.orange).frame(width: 6, height: 6)
                            }
                        }
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).frame(height: 38)
                        .chip(selected: isSelected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityValue(panel.isActive(in: recipe) ? "On" : "Off")
                }
            }
            .padding(.horizontal, 16)
        }
        .sensoryFeedback(.selection, trigger: selected)
    }
}

/// The controls for one section.
struct PanelControls: View {
    let panel: Panel
    @Binding var recipe: StyleRecipe
    /// Called to switch colour style, so the caller can restore that style's
    /// remembered intensity.
    let onSelectStyle: (ColorStyle) -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(panel.title).font(.subheadline.weight(.semibold))
                Spacer()
                Button("Reset") {
                    var r = recipe
                    panel.reset(&r)
                    recipe = r
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(panel.isActive(in: recipe) ? Color.orange : Color.white.opacity(0.35))
                .disabled(!panel.isActive(in: recipe))
                .accessibilityLabel("Reset \(panel.title)")
            }
            .foregroundStyle(.white)

            switch panel {
            case .style: styleControls
            case .adjust: adjustControls
            case .grain:
                intensitySlider(for: .grain, title: "Amount")
                UnitSlider(title: "Size", value: $recipe.grainSize)
            case .film: intensitySlider(for: .film, title: "Intensity")
            case .glow: intensitySlider(for: .glow, title: "Intensity")
            case .softSkin: intensitySlider(for: .softSkin, title: "Intensity")
            }
        }
    }

    private var styleControls: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ColorStyle.allCases) { style in
                        StyleSwatch(style: style, isSelected: recipe.colorStyle == style) {
                            onSelectStyle(style)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .sensoryFeedback(.selection, trigger: recipe.colorStyle)

            HStack(spacing: 14) {
                ToneColorPad(tone: $recipe.tone, color: $recipe.color) {
                    // Moving the pad switches it on.
                    if recipe.toneColorIntensity < 0.02 { recipe.toneColorIntensity = 1 }
                }
                .frame(width: 104, height: 104)

                VStack(spacing: 6) {
                    UnitSlider(title: "Style", value: $recipe.styleIntensity)
                        .disabled(recipe.colorStyle == .standard)
                        .opacity(recipe.colorStyle == .standard ? 0.4 : 1)
                    intensitySlider(for: .toneColor, title: "Pad")
                    Text("Tone \(signed(recipe.tone)) · Color \(signed(recipe.color))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var adjustControls: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                ForEach(Adjustment.Group.allCases) { group in
                    Text(group.rawValue.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    ForEach(group.adjustments) { adjustment in
                        BipolarSlider(title: adjustment.displayName, value: Binding(
                            get: { recipe.adjustment(adjustment) },
                            set: { recipe.setAdjustment($0, for: adjustment) }))
                    }
                }
            }
        }
        .frame(height: 176)
    }

    private func intensitySlider(for look: Look, title: String) -> some View {
        UnitSlider(title: title, value: Binding(
            get: { recipe.intensity(for: look) },
            set: { recipe.setIntensity($0, for: look) }))
    }

    private func signed(_ v: Double) -> String {
        let n = Int((v * 100).rounded())
        return n > 0 ? "+\(n)" : "\(n)"
    }
}

/// A round colour chip for one colour style, with its name underneath.
struct StyleSwatch: View {
    let style: ColorStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Circle()
                    .fill(fill)
                    .frame(width: 40, height: 40)
                    .overlay(Circle().strokeBorder(.white.opacity(isSelected ? 1 : 0.25),
                                                   lineWidth: isSelected ? 2.5 : 1))
                    .padding(3)
                Text(style.displayName)
                    .font(.caption2.weight(isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.7))
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(minWidth: 56)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var fill: LinearGradient {
        let light = style.map(.init(0.86, 0.74, 0.62))
        let dark = style.map(.init(0.30, 0.34, 0.42))
        return LinearGradient(colors: [Color(red: light.x, green: light.y, blue: light.z),
                                       Color(red: dark.x, green: dark.y, blue: dark.z)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: Sliders

/// A 0...100 slider.
struct UnitSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.caption.weight(.medium)).frame(width: 64, alignment: .leading)
            Slider(value: $value, in: 0...1).tint(.orange)
            Text("\(Int((value * 100).rounded()))")
                .font(.caption.monospacedDigit())
                .frame(width: 34, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .sensoryFeedback(.selection, trigger: Int((value * 10).rounded()))
        .accessibilityElement(children: .combine)
    }
}

/// A −100...+100 slider that rests at 0. Double-tap the name to reset it.
struct BipolarSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        let n = Int((value * 100).rounded())
        HStack(spacing: 10) {
            Text(title)
                .font(.caption.weight(.medium))
                .frame(width: 76, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { value = 0 }
            Slider(value: $value, in: -1...1).tint(n == 0 ? .gray : .orange)
            Text(n > 0 ? "+\(n)" : "\(n)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(n == 0 ? Color.white.opacity(0.5) : Color.orange)
                .frame(width: 38, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .sensoryFeedback(.selection, trigger: Int((value * 10).rounded()))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double-tap the name to reset")
    }
}

/// 2-D pad: vertical axis is tone (flat ↔ punchy), horizontal is color
/// (muted/cool ↔ rich/warm). Double-tap resets to the center.
struct ToneColorPad: View {
    @Binding var tone: Double
    @Binding var color: Double
    var onChange: () -> Void = {}

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let x = (color + 1) / 2 * size.width
            let y = (1 - (tone + 1) / 2) * size.height
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: [Color(white: 0.35), Color(red: 0.75, green: 0.45, blue: 0.25)],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(LinearGradient(colors: [.black.opacity(0.45), .clear, .white.opacity(0.12)],
                                                 startPoint: .bottom, endPoint: .top)))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.2), lineWidth: 1))
                Path { p in
                    p.move(to: CGPoint(x: size.width / 2, y: 0)); p.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                    p.move(to: CGPoint(x: 0, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                }
                .stroke(.white.opacity(0.25), lineWidth: 0.5)
                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .shadow(radius: 2)
                    .position(x: x, y: y)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                color = (g.location.x / max(size.width, 1) * 2 - 1).clamped(to: -1...1)
                tone = (1 - g.location.y / max(size.height, 1) * 2).clamped(to: -1...1)
                onChange()
            })
            .onTapGesture(count: 2) { tone = 0; color = 0 }
        }
        .accessibilityElement()
        .accessibilityLabel("Tone and color pad")
        .accessibilityValue("Tone \(Int(tone * 100)), color \(Int(color * 100))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: tone = (tone + 0.1).clamped(to: -1...1)
            case .decrement: tone = (tone - 0.1).clamped(to: -1...1)
            @unknown default: break
            }
            onChange()
        }
    }
}

// MARK: Camera controls

struct ShutterButton: View {
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                Circle().fill(.white).frame(width: 64, height: 64)
                    .scaleEffect(isBusy ? 0.85 : 1)
                    .animation(.easeOut(duration: 0.12), value: isBusy)
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: isBusy) { _, busy in busy }
        .accessibilityLabel("Take photo")
    }
}

struct LensPicker: View {
    let lenses: [Lens]
    let selected: Lens
    let onSelect: (Lens) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(lenses) { lens in
                Button {
                    onSelect(lens)
                } label: {
                    Text(lens.label)
                        .font(.caption.weight(.bold))
                        .frame(minWidth: 44, minHeight: 36)
                        .padding(.horizontal, 4)
                        .foregroundStyle(lens == selected ? Color.black : Color.white)
                        .background(lens == selected ? Color.white : Color.clear, in: Capsule())
                        // Without this only the glyphs are tappable, and "1×"
                        // is a very small target.
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(lens == selected ? .isSelected : [])
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
        .sensoryFeedback(.selection, trigger: selected)
    }
}
