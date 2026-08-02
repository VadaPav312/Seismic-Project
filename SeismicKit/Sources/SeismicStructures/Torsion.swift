import Foundation
import SeismicCore

/// How a floor actually moves.
///
/// The solver answers one question — how far does each floor travel along the
/// direction of shaking — and for a symmetric building that is the whole
/// answer. Real buildings are not symmetric, and the difference is not a
/// detail: a floor plate is a rigid diaphragm, so when the resultant of the
/// storey shear does not pass through the centre of the bracing, the floor
/// rotates. The corners then travel further than the centre, and it is the
/// corners that get torn off.
///
/// Two things follow from an irregular plan, and both are missing from a
/// single number per floor:
///
/// 1. **Twist.** Storey shear `V` acting at an eccentricity `e` from the
///    stiffness centre applies a torque `V·e`. Dividing through by the lateral
///    stiffness, the rotation is `θ = u·e/r²`, where `u` is the translation the
///    solver reported and `r` is the torsional radius. No new solve is needed —
///    the rotation is fixed by the same shear that produced the translation.
///
/// 2. **Motion across the shaking.** A plan whose stiff and weak directions are
///    rotated away from the axis of shaking does not move along that axis. Push
///    such a building north and it goes north-east, because the two principal
///    directions have different compliances and the response is their sum.
///
/// Neither is exotic; both are what building codes require an engineer to check
/// for, which is a fair indication of how much they matter.
public struct TorsionModel: Sendable, Equatable {

    /// Offset between where the mass is and where the stiffness is, metres.
    public var staticEccentricity: Double

    /// The allowance every code requires on top of the calculated offset, metres.
    ///
    /// Real buildings are never as symmetric as their drawings: the mass moves
    /// with the occupants and the furniture, and the stiffness moves with
    /// cracking. Codes handle this by requiring an additional 5% of the plan
    /// dimension whether or not any eccentricity was calculated — which is why
    /// even a perfectly symmetric building here twists a little. That is not a
    /// modelling artefact; it is the honest answer.
    public var accidentalEccentricity: Double

    /// Torsional radius of the plan, metres. The lever arm twisting works
    /// through, and the reason a compact plan twists more readily than a long
    /// one of the same area.
    public var torsionalRadius: Double

    /// Distance from the plan's centroid to its furthest corner, metres. What
    /// the rotation gets multiplied by to give the extra travel at the worst
    /// point in the building.
    public var cornerRadius: Double

    /// Half the plan's larger overall dimension, metres.
    ///
    /// The distance the *code* check is made across, which is not the same as
    /// the distance to the corner. Torsional irregularity compares the two ends
    /// of an edge, so it works through the half-width; the corner sits further
    /// out, on the diagonal, and genuinely does travel further than either end
    /// of that edge. Using the corner distance for the code check would flag a
    /// plain square as irregular purely on the accidental allowance every
    /// building is given, which is exactly the sort of false alarm that teaches
    /// people to ignore the real ones.
    public var halfPlanDimension: Double

    /// Displacement across the shaking per unit displacement along it.
    ///
    /// Zero when the plan's principal axes line up with the shaking, or when it
    /// is directionally symmetric and has no preferred axes at all.
    public var crossAxisRatio: Double

    public init(staticEccentricity: Double, accidentalEccentricity: Double,
                torsionalRadius: Double, cornerRadius: Double,
                halfPlanDimension: Double, crossAxisRatio: Double) {
        self.staticEccentricity = max(staticEccentricity, 0)
        self.accidentalEccentricity = max(accidentalEccentricity, 0)
        self.torsionalRadius = max(torsionalRadius, 0)
        self.cornerRadius = max(cornerRadius, 0)
        self.halfPlanDimension = max(halfPlanDimension, 0)
        self.crossAxisRatio = crossAxisRatio
    }

    /// Nothing twists and nothing moves sideways. What a building with no
    /// usable outline gets, rather than an invented asymmetry.
    public static let none = TorsionModel(staticEccentricity: 0, accidentalEccentricity: 0,
                                          torsionalRadius: 1, cornerRadius: 0,
                                          halfPlanDimension: 0, crossAxisRatio: 0)

    /// Total eccentricity used for the twist.
    public var designEccentricity: Double { staticEccentricity + accidentalEccentricity }

    /// Rotation of a floor that has translated `displacement` metres, radians.
    public func rotation(forDisplacement displacement: Double) -> Double {
        guard torsionalRadius > 1e-6 else { return 0 }
        return displacement * designEccentricity / (torsionalRadius * torsionalRadius)
    }

    /// The full motion of one floor, from the one number the solver gives.
    public func motion(forDisplacement displacement: Double) -> FloorMotion {
        FloorMotion(along: displacement,
                    across: displacement * crossAxisRatio,
                    rotation: rotation(forDisplacement: displacement))
    }

    /// How much further the worst corner travels than the centre, as a
    /// fraction of the centre's travel.
    ///
    /// This is the number worth putting on screen: 0.3 means the corner of the
    /// building moves 30% further than the middle of it does, every cycle, for
    /// the whole earthquake. Codes call anything above about 0.2 a torsional
    /// irregularity and require the building to be designed for it explicitly.
    public var cornerAmplification: Double {
        guard torsionalRadius > 1e-6 else { return 0 }
        return designEccentricity * cornerRadius / (torsionalRadius * torsionalRadius)
    }

    /// The same ratio taken across an edge rather than out to the corner, which
    /// is the quantity the codes define their limit on.
    public var edgeAmplification: Double {
        guard torsionalRadius > 1e-6 else { return 0 }
        return designEccentricity * halfPlanDimension / (torsionalRadius * torsionalRadius)
    }

    /// The threshold codes draw: the worse end of a floor travelling more than
    /// 20% further than its average. Above it, twisting governs the design.
    public var isTorsionallyIrregular: Bool { edgeAmplification > 0.2 }
}

/// One floor's motion in the horizontal plane.
public struct FloorMotion: Sendable, Equatable {
    /// Along the direction of shaking, metres.
    public var along: Double
    /// Perpendicular to it, metres.
    public var across: Double
    /// Rotation about the vertical, radians.
    public var rotation: Double

    public init(along: Double, across: Double, rotation: Double) {
        self.along = along
        self.across = across
        self.rotation = rotation
    }
}

// MARK: - Deriving it from a building

public extension TorsionModel {

    /// Works the model out from the building's real plan.
    ///
    /// Everything here comes from geometry that is already known, which is the
    /// point: no new input is asked of the user, and a building imported with a
    /// traced outline gets a torsional response derived from its actual shape
    /// rather than from an assumption about it.
    static func of(_ building: BuildingModel) -> TorsionModel {
        let ring = building.footprint.count >= 3
            ? building.footprint
            : BuildingModel.rectangularFootprint(area: building.footprintArea)
        let section = SectionProperties.of(ring)
        guard section.area > 1e-6, section.radiusOfGyration > 1e-6 else { return .none }

        let radius = section.radiusOfGyration

        // Where the plan's mass sits, against where its stiffness sits.
        //
        // The mass is spread over the floor area, so its centre is the area
        // centroid. The lateral system lives in the walls, so its centre is the
        // centroid of the *perimeter* — each edge weighted by its length. The
        // gap between the two is the eccentricity, taken from the shape with
        // nothing assumed about the structure.
        //
        // The obvious cheaper proxy — the centre of the bounding box — is
        // wrong, and wrong in a way that is easy to miss. It gives zero for a
        // rectangle and a circle, which is right, and then reports an
        // equilateral triangle as massively eccentric, because a triangle's
        // centroid sits a third of the way up while its bounding box is centred
        // half way. A triangle has three axes of symmetry and cannot twist
        // under a force through its centre. The Tokyo Skytree was being flagged
        // as travelling 135% further at the corners than at the centre, on a
        // plan that is perfectly symmetric.
        var minX = Double.greatestFiniteMagnitude, maxX = -Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for point in ring {
            minX = Swift.min(minX, point.x); maxX = Swift.max(maxX, point.x)
            minY = Swift.min(minY, point.y); maxY = Swift.max(maxY, point.y)
        }

        let stiffness = perimeterCentroid(ring) ?? (x: section.centroidX, y: section.centroidY)
        let geometric = ((section.centroidX - stiffness.x) * (section.centroidX - stiffness.x)
                         + (section.centroidY - stiffness.y) * (section.centroidY - stiffness.y))
            .squareRoot()

        // What the structural system adds on top of the shape. A soft storey
        // is the worst case by a distance, because the one flexible level does
        // all of the deforming and any asymmetry in it governs the whole
        // building.
        let structural: Double = switch building.system {
        case .softStorey: radius * 0.15
        // Walls are placed where the plan allows rather than where symmetry
        // would want them — a stair core at one end, a party wall down one
        // side — so a wall system carries more inherent eccentricity than a
        // frame spread evenly round the perimeter.
        case .shearWall, .bearingWall: radius * 0.06
        default: section.directionalRatio > 3 ? radius * 0.08 : 0
        }

        // Independent sources, so they combine in quadrature rather than
        // simply adding — adding them would double-count the same asymmetry
        // when a plan is both irregular and softly braced.
        let staticE = (geometric * geometric + structural * structural).squareRoot()

        let cornerRadius = ring.map { point in
            ((point.x - section.centroidX) * (point.x - section.centroidX)
             + (point.y - section.centroidY) * (point.y - section.centroidY)).squareRoot()
        }.max() ?? radius

        let planDimension = Swift.max(maxX - minX, maxY - minY)

        return TorsionModel(
            staticEccentricity: staticE,
            accidentalEccentricity: planDimension * 0.05,
            torsionalRadius: radius,
            cornerRadius: cornerRadius,
            halfPlanDimension: planDimension / 2,
            crossAxisRatio: crossAxisRatio(for: section))
    }

    /// Centroid of the outline itself, each edge weighted by its length.
    ///
    /// Stands in for the centre of rigidity. A building's lateral system is in
    /// its walls, so where the walls are is where the stiffness is — and a plan
    /// with more of its perimeter down one side is braced more heavily down
    /// that side.
    ///
    /// It agrees with the area centroid for every plan with two axes of
    /// symmetry, and for the ones with three — which is the case the bounding
    /// box got wrong.
    static func perimeterCentroid(_ ring: [Coordinate2D]) -> (x: Double, y: Double)? {
        guard ring.count >= 3 else { return nil }
        var length = 0.0, x = 0.0, y = 0.0
        for index in ring.indices {
            let a = ring[index], b = ring[(index + 1) % ring.count]
            let edge = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
            guard edge > 1e-9 else { continue }
            length += edge
            x += (a.x + b.x) / 2 * edge
            y += (a.y + b.y) / 2 * edge
        }
        guard length > 1e-9 else { return nil }
        return (x / length, y / length)
    }

    /// Sideways drift per unit forward drift, for an orthotropic plan.
    ///
    /// Treat the plan as two independent springs along its principal axes, one
    /// `d` times more compliant than the other. Resolve a unit push along the
    /// building's own x axis into those directions, let each deflect by its own
    /// compliance, and resolve the result back. The cross term survives only
    /// when the principal axes are skewed *and* the two stiffnesses differ,
    /// which is exactly when a real building crabs sideways.
    static func crossAxisRatio(for section: SectionProperties) -> Double {
        let d = Swift.min(Swift.max(section.directionalRatio, 1), 12)
        guard d > 1.0001 else { return 0 }
        let angle = section.principalAngle
        let c = cos(angle), s = sin(angle)
        let along = c * c + d * s * s
        guard along > 1e-9 else { return 0 }
        return (d - 1) * s * c / along
    }
}
