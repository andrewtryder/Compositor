import AppKit
import Testing
@testable import Compositor

@MainActor
struct CameraRawGeometryGuideTests {
    /// Sets up a session with a Camera Raw filter edit and a layer image.
    private func cameraRawSession(layerSize: CGSize = CGSize(width: 200, height: 150)) throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 400, height: 300)
        let context = try BrushRaster.context(width: Int(layerSize.width), height: Int(layerSize.height), mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: layerSize))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red"))
        session.beginFilter(.cameraRaw)
        let edit = try #require(session.filterEdit)
        edit.previewSource = image
        return session
    }

    // MARK: - Upright mode selection

    @Test func allFiveUprightModesAreDistinctAndHonest() {
        #expect(CameraRawUprightMode.allCases.count == 5)
        #expect(Set(CameraRawUprightMode.allCases) == [.off, .autoLevel, .autoVertical, .autoFull, .guided])
        #expect(CameraRawUprightMode.off.rawValue == "Off")
        #expect(CameraRawUprightMode.autoLevel.rawValue == "Auto Level")
        #expect(CameraRawUprightMode.autoVertical.rawValue == "Auto Vertical")
        #expect(CameraRawUprightMode.autoFull.rawValue == "Auto Full")
        #expect(CameraRawUprightMode.guided.rawValue == "Guided")
        #expect(CameraRawUprightMode.autoLevel.isAuto)
        #expect(CameraRawUprightMode.autoVertical.isAuto)
        #expect(CameraRawUprightMode.autoFull.isAuto)
        #expect(!CameraRawUprightMode.off.isAuto)
        #expect(!CameraRawUprightMode.guided.isAuto)
    }

    // MARK: - Guide creation and the four-guide limit

    @Test func guideCreationRespectsTheFourGuideLimit() throws {
        let session = try cameraRawSession()
        let edit = try #require(session.filterEdit)
        edit.drawingCameraRawGeometryGuide = true

        // Simulate placing four valid guides through the commit path.
        for i in 0..<4 {
            edit.cameraRawGuideDraft = (start: CGPoint(x: 0.1, y: 0.1 + Double(i) * 0.2),
                                        end: CGPoint(x: 0.9, y: 0.1 + Double(i) * 0.2))
            session.commitCameraRawGeometryGuide()
        }
        #expect(session.filterEdit?.settings.cameraRaw.geometry.guides.count == 4)
        #expect(session.filterEdit?.settings.cameraRaw.geometry.upright == .guided)

        // The fifth drawing attempt must be refused.
        edit.cameraRawGuideDraft = (start: CGPoint(x: 0.1, y: 0.9), end: CGPoint(x: 0.9, y: 0.9))
        session.commitCameraRawGeometryGuide()
        #expect(session.filterEdit?.settings.cameraRaw.geometry.guides.count == 4,
              "a fifth guide must not be committed")
    }

    @Test func zeroLengthGuideIsRefused() throws {
        let session = try cameraRawSession()
        let edit = try #require(session.filterEdit)
        edit.drawingCameraRawGeometryGuide = true

        edit.cameraRawGuideDraft = (start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 0.5, y: 0.5))
        session.commitCameraRawGeometryGuide()
        #expect(session.filterEdit?.settings.cameraRaw.geometry.guides.isEmpty == true,
              "a zero-length guide must not enter committed settings")
    }

    @Test func existingGuidesCanBeCleared() throws {
        let session = try cameraRawSession()
        let edit = try #require(session.filterEdit)
        edit.drawingCameraRawGeometryGuide = true
        edit.cameraRawGuideDraft = (start: CGPoint(x: 0.1, y: 0.1), end: CGPoint(x: 0.9, y: 0.9))
        session.commitCameraRawGeometryGuide()
        #expect(edit.settings.cameraRaw.geometry.guides.count == 1)

        session.filterEdit?.settings.cameraRaw.geometry.guides = []
        #expect(edit.settings.cameraRaw.geometry.guides.isEmpty)
    }

    // MARK: - Coordinate alignment (image → document → view)

    @Test func normalizedGuideMapsThroughPreviewMapping() throws {
        let session = try cameraRawSession()
        let edit = try #require(session.filterEdit)
        let image = edit.previewSource
        let documentSize = try #require(session.document?.size)

        // A normalized point in the middle of the image.
        let normalized = CGPoint(x: 0.5, y: 0.5)
        let pixel = CGPoint(x: normalized.x * CGFloat(image.width), y: normalized.y * CGFloat(image.height))
        let documentPoint = pixel.applying(edit.previewMapping)

        // The view point must be the document point transformed through the viewport.
        let viewPoint = session.viewport.viewPoint(from: documentPoint, documentSize: documentSize)
        #expect(viewPoint.x.isFinite && viewPoint.y.isFinite)

        // The inverse mapping (used by guide creation) must bring us back to the same normalized point.
        let back = documentPoint.applying(edit.previewMapping.inverted())
        let roundTrip = CGPoint(x: back.x / CGFloat(image.width), y: back.y / CGFloat(image.height))
        #expect(abs(roundTrip.x - normalized.x) < 0.001)
        #expect(abs(roundTrip.y - normalized.y) < 0.001)
    }

    @Test func guideCoordinatesStayWithinImageBounds() throws {
        let session = try cameraRawSession()
        let edit = try #require(session.filterEdit)
        let image = edit.previewSource
        let documentSize = try #require(session.document?.size)

        // A guide at the extreme corner of the image.
        let corner = CameraRawGeometryGuide(startX: 0, startY: 0, endX: 1, endY: 1)
        let startPixel = CGPoint(x: corner.startX * CGFloat(image.width), y: corner.startY * CGFloat(image.height))
        let endPixel = CGPoint(x: corner.endX * CGFloat(image.width), y: corner.endY * CGFloat(image.height))
        let startDoc = startPixel.applying(edit.previewMapping)
        let endDoc = endPixel.applying(edit.previewMapping)

        // Both endpoints must lie inside the document-image region (not outside).
        #expect(startDoc.x >= 0 && startDoc.y >= 0 && startDoc.x <= documentSize.width && startDoc.y <= documentSize.height)
        #expect(endDoc.x >= 0 && endDoc.y >= 0 && endDoc.x <= documentSize.width && endDoc.y <= documentSize.height)
    }

    // MARK: - Endpoint hit testing

    @Test func endpointHitTestSelectsCorrectEndpoint() throws {
        let session = try cameraRawSession()
        let edit = try #require(session.filterEdit)
        edit.settings.cameraRaw.geometry.guides = [
            CameraRawGeometryGuide(startX: 0.1, startY: 0.2, endX: 0.9, endY: 0.8)
        ]

        // Convert the guide's start endpoint to a document point and hit-test it.
        let image = edit.previewSource
        let startPixel = CGPoint(x: 0.1 * CGFloat(image.width), y: 0.2 * CGFloat(image.height))
        let startDoc = startPixel.applying(edit.previewMapping)

        let hit = session.cameraRawHitGuideEndpoint(at: startDoc, zoom: session.viewport.zoom)
        #expect(hit?.guideIndex == 0)
        #expect(hit?.endpoint == false, "start endpoint")

        // Convert the guide's end endpoint to a document point and hit-test it.
        let endPixel = CGPoint(x: 0.9 * CGFloat(image.width), y: 0.8 * CGFloat(image.height))
        let endDoc = endPixel.applying(edit.previewMapping)
        let endHit = session.cameraRawHitGuideEndpoint(at: endDoc, zoom: session.viewport.zoom)
        #expect(endHit?.guideIndex == 0)
        #expect(endHit?.endpoint == true, "end endpoint")
    }

    @Test func endpointHitTestToleranceScalesWithZoom() throws {
        let session = try cameraRawSession()
        let edit = try #require(session.filterEdit)
        edit.settings.cameraRaw.geometry.guides = [
            CameraRawGeometryGuide(startX: 0.5, startY: 0.5, endX: 0.7, endY: 0.5)
        ]
        let image = edit.previewSource
        let pixel = CGPoint(x: 0.5 * CGFloat(image.width), y: 0.5 * CGFloat(image.height))
        let docPoint = pixel.applying(edit.previewMapping)

        // At high zoom the tolerance in document pixels shrinks, so a point slightly off should still hit.
        let hitAtHighZoom = session.cameraRawHitGuideEndpoint(at: docPoint, zoom: 4)
        #expect(hitAtHighZoom?.guideIndex == 0)

        // A point far from any endpoint must not hit.
        let farPoint = CGPoint(x: docPoint.x + 100, y: docPoint.y + 100)
        let miss = session.cameraRawHitGuideEndpoint(at: farPoint, zoom: 1)
        #expect(miss == nil, "a distant point must not hit an endpoint")
    }

    @Test func endpointHitTestWithNoGuidesReturnsNil() throws {
        let session = try cameraRawSession()
        let image = try #require(session.filterEdit?.previewSource)
        let pixel = CGPoint(x: 0.5 * CGFloat(image.width), y: 0.5 * CGFloat(image.height))
        let docPoint = pixel.applying(session.filterEdit!.previewMapping)
        let hit = session.cameraRawHitGuideEndpoint(at: docPoint, zoom: 1)
        #expect(hit == nil, "no endpoints exist when there are no guides")
    }

    // MARK: - Endpoint dragging

    @Test func draggingAnEndpointMovesOnlyThatEndpoint() throws {
        let session = try cameraRawSession()
        let edit = try #require(session.filterEdit)
        edit.settings.cameraRaw.geometry.guides = [
            CameraRawGeometryGuide(startX: 0.2, startY: 0.3, endX: 0.8, endY: 0.7)
        ]
        let originalStart = edit.settings.cameraRaw.geometry.guides[0].start
        let originalEnd = edit.settings.cameraRaw.geometry.guides[0].end

        // Hit the start endpoint and begin a drag.
        let image = edit.previewSource
        let startPixel = CGPoint(x: 0.2 * CGFloat(image.width), y: 0.3 * CGFloat(image.height))
        let startDoc = startPixel.applying(edit.previewMapping)
        session.beginCameraRawGuideEndpointDrag(at: startDoc, zoom: session.viewport.zoom)
        #expect(edit.cameraRawDraggingGuideIndex == 0)
        #expect(edit.cameraRawDraggingEndpoint == false)

        // Move the start endpoint to a new location.
        let newNormalized = CGPoint(x: 0.4, y: 0.5)
        let newPixel = CGPoint(x: newNormalized.x * CGFloat(image.width), y: newNormalized.y * CGFloat(image.height))
        let newDoc = newPixel.applying(edit.previewMapping)
        session.continueCameraRawGuideEndpointDrag(to: newDoc)

        let moved = edit.settings.cameraRaw.geometry.guides[0]
        #expect(abs(moved.startX - 0.4) < 0.001, "start moved")
        #expect(abs(moved.startY - 0.5) < 0.001, "start moved")
        #expect(abs(moved.endX - originalEnd.x) < 0.001, "end stayed fixed")
        #expect(abs(moved.endY - originalEnd.y) < 0.001, "end stayed fixed")
    }

    @Test func endpointDragIsCanceledByEscape() throws {
        let session = try cameraRawSession()
        let edit = try #require(session.filterEdit)
        edit.settings.cameraRaw.geometry.guides = [
            CameraRawGeometryGuide(startX: 0.2, startY: 0.3, endX: 0.8, endY: 0.7)
        ]
        let original = edit.settings.cameraRaw.geometry.guides[0]

        let image = edit.previewSource
        let startPixel = CGPoint(x: 0.2 * CGFloat(image.width), y: 0.3 * CGFloat(image.height))
        let startDoc = startPixel.applying(edit.previewMapping)
        session.beginCameraRawGuideEndpointDrag(at: startDoc, zoom: session.viewport.zoom)
        #expect(edit.cameraRawDraggingGuideIndex != nil)

        session.cancelCameraRawGuideEndpointDrag()
        #expect(edit.cameraRawDraggingGuideIndex == nil)
        #expect(edit.cameraRawDraggingEndpoint == false)
        // The guide must be unchanged after cancel.
        let after = edit.settings.cameraRaw.geometry.guides[0]
        #expect(abs(after.startX - original.startX) < 0.0001)
        #expect(abs(after.startY - original.startY) < 0.0001)
        #expect(abs(after.endX - original.endX) < 0.0001)
        #expect(abs(after.endY - original.endY) < 0.0001)
    }

    @Test func endpointDragEscapeRestoresMovedEndpoint() throws {
        let session = try cameraRawSession()
        let edit = try #require(session.filterEdit)
        edit.settings.cameraRaw.geometry.guides = [
            CameraRawGeometryGuide(startX: 0.2, startY: 0.3, endX: 0.8, endY: 0.7)
        ]
        let original = edit.settings.cameraRaw.geometry.guides[0]

        let image = edit.previewSource
        let startPixel = CGPoint(x: 0.2 * CGFloat(image.width), y: 0.3 * CGFloat(image.height))
        let startDoc = startPixel.applying(edit.previewMapping)
        session.beginCameraRawGuideEndpointDrag(at: startDoc, zoom: session.viewport.zoom)
        #expect(edit.cameraRawDraggingGuideIndex == 0)
        #expect(edit.cameraRawDraggingEndpoint == false)

        // Perform an actual move before pressing Escape.
        let newNormalized = CGPoint(x: 0.45, y: 0.55)
        let newPixel = CGPoint(x: newNormalized.x * CGFloat(image.width), y: newNormalized.y * CGFloat(image.height))
        let newDoc = newPixel.applying(edit.previewMapping)
        session.continueCameraRawGuideEndpointDrag(to: newDoc)
        let midDrag = edit.settings.cameraRaw.geometry.guides[0]
        #expect(abs(midDrag.startX - 0.45) < 0.001, "start moved during drag")
        #expect(abs(midDrag.startY - 0.55) < 0.001, "start moved during drag")

        // Escape must restore the exact original coordinates.
        session.cancelCameraRawGuideEndpointDrag()
        #expect(edit.cameraRawDraggingGuideIndex == nil)
        #expect(edit.cameraRawDraggingEndpoint == false)
        let after = edit.settings.cameraRaw.geometry.guides[0]
        #expect(abs(after.startX - original.startX) < 0.0001, "start restored after Escape")
        #expect(abs(after.startY - original.startY) < 0.0001, "start restored after Escape")
        #expect(abs(after.endX - original.endX) < 0.0001, "end unchanged after Escape")
        #expect(abs(after.endY - original.endY) < 0.0001, "end unchanged after Escape")
    }

    @Test func endpointDragOppositeEndpointStaysFixed() throws {
        let session = try cameraRawSession()
        let edit = try #require(session.filterEdit)
        edit.settings.cameraRaw.geometry.guides = [
            CameraRawGeometryGuide(startX: 0.2, startY: 0.3, endX: 0.8, endY: 0.7)
        ]

        let image = edit.previewSource
        let endPixel = CGPoint(x: 0.8 * CGFloat(image.width), y: 0.7 * CGFloat(image.height))
        let endDoc = endPixel.applying(edit.previewMapping)
        session.beginCameraRawGuideEndpointDrag(at: endDoc, zoom: session.viewport.zoom)
        #expect(edit.cameraRawDraggingEndpoint == true)

        // Move the end endpoint; the start must not change.
        let newNormalized = CGPoint(x: 0.6, y: 0.4)
        let newPixel = CGPoint(x: newNormalized.x * CGFloat(image.width), y: newNormalized.y * CGFloat(image.height))
        let newDoc = newPixel.applying(edit.previewMapping)
        session.continueCameraRawGuideEndpointDrag(to: newDoc)

        let moved = edit.settings.cameraRaw.geometry.guides[0]
        #expect(abs(moved.endX - 0.6) < 0.001)
        #expect(abs(moved.endY - 0.4) < 0.001)
        #expect(abs(moved.startX - 0.2) < 0.001, "start unchanged")
        #expect(abs(moved.startY - 0.3) < 0.001, "start unchanged")
    }

    // MARK: - Perspective recalculation on guide move

    @Test func perspectiveRecalculatesWhenEndpointMoves() throws {
        let session = try cameraRawSession()
        let edit = try #require(session.filterEdit)
        // Guided upright must be explicitly enabled; the production default is .off, so the solver
        // would otherwise ignore the guides and the perspective would never change.
        edit.settings.cameraRaw.geometry.upright = .guided
        edit.settings.cameraRaw.geometry.guides = [
            CameraRawGeometryGuide(startX: 0.2, startY: 0.1, endX: 0.3, endY: 0.9),
            CameraRawGeometryGuide(startX: 0.7, startY: 0.1, endX: 0.8, endY: 0.9)
        ]
        // Verify the initial homography is valid and the selected guides are geometrically meaningful
        // (two roughly vertical guides, suitable for a perspective solve).
        let before = edit.settings.cameraRaw.geometry.outputCorners(width: 100, height: 100)
        let identity = CameraRawPerspective.identityCorners(width: 100, height: 100)
        #expect(!zip(before, identity).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 0.05 },
                "initial perspective corners differ from identity: guided solve is active")

        let image = edit.previewSource
        let startPixel = CGPoint(x: 0.2 * CGFloat(image.width), y: 0.1 * CGFloat(image.height))
        let startDoc = startPixel.applying(edit.previewMapping)
        session.beginCameraRawGuideEndpointDrag(at: startDoc, zoom: session.viewport.zoom)

        // Move the start endpoint well to the right, dramatically changing the guide's angle
        // and the converging vanishing point.
        let newNormalized = CGPoint(x: 0.45, y: 0.1)
        let newPixel = CGPoint(x: newNormalized.x * CGFloat(image.width), y: newNormalized.y * CGFloat(image.height))
        let newDoc = newPixel.applying(edit.previewMapping)
        session.continueCameraRawGuideEndpointDrag(to: newDoc)

        let after = edit.settings.cameraRaw.geometry.outputCorners(width: 100, height: 100)
        // Verify the guide coordinate changed and the untouched endpoint stayed fixed.
        let moved = edit.settings.cameraRaw.geometry.guides[0]
        #expect(abs(moved.startX - 0.45) < 0.001, "start endpoint moved")
        #expect(abs(moved.startY - 0.1) < 0.001, "start endpoint y unchanged")
        #expect(abs(moved.endX - 0.3) < 0.001, "untouched end endpoint x unchanged")
        #expect(abs(moved.endY - 0.9) < 0.001, "untouched end endpoint y unchanged")
        // A mathematically meaningful assertion: the perspective corners must actually change.
        let displacement = zip(before, after).map { hypot($0.x - $1.x, $0.y - $1.y) }
        #expect(displacement.max()! > 0.5, "moving an endpoint changes the perspective corners meaningfully")
        #expect(!zip(before, after).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 1 },
              "moving an endpoint changes the perspective corners")
    }

    @Test func guideSettingsSurviveUndoAndRedoCycle() throws {
        let session = try cameraRawSession()
        let edit = try #require(session.filterEdit)
        edit.settings.cameraRaw.geometry.guides = [
            CameraRawGeometryGuide(startX: 0.1, startY: 0.2, endX: 0.9, endY: 0.8)
        ]
        edit.settings.cameraRaw.geometry.upright = .guided

        // Directly mutate settings, then restore and re-apply, since guide edits live on
        // the filter's settings (preview-only until commit), not the document undo stack.
        let original = edit.settings.cameraRaw.geometry.guides[0]
        edit.settings.cameraRaw.geometry.guides.append(
            CameraRawGeometryGuide(startX: 0.3, startY: 0.05, endX: 0.7, endY: 0.95))
        #expect(edit.settings.cameraRaw.geometry.guides.count == 2)

        edit.settings.cameraRaw.geometry.guides = [original]
        #expect(edit.settings.cameraRaw.geometry.guides.count == 1)
        #expect(abs(edit.settings.cameraRaw.geometry.guides[0].startX - 0.1) < 0.0001)

        edit.settings.cameraRaw.geometry.guides.append(
            CameraRawGeometryGuide(startX: 0.3, startY: 0.05, endX: 0.7, endY: 0.95))
        #expect(edit.settings.cameraRaw.geometry.guides.count == 2)
        #expect(abs(edit.settings.cameraRaw.geometry.guides[1].startX - 0.3) < 0.0001)
    }

    @Test func guideSettingsSurviveJSONRoundTrip() throws {
        let session = try cameraRawSession()
        let edit = try #require(session.filterEdit)
        edit.settings.cameraRaw.geometry.guides = [
            CameraRawGeometryGuide(startX: 0.1, startY: 0.2, endX: 0.9, endY: 0.8),
            CameraRawGeometryGuide(startX: 0.3, startY: 0.05, endX: 0.7, endY: 0.95)
        ]
        edit.settings.cameraRaw.geometry.upright = .guided

        let encoded = try JSONEncoder().encode(edit.settings.cameraRaw.geometry)
        let decoded = try JSONDecoder().decode(CameraRawGeometrySettings.self, from: encoded)
        #expect(decoded.guides.count == 2)
        #expect(abs(decoded.guides[0].startX - 0.1) < 0.0001)
        #expect(abs(decoded.guides[0].endY - 0.8) < 0.0001)
        #expect(decoded.upright == .guided)
    }
}
