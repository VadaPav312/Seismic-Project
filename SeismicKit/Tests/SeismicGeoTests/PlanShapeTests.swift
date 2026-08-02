import XCTest
import SeismicCore
@testable import SeismicGeo

/// Every generated plan has to be a real polygon of roughly the stated area.
///
/// The area check is the one that matters. These shapes feed the structural
/// model's mass, so a cruciform that silently encloses half the floor area it
/// claims would change the building's period — the app would then report a
/// period shift that came from the renderer rather than from the building.
final class PlanShapeTests: XCTestCase {

    /// Shoelace formula. Independent of the generators, on purpose.
    private func area(_ ring: [Coordinate2D]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var points = ring
        // Drop the closing duplicate so each edge is counted once.
        if let first = points.first, let last = points.last,
           abs(first.x - last.x) < 1e-9, abs(first.y - last.y) < 1e-9 {
            points.removeLast()
        }
        var sum = 0.0
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    func testEveryShapeEnclosesTheRequestedArea() {
        for shape in PlanShape.allCases {
            for requested in [50.0, 400, 2_500, 18_000] {
                let ring = shape.polygon(area: requested)
                let measured = area(ring)
                // 2% covers the circle's polygonal approximation; everything
                // else is exact by construction.
                XCTAssertEqual(measured, requested, accuracy: requested * 0.02,
                               "\(shape.rawValue) at \(requested) m² enclosed \(measured) m²")
            }
        }
    }

    func testEveryShapeIsAClosedRingWithNoRepeatedVertices() {
        for shape in PlanShape.allCases {
            let ring = shape.polygon(area: 900)
            XCTAssertGreaterThanOrEqual(ring.count, 4, "\(shape.rawValue) is not a polygon")
            XCTAssertEqual(ring.first?.x, ring.last?.x, "\(shape.rawValue) is not closed")
            XCTAssertEqual(ring.first?.y, ring.last?.y, "\(shape.rawValue) is not closed")

            let interior = ring.dropLast()
            for (index, point) in interior.enumerated() {
                let next = interior[(index + 1) % interior.count]
                XCTAssertGreaterThan(hypot(point.x - next.x, point.y - next.y), 1e-6,
                                     "\(shape.rawValue) has a zero-length edge at \(index)")
            }
        }
    }

    /// The whole point of the irregular shapes is that they are not boxes.
    func testIrregularShapesActuallyDifferFromTheirBoundingBox() {
        for shape in PlanShape.allCases where shape.isIrregular {
            let ring = shape.polygon(area: 1_000)
            let xs = ring.map(\.x), ys = ring.map(\.y)
            let boundingArea = ((xs.max() ?? 0) - (xs.min() ?? 0))
                             * ((ys.max() ?? 0) - (ys.min() ?? 0))
            XCTAssertLessThan(area(ring), boundingArea * 0.95,
                              "\(shape.rawValue) fills its bounding box — it is a rectangle")
        }
    }

    func testAspectRatioStretchesTheRectangleWithoutChangingItsArea() {
        let wide = PlanShape.rectangular.polygon(area: 1_000, aspectRatio: 4)
        let xs = wide.map(\.x), ys = wide.map(\.y)
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        let depth = (ys.max() ?? 0) - (ys.min() ?? 0)
        XCTAssertEqual(width / depth, 4, accuracy: 0.01)
        XCTAssertEqual(area(wide), 1_000, accuracy: 1)
    }

    /// Degenerate requests come from real data: a building with no stated area.
    func testAbsurdInputsStillProduceAUsablePolygon() {
        for shape in PlanShape.allCases {
            for requested in [-100.0, 0, 0.0001, 1e9] {
                let ring = shape.polygon(area: requested, aspectRatio: -5)
                XCTAssertFalse(ring.contains { $0.x.isNaN || $0.y.isNaN },
                               "\(shape.rawValue) produced NaN at area \(requested)")
                XCTAssertGreaterThan(area(ring), 0,
                                     "\(shape.rawValue) collapsed at area \(requested)")
            }
        }
    }

    func testParsingPrefersTheMoreSpecificDescription() {
        XCTAssertEqual(PlanShape.parse("a cruciform plan with four wings"), .cruciform)
        XCTAssertEqual(PlanShape.parse("L-shaped block"), .lShaped)
        XCTAssertEqual(PlanShape.parse("Roughly rectangular slab"), .rectangular)
        XCTAssertEqual(PlanShape.parse("circular drum on a podium"), .circular)
        XCTAssertEqual(PlanShape.parse("U-shaped around a courtyard"), .uShaped)
        XCTAssertEqual(PlanShape.parse("stepped setback tower"), .setbackTower)
        // "rectangular" contains neither "circular" nor "square" — guard
        // against a substring match reintroducing that confusion.
        XCTAssertEqual(PlanShape.parse("rectangular"), .rectangular)
    }

    func testUnrecognisedDescriptionsReturnNilRatherThanGuessing() {
        for text in ["", "   ", "a very tall building", "brutalist", "modernist icon"] {
            XCTAssertNil(PlanShape.parse(text), "\(text.debugDescription) should not match")
        }
    }


    // MARK: Rounded plans

    /// Rounding removes area, so the generator has to put it back.
    ///
    /// This is the failure the shape was most likely to have: a rounded square
    /// built by cutting corners off a square of the right size encloses about
    /// six per cent less than it claims, and that six per cent would come
    /// straight off the building's mass and lengthen its computed period.
    func testRoundedPlansStillEncloseTheAreaTheyClaim() {
        for shape in [PlanShape.roundedSquare, .roundedTriangular] {
            for target in [120.0, 620.0, 2320.0] {
                let ring = shape.polygon(area: target)
                XCTAssertEqual(area(ring), target, accuracy: target * 0.01,
                               "\(shape.rawValue) at \(target) m²")
            }
        }
    }

    /// A rounded square is not a square.
    ///
    /// Asserted by counting corners rather than by eye: a square has four
    /// vertices where the direction changes sharply, and a rounded one has
    /// none — every turn is spread over an arc. Without this the shape could
    /// silently degrade to `rectangle()` and every test above would still pass.
    func testRoundedSquareHasNoSharpCorners() {
        let sharp = sharpCornerCount(PlanShape.square.polygon(area: 900))
        let rounded = sharpCornerCount(PlanShape.roundedSquare.polygon(area: 900))
        XCTAssertEqual(sharp, 4)
        XCTAssertEqual(rounded, 0)
        XCTAssertGreaterThan(PlanShape.roundedSquare.polygon(area: 900).count, 20,
                             "a rounded plan needs enough points for the curve to be fitted")
    }

    /// The curvature detector has to *find* the rounding.
    ///
    /// The two halves of this are built independently — one generates the
    /// plan, the other classifies vertices as curved or cornered — and the
    /// renderer only smooth-shades a wall when the second agrees with the
    /// first. A rounded plan that the detector reads as a polygon renders with
    /// facets, which is exactly the ziggurat look the curvature code exists to
    /// prevent.
    func testRoundedSquareIsSeenAsCurved() {
        let ring = PlanShape.roundedSquare.polygon(area: 620)
        let curved = OutlineCurvature.curvedVertices(in: ring)
        let fraction = Double(curved.filter { $0 }.count) / Double(max(curved.count, 1))
        XCTAssertGreaterThan(fraction, 0.4,
                             "most of a rounded square's outline is arc, not wall")

        let square = PlanShape.square.polygon(area: 620)
        let squareCurved = OutlineCurvature.curvedVertices(in: square)
        XCTAssertEqual(squareCurved.filter { $0 }.count, 0,
                       "a plain square has no curved vertices at all")
    }

    /// The number of vertices where the outline turns by more than 30°.
    private func sharpCornerCount(_ ring: [Coordinate2D]) -> Int {
        var points = ring
        if let first = points.first, let last = points.last,
           abs(first.x - last.x) < 1e-9, abs(first.y - last.y) < 1e-9 {
            points.removeLast()
        }
        guard points.count >= 3 else { return 0 }
        var count = 0
        for index in points.indices {
            let previous = points[(index + points.count - 1) % points.count]
            let vertex = points[index]
            let next = points[(index + 1) % points.count]
            let a = (x: vertex.x - previous.x, y: vertex.y - previous.y)
            let b = (x: next.x - vertex.x, y: next.y - vertex.y)
            let lengthA = (a.x * a.x + a.y * a.y).squareRoot()
            let lengthB = (b.x * b.x + b.y * b.y).squareRoot()
            guard lengthA > 1e-9, lengthB > 1e-9 else { continue }
            let cosine = (a.x * b.x + a.y * b.y) / (lengthA * lengthB)
            if acos(min(max(cosine, -1), 1)) > 30 * .pi / 180 { count += 1 }
        }
        return count
    }
}
