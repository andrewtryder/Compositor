import AppKit
import SwiftUI

struct CameraRawGeometryControls: View {
    @Bindable var session: EditorSession
    private var settings: FilterSettings { session.filterEdit?.settings ?? FilterSettings() }
    private var raw: CameraRawSettings { settings.cameraRaw }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Upright").font(.subheadline)
            Picker("Upright", selection: uprightBinding) {
                ForEach(CameraRawUprightMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .help("Off leaves the picture as it is. Auto finds lines in the picture. Guided straightens from lines you draw.")
            if raw.geometry.upright == .guided {
                Button {
                    session.filterEdit?.drawingCameraRawGeometryGuide.toggle()
                    session.brushRevision += 1
                } label: {
                    Label("Draw Guides", systemImage: "line.diagonal")
                }
                .help("Draw lines on the preview that should be level or vertical.")
                .tint(session.filterEdit?.drawingCameraRawGeometryGuide == true ? Color.accentColor : Color.secondary)
                if session.filterEdit?.drawingCameraRawGeometryGuide == true {
                    Text("Drag on the layer to place a guide. One near-horizontal levels; two vertical or horizontal force parallels; four make a rectangle.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !raw.geometry.guides.isEmpty {
                    Button("Clear Guides") {
                        update { $0.cameraRaw.geometry.guides = [] }
                    }
                    .help("Remove every guide line.")
                }
            }
            if raw.geometry.upright.isAuto, raw.geometry.guides.isEmpty,
               session.filterEdit?.cameraRawUprightDetectionAttempted == true {
                Text("No strong lines found. Try Guided, or draw the picture’s upright edges.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Projection", selection: binding(\.projection)) {
                ForEach(CameraRawProjection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .help("Perspective allows stronger keystone. Rectilinear keeps the warp gentler.")
            let keystoneEnabled = raw.geometry.upright == .off
            geometrySlider("Vertical", \.vertical, help: "Straightens vertical lines toward the center.",
                           enabled: keystoneEnabled)
            geometrySlider("Horizontal", \.horizontal, help: "Straightens horizontal lines toward the center.",
                           enabled: keystoneEnabled)
            geometrySlider("Rotate", \.rotate, range: CameraRawGeometrySettings.rotateRange,
                           help: "Rotates the picture around its center.", enabled: keystoneEnabled)
            if !keystoneEnabled {
                Text("Vertical, Horizontal, and Rotate stay off while Guided or Auto is solving the upright.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            geometrySlider("Aspect", \.aspect, help: "Stretches width relative to height.")
            geometrySlider("Scale", \.scale, help: "Zooms the transformed picture within the frame.")
            geometrySlider("Offset X", \.offsetX, help: "Moves the picture left or right.")
            geometrySlider("Offset Y", \.offsetY, help: "Moves the picture up or down.")
            Toggle("Constrain Crop", isOn: binding(\.constrainCrop))
                .help("Crops empty edges after the transform and fits the result back into the frame.")
            Button("Reset Geometry") {
                session.resetCameraRaw(.geometry)
            }
            .help("Clears upright, guides, volume, and framing polish. Keeps the photo’s focal length for Volume Auto.")

            Text("Volume").font(.subheadline).padding(.top, 4)
            Picker("Volume Mode", selection: binding(\.volumeMode)) {
                ForEach(CameraRawVolumeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .help("Radial pulls the corners. Horizontal and Vertical bend one axis. Horizontal & Vertical applies both.")
            volumeSlider("Horizontal", \.volumeHorizontal, help: "Cylindrical volume along the width.")
            volumeSlider("Vertical", \.volumeVertical, help: "Cylindrical volume along the height.")
            volumeSlider("Radial", \.volumeRadial, help: "Spherical volume toward the corners.")
            HStack {
                Button("Auto") {
                    update { $0.cameraRaw.geometry.applyAutoVolumeFromFocal() }
                }
                .help("Sets the volume sliders from the photo’s focal length when EXIF is available.")
                .disabled(raw.geometry.focalLengthMm <= 0 || raw.geometry.sensorWidthMm <= 0)
                if raw.geometry.focalLengthMm > 0 {
                    Text(raw.geometry.sensorWidthMm > 0
                         ? String(format: "%.0f mm · sensor %.1f mm", raw.geometry.focalLengthMm, raw.geometry.sensorWidthMm)
                         : String(format: "%.0f mm", raw.geometry.focalLengthMm))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var uprightBinding: Binding<CameraRawUprightMode> {
        Binding(get: { raw.geometry.upright }, set: { mode in
            let previous = raw.geometry.upright
            if mode.isAuto, previous == .guided {
                session.filterEdit?.cameraRawManualGuides = raw.geometry.guides
            }
            if mode == .guided, let saved = session.filterEdit?.cameraRawManualGuides {
                update {
                    $0.cameraRaw.geometry.upright = mode
                    $0.cameraRaw.geometry.guides = saved
                }
                session.filterEdit?.drawingCameraRawGeometryGuide = false
                session.filterEdit?.cameraRawUprightDetectionAttempted = false
                return
            }
            update { $0.cameraRaw.geometry.upright = mode }
            if mode != .guided { session.filterEdit?.drawingCameraRawGeometryGuide = false }
            if mode.isAuto {
                Task { await session.applyCameraRawUprightDetection() }
            } else if mode == .off {
                session.filterEdit?.cameraRawUprightDetectionAttempted = false
            }
        })
    }

    private func binding<T>(_ key: WritableKeyPath<CameraRawGeometrySettings, T>) -> Binding<T> {
        Binding(get: { raw.geometry[keyPath: key] }, set: { value in update { $0.cameraRaw.geometry[keyPath: key] = value } })
    }

    private func geometrySlider(_ title: String, _ key: WritableKeyPath<CameraRawGeometrySettings, Double>,
                                range: ClosedRange<Double> = CameraRawGeometrySettings.toneRange, help: String,
                                enabled: Bool = true) -> some View {
        let value = raw.geometry[keyPath: key]
        return HStack(spacing: 10) {
            Text(title).frame(minWidth: CameraRawControls.labelWidth, alignment: .leading).help(help)
                .scrubbable(sensitivity: 1,
                            value: Binding(get: { raw.geometry[keyPath: key] },
                                           set: { newValue in update { $0.cameraRaw.geometry[keyPath: key] = newValue } }), range: range)
            CameraRawSlider(value: value, range: range, track: .plain, help: help,
                            onChange: { rawValue in update { $0.cameraRaw.geometry[keyPath: key] = rawValue.rounded() } },
                            onReset: { update { $0.cameraRaw.geometry[keyPath: key] = 0 } })
            TextField(title, value: Binding(get: { raw.geometry[keyPath: key] },
                                            set: { newValue in update { $0.cameraRaw.geometry[keyPath: key] = newValue } }),
                      format: .number.precision(.fractionLength(0)))
                .frame(width: 56).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).help(help)
        }
        .disabled(!enabled)
    }

    private func volumeSlider(_ title: String, _ key: WritableKeyPath<CameraRawGeometrySettings, Double>, help: String) -> some View {
        let range = CameraRawGeometrySettings.volumeRange
        let value = raw.geometry[keyPath: key]
        return HStack(spacing: 10) {
            Text(title).frame(minWidth: CameraRawControls.labelWidth, alignment: .leading).help(help)
                .scrubbable(sensitivity: 1,
                            value: Binding(get: { raw.geometry[keyPath: key] },
                                           set: { newValue in update { $0.cameraRaw.geometry[keyPath: key] = newValue } }), range: range)
            CameraRawSlider(value: value, range: range, track: .plain, help: help,
                            onChange: { rawValue in update { $0.cameraRaw.geometry[keyPath: key] = rawValue.rounded() } },
                            onReset: { update { $0.cameraRaw.geometry[keyPath: key] = 0 } })
            TextField(title, value: Binding(get: { raw.geometry[keyPath: key] },
                                            set: { newValue in update { $0.cameraRaw.geometry[keyPath: key] = newValue } }),
                      format: .number.precision(.fractionLength(0)))
                .frame(width: 56).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).help(help)
        }
    }

    private func update(_ change: (inout FilterSettings) -> Void) {
        var value = settings
        change(&value)
        session.updateFilter(value, preview: session.filterEdit?.preview ?? true)
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
        }
    }

    private func update(_ change: (inout FilterSettings) -> Void) {
        var value = settings
        change(&value)
        session.updateFilter(value, preview: session.filterEdit?.preview ?? true)
    }
}
