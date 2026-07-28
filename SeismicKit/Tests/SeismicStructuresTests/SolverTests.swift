import XCTest
@testable import SeismicStructures
import SeismicCore
import SeismicSignal

// Algorithms 39–45.

final class ShearBuildingTests: XCTestCase {

    /// A single mass on a single spring — the one case with an exact answer.
    /// T = 2π√(m/k).
    private func singleDegreeOfFreedom(mass: Double, stiffness: Double,
                                       damping: Double = 0.05) -> ShearBuilding {
        ShearBuilding(storeys: [Storey(id: 1, height: 3, mass: mass,
                                       stiffness: stiffness, floorArea: 100)],
                      damping: damping)
    }

    func testMassMatrixIsDiagonal() {
        let building = ShearBuilding(storeys: (1...4).map {
            Storey(id: $0, height: 3, mass: Double($0) * 1000, stiffness: 1e7, floorArea: 100)
        }, damping: 0.05)
        let m = building.massMatrix
        for i in 0..<4 {
            for j in 0..<4 where i != j { XCTAssertEqual(m[i][j], 0) }
            XCTAssertEqual(m[i][i], Double(i + 1) * 1000)
        }
    }

    func testStiffnessMatrixIsTridiagonalAndSymmetric() {
        let building = ShearBuilding(storeys: (1...5).map {
            Storey(id: $0, height: 3, mass: 1000, stiffness: 1e7, floorArea: 100)
        }, damping: 0.05)
        let k = building.stiffnessMatrix

        for i in 0..<5 {
            for j in 0..<5 {
                XCTAssertEqual(k[i][j], k[j][i], accuracy: 1e-6, "not symmetric at \(i),\(j)")
                if abs(i - j) > 1 { XCTAssertEqual(k[i][j], 0, "not tridiagonal at \(i),\(j)") }
            }
        }
        // Interior rows: k_i + k_{i+1} on the diagonal.
        XCTAssertEqual(k[0][0], 2e7, accuracy: 1)
        // Top row has nothing above it.
        XCTAssertEqual(k[4][4], 1e7, accuracy: 1)
    }

    func testSingleDegreeOfFreedomPeriodMatchesTheAnalyticFormula() {
        for (mass, stiffness) in [(1000.0, 1e6), (50_000.0, 2e8), (2000.0, 5e5)] {
            let building = singleDegreeOfFreedom(mass: mass, stiffness: stiffness)
            let expected = 2 * Double.pi * (mass / stiffness).squareRoot()
            let computed = ModalAnalysis.fundamentalPeriod(of: building)
            XCTAssertEqual(computed, expected, accuracy: expected * 1e-6)
        }
    }

    func testStifferBuildingHasShorterPeriod() {
        let soft = singleDegreeOfFreedom(mass: 1000, stiffness: 1e6)
        let stiff = singleDegreeOfFreedom(mass: 1000, stiffness: 4e6)
        // Quadrupling stiffness halves the period exactly.
        XCTAssertEqual(ModalAnalysis.fundamentalPeriod(of: stiff),
                       ModalAnalysis.fundamentalPeriod(of: soft) / 2,
                       accuracy: 1e-9)
    }

    func testHeavierBuildingHasLongerPeriod() {
        let light = singleDegreeOfFreedom(mass: 1000, stiffness: 1e6)
        let heavy = singleDegreeOfFreedom(mass: 4000, stiffness: 1e6)
        XCTAssertEqual(ModalAnalysis.fundamentalPeriod(of: heavy),
                       ModalAnalysis.fundamentalPeriod(of: light) * 2,
                       accuracy: 1e-9)
    }

    func testBuildingFromDescriptionMatchesItsEmpiricalPeriod() {
        // The calibration step must actually work: the assembled model's
        // computed period should land on the empirical target.
        for storeys in [3, 8, 20, 45] {
            let description = BuildingModel(name: "Test \(storeys)", storeyCount: storeys,
                                            height: Double(storeys) * 3.4,
                                            material: .reinforcedConcrete, system: .momentFrame)
            let model = ShearBuilding.from(description)
            let computed = ModalAnalysis.fundamentalPeriod(of: model)
            XCTAssertEqual(computed, description.empiricalPeriod,
                           accuracy: description.empiricalPeriod * 0.02,
                           "\(storeys)-storey model did not hit its target period")
        }
    }

    func testSoftStoreyIsSofterAtTheBottom() {
        let normal = BuildingModel(name: "a", storeyCount: 6, height: 20, system: .momentFrame)
        let soft = BuildingModel(name: "b", storeyCount: 6, height: 20, system: .softStorey)
        let normalModel = ShearBuilding.from(normal)
        let softModel = ShearBuilding.from(soft)

        let normalRatio = normalModel.storeys[0].stiffness / normalModel.storeys[1].stiffness
        let softRatio = softModel.storeys[0].stiffness / softModel.storeys[1].stiffness
        XCTAssertLessThan(softRatio, normalRatio * 0.5)
    }

    func testBaseIsolationAddsASoftHeavilyDampedLayer() {
        let description = BuildingModel(name: "isolated", storeyCount: 8, height: 27,
                                        system: .baseIsolated)
        let model = ShearBuilding.from(description)
        XCTAssertEqual(model.degreesOfFreedom, 9, "no isolator layer was added")
        XCTAssertLessThan(model.storeys[0].stiffness, model.storeys[1].stiffness * 0.2)
        XCTAssertGreaterThanOrEqual(model.damping, 0.15)
    }
}

final class ModalAnalysisTests: XCTestCase {

    private func uniformBuilding(storeys: Int, mass: Double = 100_000,
                                 stiffness: Double = 2e8) -> ShearBuilding {
        ShearBuilding(storeys: (1...storeys).map {
            Storey(id: $0, height: 3.5, mass: mass, stiffness: stiffness, floorArea: 400)
        }, damping: 0.05)
    }

    func testJacobiOnADiagonalMatrixReturnsItsDiagonal() {
        let (values, _) = ModalAnalysis.jacobiEigen([[3, 0, 0], [0, 1, 0], [0, 0, 2]])
        XCTAssertEqual(values, [1, 2, 3])
    }

    func testJacobiEigenvaluesSumToTheTrace() {
        let m = [[4.0, 1.0, 0.5, 0.2],
                 [1.0, 3.0, 0.3, 0.1],
                 [0.5, 0.3, 5.0, 0.4],
                 [0.2, 0.1, 0.4, 2.0]]
        let (values, _) = ModalAnalysis.jacobiEigen(m)
        XCTAssertEqual(values.reduce(0, +), 14.0, accuracy: 1e-9)
        XCTAssertEqual(values, values.sorted(), "eigenvalues must come back ascending")
    }

    func testJacobiEigenvectorsSatisfyTheEigenEquation() {
        let m = [[4.0, 1.0, 0.5], [1.0, 3.0, 0.3], [0.5, 0.3, 5.0]]
        let (values, vectors) = ModalAnalysis.jacobiEigen(m)
        for (index, lambda) in values.enumerated() {
            let v = vectors[index]
            let mv = LinearAlgebra.matVec(m, v)
            for i in 0..<3 {
                XCTAssertEqual(mv[i], lambda * v[i], accuracy: 1e-8)
            }
        }
    }

    func testModesAreOrderedWithModeOneLongest() {
        let modes = ModalAnalysis.modes(of: uniformBuilding(storeys: 6))
        XCTAssertEqual(modes.count, 6)
        for i in 1..<modes.count {
            XCTAssertLessThan(modes[i].period, modes[i - 1].period)
            XCTAssertEqual(modes[i].number, i + 1)
        }
    }

    func testFirstModeShapeIncreasesMonotonicallyUpTheHeight() {
        // The fundamental mode of a shear building never has an internal node:
        // every floor moves the same way, more as you go up.
        let modes = ModalAnalysis.modes(of: uniformBuilding(storeys: 8))
        let shape = modes[0].shape
        for i in 1..<shape.count {
            XCTAssertGreaterThan(shape[i], shape[i - 1],
                                 "mode 1 shape is not monotonic at floor \(i)")
        }
        XCTAssertEqual(shape.last!, 1.0, accuracy: 1e-9, "shape should be normalised to peak 1")
    }

    func testHigherModesHaveNodes() {
        // Mode 2 must change sign exactly once, mode 3 twice.
        let modes = ModalAnalysis.modes(of: uniformBuilding(storeys: 10))
        func signChanges(_ shape: [Double]) -> Int {
            var count = 0
            for i in 1..<shape.count where (shape[i] < 0) != (shape[i - 1] < 0) { count += 1 }
            return count
        }
        XCTAssertEqual(signChanges(modes[1].shape), 1)
        XCTAssertEqual(signChanges(modes[2].shape), 2)
    }

    func testMassParticipationIsDominatedByTheFirstModeAndSumsToOne() {
        let modes = ModalAnalysis.modes(of: uniformBuilding(storeys: 10))
        XCTAssertGreaterThan(modes[0].massParticipationRatio, 0.7)
        let total = modes.reduce(0) { $0 + $1.massParticipationRatio }
        XCTAssertEqual(total, 1.0, accuracy: 0.02)
    }

    func testTallerBuildingsHaveLongerFundamentalPeriods() {
        let short = ModalAnalysis.fundamentalPeriod(of: uniformBuilding(storeys: 3))
        let tall = ModalAnalysis.fundamentalPeriod(of: uniformBuilding(storeys: 30))
        XCTAssertGreaterThan(tall, short * 4)
    }

    func testEmptyBuildingReturnsNoModesRatherThanCrashing() {
        let empty = ShearBuilding(storeys: [], damping: 0.05)
        XCTAssertTrue(ModalAnalysis.modes(of: empty).isEmpty)
        XCTAssertEqual(ModalAnalysis.fundamentalPeriod(of: empty), 0)
    }

    func testModeShapeSignIsStableAcrossRuns() {
        let building = uniformBuilding(storeys: 7)
        let first = ModalAnalysis.modes(of: building)
        let second = ModalAnalysis.modes(of: building)
        for i in 0..<first.count {
            XCTAssertEqual(first[i].shape, second[i].shape)
        }
    }
}

final class RayleighDampingTests: XCTestCase {

    func testTargetRatioIsHitExactlyAtBothAnchorFrequencies() {
        let (alpha, beta) = RayleighDamping.coefficients(targetRatio: 0.05,
                                                         frequency1: 1.0, frequency2: 5.0)
        XCTAssertEqual(RayleighDamping.effectiveRatio(alpha: alpha, beta: beta, frequency: 1.0),
                       0.05, accuracy: 1e-9)
        XCTAssertEqual(RayleighDamping.effectiveRatio(alpha: alpha, beta: beta, frequency: 5.0),
                       0.05, accuracy: 1e-9)
    }

    func testDampingDipsBetweenTheAnchorsAndRisesOutside() {
        let (alpha, beta) = RayleighDamping.coefficients(targetRatio: 0.05,
                                                         frequency1: 1.0, frequency2: 5.0)
        let between = RayleighDamping.effectiveRatio(alpha: alpha, beta: beta, frequency: 2.5)
        let below = RayleighDamping.effectiveRatio(alpha: alpha, beta: beta, frequency: 0.3)
        let above = RayleighDamping.effectiveRatio(alpha: alpha, beta: beta, frequency: 15)
        XCTAssertLessThan(between, 0.05)
        XCTAssertGreaterThan(below, 0.05)
        XCTAssertGreaterThan(above, 0.05)
    }

    func testMatrixIsSymmetric() {
        let building = ShearBuilding(storeys: (1...5).map {
            Storey(id: $0, height: 3, mass: 100_000, stiffness: 2e8, floorArea: 400)
        }, damping: 0.05)
        let c = RayleighDamping.matrix(for: building)
        for i in 0..<5 {
            for j in 0..<5 { XCTAssertEqual(c[i][j], c[j][i], accuracy: 1e-6) }
        }
    }

    func testEqualAnchorFrequenciesDoNotProduceNaN() {
        let (alpha, beta) = RayleighDamping.coefficients(targetRatio: 0.05,
                                                         frequency1: 2, frequency2: 2)
        XCTAssertTrue(alpha.isFinite && beta.isFinite)
    }
}

final class DriftThresholdTests: XCTestCase {

    func testStateClassificationAtEachBoundary() {
        let t = DriftThresholds(slight: 0.005, moderate: 0.010, extensive: 0.020, complete: 0.040)
        XCTAssertEqual(t.state(for: 0.001), .none)
        XCTAssertEqual(t.state(for: 0.005), .slight)
        XCTAssertEqual(t.state(for: 0.012), .moderate)
        XCTAssertEqual(t.state(for: 0.025), .extensive)
        XCTAssertEqual(t.state(for: 0.10), .complete)
    }

    func testNegativeDriftIsClassifiedByMagnitude() {
        let t = DriftThresholds(slight: 0.005, moderate: 0.010, extensive: 0.020, complete: 0.040)
        XCTAssertEqual(t.state(for: -0.025), .extensive)
    }

    func testBrittleSystemsHaveLowerThresholdsThanDuctileOnes() {
        let steel = DriftThresholds.forSystem(.momentFrame, material: .steel)
        let masonry = DriftThresholds.forSystem(.bearingWall, material: .unreinforcedMasonry)
        XCTAssertLessThan(masonry.complete, steel.complete)
        XCTAssertLessThan(masonry.slight, steel.slight)
    }

    func testThresholdsAreStrictlyIncreasingForEverySystem() {
        for system in StructuralSystem.allCases {
            for material in ConstructionMaterial.allCases {
                let t = DriftThresholds.forSystem(system, material: material)
                XCTAssertLessThan(t.slight, t.moderate, "\(system)/\(material)")
                XCTAssertLessThan(t.moderate, t.extensive, "\(system)/\(material)")
                XCTAssertLessThan(t.extensive, t.complete, "\(system)/\(material)")
            }
        }
    }

    func testEveryDamageStateExplainsItself() {
        for state in DamageState.allCases {
            XCTAssertFalse(state.label.isEmpty)
            XCTAssertFalse(state.description.isEmpty)
            XCTAssertFalse(state.systemImage.isEmpty)
        }
    }
}

final class StructuralSolverTests: XCTestCase {

    private func testBuilding(storeys: Int = 8, period: Double? = nil) -> ShearBuilding {
        let description = BuildingModel(name: "Test tower", storeyCount: storeys,
                                        height: Double(storeys) * 3.4,
                                        material: .reinforcedConcrete, system: .momentFrame)
        return ShearBuilding.from(description, targetPeriod: period)
    }

    private var thresholds: DriftThresholds {
        DriftThresholds.forSystem(.momentFrame, material: .reinforcedConcrete)
    }

    func testNoGroundMotionMeansNoResponse() {
        let quiet = Waveform(samples: [Double](repeating: 0, count: 2000), sampleRate: 100)
        let result = StructuralSolver.run(testBuilding(), groundAcceleration: quiet,
                                          thresholds: thresholds)
        XCTAssertEqual(result.maximumDrift, 0, accuracy: 1e-12)
        XCTAssertEqual(result.overallDamageState, .none)
        XCTAssertFalse(result.collapsed)
    }

    func testResonantExcitationProducesFarMoreDriftThanOffResonance() {
        // This is the single most important behaviour in the whole engine.
        let building = testBuilding(storeys: 10, period: 1.0)
        let natural = ModalAnalysis.fundamentalPeriod(of: building)
        XCTAssertEqual(natural, 1.0, accuracy: 0.05)

        let resonant = SyntheticMotion.sine(frequency: 1.0, seconds: 40,
                                            sampleRate: 100, amplitude: 0.5)
        let offResonance = SyntheticMotion.sine(frequency: 5.0, seconds: 40,
                                                sampleRate: 100, amplitude: 0.5)

        let flat = DriftThresholds(slight: .infinity, moderate: .infinity,
                                   extensive: .infinity, complete: .infinity)
        let a = StructuralSolver.run(building, groundAcceleration: resonant,
                                     thresholds: flat, options: .fast)
        let b = StructuralSolver.run(building, groundAcceleration: offResonance,
                                     thresholds: flat, options: .fast)
        XCTAssertGreaterThan(a.maximumDrift, b.maximumDrift * 10)
    }

    func testStrongerShakingProducesMoreDamage() {
        let building = testBuilding(storeys: 8)
        let base = SyntheticMotion.generate(.init(magnitude: 6.5, distanceKm: 30, seed: 7)).magnitude

        var states: [DamageState] = []
        for scale in [0.05, 1.0, 6.0] {
            let scaled = Waveform(samples: base.samples.map { $0 * scale },
                                  sampleRate: base.sampleRate)
            let result = StructuralSolver.run(building, groundAcceleration: scaled,
                                              thresholds: thresholds)
            states.append(result.overallDamageState)
        }
        XCTAssertLessThanOrEqual(states[0].rawValue, states[1].rawValue)
        XCTAssertLessThan(states[1].rawValue, states[2].rawValue)
    }

    func testDamageLengthensThePeriodAndUndamagedDoesNot() {
        let building = testBuilding(storeys: 8)
        let motion = SyntheticMotion.generate(.init(magnitude: 6.5, distanceKm: 25, seed: 3)).magnitude

        // Gentle: no damage, so the period must be unchanged.
        let gentle = Waveform(samples: motion.samples.map { $0 * 0.02 },
                              sampleRate: motion.sampleRate)
        let gentleResult = StructuralSolver.run(building, groundAcceleration: gentle,
                                                thresholds: thresholds)
        XCTAssertEqual(gentleResult.periodChangePercent, 0, accuracy: 0.01)

        // Violent: damage, so the period must lengthen — the product's core claim.
        let violent = Waveform(samples: motion.samples.map { $0 * 8 },
                               sampleRate: motion.sampleRate)
        let violentResult = StructuralSolver.run(building, groundAcceleration: violent,
                                                 thresholds: thresholds)
        XCTAssertGreaterThan(violentResult.overallDamageState.rawValue, DamageState.slight.rawValue)
        XCTAssertGreaterThan(violentResult.periodChangePercent, 5)
        XCTAssertGreaterThan(violentResult.finalPeriod, violentResult.initialPeriod)
    }

    func testDegradationCanBeDisabled() {
        let building = testBuilding(storeys: 8)
        let motion = SyntheticMotion.generate(.init(magnitude: 7, distanceKm: 15, seed: 5)).magnitude
        let violent = Waveform(samples: motion.samples.map { $0 * 5 }, sampleRate: motion.sampleRate)

        let linear = StructuralSolver.run(building, groundAcceleration: violent,
                                          thresholds: thresholds,
                                          options: .init(allowDegradation: false))
        XCTAssertEqual(linear.periodChangePercent, 0, accuracy: 1e-9)
        XCTAssertTrue(linear.storeyResults.allSatisfy { $0.stiffnessRemaining == 1 })
    }

    func testDamageIsPermanentWithinARun() {
        // Once softened, a storey must not recover when the shaking dies away.
        let building = testBuilding(storeys: 6)
        let motion = SyntheticMotion.generate(.init(magnitude: 6.8, distanceKm: 12, seed: 21)).magnitude
        var samples = motion.samples.map { $0 * 6 }
        // Append 20 s of silence after the event.
        samples.append(contentsOf: [Double](repeating: 0, count: Int(20 * motion.sampleRate)))

        let result = StructuralSolver.run(building,
                                          groundAcceleration: Waveform(samples: samples,
                                                                       sampleRate: motion.sampleRate),
                                          thresholds: thresholds)
        XCTAssertGreaterThan(result.periodChangePercent, 0)
        XCTAssertTrue(result.storeyResults.contains { $0.stiffnessRemaining < 1 })
    }

    func testDriftIsLargestSomewhereSensibleAndReported() {
        let building = testBuilding(storeys: 12)
        let motion = SyntheticMotion.generate(.init(magnitude: 6.5, distanceKm: 20, seed: 8)).magnitude
        let result = StructuralSolver.run(building, groundAcceleration: motion,
                                          thresholds: thresholds)
        XCTAssertEqual(result.storeyResults.count, 12)
        XCTAssertTrue((1...12).contains(result.worstStorey))
        let worst = result.storeyResults.first { $0.storey == result.worstStorey }!
        XCTAssertEqual(worst.peakDrift, result.maximumDrift, accuracy: 1e-12)
    }

    func testHistoryIsRecordedAndBounded() {
        let building = testBuilding(storeys: 5)
        // A long record that would otherwise store hundreds of thousands of steps.
        let motion = SyntheticMotion.generate(.init(magnitude: 7, distanceKm: 40,
                                                    sampleRate: 200, seed: 4)).magnitude
        let result = StructuralSolver.run(building, groundAcceleration: motion,
                                          thresholds: thresholds,
                                          options: .init(maximumStoredSteps: 500))
        XCTAssertGreaterThan(result.stepCount, 100)
        XCTAssertLessThanOrEqual(result.stepCount, 600)
        XCTAssertEqual(result.displacement.count, result.times.count)
        XCTAssertTrue(result.displacement.allSatisfy { $0.count == 5 })
    }

    func testHeavierDampingReducesResponse() {
        let description = BuildingModel(name: "d", storeyCount: 8, height: 27)
        var light = ShearBuilding.from(description); light.damping = 0.01
        var heavy = ShearBuilding.from(description); heavy.damping = 0.20

        let motion = SyntheticMotion.generate(.init(magnitude: 6.5, distanceKm: 25, seed: 11)).magnitude
        let flat = DriftThresholds(slight: .infinity, moderate: .infinity,
                                   extensive: .infinity, complete: .infinity)
        let a = StructuralSolver.run(light, groundAcceleration: motion,
                                     thresholds: flat, options: .fast)
        let b = StructuralSolver.run(heavy, groundAcceleration: motion,
                                     thresholds: flat, options: .fast)
        XCTAssertLessThan(b.maximumDrift, a.maximumDrift)
    }

    func testEmptyBuildingOrEmptyMotionDoesNotCrash() {
        let empty = ShearBuilding(storeys: [], damping: 0.05)
        let motion = SyntheticMotion.sine(frequency: 1, seconds: 10)
        _ = StructuralSolver.run(empty, groundAcceleration: motion, thresholds: thresholds)

        let noMotion = Waveform(samples: [], sampleRate: 100)
        let result = StructuralSolver.run(testBuilding(), groundAcceleration: noMotion,
                                          thresholds: thresholds)
        XCTAssertEqual(result.maximumDrift, 0)
    }

    func testModalSuperpositionApproximatesFullIntegration() {
        // The fast path must land in the same neighbourhood as the exact one,
        // otherwise comparison mode would show two different buildings.
        let building = testBuilding(storeys: 8)
        let motion = SyntheticMotion.generate(.init(magnitude: 6.2, distanceKm: 30, seed: 6)).magnitude
        let flat = DriftThresholds(slight: .infinity, moderate: .infinity,
                                   extensive: .infinity, complete: .infinity)

        let full = StructuralSolver.run(building, groundAcceleration: motion, thresholds: flat,
                                        options: .init(allowDegradation: false))
        let modal = StructuralSolver.modalSuperposition(building, groundAcceleration: motion,
                                                        thresholds: flat, modeCount: 3)

        XCTAssertGreaterThan(modal.maximumDrift, 0)
        XCTAssertEqual(modal.maximumDrift, full.maximumDrift,
                       accuracy: full.maximumDrift * 0.6 + 1e-6)
    }

    func testBaseIsolationLengthensThePeriodAndSoftensTheBase() {
        let conventional = ShearBuilding.from(
            BuildingModel(name: "conventional", storeyCount: 8, height: 27, system: .momentFrame))
        let isolated = ShearBuilding.from(
            BuildingModel(name: "isolated", storeyCount: 8, height: 27, system: .baseIsolated))

        // The defining characteristics: a much longer period, achieved by a
        // bearing layer far softer than anything above it.
        XCTAssertGreaterThan(ModalAnalysis.fundamentalPeriod(of: isolated),
                             ModalAnalysis.fundamentalPeriod(of: conventional) * 2)
        XCTAssertLessThan(isolated.storeys[0].stiffness, isolated.storeys[1].stiffness * 0.1)
    }

    func testBaseIsolationProtectsTheSuperstructureFromResonantShaking() {
        // Base isolation works by moving the building's period away from where
        // the shaking has its energy. Driven at the *conventional* building's
        // own frequency, the conventional frame resonates and the isolated one
        // does not — which is the entire design principle.
        //
        // Note this is not a universal benefit, and the model correctly declines
        // to pretend otherwise: against long-period near-fault motion, isolation
        // can move a building *onto* resonance rather than off it.
        let conventional = ShearBuilding.from(
            BuildingModel(name: "conventional", storeyCount: 8, height: 27, system: .momentFrame))
        let isolated = ShearBuilding.from(
            BuildingModel(name: "isolated", storeyCount: 8, height: 27, system: .baseIsolated))

        let drivingFrequency = 1 / ModalAnalysis.fundamentalPeriod(of: conventional)
        let motion = SyntheticMotion.sine(frequency: drivingFrequency, seconds: 40,
                                          sampleRate: 100, amplitude: 1.5)
        let flat = DriftThresholds(slight: .infinity, moderate: .infinity,
                                   extensive: .infinity, complete: .infinity)

        let a = StructuralSolver.run(conventional, groundAcceleration: motion,
                                     thresholds: flat, options: .fast)
        let b = StructuralSolver.run(isolated, groundAcceleration: motion,
                                     thresholds: flat, options: .fast)

        // Ignore the isolator layer itself — it is *supposed* to deform.
        let conventionalMax = a.storeyResults.map(\.peakDrift).max() ?? 0
        let isolatedSuperstructure = b.storeyResults.dropFirst().map(\.peakDrift).max() ?? 0
        XCTAssertLessThan(isolatedSuperstructure, conventionalMax * 0.5)
    }
}

final class ResonanceSweepTests: XCTestCase {

    func testSweepPeaksAtTheNaturalFrequency() {
        let description = BuildingModel(name: "sweep", storeyCount: 6, height: 20)
        let building = ShearBuilding.from(description)
        let natural = 1 / ModalAnalysis.fundamentalPeriod(of: building)

        let points = ResonanceSweep.sweep(building, sampleRate: 100)
        XCTAssertGreaterThan(points.count, 20)

        let peak = points.max { $0.amplification < $1.amplification }!
        XCTAssertEqual(peak.frequency, natural, accuracy: natural * 0.25)
    }

    func testAmplificationFallsAwayFromResonance() {
        let building = ShearBuilding.from(BuildingModel(name: "s", storeyCount: 5, height: 17))
        let points = ResonanceSweep.sweep(building, sampleRate: 100)
        guard let peak = points.max(by: { $0.amplification < $1.amplification }),
              let lowest = points.first, let highest = points.last else {
            return XCTFail("sweep produced nothing")
        }
        XCTAssertGreaterThan(peak.amplification, lowest.amplification * 2)
        XCTAssertGreaterThan(peak.amplification, highest.amplification * 2)
    }

    func testSweepOfAnEmptyBuildingIsEmptyNotACrash() {
        XCTAssertTrue(ResonanceSweep.sweep(ShearBuilding(storeys: [], damping: 0.05)).isEmpty)
    }
}
