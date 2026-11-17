import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An additive Camera Raw preset control, placed adjacent to the ten adjustment sections without
/// replacing or reordering any of them. A preset carries only the groups it lists; everything else
/// on the panel is left exactly as it is.
struct CameraRawPresetsControls: View {
    @Bindable var session: EditorSession
    @State private var showingSave = false
    @State private var saveName = ""
    @State private var saveAffects: Set<CameraRawGroup> = []

    private var presets: [CameraRawPreset] { session.cameraRawPresets.all }
    private var selected: CameraRawPreset? {
        guard let id = session.filterEdit?.selectedCameraRawPresetID else { return nil }
        return presets.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Presets").font(.headline)
                Spacer(minLength: 0)
                Menu {
                    Button("Save Current Settings…") { showingSave = true }
                    Divider()
                    Button("Import…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [UTType.cameraRawPreset]
                        panel.allowsMultipleSelection = false
                        panel.begin { response in
                            guard response == .OK, let url = panel.url else { return }
                            if let imported = session.importCameraRawPreset(from: url) {
                                session.filterEdit?.selectedCameraRawPresetID = imported.id
                            }
                        }
                    }
                    Button("Export Selected…") {
                        guard let preset = selected else { return }
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [UTType.cameraRawPreset]
                        panel.nameFieldStringValue = preset.name
                        panel.begin { response in
                            guard response == .OK, let url = panel.url else { return }
                            session.exportCameraRawPreset(preset, to: url)
                        }
                    }
                    .disabled(selected == nil)
                } label: {
                    Label("Add Preset", systemImage: "plus.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(session.filterEdit?.committing == true)
                .help("Save the current Camera Raw settings as a named preset, or import one.")
            }

            if presets.isEmpty {
                Text("A preset saves the current Camera Raw settings under a name. Applying it replaces only "
                      + "the groups it carries, leaving everything else as it is.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                list
                if let selected {
                    applyControls(selected)
                }
            }
        }
        .sheet(isPresented: $showingSave) {
            saveSheet
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(presets, id: \.id) { preset in
                Button {
                    session.filterEdit?.selectedCameraRawPresetID = preset.id
                } label: {
                    HStack(spacing: 6) {
                        Text(preset.name).font(.caption).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(preset.groupsInOrder.map(\.rawValue).joined(separator: ", "))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(session.filterEdit?.selectedCameraRawPresetID == preset.id
                                ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Rename…") {
                        saveName = preset.name
                        showingSave = true
                    }
                    Button("Duplicate…") {
                        let copyName = preset.name + " Copy"
                        if let copy = session.duplicateCameraRawPreset(preset.id, named: copyName) {
                            session.filterEdit?.selectedCameraRawPresetID = copy.id
                        }
                    }
                    Button("Delete", role: .destructive) {
                        session.deleteCameraRawPreset(preset.id)
                        if session.filterEdit?.selectedCameraRawPresetID == preset.id {
                            session.filterEdit?.selectedCameraRawPresetID = nil
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(preset.name), \(preset.groupsInOrder.map(\.rawValue).joined(separator: ", "))")
            }
        }
    }

    private func applyControls(_ preset: CameraRawPreset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    session.applyCameraRawPreset(preset)
                } label: {
                    Label("Apply", systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(.borderless)
                .tint(Color.accentColor)
                .help("Apply this preset to the current Camera Raw settings. Undoable.")
                .accessibilityLabel("Apply Preset")

                Button {
                    session.filterEdit?.selectedCameraRawPresetID = nil
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(.borderless)
                .help("Close the preset's controls.")

                Spacer(minLength: 0)
            }
            Text("Affects: " + preset.groupsInOrder.map(\.rawValue).joined(separator: ", "))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Preset").font(.headline)
            TextField("Name", text: $saveName)
                .textFieldStyle(.roundedBorder)
            Text("This preset affects:").font(.caption).foregroundStyle(.secondary)
            ForEach(CameraRawGroup.panelOrder, id: \.rawValue) { group in
                Toggle(group.rawValue, isOn: Binding(
                    get: { saveAffects.contains(group) },
                    set: { if $0 { saveAffects.insert(group) } else { saveAffects.remove(group) } }
                ))
                .toggleStyle(.checkbox)
            }
            HStack {
                Button("Cancel") { showingSave = false }
                Spacer(minLength: 0)
                Button("Save") {
                    if let preset = session.saveCameraRawPreset(name: saveName, affects: saveAffects) {
                        session.filterEdit?.selectedCameraRawPresetID = preset.id
                    }
                    showingSave = false
                    saveName = ""
                    saveAffects = []
                }
                .disabled(saveName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

extension UTType {
    static let cameraRawPreset = UTType(exportedAs: "com.compositor.camera-raw-preset")
}
