import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import Compositor

/// M12.5 on the real decoder: the Ricoh GR III DNG that genuinely runs RAW 9, and the Canon EOS 5DS R CR2 that does
/// not. Both are untracked local fixtures, so a checkout without them reports these as skipped rather than inventing
/// numbers — the deterministic suite beside this one stays mandatory.
///
/// The point of these is the distinction the API does not make for you: requesting v9 on the CR2 returns no error and
/// leaves v7 in place, so "support" means the read-back, never the request.
@MainActor
struct RawDecoderFixtureTests {
    private var dng: URL? {
        RawDecoderFixtures.dng
    }

    private var cr2: URL? {
        RawDecoderFixtures.cr2
    }

    // MARK: - The DNG that genuinely supports RAW 9

    @Test(.enabled(if: RawDecoderFixtures.dng != nil, "the untracked Ricoh GR III DNG is absent"))
    func dngListsAndHonoursRaw9() throws {
        let url = try #require(dng)
        let filter = try #require(CIRAWFilter(imageURL: url))
        let supported = filter.supportedDecoderVersions.map(\.rawValue)
        #expect(RawDecoderSelection.offersRaw9(supported: supported),
                "this DNG lists a RAW 9 spelling: \(supported)")

        // Request, then ask what version is actually in effect. This is the whole support test.
        let requested = RawDecoderChoice.appleRAW9.requestedVersions
            .first { supported.contains($0.rawValue) }
        let candidate = try #require(requested)
        filter.decoderVersion = candidate
        let effective = filter.decoderVersion.rawValue
        #expect(effective == candidate.rawValue, "RAW 9 is genuinely in effect, not a fallback (\(effective))")
        #expect(RawDecoderSelection.verdict(requested: candidate.rawValue, supported: supported,
                                            effective: effective).isApplied)
    }

    @Test(.enabled(if: RawDecoderFixtures.dng != nil, "the untracked Ricoh GR III DNG is absent"))
    func dngOffersRaw9ThroughTheProductionProbe() throws {
        let url = try #require(dng)
        #expect(RawImporter.availableDecoders(at: url).contains(.appleRAW9),
                "the sheet would offer RAW 9 for this file")
        #expect(RawImporter.availability(of: .appleRAW9, at: url) == .available)
        #expect(RawImporter.availability(of: .systemDefault, at: url) == .available)
        let capabilities = try #require(RawImporter.capabilities(at: url, decoder: .appleRAW9))
        #expect(capabilities.isRaw9, "capabilities are read at the version in effect")
    }

    /// The as-shot state has to describe the selected decoder, or the controls would be enabled for a decoder that is
    /// not being used. Under v9 this file loses three of them.
    @Test(.enabled(if: RawDecoderFixtures.dng != nil, "the untracked Ricoh GR III DNG is absent"))
    func asShotDescribesTheSelectedDecoder() throws {
        let url = try #require(dng)
        let system = try #require(RawImporter.asShot(url))
        let v9 = try #require(RawImporter.asShot(url, decoder: .appleRAW9))

        #expect(system.decoder == .systemDefault)
        #expect(v9.decoder == .appleRAW9)
        #expect(system.supportsColorNoiseReduction, "the system decoder offers Color Noise Reduction on this file")
        #expect(system.supportsDetail && system.supportsMoire, "and detail and moiré")
        #expect(!v9.supportsColorNoiseReduction, "RAW 9 does not")
        #expect(!v9.supportsDetail && !v9.supportsMoire)
        #expect(v9.supportsSharpness && v9.supportsContrast, "sharpness and contrast survive")
        #expect(v9.supportsNoiseReduction, "luminance noise reduction survives")
        #expect(v9.supportsHighlightRecovery, "highlight recovery survives")
        #expect(v9.unavailableRawDetailControls == [.detail, .moire])
        print("[M12.5] DNG as-shot: system colorNR=\(system.supportsColorNoiseReduction) "
              + "v9 colorNR=\(v9.supportsColorNoiseReduction) v9 detail=\(v9.supportsDetail) "
              + "v9 moire=\(v9.supportsMoire) v9 sharpness=\(v9.supportsSharpness) "
              + "v9 contrast=\(v9.supportsContrast) effective=\(v9.effectiveDecoderVersion)")
    }

    /// RAW 9 must change the pixels, or selecting it would be a label with no rendering behind it.
    @Test(.enabled(if: RawDecoderFixtures.dng != nil, "the untracked Ricoh GR III DNG is absent"))
    func raw9RendersDifferentlyFromTheSystemDecoder() throws {
        let url = try #require(dng)
        let system = try #require(RawImporter.asShot(url))
        var v9 = try #require(RawImporter.asShot(url, decoder: .appleRAW9))

        // A bounded preview: at native size this is seconds per decoder for a difference that is already decided.
        let a = try #require(try RawImporter.develop(url, settings: system, limit: 1200))
        let b = try #require(try RawImporter.develop(url, settings: v9, limit: 1200))
        #expect(a.width == b.width && a.height == b.height, "the same frame, developed two ways")

        let moved = try fractionDiffering(a, b)
        #expect(moved > 0.5, "RAW 9 develops genuinely different pixels (moved \(moved * 100)%)")
        print("[M12.5] DNG system vs RAW 9: \(String(format: "%.2f", moved * 100))% of pixels differ")
    }

    /// The measured control regression, on the real decoder rather than from a remembered table. The setter must not be
    /// called when the version does not offer it, so the test fails if a guard is dropped.
    @Test(.enabled(if: RawDecoderFixtures.dng != nil, "the untracked Ricoh GR III DNG is absent"))
    func theThreeControlRegressionsAreMeasuredNotAssumed() throws {
        let url = try #require(dng)
        let system = try #require(RawDecoderCapabilities(try #require(CIRAWFilter(imageURL: url))))
        let v9Filter = try #require(CIRAWFilter(imageURL: url))
        v9Filter.decoderVersion = .init(rawValue: "9")
        let v9 = RawDecoderCapabilities(v9Filter)

        #expect(system.supportsColorNoiseReduction && !v9.supportsColorNoiseReduction)
        #expect(system.supportsDetail && !v9.supportsDetail)
        #expect(system.supportsMoireReduction && !v9.supportsMoireReduction)
        // The two that do not regress.
        #expect(system.supportsSharpness && v9.supportsSharpness)
        #expect(system.supportsContrast && v9.supportsContrast)
        print("[M12.5] control regressions: colorNR \(system.supportsColorNoiseReduction)→\(v9.supportsColorNoiseReduction) "
              + "detail \(system.supportsDetail)→\(v9.supportsDetail) "
              + "moire \(system.supportsMoireReduction)→\(v9.supportsMoireReduction); "
              + "sharpness \(system.supportsSharpness)→\(v9.supportsSharpness) "
              + "contrast \(system.supportsContrast)→\(v9.supportsContrast)")
    }

    /// The 16-bit path must survive the decoder change: RGBA16, integer, 64 bits per pixel, and fully opaque, for
    /// `DeepLayer`. The alpha *layout* differs between decoders — the system decoder reports premultiplied last and RAW 9
    /// reports none-skip-last — so opacity is checked from the pixels rather than the label: both are fully opaque, which
    /// is what a RAW frame must be.
    @Test(.enabled(if: RawDecoderFixtures.dng != nil, "the untracked Ricoh GR III DNG is absent"))
    func sixteenBitOutputSurvivesRaw9() throws {
        let url = try #require(dng)
        for choice in [RawDecoderChoice.systemDefault, .appleRAW9] {
            var settings = try #require(RawImporter.asShot(url, decoder: choice))
            settings.exposure = 0
            let image = try RawImporter.develop(url, settings: settings, limit: 600, sixteenBit: true)
            #expect(image.bitsPerComponent == 16, "\(choice.label): 16 bits per component")
            #expect(image.bitsPerPixel == 64, "\(choice.label): 64 bits per pixel")
            let alphaLayoutOK = image.alphaInfo.rawValue == CGImageAlphaInfo.premultipliedLast.rawValue
                || image.alphaInfo.rawValue == CGImageAlphaInfo.last.rawValue
                || image.alphaInfo.rawValue == CGImageAlphaInfo.noneSkipLast.rawValue
            #expect(alphaLayoutOK, "\(choice.label): an integer RGBA layout, not a float conversion")
            #expect(image.colorSpace?.name == CGColorSpace.sRGB, "\(choice.label): sRGB, as the layer pipeline expects")
            // Every pixel opaque: a developed frame has no transparency, whatever layout flag the decoder used.
            let opaque = try isFullyOpaque(image)
            #expect(opaque, "\(choice.label): alpha is fully opaque")
            print("[M12.5] 16-bit at \(choice.label): bpc \(image.bitsPerComponent) bpp \(image.bitsPerPixel) "
                  + "alpha \(image.alphaInfo.rawValue) opaque \(opaque)")
        }
    }

    /// Whether every pixel's alpha is at full scale. Read through Core Image into a 16-bit buffer rather than through
    /// `BrushRaster.copy`, which deliberately produces an 8-bit copy for painting.
    private func isFullyOpaque(_ image: CGImage) throws -> Bool {
        guard image.bitsPerComponent == 16 else { return false }
        let width = image.width, height = image.height
        var wide = [UInt16](repeating: 0, count: width * height * 4)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        wide.withUnsafeMutableBytes { buffer in
            context.render(CIImage(cgImage: image), toBitmap: buffer.baseAddress!, rowBytes: width * 8,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA16,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        for index in stride(from: 3, to: wide.count, by: 4) where wide[index] != UInt16.max { return false }
        return true
    }

    /// Save → reopen → re-edit keeps the decoder, and the adjustments it could not apply.
    @Test(.enabled(if: RawDecoderFixtures.dng != nil, "the untracked Ricoh GR III DNG is absent"))
    func raw9ChoiceSurvivesProjectRoundTrip() throws {
        let url = try #require(dng)
        var settings = try #require(RawImporter.asShot(url, decoder: .appleRAW9))
        settings.exposure = 0.4
        settings.colorNoiseReduction = 0.55   // cannot be applied under RAW 9, and must not be lost
        settings.rawDetail = RawDetailSettings(enabled: true, detail: 0.3, sharpness: 0.05, contrast: 0.1, moire: 0.2)

        let source = RawSourceAsset(
            rawData: try Data(contentsOf: url), fileExtension: "dng", utType: "com.adobe.raw-image",
            pixelWidth: 6000, pixelHeight: 4000,
            asShotSettings: settings, supportsNoiseReduction: settings.supportsNoiseReduction)
        let state = RawDevelopmentPersistentState(
            source: source, settings: RawDevelopmentSettingsPersistentState(settings),
            developedWidth: 6000, developedHeight: 4000, developedColorSpace: "extendedLinearSRGB",
            developedBitsPerComponent: 16)

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(RawDevelopmentPersistentState.self, from: encoded)
        #expect(decoded.settings.selectedDecoder == .appleRAW9, "the decoder survives the round trip")
        #expect(decoded.settings.effectiveDecoderVersion == "9")
        #expect(decoded.source.rawData.count == source.rawData.count, "the original bytes are unchanged")

        let live = decoded.settings.makeSettings()
        #expect(live.decoder == .appleRAW9)
        #expect(live.exposure == 0.4)
        #expect(live.colorNoiseReduction == 0.55, "an adjustment RAW 9 cannot apply is still kept")
        #expect(live.rawDetail.detail == 0.3 && live.rawDetail.moire == 0.2)
        #expect(!live.supportsColorNoiseReduction && !live.supportsDetail && !live.supportsMoire,
                "and the reopened project does not claim controls its decoder lacks")
    }

    // MARK: - The CR2 that does not support RAW 9

    /// The Canon CR2 lists `6` and `7` only, and asking for v9 leaves v7 in place without an error. That is the case
    /// the production code must refuse rather than display as RAW 9.
    @Test(.enabled(if: RawDecoderFixtures.cr2 != nil, "the untracked Canon RAW fixture is absent"))
    func cr2RefusesRaw9RatherThanFallingBack() throws {
        let url = try #require(cr2)
        let filter = try #require(CIRAWFilter(imageURL: url))
        let supported = filter.supportedDecoderVersions.map(\.rawValue)
        #expect(!RawDecoderSelection.offersRaw9(supported: supported),
                "this CR2 does not list RAW 9: \(supported)")

        // Assign it anyway: the API keeps the previous version and reports no error.
        filter.decoderVersion = .init(rawValue: "9")
        let effective = filter.decoderVersion.rawValue
        #expect(effective != "9", "the request did not take (\(effective))")
        #expect(!RawDecoderSelection.verdict(requested: "9", supported: supported,
                                            effective: effective).isApplied,
                "and the verdict refuses it, which is what the UI reads")

        // Through the production probe: not offered, and the reason names the problem.
        #expect(!RawImporter.availableDecoders(at: url).contains(.appleRAW9))
        if case let .notOffered(reason) = RawImporter.availability(of: .appleRAW9, at: url) {
            #expect(!reason.isEmpty, "the refusal explains itself")
            print("[M12.5] CR2 RAW 9 refused: \(reason)")
        } else {
            Issue.record("RAW 9 should be reported as not offered for the CR2")
        }
        #expect(RawImporter.asShot(url, decoder: .appleRAW9) == nil, "no state is invented from a decoder it lacks")
    }

    /// The CR2 develops as it always did: System Default is its own decoder, and nothing about it changed.
    @Test(.enabled(if: RawDecoderFixtures.cr2 != nil, "the untracked Canon RAW fixture is absent"))
    func cr2SystemDefaultIsUnchanged() throws {
        let url = try #require(cr2)
        let filter = try #require(CIRAWFilter(imageURL: url))
        let defaultVersion = filter.decoderVersion.rawValue
        let settings = try #require(RawImporter.asShot(url))
        #expect(settings.decoder == .systemDefault)
        #expect(settings.supportsColorNoiseReduction, "the CR2 keeps every control it always had")
        #expect(settings.supportsDetail && settings.supportsMoire)
        #expect(settings.unavailableRawDetailControls.isEmpty)
        let image = try #require(try RawImporter.develop(url, settings: settings, limit: 800))
        #expect(image.width > 0 && image.height > 0)
        print("[M12.5] CR2 system default: version \(defaultVersion), developed \(image.width)x\(image.height)")
    }

    /// A RAW 9 project reopened on a host that cannot decode RAW 9 must not be silently redeveloped. The request is
    /// refused, which is what the re-edit path reports instead of rendering with another decoder.
    @Test(.enabled(if: RawDecoderFixtures.cr2 != nil, "the untracked Canon RAW fixture is absent"))
    func unhonouredRequestIsAnErrorNotASilentRedevelop() throws {
        let url = try #require(cr2)
        var settings = try #require(RawImporter.asShot(url))
        settings.decoder = .appleRAW9
        #expect(throws: (any Error).self) {
            _ = try RawImporter.develop(url, settings: settings, limit: 400)
        }
    }

    // MARK: - Preview cache and the switching sequence

    /// The preview cache is keyed by decoder as well as by file and size, so a switch rebuilds the filter rather than
    /// reusing one that still holds the previous version. This is what stops stale preview pixels — and stale support
    /// flags — after a decoder change.
    @Test(.enabled(if: RawDecoderFixtures.dng != nil, "the untracked Ricoh GR III DNG is absent"))
    func previewCacheIsKeyedByDecoder() async throws {
        let url = try #require(dng)
        let queue = RawImporter.Queue()
        let system = try #require(RawImporter.asShot(url))
        let v9 = try #require(RawImporter.asShot(url, decoder: .appleRAW9))
        let limit: CGFloat = 400

        _ = try await queue.develop(url, settings: system, limit: limit)
        #expect(await queue.isCached(url, limit: limit, decoder: .systemDefault))
        #expect(!(await queue.isCached(url, limit: limit, decoder: .appleRAW9)),
                "a filter built for the system decoder is not the RAW 9 one")

        _ = try await queue.develop(url, settings: v9, limit: limit)
        #expect(await queue.isCached(url, limit: limit, decoder: .appleRAW9),
                "switching rebuilds the filter for the new decoder")
        #expect(!(await queue.isCached(url, limit: limit, decoder: .systemDefault)),
                "and the old filter is not kept, so it cannot be rendered with again")
        await queue.release()
    }

    /// The required switching sequence: System Default → RAW 9 → System Default → RAW 9. The final decoder, the
    /// support flags and the rendered pixels must all agree, with no stale state left from an earlier step.
    @Test(.enabled(if: RawDecoderFixtures.dng != nil, "the untracked Ricoh GR III DNG is absent"))
    func repeatedSwitchingEndsConsistent() async throws {
        let url = try #require(dng)
        let queue = RawImporter.Queue()
        let limit: CGFloat = 400

        var settings = try #require(RawImporter.asShot(url))
        // A value RAW 9 cannot apply, which must survive the whole sequence.
        settings.colorNoiseReduction = 0.6
        var lastImage: CGImage?

        for choice in [RawDecoderChoice.systemDefault, .appleRAW9, .systemDefault, .appleRAW9] {
            let capabilities = try #require(RawImporter.capabilities(at: url, decoder: choice),
                                            "\(choice.label) is available for this file")
            settings.decoder = choice
            RawImporter.applyCapabilities(capabilities, to: &settings)
            #expect(settings.decoder == choice)
            #expect(settings.effectiveDecoderVersion == capabilities.effectiveVersion)
            let image = try await queue.develop(url, settings: settings, limit: limit)
            #expect(image != nil, "\(choice.label) develops a preview")
            lastImage = image
        }

        // The last step was RAW 9, so the state describes RAW 9 and nothing else.
        #expect(settings.decoder == .appleRAW9)
        #expect(RawDecoderChoice.raw9EffectiveVersions.contains(settings.effectiveDecoderVersion),
                "the effective version is a RAW 9 spelling: \(settings.effectiveDecoderVersion)")
        #expect(!settings.supportsColorNoiseReduction && !settings.supportsDetail && !settings.supportsMoire)
        #expect(settings.supportsSharpness && settings.supportsContrast)
        #expect(settings.colorNoiseReduction == 0.6, "the amount survived four switches")
        #expect(await queue.isCached(url, limit: limit, decoder: .appleRAW9),
                "the kept filter is the RAW 9 one, not an earlier decoder's")

        // And the pixels are RAW 9's, not a stale frame from the step before: a fresh filter at v9 renders the same.
        let fresh = try #require(try RawImporter.develop(url, settings: settings, limit: limit))
        let cached = try #require(lastImage)
        #expect(try bytes(fresh) == bytes(cached), "the cached preview matches a fresh RAW 9 development")
        await queue.release()
    }

    // MARK: - Apply, undo, redo

    /// Apply → Undo through the session: the decoder and the adjustments it could not apply are part of history like
    /// everything else, so undo restores the previous development rather than leaving a RAW 9 label over old pixels.
    ///
    /// This stops at Undo deliberately. A 24 MP 16-bit frame is about 288 MB, over `DocumentHistory`'s 256 MB
    /// retained-byte budget, so the redo side of this Apply is trimmed and `canRedo` is false. That budget is a
    /// pre-existing property of the history, not of decoder selection, and is unchanged here; the decoder's own
    /// undo/redo behaviour is covered deterministically by `decoderChoiceSurvivesUndoAndRedo`, which does not need a
    /// full-resolution frame to prove it.
    @Test(.enabled(if: RawDecoderFixtures.dng != nil, "the untracked Ricoh GR III DNG is absent"))
    func applyUndoRestoresThePreviousDecoder() async throws {
        let url = try #require(dng)
        let bytes = try Data(contentsOf: url)
        let session = EditorSession()
        session.createDocument(width: 600, height: 400)
        session.confirmRawDevelop = { _, settings in settings }

        var asShot = try #require(RawImporter.asShot(url))
        asShot.colorNoiseReduction = 0.6
        let source = RawSourceAsset(
            rawData: bytes, fileExtension: "dng", utType: "com.adobe.raw-image",
            pixelWidth: 6000, pixelHeight: 4000, asShotSettings: asShot)
        var layer = ImageLayer(name: "RAW 9 Layer", blankSize: CGSize(width: 600, height: 400))
        layer.rawDevelopment = RawDevelopmentPersistentState(
            source: source, settings: RawDevelopmentSettingsPersistentState(asShot),
            developedWidth: 6000, developedHeight: 4000, developedColorSpace: "extendedLinearSRGB",
            developedBitsPerComponent: 16)
        session.document?.layers.append(layer)
        session.activeLayerID = layer.id

        // Switch to RAW 9 as an edit, then Apply.
        _ = session.beginRawDevelopmentEdit(layerID: layer.id)
        #expect(session.switchRawDevelopmentDecoder(layerID: layer.id, to: .appleRAW9) == nil,
                "RAW 9 applies to this file")
        #expect(session.rawDrafts[layer.id]?.settings.decoder == RawDecoderChoice.appleRAW9.rawValue)
        #expect(session.rawDrafts[layer.id]?.settings.colorNoiseReduction == 0.6,
                "the switch kept the adjustment it cannot apply")
        #expect(try await session.applyRawDevelopmentEdit(layerID: layer.id), "Apply succeeds")

        let applied = try #require(session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment)
        #expect(applied.settings.selectedDecoder == .appleRAW9, "the committed project records RAW 9")
        #expect(applied.settings.makeSettings().colorNoiseReduction == 0.6)

        // Undo the Apply: the layer goes back to its earlier development, not to a RAW 9 label over old pixels.
        #expect(session.canUndo, "the Apply is undoable")
        session.undo()
        let undone = try #require(session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment)
        #expect(undone.settings.selectedDecoder == .systemDefault, "Undo restored the previous decoder")
        #expect(undone.settings.makeSettings().colorNoiseReduction == 0.6)
        print("[M12.5] Apply/Undo: decoder \(applied.settings.selectedDecoder.label) → "
              + "\(undone.settings.selectedDecoder.label)")
    }

    /// Re-editing a committed RAW 9 layer starts from its saved decoder rather than the system default, so opening the
    /// sheet on a RAW 9 frame does not silently show it developed another way.
    @Test(.enabled(if: RawDecoderFixtures.dng != nil, "the untracked Ricoh GR III DNG is absent"))
    func reEditingStartsFromTheSavedDecoder() throws {
        let url = try #require(dng)
        let bytes = try Data(contentsOf: url)
        let session = EditorSession()
        session.createDocument(width: 600, height: 400)

        var v9 = try #require(RawImporter.asShot(url, decoder: .appleRAW9))
        v9.exposure = 0.3
        v9.colorNoiseReduction = 0.4
        let source = RawSourceAsset(
            rawData: bytes, fileExtension: "dng", utType: "com.adobe.raw-image",
            pixelWidth: 6000, pixelHeight: 4000, asShotSettings: v9)
        var layer = ImageLayer(name: "Re-edit", blankSize: CGSize(width: 600, height: 400))
        layer.rawDevelopment = RawDevelopmentPersistentState(
            source: source, settings: RawDevelopmentSettingsPersistentState(v9),
            developedWidth: 6000, developedHeight: 4000, developedColorSpace: "extendedLinearSRGB",
            developedBitsPerComponent: 16)
        session.document?.layers.append(layer)
        session.activeLayerID = layer.id

        let draft = try #require(session.beginRawDevelopmentEdit(layerID: layer.id))
        #expect(draft.settings.selectedDecoder == .appleRAW9, "re-edit opens on the decoder it was saved with")
        #expect(draft.settings.effectiveDecoderVersion == "9")
        #expect(draft.settings.makeSettings().exposure == 0.3)
        #expect(!draft.settings.makeSettings().supportsColorNoiseReduction,
                "and does not claim controls RAW 9 lacks")
    }

    /// An adjustment made while RAW 9 is selected is kept when switching back to System Default, and the render picks
    /// the value up again — the retention requirement, measured through the real session rather than a struct copy.
    @Test(.enabled(if: RawDecoderFixtures.dng != nil, "the untracked Ricoh GR III DNG is absent"))
    func valuesSurviveASwitchThroughTheSession() throws {
        let url = try #require(dng)
        let bytes = try Data(contentsOf: url)
        let session = EditorSession()
        session.createDocument(width: 600, height: 400)
        let asShot = try #require(RawImporter.asShot(url))
        let source = RawSourceAsset(
            rawData: bytes, fileExtension: "dng", utType: "com.adobe.raw-image",
            pixelWidth: 6000, pixelHeight: 4000, asShotSettings: asShot)
        var layer = ImageLayer(name: "Values", blankSize: CGSize(width: 600, height: 400))
        layer.rawDevelopment = RawDevelopmentPersistentState(
            source: source, settings: RawDevelopmentSettingsPersistentState(asShot),
            developedWidth: 6000, developedHeight: 4000, developedColorSpace: "extendedLinearSRGB",
            developedBitsPerComponent: 16)
        session.document?.layers.append(layer)
        session.activeLayerID = layer.id
        _ = session.beginRawDevelopmentEdit(layerID: layer.id)

        // A Color Noise amount and a Raw Details pair, all set under the system decoder.
        #expect(session.updateRawDevelopmentSettings(layerID: layer.id, colorNoiseReduction: 0.7))
        #expect(session.updateRawDevelopmentSettings(
            layerID: layer.id,
            rawDetail: RawDetailSettings(enabled: true, detail: 0.4, sharpness: 0.15, contrast: 0, moire: 0.25)))

        #expect(session.switchRawDevelopmentDecoder(layerID: layer.id, to: .appleRAW9) == nil)
        var draft = try #require(session.rawDrafts[layer.id]).settings.makeSettings()
        #expect(draft.colorNoiseReduction == 0.7)
        #expect(draft.rawDetail.detail == 0.4 && draft.rawDetail.moire == 0.25)
        #expect(!draft.supportsColorNoiseReduction && !draft.supportsDetail && !draft.supportsMoire)
        #expect(draft.effectiveRawDetail.detail == 0 && draft.effectiveRawDetail.moire == 0,
                "an unsupported offset is not sent to the filter")
        #expect(draft.effectiveRawDetail.sharpness == 0.15, "the supported one is")

        #expect(session.switchRawDevelopmentDecoder(layerID: layer.id, to: .systemDefault) == nil)
        draft = try #require(session.rawDrafts[layer.id]).settings.makeSettings()
        #expect(draft.supportsColorNoiseReduction && draft.supportsDetail && draft.supportsMoire,
                "switching back restores the controls")
        #expect(draft.colorNoiseReduction == 0.7 && draft.rawDetail.detail == 0.4 && draft.rawDetail.moire == 0.25,
                "and every value with them")
        #expect(draft.effectiveRawDetail == draft.rawDetail, "every offset is applied again")
    }

    // MARK: - Measurements

    /// The fraction of pixels whose any channel differs between two developed frames of the same size.
    private func fractionDiffering(_ a: CGImage, _ b: CGImage) throws -> Double {
        let left = try bytes(a), right = try bytes(b)
        guard left.count == right.count, !left.isEmpty else { return 0 }
        var differing = 0
        for pixel in stride(from: 0, to: left.count / 4, by: 1) {
            let i = pixel * 4
            if left[i] != right[i] || left[i + 1] != right[i + 1] || left[i + 2] != right[i + 2] {
                differing += 1
            }
        }
        return Double(differing) / Double(left.count / 4)
    }

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        let copy = try BrushRaster.copy(image)
        let pointer = try #require(copy.data).assumingMemoryBound(to: UInt8.self)
        let rowBytes = copy.bytesPerRow
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let from = y * rowBytes + x * 4, to = (y * image.width + x) * 4
                out[to] = pointer[from]
                out[to + 1] = pointer[from + 1]
                out[to + 2] = pointer[from + 2]
                out[to + 3] = pointer[from + 3]
            }
        }
        return out
    }
}

/// Where the untracked RAW fixtures are, if this checkout has them. Both are Git-ignored: they are someone's
/// photographs, not test data that can ship.
nonisolated enum RawDecoderFixtures {
    /// The Ricoh GR III DNG copied into the ignored work folder, or wherever the geometry fixtures keep photographs.
    static var dng: URL? {
        let roots = [
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("work/camera-raw-parity/fixtures/Ricoh-GR-III.DNG"),
        ]
        for url in roots where FileManager.default.fileExists(atPath: url.path) { return url }
        return GeometryValidationFixtures.rootContaining("originals/Ricoh-GR-III.DNG")
            .map { $0.appendingPathComponent("originals/Ricoh-GR-III.DNG") }
    }

    static var cr2: URL? {
        GeometryValidationFixtures.rootContaining("originals/sigma-40art-sample.CR2")
            .map { $0.appendingPathComponent("originals/sigma-40art-sample.CR2") }
    }
}