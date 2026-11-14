import AppKit
import XCTest

/// Screenshots of the main screens, so how the app looks can be checked without launching it: CI keeps them with
/// each run. Nothing is compared. A step that can't find what it needs records a failure, and the rest still run.
final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = true }

    @MainActor
    func testMainScreens() throws {
        let app = XCUIApplication()
        // A fresh window at its default size, and no update check.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-SUEnableAutomaticChecks", "NO"]
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
        shoot("06 Camera Raw", settle: 2)

        // Milestone 10 evidence. The panel is its own dialog beside the document window, so each of these captures
        // it as an element; a screen grab would be mostly desktop. Light starts expanded, so it already shows the
        // added Auto row above the six original sliders, and Optics is opened here, with Lens Blur after its own
        // controls. Every preexisting section keeps its order and place.
        let panel = app.dialogs["filterPanel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "the Camera Raw panel")
        shoot("07 Camera Raw Light", panel, settle: 1)

        // Optics plus Lens Blur and Lens Profile is taller than the panel, so scroll the panel to its end. The scroll
        // is done unconditionally: reading a SwiftUI element's frame mid-scroll returns stale values, so a
        // frame-driven loop stops early. Lens Profile is Optics' last group, so the end of the scroll is where it sits,
        // with Lens Blur just above it: one capture shows both.
        openCameraRawSection("Optics", in: app)
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<90 {
            scrollView.scroll(byDeltaX: 0, deltaY: -60)
        }
        Thread.sleep(forTimeInterval: 1)
        let lensBlur = app.staticTexts["Lens Blur"].firstMatch
        XCTAssertTrue(lensBlur.exists, "Optics shows the added Lens Blur group")
        XCTAssertTrue(app.buttons["Move Focus Region"].firstMatch.exists, "Lens Blur's Move Focus Region button")
        shoot("08 Camera Raw Optics", panel, settle: 1)

        // Milestone 10.3: Lens Profile follows Lens Blur at the end of Optics, so the same scroll already shows it.
        let lensProfile = app.staticTexts["Lens Profile"].firstMatch
        XCTAssertTrue(lensProfile.exists, "Optics shows the added Lens Profile group")
        XCTAssertTrue(app.staticTexts["Provider"].firstMatch.exists, "the provider row is present")
        shoot("09 Camera Raw Lens Profile", panel, settle: 1)

        // Choosing Lensfun reveals the install status, the import control and the "no database yet" copy: the whole
        // of what M10.3 adds, captured with nothing installed so the evidence shows the state a new user meets.
        // A SwiftUI menu-style Picker does not surface as a pop-up button, so it is found by its identifier.
        let provider = app.descendants(matching: .any).matching(identifier: "lensProfileProvider").firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 3), "the Lens Profile provider picker is reachable")
        provider.click()
        let lensfun = app.menuItems["Lensfun"].firstMatch
        if lensfun.waitForExistence(timeout: 3) { lensfun.click() }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(app.staticTexts["Lens Profile"].firstMatch.exists, "Lens Profile survives choosing a provider")
        shoot("10 Camera Raw Lens Profile, Lensfun chosen", panel, settle: 1)

        // Milestone 10.4: Geometry is below Optics. Its own controls are unchanged, and the added Horizon subsection
        // sits at the end of Advanced Geometry. Scrolling to the panel's end puts both in one capture.
        openCameraRawSection("Geometry", in: app)
        let advanced = app.descendants(matching: .any).matching(identifier: "geometryAdvanced").firstMatch
        if advanced.waitForExistence(timeout: 3), advanced.exists { advanced.click() }
        for _ in 0..<90 {
            scrollView.scroll(byDeltaX: 0, deltaY: -60)
        }
        Thread.sleep(forTimeInterval: 1)
        let horizon = app.staticTexts["Horizon"].firstMatch
        XCTAssertTrue(horizon.exists, "Geometry shows the added Horizon subsection")
        XCTAssertTrue(app.staticTexts["Perspective Amount"].firstMatch.exists,
                      "Perspective Amount is still above it, unmoved")
        shoot("11 Camera Raw Geometry Horizon", panel, settle: 1)

        dismiss(app)

        app.typeKey("n", modifierFlags: .command)
        shoot("12 Second tab", window)
    }

    /// Opens a closed Camera Raw section by its header. A section that is already open is left as it is.
    private func openCameraRawSection(_ section: String, in app: XCUIApplication) {
        let header = app.buttons[section].firstMatch
        guard header.waitForExistence(timeout: 3) else { return }
        // Its own first control: present already means the section is open, and clicking would close it.
        let opener: [String: String] = ["Optics": "Distortion", "Light": "Exposure", "Geometry": "Upright"]
        if let marker = opener[section], app.staticTexts[marker].firstMatch.exists { return }
        header.click()
        Thread.sleep(forTimeInterval: 0.8)
    }

    /// Waits for animations to finish, then keeps a screenshot of the element, or of the whole screen (for menus and
    /// panels outside the window).
    private func shoot(_ name: String, _ element: XCUIElement? = nil, settle seconds: TimeInterval = 1) {
        Thread.sleep(forTimeInterval: seconds)
        let attachment = XCTAttachment(screenshot: element?.screenshot() ?? XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Cancels the sheet or panel showing, by its Cancel button where it has one.
    private func dismiss(_ app: XCUIApplication) {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.click() } else { app.typeKey(.escape, modifierFlags: []) }
        Thread.sleep(forTimeInterval: 0.5)
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
