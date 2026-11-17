import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var solvingBalance = false
    @State private var profileIssue: String?
    /// Why the chosen decoder cannot be used here, or nil. Shown rather than quietly developing with another.
    @State private var decoderIssue: String?
    /// The decoders this project's own RAW bytes genuinely offer.
    @State private var availableDecoders: [RawDecoderChoice] = [.systemDefault]


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
                decoderRow
                whiteBalanceControls
                slider("Temperature", value: $settings.temperature, range: 2000...50000, unit: " K", precision: 0,
                       onChange: { value in
                           session.updateRawDevelopmentSettings(layerID: layerID, temperature: value,
                                                                whiteBalanceMode: .custom)
                       })
                slider("Tint", value: $settings.tint, range: -150...150, unit: "", precision: 0,
                       onChange: { value in
                           session.updateRawDevelopmentSettings(layerID: layerID, tint: value, whiteBalanceMode: .custom)
                       })
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

                profileControls
                rawDetailControls
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
        .task { await loadAvailableDecoders() }
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

        let image: CGImage?
        do {
            image = try await RawImporter.Queue.shared.develop(tmpURL, settings: current, limit: 800)
        } catch {
            decoderIssue = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        guard !Task.isCancelled else { return }
        decoderIssue = nil
        if let image { preview = image }
    }

    /// Asks the project's own RAW bytes which decoders they offer, off the main actor: building a filter decodes the
    /// file's header. Runs once when the sheet opens.
    private func loadAvailableDecoders() async {
        let layer = session.document?.layers.first(where: { $0.id == layerID })
        guard let draft = session.rawDrafts[layerID] ?? layer?.rawDevelopment,
              let source = draft.source as RawSourceAsset? else { return }
        let choices: [RawDecoderChoice] = await Task.detached(priority: .userInitiated) {
            guard let url = try? RawImporter.temporaryFile(for: source) else { return [.systemDefault] }
            defer { try? FileManager.default.removeItem(at: url) }
            let available = RawImporter.availableDecoders(at: url)
            return available.isEmpty ? [.systemDefault] : available
        }.value
        availableDecoders = choices
    }

    /// The decoder's own two noise reductions, at the sensor stage rather than a rendered picture's Detail sliders.
    /// Chroma reduction is the one that removes color mottle without smearing luminance detail, which is why it is
    /// offered separately rather than folded into the luminance value.
    private var noiseControls: some View {
        Group {
            slider("Noise Reduction", value: $settings.noiseReduction, range: 0...1, unit: "", precision: 2,
                   onChange: { session.updateRawDevelopmentSettings(layerID: layerID, noiseReduction: $0) })
            .disabled(!settings.supportsNoiseReduction)
            .help(settings.supportsNoiseReduction ? "Smooths grain, at the cost of fine detail"
                                                  : "Not available for this camera")
            slider("Color Noise", value: $settings.colorNoiseReduction, range: 0...1, unit: "", precision: 2,
                   onChange: { session.updateRawDevelopmentSettings(layerID: layerID, colorNoiseReduction: $0) })
            .disabled(!settings.supportsColorNoiseReduction)
            .help(settings.supportsColorNoiseReduction
                  ? "Removes color mottle at the sensor stage, where it is separate from luminance detail."
                  : RawDecoderCopy.unavailable("Color Noise Reduction"))
        }
    }

    /// As Shot / Auto / Custom, and the fact that these readings are absolute: the decoder re-develops the sensor
    /// data at them, rather than shifting an already-developed picture as Camera Raw's own Temperature does.
    private var whiteBalanceControls: some View {
        HStack(spacing: 10) {
            Text("White Balance").frame(width: 110, alignment: .leading)
            Picker("White Balance", selection: Binding(
                get: { RawWhiteBalanceMode(rawValue: settings.whiteBalanceMode) ?? .asShot },
                set: setWhiteBalanceMode)) {
                ForEach(RawWhiteBalanceMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            .help("As Shot is the camera's own reading. Auto solves the frame's neutral through the sensor model. "
                  + "Custom follows the Kelvin and Tint sliders.")
            .accessibilityIdentifier("rawWhiteBalanceMode")
            if solvingBalance {
                ProgressView().controlSize(.mini)
            } else {
                Text(String(format: "As Shot %.0f K", settings.asShotTemperatureAbsolute))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// The photographic profile: the decoder's own camera rendering, a linear decode, or an ICC profile. A DCP is
    /// refused with the reason rather than accepted and ignored.
    private var profileControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Profile").frame(width: 110, alignment: .leading)
                Picker("Profile", selection: Binding(
                    get: { RawColorProfileKind(rawValue: settings.colorProfile.kind) ?? .cameraDefault },
                    set: setProfileKind)) {
                    ForEach(RawColorProfileKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
                .help("Camera Default is the decoder's own rendering for this camera. Linear removes its tone curve. "
                      + "ICC Profile interprets the developed pixels through a profile you choose.")
                .accessibilityIdentifier("rawColorProfileKind")
                Button("Choose ICC…") { chooseICCProfile() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Reads an ICC profile from disk and keeps it inside this project.")
                    .accessibilityIdentifier("rawColorProfileChoose")
                Spacer(minLength: 0)
            }
            if (RawColorProfileKind(rawValue: settings.colorProfile.kind) ?? .cameraDefault) == .icc {
                if let data = settings.colorProfile.iccData,
                   let space = RawColorProfile.validatedColorSpace(from: data) {
                    Text("\(settings.colorProfile.name.isEmpty ? "ICC profile" : settings.colorProfile.name)  •  \(space.name as String? ?? "unregistered")")
                        .font(.caption).foregroundStyle(.secondary)
                    slider("Strength", value: Binding(
                        get: { Float(settings.colorProfile.strength) },
                        set: { value in
                            var profile = persistedProfile
                            profile.strength = Double(value)
                            session.updateRawDevelopmentSettings(layerID: layerID, colorProfile: profile)
                        }), range: 0...100, unit: "%", precision: 0, onChange: { _ in })
                } else {
                    Text("Choose an ICC profile to use. A DCP profile cannot be read: it needs Adobe's own profile "
                         + "data and a parser that cannot ship here, so it is refused rather than approximated.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(profileHelp)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let profileIssue {
                Text(profileIssue).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var profileHelp: String {
        switch RawColorProfileKind(rawValue: settings.colorProfile.kind) ?? .cameraDefault {
        case .cameraDefault: return "The decoder's own color rendering for this camera, as every earlier version developed it."
        case .linear: return "The decoder's decode without its tone curve: linear sensor color, for a grade that starts from the data."
        case .icc: return ""
        }
    }

    /// Raw Details: the decoder's own reconstruction, moved from what this file's decoder does on its own rather than
    /// from zero. Zero on a control is the camera's existing rendering, which is what makes switching it on, or
    /// returning every control to its middle, a no-op.
    ///
    /// Gated one control at a time. Under RAW 9 the detail reconstruction and the moiré reduction are gone while
    /// sharpness and contrast remain, so disabling the group would take two working sliders with two unavailable
    /// ones. A value the selected decoder cannot use is kept in the draft — so switching back restores it — and said
    /// so rather than silently ignored (M12.5).
    private var rawDetailControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Raw Details").frame(width: 110, alignment: .leading)
                // Reads the draft, not the view's copy of it: the draft is what the renderer will use, and the
                // sliders below are gated on this so a stale copy would leave them unreachable.
                Toggle("Use decoder detail reconstruction", isOn: Binding(
                    get: { persistedDetail.enabled },
                    set: { enabled in
                        var detail = persistedDetail
                        detail.enabled = enabled
                        session.updateRawDevelopmentSettings(layerID: layerID, rawDetail: detail)
                        if let draft = session.rawDrafts[layerID] { settings = draft.settings }
                    }))
                .disabled(!settings.supportsRawDetail)
                .help(settings.supportsRawDetail
                      ? "Asks the RAW decoder for its own detail reconstruction, on the sensor data before it becomes pixels."
                      : "This file's decoder does not offer detail reconstruction.")
                .accessibilityIdentifier("rawDetailEnabled")
                if persistedDetail.enabled, settings.supportsRawDetail {
                    Text(String(format: "Camera's own: detail %.2f · sharpness %.2f", persistedDefaults.detail,
                                persistedDefaults.sharpness))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if persistedDetail.enabled, settings.supportsRawDetail {
                Group {
                    detailSlider("Detail", \.detail, range: RawDetailSettings.detailRange, precision: 2,
                                 base: persistedDefaults.detail, available: settings.offersDetail)
                    detailSlider("Sharpness", \.sharpness, range: RawDetailSettings.sharpnessRange, precision: 2,
                                 base: persistedDefaults.sharpness, available: settings.offersSharpness)
                    detailSlider("Contrast", \.contrast, range: RawDetailSettings.contrastRange, precision: 2,
                                 base: persistedDefaults.contrast, available: settings.offersContrast)
                    detailSlider("Moire", \.moire, range: RawDetailSettings.moireRange, precision: 2,
                                 base: persistedDefaults.moire, available: settings.offersMoire)
                }
                .padding(.leading, 120)
                if let retained = retainedDetailNote {
                    Text(retained).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 120)
                        .accessibilityIdentifier("rawDetailRetained")
                }
                Text("Amounts are relative to the camera's own decode, so 0.00 leaves it exactly as it was. Applied by "
                     + "the decoder before the image becomes pixels, so it recovers detail a rendered picture no "
                     + "longer has.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 120)
            }
        }
    }

    /// Which Raw Details amounts the selected decoder cannot apply but the draft is holding, with their values, so
    /// nobody has to wonder whether switching decoder discarded them.
    private var retainedDetailNote: String? {
        let unavailable = settings.unavailableRawDetailControls
        guard !unavailable.isEmpty else { return nil }
        let detail = persistedDetail
        let held = unavailable.filter { detail[$0] != 0 }
        let list = unavailable.map(\.rawValue).joined(separator: ", ")
        guard !held.isEmpty else {
            return "\(settings.selectedDecoder.label) does not offer \(list) here."
        }
        let values = held.map { String(format: "%@ %.2f", $0.rawValue, detail[$0]) }.joined(separator: ", ")
        return "\(settings.selectedDecoder.label) does not offer \(list) here. Kept: \(values); "
            + "\(RawDecoderChoice.systemDefault.label) applies them again."
    }

    /// One offset, with the amount the decoder will actually be asked for beside it, so the controls never leave the
    /// reader guessing what zero means for this camera.
    private func detailSlider(_ title: String, _ key: WritableKeyPath<RawDetailSettings, Float>,
                              range: ClosedRange<Float>, precision: Int, base: Float,
                              available: Bool) -> some View {
        let value = persistedDetail[keyPath: key]
        let total = base + value
        return HStack(spacing: 10) {
            Text(title).frame(width: 90, alignment: .leading)
            AppSlider(value: Binding(get: { persistedDetail[keyPath: key] },
                                     set: { newValue in
                                         var detail = persistedDetail
                                         detail[keyPath: key] = newValue
                                         session.updateRawDevelopmentSettings(layerID: layerID, rawDetail: detail)
                                     }), in: range)
                .frame(width: 210)
                .disabled(!available)
                .help(available ? "" : RawDecoderCopy.unavailable(title))
                .accessibilityIdentifier("rawDetailSlider\(title)")
            Text(String(format: "%+.\(precision)f → %.\(precision)f", value, total))
                .monospacedDigit().foregroundStyle(available ? .secondary : .tertiary)
                .frame(width: 110, alignment: .trailing)
        }
    }

    /// Which decoder develops this layer. The project's own RAW bytes are used to decide what is offered, and the
    /// effective version is shown, so a layer can never display RAW 9 while developing with another decoder (M12.5).
    private var decoderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("Decoder").frame(width: 110, alignment: .leading)
                Picker("Decoder", selection: Binding(
                    get: { settings.selectedDecoder },
                    set: setDecoder)) {
                    ForEach(availableDecoders, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
                .help("System Default is the decoder this layer was developed with before. Apple RAW 9 is offered "
                      + "only where the original RAW bytes genuinely develop with it.")
                .accessibilityIdentifier("rawDecoder")
                if settings.selectedDecoder == .appleRAW9, let effective = settings.effectiveDecoderVersion,
                   !effective.isEmpty {
                    Text("version \(effective)").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("rawDecoderEffective")
                }
                Spacer(minLength: 0)
            }
            if !availableDecoders.contains(.appleRAW9) {
                Text("Apple RAW 9 is not offered for this file: its decoder has no RAW 9 version to develop with.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 120)
            } else if settings.selectedDecoder == .appleRAW9, let lost = decoderLimitations {
                Text(lost).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 120)
            }
            if let decoderIssue {
                Text(decoderIssue).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 120)
                    .accessibilityIdentifier("rawDecoderIssue")
            }
        }
    }

    private var decoderLimitations: String? {
        var lost: [String] = []
        if !settings.supportsColorNoiseReduction { lost.append("Color Noise Reduction") }
        if !settings.offersDetail { lost.append(RawDetailControl.detail.rawValue) }
        if !settings.offersMoire { lost.append(RawDetailControl.moire.rawValue) }
        guard !lost.isEmpty else { return nil }
        return "RAW 9 does not offer \(lost.joined(separator: ", ")) on this file. Amounts already set are kept and "
            + "return when you switch back to System Default."
    }

    /// Switches decoder through the session, which re-reads this version's capabilities from the original bytes.
    /// A refusal is shown rather than accepted, so the picker never disagrees with what was rendered.
    private func setDecoder(_ choice: RawDecoderChoice) {
        guard choice != settings.selectedDecoder else { return }
        decoderIssue = session.switchRawDevelopmentDecoder(layerID: layerID, to: choice)
        if let draft = session.rawDrafts[layerID] { settings = draft.settings }
        revision += 1
    }

    /// The draft's own RAW details, not the view's copy: a slider writes the draft, and the view reads it back.
    private var persistedDetail: RawDetailSettings {
        session.rawDrafts[layerID]?.settings.makeSettings().rawDetail ?? RawDetailSettings()
    }

    /// What this file's decoder does before Raw Details' offsets apply, as the draft recorded it.
    private var persistedDefaults: RawDetailBaseline {
        guard let stored = session.rawDrafts[layerID]?.settings.rawDetailDefaults else { return RawDetailBaseline() }
        return RawDetailBaseline(detail: stored.detail, sharpness: stored.sharpness,
                                 contrast: stored.contrast, moire: stored.moire)
    }

    private var persistedProfile: RawColorProfile {
        session.rawDrafts[layerID]?.settings.makeSettings().colorProfile ?? RawColorProfile()
    }

    private func setWhiteBalanceMode(_ mode: RawWhiteBalanceMode) {
        switch mode {
        case .asShot:
            session.updateRawDevelopmentSettings(layerID: layerID, whiteBalanceMode: .asShot)
            if let draft = session.rawDrafts[layerID] { settings = draft.settings }
        case .custom:
            session.updateRawDevelopmentSettings(layerID: layerID, whiteBalanceMode: .custom)
        case .auto:
            solvingBalance = true
            Task {
                await session.solveRawDevelopmentWhiteBalance(layerID: layerID)
                if let draft = session.rawDrafts[layerID] { settings = draft.settings }
                solvingBalance = false
            }
        }
    }

    private func setProfileKind(_ kind: RawColorProfileKind) {
        var profile = persistedProfile
        profile.kind = kind
        if kind == .icc, profile.iccData == nil { profile.iccData = nil }
        session.updateRawDevelopmentSettings(layerID: layerID, colorProfile: profile)
        if let draft = session.rawDrafts[layerID] { settings = draft.settings }
        profileIssue = nil
    }

    private func chooseICCProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "icc") ?? .data, .init(filenameExtension: "icm") ?? .data,
                                     .init(filenameExtension: "dcp") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an ICC profile. A DCP profile is refused: it needs Adobe's own profile data."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let read = try RawColorProfile.read(url: url)
            session.updateRawDevelopmentSettings(layerID: layerID, colorProfile: read.profile)
            if let draft = session.rawDrafts[layerID] { settings = draft.settings }
            profileIssue = nil
            revision += 1
        } catch {
            profileIssue = error.localizedDescription
        }
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
