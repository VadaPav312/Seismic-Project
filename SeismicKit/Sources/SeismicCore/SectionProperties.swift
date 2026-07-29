import Foundation

/// The real cross-section of a building's plan.
///
/// Everything here comes from the traced outline by exact integration — Green's
/// theorem over the polygon boundary — rather than from a bounding box or an
/// assumed rectangle. That matters because these are the quantities that decide
/// how a building actually behaves:
///
/// - The **second moments** set the stiffness in each direction. A slab four
///   times longer than it is deep is roughly sixteen times stiffer along its
///   length, so it has two quite different periods, and an earthquake arriving
///   along one axis is a different event from the same earthquake arriving
///   along the other.
/// - The **principal axes** say which directions those are. For an L-shaped or
///   triangular plan they are not the compass directions, and assuming they are
///   is how a model misses the direction a building is weakest in.
/// - The **polar moment** sets torsional stiffness.
/// - The **centroid** is where the mass acts. When it does not coincide with
///   where the stiffness acts, the building twists as well as sways — and
///   torsion is what tears corners off buildings.
///
/// A curved plan is handled the same way as a straight one: the outline arrives
/// as a dense polygon, and the integration is exact for whatever polygon it is
/// given. There is no special case for curves and none is needed.
public struct SectionProperties: Sendable, Equatable, Codable {

    /// Enclosed area, m².
    public var area: Double

    /// Centroid, in the same local metres as the outline.
    public var centroidX: Double
    public var centroidY: Double

    /// Second moments of area about the centroid, m⁴.
    public var ixx: Double
    public var iyy: Double
    /// The product of inertia. Non-zero means the plan is not symmetric about
    /// the axes it was given, and the principal directions are rotated.
    public var ixy: Double

    /// Angle from the x axis to the stiffer principal axis, radians.
    public var principalAngle: Double
    /// Second moments about the principal axes, largest first.
    public var iMajor: Double
    public var iMinor: Double

    /// Polar moment of area about the centroid: ixx + iyy. Sets torsion.
    public var polarMoment: Double { ixx + iyy }

    /// Radius of gyration of the plan about its centroid, m.
    ///
    /// This is the lever arm torsion works through. A compact plan resists
    /// twisting with a short arm; a long thin one has to fight it much harder,
    /// which is why slender slabs are torsionally sensitive.
    public var radiusOfGyration: Double {
        area > 0 ? (polarMoment / area).squareRoot() : 0
    }

    /// How far from square the plan is, as a ratio of principal stiffnesses.
    ///
    /// 1 is torsionally and directionally symmetric. Large values mean the two
    /// directions behave very differently.
    public var directionalRatio: Double {
        iMinor > 1e-12 ? iMajor / iMinor : 1
    }

    // MARK: Computation

    /// Exact properties of a closed polygon, by Green's theorem.
    ///
    /// The standard shoelace formulae, extended to the second moments. Signed
    /// area is used throughout and the result taken absolute at the end, so a
    /// ring wound clockwise gives the same answer as one wound anticlockwise —
    /// which matters because traced outlines arrive in both.
    public static func of(_ ring: [Coordinate2D]) -> SectionProperties {
        var points = ring
        // Drop a repeated closing vertex; it contributes a zero-length edge and
        // nothing else.
        if let first = points.first, let last = points.last,
           abs(first.x - last.x) < 1e-12, abs(first.y - last.y) < 1e-12 {
            points.removeLast()
        }
        guard points.count >= 3 else { return .degenerate }

        var signedArea = 0.0
        var cx = 0.0
        var cy = 0.0
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            let cross = a.x * b.y - b.x * a.y
            signedArea += cross
            cx += (a.x + b.x) * cross
            cy += (a.y + b.y) * cross
        }
        signedArea /= 2
        guard abs(signedArea) > 1e-12 else { return .degenerate }

        cx /= (6 * signedArea)
        cy /= (6 * signedArea)

        // Second moments about the origin, then shifted to the centroid by the
        // parallel axis theorem. Computing about the centroid directly would
        // need the same work and one more pass.
        var ixxOrigin = 0.0
        var iyyOrigin = 0.0
        var ixyOrigin = 0.0
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            let cross = a.x * b.y - b.x * a.y

            ixxOrigin += (a.y * a.y + a.y * b.y + b.y * b.y) * cross
            iyyOrigin += (a.x * a.x + a.x * b.x + b.x * b.x) * cross
            ixyOrigin += (a.x * b.y + 2 * a.x * a.y + 2 * b.x * b.y + b.x * a.y) * cross
        }
        ixxOrigin /= 12
        iyyOrigin /= 12
        ixyOrigin /= 24

        let area = abs(signedArea)
        // Parallel axis, and the sign of the enclosed area cancels out here.
        var ixx = abs(ixxOrigin) - area * cy * cy
        var iyy = abs(iyyOrigin) - area * cx * cx
        var ixy = (signedArea < 0 ? -ixyOrigin : ixyOrigin) - area * cx * cy

        // Numerical noise can push a near-zero moment slightly negative on a
        // very thin plan; a negative second moment is not a physical quantity.
        ixx = Swift.max(ixx, 0)
        iyy = Swift.max(iyy, 0)
        if abs(ixy) < 1e-9 * Swift.max(ixx, iyy) { ixy = 0 }

        // Principal axes: the rotation that makes the product of inertia zero.
        let average = (ixx + iyy) / 2
        let difference = (ixx - iyy) / 2
        let radius = (difference * difference + ixy * ixy).squareRoot()
        let iMajor = average + radius
        let iMinor = Swift.max(average - radius, 0)
        // atan2 of twice the angle, halved — the standard Mohr's circle result.
        let angle = abs(ixy) < 1e-12 && abs(difference) < 1e-12
            ? 0
            : 0.5 * atan2(2 * ixy, ixx - iyy)

        return SectionProperties(
            area: area, centroidX: cx, centroidY: cy,
            ixx: ixx, iyy: iyy, ixy: ixy,
            principalAngle: angle, iMajor: iMajor, iMinor: iMinor)
    }

    /// What a degenerate outline returns: nothing, rather than a plausible lie.
    public static let degenerate = SectionProperties(
        area: 0, centroidX: 0, centroidY: 0,
        ixx: 0, iyy: 0, ixy: 0, principalAngle: 0, iMajor: 0, iMinor: 0)

    public init(area: Double, centroidX: Double, centroidY: Double,
                ixx: Double, iyy: Double, ixy: Double,
                principalAngle: Double, iMajor: Double, iMinor: Double) {
        self.area = area
        self.centroidX = centroidX
        self.centroidY = centroidY
        self.ixx = ixx
        self.iyy = iyy
        self.ixy = ixy
        self.principalAngle = principalAngle
        self.iMajor = iMajor
        self.iMinor = iMinor
    }
}

// MARK: - What it means

public extension SectionProperties {

    /// Plain-language reading of what this plan implies.
    var interpretation: String {
        guard area > 0 else { return "No usable outline." }

        var parts: [String] = []

        if directionalRatio > 2.5 {
            parts.append(String(
                format: "This plan is about %.1f times stiffer in one direction than the other, "
                    + "so it has two distinctly different periods. Which way an earthquake "
                    + "arrives from matters here.", directionalRatio))
        } else if directionalRatio < 1.15 {
            parts.append("The plan is close to symmetric, so it behaves much the same "
                         + "whichever direction the shaking arrives from.")
        }

        let degrees = principalAngle * 180 / .pi
        if abs(ixy) > 1e-6, abs(degrees) > 5, abs(abs(degrees) - 90) > 5 {
            parts.append(String(
                format: "Its stiff and weak directions are rotated about %.0f° from the "
                    + "building's own axes — a consequence of the plan's shape, and not "
                    + "something you would guess from a floor plan's outline.", abs(degrees)))
        }

        return parts.isEmpty
            ? "A regular plan with no strong directional preference."
            : parts.joined(separator: " ")
    }

    /// Distance between the mass centre and a given stiffness centre, as a
    /// fraction of the plan's own size.
    ///
    /// This is the number codes actually regulate. Above about 5% the torsional
    /// response stops being a correction and starts being the thing that
    /// governs — most codes require explicit torsional analysis past that, and
    /// treat 20% or more as an irregularity in its own right.
    func eccentricityRatio(stiffnessCentreX: Double, stiffnessCentreY: Double) -> Double {
        guard area > 0 else { return 0 }
        let dx = centroidX - stiffnessCentreX
        let dy = centroidY - stiffnessCentreY
        let distance = (dx * dx + dy * dy).squareRoot()
        // Normalised by the radius of gyration, which is the plan's own scale
        // for this purpose rather than its longest dimension.
        return radiusOfGyration > 1e-9 ? distance / radiusOfGyration : 0
    }
}
