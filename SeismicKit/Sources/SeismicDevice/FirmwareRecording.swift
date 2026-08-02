import Foundation
import SeismicCore

/// Reassembles a recording arriving as numbered chunks over a lossy link.
///
/// The firmware sends five hundred samples as twenty-five chunks of twenty,
/// each with the arithmetic sum of its own samples, and pauses twelve
/// milliseconds between them to let the BLE buffer drain. Chunks still go
/// missing: a notification dropped while the phone was busy, a disconnection
/// halfway through, a chunk that arrived with a byte mangled.
///
/// The rule this is built around is that **a partial recording is never
/// discarded**. Nine seconds of an earthquake is worth having and is worth
/// saying is nine seconds; throwing it away because the tenth is missing turns
/// a small loss into a total one. So gaps are recorded, what arrived is kept,
/// and a resend merges into the same buffer rather than replacing it.
///
/// `missingChunks` names exactly which are absent, and the firmware's `REC:n`
/// re-sends one by index — so recovery costs twelve milliseconds per lost
/// chunk rather than three seconds for the whole recording. That command was
/// added to `arduino.ino` for this; before it existed the only recourse was
/// `SEND`, which re-transmits all twenty-five and stands a fair chance of
/// dropping a different one on the way. `SEND` still works and still merges,
/// which is what recovers a transfer interrupted by the link going down
/// entirely.
public final class FirmwareRecordingAssembler: @unchecked Sendable {

    public struct Result: Sendable, Equatable {
        public var record: Waveform?
        public var receivedChunks: Int
        public var expectedChunks: Int
        public var missingChunks: [Int]
        /// Chunks whose samples did not add up to the sum the node sent.
        public var corruptChunks: [Int]
        public var isComplete: Bool { missingChunks.isEmpty && expectedChunks > 0 }

        /// One line for the transfer panel, in words rather than counters.
        public var summary: String {
            guard expectedChunks > 0 else { return "No recording has arrived." }
            if isComplete {
                return "Complete: \(receivedChunks) of \(expectedChunks) chunks, "
                     + "every checksum verified."
            }
            var text = "\(receivedChunks) of \(expectedChunks) chunks. "
            if !missingChunks.isEmpty {
                text += "\(missingChunks.count) missing. "
            }
            if !corruptChunks.isEmpty {
                text += "\(corruptChunks.count) failed their checksum and were rejected. "
            }
            return text + "Kept as a partial recording and marked incomplete."
        }
    }

    public private(set) var expectedSamples = 0
    public private(set) var sampleRate: Double = 50
    public private(set) var isReceiving = false

    /// Received samples by chunk index. A dictionary rather than a flat buffer
    /// because chunks arrive out of order after a resend, and because "absent"
    /// and "zero" have to stay distinguishable — an earthquake record is full
    /// of genuine zeroes.
    private var chunks: [Int: [Int]] = [:]
    private var corrupt: Set<Int> = []
    private let samplesPerChunk = 20
    private let lock = NSLock()

    public init() {}

    // MARK: Receiving

    /// A `recbegin`. Starts a transfer, or resumes one.
    ///
    /// Resuming rather than restarting is the whole point of the merge
    /// behaviour: when the link drops mid-transfer and the app asks again, the
    /// chunks that did arrive the first time are still here.
    public func begin(sampleCount: Int, sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        // A different length means a different recording, so nothing carries
        // over. Same length is treated as the same recording being resent.
        if expectedSamples != sampleCount { chunks.removeAll(); corrupt.removeAll() }
        expectedSamples = max(sampleCount, 0)
        self.sampleRate = max(sampleRate, 1)
        isReceiving = true
    }

    /// A `rec` chunk. Returns false when it was rejected.
    @discardableResult
    public func accept(index: Int, samples: [Int], checksum: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard index >= 0, !samples.isEmpty else { return false }

        // The firmware's "sum" is the arithmetic sum of the chunk's samples,
        // not a CRC. It catches a mangled digit and a truncated array, which is
        // what actually goes wrong on this link, and it costs the board
        // nothing — which matters when the board is an eight-bit micro with a
        // hundred and ninety bytes of transmit buffer.
        guard samples.reduce(0, +) == checksum else {
            corrupt.insert(index)
            return false
        }
        corrupt.remove(index)
        chunks[index] = samples
        return true
    }

    public func end() {
        lock.lock(); isReceiving = false; lock.unlock()
    }

    public func reset() {
        lock.lock()
        chunks.removeAll(); corrupt.removeAll()
        expectedSamples = 0; isReceiving = false
        lock.unlock()
    }

    // MARK: Result

    public var expectedChunks: Int {
        lock.lock(); defer { lock.unlock() }
        guard expectedSamples > 0 else { return 0 }
        return (expectedSamples + samplesPerChunk - 1) / samplesPerChunk
    }

    public var missingChunks: [Int] {
        lock.lock(); defer { lock.unlock() }
        return missingChunksLocked()
    }

    private func missingChunksLocked() -> [Int] {
        guard expectedSamples > 0 else { return [] }
        let total = (expectedSamples + samplesPerChunk - 1) / samplesPerChunk
        return (0..<total).filter { chunks[$0] == nil }
    }

    /// Fraction of the recording in hand, for a progress bar.
    public var progress: Double {
        lock.lock(); defer { lock.unlock() }
        guard expectedSamples > 0 else { return 0 }
        let total = (expectedSamples + samplesPerChunk - 1) / samplesPerChunk
        return Double(chunks.count) / Double(total)
    }

    /// What has been assembled so far.
    ///
    /// Missing chunks are filled with zero and reported, rather than the
    /// recording being refused. A gap in a trace is visible, explainable and
    /// analysable; a missing recording is none of those.
    public func result() -> Result {
        lock.lock(); defer { lock.unlock() }
        guard expectedSamples > 0 else {
            return Result(record: nil, receivedChunks: 0, expectedChunks: 0,
                          missingChunks: [], corruptChunks: corrupt.sorted())
        }
        let total = (expectedSamples + samplesPerChunk - 1) / samplesPerChunk
        var samples = [Double](repeating: 0, count: expectedSamples)
        for (index, chunk) in chunks {
            for (offset, value) in chunk.enumerated() {
                let position = index * samplesPerChunk + offset
                guard position < expectedSamples else { continue }
                // Raw counts to metres per second squared. The firmware records
                // the deviation of the accelerometer magnitude from the
                // calibrated gravity vector, in ±2 g full-scale counts —
                // 16384 per g.
                samples[position] = Double(value) / 16384.0 * gravity
            }
        }

        return Result(
            record: Waveform(samples: samples, sampleRate: sampleRate, unit: .acceleration),
            receivedChunks: chunks.count,
            expectedChunks: total,
            missingChunks: missingChunksLocked(),
            corruptChunks: corrupt.sorted())
    }
}

// MARK: - Actuation queue

/// Serialises motor commands against the node's power budget.
///
/// The board runs on USB. A hobby stepper turning a valve draws around two
/// hundred and sixty milliamps and the relay path another forty, against a
/// budget of five hundred for the whole node including the microcontroller —
/// so two moving at once browns out the board, and browning out mid-event is
/// the one failure mode this whole system exists to avoid.
///
/// The firmware already staggers its own sequence by eight hundred milliseconds.
/// This is the app's side of the same contract: a user tapping "close water"
/// while a power cut is still settling must not be able to defeat it. The queue
/// is not a limitation to apologise for — it is why each action is separately
/// visible, and it is what makes the sequence legible on screen.
public actor FirmwareActuationQueue {

    /// The gap the firmware itself uses.
    public static let gap: Duration = .milliseconds(800)

    private var isBusy = false
    private var pending: [Firmware.Command] = []

    public init() {}

    /// Sends now if nothing is moving, otherwise queues behind what is.
    ///
    /// - Parameter send: the transport's write, called on this actor so two
    ///   callers cannot interleave.
    public func enqueue(_ command: Firmware.Command,
                        send: @escaping @Sendable (Firmware.Command) -> Void) async {
        guard command.movesMotor else {
            // Nothing mechanical: straight out, no queue, no delay. Making a
            // beep wait behind a valve would be obeying the letter of the power
            // budget and none of its reasoning.
            send(command)
            return
        }

        pending.append(command)
        guard !isBusy else { return }
        isBusy = true

        while !pending.isEmpty {
            let next = pending.removeFirst()
            send(next)
            // Held even for the last one, so a command arriving immediately
            // after this drains still finds the gap in place.
            try? await Task.sleep(for: Self.gap)
        }
        isBusy = false
    }

    public var queueDepth: Int { pending.count }
    public var isActuating: Bool { isBusy }
}
