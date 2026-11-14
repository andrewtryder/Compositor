import AppKit
import Foundation
import Testing
@testable import Compositor

@Suite(.serialized)
@MainActor
struct MeshWarpTests {
    private let maximumChannelError = 1

    private struct ErrorStats {
        var maxChannel = 0
        var meanChannel = 0.0
        var mismatchedPixels = 0
        var pixels = 0
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

    private func transparentBorder(width: Int, height: Int, inset: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                let i = y * stride + x * 4
                let inside = x >= inset && y >= inset && x < width - inset && y < height - inset
                data[i] = inside ? 200 : 0
                data[i + 1] = inside ? 40 : 0
                data[i + 2] = inside ? 40 : 0
                data[i + 3] = inside ? 255 : 0
            }
        }
        return try #require(context.makeImage())
    }

    private func rgba8(_ image: CGImage) throws -> [UInt8] {
        try MeshWarpRaster.rgba8Bytes(from: image)
    }

    private func compare(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int) -> ErrorStats {
        var stats = ErrorStats(pixels: width * height)
        var sum = 0.0
        let stride = width * 4
        for y in 0..<height {
            for x in 0..<width {
                let o = y * stride + x * 4
                var pixelMismatch = false
                for c in 0..<4 {
                    let diff = abs(Int(a[o + c]) - Int(b[o + c]))
                    stats.maxChannel = max(stats.maxChannel, diff)
                    sum += Double(diff)
                    if diff > 0 { pixelMismatch = true }
                }
                if pixelMismatch { stats.mismatchedPixels += 1 }
            }
        }
        stats.meanChannel = sum / Double(max(1, width * height * 4))
        return stats
    }

    private func centerIndex(of mesh: MeshWarpGrid) -> Int {
        mesh.index(column: mesh.pointColumns / 2, row: mesh.pointRows / 2)
    }

    @Test(arguments: MeshWarpGrid.Preset.allCases)
    func identityCopiesBytes(preset: MeshWarpGrid.Preset) throws {
        let source = try checkerboard(width: 64, height: 48)
        let mesh = MeshWarpGrid.identity(preset: preset)
        var timing = MeshWarpRaster.Timing()
        let warped = try #require(MeshWarpRaster.apply(source: source, mesh: mesh, timing: &timing))
        #expect(try rgba8(source) == rgba8(warped))
        #expect(mesh.isIdentity)
    }

    @Test func landscapeAndPortraitIdentity() throws {
        for (width, height) in [(96, 48), (48, 96), (1, 1), (2, 3)] {
            let source = try checkerboard(width: width, height: height, cell: 2)
            let mesh = MeshWarpGrid.identity(preset: .points4)
            var timing = MeshWarpRaster.Timing()
            let warped = try #require(MeshWarpRaster.apply(source: source, mesh: mesh, timing: &timing))
            #expect(try rgba8(source) == rgba8(warped), "\(width)x\(height)")
        }
    }

    @Test func singleCentralPointMovesPixels() throws {
        let source = try checkerboard(width: 80, height: 80, cell: 10)
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0)
        let index = centerIndex(of: mesh)
        let original = mesh.positions[index]
        let moved = mesh.tryMove(index: index, to: original + SIMD2(0.05, -0.04))
        #expect(moved)
        #expect(!mesh.isIdentity)
        var timing = MeshWarpRaster.Timing()
        let warped = try #require(MeshWarpRaster.apply(source: source, mesh: mesh, timing: &timing))
        let before = try rgba8(source), after = try rgba8(warped)
        #expect(before != after)
        let mid = (40 * 80 + 40) * 4
        #expect(before[mid] != after[mid] || before[mid + 1] != after[mid + 1]
                || before[mid + 2] != after[mid + 2] || before[mid + 3] != after[mid + 3])
    }

    @Test func stickyBordersPinCornersAllowEdgeSlideAndKeepCornerSamples() throws {
        var sticky = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0)
        let corner = sticky.index(column: 0, row: 0)
        let cornerRejected = sticky.tryMove(index: corner, to: SIMD2(0.2, 0.2))
        #expect(!cornerRejected)
        #expect(sticky.isIdentity)

        let border = sticky.index(column: 0, row: sticky.pointRows / 2)
        let slid = sticky.tryMove(index: border, to: SIMD2(0.2, 0.55))
        #expect(slid)
        #expect(abs(sticky.positions[border].x) < 1e-6)

        var free = MeshWarpGrid.identity(preset: .points8, stickyBorders: false, propagation: 0)
        let freed = free.tryMove(index: border, to: SIMD2(0.05, free.positions[border].y))
        #expect(freed)
        #expect(!free.isIdentity)

        let source = try checkerboard(width: 64, height: 64, cell: 8)
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0)
        let center = centerIndex(of: mesh)
        let moved = mesh.tryMove(index: center, to: mesh.positions[center] + SIMD2(0.04, -0.03))
        #expect(moved)
        var timing = MeshWarpRaster.Timing()
        let warped = try #require(MeshWarpRaster.apply(source: source, mesh: mesh, timing: &timing))
        let before = try rgba8(source), after = try rgba8(warped)
        for (x, y) in [(0, 0), (63, 0), (0, 63), (63, 63)] {
            let o = (y * 64 + x) * 4
            #expect(before[o...o+3].elementsEqual(after[o...o+3]), "corner \(x),\(y)")
        }
    }

    @Test func twoNeighboringPointsAndPropagation() throws {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0.4)
        let a = mesh.index(column: 3, row: 3)
        let b = mesh.index(column: 4, row: 3)
        let neighbor = mesh.index(column: 3, row: 4)
        let beforeNeighbor = mesh.positions[neighbor]
        let first = mesh.tryMove(index: a, to: mesh.positions[a] + SIMD2(0.05, 0.04))
        #expect(first)
        #expect(mesh.positions[neighbor] != beforeNeighbor)
        let second = mesh.tryMove(index: b, to: mesh.positions[b] + SIMD2(-0.03, 0.05))
        #expect(second)
        #expect(MeshWarpGrid.trianglesValid(pointColumns: mesh.pointColumns, pointRows: mesh.pointRows,
                                            positions: mesh.positions))
    }

    @Test func degenerateAndInvertedMovesAreRejected() throws {
        var mesh = MeshWarpGrid.identity(preset: .points4, stickyBorders: false, propagation: 0)
        let a = mesh.index(column: 1, row: 1)
        let collapseH = mesh.tryMove(index: a, to: mesh.positions[mesh.index(column: 2, row: 1)])
        #expect(!collapseH)
        #expect(mesh.isIdentity)
        let collapseV = mesh.tryMove(index: a, to: mesh.positions[mesh.index(column: 1, row: 2)])
        #expect(!collapseV)
        #expect(mesh.isIdentity)
        // Hand-built inverted cell: swap two corners so one triangle flips.
        var inverted = mesh.positions
        let i00 = mesh.index(column: 0, row: 0)
        let i10 = mesh.index(column: 1, row: 0)
        let i01 = mesh.index(column: 0, row: 1)
        inverted[i10] = mesh.positions[i01]
        inverted[i01] = mesh.positions[i10]
        #expect(!MeshWarpGrid.trianglesValid(pointColumns: mesh.pointColumns, pointRows: mesh.pointRows,
                                             positions: inverted))
        let crossed = mesh.tryMove(index: a, to: mesh.positions[i00])
        #expect(!crossed)
        #expect(mesh.isIdentity)
    }

    @Test func transparentBordersRemainTransparentOutsideContent() throws {
        let source = try transparentBorder(width: 48, height: 36, inset: 8)
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0)
        let moved = mesh.tryMove(index: centerIndex(of: mesh), to: SIMD2(0.55, 0.45))
        #expect(moved)
        var timing = MeshWarpRaster.Timing()
        let warped = try #require(MeshWarpRaster.apply(source: source, mesh: mesh, timing: &timing))
        let after = try rgba8(warped)
        #expect(after[3] == 0)
        #expect(after[(35 * 48 + 47) * 4 + 3] == 0)
    }

    @Test func cpuGpuParityOnNontrivialMeshes() throws {
        guard MetalMeshWarp.shared != nil else { return }
        let cases: [(Int, Int, MeshWarpGrid.Preset)] = [
            (64, 48, .points4),
            (96, 96, .points8),
            (48, 96, .points16),
            (32, 24, .points8),
        ]
        for (width, height, preset) in cases {
            let source = try checkerboard(width: width, height: height, cell: 4)
            var mesh = MeshWarpGrid.identity(preset: preset, stickyBorders: true, propagation: 0.2)
            let moved = mesh.tryMove(index: centerIndex(of: mesh), to: SIMD2(0.58, 0.42))
            #expect(moved)
            _ = mesh.tryMove(index: mesh.index(column: 1, row: 1), to: SIMD2(0.22, 0.18))
            var cpuTiming = MeshWarpRaster.Timing()
            let cpuImage = try #require(MeshWarpRaster.apply(source: source, mesh: mesh, timing: &cpuTiming))
            let sourceBytes = try rgba8(source)
            var gpuBytes = [UInt8](repeating: 0, count: width * height * 4)
            let ok = sourceBytes.withUnsafeBufferPointer { src in
                gpuBytes.withUnsafeMutableBufferPointer { dst in
                    MetalMeshWarp.shared!.apply(source: src.baseAddress!, destination: dst.baseAddress!,
                                                width: width, height: height, stride: width * 4, mesh: mesh)
                }
            }
            #expect(ok, "Metal apply \(width)x\(height) \(preset.label)")
            let stats = compare(try rgba8(cpuImage), gpuBytes, width: width, height: height)
            #expect(stats.maxChannel <= maximumChannelError,
                    "\(width)x\(height) \(preset.label) max \(stats.maxChannel) mean \(stats.meanChannel) mismatches \(stats.mismatchedPixels)")
        }
    }

    @Test func rendererFallsBackAndReportsMetal() throws {
        let source = try checkerboard(width: 40, height: 30, cell: 5)
        var mesh = MeshWarpGrid.identity(preset: .points4, stickyBorders: true, propagation: 0)
        let moved = mesh.tryMove(index: centerIndex(of: mesh), to: SIMD2(0.6, 0.4))
        #expect(moved)
        var sample = MeshWarpRenderer.Sample()
        let image = try #require(MeshWarpRenderer.apply(source: source, mesh: mesh, sample: &sample))
        #expect(image.width == 40 && image.height == 30)
        if MetalMeshWarp.shared != nil {
            #expect(sample.usedMetal)
        } else {
            #expect(!sample.usedMetal)
            #expect(sample.cpuMilliseconds > 0)
        }
    }

    @Test func applyAndCancelAndUndoOnSession() throws {
        let source = try checkerboard(width: 64, height: 48, cell: 8)
        let session = EditorSession()
        session.createDocument(width: 64, height: 48)
        session.insert(ImportedImage(image: source, thumbnail: source, name: "Mesh"))
        session.selectTool(.reshape)
        #expect(session.meshWarpEdit != nil)
        #expect(session.tool == .reshape)

        let edit = try #require(session.meshWarpEdit)
        let index = centerIndex(of: edit.mesh)
        var mesh = edit.mesh
        let moved = mesh.tryMove(index: index, to: mesh.positions[index] + SIMD2(0.1, -0.05))
        #expect(moved)
        edit.mesh = mesh
        edit.refreshPreview()
        #expect(edit.previewCIImage != nil || edit.previewImage != nil)
        #expect(edit.usesGPUResidentPreview || edit.previewImage != nil)

        let beforeApply = try rgba8(try #require(session.activeLayer?.asset?.image))
        session.applyMeshWarp()
        #expect(session.meshWarpEdit == nil)
        let applied = try #require(session.activeLayer?.asset?.image)
        #expect(try rgba8(applied) != beforeApply)

        session.undo()
        let undone = try #require(session.activeLayer?.asset?.image)
        #expect(try rgba8(undone) == beforeApply)

        session.redo()
        let redone = try #require(session.activeLayer?.asset?.image)
        #expect(try rgba8(redone) != beforeApply)

        session.undo()
        session.selectTool(.reshape)
        let again = try #require(session.meshWarpEdit)
        var againMesh = again.mesh
        let cancelMoved = againMesh.tryMove(index: centerIndex(of: againMesh),
                                            to: againMesh.positions[centerIndex(of: againMesh)] + SIMD2(-0.08, 0.06))
        #expect(cancelMoved)
        again.mesh = againMesh
        again.refreshPreview()
        session.cancelMeshWarp()
        #expect(session.meshWarpEdit == nil)
        let cancelled = try #require(session.activeLayer?.asset?.image)
        #expect(try rgba8(cancelled) == beforeApply)
    }

    @Test func gpuResidentPreviewMatchesApply() throws {
        guard MetalMeshWarp.shared != nil else { return }
        let source = try checkerboard(width: 96, height: 72, cell: 6)
        let session = EditorSession()
        session.createDocument(width: 96, height: 72)
        session.insert(ImportedImage(image: source, thumbnail: source, name: "Preview"))
        session.beginMeshWarp(preset: .points8)
        let edit = try #require(session.meshWarpEdit)
        var mesh = edit.mesh
        let index = centerIndex(of: mesh)
        let first = mesh.tryMove(index: index, to: mesh.positions[index] + SIMD2(0.08, -0.06))
        let second = mesh.tryMove(index: index, to: mesh.positions[index] + SIMD2(-0.03, 0.04))
        #expect(first && second)
        edit.mesh = mesh
        edit.refreshPreview(waitForGPU: true)
        #expect(edit.usesGPUResidentPreview)
        var sample = MeshWarpRenderer.Sample()
        let committed = try #require(edit.commitImage(sample: &sample))
        #expect(sample.usedResidentPreview)
        let previewBytes = try rgba8(try #require(edit.commitImageForCanvas()))
        let applyBytes = try rgba8(committed)
        let stats = compare(previewBytes, applyBytes, width: 96, height: 72)
        #expect(stats.maxChannel == 0, "preview/apply diverge max \(stats.maxChannel)")
    }

    @Test func rapidDragsStayOrderedAndCancelDropsGPUWork() throws {
        guard MetalMeshWarp.shared != nil else { return }
        let source = try checkerboard(width: 80, height: 60, cell: 5)
        let session = EditorSession()
        session.createDocument(width: 80, height: 60)
        session.insert(ImportedImage(image: source, thumbnail: source, name: "Rapid"))
        session.beginMeshWarp(preset: .points8)
        let edit = try #require(session.meshWarpEdit)
        let index = centerIndex(of: edit.mesh)
        let before = try rgba8(source)
        for step in 0..<8 {
            var mesh = edit.mesh
            let delta = SIMD2(Float(step) * 0.01, Float(step) * -0.008)
            let moved = mesh.tryMove(index: index, to: mesh.rest[index] + delta)
            #expect(moved || mesh.positions[index] != mesh.rest[index])
            edit.mesh = mesh
            edit.refreshPreview(waitForGPU: true)
        }
        #expect(edit.previewGeneration > 0)
        session.meshWarpEndDrag()
        var sample = MeshWarpRenderer.Sample()
        let finalPreview = try #require(edit.commitImage(sample: &sample))
        session.applyMeshWarp()
        let applied = try #require(session.activeLayer?.asset?.image)
        let stats = compare(try rgba8(finalPreview), try rgba8(applied), width: 80, height: 60)
        #expect(stats.maxChannel == 0)

        session.undo()
        session.beginMeshWarp(preset: .points4)
        let cancelEdit = try #require(session.meshWarpEdit)
        var cancelMesh = cancelEdit.mesh
        let cancelMoved = cancelMesh.tryMove(index: centerIndex(of: cancelMesh), to: SIMD2(0.6, 0.4))
        #expect(cancelMoved)
        cancelEdit.mesh = cancelMesh
        cancelEdit.refreshPreview(waitForGPU: false)
        session.cancelMeshWarp()
        #expect(session.meshWarpEdit == nil)
        #expect(try rgba8(try #require(session.activeLayer?.asset?.image)) == before)
    }

    @Test func switchingGridSizesResetsPreview() throws {
        let source = try checkerboard(width: 64, height: 48, cell: 8)
        let session = EditorSession()
        session.createDocument(width: 64, height: 48)
        session.insert(ImportedImage(image: source, thumbnail: source, name: "Grid"))
        session.beginMeshWarp(preset: .points4)
        let edit = try #require(session.meshWarpEdit)
        var mesh = edit.mesh
        let gridMoved = mesh.tryMove(index: centerIndex(of: mesh), to: SIMD2(0.55, 0.45))
        #expect(gridMoved)
        edit.mesh = mesh
        edit.refreshPreview()
        session.setMeshWarpPreset(.points16)
        #expect(session.meshWarpEdit?.mesh.pointColumns == 16)
        #expect(session.meshWarpEdit?.mesh.isIdentity == true)
        #expect(session.meshWarpEdit?.previewCIImage == nil)
        #expect(session.meshWarpEdit?.previewImage == nil)
    }

    @Test func deepLayerIsRefused() throws {
        let preview = try checkerboard(width: 32, height: 24, cell: 4)
        let deepContext = try #require(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 16, bytesPerRow: 32 * 8,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                                                    .union(.byteOrder16Little).rawValue))
        deepContext.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        deepContext.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let deep = try #require(deepContext.makeImage())
        var asset = ImportedImage(image: preview, thumbnail: preview, name: "Deep")
        asset.deep = deep
        let session = EditorSession()
        session.createDocument(width: 32, height: 24)
        session.insert(asset)
        session.selectTool(.reshape)
        #expect(session.meshWarpEdit == nil)
        #expect(session.brushError?.contains("8-bit") == true)
    }

    @Test func zoomInvariantUVMapping() throws {
        // UV ↔ document mapping uses the layer transform only; canvas zoom must not change it.
        let transform = LayerTransform(origin: CGPoint(x: 10, y: 20), size: CGSize(width: 100, height: 80))
        let uv = SIMD2<Float>(0.4, 0.6)
        let documentPoint = transform.point(CGPoint(x: CGFloat(uv.x), y: CGFloat(uv.y)))
        let documentSize = CGSize(width: 200, height: 160)
        for zoom in [0.25, 1.0, 2.5, 8.0] as [CGFloat] {
            var viewport = CanvasViewport()
            viewport.resize(to: CGSize(width: 800, height: 600), backingScale: 2, documentSize: documentSize)
            viewport.setZoom(zoom, anchoredAt: CGPoint(x: 400, y: 300), documentSize: documentSize)
            let inverse = transform.unitToDocument.inverted()
            let unit = documentPoint.applying(inverse)
            #expect(abs(Float(unit.x) - uv.x) < 1e-5, "zoom \(zoom)")
            #expect(abs(Float(unit.y) - uv.y) < 1e-5, "zoom \(zoom)")
            let view = viewport.viewPoint(from: documentPoint, documentSize: documentSize)
            let back = viewport.documentPoint(from: view, documentSize: documentSize)
            #expect(abs(back.x - documentPoint.x) < 1e-4, "round-trip x at zoom \(zoom)")
            #expect(abs(back.y - documentPoint.y) < 1e-4, "round-trip y at zoom \(zoom)")
        }
    }

    @Test func doesNotModifyOtherLayers() throws {
        let a = try checkerboard(width: 40, height: 40, cell: 5)
        let b = try checkerboard(width: 40, height: 40, cell: 7)
        let beforeB = try rgba8(b)
        let session = EditorSession()
        session.createDocument(width: 80, height: 40)
        session.insert(ImportedImage(image: a, thumbnail: a, name: "A"))
        let layerAID = try #require(session.activeLayerID)
        session.insert(ImportedImage(image: b, thumbnail: b, name: "B"))
        let layerBID = try #require(session.activeLayerID)
        if let index = session.document?.layers.firstIndex(where: { $0.id == layerBID }) {
            session.document?.layers[index].transform.origin = CGPoint(x: 40, y: 0)
        }
        session.selectLayer(layerAID)
        session.beginMeshWarp(preset: .points4)
        let edit = try #require(session.meshWarpEdit)
        var mesh = edit.mesh
        let moved = mesh.tryMove(index: centerIndex(of: mesh), to: SIMD2(0.6, 0.4))
        #expect(moved)
        edit.mesh = mesh
        session.applyMeshWarp()
        let other = try #require(session.document?.layers.first(where: { $0.id == layerBID })?.asset?.image)
        #expect(try rgba8(other) == beforeB)
    }

    @Test func resetReturnsIdentity() throws {
        var mesh = MeshWarpGrid.identity(preset: .points16, stickyBorders: true, propagation: 0.3)
        let moved = mesh.tryMove(index: centerIndex(of: mesh), to: SIMD2(0.55, 0.45))
        #expect(moved)
        mesh.resetToRest()
        #expect(mesh.isIdentity)
    }
}
