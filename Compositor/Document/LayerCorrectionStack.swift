import CoreGraphics
import Foundation

/// Ordered non-destructive corrections on one image layer. Always evaluates from an
/// immutable source; the layer `asset` holds the last rendered display output.
///
/// Schema 1: Camera Raw geometry + ReShape.
/// Schema 2: adds full Camera Raw (`cameraRawFull`) with complete `CameraRawSettings`.
nonisolated enum LayerCorrectionKind: String, Codable, Sendable, CaseIterable {
    case cameraRawGeometry
    case cameraRawFull
    case reshape
}

/// Parameter groups for partial reset / edit of a full Camera Raw node.
nonisolated enum CameraRawCorrectionGroup: String, Codable, Sendable, CaseIterable {
    case light
    case color
    case mixer
    case grading
    case curve
    case effects
    case detail
    case optics
    case geometry
    case calibration
}

nonisolated enum LayerCorrectionError: Error, Equatable, LocalizedError, Sendable {
    case unsupported(String)
    case incompatibleOrder(String)
    case invalidDimensions(String)
    case precision(String)
    case malformed(String)
    case budget(String)
    case expandWithReshape
    case missingNode
    case deepOrHDR

    var errorDescription: String? {
        switch self {
        case .unsupported(let reason): return reason
        case .incompatibleOrder(let reason): return reason
        case .invalidDimensions(let reason): return "Correction stack dimensions are invalid (\(reason))."
        case .precision(let reason): return reason
        case .malformed(let reason): return "Correction stack data is damaged (\(reason))."
        case .budget(let reason): return "Correction stack exceeds limits (\(reason))."
        case .expandWithReshape:
            return "Expand to Fit cannot share an editable correction stack with ReShape. Use Keep Original Size, or Bake one correction first."
        case .missingNode: return "The correction node was not found."
        case .deepOrHDR:
            return "Non-destructive geometry stacks currently support 8-bit layers only."
        }
    }
}

/// One editable correction in the stack. Runtime mesh is live; persistence uses `MeshWarpPersistentState`.
nonisolated struct LayerCorrectionNode: Identifiable, Equatable, @unchecked Sendable {
    var id: UUID
    var kind: LayerCorrectionKind
    var enabled: Bool
    /// Geometry-only Camera Raw (schema 1 / `.cameraRawGeometry`).
    var cameraRaw: CameraRawGeometryBackendSettings
    /// Full Camera Raw settings when `kind == .cameraRawFull`.
    var cameraRawFull: CameraRawSettings
    /// Live mesh when `kind == .reshape`. Dimensions must match the node's input stage.
    var mesh: MeshWarpGrid?
    var meshImageWidth: Int
    var meshImageHeight: Int

    init(id: UUID = UUID(),
         kind: LayerCorrectionKind,
         enabled: Bool = true,
         cameraRaw: CameraRawGeometryBackendSettings = CameraRawGeometryBackendSettings(),
         cameraRawFull: CameraRawSettings = CameraRawSettings(),
         mesh: MeshWarpGrid? = nil,
         meshImageWidth: Int = 0,
         meshImageHeight: Int = 0) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        self.cameraRaw = cameraRaw
        self.cameraRawFull = cameraRawFull
        self.mesh = mesh
        self.meshImageWidth = meshImageWidth
        self.meshImageHeight = meshImageHeight
    }

    static func cameraRawGeometry(_ settings: CameraRawGeometryBackendSettings = CameraRawGeometryBackendSettings(),
                                  enabled: Bool = true) -> LayerCorrectionNode {
        LayerCorrectionNode(kind: .cameraRawGeometry, enabled: enabled, cameraRaw: settings.normalized)
    }

    static func cameraRawFull(_ settings: CameraRawSettings = CameraRawSettings(),
                              enabled: Bool = true) -> LayerCorrectionNode {
        LayerCorrectionNode(kind: .cameraRawFull, enabled: enabled, cameraRawFull: settings.normalized)
    }

    static func reshape(mesh: MeshWarpGrid, imageWidth: Int, imageHeight: Int,
                        enabled: Bool = true) -> LayerCorrectionNode {
        LayerCorrectionNode(kind: .reshape, enabled: enabled, mesh: mesh,
                            meshImageWidth: imageWidth, meshImageHeight: imageHeight)
    }

    var isIdentityParameters: Bool {
        switch kind {
        case .cameraRawGeometry:
            let s = cameraRaw.normalized
            return !s.geometry.adjusts && s.horizon.isIdentity && s.miniature.isIdentity
                && !s.crop.automaticOpaqueCrop
        case .cameraRawFull:
            return cameraRawFull.normalized.isIdentity
        case .reshape:
            return mesh?.isIdentity != false
        }
    }

    mutating func resetParameters() {
        switch kind {
        case .cameraRawGeometry:
            CameraRawGeometryBackend.reset(&cameraRaw)
        case .cameraRawFull:
            cameraRawFull = CameraRawSettings()
        case .reshape:
            if let mesh, let identity = MeshWarpGrid.identity(pointColumns: mesh.pointColumns,
                                                              pointRows: mesh.pointRows,
                                                              stickyBorders: mesh.stickyBorders,
                                                              propagation: mesh.propagation) {
                self.mesh = identity
            }
        }
    }

    mutating func resetCameraRawGroup(_ group: CameraRawCorrectionGroup) {
        guard kind == .cameraRawFull else { return }
        var settings = cameraRawFull
        switch group {
        case .light:
            settings.exposure = 0; settings.contrast = 0; settings.highlights = 0
            settings.shadows = 0; settings.whites = 0; settings.blacks = 0
        case .color:
            settings.whiteBalance = .custom; settings.temperature = 0; settings.tint = 0
            settings.vibrance = 0; settings.saturation = 0
        case .mixer:
            settings.mixer = CameraRawMixerSettings()
        case .grading:
            settings.grading = CameraRawGradingSettings()
        case .curve:
            settings.curve = CameraRawCurveSettings()
        case .effects:
            settings.texture = 0; settings.clarity = 0; settings.dehaze = 0
            settings.glow = 0; settings.vignetteAmount = 0; settings.grainAmount = 0
        case .detail:
            settings.detail = CameraRawDetailSettings()
        case .optics:
            settings.optics = CameraRawOpticsSettings()
        case .geometry:
            settings.geometry = CameraRawGeometrySettings()
            settings.horizon = CameraRawHorizonSettings()
            settings.perspectiveTools = CameraRawPerspectiveToolState()
            settings.miniature = CameraRawMiniatureSettings()
        case .calibration:
            settings.calibration = CameraRawCalibrationSettings()
        }
        cameraRawFull = settings.normalized
    }

    /// Expand-to-fit used by either geometry-only or full Camera Raw nodes.
    var usesExpandToFit: Bool {
        switch kind {
        case .cameraRawGeometry:
            return LayerCorrectionStack.usesExpand(cameraRaw)
        case .cameraRawFull:
            return cameraRawFull.normalized.geometry.framingMode == .expandToFit
        case .reshape:
            return false
        }
    }
}

/// Result of evaluating the stack (or a prefix of it).
nonisolated struct LayerCorrectionRenderResult: Equatable, @unchecked Sendable {
    var image: CGImage
    /// Non-nil when the last Camera Raw geometry stage used Expand to Fit.
    var expansion: CameraRawGeometryExpansion?
    var usedMetal: Bool
    var cacheHits: Int
    var stagesRendered: Int
    var timings: [StageTiming]

    nonisolated struct StageTiming: Equatable, Sendable {
        var nodeID: UUID
        var kind: LayerCorrectionKind
        var milliseconds: Double
        var usedMetal: Bool
        var cacheHit: Bool
        var metalAvailable: Bool = false
        var fallbackReason: String? = nil
        var sourceUploadMilliseconds: Double = 0
        var triangleUploadMilliseconds: Double = 0
        var kernelMilliseconds: Double = 0
        var gpuMilliseconds: Double = 0
        var syncMilliseconds: Double = 0
        var readbackMilliseconds: Double = 0
        var allocationMilliseconds: Double = 0
    }
}

/// Versioned, serializable correction stack. Caches are session-only and never written to disk.
nonisolated struct LayerCorrectionStack: Equatable, @unchecked Sendable {
    /// Schema 1: geometry + reshape. Schema 2: adds `cameraRawFull`.
    static let schemaVersion = 2
    static let maximumEncodedBytes = 8 * 1024 * 1024
    static let maximumNodes = 16
    /// Soft bound on retained stage CGImages (session-only).
    static let maximumCachedStages = 16

    var schemaVersion: Int
    var source: ImportedImage
    var sourceWidth: Int
    var sourceHeight: Int
    var nodes: [LayerCorrectionNode]
    /// Generation bumped on any structural/parameter edit; used to drop stale stage caches.
    var revision: UInt64
    /// Session-only stage outputs keyed by node id. Not part of equality or persistence.
    var stageCache: [UUID: CachedStage] = [:]

    nonisolated struct CachedStage: @unchecked Sendable {
        var revision: UInt64
        var image: CGImage
        var expansion: CameraRawGeometryExpansion?
        var inputWidth: Int
        var inputHeight: Int
        var outputWidth: Int
        var outputHeight: Int
    }

    static func == (lhs: LayerCorrectionStack, rhs: LayerCorrectionStack) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.sourceWidth == rhs.sourceWidth
            && lhs.sourceHeight == rhs.sourceHeight
            && lhs.nodes == rhs.nodes
            && lhs.revision == rhs.revision
            && lhs.source.image === rhs.source.image
    }

    init(source: ImportedImage, nodes: [LayerCorrectionNode] = []) {
        schemaVersion = Self.schemaVersion
        self.source = source
        sourceWidth = source.image.width
        sourceHeight = source.image.height
        self.nodes = nodes
        revision = 1
    }

    /// Builds a stack that preserves an existing ReShape attachment.
    static func fromReshape(_ reshape: LayerReshape) -> LayerCorrectionStack {
        let node = LayerCorrectionNode.reshape(mesh: reshape.mesh,
                                               imageWidth: reshape.imageWidth,
                                               imageHeight: reshape.imageHeight)
        return LayerCorrectionStack(source: reshape.source, nodes: [node])
    }

    /// Projection used by existing MeshWarp / v22 reshape persistence paths.
    var projectedReshape: LayerReshape? {
        guard let node = nodes.first(where: { $0.kind == .reshape }),
              let mesh = node.mesh else { return nil }
        guard node.meshImageWidth == sourceWidth, node.meshImageHeight == sourceHeight else {
            return LayerReshape(mesh: mesh, source: source)
        }
        return LayerReshape(mesh: mesh, source: source)
    }

    var hasReshape: Bool { nodes.contains { $0.kind == .reshape } }
    var hasCameraRawGeometry: Bool { nodes.contains { $0.kind == .cameraRawGeometry } }
    var hasCameraRawFull: Bool { nodes.contains { $0.kind == .cameraRawFull } }
    var hasAnyCameraRaw: Bool { hasCameraRawGeometry || hasCameraRawFull }

    /// Minimum project format that can carry this stack.
    var requiredProjectVersion: Int { hasCameraRawFull ? 24 : 23 }

    mutating func bumpRevision() {
        revision &+= 1
        stageCache.removeAll(keepingCapacity: true)
    }

    mutating func invalidateFrom(nodeID: UUID) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else {
            bumpRevision()
            return
        }
        invalidateFromIndex(index)
    }

    mutating func invalidateFromIndex(_ index: Int) {
        guard nodes.indices.contains(index) else {
            bumpRevision()
            return
        }
        revision &+= 1
        let drop = Set(nodes[index...].map(\.id))
        // Keep upstream stages; retag them to the new revision so cache hits remain valid.
        var kept: [UUID: CachedStage] = [:]
        for (id, var stage) in stageCache where !drop.contains(id) {
            stage.revision = revision
            kept[id] = stage
        }
        stageCache = kept
        trimStageCacheIfNeeded()
    }

    mutating func storeStage(_ stage: CachedStage, for nodeID: UUID) {
        stageCache[nodeID] = stage
        trimStageCacheIfNeeded()
    }

    mutating func trimStageCacheIfNeeded() {
        guard stageCache.count > Self.maximumCachedStages else { return }
        // Drop entries that no longer match an enabled node first, then oldest by not in node order.
        let live = Set(nodes.map(\.id))
        for id in stageCache.keys where !live.contains(id) {
            stageCache[id] = nil
        }
        while stageCache.count > Self.maximumCachedStages,
              let victim = stageCache.keys.first(where: { id in
                  !(nodes.contains { $0.id == id && $0.enabled })
              }) ?? stageCache.keys.first {
            stageCache[victim] = nil
        }
    }

    func validatePrecision() throws {
        guard source.deep == nil,
              source.image.bitsPerComponent <= 8,
              !DeepLayer.isHDR(source.image) else {
            throw LayerCorrectionError.deepOrHDR
        }
        guard (1...DocumentLimits.maxSide).contains(sourceWidth),
              (1...DocumentLimits.maxSide).contains(sourceHeight),
              sourceWidth == source.image.width,
              sourceHeight == source.image.height else {
            throw LayerCorrectionError.invalidDimensions("source \(sourceWidth)×\(sourceHeight)")
        }
        guard nodes.count <= Self.maximumNodes else {
            throw LayerCorrectionError.budget("node count \(nodes.count)")
        }
        var seen = Set<UUID>()
        var cameraRawGeometryCount = 0
        var cameraRawFullCount = 0
        for node in nodes {
            guard seen.insert(node.id).inserted else {
                throw LayerCorrectionError.malformed("duplicate node id")
            }
            switch node.kind {
            case .cameraRawGeometry:
                cameraRawGeometryCount += 1
                if node.usesExpandToFit, hasReshape {
                    throw LayerCorrectionError.expandWithReshape
                }
            case .cameraRawFull:
                cameraRawFullCount += 1
                guard node.cameraRawFull.normalized.isValid else {
                    throw LayerCorrectionError.malformed("cameraRawFull settings")
                }
                if node.usesExpandToFit, hasReshape {
                    throw LayerCorrectionError.expandWithReshape
                }
            case .reshape:
                guard let mesh = node.mesh else {
                    throw LayerCorrectionError.malformed("reshape missing mesh")
                }
                guard (1...DocumentLimits.maxSide).contains(node.meshImageWidth),
                      (1...DocumentLimits.maxSide).contains(node.meshImageHeight) else {
                    throw LayerCorrectionError.invalidDimensions("mesh \(node.meshImageWidth)×\(node.meshImageHeight)")
                }
                _ = mesh
            }
        }
        if cameraRawGeometryCount > 1 || cameraRawFullCount > 1 {
            throw LayerCorrectionError.unsupported("At most one Camera Raw node of each kind is allowed.")
        }
    }

    static func usesExpand(_ settings: CameraRawGeometryBackendSettings) -> Bool {
        settings.normalized.geometry.framingMode == .expandToFit
            || settings.normalized.crop.framing == .expandToFit
    }

    /// Whether reordering `from` before/after `to` is allowed for the current schema.
    func canReorder(from: UUID, toBefore: UUID?) -> Result<Void, LayerCorrectionError> {
        guard let fromIndex = nodes.firstIndex(where: { $0.id == from }) else {
            return .failure(.missingNode)
        }
        var trial = nodes
        let node = trial.remove(at: fromIndex)
        let insertAt: Int
        if let toBefore {
            guard let target = trial.firstIndex(where: { $0.id == toBefore }) else {
                return .failure(.missingNode)
            }
            insertAt = target
        } else {
            insertAt = trial.count
        }
        trial.insert(node, at: insertAt)
        var probe = self
        probe.nodes = trial
        do {
            try probe.validatePrecision()
            try probe.validateStageDimensions()
            return .success(())
        } catch let error as LayerCorrectionError {
            return .failure(error)
        } catch {
            return .failure(.malformed("reorder"))
        }
    }

    /// Dry-run dimension walk without rendering pixels.
    func validateStageDimensions() throws {
        var width = sourceWidth
        var height = sourceHeight
        for node in nodes where node.enabled {
            switch node.kind {
            case .cameraRawGeometry, .cameraRawFull:
                if node.usesExpandToFit, hasReshape {
                    throw LayerCorrectionError.expandWithReshape
                }
                if node.usesExpandToFit { continue }
            case .reshape:
                guard node.meshImageWidth == width, node.meshImageHeight == height else {
                    throw LayerCorrectionError.invalidDimensions(
                        "reshape mesh \(node.meshImageWidth)×\(node.meshImageHeight) for input \(width)×\(height)")
                }
            }
            _ = height
            _ = width
        }
    }
}

// MARK: - Persistence

nonisolated struct LayerCorrectionStackPersistentState: Codable, Equatable, Sendable {
    static let schemaVersion = LayerCorrectionStack.schemaVersion

    var schemaVersion: Int
    var sourceWidth: Int
    var sourceHeight: Int
    var nodes: [Node]

    nonisolated struct Node: Codable, Equatable, Sendable {
        var id: UUID
        var kind: LayerCorrectionKind
        var enabled: Bool
        var cameraRaw: CameraRawGeometryBackendSettings?
        /// Full Camera Raw payload (schema 2+). Explicit defaults on decode.
        var cameraRawFull: CameraRawSettingsPersistentState?
        var mesh: MeshWarpPersistentState?
    }

    enum DecodeError: Error, Equatable, LocalizedError {
        case schema(Int)
        case malformed(String)
        case budget(String)

        var errorDescription: String? {
            switch self {
            case .schema(let v): return "Unsupported correction-stack schema version \(v)."
            case .malformed(let reason): return "Correction stack data is damaged (\(reason))."
            case .budget(let reason): return "Correction stack exceeds limits (\(reason))."
            }
        }
    }

    init(stack: LayerCorrectionStack) throws {
        try stack.validatePrecision()
        // Write schema 1 when no full Camera Raw nodes exist, so v23 readers stay compatible.
        schemaVersion = stack.hasCameraRawFull ? Self.schemaVersion : 1
        sourceWidth = stack.sourceWidth
        sourceHeight = stack.sourceHeight
        nodes = try stack.nodes.map { node in
            switch node.kind {
            case .cameraRawGeometry:
                return Node(id: node.id, kind: .cameraRawGeometry, enabled: node.enabled,
                            cameraRaw: node.cameraRaw.normalized, cameraRawFull: nil, mesh: nil)
            case .cameraRawFull:
                return Node(id: node.id, kind: .cameraRawFull, enabled: node.enabled,
                            cameraRaw: nil, cameraRawFull: CameraRawSettingsPersistentState(node.cameraRawFull),
                            mesh: nil)
            case .reshape:
                guard let mesh = node.mesh else {
                    throw LayerCorrectionError.malformed("reshape missing mesh")
                }
                let persistent = MeshWarpPersistentState(mesh: mesh,
                                                         imageWidth: node.meshImageWidth,
                                                         imageHeight: node.meshImageHeight)
                return Node(id: node.id, kind: .reshape, enabled: node.enabled,
                            cameraRaw: nil, cameraRawFull: nil, mesh: persistent)
            }
        }
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= LayerCorrectionStack.maximumEncodedBytes else {
            throw DecodeError.budget("encoded size \(data.count)")
        }
        return data
    }

    static func decode(from data: Data) throws -> LayerCorrectionStackPersistentState {
        guard data.count <= LayerCorrectionStack.maximumEncodedBytes else {
            throw DecodeError.budget("encoded size \(data.count)")
        }
        do {
            return try JSONDecoder().decode(LayerCorrectionStackPersistentState.self, from: data)
        } catch let error as DecodeError {
            throw error
        } catch {
            throw DecodeError.malformed("JSON")
        }
    }

    func makeStack(source: ImportedImage) throws -> LayerCorrectionStack {
        guard schemaVersion == 1 || schemaVersion == Self.schemaVersion else {
            throw DecodeError.schema(schemaVersion)
        }
        guard source.image.width == sourceWidth, source.image.height == sourceHeight,
              source.deep == nil, source.image.bitsPerComponent <= 8, !DeepLayer.isHDR(source.image) else {
            throw DecodeError.malformed("source mismatch")
        }
        guard nodes.count <= LayerCorrectionStack.maximumNodes, !nodes.isEmpty else {
            throw DecodeError.budget("node count")
        }
        var seen = Set<UUID>()
        var live: [LayerCorrectionNode] = []
        live.reserveCapacity(nodes.count)
        for record in nodes {
            guard seen.insert(record.id).inserted else { throw DecodeError.malformed("duplicate id") }
            switch record.kind {
            case .cameraRawGeometry:
                guard record.mesh == nil, record.cameraRawFull == nil, let settings = record.cameraRaw else {
                    throw DecodeError.malformed("cameraRaw payload")
                }
                live.append(LayerCorrectionNode(id: record.id, kind: .cameraRawGeometry,
                                                enabled: record.enabled, cameraRaw: settings.normalized))
            case .cameraRawFull:
                guard schemaVersion >= 2 else { throw DecodeError.schema(schemaVersion) }
                guard record.mesh == nil, record.cameraRaw == nil, let persistent = record.cameraRawFull else {
                    throw DecodeError.malformed("cameraRawFull payload")
                }
                let settings: CameraRawSettings
                do {
                    settings = try persistent.makeSettings()
                } catch {
                    throw DecodeError.malformed("cameraRawFull settings")
                }
                live.append(LayerCorrectionNode(id: record.id, kind: .cameraRawFull,
                                                enabled: record.enabled, cameraRawFull: settings))
            case .reshape:
                guard record.cameraRaw == nil, record.cameraRawFull == nil, let meshState = record.mesh else {
                    throw DecodeError.malformed("reshape payload")
                }
                let grid = try meshState.makeGrid()
                live.append(LayerCorrectionNode(id: record.id, kind: .reshape, enabled: record.enabled,
                                                mesh: grid,
                                                meshImageWidth: meshState.imageWidth,
                                                meshImageHeight: meshState.imageHeight))
            }
        }
        var stack = LayerCorrectionStack(source: source, nodes: live)
        try stack.validatePrecision()
        try stack.validateStageDimensions()
        return stack
    }
}
