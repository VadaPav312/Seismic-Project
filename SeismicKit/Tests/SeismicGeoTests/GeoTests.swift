import XCTest
@testable import SeismicGeo
import SeismicCore

// Algorithms 35–38, plus the spatial infrastructure the map depends on.

final class GeodesyTests: XCTestCase {

    private let london = GeoPoint(latitude: 51.5074, longitude: -0.1278)
    private let paris = GeoPoint(latitude: 48.8566, longitude: 2.3522)
    private let sanFrancisco = GeoPoint(latitude: 37.7749, longitude: -122.4194)
    private let tokyo = GeoPoint(latitude: 35.6762, longitude: 139.6503)

    func testKnownCityDistances() {
        // London–Paris is about 344 km; SF–Tokyo about 8,270 km.
        XCTAssertEqual(Geodesy.distanceKm(london, paris), 344, accuracy: 5)
        XCTAssertEqual(Geodesy.distanceKm(sanFrancisco, tokyo), 8270, accuracy: 40)
    }

    func testDistanceIsZeroToItselfAndSymmetric() {
        XCTAssertEqual(Geodesy.distance(london, london), 0, accuracy: 1e-6)
        XCTAssertEqual(Geodesy.distance(london, paris), Geodesy.distance(paris, london),
                       accuracy: 1e-6)
    }

    func testShortDistancesAreAccurate() {
        // Two points 100 m apart — the scale that matters for neighbouring
        // buildings, and where the naive spherical-cosine formula loses precision.
        let a = GeoPoint(latitude: 37.7749, longitude: -122.4194)
        let b = Geodesy.destination(from: a, distanceMetres: 100, bearingDegrees: 45)
        XCTAssertEqual(Geodesy.distance(a, b), 100, accuracy: 0.01)
    }

    func testBearingCardinalDirections() {
        let origin = GeoPoint(latitude: 0, longitude: 0)
        XCTAssertEqual(Geodesy.bearing(from: origin, to: GeoPoint(latitude: 1, longitude: 0)),
                       0, accuracy: 0.01)
        XCTAssertEqual(Geodesy.bearing(from: origin, to: GeoPoint(latitude: 0, longitude: 1)),
                       90, accuracy: 0.01)
        XCTAssertEqual(Geodesy.bearing(from: origin, to: GeoPoint(latitude: -1, longitude: 0)),
                       180, accuracy: 0.01)
        XCTAssertEqual(Geodesy.bearing(from: origin, to: GeoPoint(latitude: 0, longitude: -1)),
                       270, accuracy: 0.01)
    }

    func testCompassPointLabels() {
        XCTAssertEqual(Geodesy.compassPoint(0), "N")
        XCTAssertEqual(Geodesy.compassPoint(45), "NE")
        XCTAssertEqual(Geodesy.compassPoint(180), "S")
        XCTAssertEqual(Geodesy.compassPoint(359), "N")
    }

    func testDestinationRoundTripsWithDistanceAndBearing() {
        let start = GeoPoint(latitude: 34.05, longitude: -118.24)
        for bearing in stride(from: 0.0, to: 360, by: 45) {
            let end = Geodesy.destination(from: start, distanceMetres: 5000,
                                          bearingDegrees: bearing)
            XCTAssertEqual(Geodesy.distance(start, end), 5000, accuracy: 1)
            XCTAssertEqual(Geodesy.bearing(from: start, to: end), bearing, accuracy: 0.5)
        }
    }

    func testHypocentralDistanceIncludesDepth() {
        let station = GeoPoint(latitude: 0, longitude: 0)
        let directlyBelow = GeoPoint(latitude: 0, longitude: 0, depth: 10_000)
        XCTAssertEqual(Geodesy.hypocentralDistanceKm(from: station, to: directlyBelow),
                       10, accuracy: 0.01)
    }

    func testAntimeridianIsHandled() {
        let a = GeoPoint(latitude: 0, longitude: 179.9)
        let b = GeoPoint(latitude: 0, longitude: -179.9)
        // 0.2 degrees apart across the date line, about 22 km — not 40,000 km.
        XCTAssertEqual(Geodesy.distanceKm(a, b), 22.2, accuracy: 1)
    }

    func testValidityCheckRejectsNonsense() {
        XCTAssertTrue(GeoPoint(latitude: 45, longitude: 90).isValid)
        XCTAssertFalse(GeoPoint(latitude: 91, longitude: 0).isValid)
        XCTAssertFalse(GeoPoint(latitude: .nan, longitude: 0).isValid)
    }
}

final class EpicentralDistanceTests: XCTestCase {

    func testRuleOfThumbHoldsRoughly() {
        // The classic field rule: distance in km ≈ 8 × the S−P gap in seconds.
        XCTAssertEqual(EpicentralDistance.kilometresPerSecondOfSMinusP, 8.1, accuracy: 0.3)
    }

    func testKnownGapGivesKnownDistance() {
        let result = EpicentralDistance.from(sMinusP: 10)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.distanceKm, 81, accuracy: 3)
        XCTAssertTrue(result!.range.contains(81))
    }

    func testUncertaintyGrowsWithDistanceAndFallsWithPickQuality() {
        let near = EpicentralDistance.from(sMinusP: 2, pickConfidence: 1)!
        let far = EpicentralDistance.from(sMinusP: 40, pickConfidence: 1)!
        XCTAssertLessThan(near.uncertaintyKm, far.uncertaintyKm)

        let sloppy = EpicentralDistance.from(sMinusP: 10, pickConfidence: 0.1)!
        let clean = EpicentralDistance.from(sMinusP: 10, pickConfidence: 1.0)!
        XCTAssertGreaterThan(sloppy.uncertaintyKm, clean.uncertaintyKm)
    }

    func testInvalidGapReturnsNil() {
        XCTAssertNil(EpicentralDistance.from(sMinusP: 0))
        XCTAssertNil(EpicentralDistance.from(sMinusP: -3))
        XCTAssertNil(EpicentralDistance.from(sMinusP: .nan))
    }

    func testWarningTimeGrowsWithDistanceAndIsNeverNegative() {
        let near = EpicentralDistance.warningSeconds(distanceKm: 20)
        let far = EpicentralDistance.warningSeconds(distanceKm: 200)
        XCTAssertGreaterThan(far, near)
        XCTAssertGreaterThanOrEqual(EpicentralDistance.warningSeconds(distanceKm: 5,
                                                                     elapsedSinceP: 100), 0)
    }

    func testExplanationSaysItIsACircleNotAPoint() {
        let result = EpicentralDistance.from(sMinusP: 6)!
        XCTAssertTrue(result.explanation.lowercased().contains("circle"))
    }
}

final class TriangulationTests: XCTestCase {

    /// Builds a set of arrivals consistent with a known epicentre, so the solver
    /// has a right answer to be measured against.
    private func arrivals(for source: GeoPoint, stations: [GeoPoint],
                          originTime: Date, noise: Double = 0,
                          seed: UInt64 = 1) -> [NodeArrival] {
        var rng = SeededRandom(seed: seed)
        return stations.enumerated().map { index, station in
            let distance = Geodesy.hypocentralDistanceKm(from: station, to: source)
            let travel = distance / EpicentralDistance.vP
            let error = noise > 0 ? rng.gaussian(sd: noise) : 0
            return NodeArrival(id: "node-\(index)", location: station,
                               pArrivalTime: originTime.addingTimeInterval(travel + error))
        }
    }

    func testRecoversAKnownEpicentre() {
        let source = GeoPoint(latitude: 37.80, longitude: -122.30, depth: 10_000)
        let stations = [
            GeoPoint(latitude: 37.90, longitude: -122.50),
            GeoPoint(latitude: 37.60, longitude: -122.10),
            GeoPoint(latitude: 38.00, longitude: -122.00),
            GeoPoint(latitude: 37.55, longitude: -122.60),
        ]
        let origin = Date()
        let solution = Triangulation.locate(arrivals(for: source, stations: stations,
                                                     originTime: origin))
        XCTAssertNotNil(solution)
        XCTAssertLessThan(Geodesy.distanceKm(solution!.epicentre, source), 8)
        XCTAssertLessThan(solution!.rmsResidualSeconds, 0.5)
        XCTAssertEqual(solution!.originTime.timeIntervalSince(origin), 0, accuracy: 2)
        XCTAssertTrue(solution!.isWellConstrained)
    }

    func testFewerThanThreeStationsCannotLocate() {
        let source = GeoPoint(latitude: 0, longitude: 0)
        let two = [GeoPoint(latitude: 0.1, longitude: 0), GeoPoint(latitude: 0, longitude: 0.1)]
        XCTAssertNil(Triangulation.locate(arrivals(for: source, stations: two,
                                                   originTime: Date())))
    }

    func testNoisyArrivalsStillLocateButWithLargerResidual() {
        let source = GeoPoint(latitude: 35.0, longitude: 139.0, depth: 10_000)
        let stations = [
            GeoPoint(latitude: 35.3, longitude: 139.3),
            GeoPoint(latitude: 34.7, longitude: 138.8),
            GeoPoint(latitude: 35.4, longitude: 138.6),
            GeoPoint(latitude: 34.6, longitude: 139.4),
        ]
        let clean = Triangulation.locate(arrivals(for: source, stations: stations,
                                                  originTime: Date()))!
        let noisy = Triangulation.locate(arrivals(for: source, stations: stations,
                                                  originTime: Date(), noise: 0.5, seed: 9))!
        XCTAssertGreaterThan(noisy.rmsResidualSeconds, clean.rmsResidualSeconds)
        XCTAssertLessThan(Geodesy.distanceKm(noisy.epicentre, source), 40)
    }

    func testClusteredStationsAreReportedAsPoorlyConstrained() {
        // All four sensors on the same block: the times fit, but the geometry
        // cannot resolve direction. The solver must say so rather than pretend.
        let source = GeoPoint(latitude: 40.0, longitude: -74.0, depth: 10_000)
        let stations = [
            GeoPoint(latitude: 40.50, longitude: -73.50),
            GeoPoint(latitude: 40.505, longitude: -73.505),
            GeoPoint(latitude: 40.51, longitude: -73.50),
            GeoPoint(latitude: 40.50, longitude: -73.51),
        ]
        let solution = Triangulation.locate(arrivals(for: source, stations: stations,
                                                     originTime: Date()))
        XCTAssertNotNil(solution)
        XCTAssertGreaterThan(Triangulation.azimuthalGap(from: solution!.epicentre,
                                                        to: stations), 180)
        XCTAssertFalse(solution!.isWellConstrained)
    }

    func testAzimuthalGapIsCorrectForEvenlySpacedStations() {
        let centre = GeoPoint(latitude: 0, longitude: 0)
        let stations = (0..<4).map {
            Geodesy.destination(from: centre, distanceMetres: 50_000,
                                bearingDegrees: Double($0) * 90)
        }
        XCTAssertEqual(Triangulation.azimuthalGap(from: centre, to: stations), 90, accuracy: 1)
    }

    func testAzimuthalGapOfASingleStationIsFullCircle() {
        XCTAssertEqual(Triangulation.azimuthalGap(from: GeoPoint(latitude: 0, longitude: 0),
                                                  to: [GeoPoint(latitude: 1, longitude: 1)]), 360)
    }
}

final class AttenuationTests: XCTestCase {

    func testShakingFallsWithDistance() {
        let near = AttenuationModel.predict(magnitude: 6.5, distanceKm: 10)
        let far = AttenuationModel.predict(magnitude: 6.5, distanceKm: 200)
        XCTAssertGreaterThan(near.pga, far.pga * 8)
        XCTAssertGreaterThan(near.intensity, far.intensity)
    }

    func testShakingRisesWithMagnitude() {
        let small = AttenuationModel.predict(magnitude: 4.5, distanceKm: 30)
        let large = AttenuationModel.predict(magnitude: 7.0, distanceKm: 30)
        XCTAssertGreaterThan(large.pga, small.pga * 3)
    }

    func testSoftSoilAmplifies() {
        let rock = AttenuationModel.predict(magnitude: 6, distanceKm: 30, soil: .rock)
        let soft = AttenuationModel.predict(magnitude: 6, distanceKm: 30, soil: .softSoil)
        XCTAssertGreaterThan(soft.pga, rock.pga * 2)
    }

    func testNearSourceDoesNotBlowUpToInfinity() {
        let overhead = AttenuationModel.predict(magnitude: 7.5, distanceKm: 0, depthKm: 5)
        XCTAssertTrue(overhead.pga.isFinite)
        // Even directly above a large rupture, PGA does not exceed a few g.
        XCTAssertLessThan(overhead.pga, 5 * gravity)
    }

    func testUncertaintyBandBracketsThePrediction() {
        let prediction = AttenuationModel.predict(magnitude: 6, distanceKm: 40)
        XCTAssertTrue(prediction.plausibleRange.contains(prediction.pga))
        // Roughly a factor of two either way.
        XCTAssertEqual(prediction.plausibleRange.upperBound / prediction.pga, 1.82, accuracy: 0.1)
    }

    func testExplanationIsHonestAboutVariability() {
        let prediction = AttenuationModel.predict(magnitude: 6, distanceKm: 40)
        XCTAssertTrue(prediction.explanation.contains("factor of two"))
        XCTAssertFalse(prediction.mercalli.consequence.isEmpty)
    }

    func testBlindZoneIsAcknowledged() {
        let radius = AttenuationModel.blindZoneRadiusKm(systemLatency: 1.5)
        XCTAssertGreaterThan(radius, 5)
        XCTAssertLessThan(radius, 40)
        // Inside the blind zone there is no warning time left.
        XCTAssertEqual(AttenuationModel.warningTime(distanceKm: radius * 0.5), 0, accuracy: 1e-9)
    }
}

final class GeohashTests: XCTestCase {

    func testKnownGeohashes() {
        // The canonical example from the original specification.
        XCTAssertEqual(Geohash.encode(latitude: 57.64911, longitude: 10.40744, precision: 11),
                       "u4pruydqqvj")
        XCTAssertTrue(Geohash.encode(latitude: 37.7749, longitude: -122.4194,
                                     precision: 5).hasPrefix("9q8y"))
    }

    func testDecodeRoundTripsWithinTheCellSize() {
        let point = GeoPoint(latitude: 51.5074, longitude: -0.1278)
        let hash = Geohash.encode(point, precision: 9)
        let decoded = Geohash.decode(hash)
        XCTAssertNotNil(decoded)
        XCTAssertLessThan(Geodesy.distance(point, decoded!.centre), 5)
    }

    func testLongerPrefixMeansSmallerCell() {
        let point = GeoPoint(latitude: 40, longitude: -74)
        var previous = Double.infinity
        for precision in 3...9 {
            let hash = Geohash.encode(point, precision: precision)
            let decoded = Geohash.decode(hash)!
            XCTAssertLessThan(decoded.latitudeError, previous)
            previous = decoded.latitudeError
        }
    }

    func testNearbyPointsSharePrefix() {
        let a = GeoPoint(latitude: 37.7749, longitude: -122.4194)
        let b = Geodesy.destination(from: a, distanceMetres: 50, bearingDegrees: 90)
        let hashA = Geohash.encode(a, precision: 6)
        let hashB = Geohash.encode(b, precision: 6)
        XCTAssertEqual(String(hashA.prefix(5)), String(hashB.prefix(5)))
    }

    func testNeighboursSurroundTheCell() {
        let hash = Geohash.encode(latitude: 37.7749, longitude: -122.4194, precision: 6)
        let neighbours = Geohash.neighbours(of: hash)
        XCTAssertTrue(neighbours.contains(hash))
        XCTAssertGreaterThanOrEqual(neighbours.count, 8)
    }

    func testInvalidCharactersDecodeToNil() {
        XCTAssertNil(Geohash.decode("aeilo!"))
    }

    func testPrecisionForRadiusIsMonotonic() {
        XCTAssertGreaterThan(Geohash.precision(forRadiusMetres: 10),
                             Geohash.precision(forRadiusMetres: 10_000))
    }
}

final class SpatialIndexTests: XCTestCase {

    private struct Marker: Identifiable { let id: Int }

    func testRadiusQueryFindsOnlyWhatIsInRange() {
        var index = SpatialIndex<Marker>(precision: 7)
        let centre = GeoPoint(latitude: 37.7749, longitude: -122.4194)

        // One marker every 100 m going east, out to 2 km.
        for i in 0..<20 {
            let point = Geodesy.destination(from: centre,
                                            distanceMetres: Double(i + 1) * 100,
                                            bearingDegrees: 90)
            index.insert(Marker(id: i), at: point)
        }
        XCTAssertEqual(index.count, 20)

        let within = index.items(near: centre, radiusMetres: 550)
        XCTAssertEqual(within.count, 5)
        XCTAssertTrue(within.allSatisfy { $0.distance <= 550 })
        // Sorted nearest first.
        XCTAssertEqual(within.map(\.item.id), [0, 1, 2, 3, 4])
    }

    func testQueryAcrossACellBoundaryStillFindsNeighbours() {
        var index = SpatialIndex<Marker>(precision: 6)
        // Two points 20 m apart, deliberately placed to straddle a cell edge.
        let a = GeoPoint(latitude: 37.775, longitude: -122.4194)
        let b = Geodesy.destination(from: a, distanceMetres: 20, bearingDegrees: 0)
        index.insert(Marker(id: 1), at: a)
        index.insert(Marker(id: 2), at: b)

        XCTAssertEqual(index.items(near: a, radiusMetres: 100).count, 2)
    }

    func testEmptyIndexReturnsNothingRatherThanCrashing() {
        let index = SpatialIndex<Marker>()
        XCTAssertTrue(index.items(near: GeoPoint(latitude: 0, longitude: 0),
                                  radiusMetres: 1000).isEmpty)
    }
}

final class ClusteringTests: XCTestCase {

    func testNearbyMarkersMergeAndDistantOnesDoNot() {
        let centre = GeoPoint(latitude: 37.7749, longitude: -122.4194)
        var items: [(item: Int, point: GeoPoint)] = []
        // Five markers within 30 m of each other.
        for i in 0..<5 {
            items.append((i, Geodesy.destination(from: centre, distanceMetres: Double(i) * 5,
                                                 bearingDegrees: 45)))
        }
        // One marker 5 km away.
        items.append((99, Geodesy.destination(from: centre, distanceMetres: 5000,
                                              bearingDegrees: 90)))

        let clusters = MarkerClustering.cluster(items, cellSizeMetres: 500)
        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(clusters.map(\.count).sorted(), [1, 5])
    }

    func testClusterCentreIsTheMeanOfItsMembers() {
        let items = [(1, GeoPoint(latitude: 10.0, longitude: 20.0)),
                     (2, GeoPoint(latitude: 10.002, longitude: 20.002))]
        let clusters = MarkerClustering.cluster(items.map { (item: $0.0, point: $0.1) },
                                                cellSizeMetres: 5000)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].centre.latitude, 10.001, accuracy: 1e-9)
    }

    func testClusteringIsStableUnderReordering() {
        // Panning the map must not make markers jump between clusters.
        let centre = GeoPoint(latitude: 34, longitude: -118)
        var rng = SeededRandom(seed: 3)
        let points = (0..<50).map { _ in
            Geodesy.destination(from: centre, distanceMetres: rng.uniform(0, 3000),
                                bearingDegrees: rng.uniform(0, 360))
        }
        let forward = MarkerClustering.cluster(points.enumerated().map { (item: $0.offset, point: $0.element) },
                                               cellSizeMetres: 400)
        let backward = MarkerClustering.cluster(points.enumerated().reversed().map { (item: $0.offset, point: $0.element) },
                                                cellSizeMetres: 400)
        XCTAssertEqual(forward.map(\.id).sorted(), backward.map(\.id).sorted())
        XCTAssertEqual(forward.map(\.count).sorted(), backward.map(\.count).sorted())
    }

    func testZeroCellSizeDegradesToOneClusterPerMarker() {
        let items = [(1, GeoPoint(latitude: 0, longitude: 0)),
                     (2, GeoPoint(latitude: 0, longitude: 0))]
        let clusters = MarkerClustering.cluster(items.map { (item: $0.0, point: $0.1) },
                                                cellSizeMetres: 0)
        XCTAssertEqual(clusters.count, 2)
    }

    func testEmptyInputGivesEmptyOutput() {
        XCTAssertTrue(MarkerClustering.cluster([(item: 1, point: GeoPoint(latitude: 0, longitude: 0))]
            .prefix(0).map { $0 }, cellSizeMetres: 100).isEmpty)
    }
}

final class PolygonTests: XCTestCase {

    private let unitSquare = [
        Coordinate2D(x: 0, y: 0), Coordinate2D(x: 10, y: 0),
        Coordinate2D(x: 10, y: 10), Coordinate2D(x: 0, y: 10),
    ]

    func testShoelaceAreaOfAKnownSquare() {
        XCTAssertEqual(Polygon.area(unitSquare), 100, accuracy: 1e-12)
    }

    func testShoelaceAreaOfATriangle() {
        let triangle = [Coordinate2D(x: 0, y: 0), Coordinate2D(x: 4, y: 0),
                        Coordinate2D(x: 0, y: 3)]
        XCTAssertEqual(Polygon.area(triangle), 6, accuracy: 1e-12)
    }

    func testWindingOrderIsDetectedAndCorrectable() {
        XCTAssertTrue(Polygon.isCounterClockwise(unitSquare))
        let reversed = Array(unitSquare.reversed())
        XCTAssertFalse(Polygon.isCounterClockwise(reversed))
        XCTAssertTrue(Polygon.isCounterClockwise(Polygon.madeCounterClockwise(reversed)))
        // Correcting the winding must not change the area.
        XCTAssertEqual(Polygon.area(Polygon.madeCounterClockwise(reversed)), 100, accuracy: 1e-12)
    }

    func testCentroidOfASquareIsItsMiddle() {
        let centroid = Polygon.centroid(unitSquare)
        XCTAssertEqual(centroid.x, 5, accuracy: 1e-9)
        XCTAssertEqual(centroid.y, 5, accuracy: 1e-9)
    }

    func testPerimeterOfASquare() {
        XCTAssertEqual(Polygon.perimeter(unitSquare), 40, accuracy: 1e-12)
    }

    func testPointInPolygonInsideOutsideAndOnEdge() {
        XCTAssertTrue(Polygon.contains(Coordinate2D(x: 5, y: 5), polygon: unitSquare))
        XCTAssertFalse(Polygon.contains(Coordinate2D(x: 15, y: 5), polygon: unitSquare))
        XCTAssertFalse(Polygon.contains(Coordinate2D(x: -1, y: -1), polygon: unitSquare))
        XCTAssertFalse(Polygon.contains(Coordinate2D(x: 5, y: 5), polygon: []))
    }

    func testPointInConcavePolygonIsHandledCorrectly() {
        // An L-shape: the point in the notch must read as outside.
        let lShape = [
            Coordinate2D(x: 0, y: 0), Coordinate2D(x: 10, y: 0),
            Coordinate2D(x: 10, y: 4), Coordinate2D(x: 4, y: 4),
            Coordinate2D(x: 4, y: 10), Coordinate2D(x: 0, y: 10),
        ]
        XCTAssertTrue(Polygon.contains(Coordinate2D(x: 2, y: 2), polygon: lShape))
        XCTAssertTrue(Polygon.contains(Coordinate2D(x: 8, y: 2), polygon: lShape))
        XCTAssertFalse(Polygon.contains(Coordinate2D(x: 8, y: 8), polygon: lShape))
    }

    func testRayThroughAVertexIsNotDoubleCounted() {
        // A ray at exactly a vertex height is the classic ray-casting bug.
        let diamond = [Coordinate2D(x: 0, y: 5), Coordinate2D(x: 5, y: 0),
                       Coordinate2D(x: 10, y: 5), Coordinate2D(x: 5, y: 10)]
        XCTAssertTrue(Polygon.contains(Coordinate2D(x: 5, y: 5), polygon: diamond))
        XCTAssertFalse(Polygon.contains(Coordinate2D(x: -1, y: 5), polygon: diamond))
        XCTAssertFalse(Polygon.contains(Coordinate2D(x: 11, y: 5), polygon: diamond))
    }

    func testBoundingBox() {
        let box = Polygon.boundingBox(unitSquare)
        XCTAssertEqual(box.min.x, 0); XCTAssertEqual(box.max.x, 10)
        XCTAssertEqual(box.min.y, 0); XCTAssertEqual(box.max.y, 10)
    }

    func testLocalMetreConversionPreservesArea() {
        // A roughly 40 m × 40 m building outline near San Francisco.
        let metresPerLat = Geodesy.metresPerDegreeLatitude
        let metresPerLon = Geodesy.metresPerDegreeLongitude(atLatitude: 37.7749)
        let ring = [
            GeoPoint(latitude: 37.7749, longitude: -122.4194),
            GeoPoint(latitude: 37.7749, longitude: -122.4194 + 40 / metresPerLon),
            GeoPoint(latitude: 37.7749 + 40 / metresPerLat, longitude: -122.4194 + 40 / metresPerLon),
            GeoPoint(latitude: 37.7749 + 40 / metresPerLat, longitude: -122.4194),
        ]
        let (local, _) = Polygon.toLocalMetres(ring)
        XCTAssertEqual(Polygon.area(local), 1600, accuracy: 5)
    }

    func testSimplificationReducesVerticesWithoutDestroyingArea() {
        // A circle approximated by 200 points; simplification should keep the
        // shape but shed most of the vertices.
        let circle = (0..<200).map { i -> Coordinate2D in
            let θ = Double(i) / 200 * 2 * .pi
            return Coordinate2D(x: 20 * cos(θ), y: 20 * sin(θ))
        }
        let simplified = Polygon.simplify(circle, tolerance: 0.5)
        XCTAssertLessThan(simplified.count, circle.count)
        XCTAssertGreaterThanOrEqual(simplified.count, 3)
        XCTAssertEqual(Polygon.area(simplified), Polygon.area(circle),
                       accuracy: Polygon.area(circle) * 0.1)
    }

    func testDegenerateInputsDoNotCrash() {
        XCTAssertEqual(Polygon.area([]), 0)
        XCTAssertEqual(Polygon.area([Coordinate2D(x: 1, y: 1)]), 0)
        XCTAssertEqual(Polygon.perimeter([]), 0)
        _ = Polygon.centroid([])
        _ = Polygon.simplify([Coordinate2D(x: 0, y: 0)], tolerance: 1)
    }
}

final class LocationPrivacyTests: XCTestCase {

    func testApproximateSnapsToAGridCell() {
        let exact = GeoPoint(latitude: 37.774929, longitude: -122.419416)
        let approximate = LocationPrivacy.approximate(exact, precision: 6)
        let error = Geodesy.distance(exact, approximate)
        XCTAssertGreaterThan(error, 0)
        XCTAssertLessThan(error, 800)
    }

    func testApproximationIsDeterministicSoRepeatedPublishingLeaksNothingMore() {
        // This is the whole point: a random jitter could be averaged away by
        // anyone collecting several reports. A fixed grid cell cannot.
        let exact = GeoPoint(latitude: 51.5074, longitude: -0.1278)
        let first = LocationPrivacy.approximate(exact)
        for _ in 0..<50 {
            XCTAssertEqual(LocationPrivacy.approximate(exact).latitude, first.latitude)
            XCTAssertEqual(LocationPrivacy.approximate(exact).longitude, first.longitude)
        }
    }

    func testNearbyPointsInTheSameCellBecomeIdentical() {
        let a = GeoPoint(latitude: 37.7749, longitude: -122.4194)
        let b = Geodesy.destination(from: a, distanceMetres: 30, bearingDegrees: 0)
        XCTAssertEqual(LocationPrivacy.approximate(a, precision: 5).latitude,
                       LocationPrivacy.approximate(b, precision: 5).latitude)
    }

    func testPrivateLevelPublishesNothingAtAll() {
        let point = GeoPoint(latitude: 1, longitude: 2)
        XCTAssertNil(LocationPrivacy.apply(.privateOnly, to: point))
        XCTAssertEqual(LocationPrivacy.apply(.exact, to: point), point)
        XCTAssertNotEqual(LocationPrivacy.apply(.approximate, to: point), point)
    }

    func testEveryPrivacyLevelExplainsItself() {
        for level in BuildingModel.PrivacyLevel.allCases {
            XCTAssertFalse(LocationPrivacy.description(for: level).isEmpty)
            XCTAssertFalse(level.explanation.isEmpty)
        }
    }
}
