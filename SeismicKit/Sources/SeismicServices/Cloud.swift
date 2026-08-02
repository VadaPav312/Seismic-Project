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

    /// One in-flight OAuth attempt.
    ///
    /// The verifier has to outlive the round trip to Google and back, and it
    /// must never be sent anywhere except the final token exchange — that is
    /// the whole point of PKCE. It is held by the caller rather than stored on
    /// the service so that an abandoned sign-in leaves nothing behind.
    public struct OAuthAttempt: Sendable {
        public let url: URL
        public let provider: AuthProvider
        public let callbackScheme: String
        fileprivate let verifier: String
    }

    /// Starts a browser-based sign-in.
    ///
    /// PKCE rather than the implicit flow: a public client cannot keep a secret,
    /// so the exchange is bound to a one-time verifier this app generates and
    /// never transmits until the end. `completeOAuth` still accepts an implicit
    /// fragment response, because whether a Supabase project returns a code or
    /// a token depends on its configuration and getting that wrong should not
    /// be the difference between signing in and staring at a spinner.
    public nonisolated func beginOAuth(provider: AuthProvider,
                                       redirect: String = "seismic://auth") -> OAuthAttempt? {
        guard let raw = vault.value(for: .supabaseURL),
              var components = URLComponents(string: raw + "/auth/v1/authorize"),
              let scheme = URLComponents(string: redirect)?.scheme
        else { return nil }

        let verifier = PKCE.verifier()
        components.queryItems = [
            URLQueryItem(name: "provider", value: provider.rawValue),
            URLQueryItem(name: "redirect_to", value: redirect),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
        ]
        guard let url = components.url else { return nil }
        return OAuthAttempt(url: url, provider: provider,
                            callbackScheme: scheme, verifier: verifier)
    }

    /// Turns the callback URL into a session.
    ///
    /// Three shapes arrive here and all three are real: an error the provider
    /// wants explained, a PKCE authorisation code, and an implicit fragment
    /// carrying the tokens directly.
    public func completeOAuth(callback: URL, attempt: OAuthAttempt) async throws -> CloudSession {
        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let fragment = fragmentItems(of: callback)

        func value(_ name: String) -> String? {
            query.first { $0.name == name }?.value ?? fragment.first { $0.name == name }?.value
        }

        // Google's own refusals travel in the redirect, not in an HTTP status.
        // Surfacing the provider's wording beats "sign-in failed".
        if let description = value("error_description") ?? value("error") {
            throw ServiceError.upstream(
                description.replacingOccurrences(of: "+", with: " "))
        }

        if let code = value("code") {
            struct Body: Encodable { var auth_code: String; var code_verifier: String }
            let url = try baseURL()
                .appendingPathComponent("auth/v1/token")
                .appending(queryItems: [URLQueryItem(name: "grant_type", value: "pkce")])
            let request = try HTTPRequest.json(
                "POST", url, headers: headers(authenticated: false),
                body: Body(auth_code: code, code_verifier: attempt.verifier))
            let response: GoTrueSession = try await client.json(request, as: GoTrueSession.self)
            return try store(response, provider: attempt.provider,
                             fallbackName: attempt.provider.label)
        }

        if let accessToken = value("access_token") {
            let response = GoTrueSession(
                access_token: accessToken,
                refresh_token: value("refresh_token"),
                expires_in: value("expires_in").flatMap(Int.init),
                user: try? await profile(accessToken: accessToken))
            return try store(response, provider: attempt.provider,
                             fallbackName: attempt.provider.label)
        }

        throw ServiceError.decoding("The sign-in callback carried neither a code nor a token.")
    }

    /// The implicit flow hands back a token and nothing else, so the display
    /// name and email have to be asked for separately.
    private func profile(accessToken: String) async throws -> GoTrueSession.User {
        let url = try baseURL().appendingPathComponent("auth/v1/user")
        var requestHeaders = try headers(authenticated: false)
        requestHeaders["Authorization"] = "Bearer \(accessToken)"
        return try await client.json(HTTPRequest(url: url, headers: requestHeaders, timeout: 20),
                                     as: GoTrueSession.User.self)
    }

    private nonisolated func fragmentItems(of url: URL) -> [URLQueryItem] {
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment,
              !fragment.isEmpty else { return [] }
        return URLComponents(string: "?" + fragment)?.queryItems ?? []
    }

    /// Renews the access token when it is close to expiry.
    ///
    /// Called before anything that needs authorisation. A safety app that
    /// silently stops syncing an hour after sign-in is worse than one that
    /// never signed in, because the status line claims everything is fine.
    @discardableResult
    public func refreshIfNeeded() async -> Bool {
        guard let current = session else { return false }
        guard current.expiresAt.timeIntervalSinceNow < 120 else { return true }
        guard !current.refreshToken.isEmpty else { return false }
        do {
            struct Body: Encodable { var refresh_token: String }
            let url = try baseURL()
                .appendingPathComponent("auth/v1/token")
                .appending(queryItems: [URLQueryItem(name: "grant_type",
                                                     value: "refresh_token")])
            let request = try HTTPRequest.json(
                "POST", url, headers: headers(authenticated: false),
                body: Body(refresh_token: current.refreshToken))
            let response: GoTrueSession = try await client.json(request, as: GoTrueSession.self)
            _ = try store(response, provider: current.account.provider,
                          fallbackName: current.account.displayName)
            // A refresh grant does not always echo the user back. Minting a new
            // account id here would orphan every row already synced under the
            // old one, so the identity is carried across explicitly rather than
            // left to whatever the response happened to contain.
            if response.user == nil { session?.account = current.account }
            return true
        } catch {
            return false
        }
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

    /// What deleting an account was actually able to do.
    ///
    /// Returned rather than thrown, because "some of it worked" is the normal
    /// outcome and the user has to be told which parts. An account deletion
    /// that reports success while rows remain on a server is the single most
    /// dishonest thing this app could do, and a thrown error would collapse a
    /// partial result into a total failure.
    public struct DeletionOutcome: Sendable, Equatable {
        /// Rows removed from each table, by name.
        public var clearedTables: [String] = []
        /// Tables that refused, with the reason.
        public var failures: [String: String] = [:]
        /// Whether the identity itself was removed from the auth server.
        public var identityRemoved = false
        /// Why the identity could not be removed, when it could not.
        public var identityFailure: String?

        public var isComplete: Bool { failures.isEmpty && identityRemoved }
    }

    /// Deletes everything this account owns on the server, then the account.
    ///
    /// Data first, identity last, and that order is not arbitrary: deleting the
    /// identity revokes the token every subsequent request needs, so an
    /// identity-first deletion leaves the rows orphaned and unreachable
    /// for ever — permanently undeletable rather than deleted.
    ///
    /// The identity itself is removed through an RPC rather than the admin API.
    /// Deleting a user with `auth/v1/admin/users` requires the service-role
    /// key, and a service-role key shipped inside an app is a key that can
    /// delete *anybody's* account — so the app calls a `delete_own_account`
    /// function that Supabase runs with elevated rights and which can only ever
    /// act on `auth.uid()`. Where that function has not been installed, this
    /// reports the identity as not removed rather than pretending.
    public func deleteAccount() async -> DeletionOutcome {
        var outcome = DeletionOutcome()
        guard let userID = session?.account.id else {
            outcome.identityFailure = "Not signed in."
            return outcome
        }

        // Every table keyed by owner. Ordered so that anything referencing
        // another row goes first.
        let tables = ["damage_notes", "assessments", "events", "community_tags",
                      "observations", "buildings", "households"]

        for table in tables {
            do {
                let url = try baseURL()
                    .appendingPathComponent("rest/v1/\(table)")
                    .appending(queryItems: [URLQueryItem(name: "owner_id",
                                                         value: "eq.\(userID)")])
                var requestHeaders = try headers()
                requestHeaders["Prefer"] = "return=minimal"
                _ = try await client.send(HTTPRequest(method: "DELETE", url: url,
                                                      headers: requestHeaders, timeout: 30))
                outcome.clearedTables.append(table)
            } catch let error as ServiceError {
                outcome.failures[table] = error.userFacingReason
            } catch {
                outcome.failures[table] = "Could not be reached."
            }
        }

        do {
            let url = try baseURL().appendingPathComponent("rest/v1/rpc/delete_own_account")
            _ = try await client.send(HTTPRequest(method: "POST", url: url,
                                                  headers: try headers(),
                                                  body: Data("{}".utf8), timeout: 30))
            outcome.identityRemoved = true
        } catch let error as ServiceError {
            outcome.identityFailure = error.userFacingReason
        } catch {
            outcome.identityFailure = "The account record could not be removed."
        }

        session = nil
        return outcome
    }

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

    /// Uploads one file to the storage bucket and returns its object path.
    ///
    /// The path is deliberately prefixed with the account id. That is not
    /// decoration: the row-level security policy on the bucket matches the
    /// first path component against the caller's user id, so a photograph of
    /// somebody's home is readable by that household and nobody else. Files
    /// written outside that prefix are rejected by the server, which is the
    /// only place a rejection means anything.
    ///
    /// `x-upsert` because the queue replays. An offline week that ends with the
    /// same photo being sent twice should end with one object, not a duplicate
    /// and an error.
    @discardableResult
    public func upload(_ data: Data, name: String,
                       contentType: String = "image/jpeg") async throws -> String {
        guard let bucket = vault.value(for: .cloudStorageBucket), !bucket.isEmpty else {
            throw ServiceError.notConfigured("Storage bucket")
        }
        guard let userID = session?.account.id else {
            throw ServiceError.notConfigured("Storage upload without an account")
        }
        let path = "\(userID)/\(name)"
        let url = try baseURL().appendingPathComponent("storage/v1/object/\(bucket)/\(path)")
        var requestHeaders = try headers()
        requestHeaders["Content-Type"] = contentType
        requestHeaders["x-upsert"] = "true"
        _ = try await client.send(HTTPRequest(method: "POST", url: url,
                                              headers: requestHeaders, body: data,
                                              timeout: 60))
        return path
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

    /// Publishes one building's verdict to the neighbourhood.
    ///
    /// The half of the community map that was missing. Reading everybody's
    /// tags without ever being able to add your own makes the feature a
    /// broadcast rather than a network — and the map's whole premise is that
    /// after an earthquake there are not enough engineers, so what people can
    /// establish about their own buildings is the only thing that scales.
    ///
    /// Failure is reported rather than swallowed. The tag is written locally
    /// either way, so nothing is lost and it can go out with the next sync,
    /// but somebody who believes they have warned their street deserves to
    /// know when they have not.
    public func publish(_ tag: CommunityTag) async -> Sourced<Bool> {
        guard isConfigured else {
            return Sourced(false, origin: .onDevice, provider: "None",
                           note: "No community service is configured, so this is saved on this "
                               + "device and shared with nobody. It is still on your own map.")
        }
        do {
            try await push(table: "community_tags", payload: try JSONEncoder().encode([tag]))
            return Sourced(true, origin: .live, provider: "Supabase")
        } catch {
            return Sourced(false, origin: .onDevice, provider: "None",
                           note: "It could not be published just now. It is saved on this device "
                               + "and will go out with the next sync.")
        }
    }

    /// Agreeing or disputing somebody else's report.
    ///
    /// Kept as a separate row per voter rather than an incremented counter on
    /// the tag, so one person cannot move a verdict by pressing a button
    /// repeatedly — which is the obvious way to abuse a map that people are
    /// going to make sheltering decisions from.
    public func vote(onTag id: UUID, agree: Bool) async -> Sourced<Bool> {
        guard isConfigured, let voter = session?.account.id else {
            return Sourced(false, origin: .onDevice, provider: "None",
                           note: "Recorded on this device. Sharing votes needs an account.")
        }
        struct Vote: Encodable {
            var tagID: String
            var voterID: String
            var agree: Bool
            var votedAt: Date
        }
        do {
            let payload = try JSONEncoder().encode([
                Vote(tagID: id.uuidString, voterID: voter, agree: agree, votedAt: Date()),
            ])
            try await push(table: "community_tag_votes", payload: payload)
            return Sourced(true, origin: .live, provider: "Supabase")
        } catch {
            return Sourced(false, origin: .onDevice, provider: "None",
                           note: "The vote could not be sent just now.")
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
