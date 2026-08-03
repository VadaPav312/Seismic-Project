import XCTest
@testable import SeismicDevice
import SeismicCore
import SeismicSignal

final class ProtocolFramingTests: XCTestCase {

    func testFrameRoundTrips() {
        let frame = NodeProtocol.Frame(type: .telemetry, payload: [1, 2, 3, 4, 5])
        var parser = NodeProtocol.Parser()
        let frames = parser.append(frame.encoded())
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].type, .telemetry)
        XCTAssertEqual(frames[0].payload, [1, 2, 3, 4, 5])
    }

    func testFrameSplitAcrossPacketsIsReassembled() {
        // BLE delivers whatever it likes; a frame arriving in three pieces is
        // completely ordinary.
        let encoded = NodeProtocol.Frame(type: .telemetry, payload: Array(0..<30)).encoded()
        var parser = NodeProtocol.Parser()
        XCTAssertTrue(parser.append(Array(encoded[0..<7])).isEmpty)
        XCTAssertTrue(parser.append(Array(encoded[7..<20])).isEmpty)
        let frames = parser.append(Array(encoded[20...]))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].payload, Array(0..<30))
    }

    func testMultipleFramesInOnePacket() {
        var bytes = NodeProtocol.Frame(type: .telemetry, payload: [1]).encoded()
        bytes.append(contentsOf: NodeProtocol.Frame(type: .fault, payload: [2]).encoded())
        bytes.append(contentsOf: NodeProtocol.Frame(type: .acknowledgement).encoded())

        var parser = NodeProtocol.Parser()
        let frames = parser.append(bytes)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames.map(\.type), [.telemetry, .fault, .acknowledgement])
    }

    func testCorruptedFrameIsRejectedNotDelivered() {
        var encoded = NodeProtocol.Frame(type: .telemetry, payload: [9, 9, 9]).encoded()
        encoded[6] ^= 0xFF          // flip a payload bit
        var parser = NodeProtocol.Parser()
        let frames = parser.append(encoded)
        XCTAssertTrue(frames.isEmpty, "a corrupt frame must never reach the app")
        XCTAssertEqual(parser.framesRejected, 1)
    }

    func testGarbageBeforeAFrameIsDiscardedAndTheFrameStillArrives() {
        var bytes: [UInt8] = [0x00, 0xFF, 0x12, 0x34, 0xAA]   // junk, including a partial header
        bytes.append(contentsOf: NodeProtocol.Frame(type: .fault, payload: [7]).encoded())
        var parser = NodeProtocol.Parser()
        let frames = parser.append(bytes)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].payload, [7])
        XCTAssertGreaterThan(parser.bytesDiscarded, 0)
    }

    func testParserRecoversAfterCorruptionAndReadsTheNextFrame() {
        var corrupt = NodeProtocol.Frame(type: .telemetry, payload: [1, 2, 3]).encoded()
        corrupt[5] ^= 0x55
        var bytes = corrupt
        bytes.append(contentsOf: NodeProtocol.Frame(type: .fault, payload: [42]).encoded())

        var parser = NodeProtocol.Parser()
        let frames = parser.append(bytes)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].payload, [42])
    }

    func testBufferDoesNotGrowWithoutBound() {
        var parser = NodeProtocol.Parser()
        for _ in 0..<200 { _ = parser.append([UInt8](repeating: 0x00, count: 100)) }
        XCTAssertLessThanOrEqual(parser.pendingBytes, 4096)
    }

    func testEveryMessageTypeKnowsItsDirection() {
        for type in NodeProtocol.MessageType.allCases {
            XCTAssertFalse(type.label.isEmpty)
            XCTAssertEqual(type.isFromNode, type.rawValue < 0x80)
        }
    }
}

final class PayloadCodingTests: XCTestCase {

    func testByteWriterAndReaderRoundTrip() {
        var writer = ByteWriter()
        writer.writeUInt8(200)
        writer.writeUInt16(60000)
        writer.writeInt16(-1234)
        writer.writeUInt32(4_000_000_000)
        writer.writeInt32(-2_000_000)
        writer.writeBool(true)
        writer.writeFixed16(3.14159, scale: 1000)
        let uuid = UUID()
        writer.writeUUID(uuid)

        var reader = ByteReader(writer.bytes)
        XCTAssertEqual(reader.readUInt8(), 200)
        XCTAssertEqual(reader.readUInt16(), 60000)
        XCTAssertEqual(reader.readInt16(), -1234)
        XCTAssertEqual(reader.readUInt32(), 4_000_000_000)
        XCTAssertEqual(reader.readInt32(), -2_000_000)
        XCTAssertEqual(reader.readBool(), true)
        XCTAssertEqual(reader.readFixed16(scale: 1000)!, 3.14159, accuracy: 0.001)
        XCTAssertEqual(reader.readUUID(), uuid)
        XCTAssertTrue(reader.isExhausted)
    }

    func testReaderReturnsNilPastTheEndRatherThanCrashing() {
        var reader = ByteReader([1, 2])
        XCTAssertNotNil(reader.readUInt16())
        XCTAssertNil(reader.readUInt16())
        XCTAssertNil(reader.readUInt32())
        XCTAssertNil(reader.readUUID())
    }

    func testFixedPointClampsRatherThanOverflowing() {
        var writer = ByteWriter()
        writer.writeFixed16(1e9, scale: 1000)     // far beyond Int16
        var reader = ByteReader(writer.bytes)
        XCTAssertNotNil(reader.readFixed16(scale: 1000))
    }

    func testTelemetryRoundTripsThroughItsBinaryForm() {
        let original = NodeTelemetry(
            state: .recording, timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            boardTemperature: 31.25, structureTemperature: 18.5,
            ambientVibrationRMS: 0.0042, measuredPeriod: 0.8734, staLtaRatio: 6.25,
            batteryPercent: 88, usbPowered: true, supplyVoltage: 4.93,
            activeCurrentDraw_mA: 640, gridPowerPresent: false, waterDetected: true,
            occupancyDetected: true, permanentTilt: true, tiltAngle: 1.75,
            residualDisplacement: 0.0234, faults: [.brownout, .calibrationInvalid])

        let decoded = NodeTelemetry.decode(payload: original.encodedPayload())
        XCTAssertNotNil(decoded)
        guard let decoded else { return }

        XCTAssertEqual(decoded.state, .recording)
        XCTAssertEqual(decoded.boardTemperature, 31.25, accuracy: 0.01)
        XCTAssertEqual(decoded.structureTemperature, 18.5, accuracy: 0.01)
        XCTAssertEqual(decoded.measuredPeriod!, 0.8734, accuracy: 0.001)
        XCTAssertEqual(decoded.staLtaRatio, 6.25, accuracy: 0.01)
        XCTAssertEqual(decoded.residualDisplacement, 0.0234, accuracy: 0.0002)
        XCTAssertEqual(decoded.tiltAngle, 1.75, accuracy: 0.01)
        XCTAssertFalse(decoded.gridPowerPresent)
        XCTAssertTrue(decoded.waterDetected)
        XCTAssertTrue(decoded.permanentTilt)
        XCTAssertEqual(Set(decoded.faults), Set([.brownout, .calibrationInvalid]))
    }

    func testTelemetryFitsInOneBLENotification() {
        let telemetry = NodeTelemetry()
        // A default BLE MTU gives 20 usable bytes; ours needs a slightly larger
        // one but must still fit a single 128-byte frame payload comfortably.
        XCTAssertLessThanOrEqual(telemetry.encodedPayload().count, 40)
    }

    func testNilPeriodSurvivesTheRoundTrip() {
        let telemetry = NodeTelemetry(measuredPeriod: nil, batteryPercent: nil)
        let decoded = NodeTelemetry.decode(payload: telemetry.encodedPayload())
        XCTAssertNil(decoded?.measuredPeriod)
        XCTAssertNil(decoded?.batteryPercent)
    }

    func testHighRateBatchRoundTrips() {
        let batch = HighRateBatch(sequence: 4242, sampleRate: 100,
                                  x: [0.1, -0.2, 0.35], y: [1, 2, 3], z: [-1, -2, -3])
        let decoded = HighRateBatch.decode(payload: batch.encodedPayload())
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.sequence, 4242)
        XCTAssertEqual(decoded?.count, 3)
        XCTAssertEqual(decoded!.x[2], 0.35, accuracy: 0.002)
        XCTAssertEqual(decoded!.z[0], -1, accuracy: 0.002)
    }

    func testEveryCommandRoundTrips() {
        let commands: [NodeCommand] = [
            .selfTest, .calibrateBaseline, .setSensitivity(4.5), .drill(fireActuators: true),
            .drill(fireActuators: false), .fireActuator(.mainsPower), .resetActuator(.waterMain),
            .setLED(r: 1, g: 0.5, b: 0), .buzz(pattern: "SOS"),
            .playTone(frequency: 440, duration: 1.5), .setMatrixText("SAFE"),
            .setSevenSegment("12.3"), .setFloorStressPattern(0b1010_1010),
            .requestPeriodMeasurement, .setShakeTableSpeed(0.75),
            .requestRecording(eventID: UUID(), fromChunk: 17),
            .syncClock(Date(timeIntervalSince1970: 1_700_000_000)),
            .acknowledgeEvent(UUID()), .abort,
        ]

        for command in commands {
            let decoded = NodeCommand.decode(payload: command.encodedPayload())
            XCTAssertNotNil(decoded, "\(command.label) failed to decode")
            // Fixed-point commands come back close rather than exact.
            switch (command, decoded) {
            case (.setSensitivity(let a), .setSensitivity(let b)):
                XCTAssertEqual(a, b, accuracy: 0.01)
            case (.setLED(let r1, let g1, let b1), .setLED(let r2, let g2, let b2)):
                XCTAssertEqual(r1, r2, accuracy: 0.01)
                XCTAssertEqual(g1, g2, accuracy: 0.01)
                XCTAssertEqual(b1, b2, accuracy: 0.01)
            case (.setShakeTableSpeed(let a), .setShakeTableSpeed(let b)):
                XCTAssertEqual(a, b, accuracy: 0.01)
            case (.playTone(let f1, let d1), .playTone(let f2, let d2)):
                XCTAssertEqual(f1, f2, accuracy: 1)
                XCTAssertEqual(d1, d2, accuracy: 0.01)
            default:
                XCTAssertEqual(command, decoded)
            }
        }
    }

    func testUnknownOpcodeDecodesToNilRatherThanAWrongCommand() {
        XCTAssertNil(NodeCommand.decode(payload: [0x7E]))
        XCTAssertNil(NodeCommand.decode(payload: []))
    }

    func testCommandsThatMoveMotorsAreIdentified() {
        XCTAssertTrue(NodeCommand.fireActuator(.waterMain).movesMotor)
        XCTAssertTrue(NodeCommand.fireActuator(.waterMain).movesMotor)
        XCTAssertFalse(NodeCommand.fireActuator(.mainsPower).movesMotor,
                       "a relay is not a motor")
        XCTAssertFalse(NodeCommand.selfTest.movesMotor)
        XCTAssertTrue(NodeCommand.setShakeTableSpeed(0.5).movesMotor)
        XCTAssertFalse(NodeCommand.setShakeTableSpeed(0).movesMotor)
    }
}

final class ChunkTransferTests: XCTestCase {

    private func record(seconds: Double = 6, sampleRate: Double = 100) -> TriaxialRecord {
        SyntheticMotion.generate(.init(magnitude: 6, distanceKm: 25, sampleRate: sampleRate,
                                       preEventSeconds: 2, seed: 88))
    }

    func testPerfectTransferReassemblesExactly() {
        let original = record()
        let eventID = UUID()
        let (manifest, chunks) = ChunkSplitter.split(original, eventID: eventID)

        let reassembler = ChunkReassembler()
        reassembler.begin(with: manifest)
        for chunk in chunks { XCTAssertTrue(reassembler.accept(chunk)) }

        XCTAssertTrue(reassembler.isComplete)
        let result = reassembler.finish()
        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(result.checksumMatches, result.summary)

        guard let rebuilt = result.record else { return XCTFail("no record") }
        XCTAssertGreaterThanOrEqual(rebuilt.count, original.count)
        for i in 0..<original.count {
            XCTAssertEqual(rebuilt.x.samples[i], original.x.samples[i], accuracy: 0.002)
            XCTAssertEqual(rebuilt.z.samples[i], original.z.samples[i], accuracy: 0.002)
        }
    }

    func testOutOfOrderChunksReassembleCorrectly() {
        let original = record(seconds: 4)
        let (manifest, chunks) = ChunkSplitter.split(original, eventID: UUID())

        let reassembler = ChunkReassembler()
        reassembler.begin(with: manifest)
        for chunk in chunks.shuffled() { reassembler.accept(chunk) }

        XCTAssertTrue(reassembler.isComplete)
        XCTAssertTrue(reassembler.finish().checksumMatches)
    }

    func testDuplicateChunksAreIgnoredHarmlessly() {
        let (manifest, chunks) = ChunkSplitter.split(record(seconds: 3), eventID: UUID())
        let reassembler = ChunkReassembler()
        reassembler.begin(with: manifest)
        for chunk in chunks { reassembler.accept(chunk) }
        for chunk in chunks.prefix(5) { reassembler.accept(chunk) }

        XCTAssertEqual(reassembler.duplicatesIgnored, 5)
        XCTAssertTrue(reassembler.finish().checksumMatches)
    }

    func testCorruptChunkIsRejectedAndReportedAsMissing() {
        let (manifest, chunks) = ChunkSplitter.split(record(seconds: 3), eventID: UUID())
        let reassembler = ChunkReassembler()
        reassembler.begin(with: manifest)

        for (index, chunk) in chunks.enumerated() {
            if index == 4 {
                // Corrupt the payload while keeping the original CRC.
                var broken = chunk
                broken.payload[0] ^= 0xFF
                XCTAssertFalse(reassembler.accept(broken))
            } else {
                reassembler.accept(chunk)
            }
        }

        XCTAssertEqual(reassembler.corruptChunksRejected, 1)
        XCTAssertEqual(reassembler.missingChunks, [4])
        XCTAssertFalse(reassembler.isComplete)
    }

    func testMissingChunksAreDetectedAndCompressedIntoRanges() {
        let (manifest, chunks) = ChunkSplitter.split(record(seconds: 8), eventID: UUID())
        let reassembler = ChunkReassembler()
        reassembler.begin(with: manifest)

        let dropped: Set<Int> = [3, 4, 5, 12, 20, 21]
        for chunk in chunks where !dropped.contains(chunk.index) {
            reassembler.accept(chunk)
        }

        XCTAssertEqual(Set(reassembler.missingChunks), dropped)
        XCTAssertEqual(reassembler.missingRanges, [3...5, 12...12, 20...21])
    }

    func testPartialTransferIsPreservedNotDiscarded() {
        // The acceptance criterion: losing connection mid-event must lose nothing.
        let original = record(seconds: 8)
        let eventID = UUID()
        let (manifest, chunks) = ChunkSplitter.split(original, eventID: eventID)

        let reassembler = ChunkReassembler()
        reassembler.begin(with: manifest)
        // Connection drops halfway.
        for chunk in chunks.prefix(chunks.count / 2) { reassembler.accept(chunk) }

        let partial = reassembler.finish()
        XCTAssertFalse(partial.isComplete)
        XCTAssertNotNil(partial.record, "a partial recording must still be usable")
        XCTAssertFalse(partial.missingChunks.isEmpty)
        XCTAssertTrue(partial.summary.contains("kept"))

        // Reconnect: the same manifest resumes rather than restarting.
        reassembler.begin(with: manifest)
        XCTAssertEqual(reassembler.missingChunks.count, chunks.count - chunks.count / 2)

        for chunk in chunks.suffix(chunks.count - chunks.count / 2) {
            reassembler.accept(chunk)
        }
        let full = reassembler.finish()
        XCTAssertTrue(full.isComplete)
        XCTAssertTrue(full.checksumMatches)
    }

    func testADifferentRecordingResetsTheBuffer() {
        let (manifestA, chunksA) = ChunkSplitter.split(record(seconds: 3), eventID: UUID())
        let reassembler = ChunkReassembler()
        reassembler.begin(with: manifestA)
        for chunk in chunksA.prefix(3) { reassembler.accept(chunk) }

        let (manifestB, _) = ChunkSplitter.split(record(seconds: 3), eventID: UUID())
        reassembler.begin(with: manifestB)
        XCTAssertEqual(reassembler.missingChunks.count, manifestB.totalChunks)
    }

    func testChunkFromTheWrongRecordingIsRejected() {
        let (manifest, chunks) = ChunkSplitter.split(record(seconds: 3), eventID: UUID())
        let reassembler = ChunkReassembler()
        reassembler.begin(with: manifest)

        var foreign = chunks[0]
        foreign = RecordingChunk(eventID: UUID(), index: 0, payload: foreign.payload)
        XCTAssertFalse(reassembler.accept(foreign))
    }

    func testProgressIsMonotonicAndReachesOne() {
        let (manifest, chunks) = ChunkSplitter.split(record(seconds: 5), eventID: UUID())
        let reassembler = ChunkReassembler()
        reassembler.begin(with: manifest)

        var previous = 0.0
        for chunk in chunks {
            reassembler.accept(chunk)
            XCTAssertGreaterThanOrEqual(reassembler.progress, previous)
            previous = reassembler.progress
        }
        XCTAssertEqual(reassembler.progress, 1.0, accuracy: 1e-9)
    }

    func testManifestRoundTrips() {
        let manifest = RecordingManifest(eventID: UUID(), totalChunks: 120, samplesPerChunk: 20,
                                         totalSamples: 2400, sampleRate: 100,
                                         startTime: Date(timeIntervalSince1970: 1_700_000_000),
                                         checksum: 0xDEADBEEF)
        let decoded = RecordingManifest.decode(payload: manifest.encodedPayload())
        XCTAssertEqual(decoded, manifest)
    }

    func testChunkPayloadRoundTrips() {
        let eventID = UUID()
        let chunk = RecordingChunk(eventID: eventID, index: 77, payload: Array(0..<60))
        let decoded = RecordingChunk.decode(payload: chunk.encodedPayload(), eventID: eventID)
        XCTAssertEqual(decoded?.index, 77)
        XCTAssertEqual(decoded?.payload, Array(0..<60))
        XCTAssertTrue(decoded?.isValid ?? false)
    }

    func testEmptyRecordingProducesNoChunksAndCompletesImmediately() {
        let empty = TriaxialRecord.zeros(count: 0, sampleRate: 100)
        let (manifest, chunks) = ChunkSplitter.split(empty, eventID: UUID())
        XCTAssertEqual(chunks.count, 0)
        let reassembler = ChunkReassembler()
        reassembler.begin(with: manifest)
        XCTAssertTrue(reassembler.isComplete)
    }
}

final class PowerBudgetTests: XCTestCase {

    /// The reason the node has two actuators and not three.
    ///
    /// A servo turning a gas valve draws about 240 mA and the water stepper
    /// draws 260, against a USB supply that has already spent 180 on the board.
    /// This is that arithmetic, kept as a test rather than as a comment,
    /// because it is the whole justification for the actuator that is missing.
    func testUSBCannotCarryTwoMotorsAtOnce() {
        let budget = PowerBudget.usb2
        XCTAssertFalse(budget.allowsSimultaneousMotors)
        // A relay is cheap enough to overlap with the stepper; a second motor
        // is not.
        // 500 mA supply, 180 for the board, 60 held back against brownout —
        // 260 left, which is exactly one stepper and nothing else. Even the
        // relay does not fit alongside it, which is why the sequence is
        // serialised rather than merely "no two servos".
        XCTAssertTrue(budget.canRun(.waterMain, alongside: []))
        XCTAssertFalse(budget.canRun(.mainsPower, alongside: [.waterMain]))
        XCTAssertLessThan(budget.availableForActuation,
                          240 + ActuatorKind.waterMain.peakCurrent_mA)
    }

    func testPlanSerialisesTheMotorsAndCutsPowerFirst() {
        let planner = ActuationPlanner(budget: .usb2)
        let steps = planner.plan(ActuatorKind.allCases)

        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].kind, .mainsPower,
                       "power must be cut first — live electrics in a building about to be "
                       + "flooded is what hurts people after the shaking")

        let power = steps.first { $0.kind == .mainsPower }!
        let water = steps.first { $0.kind == .waterMain }!
        XCTAssertTrue(water.startOffset >= power.endOffset,
                      "the two were scheduled to move at the same time")
    }

    func testPlanStaysWithinTheSupply() {
        let planner = ActuationPlanner(budget: .usb2)
        let steps = planner.plan(ActuatorKind.allCases)
        XCTAssertTrue(planner.staysWithinBudget(steps),
                      "peak draw \(planner.peakDraw(of: steps)) mA exceeds the supply")
    }

    func testSequenceTakesLongerOnAWeakerSupply() {
        let usb = ActuationPlanner(budget: .usb2).plan(ActuatorKind.allCases)
        let hub = ActuationPlanner(budget: .poweredHub).plan(ActuatorKind.allCases)
        let usbEnd = usb.map(\.endOffset).max() ?? 0
        let hubEnd = hub.map(\.endOffset).max() ?? 0
        XCTAssertLessThanOrEqual(hubEnd, usbEnd)
    }

    func testEveryStepExplainsWhyItIsWhereItIs() {
        for step in ActuationPlanner().plan(ActuatorKind.allCases) {
            XCTAssertFalse(step.reason.isEmpty)
        }
    }

    func testEmptyPlanIsHandled() {
        let planner = ActuationPlanner()
        XCTAssertTrue(planner.plan([]).isEmpty)
        XCTAssertEqual(planner.peakDraw(of: []), planner.budget.quiescent)
    }

    func testSequenceSummaryReflectsProgress() {
        let steps = ActuationPlanner().plan(ActuatorKind.allCases)
        var sequence = ActuationSequence(steps: steps)
        XCTAssertTrue(sequence.summary.contains("0 of 2"), sequence.summary)

        for kind in ActuatorKind.allCases {
            sequence.reports[kind] = ActuatorReport(kind: kind, state: .confirmed)
        }
        XCTAssertTrue(sequence.allConfirmed)
        XCTAssertTrue(sequence.summary.contains("All 2"), sequence.summary)

        sequence.reports[.waterMain] = ActuatorReport(kind: .waterMain, state: .failed)
        XCTAssertTrue(sequence.anyFailed)
        XCTAssertTrue(sequence.summary.contains("failed"))
    }

    func testBudgetExplainsItself() {
        XCTAssertTrue(PowerBudget.usb2.explanation.contains("one motor"))
        XCTAssertFalse(PowerBudget.poweredHub.explanation.isEmpty)
    }
}

final class SimulatedNodeTests: XCTestCase {

    /// Collects events so a test can assert on what the node actually said.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [NodeEvent] = []
        func record(_ event: NodeEvent) {
            lock.lock(); storage.append(event); lock.unlock()
        }
        var events: [NodeEvent] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        func clear() { lock.lock(); storage.removeAll(); lock.unlock() }
    }

    private func connectedNode(configuration: SimulatedNode.Configuration = .init())
        -> (SimulatedNode, Recorder)
    {
        let node = SimulatedNode(configuration: configuration)
        let recorder = Recorder()
        node.eventHandler = { [recorder] event in recorder.record(event) }
        node.startScanning()
        node.connect(to: node.identifier)
        return (node, recorder)
    }

    private func run(_ node: SimulatedNode, seconds: Double, step: Double = 0.05) {
        var elapsed = 0.0
        while elapsed < seconds {
            node.tick(deltaTime: step)
            elapsed += step
        }
    }

    func testDiscoversItselfAndConnects() {
        let (_, recorder) = connectedNode()
        let discovered = recorder.events.compactMap { event -> DiscoveredNode? in
            if case .discovered(let node) = event { return node }
            return nil
        }
        XCTAssertEqual(discovered.count, 1)
        XCTAssertTrue(discovered[0].isSimulated)

        let states = recorder.events.compactMap { event -> ConnectionState? in
            if case .connectionChanged(let state) = event { return state }
            return nil
        }
        XCTAssertTrue(states.contains(.simulated))
    }

    func testStreamsHighRateDataAndTelemetry() {
        let (node, recorder) = connectedNode()
        run(node, seconds: 3)

        let batches = recorder.events.compactMap { event -> HighRateBatch? in
            if case .highRate(let batch) = event { return batch }
            return nil
        }
        XCTAssertGreaterThan(batches.count, 20)
        XCTAssertGreaterThan(batches.reduce(0) { $0 + $1.count }, 250)

        let telemetry = recorder.events.compactMap { event -> NodeTelemetry? in
            if case .telemetry(let value) = event { return value }
            return nil
        }
        XCTAssertGreaterThanOrEqual(telemetry.count, 2)
    }

    func testAmbientDataIsQuietAndDoesNotTrigger() {
        let (node, recorder) = connectedNode()
        run(node, seconds: 20)

        let triggers = recorder.events.filter { if case .triggered = $0 { return true }; return false }
        XCTAssertTrue(triggers.isEmpty, "the node triggered on its own noise floor")

        let batches = recorder.events.compactMap { event -> HighRateBatch? in
            if case .highRate(let batch) = event { return batch }
            return nil
        }
        let peak = batches.flatMap(\.x).map(abs).max() ?? 0
        XCTAssertLessThan(peak, 0.1, "ambient noise is far too large")
    }

    func testAmbientDataCarriesTheBuildingsPeriod() {
        // The baseline measurement depends on this being present in the noise.
        let (node, _) = connectedNode(configuration: .init(buildingPeriod: 1.4, sampleRate: 100))
        let session = NodeSession()
        session.attach(node)
        node.connect(to: node.identifier)
        run(node, seconds: 120)

        let measurement = session.measurePeriodFromAmbient(band: 0.5...4)
        XCTAssertNotNil(measurement.consensus)
        XCTAssertEqual(measurement.consensus!, 1.4, accuracy: 0.5)
    }

    func testInjectedEarthquakeTriggersFiresActuatorsAndTransfersARecording() {
        let (node, recorder) = connectedNode()
        run(node, seconds: 12)          // let the detector settle on the noise floor
        recorder.clear()

        node.injectSyntheticEvent(magnitude: 6.5, distanceKm: 20)
        run(node, seconds: 60)

        let triggered = recorder.events.contains { if case .triggered = $0 { return true }; return false }
        XCTAssertTrue(triggered, "an injected magnitude 6.5 did not trigger the node")

        let reports = recorder.events.compactMap { event -> ActuatorReport? in
            if case .actuatorReport(let report) = event { return report }
            return nil
        }
        let confirmed = Set(reports.filter { $0.state == .confirmed }.map(\.kind))
        XCTAssertEqual(confirmed, Set(ActuatorKind.allCases),
                       "not every actuator confirmed")

        let manifests = recorder.events.compactMap { event -> RecordingManifest? in
            if case .recordingManifest(let manifest) = event { return manifest }
            return nil
        }
        XCTAssertFalse(manifests.isEmpty, "no recording was offered")
    }

    func testActuatorsFireOneAtATime() {
        let (node, recorder) = connectedNode()
        run(node, seconds: 12)
        recorder.clear()
        node.injectSyntheticEvent(magnitude: 6.5, distanceKm: 18)
        run(node, seconds: 40)

        // Walk the reports in order and check no two servos are ever moving.
        var moving: Set<ActuatorKind> = []
        var maximumConcurrentMotors = 0
        for event in recorder.events {
            guard case .actuatorReport(let report) = event else { continue }
            switch report.state {
            case .inProgress: moving.insert(report.kind)
            case .confirmed, .failed, .idle: moving.remove(report.kind)
            default: break
            }
            let motors = moving.filter { $0.peakCurrent_mA > 200 }
            maximumConcurrentMotors = max(maximumConcurrentMotors, motors.count)
        }
        XCTAssertLessThanOrEqual(maximumConcurrentMotors, 1,
                                 "two motors moved at once on a USB supply")
    }

    func testDamageLengthensTheMeasuredPeriod() {
        let (node, _) = connectedNode(configuration: .init(buildingPeriod: 1.0))
        node.send(.calibrateBaseline)
        let before = node.trueperiod

        run(node, seconds: 12)
        node.injectSyntheticEvent(magnitude: 7.2, distanceKm: 8)
        run(node, seconds: 80)

        XCTAssertGreaterThan(node.trueDamageFactor, 1.0,
                             "a violent event caused no simulated damage")
        XCTAssertGreaterThan(node.trueperiod, before * 1.02)
    }

    func testDeliberateDamageInjectionForTheTutorial() {
        let (node, _) = connectedNode(configuration: .init(buildingPeriod: 1.0))
        let before = node.trueperiod
        node.introduceSimulatedDamage(periodIncreaseFraction: 0.15)
        XCTAssertEqual(node.trueperiod / before, 1.15, accuracy: 0.02)
    }

    func testRecordingIsBufferedWhileDisconnectedAndDeliveredOnReconnect() {
        // The headline resilience claim, exercised end to end.
        let (node, recorder) = connectedNode()
        run(node, seconds: 12)

        node.simulateConnectionLoss()
        recorder.clear()
        node.injectSyntheticEvent(magnitude: 6.6, distanceKm: 15)
        run(node, seconds: 60)

        node.restoreConnection()
        run(node, seconds: 60)

        let manifests = recorder.events.compactMap { event -> RecordingManifest? in
            if case .recordingManifest(let manifest) = event { return manifest }
            return nil
        }
        XCTAssertFalse(manifests.isEmpty,
                       "the recording captured while disconnected was never delivered")
    }

    func testSelfTestReportsEveryCheck() {
        let (node, recorder) = connectedNode()
        node.send(.selfTest)

        let results = recorder.events.compactMap { event -> SelfTestResult? in
            if case .selfTestResult(let result) = event { return result }
            return nil
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertGreaterThanOrEqual(results[0].checks.count, 10)
        XCTAssertFalse(results[0].summary.isEmpty)
        for check in results[0].checks { XCTAssertFalse(check.detail.isEmpty) }
    }

    func testUncalibratedNodeFailsItsBaselineCheckThenPasses() {
        let (node, recorder) = connectedNode()
        node.send(.selfTest)
        var results = recorder.events.compactMap { event -> SelfTestResult? in
            if case .selfTestResult(let result) = event { return result }
            return nil
        }
        XCTAssertFalse(results[0].passed)
        XCTAssertTrue(results[0].failedChecks.contains { $0.name.contains("Baseline") })

        recorder.clear()
        node.send(.calibrateBaseline)
        node.send(.selfTest)
        results = recorder.events.compactMap { event -> SelfTestResult? in
            if case .selfTestResult(let result) = event { return result }
            return nil
        }
        XCTAssertTrue(results[0].passed, results[0].summary)
    }

    func testManualActuatorFireIsRefusedWhileAnotherMotorIsMoving() {
        let (node, recorder) = connectedNode()
        node.send(.fireActuator(.mainsPower))
        node.tick(deltaTime: 0.1)
        recorder.clear()
        node.send(.fireActuator(.waterMain))

        let reports = recorder.events.compactMap { event -> ActuatorReport? in
            if case .actuatorReport(let report) = event { return report }
            return nil
        }
        XCTAssertTrue(reports.contains { $0.kind == .waterMain && $0.state == .failed })
    }

    func testCommandsAreIgnoredWhileDisconnected() {
        let node = SimulatedNode()
        let recorder = Recorder()
        node.eventHandler = { [recorder] event in recorder.record(event) }
        node.send(.selfTest)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testSameSeedProducesTheSameStream() {
        let (a, recorderA) = connectedNode(configuration: .init(seed: 555))
        let (b, recorderB) = connectedNode(configuration: .init(seed: 555))
        run(a, seconds: 2); run(b, seconds: 2)

        let batchesA = recorderA.events.compactMap { event -> [Double]? in
            if case .highRate(let batch) = event { return batch.x }
            return nil
        }.flatMap { $0 }
        let batchesB = recorderB.events.compactMap { event -> [Double]? in
            if case .highRate(let batch) = event { return batch.x }
            return nil
        }.flatMap { $0 }
        XCTAssertEqual(batchesA, batchesB, "the simulator is not reproducible")
    }

    func testShakeTableDrivesTheSensor() {
        let (node, recorder) = connectedNode()
        run(node, seconds: 2)
        recorder.clear()
        node.send(.setShakeTableSpeed(0.8))
        run(node, seconds: 3)

        let peak = recorder.events.compactMap { event -> [Double]? in
            if case .highRate(let batch) = event { return batch.x }
            return nil
        }.flatMap { $0 }.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.5)
    }
}

final class NodeSessionTests: XCTestCase {

    func testBufferIsBoundedByTheConfiguredWindow() {
        let session = NodeSession(bufferSeconds: 5)
        let node = SimulatedNode()
        session.attach(node)
        node.startScanning()
        node.connect(to: node.identifier)

        for _ in 0..<400 { node.tick(deltaTime: 0.05) }   // 20 s of data
        let snapshot = session.snapshot()
        XCTAssertLessThanOrEqual(snapshot.recent.count, Int(5 * 100) + 20)
        XCTAssertGreaterThan(snapshot.recent.count, 100)
    }

    func testSnapshotReportsSimulationHonestly() {
        let session = NodeSession()
        let node = SimulatedNode()
        session.attach(node)
        node.startScanning()
        node.connect(to: node.identifier)
        node.tick(deltaTime: 0.1)

        let snapshot = session.snapshot()
        XCTAssertTrue(snapshot.isSimulated)
        XCTAssertTrue(snapshot.connection.isSimulated)
        XCTAssertEqual(snapshot.nodeName, "Simulated node")
    }

    func testCompletedTransferIsHandedToTheApp() {
        let session = NodeSession()
        let node = SimulatedNode()
        session.attach(node)
        node.startScanning()
        node.connect(to: node.identifier)

        let expectation = expectation(description: "recording delivered")
        let box = ResultBox()
        session.onRecordingComplete = { _, result in
            box.store(result)
            expectation.fulfill()
        }

        for _ in 0..<240 { node.tick(deltaTime: 0.05) }
        node.injectSyntheticEvent(magnitude: 6.4, distanceKm: 20)
        for _ in 0..<3000 { node.tick(deltaTime: 0.05) }

        wait(for: [expectation], timeout: 5)
        XCTAssertTrue(box.value?.isComplete ?? false, box.value?.summary ?? "no result")
        XCTAssertTrue(box.value?.checksumMatches ?? false)
    }

    func testEmptySessionSnapshotIsSafe() {
        let snapshot = NodeSession().snapshot()
        XCTAssertEqual(snapshot.recent.count, 0)
        XCTAssertEqual(snapshot.connection, .disconnected)
        XCTAssertEqual(snapshot.nodeName, "No node")
    }

    func testAmbientMeasurementDeclinesWithoutEnoughData() {
        let result = NodeSession().measurePeriodFromAmbient()
        XCTAssertNil(result.consensus)
        XCTAssertTrue(result.explanation.contains("Not enough"))
    }
}

/// Thread-safe box for capturing an async callback's result.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: ChunkReassembler.Result?
    func store(_ value: ChunkReassembler.Result) {
        lock.lock(); if storage == nil { storage = value }; lock.unlock()
    }
    var value: ChunkReassembler.Result? {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
