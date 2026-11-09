import SwiftUI

/// Viewfinder badge showing how the next photo will be saved.
struct ModeBadge: View {
    let bakeInLook: Bool

    var body: some View {
        Label(bakeInLook ? "BAKED" : "EDITABLE",
              systemImage: bakeInLook ? "lock.fill" : "slider.horizontal.3")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(bakeInLook ? Color.black : Color.white)
            .background(bakeInLook ? Color.orange : Color.white.opacity(0.18), in: Capsule())
            .accessibilityLabel(bakeInLook ? "Look will be baked in" : "Look will stay editable")
    }
}

/// Horizontal list of looks. A dot marks looks that are switched on.
struct LookPicker: View {
    @Binding var selected: Look
    let recipe: StyleRecipe

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Look.allCases) { look in
                    let isOn = recipe.intensity(for: look) > 0.0001
                    Button {
                        selected = look
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: look.symbolName)
                            Text(look.displayName)
                            if isOn {
                                Circle().fill(Color.orange).frame(width: 5, height: 5)
                            }
                        }
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .foregroundStyle(selected == look ? Color.black : Color.white)
                        .background(selected == look ? Color.white : Color.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected == look ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

/// The controls for one look: an intensity slider, plus the Tone & Color pad
/// or the grain size slider where relevant.
struct LookControls: View {
    let look: Look
    @Binding var recipe: StyleRecipe

    var body: some View {
        switch look {
        case .toneColor:
            HStack(spacing: 16) {
                ToneColorPad(tone: $recipe.tone, color: $recipe.color)
                    .frame(width: 124, height: 124)
                VStack(alignment: .leading, spacing: 6) {
                    intensitySlider
                    Text("Tone \(signed(recipe.tone)) · Color \(signed(recipe.color))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        case .grain:
            VStack(spacing: 4) {
                intensitySlider
                LabeledSlider(title: "Size", value: $recipe.grainSize)
            }
        default:
            intensitySlider
        }
    }

    private var intensitySlider: some View {
        LabeledSlider(
            title: look == .grain ? "Amount" : "Intensity",
            value: Binding(get: { recipe.intensity(for: look) },
                           set: { recipe.setIntensity($0, for: look) }))
    }

    private func signed(_ v: Double) -> String {
        let n = Int((v * 100).rounded())
        return n > 0 ? "+\(n)" : "\(n)"
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.caption.weight(.medium)).frame(width: 62, alignment: .leading)
            Slider(value: $value, in: 0...1).tint(.orange)
            Text("\(Int((value * 100).rounded()))")
                .font(.caption.monospacedDigit())
                .frame(width: 30, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

/// 2-D pad: vertical axis is tone (flat ↔ punchy), horizontal is color
/// (muted/cool ↔ rich/warm). Double-tap resets to the center.
struct ToneColorPad: View {
    @Binding var tone: Double
    @Binding var color: Double

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let x = (color + 1) / 2 * size.width
            let y = (1 - (tone + 1) / 2) * size.height
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(colors: [Color(white: 0.35), Color(red: 0.75, green: 0.45, blue: 0.25)],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(LinearGradient(colors: [.black.opacity(0.45), .clear, .white.opacity(0.12)],
                                                 startPoint: .bottom, endPoint: .top)))
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
        }
    }
}

struct ShutterButton: View {
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                Circle().fill(.white).frame(width: 62, height: 62)
                    .scaleEffect(isBusy ? 0.85 : 1)
                    .animation(.easeOut(duration: 0.12), value: isBusy)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Take photo")
    }
}

struct LensPicker: View {
    let lenses: [Lens]
    let selected: Lens
    let onSelect: (Lens) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(lenses) { lens in
                Button(lens.label) { onSelect(lens) }
                    .font(.caption.weight(.bold))
                    .frame(minWidth: 38, minHeight: 30)
                    .padding(.horizontal, 4)
                    .foregroundStyle(lens == selected ? Color.orange : Color.white)
                    .background(Color.black.opacity(lens == selected ? 0.6 : 0.35), in: Capsule())
                    .accessibilityAddTraits(lens == selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.black.opacity(0.25), in: Capsule())
    }
}
