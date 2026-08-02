import XCTest
import SeismicCore
@testable import SeismicGeo

final class NetworkInversionTests: XCTestCase {

    // MARK: 80 — RANSAC location

    /// Builds arrivals from a known epicentre, so the answer is checkable.
    private func observations(epicentre: (lat: Double, lon: Double),
                              stations: [(Double, Double)],
                              originTime: Double = 100,
                              waveSpeed: Double = 6.0) -> [ArrivalConsensus.Observation] {
        stations.map { station in
            let distance = ArrivalConsensus.distanceKm(from: station, to: epicentre)
            return ArrivalConsensus.Observation(
                latitude: station.0, longitude: station.1,
                arrivalTime: originTime + distance / waveSpeed)
        }
    }

    func testItRecoversAKnownEpicentreFromCleanArrivals() {
        let epicentre = (lat: 37.78, lon: -122.42)
        let stations: [(Double, Double)] = [
            (37.85, -122.30), (37.70, -122.50), (37.90, -122.55),
            (37.65, -122.30), (37.80, -122.60),
        ]
        guard let result = ArrivalConsensus.locate(
            observations(epicentre: epicentre, stations: stations)) else {
            return XCTFail("No solution.")
        }

        XCTAssertEqual(result.latitude, epicentre.lat, accuracy: 0.05)
        XCTAssertEqual(result.longitude, epicentre.lon, accuracy: 0.05)
        XCTAssertEqual(result.originTime, 100, accuracy: 0.5)
        XCTAssertLessThan(result.residualRMS, 0.2)
        XCTAssertTrue(result.outliers.isEmpty)
    }

    /// The whole reason for RANSAC: one phone in a moving car must not be able
    /// to drag the answer.
    func testOneBadStationIsExcludedRatherThanAccommodated() {
        let epicentre = (lat: 37.78, lon: -122.42)
        let stations: [(Double, Double)] = [
            (37.85, -122.30), (37.70, -122.50), (37.90, -122.55),
            (37.65, -122.30), (37.80, -122.60), (37.75, -122.35),
        ]
        var readings = observations(epicentre: epicentre, stations: stations)
        // One clock four seconds out — twenty-four kilometres of error.
        readings[2].arrivalTime += 4.0

        guard let result = ArrivalConsensus.locate(readings, tolerance: 0.5) else {
            return XCTFail("No solution.")
        }

        XCTAssertEqual(result.outliers.count, 1)
        XCTAssertEqual(result.outliers.first?.id, readings[2].id)
        XCTAssertEqual(result.latitude, epicentre.lat, accuracy: 0.08)
        XCTAssertEqual(result.longitude, epicentre.lon, accuracy: 0.08)
    }

    /// And the comparison that shows it was worth doing: a plain least-squares
    /// fit over the same data, outlier included, lands somewhere else.
    func testTheOutlierWouldHaveMovedAPlainLeastSquaresFit() {
        let epicentre = (lat: 37.78, lon: -122.42)
        let stations: [(Double, Double)] = [
            (37.85, -122.30), (37.70, -122.50), (37.90, -122.55),
            (37.65, -122.30), (37.80, -122.60), (37.75, -122.35),
        ]
        var readings = observations(epicentre: epicentre, stations: stations)
        readings[2].arrivalTime += 4.0

        // Every station, no rejection — which is what least squares does.
        guard let naive = ArrivalConsensus.gridSearch(readings, waveSpeed: 6, coarse: false),
              let robust = ArrivalConsensus.locate(readings, tolerance: 0.5) else {
            return XCTFail()
        }

        let naiveError = ArrivalConsensus.distanceKm(
            from: (naive.lat, naive.lon), to: (epicentre.lat, epicentre.lon))
        let robustError = ArrivalConsensus.distanceKm(
            from: (robust.latitude, robust.longitude), to: (epicentre.lat, epicentre.lon))

        XCTAssertGreaterThan(naiveError, robustError * 2,
                             "Naive error \(naiveError) km, robust \(robustError) km.")
    }

    /// The app's own network screen makes this point with a button. Here it is
    /// as a number: three stations in a line produce a confident-looking
    /// solution that the azimuthal gap gives away.
    func testStationsInALineAreReportedAsGeometricallyUnsound() {
        let epicentre = (lat: 37.78, lon: -122.42)
        // All along one meridian, north of the epicentre.
        let stations: [(Double, Double)] = [
            (37.95, -122.42), (38.00, -122.42), (38.05, -122.42), (38.10, -122.42),
        ]
        guard let result = ArrivalConsensus.locate(
            observations(epicentre: epicentre, stations: stations)) else {
            return XCTFail("No solution.")
        }
        XCTAssertGreaterThan(result.azimuthalGap, 180)
        XCTAssertFalse(result.isGeometricallySound)
    }

    func testAWellSurroundedEpicentreIsReportedAsSound() {
        let epicentre = (lat: 37.78, lon: -122.42)
        let stations: [(Double, Double)] = [
            (37.95, -122.42), (37.61, -122.42), (37.78, -122.20), (37.78, -122.64),
        ]
        guard let result = ArrivalConsensus.locate(
            observations(epicentre: epicentre, stations: stations)) else {
            return XCTFail()
        }
        XCTAssertLessThan(result.azimuthalGap, 180)
        XCTAssertTrue(result.isGeometricallySound)
    }

    func testTooFewStationsReturnsNothingRatherThanAGuess() {
        let stations: [(Double, Double)] = [(37.8, -122.4), (37.9, -122.5)]
        XCTAssertNil(ArrivalConsensus.locate(
            observations(epicentre: (37.78, -122.42), stations: stations)))
    }

    func testAzimuthalGapCountsTheWrapAroundGap() {
        // Three stations bunched in the north-east: the big gap is the one that
        // crosses zero degrees, which a naive sorted scan misses.
        let bunched = [
            ArrivalConsensus.Observation(latitude: 1.0, longitude: 0.1, arrivalTime: 0),
            ArrivalConsensus.Observation(latitude: 1.0, longitude: 0.2, arrivalTime: 0),
            ArrivalConsensus.Observation(latitude: 1.0, longitude: 0.3, arrivalTime: 0),
        ]
        let gap = ArrivalConsensus.azimuthalGap(of: bunched, fromLatitude: 0, longitude: 0)
        XCTAssertGreaterThan(gap, 300)
    }

    // MARK: 81 — Intensity field

    func testStandingOnAReportReturnsThatReport() {
        let reports = [
            IntensityField.Report(latitude: 37.78, longitude: -122.42, value: 7),
            IntensityField.Report(latitude: 37.90, longitude: -122.50, value: 3),
        ]
        guard let estimate = IntensityField.estimate(
            at: 37.78, longitude: -122.42, from: reports) else { return XCTFail() }
        XCTAssertEqual(estimate.value, 7, accuracy: 1e-9)
        XCTAssertEqual(estimate.nearestReportKm, 0, accuracy: 0.02)
    }

    func testAPointBetweenTwoReportsLandsBetweenTheirValues() {
        let reports = [
            IntensityField.Report(latitude: 37.70, longitude: -122.40, value: 2),
            IntensityField.Report(latitude: 37.90, longitude: -122.40, value: 8),
        ]
        guard let estimate = IntensityField.estimate(
            at: 37.80, longitude: -122.40, from: reports) else { return XCTFail() }
        XCTAssertEqual(estimate.value, 5, accuracy: 0.5)
        XCTAssertEqual(estimate.supportingReports, 2)
    }

    /// The honesty requirement: an estimate far from any report must be marked
    /// as such, or a map draws a guess in the same colour as a measurement.
    func testConfidenceFallsWithDistanceFromTheNearestReport() {
        let reports = [IntensityField.Report(latitude: 37.78, longitude: -122.42, value: 6)]

        guard let close = IntensityField.estimate(at: 37.785, longitude: -122.42,
                                                  from: reports),
              let far = IntensityField.estimate(at: 37.95, longitude: -122.42,
                                                from: reports, searchRadiusKm: 100)
        else { return XCTFail() }

        XCTAssertGreaterThan(close.confidence, far.confidence)
        XCTAssertGreaterThan(far.nearestReportKm, close.nearestReportKm)
    }

    func testReportsBeyondTheSearchRadiusAreIgnored() {
        let reports = [IntensityField.Report(latitude: 40.0, longitude: -120.0, value: 9)]
        guard let estimate = IntensityField.estimate(
            at: 37.78, longitude: -122.42, from: reports, searchRadiusKm: 25) else {
            return XCTFail()
        }
        XCTAssertEqual(estimate.supportingReports, 0)
        XCTAssertLessThan(estimate.confidence, 0.35)
    }

    func testAHeavierWeightedReportPullsHarder() {
        let equal = [
            IntensityField.Report(latitude: 37.70, longitude: -122.4, value: 2, weight: 1),
            IntensityField.Report(latitude: 37.90, longitude: -122.4, value: 8, weight: 1),
        ]
        let trusted = [
            IntensityField.Report(latitude: 37.70, longitude: -122.4, value: 2, weight: 1),
            IntensityField.Report(latitude: 37.90, longitude: -122.4, value: 8, weight: 5),
        ]
        let a = IntensityField.estimate(at: 37.80, longitude: -122.4, from: equal)!
        let b = IntensityField.estimate(at: 37.80, longitude: -122.4, from: trusted)!
        XCTAssertGreaterThan(b.value, a.value)
    }

    func testGridCoversTheBoxAtTheRequestedResolution() {
        let reports = [IntensityField.Report(latitude: 37.78, longitude: -122.42, value: 6)]
        let grid = IntensityField.grid(reports: reports,
                                       minimumLatitude: 37.7, maximumLatitude: 37.9,
                                       minimumLongitude: -122.5, maximumLongitude: -122.3,
                                       resolution: 8)
        XCTAssertEqual(grid.count, 8)
        XCTAssertEqual(grid[0].count, 8)
    }

    // MARK: 82 — DBSCAN

    private struct Point { var lat: Double; var lon: Double }

    private func cluster(_ points: [Point], radiusKm: Double,
                         minimumPoints: Int = 2) -> DensityClustering.Result<Point> {
        DensityClustering.cluster(points, radiusKm: radiusKm,
                                  minimumPoints: minimumPoints,
                                  latitude: \.lat, longitude: \.lon)
    }

    func testTwoSeparatedGroupsBecomeTwoClusters() {
        let points = [
            Point(lat: 37.780, lon: -122.420), Point(lat: 37.781, lon: -122.421),
            Point(lat: 37.782, lon: -122.420),
            Point(lat: 37.900, lon: -122.500), Point(lat: 37.901, lon: -122.501),
            Point(lat: 37.902, lon: -122.500),
        ]
        let result = cluster(points, radiusKm: 1)
        XCTAssertEqual(result.clusters.count, 2)
        XCTAssertTrue(result.noise.isEmpty)
        XCTAssertEqual(result.clusters[0].items.count, 3)
        XCTAssertEqual(result.clusters[1].items.count, 3)
    }

    /// The behaviour a grid cannot produce: an isolated building stays
    /// isolated, rather than being drawn as a cluster of one.
    func testAnIsolatedPointIsNoiseRatherThanAClusterOfOne() {
        let points = [
            Point(lat: 37.780, lon: -122.420), Point(lat: 37.781, lon: -122.421),
            Point(lat: 37.782, lon: -122.420),
            Point(lat: 38.500, lon: -121.000),          // miles away
        ]
        let result = cluster(points, radiusKm: 1)
        XCTAssertEqual(result.clusters.count, 1)
        XCTAssertEqual(result.noise.count, 1)
        XCTAssertEqual(result.noise.first?.lat ?? 0, 38.5, accuracy: 1e-9)
    }

    /// A chain of points each near the next forms one cluster even though the
    /// ends are far apart — density-connected, not distance-from-a-centre. A
    /// terrace of tagged houses is exactly this shape.
    func testAChainOfPointsFormsASingleCluster() {
        let points = (0..<10).map { Point(lat: 37.78 + Double($0) * 0.004, lon: -122.42) }
        let result = cluster(points, radiusKm: 0.8)
        XCTAssertEqual(result.clusters.count, 1)
        XCTAssertEqual(result.clusters[0].items.count, 10)
    }

    /// The classic DBSCAN bug: a point first seen as noise, later found to be
    /// on the edge of a cluster, has to be adopted as a border point.
    func testABorderPointIsAdoptedRatherThanLeftAsNoise() {
        let points = [
            // A dense core.
            Point(lat: 37.7800, lon: -122.4200), Point(lat: 37.7801, lon: -122.4200),
            Point(lat: 37.7802, lon: -122.4200), Point(lat: 37.7803, lon: -122.4200),
            // One point on the fringe: within reach of the core, but with too
            // few neighbours of its own to seed anything.
            Point(lat: 37.7809, lon: -122.4200),
        ]
        let result = cluster(points, radiusKm: 0.09, minimumPoints: 3)
        XCTAssertEqual(result.clusters.count, 1)
        XCTAssertEqual(result.clusters[0].items.count, 5,
                       "The border point was left as noise.")
    }

    func testAnEmptyInputProducesNothingRatherThanCrashing() {
        let result = cluster([], radiusKm: 1)
        XCTAssertTrue(result.clusters.isEmpty)
        XCTAssertTrue(result.noise.isEmpty)
    }

    func testClusterCentreIsTheMeanOfItsMembers() {
        let points = [
            Point(lat: 37.780, lon: -122.420), Point(lat: 37.782, lon: -122.422),
        ]
        let result = cluster(points, radiusKm: 1, minimumPoints: 1)
        XCTAssertEqual(result.clusters.count, 1)
        XCTAssertEqual(result.clusters[0].centreLatitude, 37.781, accuracy: 1e-9)
        XCTAssertEqual(result.clusters[0].centreLongitude, -122.421, accuracy: 1e-9)
    }
}
