import SwiftUI

/// Tool header for the document-level ReShape mesh editor.
struct MeshWarpControls: View {
    @Bindable var session: EditorSession

    private var preset: Binding<MeshWarpGrid.Preset> {
        Binding(
            get: {
                let columns = session.meshWarpEdit?.mesh.pointColumns ?? MeshWarpGrid.Preset.points8.rawValue
                return MeshWarpGrid.Preset(rawValue: columns) ?? .points8
            },
            set: { session.setMeshWarpPreset($0) }
        )
    }

    private var sticky: Binding<Bool> {
        Binding(
            get: { session.meshWarpEdit?.mesh.stickyBorders ?? true },
            set: { session.setMeshWarpStickyBorders($0) }
        )
    }

    private var propagation: Binding<Double> {
        Binding(
            get: { Double(session.meshWarpEdit?.mesh.propagation ?? 0.25) },
            set: { session.setMeshWarpPropagation(Float($0)) }
        )
    }

    private var selectedCount: Int {
        guard let edit = session.meshWarpEdit else { return 0 }
        return edit.selection.indices(in: edit.mesh).count
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("ReShape").font(ToolHeaderStyle.titleFont)
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    Picker("Grid", selection: preset) {
                        ForEach(MeshWarpGrid.Preset.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("Control-point grid size (points, not cells)")
                    .accessibilityIdentifier("reshapeGridPreset")

                    Toggle("Sticky Borders", isOn: sticky)
                        .toggleStyle(.checkbox)
                        .help("Keep edge control points fixed while dragging interior points")
                        .accessibilityIdentifier("reshapeStickyBorders")

                    Text("Propagation").scrubbable(sensitivity: 0.01, value: Binding(
                        get: { CGFloat(propagation.wrappedValue) },
                        set: { propagation.wrappedValue = Double($0) }
                    ), range: 0...1)
                    AppSlider(value: Binding(
                        get: { CGFloat(propagation.wrappedValue) },
                        set: { propagation.wrappedValue = Double($0) }
                    ), in: 0...1).frame(width: 100)
                    .help("How far a drag pulls neighboring control points (0 = only the selected point)")
                    .accessibilityIdentifier("reshapePropagation")

                    if let warning = session.meshWarpEdit?.lastWarning {
                        Text(warning).foregroundStyle(.orange).lineLimit(1)
                    }

                    // Selection and topology, appended after the original controls. Hidden entirely
                    // when no mesh is open so the bar reads exactly as it did in a plain document.
                    if let edit = session.meshWarpEdit {
                        Divider().frame(height: 20)

                        Picker("Transform", selection: Binding(
                            get: { edit.transformMode },
                            set: { session.meshWarpSetTransformMode($0) }
                        )) {
                            ForEach(MeshWarpTransformMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .help("What a drag does: move the selected points, rotate them about their barycenter, or scale them from it")
                        .accessibilityIdentifier("reshapeTransformMode")

                        Button("Subdivide") { session.meshWarpSubdivideSelection() }
                            .help("Split each mesh cell touching the selection into four finer cells")
                            .accessibilityIdentifier("reshapeSubdivide")
                        Button("Merge") { session.meshWarpMergeSelection() }
                            .help("Merge complete groups of four subdivided cells back into one")
                            .accessibilityIdentifier("reshapeMerge")

                        Menu {
                            Menu("Local Perspective") {
                                Button("Draw Destination Rectangle…") { session.meshWarpBeginQuadDestination() }
                                    .disabled(edit.transformMode != .move || edit.selection.indices(in: edit.mesh).count != 4)
                                    .help("Draw where the four selected points should go, then Apply. Exactly four points must be selected.")
                                    .accessibilityIdentifier("reshapeLocalPerspectiveDraw")
                                Button("Vertical") { session.applyMeshWarpLocalCorrection(
                                    .perspective(MeshWarpLocalPerspective(mode: .vertical, amount: localAmount))) }
                                    .accessibilityIdentifier("reshapeLocalPerspectiveVertical")
                                Button("Horizontal") { session.applyMeshWarpLocalCorrection(
                                    .perspective(MeshWarpLocalPerspective(mode: .horizontal, amount: localAmount))) }
                                    .accessibilityIdentifier("reshapeLocalPerspectiveHorizontal")
                                Button("Combined") { session.applyMeshWarpLocalCorrection(
                                    .perspective(MeshWarpLocalPerspective(mode: .combined, amount: localAmount))) }
                                    .accessibilityIdentifier("reshapeLocalPerspectiveCombined")
                            }
                            Menu("Local Horizon") {
                                ForEach(MeshWarpLocalHorizonMode.allCases, id: \.self) { mode in
                                    Button(mode.label) {
                                        if mode != .angle { session.meshWarpBeginHorizonReference() }
                                        else { applyHorizon(mode) }
                                    }
                                    .accessibilityIdentifier("reshapeLocalHorizon_\(mode.rawValue)")
                                }
                            }
                            Menu("Local Volume") {
                                ForEach(MeshWarpLocalVolumeMode.allCases, id: \.self) { mode in
                                    Button(mode.label) { session.applyMeshWarpLocalCorrection(
                                        .volume(MeshWarpLocalVolume(mode: mode, strength: volumeStrength,
                                                                    strengthVertical: volumeStrength))) }
                                        .accessibilityIdentifier("reshapeLocalVolume_\(mode.rawValue)")
                                }
                            }
                        } label: {
                            Text("Local Corrections")
                        }
                        .fixedSize()
                        .accessibilityIdentifier("reshapeLocalCorrections")

                        Button("Clear Selection") { session.meshWarpClearSelection() }
                            .disabled(selectedCount == 0)
                            .accessibilityIdentifier("reshapeClearSelection")

                        Text(selectedCount == 0 ? "No points selected"
                                                : "\(selectedCount) selected")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityIdentifier("reshapeSelectionCount")
                    }
                }
            }
            .scrollIndicators(.never)
            Spacer(minLength: 0)
            Button("Reset Mesh") { session.resetMeshWarp() }
                .disabled(session.meshWarpEdit == nil)
                .accessibilityIdentifier("reshapeReset")
            Button("Cancel") {
                session.cancelMeshWarp()
                if session.tool == .reshape { session.selectTool(.move) }
            }
                .disabled(session.meshWarpEdit == nil)
                .accessibilityIdentifier("reshapeCancel")
            Button("Apply") {
                session.applyMeshWarp()
                if session.meshWarpEdit == nil, session.tool == .reshape { session.selectTool(.move) }
            }
                .buttonStyle(.borderedProminent)
                .disabled(session.meshWarpEdit?.mesh.isIdentity != false)
                .accessibilityIdentifier("reshapeApply")
        }
        .padding(.horizontal, 18).toolHeaderBar().releasesFocusOnCommit(session)
        .disabled(session.showsBusy || session.document == nil)
    }

    // MARK: - Local correction parameters

    /// Shared Amount for the one-shot perspective and horizon corrections.
    private var localAmount: Float { 0.5 }

    /// Strength for the one-shot volume corrections.
    private var volumeStrength: Float { 0.15 }

    /// Angle-only Horizon runs at once; a reference mode needs its line drawn first, so it
    /// applies when the drag ends rather than here.
    private func applyHorizon(_ mode: MeshWarpLocalHorizonMode) {
        guard let horizon = session.meshWarpLocalHorizonCorrection(mode: mode, angleDegrees: 4,
                                                                  amount: localAmount) else { return }
        session.applyMeshWarpLocalCorrection(.horizon(horizon))
    }
}

extension MeshWarpTransformMode {
    var label: String {
        switch self {
        case .move: "Move"
        case .rotate: "Rotate"
        case .scale: "Scale"
        }
    }
}

extension MeshWarpLocalHorizonMode {
    var label: String {
        switch self {
        case .angle: "Angle…"
        case .horizontalReference: "Draw Horizontal Reference…"
        case .verticalReference: "Draw Vertical Reference…"
        }
    }
}

extension MeshWarpLocalVolumeMode {
    var label: String {
        switch self {
        case .horizontal: "Horizontal"
        case .vertical: "Vertical"
        case .radial: "Radial"
        case .combined: "Combined"
        }
    }
}
