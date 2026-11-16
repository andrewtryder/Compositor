import AppKit

/// White balance on an already-rendered layer. Raw lighting presets are absent: temperature and tint
/// are relative offsets, not kelvin.
nonisolated enum CameraRawWhiteBalance: String, CaseIterable, Sendable {
    case custom = "Custom"
    case auto = "Auto"
}

/// Glow's three looks. Warmth tints Diffusion and Bloom from cool to warm; Halation's fringe stays red.
nonisolated enum CameraRawGlowStyle: String, CaseIterable, Sendable {
    case diffusion = "Diffusion"
    case bloom = "Bloom"
    case halation = "Halation"
    var kernelValue: Int32 {
        switch self {
        case .diffusion: return 0
        case .bloom: return 1
        case .halation: return 2
        }
    }
}

/// Post-crop vignette. Highlight Priority is the style whose Highlights slider protects bright pixels.
nonisolated enum CameraRawVignetteStyle: String, CaseIterable, Sendable {
    case highlightPriority = "Highlight Priority"
    case colorPriority = "Color Priority"
    case paintOverlay = "Paint Overlay"
    var kernelValue: Int32 {
        switch self {
        case .highlightPriority: return 0
        case .colorPriority: return 1
        case .paintOverlay: return 2
        }
    }
}

/// Temporary clipping view while Option is held on a Light slider. Never written into the layer.
nonisolated enum CameraRawClipping: Int32, Sendable {
    /// Clipped channels lit on black. Exposure, Highlights, and Whites.
    case highlights = 1
    /// Clipped channels dark on white. Shadows and Blacks.
    case shadows = 2
}

/// Camera Raw Filter settings. Defaults leave the image unchanged.
nonisolated struct CameraRawSettings: Equatable, Sendable {
    static let exposureRange: ClosedRange<Double> = -5...5
    static let toneRange: ClosedRange<Double> = -100...100
    static let unitRange: ClosedRange<Double> = 0...100

    var whiteBalance: CameraRawWhiteBalance = .custom
    /// Relative cool-to-warm, −100…100. Positive is warmer.
    var temperature: Double = 0
    /// Green-to-magenta, −100…100. Positive is magenta.
    var tint: Double = 0
    /// Stops of linear light, −5…5.
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0
    /// Local contrast, −100…100. Texture is the finer band; Clarity is the broader one.
    var texture: Double = 0
    var clarity: Double = 0
    /// −100…100. Positive deepens contrast and saturation; negative lifts shadows and fades color.
    var dehaze: Double = 0
    /// 0…100. Range, spread, and warmth are idle while this stays at zero.
    var glow: Double = 0
    var glowStyle: CameraRawGlowStyle = .diffusion
    var glowRange: Double = 0
    var glowSpread: Double = 0
    var glowWarmth: Double = 0
    /// −100…100. Negative darkens the edges, positive lightens them. The center is left alone.
    var vignetteAmount: Double = 0
    var vignetteStyle: CameraRawVignetteStyle = .highlightPriority
    var vignetteMidpoint: Double = 50
    var vignetteRoundness: Double = 0
    var vignetteFeather: Double = 50
    /// Used only while `vignetteAmount` darkens, and only for Highlight Priority.
    var vignetteHighlights: Double = 0
    /// 0…100. Zero adds no grain. Size is mapped into the shared grain kernel's pixel scale.
    var grainAmount: Double = 0
    var grainSize: Double = 25
    var grainRoughness: Double = 50
    var curve = CameraRawCurveSettings()
    var mixer = CameraRawMixerSettings()
    var grading = CameraRawGradingSettings()
    var detail = CameraRawDetailSettings()
    var optics = CameraRawOpticsSettings()
    var geometry = CameraRawGeometrySettings()
    var calibration = CameraRawCalibrationSettings()
    /// Dedicated Horizon correction. Defaults off; composed into geometry corners before framing.
    var horizon = CameraRawHorizonSettings()
    /// Typed perspective-tool state. Defaults leave `geometry.guides` / manual keystone alone.
    var perspectiveTools = CameraRawPerspectiveToolState()
    /// Miniature / tilt-shift. Defaults identity; runs after geometry, before the color grade.
    var miniature = CameraRawMiniatureSettings()
    /// Crop After Transform: an explicit geometry-aware crop planned on the corrected image after geometry
    /// (de-squeeze, Volume, Perspective, Horizon, framing and Constrain Crop), before Miniature and Lens Blur.
    /// Defaults to no crop, which renders exactly as before this existed.
    var crop = CameraRawGeometryCropRequest()
    /// Local regions, each with its own tone and color. Applied to the corrected frame after the global grade, in
    /// list order; empty by default, so a project without masks renders exactly as it did.
    var localMasks: [CameraRawLocalMask] = []
    /// Optional automatic horizon angle from the last Auto Level observation (degrees). Not persisted.
    var automaticHorizonAngle: Double? = nil

    var adjustsLight: Bool {
        exposure != 0 || contrast != 0 || highlights != 0 || shadows != 0 || whites != 0 || blacks != 0
    }
    var adjustsColor: Bool {
        temperature != 0 || tint != 0 || vibrance != 0 || saturation != 0
    }
    var adjustsEffects: Bool {
        texture != 0 || clarity != 0 || dehaze != 0 || glow != 0 || vignetteAmount != 0 || grainAmount != 0
    }
    var adjustsCurve: Bool { curve.adjusts }
    var adjustsMixer: Bool { mixer.adjusts }
    var adjustsGrading: Bool { grading.adjusts }
    var adjustsDetail: Bool { detail.adjusts }
    var adjustsOptics: Bool { optics.adjusts }
    var adjustsGeometry: Bool { geometry.adjusts || !horizon.isIdentity || !miniature.isIdentity
        || perspectiveTools.kind != .automatic || !crop.isNoCrop }
    var adjustsCalibration: Bool { calibration.adjusts }
    /// Masks that are on and actually change something.
    var appliedLocalMasks: [CameraRawLocalMask] { localMasks.filter(\.applies) }
    var adjustsLocalMasks: Bool { !appliedLocalMasks.isEmpty }
    var isIdentity: Bool {
        !adjustsLight && !adjustsColor && !adjustsEffects && !adjustsCurve && !adjustsMixer && !adjustsGrading
            && !adjustsDetail && !adjustsOptics && !adjustsGeometry && !adjustsCalibration
            && !adjustsLocalMasks
            && !optics.lensProfile.adjustsPixels
    }

    /// Copies only `group` from `source` into `self`, so a preset can apply the groups it carries
    /// without touching anything else.
    mutating func applyGroup(_ group: CameraRawGroup, from source: CameraRawSettings) {
        CameraRawSettings.copy(group, from: source, to: &self)
    }
    var isValid: Bool {
        Self.exposureRange.contains(exposure) && exposure.isFinite
            && [contrast, highlights, shadows, whites, blacks, temperature, tint, vibrance, saturation,
            texture, clarity, dehaze, glowRange, glowSpread, glowWarmth, vignetteAmount, vignetteRoundness].allSatisfy {
                $0.isFinite && Self.toneRange.contains($0)
            }
        && [glow, vignetteMidpoint, vignetteFeather, vignetteHighlights, grainAmount, grainSize, grainRoughness].allSatisfy {
            $0.isFinite && Self.unitRange.contains($0)
        }
        && localMasks.count <= CameraRawLocalMask.maximumCount
        && localMasks.allSatisfy(\.isValid)
        && Set(localMasks.map(\.id)).count == localMasks.count
    }
    var normalized: Self {
        var result = self
        result.exposure = ImageAdjustmentPixels.clamp(exposure, Self.exposureRange, 0)
        result.contrast = ImageAdjustmentPixels.clamp(contrast, Self.toneRange, 0)
        result.highlights = ImageAdjustmentPixels.clamp(highlights, Self.toneRange, 0)
        result.shadows = ImageAdjustmentPixels.clamp(shadows, Self.toneRange, 0)
        result.whites = ImageAdjustmentPixels.clamp(whites, Self.toneRange, 0)
        result.blacks = ImageAdjustmentPixels.clamp(blacks, Self.toneRange, 0)
        result.temperature = ImageAdjustmentPixels.clamp(temperature, Self.toneRange, 0)
        result.tint = ImageAdjustmentPixels.clamp(tint, Self.toneRange, 0)
        result.vibrance = ImageAdjustmentPixels.clamp(vibrance, Self.toneRange, 0)
        result.saturation = ImageAdjustmentPixels.clamp(saturation, Self.toneRange, 0)
        result.texture = ImageAdjustmentPixels.clamp(texture, Self.toneRange, 0)
        result.clarity = ImageAdjustmentPixels.clamp(clarity, Self.toneRange, 0)
        result.dehaze = ImageAdjustmentPixels.clamp(dehaze, Self.toneRange, 0)
        result.glow = ImageAdjustmentPixels.clamp(glow, Self.unitRange, 0)
        result.glowRange = ImageAdjustmentPixels.clamp(glowRange, Self.toneRange, 0)
        result.glowSpread = ImageAdjustmentPixels.clamp(glowSpread, Self.toneRange, 0)
        result.glowWarmth = ImageAdjustmentPixels.clamp(glowWarmth, Self.toneRange, 0)
        result.vignetteAmount = ImageAdjustmentPixels.clamp(vignetteAmount, Self.toneRange, 0)
        result.vignetteMidpoint = ImageAdjustmentPixels.clamp(vignetteMidpoint, Self.unitRange, 50)
        result.vignetteRoundness = ImageAdjustmentPixels.clamp(vignetteRoundness, Self.toneRange, 0)
        result.vignetteFeather = ImageAdjustmentPixels.clamp(vignetteFeather, Self.unitRange, 50)
        result.vignetteHighlights = ImageAdjustmentPixels.clamp(vignetteHighlights, Self.unitRange, 0)
        result.grainAmount = ImageAdjustmentPixels.clamp(grainAmount, Self.unitRange, 0)
        result.grainSize = ImageAdjustmentPixels.clamp(grainSize, Self.unitRange, 25)
        result.grainRoughness = ImageAdjustmentPixels.clamp(grainRoughness, Self.unitRange, 50)
        result.curve = curve.normalized
        result.mixer = mixer.normalized
        result.grading = grading.normalized
        result.detail = detail.normalized
        result.optics = optics.normalized
        result.geometry = geometry.normalized
        // The keystone sliders on `geometry` are the one owner of Vertical / Horizontal / Rotate; the advanced tool's
        // copy is a mirror, refreshed here so it can never go stale and never disagree with the panel.
        result.perspectiveTools.synchronizingManual(with: result.geometry)
        result.calibration = calibration.normalized
        result.horizon = horizon.normalized
        result.miniature = miniature.normalized
        result.localMasks = Array(localMasks.prefix(CameraRawLocalMask.maximumCount)).map(\.normalized)
        return result
    }

    /// The grade with a panel's eye turned off: that group's amounts become zero and the rest stay.
    func applying(showsLight: Bool, showsColor: Bool, showsEffects: Bool = true, showsCurve: Bool = true, showsMixer: Bool = true,
                  showsGrading: Bool = true, showsDetail: Bool = true, showsOptics: Bool = true, showsGeometry: Bool = true,
                  showsCalibration: Bool = true) -> Self {
        var result = self
        if !showsLight {
            result.exposure = 0
            result.contrast = 0
            result.highlights = 0
            result.shadows = 0
            result.whites = 0
            result.blacks = 0
        }
        if !showsColor {
            result.temperature = 0
            result.tint = 0
            result.vibrance = 0
            result.saturation = 0
        }
        if !showsEffects {
            result.texture = 0
            result.clarity = 0
            result.dehaze = 0
            result.glow = 0
            result.vignetteAmount = 0
            result.grainAmount = 0
        }
        if !showsCurve { result.curve = CameraRawCurveSettings() }
        if !showsMixer { result.mixer = CameraRawMixerSettings() }
        if !showsGrading { result.grading = CameraRawGradingSettings() }
        if !showsDetail { result.detail = CameraRawDetailSettings() }
        if !showsOptics { result.optics = CameraRawOpticsSettings() }
        if !showsGeometry {
            result.geometry = CameraRawGeometrySettings()
            result.horizon = CameraRawHorizonSettings()
            result.perspectiveTools = CameraRawPerspectiveToolState()
            result.miniature = CameraRawMiniatureSettings()
            result.crop = CameraRawGeometryCropRequest()
            result.automaticHorizonAngle = nil
        }
        if !showsCalibration { result.calibration = CameraRawCalibrationSettings() }
        return result
    }

    /// Camera Raw's 0…100 size, in the pixel scale `adjust_grain` already uses.
    var grainKernelSize: Double { 0.5 + (grainSize / 100) * 19.5 }

    /// `clipping` draws the Option-drag overlay instead of the grade. Nil renders the image.
    /// `scale` is preview pixels per layer pixel. Grain uses `seed` so the pattern stays put while the panel is open.
    /// `brightness` is what the adaptive sliders read from the picture, when it's known already (a preview's source,
    /// measured once for the session); nil measures it here.
    func apply(_ image: CGImage, clipping: CameraRawClipping? = nil, scale: CGFloat = 1, seed: UInt32 = 0, visualizePointColor: Int = -1,
               sharpenMask: Bool = false, brightness known: CameraRawTables.Brightness? = nil, usesGPU: Bool = false) throws -> CGImage {
        try applyResult(image, clipping: clipping, scale: scale, seed: seed, visualizePointColor: visualizePointColor,
                        sharpenMask: sharpenMask, brightness: known, usesGPU: usesGPU).image
    }

    /// Same as `apply`, plus Expand to Fit placement metadata for FilterEdit / commit. `lensMetadata` and
    /// `lensfunDatabase` carry what the calibrated Lensfun pass needs: without them (or with no database
    /// installed) the pass never runs and the render is exactly what it was before M10.6.
    ///
    /// `lensBlurDepth`: the frame's depth estimate, computed once by the caller so Depth Focus does not run the
    /// model per slider move. `visualizesLensBlurDepth`: preview only — Lens Blur's own map, never committed.
    func applyResult(_ image: CGImage, clipping: CameraRawClipping? = nil, scale: CGFloat = 1, seed: UInt32 = 0,
                     visualizePointColor: Int = -1, sharpenMask: Bool = false,
                     brightness known: CameraRawTables.Brightness? = nil, usesGPU: Bool = false,
                     lensMetadata: LensMetadata? = nil, lensfunDatabase: LensfunDatabase? = nil,
                     policySource: CameraRawLensCorrectionPolicy.Source = .renderedImage,
                     appleCorrectionActive: Bool = false,
                     lensBlurDepth: DepthMap? = nil, visualizesLensBlurDepth: Bool = false,
                     visualizesLocalMask: UUID? = nil) throws -> CameraRawGeometryResult {
        let settings = normalized
        // A Lensfun selection can correct on its own, and whether it does is only known by resolving
        // against the photograph's metadata and the installed database — which happens below, not here.
        // The early return therefore stands aside whenever the provider is selected: the pass itself
        // leaves the pixels alone when no profile qualifies.
        let lensfunSelected = settings.optics.lensProfile.provider == .lensfun
        if settings.isIdentity && !lensfunSelected && clipping == nil && visualizePointColor < 0 && !sharpenMask
            && !visualizesLensBlurDepth && visualizesLocalMask == nil {
            return CameraRawGeometryResult(image: image, expansion: nil)
        }
        guard settings.isValid else { throw ProjectError.invalid }
        let mode = clipping?.rawValue ?? 0
        let pixelScale = scale > 0 ? Double(scale) : 1
        // Curve, Color Mixer and Color Grading go into the one composed table with Light and Color, a single lookup a
        // pixel, unless point colors or Refine Saturation (which the curve pass draws) are in play.
        let foldsColor = clipping == nil && !sharpenMask && visualizePointColor < 0 && settings.mixer.points.isEmpty
            && settings.curve.refineSaturation == 0
        let colorAdjusts = settings.adjustsCurve || settings.adjustsMixer || settings.adjustsGrading
        let paintColor = !foldsColor && clipping == nil && !sharpenMask && (colorAdjusts || visualizePointColor >= 0)
        let paintEffects = clipping == nil && !sharpenMask && settings.adjustsEffects
        let paintDetailOptics = clipping == nil && (settings.adjustsDetail || settings.adjustsOptics || sharpenMask)
        var source = image
        var geometryExpansion: CameraRawGeometryExpansion?
        var lensBlurAppliedEarly = false
        // Showing the depth map is a preview of what Depth Focus reads, not a grade: it replaces the frame for as
        // long as it is on, so the picture's own adjustments never tint it.
        if clipping == nil && !sharpenMask && visualizePointColor < 0 && visualizesLensBlurDepth,
           settings.optics.lensBlur.focusMode == .depthFocus {
            let shown = try CameraRawLensBlur.apply(image, settings: settings.optics.lensBlur, scale: CGFloat(pixelScale),
                                                    depth: lensBlurDepth, visualizeDepth: true)
            return CameraRawGeometryResult(image: shown, expansion: nil)
        }
        // Depth Focus: the blur's mask is the captured frame's own depth, so it is blended on that frame — before
        // any geometry warp — and the warp then carries the discs along with the picture. Focus Region keeps its
        // long-standing place after the warp, so its result is exactly what it was before Depth Focus existed.
        if clipping == nil && !sharpenMask && visualizePointColor < 0,
           settings.optics.lensBlur.focusMode == .depthFocus,
           !settings.optics.lensBlur.isIdentity {
            source = try CameraRawLensBlur.apply(source, settings: settings.optics.lensBlur, scale: CGFloat(pixelScale),
                                                 depth: lensBlurDepth, visualizeDepth: false)
            lensBlurAppliedEarly = true
        }
        // The calibrated Lensfun pass, before any geometry: vignetting, lateral CA and distortion in one
        // resample. It only runs when the caller supplied what it needs and the double-correction policy
        // allows it — the resolution is nil otherwise, and then nothing here changes.
        if clipping == nil && !sharpenMask && visualizePointColor < 0,
           let lensMetadata, let lensfunDatabase {
            let resolution = CameraRawLensfun.resolve(settings: settings.optics.lensProfile, metadata: lensMetadata,
                                                      database: lensfunDatabase, policySource: policySource,
                                                      appleCorrectionActive: appleCorrectionActive)
            if let correction = resolution.correction {
                source = try CameraRawLensfun.apply(source, correction: correction)
            }
        }
        // Distortion → de-squeeze → volume → perspective → crop, then the grade. Distortion moves early only when
        // geometry runs, so an optics-only grade keeps its previous order. The late pass skips distortion
        // when this already applied it, including a lens profile's share of the same k.
        var earlyDistortion = false
        if clipping == nil && !sharpenMask && visualizePointColor < 0 && settings.adjustsGeometry {
            let distortionK = settings.optics.distortionK(profileStrength: PixelFilter.lensStrength)
            if distortionK != 0 {
                source = try Self.applyLensDistort(source, k: distortionK)
                earlyDistortion = true
            }
            let geometry = CameraRawPerspectiveTools.applying(settings.perspectiveTools, to: settings.geometry)
            let backend = CameraRawGeometryBackendSettings(
                geometry: geometry, horizon: settings.horizon, perspectiveTools: settings.perspectiveTools,
                miniature: settings.miniature)
            let horizonDegrees = CameraRawGeometryBackend.horizonDegrees(
                settings: backend, width: source.width, height: source.height,
                automaticAngle: settings.automaticHorizonAngle)
            let geometryResult = try geometry.applyResult(source, horizonDegrees: horizonDegrees)
            source = geometryResult.image
            geometryExpansion = geometryResult.expansion
            // Crop After Transform plans on the corrected image, after geometry's own framing, before
            // Miniature and Lens Blur; the plan rect folds into the same placement metadata.
            if !settings.crop.isNoCrop,
               let crop = try CameraRawGeometryCrop.plan(request: settings.crop, image: source,
                                                         originalSize: CGSize(width: image.width, height: image.height)),
               crop.width < CGFloat(source.width) - 0.5 || crop.height < CGFloat(source.height) - 0.5,
               let cropped = source.cropping(to: crop) {
                source = cropped
                geometryExpansion = geometryExpansion?.cropping(to: crop)
                    ?? CameraRawGeometryExpansion(inputWidth: image.width, inputHeight: image.height,
                                                  coverageInInput: crop)
            }
            if !settings.miniature.isIdentity {
                source = try CameraRawMiniature.apply(source, settings: settings.miniature, scale: CGFloat(pixelScale))
            }
        }
        // Lens Blur is spatial like the geometry passes, so it runs before the color grade and after the warp:
        // its discs are round in the corrected picture, not in the distorted one. Depth Focus reads the frame's
        // depth estimate, which the caller may have computed once for the whole edit; it has already run above.
        if !lensBlurAppliedEarly && clipping == nil && !sharpenMask && visualizePointColor < 0
            && !settings.optics.lensBlur.isIdentity {
            source = try CameraRawLensBlur.apply(source, settings: settings.optics.lensBlur, scale: CGFloat(pixelScale),
                                                 depth: lensBlurDepth, visualizeDepth: false)
        }
        func applyTable(_ table: [Float]?, pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int, stride: Int, clipping: Int32) {
            if usesGPU, clipping == 0, let table,
               MetalCameraRawLookup.shared?.apply(pixels, width: width, height: height, rowBytes: stride,
                                                 table: table, grid: CameraRawTables.grid) == true { return }
            adjust_camera_raw(pixels, width, height, stride, table, Int32(CameraRawTables.grid), clipping)
        }
        let graded = try ImageAdjustmentPixels.run(source) { pixels, width, height, stride in
            let adaptive = settings.contrast != 0 || settings.highlights != 0
            let brightness = adaptive
                ? known ?? CameraRawTables.brightness(pixels, width: width, height: height, stride: stride) : CameraRawTables.Brightness()
            if clipping == nil && !sharpenMask && settings.adjustsCalibration {
                settings.applyCalibration(pixels: pixels, width: width, height: height, stride: stride)
            }
            // Shadows adapts region by region, so it can't join the color table: the stages before it run, then it,
            // then the rest.
            let shadows = settings.shadows != 0 && CameraRawShadows.tables != nil
            if shadows {
                if let before = CameraRawTables.compose(CameraRawTables.stages(for: settings, brightness: brightness, part: .beforeShadows)) {
                    applyTable(before, pixels: pixels, width: width, height: height, stride: stride, clipping: 0)
                }
                CameraRawShadows.apply(settings.shadows, pixels: pixels, width: width, height: height, stride: stride, scale: pixelScale)
            }
            var table = CameraRawTables.compose(CameraRawTables.stages(for: settings, brightness: brightness,
                                                                       part: shadows ? .afterShadows : nil))
            if foldsColor && colorAdjusts { table = settings.foldingColor(into: table) }
            if table != nil || clipping != nil {
                applyTable(table, pixels: pixels, width: width, height: height, stride: stride, clipping: Int32(mode))
            }
            if paintColor { settings.applyCurveColor(pixels, width: width, height: height, stride: stride, visualize: visualizePointColor) }
            if paintEffects {
                if settings.texture != 0 || settings.clarity != 0 || settings.dehaze != 0 || settings.glow != 0 || settings.vignetteAmount != 0 {
                    adjust_camera_raw_effects(pixels, width, height, stride,
                                              settings.texture, settings.clarity, settings.dehaze,
                                              settings.glow, settings.glowStyle.kernelValue, settings.glowRange,
                                              settings.glowSpread, settings.glowWarmth,
                                              settings.vignetteAmount, settings.vignetteMidpoint, settings.vignetteRoundness,
                                              settings.vignetteFeather, settings.vignetteHighlights, settings.vignetteStyle.kernelValue,
                                              pixelScale)
                }
                if settings.grainAmount > 0 {
                    adjust_grain(pixels, width, height, stride, settings.grainAmount, settings.grainKernelSize,
                                 settings.grainRoughness, seed, 0, 0, 1 / pixelScale)
                }
            }
            if paintDetailOptics {
                settings.applyDetailOptics(pixels: pixels, width: width, height: height, stride: stride, scale: pixelScale,
                                           profileStrength: PixelFilter.lensStrength, sharpenMask: sharpenMask,
                                           skipDistortion: earlyDistortion)
            }
        }
        // Local masks read the corrected frame — after de-squeeze, geometry, crop, Miniature, Lens Blur and the global
        // grade — so a region drawn on the preview lands on the pixels it was drawn over, and the global grade is
        // never applied twice. Nothing here runs when no mask is on, so a project without masks is pixel-identical.
        var result = graded
        if clipping == nil && !sharpenMask && visualizePointColor < 0 {
            if settings.adjustsLocalMasks {
                result = try CameraRawLocalMaskRenderer.applying(settings.appliedLocalMasks, to: result,
                                                                 settings: settings,
                                                                 inputWidth: image.width, inputHeight: image.height)
            }
            if let visualizesLocalMask {
                result = try CameraRawLocalMaskRenderer.overlay(settings.localMasks, maskID: visualizesLocalMask,
                                                                settings: settings, on: result,
                                                                inputWidth: image.width, inputHeight: image.height)
            }
        }
        return CameraRawGeometryResult(image: result, expansion: geometryExpansion)
    }

    /// Premultiplied RGBA lens distortion matching `lens_distort` / the Lens Correction filter.
    static func applyLensDistort(_ image: CGImage, k: Double) throws -> CGImage {
        guard k != 0 else { return image }
        let width = image.width, height = image.height
        let source = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: source)
        let destination = try BrushRaster.context(width: width, height: height, mask: false)
        guard let from = source.data, let into = destination.data else { throw ExportError.render }
        lens_distort(from.assumingMemoryBound(to: UInt8.self), into.assumingMemoryBound(to: UInt8.self),
                     width, height, source.bytesPerRow, k)
        guard let result = destination.makeImage() else { throw ExportError.render }
        return result
    }

    /// Temperature and tint that turn one straight sRGB color (0…1) as nearly gray as Camera Raw's white balance can.
    /// Nil when a channel is missing.
    static func neutralize(straightRed red: Double, green: Double, blue: Double) -> (temperature: Double, tint: Double)? {
        CameraRawTables.neutralize(red: red, green: green, blue: blue)
    }

    /// Gray-world balance of the opaque pixels. Nil when the image has no coverage or no solution.
    static func autoBalance(of image: CGImage) -> (temperature: Double, tint: Double)? {
        guard let average = averageLinear(image) else { return nil }
        return neutralize(straightRed: encode(average.red), green: encode(average.green), blue: encode(average.blue))
    }

    private static func encode(_ linear: Double) -> Double {
        linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
    }

    private static func decode(_ encoded: Double) -> Double {
        encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }

    private static func averageLinear(_ image: CGImage) -> (red: Double, green: Double, blue: Double)? {
        guard image.width > 0, image.height > 0 else { return nil }
        let context = try? BrushRaster.context(width: image.width, height: image.height, mask: false)
        guard let context else { return nil }
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        guard let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var red = 0.0, green = 0.0, blue = 0.0, count = 0.0
        for y in 0..<image.height {
            let row = y * context.bytesPerRow
            for x in 0..<image.width {
                let pixel = row + x * 4
                let alpha = Double(bytes[pixel + 3])
                if alpha == 0 { continue }
                red += decode(min(1, Double(bytes[pixel]) / alpha))
                green += decode(min(1, Double(bytes[pixel + 1]) / alpha))
                blue += decode(min(1, Double(bytes[pixel + 2]) / alpha))
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return (red / count, green / count, blue / count)
    }
}

/// Histogram or the vectorscope shown in its place.
nonisolated enum CameraRawScopeMode: String, Sendable {
    case histogram = "Histogram"
    case vectorscope = "Vectorscope"
}

/// One RGB histogram and a hue/saturation vectorscope of the same graded pixels.
nonisolated struct CameraRawScope: Equatable, Sendable {
    static let binCount = 256
    static let scopeSide = 64
    var red: [Double]
    var green: [Double]
    var blue: [Double]
    /// Density from the center outward. Index `y * scopeSide + x`.
    var vectorscope: [Double]

    /// Shared vertical scale so the three ribbons stay comparable.
    var peak: Double {
        max(LevelsHistogramDisplay.scale(for: red),
            LevelsHistogramDisplay.scale(for: green),
            LevelsHistogramDisplay.scale(for: blue))
    }

    /// Counts the graded image. Fully transparent pixels are skipped.
    /// Sample every fourth pixel each way up to 4 megapixels, every eighth above that. Read straight from the
    /// image's bytes when they're already premultiplied RGBA; this does not affect the grade or clipping paint.
    static func make(_ image: CGImage) -> Self? {
        guard image.width > 0, image.height > 0 else { return nil }
        let step = image.width * image.height <= 4_000_000 ? 4 : 8
        var bins = Array(repeating: 0.0, count: binCount * 3)
        var scope = Array(repeating: 0.0, count: scopeSide * scopeSide)
        func measure(_ bytes: UnsafePointer<UInt8>, _ stride: Int) {
            camera_raw_scope(bytes, image.width, image.height, stride, Int32(step), &bins, &scope, Int32(scopeSide))
        }
        let info = CGBitmapInfo(rawValue: image.bitmapInfo.rawValue)
        if image.bitsPerPixel == 32, image.bitsPerComponent == 8, image.alphaInfo == .premultipliedLast,
           info.intersection(.byteOrderMask).rawValue == 0 || info.contains(.byteOrder32Big),
           let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
            measure(bytes, image.bytesPerRow)
        } else {
            guard let context = try? BrushRaster.context(width: image.width, height: image.height, mask: false),
                  let data = context.data else { return nil }
            BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
            measure(data.assumingMemoryBound(to: UInt8.self), context.bytesPerRow)
        }
        return Self(red: Array(bins[0..<256]), green: Array(bins[256..<512]), blue: Array(bins[512..<768]), vectorscope: scope)
    }

    /// Paints clipped shadows blue and clipped highlights red. The histogram is counted before this.
    static func overlay(_ image: CGImage, shadows: Bool, highlights: Bool) throws -> CGImage {
        guard shadows || highlights else { return image }
        return try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
            adjust_camera_raw_clip_overlay(pixels, width, height, stride, shadows ? 1 : 0, highlights ? 1 : 0)
        }
    }

    /// Preview image plus the scope of the grade itself, without Option-drag or indicator paint.
    static func preview(_ job: FilterJob) throws -> (image: CGImage, scope: Self) {
        let made = try previewResult(job)
        return (made.image, made.scope)
    }

    /// Preview plus Expand to Fit placement metadata from the graded (non-overlay) pass.
    static func previewResult(_ job: FilterJob) throws -> (image: CGImage, scope: Self, geometryExpansion: CameraRawGeometryExpansion?) {
        var grade = job
        grade.cameraRawClipping = nil
        grade.showsShadowClipping = false
        grade.showsHighlightClipping = false
        grade.visualizesPointColor = -1
        grade.showsSharpenMask = false
        let graded = try PixelFilter.runResult(grade)
        let scope = make(graded.image) ?? Self(red: Array(repeating: 0, count: binCount), green: Array(repeating: 0, count: binCount),
                                               blue: Array(repeating: 0, count: binCount), vectorscope: Array(repeating: 0, count: scopeSide * scopeSide))
        if job.cameraRawClipping != nil || job.showsSharpenMask {
            let painted = try PixelFilter.runResult(job)
            return (painted.image, scope, painted.geometryExpansion)
        }
        if job.showsShadowClipping || job.showsHighlightClipping {
            return (try overlay(graded.image, shadows: job.showsShadowClipping, highlights: job.showsHighlightClipping),
                    scope, graded.geometryExpansion)
        }
        return (graded.image, scope, graded.geometryExpansion)
    }
}

extension EditorSession {
    /// The white-balance eyedropper: the clicked pixel of the original layer becomes neutral.
    func sampleCameraRawWhiteBalance(at point: CGPoint) {
        guard let edit = filterEdit, edit.kind == .cameraRaw, edit.samplesWhiteBalance, !edit.committing,
              let document, CGRect(origin: .zero, size: document.size).contains(point) else { return }
        let pixel = point.applying(edit.mapping.inverted())
        let rect = CGRect(x: floor(pixel.x), y: floor(pixel.y), width: 1, height: 1)
        guard pixel.x >= 0, pixel.y >= 0, pixel.x < CGFloat(edit.original.image.width),
              pixel.y < CGFloat(edit.original.image.height), let sample = edit.original.image.cropping(to: rect) else { return }
        do {
            let context = try BrushRaster.context(width: 1, height: 1, mask: false)
            BrushRaster.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1), mask: false, context: context)
            guard let data = context.data else { return }
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            guard bytes[3] > 0 else { return }
            let rgb = (0..<3).map { min(1, Double(bytes[$0]) / Double(bytes[3])) }
            guard let solved = CameraRawSettings.neutralize(straightRed: rgb[0], green: rgb[1], blue: rgb[2]) else { return }
            var settings = edit.settings
            settings.cameraRaw.temperature = solved.temperature
            settings.cameraRaw.tint = solved.tint
            settings.cameraRaw.whiteBalance = .custom
            updateFilter(settings, preview: edit.preview)
        } catch { brushError = error.localizedDescription }
    }

    /// White Balance > Auto. The mode is stored before the scan, so the picker moves on the click.
    /// The average of the original layer is taken off the main thread, then applied only if Auto is still selected.
    func applyCameraRawAutoWhiteBalance() async {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing else { return }
        var settings = edit.settings
        settings.cameraRaw.whiteBalance = .auto
        updateFilter(settings, preview: edit.preview)
        let image = edit.original.image
        let solved = await Task.detached(priority: .userInitiated) {
            CameraRawSettings.autoBalance(of: image)
        }.value
        guard filterEdit === edit, !edit.committing, edit.settings.cameraRaw.whiteBalance == .auto, let solved else { return }
        settings = edit.settings
        settings.cameraRaw.temperature = solved.temperature
        settings.cameraRaw.tint = solved.tint
        updateFilter(settings, preview: edit.preview)
    }

    /// Lens Blur's focus region follows the pointer. Armed from Optics, then dragged on the preview.
    func moveCameraRawLensBlurFocus(to point: CGPoint) {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing,
              let normalized = cameraRawNormalizedPoint(at: point) else { return }
        var settings = edit.settings
        settings.cameraRaw.optics.lensBlur.focusX = Double(normalized.x)
        settings.cameraRaw.optics.lensBlur.focusY = Double(normalized.y)
        updateFilter(settings, preview: edit.preview)
    }

    /// Depth Focus › Set Focus: the clicked point's own depth becomes the sharp band's focus, so whatever is
    /// there stays sharp and the rest of the scene blurs by its distance from it. Armed from Optics as a
    /// one-shot pick; a point with no estimate leaves the settings alone.
    func selectCameraRawLensBlurDepthFocus() {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing else { return }
        guard DepthModel.isReady else { return }
        edit.picksCameraRawLensBlurDepth = true
        edit.movesCameraRawLensBlurFocus = false
        brushRevision += 1
    }

    /// A click while Set Focus is armed: that point's depth becomes the focal distance, then the mode ends.
    func sampleCameraRawLensBlurDepth(at point: CGPoint) {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing, edit.picksCameraRawLensBlurDepth,
              let normalized = cameraRawNormalizedPoint(at: point) else { return }
        defer {
            edit.picksCameraRawLensBlurDepth = false
            brushRevision += 1
        }
        guard let depth = edit.lensBlurDepth(atNormalizedX: Double(normalized.x), y: Double(normalized.y)) else { return }
        var settings = edit.settings
        settings.cameraRaw.optics.lensBlur.focusMode = .depthFocus
        settings.cameraRaw.optics.lensBlur.depthFocalDistance = depth
        edit.settings = settings.normalized
        updateFilter(settings, preview: edit.preview)
    }

    /// Prepares the depth model on an explicit request, then redraws: a download never starts because a panel
    /// was opened. Volumetric Light's own prepare is unchanged.
    func prepareCameraRawLensBlurDepth() async {
        guard let edit = filterEdit, edit.kind == .cameraRaw else { return }
        guard !DepthModel.isReady else {
            // Already loaded: drop the cached "no estimate" and draw the depth-blurred picture.
            edit.invalidateLensBlurDepth()
            updateFilter(edit.settings, preview: edit.preview)
            return
        }
        preparingDepth = true
        let ready = await DepthModel.prepare()
        preparingDepth = false
        guard filterEdit === edit, !edit.committing else { return }
        edit.invalidateLensBlurDepth()
        if ready { updateFilter(edit.settings, preview: edit.preview) }
    }

    /// Miniature's focus follows the pointer. Armed from Geometry, then dragged on the preview,
    /// through the same mapping the Lens Blur move uses.
    func moveCameraRawMiniatureFocus(to point: CGPoint) {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing,
              let normalized = cameraRawNormalizedPoint(at: point) else { return }
        var settings = edit.settings
        settings.cameraRaw.miniature.centerX = Double(normalized.x)
        settings.cameraRaw.miniature.centerY = Double(normalized.y)
        updateFilter(settings, preview: edit.preview)
    }

    /// Arms Miniature focus dragging, capturing the center so Escape can restore it exactly.
    /// Exclusive with the other canvas modes, which are ended here rather than left armed.
    func beginCameraRawMiniatureFocusInteraction() {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing else { return }
        edit.cameraRawMiniatureDragOriginalCenter = edit.settings.cameraRaw.miniature.center
        edit.movesCameraRawMiniatureFocus = true
        edit.drawingCameraRawGeometryGuide = false
        edit.cameraRawGuideDraft = nil
        edit.drawingCameraRawPerspectiveTool = false
        edit.drawingCameraRawHorizonReference = false
        edit.cameraRawHorizonReferenceDraft = nil
        edit.cameraRawHorizonDrawingMode = nil
        brushRevision += 1
    }

    /// Restores the focus center captured when the drag began, without writing any document entry.
    func cancelCameraRawMiniatureFocusInteraction() {
        guard let edit = filterEdit else { return }
        defer {
            edit.movesCameraRawMiniatureFocus = false
            edit.cameraRawMiniatureDragOriginalCenter = nil
        }
        guard let original = edit.cameraRawMiniatureDragOriginalCenter else { return }
        var settings = edit.settings
        settings.cameraRaw.miniature.centerX = Double(original.x)
        settings.cameraRaw.miniature.centerY = Double(original.y)
        edit.settings = settings
        updateFilter(settings, preview: edit.preview)
    }

    /// Ends the armed state, keeping wherever the drag left the focus. A drag that moved nothing
    /// leaves the settings as they were, so no preview render is spent on a no-op.
    func endCameraRawMiniatureFocusInteraction() {
        guard let edit = filterEdit else { return }
        edit.movesCameraRawMiniatureFocus = false
        edit.cameraRawMiniatureDragOriginalCenter = nil
        brushRevision += 1
    }

    // MARK: - Crop After Transform on the image

    /// Arms crop-after-transform editing, capturing the stored rect so Escape can put it back exactly.
    /// Exclusive with the other canvas modes, which are ended here rather than left armed.
    func beginCameraRawCropEditing() {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing else { return }
        edit.cameraRawCropDragOriginalScalars = edit.settings.cameraRaw.crop.manualCropScalars
        edit.editsCameraRawCrop = true
        edit.cameraRawCropDragTarget = nil
        edit.movesCameraRawMiniatureFocus = false
        edit.cameraRawMiniatureDragOriginalCenter = nil
        edit.drawingCameraRawGeometryGuide = false
        edit.cameraRawGuideDraft = nil
        edit.drawingCameraRawPerspectiveTool = false
        edit.drawingCameraRawHorizonReference = false
        edit.cameraRawHorizonReferenceDraft = nil
        edit.cameraRawHorizonDrawingMode = nil
        // The first render while armed draws the full corrected frame to drag from.
        brushRevision += 1
    }

    /// Restores the crop captured when editing was armed, without writing any document entry.
    func cancelCameraRawCropEditing() {
        guard let edit = filterEdit else { return }
        defer {
            edit.editsCameraRawCrop = false
            edit.cameraRawCropDragTarget = nil
            edit.cameraRawCropDragOriginalScalars = nil
        }
        guard let original = edit.cameraRawCropDragOriginalScalars else {
            // Nothing was stored: clearing a rect the person never kept would write history.
            return
        }
        var settings = edit.settings
        settings.cameraRaw.crop.manualCropScalars = original
        edit.settings = settings
        updateFilter(settings, preview: edit.preview)
    }

    /// Ends the armed state. `cancelled` puts the rect captured when arming began back first;
    /// otherwise wherever the drag left it is kept. Either way the re-render without the
    /// neutralizer writes the genuine (possibly cropped) output again.
    func endCameraRawCropEditing(cancelled: Bool) {
        guard let edit = filterEdit else { return }
        if cancelled, let original = edit.cameraRawCropDragOriginalScalars {
            var settings = edit.settings
            settings.cameraRaw.crop.manualCropScalars = original
            edit.settings = settings
        }
        edit.editsCameraRawCrop = false
        edit.cameraRawCropDragTarget = nil
        edit.cameraRawCropDragOriginalScalars = nil
        updateFilter(edit.settings, preview: edit.preview)
    }

    /// Press on the corrected preview while crop editing: a grab of a stored handle, or a fresh
    /// rectangle drawn from the press point when there is none (or nothing was hit).
    func beginCameraRawCropDrag(at point: CGPoint) {
        guard let edit = filterEdit, edit.editsCameraRawCrop, !edit.committing,
              let prepared = edit.preparedPreview, let preparedTransform = edit.preparedTransform else { return }
        let scalars = edit.settings.cameraRaw.crop.manualCropScalars
        let stored = CameraRawCropDragTarget.rectangle
            .rect(scalars: scalars, width: prepared.width, height: prepared.height)
        let hit = stored.flatMap { Self.cropHandle(at: point, in: $0,
                                                    transform: preparedTransform, width: prepared.width, height: prepared.height) }
        edit.cameraRawCropDragOriginalScalars = edit.settings.cameraRaw.crop.manualCropScalars
        if let hit {
            edit.cameraRawCropDragTarget = hit
            return
        }
        // Nothing hit: start a new rectangle here, replacing whatever was stored.
        let corrected = Self.correctedCropPoint(point, transform: preparedTransform,
                                                width: prepared.width, height: prepared.height)
        edit.cameraRawCropDragTarget = .rectangle
        var settings = edit.settings
        settings.cameraRaw.crop.manualCropScalars = [corrected.x, corrected.y, 0, 0]
        edit.settings = settings
        updateFilter(settings, preview: edit.preview)
    }

    /// Drag while crop editing: the grabbed handle or the drawing corner follows the pointer.
    func continueCameraRawCropDrag(to point: CGPoint) {
        guard let edit = filterEdit, edit.editsCameraRawCrop, let target = edit.cameraRawCropDragTarget,
              !edit.committing, let prepared = edit.preparedPreview, let preparedTransform = edit.preparedTransform else { return }
        let bounds = CGRect(x: 0, y: 0, width: prepared.width, height: prepared.height)
        var draft: CGRect
        if target == .rectangle {
            let scalars = edit.settings.cameraRaw.crop.manualCropScalars
            guard scalars.count == 4 else { return }
            let start = CGPoint(x: scalars[0], y: scalars[1])
            let now = Self.correctedCropPoint(point, transform: preparedTransform,
                                              width: prepared.width, height: prepared.height)
            draft = CGRect(x: min(start.x, now.x), y: min(start.y, now.y),
                           width: abs(now.x - start.x), height: abs(now.y - start.y))
        } else {
            let scalars = edit.settings.cameraRaw.crop.manualCropScalars
            guard let stored = CameraRawCropDragTarget.rectangle
                .rect(scalars: scalars, width: prepared.width, height: prepared.height) else { return }
            draft = target.resizing(stored, to: Self.correctedCropPoint(point, transform: preparedTransform,
                                                              width: prepared.width, height: prepared.height))
        }
        draft = draft.intersection(bounds)
        guard draft.width >= 1, draft.height >= 1, draft.width.isFinite, draft.height.isFinite else { return }
        var settings = edit.settings
        settings.cameraRaw.crop.manualCropScalars = [draft.minX, draft.minY, draft.width, draft.height]
        edit.settings = settings
        updateFilter(settings, preview: edit.preview)
    }

    /// Mouse-up: the drag already wrote its rect; disarm the gesture but keep the armed mode,
    /// which stays until Escape, Return or the panel button ends it.
    func endCameraRawCropDrag() {
        guard let edit = filterEdit else { return }
        edit.cameraRawCropDragTarget = nil
    }

    /// A view point in the placed preview → corrected-image pixels (top-left origin), clamped in.
    private static func correctedCropPoint(_ viewPoint: CGPoint, transform: LayerTransform,
                                           width: Int, height: Int) -> CGPoint {
        let toPixels = BrushRaster.pixelToDocument(transform, width: width, height: height).inverted()
        let pixel = viewPoint.applying(toPixels)
        return CGPoint(x: min(max(pixel.x, 0), CGFloat(width)), y: min(max(pixel.y, 0), CGFloat(height)))
    }

    /// The handle of `rect` (corrected pixels, placed by `transform`) under a view point, if any.
    private static func cropHandle(at viewPoint: CGPoint, in rect: CGRect, transform: LayerTransform,
                                   width: Int, height: Int) -> CameraRawCropDragTarget? {
        let toDocument = BrushRaster.pixelToDocument(transform, width: width, height: height)
        let toPixels = toDocument.inverted()
        let corners: [(CameraRawCropDragTarget, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)), (.topEdge, CGPoint(x: rect.midX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)), (.rightEdge, CGPoint(x: rect.maxX, y: rect.midY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)), (.bottomEdge, CGPoint(x: rect.midX, y: rect.maxY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)), (.leftEdge, CGPoint(x: rect.minX, y: rect.midY)),
        ]
        let tolerance = 12 / max(sqrt(abs(toDocument.a * toDocument.d - toDocument.b * toDocument.c)), 0.001)
        let viewPixel = viewPoint.applying(toPixels)
        for (target, pixel) in corners where hypot(viewPixel.x - pixel.x, viewPixel.y - pixel.y) <= tolerance {
            return target
        }
        let edges = rect.applying(toDocument)
        return edges.contains(viewPoint) ? .rectangle : nil
    }

    /// Defringe eyedropper: centers the purple or green hue range on the clicked fringe color.
    func sampleCameraRawDefringe(at point: CGPoint) {
        guard let edit = filterEdit, edit.kind == .cameraRaw, edit.samplesDefringe, !edit.committing,
              let document, CGRect(origin: .zero, size: document.size).contains(point) else { return }
        let pixel = point.applying(edit.mapping.inverted())
        let rect = CGRect(x: floor(pixel.x), y: floor(pixel.y), width: 1, height: 1)
        guard pixel.x >= 0, pixel.y >= 0, pixel.x < CGFloat(edit.original.image.width),
              pixel.y < CGFloat(edit.original.image.height), let sample = edit.original.image.cropping(to: rect) else { return }
        do {
            let context = try BrushRaster.context(width: 1, height: 1, mask: false)
            BrushRaster.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1), mask: false, context: context)
            guard let data = context.data else { return }
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            guard bytes[3] > 0 else { return }
            let r = min(1, Double(bytes[0]) / Double(bytes[3]))
            let g = min(1, Double(bytes[1]) / Double(bytes[3]))
            let b = min(1, Double(bytes[2]) / Double(bytes[3]))
            let hue = Self.hueDegrees(red: r, green: g, blue: b)
            var settings = edit.settings
            let purpleCenter = 290.0, greenCenter = 90.0
            let span = 25.0
            if abs(hue - purpleCenter) < abs(hue - greenCenter) {
                settings.cameraRaw.optics.purpleHueLow = hue - span
                settings.cameraRaw.optics.purpleHueHigh = hue + span
                if settings.cameraRaw.optics.purpleAmount == 0 { settings.cameraRaw.optics.purpleAmount = 50 }
            } else {
                settings.cameraRaw.optics.greenHueLow = hue - span
                settings.cameraRaw.optics.greenHueHigh = hue + span
                if settings.cameraRaw.optics.greenAmount == 0 { settings.cameraRaw.optics.greenAmount = 50 }
            }
            settings.cameraRaw.optics = settings.cameraRaw.optics.normalized
            updateFilter(settings, preview: edit.preview)
        } catch { brushError = error.localizedDescription }
    }

    private static func hueDegrees(red: Double, green: Double, blue: Double) -> Double {
        let maxc = max(red, green, blue), minc = min(red, green, blue)
        let chroma = maxc - minc
        guard chroma > 1e-6 else { return 0 }
        let hue: Double
        if maxc == red { hue = (green - blue) / chroma }
        else if maxc == green { hue = 2 + (blue - red) / chroma }
        else { hue = 4 + (red - green) / chroma }
        var degrees = hue * 60
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    /// RGB under the pointer while Camera Raw is open. Outside the layer clears the readout.
    func updateCameraRawReadout(at point: CGPoint) {
        guard let edit = filterEdit, edit.kind == .cameraRaw else { return }
        let image = edit.preparedPreview ?? edit.previewSource
        let pixel = point.applying(edit.previewMapping.inverted())
        let rect = CGRect(x: floor(pixel.x), y: floor(pixel.y), width: 1, height: 1)
        guard pixel.x >= 0, pixel.y >= 0, pixel.x < CGFloat(image.width), pixel.y < CGFloat(image.height),
              let sample = image.cropping(to: rect) else {
            edit.cameraRawReadout = nil
            return
        }
        guard let context = try? BrushRaster.context(width: 1, height: 1, mask: false) else { return }
        BrushRaster.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1), mask: false, context: context)
        guard let data = context.data else { return }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        guard bytes[3] > 0 else { edit.cameraRawReadout = nil; return }
        let straight = (0..<3).map { min(255, (Int(bytes[$0]) * 255 + Int(bytes[3]) / 2) / Int(bytes[3])) }
        edit.cameraRawReadout = (straight[0], straight[1], straight[2])
    }

    func beginCameraRawDrag(at point: CGPoint) {
        guard let edit = filterEdit, edit.kind == .cameraRaw, let sample = cameraRawSample(at: point) else { return }
        edit.cameraRawDrag = CameraRawDrag(startY: point.y, settings: edit.settings.cameraRaw, tone: sample.tone, hue: sample.hue)
    }

    func dragCameraRaw(to point: CGPoint) {
        guard let edit = filterEdit, let drag = edit.cameraRawDrag else { return }
        let delta = Double(drag.startY - point.y) * 0.35
        var settings = edit.settings
        settings.cameraRaw = drag.settings
        if edit.targetsCameraRawCurve {
            if edit.cameraRawCurvePage == .parametric {
                let key = drag.settings.curve.region(for: drag.tone)
                settings.cameraRaw.curve[keyPath: key] = min(100, max(-100, drag.settings.curve[keyPath: key] + delta))
            } else {
                settings.cameraRaw.curve = drag.settings.curve.nudged(edit.cameraRawPointChannel, near: drag.tone, by: delta / 100)
            }
        } else if edit.targetsCameraRawMixer {
            let weights = CameraRawMixerSettings.weights(forHue: drag.hue)
            for index in 0..<8 where weights[index] > 0 {
                switch edit.cameraRawMixerTab {
                case .hue:
                    settings.cameraRaw.mixer.hue[index] = min(100, max(-100, drag.settings.mixer.hue[index] + delta * weights[index]))
                case .saturation:
                    settings.cameraRaw.mixer.saturation[index] = min(100, max(-100, drag.settings.mixer.saturation[index] + delta * weights[index]))
                case .luminance:
                    settings.cameraRaw.mixer.luminance[index] = min(100, max(-100, drag.settings.mixer.luminance[index] + delta * weights[index]))
                }
            }
        }
        updateFilter(settings, preview: edit.preview)
    }

    func sampleCameraRawPointColor(at point: CGPoint) {
        guard let edit = filterEdit, edit.samplesPointColor, let sample = cameraRawSample(at: point) else { return }
        var settings = edit.settings
        var color = CameraRawPointColor(hue: sample.hue, saturation: sample.saturation, luminance: sample.luminance)
        if settings.cameraRaw.mixer.points.indices.contains(edit.cameraRawPointIndex) {
            color.hueShift = settings.cameraRaw.mixer.points[edit.cameraRawPointIndex].hueShift
            color.saturationShift = settings.cameraRaw.mixer.points[edit.cameraRawPointIndex].saturationShift
            color.luminanceShift = settings.cameraRaw.mixer.points[edit.cameraRawPointIndex].luminanceShift
            settings.cameraRaw.mixer.points[edit.cameraRawPointIndex] = color
        } else if settings.cameraRaw.mixer.points.count < 8 {
            settings.cameraRaw.mixer.points.append(color)
            edit.cameraRawPointIndex = settings.cameraRaw.mixer.points.count - 1
        }
        updateFilter(settings, preview: edit.preview)
    }

    /// Auto Level / Vertical / Full: detect guides on the preview source and refresh.
    func applyCameraRawUprightDetection() async {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing else { return }
        let mode = edit.settings.cameraRaw.geometry.upright
        guard mode.isAuto else { return }
        let image = edit.previewSource
        let version = edit.previewSourceVersion
        let observation = await Task.detached(priority: .userInitiated) {
            CameraRawUprightDetection.observe(in: image, mode: mode)
        }.value
        guard let current = filterEdit, CameraRawUprightDetection.shouldApply(
            mode: mode, current: current.settings.cameraRaw.geometry.upright,
            version: version, currentVersion: current.previewSourceVersion, committing: current.committing
        ) else { return }
        var settings = current.settings
        // A miss leaves the picture alone. Guided lines stashed on the edit are put back if the user returns to Guided.
        settings.cameraRaw.geometry.guides = observation.guides
        current.cameraRawUprightDetectionAttempted = true
        updateFilter(settings, preview: current.preview)
    }

    func beginCameraRawGeometryGuide(at point: CGPoint) {
        guard let edit = filterEdit, edit.kind == .cameraRaw, edit.drawingCameraRawGeometryGuide,
              let normalized = cameraRawNormalizedPoint(at: point) else { return }
        edit.cameraRawGuideDraft = (start: normalized, end: normalized)
    }

    /// Arms Guided Upright drawing. Exclusive with the advanced tools and Horizon reference drawing: only one
    /// canvas geometry mode may consume the next drag.
    func beginCameraRawGeometryGuideDrawing() {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing else { return }
        edit.drawingCameraRawPerspectiveTool = false
        edit.cameraRawPerspectiveDraft = nil
        edit.cameraRawPerspectiveCornerDraft = nil
        edit.drawingCameraRawHorizonReference = false
        edit.cameraRawHorizonReferenceDraft = nil
        edit.cameraRawHorizonDrawingMode = nil
        edit.movesCameraRawMiniatureFocus = false
        edit.cameraRawMiniatureDragOriginalCenter = nil
        edit.drawingCameraRawGeometryGuide = true
        brushRevision += 1
    }

    func endCameraRawGeometryGuideDrawing() {
        guard let edit = filterEdit else { return }
        edit.drawingCameraRawGeometryGuide = false
        edit.cameraRawGuideDraft = nil
        edit.cameraRawDraggingGuideIndex = nil
        edit.cameraRawDraggingEndpoint = false
        brushRevision += 1
    }

    func continueCameraRawGeometryGuide(to point: CGPoint) {
        guard let edit = filterEdit, edit.drawingCameraRawGeometryGuide, let normalized = cameraRawNormalizedPoint(at: point) else { return }
        guard var draft = edit.cameraRawGuideDraft else { return }
        draft.end = normalized
        edit.cameraRawGuideDraft = draft
    }

    func commitCameraRawGeometryGuide() {
        guard let edit = filterEdit, let draft = edit.cameraRawGuideDraft else { return }
        defer {
            edit.cameraRawGuideDraft = nil
            edit.cameraRawDraggingGuideIndex = nil
            edit.cameraRawDraggingEndpoint = false
        }
        // Prevent malformed or zero-length guides from entering committed settings.
        guard hypot(draft.end.x - draft.start.x, draft.end.y - draft.start.y) > 0.01 else { return }
        var settings = edit.settings
        // Enforce the maximum of four manual guides.
        guard settings.cameraRaw.geometry.guides.count < 4 else { return }
        settings.cameraRaw.geometry.guides.append(CameraRawGeometryGuide(startX: draft.start.x, startY: draft.start.y,
                                                                         endX: draft.end.x, endY: draft.end.y))
        settings.cameraRaw.geometry.upright = .guided
        updateFilter(settings, preview: edit.preview)
    }

    /// Hit-tests a Camera Raw guide endpoint at a document point, returning the guide index and
    /// whether the endpoint is the end (`true`) or the start (`false`). Tolerance scales with zoom.
    func cameraRawHitGuideEndpoint(at documentPoint: CGPoint, zoom: CGFloat) -> (guideIndex: Int, endpoint: Bool)? {
        guard let edit = filterEdit else { return nil }
        let geometry = edit.settings.cameraRaw.geometry
        guard !geometry.guides.isEmpty else { return nil }
        let image = edit.previewSource
        let tolerance = 14.0 / max(zoom, 0.001)
        for index in geometry.guides.indices {
            let guide = geometry.guides[index]
            for endpoint in [false, true] {
                let normalized = endpoint ? guide.end : guide.start
                let pixel = CGPoint(x: normalized.x * CGFloat(image.width), y: normalized.y * CGFloat(image.height))
                let documentPointForEndpoint = pixel.applying(edit.previewMapping)
                let dx = documentPoint.x - documentPointForEndpoint.x
                let dy = documentPoint.y - documentPointForEndpoint.y
                if hypot(dx, dy) <= tolerance {
                    return (index, endpoint)
                }
            }
        }
        return nil
    }

    /// Begins dragging a Camera Raw guide endpoint. The opposite endpoint stays fixed.
    /// Captures the original guide coordinates so Escape can restore them exactly.
    func beginCameraRawGuideEndpointDrag(at documentPoint: CGPoint, zoom: CGFloat) {
        guard let edit = filterEdit else { return }
        guard let hit = cameraRawHitGuideEndpoint(at: documentPoint, zoom: zoom) else { return }
        edit.cameraRawDraggingGuideIndex = hit.guideIndex
        edit.cameraRawDraggingEndpoint = hit.endpoint
        edit.cameraRawDragOriginalGuide = edit.settings.cameraRaw.geometry.guides[hit.guideIndex]
    }

    /// Moves the currently dragged endpoint to a document point. The opposite endpoint is unchanged.
    func continueCameraRawGuideEndpointDrag(to documentPoint: CGPoint) {
        guard let edit = filterEdit, let guideIndex = edit.cameraRawDraggingGuideIndex,
              edit.settings.cameraRaw.geometry.guides.indices.contains(guideIndex) else { return }
        var settings = edit.settings
        let image = edit.previewSource
        guard let normalized = cameraRawNormalizedPoint(at: documentPoint) else { return }
        var guide = settings.cameraRaw.geometry.guides[guideIndex]
        if edit.cameraRawDraggingEndpoint {
            guide.endX = normalized.x
            guide.endY = normalized.y
        } else {
            guide.startX = normalized.x
            guide.startY = normalized.y
        }
        settings.cameraRaw.geometry.guides[guideIndex] = guide
        edit.settings = settings
        updateFilter(settings, preview: edit.preview)
    }

    /// Cancels an in-progress endpoint drag, restoring the guide to its original coordinates.
    func cancelCameraRawGuideEndpointDrag() {
        guard let edit = filterEdit else { return }
        defer {
            edit.cameraRawDraggingGuideIndex = nil
            edit.cameraRawDraggingEndpoint = false
            edit.cameraRawDragOriginalGuide = nil
        }
        guard let guideIndex = edit.cameraRawDraggingGuideIndex,
              edit.settings.cameraRaw.geometry.guides.indices.contains(guideIndex),
              let original = edit.cameraRawDragOriginalGuide else { return }
        // Restore the exact coordinates captured at drag start; no document commit occurs during cancellation.
        var settings = edit.settings
        settings.cameraRaw.geometry.guides[guideIndex] = original
        edit.settings = settings
    }

    // MARK: - Advanced Perspective Tools

    /// Arms the selected advanced tool for drawing on the preview. Refuses the two tools that have no on-image
    /// handles, and ends Guided Upright and Horizon reference drawing, so exactly one mode owns the next drag.
    func beginCameraRawPerspectiveToolDrawing() {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing else { return }
        let tool = edit.settings.cameraRaw.perspectiveTools.kind
        guard tool.drawsOnCanvas else { return }
        cancelCameraRawPerspectiveDraft()
        edit.drawingCameraRawPerspectiveTool = true
        edit.drawingCameraRawGeometryGuide = false
        edit.cameraRawGuideDraft = nil
        edit.cameraRawDraggingGuideIndex = nil
        edit.cameraRawDraggingEndpoint = false
        edit.drawingCameraRawHorizonReference = false
        edit.cameraRawHorizonReferenceDraft = nil
        edit.cameraRawHorizonDrawingMode = nil
        edit.movesCameraRawMiniatureFocus = false
        edit.cameraRawMiniatureDragOriginalCenter = nil
        brushRevision += 1
    }

    func endCameraRawPerspectiveToolDrawing() {
        guard let edit = filterEdit else { return }
        cancelCameraRawPerspectiveDraft()
        edit.drawingCameraRawPerspectiveTool = false
        brushRevision += 1
    }

    /// Drops an unfinished guide and any in-progress handle drag without touching committed geometry.
    /// The drag's original point goes back where it was, so the stored correction is exactly as it was before.
    func cancelCameraRawPerspectiveDraft() {
        guard let edit = filterEdit else { return }
        if let target = edit.cameraRawPerspectiveDragTarget,
           let original = edit.cameraRawPerspectiveDragOriginalPoint {
            var settings = edit.settings
            if CameraRawPerspectiveTools.setPoint(original, for: target,
                                                  in: &settings.cameraRaw.perspectiveTools) {
                edit.settings = settings
                updateFilter(settings, preview: edit.preview)
            }
        }
        edit.cameraRawPerspectiveDragTarget = nil
        edit.cameraRawPerspectiveDragOriginalPoint = nil
        edit.cameraRawPerspectiveDraft = nil
        edit.cameraRawPerspectiveCornerDraft = nil
    }

    /// Registered handles the pointer may grab, converted to document points through the same mapping the overlay
    /// draws with, so a handle can never be drawn in one place and grabbed in another.
    func cameraRawHitPerspectiveHandle(at documentPoint: CGPoint,
                                       zoom: CGFloat) -> CameraRawPerspectiveDragTarget? {
        guard let edit = filterEdit, edit.kind == .cameraRaw else { return nil }
        let state = edit.settings.cameraRaw.perspectiveTools
        guard state.kind.drawsOnCanvas else { return nil }
        let image = edit.previewSource
        let tolerance = 12.0 / max(zoom, 0.001)
        var best: (target: CameraRawPerspectiveDragTarget, distance: CGFloat)?
        for target in CameraRawPerspectiveTools.dragTargets(for: state) {
            guard let normalized = CameraRawPerspectiveTools.point(for: target, in: state) else { continue }
            let pixel = CGPoint(x: normalized.x * CGFloat(image.width), y: normalized.y * CGFloat(image.height))
            let document = pixel.applying(edit.previewMapping)
            let distance = hypot(documentPoint.x - document.x, documentPoint.y - document.y)
            if distance <= tolerance, distance < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (target, distance)
            }
        }
        return best?.target
    }

    /// Starts a press on the preview for the armed advanced tool: grab a handle if one is under the pointer,
    /// otherwise begin a new guide (or place the next rectangle corner).
    func beginCameraRawPerspectiveToolInteraction(at documentPoint: CGPoint, zoom: CGFloat) {
        guard let edit = filterEdit, edit.kind == .cameraRaw, edit.drawingCameraRawPerspectiveTool,
              let normalized = cameraRawNormalizedPoint(at: documentPoint) else { return }
        // Handles win over starting something new, in Rectangle too: a placed corner must stay draggable.
        if let target = cameraRawHitPerspectiveHandle(at: documentPoint, zoom: zoom),
           let point = CameraRawPerspectiveTools.point(for: target, in: edit.settings.cameraRaw.perspectiveTools) {
            edit.cameraRawPerspectiveDragTarget = target
            edit.cameraRawPerspectiveDragOriginalPoint = point
            return
        }
        if edit.settings.cameraRaw.perspectiveTools.kind == .rectangle {
            placeCameraRawPerspectiveCorner(at: normalized)
            return
        }
        edit.cameraRawPerspectiveDraft = (start: normalized, end: normalized)
    }

    /// Continues a press: moves the grabbed handle, or extends the guide being drawn.
    func continueCameraRawPerspectiveToolInteraction(to documentPoint: CGPoint) {
        guard let edit = filterEdit, edit.drawingCameraRawPerspectiveTool,
              let normalized = cameraRawNormalizedPoint(at: documentPoint) else { return }
        if let target = edit.cameraRawPerspectiveDragTarget {
            var settings = edit.settings
            guard CameraRawPerspectiveTools.setPoint(normalized, for: target,
                                                     in: &settings.cameraRaw.perspectiveTools) else {
                // The handle no longer exists (cleared mid-drag): end the drag rather than write to nothing.
                edit.cameraRawPerspectiveDragTarget = nil
                edit.cameraRawPerspectiveDragOriginalPoint = nil
                return
            }
            updateFilter(settings, preview: edit.preview)
            return
        }
        guard var draft = edit.cameraRawPerspectiveDraft else { return }
        draft.end = normalized
        edit.cameraRawPerspectiveDraft = draft
        brushRevision += 1
    }

    /// Ends a press: commits a finished guide, or leaves a handle where it was dragged to.
    /// A guide that is too short to read is discarded, so a stray click never changes the picture.
    func endCameraRawPerspectiveToolInteraction() {
        guard let edit = filterEdit else { return }
        if edit.cameraRawPerspectiveDragTarget != nil {
            edit.cameraRawPerspectiveDragTarget = nil
            edit.cameraRawPerspectiveDragOriginalPoint = nil
            return
        }
        guard let draft = edit.cameraRawPerspectiveDraft else { return }
        edit.cameraRawPerspectiveDraft = nil
        guard hypot(draft.end.x - draft.start.x, draft.end.y - draft.start.y) > 0.01 else { return }
        let tool = edit.settings.cameraRaw.perspectiveTools.kind
        guard let list = guideList(for: tool, verticalFrom: draft) else { return }
        var settings = edit.settings
        let guide = CameraRawGeometryGuide(startX: draft.start.x, startY: draft.start.y,
                                          endX: draft.end.x, endY: draft.end.y)
        guard CameraRawPerspectiveTools.appendGuide(guide, to: list,
                                                    in: &settings.cameraRaw.perspectiveTools) else { return }
        updateFilter(settings, preview: edit.preview)
    }

    /// Which list a finished guide belongs in. Combined Guides sorts by the line's own direction so the two lists
    /// stay meaningful; Vertical and Horizontal Guides take the line as given, whatever its angle.
    private func guideList(for tool: CameraRawPerspectiveToolKind,
                           verticalFrom draft: (start: CGPoint, end: CGPoint)) -> CameraRawPerspectiveGuideList? {
        switch tool {
        case .verticalGuides: return .vertical
        case .horizontalGuides: return .horizontal
        case .combinedGuides:
            return abs(draft.end.y - draft.start.y) >= abs(draft.end.x - draft.start.x) ? .vertical : .horizontal
        case .eightPoint: return .eightPoint
        case .automatic, .rectangle, .manualKeystone: return nil
        }
    }

    /// Places the next rectangle corner. The fourth corner completes the quad; an invalid quad is never stored,
    /// so an unfinished or self-crossing rectangle cannot silently apply a stale correction.
    func placeCameraRawPerspectiveCorner(at normalized: CGPoint) {
        guard let edit = filterEdit, edit.settings.cameraRaw.perspectiveTools.kind == .rectangle else { return }
        var settings = edit.settings
        var corners = settings.cameraRaw.perspectiveTools.rectangleCorners
        guard corners.count < 4 else {
            edit.cameraRawPerspectiveCornerDraft = nil
            return
        }
        corners.append(normalized)
        settings.cameraRaw.perspectiveTools.rectangleCorners = corners
        edit.cameraRawPerspectiveCornerDraft = corners.count == 4 ? nil : normalized
        // Three corners are a construction in progress: they render as handles but must not warp the picture.
        updateFilter(settings, preview: edit.preview)
    }

    /// Removes the last placed rectangle corner, or the whole rectangle when it is complete.
    func removeLastCameraRawPerspectiveCorner() {
        guard let edit = cameraRawEdit(), edit.settings.cameraRaw.perspectiveTools.kind == .rectangle else { return }
        var settings = edit.settings
        var corners = settings.cameraRaw.perspectiveTools.rectangleCorners
        guard !corners.isEmpty else { return }
        corners.removeLast()
        settings.cameraRaw.perspectiveTools.rectangleCorners = corners
        edit.cameraRawPerspectiveCornerDraft = corners.last
        updateFilter(settings, preview: edit.preview)
    }

    /// The Camera Raw edit that may still be changed, or nil while it is committing or absent.
    private func cameraRawEdit() -> FilterEdit? {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing else { return nil }
        return edit
    }

    /// Deletes the guide or corner under the pointer, if the active tool has one there.
    func deleteCameraRawPerspectiveHandle(at documentPoint: CGPoint, zoom: CGFloat) -> Bool {
        guard let edit = cameraRawEdit(),
              let target = cameraRawHitPerspectiveHandle(at: documentPoint, zoom: zoom) else {
            return false
        }
        var settings = edit.settings
        var state = settings.cameraRaw.perspectiveTools
        switch target {
        case .guide(let list, let index, _):
            var guides = state.guides(in: list)
            guard guides.indices.contains(index) else { return false }
            guides.remove(at: index)
            state.setGuides(guides, in: list)
        case .corner(let index):
            // A rectangle is one object: removing one of four corners would leave a shape that is not a rectangle.
            // If it is complete, the whole rectangle goes; while it is being drawn, the last corner does.
            var corners = state.rectangleCorners
            guard !corners.isEmpty else { return false }
            if corners.count == 4 {
                corners = []
                edit.cameraRawPerspectiveCornerDraft = nil
            } else if index == corners.count - 1 {
                corners.removeLast()
                edit.cameraRawPerspectiveCornerDraft = corners.last
            } else {
                return false
            }
            state.rectangleCorners = corners
        }
        settings.cameraRaw.perspectiveTools = state
        updateFilter(settings, preview: edit.preview)
        return true
    }

    /// Clears the active tool's own points. Other tools' work stays, and the tool stays selected.
    func clearCameraRawPerspectiveTool() {
        guard let edit = cameraRawEdit() else { return }
        var settings = edit.settings
        let tool = settings.cameraRaw.perspectiveTools.kind
        CameraRawPerspectiveTools.clear(tool, in: &settings.cameraRaw.perspectiveTools)
        edit.cameraRawPerspectiveDraft = nil
        edit.cameraRawPerspectiveCornerDraft = nil
        edit.cameraRawPerspectiveDragTarget = nil
        edit.cameraRawPerspectiveDragOriginalPoint = nil
        updateFilter(settings, preview: edit.preview)
    }

    /// Selects a tool without disturbing the others' stored points. Leaving a drawing tool ends its drag and
    /// drops anything unfinished, so a half-drawn guide can never be committed under a different tool.
    func selectCameraRawPerspectiveTool(_ tool: CameraRawPerspectiveToolKind) {
        guard let edit = cameraRawEdit() else { return }
        if edit.settings.cameraRaw.perspectiveTools.kind == tool {
            if !tool.drawsOnCanvas { endCameraRawPerspectiveToolDrawing() }
            return
        }
        cancelCameraRawPerspectiveDraft()
        var settings = edit.settings
        settings.cameraRaw.perspectiveTools.kind = tool
        // The keystone sliders are the owner; the mirror follows them on every switch.
        settings.cameraRaw.perspectiveTools.synchronizingManual(with: settings.cameraRaw.geometry)
        if !tool.drawsOnCanvas { edit.drawingCameraRawPerspectiveTool = false }
        // Upright stays exactly as it was stored. `applying` gives the selected tool the picture and returns Upright
        // to it untouched when Automatic is chosen again, so switching tools never costs a Guided correction.
        updateFilter(settings, preview: edit.preview)
        brushRevision += 1
    }

    /// What the panel says about the active tool's stored points right now, if anything is wrong.
    /// Nil while the tool has nothing to say: incomplete is only a problem for the tools that apply nothing.
    var cameraRawPerspectiveToolIssue: CameraRawPerspectiveToolIssue? {
        guard let edit = filterEdit, edit.kind == .cameraRaw else { return nil }
        let image = edit.previewSource
        return CameraRawPerspectiveTools.problem(in: edit.settings.cameraRaw.perspectiveTools,
                                                 width: image.width, height: image.height)
    }

    // MARK: - Horizon reference line

    /// Arms Horizon › Horizontal Reference / Vertical Reference so the next drag on the preview defines the line.
    /// Exclusive with Guided Upright drawing: only one of the two can own a drag.
    func beginCameraRawHorizonReferenceDrawing() {
        guard let edit = filterEdit, edit.kind == .cameraRaw else { return }
        let mode = edit.settings.cameraRaw.horizon.mode
        guard mode == .horizontalReference || mode == .verticalReference else { return }
        edit.drawingCameraRawHorizonReference = true
        edit.cameraRawHorizonDrawingMode = mode
        edit.cameraRawHorizonReferenceDraft = nil
        edit.drawingCameraRawGeometryGuide = false
        edit.cameraRawGuideDraft = nil
        edit.drawingCameraRawPerspectiveTool = false
        edit.cameraRawPerspectiveDraft = nil
        edit.cameraRawPerspectiveCornerDraft = nil
        edit.movesCameraRawMiniatureFocus = false
        edit.cameraRawMiniatureDragOriginalCenter = nil
        brushRevision += 1
    }

    func endCameraRawHorizonReferenceDrawing() {
        guard let edit = filterEdit else { return }
        edit.drawingCameraRawHorizonReference = false
        edit.cameraRawHorizonDrawingMode = nil
        edit.cameraRawHorizonReferenceDraft = nil
        brushRevision += 1
    }

    /// Starts the reference line at a document point. A stroke replaces the previous line rather than
    /// accumulating: one reference is what both reference modes read.
    func beginCameraRawHorizonReference(at documentPoint: CGPoint) {
        guard let edit = filterEdit, edit.drawingCameraRawHorizonReference,
              let normalized = cameraRawNormalizedPoint(at: documentPoint) else { return }
        edit.cameraRawHorizonReferenceDraft = (start: normalized, end: normalized)
    }

    func continueCameraRawHorizonReference(to documentPoint: CGPoint) {
        guard let edit = filterEdit, edit.drawingCameraRawHorizonReference,
              var draft = edit.cameraRawHorizonReferenceDraft,
              let normalized = cameraRawNormalizedPoint(at: documentPoint) else { return }
        draft.end = normalized
        edit.cameraRawHorizonReferenceDraft = draft
    }

    /// Commits the drawn line into the Horizon settings. A line too short to read its angle is discarded.
    func commitCameraRawHorizonReference() {
        guard let edit = filterEdit, let draft = edit.cameraRawHorizonReferenceDraft else { return }
        defer { edit.cameraRawHorizonReferenceDraft = nil }
        guard hypot(draft.end.x - draft.start.x, draft.end.y - draft.start.y) > 0.01 else { return }
        var settings = edit.settings
        settings.cameraRaw.horizon.referenceStartX = min(1, max(0, draft.start.x))
        settings.cameraRaw.horizon.referenceStartY = min(1, max(0, draft.start.y))
        settings.cameraRaw.horizon.referenceEndX = min(1, max(0, draft.end.x))
        settings.cameraRaw.horizon.referenceEndY = min(1, max(0, draft.end.y))
        edit.settings = settings
        updateFilter(settings, preview: edit.preview)
    }

    /// The drawn line, normalized, for tests and for the panel's own summary.
    var cameraRawHorizonReferenceLine: CameraRawGeometryGuide? {
        guard let edit = filterEdit else { return nil }
        let horizon = edit.settings.cameraRaw.horizon
        return CameraRawGeometryGuide(startX: horizon.referenceStartX, startY: horizon.referenceStartY,
                                      endX: horizon.referenceEndX, endY: horizon.referenceEndY)
    }

    /// Clears the reference line back to the default left-to-right line along the bottom edge.
    func clearCameraRawHorizonReference() {
        guard let edit = filterEdit, edit.kind == .cameraRaw else { return }
        var settings = edit.settings
        let base = CameraRawHorizonSettings()
        settings.cameraRaw.horizon.referenceStartX = base.referenceStartX
        settings.cameraRaw.horizon.referenceStartY = base.referenceStartY
        settings.cameraRaw.horizon.referenceEndX = base.referenceEndX
        settings.cameraRaw.horizon.referenceEndY = base.referenceEndY
        edit.settings = settings
        edit.cameraRawHorizonReferenceDraft = nil
        updateFilter(settings, preview: edit.preview)
    }

    /// Horizon › Automatic: measure the picture's own level once and keep the angle beside the settings.
    /// The angle is not persisted; the mode is, so reopening a project re-measures nothing behind the person's back.
    func applyCameraRawHorizonAutomatic() async {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing else { return }
        let image = edit.previewSource
        let version = edit.previewSourceVersion
        let observation = await Task.detached(priority: .userInitiated) {
            CameraRawUprightDetection.observe(in: image, mode: .autoLevel)
        }.value
        guard let current = filterEdit, !current.committing,
              current.previewSourceVersion == version,
              current.settings.cameraRaw.horizon.mode == .automatic else { return }
        var settings = current.settings
        settings.cameraRaw.automaticHorizonAngle = CameraRawHorizon.automaticAngle(
            from: observation, width: image.width, height: image.height)
        current.settings = settings
        updateFilter(settings, preview: current.preview)
    }

    func cameraRawNormalizedPoint(at point: CGPoint) -> CGPoint? {
        guard let edit = filterEdit else { return nil }
        let image = edit.previewSource
        let pixel = point.applying(edit.previewMapping.inverted())
        guard pixel.x >= 0, pixel.y >= 0, pixel.x < CGFloat(image.width), pixel.y < CGFloat(image.height) else { return nil }
        return CGPoint(x: pixel.x / CGFloat(image.width), y: pixel.y / CGFloat(image.height))
    }

    private func cameraRawSample(at point: CGPoint) -> (tone: Double, hue: Double, saturation: Double, luminance: Double)? {
        guard let edit = filterEdit else { return nil }
        let image = edit.preparedPreview ?? edit.previewSource
        let pixel = point.applying(edit.previewMapping.inverted())
        let rect = CGRect(x: floor(pixel.x), y: floor(pixel.y), width: 1, height: 1)
        guard pixel.x >= 0, pixel.y >= 0, pixel.x < CGFloat(image.width), pixel.y < CGFloat(image.height),
              let sample = image.cropping(to: rect),
              let context = try? BrushRaster.context(width: 1, height: 1, mask: false) else { return nil }
        BrushRaster.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1), mask: false, context: context)
        guard let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        guard bytes[3] > 0 else { return nil }
        let red = min(1, Double(bytes[0]) / Double(bytes[3]))
        let green = min(1, Double(bytes[1]) / Double(bytes[3]))
        let blue = min(1, Double(bytes[2]) / Double(bytes[3]))
        let maxChannel = max(red, green, blue), minChannel = min(red, green, blue)
        let chroma = maxChannel - minChannel
        var hue = 0.0
        if chroma > 1e-6 {
            if maxChannel == red { hue = (green - blue) / chroma }
            else if maxChannel == green { hue = 2 + (blue - red) / chroma }
            else { hue = 4 + (red - green) / chroma }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let tone = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let saturation = maxChannel == 0 ? 0 : chroma / maxChannel
        return (tone, hue * 360, saturation, (maxChannel + minChannel) / 2)
    }
}
