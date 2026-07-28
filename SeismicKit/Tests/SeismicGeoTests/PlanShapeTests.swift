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
}
