import AppKit
import XCTest

/// Guards the Camera Raw panel's structure, not its pixels: the ten sections are still there, still in their
/// order, and every preexisting control is still reachable. Milestone 10 only adds; this test is what says so.
final class CameraRawSectionOrderTests: XCTestCase {
    /// The panel's sections, in the order the requirements fix them.
    private static let sections = ["Light", "Color", "Color Grading", "Effects", "Curve", "Color Mixer",
                                   "Detail", "Optics", "Geometry", "Calibration"]

    @MainActor
    func testSectionsAndAddedControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-SUEnableAutomaticChecks", "NO"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "the editor window")
        try open(picture(), in: app)
        XCTAssertTrue(app.staticTexts["canvasDimensions"].waitForExistence(timeout: 10), "the opened picture")

        app.menuBars.menuBarItems["Filter"].click()
        app.menuItems["Camera Raw Filter…"].click()
        let light = app.staticTexts["Exposure"].firstMatch
        XCTAssertTrue(light.waitForExistence(timeout: 10), "the Camera Raw panel")

        // Every section header exists, and they run top to bottom in the required order.
        var tops: [(String, CGFloat)] = []
        for name in Self.sections {
            let header = app.buttons[name].firstMatch
            XCTAssertTrue(header.waitForExistence(timeout: 5), "section \(name) is present")
            tops.append((name, header.frame.minY))
        }
        for (earlier, later) in zip(tops, tops.dropFirst()) {
            XCTAssertLessThan(earlier.1, later.1, "\(earlier.0) stays above \(later.0)")
        }

        // Light is open as it always was, and its six rows are still there, in order, below the new Auto button.
        let auto = app.buttons["Auto Tone"].firstMatch
        XCTAssertTrue(auto.exists, "Light has the added Auto button")
        let lightTop = tops[0].1, lightBottom = tops[1].1
        let lightSliders = ["Exposure", "Contrast", "Highlights", "Shadows", "Whites", "Blacks"]
        var sliderTops: [(String, CGFloat)] = []
        for name in lightSliders {
            // The panel scrolls, so match only the copy inside Light's own band rather than any other section's.
            let rows = app.staticTexts.matching(identifier: name).allElementsBoundByIndex
                .filter { $0.frame.minY >= lightTop && $0.frame.maxY <= lightBottom }
            let row = try XCTUnwrap(rows.min { $0.frame.minY < $1.frame.minY }, "Light still has a \(name) row")
            sliderTops.append((name, row.frame.minY))
        }
        XCTAssertLessThan(auto.frame.minY, sliderTops[0].1, "Auto sits above Exposure")
        for (earlier, later) in zip(sliderTops, sliderTops.dropFirst()) {
            XCTAssertLessThan(earlier.1, later.1, "\(earlier.0) stays above \(later.0)")
        }

        // Optics still opens on the controls it always had, and the added Lens Blur group follows them.
        app.buttons["Optics"].firstMatch.click()
        let distortion = app.staticTexts["Distortion"].firstMatch
        XCTAssertTrue(distortion.waitForExistence(timeout: 5), "Optics keeps its manual Distortion")
        let flourishMarker = app.staticTexts["Lens Blur"].firstMatch
        XCTAssertTrue(flourishMarker.waitForExistence(timeout: 5), "Optics has the added Lens Blur group")
        XCTAssertLessThan(distortion.frame.minY, flourishMarker.frame.minY, "Lens Blur follows the existing Optics controls")
        XCTAssertTrue(app.buttons["Move Focus Region"].firstMatch.exists, "Lens Blur can move its focus region")
        XCTAssertTrue(app.staticTexts["Amount"].firstMatch.exists, "Lens Blur has its Amount slider")

        // Milestone 10.3's Lens Profile group follows Lens Blur, and its provider choice is a visible control rather
        // than a hidden default. The panel scrolls, so this only has to prove the group exists after Lens Blur.
        let profileMarker = app.staticTexts["Lens Profile"].firstMatch
        XCTAssertTrue(profileMarker.waitForExistence(timeout: 5), "Optics has the added Lens Profile group")
        XCTAssertLessThan(flourishMarker.frame.minY, profileMarker.frame.minY, "Lens Profile follows Lens Blur")
        XCTAssertTrue(app.staticTexts["Provider"].firstMatch.exists, "the provider is a visible, labeled choice")

        // The other sections are untouched by the additions.
        for name in ["Curve", "Color Mixer", "Detail", "Geometry", "Calibration", "Effects", "Color Grading"] {
            XCTAssertTrue(app.buttons[name].firstMatch.exists, "section \(name) is still reachable")
        }

        // Geometry keeps everything it had, and the M10.4 Horizon subsection is appended inside Advanced Geometry,
        // below Volume, where nothing preexisting had to move. The identifiers are the stable hook the accessibility
        // pass uses, so this also proves they resolve in a running app.
        openCameraRawSection("Geometry", in: app)
        let uprightStrip = app.descendants(matching: .any).matching(identifier: "geometryUprightStrip").firstMatch
        XCTAssertTrue(uprightStrip.waitForExistence(timeout: 5), "the five-mode Upright strip")
        for mode in ["off", "autoLevel", "autoVertical", "autoFull", "guided"] {
            let button = app.descendants(matching: .any).matching(identifier: "geometryUpright_\(mode)").firstMatch
            XCTAssertTrue(button.exists, "Upright \(mode) is reachable by identifier")
        }
        let manual = app.descendants(matching: .any).matching(identifier: "geometryManualTransformations").firstMatch
        XCTAssertTrue(manual.exists, "Manual Transformations disclosure")
        let constrain = app.descendants(matching: .any).matching(identifier: "geometryConstrainCrop").firstMatch
        XCTAssertTrue(constrain.exists, "Constrain Crop")
        let advanced = app.descendants(matching: .any).matching(identifier: "geometryAdvanced").firstMatch
        XCTAssertTrue(advanced.exists, "Advanced Geometry disclosure")

        // The added Horizon controls live inside Advanced Geometry.
        advanced.click()
        Thread.sleep(forTimeInterval: 0.8)
        // Advanced Geometry is taller than the panel: Volume, Projection, Framing, Perspective Amount and Horizon
        // are all below the fold, and SwiftUI does not publish off-screen rows to the accessibility tree. The panel
        // is scrolled to its end first — unconditionally, since a frame read mid-scroll is stale — so this asserts
        // what a person actually sees rather than what exists off screen.
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<90 { scrollView.scroll(byDeltaX: 0, deltaY: -60) }
        Thread.sleep(forTimeInterval: 1)
        let horizonHeader = app.descendants(matching: .any).matching(identifier: "horizonHeader").firstMatch
        XCTAssertTrue(horizonHeader.waitForExistence(timeout: 5), "Horizon is part of Advanced Geometry")
        let horizonMode = app.descendants(matching: .any).matching(identifier: "horizonModePicker").firstMatch
        XCTAssertTrue(horizonMode.exists, "Horizon has a mode selector")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "horizonAmount").firstMatch.exists,
                      "Horizon has an Amount control")
        // Perspective Amount stays where it was, above Horizon — asserted by the order of the two rows the scroll
        // reaches, rather than by a duplicate static text that could match either copy.
        let perspectiveAmount = app.staticTexts["Perspective Amount"].firstMatch
        XCTAssertTrue(perspectiveAmount.exists, "Perspective Amount is still in Advanced Geometry")
        XCTAssertLessThan(perspectiveAmount.frame.minY, horizonHeader.frame.minY,
                          "Perspective Amount keeps its place above Horizon")

        app.buttons["Cancel"].firstMatch.click()
    }

    /// Milestone 10.5: the seven Advanced Perspective tools, reached the way a person reaches them — Geometry ›
    /// Advanced Geometry › Advanced Perspective Tools — with every mode present by its stable identifier.
    @MainActor
    func testAdvancedPerspectiveToolsAreReachable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-SUEnableAutomaticChecks", "NO"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "the editor window")
        try open(picture(), in: app)
        XCTAssertTrue(app.staticTexts["canvasDimensions"].waitForExistence(timeout: 10), "the opened picture")

        app.menuBars.menuBarItems["Filter"].click()
        app.menuItems["Camera Raw Filter…"].click()
        XCTAssertTrue(app.staticTexts["Exposure"].firstMatch.waitForExistence(timeout: 10), "the Camera Raw panel")

        openCameraRawSection("Geometry", in: app)
        let advanced = app.descendants(matching: .any).matching(identifier: "geometryAdvanced").firstMatch
        XCTAssertTrue(advanced.waitForExistence(timeout: 5), "Advanced Geometry")
        advanced.click()
        Thread.sleep(forTimeInterval: 0.8)

        // Advanced Perspective is the last thing in Advanced Geometry, so scrolling to the panel's end shows it.
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<90 { scrollView.scroll(byDeltaX: 0, deltaY: -60) }
        Thread.sleep(forTimeInterval: 1)
        let disclosure = app.descendants(matching: .any).matching(identifier: "advancedPerspectiveDisclosure").firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5), "Advanced Perspective Tools is reachable")
        // Collapsed by default: an existing workflow is untouched until this is opened.
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "advancedPerspectiveToolPicker").firstMatch.exists,
                       "the subsection starts collapsed")

        disclosure.click()
        Thread.sleep(forTimeInterval: 0.8)
        let picker = app.descendants(matching: .any).matching(identifier: "advancedPerspectiveToolPicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "the tool selector appears when the subsection opens")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "advancedPerspectiveActiveTool").firstMatch.exists,
                      "the active tool is named")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "advancedPerspectiveActiveTool").firstMatch.value as? String,
                       "Off", "Automatic is the default")

        // Every one of the seven modes is in the menu, by its own identifier.
        picker.click()
        for (identifier, label) in [("automatic", "Automatic"), ("verticalGuides", "Vertical Guides"),
                                    ("horizontalGuides", "Horizontal Guides"), ("combinedGuides", "Combined Guides"),
                                    ("rectangle", "Rectangle"), ("eightPoint", "Eight Point"),
                                    ("manualKeystone", "Manual Keystone")] {
            let item = app.descendants(matching: .any).matching(identifier: "advancedPerspectiveTool_\(identifier)").firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 3), "\(label) is in the tool menu")
        }

        // Choosing Vertical Guides reveals the draw control, the count and the clear action.
        app.descendants(matching: .any).matching(identifier: "advancedPerspectiveTool_verticalGuides").firstMatch.click()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "advancedPerspectiveDraw").firstMatch.exists,
                      "a building tool offers Draw on Image")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "advancedPerspectiveInstructions").firstMatch.exists,
                      "the tool explains what to draw")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "advancedPerspectiveActiveTool").firstMatch.value as? String,
                       "Vertical Guides", "the header names the chosen tool")

        // Manual Keystone has no canvas handles: it reports the sliders above instead of offering a second set.
        picker.click()
        app.descendants(matching: .any).matching(identifier: "advancedPerspectiveTool_manualKeystone").firstMatch.click()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "advancedPerspectiveManualSummary").firstMatch.exists,
                      "Manual Keystone reports the existing sliders")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "advancedPerspectiveDraw").firstMatch.exists,
                       "Manual Keystone adds no drawing control")

        app.buttons["Cancel"].firstMatch.click()
    }

    /// Opens a closed Camera Raw section by its header. A section that is already open is left as it is.
    /// The panel scrolls, so the end is reached first: every section header is published once the list has been
    /// scrolled through, including the ones below the fold, and a header that is on screen can be clicked.
    private func openCameraRawSection(_ section: String, in app: XCUIApplication) {
        scrollPanel(app)
        let header = app.buttons[section].firstMatch
        guard header.waitForExistence(timeout: 3) else { return }
        let opener: [String: String] = ["Optics": "Distortion", "Light": "Exposure", "Geometry": "Upright"]
        if let marker = opener[section], app.staticTexts[marker].firstMatch.exists { return }
        header.click()
        Thread.sleep(forTimeInterval: 0.8)
        scrollPanel(app)
    }

    /// Scrolls the Camera Raw panel to its end. Unconditional rather than frame-driven: a SwiftUI element's frame
    /// read mid-scroll is stale, so a loop that watches for it stops early or loops forever.
    private func scrollPanel(_ app: XCUIApplication) {
        let scrollView = app.scrollViews.firstMatch
        guard scrollView.exists else { return }
        for _ in 0..<90 { scrollView.scroll(byDeltaX: 0, deltaY: -60) }
        Thread.sleep(forTimeInterval: 1)
    }

    /// Opens a file in the app under test as the Finder would.
    private func open(_ file: URL, in app: XCUIApplication) throws {
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

    /// A small flat picture: this test reads the panel, not the image.
    private func picture() throws -> URL {
        let width = 800, height = 600
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.45, green: 0.52, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Panel-\(UUID().uuidString).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
