import XCTest
import SeismicCore
@testable import SeismicServices

/// Picking the right building out of the ones nearby.
///
/// The query returns every building within sixty metres, which in a city centre
/// is a dozen of them. This is the code that decides which one you actually
/// asked for, and getting it wrong does not fail loudly — it imports the
/// neighbour's outline under your building's name, which looks like a working
/// import until you notice the shape is not yours.
final class OverpassSelectionTests: XCTestCase {

    private func way(name: String? = nil, points: [(Double, Double)],
                     tags extra: [String: String] = [:]) -> OverpassResponse.Element {
        var tags = extra
        tags["building"] = tags["building"] ?? "yes"
        if let name { tags["name"] = name }
        return OverpassResponse.Element(
            type: "way", tags: tags,
            geometry: points.map { OverpassResponse.Point(lat: $0.1, lon: $0.0) },
            members: nil)
    }

    /// Rings in local metres, which is the space `best` works in — the origin
    /// is the queried point by construction.
    private func square(centre: (Double, Double), side: Double) -> [Coordinate2D] {
        let (cx, cy) = centre
        return [Coordinate2D(x: cx - side / 2, y: cy - side / 2),
                Coordinate2D(x: cx + side / 2, y: cy - side / 2),
                Coordinate2D(x: cx + side / 2, y: cy + side / 2),
                Coordinate2D(x: cx - side / 2, y: cy + side / 2)]
    }

    // MARK: Selection

    /// The name settles it, wherever the building happens to sit.
    func testANameMatchWinsOverProximity() {
        let candidates = [
            (element: way(name: "Corner Shop", points: []), ring: square(centre: (0, 0), side: 8)),
            (element: way(name: "Willis Tower", points: []),
             ring: square(centre: (40, 40), side: 60)),
        ]
        let chosen = OverpassClient.best(of: candidates, named: "Willis Tower")
        XCTAssertEqual(chosen?.element.tags?["name"], "Willis Tower")
    }

    /// The exact case this was written for: the coordinate lands next door, and
    /// the first element returned is the wrong building.
    func testTheBuildingContainingThePointBeatsTheFirstOneListed() {
        let candidates = [
            (element: way(points: []), ring: square(centre: (50, 50), side: 30)),
            (element: way(name: "Right one", points: []), ring: square(centre: (0, 0), side: 30)),
        ]
        let chosen = OverpassClient.best(of: candidates, named: "")
        XCTAssertEqual(chosen?.element.tags?["name"], "Right one")
    }

    /// Nothing matches and nothing contains the point, so the largest wins —
    /// the reason a building is famous enough to search for is usually that it
    /// is the big one.
    func testTheLargestWinsWhenNothingElseDoes() {
        let candidates = [
            (element: way(name: "Shed", points: []), ring: square(centre: (40, 0), side: 6)),
            (element: way(name: "Hall", points: []), ring: square(centre: (-40, 0), side: 44)),
        ]
        XCTAssertEqual(OverpassClient.best(of: candidates, named: "")?.element.tags?["name"],
                       "Hall")
    }

    /// A named complex often has an entrance pavilion tagged with the same name
    /// as the tower behind it. The tower is the building.
    func testTheLargestOfSeveralNameMatchesWins() {
        let candidates = [
            (element: way(name: "Shard", points: []), ring: square(centre: (30, 0), side: 10)),
            (element: way(name: "The Shard", points: []), ring: square(centre: (0, 0), side: 50)),
        ]
        let chosen = OverpassClient.best(of: candidates, named: "The Shard")
        XCTAssertEqual(OverpassClient.polygonArea(chosen?.ring ?? []), 2500, accuracy: 1)
    }

    func testDegenerateRingsAreIgnored() {
        let candidates = [
            (element: way(name: "Broken", points: []), ring: [Coordinate2D(x: 0, y: 0)]),
            (element: way(name: "Good", points: []), ring: square(centre: (0, 0), side: 20)),
        ]
        XCTAssertEqual(OverpassClient.best(of: candidates, named: "")?.element.tags?["name"],
                       "Good")
    }

    // MARK: Name matching

    func testNamesMatchAcrossAccentsCaseAndNoiseWords() {
        XCTAssertTrue(OverpassClient.matches(OverpassClient.normalise("Torre Latinoamericana"),
                                             OverpassClient.normalise("torre latinoamericana")))
        XCTAssertTrue(OverpassClient.matches(OverpassClient.normalise("Hôtel de Ville"),
                                             OverpassClient.normalise("Hotel de Ville")))
        // OSM's name is routinely longer than the search term.
        XCTAssertTrue(OverpassClient.matches(OverpassClient.normalise("Willis Tower (Sears)"),
                                             OverpassClient.normalise("Willis Tower")))
    }

    func testUnrelatedNamesDoNotMatch() {
        XCTAssertFalse(OverpassClient.matches(OverpassClient.normalise("Empire State Building"),
                                              OverpassClient.normalise("Chrysler Building")))
        // Two buildings whose names reduce to nothing but noise words must not
        // collapse into each other.
        XCTAssertFalse(OverpassClient.matches(OverpassClient.normalise("The Building"),
                                              OverpassClient.normalise("The Tower")))
    }

    // MARK: Geometry

    func testContainsAgreesWithTheObviousCases() {
        let ring = square(centre: (0, 0), side: 10)
        XCTAssertTrue(OverpassClient.contains(ring, Coordinate2D(x: 0, y: 0)))
        XCTAssertTrue(OverpassClient.contains(ring, Coordinate2D(x: 4, y: -4)))
        XCTAssertFalse(OverpassClient.contains(ring, Coordinate2D(x: 6, y: 0)))
        XCTAssertFalse(OverpassClient.contains(ring, Coordinate2D(x: 0, y: 20)))
    }

    // MARK: Relations

    /// Multipolygon relations are how every building with a courtyard is
    /// mapped, and how most large ones are. Reading only `geometry` returned
    /// nothing for them, so exactly the buildings worth importing fell back to
    /// a generated rectangle.
    func testARelationsOuterWaysAreStitchedIntoOneRing() {
        func member(_ points: [(Double, Double)], role: String = "outer")
            -> OverpassResponse.Member {
            OverpassResponse.Member(type: "way", role: role,
                                    geometry: points.map {
                                        OverpassResponse.Point(lat: $0.1, lon: $0.0)
                                    })
        }
        // A square split into two halves, the second one listed backwards —
        // which is exactly how OSM stores them.
        let relation = OverpassResponse.Element(
            type: "relation", tags: ["building": "yes"], geometry: nil,
            members: [
                member([(0, 0), (10, 0), (10, 10)]),
                member([(0, 0), (0, 10), (10, 10)]),
                member([(50, 50), (60, 60)], role: "inner"),   // a hole, ignored
            ])

        let ring = relation.outerGeometry
        XCTAssertGreaterThanOrEqual(ring.count, 4)
        let projected = OverpassClient.localFootprint(ring, originLatitude: 0, originLongitude: 0)
        // Roughly a 10° square, so the exact metre area does not matter — that
        // it closed into one ring at all is the point.
        XCTAssertGreaterThan(OverpassClient.polygonArea(projected), 0)
    }

    func testAWayPrefersItsOwnGeometryOverMembers() {
        let element = way(points: [(0, 0), (1, 0), (1, 1), (0, 1)])
        XCTAssertEqual(element.outerGeometry.count, 4)
    }

    func testARelationWithNoUsableMembersHasNoGeometry() {
        let element = OverpassResponse.Element(type: "relation", tags: [:],
                                               geometry: nil, members: nil)
        XCTAssertTrue(element.outerGeometry.isEmpty)
    }

    // MARK: Massing from mapped parts

    /// The reason parts are fetched at all: they are the only free source of a
    /// real profile, and a tower on a podium is the shape they establish.
    func testMappedPartsProduceATowerOnAPodiumProfile() {
        let podium = square(centre: (0, 0), side: 40)     // 1600 m², 0–20 m
        let tower = square(centre: (0, 0), side: 20)      // 400 m², 0–100 m

        let profile = OverpassClient.massing(fromParts: [
            (ring: podium, levels: (bottom: 0, top: 20)),
            (ring: tower, levels: (bottom: 0, top: 100)),
        ], baseArea: 1600)

        guard let profile else { return XCTFail("two parts of different heights are a profile") }
        XCTAssertFalse(profile.isUniform)

        // Just above the ground the plan is the whole 2000 m²; above the podium
        // only the tower's 400 remains. Linear scale is the square root of the
        // area ratio, so about 0.45.
        XCTAssertEqual(profile.scale(at: 0.05), 1, accuracy: 0.05)
        XCTAssertEqual(profile.scale(at: 0.5), (400.0 / 2000).squareRoot(), accuracy: 0.05)

        // And it is a ledge, not a chamfer.
        let step = profile.largestDiscontinuity
        XCTAssertNotNil(step)
        XCTAssertEqual(step?.atHeightFraction ?? 0, 0.2, accuracy: 0.02)
    }

    /// One part is the building restated, and a prism is what the default
    /// already says.
    func testASinglePartIsNotAProfile() {
        XCTAssertNil(OverpassClient.massing(fromParts: [
            (ring: square(centre: (0, 0), side: 30), levels: (bottom: 0, top: 60)),
        ], baseArea: 900))
    }

    /// Parts of equal height stacked side by side describe a prism, and saying
    /// so with a profile would be noise.
    func testEqualHeightPartsProduceNoProfile() {
        XCTAssertNil(OverpassClient.massing(fromParts: [
            (ring: square(centre: (-10, 0), side: 18), levels: (bottom: 0, top: 40)),
            (ring: square(centre: (10, 0), side: 18), levels: (bottom: 0, top: 40)),
        ], baseArea: 648))
    }

    func testPartsWithNoHeightAreSkippedRatherThanAssumed() {
        XCTAssertNil(OverpassClient.massing(fromParts: [
            (ring: square(centre: (0, 0), side: 40), levels: nil),
            (ring: square(centre: (0, 0), side: 20), levels: nil),
        ], baseArea: 1600))
    }

    // MARK: Tag reading

    func testHeightsComeFromMetresFirstAndStoreysSecond() {
        XCTAssertEqual(OverpassClient.levels(of: ["height": "120", "min_height": "30"])?.top, 120)
        XCTAssertEqual(OverpassClient.levels(of: ["height": "120 m"])?.top, 120)
        XCTAssertEqual(OverpassClient.levels(of: ["building:levels": "10"])?.top ?? 0,
                       34, accuracy: 0.001)
        XCTAssertEqual(OverpassClient.levels(of: ["height": "60",
                                                  "building:min_level": "5"])?.bottom ?? 0,
                       17, accuracy: 0.001)
    }

    func testNonsensicalHeightsAreRefused() {
        XCTAssertNil(OverpassClient.levels(of: [:]))
        XCTAssertNil(OverpassClient.levels(of: ["height": "0"]))
        XCTAssertNil(OverpassClient.levels(of: ["height": "abc"]))
        // A part that starts above where it ends is bad data, not a building.
        XCTAssertNil(OverpassClient.levels(of: ["height": "10", "min_height": "40"]))
    }
}
