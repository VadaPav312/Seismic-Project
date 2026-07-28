import Foundation

// MARK: - Node lifecycle

public enum NodeState: String, Codable, Sendable, CaseIterable {
    case monitoring, armed, triggered, acting, recording, assessing, fault, offline

    public var label: String {
        switch self {
        case .monitoring: "Monitoring"
        case .armed: "Armed"
        case .triggered: "Triggered"
        case .acting: "Acting"
        case .recording: "Recording"
        case .assessing: "Assessing"
        case .fault: "Fault"
        case .offline: "Offline"
        }
    }

    public var isEventActive: Bool {
        self == .triggered || self == .acting || self == .recording
    }
}

/// Never let the user wonder whether the numbers on screen are real.
public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case scanning
    case connecting(attempt: Int)
    case connected(rssi: Int)
    case weakSignal(rssi: Int)
    case reconnecting(attempt: Int, nextRetryIn: TimeInterval)
    case simulated

    public var label: String {
        switch self {
        case .disconnected: "Not connected"
        case .scanning: "Scanning"
        case .connecting(let a): a <= 1 ? "Connecting" : "Connecting (attempt \(a))"
        case .connected: "Connected"
        case .weakSignal: "Weak signal"
        case .reconnecting(let a, let t): "Reconnecting in \(Int(t.rounded()))s (attempt \(a))"
        case .simulated: "Simulated node"
        }
    }

    public var isLive: Bool {
        switch self {
        case .connected, .weakSignal, .simulated: true
        default: false
        }
    }

    /// True when the data is synthetic. The UI must mark this unmistakably.
    public var isSimulated: Bool { self == .simulated }
}

// MARK: - Actuators

public enum ActuatorKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case gasValve, mainsPower, waterMain
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .gasValve: "Gas valve"
        case .mainsPower: "Mains power"
        case .waterMain: "Water main"
        }
    }

    public var actionVerb: String {
        switch self {
        case .gasValve: "Close gas valve"
        case .mainsPower: "Cut mains power"
        case .waterMain: "Close water main"
        }
    }

    public var systemImage: String {
        switch self {
        case .gasValve: "flame"
        case .mainsPower: "bolt.horizontal"
        case .waterMain: "drop"
        }
    }

    /// How the node proves the action actually happened, rather than merely
    /// having been commanded. A command with no confirmation is a rumour.
    public var confirmation: ConfirmationMethod {
        switch self {
        case .gasValve: .servoPositionFeedback
        case .mainsPower: .photoresistorLamp
        case .waterMain: .waterLevelSensor
        }
    }

    /// Current while moving, milliamps.
    ///
    /// This is the *running* draw under load, not the stall figure. A hobby
    /// servo stalls at around 650 mA, but it only reaches that against a jammed
    /// output; turning a valve it draws roughly a third of that, and the brief
    /// inrush is absorbed by the board's bulk capacitor. Scheduling against the
    /// stall figure would conclude that a USB port cannot drive even one servo,
    /// which is plainly not true — but scheduling against the running figure
    /// still correctly forbids two at once, which is the constraint that matters.
    public var peakCurrent_mA: Double {
        switch self {
        case .gasValve: 240
        case .mainsPower: 40        // a latching relay coil, and only briefly
        case .waterMain: 260
        }
    }

    /// How long the motion takes, seconds.
    public var travelTime: TimeInterval {
        switch self {
        case .gasValve: 1.4
        case .mainsPower: 0.2
        case .waterMain: 1.8
        }
    }

    /// Order matters: gas first, because a gas leak into a building with live
    /// electrics is the failure mode that kills people after the shaking stops.
    public var firingPriority: Int {
        switch self {
        case .gasValve: 0
        case .mainsPower: 1
        case .waterMain: 2
        }
    }
}

public enum ConfirmationMethod: String, Codable, Sendable {
    case servoPositionFeedback, photoresistorLamp, waterLevelSensor, ultrasonicPosition, none

    public var label: String {
        switch self {
        case .servoPositionFeedback: "Servo reported final position"
        case .photoresistorLamp: "Photoresistor saw the test lamp go dark"
        case .waterLevelSensor: "Water sensor saw flow stop"
        case .ultrasonicPosition: "Ultrasonic measured the new position"
        case .none: "Not independently confirmed"
        }
    }
}

public enum ActuatorState: String, Codable, Sendable {
    case idle, queued, commanded, inProgress, confirmed, failed, unknown

    public var label: String {
        switch self {
        case .idle: "Ready"
        case .queued: "Queued"
        case .commanded: "Commanded"
        case .inProgress: "Moving"
        case .confirmed: "Confirmed"
        case .failed: "Failed"
        case .unknown: "Unknown"
        }
    }
}

public struct ActuatorReport: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var kind: ActuatorKind
    public var state: ActuatorState
    public var commandedAt: Date?
    public var completedAt: Date?
    public var confirmedBy: ConfirmationMethod
    public var failureReason: String?

    public init(id: UUID = UUID(), kind: ActuatorKind, state: ActuatorState = .idle,
                commandedAt: Date? = nil, completedAt: Date? = nil,
                confirmedBy: ConfirmationMethod? = nil, failureReason: String? = nil) {
        self.id = id
        self.kind = kind
        self.state = state
        self.commandedAt = commandedAt
        self.completedAt = completedAt
        self.confirmedBy = confirmedBy ?? kind.confirmation
        self.failureReason = failureReason
    }

    public var elapsed: TimeInterval? {
        guard let a = commandedAt, let b = completedAt else { return nil }
        return b.timeIntervalSince(a)
    }
}

// MARK: - Sensors and faults

public enum SensorChannel: String, Codable, Sendable, CaseIterable, Identifiable {
    case accelerometer, tiltSwitch, soundSensor, ultrasonic, waterLevel
    case photoresistorGrid, photoresistorRelay, thermistorBoard, thermistorStructure
    case pir, rfid, rtc
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .accelerometer: "Accelerometer"
        case .tiltSwitch: "Tilt switch"
        case .soundSensor: "Sound sensor"
        case .ultrasonic: "Ultrasonic range"
        case .waterLevel: "Water level"
        case .photoresistorGrid: "Grid power photoresistor"
        case .photoresistorRelay: "Relay verification photoresistor"
        case .thermistorBoard: "Board thermistor"
        case .thermistorStructure: "Structure thermistor"
        case .pir: "Occupancy (PIR)"
        case .rfid: "RFID reader"
        case .rtc: "Real-time clock"
        }
    }

    /// Weight this channel carries in the fusion vote. The accelerometer is the
    /// only one that can characterise an event; the others can only agree.
    public var voteWeight: Double {
        switch self {
        case .accelerometer: 0.6
        case .tiltSwitch: 0.25
        case .soundSensor: 0.15
        default: 0
        }
    }
}

public struct SensorVote: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var channel: SensorChannel
    public var agreed: Bool
    public var value: Double
    public var at: Date

    public init(id: UUID = UUID(), channel: SensorChannel, agreed: Bool,
                value: Double, at: Date = Date()) {
        self.id = id; self.channel = channel; self.agreed = agreed
        self.value = value; self.at = at
    }
}

public enum NodeFault: String, Codable, Sendable, CaseIterable, Identifiable {
    case sensorDisconnected, actuatorJammed, brownout, calibrationInvalid
    case clockUnset, storageFull, bleCongested
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .sensorDisconnected: "Sensor disconnected"
        case .actuatorJammed: "Actuator jammed"
        case .brownout: "Brownout detected"
        case .calibrationInvalid: "Calibration invalid"
        case .clockUnset: "Clock not set"
        case .storageFull: "Node storage full"
        case .bleCongested: "Bluetooth congested"
        }
    }

    /// Plain language, with a way forward. Never a code.
    public var guidance: String {
        switch self {
        case .sensorDisconnected: "One of the node's sensors stopped responding. Check the wiring on the diagnostics screen, then run a self-test."
        case .actuatorJammed: "An actuator was commanded but never reached its end position. Reset it from the actuator console and try again by hand if it does not clear."
        case .brownout: "The node's supply voltage dipped, most likely because two motors moved at once. Any recording captured during a brownout is marked suspect and excluded from assessment."
        case .calibrationInvalid: "The baseline is stale or was taken while the building was moving. Re-run calibration while the building is quiet."
        case .clockUnset: "The node's real-time clock has no valid time, so event timestamps cannot be trusted. Sync the clock from this screen."
        case .storageFull: "The node cannot buffer another recording. Transfer or discard the recordings it is holding."
        case .bleCongested: "Bluetooth throughput has collapsed. Move closer to the node; the transfer resumes where it left off."
        }
    }

    public var severity: Severity {
        switch self {
        case .brownout, .actuatorJammed, .sensorDisconnected: .critical
        case .calibrationInvalid, .clockUnset: .warning
        case .storageFull, .bleCongested: .info
        }
    }

    public enum Severity: String, Codable, Sendable { case info, warning, critical }
}

// MARK: - Telemetry

/// The low-rate heartbeat. Everything here is displayable somewhere; nothing is
/// carried that the UI cannot explain.
public struct NodeTelemetry: Codable, Sendable, Equatable {
    public var state: NodeState
    public var timestamp: Date
    public var boardTemperature: Double        // °C
    public var structureTemperature: Double    // °C
    public var ambientVibrationRMS: Double     // m/s²
    public var measuredPeriod: Double?         // s
    public var staLtaRatio: Double
    public var batteryPercent: Double?
    public var usbPowered: Bool
    public var supplyVoltage: Double           // V, for brownout detection
    public var activeCurrentDraw_mA: Double
    public var gridPowerPresent: Bool
    public var waterDetected: Bool
    public var occupancyDetected: Bool
    public var permanentTilt: Bool
    public var tiltAngle: Double               // degrees
    public var residualDisplacement: Double    // metres
    public var faults: [NodeFault]
    public var disconnectedSensors: [SensorChannel]

    public init(
        state: NodeState = .monitoring,
        timestamp: Date = Date(),
        boardTemperature: Double = 28,
        structureTemperature: Double = 19,
        ambientVibrationRMS: Double = 0.004,
        measuredPeriod: Double? = nil,
        staLtaRatio: Double = 1.0,
        batteryPercent: Double? = nil,
        usbPowered: Bool = true,
        supplyVoltage: Double = 5.05,
        activeCurrentDraw_mA: Double = 180,
        gridPowerPresent: Bool = true,
        waterDetected: Bool = false,
        occupancyDetected: Bool = false,
        permanentTilt: Bool = false,
        tiltAngle: Double = 0,
        residualDisplacement: Double = 0,
        faults: [NodeFault] = [],
        disconnectedSensors: [SensorChannel] = []
    ) {
        self.state = state
        self.timestamp = timestamp
        self.boardTemperature = boardTemperature
        self.structureTemperature = structureTemperature
        self.ambientVibrationRMS = ambientVibrationRMS
        self.measuredPeriod = measuredPeriod
        self.staLtaRatio = staLtaRatio
        self.batteryPercent = batteryPercent
        self.usbPowered = usbPowered
        self.supplyVoltage = supplyVoltage
        self.activeCurrentDraw_mA = activeCurrentDraw_mA
        self.gridPowerPresent = gridPowerPresent
        self.waterDetected = waterDetected
        self.occupancyDetected = occupancyDetected
        self.permanentTilt = permanentTilt
        self.tiltAngle = tiltAngle
        self.residualDisplacement = residualDisplacement
        self.faults = faults
        self.disconnectedSensors = disconnectedSensors
    }
}

/// A discovered node, before or after pairing.
public struct DiscoveredNode: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var rssi: Int
    public var batteryPercent: Double?
    public var isSimulated: Bool
    public var lastSeen: Date

    public init(id: String, name: String, rssi: Int, batteryPercent: Double? = nil,
                isSimulated: Bool = false, lastSeen: Date = Date()) {
        self.id = id; self.name = name; self.rssi = rssi
        self.batteryPercent = batteryPercent; self.isSimulated = isSimulated
        self.lastSeen = lastSeen
    }

    public var signalBars: Int {
        switch rssi {
        case (-55)...: 4
        case (-67)..<(-55): 3
        case (-80)..<(-67): 2
        default: 1
        }
    }
}

// MARK: - Commands

public enum NodeCommand: Codable, Sendable, Equatable {
    case selfTest
    case calibrateBaseline
    case setSensitivity(Double)          // STA/LTA trigger threshold
    case drill(fireActuators: Bool)
    case fireActuator(ActuatorKind)
    case resetActuator(ActuatorKind)
    case setLED(r: Double, g: Double, b: Double)
    case buzz(pattern: String)
    case playTone(frequency: Double, duration: TimeInterval)
    case setMatrixText(String)
    case setSevenSegment(String)
    case setFloorStressPattern(UInt8)    // 74HC595 bit pattern
    case requestPeriodMeasurement
    case setShakeTableSpeed(Double)      // 0…1
    case requestRecording(eventID: UUID, fromChunk: Int)
    case syncClock(Date)
    case acknowledgeEvent(UUID)
    case abort

    public var label: String {
        switch self {
        case .selfTest: "Self-test"
        case .calibrateBaseline: "Calibrate baseline"
        case .setSensitivity(let v): "Set sensitivity \(String(format: "%.1f", v))"
        case .drill(let f): f ? "Drill (with actuators)" : "Drill (no actuators)"
        case .fireActuator(let k): k.actionVerb
        case .resetActuator(let k): "Reset \(k.label.lowercased())"
        case .setLED: "Set LED colour"
        case .buzz: "Sound buzzer"
        case .playTone(let f, _): "Play \(Int(f)) Hz"
        case .setMatrixText(let t): "Matrix: \(t)"
        case .setSevenSegment(let t): "7-seg: \(t)"
        case .setFloorStressPattern: "Floor stress pattern"
        case .requestPeriodMeasurement: "Measure period"
        case .setShakeTableSpeed(let s): "Shake table \(Int(s * 100))%"
        case .requestRecording: "Request recording"
        case .syncClock: "Sync clock"
        case .acknowledgeEvent: "Acknowledge event"
        case .abort: "Abort"
        }
    }

    /// Commands that move a motor. Only one of these may be in flight at a time.
    public var movesMotor: Bool {
        switch self {
        case .fireActuator(let k), .resetActuator(let k): k != .mainsPower
        case .setShakeTableSpeed(let s): s > 0
        case .drill(let fire): fire
        default: false
        }
    }
}
