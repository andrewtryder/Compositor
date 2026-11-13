import SwiftUI

/// Inspector for a layer's non-destructive correction stack (Camera Raw Geometry, Camera Raw Full, ReShape).
struct CorrectionStackInspector: View {
    @Bindable var session: EditorSession
    let layerID: UUID

    @State private var selectedNodeID: UUID?
    @State private var showAddMenu = false

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
                            try? session.addCorrection(kind: .cameraRawFull, layerID: layerID)
                            selectedNodeID = layer?.correctionStack?.nodes.last?.id
                        }
                        .disabled(session.showsBusy)
                    }
                    // Add Camera Raw Geometry
                    if canAddCameraRawGeometry {
                        Button("Add Camera Raw Geometry") {
                            try? session.addCorrection(kind: .cameraRawGeometry, layerID: layerID)
                            selectedNodeID = layer?.correctionStack?.nodes.last?.id
                        }
                        .disabled(session.showsBusy)
                    }
                    // Add ReShape
                    if canAddReshape {
                        Button("Add ReShape Correction") {
                            try? session.addCorrection(kind: .reshape, layerID: layerID)
                            selectedNodeID = layer?.correctionStack?.nodes.last?.id
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
                ForEach(stack.nodes) { node in
                    CorrectionStackRow(
                        session: session,
                        layerID: layerID,
                        node: node,
                        isSelected: selectedNodeID == node.id,
                        onSelect: { selectedNodeID = node.id },
                        onEdit: { editNode(node) },
                        onToggle: { toggleNode(node) },
                        onReset: { resetNode(node) },
                        onRemove: { removeNode(node) },
                        onBake: { bakeNode(node) }
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
                        try? session.bakeAllCorrections(layerID: layerID)
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
    }

    private var canAddCameraRaw: Bool {
        guard let stack else { return false }
        return !stack.hasCameraRawFull && !stack.hasCameraRawGeometry && session.canEditLayers
    }

    private var canAddCameraRawGeometry: Bool {
        guard let stack else { return false }
        return !stack.hasCameraRawGeometry && !stack.hasCameraRawFull && session.canEditLayers
    }

    private var canAddReshape: Bool {
        guard let stack else { return false }
        return !stack.hasReshape && session.canEditLayers
    }

    private var canAddAnyCorrection: Bool {
        canAddCameraRaw || canAddCameraRawGeometry || canAddReshape
    }

    private func editNode(_ node: LayerCorrectionNode) {
        selectedNodeID = node.id
        switch node.kind {
        case .cameraRawFull:
            session.beginFilter(.cameraRaw)
            session.filterEdit?.cameraRawTargetNodeID = node.id
        case .cameraRawGeometry:
            session.beginFilter(.cameraRaw)
            session.filterEdit?.cameraRawTargetNodeID = node.id
        case .reshape:
            // Open ReShape editor for this node
            session.beginMeshWarpForCorrectionStack(layerID: layerID, nodeID: node.id)
        }
    }

    private func toggleNode(_ node: LayerCorrectionNode) {
        try? session.setCorrectionEnabled(nodeID: node.id, enabled: !node.enabled, layerID: layerID)
    }

    private func resetNode(_ node: LayerCorrectionNode) {
        try? session.resetCorrection(nodeID: node.id, layerID: layerID)
    }

    private func removeNode(_ node: LayerCorrectionNode) {
        try? session.removeCorrection(nodeID: node.id, layerID: layerID)
        selectedNodeID = nil
    }

    private func bakeNode(_ node: LayerCorrectionNode) {
        try? session.bakeCorrection(nodeID: node.id, layerID: layerID)
    }
}

private struct CorrectionStackRow: View {
    @Bindable var session: EditorSession
    let layerID: UUID
    let node: LayerCorrectionNode
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onReset: () -> Void
    let onRemove: () -> Void
    let onBake: () -> Void

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