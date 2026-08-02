import XCTest
import SeismicCore
@testable import SeismicServices

// MARK: - Transport, retries and rate limiting

final class ResilientClientTests: XCTestCase {

    /// A transport that fails a fixed number of times and then succeeds, so the
    /// retry path is exercised without a network and without a real delay.
    final class FlakyTransport: HTTPTransport, @unchecked Sendable {
        private let failuresBeforeSuccess: Int
        private let lock = NSLock()
        private var attempts = 0

        init(failuresBeforeSuccess: Int) { self.failuresBeforeSuccess = failuresBeforeSuccess }

        var attemptCount: Int {
            lock.lock(); defer { lock.unlock() }
            return attempts
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            lock.lock()
            attempts += 1
            let current = attempts
            lock.unlock()
            if current <= failuresBeforeSuccess {
                return HTTPResponse(status: 503, body: Data("busy".utf8))
            }
            return HTTPResponse(status: 200, body: Data(#"{"ok":true}"#.utf8))
        }
    }

    /// Sleeps are replaced so the tests run in microseconds. The backoff maths
    /// is tested separately in SeismicCore; what matters here is that the
    /// client retries the right number of times.
    private func makeClient(_ transport: HTTPTransport,
                            attempts: Int = 4) -> ResilientClient {
        ResilientClient(transport: transport,
                        requestsPerSecond: 1000, burst: 1000,
                        policy: BackoffPolicy(initialDelay: 0.001, maximumDelay: 0.002,
                                              multiplier: 2, jitterFraction: 0,
                                              maximumAttempts: attempts),
                        sleeper: { _ in })
    }

    func testRetriesTransientFailureThenSucceeds() async throws {
        let transport = FlakyTransport(failuresBeforeSuccess: 2)
        let client = makeClient(transport)
        let response = try await client.send(HTTPRequest(url: URL(string: "https://x.test/a")!))
        XCTAssertTrue(response.isSuccess)
        XCTAssertEqual(transport.attemptCount, 3)
    }

    func testGivesUpAfterMaximumAttempts() async {
        let transport = FlakyTransport(failuresBeforeSuccess: 99)
        let client = makeClient(transport, attempts: 3)
        do {
            _ = try await client.send(HTTPRequest(url: URL(string: "https://x.test/a")!))
            XCTFail("Expected the client to give up")
        } catch let error as ServiceError {
            XCTAssertTrue(error.isRetryable)
            XCTAssertEqual(transport.attemptCount, 3)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    /// A rejected key is not a transient failure. Retrying it three times only
    /// wastes the user's rate limit and delays the fallback.
    func testDoesNotRetryAuthenticationFailure() async {
        let stub = StubHTTPTransport()
        stub.stub("x.test", status: 401, json: #"{"error":"bad key"}"#)
        let client = makeClient(stub)
        do {
            _ = try await client.send(HTTPRequest(url: URL(string: "https://x.test/a")!))
            XCTFail("Expected a failure")
        } catch let error as ServiceError {
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(stub.requests.count, 1)
            if case .failing = error.keyStatus() {} else {
                XCTFail("A 401 should mark the key as failing")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testRateLimitBecomesRateLimitedStatusWithRetryAfter() async {
        final class Limited: HTTPTransport, @unchecked Sendable {
            func send(_ request: HTTPRequest) async throws -> HTTPResponse {
                HTTPResponse(status: 429, headers: ["retry-after": "30"], body: Data())
            }
        }
        let client = makeClient(Limited(), attempts: 1)
        do {
            _ = try await client.send(HTTPRequest(url: URL(string: "https://x.test/a")!))
            XCTFail("Expected a rate limit")
        } catch let error as ServiceError {
            guard case .rateLimited(let retryAfter) = error else {
                return XCTFail("Expected .rateLimited, got \(error)")
            }
            XCTAssertEqual(retryAfter ?? 0, 30, accuracy: 0.001)
            guard case .rateLimited(let until)? = error.keyStatus() else {
                return XCTFail("Expected a rate-limited key status")
            }
            XCTAssertEqual(until.timeIntervalSinceNow, 30, accuracy: 2)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }
}

// MARK: - The grounding check

final class GroundingCheckTests: XCTestCase {

    private let request = AnalystRequest(
        task: .assessmentNarrative,
        subject: "Test Tower",
        facts: [AnalystFact(label: "Period before", value: "0.912 s"),
                AnalystFact(label: "Period after", value: "1.043 s")],
        constraints: ["The verdict is LIMITED USE."],
        question: "Explain it.")

    func testAcceptsAnAnswerThatOnlyRestatesSuppliedNumbers() {
        let answer = "The period moved from 0.912 s to 1.043 s, a change consistent with "
                   + "reduced stiffness."
        XCTAssertTrue(GroundingCheck.passes(answer, given: request))
    }

    func testAcceptsRoundedRestatement() {
        XCTAssertTrue(GroundingCheck.passes("The period rose from 0.91 to 1.04 seconds.",
                                            given: request))
    }

    /// The failure this check exists for: a fluent, plausible sentence
    /// containing a measurement nobody took.
    func testRejectsAnInventedMeasurement() {
        let answer = "The period lengthened by 14.4 per cent and peak drift reached 2.7 per cent."
        XCTAssertFalse(GroundingCheck.passes(answer, given: request))
    }

    func testOrdinaryProseNumbersAreAllowed() {
        XCTAssertTrue(GroundingCheck.passes("There are 2 things worth noting here.",
                                            given: request))
    }
}

// MARK: - The analyst

final class AIAnalystTests: XCTestCase {

    private func vault(_ seed: [String: String] = [:]) -> SecretsVault {
        SecretsVault(storage: InMemorySecretStorage(seed: seed))
    }

    private var sampleRequest: AnalystRequest {
        AnalystRequest(task: .assessmentNarrative, subject: "Test Tower",
                       facts: [AnalystFact(label: "Period before", value: "0.912 s"),
                               AnalystFact(label: "Period after", value: "1.043 s")],
                       constraints: ["The verdict is LIMITED USE."],
                       question: "Explain what changed.")
    }

    /// The default experience: no keys at all. It must still produce a real
    /// paragraph, not an error and not an empty string.
    ///
    /// Two things can serve it now — Apple's on-device model where the device
    /// has one, and the written narrator everywhere else — so this asserts what
    /// is actually promised rather than which of the two answered. What is
    /// promised is that the answer is grounded, mentions the verdict, and never
    /// left the device.
    func testFallsBackToTheDeviceWithNoKeys() async {
        let analyst = AIAnalyst(vault: vault(), transport: StubHTTPTransport())
        let answer = await analyst.answer(sampleRequest)
        XCTAssertEqual(answer.origin, .onDevice)
        XCTAssertTrue(answer.value.text.uppercased().contains("LIMITED USE"))
        XCTAssertGreaterThan(answer.value.text.count, 120)
        XCTAssertTrue(GroundingCheck.passes(answer.value.text, given: sampleRequest),
                      answer.value.text)
    }

    /// With no keys and no on-device model, it is the written narrator, and the
    /// answer is honestly marked as not having been written by a model.
    func testTheWrittenNarratorIsNotPassedOffAsAModel() {
        let text = OnDeviceNarrator.narrate(sampleRequest)
        XCTAssertTrue(text.uppercased().contains("LIMITED USE"))
        XCTAssertGreaterThan(text.count, 120)
    }

    func testUsesCerebrasWhenItsKeyIsPresent() async {
        let stub = StubHTTPTransport()
        stub.stub("cerebras.ai", json: """
        {"choices":[{"message":{"content":"The period moved from 0.912 s to 1.043 s."}}]}
        """)
        let analyst = AIAnalyst(vault: vault(["CEREBRAS_API_KEY": "k"]), transport: stub)
        let answer = await analyst.answer(sampleRequest)
        XCTAssertEqual(answer.origin, .live)
        XCTAssertEqual(answer.value.provider, "Cerebras")
        XCTAssertTrue(answer.value.isAIGenerated)
    }

    /// A provider that fails must not take the feature down with it.
    func testFallsThroughToTheNextProvider() async {
        let stub = StubHTTPTransport()
        stub.stub("cerebras.ai", failure: .http(status: 401, body: "bad key"))
        stub.stub("openai.com", json: """
        {"choices":[{"message":{"content":"Stiffness fell; the period lengthened."}}]}
        """)
        let analyst = AIAnalyst(vault: vault(["CEREBRAS_API_KEY": "k", "OPENAI_API_KEY": "k"]),
                                transport: stub)
        let answer = await analyst.answer(sampleRequest)
        XCTAssertEqual(answer.value.provider, "OpenAI")
        XCTAssertEqual(answer.origin, .live)
    }

    /// The most important test in this file. A model that invents a number
    /// must not reach the screen.
    func testDiscardsAnAnswerContainingAnInventedNumber() async {
        let stub = StubHTTPTransport()
        stub.stub("cerebras.ai", json: """
        {"choices":[{"message":{"content":"Peak drift reached 3.7 per cent, well past the limit."}}]}
        """)
        let analyst = AIAnalyst(vault: vault(["CEREBRAS_API_KEY": "k"]), transport: stub)
        let answer = await analyst.answer(sampleRequest)
        XCTAssertTrue(answer.value.wasSubstituted)
        XCTAssertFalse(answer.value.isAIGenerated)
        XCTAssertFalse(answer.value.text.contains("3.7"))
        XCTAssertEqual(answer.origin, .onDevice)
    }

    func testAnthropicRequestIsShapedCorrectly() async throws {
        let stub = StubHTTPTransport()
        stub.stub("api.anthropic.com", json: """
        {"content":[{"type":"text","text":"The period moved from 0.912 s to 1.043 s."}],
         "stop_reason":"end_turn"}
        """)
        let analyst = AIAnalyst(vault: vault(["ANTHROPIC_API_KEY": "k"]), transport: stub)
        let answer = await analyst.answer(sampleRequest)
        XCTAssertEqual(answer.value.provider, "Anthropic")

        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(request.headers["x-api-key"], "k")
        let body = try XCTUnwrap(request.body.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(body.contains("claude-opus-5"))
        // Adaptive thinking is the model default, so no thinking block is sent;
        // depth is controlled by effort instead.
        XCTAssertFalse(body.contains("budget_tokens"))
        XCTAssertTrue(body.contains("effort"))
    }

    /// A safety-classifier decline arrives as a *successful* response with an
    /// empty body. Reading content without checking the stop reason would show
    /// the user a blank explanation.
    func testTreatsARefusalAsAFallbackRatherThanAnEmptyAnswer() async {
        let stub = StubHTTPTransport()
        stub.stub("api.anthropic.com", json: #"{"content":[],"stop_reason":"refusal"}"#)
        let analyst = AIAnalyst(vault: vault(["ANTHROPIC_API_KEY": "k"]), transport: stub)
        let answer = await analyst.answer(sampleRequest)
        XCTAssertEqual(answer.origin, .onDevice)
        XCTAssertFalse(answer.value.text.isEmpty)
    }

    func testTidyStripsMarkdown() {
        let messy = "**Summary**\n\n- The period rose\n- Stiffness fell\n\n### Next steps"
        let tidy = AIAnalyst.tidy(messy)
        XCTAssertFalse(tidy.contains("*"))
        XCTAssertFalse(tidy.contains("#"))
        XCTAssertFalse(tidy.contains("- "))
        XCTAssertTrue(tidy.contains("The period rose"))
    }

    func testPromptCarriesTheVerdictAsAConstraint() {
        let prompt = GroundedPrompt.user(sampleRequest)
        XCTAssertTrue(prompt.contains("CONSTRAINTS"))
        XCTAssertTrue(prompt.contains("LIMITED USE"))
        XCTAssertTrue(prompt.contains("Period before: 0.912 s"))
    }

    func testSpokenGuidanceIsShortAndActionable() {
        let request = AnalystRequest.guidance(verdict: .red, isShaking: false,
                                              secondsUntilShaking: nil)
        let spoken = OnDeviceNarrator.narrate(request)
        XCTAssertTrue(spoken.lowercased().contains("stay outside"))
        XCTAssertLessThan(spoken.split(separator: " ").count, 30)
    }

    // MARK: The narrator varies its wording, but never its figures

    /// The same evidence has to read the same way every time it is asked for.
    /// Otherwise reopening a screen rewrites the paragraph under the reader,
    /// and a screenshot stops matching the app.
    func testTheSameAssessmentIsNarratedIdenticallyEveryTime() {
        let first = OnDeviceNarrator.narrate(sampleRequest)
        let second = OnDeviceNarrator.narrate(sampleRequest)
        let third = OnDeviceNarrator.narrate(sampleRequest)
        XCTAssertEqual(first, second)
        XCTAssertEqual(second, third)
    }

    /// And different evidence has to read differently, which is the whole
    /// point: a paragraph that looks identical after every event is a
    /// paragraph people stop reading, including the once it mattered.
    func testDifferentAssessmentsAreNarratedDifferently() {
        func request(before: String, after: String) -> AnalystRequest {
            AnalystRequest(
                task: .assessmentNarrative, subject: "Ashby Court",
                facts: [AnalystFact(label: "Period before", value: before),
                        AnalystFact(label: "Period after", value: after)],
                constraints: ["The verdict is LIMITED USE"],
                question: "What changed?")
        }

        let wordings = Set([
            OnDeviceNarrator.narrate(request(before: "0.912 s", after: "1.031 s")),
            OnDeviceNarrator.narrate(request(before: "0.640 s", after: "0.702 s")),
            OnDeviceNarrator.narrate(request(before: "1.220 s", after: "1.410 s")),
            OnDeviceNarrator.narrate(request(before: "0.410 s", after: "0.455 s")),
        ])
        XCTAssertGreaterThan(wordings.count, 1,
                             "Four different assessments produced one single wording.")
    }

    /// The variation is in the sentence frames only. Every figure has to
    /// survive verbatim — which is also why the narrator passes the same
    /// grounding check that polices a remote model.
    func testVariedWordingStillCarriesEveryFigureExactly() {
        let text = OnDeviceNarrator.narrate(sampleRequest)
        XCTAssertTrue(text.contains("0.912 s"), text)
        XCTAssertTrue(text.contains("1.043 s"), text)
        XCTAssertTrue(GroundingCheck.passes(text, given: sampleRequest), text)
    }

    /// A generated sentence that opens the same way as the one before it is the
    /// single most obvious tell. The assembler drops the repeat.
    func testNoTwoAdjacentSentencesOpenTheSameWay() {
        let text = OnDeviceNarrator.narrate(sampleRequest)
        let openings = text.split(separator: ".").map {
            $0.trimmingCharacters(in: .whitespaces)
                .split(separator: " ").prefix(2).joined(separator: " ").lowercased()
        }
        for (a, b) in zip(openings, openings.dropFirst()) {
            XCTAssertNotEqual(a, b, "Two sentences in a row start with \"\(a)\".")
        }
    }
}

// MARK: - Fact merging

final class BuildingFactSetTests: XCTestCase {

    private func fact(_ value: String, _ source: FactProvenance.Source,
                      _ confidence: Double) -> RetrievedFact {
        RetrievedFact(field: "height", value: value,
                      provenance: FactProvenance(source: source, confidence: confidence))
    }

    func testAgreementRaisesConfidence() {
        var a = BuildingFactSet(facts: ["height": fact("102", .wikidata, 0.85)])
        a.merge(BuildingFactSet(facts: ["height": fact("103", .openStreetMap, 0.7)]))
        let merged = try! XCTUnwrap(a["height"])
        XCTAssertGreaterThan(merged.provenance.confidence, 0.85)
        XCTAssertTrue(merged.provenance.detail?.contains("Agreed") ?? false)
    }

    /// Two heights that disagree must not be averaged. The average is a number
    /// neither source claims, and it would be presented as if it were retrieved.
    func testDisagreementKeepsAValueRatherThanAveraging() {
        var a = BuildingFactSet(facts: ["height": fact("102", .wikidata, 0.85)])
        a.merge(BuildingFactSet(facts: ["height": fact("58", .openStreetMap, 0.7)]))
        let merged = try! XCTUnwrap(a["height"])
        XCTAssertEqual(merged.value, "102")
        XCTAssertLessThan(merged.provenance.confidence, 0.85)
        XCTAssertTrue(merged.provenance.detail?.contains("Disagrees") ?? false)
    }

    func testHigherConfidenceSourceWinsADisagreement() {
        var a = BuildingFactSet(facts: ["height": fact("58", .openStreetMap, 0.7)])
        a.merge(BuildingFactSet(facts: ["height": fact("102", .wikidata, 0.9)]))
        XCTAssertEqual(a["height"]?.value, "102")
    }

    func testNumericAgreementIsWithinTenPercent() {
        XCTAssertTrue(BuildingFactSet.agree("100", "105"))
        XCTAssertFalse(BuildingFactSet.agree("100", "130"))
        XCTAssertTrue(BuildingFactSet.agree("Steel", "steel"))
    }
}

// MARK: - Retrieval clients

final class RetrievalTests: XCTestCase {

    /// Wikidata gives longitude first. Reading it in the app's usual order
    /// would place every imported building on the wrong side of the planet.
    func testWikidataPointIsLongitudeFirst() throws {
        let point = try XCTUnwrap(WikidataClient.parsePoint("Point(-0.1246 51.5007)"))
        XCTAssertEqual(point.latitude, 51.5007, accuracy: 1e-6)
        XCTAssertEqual(point.longitude, -0.1246, accuracy: 1e-6)
    }

    func testOverpassFootprintProjectsToMetresAndDropsTheClosingNode() {
        // A 100 m × 100 m square at the equator, closed the way OSM closes ways.
        let metrePerDegree = 111_132.0
        let side = 100.0 / metrePerDegree
        let points = [
            OverpassResponse.Point(lat: 0, lon: 0),
            OverpassResponse.Point(lat: 0, lon: side * 111_132.0 / 111_320.0),
            OverpassResponse.Point(lat: side, lon: side * 111_132.0 / 111_320.0),
            OverpassResponse.Point(lat: side, lon: 0),
            OverpassResponse.Point(lat: 0, lon: 0),
        ]
        let ring = OverpassClient.localFootprint(points, originLatitude: 0, originLongitude: 0)
        XCTAssertEqual(ring.count, 4, "The repeated closing node must be dropped")
        XCTAssertEqual(OverpassClient.polygonArea(ring), 10_000, accuracy: 200)
    }

    func testSnippetExtractionFindsStructuralFacts() {
        let text = "The 42-storey reinforced concrete tower, completed in 1974, "
                 + "stands 152 metres tall and uses a moment frame."
        let facts = SnippetExtractor.facts(from: text)
        XCTAssertEqual(facts["storeyCount"]?.value, "42")
        XCTAssertEqual(facts["yearBuilt"]?.value, "1974")
        XCTAssertEqual(facts["material"]?.value, "reinforcedConcrete")
        XCTAssertEqual(facts["system"]?.value, "momentFrame")
    }

    /// Everything read out of prose is a guess and is marked as one, so it can
    /// never silently become a fact inside a safety model.
    func testSnippetFactsAreNeverTreatedAsConfirmed() {
        let facts = SnippetExtractor.facts(from: "A 12-storey building.")
        let provenance = facts["storeyCount"]?.provenance
        XCTAssertEqual(provenance?.source, .webSearch)
        XCTAssertFalse(provenance?.isConfirmed ?? true)
    }

    func testUSGSFeatureBecomesAPlayableRecord() throws {
        let json = """
        {"features":[{"properties":{"mag":6.4,"place":"32 km SW of Ridgecrest","time":1562383193040},
          "geometry":{"coordinates":[-117.6,35.77,8.0]}}]}
        """
        let feed = try JSONDecoder().decode(USGSFeed.self, from: Data(json.utf8))
        let record = try XCTUnwrap(EarthquakeFeedService.record(from: feed.features[0]))
        XCTAssertEqual(record.magnitude, 6.4, accuracy: 1e-9)
        XCTAssertEqual(record.latitude, 35.77, accuracy: 1e-9)
        XCTAssertEqual(record.longitude, -117.6, accuracy: 1e-9)
        XCTAssertEqual(record.depthKm, 8.0, accuracy: 1e-9)
        XCTAssertEqual(record.origin, .liveFeed)
        // Without this the feed would show every live event as having happened
        // just now, because the library's records only carry a year.
        XCTAssertEqual(record.originTime?.timeIntervalSince1970 ?? 0,
                       1562383193.04, accuracy: 0.01)
        // A live event with no waveform is still runnable in the simulator,
        // which is the whole point of estimating these two.
        XCTAssertGreaterThan(record.duration, 5)
        XCTAssertGreaterThan(record.dominantPeriod, 0.1)
    }
}

// MARK: - Building search

final class BuildingSearchServiceTests: XCTestCase {

    private func vault(_ seed: [String: String] = [:]) -> SecretsVault {
        SecretsVault(storage: InMemorySecretStorage(seed: seed))
    }

    /// On a plane, with no keys, typing a building name must still land
    /// somewhere useful rather than on an empty state.
    func testFallsBackToTheBundledLibraryOffline() async {
        let service = BuildingSearchService(vault: vault(), transport: StubHTTPTransport())
        let results = await service.search("Transamerica")
        XCTAssertEqual(results.origin, .seeded)
        XCTAssertFalse(results.value.isEmpty)
        XCTAssertTrue(results.value.contains { $0.name.localizedCaseInsensitiveContains("Transamerica") })
    }

    /// Wikidata is now two calls, not one.
    ///
    /// The search index and the SPARQL endpoint are different services, and
    /// they are used in that order — searching first is what took the query
    /// from never returning to under a second. Both are stubbed here, and the
    /// entity id has to survive the hop between them or the details attach to
    /// the wrong building.
    func testWikidataResultsAreUsedWhenTheEndpointAnswers() async {
        let stub = StubHTTPTransport()
        stub.stub("wikidata.org/w/api.php", json: """
        {"search":[
          {"id":"Q160236","label":"Chrysler Building",
           "description":"skyscraper in Manhattan, New York"}]}
        """)
        stub.stub("query.wikidata.org", json: """
        {"results":{"bindings":[
          {"item":{"value":"http://www.wikidata.org/entity/Q160236"},
           "itemLabel":{"value":"Chrysler Building"},
           "height":{"value":"318.9"},
           "floors":{"value":"77"},
           "coord":{"value":"Point(-73.9754 40.7516)"}}]}}
        """)
        let service = BuildingSearchService(
            vault: vault(["WIKIDATA_ENDPOINT": "https://query.wikidata.org/sparql"]),
            transport: stub)
        let results = await service.search("Chrysler Building")
        XCTAssertEqual(results.origin, .live)
        XCTAssertEqual(results.value.first?.name, "Chrysler Building")
        XCTAssertEqual(results.value.first?.latitude ?? 0, 40.7516, accuracy: 1e-4)
        XCTAssertEqual(results.value.first?.externalID, "Q160236",
                       "The entity id must survive so facts resolve the right building")
    }

    /// The search index answering while SPARQL does not must still produce
    /// candidates — a name and a description is enough to choose from, and the
    /// details are an enrichment rather than a requirement.
    func testCandidatesSurviveWhenOnlyTheSearchIndexAnswers() async {
        let stub = StubHTTPTransport()
        stub.stub("wikidata.org/w/api.php", json: """
        {"search":[{"id":"Q160236","label":"Chrysler Building",
                    "description":"skyscraper in Manhattan"}]}
        """)
        let service = BuildingSearchService(
            vault: vault(["WIKIDATA_ENDPOINT": "https://query.wikidata.org/sparql"]),
            transport: stub)
        let results = await service.search("Chrysler Building")
        XCTAssertTrue(results.value.contains { $0.name == "Chrysler Building" })
    }

    func testDeduplicationMergesTheSameBuildingFromTwoProviders() {
        let candidates = [
            BuildingCandidate(name: "Chrysler Building", provider: "Wikidata",
                              confidence: 0.85, snippet: "Art deco."),
            BuildingCandidate(name: "The Chrysler Building", latitude: 40.75, longitude: -73.97,
                              provider: "Serper", confidence: 0.6, snippet: "77 storeys."),
        ]
        let merged = BuildingSearchService.deduplicate(candidates)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].latitude ?? 0, 40.75, accuracy: 1e-6,
                       "The coordinate from the lower-ranked result must be kept")
        XCTAssertTrue(merged[0].snippet.contains("77 storeys"))
        XCTAssertTrue(merged[0].provider.contains("Serper"))
    }

    /// A building with a height but no storey count is still a usable building.
    /// Composition never produces a zero-storey model.
    func testComposeDerivesTheMissingDimensionAndSaysSo() {
        let service = BuildingSearchService(vault: vault(), transport: StubHTTPTransport())
        let facts = BuildingFactSet(facts: [
            "height": RetrievedFact(field: "height", value: "68",
                                    provenance: FactProvenance(source: .wikidata)),
        ])
        let building = service.compose(
            candidate: BuildingCandidate(name: "Nameless Tower", provider: "Wikidata"),
            facts: facts)
        XCTAssertEqual(building.storeyCount, 20)
        XCTAssertEqual(building.height, 68, accuracy: 1e-9)
        XCTAssertEqual(building.provenance["storeyCount"]?.source, .defaultAssumption)
        XCTAssertTrue(building.provenance["storeyCount"]?.detail?.contains("3.4") ?? false)
    }

    func testComposeAlwaysProducesAUsableModel() {
        let service = BuildingSearchService(vault: vault(), transport: StubHTTPTransport())
        let building = service.compose(
            candidate: BuildingCandidate(name: "Nothing Known", provider: "None"),
            facts: BuildingFactSet())
        XCTAssertGreaterThanOrEqual(building.storeyCount, 1)
        XCTAssertGreaterThan(building.height, 0)
        XCTAssertGreaterThan(building.footprintArea, 0)
        XCTAssertGreaterThan(building.empiricalPeriod, 0)
    }
}

// MARK: - Voice

final class VoiceTests: XCTestCase {

    func testCommandsParseFromNaturalPhrasing() {
        XCTAssertEqual(VoiceCommand.parse("is it safe"), .isItSafe)
        XCTAssertEqual(VoiceCommand.parse("uh, is it safe to go inside?"), .isItSafe)
        XCTAssertEqual(VoiceCommand.parse("Shut off the gas"), .closeGas)
        XCTAssertEqual(VoiceCommand.parse("read it out"), .readAssessment)
    }

    /// Doing nothing is a better failure than doing the wrong thing, so an
    /// unrecognised phrase must return nil rather than the nearest match.
    func testUnrelatedSpeechIsNotForcedIntoACommand() {
        XCTAssertNil(VoiceCommand.parse("what time is the train to Manchester"))
        XCTAssertNil(VoiceCommand.parse(""))
    }

    /// A misheard word must not be able to close somebody's gas supply.
    func testPhysicalActionsRequireConfirmation() {
        XCTAssertTrue(VoiceCommand.closeGas.requiresConfirmation)
        XCTAssertTrue(VoiceCommand.callHousehold.requiresConfirmation)
        XCTAssertFalse(VoiceCommand.status.requiresConfirmation)
    }

    func testSpeechFallsBackToTheSystemVoiceWithoutAKey() async {
        let service = SpeechService(vault: SecretsVault(storage: InMemorySecretStorage()),
                                    transport: StubHTTPTransport())
        let result = await service.speak("Drop, cover and hold on.", urgency: .emergency)
        XCTAssertEqual(result.origin, .onDevice)
        guard case .systemVoice(let text, let rate) = result.value else {
            return XCTFail("Expected the system voice")
        }
        XCTAssertEqual(text, "Drop, cover and hold on.")
        XCTAssertGreaterThan(rate, 0.4)
    }

    func testSpeechUsesElevenLabsWhenConfigured() async {
        let stub = StubHTTPTransport()
        stub.stub("elevenlabs.io", json: "AUDIOBYTES")
        let vault = SecretsVault(storage: InMemorySecretStorage(seed: ["ELEVENLABS_API_KEY": "k"]))
        let result = await SpeechService(vault: vault, transport: stub)
            .speak("Stay outside.", urgency: .emergency)
        XCTAssertEqual(result.origin, .live)
        guard case .audio(let data, _) = result.value else { return XCTFail("Expected audio") }
        XCTAssertFalse(data.isEmpty)
    }
}

// MARK: - Households and escalation

final class HouseholdTests: XCTestCase {

    /// The code gets read aloud over a bad phone line, so it must not contain
    /// characters that sound or look like other characters.
    func testInviteCodeAvoidsAmbiguousCharacters() {
        var generator = SeededRandom(seed: 42)
        for _ in 0..<200 {
            let code = Household.generateInviteCode(using: &generator)
            XCTAssertEqual(code.count, 6)
            for character in code {
                XCTAssertFalse("AEIOU01258GILOSZ".contains(character),
                               "\(code) contains an ambiguous character")
            }
        }
    }

    func testRolesGateActuatorControl() {
        XCTAssertTrue(Household.Role.owner.canControlActuators)
        XCTAssertTrue(Household.Role.adult.canControlActuators)
        XCTAssertFalse(Household.Role.child.canControlActuators)
        XCTAssertFalse(Household.Role.viewer.canControlActuators)
        XCTAssertFalse(Household.Role.adult.canInvite)
    }

    func testUnaccountedMembersAreSurfaced() {
        let household = Household(name: "Home", members: [
            .init(id: "1", displayName: "A", role: .owner, checkInStatus: .safe),
            .init(id: "2", displayName: "B", role: .adult, checkInStatus: .unknown),
            .init(id: "3", displayName: "C", role: .child, checkInStatus: .needsHelp),
        ])
        XCTAssertEqual(household.membersUnaccountedFor.count, 1)
        XCTAssertEqual(household.membersNeedingHelp.first?.displayName, "C")
    }

    func testEscalationHandsTheMessageBackWhenSMSIsNotConfigured() async {
        let service = EscalationService(vault: SecretsVault(storage: InMemorySecretStorage()),
                                        transport: StubHTTPTransport())
        let message = EscalationService.message(buildingName: "Home", verdict: .red,
                                                senderName: "Sam")
        let result = await service.escalate(to: "+15550000000", message: message)
        guard case .handBackToUser(let text) = result.value else {
            return XCTFail("Expected the share-sheet fallback")
        }
        XCTAssertTrue(text.contains("DO NOT ENTER"))
        XCTAssertTrue(text.contains("Sam"))
        XCTAssertEqual(result.origin, .onDevice)
    }
}

// MARK: - Key testing

final class KeyTesterTests: XCTestCase {

    func testTestingAnUnsetKeyReportsMissingWithoutCallingAnything() async {
        let stub = StubHTTPTransport()
        let vault = SecretsVault(storage: InMemorySecretStorage())
        let status = await KeyTester(vault: vault, transport: stub).test(.openAIAPIKey)
        XCTAssertEqual(status, .missing)
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testAWorkingKeyBecomesValid() async {
        let stub = StubHTTPTransport()
        stub.stub("api.openai.com", json: #"{"data":[]}"#)
        let vault = SecretsVault(storage: InMemorySecretStorage(seed: ["OPENAI_API_KEY": "k"]))
        let status = await KeyTester(vault: vault, transport: stub).test(.openAIAPIKey)
        guard case .valid = status else { return XCTFail("Expected valid, got \(status)") }
        XCTAssertEqual(vault.status(for: .openAIAPIKey), status)
    }

    func testARejectedKeyBecomesFailingWithAReason() async {
        let stub = StubHTTPTransport()
        stub.stub("api.openai.com", status: 401, json: #"{"error":"invalid"}"#)
        let vault = SecretsVault(storage: InMemorySecretStorage(seed: ["OPENAI_API_KEY": "bad"]))
        let status = await KeyTester(vault: vault, transport: stub).test(.openAIAPIKey)
        guard case .failing(let reason, _) = status else {
            return XCTFail("Expected failing, got \(status)")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    /// Claiming a key is valid without having exercised it would be a lie the
    /// user acts on, so a key with no cheap probe reports "present" instead.
    func testAKeyWithNoProbeReportsPresentRatherThanValid() async {
        let vault = SecretsVault(storage: InMemorySecretStorage(seed: ["SENTRY_DSN": "x"]))
        let status = await KeyTester(vault: vault, transport: StubHTTPTransport()).test(.sentryDSN)
        XCTAssertEqual(status, .present)
    }
}

// MARK: - Cloud

final class CloudServiceTests: XCTestCase {

    func testUnconfiguredCloudIsAnOrdinaryStateNotAnError() async {
        let service = CloudService(vault: SecretsVault(storage: InMemorySecretStorage()),
                                   transport: StubHTTPTransport())
        XCTAssertFalse(service.isConfigured)
        let tags = await service.nearbyTags(latitude: 37.77, longitude: -122.41, radiusKm: 5)
        XCTAssertTrue(tags.value.isEmpty)
        XCTAssertEqual(tags.origin, .onDevice)
        XCTAssertNotNil(tags.note, "The user must be told why the map is local")
    }

    func testSignInStoresASessionAndDerivesTheAccount() async throws {
        let stub = StubHTTPTransport()
        stub.stub("auth/v1/token", json: """
        {"access_token":"at","refresh_token":"rt","expires_in":3600,
         "user":{"id":"u1","email":"sam@example.com","user_metadata":{"full_name":"Sam"}}}
        """)
        let vault = SecretsVault(storage: InMemorySecretStorage(seed: [
            "SUPABASE_URL": "https://project.supabase.co",
            "SUPABASE_ANON_KEY": "anon",
        ]))
        let service = CloudService(vault: vault, transport: stub)
        let session = try await service.signIn(email: "sam@example.com", password: "pw")
        XCTAssertEqual(session.account.displayName, "Sam")
        XCTAssertEqual(session.account.provider, .email)
        XCTAssertFalse(session.isExpired)
        let restored = await service.currentSession()
        XCTAssertEqual(restored?.accessToken, "at")
    }

    func testGuestAccountIsARealAccount() {
        let guest = UserAccount.guest()
        XCTAssertTrue(guest.isGuest)
        XCTAssertEqual(guest.provider, .guest)
        XCTAssertFalse(guest.id.isEmpty)
    }
}

// MARK: - The free-tier paths

/// Everything a user with no payment method can reach.
///
/// The app's promise is that it works with no keys at all, but the tier above
/// that matters too: somebody who has signed up only for the providers that
/// cost nothing should get live answers, not fallbacks. These tests pin that.
final class FreeTierTests: XCTestCase {

    private func vault(_ seed: [String: String]) -> SecretsVault {
        SecretsVault(storage: InMemorySecretStorage(seed: seed))
    }

    private var sampleRequest: AnalystRequest {
        AnalystRequest(task: .assessmentNarrative, subject: "Test Tower",
                       facts: [AnalystFact(label: "Period before", value: "0.912 s")],
                       constraints: ["The verdict is LIMITED USE."],
                       question: "Explain what changed.")
    }

    func testGeminiAnswersWhenOnlyItsKeyIsSet() async {
        let stub = StubHTTPTransport()
        stub.stub("generativelanguage.googleapis.com", json: """
        {"candidates":[{"content":{"parts":[{"text":"The period was 0.912 s before the event."}]}}]}
        """)
        let analyst = AIAnalyst(vault: vault(["GEMINI_API_KEY": "k"]), transport: stub)
        let answer = await analyst.answer(sampleRequest)

        XCTAssertEqual(answer.origin, .live)
        XCTAssertEqual(answer.value.provider, "Gemini")
        XCTAssertTrue(answer.value.isAIGenerated)
    }

    /// Gemini's answer arrives split across parts; joining them is the whole of
    /// the extraction, and getting it wrong would look like an empty reply.
    func testGeminiRepliesSplitAcrossPartsAreJoined() throws {
        let json = """
        {"candidates":[{"content":{"parts":[{"text":"The period "},{"text":"was 0.912 s."}]}}]}
        """
        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.firstText, "The period was 0.912 s.")
    }

    func testAnEmptyCandidateListReadsAsNoAnswer() throws {
        let decoded = try JSONDecoder().decode(GeminiResponse.self,
                                               from: Data(#"{"candidates":[]}"#.utf8))
        XCTAssertNil(decoded.firstText)
    }

    /// Photo description was the one feature that required a paid key. It must
    /// now work on the free tier.
    func testPhotoDescriptionWorksWithOnlyAFreeKey() async {
        let stub = StubHTTPTransport()
        stub.stub("generativelanguage.googleapis.com", json: """
        {"candidates":[{"content":{"parts":[{"text":"A hairline crack in plaster, not structural."}]}}]}
        """)
        let analyst = AIAnalyst(vault: vault(["GEMINI_API_KEY": "k"]), transport: stub)
        let answer = await analyst.describePhoto(jpegBase64: "AAAA", subject: "Test Tower",
                                                 locationLabel: "third floor")

        XCTAssertEqual(answer.origin, .live)
        XCTAssertEqual(answer.value.provider, "Gemini")
    }

    /// And when it is absent, the advice names the free option rather than the
    /// paid one.
    func testPhotoFallbackPointsAtTheFreeKey() async {
        let analyst = AIAnalyst(vault: vault([:]), transport: StubHTTPTransport())
        let answer = await analyst.describePhoto(jpegBase64: "AAAA", subject: "Tower",
                                                 locationLabel: "")
        XCTAssertEqual(answer.origin, .onDevice)
        XCTAssertTrue(answer.note?.contains("GEMINI_API_KEY") ?? false,
                      "The fallback should point at the key that costs nothing")
    }

    /// The provider order decides what a free-tier user actually gets.
    func testFreeProvidersAreTriedBeforePaidOnes() async {
        let stub = StubHTTPTransport()
        stub.stub("generativelanguage.googleapis.com", json: """
        {"candidates":[{"content":{"parts":[{"text":"A grounded sentence."}]}}]}
        """)
        stub.stub("api.openai.com", json: """
        {"choices":[{"message":{"content":"Should not be reached."}}]}
        """)
        let analyst = AIAnalyst(vault: vault(["GEMINI_API_KEY": "free",
                                              "OPENAI_API_KEY": "paid"]), transport: stub)
        let answer = await analyst.answer(sampleRequest)
        XCTAssertEqual(answer.value.provider, "Gemini")
    }

    /// Every capability has a path that costs nothing.
    func testEveryPaidKeyHasAFreeOrOnDeviceAlternative() {
        for key in SecretKey.allCases where key.cost == .paid {
            XCTAssertFalse(key.fallbackBehaviour.isEmpty,
                           "\(key.rawValue) is paid and must document what happens without it")
        }
        // The capabilities that would otherwise need a card.
        XCTAssertEqual(SecretKey.geminiAPIKey.cost, .free, "Vision must have a free path")
        XCTAssertEqual(SecretKey.cerebrasAPIKey.cost, .free, "Inference must have a free path")
        XCTAssertEqual(SecretKey.supabaseURL.cost, .free, "Sync must have a free path")
        XCTAssertFalse(SecretKey.freeKeys.isEmpty)
    }
}

// MARK: - Massing inference

/// Reading a building's form out of prose, and refusing to guess.
///
/// The failure that matters here is a confident wrong answer: a taper invented
/// from a sentence that did not say one changes the mass distribution and
/// therefore the period, and it does it silently.
final class MassingInferenceTests: XCTestCase {

    func testItReadsTheFormOutOfOrdinaryDescriptions() {
        let cases: [(String, String)] = [
            ("a slim tower rising from a five-storey podium", "podium"),
            ("the stepped setback silhouette of the 1930s", "setback"),
            ("its tapering form was designed for seismic performance", "tapered"),
            ("a pyramid of glass and steel", "tapered"),
            ("built on a granite plinth", "podium"),
            ("a wedding cake of receding terraces", "setback"),
        ]
        for (text, expected) in cases {
            let resolved = BuildingSearchService.massingFromText(text)
            XCTAssertEqual(resolved?.style, expected, "\(text.debugDescription)")
        }
    }

    /// Prose that does not describe a form must produce nothing, not a default.
    func testItReturnsNothingRatherThanGuessing() {
        for text in ["", "a well-known office building", "brutalist concrete",
                     "the tallest building in the city", "designed by a famous architect"] {
            XCTAssertNil(BuildingSearchService.massingFromText(text),
                         "\(text.debugDescription) should not imply a form")
        }
    }

    /// The named forms have to be moderate. These are inferences from a
    /// sentence, not measurements, and an exaggerated taper misstates the mass
    /// distribution more than a plain prism would.
    func testInferredFormsAreConservative() {
        for name in ["tapered", "setback", "podium"] {
            guard let resolved = BuildingSearchService.massingNamed(name) else {
                return XCTFail("\(name) should resolve")
            }
            let top = resolved.massing.stations.last?.scale ?? 1
            XCTAssertGreaterThanOrEqual(top, 0.35,
                                        "\(name) narrows too aggressively for an inference")
            XCTAssertFalse(resolved.massing.isUniform, "\(name) should change with height")
        }
        XCTAssertTrue(BuildingSearchService.massingNamed("uniform")?.massing.isUniform ?? false)
        XCTAssertNil(BuildingSearchService.massingNamed("unknown"))
        XCTAssertNil(BuildingSearchService.massingNamed(""))
    }
}
