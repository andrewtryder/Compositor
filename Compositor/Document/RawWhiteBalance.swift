import CoreGraphics
import Foundation

/// How a RAW's white balance is arrived at. As Shot keeps the camera's own reading, Auto measures the frame
/// through the decoder's sensor model, and Custom is the absolute Kelvin and tint the sliders show.
///
/// Kelvin and tint here are the decoder's own white-balance coordinates: changing them re-develops the sensor
/// data, so they are absolute (5200 K is 5200 K for this camera), unlike the Camera Raw Filter's relative
/// Temperature and Tint, which shift an already-developed picture.
nonisolated enum RawWhiteBalanceMode: String, Codable, Sendable, CaseIterable {
    case asShot = "As Shot"
    case auto = "Auto"
    case custom = "Custom"
}

/// One solved balance: absolute Kelvin/tint on the decoder's scale, and the cast it left behind (0 is neutral).
nonisolated struct RawWhiteBalanceSolution: Equatable, Sendable {
    var temperature: Float
    var tint: Float
    /// The mean color's chroma after developing at this balance, normalized 0…1. Zero is a perfectly gray frame.
    var cast: Double
}

nonisolated enum RawWhiteBalance {
    /// The decoder's own white-balance ranges, as `CIRAWFilter` documents them.
    static let temperatureRange: ClosedRange<Float> = 2000...50000
    static let tintRange: ClosedRange<Float> = -150...150

    /// How far from gray the mean color of a developed frame is: the spread of its channels over the largest.
    /// Nil when the frame has no coverage. A gray world's neutral balance is the one that minimizes this.
    static func cast(red: Double, green: Double, blue: Double) -> Double? {
        let total = red + green + blue
        guard total > 1e-9, red.isFinite, green.isFinite, blue.isFinite, red >= 0, green >= 0, blue >= 0 else { return nil }
        let largest = max(red, green, blue), smallest = min(red, green, blue)
        guard largest > 0 else { return nil }
        return (largest - smallest) / largest
    }

    /// The cast of a developed frame, measured from its pixels. Fully transparent pixels are skipped; the average
    /// is taken in linear light, where "neutral" means equal channels.
    static func cast(of image: CGImage) -> Double? {
        guard image.width > 0, image.height > 0,
              let context = try? BrushRaster.context(width: image.width, height: image.height, mask: false) else { return nil }
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
                red += decode(Double(bytes[pixel]) / alpha)
                green += decode(Double(bytes[pixel + 1]) / alpha)
                blue += decode(Double(bytes[pixel + 2]) / alpha)
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return cast(red: red / count, green: green / count, blue: blue / count)
    }

    /// Searches the decoder's temperature and tint for the balance whose developed frame is closest to gray.
    ///
    /// `measure` develops one frame at a balance and returns its cast (nil when it could not be developed). The
    /// decoder's own profile maps Kelvin and tint to RGB, so what this solves for is the camera's neutral, not a
    /// generic one — the search only proposes balances, the sensor model decides what they look like. Each axis is
    /// searched in turn, twice over: the cast is smooth in both and has a single minimum near neutral.
    static func solve(startingAt start: (temperature: Float, tint: Float),
                      temperature range: ClosedRange<Float> = temperatureRange,
                      tint tintLimits: ClosedRange<Float> = tintRange,
                      rounds: Int = 2, steps: Int = 12,
                      measure: (Float, Float) -> Double?) -> RawWhiteBalanceSolution? {
        var best = (temperature: clamp(start.temperature, range), tint: clamp(start.tint, tintLimits))
        guard let initial = measure(best.temperature, best.tint) else { return nil }
        var bestCast = initial
        for _ in 0..<max(1, rounds) {
            if let temperature = narrow(range, steps: steps, current: best.temperature,
                                        cost: { measure($0, best.tint) }),
               let cast = measure(temperature, best.tint), cast <= bestCast {
                best.temperature = temperature
                bestCast = cast
            }
            if let tint = narrow(tintLimits, steps: steps, current: best.tint,
                                 cost: { measure(best.temperature, $0) }),
               let cast = measure(best.temperature, tint), cast <= bestCast {
                best.tint = tint
                bestCast = cast
            }
        }
        return RawWhiteBalanceSolution(temperature: best.temperature, tint: best.tint, cast: bestCast)
    }

    /// Ternary search for the minimum of `cost` over `range`, kept to `steps` evaluations each side. Nil when
    /// nothing could be measured.
    private static func narrow(_ range: ClosedRange<Float>, steps: Int, current: Float,
                               cost: (Float) -> Double?) -> Float? {
        var low = range.lowerBound, high = range.upperBound
        let count = max(2, steps)
        for _ in 0..<count where high - low > 1 {
            let third = (high - low) / 3
            let left = low + third, right = high - third
            guard let leftCost = cost(left), let rightCost = cost(right) else { return nil }
            if leftCost <= rightCost { high = right } else { low = left }
        }
        let middle = (low + high) / 2
        // The starting point stays the answer unless the search found something measurably better.
        guard let started = cost(current), let middleCost = cost(middle), middleCost < started else { return current }
        return middle
    }

    private static func clamp(_ value: Float, _ range: ClosedRange<Float>) -> Float {
        guard value.isFinite else { return (range.lowerBound + range.upperBound) / 2 }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    private static func decode(_ encoded: Double) -> Double {
        let value = min(1, max(0, encoded))
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
