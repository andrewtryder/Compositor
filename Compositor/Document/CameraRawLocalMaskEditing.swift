import AppKit
import CoreImage

/// The part of a gradient a canvas drag is moving.
nonisolated enum CameraRawLocalMaskGradientHandle: Equatable, Sendable {
    /// The center of a radial gradient, or the white end of a linear one.
    case start
    /// The outer edge of a radial gradient, or the black end of a linear one.
    case end
}

extension EditorSession {
    // MARK: - Reading the panel's state

    /// The mask the panel is editing. Nil while nothing is selected or the selection names a mask that no longer exists.
    var selectedCameraRawLocalMask: CameraRawLocalMask? {
        guard let edit = filterEdit, edit.kind == .cameraRaw, let id = edit.selectedLocalMaskID else { return nil }
        return edit.settings.cameraRaw.localMasks.first { $0.id == id }
    }

    /// Keeps the selection on a mask that exists, defaulting to the first one, so the panel never edits a mask the
    /// settings do not carry.
    func reconcileCameraRawLocalMaskSelection() {
        guard let edit = filterEdit, edit.kind == .cameraRaw else { return }
        let masks = edit.settings.cameraRaw.localMasks
        if let id = edit.selectedLocalMaskID, masks.contains(where: { $0.id == id }) { return }
        edit.selectedLocalMaskID = masks.first?.id
        if masks.isEmpty {
            edit.showsLocalMaskOverlay = false
            edit.samplesLocalMask = false
            edit.drawsLocalMask = false
            edit.localMaskGradientHandle = nil
            edit.localMaskGradientOriginal = nil
        }
    }

    // MARK: - Adding masks

    /// Appends a mask and selects it. The kinds that need something already in the document say so when they are
    /// added without it: `addCameraRawLocalMask(.selection)` with no selection refuses rather than making a mask that
    /// covers everything.
    @discardableResult
    func addCameraRawLocalMask(kind: CameraRawLocalMaskKind, name: String? = nil,
                               raster: CameraRawLocalMaskRaster? = nil) -> UUID? {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing else { return nil }
        var settings = edit.settings
        guard settings.cameraRaw.localMasks.count < CameraRawLocalMask.maximumCount else {
            brushError = "Camera Raw holds at most \(CameraRawLocalMask.maximumCount) local masks."
            return nil
        }
        var mask = CameraRawLocalMask(name: name ?? Self.defaultLocalMaskName(kind, existing: settings.cameraRaw.localMasks),
                                     kind: kind)
        mask.raster = raster
        guard mask.isValid else {
            brushError = "That mask could not be made from the current selection."
            return nil
        }
        mask = mask.normalized
        settings.cameraRaw.localMasks.append(mask)
        edit.settings = settings
        edit.selectedLocalMaskID = mask.id
        updateFilter(settings, preview: edit.preview)
        return mask.id
    }

    /// Names repeats the way Photoshop does: Linear Gradient, Linear Gradient 1, Linear Gradient 2.
    static func defaultLocalMaskName(_ kind: CameraRawLocalMaskKind, existing: [CameraRawLocalMask]) -> String {
        let taken = Set(existing.map(\.name))
        guard taken.contains(kind.rawValue) else { return kind.rawValue }
        var index = 1
        while taken.contains("\(kind.rawValue) \(index)") { index += 1 }
        return "\(kind.rawValue) \(index)"
    }

    /// Adds a mask from the active layer's own layer mask, read in the layer's grid and resampled to the preview's.
    @discardableResult
    func addCameraRawLocalMaskFromLayerMask() -> UUID? {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing,
              let layerMask = document?.layers.first(where: { $0.id == edit.layerID })?.mask,
              let image = layerMask.enabledImage else {
            brushError = "The layer has no layer mask to make a local mask from."
            return nil
        }
        let width = edit.previewSource.width, height = edit.previewSource.height
        do {
            guard let coverage = try Self.layerMaskCoverage(image: image, width: width, height: height) else {
                brushError = "The layer mask hides this layer completely."
                return nil
            }
            return addCameraRawLocalMask(kind: .layerMask, name: nil,
                                         raster: try CameraRawLocalMaskRaster.make(from: coverage))
        } catch {
            brushError = error.localizedDescription
            return nil
        }
    }

    /// The layer mask's coverage on the preview's grid. A mask uses alpha rather than a single channel, so the
    /// coverage is taken from its luminance after being drawn into a matching grid.
    static func layerMaskCoverage(image: CGImage, width: Int, height: Int) throws -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        context.interpolationQuality = .high
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: true, context: context)
        guard let coverage = context.makeImage() else { throw ExportError.render }
        return CameraRawLocalMaskRenderer.hasCoverage(coverage) ? coverage : nil
    }

    /// Adds a mask from the document's selection, captured as coverage in preview pixels so later geometry changes do
    /// not move it.
    @discardableResult
    func addCameraRawLocalMaskFromSelection() -> UUID? {
        guard let edit = filterEdit, edit.kind == .cameraRaw else { return nil }
        guard let selection else {
            brushError = "Make a selection first, then add a mask from it."
            brushSound()
            return nil
        }
        let width = edit.previewSource.width, height = edit.previewSource.height
        do {
            let coverage = try Self.localMaskCoverage(selection: selection, width: width, height: height,
                                                     pixelToDocument: edit.previewMapping)
            guard let coverage else {
                brushError = "The selection does not cover any of this layer."
                return nil
            }
            return addCameraRawLocalMask(kind: .selection, name: nil, raster: try CameraRawLocalMaskRaster.make(from: coverage))
        } catch {
            brushError = error.localizedDescription
            return nil
        }
    }

    /// The selection's coverage on the preview's own pixel grid. Nil when it selects nothing there.
    static func localMaskCoverage(selection: DocumentSelection, width: Int, height: Int,
                                 pixelToDocument: CGAffineTransform) throws -> CGImage? {
        guard !selection.isEmpty, width > 0, height > 0 else { return nil }
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.concatenate(pixelToDocument.inverted())
        context.setShouldAntialias(selection.antialiased || selection.feather > 0)
        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(selection.path)
        context.fillPath(using: .winding)
        guard let image = context.makeImage() else {
            throw ExportError.render
        }
        guard selection.feather > 0 else { return image }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let soft = CIImage(cgImage: image).clampedToExtent()
            .applyingGaussianBlur(sigma: selection.feather / 2).cropped(to: extent)
        return try PixelAdjust.render(soft, width: width, height: height, isMask: true)
    }

    /// Adds a mask from Vision's foreground instance under `point`, read from the preview's own pixels with the same
    /// request Object Selection uses. Reports refusal honestly when nothing is found.
    @discardableResult
    func addCameraRawLocalMaskFromObject(at point: CGPoint) -> UUID? {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing else { return nil }
        let pixel = point.applying(edit.previewMapping.inverted())
        guard pixel.x >= 0, pixel.y >= 0, pixel.x < CGFloat(edit.previewSource.width),
              pixel.y < CGFloat(edit.previewSource.height) else { return nil }
        let image = edit.preparedPreview ?? edit.previewSource
        let scale = CGFloat(edit.previewSource.width) / CGFloat(max(1, image.width))
        let scaled = CGPoint(x: pixel.x / max(0.0001, scale), y: pixel.y / max(0.0001, scale))
        do {
            let coverage = try Self.foregroundCoverage(in: image, at: scaled)
            guard let coverage else {
                brushError = "No foreground subject was found at that point."
                return nil
            }
            return addCameraRawLocalMask(kind: .objectSelection, name: nil,
                                         raster: try CameraRawLocalMaskRaster.make(from: coverage))
        } catch {
            brushError = error.localizedDescription
            return nil
        }
    }

    /// Add a Color Range mask sampled from the pixel under `point`, matching the rest of the frame by color.
    @discardableResult
    func addCameraRawLocalMaskFromColor(at point: CGPoint) -> UUID? {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing,
              let color = Self.localMaskSampledColor(in: edit.previewSource, at: point.applying(edit.previewMapping.inverted())) else {
            return nil
        }
        return addCameraRawLocalMask(kind: .colorRange, name: nil, raster: nil, sampled: color)
    }

    /// Vision's subject coverage at `image`'s own size, as gray coverage (white over the subject). Nil when no
    /// foreground instance is found.
    nonisolated static func foregroundCoverage(in image: CGImage, at point: CGPoint) throws -> CGImage? {
        guard #available(macOS 14.0, *) else {
            throw ObjectSelection.Failure.unsupported
        }
        let path = try ObjectSelection.select(in: image, at: point, edgeOffset: 0, smoothEdges: true)
        guard let path else { return nil }
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: true)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setShouldAntialias(true)
        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(path)
        context.fillPath(using: .winding)
        return context.makeImage()
    }

    /// The straight sRGB color (0…1) at an image pixel, averaged over the 3 × 3 around it, as Color Range's own
    /// sampler reads it.
    nonisolated static func localMaskSampledColor(in image: CGImage, at point: CGPoint) -> (red: Double, green: Double, blue: Double)? {
        let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))
        guard point.x.isFinite, point.y.isFinite, (0..<image.width).contains(x), (0..<image.height).contains(y),
              let context = try? BrushRaster.context(width: 3, height: 3, mask: false) else { return nil }
        BrushRaster.draw(image, in: CGRect(x: 1 - x, y: 1 - y, width: image.width, height: image.height),
                         mask: false, context: context)
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var sums = [0, 0, 0, 0]
        for row in 0..<3 {
            for column in 0..<3 {
                for channel in 0..<4 { sums[channel] += Int(data[row * context.bytesPerRow + column * 4 + channel]) }
            }
        }
        guard sums[3] > 0 else { return nil }
        return (Double(min(255, (sums[0] * 255 + sums[3] / 2) / sums[3])) / 255,
                Double(min(255, (sums[1] * 255 + sums[3] / 2) / sums[3])) / 255,
                Double(min(255, (sums[2] * 255 + sums[3] / 2) / sums[3])) / 255)
    }

    // MARK: - Editing masks

    /// Replaces one mask, keeping its place in the list. The selection stays on it.
    func updateCameraRawLocalMask(_ mask: CameraRawLocalMask) {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing,
              !edit.settings.cameraRaw.localMasks.isEmpty else { return }
        var settings = edit.settings
        guard let index = settings.cameraRaw.localMasks.firstIndex(where: { $0.id == mask.id }) else { return }
        settings.cameraRaw.localMasks[index] = mask.normalized
        edit.settings = settings
        updateFilter(settings, preview: edit.preview)
    }

    /// Changes the selected mask's adjustments only, leaving its geometry and coverage alone.
    func updateCameraRawLocalMaskAdjustments(_ change: (inout CameraRawLocalAdjustments) -> Void) {
        guard var mask = selectedCameraRawLocalMask else { return }
        change(&mask.adjustments)
        updateCameraRawLocalMask(mask)
    }

    /// Selects a mask for editing, and ends any canvas mode that belonged to the previous one.
    func selectCameraRawLocalMask(_ id: UUID?) {
        guard let edit = filterEdit, edit.kind == .cameraRaw else { return }
        edit.selectedLocalMaskID = id
        if id == nil {
            edit.showsLocalMaskOverlay = false
            edit.samplesLocalMask = false
            edit.drawsLocalMask = false
        }
        brushRevision += 1
    }

    func toggleCameraRawLocalMaskEnabled(_ id: UUID) {
        guard var mask = filterEdit?.settings.cameraRaw.localMasks.first(where: { $0.id == id }) else { return }
        mask.enabled.toggle()
        updateCameraRawLocalMask(mask)
    }

    func setCameraRawLocalMaskInverted(_ id: UUID, _ inverted: Bool) {
        guard var mask = filterEdit?.settings.cameraRaw.localMasks.first(where: { $0.id == id }) else { return }
        mask.inverted = inverted
        updateCameraRawLocalMask(mask)
    }

    func renameCameraRawLocalMask(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var mask = filterEdit?.settings.cameraRaw.localMasks.first(where: { $0.id == id }) else { return }
        mask.name = trimmed
        updateCameraRawLocalMask(mask)
    }

    func deleteCameraRawLocalMask(_ id: UUID) {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing else { return }
        var settings = edit.settings
        guard settings.cameraRaw.localMasks.contains(where: { $0.id == id }) else { return }
        settings.cameraRaw.localMasks.removeAll { $0.id == id }
        edit.settings = settings
        if edit.selectedLocalMaskID == id {
            edit.selectedLocalMaskID = settings.cameraRaw.localMasks.first?.id
            edit.showsLocalMaskOverlay = false
            edit.samplesLocalMask = false
            edit.drawsLocalMask = false
            edit.localMaskGradientHandle = nil
            edit.localMaskGradientOriginal = nil
        }
        updateFilter(settings, preview: edit.preview)
    }

    /// Whether a mask's coverage can be set from the canvas: gradients and Color Range can, the raster kinds cannot
    /// (they are captured from something else in the document and stay as captured).
    var canEditCameraRawLocalMaskOnCanvas: Bool {
        guard let mask = selectedCameraRawLocalMask else { return false }
        return mask.kind.isGradient || mask.kind == .colorRange || mask.kind == .brushPainted
    }

    // MARK: - Gradient drawing on the canvas

    /// Arms dragging a gradient for the selected mask, capturing where it was so Escape can put it back.
    func beginCameraRawLocalMaskGradient() {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing,
              let mask = selectedCameraRawLocalMask, mask.kind.isGradient else { return }
        edit.localMaskGradientOriginal = (start: CGPoint(x: mask.startX, y: mask.startY),
                                         end: CGPoint(x: mask.endX, y: mask.endY))
        edit.drawsLocalMask = true
        edit.samplesLocalMask = false
        brushRevision += 1
    }

    /// Press on the preview while a gradient is armed: grabs the handle under the pointer, or starts a new pair from
    /// the press point.
    func beginCameraRawLocalMaskGradientDrag(at point: CGPoint) {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing, edit.drawsLocalMask,
              var mask = selectedCameraRawLocalMask, let normalized = cameraRawNormalizedPoint(at: point) else { return }
        let start = CGPoint(x: mask.startX, y: mask.startY), end = CGPoint(x: mask.endX, y: mask.endY)
        let reach = hypot(end.x - start.x, end.y - start.y)
        let tolerance = max(0.015, reach * 0.15)
        if hypot(normalized.x - end.x, normalized.y - end.y) <= tolerance {
            edit.localMaskGradientHandle = .end
        } else if hypot(normalized.x - start.x, normalized.y - start.y) <= tolerance || mask.kind == .linearGradient {
            edit.localMaskGradientHandle = .start
            mask.startX = normalized.x
            mask.startY = normalized.y
            if mask.kind == .linearGradient {
                mask.endX = normalized.x
                mask.endY = normalized.y
            }
            updateCameraRawLocalMask(mask)
        } else {
            edit.localMaskGradientHandle = .end
        }
    }

    /// Drag: the grabbed handle follows the pointer.
    func continueCameraRawLocalMaskGradientDrag(to point: CGPoint) {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing, edit.drawsLocalMask,
              let handle = edit.localMaskGradientHandle,
              var mask = selectedCameraRawLocalMask, let normalized = cameraRawNormalizedPoint(at: point) else { return }
        switch mask.kind {
        case .linearGradient:
            if handle == .start {
                mask.endX += normalized.x - mask.startX
                mask.endY += normalized.y - mask.startY
                mask.startX = normalized.x
                mask.startY = normalized.y
            } else {
                mask.endX = normalized.x
                mask.endY = normalized.y
            }
        case .radialGradient:
            if handle == .start {
                // The radii stay with the center as it moves.
                mask.centerX = normalized.x
                mask.centerY = normalized.y
            } else {
                // The rim follows the pointer, its longer axis the shorter side's fraction.
                let shorter = Double(min(edit.previewSource.width, edit.previewSource.height))
                guard shorter > 0 else { return }
                let dx = abs(normalized.x - mask.centerX) * Double(edit.previewSource.width) / shorter
                let dy = abs(normalized.y - mask.centerY) * Double(edit.previewSource.height) / shorter
                mask.radiusX = min(1, max(0.02, dx))
                mask.radiusY = min(1, max(0.02, dy))
            }
        default:
            return
        }
        updateCameraRawLocalMask(mask)
    }

    /// Release: the gradient stays where it was dragged. Nothing new is written for a drag that never moved.
    func endCameraRawLocalMaskGradientDrag() {
        guard let edit = filterEdit else { return }
        edit.localMaskGradientHandle = nil
        edit.localMaskGradientOriginal = nil
        brushRevision += 1
    }

    /// Escape during a gradient drag or drawing: puts the gradient back where it was and disarms.
    func cancelCameraRawLocalMaskGradient() {
        guard let edit = filterEdit else { return }
        defer {
            edit.localMaskGradientHandle = nil
            edit.localMaskGradientOriginal = nil
            edit.drawsLocalMask = false
            brushRevision += 1
        }
        guard let original = edit.localMaskGradientOriginal, var mask = selectedCameraRawLocalMask else { return }
        switch mask.kind {
        case .linearGradient:
            mask.startX = original.start.x
            mask.startY = original.start.y
            mask.endX = original.end.x
            mask.endY = original.end.y
        case .radialGradient:
            mask.centerX = original.start.x
            mask.centerY = original.start.y
            mask.startX = original.start.x
            mask.startY = original.start.y
            mask.endX = original.end.x
            mask.endY = original.end.y
        default:
            return
        }
        updateCameraRawLocalMask(mask)
    }

    /// Ends the armed gradient mode without restoring anything, as the panel's Done does.
    func finishCameraRawLocalMaskGradient() {
        guard let edit = filterEdit else { return }
        edit.drawsLocalMask = false
        edit.localMaskGradientHandle = nil
        edit.localMaskGradientOriginal = nil
        brushRevision += 1
    }

    // MARK: - Color Range sampling

    /// Arms the eyedropper for the selected Color Range mask. A click replaces its sampled color.
    func armCameraRawLocalMaskColorSample() {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing,
              selectedCameraRawLocalMask?.kind == .colorRange else { return }
        edit.samplesLocalMask.toggle()
        if edit.samplesLocalMask {
            edit.drawsLocalMask = false
        }
        brushRevision += 1
    }

    /// A click while the local Color Range eyedropper is armed: that pixel's color becomes the mask's sample.
    func sampleCameraRawLocalMaskColor(at point: CGPoint) {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing, edit.samplesLocalMask,
              var mask = selectedCameraRawLocalMask, mask.kind == .colorRange,
              let color = Self.localMaskSampledColor(in: edit.preparedPreview ?? edit.previewSource,
                                                    at: point.applying(edit.previewMapping.inverted())) else { return }
        mask.red = color.red
        mask.green = color.green
        mask.blue = color.blue
        updateCameraRawLocalMask(mask)
    }

    /// A click while "Object Selection…" is armed: Vision's foreground under the point becomes a new mask.
    func addCameraRawLocalMaskFromPickedObject(at point: CGPoint) {
        guard let edit = filterEdit, edit.picksLocalMaskObject else { return }
        edit.picksLocalMaskObject = false
        addCameraRawLocalMaskFromObject(at: point)
        brushRevision += 1
    }

    /// A click while "Color Range…" is armed: the color under the point becomes a new Color Range mask.
    func addCameraRawLocalMaskFromPickedColor(at point: CGPoint) {
        guard let edit = filterEdit, edit.picksLocalMaskColor else { return }
        edit.picksLocalMaskColor = false
        addCameraRawLocalMaskFromColor(at: point)
        brushRevision += 1
    }

    /// Turns off every canvas mode for local masks: used when the panel closes or another tool takes the canvas.
    func endCameraRawLocalMaskCanvasModes() {
        guard let edit = filterEdit else { return }
        edit.samplesLocalMask = false
        edit.drawsLocalMask = false
        edit.drawsLocalMaskBrush = false
        edit.picksLocalMaskObject = false
        edit.picksLocalMaskColor = false
        edit.localMaskGradientHandle = nil
        edit.localMaskGradientOriginal = nil
        edit.showsLocalMaskOverlay = false
        brushRevision += 1
    }

    // MARK: - Brush painting on a local mask

    /// Arms brush painting for the selected mask: the next drag on the preview paints or erases
    /// the mask's coverage. Fails quietly when no brush-editable mask is selected.
    func beginCameraRawLocalMaskBrush(mode: BrushToolMode) {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing,
              let mask = selectedCameraRawLocalMask, mask.kind.isBrushPainted else { return }
        // End every other canvas mode so brush painting owns the canvas.
        edit.drawsLocalMask = false
        edit.samplesLocalMask = false
        edit.picksLocalMaskObject = false
        edit.picksLocalMaskColor = false
        edit.localMaskGradientHandle = nil
        edit.localMaskGradientOriginal = nil
        edit.drawsLocalMaskBrush = true
        edit.localMaskBrushMode = mode
        edit.localMaskBrushStroke = nil
        edit.localMaskBrushStrokeBase = nil
        edit.localMaskBrushStrokeOriginalMask = mask
        brushRevision += 1
    }

    /// Press on the preview while brush painting is armed: starts a stroke on the mask's coverage.
    func beginCameraRawLocalMaskBrushStroke(at point: CGPoint) {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing,
              edit.drawsLocalMaskBrush,
              var mask = selectedCameraRawLocalMask, mask.kind.isBrushPainted,
              let normalized = cameraRawNormalizedPoint(at: point) else { return }
        let image = edit.preparedPreview ?? edit.previewSource
        guard let base = try? maskCoverageImage(mask, in: image) else { return }
        do {
            let stroke = try CameraRawLocalMaskBrush(base: base, width: image.width, height: image.height,
                                                     settings: brushSettings,
                                                     erasing: edit.localMaskBrushMode == .erase)
            edit.localMaskBrushStroke = stroke
            edit.localMaskBrushStrokeBase = base
            stroke.dab(at: normalizedPointToPixel(normalized, in: image))
            edit.localMaskBrushStrokeStart = normalized
            updateFilter(edit.settings, preview: edit.preview)
            brushRevision += 1
        } catch { brushError = error.localizedDescription }
    }

    /// Drag: the brush follows the pointer, laying down dabs along the path.
    func continueCameraRawLocalMaskBrushStroke(to point: CGPoint) {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing,
              edit.drawsLocalMaskBrush, var stroke = edit.localMaskBrushStroke,
              let normalized = cameraRawNormalizedPoint(at: point) else { return }
        stroke.dab(at: normalizedPointToPixel(normalized, in: edit.preparedPreview ?? edit.previewSource))
        edit.localMaskBrushStroke = stroke
        edit.localMaskBrushStrokeStart = normalized
        updateFilter(edit.settings, preview: edit.preview)
        brushRevision += 1
    }

    /// Release: the stroke stays painted on the mask's coverage.
    func endCameraRawLocalMaskBrushStroke() {
        guard let edit = filterEdit, let stroke = edit.localMaskBrushStroke else { return }
        do {
            let raster = try stroke.makeRaster()
            if var mask = selectedCameraRawLocalMask {
                mask.raster = raster
                updateCameraRawLocalMask(mask)
            }
        } catch { brushError = error.localizedDescription }
        finishCameraRawLocalMaskBrush()
    }

    /// Escape during a brush stroke: discards the stroke and restores the mask as it was.
    func cancelCameraRawLocalMaskBrush() {
        guard let edit = filterEdit else { return }
        defer {
            edit.localMaskBrushStroke = nil
            edit.localMaskBrushStrokeBase = nil
            edit.localMaskBrushStrokeOriginalMask = nil
            edit.drawsLocalMaskBrush = false
            brushRevision += 1
        }
        guard let original = edit.localMaskBrushStrokeOriginalMask else { return }
        updateCameraRawLocalMask(original)
    }

    /// Ends brush painting without committing an in-progress stroke, as the panel's Done does.
    func finishCameraRawLocalMaskBrush() {
        guard let edit = filterEdit else { return }
        edit.localMaskBrushStroke = nil
        edit.localMaskBrushStrokeBase = nil
        edit.localMaskBrushStrokeOriginalMask = nil
        edit.drawsLocalMaskBrush = false
        brushRevision += 1
    }

    private func brushSound() {
        NSSound.beep()
    }
}

private extension EditorSession {
    /// A mask added from a sampled color, with the sample filled in.
    @discardableResult
    func addCameraRawLocalMask(kind: CameraRawLocalMaskKind, name: String?,
                               raster: CameraRawLocalMaskRaster?,
                               sampled color: (red: Double, green: Double, blue: Double)) -> UUID? {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing else { return nil }
        var settings = edit.settings
        guard settings.cameraRaw.localMasks.count < CameraRawLocalMask.maximumCount else {
            brushError = "Camera Raw holds at most \(CameraRawLocalMask.maximumCount) local masks."
            return nil
        }
        var mask = CameraRawLocalMask(name: name ?? Self.defaultLocalMaskName(kind, existing: settings.cameraRaw.localMasks),
                                     kind: kind)
        mask.raster = raster
        mask.red = color.red
        mask.green = color.green
        mask.blue = color.blue
        mask = mask.normalized
        settings.cameraRaw.localMasks.append(mask)
        edit.settings = settings
        edit.selectedLocalMaskID = mask.id
        updateFilter(settings, preview: edit.preview)
        return mask.id
    }

    /// The mask's current coverage rendered at the preview image's grid, in the corrected frame.
    /// An empty brush-painted mask (no raster yet) yields a black coverage image.
    private func maskCoverageImage(_ mask: CameraRawLocalMask, in image: CGImage) throws -> CGImage? {
        guard mask.kind.isBrushPainted, let edit = filterEdit else { return nil }
        if mask.raster == nil {
            guard let context = try? BrushRaster.context(width: image.width, height: image.height, mask: true) else { return nil }
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return context.makeImage()
        }
        return try CameraRawLocalMaskRenderer.coverage(of: mask, settings: edit.settings.cameraRaw,
                                                       image: image, inputWidth: image.width,
                                                       inputHeight: image.height, width: image.width,
                                                       height: image.height)
    }

    /// A normalized point in the preview mapped to a pixel in the image grid.
    private func normalizedPointToPixel(_ normalized: CGPoint, in image: CGImage) -> CGPoint {
        CGPoint(x: normalized.x * Double(image.width), y: normalized.y * Double(image.height))
    }
}
