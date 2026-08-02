import Foundation
import SeismicCore
import SeismicSignal

// MARK: - 83. Pushover and the capacity curve

/// Algorithm 83 — nonlinear static pushover.
///
/// Every structural answer this app gives so far comes from running one
/// earthquake through the building. That says what *this* record did. It does
/// not say how much the building had left, and "how much was left" is the
/// question somebody standing outside actually has: it survived, but was that
/// comfortable or was it nearly the end?
///
/// A pushover answers it. Push the building sideways with a force distribution
/// shaped like its first mode, increasing steadily, and record base shear
/// against roof displacement. The curve rises linearly while everything is
/// elastic, bends over as storeys start to yield, and flattens when a mechanism
/// forms. Where it flattens is the building's capacity — a property of the
/// structure, independent of any earthquake.
///
/// The result feeds algorithm 83, which is what turns capacity into a verdict.
public enum Pushover {

    public struct Step: Sendable, Equatable, Identifiable {
        public var id: Int { index }
        public var index: Int
        /// Roof displacement, metres.
        public var roofDisplacement: Double
        /// Total base shear, newtons.
        public var baseShear: Double
        /// Fraction of storeys that have yielded by this step.
        public var yieldedFraction: Double

        public init(index: Int, roofDisplacement: Double, baseShear: Double,
                    yieldedFraction: Double) {
            self.index = index
            self.roofDisplacement = roofDisplacement
            self.baseShear = baseShear
            self.yieldedFraction = yieldedFraction
        }
    }

    public struct Capacity: Sendable, Equatable {
        public var curve: [Step]
        /// Base shear at first yield, newtons.
        public var yieldShear: Double
        /// Roof displacement at first yield, metres.
        public var yieldDisplacement: Double
        /// Peak base shear the building can carry.
        public var ultimateShear: Double
        /// Roof displacement at which a mechanism forms.
        public var ultimateDisplacement: Double

        public init(curve: [Step], yieldShear: Double, yieldDisplacement: Double,
                    ultimateShear: Double, ultimateDisplacement: Double) {
            self.curve = curve
            self.yieldShear = yieldShear
            self.yieldDisplacement = yieldDisplacement
            self.ultimateShear = ultimateShear
            self.ultimateDisplacement = ultimateDisplacement
        }

        /// Displacement ductility: how far past first yield the building can go
        /// before it runs out. The single most informative number about how a
        /// structure will behave, and the one a linear analysis cannot produce.
        public var ductility: Double {
            yieldDisplacement > 1e-9 ? ultimateDisplacement / yieldDisplacement : 0
        }
    }

    /// - Parameters:
    ///   - yieldDrift: interstorey drift ratio at which a storey yields.
    ///   - ultimateDrift: drift at which it has lost its lateral capacity.
    ///   - postYieldStiffness: fraction of the elastic stiffness retained after
    ///     yield. Small and positive — a real frame hardens slightly rather
    ///     than going perfectly flat, and a perfectly flat branch makes the
    ///     solution indeterminate.
    public static func run(_ building: ShearBuilding,
                           yieldDrift: Double = 0.005,
                           ultimateDrift: Double = 0.025,
                           postYieldStiffness: Double = 0.03,
                           steps: Int = 200) -> Capacity {
        let n = building.storeys.count
        guard n > 0 else {
            return Capacity(curve: [], yieldShear: 0, yieldDisplacement: 0,
                            ultimateShear: 0, ultimateDisplacement: 0)
        }

        // Load pattern from the first mode, which is the standard choice: the
        // building is pushed in the shape it actually deflects in.
        let modes = ModalAnalysis.modes(of: building)
        let shape = modes.first?.shape ?? (0..<n).map { Double($0 + 1) / Double(n) }
        let masses = building.storeys.map(\.mass)
        var pattern = zip(masses, shape).map { $0 * $1 }
        let patternTotal = pattern.reduce(0, +)
        if patternTotal > 0 { pattern = pattern.map { $0 / patternTotal } }

        var curve: [Step] = []
        var yieldShear = 0.0, yieldDisplacement = 0.0
        var recordedYield = false

        // March the base shear up and find the displaced shape it produces.
        let elasticStorey = building.storeys.map { $0.stiffness * $0.height * yieldDrift }
        let referenceShear = elasticStorey.min() ?? 1

        for step in 1...steps {
            let baseShear = referenceShear * Double(step) * 0.05
            var interstorey = [Double](repeating: 0, count: n)
            var yielded = 0

            // Shear carried by each storey is everything pushed above it.
            for i in 0..<n {
                let shearHere = baseShear * pattern[i...].reduce(0, +)
                let storey = building.storeys[i]
                let elasticLimit = storey.stiffness * storey.height * yieldDrift

                if shearHere <= elasticLimit {
                    interstorey[i] = shearHere / storey.stiffness
                } else {
                    // Past yield the storey keeps taking load on a much softer
                    // branch, which is what produces the knee in the curve.
                    let excess = shearHere - elasticLimit
                    let softened = storey.stiffness * postYieldStiffness
                    interstorey[i] = storey.height * yieldDrift + excess / max(softened, 1)
                    yielded += 1
                }
            }

            let roof = interstorey.reduce(0, +)
            let fraction = Double(yielded) / Double(n)

            if !recordedYield, yielded > 0 {
                yieldShear = baseShear
                yieldDisplacement = roof
                recordedYield = true
            }

            curve.append(Step(index: step, roofDisplacement: roof,
                              baseShear: baseShear, yieldedFraction: fraction))

            // Stop once any storey has run past its ultimate drift — beyond
            // that the model is extrapolating a mechanism it does not contain.
            let worstDrift = zip(interstorey, building.storeys)
                .map { $0 / $1.height }.max() ?? 0
            if worstDrift >= ultimateDrift { break }
        }

        return Capacity(curve: curve,
                        yieldShear: yieldShear,
                        yieldDisplacement: yieldDisplacement,
                        ultimateShear: curve.last?.baseShear ?? 0,
                        ultimateDisplacement: curve.last?.roofDisplacement ?? 0)
    }
}

// MARK: - 84. Capacity spectrum performance point

/// Algorithm 84 — the capacity spectrum method (the N2 performance point).
///
/// This is the algorithm that turns "here is a building" and "here is an
/// earthquake" into "here is what that earthquake does to that building", in
/// one intersection, without integrating anything.
///
/// Both sides are converted into the same coordinates — spectral acceleration
/// against spectral displacement. The capacity curve from a pushover becomes a
/// capacity *spectrum* by dividing out the mode's participation. The response
/// spectrum, which this app already computes, becomes a demand spectrum in the
/// same axes. Where the two curves cross is the performance point: the
/// displacement the building will actually reach.
///
/// The subtlety that makes it work is the reduction. A building pushed past
/// yield dissipates energy hysteretically, and that extra damping reduces the
/// demand — so the demand curve has to be pulled down by an amount that depends
/// on how far past yield the building goes, which depends on where the curves
/// cross. It is implicit, and it is solved by iterating to a fixed point.
///
/// This is the standard method in Eurocode 8 and ATC-40, and it is how a real
/// assessment gets a displacement demand without running a time history.
public enum CapacitySpectrum {

    public struct PerformancePoint: Sendable, Equatable {
        /// Spectral displacement at the intersection, metres.
        public var spectralDisplacement: Double
        /// Spectral acceleration there, m/s².
        public var spectralAcceleration: Double
        /// Roof displacement it corresponds to, metres.
        public var roofDisplacement: Double
        /// How far past yield, as a multiple. One means it just reached yield.
        public var ductilityDemand: Double
        /// Effective damping at the performance point, including hysteretic.
        public var effectiveDamping: Double
        /// Whether the two curves actually crossed. When they do not, the
        /// demand exceeds the capacity everywhere and the building does not
        /// have a performance point — which is the most important thing this
        /// method can tell you.
        public var converged: Bool

        public init(spectralDisplacement: Double, spectralAcceleration: Double,
                    roofDisplacement: Double, ductilityDemand: Double,
                    effectiveDamping: Double, converged: Bool) {
            self.spectralDisplacement = spectralDisplacement
            self.spectralAcceleration = spectralAcceleration
            self.roofDisplacement = roofDisplacement
            self.ductilityDemand = ductilityDemand
            self.effectiveDamping = effectiveDamping
            self.converged = converged
        }

        /// Plain language, because a spectral displacement means nothing to
        /// anybody standing outside a building.
        public var plainMeaning: String {
            guard converged else {
                return "The demand from this earthquake exceeds what the building can "
                     + "carry at every displacement. The model has no equilibrium to "
                     + "offer, which is what collapse looks like in this method."
            }
            switch ductilityDemand {
            case ..<1:
                return "The building stays elastic. It bends and comes back, with nothing "
                     + "left permanently different."
            case 1..<2:
                return "The building goes just past yield. Some permanent damage, "
                     + "concentrated where it bends hardest, but a long way from failure."
            case 2..<4:
                return "The building is pushed well past yield and relies on ductility to "
                     + "survive. Significant structural damage is expected."
            default:
                return "The demand is near or beyond what the building can absorb. This is "
                     + "the region where the model stops being reliable and an engineer "
                     + "becomes essential."
            }
        }
    }

    /// - Parameters:
    ///   - demand: spectral acceleration against period, as the app's response
    ///     spectrum already produces.
    ///   - initialDamping: the elastic damping, usually 5%.
    public static func performancePoint(capacity: Pushover.Capacity,
                                        building: ShearBuilding,
                                        demand: [(period: Double, acceleration: Double)],
                                        initialDamping: Double = 0.05,
                                        iterations: Int = 40) -> PerformancePoint? {
        guard !capacity.curve.isEmpty, !demand.isEmpty,
              capacity.yieldDisplacement > 1e-9 else { return nil }

        let modes = ModalAnalysis.modes(of: building)
        guard let first = modes.first, first.massParticipationRatio > 0 else { return nil }

        let totalMass = building.totalMass
        guard totalMass > 0 else { return nil }

        // Conversion from the pushover curve to the equivalent single-degree-of
        // -freedom spectrum. The participation factor and the modal mass ratio
        // are exactly what separate "the roof moved this far" from "an
        // equivalent oscillator moved this far".
        let roofShape = first.shape.last ?? 1
        let participation = first.participationFactor
        let modalMassRatio = first.massParticipationRatio
        guard abs(participation * roofShape) > 1e-12, modalMassRatio > 1e-12 else { return nil }

        func toSpectral(_ step: Pushover.Step) -> (sd: Double, sa: Double) {
            (sd: step.roofDisplacement / (participation * roofShape),
             sa: step.baseShear / (totalMass * modalMassRatio))
        }

        let spectrum = capacity.curve.map(toSpectral)
        let yieldSpectral = toSpectral(
            capacity.curve.first { $0.baseShear >= capacity.yieldShear } ?? capacity.curve[0])

        func demandAcceleration(atPeriod period: Double, damping: Double) -> Double {
            // Interpolate the spectrum, then reduce it for the extra damping.
            // The Eurocode 8 reduction factor: √(0.10/(0.05+ξ)), floored at
            // 0.55 — the floor matters, because the formula is only calibrated
            // to about thirty per cent damping and without it a very ductile
            // building would be handed an implausibly small demand.
            var acceleration = demand.first?.acceleration ?? 0
            if period <= demand.first!.period {
                acceleration = demand.first!.acceleration
            } else if period >= demand.last!.period {
                acceleration = demand.last!.acceleration
            } else {
                for i in 1..<demand.count where demand[i].period >= period {
                    let a = demand[i - 1], b = demand[i]
                    let t = (period - a.period) / max(b.period - a.period, 1e-12)
                    acceleration = a.acceleration + (b.acceleration - a.acceleration) * t
                    break
                }
            }
            let reduction = max((0.10 / (0.05 + damping)).squareRoot(), 0.55)
            return acceleration * reduction
        }

        // Fixed-point iteration. Guess a ductility, reduce the demand for the
        // damping it implies, find where the reduced demand meets the capacity,
        // read off the new ductility, repeat.
        var damping = initialDamping
        var ductility = 1.0
        var solution: (sd: Double, sa: Double)?

        for _ in 0..<iterations {
            var found: (sd: Double, sa: Double)?
            for point in spectrum where point.sd > 1e-12 {
                // Effective period at this displacement, from the secant
                // stiffness — T = 2π√(Sd/Sa).
                let period = 2 * Double.pi * (point.sd / max(point.sa, 1e-12)).squareRoot()
                let required = demandAcceleration(atPeriod: period, damping: damping)
                // The capacity curve starts below the demand and rises to meet
                // it; the crossing is the first point where it catches up.
                if point.sa >= required {
                    found = point
                    break
                }
            }
            guard let point = found else {
                // Never crossed: the demand is above the capacity everywhere.
                return PerformancePoint(
                    spectralDisplacement: spectrum.last?.sd ?? 0,
                    spectralAcceleration: spectrum.last?.sa ?? 0,
                    roofDisplacement: capacity.ultimateDisplacement,
                    ductilityDemand: capacity.ductility,
                    effectiveDamping: damping, converged: false)
            }

            let newDuctility = yieldSpectral.sd > 1e-12 ? point.sd / yieldSpectral.sd : 1
            // Hysteretic damping, in the standard bilinear form: energy
            // dissipated per cycle grows with how far past yield the loop goes.
            let hysteretic = newDuctility > 1
                ? 0.637 * (1 - 1 / newDuctility.squareRoot()) * 0.5
                : 0
            let newDamping = min(initialDamping + hysteretic, 0.35)

            let converged = abs(newDuctility - ductility) < 1e-3
            ductility = newDuctility
            damping = newDamping
            solution = point
            if converged { break }
        }

        guard let point = solution else { return nil }
        return PerformancePoint(
            spectralDisplacement: point.sd,
            spectralAcceleration: point.sa,
            roofDisplacement: point.sd * participation * roofShape,
            ductilityDemand: ductility,
            effectiveDamping: damping,
            converged: true)
    }
}

// MARK: - 85. P-delta

/// Algorithm 85 — P-delta (second-order geometric) effects.
///
/// Every stiffness in this app's model so far is a first-order one: the
/// building resists sideways load with its columns, and that is that. Real tall
/// buildings have a second effect that works the other way. Once the structure
/// leans, the weight it is carrying is no longer directly over the columns —
/// so gravity itself now contributes an overturning moment that pushes it
/// further over. The building's effective lateral stiffness is *reduced* by its
/// own weight.
///
/// It is normally small and occasionally decisive. The stability coefficient
/// θ measures it, and codes require attention above about 0.10 and forbid
/// design above roughly 0.30 — beyond that the second-order effect is
/// self-amplifying and the structure is dynamically unstable regardless of how
/// strong its members are.
///
/// It matters here because it is worst exactly where this app's users live: a
/// heavy, flexible building at large drift, which is a damaged building.
public enum PDelta {

    public struct StoreyStability: Sendable, Equatable, Identifiable {
        public var id: Int { storey }
        public var storey: Int
        /// The stability coefficient θ = (P·Δ)/(V·h).
        public var theta: Double
        /// Multiplier on the first-order drift, 1/(1−θ).
        public var amplification: Double
        /// Effective lateral stiffness after the geometric softening.
        public var reducedStiffness: Double

        public init(storey: Int, theta: Double, amplification: Double,
                    reducedStiffness: Double) {
            self.storey = storey
            self.theta = theta
            self.amplification = amplification
            self.reducedStiffness = reducedStiffness
        }

        public var classification: Classification {
            switch theta {
            case ..<0.10: .negligible
            case 0.10..<0.20: .significant
            case 0.20..<0.30: .severe
            default: .unstable
            }
        }

        public enum Classification: String, Sendable {
            case negligible, significant, severe, unstable

            public var explanation: String {
                switch self {
                case .negligible:
                    "The building's own weight adds nothing meaningful to how far it leans."
                case .significant:
                    "The building's weight is adding measurably to its sway, and a "
                    + "first-order analysis is now optimistic."
                case .severe:
                    "Gravity is amplifying the sway substantially. Codes require this to be "
                    + "modelled explicitly rather than ignored."
                case .unstable:
                    "The building's own weight is pushing it over faster than the structure "
                    + "pushes back. This is dynamic instability, and it does not depend on "
                    + "member strength."
                }
            }
        }
    }

    /// - Parameter drifts: interstorey drift per storey, metres.
    public static func analyse(_ building: ShearBuilding,
                               drifts: [Double],
                               gravity: Double = 9.80665) -> [StoreyStability] {
        let n = building.storeys.count
        guard n > 0, drifts.count == n else { return [] }

        return (0..<n).map { i in
            let storey = building.storeys[i]
            // Every storey above this one presses down on it.
            let weightAbove = building.storeys[i...].reduce(0) { $0 + $1.mass } * gravity
            let shear = storey.stiffness * drifts[i]
            let height = max(storey.height, 1e-6)

            let theta = shear > 1e-9
                ? min((weightAbove * drifts[i]) / (shear * height), 0.99)
                : 0
            return StoreyStability(
                storey: i + 1,
                theta: theta,
                amplification: 1 / max(1 - theta, 0.01),
                // Geometric stiffness subtracts directly from the elastic one.
                reducedStiffness: max(storey.stiffness - weightAbove / height, 0))
        }
    }

    /// Applies the softening to a building, producing one whose modes and
    /// response include the effect.
    ///
    /// Returned as a new building rather than mutating, so a caller can show
    /// both and let somebody see the difference — which is the only way the
    /// size of the effect is ever intuitive.
    public static func softened(_ building: ShearBuilding,
                                gravity: Double = 9.80665) -> ShearBuilding {
        var softened = building
        let n = building.storeys.count
        for i in 0..<n {
            let weightAbove = building.storeys[i...].reduce(0) { $0 + $1.mass } * gravity
            let height = max(building.storeys[i].height, 1e-6)
            softened.storeys[i].stiffness = max(
                building.storeys[i].stiffness - weightAbove / height,
                building.storeys[i].stiffness * 0.05)
        }
        return softened
    }
}

// MARK: - 86. Soil–structure interaction

/// Algorithm 86 — soil–structure interaction by the cone model.
///
/// Every model in this app so far assumes the building is bolted to bedrock. It
/// is not. A building on soft ground can rock and translate on its foundation,
/// and those two extra degrees of freedom add flexibility in series with the
/// structure's own — so the whole system has a longer period and more damping
/// than the fixed-base model says.
///
/// The direction of both errors is what makes this worth having. A longer
/// period usually means *less* acceleration demand, so ignoring it is
/// conservative for strength. But the app's entire premise is comparing a
/// measured period against a predicted one, and a fixed-base prediction on soft
/// soil is systematically too short — which reads exactly like damage. A
/// building on clay would be flagged as softened on the day it was built.
///
/// The cone model gives the foundation's stiffness and radiation damping in
/// closed form by treating the soil under a footing as a truncated cone of
/// material. It is the standard simplified method, it needs only the shear-wave
/// velocity and the footing size, and both are things this app can get.
public enum SoilStructureInteraction {

    public struct Footing: Sendable, Equatable {
        /// Equivalent radius of the footing, metres.
        public var radius: Double
        /// Soil shear-wave velocity, m/s. This is what soil class encodes.
        public var shearWaveVelocity: Double
        /// Soil density, kg/m³.
        public var density: Double
        public var poissonRatio: Double

        public init(radius: Double, shearWaveVelocity: Double,
                    density: Double = 1_900, poissonRatio: Double = 0.33) {
            self.radius = max(radius, 0.5)
            self.shearWaveVelocity = max(shearWaveVelocity, 30)
            self.density = max(density, 500)
            self.poissonRatio = min(max(poissonRatio, 0), 0.49)
        }

        /// Soil shear modulus, G = ρVs².
        public var shearModulus: Double {
            density * shearWaveVelocity * shearWaveVelocity
        }

        /// Horizontal (swaying) stiffness of the footing, N/m.
        public var swayStiffness: Double {
            8 * shearModulus * radius / (2 - poissonRatio)
        }

        /// Rocking stiffness, N·m/rad.
        public var rockingStiffness: Double {
            8 * shearModulus * radius * radius * radius / (3 * (1 - poissonRatio))
        }

    }

    public struct Result: Sendable, Equatable {
        /// Period assuming the building is fixed to bedrock.
        public var fixedBasePeriod: Double
        /// Period including foundation sway and rocking.
        public var flexibleBasePeriod: Double
        /// Total damping including radiation into the soil.
        public var effectiveDamping: Double
        /// How much longer the period is, as a fraction.
        public var periodLengthening: Double

        public init(fixedBasePeriod: Double, flexibleBasePeriod: Double,
                    effectiveDamping: Double, periodLengthening: Double) {
            self.fixedBasePeriod = fixedBasePeriod
            self.flexibleBasePeriod = flexibleBasePeriod
            self.effectiveDamping = effectiveDamping
            self.periodLengthening = periodLengthening
        }

        /// The warning this exists to produce.
        public var significance: String {
            switch periodLengthening {
            case ..<0.05:
                return "The ground is stiff enough that the foundation barely matters. A "
                     + "fixed-base period is a fair prediction here."
            case 0.05..<0.20:
                return String(format: "The soil lengthens this building's period by %.0f%%. ",
                              periodLengthening * 100)
                     + "A fixed-base prediction would be short by about that much, which is "
                     + "the same size as the change real damage produces — so the baseline "
                     + "has to account for it or the building looks damaged when it is not."
            default:
                return String(format: "The soil lengthens this building's period by %.0f%%, ",
                              periodLengthening * 100)
                     + "which is more than most damage would. On ground this soft the "
                     + "foundation dominates, and a period measured here says as much about "
                     + "the soil as about the structure."
            }
        }
    }

    /// - Parameters:
    ///   - effectiveHeight: height of the resultant lateral force above the
    ///     foundation. About 0.7 of total height for a first-mode pattern.
    public static func analyse(_ building: ShearBuilding,
                               foundation: Footing,
                               effectiveHeight: Double? = nil) -> Result? {
        let modes = ModalAnalysis.modes(of: building)
        guard let first = modes.first, first.period > 0 else { return nil }

        let mass = building.totalMass
        let height = effectiveHeight ?? building.totalHeight * 0.7
        guard mass > 0, height > 0 else { return nil }

        // Structural stiffness that produces the fixed-base period.
        let omega = 2 * Double.pi / first.period
        let structuralStiffness = mass * omega * omega

        // Three springs in series: the structure, the foundation's sway, and
        // the foundation's rocking. Rocking is converted to an equivalent
        // lateral stiffness through the lever arm — which is why the effective
        // height matters and why rocking dominates for a tall building.
        let rockingAsLateral = foundation.rockingStiffness / (height * height)
        let flexibility = 1 / structuralStiffness
                        + 1 / foundation.swayStiffness
                        + 1 / rockingAsLateral
        let combinedStiffness = 1 / flexibility

        let flexiblePeriod = 2 * Double.pi * (mass / combinedStiffness).squareRoot()
        let lengthening = first.period > 0
            ? (flexiblePeriod - first.period) / first.period : 0

        // Damping combines by the standard substitute-structure rule: the
        // structural damping is diluted by the cube of the period ratio,
        // because a softer system stores more energy in the soil than in the
        // frame, and radiation damping is added on top.
        let ratio = flexiblePeriod / first.period
        let diluted = building.damping / (ratio * ratio * ratio)
        // Radiation into a half-space, capped: the closed form runs away for
        // very soft soil and no real site radiates more than about a fifth of
        // critical.
        let radiation = min(0.05 * (1 - 1 / max(ratio * ratio, 1)), 0.20)

        return Result(fixedBasePeriod: first.period,
                      flexibleBasePeriod: flexiblePeriod,
                      effectiveDamping: min(diluted + radiation, 0.30),
                      periodLengthening: lengthening)
    }
}

// MARK: - 87. Incremental dynamic analysis

/// Algorithm 87 — incremental dynamic analysis.
///
/// The app can already say what one earthquake did to one building. The
/// question everyone asks next is the one it could not answer: *how much worse
/// could it have been before this building was in real trouble?*
///
/// IDA answers it by brute force, and the brute force is the point. Take the
/// record, scale it to a small intensity, run the full nonlinear solver, record
/// the worst drift. Scale up, run again. Repeat until the drift runs away.
/// Plotting intensity against drift gives a curve that rises steadily and then
/// goes flat — and the intensity at which it flattens is where the building
/// stops being able to absorb any more, which is the definition of collapse in
/// this framework.
///
/// It is expensive — dozens of full time-history runs — and there is no cheaper
/// way to get the answer, because the whole phenomenon being measured is the
/// nonlinearity. That is why it runs on demand rather than after every event.
public enum IncrementalDynamicAnalysis {

    public struct Point: Sendable, Equatable, Identifiable {
        public var id: Int { Int(scale * 1000) }
        /// Multiplier applied to the record.
        public var scale: Double
        /// Peak ground acceleration at that scale, m/s².
        public var intensity: Double
        /// Maximum interstorey drift ratio reached.
        public var maximumDrift: Double
        public var collapsed: Bool

        public init(scale: Double, intensity: Double, maximumDrift: Double,
                    collapsed: Bool) {
            self.scale = scale
            self.intensity = intensity
            self.maximumDrift = maximumDrift
            self.collapsed = collapsed
        }
    }

    public struct Result: Sendable, Equatable {
        public var curve: [Point]
        /// Scale factor at which the building first fails. Nil means it
        /// survived every scale tried, which is a real answer and not a
        /// missing one.
        public var collapseScale: Double?
        /// Intensity at collapse, m/s².
        public var collapseIntensity: Double?
        /// How much more than the record as given the building could take.
        public var marginOverRecord: Double?

        public init(curve: [Point], collapseScale: Double?,
                    collapseIntensity: Double?, marginOverRecord: Double?) {
            self.curve = curve
            self.collapseScale = collapseScale
            self.collapseIntensity = collapseIntensity
            self.marginOverRecord = marginOverRecord
        }

        /// The sentence somebody standing outside would want.
        public var plainMeaning: String {
            guard let margin = marginOverRecord else {
                return "The building came through every intensity tested, up up to several "
                     + "times the shaking it actually saw. There is margin here, and this "
                     + "analysis did not find its edge."
            }
            switch margin {
            case ..<1.0:
                return "This building was already past the point the model calls failure. "
                     + "Everything downstream of that is extrapolation."
            case 1.0..<1.5:
                return String(format: "It survived, with about %.0f%% in hand. ",
                              (margin - 1) * 100)
                     + "An aftershock half again as strong as the mainshock would be at the "
                     + "edge of what this model says it can take."
            case 1.5..<3.0:
                return String(format: "It could have taken roughly %.1f times ", margin)
                     + "the shaking it saw. Comfortable, but not enormous margin."
            default:
                return String(format: "It could have taken about %.0f times ", margin)
                     + "this earthquake. The record that hit it was nowhere near this "
                     + "building's limit."
            }
        }
    }

    /// - Parameters:
    ///   - collapseDrift: interstorey drift ratio treated as failure. 0.05 is
    ///     the usual figure for a ductile frame.
    ///   - scales: the multipliers to run. Geometric rather than linear,
    ///     because the interesting region is always near the top and a linear
    ///     sweep spends most of its runs establishing that small earthquakes do
    ///     little.
    public static func run(_ building: ShearBuilding,
                           ground: Waveform,
                           thresholds: DriftThresholds,
                           collapseDrift: Double = 0.05,
                           scales: [Double] = [0.25, 0.5, 0.75, 1.0, 1.5, 2.0,
                                               3.0, 4.0, 6.0, 8.0]) -> Result {
        var curve: [Point] = []
        var collapseScale: Double?
        let basePeak = ground.peakAbsolute

        for scale in scales.sorted() {
            let scaled = Waveform(samples: ground.samples.map { $0 * scale },
                                  sampleRate: ground.sampleRate,
                                  startTime: ground.startTime, unit: ground.unit)
            let result = StructuralSolver.run(
                building, groundAcceleration: scaled, thresholds: thresholds,
                options: .init(allowDegradation: true, keepHistory: false))

            let drift = result.maximumDrift
            let collapsed = drift >= collapseDrift || result.collapsed
            curve.append(Point(scale: scale, intensity: basePeak * scale,
                               maximumDrift: drift, collapsed: collapsed))

            if collapsed, collapseScale == nil { collapseScale = scale }
            // One collapse is enough. Running further scales tells you nothing
            // new and costs a full time history each.
            if collapsed { break }
        }

        return Result(curve: curve,
                      collapseScale: collapseScale,
                      collapseIntensity: collapseScale.map { basePeak * $0 },
                      marginOverRecord: collapseScale)
    }
}
