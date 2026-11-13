import CoreGraphics
import Foundation
import simd

/// Regular rectangular mesh for the ReShape tool. Dimensions are **control-point counts**
/// (an 8×8 mesh has 64 points and 7×7 cells). Rest and current positions are in
/// **normalized layer-image UV** space: (0,0) top-left, (1,1) bottom-right.
nonisolated struct MeshWarpGrid: Equatable, Sendable {
    /// Control points across (X). Must be ≥ 2.
    var pointColumns: Int
    /// Control points down (Y). Must be ≥ 2.
    var pointRows: Int
    /// Current destination positions in UV.
    var positions: [SIMD2<Float>]
    /// Bind / rest pose in UV (usually the uniform lattice).
    var rest: [SIMD2<Float>]
    var stickyBorders: Bool
    /// 0…1. Radius of neighbor influence as a fraction of the image diagonal in UV
    /// (√2). Zero moves only the dragged point.
    var propagation: Float

    var pointCount: Int { pointColumns * pointRows }
    var cellColumns: Int { pointColumns - 1 }
    var cellRows: Int { pointRows - 1 }

    static let presets = [4, 8, 16]
    static let maxPoints = 10_000
    /// Reject triangle updates whose |signed area| in UV falls below this.
    static let minimumTriangleArea: Float = 1e-8

    enum Preset: Int, CaseIterable, Sendable {
        case points4 = 4, points8 = 8, points16 = 16
        var label: String { "\(rawValue)×\(rawValue)" }
    }

    /// Uniform rest lattice. Fails when the point count is out of range.
    static func identity(pointColumns: Int, pointRows: Int,
                         stickyBorders: Bool = true, propagation: Float = 0) -> MeshWarpGrid? {
        guard pointColumns >= 2, pointRows >= 2,
              pointColumns * pointRows <= maxPoints else { return nil }
        var rest: [SIMD2<Float>] = []
        rest.reserveCapacity(pointColumns * pointRows)
        for row in 0..<pointRows {
            let v = Float(row) / Float(pointRows - 1)
            for column in 0..<pointColumns {
                let u = Float(column) / Float(pointColumns - 1)
                rest.append(SIMD2(u, v))
            }
        }
        return MeshWarpGrid(pointColumns: pointColumns, pointRows: pointRows,
                            positions: rest, rest: rest,
                            stickyBorders: stickyBorders,
                            propagation: max(0, min(1, propagation)))
    }

    static func identity(preset: Preset, stickyBorders: Bool = true, propagation: Float = 0) -> MeshWarpGrid {
        identity(pointColumns: preset.rawValue, pointRows: preset.rawValue,
                 stickyBorders: stickyBorders, propagation: propagation)!
    }

    func index(column: Int, row: Int) -> Int { row * pointColumns + column }
    func column(of index: Int) -> Int { index % pointColumns }
    func row(of index: Int) -> Int { index / pointColumns }

    func isBorder(_ index: Int) -> Bool {
        let c = column(of: index), r = row(of: index)
        return c == 0 || r == 0 || c == pointColumns - 1 || r == pointRows - 1
    }

    var isIdentity: Bool {
        zip(positions, rest).allSatisfy { abs($0.x - $1.x) < 1e-7 && abs($0.y - $1.y) < 1e-7 }
    }

    mutating func resetToRest() { positions = rest }

    /// UV → layer pixel centers space uses width/height of the bitmap.
    static func pixel(fromUV uv: SIMD2<Float>, width: Int, height: Int) -> SIMD2<Float> {
        SIMD2(uv.x * Float(max(width - 1, 0)), uv.y * Float(max(height - 1, 0)))
    }

    static func uv(fromPixel pixel: SIMD2<Float>, width: Int, height: Int) -> SIMD2<Float> {
        let sx = Float(max(width - 1, 1)), sy = Float(max(height - 1, 1))
        return SIMD2(pixel.x / sx, pixel.y / sy)
    }

    /// Hit-test in UV. `radius` is in UV units.
    func hitTest(uv: SIMD2<Float>, radius: Float) -> Int? {
        var best: Int?, bestDistance = radius * radius
        for (index, position) in positions.enumerated() {
            let d = position - uv
            let distance = d.x * d.x + d.y * d.y
            if distance <= bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// Attempt to move `index` to `destination` (and neighbors by propagation). Returns false
    /// when the move would fold a triangle or violate sticky borders; the mesh is unchanged.
    @discardableResult
    mutating func tryMove(index: Int, to destination: SIMD2<Float>) -> Bool {
        guard positions.indices.contains(index) else { return false }
        if stickyBorders, isBorder(index) { return false }

        let clamped = SIMD2(max(0, min(1, destination.x)), max(0, min(1, destination.y)))
        let delta = clamped - positions[index]
        if abs(delta.x) < 1e-12, abs(delta.y) < 1e-12 { return true }

        var trial = positions
        trial[index] = clamped

        if propagation > 1e-6 {
            let radius = propagation * Float(2).squareRoot()
            guard radius > 1e-6 else { return install(trial) }
            let origin = rest[index]
            for other in positions.indices where other != index {
                if stickyBorders, isBorder(other) { continue }
                let offset = rest[other] - origin
                let distance = (offset.x * offset.x + offset.y * offset.y).squareRoot()
                if distance >= radius { continue }
                // Smoothstep falloff: 1 at the handle, 0 at the radius.
                let t = 1 - distance / radius
                let weight = t * t * (3 - 2 * t)
                let moved = positions[other] + delta * weight
                trial[other] = SIMD2(max(0, min(1, moved.x)), max(0, min(1, moved.y)))
            }
        }

        return install(trial)
    }

    private mutating func install(_ trial: [SIMD2<Float>]) -> Bool {
        guard Self.trianglesValid(pointColumns: pointColumns, pointRows: pointRows, positions: trial) else {
            return false
        }
        positions = trial
        return true
    }

    /// Every cell is split along the diagonal (0,0)-(1,1) in cell space into two triangles.
    static func trianglesValid(pointColumns: Int, pointRows: Int, positions: [SIMD2<Float>]) -> Bool {
        for row in 0..<(pointRows - 1) {
            for column in 0..<(pointColumns - 1) {
                let i00 = row * pointColumns + column
                let i10 = i00 + 1
                let i01 = i00 + pointColumns
                let i11 = i01 + 1
                let a = positions[i00], b = positions[i10], c = positions[i11], d = positions[i01]
                // Keep both triangles oriented the same way as the rest lattice (counter-clockwise in UV with y down
                // still has positive cross for (b-a)×(d-a) on identity: (1,0)×(0,1) = 1).
                if abs(signedArea(a, b, c)) < minimumTriangleArea { return false }
                if abs(signedArea(a, c, d)) < minimumTriangleArea { return false }
                if signedArea(a, b, c) * signedArea(a, c, d) < 0 { return false }
            }
        }
        return true
    }

    static func signedArea(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
}

/// One destination triangle with corresponding rest (source) vertices.
nonisolated struct MeshWarpTriangle: Sendable {
    var destination: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)
    var source: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)
}

extension MeshWarpGrid {
    /// Destination triangles in UV, paired with rest UV for source lookup.
    nonisolated func triangles() -> [MeshWarpTriangle] {
        var list: [MeshWarpTriangle] = []
        list.reserveCapacity(cellColumns * cellRows * 2)
        for row in 0..<cellRows {
            for column in 0..<cellColumns {
                let i00 = index(column: column, row: row)
                let i10 = index(column: column + 1, row: row)
                let i01 = index(column: column, row: row + 1)
                let i11 = index(column: column + 1, row: row + 1)
                list.append(MeshWarpTriangle(destination: (positions[i00], positions[i10], positions[i11]),
                                             source: (rest[i00], rest[i10], rest[i11])))
                list.append(MeshWarpTriangle(destination: (positions[i00], positions[i11], positions[i01]),
                                             source: (rest[i00], rest[i11], rest[i01])))
            }
        }
        return list
    }
}
