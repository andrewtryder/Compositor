import CoreGraphics
import Foundation
import simd

/// Status of a local ReShape geometry correction.
nonisolated struct MeshWarpLocalStatus: Equatable, Sendable {
    var ok: Bool
    var reason: String
    static let success = MeshWarpLocalStatus(ok: true, reason: "OK")
    static func rejected(_ reason: String) -> MeshWarpLocalStatus {
        MeshWarpLocalStatus(ok: false, reason: reason)
    }
}

/// How disjoint selection components are treated.
nonisolated enum MeshWarpDisjointRegionPolicy: String, Sendable {
    /// Each connected component gets its own pivot / bbox / transform.
    case independent
    /// One shared pivot / bbox for the union (explicit opt-in).
    case unified
}

/// Selection region for local Perspective / Horizon / Volume.
nonisolated struct MeshWarpCorrectionRegion: Equatable, Sendable {
    var vertexIDs: Set<MeshWarpVertexID>
    var faceIDs: Set<MeshWarpFaceID>
    var policy: MeshWarpDisjointRegionPolicy

    static let empty = MeshWarpCorrectionRegion(vertexIDs: [], faceIDs: [], policy: .independent)

    init(vertexIDs: Set<MeshWarpVertexID> = [], faceIDs: Set<MeshWarpFaceID> = [],
         policy: MeshWarpDisjointRegionPolicy = .independent) {
        self.vertexIDs = vertexIDs
        self.faceIDs = faceIDs
        self.policy = policy
    }

    static func fromSelection(_ selection: MeshWarpSelection,
                              mesh: MeshWarpGrid,
                              policy: MeshWarpDisjointRegionPolicy = .independent) -> MeshWarpCorrectionRegion {
        let ids = selection.ids
        let faces = mesh.topology.leafFacesTouching(vertexIDs: ids)
        return MeshWarpCorrectionRegion(vertexIDs: ids, faceIDs: faces, policy: policy)
    }

    static func rectangle(uvRect: CGRect, mesh: MeshWarpGrid,
                          policy: MeshWarpDisjointRegionPolicy = .independent) -> MeshWarpCorrectionRegion {
        var selection = MeshWarpSelection()
        selection.selectMarquee(uvRect: uvRect, mesh: mesh, additive: false)
        return fromSelection(selection, mesh: mesh, policy: policy)
    }

    /// Deterministic set of mesh vertex indices affected as primary seeds.
    func resolvedVertexIndices(in mesh: MeshWarpGrid) -> Set<Int> {
        var ids = vertexIDs
        for faceID in faceIDs {
            if let face = mesh.topology.faces[faceID] {
                ids.formUnion(face.corners)
            }
        }
        return Set(ids.compactMap { mesh.index(of: $0) })
    }

    /// Connected components over leaf-face adjacency among selected faces / verts.
    func connectedComponents(in mesh: MeshWarpGrid) -> [Set<Int>] {
        let seeds = resolvedVertexIndices(in: mesh)
        guard !seeds.isEmpty else { return [] }
        if policy == .unified { return [seeds] }

        // Build adjacency: vertices sharing a leaf face are connected.
        var adjacency: [Int: Set<Int>] = [:]
        for faceID in mesh.topology.leafFaceIDs {
            guard let face = mesh.topology.faces[faceID] else { continue }
            let idxs = face.corners.compactMap { mesh.index(of: $0) }.filter { seeds.contains($0) }
            guard idxs.count >= 2 else {
                if let only = idxs.first { adjacency[only, default: []].formUnion([]) }
                continue
            }
            for i in idxs {
                for j in idxs where i != j {
                    adjacency[i, default: []].insert(j)
                }
            }
        }
        for index in seeds { adjacency[index, default: []].formUnion([]) }

        var remaining = seeds
        var components: [Set<Int>] = []
        while let start = remaining.sorted().first {
            var stack = [start]
            var component: Set<Int> = []
            while let index = stack.popLast() {
                guard remaining.contains(index) else { continue }
                remaining.remove(index)
                component.insert(index)
                stack.append(contentsOf: adjacency[index] ?? [])
            }
            components.append(component)
        }
        return components.sorted { ($0.min() ?? 0) < ($1.min() ?? 0) }
    }

    func pivotUV(in positions: [SIMD2<Float>], indices: Set<Int>) -> SIMD2<Float>? {
        MeshWarpGrid.barycenter(indices: indices, in: positions)
    }

    func boundingUV(in positions: [SIMD2<Float>], indices: Set<Int>) -> (min: SIMD2<Float>, max: SIMD2<Float>)? {
        let list = indices.filter { positions.indices.contains($0) }
        guard let first = list.first else { return nil }
        var minP = positions[first], maxP = positions[first]
        for index in list {
            let p = positions[index]
            minP = SIMD2(min(minP.x, p.x), min(minP.y, p.y))
            maxP = SIMD2(max(maxP.x, p.x), max(maxP.y, p.y))
        }
        return (minP, maxP)
    }
}

// MARK: - Homography (clean-room DLT)

/// 3×3 homography in row-major image-pixel coordinates.
nonisolated struct MeshWarpHomography: Equatable, Sendable {
    var m: (Float, Float, Float, Float, Float, Float, Float, Float, Float)

    static let identity = MeshWarpHomography(m: (1, 0, 0, 0, 1, 0, 0, 0, 1))

    static func == (lhs: MeshWarpHomography, rhs: MeshWarpHomography) -> Bool {
        lhs.m.0 == rhs.m.0 && lhs.m.1 == rhs.m.1 && lhs.m.2 == rhs.m.2 &&
        lhs.m.3 == rhs.m.3 && lhs.m.4 == rhs.m.4 && lhs.m.5 == rhs.m.5 &&
        lhs.m.6 == rhs.m.6 && lhs.m.7 == rhs.m.7 && lhs.m.8 == rhs.m.8
    }

    func apply(_ p: SIMD2<Float>) -> SIMD2<Float>? {
        let x = m.0 * p.x + m.1 * p.y + m.2
        let y = m.3 * p.x + m.4 * p.y + m.5
        let w = m.6 * p.x + m.7 * p.y + m.8
        guard w.isFinite, abs(w) > 1e-8 else { return nil }
        let rx = x / w, ry = y / w
        guard rx.isFinite, ry.isFinite else { return nil }
        return SIMD2(rx, ry)
    }

    /// Normalize so m8 == 1 when possible.
    func normalized() -> MeshWarpHomography? {
        let scale = m.8
        if abs(scale) > 1e-12 {
            return MeshWarpHomography(m: (
                m.0 / scale, m.1 / scale, m.2 / scale,
                m.3 / scale, m.4 / scale, m.5 / scale,
                m.6 / scale, m.7 / scale, 1
            ))
        }
        // Fall back to Frobenius normalization.
        let fro = sqrt(m.0*m.0 + m.1*m.1 + m.2*m.2 + m.3*m.3 + m.4*m.4 +
                       m.5*m.5 + m.6*m.6 + m.7*m.7 + m.8*m.8)
        guard fro > 1e-12 else { return nil }
        return MeshWarpHomography(m: (
            m.0 / fro, m.1 / fro, m.2 / fro,
            m.3 / fro, m.4 / fro, m.5 / fro,
            m.6 / fro, m.7 / fro, m.8 / fro
        ))
    }

    var determinantApprox: Float {
        m.0 * (m.4 * m.8 - m.5 * m.7) - m.1 * (m.3 * m.8 - m.5 * m.6) + m.2 * (m.3 * m.7 - m.4 * m.6)
    }

    /// DLT from four source→destination pixel correspondences.
    static func fromCorrespondences(source: [SIMD2<Float>], destination: [SIMD2<Float>]) -> MeshWarpHomography? {
        guard source.count == 4, destination.count == 4 else { return nil }
        guard Self.quadValid(source), Self.quadValid(destination) else { return nil }

        // Build 8×9 design matrix; solve Ah = 0 via normal equations on nullspace (SVD-free 8×8).
        // h = [h0..h7], h8 = 1.
        var a = [[Float]](repeating: [Float](repeating: 0, count: 8), count: 8)
        var b = [Float](repeating: 0, count: 8)
        for i in 0..<4 {
            let x = source[i].x, y = source[i].y
            let u = destination[i].x, v = destination[i].y
            let r = i * 2
            a[r] = [x, y, 1, 0, 0, 0, -x * u, -y * u]
            b[r] = u
            a[r + 1] = [0, 0, 0, x, y, 1, -x * v, -y * v]
            b[r + 1] = v
        }
        guard let h = Self.solveLinear8(a, b) else { return nil }
        let homo = MeshWarpHomography(m: (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], 1))
        guard let normalized = homo.normalized() else { return nil }
        guard abs(normalized.determinantApprox) > 1e-10 else { return nil }
        // Reject if any source maps non-finite or poles through the quad.
        for p in source {
            guard let q = normalized.apply(p), q.x.isFinite, q.y.isFinite else { return nil }
        }
        return normalized
    }

    static func lerp(_ a: MeshWarpHomography, _ b: MeshWarpHomography, t: Float) -> MeshWarpHomography {
        let s = max(0, min(1, t))
        func mix(_ x: Float, _ y: Float) -> Float { x * (1 - s) + y * s }
        return MeshWarpHomography(m: (
            mix(a.m.0, b.m.0), mix(a.m.1, b.m.1), mix(a.m.2, b.m.2),
            mix(a.m.3, b.m.3), mix(a.m.4, b.m.4), mix(a.m.5, b.m.5),
            mix(a.m.6, b.m.6), mix(a.m.7, b.m.7), mix(a.m.8, b.m.8)
        ))
    }

    private static func quadValid(_ points: [SIMD2<Float>]) -> Bool {
        guard points.count == 4 else { return false }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        // Non-degenerate area and consistent winding.
        var area: Float = 0
        for i in 0..<4 {
            let p = points[i], q = points[(i + 1) % 4]
            area += p.x * q.y - q.x * p.y
        }
        if abs(area) < 1e-4 { return false }
        // No near-duplicate corners.
        for i in 0..<4 {
            for j in (i + 1)..<4 {
                let d = points[i] - points[j]
                if d.x * d.x + d.y * d.y < 1e-8 { return false }
            }
        }
        return true
    }

    private static func solveLinear8(_ aIn: [[Float]], _ bIn: [Float]) -> [Float]? {
        var a = aIn
        var b = bIn
        let n = 8
        for col in 0..<n {
            var pivot = col
            var best = abs(a[col][col])
            for row in (col + 1)..<n {
                let v = abs(a[row][col])
                if v > best { best = v; pivot = row }
            }
            if best < 1e-10 { return nil }
            if pivot != col {
                a.swapAt(pivot, col)
                b.swapAt(pivot, col)
            }
            let diag = a[col][col]
            for j in col..<n { a[col][j] /= diag }
            b[col] /= diag
            for row in 0..<n where row != col {
                let factor = a[row][col]
                if factor == 0 { continue }
                for j in col..<n { a[row][j] -= factor * a[col][j] }
                b[row] -= factor * b[col]
            }
        }
        return b
    }
}

// MARK: - Local Perspective

nonisolated enum MeshWarpLocalPerspectiveMode: String, CaseIterable, Sendable {
    case fourPoint
    case vertical
    case horizontal
    case combined
}

nonisolated struct MeshWarpLocalPerspective: Equatable, Sendable {
    var mode: MeshWarpLocalPerspectiveMode = .fourPoint
    /// Source quad in image pixels (TL, TR, BR, BL).
    var sourceQuad: [SIMD2<Float>] = []
    /// Destination quad in image pixels (same order).
    var destinationQuad: [SIMD2<Float>] = []
    /// 0…1 correction amount (0 = identity).
    var amount: Float = 1

    static let identity = MeshWarpLocalPerspective(amount: 0)

    func desiredPixel(from pixel: SIMD2<Float>, pivot: SIMD2<Float>,
                      halfExtent: SIMD2<Float>) -> SIMD2<Float>? {
        let t = max(0, min(1, amount))
        if t <= 1e-9 { return pixel }

        switch mode {
        case .fourPoint:
            guard let h = MeshWarpHomography.fromCorrespondences(source: sourceQuad,
                                                                 destination: destinationQuad)
            else { return nil }
            let blended = MeshWarpHomography.lerp(.identity, h, t: t)
            return blended.apply(pixel)

        case .vertical, .horizontal, .combined:
            // Convergence correction: pull x (vertical mode) or y (horizontal mode) toward the
            // regional pivot proportional to distance along the other axis — a local keystone undo.
            let nx = halfExtent.x > 1e-6 ? (pixel.x - pivot.x) / halfExtent.x : 0
            let ny = halfExtent.y > 1e-6 ? (pixel.y - pivot.y) / halfExtent.y : 0
            var out = pixel
            let strength = t * 0.25 // keep moderate; full 1.0 would collapse edges
            if mode == .vertical || mode == .combined {
                // Reduce horizontal foreshortening with |ny|.
                out.x = pivot.x + (pixel.x - pivot.x) * (1 - strength * ny * ny)
            }
            if mode == .horizontal || mode == .combined {
                out.y = pivot.y + (pixel.y - pivot.y) * (1 - strength * nx * nx)
            }
            guard out.x.isFinite, out.y.isFinite else { return nil }
            return out
        }
    }
}

// MARK: - Local Horizon

nonisolated enum MeshWarpLocalHorizonMode: String, CaseIterable, Sendable {
    case angle
    case horizontalReference
    case verticalReference
}

nonisolated struct MeshWarpLocalHorizon: Equatable, Sendable {
    var mode: MeshWarpLocalHorizonMode = .angle
    /// Manual angle in degrees (positive = CCW in image pixels, y-down).
    var angleDegrees: Float = 0
    /// Reference segment endpoints in image pixels.
    var referenceA: SIMD2<Float> = .zero
    var referenceB: SIMD2<Float> = .zero
    var amount: Float = 1

    static let identity = MeshWarpLocalHorizon(amount: 0)

    /// Rotation that levels the reference; endpoint order does not matter.
    func levelingRadians() -> Float {
        switch mode {
        case .angle:
            return -angleDegrees * .pi / 180
        case .horizontalReference:
            let delta = referenceB - referenceA
            let angle = atan2(delta.y, delta.x)
            return -angle
        case .verticalReference:
            let delta = referenceB - referenceA
            let angle = atan2(delta.y, delta.x)
            // Vertical target is ±π/2; choose the smaller rotation.
            let toPos = Float.pi / 2 - angle
            let toNeg = -Float.pi / 2 - angle
            return abs(toPos) <= abs(toNeg) ? toPos : toNeg
        }
    }

    func desiredPixel(from pixel: SIMD2<Float>, pivot: SIMD2<Float>) -> SIMD2<Float>? {
        let t = max(0, min(1, amount))
        if t <= 1e-9 { return pixel }
        let theta = levelingRadians() * t
        let c = cos(theta), s = sin(theta)
        let r = pixel - pivot
        let out = pivot + SIMD2(r.x * c - r.y * s, r.x * s + r.y * c)
        guard out.x.isFinite, out.y.isFinite else { return nil }
        return out
    }
}

// MARK: - Local Volume

nonisolated enum MeshWarpLocalVolumeMode: String, CaseIterable, Sendable {
    case horizontal
    case vertical
    case radial
    case combined
}

nonisolated struct MeshWarpLocalVolume: Equatable, Sendable {
    var mode: MeshWarpLocalVolumeMode = .horizontal
    /// Strength in approximately −1…1 (UI may map 0…100% with sign).
    var strength: Float = 0
    var strengthVertical: Float = 0

    static let identity = MeshWarpLocalVolume(strength: 0)

    func desiredPixel(from pixel: SIMD2<Float>, pivot: SIMD2<Float>,
                      halfExtent: SIMD2<Float>) -> SIMD2<Float>? {
        let hx = max(halfExtent.x, 1)
        let hy = max(halfExtent.y, 1)
        let nx = (pixel.x - pivot.x) / hx
        let ny = (pixel.y - pivot.y) / hy
        let sh = max(-1, min(1, strength))
        let sv = max(-1, min(1, strengthVertical == 0 && mode == .combined ? strength : strengthVertical))
        var out = pixel
        switch mode {
        case .horizontal:
            // Anamorphosis-style: horizontal scale varies with ny².
            out.x = pivot.x + (pixel.x - pivot.x) * (1 + sh * ny * ny)
        case .vertical:
            out.y = pivot.y + (pixel.y - pivot.y) * (1 + sh * nx * nx)
        case .radial:
            let r2 = nx * nx + ny * ny
            let scale = 1 + sh * r2
            out = pivot + (pixel - pivot) * scale
        case .combined:
            out.x = pivot.x + (pixel.x - pivot.x) * (1 + sh * ny * ny)
            out.y = pivot.y + (pixel.y - pivot.y) * (1 + sv * nx * nx)
        }
        guard out.x.isFinite, out.y.isFinite else { return nil }
        // Safety: limit excursion relative to region size.
        let maxTravel = max(hx, hy) * 2
        if abs(out.x - pixel.x) > maxTravel || abs(out.y - pixel.y) > maxTravel {
            return nil
        }
        return out
    }
}

// MARK: - Unified local transform

nonisolated enum MeshWarpLocalCorrection: Equatable, Sendable {
    case perspective(MeshWarpLocalPerspective)
    case horizon(MeshWarpLocalHorizon)
    case volume(MeshWarpLocalVolume)
    case identity
}

extension MeshWarpGrid {
    /// Capture → resolve → desired → propagate → sticky → validate → install.
    @discardableResult
    mutating func applyLocalCorrection(_ correction: MeshWarpLocalCorrection,
                                       region: MeshWarpCorrectionRegion,
                                       imageWidth: Int, imageHeight: Int,
                                       base: [SIMD2<Float>]? = nil) -> MeshWarpLocalStatus {
        let snapshot = base ?? positions
        guard snapshot.count == positions.count else {
            return .rejected("mesh snapshot size mismatch")
        }
        // Exact identity corrections leave the mesh untouched (no float churn via write-back).
        switch correction {
        case .identity:
            return .success
        case .perspective(let p) where abs(p.amount) <= 1e-9:
            return .success
        case .horizon(let h) where abs(h.amount) <= 1e-9:
            return .success
        case .volume(let v) where abs(v.strength) <= 1e-9 && abs(v.strengthVertical) <= 1e-9:
            return .success
        default:
            break
        }
        let components = region.connectedComponents(in: self)
        guard !components.isEmpty else { return .rejected("empty selection region") }

        var trial = snapshot
        let extent = Self.extentPixels(width: imageWidth, height: imageHeight)
        let prop = propagation
        var primaryMoved = Set<Int>()

        for component in components {
            guard let pivotUV = region.pivotUV(in: snapshot, indices: component),
                  let bbox = region.boundingUV(in: snapshot, indices: component)
            else { return .rejected("region pivot undefined") }

            let pivotPx = Self.pixel(fromUV: pivotUV, width: imageWidth, height: imageHeight)
            let minPx = Self.pixel(fromUV: bbox.min, width: imageWidth, height: imageHeight)
            let maxPx = Self.pixel(fromUV: bbox.max, width: imageWidth, height: imageHeight)
            let half = SIMD2(max((maxPx.x - minPx.x) * 0.5, 1), max((maxPx.y - minPx.y) * 0.5, 1))

            for index in component {
                let baseUV = snapshot[index]
                let basePx = Self.pixel(fromUV: baseUV, width: imageWidth, height: imageHeight)
                guard let desiredPx = Self.desiredPixel(correction: correction, pixel: basePx,
                                                        pivot: pivotPx, halfExtent: half)
                else { return .rejected("degenerate or unsafe local transform") }
                let desiredUV = Self.uv(fromPixel: desiredPx, width: imageWidth, height: imageHeight)
                if let constrained = constrainSticky(index: index, proposed: desiredUV) {
                    trial[index] = constrained
                } else {
                    trial[index] = baseUV
                }
                primaryMoved.insert(index)
            }
        }

        // Propagation for unselected vertices (distance to nearest selected seed).
        if prop > 1e-9 {
            for other in positions.indices where !primaryMoved.contains(other) {
                var nearest = Float.greatestFiniteMagnitude
                var nearestSeed = primaryMoved.first!
                for seed in primaryMoved {
                    let d = Self.pixelDistance(rest[other], rest[seed],
                                               width: imageWidth, height: imageHeight)
                    if d < nearest {
                        nearest = d
                        nearestSeed = seed
                    }
                }
                let weight = Self.propagationWeight(distancePixels: nearest, propagation: prop,
                                                    extentPixels: extent)
                if weight <= 1e-9 { continue }
                let delta = trial[nearestSeed] - snapshot[nearestSeed]
                // Prefer mapping through the same correction at this vertex when weight→1.
                let baseUV = snapshot[other]
                let basePx = Self.pixel(fromUV: baseUV, width: imageWidth, height: imageHeight)
                let pivotUV = region.pivotUV(in: snapshot, indices: primaryMoved) ?? baseUV
                let pivotPx = Self.pixel(fromUV: pivotUV, width: imageWidth, height: imageHeight)
                let bbox = region.boundingUV(in: snapshot, indices: primaryMoved)
                let half: SIMD2<Float>
                if let bbox {
                    let minPx = Self.pixel(fromUV: bbox.min, width: imageWidth, height: imageHeight)
                    let maxPx = Self.pixel(fromUV: bbox.max, width: imageWidth, height: imageHeight)
                    half = SIMD2(max((maxPx.x - minPx.x) * 0.5, 1), max((maxPx.y - minPx.y) * 0.5, 1))
                } else {
                    half = SIMD2(extent * 0.5, extent * 0.5)
                }
                let fully: SIMD2<Float>
                if let desiredPx = Self.desiredPixel(correction: correction, pixel: basePx,
                                                     pivot: pivotPx, halfExtent: half) {
                    fully = Self.uv(fromPixel: desiredPx, width: imageWidth, height: imageHeight)
                } else {
                    fully = baseUV + delta
                }
                let proposed = baseUV + (fully - baseUV) * weight
                if let constrained = constrainSticky(index: other, proposed: proposed) {
                    trial[other] = constrained
                }
            }
        }

        guard trial.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return .rejected("non-finite vertex result")
        }
        var trialTopology = topology
        trialTopology.writeBack(positions: trial)
        guard Self.leafTrianglesValid(trialTopology) else {
            return .rejected("correction would fold the mesh")
        }
        positions = trial
        topology = trialTopology
        return .success
    }

    private static func desiredPixel(correction: MeshWarpLocalCorrection, pixel: SIMD2<Float>,
                                     pivot: SIMD2<Float>, halfExtent: SIMD2<Float>) -> SIMD2<Float>? {
        switch correction {
        case .identity:
            return pixel
        case .perspective(let p):
            return p.desiredPixel(from: pixel, pivot: pivot, halfExtent: halfExtent)
        case .horizon(let h):
            return h.desiredPixel(from: pixel, pivot: pivot)
        case .volume(let v):
            return v.desiredPixel(from: pixel, pivot: pivot, halfExtent: halfExtent)
        }
    }
}
