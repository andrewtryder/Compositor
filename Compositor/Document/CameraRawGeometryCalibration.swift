import AppKit
import CoreImage

nonisolated enum CameraRawUprightMode: String, CaseIterable, Sendable, Codable {
    case off = "Off"
    case autoLevel = "Auto Level"
    case autoVertical = "Auto Vertical"
    case autoFull = "Auto Full"
    case guided = "Guided"

    var isAuto: Bool {
        self == .autoLevel || self == .autoVertical || self == .autoFull
    }
}

nonisolated enum CameraRawProjection: String, CaseIterable, Sendable, Codable {
    case perspective = "Perspective"
    case rectilinear = "Rectilinear"
}

/// How the warped picture is framed after perspective.
/// Expand to Fit grows the layer footprint via `CameraRawGeometryExpansion`; Keep Original Size is the legacy path.
nonisolated enum CameraRawFramingMode: String, CaseIterable, Sendable, Codable {
    case keepOriginalSize = "Keep Original Size"
    case expandToFit = "Expand to Fit"
}

/// Volume (anamorphosis) mode matching ViewPoint modes 0–3.
nonisolated enum CameraRawVolumeMode: String, CaseIterable, Sendable, Codable {
    case radial = "Radial"
    case horizontal = "Horizontal"
    case vertical = "Vertical"
    case horizontalAndVertical = "Horizontal & Vertical"

    var kernelValue: Int32 {
        switch self {
        case .radial: return 0
        case .horizontal: return 1
        case .vertical: return 2
        case .horizontalAndVertical: return 3
        }
    }
}

/// A guide line in normalized image coordinates, 0…1 from the lower-left of the pixel grid.
nonisolated struct CameraRawGeometryGuide: Equatable, Sendable, Codable {
    var startX: Double = 0
    var startY: Double = 0
    var endX: Double = 0
    var endY: Double = 0

    var start: CGPoint { CGPoint(x: startX, y: startY) }
    var end: CGPoint { CGPoint(x: endX, y: endY) }
}

nonisolated struct CameraRawGeometrySettings: Equatable, Sendable, Codable {
    var upright: CameraRawUprightMode = .off
    var projection: CameraRawProjection = .perspective
    var vertical: Double = 0
    var horizontal: Double = 0
    var rotate: Double = 0
    var aspect: Double = 0
    var scale: Double = 0
    var offsetX: Double = 0
    var offsetY: Double = 0
    var constrainCrop = false
    /// Perspective correction strength 0…100. 100 matches the previous full-strength path; 0 is identity.
    var perspectiveAmount: Double = 100
    /// Keep Original Size preserves the layer footprint. Expand to Fit returns a larger bitmap and a placement.
    var framingMode: CameraRawFramingMode = .keepOriginalSize
    var guides: [CameraRawGeometryGuide] = []
    /// Volume deformation 0…200. Zero leaves the picture unchanged.
    var volumeHorizontal: Double = 0
    var volumeVertical: Double = 0
    var volumeRadial: Double = 0
    var volumeMode: CameraRawVolumeMode = .radial
    /// EXIF / Auto Volume. Zero means unknown.
    var focalLengthMm: Double = 0
    var sensorWidthMm: Double = 0

    static let toneRange: ClosedRange<Double> = -100...100
    static let rotateRange: ClosedRange<Double> = -45...45
    static let volumeRange: ClosedRange<Double> = 0...200
    static let amountRange: ClosedRange<Double> = 0...100
    /// Maps a 0…200 slider into ComputeAnamorphosis `b` (smaller b ⇒ stronger warp).
    /// Provisional. 0.55 keeps the top of the slider inside a fold-free range on the CPU kernel.
    /// It is not a measured match to any other product.
    static let volumeStrengthScale = 0.55

    init() {}

    /// Missing keys keep their defaults so older saved geometry still opens at full perspective strength.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try values.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        let base = Self()
        upright = try read(.upright, base.upright)
        projection = try read(.projection, base.projection)
        vertical = try read(.vertical, base.vertical)
        horizontal = try read(.horizontal, base.horizontal)
        rotate = try read(.rotate, base.rotate)
        aspect = try read(.aspect, base.aspect)
        scale = try read(.scale, base.scale)
        offsetX = try read(.offsetX, base.offsetX)
        offsetY = try read(.offsetY, base.offsetY)
        constrainCrop = try read(.constrainCrop, base.constrainCrop)
        perspectiveAmount = try read(.perspectiveAmount, base.perspectiveAmount)
        framingMode = try read(.framingMode, base.framingMode)
        guides = try read(.guides, base.guides)
        volumeHorizontal = try read(.volumeHorizontal, base.volumeHorizontal)
        volumeVertical = try read(.volumeVertical, base.volumeVertical)
        volumeRadial = try read(.volumeRadial, base.volumeRadial)
        volumeMode = try read(.volumeMode, base.volumeMode)
        focalLengthMm = try read(.focalLengthMm, base.focalLengthMm)
        sensorWidthMm = try read(.sensorWidthMm, base.sensorWidthMm)
    }

    var adjusts: Bool {
        usesSolverGuides || usesManualPerspective || usesVolume || usesPolish
    }

    /// Guided / Auto only count once a line is long enough to read. Empty Auto must not warp the picture.
    private var usesSolverGuides: Bool {
        upright != .off && guides.contains { hypot($0.endX - $0.startX, $0.endY - $0.startY) > 0.01 }
    }

    private var usesManualPerspective: Bool {
        upright == .off && (vertical != 0 || horizontal != 0 || rotate != 0)
    }

    private var usesVolume: Bool {
        switch volumeMode {
        case .radial: return volumeRadial != 0
        case .horizontal: return volumeHorizontal != 0
        case .vertical: return volumeVertical != 0
        case .horizontalAndVertical: return volumeHorizontal != 0 || volumeVertical != 0
        }
    }

    private var usesPolish: Bool {
        aspect != 0 || scale != 0 || offsetX != 0 || offsetY != 0
    }

    var normalized: Self {
        var result = self
        result.vertical = ImageAdjustmentPixels.clamp(vertical, Self.toneRange, 0)
        result.horizontal = ImageAdjustmentPixels.clamp(horizontal, Self.toneRange, 0)
        result.rotate = ImageAdjustmentPixels.clamp(rotate, Self.rotateRange, 0)
        result.aspect = ImageAdjustmentPixels.clamp(aspect, Self.toneRange, 0)
        result.scale = ImageAdjustmentPixels.clamp(scale, Self.toneRange, 0)
        result.offsetX = ImageAdjustmentPixels.clamp(offsetX, Self.toneRange, 0)
        result.offsetY = ImageAdjustmentPixels.clamp(offsetY, Self.toneRange, 0)
        result.perspectiveAmount = ImageAdjustmentPixels.clamp(perspectiveAmount, Self.amountRange, 100)
        result.volumeHorizontal = ImageAdjustmentPixels.clamp(volumeHorizontal, Self.volumeRange, 0)
        result.volumeVertical = ImageAdjustmentPixels.clamp(volumeVertical, Self.volumeRange, 0)
        result.volumeRadial = ImageAdjustmentPixels.clamp(volumeRadial, Self.volumeRange, 0)
        result.focalLengthMm = max(0, focalLengthMm.isFinite ? focalLengthMm : 0)
        result.sensorWidthMm = max(0, sensorWidthMm.isFinite ? sensorWidthMm : 0)
        result.guides = guides.filter { guide in
            hypot(guide.endX - guide.startX, guide.endY - guide.startY) > 0.01
        }
        return result
    }

    func applying(shows: Bool) -> Self { shows ? self : Self() }

    /// Fills volume sliders from focal / sensor metadata when both are known.
    mutating func applyAutoVolumeFromFocal() {
        let auto = Self.autoVolumeSliders(focalLengthMm: focalLengthMm, sensorWidthMm: sensorWidthMm)
        volumeHorizontal = auto.horizontal
        volumeVertical = auto.vertical
        volumeRadial = auto.radial
    }

    static func autoVolumeSliders(focalLengthMm: Double, sensorWidthMm: Double) -> (horizontal: Double, vertical: Double, radial: Double) {
        guard focalLengthMm > 0, sensorWidthMm > 0 else { return (0, 0, 0) }
        let focal = focalLengthMm / (sensorWidthMm / 2)
        return (
            horizontal: anamorphosisAutoSlider(focal: focal, dimension: .horizontal),
            vertical: anamorphosisAutoSlider(focal: focal, dimension: .vertical),
            radial: anamorphosisAutoSlider(focal: focal, dimension: .radial)
        )
    }

    private enum AnamorphosisDimension { case horizontal, vertical, radial }

    /// Piecewise focal-in-sensor-units curve recovered from ViewPoint.
    private static func anamorphosisAutoSlider(focal: Double, dimension: AnamorphosisDimension) -> Double {
        let xs: [Double]
        switch dimension {
        case .horizontal: xs = [0.444, 2.778, 13.889]
        case .vertical: xs = [0.667, 4.167, 20.833]
        case .radial: xs = [0.523, 3.269, 16.343]
        }
        let ys: [Double] = [200, 30, 0]
        if focal <= xs[0] { return ys[0] }
        if focal >= xs[2] { return ys[2] }
        if focal <= xs[1] {
            let t = (focal - xs[0]) / (xs[1] - xs[0])
            return ys[0] + t * (ys[1] - ys[0])
        }
        let t = (focal - xs[1]) / (xs[2] - xs[1])
        return ys[1] + t * (ys[2] - ys[1])
    }

    static func volumeStrength(_ slider: Double) -> Double {
        guard slider > 0 else { return 0 }
        return (slider / 200) * volumeStrengthScale
    }

    /// Closed-form ViewPoint leaf. Exposed for tests.
    static func computeAnamorphosis(a: Double, b: Double) -> Double {
        if b <= 0 { return a }
        let t = b * sqrt(4 * a * a + b * b) - b * b
        if t < 0 { return a }
        let r = sqrt(t * 0.5)
        return a < 0 ? -r : r
    }

    /// Perspective and volume on the pixel grid. Prefer `applyResult` when Expand to Fit placement is needed.
    /// Lens distortion is applied by `CameraRawSettings.apply` before this.
    func apply(_ image: CGImage) throws -> CGImage {
        try applyResult(image).image
    }

    /// Same as `apply`, plus an expansion describing how to place a resized result on the document.
    /// `horizonDegrees` is composed into the destination corners before framing so Expand bounds stay complete.
    func applyResult(_ image: CGImage, horizonDegrees: Double? = nil) throws -> CameraRawGeometryResult {
        let settings = normalized
        let needsPerspective = settings.usesSolverGuides || settings.usesManualPerspective || settings.usesPolish
            || (horizonDegrees.map { abs($0) > 1e-9 } ?? false)
        guard settings.adjusts || needsPerspective else { return CameraRawGeometryResult(image: image, expansion: nil) }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return CameraRawGeometryResult(image: image, expansion: nil) }
        var working = image
        if settings.usesVolume {
            working = try settings.applyVolume(working)
        }
        var expansion: CameraRawGeometryExpansion?
        if needsPerspective {
            let perspective = try settings.applyPerspectiveResult(working, horizonDegrees: horizonDegrees)
            working = perspective.image
            expansion = perspective.expansion
        }
        guard settings.constrainCrop else {
            return CameraRawGeometryResult(image: working, expansion: expansion)
        }
        let cropped = try settings.applyConstrainCropResult(working, framing: settings.framingMode, expansion: expansion)
        return cropped
    }

    private func applyVolume(_ image: CGImage) throws -> CGImage {
        let width = image.width, height = image.height
        let source = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: source)
        let destination = try BrushRaster.context(width: width, height: height, mask: false)
        guard let from = source.data, let into = destination.data else { throw ExportError.render }
        let horizontal = Self.volumeStrength(volumeHorizontal)
        let vertical = Self.volumeStrength(volumeVertical)
        let radial = Self.volumeStrength(volumeRadial)
        let mode = volumeMode.kernelValue
        // A zero strength is a byte copy. Leave that on the CPU so identity stays exact.
        let identity = (mode == 0 && radial <= 0) || (mode == 1 && horizontal <= 0) || (mode == 2 && vertical <= 0)
            || (mode == 3 && horizontal <= 0 && vertical <= 0)
        let stride = source.bytesPerRow
        let gpu = !identity && stride == destination.bytesPerRow && MetalCameraRawVolume.shared?.apply(
            source: from.assumingMemoryBound(to: UInt8.self), destination: into.assumingMemoryBound(to: UInt8.self),
            width: width, height: height, stride: stride,
            strengthH: horizontal, strengthV: vertical, strengthR: radial, mode: mode
        ) == true
        if !gpu {
            volume_deform(from.assumingMemoryBound(to: UInt8.self), into.assumingMemoryBound(to: UInt8.self),
                          width, height, stride, horizontal, vertical, radial, mode)
        }
        guard let result = destination.makeImage() else { throw ExportError.render }
        return result
    }

    private func applyPerspectiveResult(_ image: CGImage, horizonDegrees: Double? = nil) throws -> CameraRawGeometryResult {
        let width = image.width, height = image.height
        let corners = outputCorners(width: width, height: height, horizonDegrees: horizonDegrees)
        let identity = CameraRawPerspective.identityCorners(width: Double(width), height: Double(height))
        let unchanged = zip(corners, identity).allSatisfy {
            hypot($0.x - $1.x, $0.y - $1.y) < 0.05
        }
        if unchanged { return CameraRawGeometryResult(image: image, expansion: nil) }
        func vector(_ point: CGPoint) -> CIVector { CIVector(x: point.x, y: point.y) }
        let renderWidth: Int
        let renderHeight: Int
        let renderCorners: [CGPoint]
        let expansion: CameraRawGeometryExpansion?
        if framingMode == .expandToFit,
           let frame = CameraRawPerspective.expandedFrame(corners: corners),
           let coverage = CameraRawPerspective.coverageInLayerPixels(corners: corners, width: width, height: height) {
            renderWidth = Int(frame.size.width)
            renderHeight = Int(frame.size.height)
            renderCorners = CameraRawPerspective.translatedCorners(corners, by: frame.translation)
            let planned = CameraRawGeometryExpansion(inputWidth: width, inputHeight: height, coverageInInput: coverage)
            expansion = planned.isIdentityFootprint ? nil : planned
        } else {
            renderWidth = width
            renderHeight = height
            renderCorners = corners
            expansion = nil
        }
        let warped = CIImage(cgImage: image).applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": vector(renderCorners[0]),
            "inputTopRight": vector(renderCorners[1]),
            "inputBottomRight": vector(renderCorners[2]),
            "inputBottomLeft": vector(renderCorners[3]),
        ])
        let imageOut = try PixelAdjust.render(warped, width: renderWidth, height: renderHeight, isMask: false)
        return CameraRawGeometryResult(image: imageOut, expansion: expansion)
    }

    private func applyConstrainCropResult(_ image: CGImage, framing: CameraRawFramingMode,
                                          expansion: CameraRawGeometryExpansion?) throws -> CameraRawGeometryResult {
        let width = image.width, height = image.height
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let data = context.data else {
            return CameraRawGeometryResult(image: image, expansion: expansion)
        }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        // The opaque bounding box still contains transparent corners after a rotation. Fit the largest
        // axis-aligned rectangle that sits entirely on solid pixels.
        guard let crop = Self.inscribedOpaqueRect(bytes: bytes, width: width, height: height, stride: context.bytesPerRow),
              crop.width >= 1, crop.height >= 1,
              crop.width < CGFloat(width) - 0.5 || crop.height < CGFloat(height) - 0.5,
              let cropped = image.cropping(to: crop) else {
            return CameraRawGeometryResult(image: image, expansion: expansion)
        }
        if framing == .expandToFit {
            // Expanded framing already chose the canvas; Constrain Crop only removes empty margins.
            let next = expansion?.cropping(to: crop) ?? expansion
            return CameraRawGeometryResult(image: cropped, expansion: next)
        }
        let fitted = try BrushRaster.context(width: width, height: height, mask: false)
        let scale = min(CGFloat(width) / crop.width, CGFloat(height) / crop.height)
        let draw = CGRect(x: (CGFloat(width) - crop.width * scale) / 2, y: (CGFloat(height) - crop.height * scale) / 2,
                          width: crop.width * scale, height: crop.height * scale)
        BrushRaster.draw(cropped, in: draw, mask: false, context: fitted)
        guard let fittedImage = fitted.makeImage() else {
            return CameraRawGeometryResult(image: image, expansion: expansion)
        }
        // Keep Original Size: result stays the input footprint; no layer expansion.
        return CameraRawGeometryResult(image: fittedImage, expansion: nil)
    }

    /// Largest axis-aligned rectangle whose pixels are all opaque enough to count as picture, not fringe.
    /// Buffer row 0 is the top, matching `CGImage.cropping(to:)`.
    static func inscribedOpaqueRect(bytes: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) -> CGRect? {
        guard width > 0, height > 0 else { return nil }
        var left = [Int](repeating: width, count: height)
        var right = [Int](repeating: -1, count: height)
        for y in 0..<height {
            let row = bytes + y * stride
            for x in 0..<width where row[x * 4 + 3] >= 240 {
                if x < left[y] { left[y] = x }
                if x > right[y] { right[y] = x }
            }
        }
        var bestArea = 0
        var best: CGRect?
        for start in 0..<height where right[start] >= left[start] {
            var maxLeft = left[start], minRight = right[start]
            for end in start..<height {
                guard right[end] >= left[end] else { break }
                maxLeft = max(maxLeft, left[end])
                minRight = min(minRight, right[end])
                let span = minRight - maxLeft + 1
                if span <= 0 { break }
                let area = span * (end - start + 1)
                if area > bestArea {
                    bestArea = area
                    best = CGRect(x: maxLeft, y: start, width: span, height: end - start + 1)
                }
            }
        }
        return best
    }

    /// Core Image corner positions with y measured upward from the bottom (TL, TR, BR, BL).
    /// Perspective Amount blends the keystone/roll homography toward identity before Aspect / Scale / Offset.
    /// Optional `horizonDegrees` rotates those destination corners about the image center before polish/framing,
    /// so Expand to Fit bounds include Horizon.
    func outputCorners(width: Int, height: Int, horizonDegrees: Double? = nil) -> [CGPoint] {
        let w = Double(width), h = Double(height)
        let identity = CameraRawPerspective.identityCorners(width: w, height: h)
        let amount = ImageAdjustmentPixels.clamp(perspectiveAmount, Self.amountRange, 100) / 100
        var perspectiveCorners = identity
        if upright != .off, let homo = CameraRawPerspective.homography(guides: guides, width: width, height: height) {
            // Guided / Auto: solver owns keystone. Vertical / Horizontal / Rotate are ignored.
            if amount >= 1 - 1e-9 {
                perspectiveCorners = CameraRawPerspective.perspectiveCorners(homography: homo, width: width, height: height)
            } else if let blended = homo.blendedTowardIdentity(amount: amount, width: w, height: h) {
                perspectiveCorners = CameraRawPerspective.perspectiveCorners(homography: blended, width: width, height: height)
            }
        } else if upright == .off, vertical != 0 || horizontal != 0 || rotate != 0 {
            let full = Self.manualCorners(width: w, height: h, vertical: vertical, horizontal: horizontal,
                                          rotation: rotate, projection: projection)
            if amount <= 1e-9 {
                perspectiveCorners = identity
            } else if amount >= 1 - 1e-9 {
                perspectiveCorners = full
            } else if let homo = CameraRawHomography.dlt(from: identity, to: full),
                      let blended = homo.blendedTowardIdentity(amount: amount, width: w, height: h) {
                perspectiveCorners = CameraRawPerspective.perspectiveCorners(homography: blended, width: width, height: height)
            } else {
                // Degenerate blend: refuse the keystone rather than invent an intermediate.
                perspectiveCorners = identity
            }
        }
        if let degrees = horizonDegrees, degrees.isFinite, abs(degrees) > 1e-9,
           let homo = CameraRawHorizon.rotationHomography(degrees: degrees, width: w, height: h) {
            perspectiveCorners = perspectiveCorners.map { homo.applying($0) }
        }
        return Self.polish(corners: perspectiveCorners, width: w, height: h, aspect: aspect, scale: scale,
                           offsetX: offsetX, offsetY: offsetY)
    }

    /// Whether Perspective Amount currently affects the picture (solver or manual keystone/roll is active).
    var perspectiveAmountApplies: Bool {
        usesSolverGuides || usesManualPerspective
    }

    private static func manualCorners(width w: Double, height h: Double, vertical: Double, horizontal: Double,
                                      rotation: Double, projection: CameraRawProjection) -> [CGPoint] {
        let strength = projection == .perspective ? 1.0 : 0.55
        let v = vertical / 100 * w * 0.18 * strength
        let hz = horizontal / 100 * h * 0.18 * strength
        var topLeft = CGPoint(x: -v, y: h)
        var topRight = CGPoint(x: w + v, y: h)
        var bottomRight = CGPoint(x: w + hz, y: 0)
        var bottomLeft = CGPoint(x: -hz, y: 0)
        let center = CGPoint(x: w / 2, y: h / 2)
        let radians = rotation * .pi / 180
        func rotated(_ point: CGPoint) -> CGPoint {
            let dx = point.x - center.x, dy = point.y - center.y
            let cosine = cos(radians), sine = sin(radians)
            return CGPoint(x: center.x + dx * cosine - dy * sine, y: center.y + dx * sine + dy * cosine)
        }
        topLeft = rotated(topLeft); topRight = rotated(topRight)
        bottomRight = rotated(bottomRight); bottomLeft = rotated(bottomLeft)
        return [topLeft, topRight, bottomRight, bottomLeft]
    }

    private static func polish(corners: [CGPoint], width w: Double, height h: Double, aspect: Double, scale: Double,
                               offsetX: Double, offsetY: Double) -> [CGPoint] {
        let shiftX = offsetX / 100 * w * 0.15
        let shiftY = offsetY / 100 * h * 0.15
        let center = CGPoint(x: w / 2 + shiftX, y: h / 2 + shiftY)
        let aspectScale = 1 + aspect / 200
        let zoom = 1 + scale / 100
        return corners.map { point in
            var p = CGPoint(x: point.x + shiftX, y: point.y + shiftY)
            if aspectScale != 1 {
                p = CGPoint(x: center.x + (p.x - center.x) * aspectScale, y: center.y + (p.y - center.y) / aspectScale)
            }
            if zoom != 1 {
                p = CGPoint(x: center.x + (p.x - center.x) * zoom, y: center.y + (p.y - center.y) * zoom)
            }
            return p
        }
    }
}

nonisolated enum CameraRawProcessVersion: String, CaseIterable, Sendable {
    case version1 = "Version 1"
    case version2 = "Version 2"
    case version3 = "Version 3"
    case version4 = "Version 4"
    case version5 = "Version 5"
    case version6 = "Version 6"
    var kernelValue: Int32 {
        switch self {
        case .version1: return 1
        case .version2: return 2
        case .version3: return 3
        case .version4: return 4
        case .version5: return 5
        case .version6: return 6
        }
    }

    /// What this process does to the calibration sliders on an already-rendered layer.
    var summary: String {
        switch self {
        case .version1:
            return "Earliest response. Hue, saturation, and shadow tint move about half as far as Version 6."
        case .version2:
            return "A little stronger than Version 1. The sliders below still fall well short of the current look."
        case .version3:
            return "Firmer color than Version 2. Primary shifts stay gentler than the current process."
        case .version4:
            return "The 2012 response. Calibration reaches most of the strength used by Version 6."
        case .version5:
            return "Close to the current process, with slightly softer primary and shadow shifts."
        case .version6:
            return "Current default. The calibration sliders below apply at full strength."
        }
    }
}

nonisolated struct CameraRawCalibrationSettings: Equatable, Sendable {
    var process: CameraRawProcessVersion = .version6
    var shadowTint: Double = 0
    var redHue: Double = 0
    var redSaturation: Double = 0
    var greenHue: Double = 0
    var greenSaturation: Double = 0
    var blueHue: Double = 0
    var blueSaturation: Double = 0

    static let toneRange: ClosedRange<Double> = -100...100

    var adjusts: Bool {
        shadowTint != 0 || redHue != 0 || redSaturation != 0 || greenHue != 0 || greenSaturation != 0
            || blueHue != 0 || blueSaturation != 0
    }

    var normalized: Self {
        var result = self
        result.shadowTint = ImageAdjustmentPixels.clamp(shadowTint, Self.toneRange, 0)
        result.redHue = ImageAdjustmentPixels.clamp(redHue, Self.toneRange, 0)
        result.redSaturation = ImageAdjustmentPixels.clamp(redSaturation, Self.toneRange, 0)
        result.greenHue = ImageAdjustmentPixels.clamp(greenHue, Self.toneRange, 0)
        result.greenSaturation = ImageAdjustmentPixels.clamp(greenSaturation, Self.toneRange, 0)
        result.blueHue = ImageAdjustmentPixels.clamp(blueHue, Self.toneRange, 0)
        result.blueSaturation = ImageAdjustmentPixels.clamp(blueSaturation, Self.toneRange, 0)
        return result
    }

    func applying(shows: Bool) -> Self { shows ? self : Self() }
}

nonisolated extension CameraRawSettings {
    func applyCalibration(pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int, stride: Int) {
        let calibration = calibration.normalized
        guard calibration.adjusts else { return }
        // The primaries' hue and saturation come from Photoshop's measured tables, with Light and Color; this draws
        // Shadows Tint alone.
        guard calibration.shadowTint != 0 else { return }
        adjust_camera_raw_calibration(pixels, width, height, stride, calibration.shadowTint, 0, 0, 0, 0, 0, 0,
                                      calibration.process.kernelValue)
    }
}
