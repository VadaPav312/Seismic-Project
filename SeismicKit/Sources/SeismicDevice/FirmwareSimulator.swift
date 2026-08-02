import Foundation
import SeismicCore

/// A node that is not there.
///
/// It emits the same lines the firmware emits, over the same protocol, and the
/// layer above cannot tell the difference — which is the entire point. The app
/// has to be fully demonstrable with no hardware present, and a simulator that
/// takes a shortcut somewhere is a simulator that hides a bug exactly where the
/// real board would have shown it.
///
/// So it produces *text*, not model objects. Everything goes through the same
/// `Firmware.parse` the radio's bytes go through. If the parser is wrong about
/// a scaling, the simulated node is wrong in the same way and the error is
/// visible on screen rather than waiting for a board to arrive.
///
/// The physics is real enough to be worth watching: a resting noise floor, a P
/// arrival, an S arrival several seconds later, exponential coda decay, the
/// three channels voting at genuinely different moments, and a post-event
/// period consistent with the damage the shaking would have done.
public final class FirmwareSimulator: @unchecked Sendable {

    /// Where the simulated node sends its lines. Set by the transport.
    public var onLine: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var rng: SeededRandom
    private var state = Firmware.NodeState.boot
    private var elapsed: TimeInterval = 0

    // Detector state, mirroring the firmware's own variables.
    private var sta: Double = 0
    private var lta: Double = 100
    private var ratio: Double = 1
    private var triggerThreshold: Double = 4.0
    private var soundBaseline = 118
    private var photo = 320
    private var temperature = 21.4

    private var voteAccel = false, voteTilt = false, voteSound = false
    private var voteAccelAt: TimeInterval = -99
    private var voteTiltAt: TimeInterval = -99
    private var voteSoundAt: TimeInterval = -99

    private var baselinePeriod: Double = 0.432
    private var peakG: Double = 0
    private var stepperEnabled = true
    private var powerIsCut = false
    private var waterIsClosed = false

    /// An injected event's timeline, or nil while quiet.
    private var event: EventPlayback?
    /// The last recording, kept so `SEND` can genuinely resend it.
    private var recording: [Int] = []

    private var lastTelemetryAt: TimeInterval = -99
    private var lastAccelAt: TimeInterval = -99

    public init(seed: UInt64 = 0x5E15_C0DE) {
        self.rng = SeededRandom(seed: seed)
    }

    // MARK: Lifecycle

    /// Boots, then calibrates, exactly as `setup()` does.
    public func start() {
        emit(#"{"t":"boot","mpu":1}"#)
        calibrate()
    }

    /// Drives the simulation. Called from the app's display tick.
    public func tick(deltaTime: TimeInterval) {
        lock.lock()
        elapsed += deltaTime
        let now = elapsed
        lock.unlock()

        if var playback = event {
            advance(&playback, now: now, deltaTime: deltaTime)
            if playback.isFinished { event = nil } else { event = playback }
        } else {
            advanceQuiet(deltaTime: deltaTime)
        }

        // Ten acceleration samples a second, as `streamDivider` produces.
        if now - lastAccelAt >= 0.1 {
            lastAccelAt = now
            if state == .monitoring || state == .disarmed {
                emit(#"{"t":"acc","v":\#(Int(currentDeviation)),"r":\#(Int(ratio * 100))}"#)
            }
        }

        // Telemetry once a second.
        if now - lastTelemetryAt >= 1.0 {
            lastTelemetryAt = now
            sendTelemetry()
        }
    }

    // MARK: Commands

    /// Accepts a command line exactly as the firmware's `handleCommand` does,
    /// including the upper-casing.
    public func send(line: String) {
        let command = line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !command.isEmpty else { return }

        switch command {
        case "DRILL":
            ack("DRILL")
            beginEvent(isDrill: true)
        case "ARM":
            state = .monitoring; ack("ARM"); sendPhase("monitoring")
        case "DISARM":
            state = .disarmed; ack("DISARM"); sendPhase("disarmed")
        case "CAL":
            ack("CAL"); calibrate()
        case "RESET":
            ack("RESET")
            // The firmware restores power, waits the gap, then opens water.
            powerIsCut = false
            emit(#"{"t":"act","dev":"power","st":0}"#)
            waterIsClosed = false
            emit(#"{"t":"act","dev":"water","st":0}"#)
            emit(#"{"t":"note","m":"actuators reset"}"#)
            state = .monitoring
            sendPhase("monitoring")
        case "SEND":
            ack("SEND"); sendRecording()
        case "STATUS":
            sendTelemetry()
        case "PWR:1":
            ack("PWR:1"); cutPower()
        case "PWR:0":
            ack("PWR:0")
            powerIsCut = false; photo = 320
            emit(#"{"t":"act","dev":"power","st":0}"#)
        case "WTR:1":
            ack("WTR:1"); closeWater()
        case "WTR:0":
            ack("WTR:0")
            if stepperEnabled { waterIsClosed = false }
            emit(#"{"t":"act","dev":"water","st":0}"#)
        case "NOSTEP":
            stepperEnabled = false; ack("NOSTEP")
        case "YESTEP":
            stepperEnabled = true; ack("YESTEP")
        case "BEEP":
            ack("BEEP")
        default:
            if command.hasPrefix("REC:") {
                ack("REC")
                sendChunk(Int(command.dropFirst(4)) ?? -1)
            } else if command.hasPrefix("THR:") {
                triggerThreshold = Double(command.dropFirst(4)).map { $0 / 10 } ?? triggerThreshold
                sendTelemetry()
            } else if command.hasPrefix("STEP:") || command.hasPrefix("SPD:")
                        || command.hasPrefix("PHO:") {
                // Accepted and reflected, as the firmware does.
                sendTelemetry()
            } else {
                emit(#"{"t":"err","m":"unknown command"}"#)
            }
        }
    }

    // MARK: The event

    /// Injects an earthquake. Used by `DRILL` and by the demonstration
    /// controls.
    public func injectEarthquake(isDrill: Bool = false) { beginEvent(isDrill: isDrill) }

    private struct EventPlayback {
        var isDrill: Bool
        var startedAt: TimeInterval
        var stage = Stage.countdown
        var countdownRemaining = 5
        var nextCountdownAt: TimeInterval = 0
        var stageEntered: TimeInterval = 0
        var recordedSamples: [Int] = []
        var sampleClock: TimeInterval = 0

        enum Stage { case countdown, acting, recording, assessing, verdict, done }
        var isFinished: Bool { stage == .done }
    }

    private func beginEvent(isDrill: Bool) {
        guard event == nil else { return }

        // The three channels vote at genuinely different moments, which is what
        // makes the fusion display worth watching: the accelerometer sees the P
        // wave first, the sound sensor hears the building respond a fraction
        // later, and the tilt ball only rattles once the S wave arrives.
        voteAccel = true; voteAccelAt = elapsed
        voteSound = true; voteSoundAt = elapsed + 0.18
        voteTilt = true;  voteTiltAt = elapsed + 0.34
        ratio = 8.4

        state = .triggered
        emit(#"{"t":"trig","ratio":840,"va":1,"vt":1,"vs":0,"drill":\#(isDrill ? 1 : 0)}"#)
        sendPhase("warning")

        var playback = EventPlayback(isDrill: isDrill, startedAt: elapsed)
        playback.nextCountdownAt = elapsed
        playback.stageEntered = elapsed
        event = playback
    }

    private func advance(_ playback: inout EventPlayback, now: TimeInterval,
                         deltaTime: TimeInterval) {
        switch playback.stage {
        case .countdown:
            if now >= playback.nextCountdownAt, playback.countdownRemaining >= 1 {
                emit(#"{"t":"count","s":\#(playback.countdownRemaining)}"#)
                playback.countdownRemaining -= 1
                playback.nextCountdownAt = now + 1.0
            }
            if playback.countdownRemaining < 1, now >= playback.nextCountdownAt {
                playback.stage = .acting
                playback.stageEntered = now
                state = .acting
                sendPhase("acting")
                cutPower()
            }

        case .acting:
            // The eight-hundred-millisecond stagger, reproduced rather than
            // collapsed — it is the visible evidence of the power budget and
            // the reason each action can be followed.
            if now - playback.stageEntered >= 0.8, !waterIsClosed {
                closeWater()
            }
            if now - playback.stageEntered >= 1.6 {
                playback.stage = .recording
                playback.stageEntered = now
                playback.recordedSamples = []
                playback.sampleClock = 0
                peakG = 0
                state = .recording
                sendPhase("recording")
            }

        case .recording:
            // Fifty samples a second of a real-shaped earthquake.
            playback.sampleClock += deltaTime
            while playback.sampleClock >= 0.02, playback.recordedSamples.count < 500 {
                playback.sampleClock -= 0.02
                let t = Double(playback.recordedSamples.count) / 50.0
                let value = shakingSample(at: t)
                playback.recordedSamples.append(value)
                peakG = max(peakG, abs(Double(value)) / 16384.0)
            }
            if playback.recordedSamples.count >= 500 {
                recording = playback.recordedSamples
                sendRecording()
                playback.stage = .assessing
                playback.stageEntered = now
                state = .assessing
                sendPhase("assessing")
            }

        case .assessing:
            // The firmware spends about six seconds counting zero crossings.
            if now - playback.stageEntered >= 2.5 {
                playback.stage = .verdict
                state = .verdict
                sendAssessment()
                sendPhase("verdict")
                playback.stage = .done
                // Votes expire once the sequence is over, as the firmware's
                // 600 ms window would long since have done.
                voteAccel = false; voteTilt = false; voteSound = false
                ratio = 1.0
            }

        case .verdict, .done:
            playback.stage = .done
        }
    }

    /// One sample of a physically shaped earthquake, in raw counts.
    ///
    /// A P arrival, then an S arrival about two and a half seconds later
    /// carrying most of the energy, then an exponential coda. The S/P delay is
    /// what a source roughly twenty kilometres away produces, and it is the
    /// same quantity the app's own range estimate reads back out — so the
    /// simulated event is self-consistent rather than merely plausible.
    private func shakingSample(at t: Double) -> Int {
        var value = rng.gaussian(mean: 0, sd: 60)                 // noise floor

        if t >= 0.4 {                                             // P wave
            let age = t - 0.4
            value += 1_800 * exp(-age * 1.1) * sin(2 * .pi * 6.5 * age)
        }
        if t >= 2.9 {                                             // S wave
            let age = t - 2.9
            value += 6_200 * exp(-age * 0.55) * sin(2 * .pi * 2.4 * age)
                   + 2_100 * exp(-age * 0.8) * sin(2 * .pi * 3.7 * age + 1.1)
        }
        return Int(min(max(value, -32000), 32000))
    }

    // MARK: Quiet running

    private func advanceQuiet(deltaTime: TimeInterval) {
        // The same recursive STA/LTA the firmware runs, on a noise floor.
        let deviation = abs(rng.gaussian(mean: 0, sd: 45))
        sta = 0.20 * deviation + 0.80 * sta
        lta = 0.002 * deviation + 0.998 * lta
        lta = max(lta, 60)
        ratio = sta / lta

        // Votes expire after the firmware's 600 ms window.
        if voteAccel, elapsed - voteAccelAt > 0.6 { voteAccel = false }
        if voteTilt, elapsed - voteTiltAt > 0.6 { voteTilt = false }
        if voteSound, elapsed - voteSoundAt > 0.6 { voteSound = false }

        // Slow thermal drift, so the temperature channel is not a constant.
        temperature += rng.gaussian(mean: 0, sd: 0.004)
        temperature = min(max(temperature, 15), 28)
    }

    private var currentDeviation: Double {
        rng.gaussian(mean: 0, sd: 45)
    }

    /// Fires one channel without the others, so somebody can watch the fusion
    /// vote *refuse* to declare an event. This is the demonstration that
    /// explains why one sensor is not enough.
    public func nudgeSingleChannel() {
        voteAccel = true
        voteAccelAt = elapsed
        ratio = max(ratio, triggerThreshold + 1.4)
        sendTelemetry()
    }

    // MARK: Actions

    private func cutPower() {
        emit(#"{"t":"act","dev":"power","st":1}"#)
        let before = photo
        powerIsCut = true
        photo = 890                                   // the lamp goes dark
        emit(#"{"t":"act","dev":"power","st":2}"#)
        emit(#"{"t":"verify","dev":"power","before":\#(before),"after":\#(photo),"ok":1}"#)
    }

    private func closeWater() {
        guard stepperEnabled else {
            emit(#"{"t":"act","dev":"water","st":3}"#)
            emit(#"{"t":"note","m":"water main unavailable - reduced power mode"}"#)
            return
        }
        emit(#"{"t":"act","dev":"water","st":1}"#)
        waterIsClosed = true
        emit(#"{"t":"act","dev":"water","st":2}"#)
    }

    private func calibrate() {
        state = .calibrating
        sendPhase("calibrating")
        emit(#"{"t":"note","m":"calibrating - keep the surface still"}"#)

        // The firmware takes about twelve seconds. Reported immediately here
        // and paced by the caller, because a simulator that blocks a thread for
        // twelve seconds is a simulator nobody can use.
        baselinePeriod = 0.432 + rng.gaussian(mean: 0, sd: 0.004)
        soundBaseline = 118
        emit(#"{"t":"cal","grav":16384,"snd":\#(soundBaseline),"per":\#(Int(baselinePeriod * 1000))}"#)
        state = .monitoring
        sendPhase("monitoring")
    }

    // MARK: Emitting

    private func sendTelemetry() {
        let line = #"{"t":"tel","st":\#(state.rawValue),"ratio":\#(Int(ratio * 100)),"#
            + #""tmp":\#(Int(temperature * 10)),"snd":\#(soundBaseline + (voteSound ? 240 : 0)),"#
            + #""pho":\#(photo),"tilt":\#(voteTilt ? 1 : 0),"occ":\#(rng.uniform() > 0.85 ? 1 : 0),"#
            + #""va":\#(voteAccel ? 1 : 0),"vt":\#(voteTilt ? 1 : 0),"vs":\#(voteSound ? 1 : 0),"#
            + #""votes":\#((voteAccel ? 1 : 0) + (voteTilt ? 1 : 0) + (voteSound ? 1 : 0)),"#
            + #""pb":\#(Int(baselinePeriod * 1000)),"thr":\#(Int(triggerThreshold * 10))}"#
        emit(line)
    }

    /// One chunk by index, as `REC:n` asks for.
    private func sendChunk(_ index: Int) {
        let per = 20
        let chunks = (recording.count + per - 1) / per
        guard index >= 0, index < chunks else {
            emit(#"{"t":"err","m":"chunk out of range"}"#)
            return
        }
        let start = index * per
        let slice = Array(recording[start..<min(start + per, recording.count)])
        let body = slice.map(String.init).joined(separator: ",")
        emit(#"{"t":"rec","c":\#(index),"d":[\#(body)],"sum":\#(slice.reduce(0, +))}"#)
    }

    /// Drops a chunk from the next transfer, so gap recovery can be
    /// demonstrated rather than only tested.
    public var dropChunkOnNextTransfer: Int?

    private func sendRecording() {
        guard !recording.isEmpty else {
            emit(#"{"t":"recbegin","n":0,"hz":50}"#)
            emit(#"{"t":"recend"}"#)
            return
        }
        emit(#"{"t":"recbegin","n":\#(recording.count),"hz":50}"#)
        let per = 20
        let chunks = (recording.count + per - 1) / per
        for c in 0..<chunks {
            // A deliberately dropped chunk, once, so the recovery path is
            // exercised by a demonstration and not only by a test.
            if let dropped = dropChunkOnNextTransfer, dropped == c {
                dropChunkOnNextTransfer = nil
                continue
            }
            sendChunk(c)
        }
        emit(#"{"t":"recend"}"#)
    }

    private func sendAssessment() {
        // A period shift consistent with what the shaking would have done.
        // Driven by the peak the recording actually reached, so the assessment
        // and the waveform agree — an assessment invented independently of the
        // trace is the one thing a demonstration audience can catch.
        let severity = min(max((peakG - 0.08) / 0.5, 0), 1)
        let after = baselinePeriod * (1 + severity * 0.30)
        let changePercent = baselinePeriod > 0
            ? (after - baselinePeriod) / baselinePeriod * 100 : 0
        let tiltPermanent = severity > 0.75
        let verdict: String = tiltPermanent || changePercent > 15
            ? "R" : (changePercent > 5 || peakG > 0.30 ? "A" : "G")

        emit(#"{"t":"assess","pb":\#(Int(baselinePeriod * 1000)),"pa":\#(Int(after * 1000)),"#
             + #""pct":\#(Int(changePercent * 10)),"pga":\#(Int(peakG * 1000)),"#
             + #""tiltp":\#(tiltPermanent ? 1 : 0),"pwr":\#(powerIsCut ? 1 : 0),"#
             + #""verdict":"\#(verdict)"}"#)
    }

    private func sendPhase(_ phase: String) {
        emit(#"{"t":"phase","p":"\#(phase)"}"#)
    }

    private func ack(_ command: String) {
        emit(#"{"t":"ack","c":"\#(command)"}"#)
    }

    /// Simulates the board browning out and restarting.
    ///
    /// Present because a brownout is the one fault this system must never
    /// mistake for an earthquake, and a fault nobody can reproduce is a fault
    /// nobody has tested the handling of.
    public func simulateBrownout() {
        emit(#"{"t":"note","m":"supply dipped"}"#)
        emit(#"{"t":"boot","mpu":1}"#)
        state = .calibrating
        sendPhase("calibrating")
    }

    private func emit(_ line: String) { onLine?(line) }
}
