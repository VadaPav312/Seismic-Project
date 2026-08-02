import Foundation
import Combine
import SeismicCore
import SeismicDevice
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

/// The connection to the Arduino node, and everything it has told us.
///
/// One object holds the radio, the line framing, the command queue and the
/// device's state, because they are one thing: the state *is* the accumulated
/// consequence of the lines that arrived, and separating them would mean
/// keeping two copies of the truth in step.
///
/// A simulated node is selectable at any moment and goes through exactly the
/// same path — the same parser, the same assembler, the same queue. Nothing
/// below this object knows which it is talking to, which is the only way the
/// app can be honestly claimed to work without hardware.
@MainActor
final class SeismicNodeLink: NSObject, ObservableObject {

    // MARK: What it is talking to

    enum Source: String, CaseIterable, Identifiable, Sendable {
        case bluetooth, simulated
        var id: String { rawValue }

        var label: String {
            switch self {
            case .bluetooth: "Seismic node"
            case .simulated: "Simulated node"
            }
        }
    }

    @Published private(set) var source: Source = .simulated
    @Published private(set) var connection: ConnectionState = .disconnected

    // MARK: What the node has said

    @Published private(set) var telemetry: Firmware.Telemetry?
    @Published private(set) var phase: Firmware.Phase?
    /// Non-nil only while the countdown is running.
    @Published private(set) var countdown: Int?
    @Published private(set) var actuators: [Firmware.Actuator: Firmware.ActuatorState] = [:]
    /// The light readings behind each confirmation, kept as the evidence.
    @Published private(set) var verifications: [Firmware.Actuator: Verification] = [:]
    @Published private(set) var lastTrigger: Trigger?
    @Published private(set) var assessment: Firmware.Assessment?
    @Published private(set) var calibration: Calibration?
    @Published private(set) var transfer: FirmwareRecordingAssembler.Result?
    @Published private(set) var isTransferring = false

    /// A rolling window of the live acceleration samples, for the trace.
    @Published private(set) var trace: [Double] = []
    private let traceCapacity = 300

    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var discovered: [DiscoveredPeripheral] = []

    /// Per-command state, so no button is ever left in an unknown state.
    @Published private(set) var commandState: [String: CommandState] = [:]

    /// Unexpected reboots. A brownout is not a seismic event and must never be
    /// mistaken for one.
    @Published private(set) var brownouts: [Brownout] = []
    @Published private(set) var hasAccelerometer = true

    // MARK: Supporting types

    struct Verification: Equatable {
        var before: Int
        var after: Int
        var confirmed: Bool
        /// The change in the light reading, which *is* the evidence.
        var delta: Int { abs(after - before) }
    }

    struct Trigger: Equatable {
        var ratio: Double
        var votes: Firmware.Votes
        var isDrill: Bool
        var at: Date
    }

    struct Calibration: Equatable {
        var gravity: Int
        var soundBaseline: Int
        var period: Double
        var at: Date
    }

    struct Brownout: Identifiable, Equatable {
        let id = UUID()
        var at: Date
        /// Whether an event was in progress when the board restarted, which is
        /// what makes any recording around it suspect.
        var duringEvent: Bool
    }

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var at: Date
        var kind: Kind
        enum Kind { case incoming, outgoing, note, fault }
    }

    struct DiscoveredPeripheral: Identifiable, Equatable {
        var id: UUID
        var name: String
        var rssi: Int
        var lastSeen: Date

        /// Four bars from RSSI. Shown because "connect to the strongest one" is
        /// the only guidance that helps in a room with three boards on the
        /// bench.
        var signalBars: Int {
            switch rssi {
            case (-55)...: 4
            case (-67)..<(-55): 3
            case (-80)..<(-67): 2
            default: 1
            }
        }
    }

    /// Where a command has got to.
    ///
    /// Modelled explicitly because the alternative — a button that looks the
    /// same before and after a tap — is how a presenter ends up pressing
    /// "Test earthquake" three times.
    enum CommandState: Equatable {
        case idle
        case sending
        case acknowledged(at: Date)
        case failed(reason: String)

        var isInFlight: Bool { self == .sending }
    }

    // MARK: Internals

    private let assembler = FirmwareRecordingAssembler()
    private let queue = FirmwareActuationQueue()
    private var simulator: FirmwareSimulator?
    private var tickTimer: AnyCancellable?

    /// Commands waiting for an acknowledgement, with when they were sent.
    private var awaitingAck: [String: Date] = [:]
    private var ackTimeoutTask: Task<Void, Never>?

    /// Rounds of per-chunk re-requests since the last complete transfer.
    private var recoveryRounds = 0

    #if canImport(CoreBluetooth)
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    /// Incoming bytes that have not yet formed a whole line.
    private var incomingBuffer = Data()

    static let serviceUUID = CBUUID(string: "FFE0")
    static let characteristicUUID = CBUUID(string: "FFE1")
    #endif

    /// The peripheral to reconnect to without being asked.
    private var rememberedIdentifier: UUID? {
        get {
            UserDefaults.standard.string(forKey: Self.rememberedKey).flatMap(UUID.init(uuidString:))
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: Self.rememberedKey)
        }
    }
    private static let rememberedKey = "seismic.node.peripheral"

    /// Reconnection attempts since the last successful connection.
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?

    // MARK: Lifecycle

    override init() {
        super.init()
        useSimulator()
    }

    /// Switches to the simulated node.
    ///
    /// Always available, and it is not a fallback: it goes through the same
    /// parser and the same state machine, so a screen that works here works
    /// against the board.
    func useSimulator() {
        teardownBluetooth()
        resetState()
        source = .simulated
        connection = .simulated

        let node = FirmwareSimulator()
        node.onLine = { [weak self] line in
            Task { @MainActor in self?.receive(line: line) }
        }
        simulator = node
        node.start()
        startTicking()
        note("Simulated node running. Every message the firmware can send is produced here, "
             + "through the same parser the radio uses.")
    }

    private func startTicking() {
        tickTimer?.cancel()
        tickTimer = Timer.publish(every: 1.0 / 20.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.simulator?.tick(deltaTime: 1.0 / 20.0)
            }
    }

    private func resetState() {
        telemetry = nil; phase = nil; countdown = nil
        actuators = [:]; verifications = [:]
        lastTrigger = nil; assessment = nil; calibration = nil
        transfer = nil; isTransferring = false
        trace = []; commandState = [:]
        assembler.reset()
        awaitingAck = [:]
        recoveryRounds = 0
    }

    // MARK: Receiving

    /// One complete line from the node, whichever node it is.
    private func receive(line: String) {
        guard let message = Firmware.parse(line: line) else { return }
        append(line, kind: .incoming)
        apply(message)
    }

    private func apply(_ message: Firmware.Message) {
        switch message {
        case .boot(let accelerometer):
            hasAccelerometer = accelerometer
            // A boot we did not ask for is a brownout. The board restarting
            // mid-event is the one fault that must never be read as a seismic
            // trigger — it produces a burst of everything at once and looks,
            // to a naive reader, exactly like a large earthquake.
            if telemetry != nil {
                let duringEvent = telemetry?.state.isEventInProgress ?? false
                brownouts.append(Brownout(at: Date(), duringEvent: duringEvent))
                fault(duringEvent
                      ? "The node restarted during an event. Its supply dipped — most likely "
                        + "two motors moving at once. Any recording around this moment is "
                        + "marked suspect and is not used for a verdict."
                      : "The node restarted unexpectedly. That is a brownout, not an "
                        + "earthquake.")
            }
            if !accelerometer {
                fault("The accelerometer did not answer. Check the AD0 wire — the firmware "
                      + "expects the MPU at 0x69, which needs AD0 tied to 3.3 V.")
            }

        case .telemetry(let value):
            telemetry = value
            // Votes expiring is itself worth seeing, so the state is replaced
            // wholesale rather than merged.

        case .acceleration(let deviation, let ratio):
            // Counts to m/s², the same conversion the assembler uses.
            trace.append(Double(deviation) / 16384.0 * gravity)
            if trace.count > traceCapacity { trace.removeFirst(trace.count - traceCapacity) }
            if var current = telemetry {
                current.ratio = ratio
                telemetry = current
            }

        case .triggered(let ratio, let votes, let isDrill):
            lastTrigger = Trigger(ratio: ratio, votes: votes, isDrill: isDrill, at: Date())
            assessment = nil
            Haptics.shared.play(.eventTriggered)

        case .countdown(let remaining):
            countdown = remaining
            Haptics.shared.play(.countdownTick(secondsRemaining: remaining))

        case .phase(let value):
            phase = value
            if value != .warning { countdown = nil }

        case .actuator(let device, let state):
            actuators[device] = state
            switch state {
            case .commanded: Haptics.shared.play(.actuatorFired)
            case .confirmed: Haptics.shared.play(.actuatorConfirmed)
            case .failed: Haptics.shared.play(.actuatorFailed)
            case .idle: break
            }

        case .verification(let device, let before, let after, let ok):
            verifications[device] = Verification(before: before, after: after, confirmed: ok)

        case .recordingBegan(let count, let rate):
            assembler.begin(sampleCount: count, sampleRate: rate)
            isTransferring = true
            transfer = assembler.result()

        case .recordingChunk(let index, let samples, let checksum):
            assembler.accept(index: index, samples: samples, checksum: checksum)
            transfer = assembler.result()

        case .recordingEnded:
            assembler.end()
            isTransferring = false
            let result = assembler.result()
            transfer = result
            if !result.isComplete { recoverMissingChunks(result) }

        case .assessment(let value):
            assessment = value
            Haptics.shared.play(.assessmentComplete)

        case .calibrated(let gravity, let sound, let period):
            calibration = Calibration(gravity: gravity, soundBaseline: sound,
                                      period: Double(period) / 1000, at: Date())

        case .note(let text):
            note(text)

        case .error(let text):
            fault(text)

        case .acknowledged(let command):
            awaitingAck.removeValue(forKey: command)
            commandState[command] = .acknowledged(at: Date())

        case .unrecognised(let type, _):
            note("Unrecognised message type '\(type)'. The firmware is newer than this app.")
        }
    }

    // MARK: Gap recovery

    /// Asks the node for exactly the chunks that went missing.
    ///
    /// The firmware gained `REC:n` for this. Before it existed the only
    /// recourse was `SEND`, which re-transmits all twenty-five chunks — three
    /// seconds of airtime to recover twenty samples, with a fair chance of
    /// dropping a different chunk on the way and needing to start again. Asking
    /// for the one that is missing costs twelve milliseconds.
    ///
    /// Bounded, and it says so when it stops: a link losing most of a recording
    /// is a link that will lose the retries too, and hammering it is how a
    /// transfer becomes a loop. Whatever arrived is kept either way.
    private func recoverMissingChunks(_ result: FirmwareRecordingAssembler.Result) {
        let missing = result.missingChunks
        guard !missing.isEmpty else { return }

        guard recoveryRounds < 3 else {
            note(result.summary + " Three rounds of re-requests did not fill the gaps, so "
                 + "the recording is kept as it is rather than retried indefinitely. A link "
                 + "losing this much will lose the retries too.")
            return
        }
        recoveryRounds += 1

        note("\(missing.count) chunk\(missing.count == 1 ? "" : "s") missing. Asking for "
             + "\(missing.count == 1 ? "it" : "them") individually rather than re-sending the "
             + "whole recording — what already arrived is kept.")

        Task { [weak self] in
            for index in missing {
                await MainActor.run { self?.send(.resendChunk(index)) }
                // Paced, because the firmware's own transfer loop waits twelve
                // milliseconds between chunks to let the BLE buffer drain, and
                // a burst of requests would arrive faster than it can answer.
                try? await Task.sleep(for: .milliseconds(60))
            }
            // Give the replies time to land before judging the result.
            try? await Task.sleep(for: .milliseconds(400))
            await MainActor.run {
                guard let self else { return }
                let updated = self.assembler.result()
                self.transfer = updated
                if updated.isComplete {
                    self.note("Recovered. " + updated.summary)
                    self.recoveryRounds = 0
                } else {
                    self.recoverMissingChunks(updated)
                }
            }
        }
    }

    // MARK: Sending

    /// Sends a command and tracks what happens to it.
    func send(_ command: Firmware.Command) {
        let token = command.acknowledgementToken
        commandState[token] = .sending
        append(command.wire, kind: .outgoing)

        if command.expectsAcknowledgement {
            awaitingAck[token] = Date()
            scheduleAckTimeout()
        }

        Task {
            await queue.enqueue(command) { [weak self] resolved in
                Task { @MainActor in self?.write(resolved) }
            }
            // A command that never gets an ack is confirmed by having been
            // written, because there is nothing else to wait for. Saying
            // "sending" for ever would be worse than saying "sent".
            if !command.expectsAcknowledgement {
                await MainActor.run {
                    self.commandState[token] = .acknowledged(at: Date())
                }
            }
        }
    }

    private func write(_ command: Firmware.Command) {
        switch source {
        case .simulated:
            simulator?.send(line: command.wire)
        case .bluetooth:
            #if canImport(CoreBluetooth)
            guard let peripheral, let characteristic else {
                commandState[command.acknowledgementToken] =
                    .failed(reason: "Not connected.")
                return
            }
            // withResponse where the characteristic supports it: a write the
            // radio silently dropped is indistinguishable from one the node
            // ignored, and only one of those is the app's problem to report.
            let type: CBCharacteristicWriteType =
                characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
            peripheral.writeValue(command.payload, for: characteristic, type: type)
            #endif
        }
    }

    /// Fails any command that has waited too long.
    ///
    /// Three seconds covers the firmware's slowest acknowledged path — `RESET`
    /// restores power, waits the eight-hundred-millisecond gap and then drives
    /// the stepper — with room for the radio. `DRILL` and `CAL` acknowledge
    /// immediately and then take much longer to *finish*, which is why the
    /// phase messages rather than the ack are what drive the sequence display.
    private func scheduleAckTimeout() {
        ackTimeoutTask?.cancel()
        ackTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run {
                guard let self else { return }
                let now = Date()
                for (token, sentAt) in self.awaitingAck where now.timeIntervalSince(sentAt) >= 3 {
                    self.awaitingAck.removeValue(forKey: token)
                    self.commandState[token] = .failed(
                        reason: "No acknowledgement in three seconds.")
                }
            }
        }
    }

    /// Fires one shake channel without the others.
    ///
    /// Only meaningful against the simulator, and it is the single most useful
    /// thing a demonstration can do after the drill: it makes the fusion vote
    /// visibly *refuse*. Somebody watching "1 of 3 — not declared" understands
    /// in one second why a single sensor is not enough, which is an argument
    /// that takes a paragraph to make in words.
    func nudgeSingleChannel() {
        guard source == .simulated else { return }
        simulator?.nudgeSingleChannel()
        note("Nudged the accelerometer alone. The vote should refuse to declare an event.")
    }

    var canNudge: Bool { source == .simulated }

    func state(of command: Firmware.Command) -> CommandState {
        commandState[command.acknowledgementToken] ?? .idle
    }

    // MARK: Convenience the UI uses

    var isArmed: Bool { telemetry?.state.isArmed ?? false }
    var isEventRunning: Bool { telemetry?.state.isEventInProgress ?? false }

    /// The live vote state, from telemetry or from the trigger that declared
    /// the event — whichever is more recent.
    var votes: Firmware.Votes {
        telemetry?.votes ?? Firmware.Votes(accelerometer: false, tilt: false, sound: false)
    }

    /// Whether a recording captured around a brownout should be trusted.
    var hasSuspectRecording: Bool {
        brownouts.contains { $0.duringEvent }
    }

    // MARK: Logging

    private func append(_ text: String, kind: LogEntry.Kind) {
        log.insert(LogEntry(text: text, at: Date(), kind: kind), at: 0)
        if log.count > 300 { log.removeLast(log.count - 300) }
    }

    private func note(_ text: String) { append(text, kind: .note) }
    private func fault(_ text: String) {
        append(text, kind: .fault)
        Haptics.shared.play(.warning)
    }
}

// MARK: - Bluetooth

#if canImport(CoreBluetooth)
extension SeismicNodeLink: CBCentralManagerDelegate, CBPeripheralDelegate {

    /// Starts scanning for nodes.
    func startScanning() {
        source = .bluetooth
        tickTimer?.cancel()
        simulator = nil
        discovered = []
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else if central?.state == .poweredOn {
            beginScan()
        }
        connection = .scanning
    }

    func stopScanning() {
        central?.stopScan()
    }

    private func beginScan() {
        // Filtered by the service, so a room full of unrelated peripherals does
        // not fill the list. Duplicates are allowed through because RSSI is
        // only useful if it updates.
        central?.scanForPeripherals(withServices: [Self.serviceUUID],
                                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    /// Connects to a discovered node and remembers it.
    func connect(to id: UUID) {
        guard let central else { return }
        let known = central.retrievePeripherals(withIdentifiers: [id])
        guard let target = known.first else {
            fault("That node is no longer visible. Scan again.")
            return
        }
        resetState()
        source = .bluetooth
        rememberedIdentifier = id
        peripheral = target
        target.delegate = self
        connection = .connecting(attempt: reconnectAttempt + 1)
        central.stopScan()
        central.connect(target)
    }

    func disconnect() {
        reconnectTask?.cancel()
        rememberedIdentifier = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        teardownBluetooth()
        connection = .disconnected
    }

    private func teardownBluetooth() {
        reconnectTask?.cancel()
        central?.stopScan()
        peripheral = nil
        characteristic = nil
        incomingBuffer = Data()
    }

    // MARK: Central delegate

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                // Reconnect to the remembered node without being asked. Coming
                // back into range should not need a tap.
                if let remembered = rememberedIdentifier,
                   let known = central.retrievePeripherals(withIdentifiers: [remembered]).first {
                    peripheral = known
                    known.delegate = self
                    connection = .connecting(attempt: 1)
                    central.connect(known)
                } else if source == .bluetooth {
                    beginScan()
                }
            case .poweredOff:
                connection = .disconnected
                fault("Bluetooth is switched off.")
            case .unauthorized:
                connection = .disconnected
                fault("This app is not allowed to use Bluetooth. Settings → Privacy.")
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? "Seismic node"
        let id = peripheral.identifier
        let rssi = RSSI.intValue
        Task { @MainActor in
            if let index = discovered.firstIndex(where: { $0.id == id }) {
                discovered[index].rssi = rssi
                discovered[index].lastSeen = Date()
            } else {
                discovered.append(DiscoveredPeripheral(id: id, name: name, rssi: rssi,
                                                       lastSeen: Date()))
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            reconnectAttempt = 0
            connection = .connected(rssi: -60)
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in scheduleReconnect() }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            characteristic = nil
            // The node keeps running and keeps its recording. Said plainly,
            // because the instinct on seeing a dropped link mid-event is to
            // assume the event was lost.
            note("Link dropped. The node carries on and holds its recording; it is "
                 + "retrieved intact when the link comes back.")
            scheduleReconnect()
        }
    }

    /// Exponential backoff with jitter.
    ///
    /// The jitter matters more than it looks: several phones near one node all
    /// retrying on the same schedule collide on every attempt, and the more
    /// there are the worse it gets. Spreading them means the first one through
    /// succeeds instead of all of them failing together.
    private func scheduleReconnect() {
        guard rememberedIdentifier != nil, source == .bluetooth else { return }
        reconnectTask?.cancel()
        reconnectAttempt += 1

        let base = min(pow(2.0, Double(reconnectAttempt - 1)), 30)
        let jitter = Double.random(in: 0...(base * 0.3))
        let delay = base + jitter
        connection = .reconnecting(attempt: reconnectAttempt, nextRetryIn: delay)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, let peripheral = self.peripheral else { return }
                self.connection = .connecting(attempt: self.reconnectAttempt)
                self.central?.connect(peripheral)
            }
        }
    }

    // MARK: Peripheral delegate

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID })
        else { return }
        peripheral.discoverCharacteristics([Self.characteristicUUID], for: service)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        guard let found = service.characteristics?
            .first(where: { $0.uuid == Self.characteristicUUID }) else { return }
        peripheral.setNotifyValue(true, for: found)
        Task { @MainActor in
            self.characteristic = found
            self.note("Connected. Asking the node for its state.")
            // The node only sends telemetry once a second; asking immediately
            // means the screen is populated before the first tick rather than
            // a second after it.
            self.send(.status)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let data = characteristic.value else { return }
        Task { @MainActor in self.consume(data) }
    }

    /// Reassembles lines from whatever the radio hands over.
    ///
    /// BLE notifications carry about twenty bytes each, and the firmware's
    /// telemetry line is over a hundred — so a line arrives in six pieces, and
    /// two lines can share a packet. Anything that treats one notification as
    /// one message works on the bench with short messages and fails on the
    /// first telemetry line.
    private func consume(_ data: Data) {
        incomingBuffer.append(data)
        while let newline = incomingBuffer.firstIndex(of: 0x0A) {
            let lineData = incomingBuffer[incomingBuffer.startIndex..<newline]
            incomingBuffer.removeSubrange(incomingBuffer.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                receive(line: line)
            }
        }
        // A line that never terminates would grow this for ever. Two kilobytes
        // is ten times the longest message the firmware can produce.
        if incomingBuffer.count > 2048 {
            incomingBuffer.removeAll()
            fault("Discarded a malformed partial message.")
        }
    }
}
#endif
