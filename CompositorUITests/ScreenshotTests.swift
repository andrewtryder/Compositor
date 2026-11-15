import AppKit
import XCTest

/// Screenshots of the main screens, so how the app looks can be checked without launching it: CI keeps them with
/// each run. Nothing is compared. A step that can't find what it needs records a failure, and the rest still run.
final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = true }

    /// A document window that fits the display the screenshots are taken on, in the format AppKit's own window
    /// frame default uses: x y width height screenX screenY screenWidth screenHeight.
    private static let windowFrame = {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(1180, screen.width - 40), height = min(780, screen.height - 40)
        let x = screen.midX - width / 2, y = screen.midY - height / 2
        return "\(Int(x)) \(Int(y)) \(Int(width)) \(Int(height)) \(Int(screen.minX)) \(Int(screen.minY)) \(Int(screen.width)) \(Int(screen.height))"
    }()

    @MainActor
    func testMainScreens() throws {
        let app = XCUIApplication()
        // A fresh window at its default size, and no update check.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-SUEnableAutomaticChecks", "NO"]
        // The editor restores its saved window frame, which can legitimately be a very wide window from another
        // display and is then wider than the display this runs on: XCUITest cannot screenshot a window that large
        // ("Image creation failed"). The argument overrides the frame for this launch only and saves nothing.
        app.launchArguments += ["-NSWindow Frame editor", "\(Self.windowFrame)"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "the editor window")
        shoot("01 Start", window)

        try open(picture(), in: app)
        XCTAssertTrue(app.staticTexts["canvasDimensions"].waitForExistence(timeout: 10), "the opened picture")
        shoot("02 Editor", window)

        app.menuBars.menuBarItems["Filter"].click()
        shoot("03 Filter menu")
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("i", modifierFlags: [.command, .option])
        shoot("04 Image Size", window)
        dismiss(app)

        app.typeKey("u", modifierFlags: .command)
        shoot("05 Hue Saturation")
        dismiss(app)

        app.menuBars.menuBarItems["Filter"].click()
        app.menuItems["Camera Raw Filter…"].click()
        shoot("06 Camera Raw")

        // Milestone 10 evidence. The panel is its own dialog beside the document window, so each of these captures
        // it as an element; a screen grab would be mostly desktop. Light starts expanded, so it already shows the
        // added Auto row above the six original sliders, and Optics is opened here, with Lens Blur after its own
        // controls. Every preexisting section keeps its order and place.
        let panel = app.dialogs["filterPanel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "the Camera Raw panel")
        shoot("07 Camera Raw Light", panel)

        // Optics plus Lens Blur and Lens Profile is taller than the panel, so scroll the panel to its end. The scroll
        // is done unconditionally: reading a SwiftUI element's frame mid-scroll returns stale values, so a
        // frame-driven loop stops early. Lens Profile is Optics' last group, so the end of the scroll is where it sits,
        // with Lens Blur just above it: one capture shows both.
        openCameraRawSection("Optics", in: app)
        scrollPanelToEnd(app)
        let lensBlur = app.staticTexts["Lens Blur"].firstMatch
        XCTAssertTrue(lensBlur.exists, "Optics shows the added Lens Blur group")
        XCTAssertTrue(app.buttons["Move Focus Region"].firstMatch.exists, "Lens Blur's Move Focus Region button")
        shoot("08 Camera Raw Optics", panel)

        // Milestone 10.3: Lens Profile follows Lens Blur at the end of Optics, so the same scroll already shows it.
        let lensProfile = app.staticTexts["Lens Profile"].firstMatch
        XCTAssertTrue(lensProfile.exists, "Optics shows the added Lens Profile group")
        XCTAssertTrue(app.staticTexts["Provider"].firstMatch.exists, "the provider row is present")
        shoot("09 Camera Raw Lens Profile", panel)

        // Choosing Lensfun reveals the install status, the import control and the "no database yet" copy: the whole
        // of what M10.3 adds, captured with nothing installed so the evidence shows the state a new user meets.
        // A SwiftUI menu-style Picker does not surface as a pop-up button, so it is found by its identifier.
        let provider = app.descendants(matching: .any).matching(identifier: "lensProfileProvider").firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 3), "the Lens Profile provider picker is reachable")
        provider.click()
        let lensfun = app.menuItems["Lensfun"].firstMatch
        if lensfun.waitForExistence(timeout: 3) { lensfun.click() }
        XCTAssertTrue(app.staticTexts["Lens Profile"].firstMatch.exists, "Lens Profile survives choosing a provider")
        shoot("10 Camera Raw Lens Profile, Lensfun chosen", panel)

        // Milestone 10.4: Geometry is below Optics. Its own controls are unchanged, and the added Horizon subsection
        // sits at the end of Advanced Geometry. Scrolling to the panel's end puts both in one capture.
        openCameraRawSection("Geometry", in: app)
        let advanced = app.descendants(matching: .any).matching(identifier: "geometryAdvanced").firstMatch
        if advanced.waitForExistence(timeout: 3), advanced.exists { advanced.click() }
        scrollPanelToEnd(app)
        let horizon = app.staticTexts["Horizon"].firstMatch
        XCTAssertTrue(horizon.exists, "Geometry shows the added Horizon subsection")
        XCTAssertTrue(app.staticTexts["Perspective Amount"].firstMatch.exists,
                      "Perspective Amount is still above it, unmoved")
        shoot("11 Camera Raw Geometry Horizon", panel)

        // Milestone 10.5: Advanced Perspective Tools, appended after Horizon. The collapsed subsection is what an
        // existing user sees, so it is captured first, then opened to show the tool selector and its instructions.
        let advancedPerspective = app.descendants(matching: .any).matching(identifier: "advancedPerspectiveDisclosure").firstMatch
        XCTAssertTrue(advancedPerspective.waitForExistence(timeout: 5), "Advanced Perspective Tools is present")
        scrollIntoView(advancedPerspective, in: app, panel: panel)
        shoot("12 Advanced Perspective collapsed", panel)
        advancedPerspective.click()
        scrollIntoView(advancedPerspective, in: app, panel: panel)
        shoot("13 Advanced Perspective tools", panel)

        // The tool menu, opened, lists all seven kinds. Closed by choosing Automatic from it rather than by pressing
        // Escape: Escape dismisses the whole Camera Raw filter, and the rest of this run needs it open.
        let toolPicker = app.descendants(matching: .any).matching(identifier: "advancedPerspectiveToolPicker").firstMatch
        if toolPicker.waitForExistence(timeout: 3) {
            toolPicker.click()
            shoot("14 Advanced Perspective tool menu")
            let automatic = app.descendants(matching: .any).matching(identifier: "advancedPerspectiveTool_automatic").firstMatch
            if automatic.waitForExistence(timeout: 3) { automatic.click() }
        }

        // Vertical Guides: the tool chosen, drawing armed. This captures the panel state a person sees after
        // selecting the tool and pressing Draw on Image.
        //
        // The guides themselves are NOT in this capture, and the report says so: XCUITest's drag synthesis does not
        // reach the canvas here — the panel's own "N of 8 lines" counter stays at zero after a drag — so there is no
        // honest way to photograph a drawn guide from this harness. The correction each tool produces is proven by
        // `CameraRawPerspectiveEvidenceTests`, which renders real photographs through the same pipeline.
        selectPerspectiveTool("verticalGuides", app)
        let draw = app.descendants(matching: .any).matching(identifier: "advancedPerspectiveDraw").firstMatch
        if draw.waitForExistence(timeout: 3), draw.exists { draw.click() }
        XCTAssertTrue(draw.waitForExistence(timeout: 3), "selected Vertical Guides offers Draw on Image")
        scrollIntoView(advancedPerspective, in: app, panel: panel)
        shoot("15 Advanced Perspective vertical guides", panel)

        // Combined Guides, Rectangle and Eight Point: each shows its own instructions and its own wording for the
        // count, which is what tells them apart in use. The drawn geometry is evidenced by the rendered pictures.
        selectPerspectiveTool("combinedGuides", app)
        scrollIntoView(advancedPerspective, in: app, panel: panel)
        shoot("16 Advanced Perspective combined guides", panel)

        selectPerspectiveTool("rectangle", app)
        scrollIntoView(advancedPerspective, in: app, panel: panel)
        shoot("17 Advanced Perspective rectangle", panel)

        selectPerspectiveTool("eightPoint", app)
        scrollIntoView(advancedPerspective, in: app, panel: panel)
        shoot("18 Advanced Perspective eight point", panel)

        selectPerspectiveTool("manualKeystone", app)
        scrollIntoView(advancedPerspective, in: app, panel: panel)
        shoot("19 Advanced Perspective manual keystone", panel)

        dismiss(app)

        app.typeKey("n", modifierFlags: .command)
        shoot("20 Second tab", window)
    }

    /// Chooses one Advanced Perspective tool from the open subsection's menu, by its stable identifier suffix.
    private func selectPerspectiveTool(_ identifier: String, _ app: XCUIApplication) {
        let picker = app.descendants(matching: .any).matching(identifier: "advancedPerspectiveToolPicker").firstMatch
        guard picker.waitForExistence(timeout: 3), picker.exists else { return }
        picker.click()
        let item = app.descendants(matching: .any).matching(identifier: "advancedPerspectiveTool_\(identifier)").firstMatch
        if item.waitForExistence(timeout: 3) { item.click() } else { app.typeKey(.escape, modifierFlags: []) }
    }

    /// Opens a closed Camera Raw section by its header. A section that is already open is left as it is.
    /// The panel scrolls, so its end is reached first: once the list has been scrolled through, every header is
    /// published, including the ones that were below the fold.
    private func openCameraRawSection(_ section: String, in app: XCUIApplication) {
        scrollPanelToEnd(app)
        let header = app.buttons[section].firstMatch
        guard header.waitForExistence(timeout: 3) else { return }
        // Its own first control: present already means the section is open, and clicking would close it.
        let opener: [String: String] = ["Optics": "Distortion", "Light": "Exposure", "Geometry": "Upright"]
        if let marker = opener[section], app.staticTexts[marker].firstMatch.exists { return }
        header.click()
        scrollPanelToEnd(app)
    }

    /// Scrolls the panel until `element` is fully inside it, or gives up after a bounded number of nudges.
    /// Each nudge settles before the frame is read again: a SwiftUI element's frame read mid-scroll is stale, which
    /// is what made an earlier frame-driven loop stop early.
    ///
    /// Reads are kept to one snapshot per iteration. Every `.frame`, `.exists` and `.isHittable` is a round trip to
    /// the app (about 0.28 s each), so the panel's own frame is read once up front rather than once per nudge — that
    /// alone removed the bulk of this suite's runtime.
    private func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication, panel: XCUIElement) {
        let scrollView = app.scrollViews.firstMatch
        guard scrollView.exists else { return }
        let bounds = panel.frame
        for _ in 0..<12 {
            let frame = element.frame
            guard frame.height > 0 else { return }
            if frame.minY >= bounds.minY + 4, frame.maxY <= bounds.maxY - 4 { return }
            scrollView.scroll(byDeltaX: 0, deltaY: frame.maxY > bounds.maxY ? -200 : 200)
            Thread.sleep(forTimeInterval: 0.15)
        }
    }

    /// Scrolls the panel to its end in a handful of large steps. Used instead of ninety small ones: a scroll is a
    /// synthesized event plus a snapshot, so the count of steps, not their size, is what the time goes on.
    private func scrollPanelToEnd(_ app: XCUIApplication) {
        let scrollView = app.scrollViews.firstMatch
        guard scrollView.exists else { return }
        for _ in 0..<12 { scrollView.scroll(byDeltaX: 0, deltaY: -600) }
        Thread.sleep(forTimeInterval: 0.4)
    }


    /// Waits for animations to finish, then keeps a screenshot of the element, or of the whole screen (for menus and
    /// panels outside the window). A capture whose element has gone (a panel that a stray click dismissed) is
    /// recorded and skipped rather than aborting the rest of the run.
    ///
    /// The wait is short on purpose: XCUITest already waits for the app to idle after every interaction, so a second
    /// on top of that is spent sleeping rather than letting anything finish.
    private func shoot(_ name: String, _ element: XCUIElement? = nil, settle seconds: TimeInterval = 0.3) {
        if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
        if let element, !element.exists {
            XCTContext.runActivity(named: name) { activity in
                activity.add(XCTAttachment(string: "\(name): the element was gone when this capture was due."))
            }
            return
        }
        let attachment = XCTAttachment(screenshot: element?.screenshot() ?? XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Cancels the sheet or panel showing, by its Cancel button where it has one.
    private func dismiss(_ app: XCUIApplication) {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.click() } else { app.typeKey(.escape, modifierFlags: []) }
    }

    /// Opens a file in the app under test as the Finder would.
    private func open(_ file: URL, in app: XCUIApplication) throws {
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
    }

    /// A made-up landscape, for something to edit: a sunset sky, a sun and two rows of hills.
    private func picture() throws -> URL {
        let width = 2400, height = 1600
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let sky = try XCTUnwrap(CGGradient(colorsSpace: nil, colors: [
            CGColor(srgbRed: 0.98, green: 0.62, blue: 0.32, alpha: 1), CGColor(srgbRed: 0.42, green: 0.27, blue: 0.62, alpha: 1),
        ] as CFArray, locations: [0, 1]))
        context.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        context.setFillColor(CGColor(srgbRed: 1, green: 0.88, blue: 0.6, alpha: 1))
        context.fillEllipse(in: CGRect(x: 1500, y: 520, width: 360, height: 360))
        for (base, color) in [(560.0, CGColor(srgbRed: 0.24, green: 0.32, blue: 0.36, alpha: 1)),
                              (300.0, CGColor(srgbRed: 0.12, green: 0.18, blue: 0.2, alpha: 1))] {
            context.setFillColor(color)
            context.move(to: .zero)
            for x in stride(from: 0, through: width, by: 40) {
                context.addLine(to: CGPoint(x: Double(x), y: base + 120 * sin(Double(x) / 330 + base)))
            }
            context.addLine(to: CGPoint(x: width, y: 0))
            context.fillPath()
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Landscape-\(UUID().uuidString).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
