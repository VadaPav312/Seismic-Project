import XCTest
@testable import SeismicCore

/// Curved silhouettes.
///
/// Every profile the app had was made of straight edges, which quietly ruled
/// out an entire family of real buildings — the ones that bulge, the ones that
/// narrow along a curve, the ones with a rounded crown. The tests that matter
/// here are the ones that distinguish a curve from a taper, because getting
/// that wrong flattens a curved tower into a cone and nothing complains.
final class CurvedMassingTests: XCTestCase {

    // MARK: Barrel

    func testABarrelIsWidestInTheMiddleAndClosesAtTheTop() {
        let massing = Massing.barrel(bulge: 0.25, atFraction: 0.4, topScale: 0.5)

        XCTAssertEqual(massing.scale(at: 0), 1, accuracy: 0.01, "it starts on its ground plan")
        XCTAssertEqual(massing.scale(at: 0.4), 1.25, accuracy: 0.02)
        XCTAssertEqual(massing.scale(at: 1), 0.5, accuracy: 0.02)
        XCTAssertTrue(massing.bulges)
        XCTAssertEqual(massing.widest.atHeightFraction, 0.4, accuracy: 0.05)
    }

    /// The reason the scale ceiling had to move above 1. With the old clamp a
    /// barrel was impossible to express: every station above the ground plan
    /// was silently pulled back down to it, turning the Gherkin into a cone.
    func testABarrelActuallyExceedsItsGroundPlan() {
        XCTAssertGreaterThan(Massing.barrel(bulge: 0.3).widest.scale, 1.2)
        XCTAssertGreaterThan(Massing.Station.maximumScale, 1)
    }

    func testAnAbsurdBulgeIsClampedRatherThanPropagated() {
        let massing = Massing.barrel(bulge: 40)
        XCTAssertLessThanOrEqual(massing.widest.scale, Massing.Station.maximumScale)
        for station in massing.stations { XCTAssertTrue(station.scale.isFinite) }
    }

    // MARK: Concave

    func testAConcaveProfileHitsItsEndsAndBendsHarderThanAStraightTaper() {
        let curved = Massing.concave(topScale: 0.3)
        let straight = Massing.tapered(topScale: 0.3)

        XCTAssertEqual(curved.scale(at: 0), 1, accuracy: 0.001)
        XCTAssertEqual(curved.scale(at: 1), 0.3, accuracy: 0.01)

        // Same endpoints, different route: the hyperbola has fallen much
        // further by mid-height, which is exactly what "curved" means here.
        XCTAssertLessThan(curved.scale(at: 0.5), straight.scale(at: 0.5) - 0.05)
    }

    func testAConcaveProfileIsMonotonic() {
        let massing = Massing.concave(topScale: 0.25)
        var previous = Double.greatestFiniteMagnitude
        for step in 0...40 {
            let scale = massing.scale(at: Double(step) / 40)
            XCTAssertLessThanOrEqual(scale, previous + 1e-9, "a concave taper must not widen")
            previous = scale
        }
    }

    // MARK: Domed

    func testADomeIsUniformBelowItsShoulderAndFallsAwayAbove() {
        let massing = Massing.domed(shoulderFraction: 0.7)
        XCTAssertEqual(massing.scale(at: 0.3), 1, accuracy: 0.001)
        XCTAssertEqual(massing.scale(at: 0.69), 1, accuracy: 0.01)
        XCTAssertLessThan(massing.scale(at: 0.9), 0.8)
        XCTAssertLessThan(massing.scale(at: 1), 0.2)
    }

    // MARK: Telling a curve from a taper

    /// The distinction the whole feature rests on.
    func testCurvatureSeparatesCurvesFromStraightEdges() {
        XCTAssertFalse(Massing.uniform.isCurved)
        XCTAssertFalse(Massing.tapered(topScale: 0.3).isCurved,
                       "a straight taper is not a curve however steep it is")
        XCTAssertTrue(Massing.concave(topScale: 0.3).isCurved)
        XCTAssertTrue(Massing.barrel(bulge: 0.2).isCurved)
        XCTAssertTrue(Massing.domed().isCurved)
    }

    /// A setback deviates from the straight line too, and it is emphatically
    /// not a curve — a step concentrates demand at one storey and a curve does
    /// not, so confusing them would misplace the thing an engineer looks for.
    func testASetbackIsNotMistakenForACurve() {
        let massing = Massing.setback(steps: 3, topScale: 0.5)
        XCTAssertFalse(massing.isCurved)
        XCTAssertNotNil(massing.largestDiscontinuity)
    }

    func testACurvedProfileReportsNoDiscontinuity() {
        // Which is the point: nothing about a smooth curve should raise the
        // vertical-irregularity warning that a setback earns.
        XCTAssertNil(Massing.concave(topScale: 0.3).largestDiscontinuity)
        XCTAssertNil(Massing.barrel(bulge: 0.25).largestDiscontinuity)
        XCTAssertNil(Massing.domed().largestDiscontinuity)
    }

    /// A barrel bows outside the straight line between its ends; a reciprocal
    /// taper falls inside it, because it sheds width fastest near the base. The
    /// sign carries that difference, and the two must not collide on it.
    func testCurvatureIsSignedSoTheDirectionOfTheBendSurvives() {
        XCTAssertGreaterThan(Massing.barrel(bulge: 0.25).curvature, 0)
        XCTAssertLessThan(Massing.concave(topScale: 0.3).curvature, 0)
        XCTAssertEqual(Massing.tapered(topScale: 0.4).curvature, 0, accuracy: 1e-9)
    }

    // MARK: What it says about itself

    func testTheSummaryDistinguishesTheThreeCurvedForms() {
        XCTAssertTrue(Massing.barrel(bulge: 0.25).summary.lowercased().contains("swells"))
        XCTAssertTrue(Massing.concave(topScale: 0.3).summary.lowercased().contains("curve"))
        XCTAssertTrue(Massing.tapered(topScale: 0.4).summary.lowercased().contains("tapers"))
        XCTAssertTrue(Massing.setback(steps: 3, topScale: 0.5).summary.lowercased()
            .contains("setback"))
    }

    /// A dome and a reciprocal taper both end narrower than they start, so the
    /// endpoints cannot tell them apart — and they are opposite shapes. A dome
    /// was describing itself as narrowing "quickly at first", which is the
    /// wrong way round: it does not narrow at all until its shoulder.
    func testADomeIsNotDescribedAsNarrowingFromTheGround() {
        let dome = Massing.domed(shoulderFraction: 0.75).summary.lowercased()
        XCTAssertTrue(dome.contains("shaft") || dome.contains("crown"))
        XCTAssertFalse(dome.contains("quickly at first"))

        // And the reciprocal taper, which really does, keeps saying so.
        XCTAssertTrue(Massing.concave(topScale: 0.3).summary.lowercased()
            .contains("quickly at first"))
    }

    // MARK: Mass, which is what any of this is for

    /// Area goes with the square of a linear scale, and a barrel carries mass
    /// outward as well as upward. Getting that backwards would understate the
    /// overturning moment of every bulging tower.
    func testABarrelCarriesMoreFloorAreaAloftThanATaperOfTheSameCrown() {
        let storeys = 40
        let barrel = Massing.barrel(bulge: 0.25, atFraction: 0.4, topScale: 0.5)
            .floorAreas(baseArea: 1000, storeys: storeys)
        let taper = Massing.tapered(topScale: 0.5).floorAreas(baseArea: 1000, storeys: storeys)

        XCTAssertGreaterThan(barrel.reduce(0, +), taper.reduce(0, +))
        // And specifically in the upper half, where the lever arm is longest.
        XCTAssertGreaterThan(barrel.suffix(20).reduce(0, +), taper.suffix(20).reduce(0, +))
    }

    func testEveryCurvedProfileSamplesToAUsableSetOfStoreyScales() {
        for massing in [Massing.barrel(bulge: 0.2), .concave(topScale: 0.3), .domed()] {
            let scales = massing.scales(storeys: 25)
            XCTAssertEqual(scales.count, 25)
            XCTAssertTrue(scales.allSatisfy { $0.isFinite && $0 > 0 })
        }
    }
}
