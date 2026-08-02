import Foundation
import SeismicCore

/// The wire protocol the Arduino node actually speaks.
///
/// Newline-delimited JSON inbound, plain text outbound, over a single BLE
/// characteristic. Kept as pure parsing and formatting with no transport in it
/// at all, so every message the firmware can emit is testable against a string
/// literal copied out of the serial monitor — which is the only way to be sure
/// the app agrees with the board without a board.
///
/// Written against `arduino.ino` rather than against the specification, where
/// the two differ. Several fields the firmware sends are not in the spec, and
/// they are worth having:
///
/// * telemetry carries `pb` and `thr` — the node's own idea of the baseline
///   period and the trigger threshold — which is what lets the tuning controls
///   confirm a value rather than merely claiming to have sent it;
/// * `trig` carries `drill`, so a rehearsal is distinguishable from the real
///   thing in the record afterwards rather than only in the moment;
/// * there is a `cal` message reporting what calibration actually found, which
///   the spec does not mention at all.
public enum Firmware {

    // MARK: Node state

    /// `st` in the telemetry line.
    public enum NodeState: Int, Sendable, CaseIterable {
        case boot = 0, calibrating, monitoring, disarmed
        case triggered, acting, recording, assessing, verdict

        public var label: String {
            switch self {
            case .boot: "Starting"
            case .calibrating: "Calibrating"
            case .monitoring: "Armed"
            case .disarmed: "Disarmed"
            case .triggered: "Event declared"
            case .acting: "Acting"
            case .recording: "Recording"
            case .assessing: "Measuring"
            case .verdict: "Verdict"
            }
        }

        /// Whether the node is currently reacting to shaking. Disarmed is a
        /// deliberate choice rather than a fault, and the interface has to make
        /// that distinction unmistakable.
        public var isArmed: Bool { self == .monitoring }

        public var isEventInProgress: Bool {
            switch self {
            case .triggered, .acting, .recording, .assessing: true
            default: false
            }
        }
    }

    /// One physical output, and what the firmware reports about it.
    public enum ActuatorState: Int, Sendable {
        case idle = 0, commanded, confirmed, failed

        public var label: String {
            switch self {
            case .idle: "Ready"
            case .commanded: "Commanded"
            case .confirmed: "Physically confirmed"
            case .failed: "Failed"
            }
        }

        /// The distinction the whole photoresistor exists for. A command that
        /// was sent is a rumour; a command whose effect was measured is a fact,
        /// and only one of those belongs in a safety report.
        public var isProven: Bool { self == .confirmed }
    }

    // MARK: Messages

    public enum Message: Sendable, Equatable {
        /// The node restarted. `hasAccelerometer` false means the MPU is
        /// missing, which the firmware treats as fatal.
        case boot(hasAccelerometer: Bool)

        case telemetry(Telemetry)

        /// A live sample for the seismograph, about ten a second.
        case acceleration(deviation: Int, ratio: Double)

        /// An event was declared, with the votes that caused it.
        case triggered(ratio: Double, votes: Votes, isDrill: Bool)

        case countdown(secondsRemaining: Int)
        case phase(Phase)

        case actuator(device: Actuator, state: ActuatorState)

        /// The light readings behind a confirmation.
        case verification(device: Actuator, before: Int, after: Int, confirmed: Bool)

        case recordingBegan(sampleCount: Int, sampleRate: Double)
        case recordingChunk(index: Int, samples: [Int], checksum: Int)
        case recordingEnded

        case assessment(Assessment)

        /// What calibration found. Not in the specification; the firmware sends
        /// it and it is the only report of what "quiet" was learned to be.
        case calibrated(gravity: Int, soundBaseline: Int, periodMilliseconds: Int)

        case note(String)
        case error(String)
        case acknowledged(command: String)

        /// A line that parsed as JSON but was not a message this app knows.
        ///
        /// Kept rather than dropped: firmware moves on, and a silently ignored
        /// message is how an app and a board drift apart without anyone
        /// noticing. It surfaces in the log.
        case unrecognised(type: String, raw: String)
    }

    public enum Actuator: String, Sendable, CaseIterable, Identifiable {
        case power, water
        /// Present in the model and absent from the hardware. See
        /// `isAvailableInFirmware`.
        case gas
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .power: "Building power"
            case .water: "Water main"
            case .gas: "Gas valve"
            }
        }

        public var systemImage: String {
            switch self {
            case .power: "bolt.horizontal"
            case .water: "drop"
            case .gas: "flame"
            }
        }

        /// Whether this node can actually operate it.
        ///
        /// The gas valve is deliberately modelled and deliberately unavailable.
        /// Hiding it would imply the system had never considered gas; showing
        /// it greyed out with the reason states the engineering position, which
        /// is that a five-hundred-milliamp budget cannot carry three motors and
        /// something had to be shed.
        public var isAvailableInFirmware: Bool { self != .gas }

        public var unavailableReason: String? {
            guard self == .gas else { return nil }
            return "Not fitted on this node. The board runs on USB — about five hundred "
                + "milliamps — and a servo drawing two hundred and fifty of them while a "
                + "stepper draws another two hundred and sixty browns out the "
                + "microcontroller mid-event. One actuator had to be shed, so the two that "
                + "remain are electrical isolation and water: life safety first, property "
                + "second. Gas isolation needs either a second supply or a latching valve "
                + "that draws current only while it moves."
        }
    }

    public enum Phase: String, Sendable, Equatable {
        case calibrating, monitoring, disarmed, warning, acting, recording, assessing, verdict

        public var label: String {
            switch self {
            case .calibrating: "Calibrating"
            case .monitoring: "Monitoring"
            case .disarmed: "Disarmed"
            case .warning: "Warning"
            case .acting: "Acting"
            case .recording: "Recording"
            case .assessing: "Measuring the building"
            case .verdict: "Verdict"
            }
        }
    }

    /// The three shake channels' vote states, as the firmware holds them.
    public struct Votes: Sendable, Equatable {
        public var accelerometer: Bool
        public var tilt: Bool
        public var sound: Bool

        public init(accelerometer: Bool, tilt: Bool, sound: Bool) {
            self.accelerometer = accelerometer
            self.tilt = tilt
            self.sound = sound
        }

        public var count: Int {
            (accelerometer ? 1 : 0) + (tilt ? 1 : 0) + (sound ? 1 : 0)
        }

        /// Two of three, which is the firmware's `VOTES_REQUIRED`.
        public static let required = 2
        public var isDeclared: Bool { count >= Self.required }

        /// The sentence that makes false-alarm rejection watchable.
        ///
        /// "1 of 3 — not declared" is the most informative thing this app can
        /// show during a demonstration, because it is the moment somebody
        /// understands why a single sensor is not enough.
        public var summary: String {
            switch count {
            case 0: "No channel is voting"
            case Self.required...: "\(count) of 3 — event declared"
            default: "\(count) of 3 — not declared"
            }
        }
    }

    public struct Telemetry: Sendable, Equatable {
        public var state: NodeState
        /// The STA/LTA trigger ratio. At rest it sits near 1.
        public var ratio: Double
        public var temperatureCelsius: Double
        public var soundLevel: Int
        public var photoresistor: Int
        public var isTilted: Bool
        public var isOccupied: Bool
        public var votes: Votes
        /// The node's own baseline period, seconds. Zero before calibration.
        public var baselinePeriod: Double
        /// The trigger threshold currently in force, so a tuning control can
        /// confirm what the node accepted rather than what was sent to it.
        public var triggerThreshold: Double

        public init(state: NodeState, ratio: Double, temperatureCelsius: Double,
                    soundLevel: Int, photoresistor: Int, isTilted: Bool,
                    isOccupied: Bool, votes: Votes,
                    baselinePeriod: Double = 0, triggerThreshold: Double = 4) {
            self.state = state
            self.ratio = ratio
            self.temperatureCelsius = temperatureCelsius
            self.soundLevel = soundLevel
            self.photoresistor = photoresistor
            self.isTilted = isTilted
            self.isOccupied = isOccupied
            self.votes = votes
            self.baselinePeriod = baselinePeriod
            self.triggerThreshold = triggerThreshold
        }

        /// The thermistor reports −99 when the divider reads a rail, which
        /// means the sensor is open or shorted rather than that the room is
        /// very cold.
        public var isTemperatureValid: Bool { temperatureCelsius > -50 }
    }

    public struct Assessment: Sendable, Equatable {
        /// Structural period before and after the event, seconds.
        public var periodBefore: Double
        public var periodAfter: Double
        /// Percentage change. Positive means longer, which means softer.
        public var periodChangePercent: Double
        /// Peak ground acceleration, g.
        public var peakGroundAcceleration: Double
        public var hasPermanentTilt: Bool
        public var powerCutConfirmed: Bool
        public var verdict: SafetyVerdict

        public init(periodBefore: Double, periodAfter: Double,
                    periodChangePercent: Double, peakGroundAcceleration: Double,
                    hasPermanentTilt: Bool, powerCutConfirmed: Bool,
                    verdict: SafetyVerdict) {
            self.periodBefore = periodBefore
            self.periodAfter = periodAfter
            self.periodChangePercent = periodChangePercent
            self.peakGroundAcceleration = peakGroundAcceleration
            self.hasPermanentTilt = hasPermanentTilt
            self.powerCutConfirmed = powerCutConfirmed
            self.verdict = verdict
        }
    }

    // MARK: Parsing

    /// Turns one line from the node into a message.
    ///
    /// Returns nil only for a line that is not JSON at all — a fragment of a
    /// previous line, or the firmware's `Serial.println` debug echo arriving on
    /// the same wire. Anything that parses becomes a message even when its type
    /// is unknown, because an unknown type is information and a dropped line
    /// is not.
    public static func parse(line: String) -> Message? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["t"] as? String else { return nil }

        func int(_ key: String, _ fallback: Int = 0) -> Int {
            if let value = object[key] as? Int { return value }
            if let value = object[key] as? Double { return Int(value) }
            if let value = object[key] as? String { return Int(value) ?? fallback }
            return fallback
        }
        func bool(_ key: String) -> Bool { int(key) != 0 }

        switch type {
        case "boot":
            // Absent `mpu` is treated as present: an older firmware that does
            // not report it should not look like a broken accelerometer.
            return .boot(hasAccelerometer: object["mpu"] == nil || bool("mpu"))

        case "tel":
            return .telemetry(Telemetry(
                state: NodeState(rawValue: int("st")) ?? .boot,
                ratio: Double(int("ratio", 100)) / 100,
                temperatureCelsius: Double(int("tmp")) / 10,
                soundLevel: int("snd"),
                photoresistor: int("pho"),
                isTilted: bool("tilt"),
                isOccupied: bool("occ"),
                votes: Votes(accelerometer: bool("va"), tilt: bool("vt"), sound: bool("vs")),
                baselinePeriod: Double(int("pb")) / 1000,
                triggerThreshold: Double(int("thr", 40)) / 10))

        case "acc":
            return .acceleration(deviation: int("v"), ratio: Double(int("r", 100)) / 100)

        case "trig":
            return .triggered(
                ratio: Double(int("ratio", 100)) / 100,
                votes: Votes(accelerometer: bool("va"), tilt: bool("vt"), sound: bool("vs")),
                isDrill: bool("drill"))

        case "count":
            return .countdown(secondsRemaining: int("s"))

        case "phase":
            guard let raw = object["p"] as? String else { return nil }
            guard let phase = Phase(rawValue: raw) else {
                return .unrecognised(type: "phase:\(raw)", raw: trimmed)
            }
            return .phase(phase)

        case "act":
            guard let raw = object["dev"] as? String,
                  let device = Actuator(rawValue: raw) else {
                return .unrecognised(type: "act", raw: trimmed)
            }
            return .actuator(device: device,
                             state: ActuatorState(rawValue: int("st")) ?? .idle)

        case "verify":
            guard let raw = object["dev"] as? String,
                  let device = Actuator(rawValue: raw) else {
                return .unrecognised(type: "verify", raw: trimmed)
            }
            return .verification(device: device, before: int("before"),
                                 after: int("after"), confirmed: bool("ok"))

        case "recbegin":
            return .recordingBegan(sampleCount: int("n"),
                                   sampleRate: Double(int("hz", 50)))

        case "rec":
            let samples = (object["d"] as? [Any])?.compactMap { value -> Int? in
                if let v = value as? Int { return v }
                if let v = value as? Double { return Int(v) }
                return nil
            } ?? []
            return .recordingChunk(index: int("c"), samples: samples, checksum: int("sum"))

        case "recend":
            return .recordingEnded

        case "assess":
            let letter = (object["verdict"] as? String)?.uppercased() ?? "G"
            return .assessment(Assessment(
                periodBefore: Double(int("pb")) / 1000,
                periodAfter: Double(int("pa")) / 1000,
                periodChangePercent: Double(int("pct")) / 10,
                peakGroundAcceleration: Double(int("pga")) / 1000,
                hasPermanentTilt: bool("tiltp"),
                powerCutConfirmed: bool("pwr"),
                verdict: verdict(from: letter)))

        case "cal":
            return .calibrated(gravity: int("grav"), soundBaseline: int("snd"),
                               periodMilliseconds: int("per"))

        case "note":
            return .note((object["m"] as? String) ?? "")

        case "err":
            return .error((object["m"] as? String) ?? "")

        case "ack":
            return .acknowledged(command: (object["c"] as? String) ?? "")

        default:
            return .unrecognised(type: type, raw: trimmed)
        }
    }

    /// G, A, R as the firmware sends them.
    ///
    /// Anything else maps to "needs inspection" rather than to green. A letter
    /// nobody recognises is a reason for a human to look, not a reason to
    /// assume the best.
    static func verdict(from letter: String) -> SafetyVerdict {
        switch letter {
        case "G": .green
        case "A": .amber
        case "R": .red
        default: .needsInspection
        }
    }

    // MARK: Commands

    /// Everything the app can ask the node to do.
    public enum Command: Sendable, Equatable, Hashable {
        case drill
        case arm
        case disarm
        case calibrate
        case reset
        case resendRecording
        /// Re-send one chunk by index.
        ///
        /// The firmware originally had no way to ask for a single chunk, so a
        /// dropped notification meant re-requesting all twenty-five — three
        /// seconds of airtime to recover twenty samples, with a fair chance of
        /// losing a different chunk on the way. `REC:n` costs twelve
        /// milliseconds.
        case resendChunk(Int)
        case status
        case power(on: Bool)
        case water(closed: Bool)
        case beep
        /// Trigger ratio. Sent as ×10.
        case triggerThreshold(Double)
        case stepCount(Int)
        /// Stepper delay, microseconds.
        case stepDelay(Int)
        case photoThreshold(Int)
        case stepperEnabled(Bool)

        /// The exact bytes the firmware's `handleCommand` compares against.
        ///
        /// It upper-cases the whole line before matching, so case does not
        /// matter on the wire — but it is written the way the firmware's own
        /// string literals are, because that is what somebody will grep for
        /// when the two disagree.
        public var wire: String {
            switch self {
            case .drill: "DRILL"
            case .arm: "ARM"
            case .disarm: "DISARM"
            case .calibrate: "CAL"
            case .reset: "RESET"
            case .resendRecording: "SEND"
            case .resendChunk(let index): "REC:\(index)"
            case .status: "STATUS"
            case .power(let on): on ? "PWR:0" : "PWR:1"
            case .water(let closed): closed ? "WTR:1" : "WTR:0"
            case .beep: "BEEP"
            case .triggerThreshold(let value): "THR:\(Int((value * 10).rounded()))"
            case .stepCount(let value): "STEP:\(value)"
            case .stepDelay(let value): "SPD:\(value)"
            case .photoThreshold(let value): "PHO:\(value)"
            case .stepperEnabled(let on): on ? "YESTEP" : "NOSTEP"
            }
        }

        /// The bytes to write, including the terminator the firmware's line
        /// reader is waiting for.
        public var payload: Data { Data((wire + "\n").utf8) }

        /// Whether this command moves a motor.
        ///
        /// The USB budget allows one at a time. `power` is included because the
        /// firmware's `powerCut` holds a two-hundred-millisecond delay and then
        /// beeps, and issuing a stepper move across that window is exactly the
        /// overlap the eight-hundred-millisecond gap exists to prevent.
        public var movesMotor: Bool {
            switch self {
            case .water: true
            case .power: true
            case .drill, .reset, .calibrate: true    // these actuate internally
            default: false
            }
        }

        /// Whether the firmware answers with an `ack`.
        ///
        /// Not all of them do, and a control that waits for one that will never
        /// arrive is a control stuck on "sending" for ever. `STATUS` replies
        /// with telemetry; the tuning commands reply with telemetry too. Both
        /// are confirmations — they are simply not acks, and the difference has
        /// to be modelled rather than hoped about.
        public var expectsAcknowledgement: Bool {
            switch self {
            case .status, .triggerThreshold, .stepCount, .stepDelay, .photoThreshold: false
            default: true
            }
        }

        /// What an ack for this command looks like, so a reply can be matched
        /// to the control that is waiting for it.
        ///
        /// Usually the wire form, because the firmware echoes the command it
        /// received. `REC:n` is the exception: it acknowledges with the bare
        /// word, since acking a different string per chunk would mean the app
        /// tracking twenty-five separate in-flight commands to recover one
        /// recording.
        public var acknowledgementToken: String {
            if case .resendChunk = self { return "REC" }
            return wire
        }
    }
}
