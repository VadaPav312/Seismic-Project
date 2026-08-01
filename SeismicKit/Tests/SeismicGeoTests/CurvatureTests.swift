import XCTest
import SeismicCore
@testable import SeismicGeo

/// Telling a curve from a corner.
///
/// The whole feature rests on one judgement — which runs of points were meant
/// to be a curve — and it has to be wrong in neither direction. Rounding a
/// rectangle's corners would deform buildings that are genuinely rectilinear,
/// which is most of them; failing to round a circle leaves the faceting the
/// detection exists to remove.
final class CurvatureTests: XCTestCase {

    private func regularPolygon(sides: Int, radius: Double) -> [Coordinate2D] {
        (0..<sides).map { index in
            let angle = 2 * .pi * Double(index) / Double(sides)
            return Coordinate2D(x: radius * cos(angle), y: radius * sin(angle))
        }
    }

    private func rectangle(width: Double, depth: Double) -> [Coordinate2D] {
        [Coordinate2D(x: -width / 2, y: -depth / 2),
         Coordinate2D(x: width / 2, y: -depth / 2),
         Coordinate2D(x: width / 2, y: depth / 2),
         Coordinate2D(x: -width / 2, y: depth / 2)]
    }

    // MARK: Corners stay corners

    func testARectangleHasNoCurves() {
        XCTAssertTrue(OutlineCurvature.arcs(in: rectangle(width: 30, depth: 18)).isEmpty)
    }

    /// The case that would ruin most real buildings: an L-shape is all corners,
    /// including a re-entrant one, and rounding any of them would erase the
    /// plan irregularity the whole assessment turns on.
    func testAnLShapeHasNoCurves() {
        let ring = [(0.0, 0.0), (30.0, 0.0), (30.0, 12.0), (12.0, 12.0),
                    (12.0, 30.0), (0.0, 30.0)].map { Coordinate2D(x: $0.0, y: $0.1) }
        XCTAssertTrue(OutlineCurvature.arcs(in: ring).isEmpty)
    }

    /// A single chamfered corner is a corner, not a curve — two vertices is
    /// below the minimum run for a reason.
    func testAChamferedCornerIsNotACurve() {
        let ring = [(0.0, 0.0), (28.0, 0.0), (30.0, 2.0), (30.0, 20.0),
                    (0.0, 20.0)].map { Coordinate2D(x: $0.0, y: $0.1) }
        XCTAssertTrue(OutlineCurvature.arcs(in: ring).isEmpty)
    }

    // MARK: Curves are found

    func testACircleIsOneClosedCurve() {
        let arcs = OutlineCurvature.arcs(in: regularPolygon(sides: 36, radius: 14))
        XCTAssertEqual(arcs.count, 1)
        XCTAssertEqual(arcs.first?.count, 36)
        // A full turn, to within the tolerance of summing 36 equal steps.
        XCTAssertEqual(abs(arcs.first?.sweep ?? 0), 2 * .pi, accuracy: 1e-6)
        XCTAssertTrue(OutlineCurvature.curvedVertices(in: regularPolygon(sides: 36, radius: 14))
            .allSatisfy { $0 })
    }

    /// A coarse octagon is a real shape somebody chose, and its 45° turns are
    /// corners. This is the boundary the detector must not cross.
    func testAnOctagonIsCorners() {
        XCTAssertTrue(OutlineCurvature.arcs(in: regularPolygon(sides: 8, radius: 10)).isEmpty)
    }

    /// The mixed case, which is what most curved buildings actually are: a
    /// straight back, square corners, and one bowed face.
    func testACurvedSlabCurvesOnlyOnTheBow() {
        let ring = PlanShape.curvedSlab.polygon(area: 900, aspectRatio: 2.5)
        let curved = OutlineCurvature.curvedVertices(in: ring)
        XCTAssertTrue(curved.contains(true), "the bow should be found")
        XCTAssertTrue(curved.contains(false), "the straight back should survive")
    }

    /// A curve that reverses is two curves. Read as one, the fit would cut
    /// straight through the middle of the S and move the wall.
    func testAnSBendIsTwoArcs() {
        // Sampled finely enough to be a curve rather than a zigzag: at eleven
        // points a full sine wave turns more than 28° per vertex, which is a
        // polygon by any reading and correctly refused as one.
        var points: [(Double, Double)] = []
        let steps = 60
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            points.append((t * 20, sin(t * .pi * 2) * 3))
        }
        // Close it with a straight return along the bottom.
        points.append((20, -14))
        points.append((0, -14))

        let arcs = OutlineCurvature.arcs(in: points.map { Coordinate2D(x: $0.0, y: $0.1) })
        XCTAssertGreaterThanOrEqual(arcs.count, 2, "the bend reverses, so it is not one arc")
        // And they bend opposite ways, which is the property that stops a fit
        // cutting straight through the middle of the S.
        XCTAssertLessThan((arcs[0].sweep) * (arcs[1].sweep), 0)
    }

    // MARK: Circularity

    func testCircularityIsOneForACircleAndLowerForEverythingElse() {
        XCTAssertEqual(OutlineCurvature.circularity(regularPolygon(sides: 200, radius: 9)),
                       1, accuracy: 0.002)
        XCTAssertLessThan(OutlineCurvature.circularity(rectangle(width: 40, depth: 8)), 0.5)
        XCTAssertTrue(OutlineCurvature.isEssentiallyCircular(regularPolygon(sides: 24, radius: 6)))
        // An octagon is a shape of its own and must not be called a circle.
        XCTAssertFalse(OutlineCurvature.isEssentiallyCircular(regularPolygon(sides: 8, radius: 6)))
    }

    // MARK: Normalisation

    func testNormalisationDropsClosingAndDuplicatePoints() {
        var ring = rectangle(width: 10, depth: 10)
        ring.append(ring[2])            // a duplicated node mid-ring
        ring.append(ring[0])            // the closing repeat
        // Sorting is not applied, so the duplicate has to be adjacent to count;
        // rebuild it that way.
        let messy = [ring[0], ring[0], ring[1], ring[2], ring[2], ring[3], ring[0]]
        XCTAssertEqual(OutlineCurvature.normalised(messy).count, 4)
    }

    // MARK: Paths

    /// The property that justifies Catmull–Rom over a smoothing spline: the
    /// curve passes through the surveyed points rather than near them.
    func testThePathPassesThroughEveryOriginalPoint() {
        let ring = regularPolygon(sides: 24, radius: 11)
        guard let drawn = OutlineCurvature.path(for: ring) else {
            return XCTFail("a 24-gon should produce a path")
        }
        XCTAssertEqual(drawn.segments.count, ring.count)

        let endpoints = drawn.segments.map { segment -> Coordinate2D in
            switch segment {
            case .line(let to): to
            case .curve(let to, _, _): to
            }
        }
        for (index, point) in endpoints.enumerated() {
            let expected = ring[(index + 1) % ring.count]
            XCTAssertEqual(point.x, expected.x, accuracy: 1e-9)
            XCTAssertEqual(point.y, expected.y, accuracy: 1e-9)
        }
    }

    func testARectanglesPathIsAllStraightLines() {
        guard let drawn = OutlineCurvature.path(for: rectangle(width: 20, depth: 12)) else {
            return XCTFail("a rectangle should produce a path")
        }
        for segment in drawn.segments {
            guard case .line = segment else {
                return XCTFail("a rectangle must not be rounded")
            }
        }
    }

    func testADegenerateRingHasNoPath() {
        XCTAssertNil(OutlineCurvature.path(for: []))
        XCTAssertNil(OutlineCurvature.path(for: [Coordinate2D(x: 0, y: 0),
                                                 Coordinate2D(x: 1, y: 1)]))
    }
}
