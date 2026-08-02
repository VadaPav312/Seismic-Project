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

    /// The same stream, in words.
    ///
    /// Newest last, so the feed reads downwards like a transcript. The
    /// instrument panels below it are the authority; this is what somebody
    /// watching the board work actually follows.
    @Published private(set) var commentary: [FirmwareNarrator.Line] = []

    /// Called with the handful of lines that warrant being said out loud.
    ///
    /// A closure rather than a reference to the voice controller, because the
    /// link has no business knowing that speech exists — and because a test can
    /// then assert on exactly which sentences would have been spoken.
    var onSpokenLine: ((String) -> Void)?

    /// Called once, the moment the node declares an event, with whether it is a
    /// drill. The app answers this by warning the household and placing the
    /// automatic emergency call.
    var onDeclaredEvent: ((Bool) -> Void)?

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
        /// Whether FFE0 appeared in the advertisement itself.
        ///
        /// Not a requirement, only a hint. The serial modules these boards use
        /// very often advertise nothing but a local name and expose FFE0 only
        /// once you have connected and read the GATT table, so a list that
        /// showed just the peripherals advertising it would frequently be
        /// empty while the node sat there advertising happily.
        var advertisesNodeService = false
        /// False when the advertisement explicitly says so, which is the one
        /// case where tapping it can only ever fail.
        var isConnectable = true

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

        /// Ranks the list: anything that advertised a serial service first,
        /// then anything that gave a name, then by signal.
        ///
        /// The name tier matters more than it sounds. An unfiltered scan in a
        /// room turns up a dozen unnamed peripherals — headphones between
        /// pairings, a car, somebody's watch — and sorting purely by signal
        /// puts whichever of those happens to be closest above the board with
        /// "HM-10" written on it three feet away.
        var sortKey: Int {
            (advertisesNodeService ? 10_000 : 0) + (hasName ? 1_000 : 0) + rssi
        }

        var hasName: Bool { name != DiscoveredPeripheral.unnamed }
        static let unnamed = "Unnamed device"
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
    private var narrator = FirmwareNarrator()
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
    /// Where commands go.
    private var writeCharacteristic: CBCharacteristic?
    /// Where the node's stream comes from.
    ///
    /// Two separate characteristics, because on a good many modules they *are*
    /// two. Nordic UART splits them by design — 6E400003 notifies and 6E400002
    /// accepts writes — and several HM-10 clones do the same. Insisting on one
    /// characteristic that could do both found nothing at all on those, which
    /// looked from the outside exactly like a board that was not there.
    private var notifyCharacteristic: CBCharacteristic?
    /// Services whose characteristics have been asked for and not yet returned.
    ///
    /// Selection waits for all of them. Taking the first workable
    /// characteristic to arrive means taking whichever service the radio
    /// happened to answer for first, which is not the same as the best one —
    /// a vendor's own service with a notify characteristic on it would beat
    /// FFE0/FFE1 roughly half the time, at random, between launches.
    private var pendingServiceDiscoveries = 0
    /// Incoming bytes that have not yet formed a whole line.
    private var incomingBuffer = Data()

    /// Strong references to everything the scan turned up.
    ///
    /// CoreBluetooth does not retain the peripherals it hands to
    /// `didDiscover`; if nothing else holds one it is deallocated, and
    /// `retrievePeripherals(withIdentifiers:)` then cannot return it. Keeping
    /// only a UUID and asking for the object back later is the single most
    /// common way a scan list ends up full of nodes that all report
    /// "no longer visible" the moment they are tapped.
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]

    /// Scan results as they arrive, published to `discovered` on a timer.
    private var pendingDiscoveries: [UUID: DiscoveredPeripheral] = [:]
    private var discoveryFlush: AnyCancellable?

    private var scanTimeoutTask: Task<Void, Never>?
    private var signalTask: Task<Void, Never>?

    /// `nonisolated` because the CoreBluetooth delegate callbacks are, and a
    /// `@MainActor` type's statics are main-actor-isolated by default —
    /// reading one from `didDiscover` is a warning today and an error under
    /// Swift 6.
    nonisolated static let characteristicUUID = CBUUID(string: "FFE1")

    /// Whether an advertised service is one the protocol is known to run over.
    ///
    /// Only a hint for sorting the scan list — the actual choice is made after
    /// connecting, from the characteristics' properties. The list itself lives
    /// in `BluetoothSerial` so there is one copy of it, and the comparison goes
    /// through `same` rather than `==`: a stack that reports FFE0 in its long
    /// 128-bit form would otherwise fail to match the short one and the node
    /// would drop to the bottom of its own list.
    nonisolated static func isKnownSerialService(_ uuid: CBUUID) -> Bool {
        BluetoothSerial.knownServices.contains {
            BluetoothSerial.same($0, uuid.uuidString)
        }
    }
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
        commentary = []
        narrator.reset()
    }

    // MARK: Receiving

    /// One complete line from the node, whichever node it is.
    private func receive(line: String) {
        guard let message = Firmware.parse(line: line) else { return }
        append(line, kind: .incoming)
        apply(message)
        narrate(message)
    }

    /// The plain-English second reading of the same message.
    private func narrate(_ message: Firmware.Message) {
        let lines = narrator.narrate(message)
        guard !lines.isEmpty else { return }
        commentary.append(contentsOf: lines)
        if commentary.count > 120 { commentary.removeFirst(commentary.count - 120) }
        for line in lines where line.isSpoken {
            onSpokenLine?(line.text)
        }
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
            onDeclaredEvent?(isDrill)

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
            guard let peripheral, let characteristic = writeCharacteristic else {
                commandState[command.acknowledgementToken] =
                    .failed(reason: notifyCharacteristic == nil
                            ? "Not connected."
                            : "This device does not accept commands.")
                return
            }
            // withResponse where the characteristic supports it: a write the
            // radio silently dropped is indistinguishable from one the node
            // ignored, and only one of those is the app's problem to report.
            let type: CBCharacteristicWriteType =
                characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
            // Split to the negotiated MTU. These modules commonly cap a write
            // at twenty bytes, and a longer one is not truncated — it is
            // rejected outright, so `TUNE:` would silently never arrive.
            let limit = max(peripheral.maximumWriteValueLength(for: type), 20)
            let payload = command.payload
            var offset = payload.startIndex
            while offset < payload.endIndex {
                let end = payload.index(offset, offsetBy: limit, limitedBy: payload.endIndex)
                    ?? payload.endIndex
                peripheral.writeValue(payload[offset..<end], for: characteristic, type: type)
                offset = end
            }
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
        discoveredPeripherals = [:]
        pendingDiscoveries = [:]
        connection = .scanning
        if central == nil {
            // Created lazily rather than at launch, so the system permission
            // prompt appears when somebody has asked to find a node instead of
            // on the first run of an app they have not yet used.
            central = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: true])
        } else if central?.state == .poweredOn {
            beginScan()
        } else if let state = central?.state {
            reportUnavailable(state)
        }
    }

    func stopScanning() {
        scanTimeoutTask?.cancel()
        stopPublishingDiscoveries()
        central?.stopScan()
        if case .scanning = connection { connection = .disconnected }
    }

    private func beginScan() {
        // Unfiltered, deliberately.
        //
        // Scanning `withServices: [FFE0]` matches only against the service
        // UUIDs in the *advertisement*, and the serial modules these boards
        // use very often advertise nothing but a local name — FFE0 exists only
        // in the GATT table, which cannot be read until after connecting. A
        // filtered scan therefore shows an empty list next to a node that is
        // advertising perfectly well, and there is no way to tell from the
        // phone that anything is wrong. Everything is listed instead, with the
        // ones that did advertise the service ranked to the top.
        discovered = []
        pendingDiscoveries = [:]
        startPublishingDiscoveries()
        central?.scanForPeripherals(withServices: nil,
                                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        note("Scanning. Everything nearby is listed, because these serial modules usually "
             + "advertise only a name — the node's service is not visible until after "
             + "connecting. Anything that did advertise it is marked and sorted first.")

        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, case .scanning = self.connection else { return }
                // Duplicates are allowed through so RSSI stays live, which is
                // expensive to leave running. Twenty seconds is long enough to
                // find a board on the same bench.
                self.central?.stopScan()
                self.stopPublishingDiscoveries()
                self.discovered = Array(self.pendingDiscoveries.values)
                if self.discovered.isEmpty {
                    self.fault("Twenty seconds of scanning found nothing at all. The board is "
                               + "either unpowered, out of range, or its BLE module is not "
                               + "advertising — check that the module's LED is blinking rather "
                               + "than solid, which means it is already paired to something else.")
                } else {
                    self.note("Scan stopped after twenty seconds to save power. "
                              + "\(self.discovered.count) device\(self.discovered.count == 1 ? "" : "s") "
                              + "found. Tap Scan again to refresh.")
                }
            }
        }
    }

    /// Connects to a discovered node and remembers it.
    func connect(to id: UUID) {
        guard let central else { return }
        // The strong reference first, because it is the one that is reliably
        // there. `retrievePeripherals` is the fallback for a node remembered
        // across launches, which this session never discovered.
        let target = discoveredPeripherals[id]
            ?? central.retrievePeripherals(withIdentifiers: [id]).first
        guard let target else {
            fault("That node is no longer visible to the system. Scan again.")
            return
        }
        scanTimeoutTask?.cancel()
        stopPublishingDiscoveries()
        resetState()
        source = .bluetooth
        rememberedIdentifier = id
        reconnectAttempt = 0
        peripheral = target
        target.delegate = self
        connection = .connecting(attempt: 1)
        central.stopScan()
        note("Connecting to \(target.name ?? "the node").")
        // Ten seconds, because CoreBluetooth's own connect has no timeout at
        // all: a board that is powered but wedged leaves this spinning for
        // ever with nothing on screen to say so.
        central.connect(target, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        watchForConnectTimeout()
    }

    private func watchForConnectTimeout() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            await MainActor.run {
                guard let self, case .connecting = self.connection else { return }
                self.fault("No answer in ten seconds. CoreBluetooth keeps trying indefinitely, "
                           + "so this is the app giving up rather than the radio. The usual "
                           + "cause is the module being connected to something else already.")
            }
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        scanTimeoutTask?.cancel()
        signalTask?.cancel()
        rememberedIdentifier = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        teardownBluetooth()
        connection = .disconnected
    }

    private func teardownBluetooth() {
        reconnectTask?.cancel()
        scanTimeoutTask?.cancel()
        stopPublishingDiscoveries()
        signalTask?.cancel()
        central?.stopScan()
        peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        pendingServiceDiscoveries = 0
        incomingBuffer = Data()
    }

    /// Says why Bluetooth cannot be used, in terms of what to do about it.
    private func reportUnavailable(_ state: CBManagerState) {
        switch state {
        case .poweredOff:
            connection = .disconnected
            fault("Bluetooth is switched off. Turn it on in Control Centre or Settings.")
        case .unauthorized:
            connection = .disconnected
            fault("This app is not allowed to use Bluetooth. Settings → Privacy & Security → "
                  + "Bluetooth, and enable Seismic.")
        case .unsupported:
            connection = .disconnected
            // The Simulator, almost always. Worth naming, because the symptom
            // otherwise is a scan that finds nothing and explains nothing.
            fault("This device has no Bluetooth LE radio. If this is the iOS Simulator, that "
                  + "is expected — the Simulator has no Bluetooth at all. Use the simulated "
                  + "node here and the real one on a phone.")
        case .resetting:
            note("The Bluetooth stack is restarting. This resolves itself in a moment.")
        case .poweredOn:
            // Not a reason to be unavailable. Named rather than swallowed by
            // the default, so adding a state to CBManagerState is a compiler
            // error here instead of a silent nothing.
            break
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    // MARK: Central delegate

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onMain { [self] in
            switch central.state {
            case .poweredOn:
                // Reconnect to the remembered node without being asked. Coming
                // back into range should not need a tap.
                if let remembered = rememberedIdentifier,
                   let known = central.retrievePeripherals(withIdentifiers: [remembered]).first {
                    discoveredPeripherals[remembered] = known
                    peripheral = known
                    known.delegate = self
                    connection = .connecting(attempt: 1)
                    central.connect(known)
                    watchForConnectTimeout()
                } else if source == .bluetooth {
                    beginScan()
                }
            default:
                reportUnavailable(central.state)
            }
        }
    }

    /// Runs `body` on the main actor without allocating a task when it is
    /// already there.
    ///
    /// Every CoreBluetooth callback in this file used `onMain { }`,
    /// and the central is created with `queue: .main` — so the callback was
    /// *already* on the main actor and the hop bought nothing but an
    /// allocation. That was survivable for connection events and fatal for the
    /// two that arrive in floods.
    ///
    /// Scanning with duplicates on, in a room with thirty Bluetooth devices in
    /// it, delivers advertisements faster than the main actor drains its queue.
    /// Each one enqueued another task, the queue grew without bound, and iOS
    /// killed the process for memory — "Terminated due to memory issue", within
    /// a few seconds of the device list appearing. The same shape of failure
    /// waits on `didUpdateValueFor`, which fires once per BLE notification
    /// packet for as long as the node is streaming.
    private nonisolated func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            onMain { body() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let overflow =
            (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? []
        let isNode = (advertised + overflow).contains(where: Self.isKnownSerialService)
        // The local name from the advertisement, then the cached name, then
        // nothing — and an unnamed peripheral is still listed, because an
        // unconfigured module advertises no name at all and is exactly the one
        // somebody is trying to find.
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? DiscoveredPeripheral.unnamed
        let connectable =
            (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        let id = peripheral.identifier
        let rssi = RSSI.intValue
        onMain { [self] in
            // Held strongly, or CoreBluetooth deallocates it and connecting
            // later becomes impossible.
            self.discoveredPeripherals[id] = peripheral

            // Into a plain dictionary, not the published array. Advertisements
            // arrive far faster than anybody can read a list, and publishing
            // each one re-runs every observing view — with thirty devices in
            // the room that is a redraw storm on top of a radio callback. The
            // flush below is what the interface actually sees.
            if var existing = self.pendingDiscoveries[id] {
                // RSSI only; the name is not overwritten, because a duplicate
                // advertisement often omits it and the entry would flicker
                // between its name and "Unnamed device".
                existing.rssi = rssi
                existing.lastSeen = Date()
                if isNode { existing.advertisesNodeService = true }
                self.pendingDiscoveries[id] = existing
            } else {
                self.pendingDiscoveries[id] = DiscoveredPeripheral(
                    id: id, name: name, rssi: rssi, lastSeen: Date(),
                    advertisesNodeService: isNode, isConnectable: connectable)
            }
        }
    }

    /// Publishes the scan results a few times a second rather than per packet.
    ///
    /// Four hertz: fast enough that a device appears the moment you look for
    /// it, slow enough that a busy room costs four redraws a second instead of
    /// several hundred.
    private func startPublishingDiscoveries() {
        discoveryFlush?.cancel()
        discoveryFlush = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let latest = Array(self.pendingDiscoveries.values)
                // Compared before assigning: an idle scan finds the same
                // devices with the same signal for minutes at a time, and
                // republishing an identical array redraws the list for nothing.
                guard latest != self.discovered else { return }
                self.discovered = latest
            }
    }

    private func stopPublishingDiscoveries() {
        discoveryFlush?.cancel()
        discoveryFlush = nil
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        onMain { [self] in
            reconnectAttempt = 0
            connection = .connected(rssi: -60)
            note("Connected. Reading the node's services.")
            // Everything, not just FFE0. Asking for one UUID and finding it
            // absent produces silence; asking for all of them means the app
            // can say which service it *did* find, which is the difference
            // between a fixable problem and a dead screen.
            peripheral.discoverServices(nil)
            peripheral.readRSSI()
            startWatchingSignal()
        }
    }

    /// Keeps the reported signal strength honest.
    ///
    /// `didConnect` has no RSSI of its own, so without this the badge shows a
    /// made-up −60 for the entire session and "weak signal" never appears —
    /// on a link whose most common failure is exactly that.
    private func startWatchingSignal() {
        signalTask?.cancel()
        signalTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run { self?.peripheral?.readRSSI() }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didReadRSSI RSSI: NSNumber,
                                error: Error?) {
        let rssi = RSSI.intValue
        onMain { [self] in
            guard self.notifyCharacteristic != nil || self.connection.isLive else { return }
            self.connection = rssi < -85 ? .weakSignal(rssi: rssi) : .connected(rssi: rssi)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        let reason = error?.localizedDescription
        onMain { [self] in
            self.fault("Could not connect" + (reason.map { ": \($0)" } ?? "."))
            self.scheduleReconnect()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        onMain { [self] in
            writeCharacteristic = nil
            notifyCharacteristic = nil
            pendingServiceDiscoveries = 0
            signalTask?.cancel()
            incomingBuffer = Data()
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
        if let error {
            onMain { [self] in
                self.fault("Could not read the node's services: \(error.localizedDescription)")
            }
            return
        }
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            onMain { [self] in
                self.fault("The node connected but exposes no services at all. That is a module "
                           + "in command mode rather than transparent mode — it needs AT+ROLE0 "
                           + "and a power cycle.")
            }
            return
        }
        // Every service's characteristics, then one decision across all of
        // them. Discovering all of them costs one round trip each and means an
        // unrecognised module still works.
        onMain { [self] in
            self.pendingServiceDiscoveries = services.count
            self.note("Connected. Reading \(services.count) "
                      + "service\(services.count == 1 ? "" : "s").")
            self.openLinkAnywayIfDiscoveryStalls(on: peripheral)
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    /// Opens the link with whatever arrived, if not everything did.
    ///
    /// Selection waits for every service to report its characteristics, and a
    /// service that never answers would otherwise mean waiting for ever — with
    /// a perfectly usable FFE1 already discovered and sitting unused. Three
    /// seconds is far longer than a GATT table takes to read over a link that
    /// is working.
    private func openLinkAnywayIfDiscoveryStalls(on peripheral: CBPeripheral) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run {
                guard let self, self.notifyCharacteristic == nil,
                      self.peripheral === peripheral else { return }
                self.note("Not every service answered, so the link is being opened with what "
                          + "did arrive.")
                self.pendingServiceDiscoveries = 0
                self.openLink(on: peripheral)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        onMain { [self] in
            self.pendingServiceDiscoveries -= 1
            guard self.pendingServiceDiscoveries <= 0, self.notifyCharacteristic == nil else {
                return
            }
            self.openLink(on: peripheral)
        }
    }

    /// Picks the two characteristics the protocol needs and subscribes.
    ///
    /// Chosen by *properties*, ranked, with the known serial UUIDs preferred —
    /// the UUID is a convention and the properties are the contract. An HM-10
    /// puts both on FFE1; Nordic UART splits them; a clone may put a notify on
    /// its own vendor service and a write somewhere else entirely. All three
    /// work out of this.
    private func openLink(on peripheral: CBPeripheral) {
        // Flattened into plain descriptions, chosen by logic that has no
        // CoreBluetooth in it and is therefore testable without a board, then
        // mapped back to the objects the radio needs.
        var objects: [BluetoothSerial.Candidate: CBCharacteristic] = [:]
        var candidates: [BluetoothSerial.Candidate] = []
        var notifyCount = 0

        for service in peripheral.services ?? [] {
            for characteristic in service.characteristics ?? [] {
                let properties = characteristic.properties
                let canNotify = properties.contains(.notify) || properties.contains(.indicate)
                let canWrite = properties.contains(.write)
                    || properties.contains(.writeWithoutResponse)
                guard canNotify || canWrite else { continue }
                if canNotify { notifyCount += 1 }

                let candidate = BluetoothSerial.Candidate(
                    service: service.uuid.uuidString,
                    characteristic: characteristic.uuid.uuidString,
                    canNotify: canNotify, canWrite: canWrite)
                candidates.append(candidate)
                objects[candidate] = characteristic
            }
        }

        let selection = BluetoothSerial.choose(from: candidates)
        let bestNotify = selection.notify.flatMap { objects[$0] }
        let bestWrite = selection.write.flatMap { objects[$0] }

        guard let notify = bestNotify else {
            fault("This device has no characteristic that can stream data, so it is not the "
                  + "node — it is something else that happened to be nearby. Scan again and "
                  + "pick the one your board advertises, which is usually named HM-10, "
                  + "BT05, or whatever you renamed it to.")
            return
        }

        notifyCharacteristic = notify
        writeCharacteristic = bestWrite
        peripheral.setNotifyValue(true, for: notify)

        let notifyName = BluetoothSerial.shortName(notify.uuid.uuidString)
        if let write = writeCharacteristic {
            let writeName = BluetoothSerial.shortName(write.uuid.uuidString)
            note("Link open — \(notifyCount) characteristic\(notifyCount == 1 ? "" : "s") can "
                 + "stream, listening on \(notifyName) and sending on \(writeName).")
        } else {
            // Worth saying rather than discovering later: the screens will
            // populate and every button will fail.
            fault("Listening on \(notifyName), but nothing on this device accepts writes — so "
                  + "the node can be watched and not commanded. Test earthquake and the "
                  + "actuator controls will not work.")
        }

        // The node only sends telemetry once a second; asking immediately means
        // the screen is populated before the first tick rather than a second
        // after it.
        send(.status)
        confirmTrafficArrives()
    }


    /// Checks that the link carries traffic, not merely that it exists.
    ///
    /// A connected peripheral with notifications enabled and a characteristic
    /// that never fires looks, on every status display, exactly like a working
    /// node during a quiet moment. The node sends telemetry every second, so
    /// four seconds of silence is a real fault and worth naming — it is almost
    /// always a module wired to the wrong serial port, or one whose baud rate
    /// does not match the sketch's 9600.
    private func confirmTrafficArrives() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            await MainActor.run {
                guard let self, self.notifyCharacteristic != nil,
                      self.telemetry == nil else { return }
                self.fault("Connected, but the node has sent nothing in four seconds — it should "
                           + "send telemetry every second. The link is fine; the board is not "
                           + "talking. Check the module is on Serial1 and that its baud rate "
                           + "matches the 9600 in the sketch.")
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let error else { return }
        onMain { [self] in
            self.fault("A command was not accepted by the node: \(error.localizedDescription)")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        if let error {
            onMain { [self] in
                self.fault("The node's stream reported an error: \(error.localizedDescription)")
            }
            return
        }
        guard let data = characteristic.value else { return }
        onMain { self.consume(data) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let error else { return }
        onMain { [self] in
            // Without notifications the link is one-way: commands go out and
            // nothing ever comes back, which reads on screen as a node that
            // has stopped rather than a subscription that failed.
            self.fault("Could not subscribe to the node's stream: \(error.localizedDescription). "
                       + "Commands will still be sent but nothing will be received.")
        }
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
