import Foundation
import SeismicCore
#if canImport(CoreBluetooth)
import CoreBluetooth

/// Bluetooth Low Energy transport for the real node.
///
/// The HM-10 style module the Arduino uses exposes a single service with one
/// characteristic that is both writable and notifying — a transparent serial
/// pipe rather than a structured GATT profile. That means all the structure
/// lives in `NodeProtocol`, and this class is deliberately thin: discover,
/// connect, pump bytes in both directions, and reconnect when it drops.
public final class BluetoothTransport: NSObject, NodeTransport, @unchecked Sendable {

    /// The HM-10's well-known transparent-serial service and characteristic.
    /// Kept configurable because clone modules vary.
    /// Stored as strings rather than `CBUUID`, which is a reference type and so
    /// not `Sendable`. The profile is configuration that gets passed between
    /// queues, so it has to be a value all the way down.
    public struct Profile: Sendable, Equatable {
        public var serviceUUID: String
        public var characteristicUUID: String

        public init(serviceUUID: String = "FFE0", characteristicUUID: String = "FFE1") {
            self.serviceUUID = serviceUUID
            self.characteristicUUID = characteristicUUID
        }

        public var service: CBUUID { CBUUID(string: serviceUUID) }
        public var characteristic: CBUUID { CBUUID(string: characteristicUUID) }

        /// The transparent-serial profile the HM-10 and its many clones expose.
        public static let hm10 = Profile()
    }

    public private(set) var identifier: String = ""
    public private(set) var displayName: String = "Seismic node"
    public var isSimulated: Bool { false }
    public var eventHandler: (@Sendable (NodeEvent) -> Void)?

    private let profile: Profile
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var parser = NodeProtocol.Parser()
    private let lock = NSLock()

    private var desiredNodeID: String?
    private var backoff = BackoffState(policy: .bluetooth)
    private var reconnectWorkItem: DispatchWorkItem?
    private var discovered: [String: CBPeripheral] = [:]

    /// Writes are queued because a BLE characteristic accepts one write at a
    /// time and the node's buffer is small; firing a burst simply loses most of
    /// it.
    private var writeQueue: [Data] = []
    private var writeInFlight = false

    /// Held between a manifest and the chunks that follow it: a chunk carries
    /// only a four-byte tag, not the whole event identifier, so the full UUID
    /// has to be remembered from the manifest that introduced it.
    fileprivate var pendingManifestID: UUID?

    private let queue = DispatchQueue(label: "app.seismic.ble", qos: .userInitiated)

    public init(profile: Profile = .hm10) {
        self.profile = profile
        super.init()
        central = CBCentralManager(delegate: self, queue: queue,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    // MARK: NodeTransport

    public func startScanning() {
        queue.async { [weak self] in
            guard let self else { return }
            guard central.state == .poweredOn else {
                emit(.connectionChanged(.disconnected))
                emit(.log(Self.stateDescription(central.state)))
                return
            }
            emit(.connectionChanged(.scanning))
            // Duplicate keys off: a node's RSSI updates are not worth the wakeups.
            central.scanForPeripherals(withServices: [profile.service],
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    public func stopScanning() {
        queue.async { [weak self] in self?.central.stopScan() }
    }

    public func connect(to nodeID: String) {
        queue.async { [weak self] in
            guard let self else { return }
            desiredNodeID = nodeID
            guard let target = discovered[nodeID] else {
                // Not in the discovery cache — try a fresh scan for it.
                startScanning()
                return
            }
            identifier = nodeID
            displayName = target.name ?? "Seismic node"
            peripheral = target
            target.delegate = self
            emit(.connectionChanged(.connecting(attempt: backoff.attempt + 1)))
            central.connect(target, options: nil)
        }
    }

    public func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            // A deliberate disconnect must not trigger the reconnect loop.
            desiredNodeID = nil
            reconnectWorkItem?.cancel()
            if let peripheral { central.cancelPeripheralConnection(peripheral) }
            emit(.connectionChanged(.disconnected))
        }
    }

    public func send(_ command: NodeCommand) {
        let bytes = command.frame().encoded()
        queue.async { [weak self] in
            guard let self else { return }
            lock.lock()
            writeQueue.append(Data(bytes))
            lock.unlock()
            pumpWrites()
        }
    }

    private func pumpWrites() {
        lock.lock()
        guard !writeInFlight, !writeQueue.isEmpty,
              let characteristic = writeCharacteristic,
              let peripheral else { lock.unlock(); return }
        let data = writeQueue.removeFirst()
        writeInFlight = true
        lock.unlock()

        // Prefer acknowledged writes: a command to close a gas valve is not
        // something to send unreliably.
        let type: CBCharacteristicWriteType =
            characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: type)

        if type == .withoutResponse {
            lock.lock(); writeInFlight = false; lock.unlock()
            pumpWrites()
        }
    }

    private func scheduleReconnect() {
        guard let nodeID = desiredNodeID else { return }
        let delay = backoff.recordFailure()
        emit(.connectionChanged(.reconnecting(attempt: backoff.attempt, nextRetryIn: delay)))

        reconnectWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.connect(to: nodeID) }
        reconnectWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func emit(_ event: NodeEvent) { eventHandler?(event) }

    static func stateDescription(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOff: "Bluetooth is switched off. Turn it on to reach the node."
        case .unauthorized: "Seismic does not have permission to use Bluetooth. Grant it in Settings."
        case .unsupported: "This device has no Bluetooth LE radio. Use the simulated node instead."
        case .resetting: "The Bluetooth radio is restarting."
        case .unknown: "Bluetooth state is not known yet."
        case .poweredOn: "Bluetooth is ready."
        @unknown default: "Bluetooth is in an unrecognised state."
        }
    }
}

// MARK: - Central manager delegate

extension BluetoothTransport: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        emit(.log(Self.stateDescription(central.state)))
        if central.state == .poweredOn, let nodeID = desiredNodeID {
            connect(to: nodeID)
        } else if central.state != .poweredOn {
            emit(.connectionChanged(.disconnected))
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier.uuidString
        discovered[id] = peripheral

        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? "Seismic node"
        emit(.discovered(DiscoveredNode(id: id, name: name, rssi: RSSI.intValue,
                                        batteryPercent: nil, isSimulated: false)))

        // Auto-reconnect to the node we are already paired with, silently, which
        // is what makes pairing feel permanent.
        if id == desiredNodeID, peripheral.state == .disconnected {
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        backoff.recordSuccess()
        lock.lock(); parser.reset(); lock.unlock()
        peripheral.discoverServices([profile.service])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        emit(.log("Could not connect: \(error?.localizedDescription ?? "unknown reason")."))
        scheduleReconnect()
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        lock.lock()
        writeCharacteristic = nil
        writeInFlight = false
        lock.unlock()

        if desiredNodeID != nil {
            // Unexpected drop: the node keeps acting autonomously and buffers
            // its recording, so this is a reconnect rather than a failure.
            emit(.log("Connection dropped. The node continues on its own; anything it records "
                + "will be collected when it comes back."))
            scheduleReconnect()
        } else {
            emit(.connectionChanged(.disconnected))
        }
    }
}

// MARK: - Peripheral delegate

extension BluetoothTransport: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == profile.service {
            peripheral.discoverCharacteristics([profile.characteristic], for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics where characteristic.uuid == profile.characteristic {
            lock.lock(); writeCharacteristic = characteristic; lock.unlock()
            peripheral.setNotifyValue(true, for: characteristic)
            peripheral.readRSSI()
            emit(.connectionChanged(.connected(rssi: -55)))
            emit(.log("Connected and streaming."))
            pumpWrites()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        lock.lock()
        let frames = parser.append(data)
        lock.unlock()
        for frame in frames { dispatch(frame) }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        lock.lock(); writeInFlight = false; lock.unlock()
        pumpWrites()
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didReadRSSI RSSI: NSNumber, error: Error?) {
        let value = RSSI.intValue
        // A weak signal is shown distinctly, because it predicts the dropouts
        // the user is about to experience.
        emit(.connectionChanged(value < -85 ? .weakSignal(rssi: value) : .connected(rssi: value)))
    }

    /// Turns a verified frame into a typed event.
    private func dispatch(_ frame: NodeProtocol.Frame) {
        switch frame.type {
        case .telemetry:
            if let telemetry = NodeTelemetry.decode(payload: frame.payload) {
                emit(.telemetry(telemetry))
            }
        case .highRateSamples:
            if let batch = HighRateBatch.decode(payload: frame.payload) {
                emit(.highRate(batch))
            }
        case .triggerEvent:
            var reader = ByteReader(frame.payload)
            if let ratio = reader.readFixed16(scale: PayloadScale.ratio) {
                emit(.triggered(ratio: ratio, channel: .accelerometer, at: Date()))
            }
        case .sensorVote:
            var reader = ByteReader(frame.payload)
            if let channelIndex = reader.readUInt8(), let agreed = reader.readBool(),
               let value = reader.readFixed16(scale: PayloadScale.ratio),
               Int(channelIndex) < SensorChannel.allCases.count {
                emit(.sensorVote(SensorVote(channel: SensorChannel.allCases[Int(channelIndex)],
                                            agreed: agreed, value: value)))
            }
        case .actuatorReport:
            var reader = ByteReader(frame.payload)
            if let kindCode = reader.readUInt8(), let stateCode = reader.readUInt8(),
               let kind = NodeCommand.actuator(fromCode: kindCode) {
                let states = [ActuatorState.idle, .queued, .commanded, .inProgress,
                              .confirmed, .failed, .unknown]
                let state = Int(stateCode) < states.count ? states[Int(stateCode)] : .unknown
                emit(.actuatorReport(ActuatorReport(kind: kind, state: state)))
            }
        case .recordingManifest:
            if let manifest = RecordingManifest.decode(payload: frame.payload) {
                lock.lock(); pendingManifestID = manifest.eventID; lock.unlock()
                emit(.recordingManifest(manifest))
            }
        case .recordingChunk:
            lock.lock(); let id = pendingManifestID; lock.unlock()
            if let id, let chunk = RecordingChunk.decode(payload: frame.payload, eventID: id) {
                emit(.recordingChunk(chunk))
            }
        case .fault:
            var reader = ByteReader(frame.payload)
            if let code = reader.readUInt8(), Int(code) < NodeFault.allCases.count {
                emit(.fault(NodeFault.allCases[Int(code)]))
            }
        case .periodMeasurement:
            var reader = ByteReader(frame.payload)
            if let period = reader.readFixed16(scale: PayloadScale.period),
               let confidence = reader.readUInt8(),
               let temperature = reader.readFixed16(scale: PayloadScale.temperature) {
                emit(.periodMeasured(period: period, confidence: Double(confidence) / 255,
                                     temperature: temperature))
            }
        case .rfidTap:
            let tag = frame.payload.map { String(format: "%02X", $0) }.joined()
            emit(.rfidTap(tag: tag, at: Date()))
        case .selfTestResult:
            emit(.selfTestResult(Self.decodeSelfTest(frame.payload)))
        case .acknowledgement:
            emit(.log("Node acknowledged."))
        case .command, .chunkRequest, .timeSync:
            break        // phone → node only; a node sending these is a bug in its firmware
        }
    }

    private static func decodeSelfTest(_ payload: [UInt8]) -> SelfTestResult {
        // Each bit is one check, in the order the firmware defines.
        let names = ["Accelerometer", "Tilt switch", "Sound sensor", "Ultrasonic range",
                     "Thermistors", "Photoresistors", "Water sensor", "Real-time clock"]
        guard let bits = payload.first else {
            return SelfTestResult(checks: [.init(name: "Self-test", passed: false,
                                                 detail: "The node returned an empty result.")])
        }
        return SelfTestResult(checks: names.enumerated().map { index, name in
            let passed = bits & (1 << UInt8(index)) != 0
            return .init(name: name, passed: passed,
                         detail: passed ? "Responding normally."
                             : "Did not respond. Check its wiring on the diagnostics screen.")
        })
    }
}

#endif
