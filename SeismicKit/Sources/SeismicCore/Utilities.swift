import Foundation

// Supporting infrastructure. Not part of the fifty, but the app is unreliable
// without every one of them.

// MARK: - Exponential backoff with jitter

/// Reconnection and retry scheduling.
///
/// Two properties matter. Exponential growth stops a dead node being polled a
/// hundred times a minute and flattening the phone's battery. Jitter stops every
/// client in a neighbourhood retrying in lockstep after a network outage — which
/// is exactly the moment a community safety app is under most load, and exactly
/// when a synchronised retry storm would finish the server off.
public struct BackoffPolicy: Sendable, Equatable {
    public var initialDelay: TimeInterval
    public var maximumDelay: TimeInterval
    public var multiplier: Double
    /// Fraction of the delay that is randomised. 0.5 means the actual delay is
    /// uniform between half and full.
    public var jitterFraction: Double
    /// Give up after this many attempts. Zero means never give up, which is
    /// right for a node the user expects to stay paired.
    public var maximumAttempts: Int

    public init(initialDelay: TimeInterval = 0.5, maximumDelay: TimeInterval = 60,
                multiplier: Double = 2, jitterFraction: Double = 0.5,
                maximumAttempts: Int = 0) {
        self.initialDelay = Swift.max(initialDelay, 0.01)
        self.maximumDelay = Swift.max(maximumDelay, self.initialDelay)
        self.multiplier = Swift.max(multiplier, 1.01)
        self.jitterFraction = Swift.min(Swift.max(jitterFraction, 0), 1)
        self.maximumAttempts = Swift.max(maximumAttempts, 0)
    }

    /// The node should reconnect promptly but must never spam the radio.
    public static let bluetooth = BackoffPolicy(initialDelay: 0.5, maximumDelay: 30,
                                                multiplier: 1.8, jitterFraction: 0.4)
    /// Network requests can afford to be more patient.
    public static let network = BackoffPolicy(initialDelay: 1, maximumDelay: 120,
                                              multiplier: 2, jitterFraction: 0.5,
                                              maximumAttempts: 8)

    /// Delay before attempt `n`, counting from 1.
    public func delay(forAttempt attempt: Int, using rng: inout SeededRandom) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let exponential = initialDelay * pow(multiplier, Double(attempt - 1))
        let capped = Swift.min(exponential, maximumDelay)
        guard jitterFraction > 0 else { return capped }
        let low = capped * (1 - jitterFraction)
        return rng.uniform(low, capped)
    }

    /// Non-deterministic variant for production use.
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let exponential = initialDelay * pow(multiplier, Double(attempt - 1))
        let capped = Swift.min(exponential, maximumDelay)
        guard jitterFraction > 0 else { return capped }
        return Double.random(in: (capped * (1 - jitterFraction))...capped)
    }

    public func shouldGiveUp(afterAttempt attempt: Int) -> Bool {
        maximumAttempts > 0 && attempt >= maximumAttempts
    }
}

/// Tracks an in-progress retry sequence.
public struct BackoffState: Sendable {
    public private(set) var attempt: Int = 0
    public private(set) var nextDelay: TimeInterval = 0
    public let policy: BackoffPolicy

    public init(policy: BackoffPolicy) { self.policy = policy }

    @discardableResult
    public mutating func recordFailure() -> TimeInterval {
        attempt += 1
        nextDelay = policy.delay(forAttempt: attempt)
        return nextDelay
    }

    public mutating func recordSuccess() {
        attempt = 0
        nextDelay = 0
    }

    public var hasGivenUp: Bool { policy.shouldGiveUp(afterAttempt: attempt) }
}

// MARK: - Token bucket rate limiting

/// Keeps every external API inside its quota.
///
/// A bucket refills at a steady rate and each request costs a token. This allows
/// a burst — which is what actually happens when a user opens the map and
/// twenty tiles are requested at once — while holding the long-run average
/// below the limit. A fixed minimum interval between requests would make that
/// burst take twenty seconds and feel broken.
public final class TokenBucket: @unchecked Sendable {
    public let capacity: Double
    /// Tokens added per second.
    public let refillRate: Double
    private var tokens: Double
    private var lastRefill: Date
    private let lock = NSLock()

    public init(capacity: Double, refillRate: Double, startFull: Bool = true) {
        self.capacity = Swift.max(capacity, 1)
        self.refillRate = Swift.max(refillRate, 0.001)
        self.tokens = startFull ? Swift.max(capacity, 1) : 0
        self.lastRefill = Date()
    }

    private func refill(now: Date) {
        let elapsed = now.timeIntervalSince(lastRefill)
        guard elapsed > 0 else { return }
        tokens = Swift.min(tokens + elapsed * refillRate, capacity)
        lastRefill = now
    }

    /// Takes a token if one is available.
    public func tryConsume(_ count: Double = 1, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        refill(now: now)
        guard tokens >= count else { return false }
        tokens -= count
        return true
    }

    /// How long until `count` tokens will be available. Surfaced in Settings as
    /// "rate limited, try again in N seconds" rather than an opaque failure.
    public func timeUntilAvailable(_ count: Double = 1, now: Date = Date()) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        refill(now: now)
        guard tokens < count else { return 0 }
        return (count - tokens) / refillRate
    }

    public var availableTokens: Double {
        lock.lock(); defer { lock.unlock() }
        refill(now: Date())
        return tokens
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        tokens = capacity
        lastRefill = Date()
    }
}

// MARK: - LRU cache

/// Bounded cache with least-recently-used eviction.
///
/// Map tiles, rendered building thumbnails, search results and computed response
/// spectra are all expensive to produce and cheap to keep. Without a bound they
/// grow until the app is killed for memory; with one, the working set stays hot
/// and everything else is recomputed on demand.
public final class LRUCache<Key: Hashable, Value>: @unchecked Sendable {
    private final class Node {
        let key: Key
        var value: Value
        var cost: Int
        var previous: Node?
        var next: Node?
        init(key: Key, value: Value, cost: Int) {
            self.key = key; self.value = value; self.cost = cost
        }
    }

    private var nodes: [Key: Node] = [:]
    private var head: Node?      // most recently used
    private var tail: Node?      // least recently used
    private let lock = NSLock()

    public let countLimit: Int
    public let costLimit: Int
    public private(set) var totalCost: Int = 0
    public private(set) var hits: Int = 0
    public private(set) var misses: Int = 0

    public init(countLimit: Int = 128, costLimit: Int = Int.max) {
        self.countLimit = Swift.max(countLimit, 1)
        self.costLimit = Swift.max(costLimit, 1)
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return nodes.count
    }

    /// Fraction of lookups served from cache — shown on the storage screen so
    /// the number is not a mystery.
    public var hitRate: Double {
        lock.lock(); defer { lock.unlock() }
        let total = hits + misses
        return total > 0 ? Double(hits) / Double(total) : 0
    }

    public func value(forKey key: Key) -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard let node = nodes[key] else { misses += 1; return nil }
        hits += 1
        moveToFront(node)
        return node.value
    }

    public func setValue(_ value: Value, forKey key: Key, cost: Int = 1) {
        lock.lock(); defer { lock.unlock() }
        if let existing = nodes[key] {
            totalCost += cost - existing.cost
            existing.value = value
            existing.cost = cost
            moveToFront(existing)
        } else {
            let node = Node(key: key, value: value, cost: Swift.max(cost, 0))
            nodes[key] = node
            totalCost += node.cost
            insertAtFront(node)
        }
        evictIfNeeded()
    }

    public func removeValue(forKey key: Key) {
        lock.lock(); defer { lock.unlock() }
        guard let node = nodes[key] else { return }
        unlink(node)
        nodes.removeValue(forKey: key)
        totalCost -= node.cost
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        nodes.removeAll(); head = nil; tail = nil; totalCost = 0
    }

    /// Keys in order, most recently used first. Exposed for tests and the
    /// diagnostics screen.
    public var keysByRecency: [Key] {
        lock.lock(); defer { lock.unlock() }
        var out: [Key] = []
        var node = head
        while let current = node { out.append(current.key); node = current.next }
        return out
    }

    private func insertAtFront(_ node: Node) {
        node.next = head
        node.previous = nil
        head?.previous = node
        head = node
        if tail == nil { tail = node }
    }

    private func moveToFront(_ node: Node) {
        guard head !== node else { return }
        unlink(node)
        insertAtFront(node)
    }

    private func unlink(_ node: Node) {
        node.previous?.next = node.next
        node.next?.previous = node.previous
        if head === node { head = node.next }
        if tail === node { tail = node.previous }
        node.previous = nil
        node.next = nil
    }

    private func evictIfNeeded() {
        while (nodes.count > countLimit || totalCost > costLimit), let victim = tail {
            unlink(victim)
            nodes.removeValue(forKey: victim.key)
            totalCost -= victim.cost
            if nodes.isEmpty { break }
        }
    }
}

// MARK: - CRC and integrity

/// CRC-16/CCITT-FALSE.
///
/// Chosen to match what an Arduino can compute cheaply while still catching all
/// single-bit, double-bit and burst errors up to 16 bits. A BLE link on a
/// crowded 2.4 GHz band does drop and corrupt packets, and a recording that is
/// silently wrong is worse than one that is visibly missing.
public enum CRC16 {
    public static func compute(_ bytes: [UInt8], initial: UInt16 = 0xFFFF) -> UInt16 {
        var crc = initial
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if crc & 0x8000 != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }

    public static func compute(_ data: Data, initial: UInt16 = 0xFFFF) -> UInt16 {
        compute([UInt8](data), initial: initial)
    }

    public static func verify(_ bytes: [UInt8], expected: UInt16) -> Bool {
        compute(bytes) == expected
    }
}

/// CRC-32, for whole-recording verification where 16 bits is not enough.
public enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    public static func compute(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    public static func compute(_ data: Data) -> UInt32 { compute([UInt8](data)) }
}

// MARK: - Delta encoding

/// Delta plus zig-zag plus variable-length encoding for waveform transfer.
///
/// Consecutive accelerometer samples are highly correlated, so their differences
/// are small even when the values are not. Zig-zag maps small signed differences
/// onto small unsigned integers, and varint then stores those in one or two
/// bytes instead of four. On a BLE link that manages a few kilobytes a second,
/// this is the difference between a recording arriving in seconds and in
/// minutes.
public enum DeltaEncoding {

    public static func encode(_ values: [Int32]) -> Data {
        var out = Data()
        out.reserveCapacity(values.count * 2)
        var previous: Int32 = 0
        for value in values {
            let delta = value &- previous
            previous = value
            appendVarint(zigZag(delta), to: &out)
        }
        return out
    }

    public static func decode(_ data: Data, count: Int) -> [Int32] {
        var out: [Int32] = []
        out.reserveCapacity(count)
        var index = data.startIndex
        var previous: Int32 = 0
        while index < data.endIndex, out.count < count {
            guard let (value, next) = readVarint(data, from: index) else { break }
            index = next
            previous = previous &+ unZigZag(value)
            out.append(previous)
        }
        return out
    }

    /// Quantises a floating-point waveform to fixed point before encoding.
    ///
    /// The node's ADC has about 12 bits of real resolution, so storing full
    /// doubles over the air transmits mostly noise. A scale of 10,000 keeps
    /// 0.1 mm/s² steps, which is well below the sensor's own noise floor.
    ///
    /// Named distinctly from the integer pair rather than overloaded: the two
    /// decoders would otherwise differ only by a defaulted argument, and a call
    /// that forgot `scale:` would silently return raw fixed-point integers
    /// instead of accelerations.
    public static func encodeSamples(_ samples: [Double], scale: Double = 10_000) -> Data {
        // Rounded, not truncated. Anything that independently re-quantises the
        // same samples — a checksum computed before transmission, say — must
        // land on identical integers, and `Int32(x)` truncating towards zero
        // would disagree with `(x).rounded()` for half the values.
        encode(samples.map { Int32(Swift.min(Swift.max(($0 * scale).rounded(), -2.1e9), 2.1e9)) })
    }

    public static func decodeSamples(_ data: Data, count: Int, scale: Double = 10_000) -> [Double] {
        decode(data, count: count).map { Double($0) / scale }
    }

    /// Maps signed to unsigned so small negatives stay small: 0, −1, 1, −2 …
    /// become 0, 1, 2, 3 …
    public static func zigZag(_ value: Int32) -> UInt32 {
        UInt32(bitPattern: (value << 1) ^ (value >> 31))
    }

    public static func unZigZag(_ value: UInt32) -> Int32 {
        Int32(bitPattern: (value >> 1)) ^ (-Int32(bitPattern: value & 1))
    }

    private static func appendVarint(_ value: UInt32, to data: inout Data) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        data.append(UInt8(v))
    }

    private static func readVarint(_ data: Data, from start: Data.Index)
        -> (value: UInt32, next: Data.Index)?
    {
        var result: UInt32 = 0
        var shift: UInt32 = 0
        var index = start
        while index < data.endIndex {
            let byte = data[index]
            index = data.index(after: index)
            result |= UInt32(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return (result, index) }
            shift += 7
            if shift > 28 { return nil }
        }
        return nil
    }

    /// Compression ratio against raw 32-bit samples, for the transfer statistics
    /// screen.
    public static func compressionRatio(originalCount: Int, encodedBytes: Int) -> Double {
        guard encodedBytes > 0 else { return 1 }
        return Double(originalCount * 4) / Double(encodedBytes)
    }
}

// MARK: - Fuzzy string matching

public enum FuzzyMatch {

    /// Levenshtein edit distance, computed in two rows rather than a full
    /// matrix. Building names are short but there can be hundreds of candidates.
    public static func editDistance(_ a: String, _ b: String) -> Int {
        let s = Array(a.lowercased()), t = Array(b.lowercased())
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }

        var previous = Array(0...t.count)
        var current = [Int](repeating: 0, count: t.count + 1)

        for i in 1...s.count {
            current[0] = i
            for j in 1...t.count {
                let substitution = previous[j - 1] + (s[i - 1] == t[j - 1] ? 0 : 1)
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[t.count]
    }

    /// 0…1, where 1 is identical. Normalised by the longer string so "Eiffel"
    /// and "Eifel" score highly despite the absolute distance being 1.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let longest = Swift.max(a.count, b.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(editDistance(a, b)) / Double(longest)
    }

    /// Token-based similarity, which handles reordering and extra words far
    /// better than edit distance: "Tower, Eiffel" against "The Eiffel Tower".
    public static func tokenSimilarity(_ a: String, _ b: String) -> Double {
        let tokensA = tokenise(a), tokensB = tokenise(b)
        guard !tokensA.isEmpty, !tokensB.isEmpty else { return 0 }
        let intersection = tokensA.intersection(tokensB).count
        let union = tokensA.union(tokensB).count
        return union > 0 ? Double(intersection) / Double(union) : 0
    }

    /// The score actually used for de-duplicating search candidates: the better
    /// of the two measures, since either kind of near-match is worth catching.
    public static func combinedSimilarity(_ a: String, _ b: String) -> Double {
        Swift.max(similarity(a, b), tokenSimilarity(a, b))
    }

    public static func tokenise(_ text: String) -> Set<String> {
        let stopWords: Set<String> = ["the", "of", "a", "an", "in", "at", "and", "le", "la", "de"]
        return Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopWords.contains($0) })
    }
}

// MARK: - BM25 ranking

/// Okapi BM25 relevance ranking.
///
/// Building search pulls candidates from several providers, each with its own
/// idea of relevance. Re-ranking them all under one scoring function makes the
/// list coherent. BM25 over plain term frequency matters because it saturates:
/// a document mentioning "tower" nine times is not nine times more relevant than
/// one mentioning it once, and rare words like "Chrysler" should outweigh common
/// ones like "building".
public struct BM25<DocumentID: Hashable> {
    public struct Document {
        public let id: DocumentID
        public let terms: [String]
        public init(id: DocumentID, text: String) {
            self.id = id
            self.terms = BM25.tokenise(text)
        }
    }

    private var documents: [Document] = []
    private var documentFrequency: [String: Int] = [:]
    private var averageLength: Double = 0

    /// Term-frequency saturation. 1.2–2.0 is conventional.
    public let k1: Double
    /// Length normalisation strength. 0.75 is conventional.
    public let b: Double

    public init(k1: Double = 1.5, b: Double = 0.75) {
        self.k1 = k1; self.b = b
    }

    public mutating func index(_ documents: [Document]) {
        self.documents = documents
        documentFrequency.removeAll()
        for document in documents {
            for term in Set(document.terms) {
                documentFrequency[term, default: 0] += 1
            }
        }
        averageLength = documents.isEmpty ? 0
            : Double(documents.reduce(0) { $0 + $1.terms.count }) / Double(documents.count)
    }

    public func search(_ query: String, limit: Int = 20) -> [(id: DocumentID, score: Double)] {
        let queryTerms = Self.tokenise(query)
        guard !queryTerms.isEmpty, !documents.isEmpty else { return [] }

        let n = Double(documents.count)
        var scores: [(DocumentID, Double)] = []

        for document in documents {
            var score = 0.0
            let length = Double(document.terms.count)
            guard length > 0 else { continue }

            for term in Set(queryTerms) {
                let frequency = Double(document.terms.filter { $0 == term }.count)
                guard frequency > 0 else { continue }
                let df = Double(documentFrequency[term] ?? 0)
                // Smoothed IDF, which cannot go negative for very common terms.
                let idf = log(1 + (n - df + 0.5) / (df + 0.5))
                let normalisation = averageLength > 0 ? length / averageLength : 1
                let denominator = frequency + k1 * (1 - b + b * normalisation)
                score += idf * (frequency * (k1 + 1)) / denominator
            }
            if score > 0 { scores.append((document.id, score)) }
        }

        return scores.sorted { $0.1 > $1.1 }.prefix(limit).map { (id: $0.0, score: $0.1) }
    }

    public static func tokenise(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
