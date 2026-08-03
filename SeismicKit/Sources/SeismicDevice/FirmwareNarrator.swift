import Foundation

/// Turns what the node says into what a person would say.
///
/// The firmware speaks in a wire protocol — `T,2,4.31,19.4,412,...` — and every
/// screen in this app renders it as instruments: numbers, states, a timeline.
/// That is the right way to *inspect* a node and the wrong way to *watch* one.
/// Somebody standing over the board while it is working wants a running account
/// of what it is doing and why, in the order it happens, in words.
///
/// So this is a second reading of the same stream, in the first person, deriving
/// nothing the node did not say. It is not a log: a log prints everything, and
/// the node emits telemetry every second and acceleration far more often than
/// that. Almost all of that is unchanged from the line before it, and a feed
/// that repeats itself is a feed nobody reads. Every sentence here is emitted
/// because something *changed*.
///
/// Kept out of the app target and free of any UI so it can be tested against a
/// scripted sequence of messages, which is the only way to be confident that a
/// commentary meant to be watched once, live, in front of people, says the right
/// things in the right order.
public struct FirmwareNarrator: Sendable {

    /// How a line should feel, which is all the UI needs to colour it.
    public enum Tone: String, Sendable, Equatable {
        /// Ordinary business: connected, calibrated, monitoring.
        case routine
        /// Something is being sensed but nothing has been declared.
        case sensing
        /// The node has decided, or is doing something physical.
        case acting
        /// A good outcome, confirmed.
        case good
        /// A bad outcome, or a fault.
        case bad
    }

    public struct Line: Sendable, Equatable, Identifiable {
        public let id: UUID
        public var text: String
        public var tone: Tone
        /// Whether this line is important enough to interrupt and be spoken.
        ///
        /// Almost none of them are. A commentary that speaks every sentence
        /// talks continuously through an earthquake, which is worse than
        /// silence: the four sentences that matter are buried in forty that
        /// do not.
        public var isSpoken: Bool

        public init(id: UUID = UUID(), text: String, tone: Tone, isSpoken: Bool = false) {
            self.id = id
            self.text = text
            self.tone = tone
            self.isSpoken = isSpoken
        }
    }

    // MARK: What has already been said

    private var lastVotes: Firmware.Votes?
    private var lastPhase: Firmware.Phase?
    private var lastActuator: [Firmware.Actuator: Firmware.ActuatorState] = [:]
    private var hasDeclared = false
    private var hasWarnedAboutSingleChannel = false
    private var lastChunkAnnouncement = 0
    private var lastStepperReport = 0

    /// The quiet sound level, learned from the first readings.
    ///
    /// Learned rather than configured because the number a microphone reports
    /// at rest depends entirely on the room, and a fixed threshold would call
    /// a busy hallway "debris" all day.
    private var soundFloor: Double?
    private var soundSamples = 0

    public init() {}

    // MARK: The commentary

    /// One message in; nothing, or the sentences it warrants.
    public mutating func narrate(_ message: Firmware.Message) -> [Line] {
        switch message {
        case .boot(let hasAccelerometer):
            reset()
            return hasAccelerometer
                ? [Line(text: "I've just started up. Checking my sensors.", tone: .routine)]
                : [Line(text: "I've started up, but my accelerometer isn't answering. I can't "
                            + "detect an earthquake without it.", tone: .bad, isSpoken: true)]

        case .telemetry(let telemetry):
            return narrateTelemetry(telemetry)

        case .acceleration:
            // Many times a second, and the trace already shows it. Saying
            // anything here would drown everything else.
            return []

        case .triggered(let ratio, let votes, let isDrill):
            hasDeclared = true
            let how = spokenVotes(votes)
            let strength = String(format: "%.1f times", ratio)
            if isDrill {
                return [Line(text: "This is a drill. I'm running the whole sequence exactly as I "
                                 + "would for a real earthquake, so you can watch it.",
                             tone: .acting, isSpoken: true)]
            }
            return [Line(text: "Earthquake. \(how) — that's \(votes.count) of my 3 sensors, so "
                             + "I'm declaring it. The shaking is \(strength) stronger than "
                             + "background.",
                         tone: .acting, isSpoken: true)]

        case .countdown(let remaining):
            // Only the ends. The middle is a number on a screen already, and
            // counting out loud from five is how a demonstration loses its
            // audience.
            if remaining >= 5 {
                return [Line(text: "The strong shaking is a few seconds away. Take cover now — "
                                 + "get under something solid and hold on.",
                             tone: .acting, isSpoken: true)]
            }
            if remaining == 1 {
                return [Line(text: "It's about to hit.", tone: .acting)]
            }
            return []

        case .phase(let phase):
            defer { lastPhase = phase }
            guard phase != lastPhase else { return [] }
            return narratePhase(phase)

        case .actuator(let actuator, let state):
            defer { lastActuator[actuator] = state }
            guard lastActuator[actuator] != state else { return [] }
            return narrateActuator(actuator, state)

        case .stepperProgress(let percent, let degrees):
            // Only the quarters. A line every time the valve moves five per
            // cent would bury the four sentences that matter under twenty that
            // do not — which is the failure this whole type exists to avoid.
            // The progress bar on screen is the right place for the detail.
            guard percent > 0, percent.isMultiple(of: 25),
                  percent != lastStepperReport else { return [] }
            lastStepperReport = percent
            if percent >= 100 {
                return [Line(text: "The valve has turned a full revolution. That is it closed.",
                             tone: .good)]
            }
            return [Line(text: "Turning the valve — \(degrees) degrees round.", tone: .acting)]

        case .verification(let actuator, let before, let after, let confirmed):
            let noun = plainName(actuator)
            if confirmed {
                return [Line(text: "\(noun.capitalisedFirst) is confirmed off. I didn't take my "
                                 + "own word for it — I watched the light change from \(before) "
                                 + "to \(after) to prove the current actually stopped.",
                             tone: .good, isSpoken: true)]
            }
            return [Line(text: "I told \(noun) to switch off and the light barely moved "
                             + "(\(before) to \(after)). I can't prove it worked, so I'm not "
                             + "going to claim it did.",
                         tone: .bad, isSpoken: true)]

        case .recordingBegan(let count, let rate):
            lastChunkAnnouncement = 0
            let seconds = rate > 0 ? Double(count) / rate : 0
            return [Line(text: String(format: "Sending you the %.0f seconds of shaking I "
                                          + "recorded, so it can be analysed properly.", seconds),
                         tone: .routine)]

        case .recordingChunk(let index, _, _):
            // Every tenth, so the feed shows progress without becoming a
            // counter.
            guard index >= lastChunkAnnouncement + 10 else { return [] }
            lastChunkAnnouncement = index
            return [Line(text: "Still sending the recording — \(index) chunks across so far.",
                         tone: .routine)]

        case .recordingEnded:
            return [Line(text: "That's the whole recording across.", tone: .routine)]

        case .assessment(let assessment):
            return narrateAssessment(assessment)

        case .calibrated(_, _, let period):
            let seconds = Double(period) / 1000
            return [Line(text: String(format: "Calibrated. This building sways once every "
                                          + "%.2f seconds when nothing is happening to it — "
                                          + "that's the number I'll compare against afterwards.",
                                      seconds),
                         tone: .routine)]

        case .note(let text):
            return [Line(text: text, tone: .routine)]

        case .error(let text):
            return [Line(text: text, tone: .bad, isSpoken: true)]

        case .acknowledged, .unrecognised:
            return []
        }
    }

    public mutating func reset() {
        lastVotes = nil
        lastPhase = nil
        lastActuator = [:]
        hasDeclared = false
        hasWarnedAboutSingleChannel = false
        lastChunkAnnouncement = 0
        lastStepperReport = 0
        soundFloor = nil
        soundSamples = 0
    }

    // MARK: Telemetry

    private mutating func narrateTelemetry(_ telemetry: Firmware.Telemetry) -> [Line] {
        var lines: [Line] = []
        lines.append(contentsOf: narrateDebris(telemetry))

        let votes = telemetry.votes
        defer { lastVotes = votes }
        guard votes != lastVotes else { return lines }

        // Votes falling away is the ordinary end of a near-miss and does not
        // need a sentence of its own beyond the refusal, below.
        if votes.count == 0 {
            if lastVotes?.isDeclared == false, hasWarnedAboutSingleChannel {
                hasWarnedAboutSingleChannel = false
                lines.append(Line(text: "That's settled down. Nothing further — it wasn't an "
                                      + "earthquake.", tone: .routine))
            }
            return lines
        }

        if !votes.isDeclared {
            // The most useful sentence in the whole app during a demonstration:
            // the moment somebody sees the thing *refuse*.
            guard !hasWarnedAboutSingleChannel else { return lines }
            hasWarnedAboutSingleChannel = true
            lines.append(Line(text: "\(spokenVotes(votes)) — but that's only \(votes.count) of "
                                  + "my 3 sensors and I need 2 that agree. Could be a slammed "
                                  + "door or a lorry. I'm not going to cut anyone's power over "
                                  + "it.",
                              tone: .sensing))
            return lines
        }

        if !hasDeclared {
            lines.append(Line(text: "\(spokenVotes(votes)) — \(votes.count) sensors agreeing. "
                                  + "That's an earthquake.",
                              tone: .acting))
        }
        return lines
    }

    /// Something falling, as distinct from the ground moving.
    ///
    /// A loud noise with no acceleration underneath it is not shaking; it is an
    /// object hitting the floor. The node cannot see debris, but it can hear it,
    /// and the *absence* of a matching accelerometer reading is what makes the
    /// inference worth stating — during an earthquake it means something in the
    /// building has come down, which is the thing anybody deciding whether to go
    /// back inside actually wants to know.
    private mutating func narrateDebris(_ telemetry: Firmware.Telemetry) -> [Line] {
        let level = Double(telemetry.soundLevel)

        // A rolling floor over the first readings. Anything before it settles
        // is not judged, because the first sound reading after a reset is
        // frequently a boot transient.
        guard let floor = soundFloor else {
            soundFloor = level
            soundSamples = 1
            return []
        }
        soundSamples += 1
        soundFloor = floor * 0.95 + level * 0.05
        guard soundSamples > 5 else { return [] }

        // Only during and after an event: a bang in a quiet building is a
        // door, and this is not a burglar alarm.
        guard hasDeclared else { return [] }
        // Loud, and not matched by ground motion. Both halves are required —
        // the noise of the earthquake itself arrives *with* the shaking.
        guard level > floor * 2.2, level > 60, telemetry.ratio < 2.0 else { return [] }
        soundFloor = level     // so one crash is not reported repeatedly

        return [Line(text: "Something just fell. That was a loud noise with no ground motion "
                         + "underneath it, which means debris rather than shaking — treat the "
                         + "building as unsafe to walk through.",
                     tone: .bad, isSpoken: true)]
    }

    // MARK: Phases and actuators

    private func narratePhase(_ phase: Firmware.Phase) -> [Line] {
        switch phase {
        case .calibrating:
            [Line(text: "Measuring how this building normally sways. Keep still for a moment.",
                  tone: .routine)]
        case .monitoring:
            [Line(text: "Armed and listening. I'll stay quiet until something happens.",
                  tone: .routine)]
        case .disarmed:
            [Line(text: "Disarmed. I'm still watching, but I won't act on anything.",
                  tone: .routine)]
        case .warning:
            [Line(text: "Warning everyone now, before the strong shaking arrives.",
                  tone: .acting)]
        case .acting:
            [Line(text: "Making the building safe. One thing at a time — the board can't power "
                      + "two motors at once without browning out.",
                  tone: .acting)]
        case .recording:
            [Line(text: "Recording the shaking as it happens.", tone: .routine)]
        case .assessing:
            [Line(text: "Now measuring how the building sways after the earthquake. If it's "
                      + "slower than before, something inside it has been damaged.",
                  tone: .routine)]
        case .verdict:
            [Line(text: "Working out the verdict.", tone: .routine)]
        }
    }

    private func narrateActuator(_ actuator: Firmware.Actuator,
                                 _ state: Firmware.ActuatorState) -> [Line] {
        let noun = plainName(actuator)
        switch state {
        case .commanded:
            return [Line(text: "Shutting off \(noun) now.", tone: .acting, isSpoken: true)]
        case .confirmed:
            // The verification message carries the evidence and says so more
            // fully a moment later; this is the immediate acknowledgement.
            return [Line(text: "\(noun.capitalisedFirst) is off.", tone: .good)]
        case .failed:
            return [Line(text: "I couldn't shut off \(noun). Do it by hand.",
                         tone: .bad, isSpoken: true)]
        case .idle:
            return []
        }
    }

    private func narrateAssessment(_ assessment: Firmware.Assessment) -> [Line] {
        let change = assessment.periodChangePercent
        let before = String(format: "%.2f", assessment.periodBefore)
        let after = String(format: "%.2f", assessment.periodAfter)

        let explanation = "Before the earthquake this building swayed once every \(before) "
            + "seconds. Now it takes \(after)."

        switch assessment.verdict {
        case .green:
            return [Line(text: explanation + " That's essentially unchanged, so the structure "
                             + "is behaving as it did before. No sign of damage.",
                         tone: .good, isSpoken: true)]
        case .amber:
            return [Line(text: explanation + String(format: " It's swaying %.0f%% more slowly, "
                             + "which usually means something has softened. Have it looked at, "
                             + "and don't ignore new cracks.", abs(change)),
                         tone: .bad, isSpoken: true)]
        case .red:
            return [Line(text: explanation + String(format: " That's %.0f%% slower. A building "
                             + "sways more slowly when it has lost stiffness, and losing that "
                             + "much means real structural damage. Get out and stay out.",
                             abs(change)),
                         tone: .bad, isSpoken: true)]
        case .needsInspection:
            return [Line(text: explanation + " I can't tell you either way with confidence, and "
                             + "a guess is worse than nothing here. It needs someone qualified "
                             + "to look at it.",
                         tone: .bad, isSpoken: true)]
        }
    }

    // MARK: Words

    /// What the sensors are actually reporting, said as a person would say it.
    private func spokenVotes(_ votes: Firmware.Votes) -> String {
        var parts: [String] = []
        if votes.accelerometer { parts.append("I can feel the building moving") }
        if votes.sound { parts.append("I can hear it") }
        if votes.tilt { parts.append("I'm being tilted") }
        guard !parts.isEmpty else { return "Nothing is registering" }
        if parts.count == 1 { return parts[0] }
        return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
    }

    private func plainName(_ actuator: Firmware.Actuator) -> String {
        switch actuator {
        case .power: "the building's power"
        case .water: "the water main"
        }
    }
}

extension String {
    /// Upper-cases only the first character, leaving the rest — unlike
    /// `capitalized`, which would turn "the water main" into "The Water Main".
    var capitalisedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
