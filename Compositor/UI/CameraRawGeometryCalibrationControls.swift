import AppKit
import SwiftUI

/// Camera Raw Geometry panel, styled to resemble the modern Adobe Camera Raw Geometry interface.
///
/// Layout:
///   1. Compact Geometry header (title, chevron, reset)
///   2. Upright mode icon strip (Off, Auto Level, Auto Vertical, Auto Full, Guided)
///   3. Guided Upright on-image guide drawing (when Guided is active)
///   4. Manual Transformations expandable section
///   5. Constrain Crop
///   6. Advanced Geometry disclosure (Projection, Volume, Framing, Perspective Amount)
struct CameraRawGeometryControls: View {
    @Bindable var session: EditorSession

    private var settings: FilterSettings { session.filterEdit?.settings ?? FilterSettings() }
    private var raw: CameraRawSettings { settings.cameraRaw }
    private var geometry: CameraRawGeometrySettings { raw.geometry }
    /// Dedicated Horizon settings. Defaults to Off, which is bit-exact identity.
    private var horizon: CameraRawHorizonSettings { raw.horizon }
    private var edit: FilterEdit? { session.filterEdit }

    // Which manual transform rows are expanded.
    @State private var manualTransformationsExpanded = false
    @State private var advancedGeometryExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // MARK: Upright mode icon strip
            uprightModeStrip

            // MARK: Guided Upright controls
            if geometry.upright == .guided {
                guidedModeSection
            }

            // MARK: Auto-mode status message
            if geometry.upright.isAuto, geometry.guides.isEmpty,
               edit?.cameraRawUprightDetectionAttempted == true {
                Text("No strong lines found. Try Guided, or draw the picture's upright edges.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // MARK: Manual Transformations (expandable)
            manualTransformationsSection

            // MARK: Constrain Crop
            constrainCropToggle

            // MARK: Advanced Geometry (disclosure)
            advancedGeometrySection
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Upright mode icon strip

    private var uprightModeStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Upright")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            HStack(spacing: 3) {
                ForEach(CameraRawUprightMode.allCases, id: \.self) { mode in
                    UprightModeButton(
                        mode: mode,
                        isActive: geometry.upright == mode,
                        action: { selectUprightMode(mode) }
                    )
                }
            }
            .padding(5)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("geometryUprightStrip")
            .accessibilityLabel("Upright")
        }
    }

    private func selectUprightMode(_ mode: CameraRawUprightMode) {
        let previous = geometry.upright

        // Stash guided guides when switching to Auto
        if mode.isAuto, previous == .guided {
            edit?.cameraRawManualGuides = geometry.guides
        }

        // Restore guided guides when switching to Guided
        if mode == .guided, let saved = edit?.cameraRawManualGuides {
            update {
                $0.cameraRaw.geometry.upright = mode
                $0.cameraRaw.geometry.guides = saved
            }
            edit?.drawingCameraRawGeometryGuide = false
            edit?.cameraRawUprightDetectionAttempted = false
            return
        }

        update { $0.cameraRaw.geometry.upright = mode }

        // Exit drawing mode when leaving Guided
        if mode != .guided {
            edit?.drawingCameraRawGeometryGuide = false
        }

        // Trigger auto detection for auto modes
        if mode.isAuto {
            Task { await session.applyCameraRawUprightDetection() }
        } else if mode == .off {
            edit?.cameraRawUprightDetectionAttempted = false
        }
    }

    // MARK: - Guided Upright section

    private var guidedModeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                edit?.drawingCameraRawGeometryGuide.toggle()
                session.brushRevision += 1
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: edit?.drawingCameraRawGeometryGuide == true ? "pencil.line" : "pencil")
                        .font(.system(size: 12, weight: .medium))
                    Text(edit?.drawingCameraRawGeometryGuide == true ? "Stop Drawing" : "Draw Guides")
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(edit?.drawingCameraRawGeometryGuide == true ? Color.accentColor : Color(NSColor.controlBackgroundColor).opacity(0.5))
                .foregroundStyle(edit?.drawingCameraRawGeometryGuide == true ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("Draw lines on the preview that should be level or vertical.")
            .accessibilityIdentifier("geometryDrawGuides")
            .accessibilityLabel("Draw Guides")

            if edit?.drawingCameraRawGeometryGuide == true {
                Text("Drag on the image to place a guide. One near-horizontal levels; two vertical or horizontal force parallels; four make a rectangle.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
            }

            if !geometry.guides.isEmpty {
                Button("Clear Guides") {
                    update { $0.cameraRaw.geometry.guides = [] }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .help("Remove every guide line.")
                .accessibilityIdentifier("geometryClearGuides")
                .accessibilityLabel("Clear Guides")
                .padding(.top, 2)
            }

            Text("\(geometry.guides.count)/4 guides")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
    }

    // MARK: - Manual Transformations section

    private var manualTransformationsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                manualTransformationsExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: manualTransformationsExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 10)
                    Text("Manual Transformations")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Manual perspective and framing controls.")
            .accessibilityIdentifier("geometryManualTransformations")
            .accessibilityLabel("Manual Transformations")

            if manualTransformationsExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    // Projection — only if supported by the backend
                    projectionPickerRow()

                    // Adobe order: Vertical, Horizontal, Rotate, Aspect, Scale, Offset X, Offset Y
                    let keystoneEnabled = geometry.upright == .off

                    geometrySlider("Vertical", \.vertical,
                                  help: "Straightens vertical lines toward the center.",
                                  enabled: keystoneEnabled)
                    geometrySlider("Horizontal", \.horizontal,
                                  help: "Straightens horizontal lines toward the center.",
                                  enabled: keystoneEnabled)
                    geometrySlider("Rotate", \.rotate,
                                  range: CameraRawGeometrySettings.rotateRange,
                                  help: "Rotates the picture around its center.",
                                  enabled: keystoneEnabled)
                    geometrySlider("Aspect", \.aspect,
                                  help: "Stretches width relative to height.")
                    geometrySlider("Scale", \.scale,
                                  help: "Zooms the transformed picture within the frame.")
                    geometrySlider("Offset X", \.offsetX,
                                  help: "Moves the picture left or right.")
                    geometrySlider("Offset Y", \.offsetY,
                                  help: "Moves the picture up or down.")

                    if !keystoneEnabled {
                        Text("Vertical, Horizontal, and Rotate stay off while Guided or Auto is solving the upright.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Constrain Crop

    private var constrainCropToggle: some View {
        Toggle("Constrain Crop", isOn: binding(\.constrainCrop))
            .font(.system(size: 12))
            .help("Crops empty edges after the transform and fits the result back into the frame.")
            .accessibilityIdentifier("geometryConstrainCrop")
            .accessibilityLabel("Constrain Crop")
    }

    // MARK: - Advanced Geometry (disclosure)

    private var advancedGeometrySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                advancedGeometryExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: advancedGeometryExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 10)
                    Text("Advanced Geometry")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Projection, Volume, and Framing options.")
            .accessibilityIdentifier("geometryAdvanced")
            .accessibilityLabel("Advanced Geometry")

            if advancedGeometryExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    // Perspective Amount
                    amountSlider

                    // Framing
                    Picker("Framing", selection: binding(\.framingMode)) {
                        ForEach(CameraRawFramingMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("Keep Original Size preserves the layer footprint. Expand to Fit grows the layer to the warped bounds without moving sibling layers.")

                    // Volume
                    Text("Volume")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    Picker("Volume Mode", selection: binding(\.volumeMode)) {
                        ForEach(CameraRawVolumeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .help("Radial pulls the corners. Horizontal and Vertical bend one axis. Horizontal & Vertical applies both.")
                    volumeSlider("Horizontal", \.volumeHorizontal, help: "Cylindrical volume along the width.")
                    volumeSlider("Vertical", \.volumeVertical, help: "Cylindrical volume along the height.")
                    volumeSlider("Radial", \.volumeRadial, help: "Spherical volume toward the corners.")

                    HStack {
                        Button("Auto") {
                            update { $0.cameraRaw.geometry.applyAutoVolumeFromFocal() }
                        }
                        .font(.system(size: 11))
                        .help("Sets the volume sliders from the photo's focal length when EXIF is available.")
                        .disabled(raw.geometry.focalLengthMm <= 0 || raw.geometry.sensorWidthMm <= 0)
                        if raw.geometry.focalLengthMm > 0 {
                            Text(raw.geometry.sensorWidthMm > 0
                                 ? String(format: "%.0f mm · sensor %.1f mm", raw.geometry.focalLengthMm, raw.geometry.sensorWidthMm)
                                 : String(format: "%.0f mm", raw.geometry.focalLengthMm))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Horizon is appended after every preexisting Advanced Geometry row.
                    horizonSection
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Horizon (appended, independent of the Upright solver)

    /// Compact Horizon control: mode, angle, amount, and reference-line drawing. Reuses `CameraRawHorizonSettings`
    /// and `CameraRawHorizon` verbatim; it adds no second solver and no second roll.
    private var horizonSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().padding(.vertical, 2)

            HStack(spacing: 6) {
                Text("Horizon")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("horizonHeader")
                Spacer(minLength: 0)
                Text(horizon.mode.rawValue)
                    .font(.caption2)
                    .foregroundStyle(horizon.mode == .off ? Color.secondary : Color.accentColor)
                    .accessibilityIdentifier("horizonActiveMode")
                    .help("The Horizon mode in use right now.")
                Button("Reset") {
                    applyHorizon { $0 = CameraRawHorizonSettings() }
                    session.filterEdit?.drawingCameraRawHorizonReference = false
                    session.filterEdit?.cameraRawHorizonReferenceDraft = nil
                    var settings = self.settings
                    settings.cameraRaw.automaticHorizonAngle = nil
                    session.updateFilter(settings, preview: edit?.preview ?? true)
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Puts Horizon back to Off with its default angle and amount.")
                .accessibilityIdentifier("horizonReset")
                .accessibilityLabel("Reset Horizon")
            }

            Picker("Horizon Mode", selection: Binding(
                get: { horizon.mode },
                set: { mode in selectHorizonMode(mode) }
            )) {
                ForEach(CameraRawHorizonMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Off leaves the picture alone. Automatic measures its level. Angle turns it by a set amount. "
                  + "Horizontal and Vertical Reference level a line drawn on the picture.")
            .accessibilityIdentifier("horizonModePicker")
            .accessibilityLabel("Horizon Mode")

            if horizon.mode == .angle {
                horizonSlider("Angle", \.angleDegrees, range: CameraRawHorizonSettings.angleRange,
                              reset: 0, help: "Turns the picture clockwise about its center.",
                              identifier: "horizonAngle")
            }

            horizonSlider("Amount", \.amount, range: CameraRawHorizonSettings.amountRange,
                          reset: 100, help: "How much of the horizon correction is applied. 0% leaves the picture unchanged.",
                          identifier: "horizonAmount")

            if horizon.mode == .horizontalReference || horizon.mode == .verticalReference {
                horizonReferenceControls
            }

            if let note = horizonNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(horizon.mode == .off ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("horizonNote")
            }
        }
        .padding(.top, 2)
    }

    private var horizonReferenceControls: some View {
        let drawing = session.filterEdit?.drawingCameraRawHorizonReference == true
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                if drawing {
                    session.endCameraRawHorizonReferenceDrawing()
                } else {
                    session.beginCameraRawHorizonReferenceDrawing()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: drawing ? "pencil.line" : "pencil")
                        .font(.system(size: 11, weight: .medium))
                    Text(drawing ? "Stop Drawing Line" : "Draw Reference Line")
                        .font(.system(size: 11, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(drawing ? Color.accentColor : Color(NSColor.controlBackgroundColor).opacity(0.5))
                .foregroundStyle(drawing ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("Drag a line on the preview that should be level (or upright).")
            .accessibilityIdentifier("horizonDrawReference")
            .accessibilityLabel("Draw Reference Line")

            if drawing {
                Text(horizon.mode == .horizontalReference
                     ? "Drag across something that should be level, such as a rooftop or a waterline."
                     : "Drag along something that should stand upright, such as a wall edge or a window frame.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
                    .accessibilityIdentifier("horizonDrawHint")
            }

            HStack(spacing: 6) {
                Button("Clear Line") {
                    session.clearCameraRawHorizonReference()
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Restores the default reference line along the bottom edge.")
                .accessibilityIdentifier("horizonClearReference")
                .accessibilityLabel("Clear Reference Line")
                Spacer(minLength: 0)
                Text(String(format: "%.1f°", horizonReferenceDegrees))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help("The rotation the reference line asks for, before Amount.")
                    .accessibilityIdentifier("horizonReferenceAngle")
            }
        }
    }

    /// The reference line's own rotation, before Amount, for the readout.
    private var horizonReferenceDegrees: Double {
        let image = session.filterEdit?.previewSource
        return CameraRawHorizon.referenceAngle(settings: horizon,
                                               width: image?.width ?? 1000,
                                               height: image?.height ?? 1000,
                                               vertical: horizon.mode == .verticalReference) ?? 0
    }

    /// What the panel says about the current Horizon state, if anything needs saying.
    private var horizonNote: String? {
        guard horizon.mode != .off else { return nil }
        if CameraRawGeometryBackend.shouldApplyHorizon(
            CameraRawGeometryBackendSettings(geometry: raw.geometry, horizon: horizon)) == false {
            return "Auto Level is already leveling the picture, so Horizon stays out of its way. "
                + "Switch Upright to Automatic Horizon, or turn Upright Off, to use an Angle or reference."
        }
        if horizon.mode == .automatic, raw.automaticHorizonAngle == nil {
            return "Automatic needs a measurement. Choose Automatic again to retry, or use Angle."
        }
        return nil
    }

    private func selectHorizonMode(_ mode: CameraRawHorizonMode) {
        applyHorizon { $0.mode = mode }
        // Drawing state belongs to the two reference modes only.
        let edit = session.filterEdit
        if mode != .horizontalReference, mode != .verticalReference {
            edit?.drawingCameraRawHorizonReference = false
            edit?.cameraRawHorizonReferenceDraft = nil
        }
        if mode == .automatic {
            Task { await session.applyCameraRawHorizonAutomatic() }
        }
    }

    private func applyHorizon(_ change: (inout CameraRawHorizonSettings) -> Void) {
        var value = settings
        change(&value.cameraRaw.horizon)
        session.updateFilter(value, preview: edit?.preview ?? true)
    }

    private func horizonSlider(_ title: String,
                              _ key: WritableKeyPath<CameraRawHorizonSettings, Double>,
                              range: ClosedRange<Double>,
                              reset resetValue: Double,
                              help: String,
                              identifier: String) -> some View {
        let value = horizon[keyPath: key]
        return HStack(spacing: 8) {
            Text(title)
                .frame(minWidth: 64, alignment: .leading)
                .help(help)
                .font(.system(size: 11))
                .lineLimit(1)

            CameraRawSlider(value: value, range: range, track: .plain, help: help,
                            onChange: { rawValue in applyHorizon { $0[keyPath: key] = rawValue.rounded() } },
                            onReset: { applyHorizon { $0[keyPath: key] = resetValue } })

            TextField(title,
                      value: Binding(
                          get: { horizon[keyPath: key] },
                          set: { newValue in applyHorizon { $0[keyPath: key] = newValue } }
                      ),
                      format: .number.precision(.fractionLength(0)))
                .frame(width: 44)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .help(help)
                .font(.system(size: 10, design: .monospaced))
        }
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Slider helpers

    private func binding<T>(_ key: WritableKeyPath<CameraRawGeometrySettings, T>) -> Binding<T> {
        Binding(
            get: { geometry[keyPath: key] },
            set: { value in update { $0.cameraRaw.geometry[keyPath: key] = value } }
        )
    }

    @ViewBuilder
    private func geometrySlider(_ title: String,
                                _ key: WritableKeyPath<CameraRawGeometrySettings, Double>,
                                range: ClosedRange<Double> = CameraRawGeometrySettings.toneRange,
                                help: String,
                                enabled: Bool = true) -> some View {
        let value = geometry[keyPath: key]
        return HStack(spacing: 8) {
            Text(title)
                .frame(minWidth: 64, alignment: .leading)
                .help(help)
                .font(.system(size: 11))
                .lineLimit(1)

            CameraRawSlider(
                value: value,
                range: range,
                track: .plain,
                help: help,
                onChange: { rawValue in update { $0.cameraRaw.geometry[keyPath: key] = rawValue.rounded() } },
                onReset: { update { $0.cameraRaw.geometry[keyPath: key] = 0 } }
            )
            .disabled(!enabled)

            TextField(title,
                      value: Binding(
                          get: { geometry[keyPath: key] },
                          set: { newValue in update { $0.cameraRaw.geometry[keyPath: key] = newValue } }
                      ),
                      format: .number.precision(.fractionLength(0)))
                .frame(width: 44)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .help(help)
                .font(.system(size: 10, design: .monospaced))
                .disabled(!enabled)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func projectionPickerRow() -> some View {
        Picker("Projection", selection: binding(\.projection)) {
            ForEach(CameraRawProjection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Perspective allows stronger keystone. Rectilinear keeps the warp gentler.")
    }

    private var amountSlider: some View {
        let enabled = geometry.perspectiveAmountApplies
        let help = "How strongly the upright or keystone correction is applied. 0% leaves perspective unchanged; 100% is full strength."
        let range = CameraRawGeometrySettings.amountRange
        let value = geometry.perspectiveAmount
        return HStack(spacing: 8) {
            Text("Perspective Amount")
                .frame(minWidth: 64, alignment: .leading)
                .help(help)
                .font(.system(size: 11))
                .lineLimit(1)

            CameraRawSlider(value: value, range: range, track: .plain, help: help,
                            onChange: { rawValue in update { $0.cameraRaw.geometry.perspectiveAmount = rawValue.rounded() } },
                            onReset: { update { $0.cameraRaw.geometry.perspectiveAmount = 100 } })
            .disabled(!enabled)

            TextField("Perspective Amount",
                      value: Binding(
                          get: { geometry.perspectiveAmount },
                          set: { newValue in update { $0.cameraRaw.geometry.perspectiveAmount = newValue } }
                      ),
                      format: .number.precision(.fractionLength(0)))
                .frame(width: 44)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .help(help)
                .font(.system(size: 10, design: .monospaced))
                .disabled(!enabled)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    private func volumeSlider(_ title: String,
                              _ key: WritableKeyPath<CameraRawGeometrySettings, Double>,
                              help: String) -> some View {
        let range = CameraRawGeometrySettings.volumeRange
        let value = geometry[keyPath: key]
        return HStack(spacing: 8) {
            Text(title)
                .frame(minWidth: 64, alignment: .leading)
                .help(help)
                .font(.system(size: 11))
                .lineLimit(1)

            CameraRawSlider(value: value, range: range, track: .plain, help: help,
                            onChange: { rawValue in update { $0.cameraRaw.geometry[keyPath: key] = rawValue.rounded() } },
                            onReset: { update { $0.cameraRaw.geometry[keyPath: key] = 0 } })

            TextField(title,
                      value: Binding(
                          get: { geometry[keyPath: key] },
                          set: { newValue in update { $0.cameraRaw.geometry[keyPath: key] = newValue } }
                      ),
                      format: .number.precision(.fractionLength(0)))
                .frame(width: 44)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .help(help)
                .font(.system(size: 10, design: .monospaced))
        }
    }

    private func update(_ change: (inout FilterSettings) -> Void) {
        var value = settings
        change(&value)
        session.updateFilter(value, preview: edit?.preview ?? true)
    }
}

/// Icon button for a single Upright mode in the Adobe-style horizontal strip.
private struct UprightModeButton: View {
    let mode: CameraRawUprightMode
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isActive {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.18))
                }
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .frame(width: 20, height: 20)
            }
            .frame(width: 28, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityIdentifier("geometryUpright_\(modeIdentifier)")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var iconName: String {
        switch mode {
        case .off: return "square"
        case .autoLevel: return "wand.and.stars"
        case .autoVertical: return "line.horizontal.3.decrease.circle"
        case .autoFull: return "cube"
        case .guided: return "pencil.line"
        }
    }

    private var tooltip: String {
        switch mode {
        case .off: return "Off — No perspective correction"
        case .autoLevel: return "Auto Level — Levels the image and corrects horizontal tilt"
        case .autoVertical: return "Auto Vertical — Straightens converging vertical lines"
        case .autoFull: return "Auto Full — Full perspective correction for level and vertical"
        case .guided: return "Guided — Draw custom guides on the image"
        }
    }

    /// Stable per-mode identifier, independent of the visible label.
    private var modeIdentifier: String {
        switch mode {
        case .off: return "off"
        case .autoLevel: return "autoLevel"
        case .autoVertical: return "autoVertical"
        case .autoFull: return "autoFull"
        case .guided: return "guided"
        }
    }

    private var accessibilityLabel: String {
        switch mode {
        case .off: return "Off"
        case .autoLevel: return "Auto Level"
        case .autoVertical: return "Auto Vertical"
        case .autoFull: return "Auto Full"
        case .guided: return "Guided"
        }
    }
}

struct CameraRawCalibrationControls: View {
    @Bindable var session: EditorSession
    private var settings: FilterSettings { session.filterEdit?.settings ?? FilterSettings() }
    private var raw: CameraRawSettings { settings.cameraRaw }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Process", selection: binding(\.process)) {
                ForEach(CameraRawProcessVersion.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .help("Chooses how strongly the calibration sliders below are applied. Version 6 is the current default.")
            Text(raw.calibration.process.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(raw.calibration.process.summary)
            Text("Shadows").font(.subheadline)
            calibrationSlider("Tint", \.shadowTint, help: "Adds green or magenta to the darkest tones.")
            Text("Red Primary").font(.subheadline)
            calibrationSlider("Hue", \.redHue, help: "Shifts how red is interpreted.")
            calibrationSlider("Saturation", \.redSaturation, help: "Strengthens or weakens the red primary.")
            Text("Green Primary").font(.subheadline)
            calibrationSlider("Hue", \.greenHue, help: "Shifts how green is interpreted.")
            calibrationSlider("Saturation", \.greenSaturation, help: "Strengthens or weakens the green primary.")
            Text("Blue Primary").font(.subheadline)
            calibrationSlider("Hue", \.blueHue, help: "Shifts how blue is interpreted.")
            calibrationSlider("Saturation", \.blueSaturation, help: "Strengthens or weakens the blue primary.")
        }
    }

    private func binding<T>(_ key: WritableKeyPath<CameraRawCalibrationSettings, T>) -> Binding<T> {
        Binding(get: { raw.calibration[keyPath: key] }, set: { value in update { $0.cameraRaw.calibration[keyPath: key] = value } })
    }

    private func calibrationSlider(_ title: String, _ key: WritableKeyPath<CameraRawCalibrationSettings, Double>, help: String) -> some View {
        let value = raw.calibration[keyPath: key]
        return HStack(spacing: 10) {
            Text(title).frame(minWidth: CameraRawControls.labelWidth, alignment: .leading).help(help)
                .font(.system(size: 12))
                .scrubbable(sensitivity: 1,
                            value: Binding(get: { raw.calibration[keyPath: key] },
                                           set: { newValue in update { $0.cameraRaw.calibration[keyPath: key] = newValue } }),
                            range: CameraRawCalibrationSettings.toneRange)
            CameraRawSlider(value: value, range: CameraRawCalibrationSettings.toneRange, track: .plain, help: help,
                            onChange: { rawValue in update { $0.cameraRaw.calibration[keyPath: key] = rawValue.rounded() } },
                            onReset: { update { $0.cameraRaw.calibration[keyPath: key] = 0 } })
            TextField(title, value: Binding(get: { raw.calibration[keyPath: key] },
                                            set: { newValue in update { $0.cameraRaw.calibration[keyPath: key] = newValue } }),
                      format: .number.precision(.fractionLength(0)))
                .frame(width: 56).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).help(help)
                .font(.system(size: 11, design: .monospaced))
        }
    }

    private func update(_ change: (inout FilterSettings) -> Void) {
        var value = settings
        change(&value)
        session.updateFilter(value, preview: session.filterEdit?.preview ?? true)
    }
}
