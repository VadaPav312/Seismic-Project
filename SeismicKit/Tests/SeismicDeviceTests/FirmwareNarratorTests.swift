import XCTest
import SeismicCore
@testable import SeismicDevice

/// The commentary is watched once, live, in front of people. It has to say the
/// right things in the right order, and — more often the thing that goes wrong —
/// it has to stay quiet the rest of the time.
final class FirmwareNarratorTests: XCTestCase {

    private func telemetry(votes: Firmware.Votes,
                           sound: Int = 40,
                           ratio: Double = 1.0) -> Firmware.Message {
        .telemetry(Firmware.Telemetry(
            state: .monitoring, ratio: ratio, temperatureCelsius: 19,
            soundLevel: sound, photoresistor: 300, isTilted: false,
            isOccupied: true, votes: votes))
    }

    // MARK: Staying quiet

    /// The single most important property. Telemetry arrives every second and
    /// acceleration many times a second; a narrator that spoke on every message
    /// would produce hundreds of identical lines and be unreadable within ten
    /// seconds of being switched on.
    func testUnchangedTelemetryProducesNothing() {
        var narrator = FirmwareNarrator()
        let quiet = Firmware.Votes(accelerometer: false, tilt: false, sound: false)
        _ = narrator.narrate(telemetry(votes: quiet))

        for _ in 0..<50 {
            XCTAssertTrue(narrator.narrate(telemetry(votes: quiet)).isEmpty)
        }
    }

    func testAccelerationSamplesAreNeverNarrated() {
        var narrator = FirmwareNarrator()
        for value in 0..<100 {
            XCTAssertTrue(narrator.narrate(.acceleration(x: value, y: value / 2, z: 0, ratio: 1.1)).isEmpty)
        }
    }

    /// A phase repeated — which the firmware does, because phase is re-sent
    /// with each state broadcast — is not a new event.
    func testARepeatedPhaseIsOnlyNarratedOnce() {
        var narrator = FirmwareNarrator()
        XCTAssertFalse(narrator.narrate(.phase(.monitoring)).isEmpty)
        XCTAssertTrue(narrator.narrate(.phase(.monitoring)).isEmpty)
        XCTAssertFalse(narrator.narrate(.phase(.warning)).isEmpty)
    }

    // MARK: Saying the right thing

    /// The refusal is the most valuable sentence the app can produce during a
    /// demonstration, and it has to be unmistakable that nothing was declared.
    func testOneVotingSensorIsExplainedAsARefusalToAct() {
        var narrator = FirmwareNarrator()
        _ = narrator.narrate(telemetry(votes: .init(accelerometer: false, tilt: false,
                                                    sound: false)))
        let lines = narrator.narrate(telemetry(votes: .init(accelerometer: true, tilt: false,
                                                            sound: false)))
        let text = lines.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("1 of"), "the vote count has to be in the sentence: \(text)")
        XCTAssertTrue(text.lowercased().contains("feel"))
        XCTAssertEqual(lines.first?.tone, FirmwareNarrator.Tone.sensing)
        XCTAssertFalse(lines.contains { $0.isSpoken },
                       "a refusal is not worth interrupting for")
    }

    /// And it must not repeat itself while the condition persists.
    func testTheRefusalIsNotRepeatedEverySecond() {
        var narrator = FirmwareNarrator()
        let one = Firmware.Votes(accelerometer: true, tilt: false, sound: false)
        _ = narrator.narrate(telemetry(votes: one))
        _ = narrator.narrate(telemetry(votes: .init(accelerometer: false, tilt: false,
                                                    sound: false)))
        _ = narrator.narrate(telemetry(votes: one))
        for _ in 0..<20 {
            XCTAssertTrue(narrator.narrate(telemetry(votes: one)).isEmpty)
        }
    }

    func testADeclaredEventIsSpokenAndNamesTheSensorsThatAgreed() {
        var narrator = FirmwareNarrator()
        let lines = narrator.narrate(.triggered(
            ratio: 8.4,
            votes: .init(accelerometer: true, tilt: false, sound: true),
            isDrill: false))
        XCTAssertEqual(lines.count, 1)
        let line = try! XCTUnwrap(lines.first)
        XCTAssertTrue(line.isSpoken)
        XCTAssertEqual(line.tone, FirmwareNarrator.Tone.acting)
        XCTAssertTrue(line.text.lowercased().contains("hear"))
        XCTAssertTrue(line.text.lowercased().contains("feel"))
        XCTAssertTrue(line.text.contains("2 of my 3"))
    }

    /// A drill has to announce itself as one. Somebody walking past a screen
    /// mid-demonstration must not think a real earthquake is happening.
    func testADrillSaysSoInsteadOfClaimingAnEarthquake() {
        var narrator = FirmwareNarrator()
        let text = narrator.narrate(.triggered(
            ratio: 8.4,
            votes: .init(accelerometer: true, tilt: true, sound: true),
            isDrill: true)).map(\.text).joined()
        XCTAssertTrue(text.lowercased().contains("drill"))
        XCTAssertFalse(text.lowercased().hasPrefix("earthquake"))
    }

    /// The photoresistor is the whole reason the actuators are trustworthy, so
    /// the confirmation has to carry the numbers rather than assert success.
    func testAConfirmedActuatorQuotesTheEvidence() {
        var narrator = FirmwareNarrator()
        let line = try! XCTUnwrap(narrator.narrate(
            .verification(device: .power, before: 320, after: 890, confirmed: true)).first)
        XCTAssertEqual(line.tone, FirmwareNarrator.Tone.good)
        XCTAssertTrue(line.text.contains("320"))
        XCTAssertTrue(line.text.contains("890"))
    }

    /// And an unconfirmed one must not be dressed up.
    func testAnUnconfirmedActuatorRefusesToClaimItWorked() {
        var narrator = FirmwareNarrator()
        let line = try! XCTUnwrap(narrator.narrate(
            .verification(device: .power, before: 320, after: 331, confirmed: false)).first)
        XCTAssertEqual(line.tone, FirmwareNarrator.Tone.bad)
        XCTAssertTrue(line.isSpoken)
        XCTAssertTrue(line.text.lowercased().contains("can't prove"))
    }

    // MARK: Debris

    /// A bang with no ground motion behind it is something falling — which is
    /// what somebody deciding whether to walk back inside actually wants told.
    func testALoudNoiseWithoutShakingIsReportedAsDebris() {
        var narrator = FirmwareNarrator()
        // Declared, so the narrator is listening for it at all.
        _ = narrator.narrate(.triggered(ratio: 9,
                                        votes: .init(accelerometer: true, tilt: true, sound: true),
                                        isDrill: false))
        // Settle a sound floor.
        for _ in 0..<8 { _ = narrator.narrate(telemetry(votes: .init(accelerometer: true,
                                                                     tilt: true, sound: true),
                                                        sound: 40)) }
        let lines = narrator.narrate(telemetry(
            votes: .init(accelerometer: true, tilt: true, sound: true),
            sound: 300, ratio: 1.1))
        let debris = lines.first { $0.text.lowercased().contains("fell") }
        XCTAssertNotNil(debris, "a bang with no motion under it should be called out")
        XCTAssertEqual(debris?.tone, FirmwareNarrator.Tone.bad)
    }

    /// The same bang *with* shaking under it is the earthquake itself, not
    /// debris — and calling every loud moment of an earthquake "something fell"
    /// would make the one that matters worthless.
    func testALoudNoiseDuringShakingIsNotCalledDebris() {
        var narrator = FirmwareNarrator()
        _ = narrator.narrate(.triggered(ratio: 9,
                                        votes: .init(accelerometer: true, tilt: true, sound: true),
                                        isDrill: false))
        for _ in 0..<8 { _ = narrator.narrate(telemetry(votes: .init(accelerometer: true,
                                                                     tilt: true, sound: true),
                                                        sound: 40)) }
        let lines = narrator.narrate(telemetry(
            votes: .init(accelerometer: true, tilt: true, sound: true),
            sound: 300, ratio: 9.5))
        XCTAssertNil(lines.first { $0.text.lowercased().contains("fell") })
    }

    /// And a bang before anything was declared is a door.
    func testALoudNoiseWithNoEventIsIgnored() {
        var narrator = FirmwareNarrator()
        for _ in 0..<8 { _ = narrator.narrate(telemetry(votes: .init(accelerometer: false,
                                                                     tilt: false, sound: false),
                                                        sound: 40)) }
        let lines = narrator.narrate(telemetry(
            votes: .init(accelerometer: false, tilt: false, sound: false),
            sound: 300))
        XCTAssertNil(lines.first { $0.text.lowercased().contains("fell") })
    }

    // MARK: Verdicts

    func testEachVerdictIsExplainedInTermsOfTheSwayThatChanged() {
        for verdict in [SafetyVerdict.green, .amber, .red, .needsInspection] {
            var narrator = FirmwareNarrator()
            let line = try! XCTUnwrap(narrator.narrate(.assessment(
                Firmware.Assessment(periodBefore: 0.426, periodAfter: 0.498,
                                    periodChangePercent: 16.9,
                                    peakGroundAcceleration: 0.31,
                                    hasPermanentTilt: false, powerCutConfirmed: true,
                                    verdict: verdict))).first)
            XCTAssertTrue(line.isSpoken, "a verdict is always worth saying out loud")
            XCTAssertTrue(line.text.contains("0.43") || line.text.contains("0.42"),
                          "the before period belongs in the sentence: \(line.text)")
            XCTAssertTrue(line.text.contains("0.50"),
                          "the after period belongs in it too: \(line.text)")
        }
    }

    /// Resetting has to forget everything, or a reconnected node inherits the
    /// last one's votes and the first sentence is about a building that is no
    /// longer being watched.
    func testResetForgetsEverything() {
        var narrator = FirmwareNarrator()
        _ = narrator.narrate(.phase(.monitoring))
        narrator.reset()
        XCTAssertFalse(narrator.narrate(.phase(.monitoring)).isEmpty)
    }
}
