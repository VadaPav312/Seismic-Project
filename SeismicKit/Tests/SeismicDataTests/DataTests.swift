import XCTest
@testable import SeismicData
import SeismicCore
import SeismicSignal
import SeismicStructures

final class LedgerTests: XCTestCase {

    private func populatedLedger(entries: Int = 10) -> EventLedger {
        let ledger = EventLedger()
        for i in 0..<entries {
            ledger.append(kind: .eventCaptured, subjectID: UUID(),
                          summary: "Event \(i)",
                          payloadDigest: Hashing.sha256("payload-\(i)"))
        }
        return ledger
    }

    func testEmptyLedgerVerifies() {
        let verification = EventLedger().verify()
        XCTAssertTrue(verification.isIntact)
        XCTAssertEqual(verification.entriesChecked, 0)
    }

    func testEntriesChainToEachOther() {
        let ledger = populatedLedger()
        XCTAssertEqual(ledger.count, 10)
        for i in 1..<ledger.entries.count {
            XCTAssertEqual(ledger.entries[i].previousHash, ledger.entries[i - 1].hash)
            XCTAssertEqual(ledger.entries[i].index, i)
        }
        XCTAssertEqual(ledger.entries[0].previousHash, EventLedger.genesisHash)
    }

    func testIntactLedgerVerifies() {
        let verification = populatedLedger(entries: 25).verify()
        XCTAssertTrue(verification.isIntact, verification.reason)
        XCTAssertNil(verification.firstBrokenIndex)
        XCTAssertEqual(verification.entriesChecked, 25)
    }

    func testAlteringAnEntryIsDetected() {
        // The core claim of the whole feature.
        let ledger = populatedLedger(entries: 20)
        ledger.simulateTampering(atIndex: 7, newSummary: "Verdict: appears safe")

        let verification = ledger.verify()
        XCTAssertFalse(verification.isIntact)
        XCTAssertEqual(verification.firstBrokenIndex, 7)
        XCTAssertTrue(verification.reason.contains("changed"))
    }

    func testAlteringTheFirstOrLastEntryIsAlsoDetected() {
        for index in [0, 19] {
            let ledger = populatedLedger(entries: 20)
            ledger.simulateTampering(atIndex: index)
            let verification = ledger.verify()
            XCTAssertFalse(verification.isIntact, "tampering at \(index) went unnoticed")
            XCTAssertEqual(verification.firstBrokenIndex, index)
        }
    }

    func testRemovingAnEntryIsDetected() {
        let ledger = populatedLedger(entries: 15)
        var entries = ledger.entries
        entries.remove(at: 6)
        ledger.replace(with: entries)

        let verification = ledger.verify()
        XCTAssertFalse(verification.isIntact)
        XCTAssertEqual(verification.firstBrokenIndex, 6)
    }

    func testReorderingEntriesIsDetected() {
        let ledger = populatedLedger(entries: 12)
        var entries = ledger.entries
        entries.swapAt(3, 8)
        // Sorting on replace restores index order, so re-index deliberately to
        // simulate someone shuffling rows in a database.
        for i in entries.indices { entries[i].index = i }
        ledger.replace(with: entries)

        XCTAssertFalse(ledger.verify().isIntact)
    }

    func testAppendingAfterTamperingDoesNotRepairTheChain() {
        let ledger = populatedLedger(entries: 10)
        ledger.simulateTampering(atIndex: 2)
        ledger.append(kind: .noteAdded, summary: "Later entry",
                      payloadDigest: Hashing.sha256("later"))
        XCTAssertFalse(ledger.verify().isIntact)
        XCTAssertEqual(ledger.verify().firstBrokenIndex, 2)
    }

    func testHashIsDeterministicForTheSameContent() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let subject = UUID()
        let a = LedgerEntry(index: 3, timestamp: timestamp, kind: .assessmentIssued,
                            subjectID: subject, summary: "Verdict: amber",
                            payloadDigest: "abc", previousHash: "def")
        let b = LedgerEntry(index: 3, timestamp: timestamp, kind: .assessmentIssued,
                            subjectID: subject, summary: "Verdict: amber",
                            payloadDigest: "abc", previousHash: "def")
        XCTAssertEqual(a.hash, b.hash)
    }

    func testAnyFieldChangeChangesTheHash() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let subject = UUID()
        let base = LedgerEntry(index: 3, timestamp: timestamp, kind: .assessmentIssued,
                               subjectID: subject, summary: "Verdict: amber",
                               payloadDigest: "abc", previousHash: "def")

        let differentSummary = LedgerEntry(index: 3, timestamp: timestamp, kind: .assessmentIssued,
                                           subjectID: subject, summary: "Verdict: green",
                                           payloadDigest: "abc", previousHash: "def")
        let differentPayload = LedgerEntry(index: 3, timestamp: timestamp, kind: .assessmentIssued,
                                           subjectID: subject, summary: "Verdict: amber",
                                           payloadDigest: "xyz", previousHash: "def")
        let differentIndex = LedgerEntry(index: 4, timestamp: timestamp, kind: .assessmentIssued,
                                         subjectID: subject, summary: "Verdict: amber",
                                         payloadDigest: "abc", previousHash: "def")

        XCTAssertNotEqual(base.hash, differentSummary.hash)
        XCTAssertNotEqual(base.hash, differentPayload.hash)
        XCTAssertNotEqual(base.hash, differentIndex.hash)
    }

    func testMerkleRootChangesWhenAnythingChanges() {
        let ledger = populatedLedger(entries: 16)
        let original = ledger.merkleRoot()
        XCTAssertEqual(original.count, 64)

        ledger.simulateTampering(atIndex: 5)
        // The summary changed but the stored hash did not, so the root is
        // unchanged — which is exactly why `verify()` recomputes hashes rather
        // than trusting them.
        XCTAssertEqual(ledger.merkleRoot(), original)
        XCTAssertFalse(ledger.verify().isIntact)

        ledger.append(kind: .noteAdded, summary: "new", payloadDigest: "n")
        XCTAssertNotEqual(ledger.merkleRoot(), original)
    }

    func testMerkleRootHandlesOddCounts() {
        for count in [1, 2, 3, 5, 7, 9, 15] {
            let root = populatedLedger(entries: count).merkleRoot()
            XCTAssertEqual(root.count, 64, "count \(count) produced a malformed root")
        }
    }

    func testInclusionProofFindsTheEntry() {
        let ledger = EventLedger()
        let subject = UUID()
        ledger.append(kind: .eventCaptured, subjectID: UUID(), summary: "other", payloadDigest: "a")
        ledger.append(kind: .assessmentIssued, subjectID: subject,
                      summary: "Verdict: amber", payloadDigest: "b")
        ledger.append(kind: .noteAdded, subjectID: UUID(), summary: "another", payloadDigest: "c")

        let proof = ledger.proof(forSubject: subject)
        XCTAssertNotNil(proof)
        XCTAssertEqual(proof?.entry.summary, "Verdict: amber")
        XCTAssertEqual(proof?.totalEntries, 3)
        XCTAssertFalse(proof!.humanSummary.isEmpty)
        XCTAssertNil(ledger.proof(forSubject: UUID()))
    }

    func testEntriesCanBeFilteredBySubjectAndKind() {
        let ledger = EventLedger()
        let subject = UUID()
        ledger.append(kind: .eventCaptured, subjectID: subject, summary: "a", payloadDigest: "1")
        ledger.append(kind: .assessmentIssued, subjectID: subject, summary: "b", payloadDigest: "2")
        ledger.append(kind: .eventCaptured, subjectID: UUID(), summary: "c", payloadDigest: "3")

        XCTAssertEqual(ledger.entries(forSubject: subject).count, 2)
        XCTAssertEqual(ledger.entries(ofKind: .eventCaptured).count, 2)
    }

    func testDigestIsStableAcrossEncodings() {
        let building = SeedLibrary.sandboxBuilding()
        XCTAssertEqual(Hashing.digest(building), Hashing.digest(building))
    }

    func testLedgerSurvivesAJSONRoundTrip() {
        // Regression: the hash covers the timestamp, so if the stored date
        // format loses precision relative to the hashed one, the chain breaks
        // simply by being saved and reloaded — and the app accuses itself of
        // tampering every launch.
        let ledger = populatedLedger(entries: 12)
        XCTAssertTrue(ledger.verify().isIntact)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = LedgerDateFormat.encodingStrategy
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = LedgerDateFormat.decodingStrategy

        guard let data = try? encoder.encode(ledger.entries),
              let restored = try? decoder.decode([LedgerEntry].self, from: data) else {
            return XCTFail("ledger did not survive encoding")
        }

        let reloaded = EventLedger(entries: restored)
        let verification = reloaded.verify()
        XCTAssertTrue(verification.isIntact, verification.reason)
        XCTAssertEqual(reloaded.merkleRoot(), ledger.merkleRoot())
    }

    func testDateFormattingIsIdempotent() {
        let date = Date()
        let once = LedgerDateFormat.string(from: date)
        let parsed = LedgerDateFormat.date(from: once)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(LedgerDateFormat.string(from: parsed!), once)
    }

    func testEveryLedgerKindHasALabelAndIcon() {
        for kind in LedgerEntry.Kind.allCases {
            XCTAssertFalse(kind.label.isEmpty)
            XCTAssertFalse(kind.systemImage.isEmpty)
        }
    }
}

final class SeedLibraryTests: XCTestCase {

    // MARK: Plan shapes
    //
    // Asserted rather than assumed because the failure is silent: a building
    // with no footprint is extruded from a rectangle of the right area, which
    // looks like a building and is the wrong one. Nothing crashes and nothing
    // logs; the simulator just shows every tower as the same brick.

    func testEverySeededBuildingHasARealFootprint() {
        for building in SeedLibrary.buildings() {
            XCTAssertGreaterThanOrEqual(building.footprint.count, 4,
                                        "\(building.name) has no footprint")
            XCTAssertTrue(building.footprint.allSatisfy { $0.x.isFinite && $0.y.isFinite },
                          "\(building.name) has a non-finite vertex")
        }
    }

    /// The buildings that are not rectangular must not come out rectangular.
    func testIrregularBuildingsDoNotFillTheirBoundingBox() {
        for name in ["Christchurch Arts Centre", "Tokyo Skytree"] {
            guard let building = SeedLibrary.buildings().first(where: { $0.name == name }) else {
                XCTFail("\(name) is missing from the library")
                continue
            }
            let xs = building.footprint.map(\.x)
            let ys = building.footprint.map(\.y)
            let width = (xs.max() ?? 0) - (xs.min() ?? 0)
            let depth = (ys.max() ?? 0) - (ys.min() ?? 0)
            XCTAssertLessThan(planArea(building.footprint), width * depth * 0.95,
                              "\(name) fills its bounding box — it is still a rectangle")
        }
    }

    /// The plan must not change the building's mass.
    ///
    /// Every shape is normalised to the stated floor area, so choosing one
    /// cannot alter the seismic mass and therefore the period. If it could, the
    /// app would report a period shift that came from a menu selection rather
    /// than from the building.
    func testFootprintEnclosesTheStatedFloorArea() {
        for building in SeedLibrary.buildings() {
            let measured = planArea(building.footprint)
            XCTAssertEqual(measured, building.footprintArea,
                           accuracy: building.footprintArea * 0.03,
                           "\(building.name): outline encloses \(Int(measured)) m2 "
                           + "but claims \(Int(building.footprintArea)) m2")
        }
    }

    /// Shoelace formula, written out rather than reused from the geometry code
    /// so the test does not check an implementation against itself.
    private func planArea(_ ring: [Coordinate2D]) -> Double {
        var points = ring
        if let first = points.first, let last = points.last,
           abs(first.x - last.x) < 1e-9, abs(first.y - last.y) < 1e-9 {
            points.removeLast()
        }
        guard points.count >= 3 else { return 0 }

        var sum = 0.0
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }


    func testShipsAUsefulLibraryOfBuildings() {
        let buildings = SeedLibrary.buildings()
        XCTAssertGreaterThanOrEqual(buildings.count, 6)
        XCTAssertEqual(buildings.filter(\.isSandbox).count, 1,
                       "there must be exactly one sandbox building")

        for building in buildings {
            XCTAssertFalse(building.name.isEmpty)
            XCTAssertFalse(building.notes.isEmpty, "\(building.name) has no description")
            XCTAssertGreaterThan(building.height, 0)
            XCTAssertGreaterThan(building.storeyCount, 0)
            XCTAssertGreaterThan(building.empiricalPeriod, 0)
        }
    }

    func testSeededFactsCarryTheirSources() {
        for building in SeedLibrary.buildings() where !building.isSandbox {
            XCTAssertFalse(building.provenance.isEmpty, "\(building.name) has no provenance")
            // An inferred structural system must never be presented as confirmed.
            let systemProvenance = building.provenance(for: "system")
            if systemProvenance.source == .aiInference {
                XCTAssertFalse(systemProvenance.isConfirmed)
            }
        }
    }

    func testTheLibrarySpansAWideRangeOfBehaviour() {
        let buildings = SeedLibrary.buildings()
        let periods = buildings.map(\.empiricalPeriod)
        // A two-storey house and a 634 m tower should be an order of magnitude
        // apart, which is what makes the comparison mode interesting.
        XCTAssertGreaterThan(periods.max()! / periods.min()!, 8)

        XCTAssertTrue(buildings.contains { $0.system == .softStorey })
        XCTAssertTrue(buildings.contains { $0.retrofit == .baseIsolationRetrofit })
        XCTAssertTrue(buildings.contains { $0.material == .unreinforcedMasonry })
        XCTAssertTrue(buildings.contains { $0.soil == .softSoil })
    }

    func testSandboxBuildingIdentityIsStable() {
        XCTAssertEqual(SeedLibrary.sandboxBuilding().id, SeedLibrary.sandboxBuildingID)
        XCTAssertEqual(SeedLibrary.sandboxBuilding().id, SeedLibrary.sandboxBuilding().id)
    }

    func testShipsHistoricEarthquakes() {
        let records = SeedLibrary.earthquakes()
        XCTAssertGreaterThanOrEqual(records.count, 8)
        for record in records {
            XCTAssertFalse(record.summary.isEmpty, "\(record.name) has no summary")
            XCTAssertGreaterThan(record.pgaTarget, 0)
            XCTAssertGreaterThan(record.duration, 0)
            XCTAssertGreaterThan(record.dominantPeriod, 0)
            XCTAssertGreaterThan(record.magnitude, 0)
        }
        XCTAssertTrue(records.contains { $0.name == "El Centro" })
        XCTAssertTrue(records.contains { $0.name == "Mexico City" })
    }

    func testGeneratedWaveformsMatchTheirDocumentedPeak() {
        for record in SeedLibrary.earthquakes() {
            let waveform = SeedLibrary.waveform(for: record)
            XCTAssertGreaterThan(waveform.count, 100, "\(record.name) produced nothing")
            XCTAssertEqual(waveform.peakAbsolute, record.pgaTarget,
                           accuracy: record.pgaTarget * 0.02,
                           "\(record.name) peak is wrong")
            XCTAssertEqual(waveform.duration, record.duration, accuracy: 1.5)
        }
    }

    func testGeneratedWaveformsHaveDistinctFrequencyContent() {
        // Mexico City must actually be slow and Northridge must actually be
        // sharp, or the simulator's most interesting demonstration is a lie.
        let records = SeedLibrary.earthquakes()
        guard let mexico = records.first(where: { $0.name == "Mexico City" }),
              let northridge = records.first(where: { $0.name == "Northridge" }) else {
            return XCTFail("expected records missing")
        }
        let mexicoSpectrum = Spectrum.welch(SeedLibrary.waveform(for: mexico), segmentSeconds: 20)
        let northridgeSpectrum = Spectrum.welch(SeedLibrary.waveform(for: northridge),
                                                segmentSeconds: 10)
        XCTAssertLessThan(mexicoSpectrum.peakFrequency, northridgeSpectrum.peakFrequency)
    }

    func testWaveformGenerationIsReproducible() {
        let record = SeedLibrary.earthquakes()[0]
        XCTAssertEqual(SeedLibrary.waveform(for: record).samples,
                       SeedLibrary.waveform(for: record).samples)
    }

    func testMeasurementHistoryIsRichEnoughForEveryAlgorithm() {
        let history = SeedLibrary.measurementHistory(buildingID: UUID())
        XCTAssertGreaterThan(history.count, 1000)

        let modeOne = history.filter { $0.modeNumber == 1 }
        XCTAssertGreaterThan(modeOne.count, 500)
        XCTAssertTrue(modeOne.allSatisfy { $0.temperature != nil })
        XCTAssertTrue(modeOne.allSatisfy { $0.frequency > 0 })

        // Chronological, which the trend charts assume.
        XCTAssertEqual(history.map(\.at), history.map(\.at).sorted())

        // Both modes tracked.
        XCTAssertTrue(history.contains { $0.modeNumber == 2 })
    }

    func testHistoryContainsARecoverableTemperatureRelationship() {
        // The whole point of the seeded history: the temperature correction must
        // have something real to find in it.
        let history = SeedLibrary.measurementHistory(buildingID: UUID())
        let modeOne = history.filter { $0.modeNumber == 1 }
        let model = TemperatureNormalisation.fit(modeOne)

        XCTAssertTrue(model.isReliable, model.explanation)
        XCTAssertLessThan(model.slope, 0, "frequency should fall as temperature rises")
        XCTAssertEqual(model.slope, -0.0021, accuracy: 0.0012)
        XCTAssertGreaterThan(model.temperatureRange.upperBound
                             - model.temperatureRange.lowerBound, 10)
    }

    func testHistoryContainsADetectableSlowChange() {
        let history = SeedLibrary.measurementHistory(buildingID: UUID())
        let periods = history.filter { $0.modeNumber == 1 }.map(\.period)
        let result = CUSUM.onPeriodHistory(periods)
        XCTAssertTrue(result.changeDetected,
                      "the seeded history has no detectable trend, so the CUSUM screen is empty")
    }

    func testPastEventsArePlausibleAndVaried() {
        let events = SeedLibrary.pastEvents(buildingID: UUID(), nodeID: "sim-node-01")
        XCTAssertGreaterThanOrEqual(events.count, 6)
        XCTAssertTrue(events.contains { $0.isDrill })
        XCTAssertTrue(events.contains { !$0.actuatorReports.isEmpty })
        XCTAssertTrue(events.contains { $0.actuatorReports.isEmpty })

        // Newest first, which is how the list renders.
        XCTAssertEqual(events.map(\.startTime), events.map(\.startTime).sorted(by: >))

        for event in events {
            XCTAssertFalse(event.label.isEmpty)
            XCTAssertGreaterThan(event.triggerRatio, 0)
            XCTAssertFalse(event.votes.isEmpty)
        }
    }

    func testEventsThatFiredActuatorsConfirmedThemAll() {
        for event in SeedLibrary.pastEvents(buildingID: UUID(), nodeID: "n")
        where !event.actuatorReports.isEmpty {
            XCTAssertEqual(event.confirmedActuators.count, ActuatorKind.allCases.count)
        }
    }

    func testCommunityTagsArePlausiblyDistributed() {
        let tags = SeedLibrary.communityTags(near: 37.7749, longitude: -122.4194, count: 200)
        XCTAssertEqual(tags.count, 200)

        let greens = tags.filter { $0.verdict == .green }.count
        let reds = tags.filter { $0.verdict == .red }.count
        // Most buildings survive most earthquakes; a map that is mostly red
        // would be both wrong and terrifying.
        XCTAssertGreaterThan(greens, reds * 2)

        XCTAssertTrue(tags.contains { $0.tier == .professional })
        XCTAssertTrue(tags.contains { $0.tier == .sensorVerified })
        for tag in tags {
            XCTAssertFalse(tag.evidenceSummary.isEmpty)
            XCTAssertFalse(tag.buildingLabel.isEmpty)
        }
    }

    func testTagConsensusFavoursProfessionalsWithoutSilencingTheCrowd() {
        let now = Date()
        let professional = CommunityTag(verdict: .red, latitude: 0, longitude: 0,
                                        buildingLabel: "a", postedAt: now, tier: .professional)
        let community = CommunityTag(verdict: .green, latitude: 0, longitude: 0,
                                     buildingLabel: "a", postedAt: now, tier: .unverified,
                                     agreementCount: 4)
        XCTAssertGreaterThan(professional.consensusScore, community.consensusScore)

        // But a large, agreeing crowd still counts for something.
        let crowd = CommunityTag(verdict: .green, latitude: 0, longitude: 0,
                                 buildingLabel: "a", postedAt: now, tier: .sensorVerified,
                                 agreementCount: 20)
        XCTAssertGreaterThan(crowd.consensusScore, professional.consensusScore * 0.7)
    }

    func testTagsExpireSoStaleInformationDoesNotMislead() {
        let old = CommunityTag(verdict: .green, latitude: 0, longitude: 0, buildingLabel: "a",
                               postedAt: Date().addingTimeInterval(-100 * 3600))
        let fresh = CommunityTag(verdict: .green, latitude: 0, longitude: 0, buildingLabel: "a")
        XCTAssertTrue(old.isExpired)
        XCTAssertFalse(fresh.isExpired)
        XCTAssertLessThan(old.consensusScore, fresh.consensusScore)
    }
}

final class StoreTests: XCTestCase {

    private var store: SeismicStore!

    override func setUp() {
        super.setUp()
        store = SeismicStore.ephemeral()
    }

    override func tearDown() {
        store.deleteEverything()
        store = nil
        super.tearDown()
    }

    func testFirstLaunchSeedsAPopulatedStore() {
        let snapshot = store.load()
        XCTAssertGreaterThanOrEqual(snapshot.buildings.count, 6)
        XCTAssertFalse(snapshot.earthquakes.isEmpty)
        XCTAssertFalse(snapshot.events.isEmpty)
        XCTAssertFalse(snapshot.observations.isEmpty)
        XCTAssertFalse(snapshot.tags.isEmpty)
        XCTAssertFalse(snapshot.ledgerEntries.isEmpty)
    }

    func testSeededLedgerVerifies() {
        store.load()
        let verification = store.ledger.verify()
        XCTAssertTrue(verification.isIntact, verification.reason)
    }

    func testDataSurvivesAReload() {
        store.load()
        let building = BuildingModel(name: "Persisted tower", storeyCount: 12, height: 40)
        store.upsert(building)

        let reopened = SeismicStore(directory: store.storageDirectory)
        let snapshot = reopened.load()
        XCTAssertTrue(snapshot.buildings.contains { $0.name == "Persisted tower" })
        XCTAssertTrue(reopened.ledger.verify().isIntact)
    }

    func testEditingABuildingIsRecordedInTheLedger() {
        store.load()
        var building = store.buildingsList().first { $0.isSandbox }!
        let before = store.ledger.count

        building.notes = "Edited"
        store.upsert(building)

        XCTAssertGreaterThan(store.ledger.count, before)
        XCTAssertEqual(store.ledger.entries.last?.kind, .buildingEdited)
        XCTAssertTrue(store.ledger.verify().isIntact)
    }

    func testAssessmentGetsALedgerHash() {
        store.load()
        let buildingID = store.buildingsList()[0].id
        let assessment = Assessment(buildingID: buildingID, verdict: .amber,
                                    damageProbability: 0.55, confidence: 0.7)
        store.upsert(assessment)

        let stored = store.latestAssessment(forBuilding: buildingID)
        XCTAssertNotNil(stored?.ledgerHash)
        XCTAssertFalse(stored!.ledgerHash!.isEmpty)
        XCTAssertNotNil(store.ledger.proof(forSubject: assessment.id))
    }

    func testRecordingsAreStoredSeparatelyAndRetrievable() {
        store.load()
        let record = SyntheticMotion.generate(.init(magnitude: 6, distanceKm: 20, seed: 3))
        let eventID = UUID()
        store.writeRecording(record, for: eventID)

        let loaded = store.recording(for: eventID)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.count, record.count)
        XCTAssertEqual(loaded?.x.samples.first, record.x.samples.first)

        // The event index must stay small: the waveform is not inside it.
        store.upsert(SeismicEvent(id: eventID, buildingID: nil, record: record))
        let indexed = store.eventsList().first { $0.id == eventID }
        XCTAssertNotNil(indexed)
        XCTAssertNil(indexed?.record, "the waveform leaked into the event index")

        // But it is still reachable on demand.
        XCTAssertEqual(store.eventWithRecording(eventID)?.record?.count, record.count)
    }

    func testMissingRecordingReturnsNilRatherThanCrashing() {
        XCTAssertNil(store.recording(for: UUID()))
    }

    func testExportProducesReadableJSONWithALedgerRoot() {
        store.load()
        guard let data = store.exportJSON() else { return XCTFail("export failed") }
        XCTAssertGreaterThan(data.count, 1000)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try? decoder.decode(SeismicStore.ExportBundle.self, from: data)
        XCTAssertNotNil(bundle)
        XCTAssertFalse(bundle!.buildings.isEmpty)
        XCTAssertEqual(bundle!.ledgerRoot.count, 64)
    }

    func testDeleteEverythingLeavesNothingBehind() {
        store.load()
        XCTAssertFalse(store.buildingsList().isEmpty)
        store.deleteEverything()
        XCTAssertTrue(store.buildingsList().isEmpty)
        XCTAssertTrue(store.eventsList().isEmpty)
        XCTAssertEqual(store.ledger.count, 0)
    }

    /// Deleting a building has to take its verdicts with it.
    ///
    /// Only the events were being removed, so an assessment outlived the
    /// building it described — in the store, in the export and in the sync
    /// payload — and the store grew a little every time somebody tried a design
    /// and deleted it.
    func testDeletingABuildingRemovesWhatOnlyMadeSenseAlongsideIt() {
        store.load()
        guard let building = store.buildingsList().first else {
            return XCTFail("the seeded library should not be empty")
        }

        let event = SeismicEvent(buildingID: building.id, startTime: Date(),
                                 triggerRatio: 4, label: "Test")
        store.upsert(event)
        store.upsert(Assessment(buildingID: building.id, eventID: event.id,
                                verdict: .amber, damageProbability: 0.4))
        store.upsert(CommunityTag(buildingID: building.id, verdict: .amber,
                                  latitude: 0, longitude: 0, buildingLabel: building.name))

        XCTAssertFalse(store.assessments(forBuilding: building.id).isEmpty)

        store.delete(buildingID: building.id)

        XCTAssertNil(store.building(building.id))
        XCTAssertTrue(store.events(forBuilding: building.id).isEmpty)
        XCTAssertTrue(store.assessments(forBuilding: building.id).isEmpty)
        XCTAssertFalse(store.tagsList().contains { $0.buildingID == building.id })
        // And nothing belonging to any other building went with it.
        XCTAssertFalse(store.buildingsList().isEmpty)
    }

    /// The ledger is append-only and tamper-evident, so a deletion must not be
    /// able to erase the record that the building was once assessed.
    func testDeletingABuildingDoesNotRewriteTheLedger() {
        store.load()
        guard let building = store.buildingsList().first else {
            return XCTFail("the seeded library should not be empty")
        }
        let before = store.ledger.count
        store.delete(buildingID: building.id)
        XCTAssertGreaterThanOrEqual(store.ledger.count, before)
    }

    func testObservationsAreBounded() {
        let many = (0..<50_000).map { i in
            ModeObservation(modeNumber: 1, frequency: 1.0, amplitude: 1,
                            at: Date().addingTimeInterval(Double(i)), temperature: 20)
        }
        store.append(many)
        XCTAssertLessThanOrEqual(store.observationsList().count, 40_000)
    }

    func testStorageFootprintIsReported() {
        store.load()
        let footprint = store.storageFootprint()
        XCTAssertGreaterThan(footprint.documents, 0)
    }
}

final class SyncQueueTests: XCTestCase {

    func testEmptyQueueIsSynced() {
        XCTAssertEqual(SyncQueue().status, .synced)
    }

    func testQueuedItemsShowAsPendingWhenOnline() {
        let queue = SyncQueue()
        queue.setOnline(true)
        queue.enqueue(.building(UUID()))
        queue.enqueue(.event(UUID()))
        XCTAssertEqual(queue.status, .pending(count: 2))
    }

    func testQueuedItemsShowAsOfflineWhenOffline() {
        let queue = SyncQueue()
        queue.setOnline(false)
        queue.enqueue(.building(UUID()))
        XCTAssertEqual(queue.status, .offline(count: 1))
    }

    func testRepeatedEditsToTheSameItemCollapseToOne() {
        let queue = SyncQueue()
        let id = UUID()
        for _ in 0..<10 { queue.enqueue(.building(id)) }
        XCTAssertEqual(queue.count, 1)
    }

    func testDifferentItemsAreKeptSeparate() {
        let queue = SyncQueue()
        let id = UUID()
        queue.enqueue(.building(id))
        queue.enqueue(.event(id))       // same UUID, different kind
        XCTAssertEqual(queue.count, 2)
    }

    func testCompletingRemovesFromTheQueue() {
        let queue = SyncQueue()
        let item = SyncQueue.Item.building(UUID())
        queue.enqueue(item)
        queue.complete(item)
        XCTAssertEqual(queue.count, 0)
        XCTAssertEqual(queue.status, .synced)
    }

    func testConflictsTakePrecedenceOverPendingInTheStatus() {
        let queue = SyncQueue()
        queue.setOnline(true)
        let item = SyncQueue.Item.assessment(UUID())
        queue.enqueue(item)
        queue.recordConflict(.init(item: item, localSummary: "Verdict: red",
                                   remoteSummary: "Verdict: amber",
                                   localModified: Date(), remoteModified: Date()))

        XCTAssertEqual(queue.status, .conflicted(count: 1))
        XCTAssertEqual(queue.pendingConflicts().count, 1)

        queue.resolveConflict(for: item)
        XCTAssertEqual(queue.status, .pending(count: 1))
    }

    func testConflictsAreNotResolvedSilently() {
        // The requirement is explicit: conflicts are surfaced rather than
        // overwritten. Recording the same conflict twice must not duplicate it,
        // and must not resolve it either.
        let queue = SyncQueue()
        let item = SyncQueue.Item.building(UUID())
        let conflict = SyncQueue.Conflict(item: item, localSummary: "a", remoteSummary: "b",
                                          localModified: Date(), remoteModified: Date())
        queue.recordConflict(conflict)
        queue.recordConflict(conflict)
        XCTAssertEqual(queue.pendingConflicts().count, 1)
    }

    func testRestorePreservesQueueAcrossLaunches() {
        let queue = SyncQueue()
        let items: [SyncQueue.Item] = [.building(UUID()), .note(UUID())]
        queue.restore(items)
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.pending(), items)
    }

    func testEveryStatusHasALabelAndIcon() {
        let statuses: [SyncQueue.Status] = [.synced, .pending(count: 3), .offline(count: 2),
                                            .syncing(remaining: 1), .conflicted(count: 1)]
        for status in statuses {
            XCTAssertFalse(status.label.isEmpty)
            XCTAssertFalse(status.systemImage.isEmpty)
        }
    }
}
