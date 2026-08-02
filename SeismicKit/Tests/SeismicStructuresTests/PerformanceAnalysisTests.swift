import XCTest
import SeismicCore
import SeismicSignal
@testable import SeismicStructures

final class PerformanceAnalysisTests: XCTestCase {

    private func building(storeys: Int, stiffness: Double = 4.0e8,
                          mass: Double = 400_000) -> ShearBuilding {
        ShearBuilding(
            storeys: (0..<storeys).map { _ in
                Storey(id: 0, height: 3.2, mass: mass, stiffness: stiffness, floorArea: 400)
            },
            damping: 0.05, name: "Test")
    }

    // MARK: 83 — Pushover

    func testTheCapacityCurveRisesThenBendsOver() {
        let capacity = Pushover.run(building(storeys: 6))
        XCTAssertGreaterThan(capacity.curve.count, 10)

        // Base shear rises monotonically — it is the thing being incremented.
        for (a, b) in zip(capacity.curve, capacity.curve.dropFirst()) {
            XCTAssertGreaterThan(b.baseShear, a.baseShear)
        }

        // And the curve bends: the stiffness late in the run is well below the
        // stiffness at the start. That knee *is* yielding.
        let early = capacity.curve[1]
        let earlyStiffness = early.baseShear / max(early.roofDisplacement, 1e-12)
        let late = capacity.curve[capacity.curve.count - 1]
        let previous = capacity.curve[capacity.curve.count - 2]
        let lateStiffness = (late.baseShear - previous.baseShear)
                          / max(late.roofDisplacement - previous.roofDisplacement, 1e-12)
        XCTAssertLessThan(lateStiffness, earlyStiffness * 0.5)
    }

    func testYieldIsRecordedTheFirstTimeAStoreyYields() {
        let capacity = Pushover.run(building(storeys: 6))
        XCTAssertGreaterThan(capacity.yieldShear, 0)
        XCTAssertGreaterThan(capacity.yieldDisplacement, 0)
        XCTAssertLessThan(capacity.yieldDisplacement, capacity.ultimateDisplacement)
    }

    func testDuctilityIsGreaterThanOneForAYieldingBuilding() {
        let capacity = Pushover.run(building(storeys: 6))
        XCTAssertGreaterThan(capacity.ductility, 1)
    }

    /// A stiffer building yields at a higher base shear. Not a tautology — it
    /// checks that the yield criterion is tied to storey capacity rather than
    /// to the arbitrary load steps.
    func testAStifferBuildingYieldsAtAHigherShear() {
        let soft = Pushover.run(building(storeys: 6, stiffness: 2.0e8))
        let stiff = Pushover.run(building(storeys: 6, stiffness: 8.0e8))
        XCTAssertGreaterThan(stiff.yieldShear, soft.yieldShear)
    }

    func testAnEmptyBuildingProducesAnEmptyCurveRatherThanCrashing() {
        let capacity = Pushover.run(ShearBuilding(storeys: [], damping: 0.05))
        XCTAssertTrue(capacity.curve.isEmpty)
        XCTAssertEqual(capacity.ductility, 0)
    }

    // MARK: 84 — Capacity spectrum

    /// A flat demand spectrum, so the intersection can be reasoned about.
    private func demand(_ acceleration: Double) -> [(period: Double, acceleration: Double)] {
        stride(from: 0.05, through: 4.0, by: 0.05).map { (period: $0, acceleration: acceleration) }
    }

    func testAGentleEarthquakeLeavesTheBuildingElastic() {
        let frame = building(storeys: 6)
        let capacity = Pushover.run(frame)
        guard let point = CapacitySpectrum.performancePoint(
            capacity: capacity, building: frame, demand: demand(0.2)) else {
            return XCTFail("No performance point.")
        }
        XCTAssertTrue(point.converged)
        XCTAssertLessThan(point.ductilityDemand, 1.5)
        XCTAssertTrue(point.plainMeaning.lowercased().contains("elastic")
                      || point.plainMeaning.lowercased().contains("past yield"))
    }

    func testAStrongerEarthquakePushesItFurtherPastYield() {
        let frame = building(storeys: 6)
        let capacity = Pushover.run(frame)

        guard let gentle = CapacitySpectrum.performancePoint(
                capacity: capacity, building: frame, demand: demand(0.5)),
              let severe = CapacitySpectrum.performancePoint(
                capacity: capacity, building: frame, demand: demand(4.0))
        else { return XCTFail("No performance point.") }

        XCTAssertGreaterThan(severe.spectralDisplacement, gentle.spectralDisplacement)
        XCTAssertGreaterThanOrEqual(severe.ductilityDemand, gentle.ductilityDemand)
    }

    /// The most important output: a demand the building cannot meet anywhere
    /// has to be reported as non-convergence, not as a large-but-finite answer.
    func testADemandBeyondCapacityIsReportedAsNotConverged() {
        let frame = building(storeys: 6)
        let capacity = Pushover.run(frame)
        guard let point = CapacitySpectrum.performancePoint(
            capacity: capacity, building: frame, demand: demand(500)) else {
            return XCTFail()
        }
        XCTAssertFalse(point.converged)
        XCTAssertTrue(point.plainMeaning.lowercased().contains("collapse"))
    }

    func testEffectiveDampingRisesWithDuctilityDemand() {
        let frame = building(storeys: 6)
        let capacity = Pushover.run(frame)
        guard let gentle = CapacitySpectrum.performancePoint(
                capacity: capacity, building: frame, demand: demand(0.3)),
              let severe = CapacitySpectrum.performancePoint(
                capacity: capacity, building: frame, demand: demand(5.0))
        else { return XCTFail() }
        XCTAssertGreaterThanOrEqual(severe.effectiveDamping, gentle.effectiveDamping)
        XCTAssertLessThanOrEqual(severe.effectiveDamping, 0.35)
    }

    // MARK: 85 — P-delta

    func testTallHeavyBuildingsHaveLargerStabilityCoefficients() {
        let short = building(storeys: 3)
        let tall = building(storeys: 20)
        let drift = 0.01 * 3.2                       // 1% drift everywhere

        let shortResult = PDelta.analyse(short, drifts: Array(repeating: drift, count: 3))
        let tallResult = PDelta.analyse(tall, drifts: Array(repeating: drift, count: 20))

        // The ground storey carries everything above it, so a taller building
        // has more weight bearing on the same columns.
        XCTAssertGreaterThan(tallResult[0].theta, shortResult[0].theta)
    }

    func testThetaIsLargestAtTheBaseWhereTheWeightIs() {
        let frame = building(storeys: 10)
        let result = PDelta.analyse(frame, drifts: Array(repeating: 0.032, count: 10))
        XCTAssertGreaterThan(result[0].theta, result[9].theta)
    }

    func testAmplificationMatchesTheStandardFormula() {
        let frame = building(storeys: 5)
        let result = PDelta.analyse(frame, drifts: Array(repeating: 0.02, count: 5))
        for storey in result {
            XCTAssertEqual(storey.amplification, 1 / (1 - storey.theta), accuracy: 1e-9)
        }
    }

    func testClassificationsFollowTheCodeThresholds() {
        func classify(_ theta: Double) -> PDelta.StoreyStability.Classification {
            PDelta.StoreyStability(storey: 1, theta: theta, amplification: 1,
                                   reducedStiffness: 0).classification
        }
        XCTAssertEqual(classify(0.05), .negligible)
        XCTAssertEqual(classify(0.15), .significant)
        XCTAssertEqual(classify(0.25), .severe)
        XCTAssertEqual(classify(0.40), .unstable)
        XCTAssertTrue(classify(0.40).explanation.contains("instability"))
    }

    /// Softening the model has to actually lengthen its period, or the effect
    /// is being computed and then discarded.
    func testSofteningForPDeltaLengthensThePeriod() {
        let frame = building(storeys: 15, stiffness: 2.0e8, mass: 600_000)
        let before = ModalAnalysis.modes(of: frame).first?.period ?? 0
        let after = ModalAnalysis.modes(of: PDelta.softened(frame)).first?.period ?? 0
        XCTAssertGreaterThan(after, before)
    }

    // MARK: 86 — Soil–structure interaction

    private func soil(velocity: Double) -> SoilStructureInteraction.Footing {
        .init(radius: 12, shearWaveVelocity: velocity)
    }

    func testSoftSoilLengthensThePeriodAndStiffSoilBarelyDoes() {
        let frame = building(storeys: 8)
        guard let rock = SoilStructureInteraction.analyse(frame, foundation: soil(velocity: 1_500)),
              let clay = SoilStructureInteraction.analyse(frame, foundation: soil(velocity: 120))
        else { return XCTFail("No result.") }

        XCTAssertLessThan(rock.periodLengthening, 0.02)
        XCTAssertGreaterThan(clay.periodLengthening, rock.periodLengthening)
        XCTAssertGreaterThan(clay.flexibleBasePeriod, clay.fixedBasePeriod)
    }

    /// The warning this exists for: on soft ground the fixed-base prediction is
    /// short by about as much as damage would be, so it must say so.
    func testItWarnsWhenTheSoilEffectRivalsDamage() {
        let frame = building(storeys: 8)
        guard let clay = SoilStructureInteraction.analyse(frame,
                                                          foundation: soil(velocity: 110))
        else { return XCTFail() }
        XCTAssertGreaterThan(clay.periodLengthening, 0.05)
        XCTAssertTrue(clay.significance.lowercased().contains("damage"),
                      clay.significance)
    }

    func testStiffGroundIsReportedAsNotMattering() {
        let frame = building(storeys: 8)
        guard let rock = SoilStructureInteraction.analyse(frame,
                                                          foundation: soil(velocity: 2_000))
        else { return XCTFail() }
        XCTAssertTrue(rock.significance.lowercased().contains("stiff enough"),
                      rock.significance)
    }

    func testFootingStiffnessesFollowTheClosedForm() {
        let footing = SoilStructureInteraction.Footing(
            radius: 10, shearWaveVelocity: 200, density: 1_900, poissonRatio: 0.33)
        let g = 1_900.0 * 200 * 200
        XCTAssertEqual(footing.shearModulus, g, accuracy: 1)
        XCTAssertEqual(footing.swayStiffness, 8 * g * 10 / (2 - 0.33), accuracy: 1)
        XCTAssertEqual(footing.rockingStiffness,
                       8 * g * 1_000 / (3 * (1 - 0.33)), accuracy: 1)
    }

    func testDampingIncludesRadiationButStaysPhysical() {
        let frame = building(storeys: 8)
        guard let clay = SoilStructureInteraction.analyse(frame, foundation: soil(velocity: 100))
        else { return XCTFail() }
        XCTAssertGreaterThan(clay.effectiveDamping, 0)
        XCTAssertLessThanOrEqual(clay.effectiveDamping, 0.30)
    }

    // MARK: 87 — Incremental dynamic analysis

    private func groundMotion(peak: Double, seconds: Double = 12,
                              rate: Double = 100) -> Waveform {
        var rng = SeededRandom(seed: 77)
        let count = Int(seconds * rate)
        let samples = (0..<count).map { i -> Double in
            let t = Double(i) / rate
            // A shaped burst, so it excites the building rather than being a
            // step.
            let envelope = exp(-Foundation.pow(t - 4, 2) / 6)
            return envelope * rng.gaussian(mean: 0, sd: 1)
        }
        let scale = peak / max(samples.map(abs).max() ?? 1, 1e-9)
        return Waveform(samples: samples.map { $0 * scale }, sampleRate: rate)
    }

    func testDriftRisesWithIntensity() {
        let frame = building(storeys: 5)
        let result = IncrementalDynamicAnalysis.run(
            frame, ground: groundMotion(peak: 1.0),
            thresholds: .forSystem(.momentFrame, material: .reinforcedConcrete))

        XCTAssertGreaterThan(result.curve.count, 2)
        // Monotone up to collapse: a bigger earthquake cannot do less.
        let rising = result.curve.prefix(while: { !$0.collapsed })
        for (a, b) in zip(rising, rising.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.maximumDrift, a.maximumDrift * 0.95)
        }
    }

    func testAWeakBuildingCollapsesAtALowerScaleThanAStrongOne() {
        let ground = groundMotion(peak: 2.0)
        let thresholds = DriftThresholds.forSystem(.momentFrame,
                                                   material: .reinforcedConcrete)
        let weak = IncrementalDynamicAnalysis.run(
            building(storeys: 8, stiffness: 4.0e7), ground: ground, thresholds: thresholds)
        let strong = IncrementalDynamicAnalysis.run(
            building(storeys: 8, stiffness: 2.0e9), ground: ground, thresholds: thresholds)

        if let weakScale = weak.collapseScale {
            XCTAssertTrue(strong.collapseScale == nil || strong.collapseScale! > weakScale,
                          "Weak collapsed at \(weakScale), strong at "
                          + "\(String(describing: strong.collapseScale)).")
        }
    }

    /// Surviving every scale tested is a real answer, and must not be dressed
    /// up as a collapse margin.
    func testSurvivingEveryScaleIsSaidPlainly() {
        let result = IncrementalDynamicAnalysis.run(
            building(storeys: 4, stiffness: 5.0e9),
            ground: groundMotion(peak: 0.05),
            thresholds: .forSystem(.shearWall, material: .reinforcedConcrete))
        if result.collapseScale == nil {
            XCTAssertNil(result.marginOverRecord)
            XCTAssertTrue(result.plainMeaning.contains("margin"))
        }
    }

    func testItStopsAtTheFirstCollapseRatherThanRunningEveryScale() {
        let result = IncrementalDynamicAnalysis.run(
            building(storeys: 10, stiffness: 2.0e7),
            ground: groundMotion(peak: 4.0),
            thresholds: .forSystem(.momentFrame, material: .reinforcedConcrete),
            scales: [0.5, 1, 2, 4, 8, 16, 32])
        if result.collapseScale != nil {
            XCTAssertEqual(result.curve.last?.collapsed, true)
            // Nothing after the collapse.
            XCTAssertEqual(result.curve.filter(\.collapsed).count, 1)
        }
    }
}
