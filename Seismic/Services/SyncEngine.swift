import Foundation
import Combine
import Network
import SeismicCore
import SeismicData
import SeismicServices

/// Drains the sync queue.
///
/// The store has always enqueued every change; until now nothing emptied the
/// queue, so "3 changes waiting to sync" was a permanently true statement. This
/// is the other half.
///
/// Three rules shape it. Nothing uploads without an account, because there is
/// nowhere to put it and a guest was promised their data stays on the device.
/// Nothing is removed from the queue until the server has acknowledged it, so a
/// tunnel or a dead battery costs a retry rather than a building. And an item
/// whose record has since been deleted locally is dropped rather than retried
/// for ever, which is the difference between a queue and a leak.
@MainActor
final class SyncEngine: ObservableObject {

    @Published private(set) var status: SyncQueue.Status = .synced
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var lastError: String?

    private let store: SeismicStore
    private let cloud: CloudService
    private let account: () -> UserAccount?

    private let monitor = NWPathMonitor()
    private var isOnline = true
    private var isDraining = false

    /// Records that the server has rejected in a way retrying cannot fix.
    ///
    /// A malformed row would otherwise sit at the head of the queue and block
    /// everything behind it for ever. Held in memory only: a new launch is
    /// allowed to try again, since the usual cause is a schema the user has
    /// since created.
    private var poisoned: Set<SyncQueue.Item> = []

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    init(store: SeismicStore, cloud: CloudService, account: @escaping () -> UserAccount?) {
        self.store = store
        self.cloud = cloud
        self.account = account
        refreshStatus()

        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let online = path.status == .satisfied
                let cameBack = online && !self.isOnline
                self.isOnline = online
                self.store.syncQueue.setOnline(online)
                self.refreshStatus()
                // The moment signal returns is exactly when a queue built up
                // during an earthquake should start emptying.
                if cameBack { await self.sync() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.seismic.sync.path"))
    }

    deinit { monitor.cancel() }

    // MARK: Draining

    /// Uploads everything queued. Safe to call often; overlapping calls collapse.
    func sync() async {
        guard !isDraining else { return }
        guard isOnline else { refreshStatus(); return }
        guard let account = account(), !account.isGuest else { refreshStatus(); return }
        guard cloud.isConfigured else { refreshStatus(); return }

        // An expired access token turns every upload into a 401. Renewing once
        // up front is cheaper than discovering it item by item.
        guard await cloud.refreshIfNeeded() else {
            lastError = "Your session expired. Sign in again to resume syncing."
            refreshStatus()
            return
        }

        isDraining = true
        defer { isDraining = false }
        lastError = nil

        let pending = store.syncQueue.pending().filter { !poisoned.contains($0) }
        guard !pending.isEmpty else {
            status = .synced
            return
        }

        var remaining = pending.count
        for item in pending {
            status = .syncing(remaining: remaining)
            do {
                try await upload(item, owner: account.id)
                store.syncQueue.complete(item)
            } catch let error as ServiceError {
                if error.isRetryable {
                    // Stop the whole pass rather than hammering a service that
                    // is already struggling. The queue keeps its place.
                    lastError = error.userFacingReason
                    break
                }
                poisoned.insert(item)
                lastError = "\(item.label): \(error.userFacingReason)"
            } catch {
                lastError = "\(item.label) could not be uploaded."
                break
            }
            remaining -= 1
        }

        if store.syncQueue.count == 0 { lastSyncedAt = Date() }
        refreshStatus()
    }

    private func upload(_ item: SyncQueue.Item, owner: String) async throws {
        switch item {
        case .building(let id):
            guard let building = store.building(id) else { return }
            try await push(kind: "building", id: id, owner: owner, body: building)

        case .event(let id):
            guard let event = store.eventsList().first(where: { $0.id == id }) else { return }
            try await push(kind: "event", id: id, owner: owner, body: event)

        case .assessment(let id):
            guard let assessment = store.assessmentsList()
                .first(where: { $0.id == id }) else { return }
            try await push(kind: "assessment", id: id, owner: owner, body: assessment)

        case .note(let id):
            guard let note = store.notesList().first(where: { $0.id == id }) else { return }
            try await push(kind: "note", id: id, owner: owner, body: note)

        case .tag(let id):
            // The one record with a table of its own, because the community map
            // queries it by bounding box and time — which a JSON blob cannot
            // answer without dragging the whole table to the device.
            guard let tag = store.tagsList().first(where: { $0.id == id }) else { return }
            try await cloud.push(table: "community_tags", payload: try encoder.encode(tag))

        case .photo(let id):
            let url = PhotoStore.shared.url(for: id)
            guard let data = try? Data(contentsOf: url) else { return }
            try await cloud.upload(data, name: "\(id.uuidString).jpg")
        }
    }

    /// Everything except community tags shares one table.
    ///
    /// A row per record with the record itself as JSON, rather than five tables
    /// whose columns must track five Swift structs. Nothing queries these by
    /// field — they are fetched whole, by owner — so columns would buy nothing
    /// and cost a migration every time a model gains a property.
    private func push(kind: String, id: UUID, owner: String, body: some Encodable) async throws {
        let payload = try JSONValue(encoding: body, using: encoder)
        let envelope = Envelope(id: id.uuidString, user_id: owner, kind: kind,
                                updated_at: ISO8601DateFormatter().string(from: Date()),
                                payload: payload)
        try await cloud.push(table: "sync_records", payload: try encoder.encode(envelope))
    }

    // MARK: Status

    func refreshStatus() {
        let count = store.syncQueue.count
        if count == 0 {
            status = .synced
        } else if !isOnline {
            status = .offline(count: count)
        } else if account()?.isGuest ?? true {
            // Not an error, and not "pending" either — a guest has no server, so
            // the honest word is that nothing is waiting on anything.
            status = .synced
        } else {
            status = .pending(count: count)
        }
    }
}

/// One row of `sync_records`: who owns it, what kind of thing it is, and the
/// record itself.
private struct Envelope: Encodable {
    var id: String
    var user_id: String
    var kind: String
    var updated_at: String
    var payload: JSONValue
}

/// Re-encodes an already-`Encodable` value so it can be nested inside another
/// one as a JSON object rather than as a string of JSON.
///
/// Without this the payload arrives at Postgres double-encoded — a `jsonb`
/// column holding the *text* `"{\"id\":…}"` — which stores and reads back
/// without complaint and is wrong in a way nothing notices until a query
/// returns nothing.
struct JSONValue: Encodable {
    private let data: Data

    init(encoding value: some Encodable, using encoder: JSONEncoder) throws {
        self.data = try encoder.encode(value)
    }

    func encode(to encoder: any Encoder) throws {
        let object = try JSONSerialization.jsonObject(with: data,
                                                      options: [.fragmentsAllowed])
        var container = encoder.singleValueContainer()
        try container.encode(AnyEncodable(object))
    }
}

/// The minimum needed to write a decoded `JSONSerialization` tree back out.
private struct AnyEncodable: Encodable {
    let value: Any
    init(_ value: Any) { self.value = value }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let number as NSNumber:
            // NSNumber flattens Bool and the numeric types together, and the
            // object-identity check is the documented way to tell a real
            // boolean from a 0 or 1 that merely looks like one.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                try container.encode(number.boolValue)
            } else if let int = Int(exactly: number) {
                try container.encode(int)
            } else {
                try container.encode(number.doubleValue)
            }
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map(AnyEncodable.init))
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues(AnyEncodable.init))
        default:
            try container.encodeNil()
        }
    }
}
