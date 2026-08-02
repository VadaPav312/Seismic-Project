import Foundation
import Combine
import SeismicCore
import SeismicDevice

/// The real Arduino, behind the seam the whole app already talks to.
///
/// There were two Bluetooth paths in this app and only one of them could ever
/// have worked. `BluetoothTransport` speaks `NodeProtocol` — a binary framed
/// protocol with checksums — and `arduino.ino` speaks newline-delimited JSON.
/// So the sensor picker on the Node screen, which scans through whatever
/// transport is attached, would have connected to the board and then sat there
/// parsing nothing. In practice it never got that far: nothing ever attached a
/// Bluetooth transport, so the picker listed the simulated node and nothing
/// else, and there was no way from that screen to reach real hardware at all.
///
/// `SeismicNodeLink` is the path that does work — it speaks the firmware's
/// actual protocol and it is what the Hardware screen drives. This adapter puts
/// it behind `NodeTransport`, so the monitor, the detector, the recorder and
/// the assessment get the board's real motion without any of them changing.
/// They cannot tell the difference between this, the phone's accelerometer and
/// the simulator, which is the entire point of the seam.
/// `@unchecked Sendable` with a lock rather than `@MainActor`, because
/// `NodeTransport` is a `Sendable` protocol whose members are not isolated:
/// a main-actor class conforming to it crosses actors at every call, which is
/// a warning today and an error in Swift 6. The two fields that are read from
/// anywhere are guarded; everything that touches the link hops to the main
/// actor, where the link lives.
final class FirmwareNodeTransport: NodeTransport, @unchecked Sendable {

    let link: SeismicNodeLink

    private let lock = NSLock()
    private var storedIdentifier = "seismic-node"
    private var storedName = "Seismic node"

    var identifier: String { withLock { storedIdentifier } }
    var displayName: String { withLock { storedName } }
    /// False, and it matters: this is a real instrument bolted to a real
    /// building, so nothing downstream marks its verdicts as synthetic.
    let isSimulated = false

    var eventHandler: (@Sendable (NodeEvent) -> Void)? {
        get { withLock { storedHandler } }
        set { withLock { storedHandler = newValue } }
    }
    private var storedHandler: (@Sendable (NodeEvent) -> Void)?

    /// Scoped, because `NSLock.lock()` is unavailable from an async context —
    /// suspending while holding a lock is how a deadlock gets written — and
    /// every caller here is inside a `Task`.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private var cancellables: Set<AnyCancellable> = []

    /// The firmware reports acceleration as a single scalar deviation rather
    /// than three axes — it is what its detector runs on. Presented on the
    /// horizontal axis, with the others left at zero rather than invented,
    /// because a fabricated Y and Z would flow into the polarisation and
    /// bearing estimates and produce confident answers about a direction the
    /// node never measured.
    private var sequence: UInt16 = 0
    private var pending: [Double] = []
    private static let batchSize = 10
    private static let sampleRate = 20.0

    @MainActor
    init(link: SeismicNodeLink) {
        self.link = link
        observe()
    }

    // MARK: Watching the link

    /// Republishes the link's state as transport events.
    ///
    /// The link is the authority and this only translates. Anything it does not
    /// say is not emitted — a transport that filled gaps with plausible values
    /// would be putting numbers nobody measured into an assessment.
    @MainActor
    private func observe() {
        link.$discovered
            .sink { [weak self] found in
                guard let self else { return }
                for device in found {
                    self.emit(.discovered(DiscoveredNode(
                        id: device.id.uuidString, name: device.name,
                        rssi: device.rssi, batteryPercent: nil, isSimulated: false)))
                }
            }
            .store(in: &cancellables)

        link.$connection
            .removeDuplicates()
            .sink { [weak self] state in self?.emit(.connectionChanged(state)) }
            .store(in: &cancellables)

        link.$trace
            .sink { [weak self] trace in self?.forwardMotion(trace) }
            .store(in: &cancellables)

        link.$telemetry
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] telemetry in self?.forward(telemetry) }
            .store(in: &cancellables)

        link.$lastTrigger
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] trigger in
                self?.emit(.triggered(ratio: trigger.ratio, channel: .accelerometer,
                                      at: trigger.at))
            }
            .store(in: &cancellables)

        link.$actuators
            .removeDuplicates()
            .sink { [weak self] states in
                guard let self else { return }
                for (device, state) in states {
                    guard let kind = Self.actuatorKind(for: device) else { continue }
                    self.emit(.actuatorReport(ActuatorReport(
                        kind: kind, state: Self.actuatorState(for: state))))
                }
            }
            .store(in: &cancellables)

        link.$log
            .compactMap(\.first)
            .removeDuplicates()
            .sink { [weak self] entry in
                guard entry.kind == .note || entry.kind == .fault else { return }
                self?.emit(.log(entry.text))
            }
            .store(in: &cancellables)
    }

    /// The rolling trace, forwarded as it grows.
    ///
    /// `trace` is a window the link keeps rather than a stream, so only what is
    /// new since last time is sent on — otherwise every tick would re-deliver
    /// the previous three hundred samples and the session would integrate the
    /// same motion over and over.
    private var forwardedCount = 0

    @MainActor
    private func forwardMotion(_ trace: [Double]) {
        // The window is capped, so it shrinks from the front as it fills. Once
        // it is at capacity the count stops growing and the only safe reading
        // is the newest sample.
        let fresh: [Double]
        if trace.count > forwardedCount {
            fresh = Array(trace.suffix(trace.count - forwardedCount))
        } else if let last = trace.last, forwardedCount > 0 {
            fresh = [last]
        } else {
            fresh = []
        }
        forwardedCount = trace.count
        guard !fresh.isEmpty else { return }

        pending.append(contentsOf: fresh)
        while pending.count >= Self.batchSize {
            let batch = Array(pending.prefix(Self.batchSize))
            pending.removeFirst(Self.batchSize)
            sequence &+= 1
            emit(.highRate(HighRateBatch(sequence: sequence, sampleRate: Self.sampleRate,
                                         x: batch,
                                         y: [Double](repeating: 0, count: batch.count),
                                         z: [Double](repeating: 0, count: batch.count))))
        }
    }

    @MainActor
    private func forward(_ telemetry: Firmware.Telemetry) {
        // Only the fields the firmware actually sends. Everything else keeps
        // its default rather than being filled in with a plausible number: a
        // supply voltage this board never reported would end up in a brownout
        // judgement, and a structure temperature it never measured would end
        // up in the temperature correction, which is the one place in this app
        // an invented value does real harm.
        var reading = NodeTelemetry(
            state: Self.state(for: telemetry.state),
            staLtaRatio: telemetry.ratio,
            occupancyDetected: telemetry.isOccupied,
            permanentTilt: telemetry.isTilted)
        if telemetry.isTemperatureValid {
            reading.structureTemperature = telemetry.temperatureCelsius
        }
        if telemetry.baselinePeriod > 0 { reading.measuredPeriod = telemetry.baselinePeriod }
        emit(.telemetry(reading))
    }

    /// The firmware's state machine has nine states and the app's has eight,
    /// and they are not the same nine. Mapped explicitly rather than by raw
    /// value — the two enums were written years apart and their orders differ,
    /// so a numeric cast would have silently reported "recording" while the
    /// board was acting.
    private static func state(for state: Firmware.NodeState) -> NodeState {
        switch state {
        case .boot, .calibrating: .monitoring
        case .monitoring: .armed
        case .disarmed: .offline
        case .triggered: .triggered
        case .acting: .acting
        case .recording: .recording
        case .assessing, .verdict: .assessing
        }
    }

    // MARK: NodeTransport

    func startScanning() {
        Task { @MainActor in self.link.startScanning() }
    }

    func stopScanning() {
        Task { @MainActor in self.link.stopScanning() }
    }

    func connect(to nodeID: String) {
        guard let id = UUID(uuidString: nodeID) else { return }
        Task { @MainActor in
            let name = self.link.discovered.first { $0.id == id }?.name ?? "Seismic node"
            self.withLock {
                self.storedIdentifier = id.uuidString
                self.storedName = name
            }
            self.forwardedCount = 0
            self.pending = []
            self.link.connect(to: id)
        }
    }

    func disconnect() {
        Task { @MainActor in
            self.withLock { self.storedIdentifier = "seismic-node" }
            self.link.disconnect()
        }
    }

    /// Translates the app's command vocabulary into the firmware's.
    ///
    /// Only the commands the firmware actually has. A command it does not
    /// understand is dropped with a line saying so rather than sent and
    /// silently ignored — the difference between those two is whether anybody
    /// finds out that the gas valve was never told to close.
    func send(_ command: NodeCommand) {
        Task { @MainActor in
            guard let translated = Self.firmwareCommand(for: command) else {
                self.emit(.log("The node's firmware has no command for that, so nothing was "
                               + "sent."))
                return
            }
            self.link.send(translated)
        }
    }

    private func emit(_ event: NodeEvent) { eventHandler?(event) }

    // MARK: Translation

    private static func actuatorKind(for device: Firmware.Actuator) -> ActuatorKind? {
        switch device {
        case .power: nil            // the app's ActuatorKind has no mains entry
        case .water: .waterMain
        case .gas: .gasValve
        }
    }

    private static func actuatorState(for state: Firmware.ActuatorState) -> ActuatorState {
        switch state {
        case .idle: .idle
        case .commanded: .commanded
        case .confirmed: .confirmed
        case .failed: .failed
        }
    }

    private static func firmwareCommand(for command: NodeCommand) -> Firmware.Command? {
        switch command {
        case .selfTest: .status
        case .calibrateBaseline, .requestPeriodMeasurement: .calibrate
        case .drill: .drill
        case .fireActuator(let kind):
            switch kind {
            case .mainsPower: .power(on: false)
            case .waterMain: .water(closed: true)
            case .gasValve: nil          // modelled, and not fitted. See the console.
            }
        case .resetActuator: .reset
        case .abort: .disarm
        case .setSensitivity(let value): .triggerThreshold(value)
        default: nil
        }
    }
}
