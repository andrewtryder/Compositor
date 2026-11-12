import AppKit
import Foundation

/// Edge-orientation summary for a validation image.
/// Strong edges within 25° of an axis are the structural population.
/// The reported error is that population's absolute deviation from the axis:
/// median and 90th percentile, not the single strongest line.
struct LineStats: Encodable {
    var count: Int
    var medianDegrees: Double
    var p90Degrees: Double
    var within1_5: Double
}

struct ImageStats: Encodable {
    var file: String
    var width: Int
    var height: Int
    var opaqueFraction: Double
    var vertical: LineStats
    var horizontal: LineStats
}

func load(_ path: String) -> (NSBitmapImageRep, Int, Int)? {
    guard let image = NSImage(contentsOfFile: path),
          let rep = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()) else { return nil }
    return (rep, rep.pixelsWide, rep.pixelsHigh)
}

func stats(_ path: String) -> ImageStats? {
    guard let (source, width, height) = load(path) else { return nil }
    let maxSide = 800
    let scale = min(1.0, Double(maxSide) / Double(max(width, height)))
    let w = max(2, Int((Double(width) * scale).rounded()))
    let h = max(2, Int((Double(height) * scale).rounded()))
    let small = NSImage(size: NSSize(width: w, height: h))
    small.lockFocus()
    NSImage(contentsOfFile: path)?.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
    small.unlockFocus()
    guard let rep = NSBitmapImageRep(data: small.tiffRepresentation ?? Data()) else { return nil }

    var gray = [Float](repeating: 0, count: w * h)
    var opaque = 0
    for y in 0..<h {
        for x in 0..<w {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            if c.alphaComponent >= 0.94 { opaque += 1 }
            gray[y * w + x] = Float((c.redComponent + c.greenComponent + c.blueComponent) / 3)
        }
    }
    var mags: [Float] = []
    mags.reserveCapacity(w * h / 2)
    for y in 1..<(h - 1) {
        for x in 1..<(w - 1) {
            let i = y * w + x
            let gx = gray[i + 1] - gray[i - 1]
            let gy = gray[i + w] - gray[i - w]
            let mag = hypot(gx, gy)
            guard mag > 0.08 else { continue }
            mags.append(mag)
        }
    }
    mags.sort()
    let cutoff = mags.isEmpty ? 1 : mags[min(mags.count - 1, Int(Double(mags.count) * 0.92))]
    var vertical: [Double] = []
    var horizontal: [Double] = []
    for y in 1..<(h - 1) {
        for x in 1..<(w - 1) {
            let i = y * w + x
            let gx = gray[i + 1] - gray[i - 1]
            let gy = gray[i + w] - gray[i - w]
            let mag = hypot(gx, gy)
            guard mag >= cutoff else { continue }
            var degrees = atan2(Double(gy), Double(gx)) * 180 / .pi
            // Edge normal to undirected line orientation.
            degrees += 90
            while degrees < 0 { degrees += 180 }
            while degrees >= 180 { degrees -= 180 }
            let fromVertical = min(abs(degrees - 90), abs(degrees - 270))
            let fromHorizontal = min(degrees, 180 - degrees)
            if fromVertical <= 25 { vertical.append(fromVertical) }
            else if fromHorizontal <= 25 { horizontal.append(fromHorizontal) }
        }
    }
    func summarize(_ values: [Double]) -> LineStats {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return LineStats(count: 0, medianDegrees: -1, p90Degrees: -1, within1_5: 0) }
        let mid = sorted[sorted.count / 2]
        let p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        let close = Double(sorted.filter { $0 <= 1.5 }.count) / Double(sorted.count)
        return LineStats(count: sorted.count, medianDegrees: (mid * 100).rounded() / 100,
                         p90Degrees: (p90 * 100).rounded() / 100,
                         within1_5: (close * 1000).rounded() / 1000)
    }
    return ImageStats(
        file: (path as NSString).lastPathComponent,
        width: width,
        height: height,
        opaqueFraction: (Double(opaque) / Double(w * h) * 1000).rounded() / 1000,
        vertical: summarize(vertical),
        horizontal: summarize(horizontal)
    )
}

let paths = Array(CommandLine.arguments.dropFirst())
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
var rows: [ImageStats] = []
for path in paths {
    if let row = stats(path) { rows.append(row) }
    else { fputs("unreadable \(path)\n", stderr) }
}
let data = try encoder.encode(rows)
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
