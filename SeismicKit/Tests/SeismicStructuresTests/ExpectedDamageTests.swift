import XCTest
import SeismicCore
@testable import SeismicStructures

/// Where the model expects a building to crack.
///
/// The single mistake worth guarding against here is reading the mode shape as
/// displacement rather than as drift. The top of a building moves furthest and
/// cracks least; getting that backwards would send somebody to inspect the roof
/// of a building whose ground storey is the one failing.
final class ExpectedDamageTests: XCTestCase {

    private func uniform(storeys: Int, stiffness: Double = 4.0e8) -> ShearBuilding {
        ShearBuilding(
            storeys: (0..<storeys).map { _ in
                Storey(id: 0, height: 3.2, mass: 400_000,
                       stiffness: stiffness, floorArea: 400)
            },
            damping: 0.05, name: "Uniform")
    }

    func testAUniformBuildingBendsHardestAtTheBottom() {
        // Every storey is identical, so the shear carried by each is largest at
        // the base — it is holding up everything above it.
        let worst = ExpectedDamage.worstStorey(of: uniform(storeys: 8))
        XCTAssertEqual(worst, 1)
    }

    func testTheProfileIsNormalisedToOneAtTheWorstStorey() {
        let profile = ExpectedDamage.driftProfile(of: uniform(storeys: 6))
        XCTAssertEqual(profile.count, 6)
        XCTAssertEqual(profile.max() ?? 0, 1, accuracy: 1e-9)
        XCTAssertTrue(profile.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    /// The one that catches the displacement-versus-drift error. In a uniform
    /// building the roof moves most and shears least.
    func testTheRoofIsNotTheWorstStoreyDespiteMovingFurthest() {
        let profile = ExpectedDamage.driftProfile(of: uniform(storeys: 10))
        XCTAssertLessThan(profile.last ?? 1, profile.first ?? 0)
    }

    /// A soft storey — one level much less stiff than the rest — is the classic
    /// killer, and the model has to put it at the top of the list.
    func testASoftStoreyIsFoundEvenWhenItIsNotAtTheBase() {
        var building = uniform(storeys: 6)
        building.storeys[3].stiffness *= 0.25          // storey 4 is the weak one
        XCTAssertEqual(ExpectedDamage.worstStorey(of: building), 4)
    }

    // MARK: Agreement

    func testACrackAtTheWorstStoreyConfirms() {
        let building = uniform(storeys: 8)
        let agreement = ExpectedDamage.agreement(forStorey: 1, in: building)
        XCTAssertEqual(agreement?.verdict, .confirms)
        XCTAssertEqual(agreement?.worstStorey, 1)
    }

    func testACrackWhereTheModelBarelyBendsIsFlaggedAsUnexpected() {
        let building = uniform(storeys: 10)
        let agreement = ExpectedDamage.agreement(forStorey: 10, in: building)
        XCTAssertEqual(agreement?.verdict, .unexpected)
    }

    /// An unexpected crack must never be phrased as "your photograph is wrong".
    /// A crack somewhere the shear model does not bend is occasionally the most
    /// important thing in the building.
    func testAnUnexpectedCrackIsPhrasedAsAQuestionNotADismissal() {
        let building = uniform(storeys: 10)
        let explanation = ExpectedDamage.agreement(forStorey: 10, in: building)?.explanation ?? ""
        XCTAssertTrue(explanation.lowercased().contains("second look"), explanation)
        XCTAssertFalse(explanation.lowercased().contains("ignore"), explanation)
    }

    func testEveryAgreementNamesTheWorstStoreySoTheUserCanCheckIt() {
        let building = uniform(storeys: 7)
        for storey in 1...7 {
            let agreement = ExpectedDamage.agreement(forStorey: storey, in: building)
            XCTAssertNotNil(agreement)
            XCTAssertFalse(agreement?.explanation.isEmpty ?? true)
        }
    }

    func testAStoreyOutsideTheBuildingReturnsNothingRatherThanGuessing() {
        let building = uniform(storeys: 4)
        XCTAssertNil(ExpectedDamage.agreement(forStorey: 0, in: building))
        XCTAssertNil(ExpectedDamage.agreement(forStorey: 9, in: building))
    }
}
