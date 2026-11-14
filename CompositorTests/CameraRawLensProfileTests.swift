import AppKit
import Foundation
import Testing
@testable import Compositor

/// Milestone 10.3: the optional Lensfun lens-profile provider. Every test proves one of the acceptance rules: the
/// default changes nothing, an absent database is not an error, a match is never guessed, a profile never promises a
/// calibration it lacks, and a damaged database is refused rather than half-loaded.
struct CameraRawLensProfileTests {
    // MARK: - Fixtures

    /// A small database with one camera, two lenses (one zoom, one prime) and one lens on another mount.
    private static let sampleXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <lensdatabase version="1">
      <mount>
        <name>Canon EF</name>
        <compat>M42</compat>
      </mount>
      <mount>
        <name>Nikon F</name>
      </mount>
      <camera>
        <maker>Canon</maker>
        <model>Canon EOS 5D Mark IV</model>
        <mount>Canon EF</mount>
        <cropfactor>1.0</cropfactor>
      </camera>
      <camera>
        <maker>Nikon Corporation</maker>
        <model>Nikon D850</model>
        <mount>Nikon F</mount>
        <cropfactor>1.0</cropfactor>
      </camera>
      <lens>
        <maker>Canon</maker>
        <model>Canon EF 24-70mm f/2.8L II USM</model>
        <mount>Canon EF</mount>
        <cropfactor>1.0</cropfactor>
        <focal min="24" max="70" />
        <aperture min="2.8" max="22" />
        <calibration>
          <distortion model="ptlens" focal="24" a="0.01" b="-0.02" c="0" />
          <distortion model="ptlens" focal="70" a="0.02" b="-0.01" c="0" />
          <tca model="poly3" focal="24" vr="1.0" vb="1.0" cr="0.0001" cb="0.0001" br="0" bb="0" />
          <vignetting model="pa" focal="24" aperture="2.8" distance="10" k1="-0.3" k2="0.1" k3="0" />
        </calibration>
      </lens>
      <lens>
        <maker>Canon</maker>
        <model>Canon EF 50mm f/1.8 STM</model>
        <mount>Canon EF</mount>
        <cropfactor>1.0</cropfactor>
        <focal value="50" />
        <aperture min="1.8" max="22" />
        <calibration>
          <distortion model="poly3" focal="50" k1="0.005" />
        </calibration>
      </lens>
      <lens>
        <maker>Nikon</maker>
        <model>Nikon AF-S Nikkor 24-70mm f/2.8E ED VR</model>
        <mount>Nikon F</mount>
        <cropfactor>1.0</cropfactor>
        <focal min="24" max="70" />
        <calibration>
          <vignetting model="pa" focal="24" aperture="2.8" distance="10" k1="-0.2" k2="0.05" k3="0" />
        </calibration>
      </lens>
    </lensdatabase>
    """

    private func database() throws -> LensfunDatabase {
        try LensfunDatabase.parse(Data(Self.sampleXML.utf8))
    }

    private func canon() -> LensMetadata {
        LensMetadata(cameraMake: "Canon", cameraModel: "Canon EOS 5D Mark IV",
                     lensMake: "Canon", lensModel: "Canon EF 24-70mm f/2.8L II USM",
                     focalLengthMm: 24, aperture: 2.8, hasMetadata: true)
    }

    /// A scratch store, so a test never reads or writes the user's real database.
    private func scratchStore() -> LensfunDatabaseStore {
        LensfunDatabaseStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("LensfunTest-\(UUID().uuidString)", isDirectory: true))
    }

    // MARK: - Default provider

    @Test func appleNativeIsTheDefaultAndChangesNothing() {
        let settings = CameraRawSettings()
        #expect(settings.optics.lensProfile.provider == .appleNative)
        #expect(settings.optics.lensProfile.isDefault)
        #expect(!settings.optics.lensProfile.adjustsPixels)
        #expect(!settings.optics.adjusts, "the default profile alone makes no adjustment")
        #expect(settings.isIdentity)
    }

    @Test func aProfileSelectionNeverChangesRenderedPixels() throws {
        let image = try gradient()
        var settings = CameraRawSettings()
        // Even the most explicit Lensfun choice leaves the pixels alone: M10.3 has no calibrated engine.
        settings.optics.lensProfile.provider = .lensfun
        settings.optics.lensProfile.selection = CameraRawLensProfileSelection(automatic: false,
                                                                             lensID: "Canon|Canon EF 50mm f/1.8 STM|Canon EF",
                                                                             cameraID: "Canon|Canon EOS 5D Mark IV")
        #expect(!settings.optics.adjusts)
        #expect(try rgba8(try settings.apply(image)) == rgba8(image))
    }

    @Test func providerSwitchingRoundTripsThroughTheModel() {
        var settings = CameraRawSettings()
        for provider in CameraRawLensProfileProvider.allCases {
            settings.optics.lensProfile.provider = provider
            #expect(settings.optics.lensProfile.provider == provider)
            #expect(!provider.summary.isEmpty, "each provider explains itself")
        }
        // Off is not a hidden identity: it is its own, explicit choice.
        #expect(CameraRawLensProfileProvider.off != CameraRawLensProfileProvider.appleNative)
    }

    // MARK: - Not installed

    @Test func aFreshStoreIsNotInstalled() {
        let store = scratchStore()
        #expect(!store.isInstalled)
        #expect(store.xmlFiles.isEmpty)
        #expect(store.timestamp == nil)
        #expect(throws: LensfunDatabaseError.self) { _ = try store.load() }
    }

    @Test func anEmptyFolderIsNotADatabase() throws {
        let store = scratchStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        #expect(!store.isInstalled)
        #expect(throws: LensfunDatabaseError.notADatabase) { _ = try store.load() }
    }

    @Test func lensfunUnavailableLeavesAppleUsable() throws {
        // The policy is what the panel reads when there is no database: it must describe Apple as still available.
        let policy = CameraRawLensCorrectionPolicy(source: .redevelopableRaw, provider: .appleNative,
                                                   appleCorrectionActive: true, manualAdjustmentsActive: false)
        #expect(policy.explanation.contains("Apple"))
        #expect(!policy.canApplyLensfunCorrection, "no calibrated engine yet")
    }

    // MARK: - Installation opt-in

    @Test func importingValidXMLInstallsAndLoadsIt() throws {
        let store = scratchStore()
        defer { store.uninstall() }
        let source = try writeXML(Self.sampleXML)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let loaded = try store.install(from: [source])
        #expect(loaded.cameras.count == 2)
        #expect(loaded.lenses.count == 3)
        #expect(store.isInstalled)
        #expect(try store.load().lenses.count == 3)
        #expect(store.digest().count == 64)
    }

    @Test func importingACompressedUpdateFolderInstallsEveryFile() throws {
        let store = scratchStore()
        defer { store.uninstall() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LensfunUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(Self.sampleXML.utf8).write(to: folder.appendingPathComponent("canon.xml"))
        try Data(Self.sampleXML.utf8).write(to: folder.appendingPathComponent("nikon.xml"))
        try Data("1700000000".utf8).write(to: folder.appendingPathComponent("timestamp.txt"))

        let loaded = try store.install(from: [folder])
        #expect(loaded.fileCount == 2)
        #expect(store.xmlFiles.count == 2)
        #expect(store.timestamp != nil, "the update's timestamp is kept")
    }

    @Test func aBadImportLeavesThePreviousDatabaseInPlace() throws {
        let store = scratchStore()
        defer { store.uninstall() }
        let good = try writeXML(Self.sampleXML)
        defer { try? FileManager.default.removeItem(at: good.deletingLastPathComponent()) }
        _ = try store.install(from: [good])
        let before = store.digest()

        let bad = try writeXML("<not-a-database><thing/></not-a-database>")
        defer { try? FileManager.default.removeItem(at: bad.deletingLastPathComponent()) }
        #expect(throws: LensfunDatabaseError.self) { _ = try store.install(from: [bad]) }
        #expect(store.digest() == before, "the working database is untouched")
    }

    @Test func uninstallingReturnsToTheFreshState() throws {
        let store = scratchStore()
        let source = try writeXML(Self.sampleXML)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        _ = try store.install(from: [source])
        #expect(store.isInstalled)
        store.uninstall()
        #expect(!store.isInstalled)
        #expect(throws: LensfunDatabaseError.self) { _ = try store.load() }
    }

    // MARK: - Database parsing

    @Test func parsingReadsCamerasLensesAndCalibrations() throws {
        let database = try database()
        #expect(database.formatVersion == 1)
        #expect(database.cameras.map(\.model).sorted() == ["Canon EOS 5D Mark IV", "Nikon D850"])
        let zoom = try #require(database.lenses.first { $0.model.contains("24-70mm f/2.8L") })
        #expect(zoom.focalMin == 24 && zoom.focalMax == 70)
        #expect(zoom.apertureMin == 2.8 && zoom.apertureMax == 22)
        #expect(zoom.mounts == ["Canon EF"])
        #expect(zoom.calibrations.distortion)
        #expect(zoom.calibrations.tca)
        #expect(zoom.calibrations.vignetting)
        #expect(zoom.calibratedFocals.sorted() == [24, 24, 70])
        #expect(zoom.vignettePoints.count == 1)
    }

    @Test func aPrimeReadsAsASingleFocalLength() throws {
        let prime = try #require(try database().lenses.first { $0.model.contains("50mm") })
        #expect(prime.focalMin == 50 && prime.focalMax == 50)
        #expect(prime.calibrations.distortion)
        #expect(!prime.calibrations.tca)
        #expect(!prime.calibrations.vignetting)
        #expect(prime.calibrations.names == ["Distortion"])
    }

    @Test func aNoneModelIsNotACalibration() throws {
        let xml = """
        <lensdatabase version="1">
          <lens><maker>X</maker><model>X 50mm</model><mount>X</mount><cropfactor>1</cropfactor>
            <calibration><distortion model="none" focal="50" /></calibration></lens>
        </lensdatabase>
        """
        let parsed = try LensfunDatabase.parse(Data(xml.utf8))
        let lens = try #require(parsed.lenses.first)
        #expect(!lens.calibrations.distortion, "a lens with no distortion is not reported as calibrated for it")
        #expect(!lens.calibrations.any)
    }

    // MARK: - Invalid input

    @Test func malformedXMLIsRejected() {
        #expect(throws: LensfunDatabaseError.self) {
            _ = try LensfunDatabase.parse(Data("<lensdatabase version=\"1\"><lens>".utf8))
        }
    }

    @Test func aFileThatIsNotADatabaseIsRejected() {
        #expect(throws: LensfunDatabaseError.self) {
            _ = try LensfunDatabase.parse(Data("<html><body>hello</body></html>".utf8))
        }
    }

    @Test func anUnsupportedFormatVersionIsRejected() {
        let xml = "<lensdatabase version=\"0\"><lens><model>X</model></lens></lensdatabase>"
        #expect(throws: LensfunDatabaseError.self) {
            _ = try LensfunDatabase.parse(Data(xml.utf8))
        }
    }

    @Test func aDatabaseWithNoEntriesIsRejected() {
        let xml = "<lensdatabase version=\"1\"><mount><name>X</name></mount></lensdatabase>"
        #expect(throws: LensfunDatabaseError.self) {
            _ = try LensfunDatabase.parse(Data(xml.utf8))
        }
    }

    @Test func anOversizedDatabaseIsRefusedBeforeParsing() {
        let big = Data(repeating: 0x20, count: LensfunXMLParser.maximumBytes + 1)
        #expect(throws: LensfunDatabaseError.self) { _ = try LensfunDatabase.parse(big) }
    }

    // MARK: - Matching

    @Test func anExactCameraAndLensMatchIsConfident() throws {
        let match = try database().match(canon())
        #expect(match.isConfident)
        #expect(match.lens?.model.contains("24-70mm f/2.8L") == true)
        #expect(match.camera?.model == "Canon EOS 5D Mark IV")
        #expect(match.issue == nil)
    }

    @Test func nameMatchingIgnoresCaseWordOrderAndPunctuation() throws {
        let database = try database()
        var metadata = canon()
        metadata.lensModel = "canon ef 24-70MM F2.8L II usm"
        #expect(database.match(metadata).isConfident, "the same lens, spelled differently")

        metadata.cameraModel = "canon eos 5d mark iv"
        #expect(database.match(metadata).camera?.model == "Canon EOS 5D Mark IV")
    }

    @Test func aCameraModelRecordedMoreBrieflyStillFindsItsEntry() throws {
        let database = try database()
        var metadata = canon()
        metadata.cameraModel = "EOS 5D Mark IV"
        #expect(database.cameras(matching: metadata).contains { $0.model == "Canon EOS 5D Mark IV" })
    }

    @Test func aLensMissingFromTheDatabaseIsReportedNotGuessed() throws {
        let database = try database()
        var metadata = canon()
        metadata.lensModel = "Canon EF 100-400mm f/4.5-5.6L IS II USM"
        let match = database.match(metadata)
        #expect(!match.isConfident)
        #expect(match.lens == nil)
        guard case .lensNotInDatabase = match.issue else {
            Issue.record("expected a missing-lens report, got \(String(describing: match.issue))")
            return
        }
    }

    @Test func aLensOnAnotherMountIsNotAMatch() throws {
        let database = try database()
        var metadata = canon()
        // A Nikon lens on a Canon body: the name exists, but the mount rules it out.
        metadata.lensModel = "Nikon AF-S Nikkor 24-70mm f/2.8E ED VR"
        let match = database.match(metadata)
        #expect(match.lens == nil)
        guard case .mountMismatch = match.issue else {
            Issue.record("expected a mount mismatch, got \(String(describing: match.issue))")
            return
        }
        #expect(match.candidates.count == 1, "the entry is still offered for manual choice")
    }

    @Test func aFocalLengthOutsideTheLensesRangeIsNotAMatch() throws {
        let database = try database()
        var metadata = canon()
        metadata.focalLengthMm = 200
        let match = database.match(metadata)
        #expect(match.lens == nil)
        guard case .focalMismatch = match.issue else {
            Issue.record("expected a focal mismatch, got \(String(describing: match.issue))")
            return
        }
    }

    @Test func twoIdenticalEntriesAreReportedAsAmbiguous() throws {
        let xml = """
        <lensdatabase version="1">
          <camera><maker>C</maker><model>C Body</model><mount>M</mount><cropfactor>1</cropfactor></camera>
          <lens><maker>L</maker><model>L 50mm</model><mount>M</mount><cropfactor>1</cropfactor><focal value="50" />
            <calibration><distortion model="poly3" focal="50" k1="0.01" /></calibration></lens>
          <lens><maker>L</maker><model>L 50mm</model><mount>M</mount><cropfactor>1.5</cropfactor><focal value="50" />
            <calibration><distortion model="poly3" focal="50" k1="0.02" /></calibration></lens>
        </lensdatabase>
        """
        let database = try LensfunDatabase.parse(Data(xml.utf8))
        let metadata = LensMetadata(cameraMake: "C", cameraModel: "C Body", lensModel: "L 50mm",
                                    focalLengthMm: 50, aperture: 0, hasMetadata: true)
        let match = database.match(metadata)
        #expect(match.lens == nil, "two fits are never resolved by taking the first")
        guard case .ambiguous(let names) = match.issue else {
            Issue.record("expected an ambiguity report, got \(String(describing: match.issue))")
            return
        }
        #expect(names.count == 2)
        #expect(match.candidates.count == 2, "both are offered for a manual choice")
    }

    @Test func aMissingLensTagReportsNoMetadataRatherThanAMatch() throws {
        let database = try database()
        let match = database.match(LensMetadata())
        #expect(match.lens == nil)
        #expect(match.issue == .noMetadata)
    }

    @Test func aCompatibleMountIsAccepted() throws {
        let xml = """
        <lensdatabase version="1">
          <mount><name>Pentax K</name><compat>M42</compat></mount>
          <camera><maker>P</maker><model>P Body</model><mount>Pentax K</mount><cropfactor>1.5</cropfactor></camera>
          <lens><maker>Z</maker><model>Z 50mm</model><mount>M42</mount><cropfactor>1</cropfactor><focal value="50" />
            <calibration><distortion model="poly3" focal="50" k1="0.01" /></calibration></lens>
        </lensdatabase>
        """
        let database = try LensfunDatabase.parse(Data(xml.utf8))
        let metadata = LensMetadata(cameraMake: "P", cameraModel: "P Body", lensModel: "Z 50mm",
                                    focalLengthMm: 50, aperture: 0, hasMetadata: true)
        #expect(database.match(metadata).isConfident, "an M42 lens fits a Pentax K body through the declared compatibility")
    }

    // MARK: - What a profile supports

    @Test func calibrationsAreReportedOnlyWhereSamplesCoverTheShot() throws {
        let zoom = try #require(try database().lenses.first { $0.model.contains("24-70mm f/2.8L") })
        // At 24 mm and f/2.8 every sample exists.
        let at24 = zoom.calibrations(coveringFocal: 24, aperture: 2.8)
        #expect(at24.distortion && at24.tca && at24.vignetting)
        // Vignetting was only measured at f/2.8, so at f/8 it is not claimed.
        let at8 = zoom.calibrations(coveringFocal: 24, aperture: 8)
        #expect(at8.distortion)
        #expect(!at8.vignetting, "no vignetting sample at f/8, so none is promised")
    }

    @Test func aPrimeWithoutVignettingDataNeverClaimsIt() throws {
        let prime = try #require(try database().lenses.first { $0.model.contains("50mm") })
        let available = prime.calibrations(coveringFocal: 50, aperture: 2)
        #expect(available.names == ["Distortion"])
        #expect(!available.vignetting)
    }

    // MARK: - Provider switching and persistence

    @Test func theProfileChoiceSurvivesAPersistenceRoundTrip() throws {
        var settings = CameraRawSettings()
        settings.optics.lensProfile.provider = .lensfun
        settings.optics.lensProfile.selection = CameraRawLensProfileSelection(automatic: false,
                                                                             lensID: "Canon|Canon EF 50mm f/1.8 STM|Canon EF",
                                                                             cameraID: "Canon|Canon EOS 5D Mark IV")
        let data = try JSONEncoder().encode(CameraRawSettingsPersistentState(settings))
        let restored = try JSONDecoder().decode(CameraRawSettingsPersistentState.self, from: data).makeSettings()
        #expect(restored.optics.lensProfile.provider == .lensfun)
        #expect(restored.optics.lensProfile.selection.isManual)
        #expect(restored.optics.lensProfile.selection.lensID == "Canon|Canon EF 50mm f/1.8 STM|Canon EF")
    }

    @Test func olderOpticsWithoutAProfileStillLoads() throws {
        let json = Data("""
        {"schemaVersion":1,"exposure":0.25,
         "optics":{"removeChromaticAberration":false,"enableLensProfile":false,"profileDistortion":100,
                   "profileVignetting":100,"distortion":3,"purpleAmount":0,"purpleHueLow":270,
                   "purpleHueHigh":310,"greenAmount":0,"greenHueLow":60,"greenHueHigh":120,
                   "vignetteAmount":0,"vignetteMidpoint":50}}
        """.utf8)
        let settings = try JSONDecoder().decode(CameraRawSettingsPersistentState.self, from: json).makeSettings()
        #expect(settings.exposure == 0.25)
        #expect(settings.optics.distortion == 3)
        #expect(settings.optics.lensProfile.provider == .appleNative, "a project from before M10.3 keeps Apple Native")
        #expect(settings.optics.lensProfile.isDefault)
    }

    @Test func anUnknownProviderStringFallsBackToAppleNative() throws {
        var persistent = CameraRawSettingsPersistentState()
        persistent.optics.lensProfile.provider = "Some Future Provider"
        let settings = try persistent.makeSettings()
        #expect(settings.optics.lensProfile.provider == .appleNative)
    }

    @Test func anAutomaticSelectionCarriesNoPinnedLens() {
        let selection = CameraRawLensProfileSelection(automatic: true, lensID: "stale", cameraID: "stale")
        #expect(selection.normalized.lensID.isEmpty, "an automatic choice cannot keep a stale pinned identity")
    }

    // MARK: - Undo / reset

    @Test func theProfileChoiceBelongsToTheOpticsReset() {
        var settings = CameraRawSettings()
        settings.optics.lensProfile.provider = .lensfun
        settings.optics.lensProfile.selection = CameraRawLensProfileSelection(automatic: false, lensID: "x", cameraID: "y")
        #expect(!settings.isDefault(.optics))
        let reset = settings.resetting(.optics)
        #expect(reset.isDefault(.optics))
        #expect(reset.optics.lensProfile.provider == .appleNative)
        #expect(reset.optics.lensProfile.selection.lensID.isEmpty)
    }

    // MARK: - Correction policy

    @Test func aRedevelopableRawMayEventuallyTakeALensfunCorrection() {
        let policy = CameraRawLensCorrectionPolicy(source: .redevelopableRaw, provider: .lensfun,
                                                   appleCorrectionActive: false, manualAdjustmentsActive: false)
        #expect(policy.canApplyLensfunCorrection == false, "not until the calibrated engine exists")
        #expect(policy.showsUnavailableNotice)
        #expect(policy.explanation.contains("next milestone") || policy.explanation.contains("not available"))
    }

    @Test func aDevelopedRawAndARenderedImageAreBothRefused() {
        for source in [CameraRawLensCorrectionPolicy.Source.previouslyDevelopedRaw, .renderedImage] {
            let policy = CameraRawLensCorrectionPolicy(source: source, provider: .lensfun,
                                                       appleCorrectionActive: true, manualAdjustmentsActive: false)
            #expect(!policy.canApplyLensfunCorrection, "\(source) cannot be corrected without risking a double correction")
        }
    }

    @Test func appleCorrectionBeingOnIsCalledOut() {
        let on = CameraRawLensCorrectionPolicy(source: .redevelopableRaw, provider: .appleNative,
                                               appleCorrectionActive: true, manualAdjustmentsActive: false)
        #expect(on.explanation.contains("twice"), "the panel warns before a second correction")
        let off = CameraRawLensCorrectionPolicy(source: .redevelopableRaw, provider: .appleNative,
                                                appleCorrectionActive: false, manualAdjustmentsActive: false)
        #expect(off.explanation != on.explanation)
    }

    @Test func offKeepsManualAdjustmentsAndSaysSo() {
        let policy = CameraRawLensCorrectionPolicy(source: .renderedImage, provider: .off,
                                                   appleCorrectionActive: false, manualAdjustmentsActive: true)
        #expect(policy.explanation.contains("manual"))
        #expect(!policy.canApplyLensfunCorrection)
    }

    // MARK: - Helpers

    private func gradient(width: Int = 48, height: Int = 32) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                let i = y * stride + x * 4
                data[i] = UInt8((x * 255) / max(width - 1, 1))
                data[i + 1] = UInt8((y * 255) / max(height - 1, 1))
                data[i + 2] = 128
                data[i + 3] = 255
            }
        }
        return try #require(context.makeImage())
    }

    private func rgba8(_ image: CGImage) throws -> [UInt8] {
        try MeshWarpRaster.rgba8Bytes(from: image)
    }

    /// Writes XML to a fresh temporary folder, so an import test never touches a real path.
    private func writeXML(_ xml: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LensfunSource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("lensfun.xml")
        try Data(xml.utf8).write(to: url)
        return url
    }
}
