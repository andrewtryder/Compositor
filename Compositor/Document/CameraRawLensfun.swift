import CoreGraphics
import Foundation

/// The calibrated Lensfun correction: interpolation over a user-imported database's measurements, the
/// coordinate math that turns them into a pixel mapping, and the gate that decides whether the pass may
/// run at all. The equations follow Lensfun's documented calibration models (poly3, poly5, ptlens
/// distortion; linear and poly3 lateral chromatic aberration; the pa vignetting model); the engine
/// interpreting them is Compositor's own, so no Lensfun code is built, shipped or run.
///
/// Everything here is a pure function of its inputs. A missing attribute, an unsupported model or an
/// out-of-range value produces no correction rather than an approximate one.
nonisolated enum CameraRawLensfun {
    // MARK: - Focal-length interpolation

    /// Lensfun's four-point Hermite interpolation (`_lf_interpolate`): a cubic through the two bracketing
    /// samples, tangents from the neighbors when they exist and one-sided otherwise. `.infinity` marks "no
    /// sample this side", exactly as the reference's `FLT_MAX` does.
    static func hermite(_ y0: Double, _ y1: Double, _ y2: Double, _ y3: Double, _ t: Double) -> Double {
        let t2 = t * t, t3 = t2 * t
        let g2 = y0 == .infinity ? y2 - y1 : (y2 - y0) * 0.5
        let g3 = y3 == .infinity ? y2 - y1 : (y3 - y1) * 0.5
        return (2 * t3 - 3 * t2 + 1) * y1 + (t3 - 2 * t2 + t) * g2 + (-2 * t3 + 3 * t2) * y2 + (t3 - t2) * g3
    }

    private static let noSample = Double.infinity

    /// The samples on either side of `focal`, in the reference's spline order: index 1 just before the
    /// focal, 2 just after, 0 and 3 the outer neighbors. nil where there is no sample on that side.
    private static func spline(_ values: [Double], for focal: Double) -> [Int?] {
        var result: [Int?] = [nil, nil, nil, nil]
        let before = values.enumerated().filter { $0.element < focal }.sorted { $0.element > $1.element }
        let after = values.enumerated().filter { $0.element >= focal }.sorted { $0.element < $1.element }
        result[1] = before.first.map(\.offset)
        result[2] = after.first.map(\.offset)
        result[0] = before.dropFirst().first.map(\.offset)
        result[3] = after.dropFirst().first.map(\.offset)
        return result
    }

    /// The interpolated distortion at `focal`, in the calibration's own terms, or nil when the entry has
    /// no usable sample. Lensfun's interpolation scales each term by its sample's focal length and divides
    /// by the requested focal, which keeps the terms comparable across a zoom's range; the real focal
    /// length interpolates without that scaling. Only the first model an entry uses is taken, as the
    /// reference does; samples of any other model in the same entry are ignored by it and here too.
    static func interpolatedDistortion(_ samples: [LensfunDistortion], focal: Double) -> LensfunDistortion? {
        guard !samples.isEmpty else { return nil }
        let model = samples[0].model
        let usable = samples.filter { $0.model == model }
        guard !usable.isEmpty else { return nil }
        if let exact = usable.first(where: { $0.focal == focal }) { return exact }
        let slots = spline(usable.map(\.focal), for: focal)
        guard let before = slots[1], let after = slots[2] else {
            // One sample on one side only: the reference uses it as it stands.
            return (slots[1].map { usable[$0] } ?? slots[2].map { usable[$0] }) ?? usable.first
        }
        let s1 = usable[before], s2 = usable[after]
        let t = (focal - s1.focal) / (s2.focal - s1.focal)
        func term(_ index: Int) -> Double {
            let v1 = s1.terms[index] * s1.focal
            let v2 = s2.terms[index] * s2.focal
            let v0 = slots[0].map { usable[$0].terms[index] * usable[$0].focal } ?? noSample
            let v3 = slots[3].map { usable[$0].terms[index] * usable[$0].focal } ?? noSample
            return hermite(v0, v1, v2, v3, t) / focal
        }
        let terms = (0..<s1.terms.count).map(term)
        let r0 = slots[0].map { usable[$0].effectiveRealFocal } ?? noSample
        let r3 = slots[3].map { usable[$0].effectiveRealFocal } ?? noSample
        let realFocal = hermite(r0, s1.effectiveRealFocal, s2.effectiveRealFocal, r3, t)
        return LensfunDistortion(focal: focal, model: model, terms: terms, realFocal: realFocal)
    }

    /// The interpolated lateral chromatic aberration at `focal`, or nil when there is nothing to
    /// interpolate. The two scale terms interpolate without the focal scaling; the higher-order ones with
    /// it, as the reference's parameter table prescribes.
    static func interpolatedTCA(_ samples: [LensfunTCA], focal: Double) -> LensfunTCA? {
        guard !samples.isEmpty else { return nil }
        let model = samples[0].model
        let usable = samples.filter { $0.model == model }
        guard !usable.isEmpty else { return nil }
        if let exact = usable.first(where: { $0.focal == focal }) { return exact }
        let slots = spline(usable.map(\.focal), for: focal)
        guard let before = slots[1], let after = slots[2] else {
            return (slots[1].map { usable[$0] } ?? slots[2].map { usable[$0] }) ?? usable.first
        }
        let s1 = usable[before], s2 = usable[after]
        let t = (focal - s1.focal) / (s2.focal - s1.focal)
        func channel(_ red: Bool) -> [Double] {
            let terms1 = red ? s1.red : s1.blue
            let terms2 = red ? s2.red : s2.blue
            var result: [Double] = []
            for index in terms1.indices {
                if index == 0 {
                    // The scale term v: no focal scaling.
                    let v0 = slots[0].map { (red ? usable[$0].red : usable[$0].blue)[0] } ?? noSample
                    let v3 = slots[3].map { (red ? usable[$0].red : usable[$0].blue)[0] } ?? noSample
                    result.append(hermite(v0, terms1[0], terms2[0], v3, t))
                } else {
                    // The c and b terms: the reference scales them by their sample's focal length.
                    func scaled(_ sample: LensfunTCA) -> Double { (red ? sample.red : sample.blue)[index] * sample.focal }
                    let v0 = slots[0].map { scaled(usable[$0]) } ?? noSample
                    let v3 = slots[3].map { scaled(usable[$0]) } ?? noSample
                    result.append(hermite(v0, terms1[index] * s1.focal, terms2[index] * s2.focal, v3, t) / focal)
                }
            }
            return result
        }
        return LensfunTCA(focal: focal, model: model, red: channel(true), blue: channel(false))
    }

    /// The interpolated vignetting at this shot's focal length, aperture and focus distance: Lensfun's
    /// inverse-distance weighting with power 3.5 over a distance that puts focal span, aperture and focus
    /// distance on comparable scales. nil when no measurement is close enough, which is what keeps a
    /// profile from being applied where its measurements say nothing about this shot.
    static func interpolatedVignetting(_ samples: [LensfunVignetting], focal: Double, focalMin: Double,
                                       focalMax: Double, aperture: Double, distance: Double) -> LensfunVignetting? {
        guard aperture > 0, distance > 0, !samples.isEmpty else { return nil }
        let model = samples[0].model
        let usable = samples.filter { $0.model == model && $0.terms.count == 3 }
        guard !usable.isEmpty else { return nil }
        var totalWeight = 0.0
        var terms = [0.0, 0.0, 0.0]
        var smallest = Double.infinity
        for sample in usable {
            var f1 = focal - focalMin, f2 = sample.focal - focalMin
            let span = focalMax - focalMin
            if span != 0 { f1 /= span; f2 /= span }
            // Aperture enters as 4/f and focus distance as 0.1/d, so each axis is roughly 0–1.
            let a1 = 4.0 / aperture, a2 = 4.0 / sample.aperture
            let d1 = 0.1 / distance, d2 = 0.1 / sample.distance
            let apart = ((f2 - f1) * (f2 - f1) + (a2 - a1) * (a2 - a1) + (d2 - d1) * (d2 - d1)).squareRoot()
            if apart < 0.0001 { return sample }
            smallest = min(smallest, apart)
            let weight = abs(1.0 / pow(apart, 3.5))
            for index in 0..<3 { terms[index] += weight * sample.terms[index] }
            totalWeight += weight
        }
        guard smallest <= 1, totalWeight > 0 else { return nil }
        return LensfunVignetting(focal: focal, aperture: aperture, distance: distance, model: model,
                                 terms: terms.map { $0 / totalWeight })
    }

    /// Whether every focal/aperture sample says the same thing at every distance it was measured at, in
    /// which case the measurements do not depend on focus distance and no distance needs guessing. Nil
    /// when the samples differ — including when one focal/aperture was measured at only some distances —
    /// so an entry that merely repeated a measurement is what this accepts, never a fitted pattern.
    static func distanceIndependentVignetting(_ samples: [LensfunVignetting]) -> [LensfunVignetting]? {
        guard samples.count > 1 else { return nil }
        // Group by focal length and aperture; every group must carry the same coefficients.
        var groups: [Set<Double>: LensfunVignetting] = [:]
        var measuredAt: [Set<Double>: Set<Double>] = [:]
        for sample in samples {
            let key = Set([sample.focal, sample.aperture])
            if let previous = groups[key] {
                guard previous.terms == sample.terms else { return nil }
                measuredAt[key]?.insert(sample.distance)
            } else {
                groups[key] = sample
                measuredAt[key] = [sample.distance]
            }
        }
        // A sample measured at one distance while its neighbor was measured at two is not a repeated
        // measurement: the entry cannot say whether the single one depends on distance.
        guard let first = measuredAt.values.first else { return nil }
        guard measuredAt.values.allSatisfy({ $0 == first }) && first.count > 1 else { return nil }
        return groups.values.sorted { ($0.focal, $0.aperture) < ($1.focal, $1.aperture) }
    }

    // MARK: - Coordinate conversion

    /// The scale that turns pixel offsets into the calibration's coordinate system, where r = 1 is half
    /// the long edge in millimeters on the sensor: Lensfun's `NormScale`, with the extents measured at the
    /// pixel centers as the reference measures them.
    static func normalization(width: Int, height: Int, cropFactor: Double, realFocal: Double) -> Double {
        guard cropFactor > 0, realFocal > 0 else { return 0 }
        let w = width >= 2 ? Double(width - 1) : 1
        let h = height >= 2 ? Double(height - 1) : 1
        let diagonal = (36.0 * 36.0 + 24.0 * 24.0).squareRoot()
        let extent = ((w + 1.0) * (w + 1.0) + (h + 1.0) * (h + 1.0)).squareRoot()
        return diagonal / cropFactor / extent / realFocal
    }

    /// The distortion coefficients converted from the calibration's coordinate system into the normalized
    /// one the correction works in, following the reference's `rescale_polynomial_coefficients`: the
    /// ptlens-family models carry a center-shrink d that is divided out, and every term is scaled by the
    /// real focal length's ratio to the half-diagonal.
    static func rescaledDistortion(_ distortion: LensfunDistortion, cropFactor: Double) -> [Double]? {
        let huginScale = (36.0 * 36.0 + 24.0 * 24.0).squareRoot() / cropFactor / 2
        guard huginScale > 0 else { return nil }
        let scaling = distortion.effectiveRealFocal / huginScale
        switch distortion.model {
        case .poly3:
            guard let k1 = distortion.terms.first else { return nil }
            let d = 1 - k1
            guard abs(d) > 1e-9 else { return nil }
            return [k1 * scaling * scaling / (d * d * d)]
        case .poly5:
            guard distortion.terms.count >= 2 else { return nil }
            return [distortion.terms[0] * scaling * scaling,
                    distortion.terms[1] * scaling * scaling * scaling * scaling]
        case .ptlens:
            guard distortion.terms.count >= 3 else { return nil }
            let a = distortion.terms[0], b = distortion.terms[1], c = distortion.terms[2]
            let d = 1 - a - b - c
            guard abs(d) > 1e-9 else { return nil }
            return [a * scaling * scaling * scaling / (d * d * d * d),
                    b * scaling * scaling / (d * d * d),
                    c * scaling / (d * d)]
        case .acm:
            return nil
        }
    }

    /// The vignetting coefficients converted the same way: each power of the radius gains the matching
    /// power of the focal-length ratio, exactly as the reference's color rescale does.
    static func rescaledVignetting(_ vignetting: LensfunVignetting, cropFactor: Double, realFocal: Double) -> [Double]? {
        guard vignetting.terms.count == 3, cropFactor > 0, realFocal > 0 else { return nil }
        let huginScale = (36.0 * 36.0 + 24.0 * 24.0).squareRoot() / cropFactor / 2
        guard huginScale > 0 else { return nil }
        let scaling = realFocal / huginScale
        return [vignetting.terms[0] * scaling * scaling,
                vignetting.terms[1] * scaling * scaling * scaling * scaling,
                vignetting.terms[2] * pow(scaling, 6)]
    }

    /// The chromatic-aberration poly3 coefficients converted like the distortion's: the c terms gain the
    /// focal-length ratio and the b terms its square. The linear model's terms are dimensionless scale
    /// factors the reference rescales only for the reverse direction, which Compositor does not use.
    static func rescaledTCA(_ tca: LensfunTCA, cropFactor: Double, realFocal: Double) -> (red: [Double], blue: [Double])? {
        guard cropFactor > 0, realFocal > 0 else { return nil }
        switch tca.model {
        case .linear:
            guard tca.red.count >= 1, tca.blue.count >= 1 else { return nil }
            return (red: tca.red, blue: tca.blue)
        case .poly3:
            guard tca.red.count >= 3, tca.blue.count >= 3 else { return nil }
            let huginScale = (36.0 * 36.0 + 24.0 * 24.0).squareRoot() / cropFactor / 2
            guard huginScale > 0 else { return nil }
            let h = realFocal / huginScale
            return (red: [tca.red[0], tca.red[1] * h, tca.red[2] * h * h],
                    blue: [tca.blue[0], tca.blue[1] * h, tca.blue[2] * h * h])
        case .acm:
            return nil
        }
    }

    // MARK: - Resolution

    /// Why a calibrated correction is or is not running, one case per sentence the panel can show.
    nonisolated enum LensfunResolutionIssue: Equatable, Sendable {
        case noDatabase
        case noUsableProfile
        case refusedByPolicy(String)
        case noFocalLength
        case unsupportedModel(String)
        case noCalibrationForShot
        case vignettingNeedsAperture
        case vignettingDistanceUnknown
        case invalidData(String)
        case noCropFactor
    }

    /// The outcome of trying to turn the provider choice, the photograph's metadata and the installed
    /// database into a pixel correction. `correction` is nil unless every gate passed; `issues` says why
    /// not, in the order the gates were met or missed, so the panel can be exact about what happened.
    nonisolated struct Resolution: Equatable, Sendable {
        var correction: ResolvedCorrection?
        var issues: [LensfunResolutionIssue] = []
    }

    /// A correction ready to run: interpolated coefficients in their final, rescaled form, plus the
    /// normalization the pixel pass needs. Equal settings with an equal database always produce an equal
    /// value here, so a project reopens deterministically.
    nonisolated struct ResolvedCorrection: Equatable, Sendable {
        var lensID = ""
        var lensDescription = ""
        var cropFactor = 0.0
        var realFocal = 0.0
        var distortionModel: LensfunDistortionModel?
        var distortionTerms: [Double] = []
        var tcaModel: LensfunTCAModel?
        var tcaRed: [Double] = []
        var tcaBlue: [Double] = []
        var vignettingTerms: [Double] = []

        var hasDistortion: Bool { distortionModel != nil }
        var hasTCA: Bool { tcaModel != nil }
        var hasVignetting: Bool { !vignettingTerms.isEmpty }
        var correctsAnything: Bool { hasDistortion || hasTCA || hasVignetting }

        /// What the panel can promise, in the order it lists them.
        var correctionNames: [String] {
            var result: [String] = []
            if hasDistortion { result.append("Distortion") }
            if hasVignetting { result.append("Vignetting") }
            if hasTCA { result.append("Lateral chromatic aberration") }
            return result
        }
    }

    /// Turns the current settings into a correction, or explains why there is none. The gates are the
    /// double-correction policy's: only a RAW whose bytes are still held, decoded without Apple's own
    /// correction, may take a Lensfun pass. A nil database, a missing profile or an unsupported model
    /// leaves the pixels alone rather than approximating.
    static func resolve(settings: CameraRawLensProfileSettings, metadata: LensMetadata,
                        database: LensfunDatabase?, policySource: CameraRawLensCorrectionPolicy.Source,
                        appleCorrectionActive: Bool) -> Resolution {
        var issues: [LensfunResolutionIssue] = []
        guard settings.provider == .lensfun else { return Resolution(correction: nil, issues: []) }
        guard let database else {
            issues.append(.noDatabase)
            return Resolution(correction: nil, issues: issues)
        }
        // The policy gate, evaluated here rather than assumed: Apple's correction must not be in these
        // pixels, and only a redevelopable RAW qualifies at all.
        let policy = CameraRawLensCorrectionPolicy(source: policySource, provider: .lensfun,
                                                   appleCorrectionActive: appleCorrectionActive,
                                                   manualAdjustmentsActive: false)
        guard policy.canApplyLensfunCorrection else {
            issues.append(.refusedByPolicy(policy.explanation))
            return Resolution(correction: nil, issues: issues)
        }
        guard metadata.focalLengthMm > 0 else {
            issues.append(.noFocalLength)
            return Resolution(correction: nil, issues: issues)
        }
        // The profile: automatic takes the unambiguous match; manual takes the pinned identity, which a
        // database update may have removed — reported, never substituted.
        let lens: LensfunLens?
        if settings.selection.automatic {
            let match = database.match(metadata)
            lens = match.lens
            if lens == nil { issues.append(.noUsableProfile) }
        } else if settings.selection.hasChoice {
            lens = database.lens(id: settings.selection.lensID)
            if lens == nil { issues.append(.noUsableProfile) }
        } else {
            lens = nil
            issues.append(.noUsableProfile)
        }
        guard let lens else { return Resolution(correction: nil, issues: issues) }
        guard lens.center.x == 0 && lens.center.y == 0 else {
            issues.append(.unsupportedModel("decentered lens center"))
            return Resolution(correction: nil, issues: issues)
        }
        let camera = database.camera(forLens: lens, metadata: metadata)
        let cropFactor = camera?.cropFactor ?? lens.cropFactor
        guard cropFactor > 0 else {
            issues.append(.noCropFactor)
            return Resolution(correction: nil, issues: issues)
        }

        var correction = ResolvedCorrection()
        correction.lensID = lens.id
        correction.lensDescription = lens.description
        correction.cropFactor = cropFactor

        // The real focal length the calibration interpolation names is what every coefficient rescale
        // below is measured against, as in the reference, where one RealFocal drives all three
        // corrections. The nominal focal length stands in when there is none.
        var realFocal = metadata.focalLengthMm

        // Distortion. An entry whose distortion samples are all of a model this build does not apply is
        // reported as unsupported rather than corrected with the wrong equation.
        if lens.calibrations.distortion {
            if let interpolated = interpolatedDistortion(lens.distortions, focal: metadata.focalLengthMm),
               let rescaled = rescaledDistortion(interpolated, cropFactor: cropFactor),
               interpolated.model != .acm,
               interpolated.terms.allSatisfy({ $0.isFinite && abs($0) < 100 }),
               interpolated.effectiveRealFocal.isFinite && interpolated.effectiveRealFocal > 0 {
                correction.distortionModel = interpolated.model
                correction.distortionTerms = rescaled
                realFocal = interpolated.effectiveRealFocal
            } else if let first = lens.distortions.first, first.model == .acm {
                issues.append(.unsupportedModel("distortion model acm"))
            } else if lens.calibrations.hasUnsupportedDistortion {
                issues.append(.unsupportedModel("distortion"))
            } else {
                issues.append(.invalidData("distortion coefficients"))
            }
        }
        // Lateral chromatic aberration. The interpolated terms are in the calibration's coordinate
        // system; the rescale moves them into the normalized one the pixel pass works in.
        if lens.calibrations.tca {
            if let interpolated = interpolatedTCA(lens.tcas, focal: metadata.focalLengthMm),
               interpolated.model != .acm,
               (interpolated.red + interpolated.blue).allSatisfy({ $0.isFinite && abs($0) < 100 }),
               let rescaled = rescaledTCA(interpolated, cropFactor: cropFactor, realFocal: realFocal) {
                correction.tcaModel = interpolated.model
                correction.tcaRed = rescaled.red
                correction.tcaBlue = rescaled.blue
            } else if let first = lens.tcas.first, first.model == .acm {
                issues.append(.unsupportedModel("chromatic-aberration model acm"))
            } else if lens.calibrations.hasUnsupportedTCA {
                issues.append(.unsupportedModel("chromatic aberration"))
            } else {
                issues.append(.invalidData("chromatic-aberration coefficients"))
            }
        }
        // Vignetting. The correction needs the shot's aperture, and a focus distance the measurements can
        // speak to: when the entry measured several distances, the shot's actual one is unknown, so the
        // correction stays unavailable rather than guessing one. The exception is a measurement that
        // repeats itself: a focal/aperture sample whose coefficients are identical at every distance it
        // lists is a distance-independent measurement, and no shot parameter is being guessed when it is
        // used. That is how the published database writes distance-independent lenses.
        if lens.calibrations.vignetting {
            if metadata.aperture <= 0 {
                issues.append(.vignettingNeedsAperture)
            } else {
                let samples = lens.vignettings.filter { $0.model == .pa }
                let distanceIndependent = Self.distanceIndependentVignetting(samples)
                let distances = Set(samples.map(\.distance))
                if distances.count > 1 && distanceIndependent == nil {
                    issues.append(.vignettingDistanceUnknown)
                } else if let interpolated = interpolatedVignetting(
                        distanceIndependent ?? samples, focal: metadata.focalLengthMm, focalMin: lens.focalMin,
                        focalMax: lens.focalMax, aperture: metadata.aperture, distance: distances.first ?? 1),
                    let rescaled = rescaledVignetting(interpolated, cropFactor: cropFactor, realFocal: realFocal),
                    rescaled.allSatisfy({ $0.isFinite && abs($0) < 100 }) {
                    correction.vignettingTerms = rescaled
                } else if lens.calibrations.hasUnsupportedVignetting {
                    issues.append(.unsupportedModel("vignetting model acm"))
                } else {
                    issues.append(.noCalibrationForShot)
                }
            }
        }
        // The normalization uses the shared real focal length; without it, nothing can be normalized.
        guard CameraRawLensfun.normalization(width: 100, height: 100, cropFactor: cropFactor, realFocal: realFocal) > 0 else {
            issues.append(.noCropFactor)
            return Resolution(correction: nil, issues: issues)
        }
        correction.realFocal = realFocal
        guard correction.correctsAnything else { return Resolution(correction: nil, issues: issues) }
        return Resolution(correction: correction, issues: issues)
    }

    // MARK: - Pixel pass

    /// The calibrated correction over an 8-bit premultiplied RGBA image: one resample that carries the
    /// vignetting, the per-channel chromatic aberration and the distortion together. Each destination
    /// pixel finds its source position through the models' forward direction — the same mapping Lensfun's
    /// correct mode produces — so no hole can open where the inverse has no solution.
    static func apply(_ image: CGImage, correction: ResolvedCorrection) throws -> CGImage {
        let width = image.width, height = image.height
        guard width >= 2, height >= 2 else { return image }
        let source = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: source)
        let destination = try BrushRaster.context(width: width, height: height, mask: false)
        guard let from = source.data, let into = destination.data else { throw ExportError.render }
        let realFocal = correction.realFocal > 0 ? correction.realFocal : 1
        let scale = normalization(width: width, height: height, cropFactor: correction.cropFactor, realFocal: realFocal)
        guard scale > 0, scale.isFinite else { throw ExportError.render }
        var params = LensfunCorrectionParams()
        params.normScale = scale
        params.centerX = Double(width - 1) * 0.5 * scale
        params.centerY = Double(height - 1) * 0.5 * scale
        params.distortionModel = Int32(correction.distortionModel?.cIndex ?? 0)
        params.distortionTerm1 = correction.distortionTerms.count > 0 ? correction.distortionTerms[0] : 0
        params.distortionTerm2 = correction.distortionTerms.count > 1 ? correction.distortionTerms[1] : 0
        params.distortionTerm3 = correction.distortionTerms.count > 2 ? correction.distortionTerms[2] : 0
        params.tcaModel = Int32(correction.tcaModel?.cIndex ?? 0)
        params.tcaRedV = correction.tcaRed.count > 0 ? correction.tcaRed[0] : 1
        params.tcaRedC = correction.tcaRed.count > 1 ? correction.tcaRed[1] : 0
        params.tcaRedB = correction.tcaRed.count > 2 ? correction.tcaRed[2] : 0
        params.tcaBlueV = correction.tcaBlue.count > 0 ? correction.tcaBlue[0] : 1
        params.tcaBlueC = correction.tcaBlue.count > 1 ? correction.tcaBlue[1] : 0
        params.tcaBlueB = correction.tcaBlue.count > 2 ? correction.tcaBlue[2] : 0
        params.vignetting = correction.hasVignetting ? 1 : 0
        params.vignettingTerm1 = correction.vignettingTerms.count > 0 ? correction.vignettingTerms[0] : 0
        params.vignettingTerm2 = correction.vignettingTerms.count > 1 ? correction.vignettingTerms[1] : 0
        params.vignettingTerm3 = correction.vignettingTerms.count > 2 ? correction.vignettingTerms[2] : 0
        withExtendedLifetime((source, destination)) {
            lensfun_correct(from.assumingMemoryBound(to: UInt8.self), into.assumingMemoryBound(to: UInt8.self),
                            width, height, source.bytesPerRow, &params)
        }
        guard let result = destination.makeImage() else { throw ExportError.render }
        return result
    }
}

nonisolated extension LensfunDistortionModel {
    /// The kernel's model numbering.
    var cIndex: Int {
        switch self {
        case .poly3: return 1
        case .poly5: return 2
        case .ptlens: return 3
        case .acm: return 0
        }
    }
}

nonisolated extension LensfunTCAModel {
    var cIndex: Int {
        switch self {
        case .linear: return 1
        case .poly3: return 2
        case .acm: return 0
        }
    }
}
