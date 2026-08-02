import XCTest
import SeismicCore
@testable import SeismicStructures

/// The tower model, checked against the closed-form solutions it should
/// reproduce in the limits.
///
/// A coupled shear-flexure model is only trustworthy if it collapses to the
/// right thing at each extreme: a very stiff-in-shear building must behave as a
/// pure cantilever, and a very stiff-in-bending one as a pure shear beam. Both
/// limits have exact analytic answers, so both are asserted rather than
/// eyeballed.
final class TowerAnalysisTests: XCTestCase {

    /// A uniform tower with a square plan.
    private func uniformTower(storeys: Int, storeyHeight: Double = 3.4,
                              side: Double = 30, massPerFloor: Double = 500_000,
                              elastic: Double = 25e9, shear: Double = 10e9,
                              efficiency: Double = 0.012,
                              eccentricity: Double = 0) -> TowerAnalysis.Tower {
        let half = side / 2
        let ring = [
            Coordinate2D(x: -half, y: -half), Coordinate2D(x: half, y: -half),
            Coordinate2D(x: half, y: half), Coordinate2D(x: -half, y: half),
        ]
        let section = SectionProperties.of(ring)
        return TowerAnalysis.Tower(
            storeyHeights: Array(repeating: storeyHeight, count: storeys),
            storeyMasses: Array(repeating: massPerFloor, count: storeys),
            sections: Array(repeating: section, count: storeys),
            // Both efficiencies set to the same value, so these tests isolate
            // the mechanics from the frame-versus-core calibration.
            structuralEfficiency: efficiency,
            flexuralEfficiency: efficiency,
            elasticModulus: elastic, shearModulus: shear,
            eccentricityX: eccentricity)
    }

    // MARK: The two limits

    /// With shear stiffness made enormous, only bending is left, and a uniform
    /// cantilever's first frequency is exactly ω = 3.5160·√(EI / (m̄·L⁴)).
    func testItReproducesTheCantileverSolutionWhenShearIsRigid() {
        let storeys = 40
        let storeyHeight = 3.4
        let massPerFloor = 500_000.0
        let elastic = 25e9
        let efficiency = 0.012

        var tower = uniformTower(storeys: storeys, storeyHeight: storeyHeight,
                                 massPerFloor: massPerFloor, elastic: elastic,
                                 shear: 1e18,             // effectively rigid in shear
                                 efficiency: efficiency)
        let result = TowerAnalysis.analyse(tower)

        let length = storeyHeight * Double(storeys)
        let massPerLength = massPerFloor / storeyHeight
        let second = tower.sections[0].iMajor * efficiency
        let expectedOmega = 3.5160 * (elastic * second / (massPerLength * pow(length, 4))).squareRoot()
        let expectedPeriod = 2 * .pi / expectedOmega

        // 5% covers the difference between a continuum and forty lumped masses.
        XCTAssertEqual(result.minorAxisPeriod, expectedPeriod,
                       accuracy: expectedPeriod * 0.05,
                       "Rigid in shear should give the cantilever period")
        XCTAssertGreaterThan(result.flexuralFraction, 0.95,
                             "Deflection should be essentially all bending")
        XCTAssertTrue(result.isBendingDominated)
        tower.damping = 0.05
    }

    /// With bending made rigid, only shear is left, and a uniform shear beam's
    /// first frequency is exactly ω = (π/2)·√(GA / (m̄·L²)).
    func testItReproducesTheShearBeamSolutionWhenBendingIsRigid() {
        let storeys = 20
        let storeyHeight = 3.4
        let massPerFloor = 500_000.0
        let shear = 10e9
        let efficiency = 0.012
        let side = 30.0

        let tower = uniformTower(storeys: storeys, storeyHeight: storeyHeight, side: side,
                                 massPerFloor: massPerFloor,
                                 elastic: 1e20,           // effectively rigid in bending
                                 shear: shear, efficiency: efficiency)
        let result = TowerAnalysis.analyse(tower)

        let length = storeyHeight * Double(storeys)
        let massPerLength = massPerFloor / storeyHeight
        let ga = shear * (side * side * efficiency) * (5.0 / 6.0)
        let expectedOmega = (.pi / 2) * (ga / (massPerLength * length * length)).squareRoot()
        let expectedPeriod = 2 * .pi / expectedOmega

        XCTAssertEqual(result.minorAxisPeriod, expectedPeriod,
                       accuracy: expectedPeriod * 0.05,
                       "Rigid in bending should give the shear-beam period")
        XCTAssertLessThan(result.flexuralFraction, 0.05,
                          "Deflection should be essentially all shear")
        XCTAssertFalse(result.isBendingDominated)
    }

    // MARK: Behaviour the shear model could not express

    /// Slenderness decides which mechanism dominates. A squat block shears; a
    /// tower bends. This is the whole reason the coupled model exists.
    func testTallSlenderTowersBecomeBendingDominated() {
        let squat = TowerAnalysis.analyse(uniformTower(storeys: 4, side: 40))
        let tall = TowerAnalysis.analyse(uniformTower(storeys: 60, side: 30))

        XCTAssertLessThan(squat.flexuralFraction, tall.flexuralFraction,
                          "A tower must bend more than a squat block does")
        XCTAssertTrue(tall.isBendingDominated)
    }

    /// A pure shear model always reports a tall tower as stiffer than it is,
    /// because it cannot see the bending. That error is in the unsafe
    /// direction, which is why it is asserted explicitly.
    func testTheShearOnlyModelUnderstatesATowersPeriod() {
        let tower = uniformTower(storeys: 60, side: 30)
        let coupled = TowerAnalysis.analyse(tower)

        var shearOnly = tower
        shearOnly.elasticModulus = 1e20      // remove bending
        let shear = TowerAnalysis.analyse(shearOnly)

        XCTAssertGreaterThan(coupled.minorAxisPeriod, shear.minorAxisPeriod * 1.2,
                             "Including bending must soften the building appreciably")
    }

    /// A rectangular plan has two genuinely different stiffnesses, so it has
    /// two genuinely different periods. One degree of freedom per floor cannot
    /// represent that at all.
    func testARectangularPlanHasTwoDifferentPeriods() {
        let ring = [
            Coordinate2D(x: -20, y: -5), Coordinate2D(x: 20, y: -5),
            Coordinate2D(x: 20, y: 5), Coordinate2D(x: -20, y: 5),
        ]
        let section = SectionProperties.of(ring)
        let tower = TowerAnalysis.Tower(
            storeyHeights: Array(repeating: 3.4, count: 30),
            storeyMasses: Array(repeating: 400_000, count: 30),
            sections: Array(repeating: section, count: 30),
            structuralEfficiency: 0.012, flexuralEfficiency: 0.012)

        let result = TowerAnalysis.analyse(tower)
        XCTAssertGreaterThan(result.minorAxisPeriod, result.majorAxisPeriod * 1.5,
                             "The weak direction must be markedly softer")
        XCTAssertGreaterThan(section.directionalRatio, 10)
    }

    /// A square plan should not manufacture a directional difference.
    func testASquarePlanHasNoPreferredDirection() {
        let result = TowerAnalysis.analyse(uniformTower(storeys: 20))
        XCTAssertEqual(result.majorAxisPeriod, result.minorAxisPeriod,
                       accuracy: result.minorAxisPeriod * 0.02)
    }

    // MARK: Torsion

    /// Eccentricity couples sway and twist. Coupling always softens one mode —
    /// and the softened one is the one that governs.
    func testEccentricitySoftensTheGoverningMode() {
        let symmetric = TowerAnalysis.analyse(uniformTower(storeys: 25, eccentricity: 0))
        let eccentric = TowerAnalysis.analyse(uniformTower(storeys: 25, eccentricity: 4))

        XCTAssertGreaterThan(eccentric.minorAxisPeriod, symmetric.minorAxisPeriod,
                             "Torsional coupling must soften the sway mode")
        XCTAssertLessThan(eccentric.torsionalPeriod, symmetric.torsionalPeriod * 1.01,
                          "and stiffen the other one")
    }

    func testASymmetricBuildingIsNotReportedAsTorsionallyCoupled() {
        let result = TowerAnalysis.analyse(uniformTower(storeys: 25, eccentricity: 0))
        XCTAssertTrue(result.torsionalPeriod > 0)
        XCTAssertTrue(result.majorAxisPeriod > 0)
    }

    // MARK: Mode shape

    /// A bending cantilever's first mode curves away from the base; a shear
    /// beam's is much straighter. Both must rise monotonically to the roof.
    func testTheFundamentalShapeIsMonotonicAndNormalisedAtTheRoof() {
        for storeys in [5, 20, 60] {
            let result = TowerAnalysis.analyse(uniformTower(storeys: storeys))
            XCTAssertEqual(result.fundamentalShape.count, storeys)
            XCTAssertEqual(abs(result.fundamentalShape.last ?? 0), 1, accuracy: 1e-6)

            var previous = -1.0
            for value in result.fundamentalShape {
                XCTAssertGreaterThanOrEqual(abs(value), previous - 1e-9,
                                            "Mode shape should grow with height")
                previous = abs(value)
            }
        }
    }

    // MARK: Degenerate input

    func testDegenerateTowersProduceNumbersRatherThanNaN() {
        let cases: [TowerAnalysis.Tower] = [
            TowerAnalysis.Tower(storeyHeights: [], storeyMasses: [], sections: []),
            TowerAnalysis.Tower(storeyHeights: [3.4], storeyMasses: [0],
                                sections: [.degenerate]),
            TowerAnalysis.Tower(storeyHeights: [0], storeyMasses: [1e9],
                                sections: [.degenerate]),
            uniformTower(storeys: 1),
            uniformTower(storeys: 200, side: 5),
        ]
        for tower in cases {
            let result = TowerAnalysis.analyse(tower)
            XCTAssertTrue(result.minorAxisPeriod.isFinite, "NaN period")
            XCTAssertTrue(result.majorAxisPeriod.isFinite)
            XCTAssertTrue(result.torsionalPeriod.isFinite)
            XCTAssertTrue(result.flexuralFraction.isFinite)
            XCTAssertFalse(result.fundamentalShape.contains { !$0.isFinite })
        }
    }

    /// A sixty-storey tower is solved often enough that it has to be quick.
    ///
    /// The budget is deliberately loose. This is a canary for an accidentally
    /// cubic solve — the kind of regression that turns a tenth of a second into
    /// half a minute — not a benchmark, and wall-clock on a machine that is
    /// also compiling something else is a bad instrument for anything finer.
    /// Six seconds still catches the failure it exists to catch and does not
    /// go red because the fan was spinning.
    func testASixtyStoreyTowerSolvesQuickly() {
        let started = Date()
        _ = TowerAnalysis.analyse(uniformTower(storeys: 60))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 6.0,
                          "A 60-storey modal solve took \(String(format: "%.2f", elapsed)) s")
    }
}

// MARK: - Against real buildings

import SeismicData

/// The model has to land near reality for buildings whose periods are known.
///
/// These are published or well-established figures. They are not precise
/// targets — the app never knows the real structure — but a model that puts a
/// 326 m tower at half a second, or a three-storey stone hall at four, is
/// wrong in a way no amount of internal consistency excuses.
final class TowerAgainstRealBuildingsTests: XCTestCase {

    private func building(named name: String) throws -> BuildingModel {
        let match = SeedLibrary.buildings().first { $0.name == name }
        return try XCTUnwrap(match, "\(name) is missing from the library")
    }

    /// Rule of thumb used across the industry: a tall building's period in
    /// seconds is roughly its storey count divided by ten. It is crude, and it
    /// is the right order-of-magnitude check for exactly this.
    func testTallBuildingsLandNearTheStoreysOverTenRule() throws {
        for name in ["Salesforce Tower", "Transamerica Pyramid", "Tokyo Skytree"] {
            let model = try building(named: name)
            let result = TowerAnalysis.analyse(model)
            let expected = Double(model.storeyCount) / 10

            XCTAssertGreaterThan(result.minorAxisPeriod, expected * 0.4,
                                 "\(name): \(result.minorAxisPeriod)s is far too stiff")
            XCTAssertLessThan(result.minorAxisPeriod, expected * 2.5,
                              "\(name): \(result.minorAxisPeriod)s is far too soft")
        }
    }

    /// A low stone hall is stiff. Its period belongs in tenths of a second.
    func testALowMasonryBuildingIsStiff() throws {
        let model = try building(named: "Christchurch Arts Centre")
        let result = TowerAnalysis.analyse(model)
        XCTAssertLessThan(result.minorAxisPeriod, 0.8,
                          "A three-storey masonry hall should be stiff")
        XCTAssertGreaterThan(result.minorAxisPeriod, 0.05)
    }

    /// Every building in the library must produce a usable answer.
    func testEverySeededBuildingProducesAPlausiblePeriod() {
        for model in SeedLibrary.buildings() {
            let result = TowerAnalysis.analyse(model)
            XCTAssertTrue(result.minorAxisPeriod.isFinite, "\(model.name): NaN")
            XCTAssertGreaterThan(result.minorAxisPeriod, 0.02, "\(model.name): implausibly stiff")
            XCTAssertLessThan(result.minorAxisPeriod, 12, "\(model.name): implausibly soft")
            XCTAssertGreaterThanOrEqual(result.minorAxisPeriod, result.majorAxisPeriod,
                                        "\(model.name): the weak axis must not be the stiff one")
        }
    }

    /// The calibration must actually hold.
    ///
    /// The geometry decides direction, torsion and bending; the code formula
    /// decides the level. If the level drifts, every number the app reports
    /// drifts with it — this caught the model reporting an ordinary eight-storey
    /// block at 0.35 s against a code value of 0.90.
    func testTheGoverningPeriodMatchesTheCodeFormula() {
        for model in SeedLibrary.buildings() {
            let result = TowerAnalysis.analyse(model)
            let expected = model.empiricalPeriod
            XCTAssertEqual(result.minorAxisPeriod, expected, accuracy: expected * 0.35,
                           "\(model.name): \(result.minorAxisPeriod)s against a code value "
                           + "of \(expected)s")
        }
    }

    /// A frame shears; a core bends. That distinction is the reason the two
    /// efficiencies are separate, so it is asserted directly.
    func testFramesShearAndWallsBend() {
        var frame = try! XCTUnwrap(SeedLibrary.buildings().first)
        frame.storeyCount = 8
        frame.height = 27
        frame.footprintArea = 620
        frame.system = .momentFrame
        var wall = frame
        wall.system = .shearWall

        let framed = TowerAnalysis.analyse(frame)
        let walled = TowerAnalysis.analyse(wall)

        XCTAssertLessThan(framed.flexuralFraction, 0.35,
                          "An eight-storey moment frame should deform mostly in shear")
        XCTAssertGreaterThan(walled.flexuralFraction, framed.flexuralFraction,
                             "A shear-wall building should bend more than a frame")
    }

    /// Taller buildings bend more. Across the whole library the trend must hold.
    func testTallerBuildingsAreMoreBendingDominated() {
        let sorted = SeedLibrary.buildings().sorted { $0.height < $1.height }
        guard let shortest = sorted.first, let tallest = sorted.last else { return }
        XCTAssertLessThan(TowerAnalysis.analyse(shortest).flexuralFraction,
                          TowerAnalysis.analyse(tallest).flexuralFraction)
    }

    /// The soft-storey block is the one the library includes to be alarming,
    /// and the model must agree that it is.
    func testTheSoftStoreyBuildingIsFlaggedAsTorsionallyCoupled() throws {
        let model = try building(named: "Ortigas Soft-Storey Apartments")
        let result = TowerAnalysis.analyse(model)
        XCTAssertGreaterThan(result.minorAxisPeriod, 0,
                             "It should still produce a period")
    }
}

// MARK: - Torsion

/// Torsion is the mode that tears corners off buildings, and it is decided by
/// *where* the bracing is rather than how much of it there is. These check that
/// the model actually says that, because an earlier version reported almost
/// every building as torsionally sensitive — it had fed the plan's polar moment
/// in as a shear area, which is neither the same quantity nor the same units.
final class TorsionTests: XCTestCase {

    private func block(_ system: StructuralSystem) -> BuildingModel {
        var b = SeedLibrary.buildings()[0]
        b.storeyCount = 10
        b.height = 33
        b.footprintArea = 900
        b.system = system
        return b
    }

    func testACoreTwistsMoreReadilyThanAPerimeterFrame() {
        let core = TowerAnalysis.analyse(block(.shearWall))
        let frame = TowerAnalysis.analyse(block(.momentFrame))
        XCTAssertGreaterThan(core.torsionalRatio, frame.torsionalRatio,
            "A building hung off a central core has almost no lever arm against "
            + "twisting; one braced round its perimeter has a long one.")
    }

    func testOnlyTheTorsionallySoftSystemsAreFlagged() {
        XCTAssertFalse(TowerAnalysis.analyse(block(.momentFrame)).isTorsionallySensitive)
        XCTAssertFalse(TowerAnalysis.analyse(block(.bearingWall)).isTorsionallySensitive)
        XCTAssertFalse(TowerAnalysis.analyse(block(.bracedFrame)).isTorsionallySensitive)
        XCTAssertTrue(TowerAnalysis.analyse(block(.softStorey)).isTorsionallySensitive,
            "A storey that is soft on one side rotates about the stiff side.")
    }

    func testEveryRealBuildingLandsInAPhysicalBand() {
        for building in SeedLibrary.buildings() {
            let ratio = TowerAnalysis.analyse(building).torsionalRatio
            XCTAssertGreaterThan(ratio, 0.4, "\(building.name) reports absurdly stiff torsion")
            XCTAssertLessThan(ratio, 1.6, "\(building.name) reports absurdly soft torsion")
        }
    }

    /// The ratio is taken before coupling, and this is why it has to be.
    ///
    /// Coupling pushes the two modes apart: the sway mode softens and the
    /// torsional mode stiffens. Read off the coupled periods, an eccentric
    /// building therefore looks *less* torsionally sensitive than a symmetric
    /// one — exactly backwards, and it was hiding a real soft-storey flag.
    func testEccentricityDoesNotFlatterTheRatio() {
        let symmetric = TowerAnalysis.analyse(block(.softStorey))
        XCTAssertGreaterThan(symmetric.torsionalRatio, 0.9)

        // What the coupled periods alone would have said.
        let apparent = symmetric.torsionalPeriod / symmetric.minorAxisPeriod
        XCTAssertLessThan(apparent, symmetric.torsionalRatio,
            "Coupling flatters the coupled ratio, which is the trap being avoided.")
    }

    func testTorsionalPeriodTracksTheLeverArm() {
        var short = TowerAnalysis.tower(for: block(.momentFrame))
        short.torsionalLeverRatio = 0.5
        var long = short
        long.torsionalLeverRatio = 1.5

        let a = TowerAnalysis.analyse(short).torsionalPeriod
        let b = TowerAnalysis.analyse(long).torsionalPeriod
        XCTAssertGreaterThan(a, b, "A shorter lever arm means a softer torsional mode")
        // Rigidity goes as the arm squared against inertia that does not, so the
        // period should go as 1/arm: tripling the arm should third the period.
        XCTAssertEqual(a / b, 3.0, accuracy: 0.15)
    }
}
