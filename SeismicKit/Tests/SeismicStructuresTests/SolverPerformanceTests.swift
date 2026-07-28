import XCTest
import SeismicCore
import SeismicSignal
@testable import SeismicStructures

/// The solver is fast enough to be interactive.
///
/// It is easy for a time-stepping solver to be accidentally cubic in the number
/// of storeys, and easy not to notice while every test building has eight of
/// them. These bounds exist so that a tall building — which a user can import
/// by name in about four seconds — cannot quietly turn a resonance sweep into a
/// hang.
final class SolverPerformanceTests: XCTestCase {

    private func building(storeys count: Int) -> ShearBuilding {
        let storey = Storey(id: 1, height: 3.4, mass: 400_000,
                            stiffness: 4e8, floorArea: 400)
        return ShearBuilding(storeys: Array(repeating: storey, count: count), damping: 0.05)
    }

    private func motion(seconds: Double) -> Waveform {
        SyntheticMotion.sine(frequency: 1.2, seconds: seconds, sampleRate: 100, amplitude: 0.5)
    }

    /// A forty-storey tower, thirty seconds of shaking. This is an ordinary
    /// thing to ask the app for and must not take long enough to notice.
    func testATallBuildingSolvesQuickly() {
        let model = building(storeys: 40)
        let ground = motion(seconds: 30)
        let thresholds = DriftThresholds.forSystem(.momentFrame, material: .reinforcedConcrete)

        let start = Date()
        let result = StructuralSolver.run(model, groundAcceleration: ground,
                                          thresholds: thresholds)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertGreaterThan(result.maximumDrift, 0, "The solve produced nothing")
        XCTAssertLessThan(elapsed, 4.0,
                          "A 40-storey solve took \(String(format: "%.1f", elapsed)) s — the "
                          + "effective stiffness matrix is probably being re-eliminated every "
                          + "step instead of factorised once")
    }

    /// Cost should grow roughly with the square of the storey count, not the
    /// cube. A cubic solver passes the test above and still hangs on a tower.
    func testCostGrowsQuadraticallyNotCubically() {
        let ground = motion(seconds: 12)
        let thresholds = DriftThresholds.forSystem(.momentFrame, material: .reinforcedConcrete)

        func time(storeys: Int) -> TimeInterval {
            let model = building(storeys: storeys)
            let start = Date()
            _ = StructuralSolver.run(model, groundAcceleration: ground, thresholds: thresholds)
            return Date().timeIntervalSince(start)
        }

        let small = max(time(storeys: 10), 0.001)
        let large = time(storeys: 40)

        // Quadratic predicts 16×, cubic predicts 64×. The allowance is generous
        // — this is a smoke alarm for an algorithmic regression, not a
        // benchmark, and it has to hold on a loaded machine.
        XCTAssertLessThan(large / small, 40,
                          "Cost grew \(String(format: "%.0f", large / small))× for a 4× taller "
                          + "building, which is the signature of a cubic per-step solve")
    }
}

/// The cheap fundamental period must agree with the expensive one.
///
/// `fundamentalPeriod` uses inverse power iteration rather than a full
/// eigendecomposition. That is only a safe substitution if it lands on exactly
/// the same number, so this checks it against the full solver across a range of
/// shapes — including the deliberately awkward ones.
final class FundamentalPeriodAgreementTests: XCTestCase {

    private func tower(_ count: Int, stiffness: Double = 4e8,
                       mass: Double = 400_000) -> ShearBuilding {
        let storey = Storey(id: 1, height: 3.4, mass: mass,
                            stiffness: stiffness, floorArea: 400)
        return ShearBuilding(storeys: Array(repeating: storey, count: count), damping: 0.05)
    }

    func testItMatchesTheFullEigensolver() {
        let cases: [(String, ShearBuilding)] = [
            ("single storey", tower(1)),
            ("two storeys", tower(2)),
            ("eight storeys", tower(8)),
            ("forty storeys", tower(40)),
            ("very stiff", tower(6, stiffness: 4e11)),
            ("very soft", tower(6, stiffness: 4e5)),
            ("heavy", tower(6, mass: 4_000_000)),
            ("tapered", ShearBuilding(storeys: (1...10).map { level in
                Storey(id: level, height: 3.4,
                       mass: 500_000 - Double(level) * 30_000,
                       stiffness: 6e8 - Double(level) * 4e7, floorArea: 400)
            }, damping: 0.05)),
        ]

        for (name, model) in cases {
            let cheap = ModalAnalysis.fundamentalPeriod(of: model)
            let full = ModalAnalysis.modes(of: model).first?.period ?? 0
            XCTAssertEqual(cheap, full, accuracy: max(full * 1e-6, 1e-9),
                           "\(name): inverse iteration disagreed with the full eigensolver")
        }
    }

    /// The exact analytic answer for one storey: T = 2π√(m/k).
    func testSingleStoreyMatchesTheClosedForm() {
        let mass = 400_000.0, stiffness = 4e8
        let expected = 2 * Double.pi * (mass / stiffness).squareRoot()
        XCTAssertEqual(ModalAnalysis.fundamentalPeriod(of: tower(1, stiffness: stiffness,
                                                                mass: mass)),
                       expected, accuracy: expected * 1e-9)
    }
}
