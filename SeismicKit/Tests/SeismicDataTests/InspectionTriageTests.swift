import XCTest
import SeismicCore
@testable import SeismicData

/// The visit order after an event.
///
/// Worth testing carefully because the ordering encodes a judgement — that an
/// unchecked amber building outranks an evacuated red one — and a judgement
/// nobody has written down is a judgement that gets quietly reversed by the
/// next person to touch the scoring.
final class InspectionTriageTests: XCTestCase {

    private func tag(_ verdict: SafetyVerdict,
                     lat: Double = 0, lon: Double = 0,
                     tier: VerificationTier = .unverified,
                     agreements: Int = 0, disputes: Int = 0, photos: Int = 0,
                     postedAgo: TimeInterval = 600,
                     buildingID: UUID? = nil) -> CommunityTag {
        CommunityTag(buildingID: buildingID, verdict: verdict,
                     latitude: lat, longitude: lon, buildingLabel: "Test",
                     postedAt: Date().addingTimeInterval(-postedAgo), tier: tier,
                     agreementCount: agreements, disputeCount: disputes,
                     photoCount: photos)
    }

    // MARK: Ordering

    func testAnUncheckedBuildingOutranksEverything() {
        let unknown = InspectionTriage.priority(for: tag(.needsInspection), storeys: 4)
        let amber = InspectionTriage.priority(for: tag(.amber), storeys: 4)
        let red = InspectionTriage.priority(for: tag(.red), storeys: 4)
        let green = InspectionTriage.priority(for: tag(.green), storeys: 4)

        XCTAssertGreaterThan(unknown, amber)
        XCTAssertGreaterThan(amber, red)
        XCTAssertGreaterThan(red, green)
    }

    /// The one that looks wrong until you say it out loud. A red building has
    /// been emptied — the safe action is already being taken. An amber one has
    /// people inside on the strength of a guess.
    func testAmberOutranksRedBecauseRedIsAlreadyEvacuated() {
        XCTAssertGreaterThan(InspectionTriage.urgency(of: .amber),
                             InspectionTriage.urgency(of: .red))
    }

    func testGreenIsStillOnTheListRatherThanDropped() {
        let stops = InspectionTriage.queue(tags: [tag(.green)])
        XCTAssertEqual(stops.count, 1)
    }

    // MARK: Exposure

    func testTallerBuildingsOutrankShorterOnesOfTheSameColour() {
        let tall = InspectionTriage.priority(for: tag(.amber), storeys: 18)
        let short = InspectionTriage.priority(for: tag(.amber), storeys: 2)
        XCTAssertGreaterThan(tall, short)
    }

    /// An unknown building must not be quietly treated as an empty one.
    func testAnUnknownBuildingSitsBetweenTallAndShortRatherThanLast() {
        let tall = InspectionTriage.priority(for: tag(.amber), storeys: 30)
        let unknown = InspectionTriage.priority(for: tag(.amber), storeys: nil)
        let short = InspectionTriage.priority(for: tag(.amber), storeys: 1)
        XCTAssertLessThan(unknown, tall)
        XCTAssertGreaterThan(unknown, short)
    }

    func testExposureFlattensSoOneTowerCannotOutrankATerrace() {
        let twenty = InspectionTriage.exposure(storeys: 20) ?? 0
        let forty = InspectionTriage.exposure(storeys: 40) ?? 0
        let two = InspectionTriage.exposure(storeys: 2) ?? 0
        let eight = InspectionTriage.exposure(storeys: 8) ?? 0
        XCTAssertGreaterThan(eight - two, forty - twenty)
    }

    // MARK: Uncertainty

    func testADisputedTagOutranksAnAgreedOne() {
        let disputed = InspectionTriage.priority(
            for: tag(.amber, disputes: 3), storeys: 4)
        let agreed = InspectionTriage.priority(
            for: tag(.amber, tier: .professional, agreements: 4, photos: 3), storeys: 4)
        XCTAssertGreaterThan(disputed, agreed)
    }

    func testAProfessionalTagNeedsRevisitingLeastOfAll() {
        let professional = InspectionTriage.uncertainty(
            of: tag(.amber, tier: .professional, agreements: 3, photos: 2))
        let lone = InspectionTriage.uncertainty(of: tag(.amber))
        XCTAssertLessThan(professional, lone)
    }

    // MARK: The route

    func testTheRouteWalksNearestFirstWithinAPriorityBand() {
        // Three identical tags, so only distance can separate them.
        let near = tag(.amber, lat: 0.001, lon: 0)
        let middle = tag(.amber, lat: 0.004, lon: 0)
        let far = tag(.amber, lat: 0.010, lon: 0)

        let stops = InspectionTriage.queue(tags: [far, middle, near],
                                           start: (latitude: 0, longitude: 0))
        XCTAssertEqual(stops.map(\.tag.id), [near.id, middle.id, far.id])
    }

    /// And priority still beats proximity across bands: a distant unknown
    /// building is visited before a green one on the doorstep.
    func testPriorityBeatsProximityAcrossBands() {
        let closeGreen = tag(.green, lat: 0.0001, lon: 0)
        let distantUnknown = tag(.needsInspection, lat: 0.05, lon: 0)

        let stops = InspectionTriage.queue(tags: [closeGreen, distantUnknown],
                                           start: (latitude: 0, longitude: 0))
        XCTAssertEqual(stops.first?.tag.id, distantUnknown.id)
    }

    func testPositionsAreNumberedFromOneWithNoGaps() {
        let stops = InspectionTriage.queue(
            tags: [tag(.amber, lat: 0.01), tag(.red, lat: 0.02), tag(.green, lat: 0.03)],
            start: (latitude: 0, longitude: 0))
        XCTAssertEqual(stops.map(\.position), [1, 2, 3])
    }

    func testExpiredTagsAreDropped() {
        let stale = CommunityTag(verdict: .red, latitude: 0, longitude: 0,
                                 buildingLabel: "Gone",
                                 postedAt: Date().addingTimeInterval(-100 * 3600))
        XCTAssertTrue(stale.isExpired)
        XCTAssertTrue(InspectionTriage.queue(tags: [stale]).isEmpty)
    }

    func testAnEmptyMapProducesAnEmptyQueueRatherThanACrash() {
        XCTAssertTrue(InspectionTriage.queue(tags: []).isEmpty)
        XCTAssertEqual(InspectionTriage.summary(of: []),
                       "No live tags in view. Nothing to visit.")
    }

    // MARK: Explaining itself

    func testEveryStopSaysWhyItIsWhereItIs() {
        let stops = InspectionTriage.queue(
            tags: [tag(.needsInspection, lat: 0.001),
                   tag(.amber, lat: 0.002, disputes: 2),
                   tag(.green, lat: 0.003)],
            start: (latitude: 0, longitude: 0))
        for stop in stops {
            XCTAssertFalse(stop.reasons.isEmpty,
                           "\(stop.tag.verdict) arrived with no stated reason.")
        }
    }

    func testADisputedTagSaysSoInItsReasons() {
        let stops = InspectionTriage.queue(tags: [tag(.amber, disputes: 2)])
        XCTAssertTrue(stops.first?.reasons.contains { $0.contains("dispute") } ?? false)
    }

    func testTheSummaryCountsWhatIsActuallyThere() {
        let summary = InspectionTriage.summary(of: InspectionTriage.queue(
            tags: [tag(.needsInspection, lat: 0.001), tag(.amber, lat: 0.002)],
            start: (latitude: 0, longitude: 0)))
        XCTAssertTrue(summary.contains("2 buildings"), summary)
        XCTAssertTrue(summary.contains("no verdict yet"), summary)
        XCTAssertTrue(summary.contains("limited use"), summary)
    }

    // MARK: Distance

    func testDistanceIsRoughlyRightForASmallSeparation() {
        // A hundredth of a degree of latitude is about 1.11 km.
        let metres = InspectionTriage.metres(from: (0, 0), to: (0.01, 0))
        XCTAssertEqual(metres, 1_111, accuracy: 20)
    }
}
