import XCTest
@testable import SeismicServices

final class SeismicServicesPlaceholderTests: XCTestCase {
    func testModuleLoads() { XCTAssertEqual(SeismicServicesModule.name, "SeismicServices") }
}
