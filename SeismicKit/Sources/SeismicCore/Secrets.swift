import Foundation
#if canImport(Security)
import Security
#endif

/// Every credential the app can use. Nothing here is required: each key upgrades
/// one simulated path to a live one, and the app is fully demonstrable with all
/// of them empty.
public enum SecretKey: String, CaseIterable, Codable, Sendable, Identifiable {
    // AI and voice
    case cerebrasAPIKey = "CEREBRAS_API_KEY"
    case cerebrasModel = "CEREBRAS_MODEL"
    case openAIAPIKey = "OPENAI_API_KEY"
    case anthropicAPIKey = "ANTHROPIC_API_KEY"
    case elevenLabsAPIKey = "ELEVENLABS_API_KEY"
    case elevenLabsVoiceID = "ELEVENLABS_VOICE_ID"
    // Search
    case serperAPIKey = "SERPER_API_KEY"
    case tavilyAPIKey = "TAVILY_API_KEY"
    case braveSearchAPIKey = "BRAVE_SEARCH_API_KEY"
    case exaAPIKey = "EXA_API_KEY"
    case wikidataEndpoint = "WIKIDATA_ENDPOINT"
    // Geospatial
    case googleMapsAPIKey = "GOOGLE_MAPS_API_KEY"
    case google3DTilesKey = "GOOGLE_3D_TILES_KEY"
    case googlePlacesAPIKey = "GOOGLE_PLACES_API_KEY"
    case mapboxAccessToken = "MAPBOX_ACCESS_TOKEN"
    case overpassEndpoint = "OVERPASS_API_ENDPOINT"
    // Identity and cloud
    case googleClientID = "GOOGLE_CLIENT_ID"
    case googleServerClientID = "GOOGLE_SERVER_CLIENT_ID"
    case supabaseURL = "SUPABASE_URL"
    case supabaseAnonKey = "SUPABASE_ANON_KEY"
    case cloudStorageBucket = "CLOUD_STORAGE_BUCKET"
    // Alerts
    case twilioAccountSID = "TWILIO_ACCOUNT_SID"
    case twilioAuthToken = "TWILIO_AUTH_TOKEN"
    case twilioFromNumber = "TWILIO_FROM_NUMBER"
    case pushServerKey = "PUSH_SERVER_KEY"
    // Context
    case openWeatherAPIKey = "OPENWEATHER_API_KEY"
    case noaaAPIKey = "NOAA_API_KEY"
    // Operations
    case sentryDSN = "SENTRY_DSN"
    case analyticsKey = "ANALYTICS_KEY"

    public var id: String { rawValue }

    public enum Group: String, CaseIterable, Sendable, Identifiable {
        case ai = "AI and voice"
        case search = "Live web search"
        case geospatial = "Geospatial and 3D"
        case cloud = "Identity and cloud"
        case alerts = "Alerts"
        case context = "Context data"
        case operations = "Operations"
        public var id: String { rawValue }
    }

    public var group: Group {
        switch self {
        case .cerebrasAPIKey, .cerebrasModel, .openAIAPIKey, .anthropicAPIKey,
             .elevenLabsAPIKey, .elevenLabsVoiceID: .ai
        case .serperAPIKey, .tavilyAPIKey, .braveSearchAPIKey, .exaAPIKey, .wikidataEndpoint: .search
        case .googleMapsAPIKey, .google3DTilesKey, .googlePlacesAPIKey,
             .mapboxAccessToken, .overpassEndpoint: .geospatial
        case .googleClientID, .googleServerClientID, .supabaseURL,
             .supabaseAnonKey, .cloudStorageBucket: .cloud
        case .twilioAccountSID, .twilioAuthToken, .twilioFromNumber, .pushServerKey: .alerts
        case .openWeatherAPIKey, .noaaAPIKey: .context
        case .sentryDSN, .analyticsKey: .operations
        }
    }

    /// Shown verbatim in Settings → API Keys, next to the field.
    public var purpose: String {
        switch self {
        case .cerebrasAPIKey: "Primary inference. Fast enough to speak guidance during an event."
        case .cerebrasModel: "Which Cerebras model to call."
        case .openAIAPIKey: "Fallback inference, plus photo damage analysis and photo-to-building modelling."
        case .anthropicAPIKey: "Optional secondary fallback for long-form report writing."
        case .elevenLabsAPIKey: "Calm emergency voice and formal report readout."
        case .elevenLabsVoiceID: "Which ElevenLabs voice to use."
        case .serperAPIKey: "Primary search for building import."
        case .tavilyAPIKey: "AI search with content extraction, for structured building facts."
        case .braveSearchAPIKey: "Fallback search provider."
        case .exaAPIKey: "Semantic search over technical and engineering sources."
        case .wikidataEndpoint: "Structured building data. No key needed — endpoint only."
        case .googleMapsAPIKey: "Basemaps and geocoding."
        case .google3DTilesKey: "Photorealistic 3D building geometry."
        case .googlePlacesAPIKey: "Place details and photos in the import disambiguation list."
        case .mapboxAccessToken: "Alternative basemap and vector tiles."
        case .overpassEndpoint: "OpenStreetMap footprints and heights. No key needed — endpoint only."
        case .googleClientID: "Google Sign-In on this device."
        case .googleServerClientID: "Server client ID for Google ID tokens."
        case .supabaseURL: "Cloud sync, households and the community network."
        case .supabaseAnonKey: "Public anon key for the Supabase project."
        case .cloudStorageBucket: "Where recordings, photos and reports are stored."
        case .twilioAccountSID: "SMS escalation to household members who have not checked in."
        case .twilioAuthToken: "Twilio auth token."
        case .twilioFromNumber: "Number the SMS escalation is sent from."
        case .pushServerKey: "Push relay for early warning and nearby community tags."
        case .openWeatherAPIKey: "Temperature, so seasonal period swings are not mistaken for damage."
        case .noaaAPIKey: "Tsunami advisories after an offshore event."
        case .sentryDSN: "Crash and error reporting."
        case .analyticsKey: "Product analytics. Opt-in only."
        }
    }

    /// What the app does when this key is absent. Every one of these is a real,
    /// working path — not an apology.
    public var fallbackBehaviour: String {
        switch self {
        case .cerebrasAPIKey, .openAIAPIKey, .anthropicAPIKey:
            "Narrative and answers are generated by the on-device analyst from the same measurements."
        case .elevenLabsAPIKey, .elevenLabsVoiceID:
            "Speech uses the system voice, which works offline."
        case .serperAPIKey, .tavilyAPIKey, .braveSearchAPIKey, .exaAPIKey, .wikidataEndpoint:
            "Building search runs against the bundled reference library of well-known buildings."
        case .googleMapsAPIKey, .mapboxAccessToken:
            "Maps use OpenStreetMap tiles, which need no key."
        case .google3DTilesKey:
            "Geometry is generated parametrically from the building's facts."
        case .googlePlacesAPIKey:
            "Candidate thumbnails come from the bundled library."
        case .overpassEndpoint:
            "Footprints fall back to a parametric plan from the stated floor area."
        case .googleClientID, .googleServerClientID:
            "Sign-in offers Apple and email; guest mode keeps everything local."
        case .supabaseURL, .supabaseAnonKey, .cloudStorageBucket:
            "Everything is stored locally and queued; sync resumes if you add a project later."
        case .twilioAccountSID, .twilioAuthToken, .twilioFromNumber:
            "Escalation falls back to the system share sheet so you send the message yourself."
        case .pushServerKey:
            "Alerts are delivered as local notifications on this device."
        case .openWeatherAPIKey:
            "Temperature correction uses the node's own structure thermistor."
        case .noaaAPIKey:
            "Tsunami context is omitted; everything else is unaffected."
        case .sentryDSN, .analyticsKey:
            "Nothing is reported anywhere. This is the default."
        case .cerebrasModel:
            "Uses the default model name."
        }
    }

    /// Keys that are endpoints rather than credentials — they ship with a
    /// working public default, so they are never shown as "missing".
    public var defaultValue: String? {
        switch self {
        case .wikidataEndpoint: "https://query.wikidata.org/sparql"
        case .overpassEndpoint: "https://overpass-api.de/api/interpreter"
        case .cerebrasModel: "llama-3.3-70b"
        default: nil
        }
    }

    public var isSensitive: Bool { defaultValue == nil }
}

/// Per-key state, exactly as Settings shows it.
public enum KeyStatus: Equatable, Sendable, Codable {
    case missing
    case present                       // stored, never exercised
    case valid(checkedAt: Date)
    case failing(reason: String, at: Date)
    case rateLimited(until: Date)

    public var label: String {
        switch self {
        case .missing: "Missing"
        case .present: "Present"
        case .valid: "Valid"
        case .failing: "Failing"
        case .rateLimited: "Rate limited"
        }
    }

    public var isUsable: Bool {
        switch self {
        case .present, .valid: true
        case .missing, .failing: false
        case .rateLimited(let until): until < Date()
        }
    }
}

/// Parses a dotenv file. Tolerant on purpose — a user hand-editing `.env`
/// should never be punished for a stray quote or a trailing comment.
public enum EnvFileParser {
    public static func parse(_ contents: String) -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                // Quoted: take everything up to the closing quote and discard
                // whatever follows, which is a trailing comment or stray text.
                let body = value.dropFirst()
                if let close = body.firstIndex(of: quote) {
                    value = String(body[body.startIndex..<close])
                } else {
                    value = String(body)      // unterminated quote — keep the content
                }
            } else if let hash = value.range(of: " #") {
                // Unquoted: a comment starts at the first ` #`.
                value = String(value[value.startIndex..<hash.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }
            guard !key.isEmpty else { continue }
            out[key] = value
        }
        return out
    }
}

/// Where secrets actually live. Keychain on device; an in-memory dictionary
/// everywhere else so tests never touch the user's keychain.
public protocol SecretStorage: AnyObject, Sendable {
    func read(_ key: String) -> String?
    func write(_ key: String, value: String?)
    func allKeys() -> [String]
}

public final class InMemorySecretStorage: SecretStorage, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()
    public init(seed: [String: String] = [:]) { values = seed }

    public func read(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }
    public func write(_ key: String, value: String?) {
        lock.lock(); defer { lock.unlock() }
        if let value, !value.isEmpty { values[key] = value } else { values.removeValue(forKey: key) }
    }
    public func allKeys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(values.keys)
    }
}

#if canImport(Security)
public final class KeychainSecretStorage: SecretStorage, @unchecked Sendable {
    private let service: String
    private let lock = NSLock()

    public init(service: String = "app.seismic.secrets") { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    public func read(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ key: String, value: String?) {
        lock.lock(); defer { lock.unlock() }
        let q = query(key)
        SecItemDelete(q as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    public func allKeys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        q[kSecReturnData as String] = false
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let rows = item as? [[String: Any]] else { return [] }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}
#endif

/// The single place anything asks "do I have a key for this?".
///
/// Resolution order is deliberate: a value typed in Settings always beats a
/// value that came from `.env`, because the user typing it is the more recent
/// and more deliberate act.
public final class SecretsVault: @unchecked Sendable {
    private let storage: SecretStorage
    private var envDefaults: [String: String] = [:]
    private var statuses: [SecretKey: KeyStatus] = [:]
    private let lock = NSLock()

    public init(storage: SecretStorage) { self.storage = storage }

    /// Loads `.env` on first launch. Values already in secure storage win, so a
    /// stale `.env` never clobbers something the user typed.
    @discardableResult
    public func bootstrapFromEnvFile(at url: URL?) -> Int {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return bootstrap(from: EnvFileParser.parse(text))
    }

    @discardableResult
    public func bootstrap(from values: [String: String]) -> Int {
        lock.lock()
        envDefaults = values
        lock.unlock()
        var loaded = 0
        for key in SecretKey.allCases {
            guard let v = values[key.rawValue], !v.isEmpty else { continue }
            if storage.read(key.rawValue) == nil {
                storage.write(key.rawValue, value: v)
                loaded += 1
            }
        }
        return loaded
    }

    public func value(for key: SecretKey) -> String? {
        if let v = storage.read(key.rawValue), !v.isEmpty { return v }
        lock.lock(); let env = envDefaults[key.rawValue]; lock.unlock()
        if let env, !env.isEmpty { return env }
        return key.defaultValue
    }

    public func has(_ key: SecretKey) -> Bool {
        guard let v = value(for: key) else { return false }
        return !v.isEmpty
    }

    public func set(_ key: SecretKey, to value: String?) {
        storage.write(key.rawValue, value: value)
        lock.lock()
        statuses[key] = (value?.isEmpty ?? true) ? .missing : .present
        lock.unlock()
    }

    public func clear(_ key: SecretKey) { set(key, to: nil) }

    public func status(for key: SecretKey) -> KeyStatus {
        lock.lock(); let cached = statuses[key]; lock.unlock()
        if let cached, cached != .missing || !has(key) { return cached }
        return has(key) ? .present : .missing
    }

    public func setStatus(_ status: KeyStatus, for key: SecretKey) {
        lock.lock(); statuses[key] = status; lock.unlock()
    }

    /// Redacted form for logs and diagnostics — enough to tell two keys apart,
    /// never enough to use one.
    public func fingerprint(for key: SecretKey) -> String {
        guard let v = value(for: key), !v.isEmpty else { return "—" }
        guard v.count > 8 else { return String(repeating: "•", count: v.count) }
        return "\(v.prefix(3))…\(v.suffix(3))  (\(v.count) chars)"
    }

    public var configuredCount: Int {
        SecretKey.allCases.filter { $0.isSensitive && has($0) }.count
    }
}
