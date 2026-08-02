import SceneKit
import CoreGraphics
import SeismicCore
import SeismicGeo

/// Storeys as lofted solids rather than stacked prisms.
///
/// `SCNShape` extrudes one cross-section along a straight line, so every storey
/// came out a prism of constant plan. Stack prisms whose plans differ and you
/// get a ziggurat: an eight-storey barrel rendered as a wedding cake, and a
/// tapered tower as a staircase. That is not a small cosmetic complaint. The
/// whole point of a curved massing is that the surface is continuous, and a
/// stepped approximation of it says the opposite — it says the plan changes
/// abruptly at every floor, which is the signature of the one profile (a
/// setback) that genuinely does concentrate demand.
///
/// A loft interpolates the plan between the bottom of the storey and its top,
/// so the faces are slanted and the building's surface closes up. Two other
/// things follow from building the mesh here rather than handing a path to
/// SceneKit:
///
/// - **Curved walls get smooth normals.** A round tower is a many-sided
///   polygon, and shaded per-face it reads as a faceted drum however finely it
///   is tessellated. Averaging the normals across the vertices that
///   `OutlineCurvature` identified as belonging to a curve makes it read as
///   round, while corners stay sharp because their normals are not averaged.
/// - **The caps are triangulated properly**, by ear clipping, so a U-shaped
///   plan with a courtyard does not get a lid across its courtyard.
enum Loft {

    // MARK: Densifying

    /// The plan as a dense ring of points, and which of them lie on a curve.
    ///
    /// `OutlineCurvature` decides which runs of the outline were meant to be
    /// curves and hands them back as cubic Béziers. Those are flattened here at
    /// a fixed subdivision, because the mesh needs points; the flag travels
    /// with each point so the shading can tell a curve from a corner later.
    static func densified(_ ring: [Coordinate2D],
                          segmentsPerCurve: Int = 6) -> (points: [Coordinate2D],
                                                         curved: [Bool]) {
        guard let drawn = OutlineCurvature.path(for: ring) else { return ([], []) }
        var points: [Coordinate2D] = [drawn.start]
        var curved: [Bool] = [false]

        for segment in drawn.segments {
            switch segment {
            case .line(let to):
                points.append(to)
                curved.append(false)

            case .curve(let to, let c1, let c2):
                let from = points[points.count - 1]
                // The start of a curved run is on the curve too, so it is
                // re-flagged here — otherwise the first vertex of every arc
                // would shade as a corner and leave a visible crease.
                curved[curved.count - 1] = true
                for step in 1...segmentsPerCurve {
                    let t = Double(step) / Double(segmentsPerCurve)
                    points.append(cubic(from, c1, c2, to, t))
                    curved.append(true)
                }
            }
        }

        // The path closes back onto its start, so the final point is the first
        // one again and would produce a zero-length edge.
        if points.count > 1, let first = points.first, let last = points.last,
           abs(first.x - last.x) < 1e-7, abs(first.y - last.y) < 1e-7 {
            points.removeLast()
            let wasCurved = curved.removeLast()
            curved[0] = curved[0] || wasCurved
        }
        return (points, curved)
    }

    private static func cubic(_ p0: Coordinate2D, _ p1: Coordinate2D,
                              _ p2: Coordinate2D, _ p3: Coordinate2D,
                              _ t: Double) -> Coordinate2D {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return Coordinate2D(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                            y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    // MARK: The solid

    /// One storey: the ring at `bottomScale` swept up to the ring at
    /// `topScale`.
    ///
    /// Coordinates are the plan's own, centred by the caller. The solid is
    /// built with y up, so unlike `SCNShape` it needs no quarter-turn to stand
    /// the right way round.
    static func solid(ring incoming: [Coordinate2D], curved incomingCurved: [Bool],
                      bottomScale: Double, topScale: Double,
                      height: Double) -> SCNGeometry? {
        guard incoming.count >= 3, incomingCurved.count == incoming.count,
              height > 0 else { return nil }

        // Traced outlines arrive wound either way — OpenStreetMap does not
        // promise an orientation — and the generated plans are not consistent
        // with each other either. Every normal below is derived from the edge
        // direction, so the winding decides which way the walls face, and a
        // building lit from the inside reads as a black husk.
        let clockwise = Polygon.signedArea(incoming) < 0
        let ring = clockwise ? incoming.reversed().map { $0 } : incoming
        let curved = clockwise ? incomingCurved.reversed().map { $0 } : incomingCurved
        let n = ring.count

        let halfHeight = Float(height / 2)
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(n * 4 + 8)

        // MARK: Walls
        //
        // Each wall is its own pair of vertices rather than being shared with
        // its neighbours, so a corner can carry two different normals. Curved
        // runs then get theirs averaged afterwards, which is what makes the
        // difference between a drum and a faceted prism.
        for index in 0..<n {
            let next = (index + 1) % n
            let a = ring[index], b = ring[next]

            let bottomA = point(a, scale: bottomScale, y: -halfHeight)
            let bottomB = point(b, scale: bottomScale, y: -halfHeight)
            let topA = point(a, scale: topScale, y: halfHeight)
            let topB = point(b, scale: topScale, y: halfHeight)

            let base = UInt32(positions.count)
            positions.append(contentsOf: [bottomA, bottomB, topB, topA])

            // The outward face normal, from two edges of the quad. A lofted
            // wall is slanted, so this is not simply the plan's normal.
            //
            // `up × along`, in that order, and worth checking against a case
            // you can do in your head: for a plan wound anticlockwise the first
            // wall of a square runs along +x at z = -1, the interior is at
            // z > -1, so the outward normal must be -z. `up × along` gives
            // that; `along × up` gives its opposite and lights the building
            // from the inside.
            let along = SCNVector3(bottomB.x - bottomA.x, 0, bottomB.z - bottomA.z)
            let up = SCNVector3(topA.x - bottomA.x, topA.y - bottomA.y, topA.z - bottomA.z)
            let face = normalise(cross(up, along))
            normals.append(contentsOf: [face, face, face, face])

            // Wound so the triangles are front-facing seen from outside.
            //
            // The plan's y becomes the world's z, which flips handedness — so a
            // ring that is anticlockwise in plan is clockwise seen from above
            // in the scene, and the naive vertex order puts every wall's front
            // face on the inside. That is invisible while the material is
            // double-sided and a hole in the building the moment it is not.
            indices.append(contentsOf: [base, base + 2, base + 1,
                                        base, base + 3, base + 2])
        }

        smoothCurvedWalls(&normals, curved: curved, count: n)

        // MARK: Caps
        //
        // Ear clipping rather than a fan from the centroid, because the
        // centroid of a U-shaped plan lands in its courtyard and a fan from
        // there roofs the courtyard over.
        let fan = triangulate(ring)

        if !fan.isEmpty {
            let topBase = UInt32(positions.count)
            for corner in ring {
                positions.append(point(corner, scale: topScale, y: halfHeight))
                normals.append(SCNVector3(0, 1, 0))
            }
            // Reversed for the same handedness reason as the walls: the ear
            // clipper works in plan, where anticlockwise is the convention, and
            // that reads clockwise once plan y has become world z.
            for triangle in stride(from: 0, to: fan.count, by: 3) {
                let a: UInt32 = topBase + fan[triangle]
                let b: UInt32 = topBase + fan[triangle + 1]
                let c: UInt32 = topBase + fan[triangle + 2]
                indices.append(contentsOf: [c, b, a])
            }

            let bottomBase = UInt32(positions.count)
            for corner in ring {
                positions.append(point(corner, scale: bottomScale, y: -halfHeight))
                normals.append(SCNVector3(0, -1, 0))
            }
            // Wound the other way from the lid, so the underside faces down.
            for triangle in stride(from: 0, to: fan.count, by: 3) {
                let a: UInt32 = bottomBase + fan[triangle]
                let b: UInt32 = bottomBase + fan[triangle + 1]
                let c: UInt32 = bottomBase + fan[triangle + 2]
                indices.append(contentsOf: [a, b, c])
            }
        }

        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: positions),
                      SCNGeometrySource(normals: normals)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        return geometry
    }

    private static func point(_ plan: Coordinate2D, scale: Double, y: Float) -> SCNVector3 {
        // The plan's y is a ground-plane axis, so it becomes z; y is up.
        SCNVector3(Float(plan.x * scale), y, Float(plan.y * scale))
    }

    /// Averages wall normals across runs that belong to a curve.
    ///
    /// Corners are left alone. That asymmetry is the entire trick: shading a
    /// building with everything smoothed rounds off its corners, and shading it
    /// with nothing smoothed facets its curves.
    private static func smoothCurvedWalls(_ normals: inout [SCNVector3],
                                          curved: [Bool], count n: Int) {
        guard n >= 3 else { return }
        // Wall `i` runs from vertex i to vertex i+1, and contributed four
        // normals at offset 4i: [bottomA, bottomB, topB, topA] — so A belongs
        // to vertex i and B to vertex i+1.
        for vertex in 0..<n where curved[vertex] {
            let incoming = (vertex + n - 1) % n     // the wall arriving at this vertex
            let outgoing = vertex                   // the wall leaving it

            let blended = normalise(SCNVector3(
                normals[incoming * 4].x + normals[outgoing * 4].x,
                normals[incoming * 4].y + normals[outgoing * 4].y,
                normals[incoming * 4].z + normals[outgoing * 4].z))

            // B of the incoming wall and A of the outgoing wall are the same
            // point in space; both get the blend.
            normals[incoming * 4 + 1] = blended      // bottom B
            normals[incoming * 4 + 2] = blended      // top B
            normals[outgoing * 4] = blended          // bottom A
            normals[outgoing * 4 + 3] = blended      // top A
        }
    }

    // MARK: Triangulation

    /// Triangle indices for the caps.
    ///
    /// The ear clipper itself lives in `SeismicGeo`, where it can be tested
    /// against the plans that actually break a naive fan — a U with a
    /// courtyard, an L, a cruciform.
    static func triangulate(_ ring: [Coordinate2D]) -> [UInt32] {
        Polygon.triangulate(ring).map(UInt32.init)
    }

    // MARK: Vector helpers

    private static func cross(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
        SCNVector3(a.y * b.z - a.z * b.y,
                   a.z * b.x - a.x * b.z,
                   a.x * b.y - a.y * b.x)
    }

    private static func normalise(_ v: SCNVector3) -> SCNVector3 {
        let length = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        guard length > 1e-9 else { return SCNVector3(0, 1, 0) }
        return SCNVector3(v.x / length, v.y / length, v.z / length)
    }
}
