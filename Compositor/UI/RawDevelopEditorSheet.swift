import SwiftUI

/// Editor sheet for re-developing an existing RAW-backed layer. Uses the original RAW bytes
/// embedded in the project, not the external file. Slider changes update the draft via the
/// session API; Apply commits it as one undo step.
struct RawDevelopEditorSheet: View {
    let session: EditorSession
    let layerID: UUID
    @State private var settings: RawDevelopmentSettingsPersistentState
    @State private var preview: CGImage?
    @State private var working = true
    @State private var revision = 0
    @State private var sourceInfo: String = ""

    init(session: EditorSession, layerID: UUID, persistentState: RawDevelopmentPersistentState) {
        self.session = session
        self.layerID = layerID
        _settings = State(initialValue: persistentState.settings)
        // Build source info string
        let source = persistentState.source
        var parts: [String] = [source.fileName()]
        parts.append("\(source.pixelWidth) × \(source.pixelHeight) px")
        parts.append("\(source.bitsPerComponent)-bit")
        if let colorSpace = source.colorSpace { parts.append(colorSpace) }
        parts.append("RAW-backed")
        if let exif = source.cameraMetadata["Exif"] as? [CFString: Any],
           let make = exif[kCGImagePropertyTIFFMake] as? String,
           let model = exif[kCGImagePropertyTIFFModel] as? String {
            parts.append("\(make) \(model)")
        }
        if let exif = source.cameraMetadata["Exif"] as? [CFString: Any],
           let lens = exif[kCGImagePropertyExifLensModel] as? String {
            parts.append(lens)
        }
        sourceInfo = parts.joined(separator: "  •  ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit RAW Development").font(.title2.bold())
            Text(sourceInfo).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35))
                if let preview {
                    Image(decorative: preview, scale: 1)
                        .resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if working { ProgressView().controlSize(.small) }
            }
            .frame(width: 560, height: 340)

            Group {
                slider("Exposure", value: $settings.exposure, range: -3...3, unit: " EV", precision: 2,
                       onChange: { session.updateRawDevelopmentSettings(layerID: layerID, exposure: $0) })
                slider("Temperature", value: $settings.temperature, range: 2000...12000, unit: " K", precision: 0,
                       onChange: { session.updateRawDevelopmentSettings(layerID: layerID, temperature: $0) })
                slider("Tint", value: $settings.tint, range: -150...150, unit: "", precision: 0,
                       onChange: { session.updateRawDevelopmentSettings(layerID: layerID, tint: $0) })
                slider("Boost", value: $settings.boost, range: 0...2, unit: "", precision: 2,
                       onChange: { session.updateRawDevelopmentSettings(layerID: layerID, boost: $0) })
                slider("Noise Reduction", value: $settings.noiseReduction, range: 0...1, unit: "", precision: 2,
                       onChange: { session.updateRawDevelopmentSettings(layerID: layerID, noiseReduction: $0) })
                .disabled(!settings.supportsNoiseReduction)
                .help(settings.supportsNoiseReduction ? "Smooths grain, at the cost of fine detail"
                                                      : "Not available for this camera")

                HStack(spacing: 20) {
                    Toggle("Lens Correction", isOn: $settings.lensCorrection)
                        .disabled(!settings.supportsLensCorrection)
                        .onChange(of: settings.lensCorrection) { _, newValue in
                            session.updateRawDevelopmentSettings(layerID: layerID, lensCorrection: newValue)
                        }
                        .help(settings.supportsLensCorrection ? "Removes the lens's distortion and vignetting"
                                                              : "This file has no lens profile")
                    Toggle("Highlight Recovery", isOn: $settings.highlightRecovery)
                        .disabled(!settings.supportsHighlightRecovery)
                        .onChange(of: settings.highlightRecovery) { _, newValue in
                            session.updateRawDevelopmentSettings(layerID: layerID, highlightRecovery: newValue)
                        }
                        .help(settings.supportsHighlightRecovery ? "Brings back detail in bright areas the camera partly clipped"
                                                                 : "Not available for this camera")
                }
                .padding(.leading, 120)

                HStack {
                    Button("Reset to As Shot") {
                        session.resetRawDevelopmentToAsShot(layerID: layerID)
                        if let draft = session.rawDrafts[layerID] {
                            settings = draft.settings
                            Task { await refreshPreview() }
                        }
                    }
                    .disabled(settings.isAsShot || !session.canEditLayers)
                    Spacer()
                    Button("Cancel") {
                        session.cancelRawDevelopmentEdit(layerID: layerID)
                        session.showRawDevelopEditor = false
                    }.keyboardShortcut(.cancelAction)
                    Button("Apply") {
                        Task {
                            let success = await session.applyRawDevelopmentEdit(layerID: layerID)
                            if success { session.showRawDevelopEditor = false }
                        }
                    }.keyboardShortcut(.defaultAction)
                    .disabled(!session.canEditLayers)
                }
            }
        }
        .padding(24).fixedSize()
        .interactiveDismissDisabled(true)
        .task(id: revision) { await refreshPreview() }
        .onChange(of: settings) { _, _ in
            // Bump revision to trigger a new preview render; the draft itself lives in the session.
            revision += 1
        }
    }

    /// Develops a screen-sized copy. `task(id:)` cancels the previous one, so dragging a slider
    /// doesn't queue up a frame per pixel moved.
    private func refreshPreview() async {
        // Just enough to coalesce a burst of slider changes; the render itself is nearly free once
        // the file's filter is warm.
        if revision > 0 { try? await Task.sleep(for: .milliseconds(60)) }
        guard !Task.isCancelled else { return }
        working = true
        defer { working = false }
        let layer = session.document?.layers.first(where: { $0.id == layerID })
        guard let draft = session.rawDrafts[layerID] ?? layer?.rawDevelopment,
              let source = draft.source as RawSourceAsset? else { return }

        let current = draft.settings.makeSettings()

        // Materialize the original RAW bytes to a temp file for CIRAWFilter
        let tmpURL: URL
        do {
            let tempDir = FileManager.default.temporaryDirectory
            let ext = source.fileExtension.lowercased()
            let knownExtensions: Set<String> = ["dng", "cr2", "nef", "arw", "rw2", "orf", "pef", "sr2", "erf", "k25", "dcr", "mrw"]
            let fileExtension = knownExtensions.contains(ext) ? ext : "dng"
            let fileName = "compositor-raw-\(UUID().uuidString).\(fileExtension)"
            tmpURL = tempDir.appendingPathComponent(fileName)
            try source.rawData.write(to: tmpURL, options: .atomic)
        } catch { return }
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let image = await RawImporter.Queue.shared.develop(tmpURL, settings: current, limit: 800)
        guard !Task.isCancelled else { return }
        if let image { preview = image }
    }

    private func slider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>,
                        unit: String, precision: Int,
                        onChange: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 110, alignment: .leading)
            AppSlider(value: value, in: range).frame(width: 300)
                .onChange(of: value.wrappedValue) { _, newValue in
                    onChange(newValue)
                }
            Text(String(format: "%.\(precision)f%@", value.wrappedValue, unit))
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
    }
}

extension View {
    func rawDevelopEditorSheet(_ session: EditorSession) -> some View {
        sheet(isPresented: Binding(
            get: { session.showRawDevelopEditor },
            set: {
                if !$0 {
                    if let id = session.rawDevelopEditorLayerID {
                        session.cancelRawDevelopmentEdit(layerID: id)
                    }
                    session.rawDevelopEditorLayerID = nil
                }
            }
        )) {
            if let layerID = session.rawDevelopEditorLayerID,
               let layer = session.document?.layers.first(where: { $0.id == layerID }),
               let persistent = layer.rawDevelopment {
                RawDevelopEditorSheet(session: session, layerID: layerID, persistentState: persistent)
            }
        }
    }
}
