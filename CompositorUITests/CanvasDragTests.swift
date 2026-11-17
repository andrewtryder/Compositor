import AppKit
import XCTest

/// The canvas-drag gate the other harnesses cannot reach.
///
/// XCUITest's `press(forDuration:thenDragTo:)` targets window coordinates through XCAccessibility and
/// does not reach this app's layer-backed canvas (M10.5 §5.3: the panel's own counter stayed at zero
/// after every attempt). `CGEvent` posting from the runner was tried the same milestone and appeared
/// dropped — this suite re-tries it, and this time reads the panel back after the drag, so a silently
/// dropped drag **fails the test** instead of passing vacuously. M10.5's attempt could not tell
/// delivery from silence; this one can.
///
/// The launch mirrors `ScreenshotTests`: a fixed window frame (a restored frame from another display
/// breaks XCUITest's coordinate math) and the picture opened through `NSWorkspace` on the runner's own
/// Debug bundle, because AppleScript by name targets an installed Compositor instead.
///
/// Kept out of `ScreenshotTests` so a failure here cannot cost the captures.
final class CanvasDragTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testGuidedUprightReceivesACanvasDrag() throws {
        let app = try launchAndOpen()
        defer { app.terminate() }
        try openCameraRawGeometry(app)
        try armGuidedDrawing(app)
        try postDragOnCanvas(app)
        try assertGuidesArrived(app)
    }

    @MainActor
    func testAdvancedPerspectiveVerticalGuideReceivesACanvasDrag() throws {
        let app = try launchAndOpen()
        defer { app.terminate() }
        try openCameraRawGeometry(app)
        try armAdvancedPerspective(app)
        try postDragOnCanvas(app)
        try assertAdvancedPerspectiveCount(app)
    }

    // MARK: - Setup pieces

    /// Launches the app under test the way `ScreenshotTests` does, then opens a made-up picture.
    @MainActor
    private func launchAndOpen() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-SUEnableAutomaticChecks", "NO"]
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(1180, screen.width - 40), height = min(780, screen.height - 40)
        let x = screen.midX - width / 2, y = screen.midY - height / 2
        let frame = "\(Int(x)) \(Int(y)) \(Int(width)) \(Int(height)) \(Int(screen.minX)) \(Int(screen.minY)) \(Int(screen.width)) \(Int(screen.height))"
        app.launchArguments += ["-NSWindow Frame editor", frame]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "the editor window")

        let file = try makePicture()
        // This bundle is …/Products/Debug/CompositorUITests-Runner.app/Contents/PlugIns/CompositorUITests.xctest.
        var products = Bundle(for: Self.self).bundleURL
        for _ in 0..<4 { products.deleteLastPathComponent() }
        let compositor = products.appendingPathComponent("Compositor.app")
        let opened = expectation(description: "opened")
        NSWorkspace.shared.open([file], withApplicationAt: compositor, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        wait(for: [opened], timeout: 10)
        let canvas = app.descendants(matching: .any).matching(identifier: "editorCanvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 15), "the canvas exists after the document opens")
        return app
    }

    /// Posts a drag through the window server, from screen point to screen point, in small steps.
    /// The runner's accessibility grant is what lets these through; without it they are dropped and
    /// the read-back assertions report that as a failure rather than a pass.
    private func postDrag(from: CGPoint, to: CGPoint, steps: Int = 14) {
        func post(_ type: CGEventType, at point: CGPoint) {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
            event.post(tap: .cghidEventTap)
            usleep(40_000)
        }
        post(.mouseMoved, at: from)
        post(.leftMouseDown, at: from)
        for step in 1...max(steps, 1) {
            let t = CGFloat(step) / CGFloat(max(steps, 1))
            post(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        }
        post(.leftMouseUp, at: to)
        usleep(300_000)
    }

    /// A synthetic landscape, for something to edit.
    private func makePicture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CanvasDrag-\(UUID().uuidString).png")
        let width = 1600, height = 1000
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.85, green: 0.75, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (offset, shade) in [(CGFloat(0.0), CGFloat(0.3)), (CGFloat(0.3), CGFloat(0.45)), (CGFloat(0.55), CGFloat(0.6))] {
            context.setFillColor(CGColor(srgbRed: shade, green: shade * 0.8, blue: shade * 0.6, alpha: 1))
            let base = Int(CGFloat(height) * (1 - offset)) - 120
            context.fill(CGRect(x: 0, y: base, width: width, height: height - base))
        }
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "the picture was written")
        return url
    }

    /// The canvas's global screen rect. On macOS XCUITest element frames are already in global screen
    /// coordinates — adding the window origin again would aim the drag at the wrong window entirely.
    @MainActor
    private func canvasScreenRect(_ app: XCUIApplication) throws -> CGRect {
        let canvas = app.descendants(matching: .any).matching(identifier: "editorCanvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10), "the canvas element exists")
        return canvas.frame
    }

    /// Opens Camera Raw, opens the Advanced Geometry subsection, then walks its list to the end in
    /// small steps — the only walk that publishes the lazily inserted rows. The order is the one
    /// `CameraRawSectionOrderTests` proves: disclosure click before any scroll, walk after.
    @MainActor
    private func openCameraRawGeometry(_ app: XCUIApplication) throws {
        app.menuBars.menuBarItems["Filter"].click()
        app.menuItems["Camera Raw Filter…"].click()
        let geometry = app.buttons["Geometry"].firstMatch
        XCTAssertTrue(geometry.waitForExistence(timeout: 10), "the Geometry section header exists")
        // The section's first control is the marker: present means the section is already open, and
        // clicking the header would close it.
        let opened = app.staticTexts["Upright"].firstMatch.waitForExistence(timeout: 3)
        if !opened { geometry.click() }
        Thread.sleep(forTimeInterval: 0.5)
        let advanced = app.descendants(matching: .any).matching(identifier: "geometryAdvanced").firstMatch
        XCTAssertTrue(advanced.waitForExistence(timeout: 5), "the Advanced Geometry disclosure exists")
        advanced.click()
        Thread.sleep(forTimeInterval: 0.5)
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<90 { scrollView.scroll(byDeltaX: 0, deltaY: -60) }
        Thread.sleep(forTimeInterval: 1)
        // Horizon is Advanced Geometry's first appended subsection: its appearance after the walk is
        // the proof the click expanded the disclosure. It sits below the fold, so it cannot publish
        // before the walk — an earlier check here would misread "below the fold" as "not expanded",
        // and a blind retry would collapse what the first click opened.
        let horizon = app.descendants(matching: .any).matching(identifier: "horizonHeader").firstMatch
        if !horizon.waitForExistence(timeout: 3) {
            advanced.click()
            for _ in 0..<90 { scrollView.scroll(byDeltaX: 0, deltaY: -60) }
            Thread.sleep(forTimeInterval: 1)
            XCTAssertTrue(horizon.waitForExistence(timeout: 5), "Advanced Geometry expanded (retry walked too)")
        }
    }

    /// Switches Upright to Guided and arms the Draw Guides mode. The click right after the long walk
    /// is occasionally swallowed, so it retries: selecting the already-selected mode is harmless.
    @MainActor
    private func armGuidedDrawing(_ app: XCUIApplication) throws {
        let guided = app.descendants(matching: .any).matching(identifier: "geometryUpright_guided").firstMatch
        XCTAssertTrue(guided.waitForExistence(timeout: 5), "the Guided mode button is published")
        guided.click()
        let draw = app.descendants(matching: .any).matching(identifier: "geometryDrawGuides").firstMatch
        if !draw.waitForExistence(timeout: 2) {
            guided.click()
            XCTAssertTrue(draw.waitForExistence(timeout: 5), "Guided offers Draw Guides")
        }
        draw.click()
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Chooses Vertical Guides from the advanced tools and arms Draw on Image.
    @MainActor
    private func armAdvancedPerspective(_ app: XCUIApplication) throws {
        // The walk above scrolled the disclosure below the fold; bring it back.
        let disclosure = app.descendants(matching: .any).matching(identifier: "advancedPerspectiveDisclosure").firstMatch
        var steps = 0
        let scrollView = app.scrollViews.firstMatch
        while !disclosure.exists, steps < 90 {
            scrollView.scroll(byDeltaX: 0, deltaY: 60)
            steps += 1
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5), "the advanced tools disclosure is published")
        disclosure.click()
        let picker = app.descendants(matching: .any).matching(identifier: "advancedPerspectiveToolPicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "the tool picker is published")
        picker.click()
        let item = app.descendants(matching: .any).matching(identifier: "advancedPerspectiveTool_verticalGuides").firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        let draw = app.descendants(matching: .any).matching(identifier: "advancedPerspectiveDraw").firstMatch
        XCTAssertTrue(draw.waitForExistence(timeout: 5))
        draw.click()
        let count = app.descendants(matching: .any).matching(identifier: "advancedPerspectiveCount").firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5), "the counter appears once drawing is armed")
    }

    /// Drags on the canvas, between safe interior points, from global screen coordinates. The drag
    /// stays in the canvas's left half: the Camera Raw panel floats over the window's right side and
    /// would swallow the mouse-up, turning the gesture into a panel click.
    @MainActor
    private func postDragOnCanvas(_ app: XCUIApplication) throws {
        let rect = try canvasScreenRect(app)
        postDrag(from: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.minY + rect.height * 0.25),
                 to: CGPoint(x: rect.minX + rect.width * 0.5, y: rect.minY + rect.height * 0.25))
    }

    // MARK: - Proof of delivery

    @MainActor
    private func assertGuidesArrived(_ app: XCUIApplication) throws {
        // Walk back up: the Guided block is at the section's top, the walk left the panel at its end.
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<90 { scrollView.scroll(byDeltaX: 0, deltaY: 60) }
        Thread.sleep(forTimeInterval: 0.8)
        let count = app.descendants(matching: .any).matching(identifier: "geometryGuideCount").firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5), "the guide count is visible once a guide exists")
        let value = count.value as? String ?? count.label
        XCTAssertFalse(value.hasPrefix("0/4"), "the drag never reached the canvas: guide count still reads '\(value)'")
    }

    @MainActor
    private func assertAdvancedPerspectiveCount(_ app: XCUIApplication) throws {
        let count = app.descendants(matching: .any).matching(identifier: "advancedPerspectiveCount").firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5), "the advanced tools counter is still visible")
        let value = count.value as? String ?? count.label
        XCTAssertFalse(value.hasPrefix("0"), "the drag never reached the canvas: counter still reads '\(value)'")
    }
}
