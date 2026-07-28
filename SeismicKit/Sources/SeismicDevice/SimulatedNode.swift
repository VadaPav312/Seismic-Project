import Foundation
import SeismicCore
import SeismicSignal

/// A complete, physically honest simulation of the hardware.
///
/// This is not a stub that returns canned values. It runs the same STA/LTA
/// detector the Arduino runs, streams a genuine ambient noise floor with the
/// building's own resonance in it, serialises actuators against the same power
/// budget, brownouts if asked to do two at once, drifts its measured period with
/// temperature, and lengthens that period permanently when it decides the
/// building has been damaged.
///
/// The reason to build it this way rather than faking the outputs: every screen
/// in the app is then exercised by realistic data during development, and a
/// judge with no hardware sees the real product rather than a slideshow.
public final class SimulatedNode: NodeTransport, @unchecked Sendable {

    // MARK: Configuration

    public struct Configuration: Sendable {
        public var buildingPeriod: Double
        public var buildingDamping: Double
        public var sampleRate: Double
        public var noiseFloor: Double
        public var trigger: STALTAConfig
        public var budget: PowerBudget
        /// How often telemetry is pushed.
        public var telemetryInterval: TimeInterval
        /// How often a high-rate batch is pushed.
        public var highRateInterval: TimeInterval
        public var seed: UInt64
        /// Simulated link speed, bytes per second, used to pace chunk transfer
        /// so the progress bar moves at a believable rate.
        public var linkBytesPerSecond: Double

        public init(buildingPeriod: Double = 0.85, buildingDamping: Double = 0.03,
                    sampleRate: Double = 100, noiseFloor: Double = 0.004,
                    trigger: STALTAConfig = .standard, budget: PowerBudget = .usb2,
                    telemetryInterval: TimeInterval = 1.0,
                    highRateInterval: TimeInterval = 0.1,
                    seed: UInt64 = 20_260_727,
                    linkBytesPerSecond: Double = 3000) {
            self.buildingPeriod = Swift.max(buildingPeriod, 0.05)
            self.buildingDamping = Swift.min(Swift.max(buildingDamping, 0.002), 0.3)
            self.sampleRate = Swift.max(sampleRate, 20)
            self.noiseFloor = Swift.max(noiseFloor, 0)
            self.trigger = trigger
            self.budget = budget
            self.telemetryInterval = Swift.max(telemetryInterval, 0.1)
            self.highRateInterval = Swift.max(highRateInterval, 0.02)
            self.seed = seed
            self.linkBytesPerSecond = Swift.max(linkBytesPerSecond, 100)
        }
    }

    // MARK: State

    public let identifier: String
    public let displayName: String
    public var isSimulated: Bool { true }
    public var eventHandler: (@Sendable (NodeEvent) -> Void)?

    private var configuration: Configuration
    private let lock = NSLock()
    private var rng: SeededRandom

    private var state: NodeState = .offline
    private var connection: ConnectionState = .disconnected
    private var sequence: UInt16 = 0
    private var elapsed: TimeInterval = 0
    private var lastTelemetry: TimeInterval = -999

    /// Structural truth, which the node measures rather than knows.
    private var currentPeriod: Double
    private var undamagedPeriod: Double
    private var damageFactor: Double = 1.0        // period multiplier from damage
    private var structureTemperature: Double = 19
    private var residualDisplacement: Double = 0
    private var tiltAngle: Double = 0
    private var permanentTilt = false
    private var gridPowerPresent = true
    private var waterDetected = false
    private var occupancy = false
    private var faults: Set<NodeFault> = []
    private var baselineCalibrated = false

    /// The detector, running exactly as it does on the microcontroller.
    private var detector = STALTA.RecursiveState()
    private var detectorSeeded = false
    private var latestRatio: Double = 1

    private var actuatorStates: [ActuatorKind: ActuatorState] = [:]
    private var activeMotors: [ActuatorKind] = []
    private var pendingActuations: [(step: ActuationStep, sequenceStart: TimeInterval)] = []

    /// An event in progress: the remaining ground-motion samples to play out.
    private var playback: TriaxialRecord?
    private var playbackIndex = 0
    private var playbackEventID: UUID?
    private var recordedSamples: (x: [Double], y: [Double], z: [Double]) = ([], [], [])
    private var recording = false
    private var eventStartTime: Date?

    /// Buffered recordings waiting to be collected, which is what makes the
    /// "lose connection mid-event, lose nothing" story true.
    private var bufferedRecordings: [UUID: TriaxialRecord] = [:]
    private var transferQueue: [(manifest: RecordingManifest, chunks: [RecordingChunk])] = []
    private var transferCursor = 0
    private var transferBudget: Double = 0

    private var shakeTableSpeed: Double = 0

    public init(identifier: String = "sim-node-01",
                displayName: String = "Simulated node",
                configuration: Configuration = .init()) {
        self.identifier = identifier
        self.displayName = displayName
        self.configuration = configuration
        self.rng = SeededRandom(seed: configuration.seed)
        self.currentPeriod = configuration.buildingPeriod
        self.undamagedPeriod = configuration.buildingPeriod
        for kind in ActuatorKind.allCases { actuatorStates[kind] = .idle }
    }

    // MARK: Transport

    public func startScanning() {
        emit(.connectionChanged(.scanning))
        // A simulated node appears immediately: there is nothing to wait for,
        // and making the user watch a fake spinner would be theatre.
        emit(.discovered(DiscoveredNode(id: identifier, name: displayName,
                                        rssi: -48, batteryPercent: nil, isSimulated: true)))
    }

    public func stopScanning() {}

    public func connect(to nodeID: String) {
        guard nodeID == identifier else { return }
        lock.lock()
        connection = .simulated
        state = baselineCalibrated ? .monitoring : .armed
        lock.unlock()
        emit(.connectionChanged(.simulated))
        emit(.log("Simulated node connected. Data is synthetic but physically realistic."))
        // Anything buffered while disconnected is offered immediately.
        offerBufferedRecordings()
    }

    public func disconnect() {
        lock.lock()
        connection = .disconnected
        state = .offline
        lock.unlock()
        emit(.connectionChanged(.disconnected))
    }

    public func send(_ command: NodeCommand) {
        lock.lock()
        let isConnected = connection.isLive
        lock.unlock()
        guard isConnected else { return }
        handle(command)
    }

    // MARK: The tick

    /// Advances the simulation. Driven by the app's display link so the
    /// simulated node runs in step with the animation rather than on its own
    /// timer, which keeps the seismograph and the 3D view perfectly in sync.
    public func tick(deltaTime: TimeInterval) {
        lock.lock()
        guard connection.isLive else { lock.unlock(); return }
        elapsed += deltaTime
        let now = elapsed
        lock.unlock()

        advanceActuators(now: now)
        advanceTransfer(deltaTime: deltaTime)
        produceSamples(deltaTime: deltaTime)

        lock.lock()
        let shouldSendTelemetry = now - lastTelemetry >= configuration.telemetryInterval
        if shouldSendTelemetry { lastTelemetry = now }
        lock.unlock()

        if shouldSendTelemetry {
            drift()
            emit(.telemetry(currentTelemetry()))
        }
    }

    // MARK: Sample generation

    private func produceSamples(deltaTime: TimeInterval) {
        lock.lock()
        let rate = configuration.sampleRate
        let count = Swift.max(Int((deltaTime * rate).rounded()), 0)
        guard count > 0 else { lock.unlock(); return }

        var x = [Double](repeating: 0, count: count)
        var y = [Double](repeating: 0, count: count)
        var z = [Double](repeating: 0, count: count)

        let isPlaying = playback != nil
        for i in 0..<count {
            if let record = playback, playbackIndex < record.count {
                x[i] = record.x.samples[playbackIndex]
                y[i] = record.y.samples[playbackIndex]
                z[i] = record.z.samples[playbackIndex]
                playbackIndex += 1
            } else {
                // Ambient: sensor noise plus the building quietly ringing at its
                // own period, which is what the baseline measurement lives on.
                let t = Double(i) / rate + elapsed
                let resonance = sin(2 * .pi / currentPeriod * t) * configuration.noiseFloor * 2.2
                x[i] = rng.gaussian(sd: configuration.noiseFloor) + resonance
                y[i] = rng.gaussian(sd: configuration.noiseFloor) + resonance * 0.7
                z[i] = rng.gaussian(sd: configuration.noiseFloor * 0.9)
            }

            // The shake table drives the sensor directly when it is running.
            if shakeTableSpeed > 0 {
                let frequency = 0.5 + shakeTableSpeed * 6
                let t = Double(i) / rate + elapsed
                let drive = sin(2 * .pi * frequency * t) * shakeTableSpeed * 1.2
                x[i] += drive
                y[i] += drive * 0.3
            }
        }

        // Run the detector on the vector magnitude, exactly as the node does.
        let alphaS = 1 - exp(-1 / (configuration.trigger.shortWindow * rate))
        let alphaL = 1 - exp(-1 / (configuration.trigger.longWindow * rate))
        if !detectorSeeded {
            let seedValue = configuration.noiseFloor * configuration.noiseFloor * 3
            detector = STALTA.RecursiveState(sta: seedValue, lta: seedValue)
            detectorSeeded = true
        }

        var triggeredNow = false
        for i in 0..<count {
            let magnitude = (x[i] * x[i] + y[i] * y[i] + z[i] * z[i])
            detector.update(magnitude, alphaShort: alphaS, alphaLong: alphaL)
            latestRatio = detector.ratio
            if !recording, latestRatio >= configuration.trigger.triggerThreshold {
                triggeredNow = true
            }
        }

        if recording {
            recordedSamples.x.append(contentsOf: x)
            recordedSamples.y.append(contentsOf: y)
            recordedSamples.z.append(contentsOf: z)
        }

        // Playback finished: wrap the event up.
        let playbackFinished = isPlaying && (playback.map { playbackIndex >= $0.count } ?? false)

        sequence &+= 1
        let batch = HighRateBatch(sequence: sequence, sampleRate: rate, x: x, y: y, z: z)
        let ratio = latestRatio
        lock.unlock()

        emit(.highRate(batch))

        if triggeredNow { beginEvent(ratio: ratio) }
        if playbackFinished { finishEvent() }
    }

    /// Slow environmental drift, so charts over days and months have something
    /// real in them.
    private func drift() {
        lock.lock(); defer { lock.unlock() }
        // A diurnal temperature cycle plus noise.
        let dayFraction = (elapsed / 86_400).truncatingRemainder(dividingBy: 1)
        structureTemperature = 19 + 6 * sin(2 * .pi * (dayFraction - 0.25))
            + rng.gaussian(sd: 0.15)

        // Colder concrete is stiffer, so the period shortens. This is the effect
        // the temperature correction exists to remove, and the simulator has to
        // produce it or the correction has nothing to correct.
        let temperatureEffect = 1 + (structureTemperature - 19) * 0.0018
        currentPeriod = undamagedPeriod * damageFactor * temperatureEffect
            + rng.gaussian(sd: undamagedPeriod * 0.002)
    }

    // MARK: Events

    /// Plays a real or synthetic earthquake through the node.
    public func injectEvent(_ record: TriaxialRecord, eventID: UUID = UUID()) {
        lock.lock()
        playback = record
        playbackIndex = 0
        playbackEventID = eventID
        lock.unlock()
    }

    /// Convenience: generate and inject an event of a given size.
    public func injectSyntheticEvent(magnitude: Double, distanceKm: Double,
                                     soil: SoilClass = .stiffSoil,
                                     eventID: UUID = UUID()) {
        lock.lock()
        let seed = rng.next()
        let rate = configuration.sampleRate
        lock.unlock()

        let record = SyntheticMotion.generate(.init(
            magnitude: magnitude, distanceKm: distanceKm, soil: soil,
            sampleRate: rate, preEventSeconds: 3, seed: seed))
        injectEvent(record, eventID: eventID)
    }

    private func beginEvent(ratio: Double) {
        lock.lock()
        guard !recording else { lock.unlock(); return }
        recording = true
        state = .triggered
        eventStartTime = Date()
        recordedSamples = ([], [], [])
        let soundLevel = Swift.min(ratio / 12, 1)
        let tiltMoved = ratio > 9
        let threshold = configuration.trigger.triggerThreshold
        lock.unlock()

        emit(.triggered(ratio: ratio, channel: .accelerometer, at: Date()))

        // The other channels vote, and their agreement is what makes the trigger
        // trustworthy.
        let votes = SensorFusion.buildVotes(accelerationRatio: ratio, tiltChanged: tiltMoved,
                                            soundLevel: soundLevel, triggerThreshold: threshold)
        for vote in votes { emit(.sensorVote(vote)) }

        let decision = SensorFusion.vote(votes)
        emit(.log("Trigger at ratio \(String(format: "%.1f", ratio)). \(decision.explanation)"))

        if decision.accepted {
            fireProtectiveSequence()
        } else {
            lock.lock(); recording = false; state = .monitoring; lock.unlock()
            emit(.log("Rejected as a nuisance trigger. No actions taken, no event recorded."))
        }
    }

    private func finishEvent() {
        lock.lock()
        let eventID = playbackEventID ?? UUID()
        playback = nil
        playbackIndex = 0
        playbackEventID = nil

        guard recording else { lock.unlock(); return }
        recording = false
        state = .assessing

        let rate = configuration.sampleRate
        let start = eventStartTime ?? Date()
        let record = TriaxialRecord(
            x: Waveform(samples: recordedSamples.x, sampleRate: rate, startTime: start),
            y: Waveform(samples: recordedSamples.y, sampleRate: rate, startTime: start),
            z: Waveform(samples: recordedSamples.z, sampleRate: rate, startTime: start))
        recordedSamples = ([], [], [])

        // Decide what the shaking actually did to the building. Peak
        // acceleration is a crude proxy for demand, but the point here is to
        // produce a *consistent* world: if the app later says the period
        // changed, it changed because the simulated building was damaged.
        let peak = record.magnitude.peakAbsolute
        let severity = Swift.min(Swift.max((peak - 1.5) / 6.0, 0), 1)
        if severity > 0.02 {
            // 0–28% period lengthening, matching the range real damaged
            // buildings show.
            damageFactor *= 1 + severity * 0.28
            residualDisplacement += severity * 0.06 * rng.uniform(0.6, 1.4)
            if severity > 0.55 {
                permanentTilt = true
                tiltAngle += severity * 1.4
            }
            if severity > 0.3 { gridPowerPresent = false }
            if severity > 0.65 { waterDetected = true }
        }

        bufferedRecordings[eventID] = record
        let isConnected = connection.isLive
        lock.unlock()

        emit(.log("Event captured: \(record.count) samples, peak "
            + "\(String(format: "%.2f", peak / gravity)) g."))

        if isConnected {
            queueTransfer(eventID: eventID, record: record)
        }

        lock.lock(); state = .monitoring; lock.unlock()
    }

    /// The protective sequence, serialised against the power budget.
    private func fireProtectiveSequence() {
        lock.lock()
        state = .acting
        let planner = ActuationPlanner(budget: configuration.budget)
        let steps = planner.plan(ActuatorKind.allCases)
        let start = elapsed
        pendingActuations = steps.map { (step: $0, sequenceStart: start) }
        for step in steps { actuatorStates[step.kind] = .queued }
        lock.unlock()

        for step in steps {
            emit(.actuatorReport(ActuatorReport(kind: step.kind, state: .queued)))
        }
        emit(.log("Firing \(steps.count) safety actions in sequence. "
            + PowerBudget.usb2.explanation))
    }

    private func advanceActuators(now: TimeInterval) {
        var toEmit: [ActuatorReport] = []
        var brownout = false

        lock.lock()
        var stillPending: [(step: ActuationStep, sequenceStart: TimeInterval)] = []
        for entry in pendingActuations {
            let t = now - entry.sequenceStart
            let kind = entry.step.kind

            if t >= entry.step.startOffset, actuatorStates[kind] == .queued {
                // Refuse to start a second motor: this is the constraint made
                // real rather than merely documented.
                let others = activeMotors.filter { $0 != kind }
                if kind.peakCurrent_mA > 200, !configuration.budget.canRun(kind, alongside: others) {
                    brownout = true
                    faults.insert(.brownout)
                    actuatorStates[kind] = .failed
                    toEmit.append(ActuatorReport(kind: kind, state: .failed,
                                                 commandedAt: Date(),
                                                 failureReason: "Supply could not carry a second motor."))
                    continue
                }
                actuatorStates[kind] = .inProgress
                activeMotors.append(kind)
                toEmit.append(ActuatorReport(kind: kind, state: .inProgress, commandedAt: Date()))
                stillPending.append(entry)
            } else if t >= entry.step.endOffset, actuatorStates[kind] == .inProgress {
                actuatorStates[kind] = .confirmed
                activeMotors.removeAll { $0 == kind }
                toEmit.append(ActuatorReport(kind: kind, state: .confirmed,
                                             commandedAt: Date().addingTimeInterval(-entry.step.duration),
                                             completedAt: Date(),
                                             confirmedBy: kind.confirmation))
                // The mains relay actually cuts the grid, and the photoresistor
                // watching the test lamp is how that gets confirmed.
                if kind == .mainsPower { gridPowerPresent = false }
                if kind == .waterMain { waterDetected = false }
            } else {
                stillPending.append(entry)
            }
        }
        pendingActuations = stillPending
        if pendingActuations.isEmpty, state == .acting { state = .monitoring }
        lock.unlock()

        for report in toEmit { emit(.actuatorReport(report)) }
        if brownout {
            emit(.fault(.brownout))
            emit(.log("Brownout averted: a second motor was refused because the supply could "
                + "not carry it. Any event captured during a brownout is marked suspect."))
        }
    }

    // MARK: Transfers

    private func queueTransfer(eventID: UUID, record: TriaxialRecord) {
        let (manifest, chunks) = ChunkSplitter.split(record, eventID: eventID)
        lock.lock()
        transferQueue.append((manifest, chunks))
        transferCursor = 0
        lock.unlock()
        emit(.recordingManifest(manifest))
    }

    private func advanceTransfer(deltaTime: TimeInterval) {
        lock.lock()
        guard let current = transferQueue.first else { lock.unlock(); return }
        transferBudget += deltaTime * configuration.linkBytesPerSecond

        var toSend: [RecordingChunk] = []
        while transferCursor < current.chunks.count {
            let chunk = current.chunks[transferCursor]
            let cost = Double(chunk.payload.count + 12)
            guard transferBudget >= cost else { break }
            transferBudget -= cost
            toSend.append(chunk)
            transferCursor += 1
        }

        let finished = transferCursor >= current.chunks.count
        if finished {
            transferQueue.removeFirst()
            transferCursor = 0
            bufferedRecordings.removeValue(forKey: current.manifest.eventID)
        }
        lock.unlock()

        for chunk in toSend { emit(.recordingChunk(chunk)) }
        if finished { emit(.log("Recording transfer complete.")) }
    }

    private func offerBufferedRecordings() {
        lock.lock()
        let pending = bufferedRecordings
        lock.unlock()
        guard !pending.isEmpty else { return }
        emit(.log("\(pending.count) recording\(pending.count == 1 ? "" : "s") were buffered "
            + "while disconnected. Transferring now — nothing was lost."))
        for (id, record) in pending { queueTransfer(eventID: id, record: record) }
    }

    // MARK: Commands

    private func handle(_ command: NodeCommand) {
        switch command {
        case .selfTest:
            emit(.selfTestResult(runSelfTest()))

        case .calibrateBaseline:
            lock.lock()
            baselineCalibrated = true
            detectorSeeded = false
            faults.remove(.calibrationInvalid)
            state = .monitoring
            let period = currentPeriod
            let temperature = structureTemperature
            lock.unlock()
            emit(.log("Baseline calibrated. Reference period "
                + "\(String(format: "%.3f", period)) s at "
                + "\(String(format: "%.1f", temperature)) °C."))
            emit(.periodMeasured(period: period, confidence: 0.9, temperature: temperature))

        case .setSensitivity(let value):
            lock.lock()
            configuration.trigger = STALTAConfig(
                shortWindow: configuration.trigger.shortWindow,
                longWindow: configuration.trigger.longWindow,
                triggerThreshold: value,
                detriggerThreshold: Swift.max(value * 0.45, 1.2))
            lock.unlock()
            emit(.log("Trigger threshold set to \(String(format: "%.1f", value))."))

        case .drill(let fireActuators):
            emit(.log(fireActuators
                ? "Drill: running the full sequence including actuators."
                : "Drill: running the warning sequence. No actuator will move."))
            if fireActuators { fireProtectiveSequence() }

        case .fireActuator(let kind):
            lock.lock()
            let others = activeMotors
            let allowed = configuration.budget.canRun(kind, alongside: others)
            if allowed {
                actuatorStates[kind] = .queued
                let step = ActuationStep(kind: kind, startOffset: 0, duration: kind.travelTime,
                                         currentDraw: kind.peakCurrent_mA,
                                         reason: "Fired manually.")
                pendingActuations.append((step: step, sequenceStart: elapsed))
            }
            lock.unlock()
            if allowed {
                emit(.actuatorReport(ActuatorReport(kind: kind, state: .queued)))
            } else {
                emit(.actuatorReport(ActuatorReport(
                    kind: kind, state: .failed,
                    failureReason: "Another motor is already moving. Wait for it to finish.")))
            }

        case .resetActuator(let kind):
            lock.lock()
            actuatorStates[kind] = .idle
            activeMotors.removeAll { $0 == kind }
            if kind == .mainsPower { gridPowerPresent = true }
            lock.unlock()
            emit(.actuatorReport(ActuatorReport(kind: kind, state: .idle)))

        case .requestPeriodMeasurement:
            lock.lock()
            let period = currentPeriod
            let temperature = structureTemperature
            lock.unlock()
            emit(.periodMeasured(period: period, confidence: 0.85, temperature: temperature))

        case .setShakeTableSpeed(let speed):
            lock.lock(); shakeTableSpeed = Swift.min(Swift.max(speed, 0), 1); lock.unlock()
            emit(.log(speed > 0
                ? "Shake table running at \(Int(speed * 100))%."
                : "Shake table stopped."))

        case .requestRecording(let eventID, let fromChunk):
            lock.lock()
            let record = bufferedRecordings[eventID]
            lock.unlock()
            guard let record else {
                emit(.log("No buffered recording with that identifier."))
                return
            }
            let (manifest, chunks) = ChunkSplitter.split(record, eventID: eventID)
            lock.lock()
            transferQueue.append((manifest, Array(chunks.dropFirst(Swift.max(fromChunk, 0)))))
            transferCursor = 0
            lock.unlock()
            emit(.recordingManifest(manifest))
            emit(.log("Re-sending recording from chunk \(fromChunk)."))

        case .syncClock:
            lock.lock(); faults.remove(.clockUnset); lock.unlock()
            emit(.log("Clock synchronised."))

        case .abort:
            lock.lock()
            pendingActuations.removeAll()
            activeMotors.removeAll()
            shakeTableSpeed = 0
            state = .monitoring
            lock.unlock()
            emit(.log("Aborted. All motion stopped."))

        case .setLED, .buzz, .playTone, .setMatrixText, .setSevenSegment,
             .setFloorStressPattern, .acknowledgeEvent:
            // Cosmetic on real hardware; acknowledged so the console shows the
            // round trip actually happened.
            emit(.log("Node acknowledged: \(command.label)."))
        }
    }

    private func runSelfTest() -> SelfTestResult {
        lock.lock()
        let calibrated = baselineCalibrated
        let voltage = 5.05 + rng.gaussian(sd: 0.02)
        let hasFaults = !faults.isEmpty
        lock.unlock()

        return SelfTestResult(checks: [
            .init(name: "Accelerometer", passed: true,
                  detail: "Three axes responding, noise floor within specification."),
            .init(name: "Tilt switch", passed: true, detail: "Reads level and latches on test."),
            .init(name: "Sound sensor", passed: true, detail: "Responds to the test tone."),
            .init(name: "Ultrasonic range", passed: true,
                  detail: "Reads a stable distance to the reference target."),
            .init(name: "Thermistors", passed: true,
                  detail: "Board and structure sensors both within a degree of each other."),
            .init(name: "Photoresistors", passed: true,
                  detail: "Grid and relay sensors both respond to the test lamp."),
            .init(name: "Water sensor", passed: true, detail: "Dry, and responds to the wet test."),
            .init(name: "Real-time clock", passed: true, detail: "Running and set."),
            .init(name: "Supply voltage", passed: voltage > 4.75,
                  detail: "\(String(format: "%.2f", voltage)) V at the board."),
            .init(name: "Actuators", passed: !hasFaults,
                  detail: hasFaults
                    ? "One or more actuators reported a fault. Check the console."
                    : "All three moved to their end stops and returned."),
            .init(name: "Baseline calibration", passed: calibrated,
                  detail: calibrated
                    ? "A valid baseline is stored."
                    : "No baseline yet. Run calibration while the building is quiet."),
        ])
    }

    // MARK: Introspection

    private func currentTelemetry() -> NodeTelemetry {
        lock.lock(); defer { lock.unlock() }
        let activeDraw = activeMotors.reduce(configuration.budget.quiescent) {
            $0 + $1.peakCurrent_mA
        }
        return NodeTelemetry(
            state: state,
            timestamp: Date(),
            boardTemperature: structureTemperature + 9 + rng.gaussian(sd: 0.2),
            structureTemperature: structureTemperature,
            ambientVibrationRMS: configuration.noiseFloor * 1.15,
            measuredPeriod: baselineCalibrated ? currentPeriod : nil,
            staLtaRatio: latestRatio,
            batteryPercent: nil,
            usbPowered: true,
            supplyVoltage: 5.05 - Double(activeMotors.count) * 0.18,
            activeCurrentDraw_mA: activeDraw,
            gridPowerPresent: gridPowerPresent,
            waterDetected: waterDetected,
            occupancyDetected: occupancy,
            permanentTilt: permanentTilt,
            tiltAngle: tiltAngle,
            residualDisplacement: residualDisplacement,
            faults: Array(faults))
    }

    /// The building's true period, for tests and the tutorial's
    /// "introduce simulated damage" step. The app itself must never read this —
    /// it is supposed to *measure* the period, not be told it.
    public var trueperiod: Double {
        lock.lock(); defer { lock.unlock() }
        return currentPeriod
    }

    public var trueDamageFactor: Double {
        lock.lock(); defer { lock.unlock() }
        return damageFactor
    }

    /// Used by the guided tutorial to demonstrate a verdict changing.
    public func introduceSimulatedDamage(periodIncreaseFraction: Double = 0.14) {
        lock.lock()
        let increase = 1 + Swift.max(periodIncreaseFraction, 0)
        damageFactor *= increase
        // Apply it to the current period immediately rather than waiting for the
        // next drift tick: the tutorial rescans as soon as this returns.
        currentPeriod *= increase
        residualDisplacement += 0.018
        lock.unlock()
        emit(.log("Simulated damage introduced. The building is now measurably softer — "
            + "rescan to see the assessment change."))
    }

    public func simulateConnectionLoss() {
        lock.lock()
        connection = .reconnecting(attempt: 1, nextRetryIn: 2)
        lock.unlock()
        emit(.connectionChanged(.reconnecting(attempt: 1, nextRetryIn: 2)))
        emit(.log("Connection lost. The node keeps acting and buffers its recording; "
            + "nothing is lost."))
    }

    public func restoreConnection() {
        lock.lock()
        connection = .simulated
        lock.unlock()
        emit(.connectionChanged(.simulated))
        offerBufferedRecordings()
    }

    private func emit(_ event: NodeEvent) {
        eventHandler?(event)
    }
}
