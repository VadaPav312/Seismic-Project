import Foundation
import SeismicCore
import SeismicSignal

/// Offline-first persistence.
///
/// Earthquakes take down networks — that is not an edge case, it is the
/// expected operating condition. So the local store is the source of truth and
/// the cloud is a replica, never the other way round. Every write lands on disk
/// first and is queued for sync; nothing in the app ever waits on a network call
/// to show the user their own data.
///
/// Storage is JSON files rather than a database: the whole dataset for one
/// household is a few megabytes, the write pattern is append-mostly, and being
/// able to open the file and read it during development is worth more than query
/// performance the app will never need.
public final class SeismicStore: @unchecked Sendable {

    public struct Snapshot: Sendable {
        public var buildings: [BuildingModel]
        public var events: [SeismicEvent]
        public var assessments: [Assessment]
        public var observations: [ModeObservation]
        public var earthquakes: [EarthquakeRecord]
        public var tags: [CommunityTag]
        public var notes: [DamageNote]
        public var ledgerEntries: [LedgerEntry]
    }

    private let directory: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var buildings: [UUID: BuildingModel] = [:]
    private var events: [UUID: SeismicEvent] = [:]
    private var assessments: [UUID: Assessment] = [:]
    private var observations: [ModeObservation] = []
    private var earthquakes: [UUID: EarthquakeRecord] = [:]
    private var tags: [UUID: CommunityTag] = [:]
    private var notes: [UUID: DamageNote] = [:]

    public let ledger = EventLedger()
    public let syncQueue = SyncQueue()

    /// Recordings are large and are stored one file per event rather than in the
    /// main document, so loading the library does not pull megabytes of
    /// waveform into memory.
    private var recordingCache = LRUCache<UUID, TriaxialRecord>(countLimit: 8)

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Seismic", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Seismic")

        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("recordings"),
                                                 withIntermediateDirectories: true)

        encoder = JSONEncoder()
        // The ledger's date format, not plain `.iso8601`. The ledger hashes its
        // timestamps, so any loss of precision between writing and reading would
        // break the chain on every launch.
        encoder.dateEncodingStrategy = LedgerDateFormat.encodingStrategy
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = LedgerDateFormat.decodingStrategy
    }

    /// A store backed by a throwaway directory, for tests and previews.
    public static func ephemeral() -> SeismicStore {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seismic-\(UUID().uuidString)", isDirectory: true)
        return SeismicStore(directory: path)
    }

    public var storageDirectory: URL { directory }

    // MARK: - Loading and seeding

    /// Loads from disk, seeding on first run.
    ///
    /// Seeding is not a debug affordance: the app is *specified* to open onto a
    /// populated experience, so an empty store is a bug rather than a valid
    /// state.
    @discardableResult
    public func load() -> Snapshot {
        let didLoad = readFromDisk()
        if !didLoad || buildingsList().isEmpty {
            seed()
        }
        return snapshot()
    }

    private func readFromDisk() -> Bool {
        var loadedAnything = false

        if let list: [BuildingModel] = read("buildings.json") {
            lock.lock(); buildings = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            lock.unlock(); loadedAnything = true
        }
        if let list: [SeismicEvent] = read("events.json") {
            lock.lock(); events = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            lock.unlock(); loadedAnything = true
        }
        if let list: [Assessment] = read("assessments.json") {
            lock.lock(); assessments = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            lock.unlock()
        }
        if let list: [ModeObservation] = read("observations.json") {
            lock.lock(); observations = list; lock.unlock()
        }
        if let list: [EarthquakeRecord] = read("earthquakes.json") {
            lock.lock(); earthquakes = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            lock.unlock()
        }
        if let list: [CommunityTag] = read("tags.json") {
            lock.lock(); tags = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            lock.unlock()
        }
        if let list: [DamageNote] = read("notes.json") {
            lock.lock(); notes = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            lock.unlock()
        }
        if let list: [LedgerEntry] = read("ledger.json") {
            ledger.replace(with: list)
        }
        if let queued: [SyncQueue.Item] = read("syncqueue.json") {
            syncQueue.restore(queued)
        }

        return loadedAnything
    }

    /// Populates a fresh install.
    public func seed() {
        let seedBuildings = SeedLibrary.buildings()
        let sandbox = seedBuildings.first { $0.isSandbox } ?? SeedLibrary.sandboxBuilding()

        lock.lock()
        for building in seedBuildings { buildings[building.id] = building }
        for record in SeedLibrary.earthquakes() { earthquakes[record.id] = record }
        observations = SeedLibrary.measurementHistory(buildingID: sandbox.id,
                                                      basePeriod: sandbox.empiricalPeriod)
        for event in SeedLibrary.pastEvents(buildingID: sandbox.id, nodeID: "sim-node-01") {
            events[event.id] = event
        }
        for tag in SeedLibrary.communityTags(near: sandbox.latitude, longitude: sandbox.longitude) {
            tags[tag.id] = tag
        }
        lock.unlock()

        // The ledger is built from the seeded history so the verification screen
        // has a real chain to check rather than an empty one.
        ledger.append(kind: .buildingCreated, subjectID: sandbox.id,
                      summary: "Building \"\(sandbox.name)\" added",
                      payload: sandbox)
        ledger.append(kind: .baselineRecorded, subjectID: sandbox.id,
                      summary: "Baseline period recorded: "
                        + String(format: "%.3f s", sandbox.empiricalPeriod),
                      payloadDigest: Hashing.sha256("baseline-\(sandbox.id)"))

        for event in eventsList().sorted(by: { $0.startTime < $1.startTime }) {
            ledger.append(kind: .eventCaptured, subjectID: event.id,
                          summary: "\(event.label) — trigger ratio "
                            + String(format: "%.1f", event.triggerRatio),
                          payloadDigest: Hashing.sha256("event-\(event.id)"),
                          timestamp: event.startTime)
            if !event.actuatorReports.isEmpty {
                ledger.append(kind: .actuatorFired, subjectID: event.id,
                              summary: "\(event.actuatorReports.count) safety actions confirmed",
                              payloadDigest: Hashing.sha256("actuators-\(event.id)"),
                              timestamp: event.startTime.addingTimeInterval(2))
            }
        }

        save()
    }

    // MARK: - Reading

    public func snapshot() -> Snapshot {
        Snapshot(buildings: buildingsList(), events: eventsList(),
                 assessments: assessmentsList(), observations: observationsList(),
                 earthquakes: earthquakesList(), tags: tagsList(), notes: notesList(),
                 ledgerEntries: ledger.entries)
    }

    public func buildingsList() -> [BuildingModel] {
        lock.lock(); defer { lock.unlock() }
        return buildings.values.sorted {
            // The user's own building first, then alphabetically.
            if $0.isSandbox != $1.isSandbox { return $0.isSandbox }
            return $0.name < $1.name
        }
    }

    public func building(_ id: UUID) -> BuildingModel? {
        lock.lock(); defer { lock.unlock() }
        return buildings[id]
    }

    public func eventsList() -> [SeismicEvent] {
        lock.lock(); defer { lock.unlock() }
        return events.values.sorted { $0.startTime > $1.startTime }
    }

    public func events(forBuilding id: UUID) -> [SeismicEvent] {
        eventsList().filter { $0.buildingID == id }
    }

    public func assessmentsList() -> [Assessment] {
        lock.lock(); defer { lock.unlock() }
        return assessments.values.sorted { $0.createdAt > $1.createdAt }
    }

    public func assessments(forBuilding id: UUID) -> [Assessment] {
        assessmentsList().filter { $0.buildingID == id }
    }

    public func latestAssessment(forBuilding id: UUID) -> Assessment? {
        assessments(forBuilding: id).first
    }

    public func observationsList() -> [ModeObservation] {
        lock.lock(); defer { lock.unlock() }
        return observations
    }

    public func observations(mode: Int) -> [ModeObservation] {
        observationsList().filter { $0.modeNumber == mode }.sorted { $0.at < $1.at }
    }

    public func earthquakesList() -> [EarthquakeRecord] {
        lock.lock(); defer { lock.unlock() }
        return earthquakes.values.sorted { $0.year > $1.year }
    }

    public func tagsList() -> [CommunityTag] {
        lock.lock(); defer { lock.unlock() }
        return tags.values.sorted { $0.postedAt > $1.postedAt }
    }

    public func notesList() -> [DamageNote] {
        lock.lock(); defer { lock.unlock() }
        return notes.values.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Writing

    public func upsert(_ building: BuildingModel, recordInLedger: Bool = true) {
        lock.lock()
        let existed = buildings[building.id] != nil
        buildings[building.id] = building
        lock.unlock()

        if recordInLedger {
            ledger.append(kind: existed ? .buildingEdited : .buildingCreated,
                          subjectID: building.id,
                          summary: existed ? "Building \"\(building.name)\" edited"
                                           : "Building \"\(building.name)\" added",
                          payload: building)
        }
        syncQueue.enqueue(.building(building.id))
        save()
    }

    public func upsert(_ event: SeismicEvent) {
        // The waveform is moved out to its own file and dropped from the index —
        // in memory as well as on disk. Keeping it attached would mean the whole
        // event list carried every recording it had ever seen, which is exactly
        // the growth this separation exists to prevent.
        if let record = event.record { writeRecording(record, for: event.id) }
        lock.lock(); events[event.id] = stripRecording(event); lock.unlock()
        syncQueue.enqueue(.event(event.id))
        save()
    }

    /// The event with its waveform loaded back in, for replay and analysis.
    public func eventWithRecording(_ id: UUID) -> SeismicEvent? {
        guard var event = events(withID: id) else { return nil }
        event.record = recording(for: id)
        return event
    }

    private func events(withID id: UUID) -> SeismicEvent? {
        lock.lock(); defer { lock.unlock() }
        return events[id]
    }

    public func upsert(_ assessment: Assessment) {
        var stored = assessment
        let entry = ledger.append(
            kind: .assessmentIssued, subjectID: assessment.id,
            summary: "Verdict: \(assessment.verdict.placard)"
                + (assessment.periodChangePercent.map {
                    String(format: " (%.1f%% period change)", $0) } ?? ""),
            payload: assessment, authorTier: assessment.assessorTier)
        stored.ledgerHash = entry.hash

        lock.lock(); assessments[stored.id] = stored; lock.unlock()
        syncQueue.enqueue(.assessment(stored.id))
        save()
    }

    public func append(_ newObservations: [ModeObservation]) {
        guard !newObservations.isEmpty else { return }
        lock.lock()
        observations.append(contentsOf: newObservations)
        // Bounded: a node scanning four times a day for five years is 7,300
        // observations per mode, which is fine, but a runaway loop is not.
        if observations.count > 40_000 {
            observations.removeFirst(observations.count - 40_000)
        }
        lock.unlock()
        save()
    }

    public func upsert(_ tag: CommunityTag) {
        lock.lock(); tags[tag.id] = tag; lock.unlock()
        syncQueue.enqueue(.tag(tag.id))
        save()
    }

    public func upsert(_ note: DamageNote) {
        lock.lock(); notes[note.id] = note; lock.unlock()
        ledger.append(kind: .noteAdded, subjectID: note.id,
                      summary: "Note: \(note.text.prefix(60))",
                      payload: note)
        syncQueue.enqueue(.note(note.id))
        save()
    }

    public func upsert(_ record: EarthquakeRecord) {
        lock.lock(); earthquakes[record.id] = record; lock.unlock()
        save()
    }

    /// Removes a building and everything that only made sense alongside it.
    ///
    /// The events were already going; the assessments, the damage notes and the
    /// community tags were not, so deleting a building left its verdicts behind
    /// permanently. That is worse than untidy. An assessment outlives its
    /// building in the export, in the sync payload and in `assessments` — and
    /// the screens that list verdicts had no building to name, while the store
    /// grew every time somebody tried out a design and deleted it.
    ///
    /// Deliberately not deleted: the ledger. It is tamper-evident and
    /// append-only, and the point of such a record is that removing a building
    /// cannot remove the evidence that it was once assessed.
    public func delete(buildingID: UUID) {
        lock.lock()
        buildings.removeValue(forKey: buildingID)

        let relatedEvents = events.values.filter { $0.buildingID == buildingID }.map(\.id)
        for id in relatedEvents { events.removeValue(forKey: id) }

        for id in assessments.values.filter({ $0.buildingID == buildingID }).map(\.id) {
            assessments.removeValue(forKey: id)
        }
        for id in notes.values.filter({ $0.buildingID == buildingID }).map(\.id) {
            notes.removeValue(forKey: id)
        }
        for id in tags.values.filter({ $0.buildingID == buildingID }).map(\.id) {
            tags.removeValue(forKey: id)
        }
        lock.unlock()
        save()
    }

    // MARK: - Recordings

    private func recordingURL(for eventID: UUID) -> URL {
        directory.appendingPathComponent("recordings/\(eventID.uuidString).json")
    }

    public func writeRecording(_ record: TriaxialRecord, for eventID: UUID) {
        recordingCache.setValue(record, forKey: eventID)
        guard let data = try? encoder.encode(record) else { return }
        try? data.write(to: recordingURL(for: eventID), options: .atomic)
    }

    public func recording(for eventID: UUID) -> TriaxialRecord? {
        if let cached = recordingCache.value(forKey: eventID) { return cached }
        guard let data = try? Data(contentsOf: recordingURL(for: eventID)),
              let record = try? decoder.decode(TriaxialRecord.self, from: data) else { return nil }
        recordingCache.setValue(record, forKey: eventID)
        return record
    }

    /// Total bytes on disk, for the storage screen.
    public func storageFootprint() -> (documents: Int, recordings: Int) {
        let manager = FileManager.default
        func size(of url: URL) -> Int {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return 0 }
            return values.fileSize ?? 0
        }
        let documents = (try? manager.contentsOfDirectory(at: directory,
                                                          includingPropertiesForKeys: [.fileSizeKey]))?
            .reduce(0) { $0 + size(of: $1) } ?? 0
        let recordingsDirectory = directory.appendingPathComponent("recordings")
        let recordings = (try? manager.contentsOfDirectory(at: recordingsDirectory,
                                                           includingPropertiesForKeys: [.fileSizeKey]))?
            .reduce(0) { $0 + size(of: $1) } ?? 0
        return (documents, recordings)
    }

    // MARK: - Persistence

    public func save() {
        write(buildingsList(), to: "buildings.json")
        write(eventsList(), to: "events.json")
        write(assessmentsList(), to: "assessments.json")
        write(observationsList(), to: "observations.json")
        write(earthquakesList(), to: "earthquakes.json")
        write(tagsList(), to: "tags.json")
        write(notesList(), to: "notes.json")
        write(ledger.entries, to: "ledger.json")
        write(syncQueue.pending(), to: "syncqueue.json")
    }

    /// The waveform lives in its own file, so the event index stays small.
    private func stripRecording(_ event: SeismicEvent) -> SeismicEvent {
        var copy = event
        copy.record = nil
        return copy
    }

    private func write<T: Encodable>(_ value: T, to filename: String) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(filename), options: .atomic)
    }

    private func read<T: Decodable>(_ filename: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(filename))
        else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    /// Full export, for the data-portability requirement.
    public func exportJSON() -> Data? {
        let snapshot = snapshot()
        let bundle = ExportBundle(
            exportedAt: Date(), buildings: snapshot.buildings, events: snapshot.events,
            assessments: snapshot.assessments, observations: snapshot.observations,
            tags: snapshot.tags, notes: snapshot.notes, ledger: snapshot.ledgerEntries,
            ledgerRoot: ledger.merkleRoot())
        let exportEncoder = JSONEncoder()
        exportEncoder.dateEncodingStrategy = .iso8601
        exportEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? exportEncoder.encode(bundle)
    }

    public struct ExportBundle: Codable, Sendable {
        public var exportedAt: Date
        public var buildings: [BuildingModel]
        public var events: [SeismicEvent]
        public var assessments: [Assessment]
        public var observations: [ModeObservation]
        public var tags: [CommunityTag]
        public var notes: [DamageNote]
        public var ledger: [LedgerEntry]
        public var ledgerRoot: String
    }

    /// Deletes everything. Backs the account-deletion requirement, and is
    /// deliberately complete rather than merely hiding the data.
    public func deleteEverything() {
        lock.lock()
        buildings.removeAll(); events.removeAll(); assessments.removeAll()
        observations.removeAll(); earthquakes.removeAll(); tags.removeAll(); notes.removeAll()
        lock.unlock()
        ledger.replace(with: [])
        syncQueue.clear()
        recordingCache.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("recordings"),
                                                 withIntermediateDirectories: true)
    }
}

/// A dictated or typed damage note, pinned to a place and a moment.
public struct DamageNote: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var buildingID: UUID?
    public var text: String
    public var createdAt: Date
    /// Where in the building — "third floor, north-east column".
    public var locationLabel: String
    public var storey: Int?
    public var wasDictated: Bool
    public var photoIDs: [UUID]
    public var severity: Double

    public init(id: UUID = UUID(), buildingID: UUID? = nil, text: String,
                createdAt: Date = Date(), locationLabel: String = "",
                storey: Int? = nil, wasDictated: Bool = false,
                photoIDs: [UUID] = [], severity: Double = 0.5) {
        self.id = id; self.buildingID = buildingID; self.text = text
        self.createdAt = createdAt; self.locationLabel = locationLabel
        self.storey = storey; self.wasDictated = wasDictated
        self.photoIDs = photoIDs; self.severity = severity
    }
}

// MARK: - Sync queue

/// Queued changes waiting to reach the cloud.
///
/// Everything the user does is applied locally and enqueued here. If there is no
/// network — or no Supabase project configured at all — the queue simply grows
/// and the app is unaffected. When connectivity returns the queue drains in
/// order, and conflicts are surfaced for the user to resolve rather than
/// silently resolved by whoever happened to write last.
public final class SyncQueue: @unchecked Sendable {

    public enum Item: Codable, Sendable, Equatable, Hashable {
        case building(UUID)
        case event(UUID)
        case assessment(UUID)
        case tag(UUID)
        case note(UUID)
        case photo(UUID)

        public var subjectID: UUID {
            switch self {
            case .building(let id), .event(let id), .assessment(let id),
                 .tag(let id), .note(let id), .photo(let id): id
            }
        }

        public var label: String {
            switch self {
            case .building: "Building"
            case .event: "Event recording"
            case .assessment: "Assessment"
            case .tag: "Community tag"
            case .note: "Note"
            case .photo: "Photo"
            }
        }
    }

    public enum Status: Equatable, Sendable {
        case synced
        case pending(count: Int)
        case offline(count: Int)
        case syncing(remaining: Int)
        case conflicted(count: Int)

        public var label: String {
            switch self {
            case .synced: "All changes synced"
            case .pending(let count): "\(count) change\(count == 1 ? "" : "s") waiting to sync"
            case .offline(let count): "Offline — \(count) change\(count == 1 ? "" : "s") queued"
            case .syncing(let remaining): "Syncing… \(remaining) remaining"
            case .conflicted(let count): "\(count) conflict\(count == 1 ? "" : "s") need your decision"
            }
        }

        public var systemImage: String {
            switch self {
            case .synced: "checkmark.icloud"
            case .pending: "arrow.triangle.2.circlepath"
            case .offline: "icloud.slash"
            case .syncing: "arrow.clockwise.icloud"
            case .conflicted: "exclamationmark.icloud"
            }
        }
    }

    /// A conflict the user has to decide about.
    public struct Conflict: Identifiable, Sendable {
        public var id: UUID { item.subjectID }
        public var item: Item
        public var localSummary: String
        public var remoteSummary: String
        public var localModified: Date
        public var remoteModified: Date
        public var detectedAt: Date

        public init(item: Item, localSummary: String, remoteSummary: String,
                    localModified: Date, remoteModified: Date, detectedAt: Date = Date()) {
            self.item = item
            self.localSummary = localSummary
            self.remoteSummary = remoteSummary
            self.localModified = localModified
            self.remoteModified = remoteModified
            self.detectedAt = detectedAt
        }
    }

    private var queue: [Item] = []
    private var conflicts: [Conflict] = []
    private var isOnline = false
    private var inFlight = 0
    private let lock = NSLock()

    public init() {}

    public func enqueue(_ item: Item) {
        lock.lock(); defer { lock.unlock() }
        // De-duplicate: five edits to the same building before the network comes
        // back is one thing to upload, not five.
        queue.removeAll { $0 == item }
        queue.append(item)
    }

    public func pending() -> [Item] {
        lock.lock(); defer { lock.unlock() }
        return queue
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return queue.count
    }

    public func restore(_ items: [Item]) {
        lock.lock(); queue = items; lock.unlock()
    }

    public func setOnline(_ online: Bool) {
        lock.lock(); isOnline = online; lock.unlock()
    }

    /// Marks an item as successfully uploaded.
    public func complete(_ item: Item) {
        lock.lock()
        queue.removeAll { $0 == item }
        inFlight = Swift.max(inFlight - 1, 0)
        lock.unlock()
    }

    public func recordConflict(_ conflict: Conflict) {
        lock.lock()
        conflicts.removeAll { $0.item == conflict.item }
        conflicts.append(conflict)
        lock.unlock()
    }

    public func resolveConflict(for item: Item) {
        lock.lock(); conflicts.removeAll { $0.item == item }; lock.unlock()
    }

    public func pendingConflicts() -> [Conflict] {
        lock.lock(); defer { lock.unlock() }
        return conflicts
    }

    public func clear() {
        lock.lock(); queue.removeAll(); conflicts.removeAll(); lock.unlock()
    }

    public var status: Status {
        lock.lock(); defer { lock.unlock() }
        if !conflicts.isEmpty { return .conflicted(count: conflicts.count) }
        if inFlight > 0 { return .syncing(remaining: queue.count) }
        if queue.isEmpty { return .synced }
        return isOnline ? .pending(count: queue.count) : .offline(count: queue.count)
    }
}
