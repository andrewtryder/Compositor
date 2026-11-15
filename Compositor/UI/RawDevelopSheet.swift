import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A RAW file holds more range than a layer can, so the choice of what to keep is made here rather
/// than assumed. The preview develops at screen size while the sliders move; the import then
/// develops the full frame once.
struct RawDevelopSheet: View {
    let session: EditorSession
    let url: URL
    @State private var settings: RawDevelopSettings
    @State private var preview: CGImage?
    @State private var working = true
    @State private var revision = 0
    @State private var solvingBalance = false
    @State private var profileIssue: String?

    init(session: EditorSession, url: URL, settings: RawDevelopSettings) {
        self.session = session
        self.url = url
        _settings = State(initialValue: settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Develop “\(url.lastPathComponent)”").font(.title2.bold())
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35))
                if let preview {
                    Image(decorative: preview, scale: 1)
                        .resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if session.rawImporting {
                    // Import pressed: the full frame takes a second or more to develop.
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.regular)
                        Text("Importing…").foregroundStyle(.secondary)
                    }
                    .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                } else if working { ProgressView().controlSize(.small) }
            }
            .frame(width: 560, height: 340)

            Group {
                slider("Exposure", value: $settings.exposure, range: -3...3, unit: " EV", precision: 2)
                whiteBalanceModeRow
                slider("Temperature", value: $settings.temperature, range: 2000...50000, unit: " K", precision: 0)
                slider("Tint", value: $settings.tint, range: -150...150, unit: "", precision: 0)
                slider("Boost", value: $settings.boost, range: 0...1, unit: "", precision: 2)
                colorProfileRow
                slider("Noise Reduction", value: $settings.noiseReduction, range: 0...1, unit: "", precision: 2)
                    .disabled(!settings.supportsNoiseReduction)
                    .help(settings.supportsNoiseReduction ? "Smooths grain, at the cost of fine detail"
                                                          : "Not available for this camera")
                HStack(spacing: 20) {
                    Toggle("Lens Correction", isOn: $settings.lensCorrection)
                        .disabled(!settings.supportsLensCorrection)
                        .help(settings.supportsLensCorrection ? "Removes the lens's distortion and vignetting"
                                                              : "This file has no lens profile")
                    Toggle("Highlight Recovery", isOn: $settings.highlightRecovery)
                        .disabled(!settings.supportsHighlightRecovery)
                        .help(settings.supportsHighlightRecovery ? "Brings back detail in bright areas the camera partly clipped"
                                                                 : "Not available for this camera")
                }
                .padding(.leading, 120)

                HStack {
                    Button("Reset") { settings.reset() }.disabled(settings.isAsShot)
                    Spacer()
                    Button("Cancel") { session.finishRawDevelop(nil) }.keyboardShortcut(.cancelAction)
                    // Imports, then opens the Camera Raw Filter on the new layer, as Photoshop opens a RAW in Camera Raw.
                    Button("Camera Raw…") { session.finishRawDevelop(settings, openingCameraRaw: true) }
                        .help("Import, then open the Camera Raw Filter")
                    Button("Import") { session.finishRawDevelop(settings) }.keyboardShortcut(.defaultAction)
                }
            }
            .disabled(session.rawImporting)
        }
        .padding(24).fixedSize()
        .interactiveDismissDisabled(session.rawImporting)
        .task(id: revision) { await refreshPreview() }
        .onChange(of: settings) { _, _ in revision += 1 }
    }

    /// Develops a screen-sized copy. `task(id:)` cancels the previous one, so dragging a slider
    /// doesn't queue up a frame per pixel moved.
    private func refreshPreview() async {
        // Just enough to coalesce a burst of slider changes; the render itself is nearly free once
        // the file's filter is warm (see RawImporter.Queue).
        if revision > 0 { try? await Task.sleep(for: .milliseconds(60)) }
        guard !Task.isCancelled else { return }
        working = true
        defer { working = false }
        let current = settings
        let file = url
        let image = await RawImporter.Queue.shared.develop(file, settings: current, limit: 800)
        guard !Task.isCancelled else { return }
        if let image { preview = image }
    }

    /// As Shot / Auto / Custom. Auto solves the frame's neutral through the decoder's own sensor model, so the
    /// solved Kelvin is absolute for this camera rather than a shifted version of whatever it started at.
    private var whiteBalanceModeRow: some View {
        HStack(spacing: 10) {
            Text("White Balance").frame(width: 110, alignment: .leading)
            Picker("White Balance", selection: Binding(get: { settings.whiteBalanceMode },
                                                      set: setWhiteBalanceMode)) {
                ForEach(RawWhiteBalanceMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            .help("As Shot is the camera's own reading. Auto solves the frame's neutral. Custom follows the Kelvin and Tint sliders.")
            .accessibilityIdentifier("rawImportWhiteBalanceMode")
            if solvingBalance {
                ProgressView().controlSize(.mini)
            } else {
                Text(String(format: "As Shot %.0f K", settings.asShotTemperatureAbsolute))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// The photographic profile at import: the decoder's own rendering, a linear decode, or an ICC profile.
    private var colorProfileRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Profile").frame(width: 110, alignment: .leading)
                Picker("Profile", selection: Binding(get: { settings.colorProfile.kind }, set: setProfileKind)) {
                    ForEach(RawColorProfileKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
                .help("Camera Default is the decoder's own rendering for this camera. Linear removes its tone curve. ICC Profile interprets the developed pixels through a profile you choose.")
                .accessibilityIdentifier("rawImportColorProfileKind")
                Button("Choose ICC…") { chooseICCProfile() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Reads an ICC profile from disk and keeps it inside this project.")
                Spacer(minLength: 0)
            }
            if settings.colorProfile.kind == .icc {
                slider("Strength", value: Binding(get: { Float(settings.colorProfile.strength) },
                                                  set: { settings.colorProfile.strength = Double($0) }),
                       range: 0...100, unit: "%", precision: 0)
            }
            if let profileIssue {
                Text(profileIssue).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func setWhiteBalanceMode(_ mode: RawWhiteBalanceMode) {
        settings.whiteBalanceMode = mode
        switch mode {
        case .asShot:
            settings.temperature = settings.asShotTemperatureAbsolute
            settings.tint = settings.asShotTintAbsolute
        case .custom:
            break
        case .auto:
            solvingBalance = true
            let file = url
            let start = (temperature: settings.temperature, tint: settings.tint)
            Task {
                let solved = await Task.detached(priority: .userInitiated) {
                    RawImporter.solveWhiteBalance(file, startingAt: start)
                }.value
                if let solved {
                    settings.whiteBalanceMode = .custom
                    settings.temperature = solved.temperature
                    settings.tint = solved.tint
                }
                solvingBalance = false
            }
        }
    }

    private func setProfileKind(_ kind: RawColorProfileKind) {
        settings.colorProfile.kind = kind
        if kind != .icc { settings.colorProfile.iccData = nil }
        // An ICC profile without bytes would decode as Camera Default, so say so rather than look applied.
        profileIssue = kind == .icc && settings.colorProfile.iccData == nil
            ? "Choose an ICC profile. A DCP is refused: it needs Adobe's own profile data." : nil
    }

    private func chooseICCProfile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.message = "Choose an ICC profile. A DCP profile is refused: it needs Adobe's own profile data."
        let icc = UTType(filenameExtension: "icc"), icm = UTType(filenameExtension: "icm"), dcp = UTType(filenameExtension: "dcp")
        panel.allowedContentTypes = [icc, icm, dcp].compactMap { $0 }
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        do {
            settings.colorProfile = try RawColorProfile.read(url: chosen).profile
            profileIssue = nil
        } catch {
            profileIssue = error.localizedDescription
        }
    }

    private func slider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>,
                        unit: String, precision: Int) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 110, alignment: .leading)
            AppSlider(value: value, in: range).frame(width: 300)
            Text(String(format: "%.\(precision)f%@", value.wrappedValue, unit))
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
    }
}

extension View {
    func rawDevelopSheet(_ session: EditorSession) -> some View {
        sheet(isPresented: Binding(
            get: { session.showsRawDevelop },
            set: { if !$0 { session.finishRawDevelop(nil) } }
        )) {
            if let develop = session.rawDevelop {
                RawDevelopSheet(session: session, url: develop.url, settings: develop.settings)
            }
        }
    }
}
