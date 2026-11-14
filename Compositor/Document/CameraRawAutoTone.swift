import AppKit

/// Light › Auto: the six Light sliders set from the picture's own tones, as Camera Raw's Auto does.
/// A picture already well exposed comes back nearly unchanged; the values are the same kinds of measure the
/// adaptive sliders already read, so nothing here is a second tone engine.
nonisolated struct CameraRawAutoTone: Equatable, Sendable {
    var exposure = 0.0
    var contrast = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var whites = 0.0
    var blacks = 0.0

    /// Nothing to change: Auto leaves a well exposed picture as it is.
    var isIdentity: Bool {
        exposure == 0 && contrast == 0 && highlights == 0 && shadows == 0 && whites == 0 && blacks == 0
    }

    /// Writes the six sliders, leaving White Balance, Color and every other section alone.
    func apply(to settings: inout CameraRawSettings) {
        settings.exposure = exposure
        settings.contrast = contrast
        settings.highlights = highlights
        settings.shadows = shadows
        settings.whites = whites
        settings.blacks = blacks
    }
}

nonisolated extension CameraRawSettings {
    /// Auto for `image`. Nil when the layer has no opaque pixels to measure.
    static func autoTone(of image: CGImage) -> CameraRawAutoTone? {
        guard let histogram = luminanceHistogram(of: image) else { return nil }
        return autoTone(luminance: histogram)
    }

    /// 256 bins of sRGB luminance (0…255), counted on a copy no larger than 256 pixels on its longer side.
    /// Transparent pixels are skipped, and colors are read straight, as the eyedropper reads them.
    static func luminanceHistogram(of image: CGImage) -> [Double]? {
        guard image.width > 0, image.height > 0 else { return nil }
        let factor = min(1, 256 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(image.height) * factor).rounded()))
        guard let context = try? BrushRaster.context(width: width, height: height, mask: false) else { return nil }
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var bins = [Double](repeating: 0, count: 256)
        for y in 0..<height {
            let row = y * context.bytesPerRow
            for x in 0..<width {
                let pixel = row + x * 4
                let alpha = Int(bytes[pixel + 3])
                guard alpha > 0 else { continue }
                let red = min(255, (Int(bytes[pixel]) * 255 + alpha / 2) / alpha)
                let green = min(255, (Int(bytes[pixel + 1]) * 255 + alpha / 2) / alpha)
                let blue = min(255, (Int(bytes[pixel + 2]) * 255 + alpha / 2) / alpha)
                let level = Int((0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)).rounded())
                bins[min(255, max(0, level))] += 1
            }
        }
        return bins
    }

    /// The six values a luminance histogram asks for.
    ///
    /// Each slider reads one thing: Exposure puts the middle tone near 118 (mid gray, within two stops);
    /// Contrast widens or narrows the range the picture uses; Highlights pulls back when the bright end sits at
    /// clipping; Shadows open when the dark end is crushed and deepen it when haze fills it; Whites and Blacks
    /// put the two ends where they belong.
    static func autoTone(luminance histogram: [Double]) -> CameraRawAutoTone? {
        guard histogram.count == 256, histogram.reduce(0, +) > 0 else { return nil }
        let total = histogram.reduce(0, +)
        func level(at fraction: Double) -> Double {
            let target = total * fraction
            var sum = 0.0
            for index in 0..<256 {
                sum += histogram[index]
                if sum >= target { return Double(index) }
            }
            return 255
        }
        let low = level(at: 0.005)
        let mid = level(at: 0.5)
        let high = level(at: 0.995)
        let spread = high - low

        var tone = CameraRawAutoTone()
        if mid > 1 {
            let stops = log2(118 / mid)
            tone.exposure = (ImageAdjustmentPixels.clamp(stops, -2...2, 0) * 100).rounded() / 100
        }
        // A flat picture (one tone, or nearly) has no range to widen.
        if spread >= 8 {
            tone.contrast = ImageAdjustmentPixels.clamp((200 - spread) * 0.25, -40...40, 0).rounded()
        }
        tone.highlights = ImageAdjustmentPixels.clamp((238 - high) * 0.8, -80...20, 0).rounded()
        tone.shadows = ImageAdjustmentPixels.clamp((6 - low) * 1.2, -20...70, 0).rounded()
        tone.whites = ImageAdjustmentPixels.clamp((252 - high) * 0.6, -40...50, 0).rounded()
        tone.blacks = ImageAdjustmentPixels.clamp((2 - low) * 0.4, -40...20, 0).rounded()
        return tone
    }
}

nonisolated extension EditorSession {
    /// Light › Auto. The tones are measured on the original layer, off the main thread, then applied to whatever
    /// the panel holds when the measurement lands.
    func applyCameraRawAutoTone() async {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing else { return }
        let image = edit.original.image
        let tone = await Task.detached(priority: .userInitiated) {
            CameraRawSettings.autoTone(of: image)
        }.value
        guard filterEdit === edit, !edit.committing, let tone, !tone.isIdentity else { return }
        var settings = edit.settings
        tone.apply(to: &settings.cameraRaw)
        updateFilter(settings, preview: edit.preview)
    }
}
