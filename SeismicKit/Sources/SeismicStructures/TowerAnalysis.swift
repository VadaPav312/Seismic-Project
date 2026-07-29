import Foundation
import SeismicCore

/// A building that bends as well as shears, in two directions, and twists.
///
/// The shear-building idealisation this supersedes assumes floors slide past one
/// another and the whole building deforms like a stack of shear panels. For an
/// eight-storey frame that is a good assumption. For a three-hundred-metre tower
/// it is simply wrong: a slender building deforms mostly by *bending*, like a
/// cantilever, and a pure shear model of one predicts a period that can be out
/// by a factor of two — in the unsafe direction, because it reports the building
/// as stiffer than it is.
///
/// Three things are modelled here that a shear building cannot express:
///
/// 1. **Bending.** A cantilever's lateral stiffness is assembled exactly from
///    beam elements and then condensed onto the floor translations, and
///    combined with shear stiffness *in series* — which is what "both
///    mechanisms act at once" means physically.
/// 2. **Two directions.** Stiffness comes from the real second moments of the
///    traced plan, so a slab four times longer than it is deep is about sixteen
///    times stiffer along its length and genuinely has two different periods.
/// 3. **Torsion.** When the mass centre and the stiffness centre do not
///    coincide, sway and twist are coupled, and the corners of the building
///    move further than the centre does. Torsion is what tears corners off
///    buildings, and a model with one degree of freedom per floor cannot see it
///    at all.
///
/// What this is not: a finite element model. The app never learns where a
/// building's actual columns and walls are, so it cannot pretend to. What it
/// can do rigorously is derive the section properties of the outline somebody
/// traced, and carry those through the mechanics honestly.
public enum TowerAnalysis {

    // MARK: Inputs

    public struct Tower: Sendable {
        /// Storey heights, base upwards, metres.
        public var storeyHeights: [Double]
        /// Lumped mass at each floor, kg.
        public var storeyMasses: [Double]
        /// Plan section at each floor, from the real outline.
        public var sections: [SectionProperties]
        /// Damping ratio.
        public var damping: Double
        /// How much of the plan's material actually resists lateral load.
        ///
        /// A floor plate is not a solid section of structural material — the
        /// resisting elements are the columns, walls and cores within it. This
        /// is the fraction of the gross plan's second moment that behaves
        /// structurally, and it is the one genuinely empirical number in this
        /// model.
        public var structuralEfficiency: Double

        /// How much of the gross plan's second moment is structurally effective.
        ///
        /// Kept separate from the shear efficiency because the two mechanisms
        /// are carried by different elements, and the ratio between them is
        /// what decides whether a building shears or bends.
        ///
        /// The direction of that ratio is worth stating, because the intuitive
        /// reading is backwards. A *moment frame* spreads its columns to the
        /// perimeter, so as a whole it has a large second moment — a large
        /// fraction of the gross plan's — and is therefore stiff in overall
        /// bending; what it is weak in is racking, storey against storey. It
        /// deforms in shear. A *central core* does the opposite: it concentrates
        /// all its material at the centroid, where it contributes almost
        /// nothing to the second moment of the gross plan, while being very
        /// stiff in shear. It deforms in bending, like a cantilever.
        ///
        /// So a shear-dominated building has a *high* flexural efficiency and a
        /// low shear one, and a bending-dominated building the reverse.
        public var flexuralEfficiency: Double
        /// Elastic modulus, Pa.
        public var elasticModulus: Double
        /// Shear modulus, Pa.
        public var shearModulus: Double
        /// Offset of the stiffness centre from the mass centre, metres.
        ///
        /// Non-zero for a building whose stiff elements sit off to one side —
        /// a core at one end, a shear wall along one face.
        public var eccentricityX: Double
        public var eccentricityY: Double

        /// Where the lateral elements sit, as a multiple of the plan's own
        /// radius of gyration. This is what decides torsional behaviour.
        ///
        /// Twisting is resisted by each element's stiffness acting through its
        /// distance from the centre of rotation — the sum of `k·d²`. So *where*
        /// the structure is matters more than how much of it there is. A
        /// building braced round its perimeter fights torsion with a long lever
        /// arm and twists reluctantly; one that hangs everything off a central
        /// core has almost no lever arm at all, and twists first.
        ///
        /// Above 1 the elements are further out than the mass is, and the
        /// torsional period is shorter than the sway period. Below 1 they are
        /// closer in, torsion is the softer mode, and the building's first
        /// response to an earthquake is to rotate — which is the condition that
        /// tears corners off buildings.
        public var torsionalLeverRatio: Double

        public init(storeyHeights: [Double], storeyMasses: [Double],
                    sections: [SectionProperties], damping: Double = 0.05,
                    structuralEfficiency: Double = 0.012,
                    flexuralEfficiency: Double = 0.0015,
                    elasticModulus: Double = 25e9, shearModulus: Double = 10e9,
                    eccentricityX: Double = 0, eccentricityY: Double = 0,
                    torsionalLeverRatio: Double = 1.0) {
            self.storeyHeights = storeyHeights
            self.storeyMasses = storeyMasses
            self.sections = sections
            self.damping = damping
            self.structuralEfficiency = structuralEfficiency
            self.flexuralEfficiency = flexuralEfficiency
            self.elasticModulus = elasticModulus
            self.shearModulus = shearModulus
            self.eccentricityX = eccentricityX
            self.eccentricityY = eccentricityY
            self.torsionalLeverRatio = torsionalLeverRatio
        }

        public var storeyCount: Int { Swift.min(storeyHeights.count, storeyMasses.count) }
        public var totalHeight: Double { storeyHeights.reduce(0, +) }
    }

    // MARK: Results

    public struct Result: Sendable {
        /// Fundamental period swaying along the plan's stiff axis, seconds.
        public var majorAxisPeriod: Double
        /// Fundamental period along the weak axis. Always the longer of the two.
        public var minorAxisPeriod: Double
        /// Fundamental period in torsion.
        public var torsionalPeriod: Double

        /// Mode shape of the fundamental sway mode, normalised to 1 at the roof.
        public var fundamentalShape: [Double]

        /// How much of the roof deflection comes from bending rather than shear.
        ///
        /// 0 is a pure shear building; 1 is a pure cantilever. The transition is
        /// what separates a mid-rise frame from a tower, and it is the single
        /// most useful number here for deciding whether the simpler model would
        /// have been adequate.
        public var flexuralFraction: Double

        /// Ratio of the torsional period to the longer sway period, measured
        /// *before* the two are coupled by eccentricity.
        ///
        /// Uncoupled deliberately. Coupling pushes the two modes apart — the
        /// sway mode softens and the torsional mode stiffens — so reading the
        /// ratio off the coupled periods makes an eccentric building look
        /// better than it is, which is precisely backwards. Codes check the
        /// uncoupled pair for the same reason.
        public var torsionalRatio: Double

        /// Ratio of the torsional period to the longer sway period.
        ///
        /// Below about 1.0 the building twists at least as readily as it sways,
        /// which most codes treat as a torsional irregularity — the first mode
        /// is then a twisting one, and the corners lead the motion.


        public var isTorsionallySensitive: Bool { torsionalRatio > 0.9 }
        public var isBendingDominated: Bool { flexuralFraction > 0.5 }
    }

    // MARK: The analysis

    public static func analyse(_ tower: Tower) -> Result {
        let n = tower.storeyCount
        guard n > 0 else {
            return Result(majorAxisPeriod: 0, minorAxisPeriod: 0, torsionalPeriod: 0,
                          fundamentalShape: [], flexuralFraction: 0, torsionalRatio: 1)
        }

        let masses = (0..<n).map { Swift.max(tower.storeyMasses[$0], 1) }

        // Effective second moments: the gross plan's, reduced to the fraction
        // that is actually structure.
        let efficiency = Swift.max(tower.structuralEfficiency, 1e-6)
        let flexural = Swift.max(tower.flexuralEfficiency, 1e-9)
        let iMajor = (0..<n).map { Swift.max(tower.sections[safe: $0]?.iMajor ?? 0, 1e-6) * flexural }
        let iMinor = (0..<n).map { Swift.max(tower.sections[safe: $0]?.iMinor ?? 0, 1e-6) * flexural }
        let areas = (0..<n).map { Swift.max(tower.sections[safe: $0]?.area ?? 1, 1e-3) * efficiency }

        let major = sway(tower, masses: masses, second: iMajor, shearAreas: areas)
        let minor = sway(tower, masses: masses, second: iMinor, shearAreas: areas)

        // Torsion, as the same cantilever problem in a rotational coordinate.
        //
        // Each floor's resistance to being spun is its mass times the square of
        // the plan's radius of gyration — that is where the mass is. Its
        // resistance to being twisted is its lateral stiffness times the square
        // of the lever arm the bracing actually has — that is where the
        // structure is. Both rigidities scale by the same lever arm squared, so
        // the shear-and-bending mix carries over intact and the torsional period
        // comes out as the sway period times r/ρ.
        //
        // A first attempt fed the plan's polar moment in as a shear *area*,
        // which is not the same quantity or even the same units, and reported
        // almost every building as torsionally sensitive.
        let radii = (0..<n).map { index -> Double in
            let r = tower.sections[safe: index]?.radiusOfGyration ?? 1
            return Swift.max(r, 0.5)
        }
        let lever = Swift.max(tower.torsionalLeverRatio, 0.2)
        let rotationalInertia = (0..<n).map { masses[$0] * radii[$0] * radii[$0] }
        // Torsion is resisted about both axes at once, so the bending term uses
        // the mean of the two principal moments — which for a symmetric plan is
        // exactly the value each sway direction saw.
        let torsionalSecond = (0..<n).map { index -> Double in
            let arm = radii[index] * lever
            let mean = Swift.max(tower.sections[safe: index]?.polarMoment ?? 2, 1e-6) / 2
            return mean * flexural * arm * arm
        }
        let torsionalShear = (0..<n).map { areas[$0] * radii[$0] * radii[$0] * lever * lever }
        let torsion = sway(tower, masses: rotationalInertia,
                           second: torsionalSecond, shearAreas: torsionalShear)

        // Eccentricity couples sway and twist, and the effect is to push the
        // two periods apart: one mode becomes more sway-like and softer, the
        // other more twist-like and stiffer. The classical two-degree coupling
        // result is used rather than a full 3n solve, because the coupling is
        // between the *fundamental* modes and modelling it there captures what
        // matters without tripling the problem size.
        let coupled = couple(swayPeriod: Swift.max(major.period, minor.period),
                             torsionalPeriod: torsion.period,
                             eccentricity: (tower.eccentricityX * tower.eccentricityX
                                            + tower.eccentricityY * tower.eccentricityY).squareRoot(),
                             radiusOfGyration: radii.first ?? 1)

        return Result(
            majorAxisPeriod: Swift.min(major.period, minor.period),
            minorAxisPeriod: coupled.sway,
            torsionalPeriod: coupled.torsional,
            fundamentalShape: minor.shape,
            flexuralFraction: minor.flexuralFraction,
            torsionalRatio: torsion.period / Swift.max(major.period, minor.period, 1e-9))
    }

    // MARK: One direction

    private struct Direction {
        var period: Double
        var shape: [Double]
        var flexuralFraction: Double
    }

    /// Solves one lateral direction as a coupled shear-flexure cantilever.
    private static func sway(_ tower: Tower, masses: [Double],
                             second: [Double], shearAreas: [Double]) -> Direction {
        let n = masses.count
        guard n > 0 else { return Direction(period: 0, shape: [], flexuralFraction: 0) }

        let flexural = flexuralFlexibility(tower, second: second)
        let shear = shearFlexibility(tower, shearAreas: shearAreas)

        // Series combination, done in flexibility.
        //
        // This is the crux. Two mechanisms acting at once add their
        // *flexibilities*, not their stiffnesses — a building deflects by the
        // amount it shears plus the amount it bends. Adding stiffnesses instead
        // would make the building stiffer than either mechanism alone, which is
        // backwards.
        var total = flexural
        for row in 0..<n {
            for column in 0..<n {
                total[row][column] += shear[row][column]
            }
        }

        // How much of the roof movement is bending, under a uniform load. This
        // is a description of the building, not a step in the solution.
        let unit = [Double](repeating: 1, count: n)
        let flexuralTip = dot(flexural[n - 1], unit)
        let shearTip = dot(shear[n - 1], unit)
        let fraction = (flexuralTip + shearTip) > 1e-30
            ? flexuralTip / (flexuralTip + shearTip)
            : 0

        // The generalised eigenproblem in flexibility form: the largest
        // eigenvalue of F·M is 1/ω², so the fundamental mode is the *dominant*
        // one and plain power iteration converges to it directly — no
        // factorisation and no inversion.
        var vector = [Double](repeating: 1, count: n)
        var eigenvalue = 0.0
        for _ in 0..<200 {
            var next = [Double](repeating: 0, count: n)
            for row in 0..<n {
                var sum = 0.0
                for column in 0..<n {
                    sum += total[row][column] * masses[column] * vector[column]
                }
                next[row] = sum
            }
            let norm = next.map(abs).max() ?? 0
            guard norm > 1e-30 else { break }
            for index in 0..<n { next[index] /= norm }

            if abs(norm - eigenvalue) < 1e-12 * Swift.max(norm, 1) {
                eigenvalue = norm
                vector = next
                break
            }
            eigenvalue = norm
            vector = next
        }

        guard eigenvalue > 1e-30 else {
            return Direction(period: 0, shape: vector, flexuralFraction: fraction)
        }
        // eigenvalue = 1/ω², so T = 2π√(eigenvalue).
        let period = 2 * .pi * eigenvalue.squareRoot()

        // Normalised to the roof, and positive, so the shape is comparable
        // between buildings.
        let tip = vector.last.map(abs) ?? 1
        let shape = tip > 1e-12 ? vector.map { $0 / tip } : vector

        return Direction(period: period.isFinite ? period : 0,
                         shape: shape, flexuralFraction: fraction)
    }

    // MARK: Flexibility matrices

    /// Cantilever bending flexibility at each floor.
    ///
    /// Derived from the exact deflection of a stepped cantilever: the
    /// displacement at level i from a unit load at level j is the standard
    /// integral of M·m/EI over the height they share. Building it in
    /// flexibility form avoids assembling and condensing a beam stiffness
    /// matrix, and is exact for a piecewise-uniform cantilever.
    private static func flexuralFlexibility(_ tower: Tower, second: [Double]) -> [[Double]] {
        let n = second.count
        var heights = [Double](repeating: 0, count: n)
        var running = 0.0
        for index in 0..<n {
            running += tower.storeyHeights[safe: index] ?? 3.4
            heights[index] = running
        }

        let e = Swift.max(tower.elasticModulus, 1)
        var flexibility = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)

        for i in 0..<n {
            for j in 0..<n {
                // Only the part of the cantilever below both levels carries
                // moment from a load at j felt at i.
                let shared = Swift.min(heights[i], heights[j])
                var sum = 0.0
                var base = 0.0
                for segment in 0..<n {
                    let top = heights[segment]
                    guard base < shared else { break }
                    let segmentTop = Swift.min(top, shared)
                    let ei = e * second[segment]
                    guard ei > 1e-9 else { base = top; continue }

                    // ∫ (hi - z)(hj - z) dz over this segment, which is the
                    // exact integral for the unit-load moment diagrams.
                    let hi = heights[i]
                    let hj = heights[j]
                    let a = base
                    let b = segmentTop
                    let integral = hi * hj * (b - a)
                        - (hi + hj) * (b * b - a * a) / 2
                        + (b * b * b - a * a * a) / 3
                    sum += integral / ei
                    base = top
                }
                flexibility[i][j] = Swift.max(sum, 0)
            }
        }
        return flexibility
    }

    /// Shear flexibility: storeys deforming as shear panels, accumulating.
    private static func shearFlexibility(_ tower: Tower, shearAreas: [Double]) -> [[Double]] {
        let n = shearAreas.count
        let g = Swift.max(tower.shearModulus, 1)

        // Flexibility of each storey on its own.
        var storey = [Double](repeating: 0, count: n)
        for index in 0..<n {
            let height = tower.storeyHeights[safe: index] ?? 3.4
            // The shear area is a fraction of the gross section; 5/6 is the
            // standard form factor for a rectangular section in shear.
            let ga = g * shearAreas[index] * (5.0 / 6.0)
            storey[index] = ga > 1e-9 ? height / ga : 0
        }

        // Shear deformations accumulate up the height: a load at level j is
        // carried by every storey below it, and every one of those shears.
        var flexibility = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n {
                var sum = 0.0
                for level in 0...Swift.min(i, j) {
                    sum += storey[level]
                }
                flexibility[i][j] = sum
            }
        }
        return flexibility
    }

    // MARK: Torsional coupling

    /// Splits a sway period and a torsional period that are coupled by
    /// eccentricity.
    ///
    /// The classical result for one storey with two coupled degrees of freedom.
    /// With no eccentricity the two are independent and come back unchanged;
    /// with eccentricity they repel, which is exactly the physical effect —
    /// coupling always softens one mode and stiffens the other, and it is the
    /// softened one that governs.
    private static func couple(swayPeriod: Double, torsionalPeriod: Double,
                               eccentricity: Double,
                               radiusOfGyration: Double) -> (sway: Double, torsional: Double) {
        guard swayPeriod > 1e-9, torsionalPeriod > 1e-9,
              radiusOfGyration > 1e-9, eccentricity > 1e-9 else {
            return (swayPeriod, torsionalPeriod)
        }

        let e = eccentricity / radiusOfGyration
        let swayFrequency = 1 / swayPeriod
        let torsionalFrequency = 1 / torsionalPeriod

        let a = swayFrequency * swayFrequency
        let b = torsionalFrequency * torsionalFrequency

        // Eigenvalues of [[a, -a·e], [-a·e, b + a·e²]].
        let sum = a + b + a * e * e
        let discriminant = Swift.max(sum * sum - 4 * (a * b), 0)
        let root = discriminant.squareRoot()
        let lower = (sum - root) / 2
        let upper = (sum + root) / 2

        let softened = lower > 1e-30 ? 1 / lower.squareRoot() : swayPeriod
        let stiffened = upper > 1e-30 ? 1 / upper.squareRoot() : torsionalPeriod
        return (softened, stiffened)
    }

    private static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var sum = 0.0
        for index in 0..<Swift.min(a.count, b.count) { sum += a[index] * b[index] }
        return sum
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - From a building

public extension TowerAnalysis {

    /// Builds the tower model from a described building.
    ///
    /// The section at each floor is the real traced outline scaled by the
    /// massing profile, so a podium genuinely has a larger second moment than
    /// the tower standing on it — which is the whole point of doing this from
    /// geometry rather than from a single assumed stiffness.
    static func tower(for building: BuildingModel) -> Tower {
        let storeys = Swift.max(building.storeyCount, 1)
        let storeyHeight = building.height / Double(storeys)
        let scales = building.massing.scales(storeys: storeys)

        let outline = building.footprint.isEmpty
            ? BuildingModel.rectangularFootprint(area: building.footprintArea)
            : building.footprint

        var sections: [SectionProperties] = []
        var masses: [Double] = []
        sections.reserveCapacity(storeys)
        masses.reserveCapacity(storeys)

        for index in 0..<storeys {
            let scale = index < scales.count ? scales[index] : 1
            let scaled = outline.map { Coordinate2D(x: $0.x * scale, y: $0.y * scale) }
            var section = SectionProperties.of(scaled)

            // The traced outline is the gross plan; the model wants the plan of
            // the storey. Scaling the polygon already handles that, but the
            // stated floor area is the more trustworthy figure when the outline
            // came from a shape inference rather than a survey, so the section
            // is normalised onto it.
            if section.area > 1e-6, building.footprintArea > 1 {
                let target = building.footprintArea * scale * scale
                let ratio = target / section.area
                section.area *= ratio
                // Second moments scale with the square of an area ratio, since
                // they are a fourth power of a length.
                section.ixx *= ratio * ratio
                section.iyy *= ratio * ratio
                section.ixy *= ratio * ratio
                section.iMajor *= ratio * ratio
                section.iMinor *= ratio * ratio
            }

            sections.append(section)
            masses.append(Swift.max(section.area, 1) * building.material.floorMassPerArea)
        }

        // How much of the plan resists shear, and how much of it bends.
        //
        // The ratio between these two is what decides whether a building
        // behaves like a frame or like a cantilever, and it is a property of
        // the structural system rather than of the shape. A moment frame
        // carries load storey against storey and its columns sit inside the
        // plan, so it shears; a core or a wall is one deep section and bends.
        //
        // The absolute level of both is then calibrated below, so only this
        // ratio matters here.
        // (shear, flexural). Only the ratio matters — the level is calibrated
        // below — and the ratio runs the opposite way to first intuition, for
        // the reason set out on `flexuralEfficiency`.
        let (shearEfficiency, flexuralEfficiency): (Double, Double) = switch building.system {
        // A core: stiff in shear, little of the gross plan's second moment.
        case .shearWall:               (0.020, 0.0030)
        // Braced frames sit between a core and a moment frame.
        case .bracedFrame, .dualSystem: (0.012, 0.0070)
        // Walls on the perimeter: a large second moment, and stiff in shear too.
        case .bearingWall:             (0.014, 0.0140)
        // Columns spread to the perimeter, weak in racking. Shears.
        case .momentFrame:             (0.0035, 0.0170)
        // As a frame, and softer still where it matters.
        case .softStorey:              (0.0025, 0.0170)
        // Effectively rigid above the isolators.
        case .baseIsolated:            (0.010, 0.0140)
        case .unknown:                 (0.008, 0.0090)
        }
        let efficiency = shearEfficiency

        let elastic: Double = switch building.material {
        case .steel: 200e9
        case .reinforcedConcrete, .hybrid: 25e9
        case .masonry, .unreinforcedMasonry: 8e9
        case .timber: 11e9
        case .unknown: 20e9
        }

        // Eccentricity between the mass centre and the stiffness centre.
        //
        // A soft-storey building is soft on one side by definition, and an
        // irregular plan puts its stiff elements where the plan happens to be
        // thick. Neither is measured, so both are declared as the assumptions
        // they are rather than presented as findings.
        let radius = sections.first?.radiusOfGyration ?? 1
        let eccentricity: Double = switch building.system {
        case .softStorey: radius * 0.15
        default: sections.first.map { $0.directionalRatio > 3 ? radius * 0.08 : 0 } ?? 0
        }

        // Where the bracing sits, relative to where the mass sits.
        //
        // Perimeter systems get a long lever arm against twisting; a central
        // core gets almost none. This is the property that decides whether
        // torsion is a footnote or the mode that governs.
        var lever: Double = switch building.system {
        // Columns and walls all round the edge.
        case .momentFrame:              1.25
        case .bearingWall:              1.30
        // Isolators are laid out under the perimeter of the raft.
        case .baseIsolated:             1.30
        case .dualSystem:               1.20
        case .bracedFrame:              1.15
        // Soft at one level, and that level decides the whole response.
        case .softStorey:               0.95
        // A single core at the centre: the classic torsionally soft building.
        case .shearWall:                0.85
        case .unknown:                  1.15
        }
        // A long thin plan cannot brace its short direction with a long arm,
        // whatever the system, so slenderness erodes the advantage. The cap
        // keeps a very elongated slab from being driven to absurdity.
        if let plan = sections.first, plan.directionalRatio > 1.5 {
            let excess = Swift.min(plan.directionalRatio - 1.5, 4.0)
            lever *= 1 - 0.06 * excess
        }

        var tower = Tower(
            storeyHeights: Array(repeating: storeyHeight, count: storeys),
            storeyMasses: masses,
            sections: sections,
            damping: building.damping,
            structuralEfficiency: efficiency,
            flexuralEfficiency: flexuralEfficiency,
            elasticModulus: elastic,
            shearModulus: elastic / 2.4,      // ≈ E/(2(1+ν)) with ν ≈ 0.2
            eccentricityX: eccentricity,
            eccentricityY: 0,
            torsionalLeverRatio: lever)

        // Calibrated against the code formula, which is the only empirical
        // anchor available without knowing the real structure.
        //
        // This is the same direction the shear model already works in, and it
        // is the honest one: the building codes' period formula is a regression
        // through hundreds of measured buildings, so it fixes the *level*
        // credibly. What it cannot do is say anything about direction, torsion
        // or how a particular shape distributes its stiffness — and that is
        // exactly what the geometry here supplies. Calibrating the level and
        // deriving the differences is the combination that gets both right.
        //
        // Without it the model was reporting an ordinary eight-storey block at
        // 0.35 s against a code value of 0.90.
        let uncalibrated = analyse(tower)
        let target = building.empiricalPeriod
        if uncalibrated.minorAxisPeriod > 1e-6, target > 1e-6 {
            // Period goes with one over the square root of stiffness, so
            // matching it means scaling stiffness by the square of the ratio.
            let ratio = uncalibrated.minorAxisPeriod / target
            let scale = ratio * ratio
            tower.structuralEfficiency *= scale
            tower.flexuralEfficiency *= scale
        }
        return tower
    }

    /// The full three-dimensional picture for a building.
    static func analyse(_ building: BuildingModel) -> Result {
        analyse(tower(for: building))
    }
}
