import SwiftUI
import AppKit

/// Inspector for a layer's non-destructive correction stack (Camera Raw Geometry, Camera Raw Full, ReShape).
struct CorrectionStackInspector: View {
    @Bindable var session: EditorSession
    let layerID: UUID

    @State private var selectedNodeID: UUID?
    @State private var showNodeEditUnsupported = false

    private var layer: ImageLayer? {
        session.document?.layers.first(where: { $0.id == layerID })
    }

    private var stack: LayerCorrectionStack? {
        layer?.correctionStack
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Corrections").font(.headline)
                Spacer()
                Menu {
                    // Add Camera Raw correction
                    if canAddCameraRaw {
                        Button("Add Camera Raw Correction") {
                            do {
                                try session.addCorrection(kind: .cameraRawFull, layerID: layerID)
                                selectedNodeID = layer?.correctionStack?.nodes.last?.id
                            } catch {
                                session.brushError = error.localizedDescription
                            }
                        }
                        .disabled(session.showsBusy)
                    }
                    // Add Camera Raw Geometry
                    if canAddCameraRawGeometry {
                        Button("Add Camera Raw Geometry") {
                            do {
                                try session.addCorrection(kind: .cameraRawGeometry, layerID: layerID)
                                selectedNodeID = layer?.correctionStack?.nodes.last?.id
                            } catch {
                                session.brushError = error.localizedDescription
                            }
                        }
                        .disabled(session.showsBusy)
                    }
                    // Add ReShape
                    if canAddReshape {
                        Button("Add ReShape Correction") {
                            do {
                                try session.addCorrection(kind: .reshape, layerID: layerID)
                                selectedNodeID = layer?.correctionStack?.nodes.last?.id
                            } catch {
                                session.brushError = error.localizedDescription
                            }
                        }
                        .disabled(session.showsBusy)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .help("Add a correction node")
                .disabled(!canAddAnyCorrection)
            }

            // Stack list
            if let stack, !stack.nodes.isEmpty {
                ForEach(Array(stack.nodes.enumerated()), id: \.element.id) { index, node in
                    CorrectionStackRow(
                        session: session,
                        layerID: layerID,
                        node: node,
                        isSelected: selectedNodeID == node.id,
                        index: index,
                        total: stack.nodes.count,
                        onSelect: { selectedNodeID = node.id },
                        onEdit: { editNode(node) },
                        onToggle: { toggleNode(node) },
                        onReset: { resetNode(node) },
                        onRemove: { removeNode(node) },
                        onBake: { bakeNode(node) },
                        onMoveUp: { moveNodeUp(node) },
                        onMoveDown: { moveNodeDown(node) }
                    )
                }
            } else {
                Text("No corrections").font(.caption).foregroundStyle(.secondary)
            }

            // Bake all button
            if let stack, !stack.nodes.isEmpty {
                Divider()
                HStack {
                    Spacer()
                    Button("Bake All Corrections") {
                        do {
                            try session.bakeAllCorrections(layerID: layerID)
                        } catch {
                            session.brushError = error.localizedDescription
                        }
                    }
                    .disabled(!session.canEditLayers || session.showsBusy)
                    .help("Collapse all corrections into the layer's pixels")
                }
            }
        }
        .padding(.vertical, 8)
        .onAppear {
            if selectedNodeID == nil, let first = stack?.nodes.first?.id {
                selectedNodeID = first
            }
        }
        .onChange(of: stack?.nodes.count) { _, _ in
            if selectedNodeID == nil, let first = stack?.nodes.first?.id {
                selectedNodeID = first
            }
        }
        .alert("Cannot edit this node", isPresented: $showNodeEditUnsupported) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This correction node type cannot be edited in the Camera Raw editor. Use ReShape for geometry edits, or bake the node to apply it destructively.")
        }
    }

    /// Whether the active layer can host a new correction stack (8-bit compatible).
    private var canCreateStack: Bool {
        guard let layer = layer, let asset = layer.asset else { return false }
        return session.canEditLayers
            && asset.deep == nil
            && asset.image.bitsPerComponent <= 8
            && !DeepLayer.isHDR(asset.image)
    }

    private var canAddCameraRaw: Bool {
        canCreateStack && !stackHasAnyCameraRaw
    }

    private var canAddCameraRawGeometry: Bool {
        canCreateStack && !stackHasAnyCameraRaw
    }

    private var canAddReshape: Bool {
        canCreateStack && !(stack?.hasReshape ?? false)
    }

    private var canAddAnyCorrection: Bool {
        canAddCameraRaw || canAddCameraRawGeometry || canAddReshape
    }

    /// True when the stack already holds any Camera Raw correction (full or geometry).
    private var stackHasAnyCameraRaw: Bool {
        guard let stack else { return false }
        return stack.hasCameraRawFull || stack.hasCameraRawGeometry
    }

    private func editNode(_ node: LayerCorrectionNode) {
        selectedNodeID = node.id
        switch node.kind {
        case .cameraRawFull:
            // Begin a node-scoped Camera Raw edit: commits back to this exact node.
            guard session.beginCameraRawNodeEdit(layerID: layerID, nodeID: node.id) else {
                session.brushError = "Could not open the Camera Raw editor for this node."
                return
            }
        case .cameraRawGeometry:
            // Camera Raw Geometry nodes need their geometry controls, not the full
            // Camera Raw editor. Dedicated geometry editing is not yet available;
            // show a clear explanation rather than opening an unrelated editor.
            showNodeEditUnsupported = true
        case .reshape:
            // Open ReShape editor for this node
            session.beginMeshWarpForCorrectionStack(layerID: layerID, nodeID: node.id)
        }
    }

    private func toggleNode(_ node: LayerCorrectionNode) {
        do {
            try session.setCorrectionEnabled(nodeID: node.id, enabled: !node.enabled, layerID: layerID)
        } catch {
            session.brushError = error.localizedDescription
        }
    }

    private func resetNode(_ node: LayerCorrectionNode) {
        do {
            try session.resetCorrection(nodeID: node.id, layerID: layerID)
        } catch {
            session.brushError = error.localizedDescription
        }
    }

    private func removeNode(_ node: LayerCorrectionNode) {
        do {
            try session.removeCorrection(nodeID: node.id, layerID: layerID)
            selectedNodeID = nil
        } catch {
            session.brushError = error.localizedDescription
        }
    }

    private func bakeNode(_ node: LayerCorrectionNode) {
        do {
            try session.bakeCorrection(nodeID: node.id, layerID: layerID)
        } catch {
            session.brushError = error.localizedDescription
        }
    }

    private func moveNodeUp(_ node: LayerCorrectionNode) {
        guard let stack else { return }
        let currentIndex = stack.nodes.firstIndex(where: { $0.id == node.id }) ?? 0
        guard currentIndex > 0 else { return }
        let beforeID = stack.nodes[currentIndex - 1].id
        do {
            try session.reorderCorrection(nodeID: node.id, before: beforeID, layerID: layerID)
        } catch {
            session.brushError = error.localizedDescription
        }
    }

    private func moveNodeDown(_ node: LayerCorrectionNode) {
        guard let stack else { return }
        let currentIndex = stack.nodes.firstIndex(where: { $0.id == node.id }) ?? 0
        guard currentIndex < stack.nodes.count - 1 else { return }
        let beforeID = stack.nodes[currentIndex + 2].id
        do {
            try session.reorderCorrection(nodeID: node.id, before: beforeID, layerID: layerID)
        } catch {
            session.brushError = error.localizedDescription
        }
    }
}

private struct CorrectionStackRow: View {
    @Bindable var session: EditorSession
    let layerID: UUID
    let node: LayerCorrectionNode
    let isSelected: Bool
    let index: Int
    let total: Int
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onReset: () -> Void
    let onRemove: () -> Void
    let onBake: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                // Selection indicator
                Rectangle()
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .frame(width: 3, height: 24)
                    .overlay(Rectangle().stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))

                // Enabled toggle
                Button(action: onToggle) {
                    Image(systemName: node.enabled ? "eye" : "eye.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(node.enabled ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(node.enabled ? "Disable this correction" : "Enable this correction")
                .disabled(!session.canEditLayers)

                // Node type icon and name
                HStack(spacing: 6) {
                    Image(systemName: nodeIcon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(node.enabled ? Color.primary : Color.secondary)
                    Text(nodeDisplayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(node.enabled ? Color.primary : Color.secondary)
                }
                .onTapGesture { onSelect() }

                Spacer()

                // Move Up / Move Down
                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(!session.canEditLayers || index == 0)
                .help(index == 0 ? "Already at the top" : "Move correction up")

                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(!session.canEditLayers || index == total - 1)
                .help(index == total - 1 ? "Already at the bottom" : "Move correction down")

                // Node actions
                HStack(spacing: 4) {
                    // Edit button
                    Button(action: onEdit) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Edit \(nodeDisplayName) settings")
                    .disabled(!session.canEditLayers || !node.enabled)

                    // Reset button
                    Button(action: onReset) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Reset \(nodeDisplayName) to defaults")
                    .disabled(!session.canEditLayers || !node.enabled)

                    // Bake button
                    Button(action: onBake) {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Bake \(nodeDisplayName) into pixels")
                    .disabled(!session.canEditLayers || !node.enabled)

                    // Remove button
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(nodeDisplayName)")
                    .disabled(!session.canEditLayers)
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private var nodeIcon: String {
        switch node.kind {
        case .cameraRawFull: "camera.filters"
        case .cameraRawGeometry: "camera.viewfinder"
        case .reshape: "square.grid.3x3"
        }
    }

    private var nodeDisplayName: String {
        switch node.kind {
        case .cameraRawFull: "Camera Raw"
        case .cameraRawGeometry: "Camera Raw Geometry"
        case .reshape: "ReShape"
        }
    }
}
