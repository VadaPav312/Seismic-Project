import Foundation
import SeismicCore
import SeismicData

// MARK: - Identity

public struct UserAccount: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var email: String?
    public var displayName: String
    public var provider: AuthProvider
    public var tier: VerificationTier
    public var createdAt: Date
    /// Set for guests. A guest is a real account locally; it simply has no
    /// server behind it yet, which is a property of the account rather than a
    /// different kind of user.
    public var isGuest: Bool

    public init(id: String, email: String? = nil, displayName: String,
                provider: AuthProvider, tier: VerificationTier = .unverified,
                createdAt: Date = Date(), isGuest: Bool = false) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.provider = provider
        self.tier = tier
        self.createdAt = createdAt
        self.isGuest = isGuest
    }

    public static func guest() -> UserAccount {
        UserAccount(id: "guest-" + UUID().uuidString, displayName: "Guest",
                    provider: .guest, isGuest: true)
    }
}

public enum AuthProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case guest, apple, google, email
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .guest: "Continue without an account"
        case .apple: "Sign in with Apple"
        case .google: "Continue with Google"
        case .email: "Email and password"
        }
    }

    public var systemImage: String {
        switch self {
        case .guest: "person.crop.circle.dashed"
        case .apple: "apple.logo"
        case .google: "globe"
        case .email: "envelope"
        }
    }

    /// What the user gets by choosing this, said plainly rather than as a
    /// growth-team euphemism.
    public var explanation: String {
        switch self {
        case .guest:
            "Everything works. Your data stays on this device and is not backed up."
        case .apple:
            "Backs up your buildings and assessments, and lets you share a household."
        case .google:
            "Backs up your buildings and assessments, and lets you share a household."
        case .email:
            "Backs up your buildings and assessments. Useful if you have no Apple or Google account."
        }
    }
}

// MARK: - Households

public struct Household: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var inviteCode: String
    public var createdAt: Date
    public var members: [Member]

    public struct Member: Identifiable, Codable, Sendable, Equatable {
        public var id: String
        public var displayName: String
        public var role: Role
        /// Optional, and the feature degrades rather than fails without it: a
        /// member with no number gets a message prepared for the share sheet
        /// instead of an SMS. Requiring one would mean nobody could be added
        /// until their number was to hand.
        public var phoneNumber: String?
        public var joinedAt: Date
        public var lastCheckIn: Date?
        public var checkInStatus: CheckInStatus

        public init(id: String, displayName: String, role: Role,
                    phoneNumber: String? = nil,
                    joinedAt: Date = Date(), lastCheckIn: Date? = nil,
                    checkInStatus: CheckInStatus = .unknown) {
            self.id = id
            self.displayName = displayName
            self.role = role
            self.phoneNumber = phoneNumber?.isEmpty == true ? nil : phoneNumber
            self.joinedAt = joinedAt
            self.lastCheckIn = lastCheckIn
            self.checkInStatus = checkInStatus
        }

        public var isReachableBySMS: Bool { phoneNumber != nil }
    }

    public enum Role: String, Codable, Sendable, CaseIterable, Identifiable {
        case owner, adult, child, viewer
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .owner: "Owner"
            case .adult: "Adult"
            case .child: "Child"
            case .viewer: "Viewer"
            }
        }

        /// Only an owner or an adult may fire an actuator remotely. A viewer
        /// sees everything and touches nothing, which is the right shape for a
        /// worried relative in another city.
        public var canControlActuators: Bool {
            self == .owner || self == .adult
        }

        public var canEditBuildings: Bool { self == .owner || self == .adult }
        public var canInvite: Bool { self == .owner }
    }

    public enum CheckInStatus: String, Codable, Sendable {
        case unknown, safe, needsHelp, noAnswer

        public var label: String {
            switch self {
            case .unknown: "Not asked"
            case .safe: "Safe"
            case .needsHelp: "Needs help"
            case .noAnswer: "No answer"
            }
        }

        public var systemImage: String {
            switch self {
            case .unknown: "questionmark.circle"
            case .safe: "checkmark.circle.fill"
            case .needsHelp: "exclamationmark.triangle.fill"
            case .noAnswer: "clock.badge.questionmark"
            }
        }
    }

    public init(id: UUID = UUID(), name: String, inviteCode: String? = nil,
                createdAt: Date = Date(), members: [Member] = []) {
        self.id = id
        self.name = name
        self.inviteCode = inviteCode ?? Self.generateInviteCode()
        self.createdAt = createdAt
        self.members = members
    }

    /// Six characters that can be read aloud over a bad phone line.
    ///
    /// Vowels are excluded so a code can never spell a word, and every
    /// look-alike pair is broken rather than merely thinned: no I/L/1, no O/0,
    /// no S/5, no Z/2, no G/6, no B/8. What remains is 22 characters, which at
    /// six places is still 113 million codes.
    public static func generateInviteCode(using generator: inout SeededRandom) -> String {
        let alphabet = Array("BCDFHJKMNPQRTVWXY34679")
        return String((0..<6).map { _ in
            alphabet[Int(generator.next() % UInt64(alphabet.count))]
        })
    }

    public static func generateInviteCode() -> String {
        var generator = SeededRandom(seed: UInt64(Date().timeIntervalSince1970 * 1000)
                                         ^ UInt64(UInt32.random(in: 0...UInt32.max)))
        return generateInviteCode(using: &generator)
    }

    /// The share link. A universal link so it opens the app when installed and
    /// a web page explaining what this is when it is not.
    public var inviteURL: URL? {
        URL(string: "https://seismic.app/join/\(inviteCode)")
    }

    public var membersNeedingHelp: [Member] {
        members.filter { $0.checkInStatus == .needsHelp }
    }

    public var membersUnaccountedFor: [Member] {
        members.filter { $0.checkInStatus == .unknown || $0.checkInStatus == .noAnswer }
    }
}

// MARK: - Supabase

/// A thin PostgREST and GoTrue client.
///
/// Everything is written so that "no Supabase project" is an ordinary state
/// rather than an error path: the sync queue in `SeismicData` keeps working, the
/// household lives locally, and if a project is configured later the queue
/// drains into it. Nothing is lost by never signing in.
public actor CloudService {
    private let vault: SecretsVault
    private let client: ResilientClient
    private var session: CloudSession?

    public struct CloudSession: Codable, Sendable, Equatable {
        public var accessToken: String
        public var refreshToken: String
        public var expiresAt: Date
        public var account: UserAccount

        public var isExpired: Bool { Date() >= expiresAt }
    }

    public init(vault: SecretsVault, transport: HTTPTransport = URLSessionHTTPTransport()) {
        self.vault = vault
        self.client = ResilientClient(transport: transport, requestsPerSecond: 5, burst: 10)
    }

    public nonisolated var isConfigured: Bool {
        vault.has(.supabaseURL) && vault.has(.supabaseAnonKey)
    }

    private func baseURL() throws -> URL {
        guard let raw = vault.value(for: .supabaseURL), let url = URL(string: raw) else {
            throw ServiceError.notConfigured("Supabase")
        }
        return url
    }

    private func anonKey() throws -> String {
        guard let key = vault.value(for: .supabaseAnonKey), !key.isEmpty else {
            throw ServiceError.noCredential(.supabaseAnonKey)
        }
        return key
    }

    private func headers(authenticated: Bool = true) throws -> [String: String] {
        let key = try anonKey()
        var headers = ["apikey": key, "Content-Type": "application/json"]
        if authenticated, let token = session?.accessToken {
            headers["Authorization"] = "Bearer \(token)"
        } else {
            headers["Authorization"] = "Bearer \(key)"
        }
        return headers
    }

    // MARK: Authentication

    public func signUp(email: String, password: String,
                       displayName: String) async throws -> CloudSession {
        struct Body: Encodable { var email: String; var password: String }
        let url = try baseURL().appendingPathComponent("auth/v1/signup")
        let request = try HTTPRequest.json("POST", url, headers: headers(authenticated: false),
                                           body: Body(email: email, password: password))
        let response: GoTrueSession = try await client.json(request, as: GoTrueSession.self)
        return try store(response, provider: .email, fallbackName: displayName)
    }

    public func signIn(email: String, password: String) async throws -> CloudSession {
        struct Body: Encodable { var email: String; var password: String }
        let url = try baseURL()
            .appendingPathComponent("auth/v1/token")
            .appending(queryItems: [URLQueryItem(name: "grant_type", value: "password")])
        let request = try HTTPRequest.json("POST", url, headers: headers(authenticated: false),
                                           body: Body(email: email, password: password))
        let response: GoTrueSession = try await client.json(request, as: GoTrueSession.self)
        return try store(response, provider: .email, fallbackName: email)
    }

    /// Exchanges an Apple or Google identity token for a session.
    ///
    /// Sign in with Apple and Google Sign-In both hand the app an ID token; the
    /// exchange is identical for both, which is why there is one method rather
    /// than two nearly-identical ones.
    public func signIn(idToken: String, provider: AuthProvider,
                       displayName: String) async throws -> CloudSession {
        struct Body: Encodable { var provider: String; var id_token: String }
        let url = try baseURL()
            .appendingPathComponent("auth/v1/token")
            .appending(queryItems: [URLQueryItem(name: "grant_type", value: "id_token")])
        let request = try HTTPRequest.json(
            "POST", url, headers: headers(authenticated: false),
            body: Body(provider: provider == .apple ? "apple" : "google", id_token: idToken))
        let response: GoTrueSession = try await client.json(request, as: GoTrueSession.self)
        return try store(response, provider: provider, fallbackName: displayName)
    }

    /// The OAuth URL for providers without a native token flow. The app opens
    /// this in an authentication session and hands back the redirect.
    public nonisolated func authorizationURL(provider: AuthProvider,
                                             redirect: String) -> URL? {
        guard let raw = vault.value(for: .supabaseURL), var components =
                URLComponents(string: raw + "/auth/v1/authorize") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "provider", value: provider.rawValue),
            URLQueryItem(name: "redirect_to", value: redirect),
        ]
        return components.url
    }

    private func store(_ response: GoTrueSession, provider: AuthProvider,
                       fallbackName: String) throws -> CloudSession {
        guard let accessToken = response.access_token else {
            throw ServiceError.decoding("No access token in the sign-in response")
        }
        let account = UserAccount(
            id: response.user?.id ?? UUID().uuidString,
            email: response.user?.email,
            displayName: response.user?.user_metadata?.full_name ?? fallbackName,
            provider: provider,
            tier: .unverified)
        let created = CloudSession(
            accessToken: accessToken,
            refreshToken: response.refresh_token ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in ?? 3600)),
            account: account)
        session = created
        return created
    }

    public func restore(_ session: CloudSession) { self.session = session }
    public func signOut() { session = nil }
    public func currentSession() -> CloudSession? { session }

    // MARK: Sync

    /// Pushes one queued item. Conflicts are surfaced, never resolved silently.
    ///
    /// `Prefer: resolution=merge-duplicates` makes the server treat a repeat of
    /// the same row as an upsert, which is what an offline queue replaying after
    /// a week of no signal actually needs.
    public func push(table: String, payload: Data) async throws {
        let url = try baseURL().appendingPathComponent("rest/v1/\(table)")
        var requestHeaders = try headers()
        requestHeaders["Prefer"] = "resolution=merge-duplicates,return=minimal"
        _ = try await client.send(HTTPRequest(method: "POST", url: url,
                                              headers: requestHeaders, body: payload,
                                              timeout: 25))
    }

    public func fetch<T: Decodable>(table: String, query: [URLQueryItem],
                                    as type: T.Type) async throws -> T {
        let url = try baseURL()
            .appendingPathComponent("rest/v1/\(table)")
            .appending(queryItems: query)
        return try await client.json(HTTPRequest(url: url, headers: try headers(), timeout: 25),
                                     as: type)
    }

    /// Community tags near a point. The one query that has to work when a whole
    /// city is opening the app at once, so it is deliberately narrow: a bounding
    /// box, a time cutoff and a row limit.
    public func nearbyTags(latitude: Double, longitude: Double,
                           radiusKm: Double) async -> Sourced<[CommunityTag]> {
        let degrees = radiusKm / 111.0
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-72 * 3600))
        do {
            let tags: [CommunityTag] = try await fetch(
                table: "community_tags",
                query: [URLQueryItem(name: "latitude", value: "gte.\(latitude - degrees)"),
                        URLQueryItem(name: "latitude", value: "lte.\(latitude + degrees)"),
                        URLQueryItem(name: "longitude", value: "gte.\(longitude - degrees)"),
                        URLQueryItem(name: "longitude", value: "lte.\(longitude + degrees)"),
                        URLQueryItem(name: "postedAt", value: "gte.\(since)"),
                        URLQueryItem(name: "limit", value: "300")],
                as: [CommunityTag].self)
            return Sourced(tags, origin: .live, provider: "Supabase")
        } catch {
            return Sourced([], origin: .onDevice, provider: "None",
                           note: isConfigured ? "The community service did not answer."
                                              : "No community service is configured, so the map "
                                              + "shows your own buildings and the seeded example "
                                              + "neighbourhood.")
        }
    }
}

struct GoTrueSession: Decodable {
    struct User: Decodable {
        struct Metadata: Decodable { var full_name: String? }
        var id: String
        var email: String?
        var user_metadata: Metadata?
    }
    var access_token: String?
    var refresh_token: String?
    var expires_in: Int?
    var user: User?
}

// MARK: - Escalation

/// Reaching household members who have not checked in.
///
/// With Twilio configured it sends an SMS. Without it, the message is handed
/// back for the share sheet so the user sends it themselves — which is slower
/// but not a dead end, and is what most people will actually experience.
public actor EscalationService {
    private let vault: SecretsVault
    private let client: ResilientClient

    public init(vault: SecretsVault, transport: HTTPTransport = URLSessionHTTPTransport()) {
        self.vault = vault
        self.client = ResilientClient(transport: transport, requestsPerSecond: 2, burst: 4)
    }

    public enum Delivery: Sendable, Equatable {
        case sent(to: String)
        /// The app should present the share sheet with this text.
        case handBackToUser(String)
    }

    public static func message(buildingName: String, verdict: SafetyVerdict?,
                               senderName: String) -> String {
        let state = verdict.map { "The assessment for \(buildingName) is: \($0.placard)." }
            ?? "An earthquake was detected at \(buildingName)."
        return "\(senderName) via Seismic: \(state) Reply SAFE if you are all right, "
             + "or HELP if you are not."
    }

    public func escalate(to phoneNumber: String, message: String) async -> Sourced<Delivery> {
        // No number, nothing to send to. Falling through would post to Twilio
        // with an empty recipient and report a service failure for what is
        // really a missing field.
        guard !phoneNumber.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Sourced(.handBackToUser(message), origin: .onDevice, provider: "Share sheet",
                           note: "No phone number is recorded for them, so the message is ready "
                               + "for you to send however you normally would.")
        }
        guard let sid = vault.value(for: .twilioAccountSID), !sid.isEmpty,
              let token = vault.value(for: .twilioAuthToken), !token.isEmpty,
              let from = vault.value(for: .twilioFromNumber), !from.isEmpty else {
            return Sourced(.handBackToUser(message), origin: .onDevice, provider: "Share sheet",
                           note: "No SMS service is configured, so the message is ready for you "
                               + "to send yourself.")
        }

        let url = URL(string: "https://api.twilio.com/2010-04-01/Accounts/\(sid)/Messages.json")!
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "To", value: phoneNumber),
                           URLQueryItem(name: "From", value: from),
                           URLQueryItem(name: "Body", value: message)]
        let body = (form.percentEncodedQuery ?? "").data(using: .utf8) ?? Data()
        let credentials = Data("\(sid):\(token)".utf8).base64EncodedString()

        do {
            _ = try await client.send(HTTPRequest(
                method: "POST", url: url,
                headers: ["Authorization": "Basic \(credentials)",
                          "Content-Type": "application/x-www-form-urlencoded"],
                body: body, timeout: 20))
            vault.setStatus(.valid(checkedAt: Date()), for: .twilioAuthToken)
            return Sourced(.sent(to: phoneNumber), origin: .live, provider: "Twilio")
        } catch let error as ServiceError {
            if let status = error.keyStatus() { vault.setStatus(status, for: .twilioAuthToken) }
            return Sourced(.handBackToUser(message), origin: .onDevice, provider: "Share sheet",
                           note: "The SMS service did not answer, so the message is ready for "
                               + "you to send yourself.")
        } catch {
            return Sourced(.handBackToUser(message), origin: .onDevice, provider: "Share sheet")
        }
    }
}
