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
    @State private var advancedPerspectiveExpanded = false
    @State private var miniatureExpanded = false
    /// The active advanced tool's stored points.
    private var tools: CameraRawPerspectiveToolState { raw.perspectiveTools }

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
            session.endCameraRawGeometryGuideDrawing()
        }

        // Trigger auto detection for auto modes
        if mode.isAuto {
            // An automatic mode owns the picture's keystone, so an advanced guide tool cannot also be selected:
            // returning to Upright Automatic is exactly the path back to the legacy behavior.
            if edit?.settings.cameraRaw.perspectiveTools.kind != .automatic {
                session.selectCameraRawPerspectiveTool(.automatic)
            }
            Task { await session.applyCameraRawUprightDetection() }
        } else if mode == .off {
            edit?.cameraRawUprightDetectionAttempted = false
        } else if edit?.settings.cameraRaw.perspectiveTools.kind != .automatic {
            // Guided is the legacy guide path. Choosing it takes the picture back from the advanced tool, which
            // keeps its own points for when it is selected again.
            session.selectCameraRawPerspectiveTool(.automatic)
        }
    }

    // MARK: - Guided Upright section

    private var guidedModeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if edit?.drawingCameraRawGeometryGuide == true {
                    session.endCameraRawGeometryGuideDrawing()
                } else {
                    session.beginCameraRawGeometryGuideDrawing()
                }
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
                .accessibilityIdentifier("geometryGuideCount")
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
                    // One owner of the keystone at a time: a solver Upright mode, or an advanced guide tool that
                    // solves instead of it. Anything else would be a slider that visibly does nothing.
                    let keystoneEnabled = geometry.upright == .off && !tools.kind.ownsSolver

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
                        Text(tools.kind.ownsSolver
                             ? "Vertical, Horizontal, and Rotate stay off while \(tools.kind.rawValue) is solving the upright. Choose Automatic to use them again."
                             : "Vertical, Horizontal, and Rotate stay off while Guided or Auto is solving the upright.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("geometryKeystoneNote")
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

                    // Advanced Perspective Tools are appended last, after Horizon.
                    advancedPerspectiveSection

                    // Miniature / Tilt-Shift is appended after the advanced tools, keeping the
                    // additive order this milestone continues: nothing above moves.
                    miniatureSection
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

    // MARK: - Advanced Perspective Tools (appended last, inside Advanced Geometry)

    /// Compact disclosure for the seven perspective tool kinds. The tools reuse `CameraRawPerspectiveToolState`
    /// and `CameraRawPerspectiveTools`; nothing here solves a transform, and nothing here is applied until its
    /// points are valid. Collapsed by default, so an existing workflow is untouched.
    private var advancedPerspectiveSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().padding(.vertical, 2)

            // The disclosure button and the active-tool name sit side by side rather than nested: a SwiftUI button
            // merges its children into one accessibility element, which swallowed the status identifier and left
            // no way to read or drive it.
            HStack(spacing: 6) {
                Button {
                    advancedPerspectiveExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: advancedPerspectiveExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .frame(width: 10)
                        Text("Advanced Perspective Tools")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Guides, Rectangle, Eight Point and Manual Keystone, on top of Upright.")
                .accessibilityIdentifier("advancedPerspectiveDisclosure")
                .accessibilityLabel("Advanced Perspective Tools")
                .accessibilityValue(advancedPerspectiveExpanded ? "Expanded" : "Collapsed")

                Text(tools.kind == .automatic ? "Off" : tools.kind.rawValue)
                    .font(.caption2)
                    .foregroundStyle(tools.kind == .automatic ? Color.secondary : Color.accentColor)
                    .help("The perspective tool in use right now.")
                    .accessibilityIdentifier("advancedPerspectiveActiveTool")
                    .accessibilityLabel("Active Perspective Tool")
                    .accessibilityValue(tools.kind == .automatic ? "Off" : tools.kind.rawValue)
            }

            if advancedPerspectiveExpanded {
                advancedPerspectiveContent
                    .padding(.top, 4)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var advancedPerspectiveContent: some View {
        Picker("Tool", selection: Binding(
            get: { tools.kind },
            set: { session.selectCameraRawPerspectiveTool($0) }
        )) {
            // Stability first: the menu lists every kind in its declared order, so a screenshot and a UI guard
            // read the same list. Each row carries its own stable identifier.
            ForEach(CameraRawPerspectiveToolKind.allCases, id: \.self) { kind in
                Text(kind.rawValue)
                    .tag(kind)
                    .accessibilityIdentifier("advancedPerspectiveTool_\(kind.tagIdentifier)")
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Automatic leaves the Upright mode above in charge. Manual Keystone uses the sliders above.")
        .accessibilityIdentifier("advancedPerspectiveToolPicker")
        .accessibilityLabel("Perspective Tool")
        .accessibilityValue(tools.kind.rawValue)

        Text(tools.kind.instructions)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("advancedPerspectiveInstructions")

        if tools.kind.drawsOnCanvas {
            drawingButton
            if !activeCountText.isEmpty {
                Text(activeCountText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("advancedPerspectiveCount")
            }
            if let issue = session.cameraRawPerspectiveToolIssue, activeCount > 0 {
                Text(issue.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("advancedPerspectiveIssue")
            }
            if activeCount > 0 {
                Button(tools.kind == .rectangle ? "Clear Rectangle" : "Clear Lines") {
                    session.clearCameraRawPerspectiveTool()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .help("Removes only this tool's points. Other tools keep theirs.")
                .accessibilityIdentifier("advancedPerspectiveClear")
                .accessibilityLabel("Clear This Tool")
                .padding(.top, 1)
            }
        } else if tools.kind == .manualKeystone {
            // The sliders themselves live in Manual Transformations; this only reports what they say, so there is
            // no second set of controls to disagree with the first.
            Text(String(format: "Vertical %+.0f · Horizontal %+.0f · Rotate %+.1f°",
                        geometry.vertical, geometry.horizontal, geometry.rotate))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("The Manual Transformations sliders above, which stay the one owner of these numbers.")
                .accessibilityIdentifier("advancedPerspectiveManualSummary")
            if geometry.upright != .off {
                // The stored Upright mode is untouched — only the rendered copy stands aside — so switching back to
                // Automatic brings the Upright correction straight back. Say that, rather than claiming it was turned off.
                Text("While Manual Keystone is selected, these sliders correct the picture instead of the Upright mode above. Your Upright setting is kept for when you choose Automatic again.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var drawingButton: some View {
        let drawing = session.filterEdit?.drawingCameraRawPerspectiveTool == true
        return Button {
            if drawing {
                session.endCameraRawPerspectiveToolDrawing()
            } else {
                session.beginCameraRawPerspectiveToolDrawing()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: drawing ? "pencil.line" : "pencil")
                    .font(.system(size: 11, weight: .medium))
                Text(drawing ? "Stop Drawing" : "Draw on Image")
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
        .help("Draws this tool's reference points on the preview. Escape cancels an unfinished one.")
        .accessibilityIdentifier("advancedPerspectiveDraw")
        .accessibilityLabel(drawing ? "Stop Drawing" : "Draw on Image")
    }

    /// The active tool's own point count, in the words that tool uses: guides, corners, or segments.
    private var activeCountText: String {
        switch tools.kind {
        case .automatic, .manualKeystone:
            return ""
        case .verticalGuides, .horizontalGuides:
            return "\(activeCount) of \(CameraRawPerspectiveToolState.capacity(for: .vertical)) lines"
        case .combinedGuides:
            return "\(tools.verticalGuides.count) vertical · \(tools.horizontalGuides.count) horizontal"
        case .rectangle:
            return "\(activeCount) of 4 corners"
        case .eightPoint:
            return "\(activeCount) of 4 segments · \(activeCount * 2) of 8 endpoints"
        }
    }

    private var activeCount: Int {
        tools.guideCount(for: tools.kind)
    }

    // MARK: - Miniature / Tilt-Shift (appended last, after the advanced tools)

    /// Compact disclosure for the existing `CameraRawMiniature` engine, which has run in the
    /// pipeline since before it had controls. Nothing here renders: the section writes
    /// `CameraRawMiniatureSettings`, and `CameraRawSettings.applyResult` blurs through
    /// `CIMaskedVariableBlur` after geometry, as it always did. Collapsed by default, so an
    /// existing workflow is untouched until it is opened.
    private var miniatureSection: some View {
        let miniature = raw.miniature
        return VStack(alignment: .leading, spacing: 5) {
            Divider().padding(.vertical, 2)

            // The disclosure button and the active state sit side by side, the way the advanced
            // tools' header reads, so a screenshot and a UI guard see one stable identifier each.
            HStack(spacing: 6) {
                Button {
                    miniatureExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: miniatureExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .frame(width: 10)
                        Text("Miniature / Tilt-Shift")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Blurs everything outside a sharp focus band or region, through the existing Core Image miniature engine.")
                .accessibilityIdentifier("miniatureDisclosure")
                .accessibilityLabel("Miniature Tilt-Shift")
                .accessibilityValue(miniatureExpanded ? "Expanded" : "Collapsed")

                Text(miniature.strength > 0 ? "On" : "Off")
                    .font(.caption2)
                    .foregroundStyle(miniature.strength > 0 ? Color.accentColor : Color.secondary)
                    .help("Whether the miniature effect is changing the picture right now.")
                    .accessibilityIdentifier("miniatureActiveState")
                    .accessibilityLabel("Miniature State")
                    .accessibilityValue(miniature.strength > 0 ? "On" : "Off")
            }

            if miniatureExpanded {
                miniatureContent
                    .padding(.top, 4)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var miniatureContent: some View {
        let miniature = raw.miniature
        Picker("Shape", selection: Binding(
            get: { miniature.shape },
            set: { shape in update { $0.cameraRaw.miniature.shape = shape } }
        )) {
            ForEach(CameraRawMiniatureShape.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Linear blurs above and below a sharp band; Circular blurs outside a sharp region.")
        .accessibilityIdentifier("miniatureShapePicker")
        .accessibilityLabel("Miniature Shape")

        miniatureSlider("Amount", \.strength, reset: 0,
                        help: "Blur strength outside the focus. 0 leaves the picture alone.",
                        identifier: "miniatureAmount")

        // Angle only shapes a linear band; a circular focus has no direction to tilt.
        if miniature.shape == .linear {
            miniatureSlider("Angle", \.angleDegrees, reset: 0,
                            help: "Tilts the focus band. 0° is horizontal.",
                            identifier: "miniatureAngle")
        }

        miniatureSlider("Focus Size", \.focusSize, reset: 0.2,
                        help: "Half-width of the sharp band, or the sharp region's radius, as a share of the longer side.",
                        identifier: "miniatureFocusSize")
        miniatureSlider("Falloff", \.falloff, reset: 40,
                        help: "How gradually the sharp focus gives way to the blur.")
        miniatureSlider("Center X", \.centerX, reset: 0.5,
                        help: "The focus band or region's center, across the picture.",
                        identifier: "miniatureCenterX")
        miniatureSlider("Center Y", \.centerY, reset: 0.5,
                        help: "The focus band or region's center, down the picture.",
                        identifier: "miniatureCenterY")

        Toggle("Symmetric Blur", isOn: Binding(
            get: { miniature.symmetricBlur },
            set: { value in update { $0.cameraRaw.miniature.symmetricBlur = value } }
        ))
        .font(.system(size: 11))
        .help("Linear only. On, both sides of the band blur; off, only one side does.")
        .accessibilityIdentifier("miniatureSymmetricBlur")

        HStack(spacing: 10) {
            Button {
                if session.filterEdit?.movesCameraRawMiniatureFocus == true {
                    session.endCameraRawMiniatureFocusInteraction()
                } else {
                    session.beginCameraRawMiniatureFocusInteraction()
                }
            } label: {
                Label("Move Focus", systemImage: "scope")
            }
            .buttonStyle(.borderless)
            .tint(session.filterEdit?.movesCameraRawMiniatureFocus == true ? Color.accentColor : Color.secondary)
            .help("Click or drag on the preview to move the focus. Escape puts it back.")
            .accessibilityLabel("Move Miniature Focus")
            .accessibilityIdentifier("miniatureMoveFocus")
            .disabled(miniature.strength <= 0)
            Spacer(minLength: 0)
            Button("Reset Miniature") {
                update { $0.cameraRaw.miniature = CameraRawMiniatureSettings() }
                session.filterEdit?.movesCameraRawMiniatureFocus = false
                session.filterEdit?.cameraRawMiniatureDragOriginalCenter = nil
            }
            .font(.system(size: 11))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Puts the miniature effect back to Off with its defaults.")
            .accessibilityIdentifier("miniatureReset")
            .accessibilityLabel("Reset Miniature")
        }
        .opacity(miniature.strength > 0 ? 1 : 0.5)
    }

    private func miniatureSlider(_ title: String,
                                 _ key: WritableKeyPath<CameraRawMiniatureSettings, Double>,
                                 reset resetValue: Double,
                                 help: String,
                                 identifier: String? = nil) -> some View {
        let value = raw.miniature[keyPath: key]
        let range = key == \.focusSize ? CameraRawMiniatureSettings.sizeRange : CameraRawMiniatureSettings.unitRange
        let decimals = key == \.focusSize ? 2 : 0
        return HStack(spacing: 8) {
            Text(title)
                .frame(minWidth: 64, alignment: .leading)
                .help(help)
                .font(.system(size: 11))
                .lineLimit(1)

            CameraRawSlider(value: value, range: range, track: .plain, help: help,
                            onChange: { rawValue in update { $0.cameraRaw.miniature[keyPath: key] = decimals == 0 ? rawValue.rounded() : rawValue } },
                            onReset: { update { $0.cameraRaw.miniature[keyPath: key] = resetValue } })

            TextField(title,
                      value: Binding(
                          get: { raw.miniature[keyPath: key] },
                          set: { newValue in update { $0.cameraRaw.miniature[keyPath: key] = newValue } }
                      ),
                      format: .number.precision(.fractionLength(decimals)))
                .frame(width: 44)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .help(help)
                .font(.system(size: 10, design: .monospaced))
        }
        .accessibilityIdentifier(identifier ?? "")
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
