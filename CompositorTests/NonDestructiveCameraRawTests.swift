import AppKit
import Foundation
import Testing
@testable import Compositor

@Suite(.serialized)
@MainActor
struct NonDestructiveCameraRawTests {
    private func gradient(width: Int, height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                let i = y * stride + x * 4
                data[i] = UInt8((x * 255) / max(width - 1, 1))
                data[i + 1] = UInt8((y * 255) / max(height - 1, 1))
                data[i + 2] = 160
                data[i + 3] = 255
            }
        }
        return try #require(context.makeImage())
    }

    private func checkerboard(width: Int, height: Int, cell: Int = 8) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                let on = ((x / cell) + (y / cell)) % 2 == 0
                let i = y * stride + x * 4
                let value: UInt8 = on ? 220 : 40
                data[i] = value; data[i + 1] = value; data[i + 2] = on ? 255 : 60; data[i + 3] = 255
            }
        }
        return try #require(context.makeImage())
    }

    private func skinTone(width: Int, height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(red: 0.76, green: 0.55, blue: 0.45, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func sessionWithImage(_ image: CGImage) -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: image.width, height: image.height)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Layer"))
        return session
    }

    private func rgba8(_ image: CGImage) throws -> [UInt8] {
        try MeshWarpRaster.rgba8Bytes(from: image)
    }

    private func warpedMesh(preset: MeshWarpGrid.Preset = .points4) -> MeshWarpGrid {
        var mesh = MeshWarpGrid.identity(preset: preset, stickyBorders: true, propagation: 0.25)
        let handle = mesh.index(column: mesh.pointColumns / 2, row: mesh.pointRows / 2)
        var positions = mesh.positions
        positions[handle].x += 0.04
        mesh.positions = positions
        mesh.topology.writeBack(positions: positions)
        return mesh
    }

    private func maxChannelDelta(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    // MARK: - Persistence

    @Test func fullSettingsRoundTrip() throws {
        var settings = CameraRawSettings()
        settings.exposure = 0.75
        settings.contrast = 20
        settings.temperature = -15
        settings.vibrance = 30
        settings.curve.shadows = 10
        settings.mixer.hue[0] = 12
        settings.grading.midtones.hue = 40
        settings.grading.midtones.saturation = 25
        settings.detail.sharpenAmount = 40
        settings.optics.distortion = -8
        settings.geometry.vertical = 12
        settings.geometry.framingMode = .keepOriginalSize
        settings.calibration.redHue = 5
        settings.clarity = 18
        settings.dehaze = 10

        let persistent = CameraRawSettingsPersistentState(settings)
        let data = try JSONEncoder().encode(persistent)
        let decoded = try JSONDecoder().decode(CameraRawSettingsPersistentState.self, from: data)
        let restored = try decoded.makeSettings()
        #expect(restored.exposure == settings.normalized.exposure)
        #expect(restored.mixer.hue[0] == settings.normalized.mixer.hue[0])
        #expect(restored.grading.midtones.saturation == settings.normalized.grading.midtones.saturation)
        #expect(restored.detail.sharpenAmount == settings.normalized.detail.sharpenAmount)
        #expect(restored.optics.distortion == settings.normalized.optics.distortion)
        #expect(restored.geometry.vertical == settings.normalized.geometry.vertical)
        #expect(restored.calibration.redHue == settings.normalized.calibration.redHue)
    }

    @Test func corruptSettingsRejected() throws {
        var persistent = CameraRawSettingsPersistentState()
        persistent.schemaVersion = 99
        #expect(throws: CameraRawSettingsPersistentState.DecodeError.self) {
            _ = try persistent.makeSettings()
        }
        persistent = CameraRawSettingsPersistentState()
        persistent.exposure = .nan
        #expect(throws: CameraRawSettingsPersistentState.DecodeError.self) {
            _ = try persistent.makeSettings()
        }
    }

    @Test func missingKeysUseExplicitDefaults() throws {
        let json = Data(#"{"schemaVersion":1,"exposure":1.0}"#.utf8)
        let decoded = try JSONDecoder().decode(CameraRawSettingsPersistentState.self, from: json)
        let settings = try decoded.makeSettings()
        #expect(settings.exposure == 1.0)
        #expect(settings.contrast == 0)
        #expect(settings.temperature == 0)
        #expect(settings.detail.sharpenAmount == 0)
        #expect(settings.geometry.vertical == 0)
    }

    // MARK: - Stack evaluation

    @Test func identityFullCameraRaw() throws {
        let image = try gradient(width: 48, height: 48)
        var stack = LayerCorrectionStack(
            source: ImportedImage(image: image, thumbnail: image, name: "L"),
            nodes: [.cameraRawFull(CameraRawSettings())])
        let result = try LayerCorrectionRenderer.render(&stack)
        #expect(try rgba8(result.image) == rgba8(image))
    }

    @Test func exposureAndColorAdjustments() throws {
        let session = sessionWithImage(try skinTone(width: 64, height: 48))
        var settings = CameraRawSettings()
        settings.exposure = 0.5
        settings.temperature = 20
        settings.vibrance = 25
        try session.addCorrection(kind: .cameraRawFull, cameraRawFull: settings)
        let before = try rgba8(try #require(session.activeLayer?.asset?.image))
        let source = try rgba8(try #require(session.activeLayer?.correctionStack?.source.image))
        #expect(before != source)
        let id = try #require(session.activeLayer?.correctionStack?.nodes.first?.id)
        try session.resetCameraRawGroup(nodeID: id, group: .light)
        try session.resetCameraRawGroup(nodeID: id, group: .color)
        let after = try rgba8(try #require(session.activeLayer?.asset?.image))
        #expect(after == source)
    }

    @Test func curveMixerGradingDetailOpticsGeometry() throws {
        let image = try checkerboard(width: 64, height: 64)
        var settings = CameraRawSettings()
        settings.curve.highlights = -20
        settings.mixer.saturation[2] = 30
        settings.grading.shadows.saturation = 20
        settings.detail.sharpenAmount = 50
        settings.optics.distortion = 5
        settings.geometry.vertical = 15
        settings.geometry.framingMode = .keepOriginalSize
        var stack = LayerCorrectionStack(
            source: ImportedImage(image: image, thumbnail: image, name: "L"),
            nodes: [.cameraRawFull(settings)])
        let result = try LayerCorrectionRenderer.render(&stack)
        #expect(try rgba8(result.image) != rgba8(image))
        #expect(result.image.width == 64)
    }

    @Test func fullCameraRawMatchesStandaloneFilter() throws {
        let image = try gradient(width: 80, height: 60)
        var settings = CameraRawSettings()
        settings.exposure = -0.4
        settings.contrast = 15
        settings.saturation = 10
        settings.clarity = 12
        let standalone = try settings.apply(image)
        var stack = LayerCorrectionStack(
            source: ImportedImage(image: image, thumbnail: image, name: "L"),
            nodes: [.cameraRawFull(settings)])
        let stacked = try LayerCorrectionRenderer.render(&stack)
        #expect(try rgba8(standalone) == rgba8(stacked.image))
    }

    @Test func cameraRawThenReshape() throws {
        let session = sessionWithImage(try gradient(width: 64, height: 64))
        var settings = CameraRawSettings()
        settings.exposure = 0.3
        settings.geometry.vertical = 10
        settings.geometry.framingMode = .keepOriginalSize
        try session.addCorrection(kind: .cameraRawFull, cameraRawFull: settings)
        try session.addCorrection(kind: .reshape, meshPreset: .points4)
        let reshapeID = try #require(session.activeLayer?.correctionStack?.nodes.first(where: { $0.kind == .reshape })?.id)
        try session.editCorrection(nodeID: reshapeID) {
            $0.mesh = warpedMesh()
            $0.meshImageWidth = 64
            $0.meshImageHeight = 64
        }
        #expect(session.activeLayer?.correctionStack?.nodes.map(\.kind) == [.cameraRawFull, .reshape])
        #expect(session.activeLayer?.correctionStack?.source.image.width == 64)
    }

    @Test func reshapeThenCameraRaw() throws {
        let session = sessionWithImage(try checkerboard(width: 48, height: 48))
        session.beginMeshWarp(preset: .points4)
        let edit = try #require(session.meshWarpEdit)
        edit.mesh = warpedMesh()
        session.applyMeshWarp()
        var settings = CameraRawSettings()
        settings.exposure = 0.6
        try session.addCorrection(kind: .cameraRawFull, cameraRawFull: settings)
        #expect(session.activeLayer?.correctionStack?.nodes.map(\.kind) == [.reshape, .cameraRawFull])
    }

    @Test func expandWithReshapeRefused() throws {
        let session = sessionWithImage(try checkerboard(width: 40, height: 40))
        session.beginMeshWarp(preset: .points4)
        session.meshWarpEdit?.mesh = warpedMesh()
        session.applyMeshWarp()
        var settings = CameraRawSettings()
        settings.geometry.framingMode = .expandToFit
        #expect(throws: LayerCorrectionError.expandWithReshape) {
            try session.addCorrection(kind: .cameraRawFull, cameraRawFull: settings)
        }
    }

    @Test func cachedEqualsUncached() throws {
        let image = try gradient(width: 96, height: 72)
        var settings = CameraRawSettings()
        settings.exposure = 0.25
        settings.vibrance = 20
        let mesh = warpedMesh()
        var stack = LayerCorrectionStack(
            source: ImportedImage(image: image, thumbnail: image, name: "L"),
            nodes: [
                .cameraRawFull(settings),
                .reshape(mesh: mesh, imageWidth: 96, imageHeight: 72)
            ])
        let gpu = LayerCorrectionGPUContext()
        let cold = try LayerCorrectionRenderer.render(&stack, options: .init(useCache: false, gpuContext: gpu))
        let warm = try LayerCorrectionRenderer.render(&stack, options: .init(useCache: true, gpuContext: gpu))
        #expect(try rgba8(cold.image) == rgba8(warm.image))
        #expect(warm.cacheHits == 2)
    }

    @Test func sourceImmutability() throws {
        let session = sessionWithImage(try skinTone(width: 48, height: 48))
        let original = try rgba8(try #require(session.activeLayer?.asset?.image))
        var settings = CameraRawSettings()
        settings.exposure = 1.0
        try session.addCorrection(kind: .cameraRawFull, cameraRawFull: settings)
        #expect(try rgba8(try #require(session.activeLayer?.correctionStack?.source.image)) == original)
    }

    @Test func saveReopenEdit() async throws {
        let session = sessionWithImage(try gradient(width: 56, height: 40))
        var settings = CameraRawSettings()
        settings.exposure = 0.4
        settings.contrast = 12
        try session.addCorrection(kind: .cameraRawFull, cameraRawFull: settings)
        let before = try rgba8(try #require(session.activeLayer?.asset?.image))
        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version == 24)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("m88-\(UUID().uuidString).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.version == 24)
        let layer = try #require(loaded.documentLayers.first)
        let node = try #require(layer.correctionStack?.nodes.first)
        #expect(node.kind == .cameraRawFull)
        #expect(node.cameraRawFull.exposure == 0.4)
        #expect(try rgba8(try #require(layer.asset?.image)) == before)
        let session2 = EditorSession()
        session2.installProject(loaded, from: url)
        let liveID = try #require(session2.activeLayer?.correctionStack?.nodes.first?.id)
        try session2.editCameraRawFull(nodeID: liveID) { $0.exposure = 1.0 }
        #expect(session2.activeLayer?.correctionStack?.nodes.first?.cameraRawFull.exposure == 1.0)
        #expect(try rgba8(try #require(session2.activeLayer?.asset?.image)) != before)
    }

    @Test func undoRedoDisableRemove() throws {
        let session = sessionWithImage(try checkerboard(width: 40, height: 40))
        var settings = CameraRawSettings()
        settings.exposure = 0.8
        try session.addCorrection(kind: .cameraRawFull, cameraRawFull: settings)
        let id = try #require(session.activeLayer?.correctionStack?.nodes.first?.id)
        let on = try rgba8(try #require(session.activeLayer?.asset?.image))
        try session.setCorrectionEnabled(nodeID: id, enabled: false)
        let off = try rgba8(try #require(session.activeLayer?.asset?.image))
        #expect(on != off)
        session.undo()
        #expect(try rgba8(try #require(session.activeLayer?.asset?.image)) == on)
        session.redo()
        #expect(try rgba8(try #require(session.activeLayer?.asset?.image)) == off)
        session.undo()
        try session.resetCameraRawGroup(nodeID: id, group: .light)
        #expect(session.activeLayer?.correctionStack?.nodes.first?.cameraRawFull.exposure == 0)
        try session.removeCorrection(nodeID: id)
        #expect(session.activeLayer?.correctionStack == nil)
    }

    @Test func metalStackExecutionConfirmed() throws {
        guard MetalMeshWarp.shared != nil else { return }
        let image = try gradient(width: 128, height: 128)
        let mesh = warpedMesh(preset: .points8)
        var stack = LayerCorrectionStack(
            source: ImportedImage(image: image, thumbnail: image, name: "L"),
            nodes: [.reshape(mesh: mesh, imageWidth: 128, imageHeight: 128)])
        let gpu = LayerCorrectionGPUContext()
        let result = try LayerCorrectionRenderer.render(
            &stack,
            options: .init(preferMetalMesh: true, useCache: false, gpuContext: gpu,
                           requireMetalMeshWhenAvailable: true))
        #expect(result.usedMetal)
        let reshapeTiming = try #require(result.timings.first)
        #expect(reshapeTiming.usedMetal)
        #expect(reshapeTiming.metalAvailable)
        #expect(reshapeTiming.fallbackReason == nil)
        #expect(reshapeTiming.gpuMilliseconds >= 0)
    }

    @Test func explicitCPUFallback() throws {
        let image = try gradient(width: 64, height: 64)
        let mesh = warpedMesh()
        var stack = LayerCorrectionStack(
            source: ImportedImage(image: image, thumbnail: image, name: "L"),
            nodes: [.reshape(mesh: mesh, imageWidth: 64, imageHeight: 64)])
        let result = try LayerCorrectionRenderer.render(
            &stack, options: .init(preferMetalMesh: false, useCache: false))
        #expect(!result.usedMetal)
        #expect(result.timings.first?.fallbackReason?.contains("CPU") == true)
    }

    @Test func cpuGpuMeshParity() throws {
        guard MetalMeshWarp.shared != nil else { return }
        let image = try checkerboard(width: 96, height: 96, cell: 4)
        let mesh = warpedMesh(preset: .points8)
        let gpu = LayerCorrectionGPUContext()
        var metalStack = LayerCorrectionStack(
            source: ImportedImage(image: image, thumbnail: image, name: "L"),
            nodes: [.reshape(mesh: mesh, imageWidth: 96, imageHeight: 96)])
        var cpuStack = metalStack
        let metal = try LayerCorrectionRenderer.render(
            &metalStack, options: .init(preferMetalMesh: true, useCache: false, gpuContext: gpu,
                                        requireMetalMeshWhenAvailable: true))
        let cpu = try LayerCorrectionRenderer.render(
            &cpuStack, options: .init(preferMetalMesh: false, useCache: false))
        let delta = maxChannelDelta(try rgba8(metal.image), try rgba8(cpu.image))
        #expect(delta <= 1)
    }

    @Test func editingSecondNodePreservesUpstreamCache() throws {
        let image = try gradient(width: 64, height: 64)
        var settings = CameraRawSettings()
        settings.exposure = 0.2
        let mesh = warpedMesh()
        var stack = LayerCorrectionStack(
            source: ImportedImage(image: image, thumbnail: image, name: "L"),
            nodes: [
                .cameraRawFull(settings),
                .reshape(mesh: mesh, imageWidth: 64, imageHeight: 64)
            ])
        let gpu = LayerCorrectionGPUContext()
        _ = try LayerCorrectionRenderer.render(&stack, options: .init(gpuContext: gpu))
        #expect(stack.stageCache.count == 2)
        let upstreamID = stack.nodes[0].id
        let upstreamImage = try #require(stack.stageCache[upstreamID]?.image)
        stack.nodes[1].mesh = warpedMesh(preset: .points4)
        stack.nodes[1].meshImageWidth = 64
        stack.nodes[1].meshImageHeight = 64
        stack.invalidateFromIndex(1)
        #expect(stack.stageCache[upstreamID]?.image === upstreamImage)
        let again = try LayerCorrectionRenderer.render(&stack, options: .init(gpuContext: gpu))
        #expect(again.cacheHits == 1)
        #expect(again.stagesRendered == 1)
    }

    @Test func legacyGeometryStackStillSchema1() throws {
        let image = try checkerboard(width: 32, height: 32)
        var geo = CameraRawGeometryBackendSettings()
        geo.geometry.vertical = 10
        geo.geometry.framingMode = .keepOriginalSize
        let stack = LayerCorrectionStack(
            source: ImportedImage(image: image, thumbnail: image, name: "L"),
            nodes: [.cameraRawGeometry(geo)])
        let persistent = try LayerCorrectionStackPersistentState(stack: stack)
        #expect(persistent.schemaVersion == 1)
        #expect(!persistent.nodes.contains { $0.kind == .cameraRawFull })
    }
}
