import AppKit
import SwiftUI

/// Camera Raw Geometry panel, styled to resemble the modern Adobe Camera Raw Geometry interface.
///
/// Layout:
///   1. Compact Geometry header (title, chevron, reset)
///   2. Upright mode icon strip (Off, Auto, Level, Vertical, Full, Guided)
///   3. Guided Upright on-image guide drawing (when Guided is active)
///   4. Manual Transformations expandable section
///   5. Constrain Crop
///   6. Advanced Geometry disclosure (Projection, Volume, Framing, Perspective Amount)
struct CameraRawGeometryControls: View {
    @Bindable var session: EditorSession

    private var settings: FilterSettings { session.filterEdit?.settings ?? FilterSettings() }
    private var raw: CameraRawSettings { settings.cameraRaw }
    private var geometry: CameraRawGeometrySettings { raw.geometry }
    private var edit: FilterEdit? { session.filterEdit }

    // Which manual transform rows are expanded.
    @State private var manualTransformationsExpanded = false
    @State private var advancedGeometryExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // MARK: Header
            geometryHeader

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

            // MARK: Reset
            resetButton

            // MARK: Advanced Geometry (disclosure)
            advancedGeometrySection
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Header

    private var geometryHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.3.layers.3d.down.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Geometry")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Button {
                session.resetCameraRaw(.geometry)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .regular))
            }
            .buttonStyle(.plain)
            .help("Reset Geometry")
            .accessibilityLabel("Reset Geometry")
        }
        .padding(.bottom, 2)
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
            .accessibilityLabel("Constrain Crop")
    }

    // MARK: - Reset

    private var resetButton: some View {
        Button {
            session.resetCameraRaw(.geometry)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11))
                Text("Reset Geometry")
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .help("Clears upright, guides, volume, and framing polish. Keeps the photo's focal length for Volume Auto.")
        .accessibilityLabel("Reset Geometry")
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
                }
                .padding(.top, 4)
            }
        }
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
        case .autoLevel: return "Auto — Balanced perspective correction"
        case .autoVertical: return "Level — Level the horizon only"
        case .autoFull: return "Full — Full perspective correction"
        case .guided: return "Guided — Draw custom guides"
        }
    }

    private var accessibilityLabel: String {
        switch mode {
        case .off: return "Off"
        case .autoLevel: return "Auto"
        case .autoVertical: return "Level"
        case .autoFull: return "Full"
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
