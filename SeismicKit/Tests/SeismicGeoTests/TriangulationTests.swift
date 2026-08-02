import XCTest
import SeismicCore
@testable import SeismicGeo

/// Splitting a plan into triangles.
///
/// This is what closes the top and bottom of every storey in the 3D model, and
/// the reason it is ear clipping rather than a fan from the centroid is the
/// U-shaped plan: a fan roofs its courtyard over, and the courtyard is the
/// whole reason that plan is irregular.
final class PlanTriangulationTests: XCTestCase {

    private func ring(_ points: [(Double, Double)]) -> [Coordinate2D] {
        points.map { Coordinate2D(x: $0.0, y: $0.1) }
    }

    /// Total area of the triangles, which for a correct triangulation equals
    /// the area of the polygon. This is the check that catches both a missing
    /// triangle and one that covers a hole.
    private func triangulatedArea(_ polygon: [Coordinate2D]) -> Double {
        let indices = Polygon.triangulate(polygon)
        var total = 0.0
        for start in stride(from: 0, to: indices.count, by: 3) {
            let a = polygon[indices[start]]
            let b = polygon[indices[start + 1]]
            let c = polygon[indices[start + 2]]
            total += abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
        }
        return total
    }

    // MARK: Convex

    func testATriangleIsItsOwnTriangle() {
        XCTAssertEqual(Polygon.triangulate(ring([(0, 0), (10, 0), (0, 10)])).count, 3)
    }

    func testASquareBecomesTwoTrianglesCoveringItExactly() {
        let square = ring([(0, 0), (10, 0), (10, 10), (0, 10)])
        XCTAssertEqual(Polygon.triangulate(square).count, 6)
        XCTAssertEqual(triangulatedArea(square), 100, accuracy: 1e-9)
    }

    func testAManySidedPlanIsFullyCovered() {
        let circle = PlanShape.circular.polygon(area: 800)
        XCTAssertEqual(triangulatedArea(circle), abs(Polygon.signedArea(circle)), accuracy: 0.5)
    }

    // MARK: Concave — the cases a fan gets wrong

    func testAnLShapeIsCoveredWithoutSpillingIntoTheMissingCorner() {
        let shape = ring([(0, 0), (30, 0), (30, 12), (12, 12), (12, 30), (0, 30)])
        // 30x12 plus 12x18 = 360 + 216.
        XCTAssertEqual(triangulatedArea(shape), 576, accuracy: 1e-6)
    }

    /// The case the whole choice of algorithm rests on. A U's centroid sits in
    /// its courtyard, so a fan from there would add the courtyard's area.
    func testAUShapeDoesNotRoofOverItsCourtyard() {
        let shape = PlanShape.uShaped.polygon(area: 1000)
        XCTAssertEqual(triangulatedArea(shape), abs(Polygon.signedArea(shape)), accuracy: 0.5)
        // And specifically: it must not come out as its bounding box.
        let box = Polygon.boundingBox(shape)
        let envelope = (box.max.x - box.min.x) * (box.max.y - box.min.y)
        XCTAssertLessThan(triangulatedArea(shape), envelope * 0.95)
    }

    func testACruciformIsCovered() {
        let shape = PlanShape.cruciform.polygon(area: 900)
        XCTAssertEqual(triangulatedArea(shape), abs(Polygon.signedArea(shape)), accuracy: 0.5)
    }

    func testEveryStandardPlanTriangulatesToItsOwnArea() {
        for shape in PlanShape.allCases {
            let polygon = shape.polygon(area: 700, aspectRatio: 2)
            XCTAssertEqual(triangulatedArea(polygon), abs(Polygon.signedArea(polygon)),
                           accuracy: 1, "\(shape.label) was not covered exactly")
        }
    }

    // MARK: Winding

    /// Traced outlines arrive wound either way and both must work — OSM makes
    /// no promise about orientation.
    func testTheResultDoesNotDependOnWinding() {
        let shape = ring([(0, 0), (30, 0), (30, 12), (12, 12), (12, 30), (0, 30)])
        XCTAssertEqual(triangulatedArea(shape), triangulatedArea(shape.reversed()),
                       accuracy: 1e-6)
    }

    // MARK: Degenerate input

    func testTooFewPointsProduceNothingRatherThanCrashing() {
        XCTAssertTrue(Polygon.triangulate([]).isEmpty)
        XCTAssertTrue(Polygon.triangulate(ring([(0, 0)])).isEmpty)
        XCTAssertTrue(Polygon.triangulate(ring([(0, 0), (1, 1)])).isEmpty)
    }

    /// A self-intersecting ring has no valid triangulation. Returning what was
    /// clipped is the right answer; looping forever is not.
    func testASelfIntersectingRingTerminates() {
        let bowtie = ring([(0, 0), (10, 10), (10, 0), (0, 10)])
        let indices = Polygon.triangulate(bowtie)
        XCTAssertEqual(indices.count % 3, 0)
        for index in indices { XCTAssertTrue(bowtie.indices.contains(index)) }
    }

    func testEveryIndexIsInRangeAndNoTriangleIsDegenerate() {
        let shape = PlanShape.tShaped.polygon(area: 600)
        let indices = Polygon.triangulate(shape)
        XCTAssertFalse(indices.isEmpty)
        XCTAssertEqual(indices.count % 3, 0)
        for start in stride(from: 0, to: indices.count, by: 3) {
            let a = indices[start], b = indices[start + 1], c = indices[start + 2]
            XCTAssertTrue(shape.indices.contains(a))
            XCTAssertNotEqual(a, b)
            XCTAssertNotEqual(b, c)
            XCTAssertNotEqual(a, c)
        }
    }
}
