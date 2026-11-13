import Foundation
import CoreGraphics

extension EditorSession {
    func projectSnapshot() -> ProjectSnapshot? {
        guard let document else { return nil }
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        var animations: [UUID: GIFAnimation] = [:]
        var reshapeSources: [UUID: ImportedImage] = [:]
        var reshapeMeshes: [UUID: MeshWarpPersistentState] = [:]
        var correctionSources: [UUID: ImportedImage] = [:]
        var correctionStacks: [UUID: LayerCorrectionStackPersistentState] = [:]
        var rawSources: [UUID: RawSourceAsset] = [:]
        let layers = document.layers.map { layer -> ProjectLayerRecord in
            let asset = displayedAsset(for: layer)
            if let asset { images[layer.id] = asset }
            if let mask = layer.mask { masks[layer.id] = mask.asset }
            var gif: ProjectGIFRecord?
            if let animation = currentGIFAnimation(for: layer) {
                animations[layer.id] = animation
                gif = ProjectGIFRecord(sourceFile: "\(layer.id.uuidString).gif", selectedFrameIndex: animation.selectedFrameIndex,
                    geometry: animation.geometry,
                    framePixels: animation.framePixels.keys.sorted().map {
                        ProjectGIFPixelsRecord(index: $0, imageFile: "\(layer.id.uuidString).frame-\($0).png")
                    }, deletedFrameIndices: animation.deletedFrameIndices.sorted(), frameOrder: animation.frameOrder,
                    timing: animation.timing == GIFFrameTiming() ? nil : ProjectGIFTimingRecord(animation.timing))
            }
            var reshape: ProjectReshapeRecord?
            var correction: ProjectCorrectionStackRecord?
            var rawSourceFile: String?
            var raw: ProjectRawDevelopmentRecord?
            let stack = layer.correctionStack
            let persistStack = stack.map { !$0.nodes.isEmpty && ($0.hasAnyCameraRaw || $0.nodes.count > 1) } ?? false
            if persistStack, let stack,
               let persistent = try? LayerCorrectionStackPersistentState(stack: stack) {
                correctionSources[layer.id] = stack.source
                correctionStacks[layer.id] = persistent
                let sharesReshapeSource = stack.hasReshape
                let sourceFile = sharesReshapeSource
                    ? "\(layer.id.uuidString).reshape-source.png"
                    : "\(layer.id.uuidString).corrections-source.png"
                correction = ProjectCorrectionStackRecord(
                    sourceFile: sourceFile,
                    stackFile: "\(layer.id.uuidString).corrections.json")
                if let projected = stack.projectedReshape {
                    reshapeSources[layer.id] = projected.source
                    reshapeMeshes[layer.id] = projected.persistentState
                    reshape = ProjectReshapeRecord(
                        sourceFile: "\(layer.id.uuidString).reshape-source.png",
                        meshFile: "\(layer.id.uuidString).reshape.json")
                }
            } else if let projected = stack?.projectedReshape ?? layer.reshape {
                // Reshape-only stays on the v22 reshape dual-write path (no corrections.json).
                reshapeSources[layer.id] = projected.source
                reshapeMeshes[layer.id] = projected.persistentState
                reshape = ProjectReshapeRecord(
                    sourceFile: "\(layer.id.uuidString).reshape-source.png",
                    meshFile: "\(layer.id.uuidString).reshape.json")
            }
            // Persistent RAW development: store the immutable source bytes inside the package.
            if let rawDevelopment = layer.rawDevelopment {
                rawSources[layer.id] = rawDevelopment.source
                rawSourceFile = rawDevelopment.source.fileName()
                let asShotPersistent = RawDevelopmentSettingsPersistentState(rawDevelopment.source.asShotSettings)
                var cameraMetadata: [String: String] = [:]
                for (key, value) in rawDevelopment.source.cameraMetadata {
                    cameraMetadata[key] = String(describing: value)
                }
                raw = ProjectRawDevelopmentRecord(
                    sourceFile: rawSourceFile ?? "\(layer.id.uuidString).raw-source.dng",
                    settings: rawDevelopment.settings,
                    developedWidth: rawDevelopment.developedWidth,
                    developedHeight: rawDevelopment.developedHeight,
                    developedColorSpace: rawDevelopment.developedColorSpace,
                    developedBitsPerComponent: rawDevelopment.developedBitsPerComponent,
                    asShotSettings: asShotPersistent,
                    cameraMetadata: cameraMetadata,
                    colorSpace: rawDevelopment.source.colorSpace,
                    bitsPerComponent: rawDevelopment.source.bitsPerComponent,
                    supportsNoiseReduction: rawDevelopment.source.supportsNoiseReduction,
                    supportsLensCorrection: rawDevelopment.source.supportsLensCorrection,
                    supportsHighlightRecovery: rawDevelopment.source.supportsHighlightRecovery
                )
            }
            return ProjectLayerRecord(id: layer.id, name: layer.name, isVisible: layer.isVisible,
                transform: layer.transform, imageFile: asset?.file(for: layer.id), parentID: layer.parentID, isGroup: layer.isGroup, opacity: layer.opacity, blendMode: layer.blendMode, maskFile: layer.mask == nil ? nil : "\(layer.id.uuidString).mask.png", maskEnabled: layer.mask?.isEnabled, maskSourceID: layer.maskSourceID, adjustment: layer.adjustment, maskPlacement: layer.mask?.placement, maskLinked: layer.mask?.isLinked, shape: layer.liveShape?.style, effects: layer.effects, text: layer.liveText?.style, gif: gif, reshape: reshape, correctionStack: correction, rawSourceFile: rawSourceFile, rawDevelopment: raw)
        }
        var manifest = ProjectManifest(resolution: document.resolution, documentID: document.id, width: document.width,
            height: document.height, activeLayerID: activeLayerID, layers: layers,
            guides: document.guides.isEmpty ? nil : document.guides)
        // v24 when any stack carries full Camera Raw; v23 for geometry/reshape stacks;
        // reshape-only packages stay at v22. v25 when any layer carries persistent RAW source.
        let needsFullCameraRaw = correctionStacks.values.contains { state in
            state.nodes.contains { $0.kind == .cameraRawFull }
        }
        let needsRAW = !rawSources.isEmpty
        if needsRAW {
            manifest.version = 25
        } else if needsFullCameraRaw {
            manifest.version = 24
        } else if !correctionStacks.isEmpty {
            manifest.version = 23
        } else if !reshapeMeshes.isEmpty {
            manifest.version = 22
        } else {
            manifest.version = ProjectManifest.current
        }
        return ProjectSnapshot(manifest: manifest, images: images, masks: masks,
            animations: animations, reshapeSources: reshapeSources, reshapeMeshes: reshapeMeshes,
            correctionSources: correctionSources, correctionStacks: correctionStacks,
            rawSources: rawSources)
    }

    /// Called only after the entire package has successfully validated and loaded.
    func installProject(_ snapshot: ProjectSnapshot, from url: URL) {
        clearGIFTimeline()
        collapsedGroupIDs = []
        isMaskSelected = false
        cancelCrop()
        guideDrag = nil
        let manifest = snapshot.manifest
        transformEdit = nil
        document = CanvasDocument(id: manifest.documentID, width: manifest.width, height: manifest.height,
            layers: snapshot.documentLayers, resolution: manifest.resolution ?? 72, guides: manifest.guides ?? [])
        activeLayerID = manifest.activeLayerID
        projectURL = url
        sourceImageURL = nil
        renamingLayerID = nil
        history.reset()
        // Clear stale RAW drafts when a new project is loaded.
        rawDrafts.removeAll()
        viewport.fit(documentSize: document!.size)
    }

    /// Replaces the document with what its package holds now, after something else wrote it. Unlike `installProject`
    /// it keeps the viewport, the collapsed folders and the selection where those layers still exist, so the
    /// reload is invisible beyond the change itself. Undo history is session-only and starts over, as after an open.
    func reloadProject(_ snapshot: ProjectSnapshot) {
        guard let url = projectURL else { return }
        let viewport = self.viewport
        let collapsed = collapsedGroupIDs
        let active = activeLayerID
        let selected = selectedLayerIDs
        installProject(snapshot, from: url)
        self.viewport = viewport
        let ids = Set(snapshot.manifest.layers.map(\.id))
        collapsedGroupIDs = collapsed.intersection(ids)
        if let active, ids.contains(active) {
            activeLayerID = active
            selectedLayerIDs = selected.intersection(ids).union([active])
        }
    }

    func clearProject() {
        clearGIFTimeline()
        collapsedGroupIDs = []
        isMaskSelected = false
        cancelCrop()
        transformEdit = nil
        guideDrag = nil
        document = nil
        activeLayerID = nil
        renamingLayerID = nil
        projectURL = nil
        sourceImageURL = nil
        history.reset()
        // Clear stale RAW drafts when the project changes.
        rawDrafts.removeAll()
    }

    func createNewProject(width: Int, height: Int, resolution: Double = 72, background: CGColor? = nil) {
        guard !isProjectBusy, !isImporting, (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else { return }
        clearProject()
        createDocument(width: width, height: height, emptyLayer: true, resolution: resolution, background: background)
    }
}

extension ProjectSnapshot {
    /// The layers the manifest records, each with its pixels, mask, effects and live text or shape. Opening a project
    /// and the edits that rebuild the document from a snapshot (canvas and image size, crop, trim) all build them here,
    /// so none of them leaves part of a layer behind.
    var documentLayers: [ImageLayer] {
        manifest.layers.map { record in
            var reshape: LayerReshape?
            if let persistent = reshapeMeshes[record.id], let source = reshapeSources[record.id] {
                reshape = LayerReshape(persistent: persistent, source: source)
            }
            var stack: LayerCorrectionStack?
            if let persistent = correctionStacks[record.id], let source = correctionSources[record.id] {
                stack = try? persistent.makeStack(source: source)
            } else if let reshape {
                // v22 reshape-only: synthesize an in-memory stack so ND ops work after open.
                stack = LayerCorrectionStack.fromReshape(reshape)
            }
            return ImageLayer(id: record.id, asset: images[record.id], name: record.name,
                       isVisible: record.isVisible, transform: record.transform, parentID: record.parentID, isGroup: record.isGroup == true, opacity: record.opacity ?? 1, blendMode: record.blendMode ?? .normal, mask: mask(for: record), maskSourceID: record.maskSourceID, adjustment: record.adjustment,
                       shape: LayerShape.loaded(record.shape, image: images[record.id]?.image),
                       effects: record.effects,
                       text: LayerText.loaded(record.text, image: images[record.id]?.image),
                       gifAnimation: animations[record.id],
                       reshape: reshape ?? stack?.projectedReshape,
                       correctionStack: stack,
                       rawDevelopment: record.rawDevelopment.map { rawRecord in
                           guard let source = rawSources[record.id] else { return nil }
                           return RawDevelopmentPersistentState(source: source,
                                                                settings: rawRecord.settings,
                                                                developedWidth: rawRecord.developedWidth,
                                                                developedHeight: rawRecord.developedHeight,
                                                                developedColorSpace: rawRecord.developedColorSpace,
                                                                developedBitsPerComponent: rawRecord.developedBitsPerComponent)
                       } ?? nil)
        }
    }
}
