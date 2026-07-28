import Foundation
import SeismicCore
import SeismicSignal

/// The stateful layer above the transport.
///
/// Holds the rolling waveform buffer the seismograph draws from, drives chunk
/// reassembly, tracks actuator state, and turns the stream of low-level events
/// into the handful of things the UI actually cares about. Written against the
/// `NodeTransport` protocol, so it is identical for real and simulated hardware.
public final class NodeSession: @unchecked Sendable {

    public struct Snapshot: Sendable {
        public var connection: ConnectionState
        public var telemetry: NodeTelemetry
        public var recent: TriaxialRecord
        public var ratio: Waveform
        public var actuators: [ActuatorKind: ActuatorReport]
        public var votes: [SensorVote]
        public var faults: [NodeFault]
        public var transferProgress: Double?
        public var transferSummary: String?
        public var isSimulated: Bool
        public var nodeName: String
    }

    /// How many seconds of high-rate data to keep in memory for the live trace.
    public let bufferSeconds: Double

    private let lock = NSLock()
    private var transport: NodeTransport?

    private var x: [Double] = []
    private var y: [Double] = []
    private var z: [Double] = []
    private var ratioSamples: [Double] = []
    private var sampleRate: Double = 100
    private var lastSequence: UInt16?
    public private(set) var droppedBatches = 0

    private var telemetry = NodeTelemetry(state: .offline)
    private var connection: ConnectionState = .disconnected
    private var actuators: [ActuatorKind: ActuatorReport] = [:]
    private var votes: [SensorVote] = []
    private var faults: [NodeFault] = []
    private var reassembler = ChunkReassembler()
    private var transferSummary: String?

    /// Handlers the app installs. Kept as closures rather than a delegate so a
    /// SwiftUI view model can own them without an extra object.
    public var onEvent: (@Sendable (NodeEvent) -> Void)?
    public var onRecordingComplete: (@Sendable (UUID, ChunkReassembler.Result) -> Void)?
    public var onTriggered: (@Sendable (Double, Date) -> Void)?

    public init(bufferSeconds: Double = 60) {
        self.bufferSeconds = Swift.max(bufferSeconds, 5)
    }

    // MARK: Attaching a transport

    public func attach(_ transport: NodeTransport) {
        lock.lock()
        self.transport = transport
        lock.unlock()

        transport.eventHandler = { [weak self] event in
            self?.handle(event)
        }
    }

    public var attachedTransport: NodeTransport? {
        lock.lock(); defer { lock.unlock() }
        return transport
    }

    public func startScanning() { attachedTransport?.startScanning() }
    public func stopScanning() { attachedTransport?.stopScanning() }
    public func connect(to nodeID: String) { attachedTransport?.connect(to: nodeID) }
    public func disconnect() { attachedTransport?.disconnect() }
    public func send(_ command: NodeCommand) { attachedTransport?.send(command) }

    // MARK: Event handling

    private func handle(_ event: NodeEvent) {
        switch event {
        case .connectionChanged(let state):
            lock.lock(); connection = state; lock.unlock()

        case .telemetry(let value):
            lock.lock()
            telemetry = value
            faults = value.faults
            lock.unlock()

        case .highRate(let batch):
            append(batch)

        case .triggered(let ratio, _, let at):
            lock.lock(); votes.removeAll(); lock.unlock()
            onTriggered?(ratio, at)

        case .sensorVote(let vote):
            lock.lock()
            votes.removeAll { $0.channel == vote.channel }
            votes.append(vote)
            lock.unlock()

        case .actuatorReport(let report):
            lock.lock(); actuators[report.kind] = report; lock.unlock()

        case .recordingManifest(let manifest):
            lock.lock()
            reassembler.begin(with: manifest)
            transferSummary = reassembler.state.label
            lock.unlock()

        case .recordingChunk(let chunk):
            lock.lock()
            reassembler.accept(chunk)
            let complete = reassembler.isComplete
            let eventID = reassembler.manifest?.eventID
            transferSummary = reassembler.state.label
            lock.unlock()

            if complete, let eventID {
                let result = reassembler.finish()
                lock.lock(); transferSummary = result.summary; lock.unlock()
                onRecordingComplete?(eventID, result)
                lock.lock(); reassembler.reset(); lock.unlock()
            }

        case .fault(let fault):
            lock.lock()
            if !faults.contains(fault) { faults.append(fault) }
            lock.unlock()

        case .discovered, .selfTestResult, .periodMeasured, .rfidTap, .log:
            break
        }

        onEvent?(event)
    }

    private func append(_ batch: HighRateBatch) {
        lock.lock(); defer { lock.unlock() }

        // Sequence gaps mean batches were lost in the air. Recorded rather than
        // hidden, because a gap in the live trace has to be explainable.
        if let last = lastSequence {
            let expected = last &+ 1
            if batch.sequence != expected { droppedBatches += 1 }
        }
        lastSequence = batch.sequence

        sampleRate = batch.sampleRate
        x.append(contentsOf: batch.x)
        y.append(contentsOf: batch.y)
        z.append(contentsOf: batch.z)

        // Ratio is recomputed here rather than trusted from the node, so the
        // trace under the seismograph always corresponds to the samples above it.
        let capacity = Int(bufferSeconds * sampleRate)
        trim(&x, to: capacity); trim(&y, to: capacity); trim(&z, to: capacity)

        let magnitudeSquared = zip(zip(batch.x, batch.y), batch.z).map { pair, zValue in
            pair.0 * pair.0 + pair.1 * pair.1 + zValue * zValue
        }
        ratioSamples.append(contentsOf: magnitudeSquared)
        trim(&ratioSamples, to: capacity)
    }

    private func trim(_ array: inout [Double], to capacity: Int) {
        guard capacity > 0, array.count > capacity else { return }
        array.removeFirst(array.count - capacity)
    }

    // MARK: Snapshot

    public func snapshot() -> Snapshot {
        lock.lock()
        let localX = x, localY = y, localZ = z
        let rate = sampleRate
        let localTelemetry = telemetry
        let localConnection = connection
        let localActuators = actuators
        let localVotes = votes
        let localFaults = faults
        let progress = reassembler.manifest == nil ? nil : reassembler.progress
        let summary = transferSummary
        let simulated = transport?.isSimulated ?? false
        let name = transport?.displayName ?? "No node"
        let ratioSource = ratioSamples
        lock.unlock()

        let start = Date().addingTimeInterval(-Double(localX.count) / rate)
        let record = TriaxialRecord(
            x: Waveform(samples: localX, sampleRate: rate, startTime: start),
            y: Waveform(samples: localY, sampleRate: rate, startTime: start),
            z: Waveform(samples: localZ, sampleRate: rate, startTime: start))

        // The STA/LTA trace shown beneath the seismograph, computed over the
        // whole visible buffer so it matches what the user can see.
        let ratio: Waveform
        if ratioSource.count > 16 {
            let source = Waveform(samples: ratioSource.map { $0.squareRoot() },
                                  sampleRate: rate, startTime: start)
            ratio = STALTA.recursive(source).ratio
        } else {
            ratio = Waveform(samples: [Double](repeating: 1, count: ratioSource.count),
                             sampleRate: rate, startTime: start, unit: .dimensionless)
        }

        return Snapshot(connection: localConnection, telemetry: localTelemetry,
                        recent: record, ratio: ratio, actuators: localActuators,
                        votes: localVotes, faults: localFaults,
                        transferProgress: progress, transferSummary: summary,
                        isSimulated: simulated, nodeName: name)
    }

    /// Everything currently buffered, as a record — used when the user freezes
    /// the trace to inspect it, and when a period measurement is taken from
    /// ambient data.
    public func bufferedRecord() -> TriaxialRecord { snapshot().recent }

    public func clearBuffer() {
        lock.lock()
        x.removeAll(); y.removeAll(); z.removeAll(); ratioSamples.removeAll()
        lastSequence = nil
        lock.unlock()
    }

    /// Measures the building's period from whatever ambient data is buffered.
    ///
    /// This is the operation behind "Measure now" — it needs no earthquake, no
    /// shaker and no cooperation from the building's occupants.
    public func measurePeriodFromAmbient(band: ClosedRange<Double> = 0.1...10)
        -> PeriodEstimation.CrossCheckedPeriod
    {
        let record = bufferedRecord()
        guard record.count > 64 else {
            return PeriodEstimation.CrossCheckedPeriod(
                spectral: nil, autocorrelation: nil, zeroCrossing: nil,
                consensus: nil, agreement: 0,
                explanation: "Not enough data buffered yet. Leave the node connected for a "
                    + "minute and try again.")
        }
        return PeriodEstimation.crossChecked(record.dominantHorizontal, band: band)
    }
}
