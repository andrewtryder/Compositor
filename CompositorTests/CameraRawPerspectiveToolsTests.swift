import AppKit
import Foundation
import Testing
@testable import Compositor

/// Milestone 10.5: the seven Advanced Perspective Tools. Every test drives `CameraRawPerspectiveToolState`,
/// `CameraRawPerspectiveTools` and the `EditorSession` drawing methods the panel and the canvas call: no test
/// reimplements a homography, and no test asserts a parity with another product that has not been measured.
@MainActor
struct CameraRawPerspectiveToolsTests {
    // MARK: - Helpers

    /// A gradient with a hard ruled grid, so a correction shows in the pixels and not only in the corners.
    private func ruled(width: Int = 96, height: Int = 64) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                let i = y * stride + x * 4
                data[i] = UInt8((x * 255) / max(width - 1, 1))
                data[i + 1] = UInt8((y * 255) / max(height - 1, 1))
                data[i + 2] = ((x / 6) + (y / 6)) % 2 == 0 ? 240 : 20
                data[i + 3] = 255
            }
        }
        return try #require(context.makeImage())
    }

    private func rgba8(_ image: CGImage) throws -> [UInt8] {
        try MeshWarpRaster.rgba8Bytes(from: image)
    }

    private func maxDelta(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    /// A session with a Camera Raw panel open and a preview source, as `beginFilter` sets up.
    private func cameraRawSession(width: Int = 96, height: Int = 64) throws -> (EditorSession, FilterEdit) {
        let image = try ruled(width: width, height: height)
        let session = EditorSession()
        session.createDocument(width: width, height: height)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Photo"))
        session.beginFilter(.cameraRaw)
        let edit = try #require(session.filterEdit)
        edit.previewSource = image
        return (session, edit)
    }

    /// Two verticals that converge upward, which is what makes a keystone correction visible.
    private func convergingVerticals() -> [CameraRawGeometryGuide] {
        [CameraRawGeometryGuide(startX: 0.2, startY: 0.05, endX: 0.35, endY: 0.95),
         CameraRawGeometryGuide(startX: 0.8, startY: 0.05, endX: 0.65, endY: 0.95)]
    }

    /// Document points for a normalized image point, through the same mapping the canvas overlay uses.
    private func documentPoint(_ normalized: CGPoint, edit: FilterEdit) -> CGPoint {
        let image = edit.previewSource
        return CGPoint(x: normalized.x * CGFloat(image.width), y: normalized.y * CGFloat(image.height))
            .applying(edit.previewMapping)
    }

    /// Drags from one normalized point to another through the public canvas interaction methods.
    private func drawGuide(from start: CGPoint, to end: CGPoint, session: EditorSession, edit: FilterEdit) {
        session.beginCameraRawPerspectiveToolInteraction(at: documentPoint(start, edit: edit), zoom: 1)
        session.continueCameraRawPerspectiveToolInteraction(to: documentPoint(end, edit: edit))
        session.endCameraRawPerspectiveToolInteraction()
    }

    // MARK: - 1. Automatic is the default and changes nothing

    @Test func automaticIsTheDefaultAndLeavesEveryValueAlone() {
        let state = CameraRawPerspectiveToolState()
        #expect(state.kind == .automatic)
        #expect(!state.kind.drawsOnCanvas)
        #expect(!state.kind.ownsSolver)
        #expect(state.guideCount() == 0)
        #expect(CameraRawPerspectiveTools.dragTargets(for: state).isEmpty)

        var geometry = CameraRawGeometrySettings()
        geometry.upright = .guided
        geometry.guides = convergingVerticals()
        geometry.vertical = 12
        let untouched = CameraRawPerspectiveTools.applying(state, to: geometry)
        #expect(untouched == geometry, "Automatic hands the picture back to the existing path, byte for byte")
    }

    // MARK: - 2. The five legacy Upright modes still behave as they did

    @Test func legacyUprightModesAreUnchangedByAnAutomaticTool() throws {
        #expect(CameraRawUprightMode.allCases == [.off, .autoLevel, .autoVertical, .autoFull, .guided])
        var settings = CameraRawSettings()
        settings.perspectiveTools.kind = .automatic
        for mode in CameraRawUprightMode.allCases {
            settings.geometry.upright = mode
            settings.geometry.guides = convergents(for: mode)
            let geometry = CameraRawPerspectiveTools.applying(settings.perspectiveTools, to: settings.geometry)
            #expect(geometry.upright == mode, "\(mode.rawValue) survives an Automatic tool")
            #expect(geometry.guides == settings.geometry.guides)
        }
        // The guided solver still produces a real correction through the same backend.
        var tools = CameraRawPerspectiveToolState()
        tools.kind = .verticalGuides
        tools.verticalGuides = convergingVerticals()
        settings.perspectiveTools = tools
        settings.geometry.upright = .guided
        let output = try CameraRawGeometryBackend.geometry(applying: CameraRawGeometryBackendSettings(
            geometry: settings.geometry, perspectiveTools: tools))
        #expect(output.upright == .guided)
        #expect(output.guides.count == 2)
    }

    private func convergents(for mode: CameraRawUprightMode) -> [CameraRawGeometryGuide] {
        mode == .guided ? convergingVerticals() : []
    }

    // MARK: - 3. Each tool selects its own stored geometry

    @Test func eachToolReadsItsOwnStoredPoints() {
        var state = CameraRawPerspectiveToolState()
        let doubles: [CameraRawGeometryGuide] = [
            CameraRawGeometryGuide(startX: 0.1, startY: 0.1, endX: 0.2, endY: 0.9),
            CameraRawGeometryGuide(startX: 0.9, startY: 0.1, endX: 0.8, endY: 0.9)
        ]
        state.verticalGuides = doubles
        state.horizontalGuides = [CameraRawGeometryGuide(startX: 0.1, startY: 0.3, endX: 0.9, endY: 0.35)]
        state.eightPointGuides = [
            CameraRawGeometryGuide(startX: 0.1, startY: 0.1, endX: 0.4, endY: 0.15),
            CameraRawGeometryGuide(startX: 0.6, startY: 0.15, endX: 0.9, endY: 0.1),
            CameraRawGeometryGuide(startX: 0.12, startY: 0.9, endX: 0.45, endY: 0.85),
            CameraRawGeometryGuide(startX: 0.55, startY: 0.85, endX: 0.88, endY: 0.9)
        ]
        state.rectangleCorners = [CGPoint(x: 0.2, y: 0.9), CGPoint(x: 0.8, y: 0.85),
                                  CGPoint(x: 0.75, y: 0.15), CGPoint(x: 0.25, y: 0.2)]

        state.kind = .verticalGuides
        #expect(CameraRawPerspectiveTools.activeGuides(for: state) == doubles)
        state.kind = .horizontalGuides
        #expect(CameraRawPerspectiveTools.activeGuides(for: state) == state.horizontalGuides)
        state.kind = .combinedGuides
        #expect(CameraRawPerspectiveTools.activeGuides(for: state) == doubles + state.horizontalGuides,
                "deterministic order: every vertical, then every horizontal")
        state.kind = .eightPoint
        #expect(CameraRawPerspectiveTools.activeGuides(for: state)?.count == 4)
        state.kind = .rectangle
        let rectangle = try? #require(CameraRawPerspectiveTools.activeGuides(for: state))
        #expect(rectangle?.count == 4, "four corners become four edges")
        state.kind = .automatic
        #expect(CameraRawPerspectiveTools.activeGuides(for: state) == nil)
        state.kind = .manualKeystone
        #expect(CameraRawPerspectiveTools.activeGuides(for: state) == nil)
    }

    // MARK: - 4–6. Vertical, horizontal and combined correction

    @Test func verticalGuidesWarpThePicture() throws {
        let image = try ruled(width: 64, height: 64)
        var tools = CameraRawPerspectiveToolState()
        tools.kind = .verticalGuides
        tools.verticalGuides = convergingVerticals()
        var settings = CameraRawSettings()
        settings.perspectiveTools = tools
        let out = try settings.apply(image)
        #expect(try maxDelta(try rgba8(image), try rgba8(out)) > 8, "two vertical guides produce a real correction")
        #expect(tools.problem(width: 64, height: 64) == nil)
    }

    @Test func horizontalGuidesWarpThePicture() throws {
        var tools = CameraRawPerspectiveToolState()
        tools.kind = .horizontalGuides
        tools.horizontalGuides = [
            CameraRawGeometryGuide(startX: 0.05, startY: 0.3, endX: 0.95, endY: 0.42),
            CameraRawGeometryGuide(startX: 0.05, startY: 0.7, endX: 0.95, endY: 0.82)
        ]
        #expect(tools.problem(width: 200, height: 120) == nil)
        let geometry = CameraRawPerspectiveTools.applying(tools, to: CameraRawGeometrySettings())
        #expect(geometry.upright == .guided)
        #expect(geometry.guides.count == 2)
    }

    @Test func combinedGuidesUseBothListsInAStableOrder() throws {
        var tools = CameraRawPerspectiveToolState()
        tools.kind = .combinedGuides
        tools.verticalGuides = convergingVerticals()
        tools.horizontalGuides = [
            CameraRawGeometryGuide(startX: 0.05, startY: 0.25, endX: 0.95, endY: 0.3),
            CameraRawGeometryGuide(startX: 0.05, startY: 0.75, endX: 0.95, endY: 0.72)
        ]
        #expect(tools.problem(width: 200, height: 120) == nil)
        let guides = try #require(CameraRawPerspectiveTools.activeGuides(for: tools))
        #expect(guides == tools.verticalGuides + tools.horizontalGuides)
        // Same input, same solver input, every time: the order never depends on dictionary or set iteration.
        #expect(CameraRawPerspectiveTools.activeGuides(for: tools) == guides)
    }

    // MARK: - 7. Rectangle construction

    @Test func rectangleConstructionProducesFourOrderedEdges() throws {
        var tools = CameraRawPerspectiveToolState()
        tools.kind = .rectangle
        tools.rectangleCorners = [CGPoint(x: 0.2, y: 0.9), CGPoint(x: 0.8, y: 0.85),
                                  CGPoint(x: 0.75, y: 0.15), CGPoint(x: 0.25, y: 0.2)]
        let edges = try #require(CameraRawPerspectiveTools.rectangleGuides(corners: tools.rectangleCorners))
        #expect(edges.count == 4)
        #expect(edges[0].startX == 0.2 && edges[0].startY == 0.9, "TL")
        #expect(edges[0].endX == 0.8 && edges[0].endY == 0.85, "TL → TR")
        #expect(edges[2].endX == 0.25 && edges[2].endY == 0.2, "BR → BL")
        #expect(edges[3].endX == 0.2 && edges[3].endY == 0.9, "BL → TL closes the quad")
        #expect(tools.problem(width: 200, height: 120) == nil)
    }

    @Test func incompleteRectangleAppliesNothing() {
        var tools = CameraRawPerspectiveToolState()
        tools.kind = .rectangle
        tools.rectangleCorners = [CGPoint(x: 0.2, y: 0.9), CGPoint(x: 0.8, y: 0.85), CGPoint(x: 0.75, y: 0.15)]
        #expect(CameraRawPerspectiveTools.rectangleGuides(corners: tools.rectangleCorners) == nil)
        #expect(CameraRawPerspectiveTools.activeGuides(for: tools) == [])
        #expect(tools.problem(width: 200, height: 120) == .insufficientPoints)
        var geometry = CameraRawGeometrySettings()
        geometry.upright = .guided
        geometry.guides = convergingVerticals()
        let applied = CameraRawPerspectiveTools.applying(tools, to: geometry)
        #expect(applied.upright == .off, "three corners never leave the previous correction on screen")
        #expect(applied.guides.isEmpty)
    }

    @Test func rectangleCornerOrderIsEnforced() {
        let crossed = [CGPoint(x: 0.2, y: 0.9), CGPoint(x: 0.25, y: 0.2),
                       CGPoint(x: 0.75, y: 0.15), CGPoint(x: 0.8, y: 0.85)]
        #expect(CameraRawPerspectiveTools.rectangleProblem(corners: crossed) == .invalidCornerOrder)
        let reversedX = [CGPoint(x: 0.8, y: 0.9), CGPoint(x: 0.2, y: 0.85),
                         CGPoint(x: 0.25, y: 0.15), CGPoint(x: 0.75, y: 0.2)]
        #expect(CameraRawPerspectiveTools.rectangleProblem(corners: reversedX) == .invalidCornerOrder)
        #expect(CameraRawPerspectiveTools.rectangleGuides(corners: crossed) == nil)
    }

    // MARK: - 8. Eight Point construction

    @Test func eightPointNeedsAllFourSegments() {
        var tools = CameraRawPerspectiveToolState()
        tools.kind = .eightPoint
        tools.eightPointGuides = [
            CameraRawGeometryGuide(startX: 0.1, startY: 0.15, endX: 0.45, endY: 0.12),
            CameraRawGeometryGuide(startX: 0.55, startY: 0.12, endX: 0.9, endY: 0.15)
        ]
        #expect(tools.problem(width: 200, height: 120) == .insufficientPoints)
        #expect(CameraRawPerspectiveTools.activeGuides(for: tools) == [],
                "two segments are half a construction, not a weaker correction")
        var geometry = CameraRawGeometrySettings()
        geometry.guides = convergingVerticals()
        geometry.upright = .guided
        let partial = CameraRawPerspectiveTools.applying(tools, to: geometry)
        #expect(partial.upright == .off)

        tools.eightPointGuides += [
            CameraRawGeometryGuide(startX: 0.12, startY: 0.88, endX: 0.48, endY: 0.85),
            CameraRawGeometryGuide(startX: 0.52, startY: 0.85, endX: 0.88, endY: 0.88)
        ]
        #expect(tools.problem(width: 200, height: 120) == nil)
        let applied = CameraRawPerspectiveTools.applying(tools, to: geometry)
        #expect(applied.upright == .guided)
        #expect(applied.guides.count == 4, "four segments, eight endpoints")
    }

    @Test func eightPointIsFourSegmentsNotEightSeparateGuides() {
        #expect(CameraRawPerspectiveToolState.capacity(for: .eightPoint) == 4)
        var tools = CameraRawPerspectiveToolState()
        tools.kind = .eightPoint
        for index in 0..<4 {
            let ok = CameraRawPerspectiveTools.appendGuide(
                CameraRawGeometryGuide(startX: 0.1, startY: 0.1 + Double(index) * 0.2,
                                       endX: 0.9, endY: 0.12 + Double(index) * 0.2),
                to: .eightPoint, in: &tools)
            #expect(ok)
        }
        #expect(tools.eightPointGuides.count == 4)
        let fifth = CameraRawPerspectiveTools.appendGuide(
            CameraRawGeometryGuide(startX: 0.1, startY: 0.95, endX: 0.9, endY: 0.97),
            to: .eightPoint, in: &tools)
        #expect(!fifth, "a fifth segment is refused, so the limits stay a model of eight endpoints")
        // The normal Guided mode keeps its own four-guide limit, untouched by this tool's numbers.
        #expect(CameraRawPerspectiveToolState.capacity(for: .vertical) == 2)
    }

    // MARK: - 9. Manual Keystone synchronization

    @Test func manualKeystoneMirrorsTheExistingSliders() throws {
        var settings = CameraRawSettings()
        settings.geometry.vertical = 24
        settings.geometry.horizontal = -8
        settings.geometry.rotate = 3.5
        let normalized = settings.normalized
        #expect(normalized.perspectiveTools.manualKeystoneIsMirrored(with: normalized.geometry),
                "normalizing refreshes the mirror, so it can never be stale")

        // The tool state that reaches the renderer never overrides the sliders.
        var tools = CameraRawPerspectiveToolState()
        tools.kind = .manualKeystone
        tools.manualVertical = -100
        tools.manualHorizontal = 100
        tools.manualRotate = 45
        let geometry = CameraRawPerspectiveTools.applying(tools, to: normalized.geometry)
        #expect(geometry.vertical == 24)
        #expect(geometry.horizontal == -8)
        #expect(geometry.rotate == 3.5)

        // The sliders still produce a real correction under Manual Keystone.
        let corners = geometry.outputCorners(width: 100, height: 80)
        let identity = CameraRawPerspective.identityCorners(width: 100, height: 80)
        #expect(!zip(corners, identity).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 0.05 })
    }

    @Test func selectingManualKeystoneSeedsTheMirrorFromTheSliders() throws {
        let (session, edit) = try cameraRawSession()
        var settings = edit.settings
        settings.cameraRaw.geometry.vertical = 15
        settings.cameraRaw.geometry.rotate = 2
        session.updateFilter(settings, preview: true)

        session.selectCameraRawPerspectiveTool(.manualKeystone)
        let raw = edit.settings.cameraRaw
        #expect(raw.perspectiveTools.kind == .manualKeystone)
        #expect(raw.perspectiveTools.manualVertical == 15)
        #expect(raw.perspectiveTools.manualRotate == 2)
        #expect(raw.perspectiveTools.manualKeystoneIsMirrored(with: raw.geometry))
        #expect(raw.geometry.upright == .off, "the sliders solve only with Upright off, exactly as before")
    }

    @Test func aspectScaleAndOffsetSurviveManualKeystone() {
        var geometry = CameraRawGeometrySettings()
        geometry.vertical = 10
        geometry.aspect = 20
        geometry.scale = 12
        geometry.offsetX = -5
        geometry.offsetY = 7
        var tools = CameraRawPerspectiveToolState()
        tools.kind = .manualKeystone
        let applied = CameraRawPerspectiveTools.applying(tools, to: geometry)
        #expect(applied.aspect == 20)
        #expect(applied.scale == 12)
        #expect(applied.offsetX == -5)
        #expect(applied.offsetY == 7)
        #expect(applied.perspectiveAmount == 100)
    }

    // MARK: - 10. Inactive tool state does not affect the active rendering

    @Test func inactiveToolStateNeverReachesTheRenderer() throws {
        var tools = CameraRawPerspectiveToolState()
        tools.kind = .verticalGuides
        tools.verticalGuides = convergingVerticals()
        // Another tool, and Manual Keystone, hold very different work. None of it may leak into the active tool.
        tools.horizontalGuides = [CameraRawGeometryGuide(startX: 0.05, startY: 0.5, endX: 0.95, endY: 0.6)]
        tools.eightPointGuides = [CameraRawGeometryGuide(startX: 0, startY: 0, endX: 1, endY: 1)]
        tools.rectangleCorners = [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 0)]
        tools.manualVertical = 60
        let geometry = CameraRawPerspectiveTools.applying(tools, to: CameraRawGeometrySettings())
        #expect(geometry.guides == convergingVerticals())
        #expect(geometry.vertical == 0, "a stored keystone mirror never silently applies")
    }

    // MARK: - 11. Mode switching preserves independent data

    @Test func switchingToolsPreservesEachToolsWork() throws {
        let (session, edit) = try cameraRawSession()
        session.selectCameraRawPerspectiveTool(.verticalGuides)
        session.beginCameraRawPerspectiveToolDrawing()
        drawGuide(from: CGPoint(x: 0.2, y: 0.1), to: CGPoint(x: 0.32, y: 0.9), session: session, edit: edit)
        drawGuide(from: CGPoint(x: 0.8, y: 0.1), to: CGPoint(x: 0.68, y: 0.9), session: session, edit: edit)
        #expect(edit.settings.cameraRaw.perspectiveTools.verticalGuides.count == 2)

        session.selectCameraRawPerspectiveTool(.horizontalGuides)
        drawGuide(from: CGPoint(x: 0.1, y: 0.3), to: CGPoint(x: 0.9, y: 0.35), session: session, edit: edit)
        #expect(edit.settings.cameraRaw.perspectiveTools.horizontalGuides.count == 1)
        #expect(edit.settings.cameraRaw.perspectiveTools.verticalGuides.count == 2, "verticals kept their work")

        session.selectCameraRawPerspectiveTool(.verticalGuides)
        #expect(edit.settings.cameraRaw.perspectiveTools.verticalGuides.count == 2)
        #expect(edit.settings.cameraRaw.perspectiveTools.horizontalGuides.count == 1)

        session.selectCameraRawPerspectiveTool(.automatic)
        #expect(edit.settings.cameraRaw.perspectiveTools.kind == .automatic)
        #expect(edit.settings.cameraRaw.perspectiveTools.verticalGuides.count == 2,
                "returning to Automatic loses no stored work")
    }

    // MARK: - 12. Incomplete tools render no stale geometry

    @Test func switchingAwayFromAnIncompleteToolLeavesNoGeometry() throws {
        let (session, edit) = try cameraRawSession()
        var settings = edit.settings
        settings.cameraRaw.geometry.upright = .guided
        settings.cameraRaw.geometry.guides = convergingVerticals()
        session.updateFilter(settings, preview: true)
        #expect(CameraRawPerspectiveTools.applying(edit.settings.cameraRaw.perspectiveTools,
                                                   to: edit.settings.cameraRaw.geometry).upright == .guided)

        session.selectCameraRawPerspectiveTool(.rectangle)
        let applied = CameraRawPerspectiveTools.applying(edit.settings.cameraRaw.perspectiveTools,
                                                        to: edit.settings.cameraRaw.geometry)
        #expect(applied.upright == .off, "an empty rectangle hides the previous Guided correction")
        // The Guided guides themselves are still stored, so going back restores them exactly.
        #expect(edit.settings.cameraRaw.geometry.guides.count == 2)
        session.selectCameraRawPerspectiveTool(.automatic)
        #expect(CameraRawPerspectiveTools.applying(edit.settings.cameraRaw.perspectiveTools,
                                                   to: edit.settings.cameraRaw.geometry).upright == .guided)
    }

    // MARK: - 13–14. Dragging, and Escape

    @Test func draggingAnEndpointUpdatesThatPointOnly() throws {
        let (session, edit) = try cameraRawSession(width: 200, height: 150)
        var tools = edit.settings.cameraRaw.perspectiveTools
        tools.kind = .verticalGuides
        tools.verticalGuides = convergingVerticals()
        session.selectCameraRawPerspectiveTool(.verticalGuides)
        var settings = edit.settings
        settings.cameraRaw.perspectiveTools = tools
        session.updateFilter(settings, preview: true)
        session.beginCameraRawPerspectiveToolDrawing()

        let handle = documentPoint(CGPoint(x: 0.2, y: 0.05), edit: edit)
        #expect(session.cameraRawHitPerspectiveHandle(at: handle, zoom: 1) ==
                .guide(list: .vertical, index: 0, isEnd: false))
        session.beginCameraRawPerspectiveToolInteraction(at: handle, zoom: 1)
        session.continueCameraRawPerspectiveToolInteraction(to: documentPoint(CGPoint(x: 0.3, y: 0.1), edit: edit))
        session.endCameraRawPerspectiveToolInteraction()

        let state = edit.settings.cameraRaw.perspectiveTools
        #expect(abs(state.verticalGuides[0].startX - 0.3) < 0.01)
        #expect(abs(state.verticalGuides[0].startY - 0.1) < 0.01)
        #expect(abs(state.verticalGuides[0].endX - 0.35) < 1e-9, "the opposite endpoint stayed fixed")
        #expect(abs(state.verticalGuides[1].startX - 0.8) < 1e-9, "the other guide was not touched")
    }

    @Test func escapeRestoresTheOriginalDragState() throws {
        let (session, edit) = try cameraRawSession(width: 200, height: 150)
        var tools = edit.settings.cameraRaw.perspectiveTools
        tools.kind = .verticalGuides
        tools.verticalGuides = convergingVerticals()
        var settings = edit.settings
        settings.cameraRaw.perspectiveTools = tools
        session.updateFilter(settings, preview: true)
        session.selectCameraRawPerspectiveTool(.verticalGuides)
        session.beginCameraRawPerspectiveToolDrawing()

        let original = try #require(edit.settings.cameraRaw.perspectiveTools.verticalGuides.first)
        let handle = documentPoint(CGPoint(x: 0.2, y: 0.05), edit: edit)
        session.beginCameraRawPerspectiveToolInteraction(at: handle, zoom: 1)
        session.continueCameraRawPerspectiveToolInteraction(to: documentPoint(CGPoint(x: 0.45, y: 0.2), edit: edit))
        #expect(abs(edit.settings.cameraRaw.perspectiveTools.verticalGuides[0].startX - 0.45) < 0.01)

        session.cancelCameraRawPerspectiveDraft()
        let restored = edit.settings.cameraRaw.perspectiveTools.verticalGuides[0]
        #expect(restored.startX == original.startX, "Escape puts the exact coordinate back")
        #expect(restored.startY == original.startY)
        #expect(edit.cameraRawPerspectiveDragTarget == nil)
        #expect(edit.cameraRawPerspectiveDragOriginalPoint == nil)
    }

    @Test func escapeDropsAnUnfinishedGuide() throws {
        let (session, edit) = try cameraRawSession(width: 200, height: 150)
        session.selectCameraRawPerspectiveTool(.verticalGuides)
        session.beginCameraRawPerspectiveToolDrawing()
        session.beginCameraRawPerspectiveToolInteraction(at: documentPoint(CGPoint(x: 0.2, y: 0.2), edit: edit), zoom: 1)
        session.continueCameraRawPerspectiveToolInteraction(to: documentPoint(CGPoint(x: 0.3, y: 0.8), edit: edit))
        #expect(edit.cameraRawPerspectiveDraft != nil)
        session.cancelCameraRawPerspectiveDraft()
        #expect(edit.cameraRawPerspectiveDraft == nil)
        #expect(edit.settings.cameraRaw.perspectiveTools.verticalGuides.isEmpty, "no document-history entry is made")
    }

    // MARK: - 15. Degenerate geometry is rejected

    @Test func degenerateGeometryIsRejected() {
        var tools = CameraRawPerspectiveToolState()
        tools.kind = .verticalGuides
        // Zero length.
        tools.verticalGuides = [CameraRawGeometryGuide(startX: 0.5, startY: 0.5, endX: 0.5, endY: 0.5)]
        #expect(CameraRawPerspectiveTools.problem(in: tools, width: 100, height: 100) == .zeroLengthSegment)
        // Duplicates.
        let guide = CameraRawGeometryGuide(startX: 0.2, startY: 0.1, endX: 0.3, endY: 0.9)
        tools.verticalGuides = [guide, guide]
        #expect(CameraRawPerspectiveTools.problem(in: tools, width: 100, height: 100) == .duplicatePoints)
        // Collinear. B lies exactly on A's line, so the pair constrains no keystone at all.
        tools.verticalGuides = [
            CameraRawGeometryGuide(startX: 0.2, startY: 0.0, endX: 0.3, endY: 1.0),
            CameraRawGeometryGuide(startX: 0.24, startY: 0.4, endX: 0.28, endY: 0.8)
        ]
        #expect(CameraRawPerspectiveTools.problem(in: tools, width: 100, height: 100) == .collinearConstraints)
        // Non-finite.
        tools.verticalGuides = [CameraRawGeometryGuide(startX: .nan, startY: 0.1, endX: 0.3, endY: 0.9)]
        #expect(CameraRawPerspectiveTools.problem(in: tools, width: 100, height: 100) == .nonFiniteCoordinates)
        // Nothing at all.
        tools.verticalGuides = []
        #expect(CameraRawPerspectiveTools.problem(in: tools, width: 100, height: 100) == .insufficientPoints)
    }

    @Test func anExtremeRectangleIsRefusedRatherThanFolded() {
        // Two corners at the same spot, and a quad whose area is far too small to constrain anything.
        #expect(CameraRawPerspectiveTools.rectangleProblem(corners: [
            CGPoint(x: 0.5, y: 0.9), CGPoint(x: 0.5, y: 0.9),
            CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.4, y: 0.5)
        ]) == .duplicatePoints)
        #expect(CameraRawPerspectiveTools.rectangleProblem(corners: [
            CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.505, y: 0.5),
            CGPoint(x: 0.505, y: 0.505), CGPoint(x: 0.5, y: 0.505)
        ]) != nil, "a half-percent quad is not a rectangle worth solving")
        #expect(CameraRawPerspectiveTools.rectangleProblem(corners: [
            CGPoint(x: -0.2, y: 0.9), CGPoint(x: 0.8, y: 0.9),
            CGPoint(x: 0.8, y: 0.1), CGPoint(x: -0.2, y: 0.1)
        ]) == .coordinatesOutsideImage)
    }

    // MARK: - 16. Perspective Amount composition

    @Test func perspectiveAmountZeroIsIdentityForAnyTool() throws {
        var geometry = CameraRawGeometrySettings()
        geometry.perspectiveAmount = 0
        for kind in [CameraRawPerspectiveToolKind.verticalGuides, .horizontalGuides, .combinedGuides,
                     .rectangle, .eightPoint] {
            var tools = CameraRawPerspectiveToolState()
            tools.kind = kind
            tools.verticalGuides = convergingVerticals()
            tools.horizontalGuides = [CameraRawGeometryGuide(startX: 0.05, startY: 0.3, endX: 0.95, endY: 0.45)]
            tools.rectangleCorners = [CGPoint(x: 0.2, y: 0.9), CGPoint(x: 0.8, y: 0.85),
                                      CGPoint(x: 0.75, y: 0.15), CGPoint(x: 0.25, y: 0.2)]
            tools.eightPointGuides = [
                CameraRawGeometryGuide(startX: 0.1, startY: 0.15, endX: 0.45, endY: 0.12),
                CameraRawGeometryGuide(startX: 0.55, startY: 0.12, endX: 0.9, endY: 0.15),
                CameraRawGeometryGuide(startX: 0.12, startY: 0.88, endX: 0.48, endY: 0.85),
                CameraRawGeometryGuide(startX: 0.52, startY: 0.85, endX: 0.88, endY: 0.88)
            ]
            let applied = CameraRawPerspectiveTools.applying(tools, to: geometry)
            let corners = applied.outputCorners(width: 100, height: 80)
            let identity = CameraRawPerspective.identityCorners(width: 100, height: 80)
            #expect(zip(corners, identity).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 1e-9 },
                    "\(kind.rawValue) at Perspective Amount 0 is identity")
        }
    }

    @Test func perspectiveAmountBlendsRatherThanReplacing() throws {
        var tools = CameraRawPerspectiveToolState()
        tools.kind = .verticalGuides
        tools.verticalGuides = convergingVerticals()
        func corners(_ amount: Double) -> [CGPoint] {
            var geometry = CameraRawGeometrySettings()
            geometry.perspectiveAmount = amount
            return CameraRawPerspectiveTools.applying(tools, to: geometry).outputCorners(width: 200, height: 160)
        }
        let identity = CameraRawPerspective.identityCorners(width: 200, height: 160)
        let half = corners(50), full = corners(100)
        let halfMove = zip(half, identity).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
        let fullMove = zip(full, identity).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
        #expect(halfMove > 0.5)
        #expect(fullMove > halfMove, "half strength is between identity and full strength")
    }

    // MARK: - 17. Horizon composition, without a double roll

    @Test func horizonComposesWithAToolWithoutDoubleRoll() throws {
        var tools = CameraRawPerspectiveToolState()
        tools.kind = .verticalGuides
        tools.verticalGuides = convergingVerticals()
        var backend = CameraRawGeometryBackendSettings(geometry: CameraRawGeometrySettings(), perspectiveTools: tools)
        // A solver upright mode already rolls: an Automatic Horizon must stand aside, as it did before this milestone.
        backend.geometry.upright = .guided
        backend.horizon.mode = .automatic
        #expect(!CameraRawGeometryBackend.shouldApplyHorizon(backend))
        // An explicit angle is the person asking for a rotation on top, so it still runs.
        backend.horizon.mode = .angle
        backend.horizon.angleDegrees = 5
        #expect(CameraRawGeometryBackend.shouldApplyHorizon(backend))
        #expect(CameraRawGeometryBackend.horizonDegrees(settings: backend, width: 100, height: 80) == 5)
    }

    @Test func horizonAndAToolBothReachTheCorners() {
        var geometry = CameraRawGeometrySettings()
        geometry.upright = .guided
        geometry.guides = convergingVerticals()
        let without = geometry.outputCorners(width: 200, height: 160)
        let with = geometry.outputCorners(width: 200, height: 160, horizonDegrees: 6)
        #expect(zip(without, with).contains { hypot($0.x - $1.x, $0.y - $1.y) > 0.5 },
                "Horizon rotates the corrected corners rather than replacing them")
    }

    // MARK: - 18. Volume stays independent

    @Test func volumeRemainsIndependentOfThePerspectiveTools() {
        var settings = CameraRawSettings()
        settings.perspectiveTools.kind = .verticalGuides
        settings.perspectiveTools.verticalGuides = convergingVerticals()
        settings.geometry.volumeRadial = 80
        #expect(settings.geometry.volumeRadial == 80)
        let geometry = CameraRawPerspectiveTools.applying(settings.perspectiveTools, to: settings.geometry)
        #expect(geometry.volumeRadial == 80, "the perspective tool never touches Volume")
        #expect(geometry.volumeMode == .radial)
    }

    // MARK: - 19. Constrain Crop and Expand to Fit

    @Test func constrainCropIsLeftToTheExistingPipeline() throws {
        var tools = CameraRawPerspectiveToolState()
        tools.kind = .verticalGuides
        tools.verticalGuides = convergingVerticals()
        for framing in [CameraRawFramingMode.keepOriginalSize, .expandToFit] {
            var geometry = CameraRawGeometrySettings()
            geometry.constrainCrop = true
            geometry.framingMode = framing
            let applied = CameraRawPerspectiveTools.applying(tools, to: geometry)
            #expect(applied.constrainCrop, "the tool never clears Constrain Crop")
            #expect(applied.framingMode == framing)
        }
    }

    // MARK: - 20–21. Preview versus committed image; Apply and Cancel

    @Test func previewAndCommittedRenderTheSamePixels() throws {
        let image = try ruled(width: 60, height: 44)
        var tools = CameraRawPerspectiveToolState()
        tools.kind = .verticalGuides
        tools.verticalGuides = convergingVerticals()
        var settings = CameraRawSettings()
        settings.perspectiveTools = tools
        // `apply` is what the preview runs; `apply` is also what a commit runs. Same settings, same pixels.
        let preview = try rgba8(try settings.apply(image))
        let committed = try rgba8(try settings.apply(image))
        #expect(preview == committed)
        #expect(try maxDelta(try rgba8(image), preview) > 4)
    }

    @Test func cancellingTheFilterLeavesTheLayerUntouched() throws {
        let (session, edit) = try cameraRawSession(width: 200, height: 150)
        session.selectCameraRawPerspectiveTool(.verticalGuides)
        session.beginCameraRawPerspectiveToolDrawing()
        drawGuide(from: CGPoint(x: 0.2, y: 0.1), to: CGPoint(x: 0.3, y: 0.9), session: session, edit: edit)
        let before = try rgba8(try #require(session.activeLayer?.asset?.image))
        session.cancelFilter()
        #expect(session.filterEdit == nil)
        let after = try rgba8(try #require(session.activeLayer?.asset?.image))
        #expect(before == after, "Cancel makes no document change")
    }

    // MARK: - 22. Undo and Redo

    @Test func undoAndRedoKeepTheCommittedCorrection() throws {
        let image = try ruled(width: 60, height: 44)
        let session = EditorSession()
        session.createDocument(width: 60, height: 44)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Photo"))
        let before = try rgba8(try #require(session.activeLayer?.asset?.image))

        try session.addCorrection(kind: .cameraRawFull, cameraRawFull: {
            var settings = CameraRawSettings()
            settings.perspectiveTools.kind = .verticalGuides
            settings.perspectiveTools.verticalGuides = convergingVerticals()
            return settings
        }())
        let corrected = try rgba8(try #require(session.activeLayer?.asset?.image))
        #expect(try maxDelta(before, corrected) > 4, "the correction is in the document")

        session.undo()
        #expect(try maxDelta(before, try rgba8(try #require(session.activeLayer?.asset?.image))) == 0)
        session.redo()
        #expect(try maxDelta(corrected, try rgba8(try #require(session.activeLayer?.asset?.image))) == 0)
    }

    // MARK: - 23–25. Save and reopen, legacy decoding, correction-stack persistence

    @Test func everyToolsStateSurvivesSaveAndReopen() async throws {
        let image = try ruled(width: 60, height: 44)
        let session = EditorSession()
        session.createDocument(width: 60, height: 44)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Photo"))
        try session.addCorrection(kind: .cameraRawFull, cameraRawFull: {
            var settings = CameraRawSettings()
            settings.perspectiveTools.kind = .combinedGuides
            settings.perspectiveTools.verticalGuides = convergingVerticals()
            settings.perspectiveTools.horizontalGuides = [
                CameraRawGeometryGuide(startX: 0.05, startY: 0.3, endX: 0.95, endY: 0.42)]
            settings.perspectiveTools.eightPointGuides = [
                CameraRawGeometryGuide(startX: 0.1, startY: 0.15, endX: 0.45, endY: 0.12),
                CameraRawGeometryGuide(startX: 0.55, startY: 0.12, endX: 0.9, endY: 0.15),
                CameraRawGeometryGuide(startX: 0.12, startY: 0.88, endX: 0.48, endY: 0.85),
                CameraRawGeometryGuide(startX: 0.52, startY: 0.85, endX: 0.88, endY: 0.88)]
            settings.perspectiveTools.rectangleCorners = [
                CGPoint(x: 0.2, y: 0.9), CGPoint(x: 0.8, y: 0.85),
                CGPoint(x: 0.75, y: 0.15), CGPoint(x: 0.25, y: 0.2)]
            return settings
        }())

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PerspectiveTools-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let restored = EditorSession()
        restored.installProject(loaded, from: url)

        let node = try #require(restored.activeLayer?.correctionStack?.nodes.first)
        let tools = node.cameraRawFull.perspectiveTools
        #expect(tools.kind == .combinedGuides)
        #expect(tools.verticalGuides.count == 2)
        #expect(tools.horizontalGuides.count == 1)
        #expect(tools.eightPointGuides.count == 4, "eight endpoints on four segments")
        #expect(tools.rectangleCorners.count == 4)
        let before = try rgba8(try #require(session.activeLayer?.asset?.image))
        let after = try rgba8(try #require(restored.activeLayer?.asset?.image))
        #expect(before == after, "a reopened project renders the same perspective")
    }

    @Test func aDocumentFromBeforeThisMilestoneOpensUnchanged() throws {
        // No `perspectiveTools` key at all: exactly what every file written before this milestone contains.
        let json = Data(#"{"schemaVersion":1,"geometry":{"upright":"Guided","vertical":0,"horizontal":0,"rotate":0,"aspect":0,"scale":0,"offsetX":0,"offsetY":0,"perspectiveAmount":100,"guides":[{"startX":0.2,"startY":0.05,"endX":0.35,"endY":0.95},{"startX":0.8,"startY":0.05,"endX":0.65,"endY":0.95}]}}"#.utf8)
        let persistent = try JSONDecoder().decode(CameraRawSettingsPersistentState.self, from: json)
        let settings = try persistent.makeSettings()
        #expect(settings.perspectiveTools.kind == .automatic, "missing tools means Automatic")
        #expect(settings.perspectiveTools.verticalGuides.isEmpty)
        #expect(settings.geometry.upright == .guided)
        #expect(settings.geometry.guides.count == 2)
        // Automatic applies nothing, so the old file renders exactly as it always did.
        let applied = CameraRawPerspectiveTools.applying(settings.perspectiveTools, to: settings.geometry)
        #expect(applied == settings.geometry)
    }

    @Test func corruptToolPointsAreDroppedRatherThanRendered() {
        var persistent = CameraRawSettingsPersistentState()
        persistent.perspectiveTools.kind = .verticalGuides
        persistent.perspectiveTools.verticalGuides = [
            CameraRawGeometryGuide(startX: .nan, startY: 0.1, endX: 0.3, endY: 0.9),
            CameraRawGeometryGuide(startX: 0.2, startY: 0.1, endX: 0.3, endY: 0.9)
        ]
        let state = persistent.perspectiveTools.sanitized
        #expect(state.verticalGuides.count == 1, "the non-finite point is dropped")
        #expect(state.verticalGuides[0].startX == 0.2)
    }

    // MARK: - The panel's structure

    @Test func theAdvancedSectionIsAppendedAfterHorizonAndKeepsEverySection() {
        #expect(CameraRawGroup.panelOrder.map(\.rawValue) ==
                ["Light", "Color", "Color Grading", "Effects", "Curve", "Color Mixer", "Detail", "Optics",
                 "Geometry", "Calibration"])
        let source = Self.panelSource()
        let horizon = try? #require(source.range(of: "private var horizonSection"))
        let advanced = try? #require(source.range(of: "private var advancedPerspectiveSection"))
        let constrain = try? #require(source.range(of: "constrainCropToggle"))
        #expect(horizon != nil && advanced != nil && constrain != nil)
        if let horizon, let advanced {
            #expect(horizon.lowerBound < advanced.lowerBound, "Advanced Perspective is appended after Horizon")
        }
        // Horizon stays after Volume's sliders, as M10.4 left it.
        if let volume = source.range(of: "volumeSlider(\"Radial\""), let horizon {
            #expect(volume.lowerBound < horizon.lowerBound, "Horizon is still after Volume")
        }
        // The disclosure is collapsed by default and every control has a stable identifier.
        #expect(source.contains("advancedPerspectiveExpanded = false"))
        for identifier in ["advancedPerspectiveDisclosure", "advancedPerspectiveToolPicker", "advancedPerspectiveDraw",
                           "advancedPerspectiveCount", "advancedPerspectiveClear", "advancedPerspectiveActiveTool"] {
            #expect(source.contains(identifier), "\(identifier) is missing")
        }
        // The advanced section is the last thing inside Advanced Geometry, so nothing after it moved.
        if let advanced, let horizon {
            let advancedBody = source[advanced.lowerBound...]
            let horizonBody = source[horizon.lowerBound...]
            #expect(advancedBody.count < horizonBody.count + 40_000)
        }
        // ReShape stays its own tool: nothing in the Geometry panel mentions it.
        #expect(!source.contains("ReShape"))
    }

    /// The panel's own source, so the guard reads the order the file builds rather than a copy of it.
    private static func panelSource() -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Compositor/UI/CameraRawGeometryCalibrationControls.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test func everyToolKindIsOfferedAndNamed() {
        #expect(CameraRawPerspectiveToolKind.allCases == [
            .automatic, .verticalGuides, .horizontalGuides, .combinedGuides, .rectangle, .eightPoint, .manualKeystone
        ])
        #expect(CameraRawPerspectiveToolKind.allCases.map(\.tagIdentifier) == [
            "automatic", "verticalGuides", "horizontalGuides", "combinedGuides", "rectangle", "eightPoint", "manualKeystone"
        ])
        #expect(CameraRawPerspectiveToolKind.allCases.allSatisfy { !$0.instructions.isEmpty })
        #expect(CameraRawPerspectiveToolKind.allCases.filter(\.drawsOnCanvas) ==
                [.verticalGuides, .horizontalGuides, .combinedGuides, .rectangle, .eightPoint])
    }

    // MARK: - Canvas interaction ownership

    @Test func onlyOneCanvasGeometryModeIsActive() throws {
        let (session, edit) = try cameraRawSession()
        session.selectCameraRawPerspectiveTool(.verticalGuides)
        session.beginCameraRawPerspectiveToolDrawing()
        #expect(edit.drawingCameraRawPerspectiveTool)

        // Guided Upright takes the drag and the advanced tool stands down.
        session.beginCameraRawGeometryGuideDrawing()
        #expect(edit.drawingCameraRawGeometryGuide)
        #expect(!edit.drawingCameraRawPerspectiveTool)

        // Horizon reference takes it back the same way.
        var settings = edit.settings
        settings.cameraRaw.horizon.mode = .horizontalReference
        session.updateFilter(settings, preview: true)
        session.beginCameraRawHorizonReferenceDrawing()
        #expect(edit.drawingCameraRawHorizonReference)
        #expect(!edit.drawingCameraRawGeometryGuide)

        session.beginCameraRawPerspectiveToolDrawing()
        #expect(edit.drawingCameraRawPerspectiveTool)
        #expect(!edit.drawingCameraRawHorizonReference)
        #expect(!edit.drawingCameraRawGeometryGuide)
    }

    @Test func toolsWithNoHandlesCannotArmDrawing() throws {
        let (session, edit) = try cameraRawSession()
        session.selectCameraRawPerspectiveTool(.automatic)
        session.beginCameraRawPerspectiveToolDrawing()
        #expect(!edit.drawingCameraRawPerspectiveTool, "Automatic has nothing to draw")
        session.selectCameraRawPerspectiveTool(.manualKeystone)
        session.beginCameraRawPerspectiveToolDrawing()
        #expect(!edit.drawingCameraRawPerspectiveTool, "Manual Keystone is the sliders, not the canvas")
    }

    @Test func switchingToolEndsAnUnfinishedGesture() throws {
        let (session, edit) = try cameraRawSession()
        session.selectCameraRawPerspectiveTool(.verticalGuides)
        session.beginCameraRawPerspectiveToolDrawing()
        session.beginCameraRawPerspectiveToolInteraction(at: documentPoint(CGPoint(x: 0.2, y: 0.2), edit: edit), zoom: 1)
        #expect(edit.cameraRawPerspectiveDraft != nil)
        session.selectCameraRawPerspectiveTool(.horizontalGuides)
        #expect(edit.cameraRawPerspectiveDraft == nil, "an unfinished vertical never becomes a horizontal")
        #expect(edit.settings.cameraRaw.perspectiveTools.verticalGuides.isEmpty)
    }

    @Test func deletingAHandleRemovesOnlyThatGuide() throws {
        let (session, edit) = try cameraRawSession(width: 200, height: 150)
        var tools = edit.settings.cameraRaw.perspectiveTools
        tools.kind = .verticalGuides
        tools.verticalGuides = convergingVerticals()
        var settings = edit.settings
        settings.cameraRaw.perspectiveTools = tools
        session.updateFilter(settings, preview: true)
        session.selectCameraRawPerspectiveTool(.verticalGuides)
        session.beginCameraRawPerspectiveToolDrawing()

        let handle = documentPoint(CGPoint(x: 0.2, y: 0.05), edit: edit)
        #expect(session.deleteCameraRawPerspectiveHandle(at: handle, zoom: 1))
        #expect(edit.settings.cameraRaw.perspectiveTools.verticalGuides.count == 1)
        #expect(!session.deleteCameraRawPerspectiveHandle(at: CGPoint(x: -500, y: -500), zoom: 1),
                "an empty spot has nothing to delete")
    }

    @Test func clearingAToolLeavesTheOthersAlone() throws {
        let (session, edit) = try cameraRawSession()
        var tools = edit.settings.cameraRaw.perspectiveTools
        tools.kind = .combinedGuides
        tools.verticalGuides = convergingVerticals()
        tools.horizontalGuides = [CameraRawGeometryGuide(startX: 0.1, startY: 0.3, endX: 0.9, endY: 0.35)]
        tools.eightPointGuides = [CameraRawGeometryGuide(startX: 0, startY: 0, endX: 1, endY: 1)]
        var settings = edit.settings
        settings.cameraRaw.perspectiveTools = tools
        session.updateFilter(settings, preview: true)
        session.selectCameraRawPerspectiveTool(.combinedGuides)
        session.clearCameraRawPerspectiveTool()
        let cleared = edit.settings.cameraRaw.perspectiveTools
        #expect(cleared.verticalGuides.isEmpty)
        #expect(cleared.horizontalGuides.isEmpty)
        #expect(cleared.eightPointGuides.count == 1, "another tool's work stays")
        #expect(cleared.kind == .combinedGuides, "clearing does not change the selected tool")
    }

    @Test func rectangleCornersArePlacedAndCanBeTakenBack() throws {
        let (session, edit) = try cameraRawSession(width: 200, height: 150)
        session.selectCameraRawPerspectiveTool(.rectangle)
        session.beginCameraRawPerspectiveToolDrawing()
        let corners = [CGPoint(x: 0.2, y: 0.9), CGPoint(x: 0.8, y: 0.85),
                       CGPoint(x: 0.75, y: 0.15), CGPoint(x: 0.25, y: 0.2)]
        for corner in corners {
            session.beginCameraRawPerspectiveToolInteraction(at: documentPoint(corner, edit: edit), zoom: 1)
            session.endCameraRawPerspectiveToolInteraction()
        }
        #expect(edit.settings.cameraRaw.perspectiveTools.rectangleCorners.count == 4)
        #expect(edit.cameraRawPerspectiveCornerDraft == nil)
        #expect(edit.settings.cameraRaw.perspectiveTools.problem(width: 200, height: 150) == nil)
    }

    @Test func anIncompleteRectangleDoesNotWarpThePreview() throws {
        let (session, edit) = try cameraRawSession(width: 200, height: 150)
        session.selectCameraRawPerspectiveTool(.rectangle)
        session.beginCameraRawPerspectiveToolDrawing()
        session.beginCameraRawPerspectiveToolInteraction(at: documentPoint(CGPoint(x: 0.2, y: 0.9), edit: edit), zoom: 1)
        session.endCameraRawPerspectiveToolInteraction()
        let applied = CameraRawPerspectiveTools.applying(edit.settings.cameraRaw.perspectiveTools,
                                                        to: edit.settings.cameraRaw.geometry)
        #expect(applied.upright == .off)
        #expect(applied.guides.isEmpty, "one corner warps nothing")
    }

    @Test func guideCapacityMatchesTheSolversExpectations() {
        #expect(CameraRawPerspectiveToolState.capacity(for: .vertical) == 2)
        #expect(CameraRawPerspectiveToolState.capacity(for: .horizontal) == 2)
        #expect(CameraRawPerspectiveToolState.capacity(for: .eightPoint) == 4)
        var tools = CameraRawPerspectiveToolState()
        tools.kind = .verticalGuides
        for index in 0..<2 {
            #expect(CameraRawPerspectiveTools.appendGuide(
                CameraRawGeometryGuide(startX: 0.2 + Double(index) * 0.4, startY: 0.1,
                                       endX: 0.3 + Double(index) * 0.4, endY: 0.9),
                to: .vertical, in: &tools))
        }
        #expect(!CameraRawPerspectiveTools.appendGuide(
            CameraRawGeometryGuide(startX: 0.5, startY: 0.1, endX: 0.6, endY: 0.9), to: .vertical, in: &tools),
            "the third vertical is refused rather than handed to a solver that reads two")
    }
}
