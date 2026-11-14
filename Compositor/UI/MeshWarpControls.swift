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
}
