import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Optics › Lens Profile: which provider corrects the lens, whether Lensfun is installed, what camera and lens the
/// file recorded, and which profile matched. Appended after Lens Blur, so every existing Optics control keeps its
/// place. Nothing here changes a pixel in M10.3; the panel says so rather than implying a correction happened.
struct CameraRawLensProfileControls: View {
    @Bindable var session: EditorSession
    private var settings: FilterSettings { session.filterEdit?.settings ?? FilterSettings() }
    private var raw: CameraRawSettings { settings.cameraRaw }
    private var profile: CameraRawLensProfileSettings { raw.optics.lensProfile }
    @State private var showsPicker = false

    /// The database manager lives on the session so its state survives closing and reopening the panel.
    private var manager: LensfunDatabaseManager { session.lensfunDatabase }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            providerPicker
            Text(profile.provider.summary)
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if profile.provider == .lensfun {
                lensfunStatus
            }
            metadataRows
            policyNotice
        }
        .onAppear { manager.refresh() }
    }

    // MARK: - Provider

    private var providerPicker: some View {
        HStack(spacing: 10) {
            Text("Provider")
                .frame(minWidth: CameraRawControls.labelWidth, alignment: .leading)
                .help("Which lens correction Compositor uses. Apple's is built in; Lensfun is optional; Off leaves both alone.")
            Picker("Provider", selection: Binding(get: { profile.provider },
                                                  set: { setProvider($0) })) {
                ForEach(CameraRawLensProfileProvider.allCases) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Lens Profile Provider")
            .accessibilityIdentifier("lensProfileProvider")
            Spacer(minLength: 0)
        }
    }

    /// Changing provider is one undoable change, like every other Optics control. Choosing Lensfun does not install
    /// anything; it only says which source would be consulted.
    private func setProvider(_ provider: CameraRawLensProfileProvider) {
        update { settings in
            settings.cameraRaw.optics.lensProfile.provider = provider
            if provider != .lensfun {
                // Apple Native and Off have no use for a pinned Lensfun lens; the identity is kept out of the way
                // rather than silently applied later.
                settings.cameraRaw.optics.lensProfile.selection = CameraRawLensProfileSelection()
            }
        }
    }

    // MARK: - Lensfun status

    @ViewBuilder private var lensfunStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: manager.isInstalled ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(manager.isInstalled ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            Text("Lensfun database: \(manager.statusText)")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        if let date = manager.databaseDate {
            Text("Database dated \(date.formatted(date: .abbreviated, time: .omitted)).")
                .font(.caption2).foregroundStyle(.secondary)
        }
        HStack(spacing: 10) {
            Button("Import Lensfun Database…") { showsPicker = true }
                .help("Choose a Lensfun XML file or the folder an update was unpacked into. Nothing is downloaded.")
                .accessibilityLabel("Import Lensfun Database")
            if manager.isInstalled {
                Button("Remove") { manager.uninstall() }
                    .help("Remove the imported database. Projects that name a Lensfun profile keep the name and report it as missing.")
            }
            Spacer(minLength: 0)
        }
        if let error = manager.lastError {
            Text(error).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        Text("Importing reads Lensfun's XML profile data only. No Lensfun code is installed or run, and nothing is fetched without your choosing a file.")
            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if manager.isInstalled {
            matchingRows
        } else {
            Text("Without a database, Apple Native correction still works and nothing in this panel changes the picture.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        fileImporter
    }

    private var fileImporter: some View {
        Color.clear
            .frame(height: 0)
            .fileImporter(isPresented: $showsPicker, allowedContentTypes: [.xml, .folder], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    manager.install(from: urls)
                case .failure(let error):
                    // A cancelled panel is not an error worth reporting; anything else is the panel's own failure.
                    if (error as NSError).code != NSUserCancelledError {
                        manager.report(error)
                    }
                }
            }
    }

    // MARK: - Detected camera and lens

    private var metadata: LensMetadata { session.filterEdit?.lensMetadata ?? LensMetadata() }

    @ViewBuilder private var metadataRows: some View {
        if metadata.isEmpty {
            Text("This layer carries no camera or lens tags, so no profile can be looked up.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if let camera = metadata.cameraDescription {
                    Text("Camera: \(camera)").font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let lens = metadata.lensDescription {
                    Text("Lens: \(lens)").font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let shot = shotDescription
                if !shot.isEmpty {
                    Text(shot).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var shotDescription: String {
        var parts: [String] = []
        if metadata.focalLengthMm > 0 { parts.append("\(Int(metadata.focalLengthMm.rounded())) mm") }
        if metadata.aperture > 0 { parts.append("f/\(String(format: "%.1f", metadata.aperture))") }
        return parts.joined(separator: "  •  ")
    }

    // MARK: - Matching

    @ViewBuilder private var matchingRows: some View {
        if let database = manager.database {
            let match = database.match(metadata)
            let chosen = chosenLens(in: database, match: match)
            HStack(spacing: 8) {
                Text("Matching").font(.caption)
                Picker("Matching", selection: Binding(get: { profile.selection.automatic },
                                                      set: { setAutomatic($0) })) {
                    Text("Automatic").tag(true)
                    Text("Manual").tag(false)
                }
                .labelsHidden().fixedSize()
                .accessibilityLabel("Lens Profile Matching")
                Spacer(minLength: 0)
            }
            if profile.selection.automatic {
                automaticResult(match)
            } else {
                manualPicker(database: database, match: match)
            }
            if let chosen {
                profileSummary(chosen, camera: database.camera(forLens: chosen, metadata: metadata))
            }
            calibratedNotice
        }
    }

    private func chosenLens(in database: LensfunDatabase, match: LensfunMatch) -> LensfunLens? {
        if profile.selection.automatic { return match.isConfident ? match.lens : nil }
        guard profile.selection.hasChoice else { return nil }
        return database.lens(id: profile.selection.lensID)
    }

    private func setAutomatic(_ automatic: Bool) {
        update { settings in
            var selection = settings.cameraRaw.optics.lensProfile.selection
            selection.automatic = automatic
            settings.cameraRaw.optics.lensProfile.selection = selection.normalized
        }
    }

    @ViewBuilder private func automaticResult(_ match: LensfunMatch) -> some View {
        switch match.issue {
        case .none:
            if let lens = match.lens {
                Text("Matched \(lens.description)").font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .noMetadata:
            Text("No camera or lens tags to match against.").font(.caption2).foregroundStyle(.secondary)
        case .lensNotInDatabase(let name):
            warning("No database entry matches “\(name)”.")
        case .mountMismatch(let name):
            warning("“\(name)” is in the database, but not for this camera's mount.")
        case .focalMismatch(let name):
            warning("“\(name)” does not cover \(Int(metadata.focalLengthMm.rounded())) mm on this camera.")
        case .ambiguous(let names):
            warning("More than one entry fits “\(names.first ?? "this lens")”. Choose one under Manual.")
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption2)
                .accessibilityHidden(true)
            Text(text).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func manualPicker(database: LensfunDatabase, match: LensfunMatch) -> some View {
        // The plausible entries, which is every candidate the automatic match considered plus, when nothing
        // matched, the lenses whose names are close enough to be the same glass under another spelling.
        let options = manualOptions(database: database, match: match)
        if options.isEmpty {
            Text("No lens in the database is close enough to choose from.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            Picker("Profile", selection: Binding(get: { profile.selection.lensID },
                                                 set: { setLens($0, in: database) })) {
                Text("Choose a lens…").tag("")
                ForEach(options, id: \.id) { lens in
                    Text(lensOptionTitle(lens)).tag(lens.id)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Lens Profile Selection")
        }
        if profile.selection.hasChoice, database.lens(id: profile.selection.lensID) == nil {
            warning("The chosen profile is no longer in the installed database.")
        }
    }

    private func manualOptions(database: LensfunDatabase, match: LensfunMatch) -> [LensfunLens] {
        var options = match.candidates
        if options.isEmpty { options = database.lenses(matching: metadata) }
        if options.isEmpty, let camera = database.cameras(matching: metadata).first {
            // A camera with no lens tag: offer what that body can take.
            options = database.lenses.filter { database.mountMatches(camera, $0) }
        }
        // One row per lens identity, so two identical entries do not appear twice.
        var seen = Set<String>()
        return options.filter { seen.insert($0.id).inserted }
    }

    private func lensOptionTitle(_ lens: LensfunLens) -> String {
        var parts = [lens.description]
        if !lens.mounts.isEmpty { parts.append(lens.mounts.joined(separator: ", ")) }
        if lens.cropFactor > 0 { parts.append(String(format: "crop %.2f", lens.cropFactor)) }
        return parts.joined(separator: " — ")
    }

    private func setLens(_ id: String, in database: LensfunDatabase) {
        update { settings in
            var selection = settings.cameraRaw.optics.lensProfile.selection
            selection.automatic = false
            selection.lensID = id
            selection.cameraID = database.lens(id: id).flatMap { database.camera(forLens: $0, metadata: metadata)?.id } ?? ""
            settings.cameraRaw.optics.lensProfile.selection = selection
        }
    }

    /// What the matched profile actually carries, measured against this shot. A missing calibration is named as
    /// missing rather than implied.
    private func profileSummary(_ lens: LensfunLens, camera: LensfunCamera?) -> some View {
        let available = lens.calibrations(coveringFocal: metadata.focalLengthMm, aperture: metadata.aperture)
        return VStack(alignment: .leading, spacing: 2) {
            Text("Profile: \(lens.description)").font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let camera {
                Text("Measured on \(camera.description)" + (camera.cropFactor > 0 ? String(format: " (crop %.2f)", camera.cropFactor) : ""))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if available.any {
                Text("Calibrated for: \(available.names.joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This profile has no calibration covering \(shotDescription.isEmpty ? "this shot" : shotDescription).")
                    .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The honest statement about what happens to pixels: a match describes the lens, and nothing is applied yet.
    private var calibratedNotice: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.secondary).font(.caption2).accessibilityHidden(true)
            Text("Calibrated Lensfun correction is not available in this version. A match describes what this profile could correct; no pixels are changed by it.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Correction policy

    @ViewBuilder private var policyNotice: some View {
        let policy = session.filterEdit?.lensCorrectionPolicy ?? CameraRawLensCorrectionPolicy(
            source: .renderedImage, provider: profile.provider, appleCorrectionActive: false,
            manualAdjustmentsActive: raw.optics.adjusts)
        Text(policy.explanation)
            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func update(_ change: (inout FilterSettings) -> Void) {
        var value = settings
        change(&value)
        session.updateFilter(value, preview: session.filterEdit?.preview ?? true)
    }
}
