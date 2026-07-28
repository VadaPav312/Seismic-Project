import Foundation
import SeismicCore
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The tamper-evident event ledger.
///
/// An assessment is evidence. If a building is later found to have been unsafe,
/// somebody will ask what the system said and when — and if the records can be
/// quietly edited afterwards, the answer is worthless. Hash-chaining each entry
/// to its predecessor means altering any historical record changes its hash,
/// which breaks every hash after it. You cannot rewrite one entry; you can only
/// visibly break the chain.
///
/// This is deliberately *evident* rather than *proof*: a determined attacker
/// with the device can rebuild the whole chain. What it defeats is the realistic
/// case — quietly changing one verdict from red to green after the fact.

public struct LedgerEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case buildingCreated, buildingEdited, baselineRecorded, eventCaptured
        case assessmentIssued, actuatorFired, photoAttached, noteAdded
        case professionalSignature, verdictPublished, keyRotated

        public var label: String {
            switch self {
            case .buildingCreated: "Building added"
            case .buildingEdited: "Building edited"
            case .baselineRecorded: "Baseline recorded"
            case .eventCaptured: "Event captured"
            case .assessmentIssued: "Assessment issued"
            case .actuatorFired: "Safety action fired"
            case .photoAttached: "Photo attached"
            case .noteAdded: "Note added"
            case .professionalSignature: "Professional signature"
            case .verdictPublished: "Verdict published"
            case .keyRotated: "Signing key rotated"
            }
        }

        public var systemImage: String {
            switch self {
            case .buildingCreated, .buildingEdited: "building.2"
            case .baselineRecorded: "waveform.path.ecg"
            case .eventCaptured: "waveform.badge.exclamationmark"
            case .assessmentIssued, .verdictPublished: "checkmark.shield"
            case .actuatorFired: "bolt.horizontal"
            case .photoAttached: "camera"
            case .noteAdded: "note.text"
            case .professionalSignature: "checkmark.seal"
            case .keyRotated: "key"
            }
        }
    }

    public var id: UUID
    public var index: Int
    public var timestamp: Date
    public var kind: Kind
    public var subjectID: UUID?
    /// Human-readable summary, shown in the verification screen.
    public var summary: String
    /// Canonical JSON of the payload being attested to.
    public var payloadDigest: String
    public var previousHash: String
    public var hash: String
    public var authorTier: VerificationTier

    public init(id: UUID = UUID(), index: Int, timestamp: Date = Date(), kind: Kind,
                subjectID: UUID? = nil, summary: String, payloadDigest: String,
                previousHash: String, authorTier: VerificationTier = .unverified) {
        self.id = id
        self.index = index
        self.timestamp = timestamp
        self.kind = kind
        self.subjectID = subjectID
        self.summary = summary
        self.payloadDigest = payloadDigest
        self.previousHash = previousHash
        self.authorTier = authorTier
        self.hash = ""
        self.hash = Self.computeHash(of: self)
    }

    /// The fields that are covered by the hash. Anything not in here can be
    /// changed without detection, so everything that matters is in here.
    ///
    /// Note the fixed ordering and the ISO-8601 timestamp: a dictionary's
    /// iteration order or a locale-dependent date format would make the same
    /// entry hash differently on two devices, and the chain would appear broken
    /// when nothing was wrong.
    public var canonicalForm: String {
        return [
            String(index),
            LedgerDateFormat.string(from: timestamp),
            kind.rawValue,
            subjectID?.uuidString ?? "-",
            summary,
            payloadDigest,
            previousHash,
            authorTier.rawValue,
        ].joined(separator: "\u{1F}")     // unit separator: cannot occur in the fields
    }

    public static func computeHash(of entry: LedgerEntry) -> String {
        Hashing.sha256(entry.canonicalForm)
    }

    public var isSelfConsistent: Bool { hash == Self.computeHash(of: self) }
}

/// The single date representation the ledger uses, for both hashing and storage.
///
/// This has to be one format used in both places, and it caused a subtle and
/// serious bug when it was not: the hash was computed over a timestamp with
/// fractional seconds, while the store encoded dates without them. Saving the
/// ledger and reading it back therefore changed every timestamp by a fraction of
/// a second, which changed every hash, and the app reported its own untampered
/// history as tampered with — the exact failure that would destroy trust in the
/// feature.
///
/// Formatting is idempotent under a round trip: `format(parse(format(x)))`
/// always equals `format(x)`, so a date that has been through storage hashes
/// identically to one that has not.
public enum LedgerDateFormat {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    public static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }

    /// Date strategies that match the hashing format exactly.
    public static var encodingStrategy: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
    }

    public static var decodingStrategy: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let value = date(from: raw) else {
                // Tolerate dates written before this format was settled rather
                // than failing to load the user's entire history.
                let fallback = ISO8601DateFormatter()
                fallback.formatOptions = [.withInternetDateTime]
                guard let recovered = fallback.date(from: raw) else {
                    throw DecodingError.dataCorruptedError(
                        in: try decoder.singleValueContainer(),
                        debugDescription: "Unrecognised date: \(raw)")
                }
                return recovered
            }
            return value
        }
    }
}

public enum Hashing {
    public static func sha256(_ string: String) -> String {
        sha256(Data(string.utf8))
    }

    public static func sha256(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        // Fallback for platforms without CryptoKit. Not cryptographically
        // equivalent, and the ledger screen says so rather than implying a
        // guarantee it cannot make.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016lx%016lx", hash, hash &* 31)
        #endif
    }

    /// Whether the strong hash is available on this platform.
    public static var isCryptographicallyStrong: Bool {
        #if canImport(CryptoKit)
        true
        #else
        false
        #endif
    }

    /// Digest of any Codable payload, computed over a canonical encoding so the
    /// same value always produces the same digest.
    public static func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return sha256("<unencodable>") }
        return sha256(data)
    }
}

/// The chain itself.
public final class EventLedger: @unchecked Sendable {

    public private(set) var entries: [LedgerEntry] = []
    private let lock = NSLock()

    /// The chain's anchor. Fixed, so two devices building the same history
    /// produce the same hashes.
    public static let genesisHash = String(repeating: "0", count: 64)

    public init(entries: [LedgerEntry] = []) {
        self.entries = entries.sorted { $0.index < $1.index }
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    public var headHash: String {
        lock.lock(); defer { lock.unlock() }
        return entries.last?.hash ?? Self.genesisHash
    }

    @discardableResult
    public func append(kind: LedgerEntry.Kind, subjectID: UUID? = nil, summary: String,
                       payloadDigest: String, authorTier: VerificationTier = .unverified,
                       timestamp: Date = Date()) -> LedgerEntry {
        lock.lock()
        let entry = LedgerEntry(index: entries.count, timestamp: timestamp, kind: kind,
                                subjectID: subjectID, summary: summary,
                                payloadDigest: payloadDigest,
                                previousHash: entries.last?.hash ?? Self.genesisHash,
                                authorTier: authorTier)
        entries.append(entry)
        lock.unlock()
        return entry
    }

    @discardableResult
    public func append<T: Encodable>(kind: LedgerEntry.Kind, subjectID: UUID? = nil,
                                     summary: String, payload: T,
                                     authorTier: VerificationTier = .unverified) -> LedgerEntry {
        append(kind: kind, subjectID: subjectID, summary: summary,
               payloadDigest: Hashing.digest(payload), authorTier: authorTier)
    }

    // MARK: Verification

    public struct Verification: Sendable, Equatable {
        public var isIntact: Bool
        /// Index of the first entry that fails. Everything after it is suspect
        /// by construction, so only the first matters.
        public var firstBrokenIndex: Int?
        public var reason: String
        public var entriesChecked: Int
        public var usesStrongHashing: Bool

        public var headline: String {
            isIntact ? "Ledger intact" : "Ledger broken at entry \((firstBrokenIndex ?? 0) + 1)"
        }
    }

    public func verify() -> Verification {
        lock.lock()
        let snapshot = entries
        lock.unlock()

        guard !snapshot.isEmpty else {
            return Verification(isIntact: true, firstBrokenIndex: nil,
                                reason: "The ledger is empty. Nothing has been recorded yet.",
                                entriesChecked: 0,
                                usesStrongHashing: Hashing.isCryptographicallyStrong)
        }

        var previous = Self.genesisHash
        for (position, entry) in snapshot.enumerated() {
            // Three independent checks: the entry's own hash, its link to the
            // previous entry, and its position in the sequence.
            if entry.index != position {
                return Verification(
                    isIntact: false, firstBrokenIndex: position,
                    reason: "Entry \(position + 1) claims to be number \(entry.index + 1). "
                        + "An entry has been inserted or removed.",
                    entriesChecked: position + 1,
                    usesStrongHashing: Hashing.isCryptographicallyStrong)
            }
            if entry.previousHash != previous {
                return Verification(
                    isIntact: false, firstBrokenIndex: position,
                    reason: "Entry \(position + 1) does not link to the one before it. "
                        + "Something earlier in the chain has been altered or removed.",
                    entriesChecked: position + 1,
                    usesStrongHashing: Hashing.isCryptographicallyStrong)
            }
            if !entry.isSelfConsistent {
                return Verification(
                    isIntact: false, firstBrokenIndex: position,
                    reason: "Entry \(position + 1) — \"\(entry.summary)\" — does not match its "
                        + "own hash. Its contents have been changed since it was written.",
                    entriesChecked: position + 1,
                    usesStrongHashing: Hashing.isCryptographicallyStrong)
            }
            previous = entry.hash
        }

        return Verification(
            isIntact: true, firstBrokenIndex: nil,
            reason: "All \(snapshot.count) entries verified. Each one links to the one before "
                + "it and matches its own contents, so nothing has been altered since it was "
                + "written.",
            entriesChecked: snapshot.count,
            usesStrongHashing: Hashing.isCryptographicallyStrong)
    }

    /// Proof that a specific record is in the ledger and unaltered — what gets
    /// embedded in a PDF report so a third party can check it.
    public struct InclusionProof: Sendable, Equatable {
        public var entry: LedgerEntry
        public var chainHead: String
        public var totalEntries: Int
        public var recordedAt: Date

        public var humanSummary: String {
            "Recorded as ledger entry \(entry.index + 1) of \(totalEntries) at "
                + "\(recordedAt.formatted(date: .abbreviated, time: .standard)). "
                + "Entry hash \(entry.hash.prefix(16))…, chain head \(chainHead.prefix(16))…"
        }
    }

    public func proof(forSubject subjectID: UUID) -> InclusionProof? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries.last(where: { $0.subjectID == subjectID }) else { return nil }
        return InclusionProof(entry: entry, chainHead: entries.last?.hash ?? Self.genesisHash,
                              totalEntries: entries.count, recordedAt: entry.timestamp)
    }

    public func entries(forSubject subjectID: UUID) -> [LedgerEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.subjectID == subjectID }
    }

    public func entries(ofKind kind: LedgerEntry.Kind) -> [LedgerEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.kind == kind }
    }

    public func replace(with entries: [LedgerEntry]) {
        lock.lock()
        self.entries = entries.sorted { $0.index < $1.index }
        lock.unlock()
    }

    // MARK: Merkle root

    /// Merkle root over every entry hash.
    ///
    /// The chain already makes tampering evident. The root adds a single short
    /// value that summarises the entire history, which is what a report prints
    /// and what a synced device compares — checking one string is a great deal
    /// cheaper than transferring and re-walking the whole chain.
    public func merkleRoot() -> String {
        lock.lock()
        var level = entries.map(\.hash)
        lock.unlock()

        guard !level.isEmpty else { return Self.genesisHash }

        while level.count > 1 {
            var next: [String] = []
            next.reserveCapacity((level.count + 1) / 2)
            var index = 0
            while index < level.count {
                if index + 1 < level.count {
                    next.append(Hashing.sha256(level[index] + level[index + 1]))
                } else {
                    // Odd node is promoted rather than duplicated, which avoids
                    // the second-preimage weakness that duplication introduces.
                    next.append(level[index])
                }
                index += 2
            }
            level = next
        }
        return level[0]
    }

    /// Deliberately corrupts an entry. Exists so the verification screen can
    /// *demonstrate* detection rather than merely claim it — a judge tapping
    /// "simulate tampering" sees the chain break in front of them.
    public func simulateTampering(atIndex index: Int, newSummary: String = "Verdict: appears safe") {
        lock.lock(); defer { lock.unlock() }
        guard entries.indices.contains(index) else { return }
        // Change the contents but leave the stored hash alone, exactly as
        // someone editing the database directly would.
        entries[index].summary = newSummary
    }
}
