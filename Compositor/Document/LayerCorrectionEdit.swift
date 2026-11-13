import CoreGraphics
import Foundation

extension EditorSession {
    /// Message when a destructive pixel edit would discard an editable correction stack / ReShape.
    func correctionStackDestructiveRefusal(for layer: ImageLayer) -> String? {
        if layer.correctionStack != nil {
            return "“\(layer.name)” has an editable geometry correction stack. Bake corrections before painting or applying filters."
        }
        return reshapeDestructiveRefusal(for: layer)
    }

    /// Builds a stack from the layer without writing (caller installs inside an undo entry).
    func makeCorrectionStack(for layer: ImageLayer) throws -> LayerCorrectionStack {
        if var stack = layer.correctionStack {
            try stack.validatePrecision()
            return stack
        }
        if let reshape = layer.reshape {
            var stack = LayerCorrectionStack.fromReshape(reshape)
            try stack.validatePrecision()
            return stack
        }
        guard let asset = layer.asset else {
            throw LayerCorrectionError.unsupported("The layer has no image to correct.")
        }
        guard asset.deep == nil, asset.image.bitsPerComponent <= 8, !DeepLayer.isHDR(asset.image) else {
            throw LayerCorrectionError.deepOrHDR
        }
        return LayerCorrectionStack(source: asset, nodes: [])
    }

    func addCorrection(kind: LayerCorrectionKind, layerID: UUID? = nil,
                       cameraRaw: CameraRawGeometryBackendSettings = CameraRawGeometryBackendSettings(),
                       meshPreset: MeshWarpGrid.Preset = .points8) throws {
        let id = layerID ?? activeLayerID
        guard canEditLayers, let id,
              let index = document?.layers.firstIndex(where: { $0.id == id }),
              var layer = document?.layers[index] else {
            throw LayerCorrectionError.missingNode
        }
        var stack = try makeCorrectionStack(for: layer)

        let node: LayerCorrectionNode
        switch kind {
        case .cameraRawGeometry:
            if LayerCorrectionStack.usesExpand(cameraRaw), stack.hasReshape {
                throw LayerCorrectionError.expandWithReshape
            }
            if stack.hasCameraRawGeometry {
                throw LayerCorrectionError.unsupported("This stack already has a Camera Raw geometry correction.")
            }
            node = .cameraRawGeometry(cameraRaw)
        case .reshape:
            if stack.hasReshape {
                throw LayerCorrectionError.unsupported("This stack already has a ReShape correction.")
            }
            let input = try LayerCorrectionRenderer.renderCopy(stack)
            guard let mesh = MeshWarpGrid.identity(pointColumns: meshPreset.rawValue,
                                                   pointRows: meshPreset.rawValue,
                                                   stickyBorders: true, propagation: 0.25) else {
                throw LayerCorrectionError.malformed("identity mesh")
            }
            node = .reshape(mesh: mesh, imageWidth: input.image.width, imageHeight: input.image.height)
        }

        beginEdit("Add Correction")
        stack.nodes.append(node)
        stack.bumpRevision()
        try commitCorrectionStack(stack, on: &layer, index: index, expandPlacement: true)
        endEdit()
    }

    func editCorrection(nodeID: UUID, layerID: UUID? = nil,
                        update: (inout LayerCorrectionNode) -> Void) throws {
        let id = layerID ?? activeLayerID
        guard canEditLayers, let id,
              let index = document?.layers.firstIndex(where: { $0.id == id }),
              var layer = document?.layers[index],
              var stack = layer.correctionStack,
              let nodeIndex = stack.nodes.firstIndex(where: { $0.id == nodeID }) else {
            throw LayerCorrectionError.missingNode
        }
        beginEdit("Edit Correction")
        update(&stack.nodes[nodeIndex])
        if stack.nodes[nodeIndex].kind == .cameraRawGeometry {
            stack.nodes[nodeIndex].cameraRaw = stack.nodes[nodeIndex].cameraRaw.normalized
            if LayerCorrectionStack.usesExpand(stack.nodes[nodeIndex].cameraRaw), stack.hasReshape {
                endEdit()
                throw LayerCorrectionError.expandWithReshape
            }
        }
        stack.invalidateFromIndex(nodeIndex)
        try commitCorrectionStack(stack, on: &layer, index: index, expandPlacement: true)
        endEdit()
    }

    func setCorrectionEnabled(nodeID: UUID, enabled: Bool, layerID: UUID? = nil) throws {
        try editCorrection(nodeID: nodeID, layerID: layerID) { $0.enabled = enabled }
    }

    func resetCorrection(nodeID: UUID, layerID: UUID? = nil) throws {
        try editCorrection(nodeID: nodeID, layerID: layerID) { $0.resetParameters() }
    }

    func removeCorrection(nodeID: UUID, layerID: UUID? = nil) throws {
        let id = layerID ?? activeLayerID
        guard canEditLayers, let id,
              let index = document?.layers.firstIndex(where: { $0.id == id }),
              var layer = document?.layers[index],
              var stack = layer.correctionStack,
              let nodeIndex = stack.nodes.firstIndex(where: { $0.id == nodeID }) else {
            throw LayerCorrectionError.missingNode
        }
        beginEdit("Remove Correction")
        stack.nodes.remove(at: nodeIndex)
        stack.bumpRevision()
        if stack.nodes.isEmpty {
            // Empty stack: restore immutable source as display and clear stack/reshape.
            let source = stack.source
            var edited = try layerByEditingPixels(layer, asset: source, transform: layer.transform, mask: layer.mask)
            edited.correctionStack = nil
            edited.reshape = nil
            document?.layers[index] = edited
        } else {
            try commitCorrectionStack(stack, on: &layer, index: index, expandPlacement: true)
        }
        endEdit()
    }

    func reorderCorrection(nodeID: UUID, before beforeID: UUID?, layerID: UUID? = nil) throws {
        let id = layerID ?? activeLayerID
        guard canEditLayers, let id,
              let index = document?.layers.firstIndex(where: { $0.id == id }),
              var layer = document?.layers[index],
              var stack = layer.correctionStack else {
            throw LayerCorrectionError.missingNode
        }
        switch stack.canReorder(from: nodeID, toBefore: beforeID) {
        case .failure(let error): throw error
        case .success:
            break
        }
        guard let fromIndex = stack.nodes.firstIndex(where: { $0.id == nodeID }) else {
            throw LayerCorrectionError.missingNode
        }
        beginEdit("Reorder Correction")
        let node = stack.nodes.remove(at: fromIndex)
        if let beforeID, let target = stack.nodes.firstIndex(where: { $0.id == beforeID }) {
            stack.nodes.insert(node, at: target)
        } else {
            stack.nodes.append(node)
        }
        stack.bumpRevision()
        try commitCorrectionStack(stack, on: &layer, index: index, expandPlacement: true)
        endEdit()
    }

    /// Bakes one node into the immutable source and removes it from the stack.
    func bakeCorrection(nodeID: UUID, layerID: UUID? = nil) throws {
        let id = layerID ?? activeLayerID
        guard canEditLayers, let id,
              let index = document?.layers.firstIndex(where: { $0.id == id }),
              var layer = document?.layers[index],
              var stack = layer.correctionStack,
              let nodeIndex = stack.nodes.firstIndex(where: { $0.id == nodeID }) else {
            throw LayerCorrectionError.missingNode
        }
        beginEdit("Bake Correction")
        // Render through the baked node (inclusive), then make that the new source.
        var prefix = stack
        prefix.nodes = Array(stack.nodes.prefix(through: nodeIndex))
        let rendered = try LayerCorrectionRenderer.render(&prefix)
        let thumb = try PixelAdjust.thumbnail(of: rendered.image)
        let bakedSource = ImportedImage(image: rendered.image, thumbnail: thumb, name: layer.name)
        var remaining = Array(stack.nodes.suffix(from: nodeIndex + 1))
        // Remap reshape mesh dimensions when they still match the baked output size.
        for i in remaining.indices where remaining[i].kind == .reshape {
            remaining[i].meshImageWidth = bakedSource.image.width
            remaining[i].meshImageHeight = bakedSource.image.height
        }
        if remaining.isEmpty {
            var edited = try layerByEditingPixels(layer, asset: bakedSource, transform: layer.transform, mask: layer.mask)
            if let expansion = rendered.expansion {
                edited.transform = expansion.layerTransform(from: layer.transform)
            }
            edited.correctionStack = nil
            edited.reshape = nil
            document?.layers[index] = edited
        } else {
            var newStack = LayerCorrectionStack(source: bakedSource, nodes: remaining)
            newStack.bumpRevision()
            try commitCorrectionStack(newStack, on: &layer, index: index, expandPlacement: true)
        }
        endEdit()
    }

    /// Bakes every correction into ordinary layer pixels.
    func bakeAllCorrections(layerID: UUID? = nil) throws {
        let id = layerID ?? activeLayerID
        guard canEditLayers, let id,
              let index = document?.layers.firstIndex(where: { $0.id == id }),
              var layer = document?.layers[index] else {
            throw LayerCorrectionError.missingNode
        }
        if layer.correctionStack == nil, layer.reshape != nil {
            bakeReshape(layerID: id)
            return
        }
        guard var stack = layer.correctionStack else { return }
        beginEdit("Bake Corrections")
        let rendered = try LayerCorrectionRenderer.render(&stack)
        let thumb = try PixelAdjust.thumbnail(of: rendered.image)
        let display = ImportedImage(image: rendered.image, thumbnail: thumb, name: layer.name)
        var edited = try layerByEditingPixels(layer, asset: display, transform: layer.transform, mask: layer.mask)
        if let expansion = rendered.expansion {
            edited.transform = expansion.layerTransform(from: layer.transform)
        }
        edited.correctionStack = nil
        edited.reshape = nil
        document?.layers[index] = edited
        if meshWarpEdit?.layerID == id { cancelMeshWarp() }
        endEdit()
    }

    /// Re-renders display from the stack without a new undo entry (caller owns history).
    func refreshCorrectionStackDisplay(layerID: UUID) throws {
        guard let index = document?.layers.firstIndex(where: { $0.id == layerID }),
              var layer = document?.layers[index],
              var stack = layer.correctionStack else { return }
        try commitCorrectionStack(stack, on: &layer, index: index, expandPlacement: false)
    }

    /// Writes rendered display + synced reshape projection. Caller owns `beginEdit`/`endEdit`.
    fileprivate func commitCorrectionStack(_ stack: LayerCorrectionStack,
                                           on layer: inout ImageLayer,
                                           index: Int,
                                           expandPlacement: Bool) throws {
        var working = stack
        try working.validatePrecision()
        try working.validateStageDimensions()
        let rendered = try LayerCorrectionRenderer.render(&working)
        let thumb = try PixelAdjust.thumbnail(of: rendered.image)
        let display = ImportedImage(image: rendered.image, thumbnail: thumb, name: layer.name)

        let used = (document?.layers ?? []).reduce(0) { total, candidate in
            let assetPixels = candidate.id == layer.id ? 0
                : (candidate.asset.map { $0.image.width * $0.image.height } ?? 0)
            let sourcePixels: Int = {
                if candidate.id == layer.id { return 0 }
                if let stack = candidate.correctionStack {
                    return stack.source.image.width * stack.source.image.height
                }
                return candidate.reshape.map { $0.source.image.width * $0.source.image.height } ?? 0
            }()
            let frames = candidate.gifAnimation?.framePixels.values
                .reduce(0) { $0 + $1.image.width * $1.image.height } ?? 0
            return total + assetPixels + sourcePixels + frames
        }
        let needed = display.image.width * display.image.height
            + working.source.image.width * working.source.image.height
        guard needed <= DocumentLimits.documentPixelBudget - used else {
            throw LayerCorrectionError.budget("document megapixel limit")
        }

        var transform = layer.transform
        if expandPlacement, let expansion = rendered.expansion {
            transform = expansion.layerTransform(from: layer.transform)
        }
        var edited = try layerByEditingPixels(layer, asset: display, transform: transform, mask: layer.mask)
        edited.correctionStack = working
        edited.reshape = working.projectedReshape
        document?.layers[index] = edited
        brushRevision += 1
    }

    /// Installs or updates a reshape node from a MeshWarp edit commit, preserving other nodes.
    func applyMeshWarpIntoCorrectionStack(edit: MeshWarpEdit, mesh: MeshWarpGrid,
                                          display: ImportedImage, source: ImportedImage,
                                          layer: ImageLayer, index: Int) throws {
        var stack: LayerCorrectionStack
        if let existing = layer.correctionStack {
            stack = existing
            // Source must remain the stack's immutable original. MeshWarpEdit may be sampling an
            // upstream stage image; never replace stack.source with that intermediate.
        } else {
            stack = LayerCorrectionStack(source: source, nodes: [])
        }

        if let reshapeIndex = stack.nodes.firstIndex(where: { $0.kind == .reshape }) {
            stack.nodes[reshapeIndex].mesh = mesh
            stack.nodes[reshapeIndex].meshImageWidth = source.image.width
            stack.nodes[reshapeIndex].meshImageHeight = source.image.height
            stack.nodes[reshapeIndex].enabled = true
            stack.invalidateFromIndex(reshapeIndex)
        } else {
            let node = LayerCorrectionNode.reshape(mesh: mesh,
                                                   imageWidth: source.image.width,
                                                   imageHeight: source.image.height)
            stack.nodes.append(node)
            stack.bumpRevision()
        }

        // When the stack has upstream Camera Raw, MeshWarpEdit's originalImage is the upstream
        // output, not the immutable stack source. In that case mesh dims match upstream output;
        // keep stack.source as the true original and set mesh dims to the edit image size.
        if stack.hasCameraRawGeometry,
           let reshapeIndex = stack.nodes.firstIndex(where: { $0.kind == .reshape }) {
            // For dimension-preserving stacks, upstream output size == source size.
            stack.nodes[reshapeIndex].meshImageWidth = edit.width
            stack.nodes[reshapeIndex].meshImageHeight = edit.height
            // If edit was opened on stack.source (reshape-only or CR after reshape), fine.
            // If edit was opened on upstream-rendered pixels, those pixels are NOT the immutable
            // source — MeshWarpEdit.begin must open on the correct stage (see beginMeshWarp).
        }

        var mutable = layer
        // Prefer provided display when stack is reshape-only (avoids double raster).
        if stack.nodes.count == 1, stack.nodes[0].kind == .reshape {
            var edited = try layerByEditingPixels(layer, asset: display, transform: layer.transform, mask: layer.mask)
            edited.correctionStack = stack
            edited.reshape = LayerReshape(mesh: mesh, source: stack.source)
            document?.layers[index] = edited
            return
        }
        try commitCorrectionStack(stack, on: &mutable, index: index, expandPlacement: false)
    }
}
