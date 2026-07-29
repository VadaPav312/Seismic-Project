import XCTest
@testable import SeismicStructures
@testable import SeismicCore
@testable import SeismicData

/// The plain-language layer is the one place where a wrong word does more harm
/// than a wrong number, so its promises are tested rather than trusted: it must
/// never call a building safe, must always admit what it cannot see, and must
/// say when it is working from guesses.
final class PlainReadingTests: XCTestCase {

    private func building(_ mutate: (inout BuildingModel) -> Void) -> BuildingModel {
        var b = SeedLibrary.buildings()[0]
        mutate(&b)
        return b
    }

    // MARK: The promises

    /// The rule that matters most. No arrangement of age, shape and soil can
    /// establish that a building is safe, and a reader takes a reassuring word
    /// far more seriously than the caveat after it.
    func testItNeverCallsABuildingSafe() {
        for seed in SeedLibrary.buildings() {
            let reading = PlainReading.of(seed, tower: TowerAnalysis.analyse(seed))
            let prose = ([reading.headline, reading.summary, reading.caveat,
                          reading.confidenceNote]
                         + reading.actions
                         + reading.points.flatMap { [$0.title, $0.meaning] })
                .joined(separator: " ")
                .lowercased()

            for phrase in ["is safe", "it's safe", "perfectly safe", "safe to enter",
                           "safe to occupy", "no risk", "guaranteed", "will survive",
                           "will not collapse", "structurally sound"] {
                XCTAssertFalse(prose.contains(phrase),
                    "\(seed.name) claims “\(phrase)”, which no calculation here can support")
            }
        }
    }

    /// Said at every level, including the reassuring one — the limit does not
    /// become less true when the news is good.
    func testItAlwaysAdmitsWhatItCannotSee() {
        for seed in SeedLibrary.buildings() {
            let reading = PlainReading.of(seed)
            XCTAssertTrue(reading.caveat.contains("cannot see"),
                "\(seed.name) omits the limits of the exercise")
            XCTAssertTrue(reading.caveat.lowercased().contains("engineer"),
                "\(seed.name) does not point at a professional")
        }
    }

    func testEveryPointGivesAReasonAndNotJustAFact() {
        for seed in SeedLibrary.buildings() {
            for point in PlainReading.of(seed, tower: TowerAnalysis.analyse(seed)).points {
                XCTAssertGreaterThan(point.meaning.count, 80,
                    "“\(point.title)” states a fact without explaining what it means")
                XCTAssertFalse(point.title.isEmpty)
            }
        }
    }

    func testThereIsAlwaysSomethingToDo() {
        for seed in SeedLibrary.buildings() {
            XCTAssertFalse(PlainReading.of(seed).actions.isEmpty,
                "\(seed.name) is a dead end — no action offered")
        }
    }

    // MARK: The judgements

    func testUnreinforcedMasonryIsSerious() {
        let reading = PlainReading.of(building {
            $0.material = .unreinforcedMasonry
            $0.retrofit = .none
        })
        XCTAssertEqual(reading.level, .serious)
        XCTAssertTrue(reading.points.contains { $0.title.contains("Unreinforced") })
    }

    func testASoftGroundFloorIsSeriousAndHasAFix() {
        let reading = PlainReading.of(building { $0.system = .softStorey })
        XCTAssertEqual(reading.level, .serious)
        XCTAssertTrue(reading.actions.contains { $0.contains("Ground-floor strengthening") },
            "The commonest fatal configuration also has a well-known fix, and saying so is "
            + "the difference between informing somebody and frightening them")
    }

    /// The point of the whole exercise: a hazard that cannot be seen.
    func testResonanceWithTheGroundIsFlagged() {
        // A building whose period lands on soft clay's ~1.1 s: roughly 12 storeys.
        let resonant = building {
            $0.storeyCount = 12
            $0.height = 40
            $0.soil = .softSoil
            $0.system = .momentFrame
            $0.material = .reinforcedConcrete
            $0.yearBuilt = 2010
            $0.retrofit = .none
        }
        let reading = PlainReading.of(resonant)
        XCTAssertTrue(reading.points.contains { $0.title.contains("sways at about the rate") },
            "period \(resonant.empiricalPeriod)s against ground \(resonant.soil.resonantPeriod)s "
            + "should have been flagged as resonant")
        XCTAssertEqual(reading.level, .serious)

        // The same building on rock is a different building.
        var onRock = resonant
        onRock.soil = .rock
        XCTAssertFalse(PlainReading.of(onRock).points
            .contains { $0.title.contains("sways at about the rate") })
    }

    func testWorstConcernLeadsTheReading() {
        let reading = PlainReading.of(building {
            $0.material = .unreinforcedMasonry
            $0.system = .softStorey
            $0.soil = .softSoil
            $0.yearBuilt = 1925
        })
        XCTAssertEqual(reading.points.first?.severity, .serious)
        XCTAssertTrue(reading.headline.contains("known to fail"), reading.headline)
        // Counts rather than quoting the point below it, so the two do not say
        // the same thing a centimetre apart.
        XCTAssertFalse(reading.headline.lowercased()
            .contains(reading.points[0].title.lowercased()))
        // Sorted worst-first throughout, not merely at the top.
        for (a, b) in zip(reading.points, reading.points.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a.severity, b.severity)
        }
    }

    func testAModernWellFoundedBuildingReadsAsOrdinary() {
        let reading = PlainReading.of(building {
            $0.storeyCount = 4
            $0.height = 14
            $0.yearBuilt = 2015
            $0.material = .reinforcedConcrete
            $0.system = .momentFrame
            $0.soil = .stiffRock
            $0.retrofit = .none
            $0.massing = .uniform
        })
        XCTAssertEqual(reading.level, .ordinary, "flagged: \(reading.points.map(\.title))")
        XCTAssertTrue(reading.headline.contains("stands out"))
    }

    /// A full retrofit means somebody assessed this building rather than its
    /// type, and that outranks anything inferred.
    func testAFullRetrofitIsCreditedAsOutrankingInference() {
        let reading = PlainReading.of(building {
            $0.material = .unreinforcedMasonry
            $0.retrofit = .full
        })
        XCTAssertTrue(reading.points.contains {
            $0.title == "Fully strengthened" && $0.meaning.contains("worth more than")
        })
        // But it does not erase the masonry point — the retrofit is evidence, not
        // an eraser, and hiding the reason for the work would be dishonest.
        XCTAssertTrue(reading.points.contains { $0.title.contains("Unreinforced") })
    }

    // MARK: Confidence

    func testGuessedFactsLowerConfidenceAndAreNamed() {
        var guessed = building { $0.provenance = [:] }
        guessed.provenance = ["system": FactProvenance(source: .defaultAssumption, confidence: 0.3),
                              "material": FactProvenance(source: .defaultAssumption, confidence: 0.3),
                              "soil": FactProvenance(source: .defaultAssumption, confidence: 0.3),
                              "yearBuilt": FactProvenance(source: .defaultAssumption, confidence: 0.3),
                              "height": FactProvenance(source: .defaultAssumption, confidence: 0.3)]
        let weak = PlainReading.of(guessed)
        XCTAssertLessThan(weak.confidence, 0.5)
        XCTAssertTrue(weak.confidenceNote.contains("structural system"),
            "the shakiest fact should be named, not merely counted")
        XCTAssertTrue(weak.summary.contains("starting point for questions"))

        var known = guessed
        known.provenance = known.provenance.mapValues { _ in
            FactProvenance(source: .userEntered, confidence: 0.95)
        }
        let strong = PlainReading.of(known)
        XCTAssertGreaterThan(strong.confidence, weak.confidence)
        XCTAssertTrue(strong.confidenceNote.contains("confirmed"))
    }

    /// The structural system drives most of the points, so a guess about it must
    /// cost more confidence than a guess about the height.
    func testConfidenceIsWeightedByWhatTheReadingLeansOn() {
        let base = FactProvenance(source: .userEntered, confidence: 0.95)
        let guess = FactProvenance(source: .defaultAssumption, confidence: 0.2)
        let fields = ["system", "material", "soil", "yearBuilt", "height"]

        func reading(guessing field: String) -> Double {
            var b = building { _ in }
            b.provenance = Dictionary(uniqueKeysWithValues:
                fields.map { ($0, $0 == field ? guess : base) })
            return PlainReading.of(b).confidence
        }

        XCTAssertLessThan(reading(guessing: "system"), reading(guessing: "height"))
    }

    // MARK: Missing input

    /// A missing input should cost a point, never produce a wrong one.
    func testAnUnknownAgeIsSaidRatherThanAssumed() {
        let reading = PlainReading.of(building { $0.yearBuilt = nil })
        XCTAssertTrue(reading.points.contains { $0.title.contains("age is unknown") })
        XCTAssertFalse(reading.points.contains { $0.title.contains("Built in") })
    }

    func testItWorksWithoutTheThreeDimensionalAnalysis() {
        for seed in SeedLibrary.buildings() {
            let without = PlainReading.of(seed)
            let with = PlainReading.of(seed, tower: TowerAnalysis.analyse(seed))
            XCTAssertFalse(without.headline.isEmpty)
            // The tower analysis can only add points, never contradict them.
            XCTAssertLessThanOrEqual(without.points.count, with.points.count)
        }
    }

    func testEverySeededBuildingProducesUsableProse() {
        for seed in SeedLibrary.buildings() {
            let reading = PlainReading.of(seed, tower: TowerAnalysis.analyse(seed))
            XCTAssertGreaterThan(reading.headline.count, 20, seed.name)
            XCTAssertGreaterThan(reading.summary.count, 120, seed.name)
            XCTAssertTrue((0...1).contains(reading.confidence), seed.name)
            XCTAssertFalse(reading.confidenceNote.isEmpty, seed.name)
        }
    }
}
