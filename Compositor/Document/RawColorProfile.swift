import CoreGraphics
import CoreImage
import Foundation

/// Which profile decides what the sensor's colors look like. This is the photographic profile — the camera's
/// color rendering — and not Optics › Lens Profile, which corrects a lens; the two never share a selection.
///
/// The decoder's own profiles are the only camera profiles the system can name, so Compositor offers those and,
/// for a look that is not the camera's, an ICC profile the person supplies. DCP is recognized and refused:
/// reading it would mean a proprietary parser and Adobe's own profile data, which cannot ship here.
nonisolated enum RawColorProfileKind: String, Codable, Sendable, CaseIterable {
    /// The decoder's own rendering for this camera, exactly as every earlier version developed it.
    case cameraDefault = "Camera Default"
    /// The same decode without its tone curve: linear sensor color, for a grade that starts from the raw data.
    case linear = "Linear"
    /// An ICC profile the person selected; the pixels are interpreted through it.
    case icc = "ICC Profile"
}

nonisolated enum RawColorProfileError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedFormat(String)
    case malformedProfile
    case missingProfile

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let name):
            return "\(name) is not supported. Compositor reads ICC profiles; a DCP needs Adobe's own profile data "
                + "and a proprietary parser, so it is refused rather than approximated."
        case .malformedProfile: return "That file is not a readable ICC profile."
        case .missingProfile: return "The ICC profile this project used is missing, so the camera's own rendering is shown."
        }
    }
}

/// A photographic profile choice, with identity for a project that never made one: Camera Default renders the
/// sensor exactly as before this existed.
nonisolated struct RawColorProfile: Equatable, Sendable, Codable {
    var kind: RawColorProfileKind = .cameraDefault
    /// The ICC profile's bytes, kept in the project so reopening it does not depend on the original file.
    var iccData: Data?
    /// The profile's own name, as its file gave it, for the panel and for persistence.
    var name: String = ""
    /// 0…100. Only an ICC profile has a strength: the decoder's profiles are the camera's rendering, whole.
    var strength: Double = 100

    static let strengthRange: ClosedRange<Double> = 0...100

    /// Whether this profile changes any pixels.
    var adjusts: Bool {
        switch kind {
        case .cameraDefault: return false
        case .linear: return true
        case .icc: return iccData != nil && strength > 0
        }
    }

    var normalized: Self {
        var result = self
        result.strength = min(100, max(0, strength.isFinite ? strength : 100))
        if result.kind != .icc { result.strength = 100 }
        if result.kind != .icc { result.iccData = nil }
        return result
    }

    // MARK: - Reading a profile from a file

    /// Reads an ICC profile the person picked. A DCP is identified by its own signature and refused with the reason,
    /// rather than being accepted and silently ignored.
    static func read(url: URL) throws -> (profile: RawColorProfile, data: Data) {
        let data = try Data(contentsOf: url)
        let name = url.deletingPathExtension().lastPathComponent
        if url.pathExtension.lowercased() == "dcp" || data.starts(with: Data("DCP\0".utf8)) {
            throw RawColorProfileError.unsupportedFormat("A DCP profile (\(name))")
        }
        guard validatedColorSpace(from: data) != nil else { throw RawColorProfileError.malformedProfile }
        return (RawColorProfile(kind: .icc, iccData: data, name: name, strength: 100), data)
    }

    /// Whether `data` is a profile Core Graphics will use, and the color space it makes.
    static func validatedColorSpace(from data: Data) -> CGColorSpace? {
        guard data.count > 128 else { return nil }
        guard let space = CGColorSpace(iccData: data as CFData) else { return nil }
        // A space that cannot describe a model Core Image can render is no use as a look.
        guard space.model == .rgb || space.model == .monochrome else { return nil }
        return space
    }

    // MARK: - Applying it

    /// The image seen through this profile. An ICC profile's pixels are interpreted through it and converted back
    /// to sRGB for display, then mixed with the original by `strength`; at zero the result is the exact input.
    /// The decoder's profiles are applied while the RAW is developed (see `RawImporter`), never here, so a camera
    /// transform is never applied twice.
    func applying(to image: CGImage) throws -> CGImage {
        let profile = normalized
        switch profile.kind {
        case .cameraDefault, .linear:
            // Developed with the decoder: nothing left to do to the pixels.
            return image
        case .icc:
            guard let data = profile.iccData else { throw RawColorProfileError.missingProfile }
            guard let space = Self.validatedColorSpace(from: data) else { throw RawColorProfileError.malformedProfile }
            guard let tagged = image.copy(colorSpace: space) else { throw RawColorProfileError.malformedProfile }
            let width = image.width, height = image.height
            let extent = CGRect(x: 0, y: 0, width: width, height: height)
            // Keep a 16-bit develop 16-bit through the look, so a deep layer does not lose precision it had.
            let deep = image.bitsPerComponent >= 16
            guard let converted = Self.context.createCGImage(CIImage(cgImage: tagged), from: extent,
                                                             format: deep ? .RGBA16 : .RGBA8,
                                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            else { throw RawColorProfileError.malformedProfile }
            guard profile.strength < 100 else { return converted }
            return try Self.mix(image, converted, amount: profile.strength / 100)
        }
    }

    /// No color management turned on beyond the profile itself: the profile's own conversion is the whole
    /// transformation, and nothing is rounded twice.
    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .workingFormat: CIFormat.RGBAh,
    ])

    /// `original` mixed with `converted` by `amount` (0…1), in floating point and without color conversion, so
    /// the endpoints are exact.
    static func mix(_ original: CGImage, _ converted: CGImage, amount: Double) throws -> CGImage {
        let width = original.width, height = original.height
        guard converted.width == width, converted.height == height else { throw RawColorProfileError.malformedProfile }
        let value = min(1, max(0, amount))
        if value <= 0 { return original }
        if value >= 1 { return converted }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let mixed = CIImage(cgImage: converted).applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: CIImage(cgImage: original),
            kCIInputTimeKey: 1 - value,
        ])
        guard let result = PixelAdjust.ciContext.createCGImage(mixed.cropped(to: extent), from: extent,
                                                              format: original.bitsPerComponent >= 16 ? .RGBA16 : .RGBA8,
                                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw RawColorProfileError.malformedProfile
        }
        return result
    }
}
