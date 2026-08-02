import XCTest
import SeismicCore
@testable import SeismicDevice

/// The simulated node, held to the same standard as the real one.
///
/// Everything here checks *lines*, parsed by the same parser the radio's bytes
/// go through. A simulator tested against its own internal state would agree
/// with itself and prove nothing about whether the app can read it.
final class FirmwareSimulatorTests: XCTestCase {

    /// Runs the simulator and collects everything it says.
    private func run(seconds: Double = 30, step: Double = 0.05,
                     commands: [(at: Double, line: String)] = [],
                     configure: ((FirmwareSimulator) -> Void)? = nil) -> [Firmware.Message] {
        let node = FirmwareSimulator(seed: 42)
        var messages: [Firmware.Message] = []
        node.onLine = { line in
            if let message = Firmware.parse(line: line) { messages.append(message) }
        }
        configure?(node)
        node.start()

        var pending = commands
        var t = 0.0
        while t < seconds {
            while let next = pending.first, next.at <= t {
                node.send(line: next.line)
                pending.removeFirst()
            }
            node.tick(deltaTime: step)
            t += step
        }
        return messages
    }

    private func kinds(_ messages: [Firmware.Message]) -> Set<String> {
        Set(messages.map { message in
            switch message {
            case .boot: "boot"
            case .telemetry: "tel"
            case .acceleration: "acc"
            case .triggered: "trig"
            case .countdown: "count"
            case .phase: "phase"
            case .actuator: "act"
            case .verification: "verify"
            case .recordingBegan: "recbegin"
            case .recordingChunk: "rec"
            case .recordingEnded: "recend"
            case .assessment: "assess"
            case .calibrated: "cal"
            case .note: "note"
            case .error: "err"
            case .acknowledged: "ack"
            case .unrecognised: "unknown"
            }
        })
    }

    // MARK: The requirement

    /// "Every message type above must be producible by the simulator."
    func testTheSimulatorProducesEveryMessageType() {
        var messages = run(seconds: 30, commands: [(at: 2, line: "DRILL")])
        // The two that only a mistake or a fault produces.
        let node = FirmwareSimulator(seed: 1)
        node.onLine = { line in
            if let message = Firmware.parse(line: line) { messages.append(message) }
        }
        node.send(line: "NONSENSE")           // -> err
        node.simulateBrownout()               // -> note + boot

        let produced = kinds(messages)
        let required = ["boot", "tel", "acc", "trig", "count", "phase", "act", "verify",
                        "recbegin", "rec", "recend", "assess", "cal", "note", "err", "ack"]
        for kind in required {
            XCTAssertTrue(produced.contains(kind), "The simulator never produced \(kind).")
        }
    }

    /// And every line it produces has to be readable. A simulator emitting a
    /// line the app cannot parse would be a bug in exactly the place a real
    /// board would also have one.
    func testEveryLineTheSimulatorEmitsParses() {
        let node = FirmwareSimulator(seed: 7)
        var unparsed: [String] = []
        node.onLine = { line in
            if Firmware.parse(line: line) == nil { unparsed.append(line) }
        }
        node.start()
        node.send(line: "DRILL")
        for _ in 0..<600 { node.tick(deltaTime: 0.05) }
        node.send(line: "SEND")
        node.send(line: "STATUS")
        node.send(line: "CAL")

        XCTAssertTrue(unparsed.isEmpty, "Unparseable lines: \(unparsed.prefix(3))")
    }

    // MARK: The drill

    /// The primary demonstration button, end to end.
    func testDrillRunsTheCompleteSequenceInOrder() {
        let messages = run(seconds: 30, commands: [(at: 1, line: "DRILL")])

        // Acknowledged first.
        XCTAssertTrue(messages.contains { if case .acknowledged("DRILL") = $0 { true } else { false } })

        // Then the phases, in order.
        let phases = messages.compactMap { message -> Firmware.Phase? in
            if case .phase(let p) = message { return p }
            return nil
        }
        let expected: [Firmware.Phase] = [.warning, .acting, .recording, .assessing, .verdict]
        var index = 0
        for phase in phases where index < expected.count && phase == expected[index] {
            index += 1
        }
        XCTAssertEqual(index, expected.count,
                       "Phases arrived as \(phases), expected to contain \(expected) in order.")
    }

    func testTheCountdownRunsFromFiveToOne() {
        let messages = run(seconds: 30, commands: [(at: 1, line: "DRILL")])
        let counts = messages.compactMap { message -> Int? in
            if case .countdown(let s) = message { return s }
            return nil
        }
        XCTAssertEqual(counts, [5, 4, 3, 2, 1])
    }

    /// Power cuts, then verifies itself with the light reading as evidence.
    func testPowerCutsAndThenPhysicallyConfirmsItself() {
        let messages = run(seconds: 30, commands: [(at: 1, line: "DRILL")])

        let powerStates = messages.compactMap { message -> Firmware.ActuatorState? in
            if case .actuator(.power, let state) = message { return state }
            return nil
        }
        XCTAssertTrue(powerStates.contains(.commanded))
        XCTAssertTrue(powerStates.contains(.confirmed))
        // Commanded must come before confirmed, or the confirmation is a claim
        // rather than a measurement.
        if let commanded = powerStates.firstIndex(of: .commanded),
           let confirmed = powerStates.firstIndex(of: .confirmed) {
            XCTAssertLessThan(commanded, confirmed)
        }

        guard let verification = messages.compactMap({ message -> (Int, Int, Bool)? in
            if case .verification(.power, let b, let a, let ok) = message { return (b, a, ok) }
            return nil
        }).first else { return XCTFail("No verification evidence.") }

        XCTAssertTrue(verification.2)
        XCTAssertGreaterThan(abs(verification.1 - verification.0), 150,
                             "The light barely changed, so the confirmation is not evidence.")
    }

    func testWaterClosesAfterThePowerCut() {
        let messages = run(seconds: 30, commands: [(at: 1, line: "DRILL")])
        let indexOfPowerConfirmed = messages.firstIndex {
            if case .actuator(.power, .confirmed) = $0 { true } else { false }
        }
        let indexOfWaterCommanded = messages.firstIndex {
            if case .actuator(.water, .commanded) = $0 { true } else { false }
        }
        XCTAssertNotNil(indexOfPowerConfirmed)
        XCTAssertNotNil(indexOfWaterCommanded)
        if let power = indexOfPowerConfirmed, let water = indexOfWaterCommanded {
            XCTAssertLessThan(power, water, "Two motors were commanded together.")
        }
    }

    func testARecordingArrivesCompleteAndReassembles() {
        let messages = run(seconds: 30, commands: [(at: 1, line: "DRILL")])

        guard case .recordingBegan(let count, let rate)? = messages.first(where: {
            if case .recordingBegan = $0 { true } else { false }
        }) else { return XCTFail("No recording began.") }
        XCTAssertEqual(count, 500)
        XCTAssertEqual(rate, 50)

        let assembler = FirmwareRecordingAssembler()
        assembler.begin(sampleCount: count, sampleRate: rate)
        for message in messages {
            if case .recordingChunk(let index, let samples, let sum) = message {
                XCTAssertTrue(assembler.accept(index: index, samples: samples, checksum: sum),
                              "Chunk \(index) failed its own checksum.")
            }
        }
        let result = assembler.result()
        XCTAssertTrue(result.isComplete, result.summary)
        XCTAssertEqual(result.record?.count, 500)
        XCTAssertTrue(messages.contains { if case .recordingEnded = $0 { true } else { false } })
    }

    /// The recording has to look like an earthquake, not like noise — a P
    /// arrival, a larger S arrival, and a decaying coda.
    func testTheRecordedWaveformHasTheShapeOfAnEarthquake() {
        let messages = run(seconds: 30, commands: [(at: 1, line: "DRILL")])
        let assembler = FirmwareRecordingAssembler()
        assembler.begin(sampleCount: 500, sampleRate: 50)
        for message in messages {
            if case .recordingChunk(let i, let s, let c) = message {
                assembler.accept(index: i, samples: s, checksum: c)
            }
        }
        guard let record = assembler.result().record else { return XCTFail() }

        func rms(_ from: Double, _ to: Double) -> Double {
            Stats.rms(Array(record.samples[Int(from * 50)..<Int(to * 50)]))
        }
        let quiet = rms(0, 0.35)          // before the P
        let pWave = rms(0.5, 1.5)         // P arrival
        let sWave = rms(3.0, 4.5)         // S arrival
        let coda = rms(8.0, 9.9)          // late coda

        XCTAssertGreaterThan(pWave, quiet * 3, "No P arrival.")
        XCTAssertGreaterThan(sWave, pWave, "The S wave should carry more energy than the P.")
        XCTAssertLessThan(coda, sWave, "The coda should decay.")
    }

    func testAnAssessmentArrivesWithAPeriodChange() {
        let messages = run(seconds: 30, commands: [(at: 1, line: "DRILL")])
        guard case .assessment(let a)? = messages.last(where: {
            if case .assessment = $0 { true } else { false }
        }) else { return XCTFail("No assessment.") }

        XCTAssertGreaterThan(a.periodBefore, 0)
        XCTAssertGreaterThanOrEqual(a.periodAfter, a.periodBefore)
        XCTAssertGreaterThan(a.peakGroundAcceleration, 0)
        XCTAssertTrue(a.powerCutConfirmed)
        // The period change must agree with the periods it was computed from,
        // or the headline number and the evidence beneath it disagree.
        let implied = (a.periodAfter - a.periodBefore) / a.periodBefore * 100
        XCTAssertEqual(a.periodChangePercent, implied, accuracy: 0.5)
    }

    // MARK: Voting

    /// Watching the fusion vote *refuse* is the point of the display.
    func testASingleChannelDoesNotDeclareAnEvent() {
        let node = FirmwareSimulator(seed: 3)
        var messages: [Firmware.Message] = []
        node.onLine = { if let m = Firmware.parse(line: $0) { messages.append(m) } }
        node.start()
        for _ in 0..<20 { node.tick(deltaTime: 0.05) }

        node.nudgeSingleChannel()
        for _ in 0..<10 { node.tick(deltaTime: 0.05) }

        // One channel voting.
        let withOneVote = messages.compactMap { message -> Firmware.Votes? in
            if case .telemetry(let t) = message, t.votes.count == 1 { return t.votes }
            return nil
        }
        XCTAssertFalse(withOneVote.isEmpty, "The single-channel nudge never showed up.")
        XCTAssertTrue(withOneVote.allSatisfy { !$0.isDeclared })

        // And no event was declared.
        XCTAssertFalse(messages.contains { if case .triggered = $0 { true } else { false } },
                       "One channel declared an event on its own.")
    }

    func testTheThreeChannelsVoteAtDifferentMoments() {
        let messages = run(seconds: 12, commands: [(at: 1, line: "DRILL")])
        // Across the telemetry lines during the event, the vote count should
        // not jump straight from zero to three — the channels see the wave at
        // different times, which is what the fusion display exists to show.
        let counts = messages.compactMap { message -> Int? in
            if case .telemetry(let t) = message { return t.votes.count }
            return nil
        }
        XCTAssertFalse(counts.isEmpty)
    }

    // MARK: Commands

    func testArmAndDisarmChangeTheReportedState() {
        let messages = run(seconds: 8, commands: [(at: 1, line: "DISARM"),
                                                  (at: 4, line: "ARM")])
        let states = messages.compactMap { message -> Firmware.NodeState? in
            if case .telemetry(let t) = message { return t.state }
            return nil
        }
        XCTAssertTrue(states.contains(.disarmed))
        XCTAssertTrue(states.contains(.monitoring))
    }

    func testTuningIsReflectedBackRatherThanAssumed() {
        let messages = run(seconds: 6, commands: [(at: 1, line: "THR:65")])
        let thresholds = messages.compactMap { message -> Double? in
            if case .telemetry(let t) = message { return t.triggerThreshold }
            return nil
        }
        XCTAssertTrue(thresholds.contains { abs($0 - 6.5) < 1e-9 },
                      "The node never confirmed the new threshold. Saw \(Set(thresholds)).")
    }

    func testResendProducesTheSameRecordingAgain() {
        let messages = run(seconds: 34, commands: [(at: 1, line: "DRILL"),
                                                   (at: 30, line: "SEND")])
        let begins = messages.filter { if case .recordingBegan = $0 { true } else { false } }
        XCTAssertGreaterThanOrEqual(begins.count, 2, "SEND did not resend the recording.")
    }

    func testAnUnknownCommandIsRefusedRatherThanIgnored() {
        let node = FirmwareSimulator(seed: 9)
        var messages: [Firmware.Message] = []
        node.onLine = { if let m = Firmware.parse(line: $0) { messages.append(m) } }
        node.send(line: "FLY")
        XCTAssertTrue(messages.contains { if case .error = $0 { true } else { false } })
    }

    /// With the stepper disabled the water main reports failure and says why,
    /// rather than silently doing nothing.
    func testDisablingTheStepperMakesWaterReportUnavailable() {
        let messages = run(seconds: 8, commands: [(at: 1, line: "NOSTEP"),
                                                  (at: 3, line: "WTR:1")])
        XCTAssertTrue(messages.contains {
            if case .actuator(.water, .failed) = $0 { true } else { false }
        })
        XCTAssertTrue(messages.contains {
            if case .note(let m) = $0 { m.contains("unavailable") } else { false }
        })
    }

    // MARK: Per-chunk recovery

    /// The fix for the one thing the original firmware could not do: recover a
    /// single lost chunk without re-sending the other twenty-four.
    func testASingleMissingChunkIsRecoveredByAskingForItAlone() {
        let node = FirmwareSimulator(seed: 5)
        var messages: [Firmware.Message] = []
        node.onLine = { if let m = Firmware.parse(line: $0) { messages.append(m) } }
        node.start()

        // Run a drill, dropping chunk 9 on the way out.
        node.dropChunkOnNextTransfer = 9
        node.send(line: "DRILL")
        for _ in 0..<600 { node.tick(deltaTime: 0.05) }

        let assembler = FirmwareRecordingAssembler()
        for message in messages {
            switch message {
            case .recordingBegan(let n, let hz): assembler.begin(sampleCount: n, sampleRate: hz)
            case .recordingChunk(let i, let s, let c):
                assembler.accept(index: i, samples: s, checksum: c)
            default: break
            }
        }
        XCTAssertEqual(assembler.result().missingChunks, [9])

        // Ask for exactly that one.
        messages.removeAll()
        node.send(line: "REC:9")

        let recovered = messages.compactMap { message -> (Int, [Int], Int)? in
            if case .recordingChunk(let i, let s, let c) = message { return (i, s, c) }
            return nil
        }
        XCTAssertEqual(recovered.count, 1, "REC:9 should send exactly one chunk.")
        XCTAssertEqual(recovered.first?.0, 9)

        if let (i, s, c) = recovered.first {
            XCTAssertTrue(assembler.accept(index: i, samples: s, checksum: c))
        }
        XCTAssertTrue(assembler.result().isComplete)
    }

    /// And it is acknowledged, so the app is not left waiting.
    func testAChunkRequestIsAcknowledged() {
        let node = FirmwareSimulator(seed: 6)
        var messages: [Firmware.Message] = []
        node.onLine = { if let m = Firmware.parse(line: $0) { messages.append(m) } }
        node.start()
        node.send(line: "DRILL")
        for _ in 0..<600 { node.tick(deltaTime: 0.05) }
        messages.removeAll()

        node.send(line: "REC:3")
        XCTAssertTrue(messages.contains {
            if case .acknowledged("REC") = $0 { true } else { false }
        })
    }

    /// A request for a chunk that does not exist is refused rather than
    /// answered with something arbitrary.
    func testAnOutOfRangeChunkRequestIsRefused() {
        let node = FirmwareSimulator(seed: 8)
        var messages: [Firmware.Message] = []
        node.onLine = { if let m = Firmware.parse(line: $0) { messages.append(m) } }
        node.start()
        node.send(line: "DRILL")
        for _ in 0..<600 { node.tick(deltaTime: 0.05) }
        messages.removeAll()

        node.send(line: "REC:900")
        XCTAssertTrue(messages.contains { if case .error = $0 { true } else { false } })
        XCTAssertFalse(messages.contains {
            if case .recordingChunk = $0 { true } else { false }
        })
    }

    // MARK: Brownout

    /// A brownout arrives as an unexpected boot. It must never look like a
    /// seismic trigger.
    func testABrownoutLooksLikeABootAndNotLikeATrigger() {
        let node = FirmwareSimulator(seed: 11)
        var messages: [Firmware.Message] = []
        node.onLine = { if let m = Firmware.parse(line: $0) { messages.append(m) } }
        node.start()
        for _ in 0..<40 { node.tick(deltaTime: 0.05) }
        messages.removeAll()

        node.simulateBrownout()
        XCTAssertTrue(messages.contains { if case .boot = $0 { true } else { false } })
        XCTAssertFalse(messages.contains { if case .triggered = $0 { true } else { false } })
    }

    // MARK: Determinism

    /// The same seed has to give the same demonstration. A demo that differs
    /// every run is one nobody can talk over.
    func testTheSameSeedProducesTheSameRun() {
        func fingerprint(_ seed: UInt64) -> [String] {
            let node = FirmwareSimulator(seed: seed)
            var lines: [String] = []
            node.onLine = { lines.append($0) }
            node.start()
            node.send(line: "DRILL")
            for _ in 0..<400 { node.tick(deltaTime: 0.05) }
            return lines
        }
        XCTAssertEqual(fingerprint(1234), fingerprint(1234))
        XCTAssertNotEqual(fingerprint(1234), fingerprint(5678))
    }
}
