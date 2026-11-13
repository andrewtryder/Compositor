import CoreGraphics
import Foundation
import simd

/// On-disk / history-safe ReShape mesh. Triangle buffers are never stored; leaf connectivity
/// is rebuilt from faces + edge midpoints on decode.
nonisolated struct MeshWarpPersistentState: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    /// Soft cap on encoded mesh JSON (manifest sibling file).
    static let maximumEncodedBytes = 4 * 1024 * 1024

    var schemaVersion: Int
    var imageWidth: Int
    var imageHeight: Int
    var pointColumns: Int
    var pointRows: Int
    var stickyBorders: Bool
    var propagation: Float
    var vertices: [Vertex]
    var faces: [Face]
    var rootFaceIDs: [Int]
    var edgeMidpoints: [EdgeMidpoint]
    var nextVertexID: Int
    var nextFaceID: Int

    nonisolated struct Vertex: Codable, Equatable, Sendable {
        var id: Int
        var restX: Float
        var restY: Float
        var positionX: Float
        var positionY: Float
    }

    nonisolated struct Face: Codable, Equatable, Sendable {
        var id: Int
        var corners: [Int]
        var parent: Int?
        var children: [Int]?
    }

    nonisolated struct EdgeMidpoint: Codable, Equatable, Sendable {
        var a: Int
        var b: Int
        var mid: Int
    }

    enum DecodeError: Error, Equatable, LocalizedError {
        case schema(Int)
        case malformed(String)
        case budget(String)
        case degenerate(String)

        var errorDescription: String? {
            switch self {
            case .schema(let v): return "Unsupported ReShape mesh schema version \(v)."
            case .malformed(let reason): return "ReShape mesh data is damaged (\(reason))."
            case .budget(let reason): return "ReShape mesh exceeds topology limits (\(reason))."
            case .degenerate(let reason): return "ReShape mesh is invalid (\(reason))."
            }
        }
    }

    init(mesh: MeshWarpGrid, imageWidth: Int, imageHeight: Int) {
        schemaVersion = Self.schemaVersion
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        pointColumns = mesh.pointColumns
        pointRows = mesh.pointRows
        stickyBorders = mesh.stickyBorders
        propagation = mesh.propagation
        let topology = mesh.topology
        vertices = topology.order.compactMap { id in
            guard let v = topology.vertices[id] else { return nil }
            return Vertex(id: id.rawValue, restX: v.rest.x, restY: v.rest.y,
                          positionX: v.position.x, positionY: v.position.y)
        }
        faces = topology.faces.values.sorted { $0.id.rawValue < $1.id.rawValue }.map { face in
            Face(id: face.id.rawValue,
                 corners: face.corners.map(\.rawValue),
                 parent: face.parent?.rawValue,
                 children: face.children?.map(\.rawValue))
        }
        rootFaceIDs = topology.rootFaceIDs.map(\.rawValue)
        edgeMidpoints = topology.edgeMidpoints.map { key, mid in
            EdgeMidpoint(a: key.a.rawValue, b: key.b.rawValue, mid: mid.rawValue)
        }.sorted {
            if $0.a != $1.a { return $0.a < $1.a }
            if $0.b != $1.b { return $0.b < $1.b }
            return $0.mid < $1.mid
        }
        nextVertexID = topology.nextVertexID
        nextFaceID = topology.nextFaceID
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedBytes else {
            throw DecodeError.budget("encoded size \(data.count)")
        }
        return data
    }

    static func decode(from data: Data) throws -> MeshWarpPersistentState {
        guard data.count <= maximumEncodedBytes else {
            throw DecodeError.budget("encoded size \(data.count)")
        }
        do {
            return try JSONDecoder().decode(MeshWarpPersistentState.self, from: data)
        } catch let error as DecodeError {
            throw error
        } catch {
            throw DecodeError.malformed("JSON")
        }
    }

    /// Rebuilds a live mesh. Rejects inconsistent topology; reconstructs leaf triangulation.
    func makeGrid() throws -> MeshWarpGrid {
        guard schemaVersion == Self.schemaVersion else { throw DecodeError.schema(schemaVersion) }
        guard (1...DocumentLimits.maxSide).contains(imageWidth),
              (1...DocumentLimits.maxSide).contains(imageHeight) else {
            throw DecodeError.budget("image \(imageWidth)×\(imageHeight)")
        }
        guard pointColumns >= 2, pointRows >= 2,
              pointColumns * pointRows <= MeshWarpGrid.maxPoints else {
            throw DecodeError.budget("lattice \(pointColumns)×\(pointRows)")
        }
        guard propagation.isFinite, (0...1).contains(propagation) else {
            throw DecodeError.malformed("propagation")
        }
        guard !vertices.isEmpty, vertices.count <= MeshWarpTopology.maxVertices,
              faces.count <= MeshWarpTopology.maxFaces,
              nextVertexID >= 0, nextFaceID >= 0,
              nextVertexID <= MeshWarpTopology.maxVertices * 2,
              nextFaceID <= MeshWarpTopology.maxFaces * 2 else {
            throw DecodeError.budget("vertex/face counts")
        }
        guard Set(vertices.map(\.id)).count == vertices.count else {
            throw DecodeError.malformed("duplicate vertex id")
        }
        guard Set(faces.map(\.id)).count == faces.count else {
            throw DecodeError.malformed("duplicate face id")
        }
        guard Set(rootFaceIDs).count == rootFaceIDs.count else {
            throw DecodeError.malformed("duplicate root face")
        }

        var vertexMap: [MeshWarpVertexID: MeshWarpVertex] = [:]
        var order: [MeshWarpVertexID] = []
        order.reserveCapacity(vertices.count)
        for record in vertices {
            guard record.id >= 0, record.id < nextVertexID else {
                throw DecodeError.malformed("vertex id \(record.id)")
            }
            let rest = SIMD2(record.restX, record.restY)
            let position = SIMD2(record.positionX, record.positionY)
            guard rest.x.isFinite, rest.y.isFinite, position.x.isFinite, position.y.isFinite,
                  rest.x >= -0.05, rest.x <= 1.05, rest.y >= -0.05, rest.y <= 1.05,
                  position.x >= -2, position.x <= 3, position.y >= -2, position.y <= 3 else {
                throw DecodeError.degenerate("non-finite or out-of-range UV")
            }
            let id = MeshWarpVertexID(record.id)
            vertexMap[id] = MeshWarpVertex(id: id, rest: rest, position: position)
            order.append(id)
        }

        let vertexIDs = Set(vertexMap.keys)
        var faceMap: [MeshWarpFaceID: MeshWarpFace] = [:]
        for record in faces {
            guard record.id >= 0, record.id < nextFaceID else {
                throw DecodeError.malformed("face id \(record.id)")
            }
            guard record.corners.count == 4,
                  Set(record.corners).count == 4,
                  record.corners.allSatisfy({ vertexIDs.contains(MeshWarpVertexID($0)) }) else {
                throw DecodeError.malformed("face corners \(record.id)")
            }
            if let children = record.children {
                guard children.count == 4, Set(children).count == 4 else {
                    throw DecodeError.malformed("face children \(record.id)")
                }
            }
            if let parent = record.parent {
                guard parent >= 0, parent < nextFaceID, parent != record.id else {
                    throw DecodeError.malformed("face parent \(record.id)")
                }
            }
            let id = MeshWarpFaceID(record.id)
            faceMap[id] = MeshWarpFace(
                id: id,
                corners: record.corners.map(MeshWarpVertexID.init),
                parent: record.parent.map(MeshWarpFaceID.init),
                children: record.children?.map(MeshWarpFaceID.init)
            )
        }

        let roots = rootFaceIDs.map(MeshWarpFaceID.init)
        guard roots.allSatisfy({ faceMap[$0] != nil }) else {
            throw DecodeError.malformed("missing root face")
        }
        for root in roots {
            guard faceMap[root]?.parent == nil else {
                throw DecodeError.malformed("rooted face has parent")
            }
        }

        for (id, face) in faceMap {
            if let parent = face.parent {
                guard let parentFace = faceMap[parent],
                      parentFace.children?.contains(id) == true else {
                    throw DecodeError.malformed("parent/child mismatch \(id.rawValue)")
                }
            }
            if let children = face.children {
                for child in children {
                    guard let childFace = faceMap[child], childFace.parent == id else {
                        throw DecodeError.malformed("child link \(id.rawValue)")
                    }
                }
                // Subdivision depth: walk ancestors.
                var depth = 0
                var current = face.parent
                while let p = current {
                    depth += 1
                    guard depth <= MeshWarpTopology.maxSubdivisionDepth else {
                        throw DecodeError.budget("subdivision depth")
                    }
                    current = faceMap[p]?.parent
                }
            }
        }

        var edgeMidpoints: [MeshWarpEdgeKey: MeshWarpVertexID] = [:]
        for record in self.edgeMidpoints {
            let a = MeshWarpVertexID(record.a)
            let b = MeshWarpVertexID(record.b)
            let mid = MeshWarpVertexID(record.mid)
            guard vertexIDs.contains(a), vertexIDs.contains(b), vertexIDs.contains(mid), a != b else {
                throw DecodeError.malformed("edge midpoint")
            }
            let key = MeshWarpEdgeKey(a, b)
            guard edgeMidpoints[key] == nil else {
                throw DecodeError.malformed("duplicate edge midpoint")
            }
            edgeMidpoints[key] = mid
        }

        let topology = MeshWarpTopology(
            vertices: vertexMap,
            order: order,
            faces: faceMap,
            rootFaceIDs: roots,
            edgeMidpoints: edgeMidpoints,
            nextVertexID: nextVertexID,
            nextFaceID: nextFaceID
        )

        let triangles = topology.triangles()
        guard triangles.count <= MeshWarpTopology.maxTriangles else {
            throw DecodeError.budget("triangles \(triangles.count)")
        }
        guard !triangles.isEmpty else {
            throw DecodeError.degenerate("no triangles")
        }
        for tri in triangles {
            let area = MeshWarpGrid.signedArea(tri.destination.0, tri.destination.1, tri.destination.2)
            guard abs(area) >= MeshWarpGrid.minimumTriangleArea else {
                throw DecodeError.degenerate("degenerate triangle")
            }
        }

        let arrays = topology.syncArrays()
        guard arrays.positions.count == order.count,
              arrays.positions.count == arrays.rest.count else {
            throw DecodeError.malformed("array sync")
        }

        return MeshWarpGrid(
            pointColumns: pointColumns,
            pointRows: pointRows,
            positions: arrays.positions,
            rest: arrays.rest,
            stickyBorders: stickyBorders,
            propagation: max(0, min(1, propagation)),
            topology: topology
        )
    }
}

/// Persistent editable ReShape attached to an image layer. `source` is the immutable unwarped
/// bitmap; the layer's `asset` holds the last rendered output for display/export.
nonisolated struct LayerReshape: Equatable, @unchecked Sendable {
    var mesh: MeshWarpGrid
    var source: ImportedImage
    var imageWidth: Int
    var imageHeight: Int

    init(mesh: MeshWarpGrid, source: ImportedImage) {
        self.mesh = mesh
        self.source = source
        self.imageWidth = source.image.width
        self.imageHeight = source.image.height
    }

    init?(persistent: MeshWarpPersistentState, source: ImportedImage) {
        guard source.image.width == persistent.imageWidth,
              source.image.height == persistent.imageHeight,
              source.deep == nil,
              source.image.bitsPerComponent <= 8,
              !DeepLayer.isHDR(source.image),
              let mesh = try? persistent.makeGrid() else { return nil }
        self.mesh = mesh
        self.source = source
        self.imageWidth = persistent.imageWidth
        self.imageHeight = persistent.imageHeight
    }

    var persistentState: MeshWarpPersistentState {
        MeshWarpPersistentState(mesh: mesh, imageWidth: imageWidth, imageHeight: imageHeight)
    }

    static func == (lhs: LayerReshape, rhs: LayerReshape) -> Bool {
        lhs.mesh == rhs.mesh
            && lhs.imageWidth == rhs.imageWidth
            && lhs.imageHeight == rhs.imageHeight
            && lhs.source.image === rhs.source.image
    }
}
