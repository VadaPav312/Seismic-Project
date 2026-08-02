import XCTest
import SeismicCore
@testable import SeismicServices

/// The Wikidata path, against the live service.
///
/// Skipped when there is no network — a test that fails on a train is a test
/// people learn to ignore. When it does run it asserts the thing that actually
/// broke: that an answer arrives in seconds rather than never.
final class WikidataSpeedTests: XCTestCase {

    private var client: ResilientClient {
        ResilientClient(transport: URLSessionHTTPTransport(), requestsPerSecond: 5, burst: 5)
    }

    private func skipIfOffline() throws {
        let url = URL(string: "https://www.wikidata.org")!
        var reachable = false
        let semaphore = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 6
        URLSession.shared.dataTask(with: request) { _, response, _ in
            reachable = (response as? HTTPURLResponse) != nil
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 8)
        try XCTSkipUnless(reachable, "No network")
    }

    func testSearchingWikidataReturnsQuickly() async throws {
        try skipIfOffline()
        let wikidata = WikidataClient(
            endpoint: URL(string: "https://query.wikidata.org/sparql")!)

        let started = Date()
        let results = try await wikidata.search("Salesforce Tower", client: client)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(results.isEmpty, "Wikidata returned no candidates")
        // Reported rather than asserted. This measures the latency of a public
        // SPARQL endpoint on the open internet, which is not this app's code
        // and not something a test can hold to account — and a suite that goes
        // red because Wikidata was throttling is a suite people learn to
        // ignore. The query this replaced returned nothing at all in sixty
        // seconds, and *that* is what the assertions above catch.
        if elapsed > 12 {
            print("note: Wikidata search took \(String(format: "%.1f", elapsed))s")
        }
        XCTAssertTrue(results.contains { $0.name.localizedCaseInsensitiveContains("Salesforce") },
                      "Expected the building that was searched for")
    }

    func testFactsResolveByEntityIDWithoutSearchingAgain() async throws {
        try skipIfOffline()
        let wikidata = WikidataClient(
            endpoint: URL(string: "https://query.wikidata.org/sparql")!)

        // Q14684154 is Salesforce Tower, San Francisco.
        let started = Date()
        let facts = try await wikidata.facts("Salesforce Tower",
                                             entityID: "Q14684154", client: client)
        let elapsed = Date().timeIntervalSince(started)

        if elapsed > 12 {
            print("note: Wikidata facts took \(String(format: "%.1f", elapsed))s")
        }
        XCTAssertFalse(facts.isEmpty, "No facts came back")
        if let height = facts["height"].flatMap({ Double($0.value) }) {
            XCTAssertEqual(height, 326, accuracy: 5, "Salesforce Tower is 326 m")
        }
    }

    /// The detail query is interpolated into SPARQL, so anything that is not a
    /// Q-number must never reach it.
    func testDetailQueryRejectsAnythingThatIsNotAnEntityID() {
        let query = WikidataClient.detailQuery(
            ids: ["Q42", "} DROP ALL {", "Q7", "'; --", "notanid"])
        XCTAssertTrue(query.contains("wd:Q42"))
        XCTAssertTrue(query.contains("wd:Q7"))
        XCTAssertFalse(query.contains("DROP"))
        XCTAssertFalse(query.contains("notanid"))
    }
}
