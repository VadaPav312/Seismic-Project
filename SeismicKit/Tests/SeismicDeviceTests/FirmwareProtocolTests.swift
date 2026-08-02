import XCTest
import SeismicCore
@testable import SeismicDevice

/// The wire protocol, tested against lines the firmware actually emits.
///
/// Every literal here is built from a `snprintf` format string in
/// `arduino.ino`, with plausible values substituted. That is deliberate: the
/// point of these tests is to catch the app and the board disagreeing, and a
/// test written against the app's own idea of the format would agree with
/// itself for ever.
final class FirmwareProtocolTests: XCTestCase {

    // MARK: Telemetry

    func testItParsesATelemetryLine() {
        let line = #"{"t":"tel","st":2,"ratio":102,"tmp":214,"snd":118,"pho":320,"tilt":0,"occ":0,"va":0,"vt":0,"vs":0,"votes":0,"pb":432,"thr":40}"#
        guard case .telemetry(let t)? = Firmware.parse(line: line) else {
            return XCTFail("Did not parse as telemetry.")
        }
        XCTAssertEqual(t.state, .monitoring)
        // The scalings are where this goes wrong silently, so each is checked.
        XCTAssertEqual(t.ratio, 1.02, accuracy: 1e-9)
        XCTAssertEqual(t.temperatureCelsius, 21.4, accuracy: 1e-9)
        XCTAssertEqual(t.baselinePeriod, 0.432, accuracy: 1e-9)
        XCTAssertEqual(t.triggerThreshold, 4.0, accuracy: 1e-9)
        XCTAssertEqual(t.soundLevel, 118)
        XCTAssertEqual(t.photoresistor, 320)
        XCTAssertFalse(t.isTilted)
        XCTAssertFalse(t.isOccupied)
        XCTAssertEqual(t.votes.count, 0)
    }

    func testEveryNodeStateNumberMapsToAState() {
        for raw in 0...8 {
            let line = #"{"t":"tel","st":\#(raw),"ratio":100,"tmp":200,"snd":0,"pho":0,"tilt":0,"occ":0,"va":0,"vt":0,"vs":0,"votes":0}"#
            guard case .telemetry(let t)? = Firmware.parse(line: line) else {
                return XCTFail("State \(raw) did not parse.")
            }
            XCTAssertEqual(t.state.rawValue, raw)
            XCTAssertFalse(t.state.label.isEmpty)
        }
    }

    /// The thermistor reports −99 for an open or shorted divider, which is a
    /// fault rather than a very cold room.
    func testAnImpossibleTemperatureIsReportedAsInvalid() {
        let line = #"{"t":"tel","st":2,"ratio":100,"tmp":-990,"snd":0,"pho":0,"tilt":0,"occ":0,"va":0,"vt":0,"vs":0,"votes":0}"#
        guard case .telemetry(let t)? = Firmware.parse(line: line) else { return XCTFail() }
        XCTAssertFalse(t.isTemperatureValid)
    }

    func testMissingOptionalFieldsFallBackRatherThanFailing() {
        // An older firmware without pb/thr must still parse.
        let line = #"{"t":"tel","st":2,"ratio":100,"tmp":200,"snd":0,"pho":0,"tilt":0,"occ":0,"va":0,"vt":0,"vs":0,"votes":0}"#
        guard case .telemetry(let t)? = Firmware.parse(line: line) else { return XCTFail() }
        XCTAssertEqual(t.baselinePeriod, 0)
        XCTAssertEqual(t.triggerThreshold, 4.0, accuracy: 1e-9)
    }

    // MARK: Boot

    func testBootReportsAMissingAccelerometer() {
        guard case .boot(let ok)? = Firmware.parse(line: #"{"t":"boot","mpu":0}"#) else {
            return XCTFail()
        }
        XCTAssertFalse(ok)

        guard case .boot(let good)? = Firmware.parse(line: #"{"t":"boot","mpu":1}"#) else {
            return XCTFail()
        }
        XCTAssertTrue(good)
    }

    /// A boot line without the field should not look like broken hardware.
    func testBootWithoutTheFieldAssumesTheAccelerometerIsPresent() {
        guard case .boot(let ok)? = Firmware.parse(line: #"{"t":"boot"}"#) else {
            return XCTFail()
        }
        XCTAssertTrue(ok)
    }

    // MARK: Events

    func testItParsesATriggerWithItsVoteBreakdown() {
        let line = #"{"t":"trig","ratio":840,"va":1,"vt":1,"vs":0,"drill":0}"#
        guard case .triggered(let ratio, let votes, let isDrill)? = Firmware.parse(line: line)
        else { return XCTFail() }
        XCTAssertEqual(ratio, 8.4, accuracy: 1e-9)
        XCTAssertTrue(votes.accelerometer)
        XCTAssertTrue(votes.tilt)
        XCTAssertFalse(votes.sound)
        XCTAssertEqual(votes.count, 2)
        XCTAssertTrue(votes.isDeclared)
        XCTAssertFalse(isDrill)
    }

    func testADrillIsDistinguishableFromTheRealThing() {
        let line = #"{"t":"trig","ratio":400,"va":1,"vt":1,"vs":1,"drill":1}"#
        guard case .triggered(_, _, let isDrill)? = Firmware.parse(line: line) else {
            return XCTFail()
        }
        XCTAssertTrue(isDrill)
    }

    func testItParsesCountdownAndPhases() {
        guard case .countdown(let s)? = Firmware.parse(line: #"{"t":"count","s":5}"#) else {
            return XCTFail()
        }
        XCTAssertEqual(s, 5)

        for name in ["calibrating", "monitoring", "disarmed", "warning",
                     "acting", "recording", "assessing", "verdict"] {
            guard case .phase(let phase)? =
                    Firmware.parse(line: #"{"t":"phase","p":"\#(name)"}"#) else {
                return XCTFail("Phase \(name) did not parse.")
            }
            XCTAssertEqual(phase.rawValue, name)
        }
    }

    // MARK: Actuators

    func testItParsesActuatorStates() {
        for raw in 0...3 {
            let line = #"{"t":"act","dev":"power","st":\#(raw)}"#
            guard case .actuator(let device, let state)? = Firmware.parse(line: line) else {
                return XCTFail("State \(raw) did not parse.")
            }
            XCTAssertEqual(device, .power)
            XCTAssertEqual(state.rawValue, raw)
        }
    }

    /// The distinction the photoresistor exists for.
    func testOnlyAConfirmedActuatorCountsAsProven() {
        XCTAssertTrue(Firmware.ActuatorState.confirmed.isProven)
        XCTAssertFalse(Firmware.ActuatorState.commanded.isProven)
        XCTAssertFalse(Firmware.ActuatorState.failed.isProven)
        XCTAssertFalse(Firmware.ActuatorState.idle.isProven)
    }

    func testItParsesTheVerificationEvidence() {
        let line = #"{"t":"verify","dev":"power","before":320,"after":890,"ok":1}"#
        guard case .verification(let device, let before, let after, let ok)? =
                Firmware.parse(line: line) else { return XCTFail() }
        XCTAssertEqual(device, .power)
        XCTAssertEqual(before, 320)
        XCTAssertEqual(after, 890)
        XCTAssertTrue(ok)
    }

    /// The gas valve is modelled and absent, and says why.
    func testTheGasValveIsModelledAsUnavailableWithAReason() {
        XCTAssertFalse(Firmware.Actuator.gas.isAvailableInFirmware)
        XCTAssertTrue(Firmware.Actuator.power.isAvailableInFirmware)
        XCTAssertTrue(Firmware.Actuator.water.isAvailableInFirmware)

        let reason = Firmware.Actuator.gas.unavailableReason ?? ""
        XCTAssertTrue(reason.contains("USB"), reason)
        XCTAssertNil(Firmware.Actuator.power.unavailableReason)
    }

    // MARK: Recording

    func testItParsesRecordingFraming() {
        guard case .recordingBegan(let n, let hz)? =
                Firmware.parse(line: #"{"t":"recbegin","n":500,"hz":50}"#) else {
            return XCTFail()
        }
        XCTAssertEqual(n, 500)
        XCTAssertEqual(hz, 50)

        guard case .recordingEnded? = Firmware.parse(line: #"{"t":"recend"}"#) else {
            return XCTFail()
        }
    }

    func testItParsesARecordingChunkIncludingNegativeSamples() {
        let line = #"{"t":"rec","c":3,"d":[10,-20,30,-40],"sum":-20}"#
        guard case .recordingChunk(let index, let samples, let sum)? =
                Firmware.parse(line: line) else { return XCTFail() }
        XCTAssertEqual(index, 3)
        XCTAssertEqual(samples, [10, -20, 30, -40])
        XCTAssertEqual(sum, -20)
    }

    // MARK: Assessment

    func testItParsesAnAssessment() {
        let line = #"{"t":"assess","pb":432,"pa":541,"pct":252,"pga":180,"tiltp":0,"pwr":1,"verdict":"A"}"#
        guard case .assessment(let a)? = Firmware.parse(line: line) else { return XCTFail() }
        XCTAssertEqual(a.periodBefore, 0.432, accuracy: 1e-9)
        XCTAssertEqual(a.periodAfter, 0.541, accuracy: 1e-9)
        XCTAssertEqual(a.periodChangePercent, 25.2, accuracy: 1e-9)
        XCTAssertEqual(a.peakGroundAcceleration, 0.180, accuracy: 1e-9)
        XCTAssertFalse(a.hasPermanentTilt)
        XCTAssertTrue(a.powerCutConfirmed)
        XCTAssertEqual(a.verdict, .amber)
    }

    func testTheThreeVerdictLettersMap() {
        XCTAssertEqual(Firmware.verdict(from: "G"), .green)
        XCTAssertEqual(Firmware.verdict(from: "A"), .amber)
        XCTAssertEqual(Firmware.verdict(from: "R"), .red)
    }

    /// A letter nobody recognises must not become green. An unknown verdict is
    /// a reason for a person to look, not a reason to assume the best.
    func testAnUnknownVerdictLetterBecomesNeedsInspection() {
        XCTAssertEqual(Firmware.verdict(from: "X"), .needsInspection)
        XCTAssertEqual(Firmware.verdict(from: ""), .needsInspection)
    }

    // MARK: The rest

    func testItParsesCalibrationNotesErrorsAndAcks() {
        guard case .calibrated(let g, let s, let p)? =
                Firmware.parse(line: #"{"t":"cal","grav":16380,"snd":118,"per":432}"#) else {
            return XCTFail()
        }
        XCTAssertEqual(g, 16380); XCTAssertEqual(s, 118); XCTAssertEqual(p, 432)

        guard case .note(let note)? =
                Firmware.parse(line: #"{"t":"note","m":"actuators reset"}"#) else {
            return XCTFail()
        }
        XCTAssertEqual(note, "actuators reset")

        guard case .error(let message)? =
                Firmware.parse(line: #"{"t":"err","m":"unknown command"}"#) else {
            return XCTFail()
        }
        XCTAssertEqual(message, "unknown command")

        guard case .acknowledged(let command)? =
                Firmware.parse(line: #"{"t":"ack","c":"DRILL"}"#) else { return XCTFail() }
        XCTAssertEqual(command, "DRILL")
    }

    /// An unknown message type is kept rather than dropped. Firmware moves on,
    /// and a silently ignored line is how an app and a board drift apart.
    func testAnUnknownTypeIsKeptRatherThanDropped() {
        guard case .unrecognised(let type, _)? =
                Firmware.parse(line: #"{"t":"newthing","x":1}"#) else {
            return XCTFail("An unknown type was dropped.")
        }
        XCTAssertEqual(type, "newthing")
    }

    func testNonJSONLinesAreIgnored() {
        XCTAssertNil(Firmware.parse(line: ""))
        XCTAssertNil(Firmware.parse(line: "SEISMIC node starting"))
        XCTAssertNil(Firmware.parse(line: #"{"t":"tel","st":2,"#))   // truncated
    }

    // MARK: Commands

    /// Every command's wire form, against the firmware's own string literals.
    func testCommandsMatchTheFirmwareStrings() {
        XCTAssertEqual(Firmware.Command.drill.wire, "DRILL")
        XCTAssertEqual(Firmware.Command.arm.wire, "ARM")
        XCTAssertEqual(Firmware.Command.disarm.wire, "DISARM")
        XCTAssertEqual(Firmware.Command.calibrate.wire, "CAL")
        XCTAssertEqual(Firmware.Command.reset.wire, "RESET")
        XCTAssertEqual(Firmware.Command.resendRecording.wire, "SEND")
        XCTAssertEqual(Firmware.Command.status.wire, "STATUS")
        XCTAssertEqual(Firmware.Command.beep.wire, "BEEP")
        XCTAssertEqual(Firmware.Command.stepperEnabled(false).wire, "NOSTEP")
        XCTAssertEqual(Firmware.Command.stepperEnabled(true).wire, "YESTEP")
    }

    /// The polarity that is easy to invert and expensive to get wrong: PWR:1
    /// *cuts* the power. The firmware's `powerCut` is bound to `PWR:1`.
    func testPowerAndWaterPolarityMatchTheFirmware() {
        XCTAssertEqual(Firmware.Command.power(on: false).wire, "PWR:1")  // cut
        XCTAssertEqual(Firmware.Command.power(on: true).wire, "PWR:0")   // restore
        XCTAssertEqual(Firmware.Command.water(closed: true).wire, "WTR:1")
        XCTAssertEqual(Firmware.Command.water(closed: false).wire, "WTR:0")
    }

    /// `REC:n` names the chunk, and acknowledges with the bare word — so one
    /// waiting control covers a whole round of re-requests rather than
    /// twenty-five separate ones.
    func testChunkRequestsNameTheirIndexAndShareAnAck() {
        XCTAssertEqual(Firmware.Command.resendChunk(9).wire, "REC:9")
        XCTAssertEqual(Firmware.Command.resendChunk(0).wire, "REC:0")
        XCTAssertEqual(Firmware.Command.resendChunk(9).acknowledgementToken, "REC")
        XCTAssertEqual(Firmware.Command.resendChunk(24).acknowledgementToken, "REC")
        // And it is not a motor, so it must not be delayed behind the valve.
        XCTAssertFalse(Firmware.Command.resendChunk(9).movesMotor)
        XCTAssertTrue(Firmware.Command.resendChunk(9).expectsAcknowledgement)
    }

    func testTuningCommandsCarryTheirScaling() {
        // THR is the ratio times ten.
        XCTAssertEqual(Firmware.Command.triggerThreshold(4.5).wire, "THR:45")
        XCTAssertEqual(Firmware.Command.triggerThreshold(2.0).wire, "THR:20")
        XCTAssertEqual(Firmware.Command.stepCount(1024).wire, "STEP:1024")
        XCTAssertEqual(Firmware.Command.stepDelay(3000).wire, "SPD:3000")
        XCTAssertEqual(Firmware.Command.photoThreshold(600).wire, "PHO:600")
    }

    func testEveryCommandIsNewlineTerminated() {
        let commands: [Firmware.Command] = [
            .drill, .arm, .disarm, .calibrate, .reset, .resendRecording, .status,
            .power(on: true), .water(closed: true), .beep, .triggerThreshold(4),
            .stepCount(1024), .stepDelay(3000), .photoThreshold(600),
            .stepperEnabled(true),
        ]
        for command in commands {
            let text = String(decoding: command.payload, as: UTF8.self)
            XCTAssertTrue(text.hasSuffix("\n"),
                          "\(command.wire) has no terminator; the firmware's line "
                          + "reader would wait for ever.")
            XCTAssertFalse(command.wire.contains("\n"))
        }
    }

    /// A control waiting for an acknowledgement that will never arrive is a
    /// control stuck on "sending" for ever. The firmware acks most commands and
    /// answers the tuning ones with telemetry instead.
    func testCommandsThatNeverGetAnAckAreMarkedAsSuch() {
        XCTAssertFalse(Firmware.Command.status.expectsAcknowledgement)
        XCTAssertFalse(Firmware.Command.triggerThreshold(4).expectsAcknowledgement)
        XCTAssertFalse(Firmware.Command.stepCount(1024).expectsAcknowledgement)
        XCTAssertFalse(Firmware.Command.stepDelay(3000).expectsAcknowledgement)
        XCTAssertFalse(Firmware.Command.photoThreshold(600).expectsAcknowledgement)

        XCTAssertTrue(Firmware.Command.drill.expectsAcknowledgement)
        XCTAssertTrue(Firmware.Command.arm.expectsAcknowledgement)
        XCTAssertTrue(Firmware.Command.water(closed: true).expectsAcknowledgement)
    }

    func testMotorCommandsAreIdentifiedForTheQueue() {
        XCTAssertTrue(Firmware.Command.water(closed: true).movesMotor)
        XCTAssertTrue(Firmware.Command.power(on: false).movesMotor)
        XCTAssertTrue(Firmware.Command.drill.movesMotor)
        XCTAssertFalse(Firmware.Command.status.movesMotor)
        XCTAssertFalse(Firmware.Command.beep.movesMotor)
        XCTAssertFalse(Firmware.Command.triggerThreshold(4).movesMotor)
    }

    // MARK: Votes

    func testTheVoteSummaryMakesRejectionVisible() {
        XCTAssertEqual(Firmware.Votes(accelerometer: false, tilt: false, sound: false).summary,
                       "No channel is voting")
        XCTAssertEqual(Firmware.Votes(accelerometer: true, tilt: false, sound: false).summary,
                       "1 of 3 — not declared")
        XCTAssertEqual(Firmware.Votes(accelerometer: true, tilt: true, sound: false).summary,
                       "2 of 3 — event declared")
        XCTAssertEqual(Firmware.Votes(accelerometer: true, tilt: true, sound: true).summary,
                       "3 of 3 — event declared")
    }

    func testOneChannelIsNeverEnough() {
        XCTAssertFalse(Firmware.Votes(accelerometer: true, tilt: false, sound: false).isDeclared)
        XCTAssertFalse(Firmware.Votes(accelerometer: false, tilt: true, sound: false).isDeclared)
        XCTAssertFalse(Firmware.Votes(accelerometer: false, tilt: false, sound: true).isDeclared)
    }

    func testAnyTwoChannelsAreEnough() {
        XCTAssertTrue(Firmware.Votes(accelerometer: true, tilt: true, sound: false).isDeclared)
        XCTAssertTrue(Firmware.Votes(accelerometer: true, tilt: false, sound: true).isDeclared)
        XCTAssertTrue(Firmware.Votes(accelerometer: false, tilt: true, sound: true).isDeclared)
    }
}
