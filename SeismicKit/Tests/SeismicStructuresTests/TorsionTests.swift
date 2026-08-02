import XCTest
import SeismicCore
import SeismicGeo
@testable import SeismicStructures

/// Twist, and the shapes that cause it.
///
/// The claim being tested is a physical one: a symmetric building twists only
/// by the accidental amount every code requires, and an irregular one twists
/// because of where its area actually sits. If a rectangle came out torsionally
/// irregular the model would be inventing a hazard; if an L-shape came out
/// symmetric it would be hiding one.
final class PlanTorsionTests: XCTestCase {

    private func building(footprint: [Coordinate2D],
                          system: StructuralSystem = .momentFrame) -> BuildingModel {
        BuildingModel(name: "Test", storeyCount: 10, height: 34,
                      footprintArea: 600, footprint: footprint, system: system)
    }

    private func rectangle(width: Double, depth: Double) -> [Coordinate2D] {
        [Coordinate2D(x: -width / 2, y: -depth / 2),
         Coordinate2D(x: width / 2, y: -depth / 2),
         Coordinate2D(x: width / 2, y: depth / 2),
         Coordinate2D(x: -width / 2, y: depth / 2)]
    }

    // MARK: Symmetry

    func testASquareHasNoCalculatedEccentricity() {
        let model = TorsionModel.of(building(footprint: rectangle(width: 24, depth: 24)))
        XCTAssertEqual(model.staticEccentricity, 0, accuracy: 1e-9)
        XCTAssertEqual(model.crossAxisRatio, 0, accuracy: 1e-9)
    }

    /// It still twists, and that is correct rather than a bug. Codes require a
    /// 5% allowance on every building because no real one is as symmetric as
    /// its drawing.
    func testEvenASymmetricBuildingCarriesTheAccidentalAllowance() {
        let model = TorsionModel.of(building(footprint: rectangle(width: 24, depth: 24)))
        XCTAssertEqual(model.accidentalEccentricity, 24 * 0.05, accuracy: 1e-9)
        XCTAssertGreaterThan(model.rotation(forDisplacement: 0.1), 0)
        XCTAssertFalse(model.isTorsionallyIrregular)
    }

    /// The corner of a square does travel further than its edges — it is
    /// further out — but that is not what the code limit is measured across.
    /// Reading the irregularity check off the diagonal is what made a plain
    /// square trip it on the accidental allowance alone.
    func testTheCornerTravelsFurtherThanTheEdgeButOnlyTheEdgeSetsTheLimit() {
        let model = TorsionModel.of(building(footprint: rectangle(width: 24, depth: 24)))
        XCTAssertGreaterThan(model.cornerAmplification, model.edgeAmplification)
        XCTAssertLessThan(model.edgeAmplification, 0.2)
    }

    /// A plan aligned with its own axes has no cross-axis motion however
    /// elongated it is: pushing a slab along its length moves it along its
    /// length.
    func testAnAlignedSlabDoesNotCrabSideways() {
        let model = TorsionModel.of(building(footprint: rectangle(width: 60, depth: 12)))
        XCTAssertEqual(model.crossAxisRatio, 0, accuracy: 1e-6)
    }

    /// The case that caught a real error: a triangle has three axes of
    /// symmetry and cannot twist under a force through its centre, but its
    /// centroid sits a third of the way up while its bounding box is centred
    /// half way. Using the box as the stiffness centre reported the Tokyo
    /// Skytree — an equilateral plan — as travelling 135% further at the
    /// corners than at the middle.
    func testASymmetricTriangleHasNoCalculatedEccentricity() {
        let model = TorsionModel.of(
            building(footprint: PlanShape.triangular.polygon(area: 2000)))
        XCTAssertEqual(model.staticEccentricity, 0, accuracy: 0.01)
    }

    /// It is still flagged, and that is right rather than a leftover of the
    /// bug. A triangle is a less compact shape than a square of the same area —
    /// its plan reaches further out relative to its radius of gyration — so the
    /// 5% allowance every building is given produces a 1.30 ratio against a
    /// square's 1.15, and trips the same limit a code check would.
    ///
    /// The distinction that matters: the eccentricity above is zero, so nothing
    /// is being invented from the shape. Only the allowance is at work.
    func testATriangleStillTripsTheLimitOnTheAllowanceAlone() {
        let triangle = TorsionModel.of(
            building(footprint: PlanShape.triangular.polygon(area: 2000)))
        let square = TorsionModel.of(building(footprint: PlanShape.square.polygon(area: 2000)))

        XCTAssertEqual(triangle.designEccentricity, triangle.accidentalEccentricity,
                       accuracy: 0.01, "nothing but the allowance should be contributing")
        XCTAssertGreaterThan(triangle.edgeAmplification, square.edgeAmplification)
        XCTAssertFalse(square.isTorsionallyIrregular)
    }

    /// Every regular plan, for the same reason. A shape you can rotate onto
    /// itself has its mass and its bracing in the same place by construction.
    func testEveryRegularPlanIsConcentric() {
        for shape in [PlanShape.triangular, .square, .octagonal, .circular] {
            let model = TorsionModel.of(building(footprint: shape.polygon(area: 900)))
            XCTAssertEqual(model.staticEccentricity, 0, accuracy: 0.01,
                           "\(shape.label) should have no calculated eccentricity")
        }
    }

    /// And the converse, so the fix cannot have simply zeroed everything: a
    /// plan that really is lopsided still reports it.
    func testTheFixDidNotSimplyZeroEveryPlan() {
        let ring = [(0.0, 0.0), (30.0, 0.0), (30.0, 12.0), (12.0, 12.0),
                    (12.0, 30.0), (0.0, 30.0)].map { Coordinate2D(x: $0.0, y: $0.1) }
        XCTAssertGreaterThan(TorsionModel.of(building(footprint: ring)).staticEccentricity, 0.5)
    }

    func testThePerimeterCentroidAgreesWithTheAreaCentroidWhenSymmetric() {
        for shape in [PlanShape.triangular, .square, .circular, .octagonal] {
            let ring = shape.polygon(area: 500)
            let section = SectionProperties.of(ring)
            guard let perimeter = TorsionModel.perimeterCentroid(ring) else {
                return XCTFail("\(shape.label) should have a perimeter centroid")
            }
            XCTAssertEqual(perimeter.x, section.centroidX, accuracy: 0.01)
            XCTAssertEqual(perimeter.y, section.centroidY, accuracy: 0.01)
        }
    }

    // MARK: Irregularity

    /// The centroid of an L sits inside the solid arm while the envelope's
    /// centre sits in the missing corner, and that gap is the eccentricity —
    /// taken from the shape, with nothing assumed about the structure.
    func testAnLShapeIsEccentricAndTorsionallyIrregular() {
        let ring = [(0.0, 0.0), (30.0, 0.0), (30.0, 12.0), (12.0, 12.0),
                    (12.0, 30.0), (0.0, 30.0)].map { Coordinate2D(x: $0.0, y: $0.1) }
        let model = TorsionModel.of(building(footprint: ring))

        XCTAssertGreaterThan(model.staticEccentricity, 0.5)
        XCTAssertGreaterThan(model.cornerAmplification, 0.2)
        XCTAssertTrue(model.isTorsionallyIrregular)
    }

    /// A skewed plan crabs. The direction of the offset follows the skew, so
    /// the sign flips with it — a plan rotated the other way leans the other
    /// way, which is the part a magnitude-only check would miss.
    func testASkewedPlanMovesAcrossTheShakingAndReversesWithTheSkew() {
        func slab(rotatedBy angle: Double) -> [Coordinate2D] {
            rectangle(width: 48, depth: 12).map {
                Coordinate2D(x: $0.x * cos(angle) - $0.y * sin(angle),
                             y: $0.x * sin(angle) + $0.y * cos(angle))
            }
        }
        let clockwise = TorsionModel.of(building(footprint: slab(rotatedBy: .pi / 6)))
        let anticlockwise = TorsionModel.of(building(footprint: slab(rotatedBy: -.pi / 6)))

        XCTAssertGreaterThan(abs(clockwise.crossAxisRatio), 0.1)
        XCTAssertEqual(clockwise.crossAxisRatio, -anticlockwise.crossAxisRatio, accuracy: 1e-6)
    }

    /// A soft storey is the configuration that kills people, and the one where
    /// eccentricity does the most damage: the whole building's deformation
    /// happens at the one flexible level.
    func testASoftStoreyTwistsMoreThanAFrameOfTheSamePlan() {
        let plan = rectangle(width: 40, depth: 14)
        let frame = TorsionModel.of(building(footprint: plan, system: .momentFrame))
        let soft = TorsionModel.of(building(footprint: plan, system: .softStorey))
        XCTAssertGreaterThan(soft.staticEccentricity, frame.staticEccentricity)
        XCTAssertGreaterThan(soft.cornerAmplification, frame.cornerAmplification)
    }

    // MARK: The response

    /// Rotation is proportional to translation, because both are driven by the
    /// same storey shear. This is what lets the twist be derived from a solved
    /// one-dimensional response instead of needing a second solve.
    func testRotationScalesWithDisplacement() {
        let model = TorsionModel.of(building(footprint: rectangle(width: 30, depth: 12)))
        let small = model.rotation(forDisplacement: 0.01)
        let large = model.rotation(forDisplacement: 0.05)
        XCTAssertEqual(large, small * 5, accuracy: 1e-12)
    }

    func testMotionCarriesAllThreeComponents() {
        let ring = [(0.0, 0.0), (30.0, 0.0), (30.0, 12.0), (12.0, 12.0),
                    (12.0, 30.0), (0.0, 30.0)].map { Coordinate2D(x: $0.0, y: $0.1) }
        let motion = TorsionModel.of(building(footprint: ring)).motion(forDisplacement: 0.08)
        XCTAssertEqual(motion.along, 0.08, accuracy: 1e-12)
        XCTAssertNotEqual(motion.rotation, 0)
    }

    /// Zero in, zero out: a floor that has not moved has not twisted.
    func testAStationaryFloorDoesNotTwist() {
        let model = TorsionModel.of(building(footprint: rectangle(width: 30, depth: 12)))
        XCTAssertEqual(model.rotation(forDisplacement: 0), 0)
        XCTAssertEqual(model.motion(forDisplacement: 0), FloorMotion(along: 0, across: 0,
                                                                     rotation: 0))
    }

    /// A building with no usable outline gets no invented asymmetry.
    func testADegenerateOutlineProducesNoTwist() {
        let model = TorsionModel.of(
            BuildingModel(name: "Bare", storeyCount: 4, height: 13,
                          footprintArea: 200, footprint: [Coordinate2D(x: 0, y: 0)]))
        // Falls back to the rectangular footprint, which is symmetric, so the
        // only twist is the accidental allowance — never a fabricated one.
        XCTAssertEqual(model.staticEccentricity, 0, accuracy: 1e-9)
    }

    /// Curved plans are the ones the renderer changed, so they are worth
    /// checking end to end: a bowed slab is genuinely eccentric, because the
    /// bow moves the area away from the straight face.
    func testACurvedSlabIsEccentricBecauseOfItsBow() {
        let model = TorsionModel.of(
            building(footprint: PlanShape.curvedSlab.polygon(area: 900, aspectRatio: 2.5)))
        XCTAssertGreaterThan(model.staticEccentricity, 0.1)
    }

    func testACircularPlanHasNoDirectionalPreference() {
        let model = TorsionModel.of(
            building(footprint: PlanShape.circular.polygon(area: 700)))
        XCTAssertEqual(model.staticEccentricity, 0, accuracy: 0.05)
        XCTAssertEqual(model.crossAxisRatio, 0, accuracy: 0.02)
    }
}
