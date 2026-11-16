import Foundation
import Testing
@testable import Compositor

/// Camera Raw presets: save, apply, rename, delete, duplicate, import/export, and corrupted-file handling.
struct CameraRawPresetTests {
    // MARK: - Fixtures

    private func settingsWithExposure(_ exposure: Double) -> CameraRawSettings {
        var s = CameraRawSettings()
        s.exposure = exposure
        return s
    }

    private func settingsWithTemperature(_ temperature: Double) -> CameraRawSettings {
        var s = CameraRawSettings()
        s.temperature = temperature
        return s
    }

    // MARK: - Save and apply

    @Test func aPresetSavesTheCurrentSettingsAndAppliesThem() throws {
        let manager = CameraRawPresets()
        _ = manager.all // force load

        var settings = settingsWithExposure(2)
        try manager.save(name: "Brighten", affects: [.light], settings: settings)
        let preset = try #require(manager.all.first { $0.name == "Brighten" })
        #expect(preset.affects == [.light])
        #expect(preset.settings.exposure == 2)

        var target = CameraRawSettings()
        manager.apply(preset, to: &target)
        #expect(target.exposure == 2, "the preset's light group is applied")
        #expect(target.temperature == 0, "the preset's untouched color group is left at default")
    }

    @Test func anAdditivePresetLeavesUnlistedGroupsAlone() throws {
        let manager = CameraRawPresets()
        var settings = settingsWithTemperature(40)
        try manager.save(name: "Warm", affects: [.color], settings: settings)

        var target = settingsWithExposure(2)
        manager.apply(try #require(manager.all.first), to: &target)
        #expect(target.temperature == 40, "color group applied")
        #expect(target.exposure == 2, "light group untouched by the preset")
    }

    // MARK: - Rename and delete

    @Test func renamingAPresetKeepsItsSettings() throws {
        let manager = CameraRawPresets()
        try manager.save(name: "Old", affects: [.light], settings: settingsWithExposure(1))
        let preset = try #require(manager.all.first)
        try manager.rename(preset.id, to: "New")
        #expect(manager.all.first?.name == "New")
        #expect(manager.all.first?.settings.exposure == 1)
    }

    @Test func deletingAPresetRemovesIt() throws {
        let manager = CameraRawPresets()
        try manager.save(name: "Gone", affects: [.light], settings: settingsWithExposure(1))
        let preset = try #require(manager.all.first)
        try manager.delete(preset.id)
        #expect(manager.all.first { $0.id == preset.id } == nil)
    }

    // MARK: - Duplicate

    @Test func duplicatingAPresetKeepsItsGroupsAndSettings() throws {
        let manager = CameraRawPresets()
        try manager.save(name: "Base", affects: [.light, .color], settings: settingsWithExposure(1))
        let preset = try #require(manager.all.first)
        let copy = try manager.duplicate(preset.id, named: "Copy")
        #expect(copy.name == "Copy")
        #expect(copy.affects == [.light, .color])
        #expect(copy.settings.exposure == 1)
        #expect(manager.all.count == 2)
    }

    // MARK: - Import and export

    @Test func importAndExportRoundTrip() throws {
        let manager = CameraRawPresets()
        try manager.save(name: "Exportable", affects: [.light], settings: settingsWithExposure(3))
        let preset = try #require(manager.all.first)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.compositorpreset")
        try? FileManager.default.removeItem(at: url)
        try manager.export(preset, to: url)

        let imported = try manager.importPreset(from: url)
        #expect(imported.name == "Exportable")
        #expect(imported.affects == [.light])
        #expect(imported.settings.exposure == 3)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func importingACorruptedFileThrows() throws {
        let manager = CameraRawPresets()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad.compositorpreset")
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: CameraRawPresetError.self) { try manager.importPreset(from: url) }
        try? FileManager.default.removeItem(at: url)
    }

    @Test func importingAWrongVersionThrows() throws {
        let manager = CameraRawPresets()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("future.compositorpreset")
        let file = CameraRawPresetFile(version: 999, name: "Future", affects: [],
                                       settings: CameraRawSettingsPersistentState(CameraRawSettings()))
        let data = try JSONEncoder().encode(file)
        try data.write(to: url)
        #expect(throws: CameraRawPresetError.self) { try manager.importPreset(from: url) }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Validation

    @Test func savingWithoutANameThrows() throws {
        let manager = CameraRawPresets()
        #expect(throws: CameraRawPresetError.self) {
            try manager.save(name: "", affects: [.light], settings: settingsWithExposure(1))
        }
    }

    @Test func savingADuplicateNameThrows() throws {
        let manager = CameraRawPresets()
        try manager.save(name: "Dup", affects: [.light], settings: settingsWithExposure(1))
        #expect(throws: CameraRawPresetError.self) {
            try manager.save(name: "Dup", affects: [.light], settings: settingsWithExposure(2))
        }
    }

    @Test func anEmptyPresetChangesNothing() throws {
        let manager = CameraRawPresets()
        try manager.save(name: "Empty", affects: [], settings: settingsWithExposure(5))
        let preset = try #require(manager.all.first)
        #expect(preset.isEmpty)

        var target = settingsWithTemperature(10)
        manager.apply(preset, to: &target)
        #expect(target.temperature == 10, "an empty preset leaves everything alone")
    }

    // MARK: - The preset file carries the versioned settings mirror

    @Test func presetFileUsesThePersistentStateMirror() throws {
        let preset = CameraRawPreset(name: "X", affects: [.light], settings: settingsWithExposure(4))
        let file = CameraRawPresetFile(preset: preset)
        #expect(file.version == CameraRawPresetFormatVersion)
        #expect(file.settings.exposure == 4)
        let decoded = try JSONDecoder().decode(CameraRawPresetFile.self, from: try JSONEncoder().encode(file))
        #expect(decoded.settings.exposure == 4)
    }
}
