import Foundation
import SeismicCore

/// Chunked transfer of a recording from the node's buffer to the phone.
///
/// The acceptance criterion this exists to satisfy is blunt: *losing connection
/// mid-event loses no data*. That means every part of this has to survive being
/// interrupted — a partial transfer is preserved and resumable, gaps are
/// detected rather than papered over, every chunk is CRC-checked on arrival, and
/// the whole recording is checked again at the end against a manifest the node
/// computed before it started sending.

/// Sent first, describing what is about to arrive.
public struct RecordingManifest: Sendable, Equatable, Codable {
    public var eventID: UUID
    public var totalChunks: Int
    public var samplesPerChunk: Int
    public var totalSamples: Int
    public var sampleRate: Double
    public var startTime: Date
    /// CRC-32 of the fully reassembled, decoded sample stream.
    public var checksum: UInt32
    public var isDeltaEncoded: Bool

    public init(eventID: UUID, totalChunks: Int, samplesPerChunk: Int, totalSamples: Int,
                sampleRate: Double, startTime: Date, checksum: UInt32,
                isDeltaEncoded: Bool = true) {
        self.eventID = eventID
        self.totalChunks = Swift.max(totalChunks, 0)
        self.samplesPerChunk = Swift.max(samplesPerChunk, 1)
        self.totalSamples = Swift.max(totalSamples, 0)
        self.sampleRate = Swift.max(sampleRate, 1)
        self.startTime = startTime
        self.checksum = checksum
        self.isDeltaEncoded = isDeltaEncoded
    }

    public func encodedPayload() -> [UInt8] {
        var writer = ByteWriter()
        writer.writeUUID(eventID)
        writer.writeUInt16(UInt16(Swift.min(totalChunks, 65535)))
        writer.writeUInt16(UInt16(Swift.min(samplesPerChunk, 65535)))
        writer.writeUInt32(UInt32(Swift.min(totalSamples, Int(UInt32.max))))
        writer.writeUInt16(UInt16(Swift.min(sampleRate, 65535)))
        writer.writeUInt32(UInt32(Swift.max(startTime.timeIntervalSince1970, 0)))
        writer.writeUInt32(checksum)
        writer.writeBool(isDeltaEncoded)
        return writer.bytes
    }

    public static func decode(payload: [UInt8]) -> RecordingManifest? {
        var reader = ByteReader(payload)
        guard let id = reader.readUUID(),
              let chunks = reader.readUInt16(),
              let perChunk = reader.readUInt16(),
              let samples = reader.readUInt32(),
              let rate = reader.readUInt16(),
              let epoch = reader.readUInt32(),
              let checksum = reader.readUInt32(),
              let delta = reader.readBool() else { return nil }
        return RecordingManifest(eventID: id, totalChunks: Int(chunks),
                                 samplesPerChunk: Int(perChunk), totalSamples: Int(samples),
                                 sampleRate: Double(rate),
                                 startTime: Date(timeIntervalSince1970: TimeInterval(epoch)),
                                 checksum: checksum, isDeltaEncoded: delta)
    }
}

/// One chunk of the recording.
public struct RecordingChunk: Sendable, Equatable {
    public var eventID: UUID
    public var index: Int
    public var payload: [UInt8]
    public var crc: UInt16

    public init(eventID: UUID, index: Int, payload: [UInt8]) {
        self.eventID = eventID
        self.index = index
        self.payload = payload
        self.crc = CRC16.compute(payload)
    }

    public init(eventID: UUID, index: Int, payload: [UInt8], crc: UInt16) {
        self.eventID = eventID; self.index = index; self.payload = payload; self.crc = crc
    }

    public var isValid: Bool { CRC16.compute(payload) == crc }

    public func encodedPayload() -> [UInt8] {
        var writer = ByteWriter()
        // Only the first four bytes of the event ID travel with each chunk: the
        // full UUID is in the manifest, and 32 bits is ample to notice that a
        // chunk belongs to a different recording.
        writer.writeBytes(Array(withUnsafeBytes(of: eventID.uuid) { Array($0.prefix(4)) }))
        writer.writeUInt16(UInt16(Swift.min(index, 65535)))
        writer.writeUInt16(crc)
        writer.writeUInt8(UInt8(Swift.min(payload.count, 255)))
        writer.writeBytes(Array(payload.prefix(255)))
        return writer.bytes
    }

    public static func decode(payload: [UInt8], eventID: UUID) -> RecordingChunk? {
        var reader = ByteReader(payload)
        guard let tag = reader.readBytes(4),
              let index = reader.readUInt16(),
              let crc = reader.readUInt16(),
              let length = reader.readUInt8(),
              let body = reader.readBytes(Int(length)) else { return nil }

        let expectedTag = withUnsafeBytes(of: eventID.uuid) { Array($0.prefix(4)) }
        guard tag == expectedTag else { return nil }

        return RecordingChunk(eventID: eventID, index: Int(index), payload: body, crc: crc)
    }
}

/// Reassembles a recording from chunks that may arrive out of order, be
/// duplicated, be corrupted, or never arrive at all.
public final class ChunkReassembler: @unchecked Sendable {

    public enum State: Equatable, Sendable {
        case awaitingManifest
        case receiving(received: Int, total: Int)
        case complete
        case failedChecksum
        case abandoned(reason: String)

        public var label: String {
            switch self {
            case .awaitingManifest: "Waiting for the node to describe the recording"
            case .receiving(let received, let total):
                "Receiving: \(received) of \(total) chunks"
            case .complete: "Complete and verified"
            case .failedChecksum: "Transferred, but the checksum does not match"
            case .abandoned(let reason): reason
            }
        }
    }

    public private(set) var manifest: RecordingManifest?
    public private(set) var state: State = .awaitingManifest
    private var chunks: [Int: [UInt8]] = [:]
    private var rejected: [Int: Int] = [:]     // index → failed attempts
    private let lock = NSLock()

    public private(set) var duplicatesIgnored = 0
    public private(set) var corruptChunksRejected = 0
    public private(set) var bytesReceived = 0

    public init() {}

    public func begin(with manifest: RecordingManifest) {
        lock.lock(); defer { lock.unlock() }
        // Restarting the same recording keeps whatever already arrived, which is
        // what makes a dropped connection cost seconds rather than the whole
        // transfer.
        if self.manifest?.eventID != manifest.eventID {
            chunks.removeAll()
            rejected.removeAll()
            duplicatesIgnored = 0
            corruptChunksRejected = 0
            bytesReceived = 0
        }
        self.manifest = manifest
        state = manifest.totalChunks == 0
            ? .complete
            : .receiving(received: chunks.count, total: manifest.totalChunks)
    }

    @discardableResult
    public func accept(_ chunk: RecordingChunk) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let manifest else { return false }
        guard chunk.eventID == manifest.eventID else { return false }
        guard chunk.index >= 0, chunk.index < manifest.totalChunks else { return false }

        guard chunk.isValid else {
            corruptChunksRejected += 1
            rejected[chunk.index, default: 0] += 1
            return false
        }

        if chunks[chunk.index] != nil {
            duplicatesIgnored += 1
            return true          // already have it; harmless
        }

        chunks[chunk.index] = chunk.payload
        bytesReceived += chunk.payload.count
        rejected[chunk.index] = nil
        state = .receiving(received: chunks.count, total: manifest.totalChunks)
        return true
    }

    /// Which chunks are still missing. This is what the app re-requests, and it
    /// is why a gap in the middle of a transfer is recoverable rather than fatal.
    public var missingChunks: [Int] {
        lock.lock(); defer { lock.unlock() }
        guard let manifest else { return [] }
        return (0..<manifest.totalChunks).filter { chunks[$0] == nil }
    }

    /// Compresses the missing list into contiguous ranges, so a request for 400
    /// missing chunks is a handful of ranges rather than 400 messages.
    public var missingRanges: [ClosedRange<Int>] {
        let missing = missingChunks.sorted()
        guard !missing.isEmpty else { return [] }
        var out: [ClosedRange<Int>] = []
        var start = missing[0], previous = missing[0]
        for index in missing.dropFirst() {
            if index == previous + 1 { previous = index }
            else { out.append(start...previous); start = index; previous = index }
        }
        out.append(start...previous)
        return out
    }

    public var progress: Double {
        lock.lock(); defer { lock.unlock() }
        guard let manifest, manifest.totalChunks > 0 else { return 0 }
        return Double(chunks.count) / Double(manifest.totalChunks)
    }

    public var isComplete: Bool { missingChunks.isEmpty && manifest != nil }

    /// A chunk that has failed repeatedly is probably not going to arrive
    /// intact. Surfaced so the UI can say which part of the record is damaged
    /// rather than pretending the whole thing failed.
    public var persistentlyFailingChunks: [Int] {
        lock.lock(); defer { lock.unlock() }
        return rejected.filter { $0.value >= 3 }.keys.sorted()
    }

    /// Assembles what has arrived.
    ///
    /// Returns a result even when chunks are missing: a recording with a gap is
    /// far more useful than no recording, provided the gap is honestly marked.
    public func finish(scale: Double = PayloadScale.acceleration) -> Result {
        lock.lock()
        let localManifest = manifest
        let localChunks = chunks
        lock.unlock()

        guard let manifest = localManifest else {
            return Result(record: nil, isComplete: false, missingChunks: [],
                          checksumMatches: false,
                          summary: "No manifest was received, so there is nothing to assemble.")
        }

        let missing = (0..<manifest.totalChunks).filter { localChunks[$0] == nil }

        var samples: [Double] = []
        samples.reserveCapacity(manifest.totalSamples)
        for index in 0..<manifest.totalChunks {
            guard let payload = localChunks[index] else {
                // A gap is filled with zeros so sample indices stay aligned with
                // wall-clock time. Shifting everything after a gap would corrupt
                // every arrival time in the record.
                samples.append(contentsOf: [Double](repeating: 0,
                                                    count: manifest.samplesPerChunk * 3))
                continue
            }
            let decoded = manifest.isDeltaEncoded
                ? DeltaEncoding.decodeSamples(Data(payload),
                                              count: manifest.samplesPerChunk * 3, scale: scale)
                : ByteReader.readFixed16Array(payload, scale: scale)
            samples.append(contentsOf: decoded)
        }

        // De-interleave x, y, z.
        let triples = samples.count / 3
        var x = [Double](), y = [Double](), z = [Double]()
        x.reserveCapacity(triples); y.reserveCapacity(triples); z.reserveCapacity(triples)
        for i in 0..<triples {
            x.append(samples[i * 3])
            y.append(samples[i * 3 + 1])
            z.append(samples[i * 3 + 2])
        }

        let record = TriaxialRecord(
            x: Waveform(samples: x, sampleRate: manifest.sampleRate, startTime: manifest.startTime),
            y: Waveform(samples: y, sampleRate: manifest.sampleRate, startTime: manifest.startTime),
            z: Waveform(samples: z, sampleRate: manifest.sampleRate, startTime: manifest.startTime))

        // The end-to-end check: does what arrived match what the node computed
        // before it started sending?
        let quantised = samples.map { Int32(($0 * scale).rounded()) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(quantised.count * 4)
        for value in quantised {
            let unsigned = UInt32(bitPattern: value)
            for shift in stride(from: 0, to: 32, by: 8) {
                bytes.append(UInt8((unsigned >> UInt32(shift)) & 0xFF))
            }
        }
        let checksumMatches = missing.isEmpty && CRC32.compute(bytes) == manifest.checksum

        lock.lock()
        if missing.isEmpty {
            state = checksumMatches ? .complete : .failedChecksum
        }
        lock.unlock()

        let summary: String
        if missing.isEmpty && checksumMatches {
            summary = "Recording transferred intact: \(triples) samples, verified against the "
                + "node's checksum."
        } else if missing.isEmpty {
            summary = "All chunks arrived but the checksum does not match. The recording is "
                + "kept and marked unverified rather than discarded."
        } else {
            let percent = Int((1 - Double(missing.count) / Double(Swift.max(manifest.totalChunks, 1))) * 100)
            summary = "\(percent)% of the recording transferred. \(missing.count) chunk"
                + "\(missing.count == 1 ? " is" : "s are") still missing and will be requested "
                + "again when the node is next in range. What arrived is kept."
        }

        return Result(record: record, isComplete: missing.isEmpty,
                      missingChunks: missing, checksumMatches: checksumMatches,
                      summary: summary)
    }

    public struct Result: Sendable {
        public var record: TriaxialRecord?
        public var isComplete: Bool
        public var missingChunks: [Int]
        public var checksumMatches: Bool
        public var summary: String
    }

    public func abandon(reason: String) {
        lock.lock(); defer { lock.unlock() }
        state = .abandoned(reason: reason)
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        manifest = nil
        chunks.removeAll()
        rejected.removeAll()
        state = .awaitingManifest
        duplicatesIgnored = 0
        corruptChunksRejected = 0
        bytesReceived = 0
    }
}

extension ByteReader {
    /// Reads a raw fixed-point array — the non-delta-encoded fallback, used when
    /// the node is too busy to compress.
    static func readFixed16Array(_ bytes: [UInt8], scale: Double) -> [Double] {
        var reader = ByteReader(bytes)
        var out: [Double] = []
        while let value = reader.readFixed16(scale: scale) { out.append(value) }
        return out
    }
}

/// The sending side, used by the simulated node and mirrored by the Arduino
/// sketch.
public enum ChunkSplitter {

    public static func split(_ record: TriaxialRecord, eventID: UUID,
                             samplesPerChunk: Int = 20,
                             scale: Double = PayloadScale.acceleration)
        -> (manifest: RecordingManifest, chunks: [RecordingChunk])
    {
        let count = record.count
        let perChunk = Swift.max(samplesPerChunk, 1)
        let totalChunks = count == 0 ? 0 : (count + perChunk - 1) / perChunk

        // Interleave so a chunk carries whole samples: losing one chunk costs a
        // brief gap in all three axes rather than one axis for the whole record.
        var interleaved: [Double] = []
        interleaved.reserveCapacity(count * 3)
        for i in 0..<count {
            interleaved.append(record.x.samples[i])
            interleaved.append(record.y.samples[i])
            interleaved.append(record.z.samples[i])
        }

        var chunks: [RecordingChunk] = []
        for index in 0..<totalChunks {
            let start = index * perChunk * 3
            let end = Swift.min(start + perChunk * 3, interleaved.count)
            guard start < end else { break }
            var slice = Array(interleaved[start..<end])
            // Pad the final chunk so every chunk decodes to the same length.
            if slice.count < perChunk * 3 {
                slice.append(contentsOf: [Double](repeating: 0, count: perChunk * 3 - slice.count))
            }
            let encoded = [UInt8](DeltaEncoding.encodeSamples(slice, scale: scale))
            chunks.append(RecordingChunk(eventID: eventID, index: index, payload: encoded))
        }

        // Checksum over the padded, quantised stream — exactly what the
        // reassembler will reconstruct.
        var padded = interleaved
        let expected = totalChunks * perChunk * 3
        if padded.count < expected {
            padded.append(contentsOf: [Double](repeating: 0, count: expected - padded.count))
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(padded.count * 4)
        for value in padded {
            let unsigned = UInt32(bitPattern: Int32((value * scale).rounded()))
            for shift in stride(from: 0, to: 32, by: 8) {
                bytes.append(UInt8((unsigned >> UInt32(shift)) & 0xFF))
            }
        }

        let manifest = RecordingManifest(
            eventID: eventID, totalChunks: totalChunks, samplesPerChunk: perChunk,
            totalSamples: count, sampleRate: record.sampleRate,
            startTime: record.startTime, checksum: CRC32.compute(bytes))

        return (manifest, chunks)
    }
}
