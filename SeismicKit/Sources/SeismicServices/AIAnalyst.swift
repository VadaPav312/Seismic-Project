import Foundation
import SeismicCore
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - What the analyst is being asked to do

/// The analyst is deliberately narrow. It explains measurements that have
/// already been made; it never decides anything. The verdict is computed by
/// `AssessmentEngine` from the evidence and is passed *in* to the analyst as a
/// fact — a language model is not permitted to move a building from amber to
/// green, and this is enforced by the shape of the request rather than by
/// asking politely in a prompt.
public enum AnalystTask: String, Sendable, Codable, CaseIterable {
    case assessmentNarrative
    case spokenGuidance
    case buildingSummary
    case photoDamage
    case plainEnglish

    var wordBudget: Int {
        switch self {
        case .assessmentNarrative: 180
        case .spokenGuidance: 45
        case .buildingSummary: 120
        case .photoDamage: 120
        case .plainEnglish: 90
        }
    }

    /// Spoken guidance during an event is on the critical path for someone's
    /// safety, so it gets the lowest reasoning effort and the tightest timeout.
    /// A perfect sentence that arrives after the shaking is worthless.
    var effort: String {
        switch self {
        case .spokenGuidance: "low"
        case .plainEnglish, .photoDamage: "medium"
        case .assessmentNarrative, .buildingSummary: "medium"
        }
    }

    var timeout: TimeInterval {
        switch self {
        case .spokenGuidance: 6
        default: 30
        }
    }
}

/// One grounded fact. The analyst may restate these and reason about them; it
/// may not introduce a number that is not here.
public struct AnalystFact: Sendable, Equatable, Codable {
    public var label: String
    public var value: String
    public var source: String

    public init(label: String, value: String, source: String = "measured") {
        self.label = label
        self.value = value
        self.source = source
    }

    public init(label: String, number: Double, unit: String,
                decimals: Int = 2, source: String = "measured") {
        self.label = label
        self.value = String(format: "%.\(decimals)f", number) + (unit.isEmpty ? "" : " \(unit)")
        self.source = source
    }
}

public struct AnalystRequest: Sendable, Equatable, Codable {
    public var task: AnalystTask
    public var subject: String
    public var facts: [AnalystFact]
    /// Non-negotiable statements the answer must not contradict — the verdict,
    /// mostly. Rendered into the prompt as constraints and checked afterwards.
    public var constraints: [String]
    public var question: String

    public init(task: AnalystTask, subject: String, facts: [AnalystFact],
                constraints: [String] = [], question: String) {
        self.task = task
        self.subject = subject
        self.facts = facts
        self.constraints = constraints
        self.question = question
    }
}

public struct AnalystAnswer: Sendable, Equatable, Codable {
    public var text: String
    public var provider: String
    public var isAIGenerated: Bool
    /// Set when the model produced something the grounding check rejected and
    /// the on-device narrator was substituted instead. Shown in the UI.
    public var wasSubstituted: Bool

    public init(text: String, provider: String, isAIGenerated: Bool, wasSubstituted: Bool = false) {
        self.text = text
        self.provider = provider
        self.isAIGenerated = isAIGenerated
        self.wasSubstituted = wasSubstituted
    }
}

// MARK: - Prompt construction

/// Builds the prompt. Kept as pure string assembly in its own type so the exact
/// text a model receives is testable without a network.
public enum GroundedPrompt {

    public static func system(for task: AnalystTask) -> String {
        let common = """
        You are the structural analyst inside SEISMIC, an earthquake safety app. \
        You explain measurements to a person who is standing outside a building \
        wondering whether it is safe to go back in.

        Rules, in order of importance:
        1. Use only the facts supplied below. Never introduce a number, a date, a \
        material, a code reference or a building name that is not in them.
        2. Never contradict a stated constraint. The safety verdict has already \
        been computed from the evidence; you are explaining it, not revising it.
        3. Never tell anyone a building is safe to occupy. You are not an inspection.
        4. If the evidence is thin or contradictory, say so plainly. "The measurements \
        disagree" is a better answer than a confident one.
        5. Write in plain British English, in complete sentences. No bullet points, \
        no headings, no markdown, no emoji.
        6. Do not begin with a preamble. Start with the substance.
        """

        switch task {
        case .spokenGuidance:
            return common + """


            This answer will be spoken aloud, out loud, during or immediately after \
            an earthquake. Write at most two short sentences. Say what to do first. \
            Use no numbers unless a number changes the action.
            """
        case .assessmentNarrative:
            return common + """


            Write a single paragraph explaining what changed, what it means and what \
            the person should do next. Name the single strongest piece of evidence and \
            say what would change the conclusion.
            """
        case .buildingSummary:
            return common + """


            Describe this building's likely seismic behaviour in one paragraph: how it \
            resists lateral load, what its period implies, and what it is sensitive to. \
            Mark anything uncertain as uncertain.
            """
        case .photoDamage:
            return common + """


            Describe only what is visible in the photograph. Distinguish cosmetic \
            finishes from structural elements. If you cannot tell which one you are \
            looking at, say that — it is the most useful thing you can say.
            """
        case .plainEnglish:
            return common + """


            Explain the term or measurement in plain language for someone with no \
            engineering background. One short paragraph. An everyday analogy is welcome \
            if it is accurate.
            """
        }
    }

    public static func user(_ request: AnalystRequest) -> String {
        var lines: [String] = []
        lines.append("SUBJECT: \(request.subject)")
        lines.append("")
        lines.append("FACTS (the only information you have):")
        if request.facts.isEmpty {
            lines.append("- none were measured")
        } else {
            for fact in request.facts {
                lines.append("- \(fact.label): \(fact.value)  [\(fact.source)]")
            }
        }
        if !request.constraints.isEmpty {
            lines.append("")
            lines.append("CONSTRAINTS (must not be contradicted):")
            for constraint in request.constraints { lines.append("- \(constraint)") }
        }
        lines.append("")
        lines.append("TASK: \(request.question)")
        lines.append("Answer in at most \(request.task.wordBudget) words.")
        return lines.joined(separator: "\n")
    }
}

// MARK: - The grounding check

/// A cheap, deterministic check that the model did not invent a number.
///
/// It is not a proof of truthfulness and does not pretend to be. It catches the
/// one failure mode that matters here: a fluent paragraph containing a
/// measurement that was never taken. Any numeric token in the answer that does
/// not appear in the supplied facts — beyond a small allow-list of ordinary
/// prose numbers — fails the check and the on-device narrator is used instead.
public enum GroundingCheck {

    /// Numbers a sentence can legitimately contain without being a measurement.
    private static let benign: Set<String> = ["0", "1", "2", "3", "4", "5", "6",
                                              "7", "8", "9", "10", "100"]

    public static func numericTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in text {
            if character.isNumber || (character == "." && !current.isEmpty) {
                current.append(character)
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens.map { token in
            // Trim a trailing decimal point left by "3." at the end of a sentence.
            token.hasSuffix(".") ? String(token.dropLast()) : token
        }
    }

    public static func passes(_ answer: String, given request: AnalystRequest) -> Bool {
        let supplied = Set(
            (request.facts.map(\.value) + request.constraints + [request.subject])
                .flatMap { numericTokens(in: $0) }
        )
        for token in numericTokens(in: answer) {
            if benign.contains(token) { continue }
            if supplied.contains(token) { continue }
            // A rounded restatement is fine: 0.94 for 0.9412, 12 for 12.4.
            if supplied.contains(where: { $0.hasPrefix(token) || token.hasPrefix($0) }) { continue }
            return false
        }
        return true
    }
}

// MARK: - Providers

/// One inference backend. Each is a thin, explicit HTTP client — Swift has no
/// official SDK for any of these, so the wire format is written out rather than
/// guessed at through a wrapper.
protocol InferenceProvider: Sendable {
    var name: String { get }
    var key: SecretKey { get }
    func complete(_ request: AnalystRequest, system: String, user: String,
                  client: ResilientClient, vault: SecretsVault) async throws -> String
}

/// Cerebras. OpenAI-compatible wire format, chosen for time-to-first-token:
/// spoken guidance during an event cannot wait for a slow stream to start.
struct CerebrasProvider: InferenceProvider {
    let name = "Cerebras"
    let key = SecretKey.cerebrasAPIKey

    func complete(_ request: AnalystRequest, system: String, user: String,
                  client: ResilientClient, vault: SecretsVault) async throws -> String {
        guard let apiKey = vault.value(for: key), !apiKey.isEmpty else {
            throw ServiceError.noCredential(key)
        }
        let model = vault.value(for: .cerebrasModel) ?? SecretKey.cerebrasModel.defaultValue!
        let url = URL(string: "https://api.cerebras.ai/v1/chat/completions")!
        let payload = OpenAIChatRequest(
            model: model,
            messages: [.init(role: "system", content: system),
                       .init(role: "user", content: user)],
            max_completion_tokens: request.task.wordBudget * 3,
            temperature: 0.2)
        let http = try HTTPRequest.json("POST", url,
                                        headers: ["Authorization": "Bearer \(apiKey)"],
                                        body: payload, timeout: request.task.timeout)
        let response: OpenAIChatResponse = try await client.json(http, as: OpenAIChatResponse.self)
        guard let text = response.choices.first?.message.content, !text.isEmpty else {
            throw ServiceError.emptyResult
        }
        return text
    }
}

/// Gemini. The free-tier provider, and the vision path that needs no card.
///
/// It matters more than its position in the chain suggests: photo damage
/// analysis previously required OpenAI, which has no free tier, so the one
/// feature in this app that genuinely cannot be done on the device sat behind
/// a payment method. This removes that.
struct GeminiProvider: InferenceProvider {
    let name = "Gemini"
    let key = SecretKey.geminiAPIKey

    /// The floating alias, deliberately, rather than a pinned version.
    ///
    /// Google retires specific Gemini versions from the free tier on its own
    /// schedule — `gemini-2.0-flash` now answers with a zero free quota, and
    /// `gemini-2.5-flash` refuses new users outright. A pinned id means the
    /// photo path silently dies on a date nobody chose. The alias tracks
    /// whichever flash model is currently free, which is exactly what a build
    /// that must keep working without maintenance needs.
    static let model = "gemini-flash-latest"

    static func endpoint(model: String) -> URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/"
                  + "\(model):generateContent")!
    }

    func complete(_ request: AnalystRequest, system: String, user: String,
                  client: ResilientClient, vault: SecretsVault) async throws -> String {
        guard let apiKey = vault.value(for: key), !apiKey.isEmpty else {
            throw ServiceError.noCredential(key)
        }

        let payload = GeminiRequest(
            contents: [.init(role: "user", parts: [.init(text: user)])],
            systemInstruction: .init(parts: [.init(text: system)]),
            generationConfig: .init(temperature: 0.2,
                                    maxOutputTokens: request.task.wordBudget * 4))

        let http = try HTTPRequest.json(
            "POST", Self.endpoint(model: Self.model),
            headers: ["x-goog-api-key": apiKey],
            body: payload, timeout: request.task.timeout)

        let response: GeminiResponse = try await client.json(http, as: GeminiResponse.self)
        guard let text = response.firstText, !text.isEmpty else { throw ServiceError.emptyResult }
        return text
    }
}

/// OpenAI. A fallback for text and for vision when its key happens to be set.
struct OpenAIProvider: InferenceProvider {
    let name = "OpenAI"
    let key = SecretKey.openAIAPIKey

    func complete(_ request: AnalystRequest, system: String, user: String,
                  client: ResilientClient, vault: SecretsVault) async throws -> String {
        guard let apiKey = vault.value(for: key), !apiKey.isEmpty else {
            throw ServiceError.noCredential(key)
        }
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        let payload = OpenAIChatRequest(
            model: "gpt-4o",
            messages: [.init(role: "system", content: system),
                       .init(role: "user", content: user)],
            max_completion_tokens: request.task.wordBudget * 3,
            temperature: 0.2)
        let http = try HTTPRequest.json("POST", url,
                                        headers: ["Authorization": "Bearer \(apiKey)"],
                                        body: payload, timeout: request.task.timeout)
        let response: OpenAIChatResponse = try await client.json(http, as: OpenAIChatResponse.self)
        guard let text = response.choices.first?.message.content, !text.isEmpty else {
            throw ServiceError.emptyResult
        }
        return text
    }
}

/// Anthropic, via the Messages API.
///
/// Adaptive thinking is on by default on this model, so `thinking` is left
/// unset and depth is controlled with `output_config.effort`. `max_tokens` is
/// a hard ceiling over thinking *and* the reply, so it is sized well above the
/// word budget. Server-side fallback is requested so that a safety-classifier
/// decline is re-served rather than returned as an empty answer — this app
/// discusses building collapse for a living and occasionally reads as alarming.
struct AnthropicProvider: InferenceProvider {
    let name = "Anthropic"
    let key = SecretKey.anthropicAPIKey

    static let model = "claude-opus-5"

    func complete(_ request: AnalystRequest, system: String, user: String,
                  client: ResilientClient, vault: SecretsVault) async throws -> String {
        guard let apiKey = vault.value(for: key), !apiKey.isEmpty else {
            throw ServiceError.noCredential(key)
        }
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        let payload = AnthropicMessagesRequest(
            model: Self.model,
            max_tokens: 8000,
            system: system,
            messages: [.init(role: "user", content: user)],
            output_config: .init(effort: request.task.effort),
            fallbacks: "default")
        let http = try HTTPRequest.json(
            "POST", url,
            headers: ["x-api-key": apiKey,
                      "anthropic-version": "2023-06-01",
                      "anthropic-beta": "server-side-fallback-2026-07-01"],
            body: payload, timeout: request.task.timeout)

        let response: AnthropicMessagesResponse =
            try await client.json(http, as: AnthropicMessagesResponse.self)

        // A refusal arrives as a successful response with an empty or partial
        // body, so `stop_reason` has to be checked before the content is read.
        if response.stop_reason == "refusal" { throw ServiceError.emptyResult }

        let text = response.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ServiceError.emptyResult }
        return text
    }
}

// MARK: Wire types

struct OpenAIChatRequest: Encodable {
    struct Message: Encodable { var role: String; var content: String }
    var model: String
    var messages: [Message]
    var max_completion_tokens: Int
    var temperature: Double
}

struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { var content: String? }
        var message: Message
    }
    var choices: [Choice]
}

struct GeminiRequest: Encodable {
    struct Part: Encodable {
        var text: String?
        var inline_data: InlineData?

        init(text: String? = nil, inline_data: InlineData? = nil) {
            self.text = text
            self.inline_data = inline_data
        }
    }
    struct InlineData: Encodable {
        var mime_type: String
        var data: String
    }
    struct Content: Encodable {
        var role: String?
        var parts: [Part]
    }
    struct SystemInstruction: Encodable { var parts: [Part] }
    struct GenerationConfig: Encodable {
        var temperature: Double
        var maxOutputTokens: Int
    }

    var contents: [Content]
    var systemInstruction: SystemInstruction?
    var generationConfig: GenerationConfig
}

struct GeminiResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable { var text: String? }
            var parts: [Part]?
        }
        var content: Content?
        var finishReason: String?
    }
    var candidates: [Candidate]?

    /// Gemini returns the answer split across parts; joining them is the whole
    /// of the extraction, and an empty candidate list means it declined.
    var firstText: String? {
        let joined = (candidates?.first?.content?.parts ?? [])
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}

struct AnthropicMessagesRequest: Encodable {
    struct Message: Encodable { var role: String; var content: String }
    struct OutputConfig: Encodable { var effort: String }
    var model: String
    var max_tokens: Int
    var system: String
    var messages: [Message]
    var output_config: OutputConfig
    var fallbacks: String
}

struct AnthropicMessagesResponse: Decodable {
    struct Block: Decodable {
        var type: String
        var text: String?
    }
    var content: [Block]
    var stop_reason: String?
}

// MARK: - The on-device narrator

/// The answer when there is no key, no network, or no trustworthy model output.
///
/// This is not a placeholder string. It reads the same evidence the model would
/// have read and writes a real paragraph from it, so the app's default
/// experience — which, with no keys configured, is *everyone's* experience — is
/// an explanation rather than an apology.
///
/// **It does not say the same thing every time, and that is a safety property
/// rather than a flourish.** The original wrote one fixed sentence per verdict.
/// After the third event a reader stops reading it: the paragraph looks like
/// the paragraph they already know, so the one time a clause changed — the one
/// time it said the measurements disagreed — they would have skimmed straight
/// past it. Text that always looks identical trains people not to look.
///
/// So the phrasing is drawn from pools, and two things are true of the draw:
///
/// * **The seed is the evidence.** It is derived from the facts themselves, so
///   the same assessment always reads the same way — reopening a screen does
///   not rewrite the paragraph under somebody, and a screenshot still matches
///   the app. Two different assessments read differently.
/// * **Only the frame varies, never the value.** Every number, unit and name is
///   substituted verbatim from `AnalystFact`. The pools contain sentence
///   scaffolding and nothing else, which is why the same grounding check that
///   polices a remote model passes this unchanged.
public enum OnDeviceNarrator {

    public static func narrate(_ request: AnalystRequest) -> String {
        var rng = SeededRandom(seed: seed(for: request))
        switch request.task {
        case .assessmentNarrative: return assessment(request, &rng)
        case .spokenGuidance: return guidance(request, &rng)
        case .buildingSummary: return summary(request, &rng)
        case .photoDamage: return photo(request, &rng)
        case .plainEnglish: return plain(request, &rng)
        }
    }

    // MARK: Choosing

    /// A seed derived from the request's content.
    ///
    /// Deliberately not `hashValue`: Swift seeds its hasher per process, so a
    /// paragraph keyed on it would be rewritten on every launch — the exact
    /// instability this is meant to avoid. FNV-1a over a canonical rendering is
    /// stable across launches, devices and OS versions.
    private static func seed(for request: AnalystRequest) -> UInt64 {
        var canonical = request.task.rawValue + "|" + request.subject
        for fact in request.facts { canonical += "|\(fact.label)=\(fact.value)" }
        canonical += "|" + request.constraints.joined(separator: ";")

        var hash: UInt64 = 0xcbf29ce484222325
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    private static func pick(_ options: [String], _ rng: inout SeededRandom) -> String {
        guard !options.isEmpty else { return "" }
        return options[Int(rng.next() % UInt64(options.count))]
    }

    private static func value(_ request: AnalystRequest, _ label: String) -> String? {
        request.facts.first { $0.label.caseInsensitiveCompare(label) == .orderedSame }?.value
    }

    /// Joins sentences and repairs the seams.
    ///
    /// Drawing independently from several pools occasionally lands two
    /// sentences that open the same way, which reads as a stutter and is the
    /// one artefact that makes generated text obvious. Cheaper to fix here than
    /// to constrain every pool against every other.
    private static func assemble(_ sentences: [String]) -> String {
        var output: [String] = []
        for sentence in sentences where !sentence.isEmpty {
            if let previous = output.last, opening(of: previous) == opening(of: sentence) {
                continue
            }
            output.append(sentence.hasSuffix(".") ? sentence : sentence + ".")
        }
        return output.joined(separator: " ")
    }

    private static func opening(of sentence: String) -> String {
        sentence.split(separator: " ").prefix(2).joined(separator: " ").lowercased()
    }

    // MARK: Assessment

    private static func assessment(_ request: AnalystRequest,
                                   _ rng: inout SeededRandom) -> String {
        var sentences: [String] = []

        let verdict = request.constraints.first ?? "The verdict is inconclusive"
        sentences.append(verdict)

        if let before = value(request, "Period before"),
           let after = value(request, "Period after temperature correction")
                    ?? value(request, "Period after") {
            sentences.append(pick([
                "The building's natural period was \(before) before the event and \(after) "
                    + "after it, once the seasonal temperature effect had been removed",
                "Measured before the shaking, the period was \(before); measured after, and "
                    + "corrected for temperature, it was \(after)",
                "The rhythm the building sways at went from \(before) to \(after), with the "
                    + "temperature effect already taken out",
                "Period before: \(before). Period after, temperature-corrected: \(after)",
            ], &rng))
        }

        if let residual = value(request, "Residual displacement") {
            sentences.append(pick([
                "It came to rest \(residual) from where it started, which temperature "
                    + "cannot explain",
                "The building settled \(residual) away from its original position — and "
                    + "unlike the period, nothing seasonal accounts for that",
                "A residual offset of \(residual) remains, which is a mechanical change "
                    + "rather than a thermal one",
            ], &rng))
        }

        if let tilt = value(request, "Permanent tilt") {
            sentences.append(pick([
                "A permanent tilt of \(tilt) remains",
                "The structure is now leaning by \(tilt) and has not returned",
                "Tilt of \(tilt) persisted after the shaking stopped",
            ], &rng))
        }

        if let drift = value(request, "Peak storey drift") {
            sentences.append(pick([
                "The worst storey drift reached \(drift)",
                "At its peak, one storey moved \(drift) relative to the one below it",
                "Peak drift between adjacent floors was \(drift)",
            ], &rng))
        }

        if request.facts.count < 3 {
            sentences.append(pick([
                "Few measurements were available, so this reading is weaker than it would "
                    + "be after a fully recorded event",
                "This rests on very little data. A fully recorded event would support a "
                    + "firmer conclusion than this one does",
                "There is not much evidence here, and the conclusion is only as strong as "
                    + "the evidence under it",
            ], &rng))
        }

        sentences.append(pick([
            "This is a screening measurement, not an inspection. It narrows down where a "
                + "qualified engineer should look first",
            "None of this replaces an inspection. What it does is tell an engineer where "
                + "to start",
            "Treat this as a triage result rather than a verdict on the structure. A "
                + "qualified engineer still has to look",
        ], &rng))

        return assemble(sentences)
    }

    // MARK: Spoken guidance

    /// Spoken aloud, and therefore the one place variation is kept on a short
    /// leash. The instruction itself never changes — "stay outside" is always
    /// "stay outside" — only the sentence that follows it.
    private static func guidance(_ request: AnalystRequest,
                                 _ rng: inout SeededRandom) -> String {
        let verdict = (request.constraints.first ?? "").lowercased()

        if verdict.contains("do not enter") || verdict.contains("red") {
            return "Stay outside. " + pick([
                "Do not go back in until an engineer has looked at the building.",
                "Nobody goes back in until this building has been inspected.",
                "The building needs an engineer before anyone re-enters.",
            ], &rng)
        }
        if verdict.contains("limited use") || verdict.contains("amber") {
            return pick([
                "Go in only if you have to, and only briefly. Arrange an inspection today.",
                "Brief trips inside only. Get an inspection booked today.",
                "Limit time indoors to what is necessary, and have it inspected today.",
            ], &rng)
        }
        if verdict.contains("appears safe") || verdict.contains("green") {
            return pick([
                "Nothing structural changed. Check for gas, water and broken glass before "
                    + "settling back in.",
                "No structural change was measured. Still check for gas, water and broken "
                    + "glass first.",
                "The structure reads as unchanged. Look for gas, water and broken glass "
                    + "before you settle.",
            ], &rng)
        }
        return "Drop, cover and hold on. Stay where you are until the shaking stops."
    }

    // MARK: Building summary

    private static func summary(_ request: AnalystRequest,
                                _ rng: inout SeededRandom) -> String {
        var parts: [String] = []
        let material = value(request, "Material") ?? "an unrecorded material"
        let system = value(request, "Structural system") ?? "an unrecorded lateral system"
        let storeys = value(request, "Storeys") ?? "an unrecorded number of"

        parts.append(pick([
            "\(request.subject) is a \(storeys)-storey building in \(material), resisting "
                + "lateral load through \(system)",
            "\(request.subject) rises \(storeys) storeys, is built in \(material), and "
                + "takes its lateral load through \(system)",
            "\(storeys) storeys of \(material), with \(system) carrying the lateral load — "
                + "that is \(request.subject)",
        ], &rng))

        if let period = value(request, "Estimated period") {
            parts.append(pick([
                "Its estimated natural period is \(period), so it responds most strongly to "
                    + "ground motion arriving at about that rhythm",
                "It sways naturally at about \(period), and ground motion at that rhythm is "
                    + "what it responds to most",
                "Estimated period \(period): shaking that arrives at roughly that beat is "
                    + "what this building feels hardest",
            ], &rng))
        }

        if let soil = value(request, "Soil class") {
            parts.append(pick([
                "It sits on \(soil), which shapes how much of the incoming motion reaches "
                    + "the foundation",
                "The ground beneath it is \(soil), and that governs how much of the motion "
                    + "arrives at the foundation in the first place",
                "Founded on \(soil) — the soil decides how much shaking gets through",
            ], &rng))
        }

        if let retrofit = value(request, "Retrofit"), retrofit.lowercased() != "none" {
            parts.append(pick([
                "A \(retrofit) retrofit has been recorded, which stiffens the frame and "
                    + "shortens the period",
                "It has had a \(retrofit) retrofit; that stiffening is why the period is "
                    + "shorter than the bare frame would give",
            ], &rng))
        }

        parts.append(pick([
            "Figures not marked as confirmed are estimates from the building's geometry and "
                + "should be treated as such",
            "Anything not marked confirmed was estimated from geometry, not measured",
            "Where a figure is not marked confirmed, it came from the shape of the building "
                + "rather than from an instrument",
        ], &rng))

        return assemble(parts)
    }

    // MARK: The rest

    private static func photo(_ request: AnalystRequest, _ rng: inout SeededRandom) -> String {
        pick([
            "Photograph stored and timestamped against this building. Automatic description "
                + "needs a vision model, which is not configured, so the image has been kept "
                + "for side-by-side comparison instead: take the same shot from the same "
                + "place after the next event and the two will be shown together. A crack "
                + "that has widened between two photographs is worth far more than any "
                + "single description of one.",
            "Stored and timestamped. There is no vision model configured to describe it, so "
                + "this photograph is being kept for comparison rather than captioned. Take "
                + "the same shot from the same spot after the next event: what matters is "
                + "whether a crack moved, and no description of a single photograph can "
                + "tell you that.",
        ], &rng)
    }

    private static func plain(_ request: AnalystRequest, _ rng: inout SeededRandom) -> String {
        "\(request.subject): \(request.question) " + pick([
            "A full explanation needs an inference key, which is not configured. The "
                + "glossary in this app covers every term used on screen.",
            "Answering this properly needs an inference key, and none is set. Every term "
                + "used on screen is defined in the glossary.",
        ], &rng)
    }
}

// MARK: - Apple's on-device model

/// The model that is already on the phone.
///
/// Tried before any of the keyed providers, and it should be: it needs no key,
/// costs nothing, works with the aeroplane in flight mode, and — the part that
/// matters here — the building's measurements never leave the device. An
/// earthquake app whose explanation of your home requires uploading its
/// structural condition to a third party has a problem the free tier does not
/// solve.
///
/// It is held to exactly the same standard as everything else. The output goes
/// through `GroundingCheck` unchanged, and a number the model invented gets the
/// answer thrown away and the narrator substituted, with the substitution shown
/// on screen. Being local buys privacy and latency; it buys no trust.
enum AppleOnDeviceModel {

    /// Why the on-device path is not being used, in words a user could act on.
    /// Nil when it is available.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.deviceNotEligible):
                return "This device does not support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Apple Intelligence is switched off in Settings."
            case .unavailable(.modelNotReady):
                return "Apple Intelligence is still downloading its model."
            @unknown default:
                return "Apple Intelligence is unavailable."
            }
        }
        return "Apple Intelligence needs iOS 26."
        #else
        return "This build has no on-device model."
        #endif
    }

    static var isAvailable: Bool { unavailableReason == nil }

    /// Returns the model's answer, or nil if it could not produce one.
    ///
    /// Nil rather than throwing: a missing on-device model is not an error
    /// condition, it is the ordinary state of most devices, and the caller's
    /// only reasonable response is to try the next provider.
    static func complete(system: String, user: String, task: AnalystTask) async -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *), isAvailable else { return nil }
        do {
            let session = LanguageModelSession(instructions: system)
            // Low temperature on purpose. This is not creative writing — the
            // paragraph is a restatement of measurements, and a model given
            // room to be interesting here is a model given room to embellish.
            let options = GenerationOptions(temperature: 0.4)
            let response = try await session.respond(to: user, options: options)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}

// MARK: - The analyst

/// Tries each configured provider in order and falls back to the device.
///
/// It never throws. A screen asking for an explanation always receives one; the
/// only thing that varies is who wrote it, and that is reported honestly.
public actor AIAnalyst {
    private let client: ResilientClient
    private let vault: SecretsVault
    private let providers: [InferenceProvider]
    private var cache = LRUCache<String, AnalystAnswer>(countLimit: 64)

    public init(vault: SecretsVault, transport: HTTPTransport = URLSessionHTTPTransport()) {
        self.vault = vault
        self.client = ResilientClient(transport: transport, requestsPerSecond: 2, burst: 4)
        // Free-tier providers first, so a user who has added only the keys
        // that cost nothing still gets the live path rather than the fallback.
        self.providers = [CerebrasProvider(), GeminiProvider(),
                          OpenAIProvider(), AnthropicProvider()]
    }

    /// The providers that could be tried right now, in order. Surfaced in
    /// Settings so the user can see which key is actually doing the work.
    /// In the order they will actually be tried, which is why Apple's model is
    /// last: a key the user added on purpose outranks the one that came with
    /// the phone.
    public func availableProviders() -> [String] {
        let keyed = providers.filter { vault.has($0.key) }.map(\.name)
        return AppleOnDeviceModel.isAvailable ? keyed + ["Apple Intelligence"] : keyed
    }

    public var hasAnyProvider: Bool {
        AppleOnDeviceModel.isAvailable || hasKeyedProvider
    }

    /// Whether any provider needing a key is configured. Distinct from
    /// `hasAnyProvider` because "you have added no keys" and "nothing answered"
    /// are different things to tell somebody.
    public var hasKeyedProvider: Bool {
        providers.contains { vault.has($0.key) }
    }

    /// Why the on-device model is not in use, or nil when it is. Shown in
    /// Settings beside the key list, because "no key configured" and "Apple
    /// Intelligence is switched off" send a user to two different places.
    public var onDeviceModelUnavailableReason: String? {
        AppleOnDeviceModel.unavailableReason
    }

    public func answer(_ request: AnalystRequest) async -> Sourced<AnalystAnswer> {
        let cacheKey = Self.cacheKey(for: request)
        if let hit = cache.value(forKey: cacheKey) {
            return Sourced(hit, origin: .cached, provider: hit.provider)
        }

        let system = GroundedPrompt.system(for: request.task)
        let user = GroundedPrompt.user(request)

        for provider in providers where vault.has(provider.key) {
            do {
                let raw = try await provider.complete(request, system: system, user: user,
                                                      client: client, vault: vault)
                let text = Self.tidy(raw)
                guard GroundingCheck.passes(text, given: request) else {
                    // The model produced a number nobody measured. That is the
                    // one failure this app cannot ship, so the answer is
                    // discarded and the deterministic narrator is used.
                    let fallback = AnalystAnswer(text: OnDeviceNarrator.narrate(request),
                                                 provider: "On device",
                                                 isAIGenerated: false,
                                                 wasSubstituted: true)
                    cache.setValue(fallback, forKey: cacheKey)
                    return Sourced(fallback, origin: .onDevice, provider: provider.name,
                                   note: "The model's answer contained a figure that was "
                                       + "never measured, so it was not used.")
                }
                vault.setStatus(.valid(checkedAt: Date()), for: provider.key)
                let answer = AnalystAnswer(text: text, provider: provider.name,
                                           isAIGenerated: true)
                cache.setValue(answer, forKey: cacheKey)
                return Sourced(answer, origin: .live, provider: provider.name)
            } catch let error as ServiceError {
                if let status = error.keyStatus() { vault.setStatus(status, for: provider.key) }
                continue                                   // try the next provider
            } catch {
                continue
            }
        }

        // Apple's on-device model, after the keyed providers and before the
        // written fallback.
        //
        // The ordering is the whole argument. Ahead of the keyed providers it
        // would quietly overrule somebody who had gone to the trouble of adding
        // a key to a stronger model — their explicit choice, silently
        // discarded. Behind them, it is what actually happens for the large
        // majority of users, who have configured nothing: a real model,
        // running on the phone, for free, with the building's measurements
        // never leaving the device, in place of a paragraph assembled from
        // templates.
        if let raw = await AppleOnDeviceModel.complete(system: system, user: user,
                                                       task: request.task) {
            let text = Self.tidy(raw)
            if GroundingCheck.passes(text, given: request) {
                let answer = AnalystAnswer(text: text, provider: "Apple Intelligence",
                                           isAIGenerated: true)
                cache.setValue(answer, forKey: cacheKey)
                return Sourced(answer, origin: .onDevice, provider: "Apple Intelligence",
                               note: "Answered on this device. Nothing was sent anywhere.")
            }
            // It invented a figure. Exactly the same consequence a remote model
            // gets — being local earns privacy and latency, not leniency.
            let fallback = AnalystAnswer(text: OnDeviceNarrator.narrate(request),
                                         provider: "On device", isAIGenerated: false,
                                         wasSubstituted: true)
            cache.setValue(fallback, forKey: cacheKey)
            return Sourced(fallback, origin: .onDevice, provider: "Apple Intelligence",
                           note: "The on-device model's answer contained a figure that was "
                               + "never measured, so it was not used.")
        }

        let answer = AnalystAnswer(text: OnDeviceNarrator.narrate(request),
                                   provider: "On device", isAIGenerated: false)
        cache.setValue(answer, forKey: cacheKey)
        return Sourced(answer, origin: .onDevice, provider: "On device",
                       note: hasKeyedProvider ? "No inference provider answered."
                                              : "No inference key is configured.")
    }

    /// Describes a photograph of possible damage.
    ///
    /// Vision is a separate path because only one configured provider has it,
    /// and because the failure mode is different: a wrong number in a paragraph
    /// is caught by the grounding check, whereas a confident description of a
    /// crack that is really a paint line cannot be. So the prompt pushes hard
    /// towards "I cannot tell from this photograph", which is both the honest
    /// answer and the useful one — it tells the user to take a better photo.
    public func describePhoto(jpegBase64: String, subject: String,
                              locationLabel: String) async -> Sourced<AnalystAnswer> {
        let request = AnalystRequest(
            task: .photoDamage, subject: subject,
            facts: [AnalystFact(label: "Where the photograph was taken",
                                value: locationLabel.isEmpty ? "not recorded" : locationLabel,
                                source: "entered by the user")],
            question: "Describe what is visible. Say whether it looks structural, "
                    + "non-structural, or impossible to tell from this photograph.")

        // Gemini first: it has a free tier, and photo description is the one
        // thing in this app that genuinely cannot be done on the device, so it
        // should not be the one thing that requires a payment method.
        if let geminiKey = vault.value(for: .geminiAPIKey), !geminiKey.isEmpty {
            if let answer = await describeWithGemini(jpegBase64: jpegBase64, request: request,
                                                    apiKey: geminiKey) {
                return answer
            }
        }

        guard let apiKey = vault.value(for: .openAIAPIKey), !apiKey.isEmpty else {
            return Sourced(AnalystAnswer(text: OnDeviceNarrator.narrate(request),
                                         provider: "On device", isAIGenerated: false),
                           origin: .onDevice, provider: "On device",
                           note: "Photograph description needs a vision key — GEMINI_API_KEY is "
                               + "free. The photograph is stored either way and can be compared "
                               + "with a later one.")
        }

        struct Content: Encodable {
            var type: String
            var text: String?
            var image_url: ImageURL?
            struct ImageURL: Encodable { var url: String }
        }
        struct Message: Encodable { var role: String; var content: [Content] }
        struct Body: Encodable {
            var model: String
            var messages: [Message]
            var max_completion_tokens: Int
        }

        let payload = Body(
            model: "gpt-4o",
            messages: [
                Message(role: "system",
                        content: [Content(type: "text",
                                          text: GroundedPrompt.system(for: .photoDamage),
                                          image_url: nil)]),
                Message(role: "user", content: [
                    Content(type: "text", text: GroundedPrompt.user(request), image_url: nil),
                    Content(type: "image_url", text: nil,
                            image_url: .init(url: "data:image/jpeg;base64,\(jpegBase64)")),
                ]),
            ],
            max_completion_tokens: 400)

        do {
            let http = try HTTPRequest.json(
                "POST", URL(string: "https://api.openai.com/v1/chat/completions")!,
                headers: ["Authorization": "Bearer \(apiKey)"], body: payload, timeout: 40)
            let response: OpenAIChatResponse = try await client.json(http,
                                                                     as: OpenAIChatResponse.self)
            guard let text = response.choices.first?.message.content, !text.isEmpty else {
                throw ServiceError.emptyResult
            }
            vault.setStatus(.valid(checkedAt: Date()), for: .openAIAPIKey)
            return Sourced(AnalystAnswer(text: Self.tidy(text), provider: "OpenAI",
                                         isAIGenerated: true),
                           origin: .live, provider: "OpenAI")
        } catch let error as ServiceError {
            if let status = error.keyStatus() { vault.setStatus(status, for: .openAIAPIKey) }
            return Sourced(AnalystAnswer(text: OnDeviceNarrator.narrate(request),
                                         provider: "On device", isAIGenerated: false),
                           origin: .onDevice, provider: "On device",
                           note: error.userFacingReason)
        } catch {
            return Sourced(AnalystAnswer(text: OnDeviceNarrator.narrate(request),
                                         provider: "On device", isAIGenerated: false),
                           origin: .onDevice, provider: "On device")
        }
    }

    /// The Gemini vision call. Returns nil so the caller can try the next path
    /// rather than treating one provider's silence as the final answer.
    private func describeWithGemini(jpegBase64: String, request: AnalystRequest,
                                    apiKey: String) async -> Sourced<AnalystAnswer>? {
        let payload = GeminiRequest(
            contents: [.init(role: "user", parts: [
                .init(text: GroundedPrompt.user(request)),
                .init(inline_data: .init(mime_type: "image/jpeg", data: jpegBase64)),
            ])],
            systemInstruction: .init(parts: [.init(text: GroundedPrompt.system(for: .photoDamage))]),
            generationConfig: .init(temperature: 0.2, maxOutputTokens: 600))

        do {
            let http = try HTTPRequest.json(
                "POST", GeminiProvider.endpoint(model: GeminiProvider.model),
                headers: ["x-goog-api-key": apiKey], body: payload, timeout: 40)
            let response: GeminiResponse = try await client.json(http, as: GeminiResponse.self)
            guard let text = response.firstText else { return nil }
            vault.setStatus(.valid(checkedAt: Date()), for: .geminiAPIKey)
            return Sourced(AnalystAnswer(text: Self.tidy(text), provider: "Gemini",
                                         isAIGenerated: true),
                           origin: .live, provider: "Gemini")
        } catch let error as ServiceError {
            if let status = error.keyStatus() { vault.setStatus(status, for: .geminiAPIKey) }
            return nil
        } catch {
            return nil
        }
    }

    /// Strips the things a model adds that this app's typography does not want:
    /// markdown emphasis, headings, list bullets and a leading restatement.
    static func tidy(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["**", "*", "###", "##", "#", "`"] {
            out = out.replacingOccurrences(of: marker, with: "")
        }
        out = out.split(separator: "\n")
            .map { line -> String in
                var line = line.trimmingCharacters(in: .whitespaces)
                for bullet in ["- ", "• ", "– "] where line.hasPrefix(bullet) {
                    line = String(line.dropFirst(bullet.count))
                }
                return line
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return out
    }

    static func cacheKey(for request: AnalystRequest) -> String {
        var hasher = Hasher()
        hasher.combine(request.task.rawValue)
        hasher.combine(request.subject)
        hasher.combine(request.question)
        for fact in request.facts { hasher.combine(fact.label); hasher.combine(fact.value) }
        for constraint in request.constraints { hasher.combine(constraint) }
        return String(hasher.finalize())
    }
}

// MARK: - Building the request from domain objects

public extension AnalystRequest {

    /// The narrative for a completed assessment. The verdict is passed as a
    /// constraint, so the analyst explains it and cannot overturn it.
    static func narrative(for assessment: Assessment, building: BuildingModel) -> AnalystRequest {
        var facts: [AnalystFact] = [
            AnalystFact(label: "Storeys", value: "\(building.storeyCount)", source: "library"),
            AnalystFact(label: "Material", value: building.material.label, source: "library"),
            AnalystFact(label: "Structural system", value: building.system.label, source: "library"),
        ]
        if let before = assessment.periodBefore {
            facts.append(AnalystFact(label: "Period before", number: before, unit: "s", decimals: 3))
        }
        if let after = assessment.periodAfter {
            facts.append(AnalystFact(label: "Period after", number: after, unit: "s", decimals: 3))
        }
        if let corrected = assessment.periodAfterTemperatureCorrection {
            facts.append(AnalystFact(label: "Period after temperature correction",
                                     number: corrected, unit: "s", decimals: 3))
        }
        for item in assessment.evidence {
            facts.append(AnalystFact(label: item.kind.label,
                                     value: item.headline,
                                     source: item.source.label))
        }
        let probability = Int((assessment.damageProbability * 100).rounded())
        return AnalystRequest(
            task: .assessmentNarrative,
            subject: building.name,
            facts: facts,
            constraints: [
                "The verdict is \(assessment.verdict.placard).",
                "The computed probability of structural damage is \(probability)%.",
                "This is a screening measurement and never replaces an engineer's inspection.",
            ],
            question: "Explain what was measured, what it means for this building, and what "
                    + "the person should do next.")
    }

    static func summary(for building: BuildingModel) -> AnalystRequest {
        var facts: [AnalystFact] = [
            AnalystFact(label: "Storeys", value: "\(building.storeyCount)", source: "library"),
            AnalystFact(label: "Height", number: building.height, unit: "m", decimals: 1,
                        source: "library"),
            AnalystFact(label: "Material", value: building.material.label, source: "library"),
            AnalystFact(label: "Structural system", value: building.system.label, source: "library"),
            AnalystFact(label: "Soil class", value: building.soil.label, source: "library"),
            AnalystFact(label: "Retrofit", value: building.retrofit.label, source: "library"),
            AnalystFact(label: "Estimated period", number: building.empiricalPeriod,
                        unit: "s", decimals: 2, source: "estimated from geometry"),
        ]
        if let year = building.yearBuilt {
            facts.append(AnalystFact(label: "Year built", value: "\(year)", source: "library"))
        }
        return AnalystRequest(task: .buildingSummary, subject: building.name, facts: facts,
                              question: "Describe how this building is likely to behave in an "
                                      + "earthquake.")
    }

    /// The line that is spoken aloud during an event.
    static func guidance(verdict: SafetyVerdict?, isShaking: Bool,
                         secondsUntilShaking: Double?) -> AnalystRequest {
        var facts: [AnalystFact] = []
        if let seconds = secondsUntilShaking {
            facts.append(AnalystFact(label: "Seconds until strong shaking",
                                     value: "\(Int(seconds.rounded()))"))
        }
        facts.append(AnalystFact(label: "Shaking now", value: isShaking ? "yes" : "no"))
        return AnalystRequest(
            task: .spokenGuidance,
            subject: "the person holding the phone",
            facts: facts,
            constraints: verdict.map { ["The verdict is \($0.placard)."] } ?? [],
            question: "Say what to do, right now, in at most two short sentences.")
    }
}
