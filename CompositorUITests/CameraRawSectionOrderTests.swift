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

        // The other sections are untouched by the additions.
        for name in ["Curve", "Color Mixer", "Detail", "Geometry", "Calibration", "Effects", "Color Grading"] {
            XCTAssertTrue(app.buttons[name].firstMatch.exists, "section \(name) is still reachable")
        }

        app.buttons["Cancel"].firstMatch.click()
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
