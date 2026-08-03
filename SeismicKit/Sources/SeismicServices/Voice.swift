import Foundation
import SeismicCore

/// Spoken output.
///
/// Two paths, and the fallback is not a degraded one. ElevenLabs gives a calm,
/// deliberately unhurried voice for the emergency announcements — a panicked
/// synthetic voice makes people freeze — but the system voice says exactly the
/// same words, immediately, with no network. During an earthquake the local
/// voice is arguably the better product: it cannot be delayed by a congested
/// cell tower at the precise moment the tower is congested.
public actor SpeechService {

    /// What the app should do with the result.
    public enum Output: Sendable, Equatable {
        /// Synthesised audio, ready to hand to an audio player.
        case audio(Data, mimeType: String)
        /// Speak this with the on-device synthesiser at the given rate.
        case systemVoice(String, rate: Double)
    }

    private let vault: SecretsVault
    private let client: ResilientClient
    private var cache = LRUCache<String, Data>(countLimit: 24)

    public init(vault: SecretsVault, transport: HTTPTransport = URLSessionHTTPTransport()) {
        self.vault = vault
        self.client = ResilientClient(transport: transport, requestsPerSecond: 2, burst: 3)
    }

    public nonisolated var hasLiveVoice: Bool { vault.has(.elevenLabsAPIKey) }

    /// Urgency changes the delivery, not the words. Sped-up speech in an
    /// emergency reduces comprehension, so the urgent setting is only slightly
    /// faster and the sentence is shortened instead.
    public enum Urgency: Sendable {
        case emergency, normal, calm

        var rate: Double {
            switch self {
            case .emergency: 0.52
            case .normal: 0.48
            case .calm: 0.44
            }
        }

        var stability: Double {
            switch self {
            case .emergency: 0.75      // steady, not expressive
            case .normal: 0.55
            case .calm: 0.45
            }
        }
    }

    public func speak(_ text: String, urgency: Urgency = .normal) async -> Sourced<Output> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Sourced(.systemVoice("", rate: urgency.rate), origin: .onDevice,
                           provider: "System voice")
        }

        let cacheKey = "\(urgency.stability)|\(trimmed)"
        if let audio = cache.value(forKey: cacheKey) {
            return Sourced(.audio(audio, mimeType: "audio/mpeg"), origin: .cached,
                           provider: "ElevenLabs")
        }

        guard let key = vault.value(for: .elevenLabsAPIKey), !key.isEmpty else {
            return Sourced(.systemVoice(trimmed, rate: urgency.rate), origin: .onDevice,
                           provider: "System voice")
        }

        // Overridable, because a household may want a voice they will
        // recognise instantly at three in the morning.
        let voiceID = vault.value(for: .elevenLabsVoiceID).flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.defaultVoiceID

        struct Settings: Encodable {
            var stability: Double
            var similarity_boost: Double
            var use_speaker_boost: Bool
        }
        struct Body: Encodable {
            var text: String
            var model_id: String
            var voice_settings: Settings
        }

        do {
            let audio = try await render(trimmed, voiceID: voiceID, key: key, urgency: urgency)
            cache.setValue(audio, forKey: cacheKey, cost: audio.count)
            vault.setStatus(.valid(checkedAt: Date()), for: .elevenLabsAPIKey)
            return Sourced(.audio(audio, mimeType: "audio/mpeg"), origin: .live,
                           provider: "ElevenLabs")
        } catch let error as ServiceError {
            // A voice the plan is not entitled to is a *voice* problem, not a
            // key problem, and it is worth one retry with a voice every account
            // has. Free plans cannot use library voices through the API, which
            // is not something anybody discovers from the ElevenLabs voice
            // picker — it lists them all, and the refusal only arrives at the
            // moment the app tries to speak. Falling back silently to the
            // device voice would present that as "the network was slow" for
            // ever.
            if case .http(let status, _) = error, status == 402, voiceID != Self.defaultVoiceID {
                if let audio = try? await render(trimmed, voiceID: Self.defaultVoiceID,
                                                 key: key, urgency: urgency) {
                    cache.setValue(audio, forKey: cacheKey, cost: audio.count)
                    vault.setStatus(.valid(checkedAt: Date()), for: .elevenLabsAPIKey)
                    return Sourced(.audio(audio, mimeType: "audio/mpeg"), origin: .live,
                                   provider: "ElevenLabs",
                                   note: "Your chosen voice needs a paid ElevenLabs plan, so the "
                                       + "default voice was used instead.")
                }
            }

            if let status = error.keyStatus() {
                vault.setStatus(status, for: .elevenLabsAPIKey)
            }
            return Sourced(.systemVoice(trimmed, rate: urgency.rate), origin: .onDevice,
                           provider: "System voice",
                           note: Self.explain(error))
        } catch {
            return Sourced(.systemVoice(trimmed, rate: urgency.rate), origin: .onDevice,
                           provider: "System voice")
        }
    }

    /// George — a premade voice, available on every plan including the free
    /// one. That last part is the whole reason it is the default: a default
    /// that four out of five new users cannot actually use is not a default.
    static let defaultVoiceID = "JBFqnCBsd6RMkjVDRZzb"

    private func render(_ text: String, voiceID: String, key: String,
                        urgency: Urgency) async throws -> Data {
        struct Settings: Encodable {
            var stability: Double
            var similarity_boost: Double
            var use_speaker_boost: Bool
        }
        struct Body: Encodable {
            var text: String
            var model_id: String
            var voice_settings: Settings
        }

        let request = try HTTPRequest.json(
            "POST",
            URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)")!,
            headers: ["xi-api-key": key, "Accept": "audio/mpeg"],
            body: Body(text: text,
                       model_id: "eleven_turbo_v2_5",
                       voice_settings: Settings(stability: urgency.stability,
                                                similarity_boost: 0.7,
                                                use_speaker_boost: true)),
            // Six seconds and no more. If the voice has not arrived by then
            // during an event, the device speaks it instead.
            timeout: urgency == .emergency ? 6 : 20)

        let response = try await client.send(request)
        guard !response.body.isEmpty else { throw ServiceError.emptyResult }
        return response.body
    }

    /// Why the device voice is speaking instead.
    ///
    /// It used to say "did not answer in time" whatever had happened, which is
    /// true of a timeout and false of everything else — and the two that
    /// actually occur, a key without the right permission and a plan without
    /// the right voice, are both things somebody can fix in a minute if they
    /// are told which one it is.
    private static func explain(_ error: ServiceError) -> String {
        switch error {
        case .http(401, _), .noCredential:
            "Your ElevenLabs key was refused. Check it in Settings → API keys."
        case .http(403, _):
            "Your ElevenLabs key does not have permission to generate speech."
        case .http(402, _):
            "Your ElevenLabs plan does not include this voice."
        case .rateLimited, .http(429, _):
            "ElevenLabs is rate-limiting this key."
        case .http(let status, _) where status >= 500:
            "ElevenLabs is having trouble at the moment."
        default:
            "The voice service did not answer in time."
        }
    }

    /// Pre-renders the handful of lines that must never wait for a network.
    ///
    /// Called after an assessment completes, so the sentences that would be
    /// spoken during the *next* event are already in the cache before it
    /// happens. This is the whole point of the cache: an emergency line
    /// fetched during the emergency is fetched at the worst possible moment.
    public func prewarmEmergencyLines() async {
        guard hasLiveVoice else { return }
        for line in Self.emergencyLines {
            _ = await speak(line, urgency: .emergency)
        }
    }

    public static let emergencyLines = [
        "Earthquake detected. Drop, cover and hold on.",
        "Strong shaking expected in ten seconds. Drop, cover and hold on.",
        "Shaking has stopped. Stay where you are until the assessment finishes.",
        "Stay outside. Do not go back in until an engineer has looked at the building.",
        "No structural change was detected. Check for gas, water and broken glass.",
    ]
}

// MARK: - Voice commands

/// The command grammar for hands-free control.
///
/// Recognition happens on-device in the app target using `SFSpeechRecognizer`;
/// this type owns the *interpretation*, so the grammar is unit-tested without a
/// microphone. Matching is fuzzy on purpose — somebody shouting at a phone
/// during an earthquake will not enunciate.
public enum VoiceCommand: String, Sendable, CaseIterable, Identifiable {
    /// The one command somebody shouts rather than says.
    ///
    /// Kept first because it is the only one on this list that matters when a
    /// person cannot reach their phone properly — trapped, injured, or holding
    /// something with both hands. Everything else here is a convenience.
    case callForHelp
    case status
    case isItSafe
    case startDrill
    case measureNow
    case callHousehold
    case readAssessment
    case stopSpeaking
    case showMap

    public var id: String { rawValue }

    public var spokenExamples: [String] {
        switch self {
        case .callForHelp: ["help", "help me", "i need help", "call for help",
                            "call emergency", "call nine one one", "call 911",
                            "emergency", "send help"]
        case .status: ["status", "what's happening", "report"]
        case .isItSafe: ["is it safe", "am i safe", "can i go in", "is the building safe"]
        case .startDrill: ["start a drill", "run a drill", "practise", "practice"]
        case .measureNow: ["measure now", "take a measurement", "check the building"]
        case .callHousehold: ["call my household", "check on everyone", "alert my family"]
        case .readAssessment: ["read the assessment", "read it out", "what does it say"]
        case .stopSpeaking: ["stop", "be quiet", "stop talking"]
        case .showMap: ["show the map", "open the map", "who else is nearby"]
        }
    }

    public var confirmation: String {
        switch self {
        case .callForHelp: "Calling emergency services."
        case .status: "Reading the current status."
        case .isItSafe: "Reading the latest assessment."
        case .startDrill: "Starting a drill. Nothing will actually fire."
        case .measureNow: "Measuring the building's period now."
        case .callHousehold: "Alerting your household."
        case .readAssessment: "Reading the assessment."
        case .stopSpeaking: ""
        case .showMap: "Opening the map."
        }
    }

    /// Commands that do something physical and irreversible need confirmation
    /// before they run — a misheard word must not close somebody's gas supply.
    public var requiresConfirmation: Bool {
        switch self {
        // Not `callForHelp`. Everything else that acts on the world asks
        // first, because a misheard word must not do something irreversible —
        // but making somebody confirm a call for help is exactly backwards.
        // The call is reversible in one tap and the situation it is for is not.
        case .callHousehold: true
        default: false
        }
    }

    /// Best match above the threshold, or nil. The threshold is deliberately
    /// high: doing nothing is a better failure than doing the wrong thing.
    public static func parse(_ heard: String, threshold: Double = 0.72) -> VoiceCommand? {
        let normalised = heard.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            // Digits kept. Speech recognition returns "call 911" with numerals,
            // not words, and stripping them left "call " — which matches
            // nothing. Punctuation still goes.
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace || $0 == "'" }
        guard !normalised.isEmpty else { return nil }

        var best: (command: VoiceCommand, score: Double)?
        for command in VoiceCommand.allCases {
            for example in command.spokenExamples {
                // A spoken phrase often contains the command plus filler
                // ("uh, is it safe to go inside"), so containment counts as a
                // full match and edit distance handles the rest.
                let score = normalised.contains(example)
                    ? 1.0
                    : FuzzyMatch.tokenSimilarity(normalised, example)
                if score > (best?.score ?? 0) { best = (command, score) }
            }
        }
        guard let best, best.score >= threshold else { return nil }
        return best.command
    }
}
