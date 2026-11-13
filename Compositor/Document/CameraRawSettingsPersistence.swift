import Foundation

/// Versioned on-disk representation of `CameraRawSettings`. Nested live models are not all Codable;
/// this mirror uses explicit defaults so missing historical keys do not alter older photographs.
nonisolated struct CameraRawSettingsPersistentState: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int = schemaVersion
    var whiteBalance: String = CameraRawWhiteBalance.custom.rawValue
    var temperature: Double = 0
    var tint: Double = 0
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0
    var texture: Double = 0
    var clarity: Double = 0
    var dehaze: Double = 0
    var glow: Double = 0
    var glowStyle: String = CameraRawGlowStyle.diffusion.rawValue
    var glowRange: Double = 0
    var glowSpread: Double = 0
    var glowWarmth: Double = 0
    var vignetteAmount: Double = 0
    var vignetteStyle: String = CameraRawVignetteStyle.highlightPriority.rawValue
    var vignetteMidpoint: Double = 50
    var vignetteRoundness: Double = 0
    var vignetteFeather: Double = 50
    var vignetteHighlights: Double = 0
    var grainAmount: Double = 0
    var grainSize: Double = 25
    var grainRoughness: Double = 50
    var curve: Curve = Curve()
    var mixer: Mixer = Mixer()
    var grading: Grading = Grading()
    var detail: Detail = Detail()
    var optics: Optics = Optics()
    var geometry: CameraRawGeometrySettings = CameraRawGeometrySettings()
    var calibration: Calibration = Calibration()
    var horizon: CameraRawHorizonSettings = CameraRawHorizonSettings()
    var perspectiveTools: CameraRawPerspectiveToolState = CameraRawPerspectiveToolState()
    var miniature: CameraRawMiniatureSettings = CameraRawMiniatureSettings()

    nonisolated struct Curve: Codable, Equatable, Sendable {
        var shadows: Double = 0
        var darks: Double = 0
        var lights: Double = 0
        var highlights: Double = 0
        var shadowSplit: Double = 25
        var darkSplit: Double = 50
        var lightSplit: Double = 75
        var rgb: [CurvePoint] = CameraRawCurveSettings.linear
        var red: [CurvePoint] = CameraRawCurveSettings.linear
        var green: [CurvePoint] = CameraRawCurveSettings.linear
        var blue: [CurvePoint] = CameraRawCurveSettings.linear
        var refineSaturation: Double = 0
    }

    nonisolated struct Mixer: Codable, Equatable, Sendable {
        var hue: [Double] = Array(repeating: 0, count: 8)
        var saturation: [Double] = Array(repeating: 0, count: 8)
        var luminance: [Double] = Array(repeating: 0, count: 8)
        var points: [PointColor] = []
    }

    nonisolated struct PointColor: Codable, Equatable, Sendable {
        var hue: Double = 0
        var saturation: Double = 0
        var luminance: Double = 0
        var hueShift: Double = 0
        var saturationShift: Double = 0
        var luminanceShift: Double = 0
        var hueRange: Double = 30
        var saturationRange: Double = 0.4
        var luminanceRange: Double = 0.4
    }

    nonisolated struct GradeWheel: Codable, Equatable, Sendable {
        var hue: Double = 0
        var saturation: Double = 0
        var luminance: Double = 0
    }

    nonisolated struct Grading: Codable, Equatable, Sendable {
        var shadows: GradeWheel = GradeWheel()
        var midtones: GradeWheel = GradeWheel()
        var highlights: GradeWheel = GradeWheel()
        var global: GradeWheel = GradeWheel()
        var blending: Double = 50
        var balance: Double = 0
    }

    nonisolated struct Detail: Codable, Equatable, Sendable {
        var sharpenAmount: Double = 0
        var sharpenRadius: Double = 10
        var sharpenDetail: Double = 25
        var sharpenMasking: Double = 0
        var noiseLuminance: Double = 0
        var noiseLuminanceDetail: Double = 50
        var noiseLuminanceContrast: Double = 0
        var noiseColor: Double = 0
        var noiseColorDetail: Double = 50
        var noiseColorSmoothness: Double = 50
    }

    nonisolated struct Optics: Codable, Equatable, Sendable {
        var removeChromaticAberration = false
        var enableLensProfile = false
        var profileDistortion: Double = 100
        var profileVignetting: Double = 100
        var distortion: Double = 0
        var purpleAmount: Double = 0
        var purpleHueLow: Double = 270
        var purpleHueHigh: Double = 310
        var greenAmount: Double = 0
        var greenHueLow: Double = 60
        var greenHueHigh: Double = 120
        var vignetteAmount: Double = 0
        var vignetteMidpoint: Double = 50
    }

    nonisolated struct Calibration: Codable, Equatable, Sendable {
        var process: String = CameraRawProcessVersion.version6.rawValue
        var shadowTint: Double = 0
        var redHue: Double = 0
        var redSaturation: Double = 0
        var greenHue: Double = 0
        var greenSaturation: Double = 0
        var blueHue: Double = 0
        var blueSaturation: Double = 0
    }

    enum DecodeError: Error, Equatable, LocalizedError {
        case schema(Int)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .schema(let v): return "Unsupported Camera Raw settings schema version \(v)."
            case .malformed(let reason): return "Camera Raw settings data is damaged (\(reason))."
            }
        }
    }

    init() {}

    init(_ settings: CameraRawSettings) {
        let s = settings.normalized
        whiteBalance = s.whiteBalance.rawValue
        temperature = s.temperature
        tint = s.tint
        exposure = s.exposure
        contrast = s.contrast
        highlights = s.highlights
        shadows = s.shadows
        whites = s.whites
        blacks = s.blacks
        vibrance = s.vibrance
        saturation = s.saturation
        texture = s.texture
        clarity = s.clarity
        dehaze = s.dehaze
        glow = s.glow
        glowStyle = s.glowStyle.rawValue
        glowRange = s.glowRange
        glowSpread = s.glowSpread
        glowWarmth = s.glowWarmth
        vignetteAmount = s.vignetteAmount
        vignetteStyle = s.vignetteStyle.rawValue
        vignetteMidpoint = s.vignetteMidpoint
        vignetteRoundness = s.vignetteRoundness
        vignetteFeather = s.vignetteFeather
        vignetteHighlights = s.vignetteHighlights
        grainAmount = s.grainAmount
        grainSize = s.grainSize
        grainRoughness = s.grainRoughness
        curve = Curve(shadows: s.curve.shadows, darks: s.curve.darks, lights: s.curve.lights,
                      highlights: s.curve.highlights, shadowSplit: s.curve.shadowSplit,
                      darkSplit: s.curve.darkSplit, lightSplit: s.curve.lightSplit,
                      rgb: s.curve.rgb, red: s.curve.red, green: s.curve.green, blue: s.curve.blue,
                      refineSaturation: s.curve.refineSaturation)
        mixer = Mixer(hue: s.mixer.hue, saturation: s.mixer.saturation, luminance: s.mixer.luminance,
                      points: s.mixer.points.map {
                          PointColor(hue: $0.hue, saturation: $0.saturation, luminance: $0.luminance,
                                     hueShift: $0.hueShift, saturationShift: $0.saturationShift,
                                     luminanceShift: $0.luminanceShift, hueRange: $0.hueRange,
                                     saturationRange: $0.saturationRange, luminanceRange: $0.luminanceRange)
                      })
        grading = Grading(shadows: .init(hue: s.grading.shadows.hue, saturation: s.grading.shadows.saturation,
                                         luminance: s.grading.shadows.luminance),
                          midtones: .init(hue: s.grading.midtones.hue, saturation: s.grading.midtones.saturation,
                                          luminance: s.grading.midtones.luminance),
                          highlights: .init(hue: s.grading.highlights.hue, saturation: s.grading.highlights.saturation,
                                            luminance: s.grading.highlights.luminance),
                          global: .init(hue: s.grading.global.hue, saturation: s.grading.global.saturation,
                                        luminance: s.grading.global.luminance),
                          blending: s.grading.blending, balance: s.grading.balance)
        detail = Detail(sharpenAmount: s.detail.sharpenAmount, sharpenRadius: s.detail.sharpenRadius,
                        sharpenDetail: s.detail.sharpenDetail, sharpenMasking: s.detail.sharpenMasking,
                        noiseLuminance: s.detail.noiseLuminance, noiseLuminanceDetail: s.detail.noiseLuminanceDetail,
                        noiseLuminanceContrast: s.detail.noiseLuminanceContrast, noiseColor: s.detail.noiseColor,
                        noiseColorDetail: s.detail.noiseColorDetail, noiseColorSmoothness: s.detail.noiseColorSmoothness)
        optics = Optics(removeChromaticAberration: s.optics.removeChromaticAberration,
                        enableLensProfile: s.optics.enableLensProfile, profileDistortion: s.optics.profileDistortion,
                        profileVignetting: s.optics.profileVignetting, distortion: s.optics.distortion,
                        purpleAmount: s.optics.purpleAmount, purpleHueLow: s.optics.purpleHueLow,
                        purpleHueHigh: s.optics.purpleHueHigh, greenAmount: s.optics.greenAmount,
                        greenHueLow: s.optics.greenHueLow, greenHueHigh: s.optics.greenHueHigh,
                        vignetteAmount: s.optics.vignetteAmount, vignetteMidpoint: s.optics.vignetteMidpoint)
        geometry = s.geometry
        calibration = Calibration(process: s.calibration.process.rawValue, shadowTint: s.calibration.shadowTint,
                                  redHue: s.calibration.redHue, redSaturation: s.calibration.redSaturation,
                                  greenHue: s.calibration.greenHue, greenSaturation: s.calibration.greenSaturation,
                                  blueHue: s.calibration.blueHue, blueSaturation: s.calibration.blueSaturation)
        horizon = s.horizon
        perspectiveTools = s.perspectiveTools
        miniature = s.miniature
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let base = Self()
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try values.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        schemaVersion = try read(.schemaVersion, base.schemaVersion)
        whiteBalance = try read(.whiteBalance, base.whiteBalance)
        temperature = try read(.temperature, base.temperature)
        tint = try read(.tint, base.tint)
        exposure = try read(.exposure, base.exposure)
        contrast = try read(.contrast, base.contrast)
        highlights = try read(.highlights, base.highlights)
        shadows = try read(.shadows, base.shadows)
        whites = try read(.whites, base.whites)
        blacks = try read(.blacks, base.blacks)
        vibrance = try read(.vibrance, base.vibrance)
        saturation = try read(.saturation, base.saturation)
        texture = try read(.texture, base.texture)
        clarity = try read(.clarity, base.clarity)
        dehaze = try read(.dehaze, base.dehaze)
        glow = try read(.glow, base.glow)
        glowStyle = try read(.glowStyle, base.glowStyle)
        glowRange = try read(.glowRange, base.glowRange)
        glowSpread = try read(.glowSpread, base.glowSpread)
        glowWarmth = try read(.glowWarmth, base.glowWarmth)
        vignetteAmount = try read(.vignetteAmount, base.vignetteAmount)
        vignetteStyle = try read(.vignetteStyle, base.vignetteStyle)
        vignetteMidpoint = try read(.vignetteMidpoint, base.vignetteMidpoint)
        vignetteRoundness = try read(.vignetteRoundness, base.vignetteRoundness)
        vignetteFeather = try read(.vignetteFeather, base.vignetteFeather)
        vignetteHighlights = try read(.vignetteHighlights, base.vignetteHighlights)
        grainAmount = try read(.grainAmount, base.grainAmount)
        grainSize = try read(.grainSize, base.grainSize)
        grainRoughness = try read(.grainRoughness, base.grainRoughness)
        curve = try read(.curve, base.curve)
        mixer = try read(.mixer, base.mixer)
        grading = try read(.grading, base.grading)
        detail = try read(.detail, base.detail)
        optics = try read(.optics, base.optics)
        geometry = try read(.geometry, base.geometry)
        calibration = try read(.calibration, base.calibration)
        horizon = try read(.horizon, base.horizon)
        perspectiveTools = try read(.perspectiveTools, base.perspectiveTools)
        miniature = try read(.miniature, base.miniature)
    }

    func makeSettings() throws -> CameraRawSettings {
        guard schemaVersion == Self.schemaVersion else { throw DecodeError.schema(schemaVersion) }
        let scalars: [Double] = [
            temperature, tint, exposure, contrast, highlights, shadows, whites, blacks,
            vibrance, saturation, texture, clarity, dehaze, glow, glowRange, glowSpread, glowWarmth,
            vignetteAmount, vignetteMidpoint, vignetteRoundness, vignetteFeather, vignetteHighlights,
            grainAmount, grainSize, grainRoughness,
            curve.shadows, curve.darks, curve.lights, curve.highlights,
            curve.shadowSplit, curve.darkSplit, curve.lightSplit, curve.refineSaturation,
            grading.blending, grading.balance,
            detail.sharpenAmount, detail.sharpenRadius, detail.sharpenDetail, detail.sharpenMasking,
            detail.noiseLuminance, detail.noiseLuminanceDetail, detail.noiseLuminanceContrast,
            detail.noiseColor, detail.noiseColorDetail, detail.noiseColorSmoothness,
            optics.profileDistortion, optics.profileVignetting, optics.distortion,
            optics.purpleAmount, optics.purpleHueLow, optics.purpleHueHigh,
            optics.greenAmount, optics.greenHueLow, optics.greenHueHigh,
            optics.vignetteAmount, optics.vignetteMidpoint,
            calibration.shadowTint, calibration.redHue, calibration.redSaturation,
            calibration.greenHue, calibration.greenSaturation, calibration.blueHue, calibration.blueSaturation
        ]
        guard scalars.allSatisfy(\.isFinite),
              mixer.hue.allSatisfy(\.isFinite), mixer.saturation.allSatisfy(\.isFinite),
              mixer.luminance.allSatisfy(\.isFinite) else {
            throw DecodeError.malformed("non-finite")
        }
        var settings = CameraRawSettings()
        settings.whiteBalance = CameraRawWhiteBalance(rawValue: whiteBalance) ?? .custom
        settings.temperature = temperature
        settings.tint = tint
        settings.exposure = exposure
        settings.contrast = contrast
        settings.highlights = highlights
        settings.shadows = shadows
        settings.whites = whites
        settings.blacks = blacks
        settings.vibrance = vibrance
        settings.saturation = saturation
        settings.texture = texture
        settings.clarity = clarity
        settings.dehaze = dehaze
        settings.glow = glow
        settings.glowStyle = CameraRawGlowStyle(rawValue: glowStyle) ?? .diffusion
        settings.glowRange = glowRange
        settings.glowSpread = glowSpread
        settings.glowWarmth = glowWarmth
        settings.vignetteAmount = vignetteAmount
        settings.vignetteStyle = CameraRawVignetteStyle(rawValue: vignetteStyle) ?? .highlightPriority
        settings.vignetteMidpoint = vignetteMidpoint
        settings.vignetteRoundness = vignetteRoundness
        settings.vignetteFeather = vignetteFeather
        settings.vignetteHighlights = vignetteHighlights
        settings.grainAmount = grainAmount
        settings.grainSize = grainSize
        settings.grainRoughness = grainRoughness
        settings.curve.shadows = curve.shadows
        settings.curve.darks = curve.darks
        settings.curve.lights = curve.lights
        settings.curve.highlights = curve.highlights
        settings.curve.shadowSplit = curve.shadowSplit
        settings.curve.darkSplit = curve.darkSplit
        settings.curve.lightSplit = curve.lightSplit
        settings.curve.rgb = curve.rgb
        settings.curve.red = curve.red
        settings.curve.green = curve.green
        settings.curve.blue = curve.blue
        settings.curve.refineSaturation = curve.refineSaturation
        settings.mixer.hue = pad8(mixer.hue)
        settings.mixer.saturation = pad8(mixer.saturation)
        settings.mixer.luminance = pad8(mixer.luminance)
        settings.mixer.points = mixer.points.map {
            CameraRawPointColor(hue: $0.hue, saturation: $0.saturation, luminance: $0.luminance,
                                hueShift: $0.hueShift, saturationShift: $0.saturationShift,
                                luminanceShift: $0.luminanceShift, hueRange: $0.hueRange,
                                saturationRange: $0.saturationRange, luminanceRange: $0.luminanceRange)
        }
        settings.grading.shadows = CameraRawGradeWheel(hue: grading.shadows.hue,
                                                       saturation: grading.shadows.saturation,
                                                       luminance: grading.shadows.luminance)
        settings.grading.midtones = CameraRawGradeWheel(hue: grading.midtones.hue,
                                                        saturation: grading.midtones.saturation,
                                                        luminance: grading.midtones.luminance)
        settings.grading.highlights = CameraRawGradeWheel(hue: grading.highlights.hue,
                                                          saturation: grading.highlights.saturation,
                                                          luminance: grading.highlights.luminance)
        settings.grading.global = CameraRawGradeWheel(hue: grading.global.hue,
                                                      saturation: grading.global.saturation,
                                                      luminance: grading.global.luminance)
        settings.grading.blending = grading.blending
        settings.grading.balance = grading.balance
        settings.detail.sharpenAmount = detail.sharpenAmount
        settings.detail.sharpenRadius = detail.sharpenRadius
        settings.detail.sharpenDetail = detail.sharpenDetail
        settings.detail.sharpenMasking = detail.sharpenMasking
        settings.detail.noiseLuminance = detail.noiseLuminance
        settings.detail.noiseLuminanceDetail = detail.noiseLuminanceDetail
        settings.detail.noiseLuminanceContrast = detail.noiseLuminanceContrast
        settings.detail.noiseColor = detail.noiseColor
        settings.detail.noiseColorDetail = detail.noiseColorDetail
        settings.detail.noiseColorSmoothness = detail.noiseColorSmoothness
        settings.optics.removeChromaticAberration = optics.removeChromaticAberration
        settings.optics.enableLensProfile = optics.enableLensProfile
        settings.optics.profileDistortion = optics.profileDistortion
        settings.optics.profileVignetting = optics.profileVignetting
        settings.optics.distortion = optics.distortion
        settings.optics.purpleAmount = optics.purpleAmount
        settings.optics.purpleHueLow = optics.purpleHueLow
        settings.optics.purpleHueHigh = optics.purpleHueHigh
        settings.optics.greenAmount = optics.greenAmount
        settings.optics.greenHueLow = optics.greenHueLow
        settings.optics.greenHueHigh = optics.greenHueHigh
        settings.optics.vignetteAmount = optics.vignetteAmount
        settings.optics.vignetteMidpoint = optics.vignetteMidpoint
        settings.geometry = geometry
        settings.calibration.process = CameraRawProcessVersion(rawValue: calibration.process) ?? .version6
        settings.calibration.shadowTint = calibration.shadowTint
        settings.calibration.redHue = calibration.redHue
        settings.calibration.redSaturation = calibration.redSaturation
        settings.calibration.greenHue = calibration.greenHue
        settings.calibration.greenSaturation = calibration.greenSaturation
        settings.calibration.blueHue = calibration.blueHue
        settings.calibration.blueSaturation = calibration.blueSaturation
        settings.horizon = horizon
        settings.perspectiveTools = perspectiveTools
        settings.miniature = miniature
        settings = settings.normalized
        guard settings.isValid else { throw DecodeError.malformed("out of range") }
        return settings
    }

    private func pad8(_ values: [Double]) -> [Double] {
        var result = Array(values.prefix(8))
        while result.count < 8 { result.append(0) }
        return result
    }
}
