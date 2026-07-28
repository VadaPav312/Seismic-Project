import Foundation
import SeismicCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why a service call did not produce a live answer.
///
/// Every one of these is a *reason to fall back*, not a reason to fail. The
/// caller's job is to substitute a local answer and say which one it used; no
/// screen in this app is allowed to show a dead end because a server was slow.
public enum ServiceError: Error, Equatable, Sendable {
    case noCredential(SecretKey)
    case notConfigured(String)
    case transport(String)
    case http(status: Int, body: String)
    case rateLimited(retryAfter: TimeInterval?)
    case decoding(String)
    case cancelled
    case emptyResult
    /// A refusal the upstream service worded itself, and worded better than a
    /// status code could. Sign-in providers explain rejections in the redirect
    /// rather than in an HTTP status, and "Access blocked: this app's request
    /// is invalid" tells the user what to fix in a way that "400" never will.
    case upstream(String)

    public var isRetryable: Bool {
        switch self {
        case .transport: true
        case .http(let status, _): status >= 500 || status == 408 || status == 429
        case .rateLimited: true
        case .noCredential, .notConfigured, .decoding, .cancelled, .emptyResult,
             .upstream: false
        }
    }

    /// What a person should be told. Never a stack trace, never a raw body.
    public var userFacingReason: String {
        switch self {
        case .noCredential(let key): "No \(key.rawValue) is set."
        case .notConfigured(let what): "\(what) is not configured."
        case .transport: "The network did not answer."
        case .http(let status, _) where status == 401 || status == 403: "That key was rejected."
        case .http(let status, _): "The service answered \(status)."
        case .rateLimited: "That service is rate limited right now."
        case .decoding: "The service answered in a shape this app did not expect."
        case .cancelled: "Cancelled."
        case .emptyResult: "Nothing was found."
        case .upstream(let message): message
        }
    }

    /// The status a key should be moved to after this failure, if any. Used so
    /// Settings → API Keys reflects reality without the user pressing "test".
    public func keyStatus(at now: Date = Date()) -> KeyStatus? {
        switch self {
        case .http(let status, _) where status == 401 || status == 403:
            .failing(reason: "Rejected by the service", at: now)
        case .rateLimited(let retryAfter):
            .rateLimited(until: now.addingTimeInterval(retryAfter ?? 60))
        case .http(let status, _) where status >= 500:
            .failing(reason: "Service error \(status)", at: now)
        default:
            nil
        }
    }
}

/// A minimal request description, kept free of URLSession so it can be built
/// and asserted on in tests without a network.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(method: String = "GET", url: URL, headers: [String: String] = [:],
                body: Data? = nil, timeout: TimeInterval = 20) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    public static func json(_ method: String, _ url: URL, headers: [String: String] = [:],
                            body: some Encodable, timeout: TimeInterval = 20) throws -> HTTPRequest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]   // deterministic, so caches actually hit
        var merged = headers
        merged["Content-Type"] = "application/json"
        return HTTPRequest(method: method, url: url, headers: merged,
                           body: try encoder.encode(body), timeout: timeout)
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
    public var text: String { String(data: body, encoding: .utf8) ?? "" }

    public func decode<T: Decodable>(_ type: T.Type,
                                     using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        do { return try decoder.decode(type, from: body) }
        catch { throw ServiceError.decoding(String(describing: error).prefix(200).description) }
    }
}

/// The seam every network client is written against.
///
/// Production uses `URLSessionHTTPTransport`. Tests use `StubHTTPTransport`, so
/// the entire service layer is exercised offline and deterministically —
/// including the retry and fallback paths, which are the parts that actually
/// matter and the parts a live-network test would never reach reliably.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                return HTTPResponse(status: 200, body: data)
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    headers[key.lowercased()] = value
                }
            }
            return HTTPResponse(status: http.statusCode, headers: headers, body: data)
        } catch is CancellationError {
            throw ServiceError.cancelled
        } catch {
            throw ServiceError.transport(error.localizedDescription)
        }
    }
}

/// A scripted transport. Requests are matched by a substring of the URL, so a
/// test can say "the Serper call fails, the Tavily call works" without knowing
/// how the client assembles its query string.
public final class StubHTTPTransport: HTTPTransport, @unchecked Sendable {
    public struct Rule: Sendable {
        public var match: String
        public var result: Result<HTTPResponse, ServiceError>
        public init(match: String, result: Result<HTTPResponse, ServiceError>) {
            self.match = match
            self.result = result
        }
    }

    private var rules: [Rule] = []
    private var recorded: [HTTPRequest] = []
    private let lock = NSLock()

    public init(rules: [Rule] = []) { self.rules = rules }

    public func stub(_ match: String, status: Int = 200, json: String) {
        lock.lock(); defer { lock.unlock() }
        rules.append(Rule(match: match,
                          result: .success(HTTPResponse(status: status,
                                                        body: Data(json.utf8)))))
    }

    public func stub(_ match: String, failure: ServiceError) {
        lock.lock(); defer { lock.unlock() }
        rules.append(Rule(match: match, result: .failure(failure)))
    }

    public var requests: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// Kept synchronous so the lock is never held across a suspension point.
    private func recordAndMatch(_ request: HTTPRequest) -> Rule? {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        return rules.first { request.url.absoluteString.contains($0.match) }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let matched = recordAndMatch(request) else {
            throw ServiceError.transport("No stub for \(request.url)")
        }
        switch matched.result {
        case .success(let response): return response
        case .failure(let error): throw error
        }
    }
}

/// Wraps a transport with the two things every real client needs and nobody
/// enjoys writing twice: a token bucket so a burst cannot get the key banned,
/// and exponential backoff with jitter so a transient failure is retried
/// without synchronising every device on the planet onto the same retry tick.
public actor ResilientClient {
    private let transport: HTTPTransport
    private let bucket: TokenBucket
    private let policy: BackoffPolicy
    private var rng: SeededRandom
    private let sleeper: @Sendable (TimeInterval) async -> Void

    public init(transport: HTTPTransport,
                requestsPerSecond: Double = 4,
                burst: Double = 8,
                policy: BackoffPolicy = BackoffPolicy(initialDelay: 0.4, maximumDelay: 8,
                                                      multiplier: 2, jitterFraction: 0.3,
                                                      maximumAttempts: 3),
                seed: UInt64 = 0x5E15_31C0,
                sleeper: (@Sendable (TimeInterval) async -> Void)? = nil) {
        self.transport = transport
        self.bucket = TokenBucket(capacity: burst, refillRate: requestsPerSecond)
        self.policy = policy
        self.rng = SeededRandom(seed: seed)
        self.sleeper = sleeper ?? { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
        }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var attempt = 0
        var lastError: ServiceError = .transport("No attempt was made")

        while !policy.shouldGiveUp(afterAttempt: attempt) {
            if !bucket.tryConsume() {
                await sleeper(bucket.timeUntilAvailable())
                _ = bucket.tryConsume()
            }

            do {
                let response = try await transport.send(request)
                if response.status == 429 {
                    let retryAfter = response.headers["retry-after"].flatMap(Double.init)
                    throw ServiceError.rateLimited(retryAfter: retryAfter)
                }
                if !response.isSuccess {
                    throw ServiceError.http(status: response.status,
                                            body: String(response.text.prefix(400)))
                }
                return response
            } catch let error as ServiceError {
                lastError = error
                guard error.isRetryable else { throw error }
                attempt += 1
                if policy.shouldGiveUp(afterAttempt: attempt) { break }
                await sleeper(policy.delay(forAttempt: attempt, using: &rng))
            } catch {
                throw ServiceError.transport(error.localizedDescription)
            }
        }
        throw lastError
    }

    /// Convenience for the common shape: send, decode, and turn any decoding
    /// slip into a `ServiceError` the caller can fall back on.
    public func json<T: Decodable>(_ request: HTTPRequest, as type: T.Type,
                                   decoder: JSONDecoder = JSONDecoder()) async throws -> T {
        try await send(request).decode(type, using: decoder)
    }
}

/// Whether a given answer came from the network or from the device.
///
/// Carried alongside every service result and shown in the UI. A user should
/// always be able to tell whether they are looking at live data or at a local
/// stand-in, without having to guess from how plausible it looks.
public enum ResultOrigin: String, Codable, Sendable, Equatable {
    case live
    case cached
    case onDevice
    case seeded

    public var label: String {
        switch self {
        case .live: "Live"
        case .cached: "Cached"
        case .onDevice: "On device"
        case .seeded: "Bundled"
        }
    }

    public var systemImage: String {
        switch self {
        case .live: "antenna.radiowaves.left.and.right"
        case .cached: "clock.arrow.circlepath"
        case .onDevice: "iphone"
        case .seeded: "shippingbox"
        }
    }

    public var isLive: Bool { self == .live }
}

/// A service answer plus how it was obtained. Nothing in this app returns a
/// bare value from a service — the provenance travels with it.
public struct Sourced<Value: Sendable>: Sendable {
    public var value: Value
    public var origin: ResultOrigin
    public var provider: String
    public var note: String?

    public init(_ value: Value, origin: ResultOrigin, provider: String, note: String? = nil) {
        self.value = value
        self.origin = origin
        self.provider = provider
        self.note = note
    }

    public func map<T: Sendable>(_ transform: (Value) -> T) -> Sourced<T> {
        Sourced<T>(transform(value), origin: origin, provider: provider, note: note)
    }
}
