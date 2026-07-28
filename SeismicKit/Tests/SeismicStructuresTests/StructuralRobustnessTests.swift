import XCTest
import SeismicCore
import SeismicSignal
@testable import SeismicStructures

/// Degenerate buildings and degenerate motion.
///
/// A user can build any of these in the app: a one-storey shed, a tower with a
/// storey the importer gave no mass, a footprint of nearly nothing. The solver
/// has to produce something finite for all of them, because the alternative is
/// a NaN that travels quietly into a safety verdict.
final class StructuralRobustnessTests: XCTestCase {

    private func storey(mass: Double = 400_000, stiffness: Double = 4e8,
                        height: Double = 3.4) -> Storey {
        Storey(id: 1, height: height, mass: mass, stiffness: stiffness, floorArea: 400)
    }

    private var degenerateBuildings: [(name: String, model: ShearBuilding)] {
        [
            ("no storeys", ShearBuilding(storeys: [], damping: 0.05)),
            ("one storey", ShearBuilding(storeys: [storey()], damping: 0.05)),
            ("zero mass", ShearBuilding(storeys: [storey(mass: 0), storey(mass: 0)],
                                        damping: 0.05)),
            ("zero stiffness", ShearBuilding(storeys: [storey(stiffness: 0)], damping: 0.05)),
            ("zero damping", ShearBuilding(storeys: [storey(), storey()], damping: 0)),
            ("absurd damping", ShearBuilding(storeys: [storey(), storey()], damping: 5)),
            // Sixty storeys is taller than almost anything a user will model
            // and still cheap enough to assert on in a debug build, where the
            // numeric code runs without optimisation.
            ("enormous", ShearBuilding(storeys: Array(repeating: storey(), count: 60),
                                       damping: 0.05)),
            ("hair-thin storey", ShearBuilding(storeys: [storey(height: 1e-6)], damping: 0.05)),
        ]
    }

    func testModalAnalysisSurvivesDegenerateBuildings() {
        for (name, model) in degenerateBuildings {
            let modes = ModalAnalysis.modes(of: model)
            for mode in modes {
                XCTAssertFalse(mode.period.isNaN, "\(name): NaN period")
                XCTAssertFalse(mode.frequency.isNaN, "\(name): NaN frequency")
                XCTAssertTrue(mode.period >= 0, "\(name): negative period")
                XCTAssertFalse(mode.shape.contains { $0.isNaN }, "\(name): NaN in the mode shape")
                XCTAssertFalse(mode.massParticipationRatio.isNaN,
                               "\(name): NaN mass participation")
            }

            let fundamental = ModalAnalysis.fundamentalPeriod(of: model)
            XCTAssertFalse(fundamental.isNaN, "\(name): NaN fundamental period")
        }
    }

    func testSolverSurvivesDegenerateInput() {
        let motions: [(String, Waveform)] = [
            ("empty", Waveform(samples: [], sampleRate: 100, unit: .acceleration)),
            ("one sample", Waveform(samples: [1], sampleRate: 100, unit: .acceleration)),
            ("silence", Waveform(samples: Array(repeating: 0, count: 500),
                                 sampleRate: 100, unit: .acceleration)),
            ("enormous", Waveform(samples: Array(repeating: 1e6, count: 200),
                                  sampleRate: 100, unit: .acceleration)),
        ]

        for (buildingName, model) in degenerateBuildings {
            for (motionName, motion) in motions {
                let thresholds = DriftThresholds.forSystem(.momentFrame,
                                                           material: .reinforcedConcrete)
                let result = StructuralSolver.run(model, groundAcceleration: motion,
                                                  thresholds: thresholds)

                let label = "\(buildingName) / \(motionName)"
                XCTAssertFalse(result.maximumDrift.isNaN, "\(label): NaN peak drift")
                XCTAssertFalse(result.initialPeriod.isNaN, "\(label): NaN initial period")
                XCTAssertFalse(result.finalPeriod.isNaN, "\(label): NaN final period")
                XCTAssertFalse(result.periodChangePercent.isNaN, "\(label): NaN period change")
                for storeyResult in result.storeyResults {
                    XCTAssertFalse(storeyResult.peakDrift.isNaN, "\(label): NaN storey drift")
                }
            }
        }
    }

    /// The sweep runs sixty solves; one bad building must not take it down.
    ///
    /// The tallest case is excluded deliberately: sixty solves of a model that
    /// size is minutes of legitimate work in an unoptimised build, and
    /// asserting on it would be testing the machine rather than the code. Its
    /// modal analysis and single solves are covered above.
    func testResonanceSweepSurvivesDegenerateBuildings() {
        for (name, model) in degenerateBuildings where model.storeys.count < 50 {
            let points = ResonanceSweep.sweep(model)
            for point in points {
                XCTAssertFalse(point.amplification.isNaN, "\(name): NaN amplification")
                XCTAssertFalse(point.frequency.isNaN, "\(name): NaN frequency")
                XCTAssertTrue(point.frequency > 0, "\(name): non-positive frequency")
            }
        }
    }

    /// Fragility and damage state feed the verdict directly.
    func testFragilityStaysWithinProbabilityBounds() {
        let thresholds = DriftThresholds.forSystem(.momentFrame, material: .reinforcedConcrete)
        let set = FragilitySet.from(thresholds, label: "Moment frame")
        for demand in [-1.0, 0, 1e-12, 0.001, 0.05, 1, 1e6, .infinity] {
            for curve in set.curves {
                let probability = curve.probabilityOfExceedance(demand: demand)
                XCTAssertFalse(probability.isNaN,
                               "NaN exceedance probability at demand \(demand)")
                XCTAssertTrue((0...1).contains(probability),
                              "Probability \(probability) out of range at demand \(demand)")
            }
        }
    }
}
