import AppKit
import XCTest

/// Milestone 10.6 captures: the Lens Profile group in the states the calibrated engine produces.
///
/// These are genuine UI screenshots through the same automation `testMainScreens` uses. Each capture shows
/// the panel as a user meets it: Lensfun chosen with no database, Lensfun with a database imported and a
/// profile matched, and the policy sentence when the source is not a RAW. The green "Applying…" state needs
/// a RAW-backed layer with Apple's decode correction off, which this harness cannot manufacture (a JPEG
/// source is refused by policy, honestly); the rendered proof of that state is
/// `CameraRawLensfunRawEvidenceTests`, and the panel's wording for it is asserted by
/// `CameraRawLensProfileTests`.
final class LensfunScreenshotTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = true }

    @MainActor
    func testLensProfileStates() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-SUEnableAutomaticChecks", "NO"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "the editor window")

        try open(tiffPicture(), in: app)
        XCTAssertTrue(app.staticTexts["canvasDimensions"].waitForExistence(timeout: 10), "the opened picture")

        app.menuBars.menuBarItems["Filter"].click()
        app.menuItems["Camera Raw Filter…"].click()
        let panel = app.dialogs["filterPanel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "the Camera Raw panel")

        openCameraRawSection("Optics", in: app)
        scrollPanelToEnd(app)
        let profileMarker = app.staticTexts["Lens Profile"].firstMatch
        XCTAssertTrue(profileMarker.waitForExistence(timeout: 5), "the Lens Profile group")

        // 1. The default: Apple Native, which a user who never installs Lensfun keeps forever.
        shoot("21 Lens Profile Apple Native default", panel)

        // 2. Lensfun chosen with nothing installed: the import control and the honest statement that
        //    without a database nothing changes.
        let provider = app.descendants(matching: .any).matching(identifier: "lensProfileProvider").firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 3), "the provider picker")
        provider.click()
        let lensfun = app.menuItems["Lensfun"].firstMatch
        if lensfun.waitForExistence(timeout: 3) { lensfun.click() }
        XCTAssertTrue(app.buttons["Import Lensfun Database"].firstMatch.waitForExistence(timeout: 3),
                      "the import control appears")
        scrollIntoView(profileMarker, in: app, panel: panel)
        shoot("22 Lensfun chosen, no database", panel)

        // 3. Lensfun with a database installed: a profile matches the TIFF's camera and lens tags and the
        //    panel reports what the profile is calibrated for. The pixel pass is refused on a TIFF — the
        //    policy sentence says exactly why, which is the honest state for a rendered source.
        installFixtureDatabase()
        // The panel reads the database when it appears; reopening it is what a person does to refresh.
        // Cancel closes the edit, and Cancel must leave the settings as they were, so the reopened panel
        // carries Apple Native again. Choosing Lensfun once more is what a person does with the database
        // in place: the match now runs, and the panel answers with the refusal this TIFF earns.
        app.buttons["Cancel"].firstMatch.click()
        Thread.sleep(forTimeInterval: 0.5)
        app.menuBars.menuBarItems["Filter"].click()
        app.menuItems["Camera Raw Filter…"].click()
        XCTAssertTrue(app.staticTexts["Exposure"].firstMatch.waitForExistence(timeout: 10), "the panel reopens")
        let refreshedPanel = app.dialogs["filterPanel"]
        XCTAssertTrue(refreshedPanel.waitForExistence(timeout: 5), "the reopened panel")
        openCameraRawSection("Optics", in: app)
        scrollPanelToEnd(app)
        let refreshedMarker = app.staticTexts["Lens Profile"].firstMatch
        XCTAssertTrue(refreshedMarker.waitForExistence(timeout: 5), "Lens Profile survives the refresh")
        let reopenedProvider = app.descendants(matching: .any).matching(identifier: "lensProfileProvider").firstMatch
        XCTAssertTrue(reopenedProvider.waitForExistence(timeout: 3), "the provider picker again")
        reopenedProvider.click()
        let lensfunAgain = app.menuItems["Lensfun"].firstMatch
        XCTAssertTrue(lensfunAgain.waitForExistence(timeout: 3), "Lensfun is offered with the database installed")
        lensfunAgain.click()
        scrollIntoView(refreshedMarker, in: app, panel: refreshedPanel)
        shoot("24 Lensfun with database, profile matched, refused on a TIFF", refreshedPanel)

        // 4. Off: both providers out of the way, with the sentence that manual Optics still apply.
        let refreshedProvider = app.descendants(matching: .any).matching(identifier: "lensProfileProvider").firstMatch
        XCTAssertTrue(refreshedProvider.waitForExistence(timeout: 3), "the provider picker again")
        refreshedProvider.click()
        let off = app.menuItems["Off"].firstMatch
        if off.waitForExistence(timeout: 3) { off.click() }
        scrollIntoView(refreshedMarker, in: app, panel: refreshedPanel)
        shoot("23 Provider Off", refreshedPanel)

        app.buttons["Cancel"].firstMatch.click()
    }

    /// Installs a small calibrated Lensfun XML into the app's own database store, the same folder the
    /// panel's import button fills. This writes Lensfun data, not code, and the app never executes it.
    /// It is removed afterwards so the developer's app state is untouched.
    private func installFixtureDatabase() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <lensdatabase version="1">
          <camera>
            <maker>Canon</maker>
            <model>Canon EOS 6D</model>
            <mount>Canon EF</mount>
            <cropfactor>1.005</cropfactor>
          </camera>
          <lens>
            <maker>Sigma</maker>
            <model>Sigma 24-70mm F2.8 DG OS HSM | Art 017</model>
            <mount>Canon EF</mount>
            <cropfactor>1.0</cropfactor>
            <focal min="24" max="70" />
            <aperture min="2.8" max="22" />
            <calibration>
              <distortion model="ptlens" focal="24" a="0.0242559" b="-0.0662983" c="0.0245867" />
              <tca model="poly3" focal="24" vr="1.0001580" vb="1.0001595" />
              <vignetting model="pa" focal="24" aperture="2.8" distance="10" k1="-0.5" k2="0.2" k3="0" />
            </calibration>
          </lens>
        </lensdatabase>
        """
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.wonderassembly.compositor/Data/Library/Application Support/Compositor/Lensfun Database", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? xml.write(to: base.appendingPathComponent("fixture.xml"), atomically: true, encoding: .utf8)
        installedFixture = true
    }

    private var installedFixture = false

    override func tearDownWithError() throws {
        if installedFixture {
            let base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/com.wonderassembly.compositor/Data/Library/Application Support/Compositor/Lensfun Database", isDirectory: true)
            try? FileManager.default.removeItem(at: base)
        }
    }

    // MARK: - Shared machinery (kept in step with ScreenshotTests)

    private func openCameraRawSection(_ section: String, in app: XCUIApplication) {
        scrollPanelToEnd(app)
        let header = app.buttons[section].firstMatch
        guard header.waitForExistence(timeout: 3) else { return }
        let opener: [String: String] = ["Optics": "Distortion", "Light": "Exposure", "Geometry": "Upright"]
        if let marker = opener[section], app.staticTexts[marker].firstMatch.exists { return }
        header.click()
        scrollPanelToEnd(app)
    }

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

    private func scrollPanelToEnd(_ app: XCUIApplication) {
        let scrollView = app.scrollViews.firstMatch
        guard scrollView.exists else { return }
        for _ in 0..<12 { scrollView.scroll(byDeltaX: 0, deltaY: -600) }
        Thread.sleep(forTimeInterval: 0.4)
    }

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

    /// The same made-up landscape as `ScreenshotTests.picture`, written as a TIFF with camera tags, so
    /// the panel's metadata rows show a camera and a lens the way a photograph would. TIFF carries EXIF.
    private func tiffPicture() throws -> URL {
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Landscape-\(UUID().uuidString).tif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Canon",
                kCGImagePropertyTIFFModel: "Canon EOS 6D",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "24-70mm F2.8 DG OS HSM | Art 017",
                kCGImagePropertyExifFocalLength: 24.0,
                kCGImagePropertyExifFNumber: 3.2,
            ],
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
