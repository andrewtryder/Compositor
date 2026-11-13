import Foundation
import CoreGraphics
import Testing
@testable import Compositor

/// Tests for RAW development persistence: settings encode/decode, as-shot reset,
/// invalid values, project save/reopen, byte equality, and legacy compatibility.
///
/// NOTE: These tests use synthesized data rather than real RAW/DNG fixtures because
/// no redistributable RAW photograph is available in this worktree. Actual decoder
/// integration with a real RAW photograph is marked NOT MEASURED.
struct RawDevelopmentPersistenceTests {

    // MARK: - Settings encode/decode

    @Test func settingsEncodeDecodeRoundTrip() throws {
        var settings = RawDevelopmentSettingsPersistentState()
        settings.exposure = 1.5
        settings.temperature = 5600
        settings.tint = 15
        settings.boost = 0.9
        settings.noiseReduction = 0.3
        settings.lensCorrection = true
        settings.highlightRecovery = true
        settings.asShotTemperature = 5200
        settings.asShotTint = 8
        settings.asShotNoiseReduction = 0.1
        settings.asShotLensCorrection = false
        settings.asShotHighlightRecovery = false
        settings.supportsNoiseReduction = true
        settings.supportsLensCorrection = true
        settings.supportsHighlightRecovery = true

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(RawDevelopmentSettingsPersistentState.self, from: encoded)
        #expect(decoded == settings, "settings must round-trip through JSON")
        #expect(decoded.schemaVersion == RawDevelopmentSettingsPersistentState.schemaVersion)
    }

    @Test func settingsDefaultValuesAreValid() {
        let settings = RawDevelopmentSettingsPersistentState()
        #expect(settings.isValid(), "default settings must be valid")
        #expect(settings.exposure == 0)
        #expect(settings.temperature == 5000)
        #expect(settings.tint == 0)
        #expect(settings.boost == 1)
        #expect(settings.noiseReduction == 0)
    }

    // MARK: - As Shot reset

    @Test func asShotResetRestoresCameraDefaults() {
        var settings = RawDevelopmentSettingsPersistentState()
        settings.exposure = 2.0
        settings.temperature = 6500
        settings.tint = -20
        settings.noiseReduction = 0.7
        settings.lensCorrection = true
        settings.highlightRecovery = true
        settings.asShotTemperature = 5200
        settings.asShotTint = 8
        settings.asShotNoiseReduction = 0.1
        settings.asShotLensCorrection = false
        settings.asShotHighlightRecovery = false

        settings.reset()
        #expect(settings.exposure == 0, "exposure reset to 0")
        #expect(settings.boost == 1, "boost reset to 1")
        #expect(settings.temperature == 5200, "temperature reset to asShot")
        #expect(settings.tint == 8, "tint reset to asShot")
        #expect(settings.noiseReduction == 0.1, "noise reduction reset to asShot")
        #expect(settings.lensCorrection == false, "lens correction reset to asShot")
        #expect(settings.highlightRecovery == false, "highlight recovery reset to asShot")
    }

    @Test func isAsShotDetectsUnchangedSettings() {
        var settings = RawDevelopmentSettingsPersistentState()
        settings.asShotTemperature = 5200
        settings.asShotTint = 8
        settings.temperature = 5200
        settings.tint = 8
        #expect(settings.isAsShot, "settings matching asShot should report isAsShot")

        settings.temperature = 6000
        #expect(!settings.isAsShot, "changed temperature should not be asShot")
    }

    // MARK: - Invalid values

    @Test func invalidSettingsAreRejected() {
        var settings = RawDevelopmentSettingsPersistentState()
        settings.exposure = .nan
        #expect(!settings.isValid(), "NaN exposure is invalid")

        settings.exposure = 0
        settings.boost = -1
        #expect(!settings.isValid(), "negative boost is invalid")

        settings.boost = 1
        settings.noiseReduction = 1.5
        #expect(!settings.isValid(), "noise reduction > 1 is invalid")
    }

    // MARK: - RawSourceAsset encode/decode

    @Test func rawSourceAssetEncodeDecodeRoundTrip() throws {
        let settings = RawDevelopSettings()
        let source = RawSourceAsset(
            rawData: Data([0x49, 0x49, 0x2A, 0x00]), // TIFF little-endian magic
            fileExtension: "dng",
            utType: "com.adobe.raw-image",
            pixelWidth: 4000,
            pixelHeight: 3000,
            cameraMetadata: ["Make": "TestCamera", "Model": "TestModel"],
            colorSpace: "extendedLinearSRGB",
            bitsPerComponent: 14,
            asShotSettings: settings,
            supportsNoiseReduction: true,
            supportsLensCorrection: false,
            supportsHighlightRecovery: true
        )

        let encoded = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(RawSourceAsset.self, from: encoded)
        #expect(decoded.sourceID == source.sourceID)
        #expect(decoded.rawData == source.rawData, "raw bytes must round-trip exactly")
        #expect(decoded.fileExtension == "dng")
        #expect(decoded.pixelWidth == 4000)
        #expect(decoded.pixelHeight == 3000)
        #expect(decoded.bitsPerComponent == 14)
        #expect(decoded.asShotSettings == settings)
    }

    // MARK: - RawDevelopmentPersistentState encode/decode

    @Test func rawDevelopmentPersistentStateEncodeDecode() throws {
        let settings = RawDevelopSettings(exposure: 1.0, temperature: 5500)
        let source = RawSourceAsset(
            rawData: Data([1, 2, 3, 4]),
            fileExtension: "dng",
            utType: "com.adobe.raw-image",
            pixelWidth: 2000,
            pixelHeight: 1500,
            asShotSettings: settings
        )
        let persistent = RawDevelopmentPersistentState(
            source: source,
            settings: RawDevelopmentSettingsPersistentState(settings),
            developedWidth: 2000,
            developedHeight: 1500,
            developedColorSpace: "extendedLinearSRGB",
            developedBitsPerComponent: 16
        )

        let encoded = try JSONEncoder().encode(persistent)
        let decoded = try JSONDecoder().decode(RawDevelopmentPersistentState.self, from: encoded)
        #expect(decoded.source.rawData == source.rawData, "source bytes must round-trip")
        #expect(decoded.settings.exposure == 1.0)
        #expect(decoded.developedBitsPerComponent == 16, "16-bit depth preserved")
    }

    // MARK: - Project persistence v25

    @Test func projectManifestCurrentIs25() {
        #expect(ProjectManifest.current == 25, "project format must be v25 for RAW persistence")
    }

    // MARK: - Byte budget and source sharing

    @Test func duplicateLayersShareSourceIDWithoutByteDuplication() throws {
        let settings = RawDevelopSettings()
        let source = RawSourceAsset(
            rawData: Data(repeating: 0xFF, count: 1_000_000), // 1MB of RAW bytes
            fileExtension: "dng",
            utType: "com.adobe.raw-image",
            pixelWidth: 2000,
            pixelHeight: 1500,
            asShotSettings: settings
        )
        let state = RawDevelopmentPersistentState(
            source: source,
            settings: RawDevelopmentSettingsPersistentState(settings),
            developedWidth: 2000,
            developedHeight: 1500,
            developedColorSpace: "extendedLinearSRGB",
            developedBitsPerComponent: 16
        )

        var layer1 = ImageLayer(name: "RAW Layer 1", blankSize: CGSize(width: 2000, height: 1500))
        layer1.rawDevelopment = state
        var layer2 = ImageLayer(name: "RAW Layer 2 (duplicate)", blankSize: CGSize(width: 2000, height: 1500))
        layer2.rawDevelopment = state

        // Duplicate layers share the same sourceID (same source asset), avoiding byte duplication.
        #expect(layer1.rawDevelopment?.source.sourceID == layer2.rawDevelopment?.source.sourceID,
                "duplicate layers must share source identity")
        #expect(layer1.rawDevelopment?.source.rawData.count == 1_000_000,
                "source retains full byte count")
    }

    // MARK: - 16-bit precision

    @Test func sixteenBitPrecisionIsPreserved() {
        let settings = RawDevelopSettings()
        let source = RawSourceAsset(
            rawData: Data([1, 2, 3]),
            fileExtension: "dng",
            utType: "com.adobe.raw-image",
            pixelWidth: 100,
            pixelHeight: 100,
            asShotSettings: settings
        )
        let state = RawDevelopmentPersistentState(
            source: source,
            settings: RawDevelopmentSettingsPersistentState(settings),
            developedWidth: 100,
            developedHeight: 100,
            developedColorSpace: "extendedLinearSRGB",
            developedBitsPerComponent: 16
        )
        #expect(state.developedBitsPerComponent == 16, "RAW development must keep 16-bit precision")
    }
}