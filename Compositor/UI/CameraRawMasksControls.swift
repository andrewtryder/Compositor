import AppKit
import SwiftUI

/// Camera Raw's local masks, below the ten adjustment groups: a list of regions, the selected region's coverage
/// controls, and the tone and color that apply only inside it. The global sliders above are never touched by these.
struct CameraRawMasksControls: View {
    @Bindable var session: EditorSession
    @State private var renaming: UUID?
    @State private var draftName = ""

    private var settings: FilterSettings { session.filterEdit?.settings ?? FilterSettings() }
    private var raw: CameraRawSettings { settings.cameraRaw }
    private var masks: [CameraRawLocalMask] { raw.localMasks }
    private var selected: CameraRawLocalMask? { session.selectedCameraRawLocalMask }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Masks").font(.headline)
                Spacer(minLength: 0)
                Menu {
                    Button("From Selection") { session.addCameraRawLocalMaskFromSelection() }
                        .disabled(session.selection == nil)
                    Button("From Layer Mask") { session.addCameraRawLocalMaskFromLayerMask() }
                        .disabled(session.filterEdit.map { !hasLayerMask(layerID: $0.layerID) } ?? true)
                    Divider()
                    Button("Linear Gradient") { session.addCameraRawLocalMask(kind: .linearGradient) }
                    Button("Radial Gradient") { session.addCameraRawLocalMask(kind: .radialGradient) }
                    Divider()
                    // Kinds that need something in the document are captured through the tools above, not from
                    // here: an Object or Color Range mask with nothing sampled would cover nothing.
                    Button("Object Selection…") { session.filterEdit?.picksLocalMaskObject = true }
                    Button("Color Range…") { session.filterEdit?.picksLocalMaskColor = true }
                } label: {
                    Label("Add Mask", systemImage: "plus.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(masks.count >= CameraRawLocalMask.maximumCount || session.filterEdit?.committing == true)
                .help("Add a region whose own adjustments apply only where it shows.")
                .accessibilityLabel("Add Local Mask")
            }
            if masks.isEmpty {
                Text("A mask limits the adjustments below to one region, leaving the rest of the picture as it is.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                list
                if let selected {
                    coverageControls(selected)
                    adjustments(selected)
                }
            }
        }
    }

    private func hasLayerMask(layerID: UUID) -> Bool {
        session.document?.layers.first(where: { $0.id == layerID })?.mask != nil
    }

    // MARK: - The list

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(masks) { mask in
                row(mask)
            }
        }
    }

    private func row(_ mask: CameraRawLocalMask) -> some View {
        let isSelected = mask.id == session.filterEdit?.selectedLocalMaskID
        return HStack(spacing: 6) {
            Button {
                session.toggleCameraRawLocalMaskEnabled(mask.id)
            } label: {
                Image(systemName: mask.enabled ? "circle.fill" : "circle")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .help(mask.enabled ? "Turn this mask off, keeping its settings." : "Turn this mask on.")
            .accessibilityLabel(mask.enabled ? "Disable \(mask.name)" : "Enable \(mask.name)")

            if renaming == mask.id {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit {
                        session.renameCameraRawLocalMask(mask.id, to: draftName)
                        renaming = nil
                    }
            } else {
                Text(mask.name)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(mask.enabled ? (isSelected ? Color.primary : Color.secondary) : Color.secondary.opacity(0.6))
            }
            Spacer(minLength: 0)
            Text(mask.kind.rawValue).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { session.selectCameraRawLocalMask(mask.id) }
        .contextMenu {
            Button("Rename…") {
                draftName = mask.name
                renaming = mask.id
                session.selectCameraRawLocalMask(mask.id)
            }
            Button(mask.enabled ? "Disable" : "Enable") { session.toggleCameraRawLocalMaskEnabled(mask.id) }
            Button(mask.inverted ? "Invert: Off" : "Invert: On") {
                session.setCameraRawLocalMaskInverted(mask.id, !mask.inverted)
            }
            Divider()
            Button("Delete", role: .destructive) { session.deleteCameraRawLocalMask(mask.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mask.name), \(mask.kind.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Coverage of the selected mask

    @ViewBuilder private func coverageControls(_ mask: CameraRawLocalMask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    session.filterEdit?.showsLocalMaskOverlay.toggle()
                    if let edit = session.filterEdit { session.updateFilter(edit.settings, preview: edit.preview) }
                    session.brushRevision += 1
                } label: {
                    Label("Show Overlay", systemImage: "theatermasks")
                }
                .buttonStyle(.borderless)
                .tint(session.filterEdit?.showsLocalMaskOverlay == true ? Color.accentColor : Color.secondary)
                .help("Paint this mask's region over the preview.")
                .accessibilityLabel("Show Mask Overlay")

                Toggle("Invert", isOn: Binding(get: { mask.inverted },
                                               set: { session.setCameraRawLocalMaskInverted(mask.id, $0) }))
                    .toggleStyle(.checkbox)
                    .help("Apply the adjustments outside this region instead of inside it.")
                Spacer(minLength: 0)
                Button {
                    session.deleteCameraRawLocalMask(mask.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this mask.")
                .accessibilityLabel("Delete Mask")
            }
            slider("Feather", value: mask.feather, range: CameraRawLocalMask.featherRange, decimals: 0,
                   help: "Softens the edge of the mask, in pixels.") { value in
                var updated = mask
                updated.feather = value
                session.updateCameraRawLocalMask(updated)
            }
            if mask.kind.isGradient {
                Button {
                    if session.filterEdit?.drawsLocalMask == true {
                        session.finishCameraRawLocalMaskGradient()
                    } else {
                        session.beginCameraRawLocalMaskGradient()
                    }
                } label: {
                    Label(session.filterEdit?.drawsLocalMask == true ? "Done Drawing" : "Draw Gradient",
                          systemImage: "slider.horizontal.2.square")
                }
                .buttonStyle(.borderless)
                .tint(session.filterEdit?.drawsLocalMask == true ? Color.accentColor : Color.secondary)
                .help(mask.kind == .linearGradient
                      ? "Drag on the preview to set where the mask starts and ends."
                      : "Drag on the preview to move the mask's center and set its reach.")
                .accessibilityLabel("Draw Mask Gradient")
            }
            if mask.kind == .colorRange {
                HStack(spacing: 10) {
                    Button {
                        session.armCameraRawLocalMaskColorSample()
                    } label: {
                        Image(systemName: "eyedropper")
                    }
                    .buttonStyle(.borderless)
                    .tint(session.filterEdit?.samplesLocalMask == true ? Color.accentColor : Color.secondary)
                    .help("Click a pixel to choose the color this mask follows.")
                    .accessibilityLabel("Sample Mask Color")
                    Spacer(minLength: 0)
                }
                slider("Fuzziness", value: mask.fuzziness, range: CameraRawLocalMask.fuzzinessRange, decimals: 0,
                       help: "How far from the sampled color a pixel can be and still count.") { value in
                    var updated = mask
                    updated.fuzziness = value
                    session.updateCameraRawLocalMask(updated)
                }
            }
        }
    }

    // MARK: - The selected mask's own adjustments

    private func adjustments(_ mask: CameraRawLocalMask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local Adjustments").font(.subheadline)
            ForEach(CameraRawLocalAdjustmentField.allCases) { field in
                slider(field.rawValue, value: field.value(in: mask.adjustments), range: field.range,
                       decimals: field.decimals, track: field.track,
                       help: field.help) { value in
                    session.updateCameraRawLocalMaskAdjustments { $0[keyPath: field.keyPath] = value }
                }
            }
            HStack(spacing: 10) {
                Button("Reset") {
                    session.updateCameraRawLocalMaskAdjustments { $0 = CameraRawLocalAdjustments() }
                }
                .buttonStyle(.borderless)
                .disabled(mask.adjustments.isIdentity)
                .help("Put every local adjustment back to zero.")
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - One slider

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, decimals: Int,
                        track: CameraRawSliderTrack = .plain, help: String,
                        set: @escaping (Double) -> Void) -> some View {
        let step = pow(10, Double(decimals))
        return HStack(spacing: 10) {
            Text(title)
                .frame(minWidth: CameraRawControls.labelWidth, alignment: .leading)
                .help(help)
            CameraRawSlider(value: value, range: range, track: track, help: help,
                            onChange: { set(($0 * step).rounded() / step) }, onReset: { set(0) })
            TextField(title, value: Binding(get: { value }, set: { set($0) }),
                      format: .number.precision(.fractionLength(0...decimals)))
                .frame(width: 56).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .help(help)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// The local adjustments in Camera Raw's own order, with the ranges and tracks the global sliders use, so a local
/// Exposure means the same as a global one.
enum CameraRawLocalAdjustmentField: String, CaseIterable, Identifiable {
    case exposure = "Exposure"
    case contrast = "Contrast"
    case highlights = "Highlights"
    case shadows = "Shadows"
    case whites = "Whites"
    case blacks = "Blacks"
    case temperature = "Temperature"
    case tint = "Tint"
    case vibrance = "Vibrance"
    case saturation = "Saturation"
    case texture = "Texture"
    case clarity = "Clarity"
    case dehaze = "Dehaze"

    var id: String { rawValue }

    var keyPath: WritableKeyPath<CameraRawLocalAdjustments, Double> {
        switch self {
        case .exposure: return \.exposure
        case .contrast: return \.contrast
        case .highlights: return \.highlights
        case .shadows: return \.shadows
        case .whites: return \.whites
        case .blacks: return \.blacks
        case .temperature: return \.temperature
        case .tint: return \.tint
        case .vibrance: return \.vibrance
        case .saturation: return \.saturation
        case .texture: return \.texture
        case .clarity: return \.clarity
        case .dehaze: return \.dehaze
        }
    }

    var range: ClosedRange<Double> {
        self == .exposure ? CameraRawSettings.exposureRange : CameraRawSettings.toneRange
    }
    var decimals: Int { self == .exposure ? 2 : 0 }

    var track: CameraRawSliderTrack {
        switch self {
        case .temperature: return .temperature
        case .tint: return .tint
        case .vibrance, .saturation: return .chroma
        default: return .plain
        }
    }

    var help: String {
        switch self {
        case .exposure: return "Brightens or darkens the region, in stops of light."
        case .contrast: return "Makes light and dark tones in the region more or less different."
        case .highlights: return "Adjusts the bright parts of the region."
        case .shadows: return "Adjusts the dark parts of the region."
        case .whites: return "Sets the brightest point of the region."
        case .blacks: return "Sets the darkest point of the region."
        case .temperature: return "Shifts the region from blue to yellow. Relative, as these pixels are already developed."
        case .tint: return "Shifts the region from green to mauve. Relative, as these pixels are already developed."
        case .vibrance: return "Strengthens quiet colors in the region more than strong ones."
        case .saturation: return "Strengthens or weakens every color in the region by the same amount."
        case .texture: return "Adds or softens small detail in the region."
        case .clarity: return "Adds or softens contrast along broader shapes in the region."
        case .dehaze: return "Clears haze in the region when raised, and adds haze when lowered."
        }
    }

    func value(in adjustments: CameraRawLocalAdjustments) -> Double { adjustments[keyPath: keyPath] }
}
