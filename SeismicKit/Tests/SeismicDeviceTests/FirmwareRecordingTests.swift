import XCTest
import SeismicCore
@testable import SeismicDevice

final class FirmwareRecordingTests: XCTestCase {

    /// One chunk as the firmware would send it: twenty samples and their
    /// arithmetic sum.
    private func chunk(_ index: Int, base: Int = 0) -> (Int, [Int], Int) {
        let samples = (0..<20).map { base + index * 20 + $0 }
        return (index, samples, samples.reduce(0, +))
    }

    private func assembler(samples: Int = 500) -> FirmwareRecordingAssembler {
        let a = FirmwareRecordingAssembler()
        a.begin(sampleCount: samples, sampleRate: 50)
        return a
    }

    // MARK: The happy path

    func testAWholeRecordingReassembles() {
        let a = assembler()
        for index in 0..<25 {
            let (i, samples, sum) = chunk(index)
            XCTAssertTrue(a.accept(index: i, samples: samples, checksum: sum))
        }
        a.end()

        let result = a.result()
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.receivedChunks, 25)
        XCTAssertEqual(result.expectedChunks, 25)
        XCTAssertTrue(result.missingChunks.isEmpty)
        XCTAssertEqual(result.record?.count, 500)
        XCTAssertEqual(result.record?.sampleRate, 50)
        XCTAssertTrue(result.summary.contains("Complete"))
    }

    /// Ten seconds at fifty hertz. If this drifts, every duration in the app
    /// drifts with it.
    func testAFullRecordingIsTenSeconds() {
        let a = assembler()
        for index in 0..<25 {
            let (i, s, c) = chunk(index)
            a.accept(index: i, samples: s, checksum: c)
        }
        XCTAssertEqual(a.result().record?.duration ?? 0, 10, accuracy: 0.01)
    }

    /// Raw counts to m/s². The firmware records deviation from calibrated
    /// gravity in ±2 g counts, 16384 per g.
    func testCountsAreConvertedToAcceleration() {
        let a = assembler(samples: 20)
        let samples = [Int](repeating: 16384, count: 20)     // exactly 1 g
        a.accept(index: 0, samples: samples, checksum: samples.reduce(0, +))
        let first = a.result().record?.samples.first ?? 0
        XCTAssertEqual(first, gravity, accuracy: 1e-6)
    }

    // MARK: Losses

    /// The rule the whole class is built around: a partial recording is kept.
    func testAPartialRecordingIsKeptRatherThanDiscarded() {
        let a = assembler()
        for index in 0..<25 where index != 7 && index != 19 {
            let (i, s, c) = chunk(index)
            a.accept(index: i, samples: s, checksum: c)
        }
        a.end()

        let result = a.result()
        XCTAssertFalse(result.isComplete)
        XCTAssertNotNil(result.record, "A partial recording was discarded.")
        XCTAssertEqual(result.record?.count, 500)
        XCTAssertEqual(result.missingChunks, [7, 19])
        XCTAssertTrue(result.summary.contains("incomplete"))
    }

    func testGapsAreNamedIndividually() {
        let a = assembler(samples: 100)              // five chunks
        for index in [0, 2, 4] {
            let (i, s, c) = chunk(index)
            a.accept(index: i, samples: s, checksum: c)
        }
        XCTAssertEqual(a.missingChunks, [1, 3])
        XCTAssertEqual(a.progress, 0.6, accuracy: 1e-9)
    }

    /// A missing chunk shows as a gap of zeroes, and the samples around it are
    /// still where they belong. Shifting everything up to close the gap would
    /// silently corrupt every timestamp after it.
    func testAMissingChunkLeavesAGapRatherThanShiftingTheRest() {
        let a = assembler(samples: 60)
        let (i0, s0, c0) = chunk(0, base: 100)
        let (i2, s2, c2) = chunk(2, base: 100)
        a.accept(index: i0, samples: s0, checksum: c0)
        a.accept(index: i2, samples: s2, checksum: c2)

        guard let record = a.result().record else { return XCTFail() }
        XCTAssertEqual(record.count, 60)
        // Chunk 2's first sample must still be at position 40.
        XCTAssertEqual(record.samples[40], Double(s2[0]) / 16384.0 * gravity, accuracy: 1e-9)
        // The gap is zeroes.
        for i in 20..<40 { XCTAssertEqual(record.samples[i], 0) }
    }

    // MARK: Corruption

    func testAChunkThatFailsItsChecksumIsRejected() {
        let a = assembler(samples: 40)
        let (i, samples, sum) = chunk(0)
        XCTAssertFalse(a.accept(index: i, samples: samples, checksum: sum + 1))

        let result = a.result()
        XCTAssertEqual(result.corruptChunks, [0])
        XCTAssertEqual(result.missingChunks, [0, 1])
        XCTAssertTrue(result.summary.contains("checksum"))
    }

    /// A resend of a chunk that arrived corrupt should clear the mark.
    func testAGoodResendClearsAPreviousCorruption() {
        let a = assembler(samples: 20)
        let (i, samples, sum) = chunk(0)
        a.accept(index: i, samples: samples, checksum: sum + 1)
        XCTAssertEqual(a.result().corruptChunks, [0])

        a.accept(index: i, samples: samples, checksum: sum)
        let result = a.result()
        XCTAssertTrue(result.corruptChunks.isEmpty)
        XCTAssertTrue(result.isComplete)
    }

    func testAnEmptyChunkIsRejected() {
        let a = assembler(samples: 20)
        XCTAssertFalse(a.accept(index: 0, samples: [], checksum: 0))
    }

    // MARK: Merging across a dropped link

    /// The behaviour that makes "never lose an event" true.
    ///
    /// The link drops halfway through a transfer. On reconnect the app asks for
    /// the recording again, and the firmware — which has no way to send a
    /// single chunk — sends all of it. The chunks that already arrived must not
    /// be thrown away and re-received; the ones that were missing must fill in.
    func testAResendMergesIntoWhatAlreadyArrived() {
        let a = assembler()
        // First attempt: the link dies after twelve chunks.
        for index in 0..<12 {
            let (i, s, c) = chunk(index)
            a.accept(index: i, samples: s, checksum: c)
        }
        XCTAssertFalse(a.result().isComplete)
        XCTAssertEqual(a.result().receivedChunks, 12)

        // Reconnect and ask again. Same length, so the same recording.
        a.begin(sampleCount: 500, sampleRate: 50)
        XCTAssertEqual(a.result().receivedChunks, 12,
                       "Reopening the transfer threw away what had arrived.")

        // The rest arrives.
        for index in 12..<25 {
            let (i, s, c) = chunk(index)
            a.accept(index: i, samples: s, checksum: c)
        }
        a.end()
        XCTAssertTrue(a.result().isComplete)
    }

    /// A recording of a different length is a different recording, so nothing
    /// carries over. Merging two events into one buffer would be worse than
    /// losing one.
    func testADifferentRecordingDoesNotMergeWithTheOldOne() {
        let a = assembler()
        for index in 0..<12 {
            let (i, s, c) = chunk(index)
            a.accept(index: i, samples: s, checksum: c)
        }
        a.begin(sampleCount: 200, sampleRate: 50)
        XCTAssertEqual(a.result().receivedChunks, 0)
        XCTAssertEqual(a.result().expectedChunks, 10)
    }

    func testNothingReceivedYetIsSaidPlainly() {
        let a = FirmwareRecordingAssembler()
        let result = a.result()
        XCTAssertNil(result.record)
        XCTAssertEqual(result.expectedChunks, 0)
        XCTAssertTrue(result.summary.contains("No recording"))
    }

    // MARK: Actuation queue

    /// Two motor commands must never be in flight at once.
    func testMotorCommandsAreSeparatedByTheRequiredGap() async {
        let queue = FirmwareActuationQueue()
        actor Log {
            var times: [ContinuousClock.Instant] = []
            func record(_ t: ContinuousClock.Instant) { times.append(t) }
            var all: [ContinuousClock.Instant] { times }
        }
        let log = Log()
        let clock = ContinuousClock()

        await withTaskGroup(of: Void.self) { group in
            for command in [Firmware.Command.power(on: false),
                            Firmware.Command.water(closed: true)] {
                group.addTask {
                    await queue.enqueue(command) { _ in
                        Task { await log.record(clock.now) }
                    }
                }
            }
        }

        let times = await log.all
        XCTAssertEqual(times.count, 2)
        guard times.count == 2 else { return }
        let gap = times.map(\.self).sorted()
        let separation = gap[0].duration(to: gap[1])
        XCTAssertGreaterThan(separation, .milliseconds(700),
                             "Two motor commands went out \(separation) apart; the USB "
                             + "budget needs 800 ms.")
    }

    /// A beep is not a motor and must not wait behind a valve. Obeying the
    /// power budget for something that draws no power would be following the
    /// letter of the rule and none of its reasoning.
    func testNonMotorCommandsAreNotDelayed() async {
        let queue = FirmwareActuationQueue()
        let clock = ContinuousClock()
        let start = clock.now
        await queue.enqueue(.status) { _ in }
        await queue.enqueue(.beep) { _ in }
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(100))
    }
}
