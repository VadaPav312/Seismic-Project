import XCTest
import SeismicCore
@testable import SeismicServices

/// What a place's earthquake history says.
///
/// The map's central promise is that tapping anywhere on Earth gives a true
/// answer, including "nothing has happened here" — which is the correct answer
/// for most of the planet and the one an app is most tempted to dress up.
final class RegionalHistoryTests: XCTestCase {

    private func feature(magnitude: Double, place: String, yearsAgo: Double,
                         alert: String? = nil, mmi: Double? = nil,
                         tsunami: Int = 0) -> USGSFeed.Feature {
        USGSFeed.Feature(
            properties: .init(mag: magnitude, place: place,
                              time: Date(timeIntervalSinceNow: -yearsAgo * 365.25 * 86_400)
                                  .timeIntervalSince1970 * 1000,
                              tsunami: tsunami, alert: alert, mmi: mmi, cdi: nil, felt: nil),
            geometry: .init(coordinates: [140, 36, 30]),
            id: "\(place)-\(magnitude)")
    }

    private func history(_ features: [USGSFeed.Feature]) -> RegionalHistory {
        RegionalHistory(features: features, radiusKm: 150, years: 10, magnitudeFloor: 4.5)
    }

    // MARK: Nothing there

    /// The honest answer for most of the Earth's surface, and it has to be
    /// stated rather than shown as an empty list that reads like a failure.
    func testAQuietPlaceSaysSoPlainly() {
        let quiet = RegionalHistory.empty(radiusKm: 150, years: 10, floor: 4.5)
        XCTAssertTrue(quiet.events.isEmpty)
        XCTAssertNil(quiet.largest)
        XCTAssertEqual(quiet.annualRateAboveFive, 0)
        XCTAssertTrue(quiet.narrative.contains("No earthquake"))
        XCTAssertTrue(quiet.narrative.contains("10 years"))
    }

    // MARK: Summarising

    func testTheLargestAndMostRecentAreDifferentQuestions() {
        let subject = history([
            feature(magnitude: 7.8, place: "Old big one", yearsAgo: 8),
            feature(magnitude: 5.1, place: "Yesterday", yearsAgo: 0.01),
        ])
        XCTAssertEqual(subject.largest?.magnitude, 7.8)
        XCTAssertEqual(subject.mostRecent?.place, "Yesterday")
    }

    func testTheRateCountsOnlyEventsAboveFive() {
        let subject = history([
            feature(magnitude: 4.6, place: "Small", yearsAgo: 1),
            feature(magnitude: 5.2, place: "Felt", yearsAgo: 2),
            feature(magnitude: 6.0, place: "Damaging", yearsAgo: 3),
        ])
        // Two of the three, over ten years.
        XCTAssertEqual(subject.annualRateAboveFive, 0.2, accuracy: 1e-9)
    }

    // MARK: Impact

    /// The distinction the whole layer turns on: thousands of events shake
    /// nothing, and a handful damage buildings.
    func testOnlyYellowAndAboveCountAsHavingDamagedBuildings() {
        XCTAssertFalse(RegionalHistory.Impact.none.damagedBuildings)
        XCTAssertFalse(RegionalHistory.Impact.green.damagedBuildings)
        XCTAssertTrue(RegionalHistory.Impact.yellow.damagedBuildings)
        XCTAssertTrue(RegionalHistory.Impact.orange.damagedBuildings)
        XCTAssertTrue(RegionalHistory.Impact.red.damagedBuildings)
    }

    func testDamagingEventsAreListedWorstFirst() {
        let subject = history([
            feature(magnitude: 6.1, place: "Some damage", yearsAgo: 4, alert: "yellow"),
            feature(magnitude: 7.9, place: "Catastrophe", yearsAgo: 6, alert: "red"),
            feature(magnitude: 5.0, place: "Nothing", yearsAgo: 1, alert: "green"),
            feature(magnitude: 6.6, place: "Serious", yearsAgo: 2, alert: "orange"),
        ])
        XCTAssertEqual(subject.damaging.map(\.place), ["Catastrophe", "Serious", "Some damage"])
        XCTAssertEqual(subject.worstImpact, .red)
    }

    /// An unknown alert level must not be read as "no damage" — it is read as
    /// "not estimated", and says so.
    func testAMissingAlertIsNotTreatedAsHarmless() {
        let subject = history([feature(magnitude: 7.0, place: "Unrated", yearsAgo: 3)])
        XCTAssertEqual(subject.events.first?.impact, RegionalHistory.Impact.none)
        XCTAssertTrue(RegionalHistory.Impact.none.meaning.contains("No loss estimate"))
        XCTAssertFalse(RegionalHistory.Impact.none.meaning.contains("No significant damage"))
    }

    func testImpactOrdersFromNoneToRed() {
        XCTAssertLessThan(RegionalHistory.Impact.none, .green)
        XCTAssertLessThan(RegionalHistory.Impact.green, .yellow)
        XCTAssertLessThan(RegionalHistory.Impact.yellow, .orange)
        XCTAssertLessThan(RegionalHistory.Impact.orange, .red)
    }

    // MARK: The narrative

    func testTheNarrativeNamesTheLargestAndCountsTheDamagingOnes() {
        let subject = history([
            feature(magnitude: 8.1, place: "Off the coast", yearsAgo: 5, alert: "red"),
            feature(magnitude: 5.4, place: "Inland", yearsAgo: 1),
        ])
        let text = subject.narrative
        XCTAssertTrue(text.contains("8.1"))
        XCTAssertTrue(text.contains("Off the coast"))
        XCTAssertTrue(text.contains("1 of them was"))
    }

    func testANarrativeSaysWhenNothingCausedDamage() {
        let subject = history([feature(magnitude: 5.0, place: "Somewhere", yearsAgo: 2,
                                       alert: "green")])
        XCTAssertTrue(subject.narrative.contains("None of them"))
    }

    // MARK: Query shaping

    /// A wider circle means a higher floor. A 300 km circle around Tokyo holds
    /// tens of thousands of magnitude 2 events, which is a slow query and an
    /// unreadable list.
    func testTheMagnitudeFloorRisesWithTheRadius() {
        let floors = [30.0, 100, 250, 900].map(EarthquakeFeedService.magnitudeFloor(forRadiusKm:))
        XCTAssertEqual(floors, floors.sorted())
        XCTAssertEqual(EarthquakeFeedService.magnitudeFloor(forRadiusKm: 30), 2.5)
        XCTAssertEqual(EarthquakeFeedService.magnitudeFloor(forRadiusKm: 900), 5.5)
    }

    // MARK: Decoding

    /// The impact fields are additions to a response shape that was already in
    /// use, so the old one has to keep decoding.
    func testAFeedWithoutTheImpactFieldsStillDecodes() throws {
        let json = """
        {"features":[{"properties":{"mag":6.2,"place":"Nowhere","time":1600000000000},
        "geometry":{"coordinates":[10,20,5]}}]}
        """
        let feed = try JSONDecoder().decode(USGSFeed.self, from: Data(json.utf8))
        let subject = history(feed.features)
        XCTAssertEqual(subject.events.count, 1)
        XCTAssertEqual(subject.events.first?.impact, RegionalHistory.Impact.none)
        XCTAssertNil(subject.events.first?.shaking)
    }

    func testImpactFieldsDecodeWhenPresent() throws {
        let json = """
        {"features":[{"id":"us7000abcd","properties":{"mag":7.1,"place":"Somewhere",
        "time":1600000000000,"alert":"orange","mmi":8.4,"felt":2100,"tsunami":1},
        "geometry":{"coordinates":[10,20,5]}}]}
        """
        let feed = try JSONDecoder().decode(USGSFeed.self, from: Data(json.utf8))
        let event = history(feed.features).events.first
        XCTAssertEqual(event?.id, "us7000abcd")
        XCTAssertEqual(event?.impact, .orange)
        XCTAssertEqual(event?.shaking ?? 0, 8.4, accuracy: 1e-9)
        XCTAssertEqual(event?.felt, 2100)
        XCTAssertTrue(event?.causedTsunami ?? false)
    }
}
