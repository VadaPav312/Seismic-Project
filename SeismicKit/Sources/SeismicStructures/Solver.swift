import Foundation
import SeismicCore
import SeismicSignal

// Algorithms 39–45. The structural engine: turning a building's description
// into matrices, finding how it wants to move, and pushing it through an
// earthquake one time step at a time.

// MARK: - 39. Lumped-mass assembly

/// A shear-building idealisation: one mass per floor, one lateral spring
/// between adjacent floors.
///
/// This is a drastic simplification of a real structure, and it is the *right*
/// simplification for the question being asked. Storey drift and sway period are
/// governed almost entirely by how mass and lateral stiffness are distributed up
/// the height; the detail of individual beams and columns changes the answer by
/// far less than the uncertainty in the inputs. A model an engineer can check in
/// their head is worth more here than a finite-element mesh nobody can audit.
public struct ShearBuilding: Sendable, Equatable {
    public var storeys: [Storey]
    public var damping: Double
    public var name: String
    /// Displacement ductility capacity — how far it can deform before the
    /// damage model treats it as lost.
    public var ductility: Double

    public init(storeys: [Storey], damping: Double, name: String = "", ductility: Double = 3) {
        self.storeys = storeys
        self.damping = Swift.min(Swift.max(damping, 0.001), 0.5)
        self.name = name
        self.ductility = Swift.max(ductility, 1)
    }

    public var degreesOfFreedom: Int { storeys.count }
    public var totalMass: Double { storeys.reduce(0) { $0 + $1.mass } }
    public var totalHeight: Double { storeys.reduce(0) { $0 + $1.height } }

    /// Height of each floor level above ground.
    public var levelHeights: [Double] {
        var out: [Double] = []
        var running = 0.0
        for storey in storeys { running += storey.height; out.append(running) }
        return out
    }

    /// Mass matrix. Diagonal by construction, which is what makes the whole
    /// scheme cheap: no matrix inversion is ever needed.
    public var massMatrix: [[Double]] {
        let n = degreesOfFreedom
        var m = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n { m[i][i] = storeys[i].mass }
        return m
    }

    /// Stiffness matrix. Tridiagonal: each floor is connected only to the floors
    /// immediately above and below it.
    ///
    ///   K[i][i]   =  k_i + k_{i+1}
    ///   K[i][i+1] = −k_{i+1}
    ///
    /// where k_i is the stiffness of the storey *below* floor i.
    public var stiffnessMatrix: [[Double]] {
        let n = degreesOfFreedom
        var k = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            let below = storeys[i].stiffness
            let above = i + 1 < n ? storeys[i + 1].stiffness : 0
            k[i][i] = below + above
            if i + 1 < n {
                k[i][i + 1] = -above
                k[i + 1][i] = -above
            }
        }
        return k
    }

    /// Builds a model from a described building, choosing storey properties from
    /// its facts and then *calibrating* the stiffness so the model's computed
    /// first period matches the empirical estimate for that structural type.
    ///
    /// Calibration rather than first-principles stiffness is deliberate: nobody
    /// knows the true lateral stiffness of a building they have only read about,
    /// but the period–height relationships are well established across thousands
    /// of real buildings. Matching the known quantity and deriving the unknown
    /// one is the honest direction to work in.
    public static func from(_ building: BuildingModel,
                            stiffnessScale: Double = 1.0,
                            targetPeriod: Double? = nil) -> ShearBuilding {
        let n = Swift.max(building.storeyCount, 1)
        let storeyHeight = building.height / Double(n)
        let floorArea = building.footprintArea
        let massPerFloor = floorArea * building.material.floorMassPerArea

        // A provisional stiffness; the absolute value is arbitrary because it is
        // about to be scaled to hit the target period.
        let provisional = 1.0e8

        // Stiffness usually tapers up the height — upper storeys carry less
        // load and are built lighter. A linear taper to 60% at the roof is a
        // standard, defensible assumption, and it produces realistic mode
        // shapes rather than the unnaturally straight ones a uniform model gives.
        // The massing profile, sampled per storey. A uniform building gives all
        // ones and this changes nothing; a podium or a taper changes both the
        // mass and the stiffness of the storeys it affects.
        let planScales = building.massing.scales(storeys: n)

        var storeys: [Storey] = []
        for i in 0..<n {
            let fraction = n > 1 ? Double(i) / Double(n - 1) : 0
            let taper = 1.0 - 0.4 * fraction

            // Floor area goes with the square of a linear plan scale, so a
            // tower at half the plan width has a quarter of the floor — and a
            // quarter of the mass. Getting this wrong on a tower-on-podium
            // misplaces a large fraction of the building's weight.
            let planScale = i < planScales.count ? planScales[i] : 1
            let storeyArea = floorArea * planScale * planScale

            // Lateral stiffness scales roughly with the plan area available for
            // columns and walls. Linear in area is the defensible assumption
            // here: the alternative, holding stiffness constant while mass
            // drops, would make a slender tower stiffer than the podium
            // carrying it, which is the opposite of what happens.
            storeys.append(Storey(id: i + 1,
                                  height: storeyHeight,
                                  mass: massPerFloor * planScale * planScale,
                                  stiffness: provisional * taper * planScale * planScale,
                                  floorArea: storeyArea))
        }

        // A soft ground storey — an open lobby or undercroft parking — is one of
        // the deadliest configurations there is, and the model has to show it.
        if building.system == .softStorey, !storeys.isEmpty {
            storeys[0].stiffness *= 0.35
        }

        var model = ShearBuilding(storeys: storeys, damping: building.damping,
                                  name: building.name,
                                  ductility: building.system.ductility)

        let isolated = building.system == .baseIsolated
            || building.retrofit == .baseIsolationRetrofit

        // The superstructure is calibrated to its *fixed-base* period — what it
        // would do bolted straight to the ground.
        //
        // For an isolated building that is emphatically not the same as its
        // as-built period. The whole design principle is a stiff superstructure
        // sitting on soft bearings: the frame stays short-period and barely
        // deforms while the isolators take the movement. Calibrating the frame
        // to the long isolated period instead produces a floppy superstructure
        // on soft bearings, which behaves worse than a conventional building —
        // the opposite of what base isolation does.
        let fixedBaseTarget: Double
        if let targetPeriod {
            fixedBaseTarget = targetPeriod
        } else if isolated {
            fixedBaseTarget = 0.0466 * pow(building.height, 0.9)
        } else {
            fixedBaseTarget = building.empiricalPeriod
        }

        if let computed = ModalAnalysis.naturalPeriods(of: model).first,
           computed > 0, fixedBaseTarget > 0 {
            // T ∝ 1/√k, so to change the period by a factor r the stiffness must
            // change by 1/r².
            let ratio = computed / fixedBaseTarget
            let factor = ratio * ratio * stiffnessScale
            for i in model.storeys.indices { model.storeys[i].stiffness *= factor }
        }

        // Base isolation is modelled as an extra, deliberately very soft and
        // very heavily damped storey at the bottom — which is exactly what it
        // physically is. Its stiffness is sized from the mass it has to carry so
        // the whole assembly lands on the intended isolated period, rather than
        // being an arbitrary fraction of the storey above.
        if isolated {
            let carriedMass = model.storeys.reduce(0) { $0 + $1.mass }
            let isolatedPeriod = Swift.max(building.empiricalPeriod * 1.5, 2.5)
            let omega = 2 * Double.pi / isolatedPeriod
            let isolatorStiffness = carriedMass * omega * omega

            let isolator = Storey(id: 0, height: 0.6, mass: massPerFloor * 0.3,
                                  stiffness: isolatorStiffness, floorArea: floorArea)
            model.storeys.insert(isolator, at: 0)
            for i in model.storeys.indices { model.storeys[i].id = i + 1 }
            // Lead-rubber and friction-pendulum bearings are deliberately very
            // lossy; 15–30% of critical is normal and is half the point of them.
            model.damping = Swift.max(model.damping, 0.18)
        }

        return model
    }
}

// MARK: - 40. Eigenvalue extraction

public struct ModeShape: Sendable, Equatable, Identifiable {
    public var id: Int { number }
    public var number: Int
    public var frequency: Double        // Hz
    public var period: Double           // s
    /// Normalised so the largest component is 1 — the form the animation wants.
    public var shape: [Double]
    /// What fraction of the building's mass this mode moves. The first mode of
    /// a regular building typically carries 70–85%, which is why single-mode
    /// reasoning works at all.
    public var participationFactor: Double
    public var massParticipationRatio: Double

    public init(number: Int, frequency: Double, shape: [Double],
                participationFactor: Double, massParticipationRatio: Double) {
        self.number = number
        self.frequency = frequency
        self.period = frequency > 0 ? 1 / frequency : 0
        self.shape = shape
        self.participationFactor = participationFactor
        self.massParticipationRatio = massParticipationRatio
    }
}

public enum ModalAnalysis {

    /// Algorithm 40 — Jacobi eigenvalue extraction.
    ///
    /// Repeatedly zeroes the largest off-diagonal entry with a plane rotation.
    /// It is not the fastest method known, but it is unconditionally stable for
    /// symmetric matrices, needs no starting guess, and returns *every*
    /// eigenvector accurately — including the closely spaced higher modes that
    /// power-iteration methods struggle to separate. For the matrix sizes here
    /// (tens of storeys) it is instantaneous.
    /// - Parameter maxSweeps: a *sweep* visits every off-diagonal entry once.
    ///   Cyclic Jacobi converges in six to ten sweeps for any matrix this code
    ///   will ever see, so the cap only exists as a backstop.
    ///
    /// Note the structure: one rotation per iteration — the naive reading of
    /// "repeatedly zero the largest off-diagonal" — needs thousands of
    /// iterations for a 30×30 matrix and silently returns garbage if it runs
    /// out. Sweeping cyclically over all n(n−1)/2 pairs is both faster and
    /// bounded, and a 40-storey tower is a perfectly ordinary input here.
    public static func jacobiEigen(_ matrix: [[Double]], maxSweeps: Int = 60)
        -> (values: [Double], vectors: [[Double]])
    {
        let n = matrix.count
        guard n > 0, matrix.allSatisfy({ $0.count == n }) else { return ([], []) }
        if n == 1 { return ([matrix[0][0]], [[1]]) }

        var a = matrix
        var v = LinearAlgebra.identity(n)

        // Convergence is measured relative to the matrix's own scale, so it
        // works equally well for stiffnesses of 10⁸ and normalised matrices of
        // order 1.
        let scale = (0..<n).reduce(0.0) { $0 + abs(a[$1][$1]) } / Double(n)
        let tolerance = Swift.max(scale, 1) * 1e-14

        for _ in 0..<maxSweeps {
            var offDiagonal = 0.0
            for i in 0..<n {
                for j in (i + 1)..<n { offDiagonal += a[i][j] * a[i][j] }
            }
            if offDiagonal.squareRoot() < tolerance { break }

            var rotated = false
            for p in 0..<(n - 1) {
                for q in (p + 1)..<n {
                    let apq = a[p][q]
                    guard abs(apq) > tolerance * 1e-3 else { continue }
                    rotated = true

                    let app = a[p][p], aqq = a[q][q]
                    let theta = (aqq - app) / (2 * apq)
                    let t = (theta >= 0 ? 1.0 : -1.0)
                        / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot()
                    let s = t * c

                    // Apply the rotation to A and accumulate it into V.
                    for k in 0..<n {
                        let akp = a[k][p], akq = a[k][q]
                        a[k][p] = c * akp - s * akq
                        a[k][q] = s * akp + c * akq
                    }
                    for k in 0..<n {
                        let apk = a[p][k], aqk = a[q][k]
                        a[p][k] = c * apk - s * aqk
                        a[q][k] = s * apk + c * aqk
                    }
                    for k in 0..<n {
                        let vkp = v[k][p], vkq = v[k][q]
                        v[k][p] = c * vkp - s * vkq
                        v[k][q] = s * vkp + c * vkq
                    }
                }
            }

            // A sweep that rotated nothing has nothing left to zero. Without
            // this the loop runs its full sixty sweeps on an already-diagonal
            // matrix, which on a hundred-storey model is tens of millions of
            // pointless operations.
            if !rotated { break }
        }

        let values = (0..<n).map { a[$0][$0] }
        let vectors = (0..<n).map { column in (0..<n).map { v[$0][column] } }

        // Sort ascending by eigenvalue, so mode 1 is genuinely the first mode.
        let order = (0..<n).sorted { values[$0] < values[$1] }
        return (order.map { values[$0] }, order.map { vectors[$0] })
    }

    /// Solves the generalised problem `K·φ = ω²·M·φ`.
    ///
    /// Because M is diagonal and positive, the standard substitution
    /// `K̃ = M^(−1/2)·K·M^(−1/2)` reduces this to an ordinary symmetric
    /// eigenproblem without ever forming an inverse.
    public static func modes(of building: ShearBuilding) -> [ModeShape] {
        let n = building.degreesOfFreedom
        guard n > 0 else { return [] }

        let masses = building.storeys.map { Swift.max($0.mass, 1e-6) }
        let k = building.stiffnessMatrix

        let invSqrtM = masses.map { 1 / $0.squareRoot() }
        var reduced = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n {
                reduced[i][j] = k[i][j] * invSqrtM[i] * invSqrtM[j]
            }
        }
        // Force exact symmetry — accumulated rounding otherwise makes Jacobi
        // converge to slightly different values depending on traversal order.
        for i in 0..<n {
            for j in (i + 1)..<n {
                let mean = (reduced[i][j] + reduced[j][i]) / 2
                reduced[i][j] = mean; reduced[j][i] = mean
            }
        }

        let (values, vectors) = jacobiEigen(reduced)
        guard !values.isEmpty else { return [] }

        let totalMass = masses.reduce(0, +)
        var out: [ModeShape] = []

        for (index, eigenvalue) in values.enumerated() {
            let omegaSquared = Swift.max(eigenvalue, 0)
            let omega = omegaSquared.squareRoot()
            let frequency = omega / (2 * Double.pi)

            // Transform the eigenvector back out of the mass-normalised space.
            var shape = (0..<n).map { vectors[index][$0] * invSqrtM[$0] }

            // Sign convention: make the roof displacement positive, so mode
            // shapes do not flip arbitrarily between runs and the animation
            // stays stable.
            if let last = shape.last, last < 0 { shape = shape.map { -$0 } }

            // Mass participation ratio is independent of how the vector is
            // scaled, so it can be computed from the raw eigenvector.
            var rawNumerator = 0.0, rawDenominator = 0.0
            for i in 0..<n {
                rawNumerator += masses[i] * shape[i]
                rawDenominator += masses[i] * shape[i] * shape[i]
            }
            let effectiveMass = rawDenominator > 1e-30
                ? rawNumerator * rawNumerator / rawDenominator : 0
            let ratio = totalMass > 0 ? effectiveMass / totalMass : 0

            // Normalise the shape to a peak of 1 for display and animation.
            let peak = Stats.peakAbs(shape)
            let normalised = peak > 1e-30 ? shape.map { $0 / peak } : shape

            // Participation factor Γ = φᵀM·1 / φᵀMφ, computed against the
            // *normalised* shape.
            //
            // Γ and φ are not independent: Γ scales inversely with φ, so the
            // product Γ·φ is what is physically meaningful. Computing Γ from the
            // raw eigenvector and then applying it to the normalised one — the
            // easy mistake — leaves modal superposition wrong by whatever factor
            // the normalisation happened to be, which here is around a thousand.
            var numerator = 0.0, denominator = 0.0
            for i in 0..<n {
                numerator += masses[i] * normalised[i]
                denominator += masses[i] * normalised[i] * normalised[i]
            }
            let participation = denominator > 1e-30 ? numerator / denominator : 0

            out.append(ModeShape(number: index + 1, frequency: frequency,
                                 shape: normalised,
                                 participationFactor: participation,
                                 massParticipationRatio: ratio))
        }
        return out
    }

    public static func naturalPeriods(of building: ShearBuilding) -> [Double] {
        modes(of: building).map(\.period)
    }

    /// The first mode's period, without solving for every mode.
    ///
    /// The full eigendecomposition returns n periods and n mode shapes; this
    /// wants one number. Inverse power iteration converges on the *smallest*
    /// eigenvalue — which is the fundamental — using the LU factorisation of
    /// the stiffness matrix, so each iteration is a substitution rather than
    /// another decomposition. On a hundred-storey tower that is the difference
    /// between tens of millions of operations and tens of thousands, and the
    /// solver asks for it twice on every single run.
    public static func fundamentalPeriod(of building: ShearBuilding) -> Double {
        let n = building.degreesOfFreedom
        guard n > 0 else { return 0 }

        let masses = building.storeys.map(\.mass)
        guard masses.allSatisfy({ $0 > 0 }) else { return naturalPeriods(of: building).first ?? 0 }

        // Same substitution the full solver uses: K̃ = M^(−1/2)·K·M^(−1/2),
        // which turns the generalised problem into an ordinary symmetric one
        // without ever forming an inverse.
        let root = masses.map { $0.squareRoot() }
        let k = building.stiffnessMatrix
        var scaled = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n { scaled[i][j] = k[i][j] / (root[i] * root[j]) }
        }

        guard let factorisation = LinearAlgebra.factorise(scaled) else {
            return naturalPeriods(of: building).first ?? 0
        }

        // Iterate x ← K̃⁻¹x, normalising each time. The Rayleigh quotient of
        // the converged vector is the smallest eigenvalue, ω².
        var x = [Double](repeating: 1, count: n)
        var eigenvalue = 0.0

        for _ in 0..<100 {
            guard let next = factorisation.solve(x) else {
                return naturalPeriods(of: building).first ?? 0
            }
            let norm = next.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 1e-300, norm.isFinite else {
                return naturalPeriods(of: building).first ?? 0
            }
            let normalised = next.map { $0 / norm }

            // Rayleigh quotient xᵀK̃x, with x already unit length.
            var quotient = 0.0
            for i in 0..<n {
                var row = 0.0
                for j in 0..<n { row += scaled[i][j] * normalised[j] }
                quotient += normalised[i] * row
            }

            let converged = abs(quotient - eigenvalue) <= abs(quotient) * 1e-12
            eigenvalue = quotient
            x = normalised
            if converged { break }
        }

        guard eigenvalue > 0, eigenvalue.isFinite else {
            return naturalPeriods(of: building).first ?? 0
        }
        return 2 * Double.pi / eigenvalue.squareRoot()
    }
}

// MARK: - 41. Rayleigh damping

public enum RayleighDamping {

    /// Algorithm 41 — build a damping matrix as `C = α·M + β·K`.
    ///
    /// Real damping is not proportional to anything in particular, but a
    /// proportional model is the only kind that leaves the modes uncoupled, and
    /// uncoupled modes are what make modal superposition possible at all. The
    /// coefficients are chosen so the target damping ratio is hit exactly at two
    /// chosen frequencies — conventionally the first and a higher mode — with
    /// damping dipping slightly between them and rising outside.
    public static func coefficients(targetRatio: Double,
                                    frequency1: Double, frequency2: Double)
        -> (alpha: Double, beta: Double)
    {
        let w1 = 2 * Double.pi * Swift.max(frequency1, 1e-6)
        let w2 = 2 * Double.pi * Swift.max(frequency2, frequency1 * 1.0001 + 1e-6)
        guard w2 > w1 else { return (2 * targetRatio * w1, 0) }
        let alpha = targetRatio * 2 * w1 * w2 / (w1 + w2)
        let beta = targetRatio * 2 / (w1 + w2)
        return (alpha, beta)
    }

    public static func matrix(for building: ShearBuilding,
                              modes: [ModeShape]? = nil) -> [[Double]] {
        let n = building.degreesOfFreedom
        let computed = modes ?? ModalAnalysis.modes(of: building)
        let f1 = computed.first?.frequency ?? 1
        // Anchor the second point at whichever higher mode actually carries
        // meaningful mass, falling back to three times the first frequency.
        let f2 = computed.dropFirst().first(where: { $0.massParticipationRatio > 0.02 })?.frequency
            ?? (f1 * 3)

        let (alpha, beta) = coefficients(targetRatio: building.damping,
                                         frequency1: f1, frequency2: f2)
        let m = building.massMatrix
        let k = building.stiffnessMatrix

        var c = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n { c[i][j] = alpha * m[i][j] + beta * k[i][j] }
        }
        return c
    }

    /// The damping ratio this model actually delivers at a given frequency —
    /// worth showing, because it is not flat and people assume it is.
    public static func effectiveRatio(alpha: Double, beta: Double, frequency: Double) -> Double {
        let w = 2 * Double.pi * Swift.max(frequency, 1e-9)
        return alpha / (2 * w) + beta * w / 2
    }
}

// MARK: - 45. Drift and damage states

public enum DamageState: Int, Codable, Sendable, CaseIterable, Comparable, Identifiable {
    case none = 0, slight, moderate, extensive, complete
    public var id: Int { rawValue }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .none: "No damage"
        case .slight: "Slight"
        case .moderate: "Moderate"
        case .extensive: "Extensive"
        case .complete: "Complete"
        }
    }

    public var description: String {
        switch self {
        case .none: "Nothing beyond what the structure is designed to take."
        case .slight: "Hairline cracking in finishes. No loss of strength."
        case .moderate: "Visible cracking in structural elements. Some loss of stiffness, repairable."
        case .extensive: "Major cracking, permanent deformation. The frame has lost significant capacity."
        case .complete: "Collapse or imminent collapse. The structure can no longer be relied on."
        }
    }

    /// Distinct glyph as well as colour, so the state survives colour blindness.
    public var systemImage: String {
        switch self {
        case .none: "checkmark"
        case .slight: "minus"
        case .moderate: "exclamationmark"
        case .extensive: "exclamationmark.2"
        case .complete: "xmark"
        }
    }
}

/// Drift thresholds, as a fraction of storey height.
///
/// These are the numbers engineers actually reason with: 0.5% is where finishes
/// start to crack, 1% is meaningful structural damage, 2% is severe, and beyond
/// about 4% a conventional frame is generally beyond saving. They vary by
/// structural type, which is why they are a table rather than a constant.
public struct DriftThresholds: Sendable, Equatable, Codable {
    public var slight: Double
    public var moderate: Double
    public var extensive: Double
    public var complete: Double

    public init(slight: Double, moderate: Double, extensive: Double, complete: Double) {
        self.slight = slight; self.moderate = moderate
        self.extensive = extensive; self.complete = complete
    }

    public static func forSystem(_ system: StructuralSystem,
                                 material: ConstructionMaterial) -> DriftThresholds {
        switch (system, material) {
        case (.momentFrame, .steel):
            // Steel frames are ductile: they bend a long way before they break.
            return DriftThresholds(slight: 0.006, moderate: 0.012, extensive: 0.030, complete: 0.060)
        case (.momentFrame, _):
            return DriftThresholds(slight: 0.005, moderate: 0.010, extensive: 0.020, complete: 0.040)
        case (.shearWall, _), (.bearingWall, _):
            // Walls are stiff and brittle: they crack at much smaller drifts.
            return DriftThresholds(slight: 0.002, moderate: 0.005, extensive: 0.010, complete: 0.020)
        case (.bracedFrame, _):
            return DriftThresholds(slight: 0.004, moderate: 0.008, extensive: 0.016, complete: 0.030)
        case (.baseIsolated, _):
            // The superstructure barely deforms; the isolators take it.
            return DriftThresholds(slight: 0.004, moderate: 0.008, extensive: 0.015, complete: 0.030)
        case (.softStorey, _):
            // Everything concentrates in one storey, so the building fails at a
            // much smaller *average* drift than the numbers suggest.
            return DriftThresholds(slight: 0.003, moderate: 0.006, extensive: 0.012, complete: 0.022)
        case (_, .unreinforcedMasonry):
            return DriftThresholds(slight: 0.001, moderate: 0.003, extensive: 0.006, complete: 0.012)
        default:
            return DriftThresholds(slight: 0.004, moderate: 0.008, extensive: 0.016, complete: 0.032)
        }
    }

    public func state(for drift: Double) -> DamageState {
        let d = abs(drift)
        if d >= complete { return .complete }
        if d >= extensive { return .extensive }
        if d >= moderate { return .moderate }
        if d >= slight { return .slight }
        return .none
    }

    public var asArray: [Double] { [slight, moderate, extensive, complete] }
}

/// Per-storey result of a simulation run.
public struct StoreyResult: Sendable, Equatable, Identifiable {
    public var id: Int { storey }
    public var storey: Int
    /// Peak interstorey drift as a fraction of storey height.
    public var peakDrift: Double
    public var peakDisplacement: Double
    public var peakAcceleration: Double
    public var damageState: DamageState
    /// Fraction of original stiffness remaining after the run.
    public var stiffnessRemaining: Double
    public var timeOfPeak: Double

    public var driftPercent: Double { peakDrift * 100 }

    public init(storey: Int, peakDrift: Double, peakDisplacement: Double,
                peakAcceleration: Double, damageState: DamageState,
                stiffnessRemaining: Double, timeOfPeak: Double) {
        self.storey = storey; self.peakDrift = peakDrift
        self.peakDisplacement = peakDisplacement
        self.peakAcceleration = peakAcceleration
        self.damageState = damageState
        self.stiffnessRemaining = stiffnessRemaining
        self.timeOfPeak = timeOfPeak
    }
}

// MARK: - 42, 43, 44. Time integration

/// The full result of shaking a building.
public struct SimulationResult: Sendable {
    /// Relative displacement of each floor, `displacement[timeStep][floor]`.
    public var displacement: [[Double]]
    /// Interstorey drift ratio, same indexing.
    public var drift: [[Double]]
    /// Absolute acceleration of each floor.
    public var acceleration: [[Double]]
    public var times: [Double]
    public var storeyResults: [StoreyResult]
    public var roofDisplacement: Waveform
    public var roofAcceleration: Waveform
    public var baseShear: Waveform
    public var groundMotion: Waveform

    /// Period at the start and end of the run. When damage occurs these differ,
    /// and that difference *is* the product's core claim, produced here from
    /// first principles rather than asserted.
    public var initialPeriod: Double
    public var finalPeriod: Double
    public var maximumDrift: Double
    public var worstStorey: Int
    public var overallDamageState: DamageState
    public var collapsed: Bool

    public var periodChangePercent: Double {
        guard initialPeriod > 0 else { return 0 }
        return (finalPeriod - initialPeriod) / initialPeriod * 100
    }

    public var stepCount: Int { times.count }
}

public enum StructuralSolver {

    public struct Options: Sendable, Equatable {
        /// Allow the model to soften as it is damaged (algorithm 44).
        public var allowDegradation: Bool
        /// Newmark parameters. β = 1/4, γ = 1/2 is the average-acceleration
        /// scheme: unconditionally stable and free of numerical damping.
        public var beta: Double
        public var gamma: Double
        /// Store the full response history rather than just the peaks. The
        /// animation needs it; a batch comparison of fifty buildings does not.
        public var keepHistory: Bool
        /// Cap on stored steps, so a ten-minute record at 200 Hz does not
        /// allocate gigabytes for an animation running at 60 fps.
        public var maximumStoredSteps: Int

        public init(allowDegradation: Bool = true, beta: Double = 0.25, gamma: Double = 0.5,
                    keepHistory: Bool = true, maximumStoredSteps: Int = 6000) {
            self.allowDegradation = allowDegradation
            self.beta = beta; self.gamma = gamma
            self.keepHistory = keepHistory
            self.maximumStoredSteps = Swift.max(maximumStoredSteps, 100)
        }

        public static let standard = Options()
        public static let fast = Options(allowDegradation: false, keepHistory: false)
    }

    /// Algorithm 42 — Newmark-beta time integration of the full
    /// multi-degree-of-freedom system, with algorithm 44 folded in.
    ///
    /// At each step the effective stiffness matrix is solved for the new
    /// displacement. When degradation is enabled, any storey whose drift exceeds
    /// a damage threshold permanently loses stiffness — so the building's period
    /// lengthens *during* the run, exactly as a real structure's does, and every
    /// subsequent step sees the softened structure. This is what makes the
    /// simulation's damaged-period prediction comparable with a real
    /// measurement, rather than an unrelated number.
    public static func run(_ building: ShearBuilding,
                           groundAcceleration: Waveform,
                           thresholds: DriftThresholds,
                           options: Options = .standard) -> SimulationResult {
        let n = building.degreesOfFreedom
        guard n > 0, groundAcceleration.count > 1 else {
            return emptyResult(building: building, groundMotion: groundAcceleration)
        }

        var working = building
        let originalStiffness = building.storeys.map(\.stiffness)
        let initialModes = ModalAnalysis.modes(of: building)
        let initialPeriod = initialModes.first?.period ?? 0

        let dt = groundAcceleration.dt
        let masses = working.storeys.map { Swift.max($0.mass, 1e-6) }
        let m = working.massMatrix
        var k = working.stiffnessMatrix
        var c = RayleighDamping.matrix(for: working, modes: initialModes)

        let beta = options.beta, gamma = options.gamma
        let a0 = 1 / (beta * dt * dt), a1 = gamma / (beta * dt)
        let a2 = 1 / (beta * dt), a3 = 1 / (2 * beta) - 1
        let a4 = gamma / beta - 1, a5 = dt / 2 * (gamma / beta - 2)

        var u = [Double](repeating: 0, count: n)
        var v = [Double](repeating: 0, count: n)
        var a = [Double](repeating: 0, count: n)

        var peakDrift = [Double](repeating: 0, count: n)
        var peakDisplacement = [Double](repeating: 0, count: n)
        var peakAcceleration = [Double](repeating: 0, count: n)
        var peakTime = [Double](repeating: 0, count: n)
        var stiffnessFactor = [Double](repeating: 1, count: n)

        let heights = working.storeys.map { Swift.max($0.height, 0.1) }
        let steps = groundAcceleration.count

        // Only store every `stride`-th step, so a long record still animates.
        let stride = Swift.max(steps / options.maximumStoredSteps, 1)
        var displacementHistory: [[Double]] = []
        var driftHistory: [[Double]] = []
        var accelerationHistory: [[Double]] = []
        var times: [Double] = []
        var roofDisplacement: [Double] = []
        var roofAcceleration: [Double] = []
        var baseShear: [Double] = []
        if options.keepHistory {
            let reserve = steps / stride + 2
            displacementHistory.reserveCapacity(reserve)
            driftHistory.reserveCapacity(reserve)
            accelerationHistory.reserveCapacity(reserve)
            times.reserveCapacity(reserve)
        }
        roofDisplacement.reserveCapacity(steps / stride + 2)
        roofAcceleration.reserveCapacity(steps / stride + 2)
        baseShear.reserveCapacity(steps / stride + 2)

        var effective = effectiveStiffness(k: k, m: m, c: c, a0: a0, a1: a1)
        var factorisation = LinearAlgebra.factorise(effective)
        var needsRebuild = false
        var collapsed = false

        for step in 0..<steps {
            let ag = groundAcceleration.samples[step]

            if step == 0 {
                // Initial acceleration from equilibrium at t = 0.
                for i in 0..<n { a[i] = -ag }
            } else {
                if needsRebuild {
                    k = working.stiffnessMatrix
                    c = RayleighDamping.matrix(for: working)
                    effective = effectiveStiffness(k: k, m: m, c: c, a0: a0, a1: a1)
                    // Factorised here and reused for every step until the
                    // structure degrades, rather than being eliminated afresh
                    // thousands of times for a matrix that has not changed.
                    factorisation = LinearAlgebra.factorise(effective)
                    needsRebuild = false
                }

                // Effective load: the earthquake enters as an inertial force
                // −M·1·a_g, which is why a heavy building is not automatically
                // a safe one.
                var load = [Double](repeating: 0, count: n)
                for i in 0..<n {
                    load[i] = -masses[i] * ag
                        + masses[i] * (a0 * u[i] + a2 * v[i] + a3 * a[i])
                    var damping = 0.0
                    for j in 0..<n {
                        damping += c[i][j] * (a1 * u[j] + a4 * v[j] + a5 * a[j])
                    }
                    load[i] += damping
                }

                guard let factorisation, let uNext = factorisation.solve(load) else { break }
                var aNext = [Double](repeating: 0, count: n)
                var vNext = [Double](repeating: 0, count: n)
                for i in 0..<n {
                    aNext[i] = a0 * (uNext[i] - u[i]) - a2 * v[i] - a3 * a[i]
                    vNext[i] = v[i] + dt * ((1 - gamma) * a[i] + gamma * aNext[i])
                }
                u = uNext; v = vNext; a = aNext
            }

            // Drift and peak tracking.
            var drifts = [Double](repeating: 0, count: n)
            let time = groundAcceleration.time(at: step)
            for i in 0..<n {
                let below = i == 0 ? 0 : u[i - 1]
                let relative = u[i] - below
                let driftRatio = relative / heights[i]
                drifts[i] = driftRatio

                if abs(driftRatio) > abs(peakDrift[i]) {
                    peakDrift[i] = driftRatio
                    peakTime[i] = time
                }
                peakDisplacement[i] = Swift.max(peakDisplacement[i], abs(u[i]))
                peakAcceleration[i] = Swift.max(peakAcceleration[i], abs(a[i] + ag))

                // Algorithm 44 — hysteretic stiffness degradation.
                //
                // Once a storey has been pushed past a damage threshold it never
                // recovers: the stiffness is reduced permanently, and softening
                // makes it more likely to be pushed further next cycle. That
                // ratcheting is the physical mechanism behind progressive
                // collapse, and modelling it is what separates this from a
                // linear toy.
                if options.allowDegradation {
                    let state = thresholds.state(for: driftRatio)
                    let targetFactor: Double = switch state {
                    case .none: 1.0
                    case .slight: 0.92
                    case .moderate: 0.72
                    case .extensive: 0.42
                    case .complete: 0.15
                    }
                    if targetFactor < stiffnessFactor[i] - 1e-9 {
                        stiffnessFactor[i] = targetFactor
                        working.storeys[i].stiffness = originalStiffness[i] * targetFactor
                        needsRebuild = true
                        if state == .complete { collapsed = true }
                    }
                }
            }

            if step % stride == 0 {
                times.append(time)
                roofDisplacement.append(u[n - 1])
                roofAcceleration.append(a[n - 1] + ag)
                // Base shear: the force the foundation has to resist.
                var shear = 0.0
                for i in 0..<n { shear += masses[i] * (a[i] + ag) }
                baseShear.append(shear)

                if options.keepHistory {
                    displacementHistory.append(u)
                    driftHistory.append(drifts)
                    accelerationHistory.append((0..<n).map { a[$0] + ag })
                }
            }
        }

        let finalPeriod = ModalAnalysis.fundamentalPeriod(of: working)

        var results: [StoreyResult] = []
        for i in 0..<n {
            results.append(StoreyResult(
                storey: i + 1,
                peakDrift: abs(peakDrift[i]),
                peakDisplacement: peakDisplacement[i],
                peakAcceleration: peakAcceleration[i],
                damageState: thresholds.state(for: peakDrift[i]),
                stiffnessRemaining: stiffnessFactor[i],
                timeOfPeak: peakTime[i]))
        }

        let worst = results.max { $0.peakDrift < $1.peakDrift }
        let sampleRate = groundAcceleration.sampleRate / Double(stride)

        return SimulationResult(
            displacement: displacementHistory,
            drift: driftHistory,
            acceleration: accelerationHistory,
            times: times,
            storeyResults: results,
            roofDisplacement: Waveform(samples: roofDisplacement, sampleRate: sampleRate,
                                       startTime: groundAcceleration.startTime,
                                       unit: .displacement),
            roofAcceleration: Waveform(samples: roofAcceleration, sampleRate: sampleRate,
                                       startTime: groundAcceleration.startTime,
                                       unit: .acceleration),
            baseShear: Waveform(samples: baseShear, sampleRate: sampleRate,
                                startTime: groundAcceleration.startTime,
                                unit: .dimensionless),
            groundMotion: groundAcceleration,
            initialPeriod: initialPeriod,
            finalPeriod: finalPeriod,
            maximumDrift: worst?.peakDrift ?? 0,
            worstStorey: worst?.storey ?? 1,
            overallDamageState: results.map(\.damageState).max() ?? .none,
            collapsed: collapsed)
    }

    private static func effectiveStiffness(k: [[Double]], m: [[Double]], c: [[Double]],
                                           a0: Double, a1: Double) -> [[Double]] {
        let n = k.count
        var out = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n { out[i][j] = k[i][j] + a0 * m[i][j] + a1 * c[i][j] }
        }
        return out
    }

    private static func emptyResult(building: ShearBuilding,
                                    groundMotion: Waveform) -> SimulationResult {
        let period = ModalAnalysis.modes(of: building).first?.period ?? 0
        let empty = Waveform(samples: [], sampleRate: Swift.max(groundMotion.sampleRate, 1))
        return SimulationResult(
            displacement: [], drift: [], acceleration: [], times: [], storeyResults: [],
            roofDisplacement: empty, roofAcceleration: empty, baseShear: empty,
            groundMotion: groundMotion,
            initialPeriod: period, finalPeriod: period, maximumDrift: 0,
            worstStorey: 1, overallDamageState: .none, collapsed: false)
    }

    /// Algorithm 43 — modal superposition.
    ///
    /// Instead of integrating the coupled system, project the load onto each
    /// mode, run that mode as an independent single-degree-of-freedom
    /// oscillator, and add the results back up. Two or three modes usually
    /// capture over 90% of the response, so this is far faster than the full
    /// integration — which is what makes live scrubbing and side-by-side
    /// comparison of two buildings possible.
    ///
    /// It is strictly linear: no degradation, no damage. That is the trade, and
    /// the UI says which path produced a given number.
    public static func modalSuperposition(_ building: ShearBuilding,
                                          groundAcceleration: Waveform,
                                          thresholds: DriftThresholds,
                                          modeCount: Int = 3) -> SimulationResult {
        let n = building.degreesOfFreedom
        let modes = ModalAnalysis.modes(of: building)
        guard n > 0, !modes.isEmpty, groundAcceleration.count > 1 else {
            return emptyResult(building: building, groundMotion: groundAcceleration)
        }

        let used = Array(modes.prefix(Swift.max(modeCount, 1)))
        let heights = building.storeys.map { Swift.max($0.height, 0.1) }
        let masses = building.storeys.map { Swift.max($0.mass, 1e-6) }

        // Each mode's generalised coordinate over time.
        var modalHistories: [[Double]] = []
        for mode in used {
            let response = ResponseSpectrumAnalysis.sdofResponse(
                acceleration: groundAcceleration, period: mode.period,
                damping: building.damping, keepHistory: true)
            modalHistories.append(response.displacement)
        }

        let steps = modalHistories.map(\.count).min() ?? 0
        guard steps > 1 else { return emptyResult(building: building, groundMotion: groundAcceleration) }

        var peakDrift = [Double](repeating: 0, count: n)
        var peakDisplacement = [Double](repeating: 0, count: n)
        var peakTime = [Double](repeating: 0, count: n)
        var displacementHistory: [[Double]] = []
        var driftHistory: [[Double]] = []
        var times: [Double] = []
        var roof: [Double] = []

        for step in 0..<steps {
            var u = [Double](repeating: 0, count: n)
            for (index, mode) in used.enumerated() {
                // Un-normalise: the shape stored for display has peak 1, but the
                // participation factor was computed on the raw vector.
                let q = modalHistories[index][step] * mode.participationFactor
                for i in 0..<n { u[i] += q * mode.shape[i] }
            }

            var drifts = [Double](repeating: 0, count: n)
            let time = groundAcceleration.time(at: step)
            for i in 0..<n {
                let below = i == 0 ? 0 : u[i - 1]
                drifts[i] = (u[i] - below) / heights[i]
                if abs(drifts[i]) > abs(peakDrift[i]) {
                    peakDrift[i] = drifts[i]; peakTime[i] = time
                }
                peakDisplacement[i] = Swift.max(peakDisplacement[i], abs(u[i]))
            }

            displacementHistory.append(u)
            driftHistory.append(drifts)
            times.append(time)
            roof.append(u[n - 1])
        }

        let results = (0..<n).map { i in
            StoreyResult(storey: i + 1, peakDrift: abs(peakDrift[i]),
                         peakDisplacement: peakDisplacement[i],
                         peakAcceleration: 0,
                         damageState: thresholds.state(for: peakDrift[i]),
                         stiffnessRemaining: 1, timeOfPeak: peakTime[i])
        }
        let worst = results.max { $0.peakDrift < $1.peakDrift }
        let period = used.first?.period ?? 0
        _ = masses

        return SimulationResult(
            displacement: displacementHistory, drift: driftHistory, acceleration: [],
            times: times, storeyResults: results,
            roofDisplacement: Waveform(samples: roof, sampleRate: groundAcceleration.sampleRate,
                                       startTime: groundAcceleration.startTime, unit: .displacement),
            roofAcceleration: Waveform(samples: [], sampleRate: groundAcceleration.sampleRate),
            baseShear: Waveform(samples: [], sampleRate: groundAcceleration.sampleRate),
            groundMotion: groundAcceleration,
            initialPeriod: period, finalPeriod: period,
            maximumDrift: worst?.peakDrift ?? 0, worstStorey: worst?.storey ?? 1,
            overallDamageState: results.map(\.damageState).max() ?? .none,
            collapsed: false)
    }
}

// MARK: - Resonance sweep

public enum ResonanceSweep {

    public struct Point: Sendable, Equatable, Identifiable {
        public var id: Double { frequency }
        public var frequency: Double
        public var amplification: Double
        public var roofDisplacement: Double
    }

    /// Drives the building at a range of frequencies and records how much it
    /// amplifies each one.
    ///
    /// The resulting curve, with its dramatic spike where the driving frequency
    /// meets the building's own, is the single most persuasive demonstration in
    /// the app — and it is also exactly what the physical shake table produces,
    /// so measured and predicted curves can be laid over one another.
    public static func sweep(_ building: ShearBuilding,
                             frequencies: [Double]? = nil,
                             amplitude: Double = 0.5,
                             cyclesPerFrequency: Double = 12,
                             sampleRate: Double = 100) -> [Point] {
        let period = ModalAnalysis.fundamentalPeriod(of: building)
        guard period > 0 else { return [] }
        let natural = 1 / period

        let list = frequencies ?? (0..<60).map { i in
            // Sweep from a fifth to three times the natural frequency, spaced
            // logarithmically so the peak is well sampled.
            natural * pow(15.0, Double(i) / 59.0 - 0.7)
        }

        let thresholds = DriftThresholds(slight: .infinity, moderate: .infinity,
                                         extensive: .infinity, complete: .infinity)

        return list.compactMap { frequency -> Point? in
            guard frequency > 0.01, frequency < sampleRate / 4 else { return nil }
            let seconds = Swift.max(cyclesPerFrequency / frequency, 4)

            // The dwell has to be long in *cycles* to reach steady state, which
            // at a tenth of a hertz is two minutes of simulated time. Sampling
            // that at a fixed 100 Hz spends twelve thousand steps resolving a
            // wave that changes twenty times a second at most. The rate instead
            // follows whichever is faster — the drive or the building's own
            // motion — with plenty of margin over Nyquist.
            let fastest = Swift.max(frequency, natural)
            let stepRate = Swift.min(Swift.max(20 * fastest, 20), sampleRate)

            let drive = SyntheticMotion.sine(frequency: frequency, seconds: seconds,
                                             sampleRate: stepRate, amplitude: amplitude)
            // Degradation off: a sweep is a probe, not an event, and letting it
            // damage the model would make each point depend on the last.
            let result = StructuralSolver.run(building, groundAcceleration: drive,
                                              thresholds: thresholds,
                                              options: .sweepOptions)
            let roofPeak = result.roofDisplacement.peakAbsolute
            // Amplification relative to the ground displacement at this frequency.
            let omega = 2 * Double.pi * frequency
            let groundDisplacement = amplitude / (omega * omega)
            let amplification = groundDisplacement > 1e-12 ? roofPeak / groundDisplacement : 0
            return Point(frequency: frequency, amplification: amplification,
                         roofDisplacement: roofPeak)
        }
    }
}

extension StructuralSolver.Options {
    static let sweepOptions = StructuralSolver.Options(
        allowDegradation: false, keepHistory: false, maximumStoredSteps: 200)
}
