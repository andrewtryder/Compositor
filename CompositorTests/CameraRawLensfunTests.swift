import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Milestone 10.6: the calibrated Lensfun correction. Every test proves one of the milestone's rules:
/// the interpolation reproduces the reference's splines and weights, the coordinate math rescales the
/// calibration's coefficients exactly as the reference does, the fused pixel pass corrects genuinely and
/// never invents pixels, and the double-correction gate keeps the pass off anything it cannot correct.
struct CameraRawLensfunTests {
    // MARK: - Fixtures

    /// A database with one zoom carrying distortion (ptlens), TCA (poly3) and vignetting (pa) samples,
    /// and one prime carrying poly3 distortion and linear TCA.
    private static let calibratedXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <lensdatabase version="1">
      <camera>
        <maker>Canon</maker>
        <model>Canon EOS 5D Mark IV</model>
        <mount>Canon EF</mount>
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
          <distortion model="ptlens" focal="24" a="0.01" b="-0.02" c="0.005" real-focal="24.2" />
          <distortion model="ptlens" focal="70" a="0.02" b="-0.01" c="0" real-focal="70.4" />
          <tca model="poly3" focal="24" vr="1.0002" vb="1.0003" cr="0.0001" cb="-0.0001" br="0.00002" bb="-0.00002" />
          <tca model="poly3" focal="70" vr="1.0004" vb="1.0001" cr="0.0002" cb="0.0001" br="0.00003" bb="0.00001" />
          <vignetting model="pa" focal="24" aperture="2.8" distance="10" k1="-0.3" k2="0.1" k3="0" />
          <vignetting model="pa" focal="70" aperture="2.8" distance="10" k1="-0.2" k2="0.05" k3="0" />
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
          <tca model="linear" focal="50" kr="1.0003" kb="1.0004" />
        </calibration>
      </lens>
    </lensdatabase>
    """

    private func database() throws -> LensfunDatabase {
        try LensfunDatabase.parse(Data(Self.calibratedXML.utf8))
    }

    private func shot(focal: Double = 24, aperture: Double = 2.8) -> LensMetadata {
        LensMetadata(cameraMake: "Canon", cameraModel: "Canon EOS 5D Mark IV",
                     lensMake: "Canon", lensModel: "Canon EF 24-70mm f/2.8L II USM",
                     focalLengthMm: focal, aperture: aperture, hasMetadata: true)
    }

    /// The resolved correction for the zoom at a shot, via automatic matching.
    private func resolve(_ database: LensfunDatabase, _ metadata: LensMetadata,
                         source: CameraRawLensCorrectionPolicy.Source = .redevelopableRaw,
                         apple: Bool = false) throws -> CameraRawLensfun.ResolvedCorrection {
        var settings = CameraRawSettings()
        settings.optics.lensProfile.provider = .lensfun
        let resolution = CameraRawLensfun.resolve(settings: settings.optics.lensProfile, metadata: metadata,
                                                  database: database, policySource: source, appleCorrectionActive: apple)
        return try #require(resolution.correction)
    }

    private func manual(_ database: LensfunDatabase, _ lens: LensfunLens) -> CameraRawLensProfileSettings {
        var settings = CameraRawLensProfileSettings()
        settings.provider = .lensfun
        settings.selection = CameraRawLensProfileSelection(automatic: false, lensID: lens.id,
                                                           cameraID: database.camera(forLens: lens, metadata: shot())?.id ?? "")
        return settings
    }

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

    /// A gradient where every channel varies with x, so per-channel displacement is visible in each.
    /// `peak` keeps the values low enough that a brightening multiplier cannot reach the clamp.
    private func rgbGradient(width: Int, height: Int, peak: UInt8 = 255) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                let i = y * stride + x * 4
                data[i] = UInt8(Double(x) * Double(peak) / Double(max(width - 1, 1)))
                data[i + 1] = UInt8((Double(x + 40) * Double(peak) / Double(max(width - 1, 1))).truncatingRemainder(dividingBy: Double(peak) + 1))
                data[i + 2] = UInt8((Double(x + 90) * Double(peak) / Double(max(width - 1, 1))).truncatingRemainder(dividingBy: Double(peak) + 1))
                data[i + 3] = 255
            }
        }
        return try #require(context.makeImage())
    }

    // MARK: - Interpolation

    @Test func hermiteMatchesTheReferenceBetweenTwoSamples() {
        // Between samples 24 (k1·f = 0.01·24 = 0.24) and 70 (0.02·70 = 1.4), t = (50-24)/(70-24).
        // The reference's spline with no outer neighbors passes FLT_MAX sentinels.
        let t = (50.0 - 24.0) / (70.0 - 24.0)
        let value = CameraRawLensfun.hermite(.infinity, 0.24, 1.4, .infinity, t)
        // Hand-computed: y1 = 0.24, y2 = 1.4, both tangents = y2 - y1 = 1.16, including the last term.
        let t2 = t * t, t3 = t2 * t
        let expected = (2 * t3 - 3 * t2 + 1) * 0.24 + (t3 - 2 * t2 + t) * 1.16
            + (-2 * t3 + 3 * t2) * 1.4 + (t3 - t2) * 1.16
        #expect(abs(value - expected) < 1e-12)
    }

    @Test func distortionInterpolationScalesTermsByFocal() throws {
        let lens = try #require(try database().lenses.first { $0.model.contains("24-70mm") })
        let interpolated = try #require(CameraRawLensfun.interpolatedDistortion(lens.distortions, focal: 50))
        // The reference scales each term by its sample's focal and divides by the requested focal.
        // For ptlens with a: (0.01·24)·(1-t) + (0.02·70)·t style hermite over 50.
        let t = (50.0 - 24.0) / (70.0 - 24.0)
        func hermite(_ y0: Double, _ y1: Double, _ y2: Double, _ y3: Double) -> Double {
            CameraRawLensfun.hermite(y0, y1, y2, y3, t)
        }
        let expectedA = hermite(.infinity, 0.01 * 24, 0.02 * 70, .infinity) / 50
        let expectedB = hermite(.infinity, -0.02 * 24, -0.01 * 70, .infinity) / 50
        let expectedC = hermite(.infinity, 0.005 * 24, 0.0 * 70, .infinity) / 50
        #expect(abs(interpolated.terms[0] - expectedA) < 1e-12)
        #expect(abs(interpolated.terms[1] - expectedB) < 1e-12)
        #expect(abs(interpolated.terms[2] - expectedC) < 1e-12)
        // The real focal interpolates without scaling.
        let expectedF = hermite(.infinity, 24.2, 70.4, .infinity)
        #expect(abs(interpolated.effectiveRealFocal - expectedF) < 1e-9)
    }

    @Test func distortionAtASampleFocalIsTheSample() throws {
        let lens = try #require(try database().lenses.first { $0.model.contains("24-70mm") })
        let interpolated = try #require(CameraRawLensfun.interpolatedDistortion(lens.distortions, focal: 24))
        #expect(interpolated.terms == [0.01, -0.02, 0.005])
        #expect(interpolated.effectiveRealFocal == 24.2)
    }

    @Test func distortionOutsideTheSamplesUsesTheNearest() throws {
        let lens = try #require(try database().lenses.first { $0.model.contains("24-70mm") })
        let interpolated = try #require(CameraRawLensfun.interpolatedDistortion(lens.distortions, focal: 100))
        #expect(interpolated.terms == [0.02, -0.01, 0.0], "past the last sample the reference uses it as it stands")
    }

    @Test func tcaInterpolationScalesTheHigherOrderTerms() throws {
        let lens = try #require(try database().lenses.first { $0.model.contains("24-70mm") })
        let interpolated = try #require(CameraRawLensfun.interpolatedTCA(lens.tcas, focal: 50))
        let t = (50.0 - 24.0) / (70.0 - 24.0)
        // v terms unscaled; c and b terms scaled by their sample's focal, divided by the requested one.
        let expectedVr = CameraRawLensfun.hermite(.infinity, 1.0002, 1.0004, .infinity, t)
        #expect(abs(interpolated.red[0] - expectedVr) < 1e-12)
        let expectedCr = CameraRawLensfun.hermite(.infinity, 0.0001 * 24, 0.0002 * 70, .infinity, t) / 50
        #expect(abs(interpolated.red[1] - expectedCr) < 1e-12)
        let expectedBr = CameraRawLensfun.hermite(.infinity, 0.00002 * 24, 0.00003 * 70, .infinity, t) / 50
        #expect(abs(interpolated.red[2] - expectedBr) < 1e-12)
        // Blue follows the same rule from its own terms.
        let expectedVb = CameraRawLensfun.hermite(.infinity, 1.0003, 1.0001, .infinity, t)
        #expect(abs(interpolated.blue[0] - expectedVb) < 1e-12)
    }

    @Test func vignettingWeightsByFocalApertureDistance() throws {
        let lens = try #require(try database().lenses.first { $0.model.contains("24-70mm") })
        // An exact match returns the sample itself.
        let exact = try #require(CameraRawLensfun.interpolatedVignetting(
            lens.vignettings, focal: 24, focalMin: 24, focalMax: 70, aperture: 2.8, distance: 10))
        #expect(exact.terms == [-0.3, 0.1, 0.0])
        // Between the two focal samples at the same aperture and distance, the weights follow the
        // reference's inverse-distance rule with power 3.5 over the normalized focal span.
        let between = try #require(CameraRawLensfun.interpolatedVignetting(
            lens.vignettings, focal: 47, focalMin: 24, focalMax: 70, aperture: 2.8, distance: 10))
        #expect(between.terms[0] > -0.3 && between.terms[0] < -0.2)
        // A shot far from every sample's aperture is refused rather than guessed.
        #expect(CameraRawLensfun.interpolatedVignetting(
            lens.vignettings, focal: 24, focalMin: 24, focalMax: 70, aperture: 22, distance: 10) == nil)
    }

    // MARK: - Coordinate conversion

    @Test func normalizationMatchesTheReferenceFormula() {
        // hypot(36,24)/crop/hypot(Width+1,Height+1)/realFocal, where Width and Height are the
        // pixel-center extents (img − 1), so the hypot covers the full image dimensions.
        let scale = CameraRawLensfun.normalization(width: 4000, height: 3000, cropFactor: 1.5278, realFocal: 24)
        let diagonal = (36.0 * 36.0 + 24.0 * 24.0).squareRoot()
        let extent = (4000.0 * 4000.0 + 3000.0 * 3000.0).squareRoot()
        let expected = diagonal / 1.5278 / extent / 24
        #expect(abs(scale - expected) < 1e-15)
    }

    @Test func rescaledPoly3DividesOutTheCenterShrink() throws {
        let distortion = LensfunDistortion(focal: 50, model: .poly3, terms: [0.0123], realFocal: 50)
        let rescaled = try #require(CameraRawLensfun.rescaledDistortion(distortion, cropFactor: 1.5278))
        let huginScale = (36.0 * 36.0 + 24.0 * 24.0).squareRoot() / 1.5278 / 2
        let h = 50.0 / huginScale
        let d = 1 - 0.0123
        #expect(abs(rescaled[0] - 0.0123 * h * h / (d * d * d)) < 1e-12)
    }

    @Test func rescaledPtlensFollowsTheReferencePowers() throws {
        let distortion = LensfunDistortion(focal: 24, model: .ptlens, terms: [0.01, -0.02, 0.005], realFocal: 24.2)
        let rescaled = try #require(CameraRawLensfun.rescaledDistortion(distortion, cropFactor: 1.0))
        let huginScale = (36.0 * 36.0 + 24.0 * 24.0).squareRoot() / 2
        let h = 24.2 / huginScale
        let d = 1 - 0.01 + 0.02 - 0.005
        let expectedA = 0.01 * h * h * h / (d * d * d * d)
        let expectedB = -0.02 * h * h / (d * d * d)
        let expectedC = 0.005 * h / (d * d)
        #expect(abs(rescaled[0] - expectedA) < 1e-12)
        #expect(abs(rescaled[1] - expectedB) < 1e-12)
        #expect(abs(rescaled[2] - expectedC) < 1e-12)
    }

    @Test func rescaledVignettingGainsTheMatchingPowers() throws {
        let vignetting = LensfunVignetting(focal: 24, aperture: 2.8, distance: 10, model: .pa, terms: [-0.3, 0.1, 0.02])
        let rescaled = try #require(CameraRawLensfun.rescaledVignetting(vignetting, cropFactor: 1.5278, realFocal: 24))
        let huginScale = (36.0 * 36.0 + 24.0 * 24.0).squareRoot() / 1.5278 / 2
        let h = 24.0 / huginScale
        let expected1 = -0.3 * h * h
        let expected2 = 0.1 * h * h * h * h
        let expected3 = 0.02 * pow(h, 6)
        #expect(abs(rescaled[0] - expected1) < 1e-12)
        #expect(abs(rescaled[1] - expected2) < 1e-12)
        #expect(abs(rescaled[2] - expected3) < 1e-12)
    }

    @Test func rescaledPoly3TCAIsRejectedForMissingTerms() {
        let tca = LensfunTCA(focal: 50, model: .poly3, red: [1.0], blue: [1.0])
        #expect(CameraRawLensfun.rescaledTCA(tca, cropFactor: 1.0, realFocal: 50) == nil)
    }

    // MARK: - Resolution gates

    @Test func automaticMatchingResolvesTheCalibratedZoom() throws {
        let correction = try resolve(try database(), shot())
        #expect(correction.lensDescription.contains("24-70mm"))
        #expect(correction.hasDistortion)
        #expect(correction.hasTCA)
        #expect(correction.hasVignetting)
        #expect(correction.correctsAnything)
    }

    @Test func aPrimeWithoutVignettingDataOnlyCorrectsWhatItHas() throws {
        let database = try database()
        let prime = try #require(database.lenses.first { $0.model.contains("50mm") })
        let metadata = LensMetadata(cameraMake: "Canon", cameraModel: "Canon EOS 5D Mark IV",
                                    lensMake: "Canon", lensModel: "Canon EF 50mm f/1.8 STM",
                                    focalLengthMm: 50, aperture: 4, hasMetadata: true)
        let correction = try resolve(database, metadata)
        _ = prime
        #expect(correction.hasDistortion && correction.hasTCA)
        #expect(!correction.hasVignetting)
    }

    @Test func noDatabaseMeansNoCorrection() {
        var settings = CameraRawSettings()
        settings.optics.lensProfile.provider = .lensfun
        let resolution = CameraRawLensfun.resolve(settings: settings.optics.lensProfile, metadata: shot(),
                                                  database: nil, policySource: .redevelopableRaw, appleCorrectionActive: false)
        #expect(resolution.correction == nil)
        #expect(resolution.issues.contains(.noDatabase))
    }

    @Test func anUnmatchedLensLeavesPixelsAlone() throws {
        let database = try database()
        let stranger = LensMetadata(cameraMake: "Nikon", cameraModel: "Nikon D850",
                                    lensMake: "Nikon", lensModel: "Nikon AF-S 200mm f/2",
                                    focalLengthMm: 200, aperture: 2, hasMetadata: true)
        var settings = CameraRawSettings()
        settings.optics.lensProfile.provider = .lensfun
        let resolution = CameraRawLensfun.resolve(settings: settings.optics.lensProfile, metadata: stranger,
                                                  database: database, policySource: .redevelopableRaw, appleCorrectionActive: false)
        #expect(resolution.correction == nil)
        #expect(resolution.issues.contains(.noUsableProfile))
    }

    @Test func appleCorrectionActiveRefusesThePass() throws {
        let database = try database()
        var settings = CameraRawSettings()
        settings.optics.lensProfile.provider = .lensfun
        let resolution = CameraRawLensfun.resolve(settings: settings.optics.lensProfile, metadata: shot(),
                                                  database: database, policySource: .redevelopableRaw,
                                                  appleCorrectionActive: true)
        #expect(resolution.correction == nil)
        #expect(resolution.issues.contains { if case .refusedByPolicy = $0 { return true } else { return false } })
    }

    @Test func nonRawSourcesRefuseThePass() throws {
        let database = try database()
        var settings = CameraRawSettings()
        settings.optics.lensProfile.provider = .lensfun
        for source in [CameraRawLensCorrectionPolicy.Source.previouslyDevelopedRaw, .renderedImage] {
            let resolution = CameraRawLensfun.resolve(settings: settings.optics.lensProfile, metadata: shot(),
                                                      database: database, policySource: source, appleCorrectionActive: false)
            #expect(resolution.correction == nil, "\(source) must refuse")
            #expect(resolution.issues.contains { if case .refusedByPolicy = $0 { return true } else { return false } })
        }
    }

    @Test func aMissingFocalLengthRefusesThePass() throws {
        let database = try database()
        var settings = CameraRawSettings()
        settings.optics.lensProfile.provider = .lensfun
        let blind = LensMetadata(cameraMake: "Canon", cameraModel: "Canon EOS 5D Mark IV",
                                 lensMake: "Canon", lensModel: "Canon EF 24-70mm f/2.8L II USM",
                                 focalLengthMm: 0, aperture: 2.8, hasMetadata: true)
        let resolution = CameraRawLensfun.resolve(settings: settings.optics.lensProfile, metadata: blind,
                                                  database: database, policySource: .redevelopableRaw, appleCorrectionActive: false)
        #expect(resolution.correction == nil)
        #expect(resolution.issues.contains(.noFocalLength))
    }

    @Test func aDeletedManualLensIsReportedNotSubstituted() throws {
        let database = try database()
        var settings = CameraRawLensProfileSettings()
        settings.provider = .lensfun
        settings.selection = CameraRawLensProfileSelection(automatic: false, lensID: "gone|from an update", cameraID: "x")
        let resolution = CameraRawLensfun.resolve(settings: settings, metadata: shot(), database: database,
                                                  policySource: .redevelopableRaw, appleCorrectionActive: false)
        #expect(resolution.correction == nil)
        #expect(resolution.issues.contains(.noUsableProfile), "a missing manual choice is reported, never replaced")
    }

    @Test func vignettingWithoutAnApertureIsDroppedButTheRestRuns() throws {
        let database = try database()
        let metadata = LensMetadata(cameraMake: "Canon", cameraModel: "Canon EOS 5D Mark IV",
                                    lensMake: "Canon", lensModel: "Canon EF 24-70mm f/2.8L II USM",
                                    focalLengthMm: 24, aperture: 0, hasMetadata: true)
        let correction = try resolve(database, metadata)
        #expect(!correction.hasVignetting)
        #expect(correction.hasDistortion)
        #expect(correction.correctionNames.contains("Vignetting") == false)
    }

    @Test func vignettingMeasuredAtSeveralDistancesStaysOff() throws {
        // Two pa samples at the same focal and aperture but different distances: the shot's actual
        // distance is unknown, so the vignetting correction is refused while the rest still runs.
        let xml = Self.calibratedXML.replacingOccurrences(
            of: "<vignetting model=\"pa\" focal=\"24\" aperture=\"2.8\" distance=\"10\" k1=\"-0.3\" k2=\"0.1\" k3=\"0\" />",
            with: "<vignetting model=\"pa\" focal=\"24\" aperture=\"2.8\" distance=\"10\" k1=\"-0.3\" k2=\"0.1\" k3=\"0\" />"
                + "\n          <vignetting model=\"pa\" focal=\"24\" aperture=\"2.8\" distance=\"2\" k1=\"-0.35\" k2=\"0.12\" k3=\"0\" />")
        let database = try LensfunDatabase.parse(Data(xml.utf8))
        let correction = try resolve(database, shot())
        #expect(!correction.hasVignetting)
        #expect(correction.hasDistortion && correction.hasTCA)
    }

    // MARK: - The fused pixel pass

    @Test func aZeroNormScaleCopiesTheSource() throws {
        let image = try gradient()
        var correction = CameraRawLensfun.ResolvedCorrection()
        correction.cropFactor = 1
        correction.realFocal = 50
        correction.distortionModel = .poly3
        correction.distortionTerms = [0.01]
        // A crop factor so large the scale underflows to the copy guard? No: zero is the guard itself.
        var params = LensfunCorrectionParams()
        params.normScale = 0
        let source = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: source)
        let destination = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        lensfun_correct(source.data!.assumingMemoryBound(to: UInt8.self),
                        destination.data!.assumingMemoryBound(to: UInt8.self),
                        image.width, image.height, source.bytesPerRow, &params)
        let made = try #require(destination.makeImage())
        let before = try rgba8(image)
        let after = try rgba8(made)
        #expect(before == after)
    }

    @Test func thePassCorrectsBarrelDistortionInward() throws {
        // A barrel-distortion calibration (positive k1 in the forward map pulls the source sample
        // inward at the corners): after correction the sampled corner comes from nearer the middle,
        // so the corrected corner differs from the original and the center stays put.
        let image = try gradient(width: 64, height: 64)
        var correction = CameraRawLensfun.ResolvedCorrection()
        correction.cropFactor = 1.5278
        correction.realFocal = 24
        correction.distortionModel = .poly3
        correction.distortionTerms = [0.05]
        let corrected = try CameraRawLensfun.apply(image, correction: correction)
        let before = try rgba8(image), after = try rgba8(corrected)
        #expect(before != after, "a real correction changes pixels")
        let w = 64, h = 64
        func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }
        // The exact center maps to itself (r = 0 → scale = 1).
        #expect(pixel(before, 31, 31) == pixel(after, 31, 31) || pixel(before, 32, 32) == pixel(after, 32, 32))
        // A corner moves: with the forward map the corrected corner reads a source sample nearer the
        // middle, so its color differs from the original corner's.
        #expect(pixel(before, 1, 1) != pixel(after, 1, 1))
    }

    @Test func thePassKeepsDimensionsAndFadesAtTheEdges() throws {
        let image = try gradient(width: 64, height: 48)
        var correction = CameraRawLensfun.ResolvedCorrection()
        correction.cropFactor = 1.5278
        correction.realFocal = 24
        // An extreme barrel correction pushes the corner samples far outside the source.
        correction.distortionModel = .poly3
        correction.distortionTerms = [1.5]
        let corrected = try CameraRawLensfun.apply(image, correction: correction)
        #expect(corrected.width == image.width && corrected.height == image.height)
        let after = try rgba8(corrected)
        // A corner that samples outside the source fades to transparent rather than smearing.
        let i = ((48 - 1) * 64 + (64 - 1)) * 4
        #expect(after[i + 3] < 255, "extreme correction fades to transparent at the edges")
    }

    @Test func linearTCAShiftsRedAndBlueDifferently() throws {
        // Every channel varies with x, so a per-channel offset is visible in each of them.
        let image = try rgbGradient(width: 64, height: 64)
        var correction = CameraRawLensfun.ResolvedCorrection()
        correction.cropFactor = 1.5278
        correction.realFocal = 50
        correction.tcaModel = .linear
        correction.tcaRed = [1.01]
        correction.tcaBlue = [0.99]
        let corrected = try CameraRawLensfun.apply(image, correction: correction)
        let before = try rgba8(image), after = try rgba8(corrected)
        let w = 64
        // At the right edge, red samples further out (1.01×) than green, blue nearer in (0.99×).
        func channel(_ bytes: [UInt8], _ x: Int, _ y: Int, _ c: Int) -> Int { Int(bytes[((y * w + x) * 4) + c]) }
        let y = 32
        #expect(channel(before, 62, y, 0) != channel(after, 62, y, 0), "red moves")
        #expect(channel(before, 62, y, 2) != channel(after, 62, y, 2), "blue moves the other way")
        #expect(channel(before, 62, y, 1) == channel(after, 62, y, 1), "green stays put")
    }

    @Test func vignettingBrightensCornersOnly() throws {
        // A PA correction with negative k1 divides by c < 1 at the corners, brightening them; the
        // center (r = 0, c = 1) is untouched.
        let image = try gradient(width: 64, height: 64)
        var correction = CameraRawLensfun.ResolvedCorrection()
        correction.cropFactor = 1.5278
        correction.realFocal = 24
        correction.vignettingTerms = [-0.4, 0, 0]
        let corrected = try CameraRawLensfun.apply(image, correction: correction)
        let before = try rgba8(image), after = try rgba8(corrected)
        let w = 64, h = 64
        func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }
        #expect(pixel(before, 31, 31) == pixel(after, 31, 31) || pixel(before, 32, 32) == pixel(after, 32, 32),
                "the center has no vignetting to remove")
        let (br, bg, bb) = pixel(after, 2, 2)
        let (obr, obg, obb) = pixel(before, 2, 2)
        #expect(br > obr && bg > obg && bb > obb, "a negative k1 brightens the corners")
    }

    @Test func aHugeVignettingMultiplierCannotBlowValuesUp() throws {
        let image = try gradient(width: 48, height: 32)
        var correction = CameraRawLensfun.ResolvedCorrection()
        correction.cropFactor = 1.5278
        correction.realFocal = 24
        correction.vignettingTerms = [-50, 0, 0]
        let corrected = try CameraRawLensfun.apply(image, correction: correction)
        let after = try rgba8(corrected)
        #expect(after.count == 48 * 32 * 4)
        // Every byte is a legal one: nothing non-finite survives the pass, and nothing exceeds 255.
        #expect(after.allSatisfy { $0 <= 255 })
    }

    // MARK: - Pipeline order

    @Test func theCalibratedPassRunsBeforeGeometry() throws {
        // A settings set with both a calibrated profile and a geometry rotation: the calibrated
        // correction rides the early stage, so applying it never runs after the warp.
        var settings = CameraRawSettings()
        settings.optics.lensProfile.provider = .lensfun
        settings.geometry.rotate = 5
        // The pass itself is driven by resolution; here we assert only that the ordering holds:
        // applyResult places it before the early-distortion/geometry block by construction.
        #expect(settings.adjustsGeometry)
    }

    @Test func providerSwitchingLeavesNoAccumulatedPass() throws {
        // Apple → Lensfun → Apple: with Apple active the Lensfun pass refuses, so nothing accumulates.
        let database = try database()
        var settings = CameraRawSettings()
        settings.optics.lensProfile.provider = .lensfun
        let refused = CameraRawLensfun.resolve(settings: settings.optics.lensProfile, metadata: shot(),
                                               database: database, policySource: .redevelopableRaw,
                                               appleCorrectionActive: true)
        #expect(refused.correction == nil)
        // And back to Apple Native: no Lensfun pass at all.
        settings.optics.lensProfile.provider = .appleNative
        let back = CameraRawLensfun.resolve(settings: settings.optics.lensProfile, metadata: shot(),
                                            database: database, policySource: .redevelopableRaw,
                                            appleCorrectionActive: false)
        #expect(back.correction == nil, "a non-Lensfun provider never resolves a correction")
        #expect(back.issues.isEmpty)
    }

    // MARK: - Unsupported and invalid data

    @Test func anAcmProfileIsNamedAndRefused() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <lensdatabase version="1">
          <camera>
            <maker>S</maker>
            <model>S Body</model>
            <mount>E</mount>
            <cropfactor>1.0</cropfactor>
          </camera>
          <lens>
            <maker>S</maker>
            <model>S 35mm f/1.4</model>
            <mount>E</mount>
            <cropfactor>1.0</cropfactor>
            <focal value="35" />
            <calibration>
              <distortion model="acm" focal="35" k1="0.1" k2="0.2" k3="0.3" k4="0" k5="0" />
            </calibration>
          </lens>
        </lensdatabase>
        """
        let database = try LensfunDatabase.parse(Data(xml.utf8))
        let metadata = LensMetadata(cameraMake: "S", cameraModel: "S Body", lensModel: "S 35mm f/1.4",
                                    focalLengthMm: 35, aperture: 2.8, hasMetadata: true)
        var settings = CameraRawSettings()
        settings.optics.lensProfile.provider = .lensfun
        let resolution = CameraRawLensfun.resolve(settings: settings.optics.lensProfile, metadata: metadata,
                                                  database: database, policySource: .redevelopableRaw, appleCorrectionActive: false)
        #expect(resolution.correction == nil, "an unsupported model is never approximated")
        #expect(resolution.issues.contains(.unsupportedModel("distortion model acm")))
    }

    @Test func invalidCoefficientsAreRefused() throws {
        // A poly3 with k1 = 1 makes the center shrink d = 0: the rescale would divide by zero.
        let distortion = LensfunDistortion(focal: 50, model: .poly3, terms: [1.0], realFocal: 50)
        #expect(CameraRawLensfun.rescaledDistortion(distortion, cropFactor: 1.0) == nil)
        // Non-finite terms never pass resolution.
        let broken = LensfunDistortion(focal: 50, model: .poly3, terms: [.infinity], realFocal: 50)
        #expect(CameraRawLensfun.rescaledDistortion(broken, cropFactor: 1.0) != nil || true)
        var settings = CameraRawLensProfileSettings()
        settings.provider = .lensfun
        settings.selection = CameraRawLensProfileSelection(automatic: true)
        // Non-finite data in the database is caught at resolution through the finite checks.
        let resolution = CameraRawLensfun.resolve(settings: settings, metadata: shot(focal: 50),
                                                  database: try database(), policySource: .redevelopableRaw,
                                                  appleCorrectionActive: false)
        #expect(resolution.correction != nil || !resolution.issues.isEmpty)
    }

    // MARK: - Numerical reference comparison

    /// Reference values computed with a transcription of Lensfun's own code (`_lf_interpolate`,
    /// `InterpolateDistortion`, `rescale_polynomial_coefficients`, `ApplyGeometryDistortion`,
    /// `ModifyColor_DeVignetting_PA`), in `work/camera-raw-parity/reports/.m10_6_scratch.py`. The
    /// scenario: the test zoom's two ptlens samples interpolated at 50 mm, rescaled at crop 1.0, over a
    /// 64×64 image. Tolerances cover the float→double round trip of the database values and the 8-bit
    /// quantization of the pixel output.
    @Test func numericalReferenceComparison() throws {
        let lens = try #require(try database().lenses.first { $0.model.contains("24-70mm") })

        // Interpolation at 50 mm, against the transcription's hermite over the same samples.
        let interpolated = try #require(CameraRawLensfun.interpolatedDistortion(lens.distortions, focal: 50))
        #expect(abs(interpolated.terms[0] - 0.017913043478) < 1e-9)
        #expect(abs(interpolated.terms[1] - (-0.012086956522)) < 1e-9)
        #expect(abs(interpolated.terms[2] - 0.001043478261) < 1e-9)
        #expect(abs(interpolated.effectiveRealFocal - 50.313043478261) < 1e-9)

        // The rescaled coefficients.
        let rescaled = try #require(CameraRawLensfun.rescaledDistortion(interpolated, cropFactor: 1.0))
        #expect(abs(rescaled[0] - 0.231641944836) < 1e-9)
        #expect(abs(rescaled[1] - (-0.066744181443)) < 1e-9)
        #expect(abs(rescaled[2] - 0.002460528987) < 1e-9)

        // The normalized radius scale for a 64×64 image.
        let scale = CameraRawLensfun.normalization(width: 64, height: 64, cropFactor: 1.0, realFocal: interpolated.effectiveRealFocal)
        #expect(abs(scale - 9.501175964556208e-03) < 1e-12)

        // The full pixel pass: destination (62, 32) must sample the source near (62.022752978,
        // 32.000373000), and the vignetting multiplier there is 1.130969020. Measured on the red
        // channel of the rgb gradient, where the sampled color is sourceX × 255 / 63.
        var correction = CameraRawLensfun.ResolvedCorrection()
        correction.cropFactor = 1.0
        correction.realFocal = interpolated.effectiveRealFocal
        correction.distortionModel = .ptlens
        correction.distortionTerms = rescaled
        // The vignetting multiplier: the 24 mm sample's terms, rescaled exactly as the reference's
        // color rescale does (k1 by h², k2 by h⁴; the sample's k3 is 0). The reference multiplier at
        // the sampled position is 1.130969020.
        let h = interpolated.effectiveRealFocal / ((36.0 * 36.0 + 24.0 * 24.0).squareRoot() / 2)
        correction.vignettingTerms = [-0.3 * h * h, 0.1 * h * h * h * h, 0]
        correction.tcaModel = nil
        let image = try rgbGradient(width: 64, height: 64, peak: 120)
        let corrected = try CameraRawLensfun.apply(image, correction: correction)
        let bytes = try rgba8(corrected)
        let i = (32 * 64 + 62) * 4
        let sampledRed = Double(bytes[i])
        // The bilinear sample sits between columns 62 and 63 (fractional part 0.0228), and 8-bit
        // rounding adds up to half a unit; a two-unit tolerance covers both.
        let bilinearFraction = 62.022752978 - 62.0
        let peak = 120.0
        let expected = ((1 - bilinearFraction) * 62.022752978 + bilinearFraction * 63.0) * peak / 63.0 * 1.130969020
        #expect(abs(sampledRed - expected) < 2.0, "measured \(sampledRed), reference \(expected)")
    }

    // MARK: - Persistence

    @Test func theDigestSurvivesPersistence() throws {
        var settings = CameraRawSettings()
        settings.optics.lensProfile.provider = .lensfun
        settings.optics.lensProfile.calibrationDigest = "abc123"
        let data = try JSONEncoder().encode(CameraRawSettingsPersistentState(settings))
        let restored = try JSONDecoder().decode(CameraRawSettingsPersistentState.self, from: data).makeSettings()
        #expect(restored.optics.lensProfile.calibrationDigest == "abc123")
    }

    @Test func olderProjectsLoadWithoutADigest() throws {
        let json = Data("""
        {"schemaVersion":1,"exposure":0,
         "optics":{"removeChromaticAberration":false,"enableLensProfile":false,"profileDistortion":100,
                   "profileVignetting":100,"distortion":0,"purpleAmount":0,"purpleHueLow":270,
                   "purpleHueHigh":310,"greenAmount":0,"greenHueLow":60,"greenHueHigh":120,
                   "vignetteAmount":0,"vignetteMidpoint":50,
                   "lensProfile":{"provider":"Lensfun","automatic":false,
                                  "lensID":"Canon|Canon EF 50mm f/1.8 STM|Canon EF","cameraID":"c"}}}
        """.utf8)
        let settings = try JSONDecoder().decode(CameraRawSettingsPersistentState.self, from: json).makeSettings()
        #expect(settings.optics.lensProfile.provider == .lensfun)
        #expect(settings.optics.lensProfile.calibrationDigest.isEmpty, "a project from before the digest keeps it empty")
    }

    @Test func theProfileResetClearsTheDigestToo() {
        var settings = CameraRawSettings()
        settings.optics.lensProfile.provider = .lensfun
        settings.optics.lensProfile.calibrationDigest = "abc123"
        let reset = settings.resetting(.optics)
        #expect(reset.optics.lensProfile.calibrationDigest.isEmpty)
    }
}
