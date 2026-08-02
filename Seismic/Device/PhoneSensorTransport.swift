import Foundation
import SeismicCore
import SeismicDevice
import SeismicSignal
#if canImport(CoreMotion)
import CoreMotion
#endif
#if canImport(UIKit)
import UIKit
#endif

/// The phone itself, as a node.
///
/// A modern phone contains a three-axis accelerometer good to roughly a
/// milli-g, which is enough to see a building sway and far more than enough to
/// see an earthquake. So the hardware is optional: leave the phone face down on
/// a shelf and it does the same job as the node, less well.
///
/// **Less well is the important part, and it is not marketing softness.** A
/// wired node is bolted to the structure, samples on a crystal, has a
/// thermometer against the concrete, and has actuators. A phone is resting on
/// furniture that has its own resonance, timestamps on a clock the OS is free
/// to adjust, cannot tell you the structure's temperature — which is the whole
/// basis of the temperature correction — and cannot close your gas valve. The
/// interface says so plainly wherever the choice is offered.
///
/// It implements `NodeTransport`, which is the entire trick: the monitor, the
/// detector, the period measurement, the event recorder and the assessment all
/// talk to `NodeSession` and cannot tell what is underneath it. Nothing else in
/// the app changed to support this.
final class PhoneSensorTransport: NodeTransport, @unchecked Sendable {

    let identifier = "phone-motion"
    var displayName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return "This phone"
        #endif
    }
    /// False, and that matters: this is real measured motion, so nothing in the
    /// app marks it as synthetic and no verdict derived from it carries the
    /// simulated caveat.
    let isSimulated = false

    var eventHandler: (@Sendable (NodeEvent) -> Void)?

    /// What a phone genuinely does not have.
    ///
    /// Declared rather than faked. The diagnostics screen already knows how to
    /// show a missing sensor, so the honest answer costs nothing and the
    /// dishonest one would have quietly poisoned the temperature correction.
    static let absentSensors: [SensorChannel] = [
        .thermistorStructure, .thermistorBoard, .ultrasonic, .waterLevel,
        .photoresistorGrid, .photoresistorRelay, .pir, .rfid,
    ]

    // MARK: State

    private let lock = NSLock()
    private let config: STALTAConfig
    private let sampleRate: Double

    #if canImport(CoreMotion)
    private let motion = CMMotionManager()
    private let queue = OperationQueue()
    #endif

    /// Samples that have arrived from CoreMotion but not yet been emitted.
    private var pendingX: [Double] = []
    private var pendingY: [Double] = []
    private var pendingZ: [Double] = []

    /// A few seconds of history kept at all times, so a recording can begin
    /// *before* the trigger. The onset is the most informative part of an
    /// earthquake record and it is always already over by the time anything
    /// has decided an earthquake is happening.
    private var preRollX: [Double] = []
    private var preRollY: [Double] = []
    private var preRollZ: [Double] = []
    private var preRollCapacity: Int { Int(sampleRate * 5) }

    private var recorded: (x: [Double], y: [Double], z: [Double]) = ([], [], [])
    private var isRecording = false
    private var recordingStart: Date?
    private var secondsBelowDetrigger: Double = 0

    private var detector = STALTA.RecursiveState()
    private var detectorSeeded = false
    private var latestRatio: Double = 1
    private var ambientRMS: Double = 0

    private var sequence: UInt16 = 0
    private var nodeState: NodeState = .offline
    private var connection: ConnectionState = .disconnected

    /// The gravity direction when the baseline was taken. A change in it is a
    /// real tilt measurement — provided the phone has not been picked up, which
    /// is exactly what `hasMoved` is for.
    private var tiltBaseline: (x: Double, y: Double, z: Double)?
    private var tiltAngle: Double = 0
    private var hasBeenPickedUp = false

    private var failureReason: String?

    init(trigger: STALTAConfig = .conservative, sampleRate: Double = 100) {
        self.config = trigger
        self.sampleRate = sampleRate
        #if canImport(CoreMotion)
        queue.name = "seismic.phone-motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        #endif
    }

    // MARK: Lifecycle

    /// Whether this device can be used as a sensor at all.
    static var isAvailable: Bool {
        #if canImport(CoreMotion)
        return CMMotionManager().isDeviceMotionAvailable
        #else
        return false
        #endif
    }

    func startScanning() {
        // There is nothing to scan for — the sensor is already in your hand.
        // Reported as a discovery anyway so the scanner sheet lists it beside
        // any real hardware, and the choice is made in one place.
        emit(.discovered(DiscoveredNode(id: identifier, name: displayName,
                                        rssi: 0, batteryPercent: batteryPercent,
                                        isSimulated: false)))
    }

    func stopScanning() {}

    func connect(to nodeID: String) {
        #if canImport(CoreMotion)
        guard motion.isDeviceMotionAvailable else {
            failureReason = "This device has no motion sensor available to the app."
            set(connection: .disconnected)
            emit(.log(failureReason!))
            return
        }

        motion.deviceMotionUpdateInterval = 1 / sampleRate
        // `.xArbitraryZVertical` puts Z along true vertical regardless of how
        // the phone is lying, which is what every downstream algorithm assumes
        // — the P-wave picker reads the vertical channel specifically. Without
        // this, a phone flat on a table and a phone stood on edge would produce
        // incompatible records.
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) {
            [weak self] data, error in
            guard let self else { return }
            if let error {
                self.failureReason = error.localizedDescription
                return
            }
            guard let data else { return }
            self.accept(data)
        }

        set(connection: .connected(rssi: 0))
        lock.lock(); nodeState = .monitoring; lock.unlock()
        emit(.log("Using this phone's accelerometer. Leave it resting on a hard, "
                  + "flat surface — a phone in a pocket measures the pocket."))
        #else
        set(connection: .disconnected)
        #endif
    }

    func disconnect() {
        #if canImport(CoreMotion)
        motion.stopDeviceMotionUpdates()
        #endif
        lock.lock()
        nodeState = .offline
        detectorSeeded = false
        isRecording = false
        recorded = ([], [], [])
        lock.unlock()
        set(connection: .disconnected)
    }

    // MARK: Sampling

    #if canImport(CoreMotion)
    /// Called on the motion queue, up to a hundred times a second. Does as
    /// little as possible: everything else happens on the display tick.
    private func accept(_ data: CMDeviceMotion) {
        // userAcceleration excludes gravity and is reported in g.
        let x = data.userAcceleration.x * gravity
        let y = data.userAcceleration.y * gravity
        let z = data.userAcceleration.z * gravity

        lock.lock()
        pendingX.append(x); pendingY.append(y); pendingZ.append(z)

        // Tilt, from where gravity is pointing relative to where it pointed when
        // the baseline was taken. Only meaningful while the phone stays put, so
        // a large sustained change is treated as "somebody moved it" rather than
        // as the building leaning over.
        let g = (data.gravity.x, data.gravity.y, data.gravity.z)
        if let base = tiltBaseline {
            let dot = base.x * g.0 + base.y * g.1 + base.z * g.2
            let angle = acos(min(max(dot, -1), 1)) * 180 / .pi
            tiltAngle = angle
            if angle > 25 { hasBeenPickedUp = true }
        } else {
            tiltBaseline = g
        }
        lock.unlock()
    }
    #endif

    /// Drains what has arrived, runs the detector, and emits. Driven by the
    /// app's existing display tick, so phone data arrives in step with
    /// everything else exactly as the simulated node's does.
    func tick(deltaTime: TimeInterval) {
        lock.lock()
        guard !pendingX.isEmpty else {
            let state = nodeState
            lock.unlock()
            if state != .offline { emit(.telemetry(currentTelemetry())) }
            return
        }

        let x = pendingX, y = pendingY, z = pendingZ
        pendingX.removeAll(keepingCapacity: true)
        pendingY.removeAll(keepingCapacity: true)
        pendingZ.removeAll(keepingCapacity: true)

        sequence = sequence &+ 1
        let batch = HighRateBatch(sequence: sequence, sampleRate: sampleRate, x: x, y: y, z: z)

        // The same recursive detector the firmware runs and the simulated node
        // runs. Deliberately not a second implementation: if the phone decided
        // an earthquake had started on different evidence from the node, two
        // sources in the same building could disagree for no physical reason.
        let alphaShort = 1 - exp(-1 / (config.shortWindow * sampleRate))
        let alphaLong = 1 - exp(-1 / (config.longWindow * sampleRate))
        var triggeredNow = false
        var sumSquares = 0.0

        for i in 0..<x.count {
            let magnitude = (x[i] * x[i] + y[i] * y[i] + z[i] * z[i]).squareRoot()
            sumSquares += magnitude * magnitude

            if !detectorSeeded {
                detector = STALTA.RecursiveState(sta: magnitude, lta: max(magnitude, 1e-6))
                detectorSeeded = true
                continue
            }
            detector.update(magnitude, alphaShort: alphaShort, alphaLong: alphaLong)
            latestRatio = detector.ratio
            if !isRecording, latestRatio >= config.triggerThreshold { triggeredNow = true }
        }
        ambientRMS = (sumSquares / Double(max(x.count, 1))).squareRoot()

        appendPreRoll(x: x, y: y, z: z)
        if isRecording { appendRecording(x: x, y: y, z: z) }

        let ratio = latestRatio
        let recording = isRecording
        lock.unlock()

        emit(.highRate(batch))
        emit(.telemetry(currentTelemetry()))

        if triggeredNow {
            beginRecording(ratio: ratio)
        } else if recording {
            advanceRecording(ratio: ratio, deltaTime: deltaTime)
        }
    }

    private func appendPreRoll(x: [Double], y: [Double], z: [Double]) {
        preRollX.append(contentsOf: x)
        preRollY.append(contentsOf: y)
        preRollZ.append(contentsOf: z)
        let capacity = preRollCapacity
        if preRollX.count > capacity {
            preRollX.removeFirst(preRollX.count - capacity)
            preRollY.removeFirst(preRollY.count - capacity)
            preRollZ.removeFirst(preRollZ.count - capacity)
        }
    }

    private func appendRecording(x: [Double], y: [Double], z: [Double]) {
        recorded.x.append(contentsOf: x)
        recorded.y.append(contentsOf: y)
        recorded.z.append(contentsOf: z)
    }

    // MARK: Events

    private func beginRecording(ratio: Double) {
        lock.lock()
        guard !isRecording else { lock.unlock(); return }
        isRecording = true
        nodeState = .triggered
        secondsBelowDetrigger = 0
        // The recording opens with the pre-roll, so the onset is in it.
        recorded = (preRollX, preRollY, preRollZ)
        recordingStart = Date().addingTimeInterval(-Double(preRollX.count) / sampleRate)
        let threshold = config.triggerThreshold
        lock.unlock()

        emit(.triggered(ratio: ratio, channel: .accelerometer, at: Date()))

        // A phone has one sensor, so it can only cast one meaningful vote. The
        // other two are reported as abstentions rather than invented agreement:
        // that is precisely why a trigger from a phone is worth less than a
        // trigger from a node, and the fusion vote should feel that.
        let votes = [
            SensorVote(channel: .accelerometer, agreed: ratio >= threshold, value: ratio),
            SensorVote(channel: .tiltSwitch, agreed: false, value: 0),
            SensorVote(channel: .soundSensor, agreed: false, value: 0),
        ]
        for vote in votes { emit(.sensorVote(vote)) }
        emit(.log("Trigger at ratio \(String(format: "%.1f", ratio)) on this phone's "
                  + "accelerometer. One sensor agreeing is weaker corroboration than a "
                  + "node's three."))

        lock.lock(); nodeState = .recording; lock.unlock()
    }

    private func advanceRecording(ratio: Double, deltaTime: TimeInterval) {
        lock.lock()
        if ratio <= config.detriggerThreshold {
            secondsBelowDetrigger += deltaTime
        } else {
            secondsBelowDetrigger = 0
        }
        let elapsed = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
        // Ends five quiet seconds after the shaking stops, or at ninety seconds
        // whatever happens — a detector stuck on would otherwise record until
        // the phone ran out of memory.
        let shouldFinish = secondsBelowDetrigger >= 5 || elapsed > 90
        guard shouldFinish else { lock.unlock(); return }

        isRecording = false
        nodeState = .assessing
        let rate = sampleRate
        let start = recordingStart ?? Date()
        let record = TriaxialRecord(
            x: Waveform(samples: recorded.x, sampleRate: rate, startTime: start),
            y: Waveform(samples: recorded.y, sampleRate: rate, startTime: start),
            z: Waveform(samples: recorded.z, sampleRate: rate, startTime: start))
        recorded = ([], [], [])
        recordingStart = nil
        lock.unlock()

        emit(.log("Event captured: \(record.count) samples, peak "
                  + "\(String(format: "%.3f", record.magnitude.peakAbsolute / gravity)) g."))

        // Split and delivered through the same chunked path a radio link uses.
        // There is no radio here and it would be faster to hand the record over
        // directly — but then this would be the one source whose transfers
        // could not be interrupted, resumed or corrupted, and the code that
        // handles all three would never run against it.
        let (manifest, chunks) = ChunkSplitter.split(record, eventID: UUID())
        emit(.recordingManifest(manifest))
        for chunk in chunks { emit(.recordingChunk(chunk)) }

        lock.lock(); nodeState = .monitoring; lock.unlock()
    }

    // MARK: Commands

    func send(_ command: NodeCommand) {
        switch command {
        case .calibrateBaseline:
            lock.lock()
            detectorSeeded = false
            tiltBaseline = nil
            tiltAngle = 0
            hasBeenPickedUp = false
            lock.unlock()
            emit(.log("Baseline re-taken. Keep the phone still for a few seconds."))

        case .selfTest:
            emit(.selfTestResult(selfTest()))

        case .fireActuator(let kind), .resetActuator(let kind):
            // Not a failure — a phone was never wired to anything. Reported as
            // unknown rather than failed so the actuator console does not fill
            // with red for a capability that was never claimed.
            emit(.actuatorReport(ActuatorReport(
                kind: kind, state: .unknown,
                failureReason: "This phone is not wired to anything. Only a node can "
                    + "close a gas valve.")))

        case .drill:
            emit(.log("Drill acknowledged. The warning sequence runs, but nothing physical "
                      + "moves — a phone has no actuators."))

        case .setSensitivity, .requestPeriodMeasurement, .syncClock,
             .acknowledgeEvent, .abort, .requestRecording:
            break

        case .setLED, .buzz, .playTone, .setMatrixText, .setSevenSegment,
             .setFloorStressPattern, .setShakeTableSpeed:
            break
        }
    }

    private func selfTest() -> SelfTestResult {
        lock.lock()
        let seeded = detectorSeeded
        let picked = hasBeenPickedUp
        let rms = ambientRMS
        let reason = failureReason
        lock.unlock()

        #if canImport(CoreMotion)
        let available = motion.isDeviceMotionAvailable
        let running = motion.isDeviceMotionActive
        #else
        let available = false, running = false
        #endif

        return SelfTestResult(checks: [
            .init(name: "Motion sensor", passed: available,
                  detail: available ? "Device motion is available at \(Int(sampleRate)) Hz."
                                    : (reason ?? "No motion sensor is available to the app.")),
            .init(name: "Streaming", passed: running,
                  detail: running ? "Samples are arriving." : "Not currently sampling."),
            .init(name: "Noise floor", passed: seeded,
                  detail: seeded
                      ? "Baseline established at \(String(format: "%.4f", rms)) m/s²."
                      : "Still settling. Leave the phone still for a few seconds."),
            .init(name: "Phone left in place", passed: !picked,
                  detail: picked
                      ? "The phone has been moved since the baseline was taken, so tilt "
                        + "readings mean nothing until it is re-calibrated."
                      : "The phone has not been picked up since calibration."),
            // Stated as a failing check on purpose. It is the honest headline
            // difference between this and a node, and burying it in help text
            // is how somebody ends up trusting a temperature correction that
            // was never made.
            .init(name: "Structure temperature", passed: false,
                  detail: "A phone has no thermometer against the structure, so the "
                      + "temperature correction cannot be applied. Period changes measured "
                      + "this way carry the seasonal effect with them."),
        ])
    }

    // MARK: Telemetry

    private var batteryPercent: Double? {
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : Double(level) * 100
        #else
        return nil
        #endif
    }

    private func currentTelemetry() -> NodeTelemetry {
        lock.lock()
        let state = nodeState
        let ratio = latestRatio
        let rms = ambientRMS
        let tilt = tiltAngle
        let moved = hasBeenPickedUp
        lock.unlock()

        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let plugged = UIDevice.current.batteryState == .charging
                   || UIDevice.current.batteryState == .full
        #else
        let plugged = false
        #endif

        return NodeTelemetry(
            state: state,
            ambientVibrationRMS: rms,
            staLtaRatio: ratio,
            batteryPercent: batteryPercent,
            usbPowered: plugged,
            // Not measurable on a phone, and reported as zero rather than as a
            // plausible five volts. The Home screen shows battery here instead
            // when the phone is the source; a fabricated rail voltage would
            // have looked exactly like a real one.
            supplyVoltage: 0,
            activeCurrentDraw_mA: 0,
            gridPowerPresent: plugged,
            permanentTilt: !moved && tilt > 0.4,
            tiltAngle: moved ? 0 : tilt,
            // A phone cannot measure where the building came to rest: that
            // needs double integration of a signal whose drift swamps the
            // answer. Left at zero, and the assessment weighs it accordingly.
            residualDisplacement: 0,
            faults: moved ? [.calibrationInvalid] : [],
            disconnectedSensors: Self.absentSensors)
    }

    // MARK: Plumbing

    private func set(connection state: ConnectionState) {
        lock.lock(); connection = state; lock.unlock()
        emit(.connectionChanged(state))
    }

    private func emit(_ event: NodeEvent) { eventHandler?(event) }
}
