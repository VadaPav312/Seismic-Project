import Foundation
import Combine
import SeismicCore
import SeismicServices

/// The rest of the street, kept per building.
///
/// Neighbours are not buildings the app monitors. They have no baseline, no
/// assessment and no verdict, and they never will — so they are deliberately
/// not `BuildingModel`s in the library. Putting nineteen of them in there would
/// leave the user with a list mostly full of buildings that can never say
/// anything, which is worse than not having them.
///
/// They live here instead: a cache, keyed by the building they surround,
/// written to disk so a street fetched once is not fetched again on every
/// launch. It is derived data from a free service, so losing it costs one
/// request.
@MainActor
final class BlockContext: ObservableObject {

    @Published private(set) var byBuilding: [UUID: [BlockBuilding]] = [:]
    @Published private(set) var isFetching: Set<UUID> = []
    /// Why the last fetch came back empty, if it did. Shown rather than left as
    /// a silently missing street.
    @Published private(set) var notes: [UUID: String] = [:]

    private let fileURL: URL? = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("street-context.json")
    }()

    init() { load() }

    func neighbours(of buildingID: UUID?) -> [BlockBuilding] {
        guard let buildingID else { return [] }
        return byBuilding[buildingID] ?? []
    }

    func hasFetched(_ buildingID: UUID?) -> Bool {
        guard let buildingID else { return false }
        return byBuilding[buildingID] != nil
    }

    /// Pulls the street around a building.
    ///
    /// Never throws and never blocks anything. A building with no mapped
    /// neighbours simply has none, and the simulator falls back to showing one
    /// building — which is what it always did.
    func fetch(for building: BuildingModel, using services: ServiceHub,
               radius: Int = 90, force: Bool = false) async {
        guard force || byBuilding[building.id] == nil else { return }
        guard !isFetching.contains(building.id) else { return }
        isFetching.insert(building.id)
        defer { isFetching.remove(building.id) }

        let result = await services.search.block(latitude: building.latitude,
                                                 longitude: building.longitude,
                                                 radius: radius)
        // The subject building is in that list too — it is the one the query
        // was centred on. Dropped by proximity to the origin, because keeping
        // it would draw a second, cruder copy of the building standing inside
        // the real one.
        let others = result.value.filter {
            hypot($0.centre.x, $0.centre.y) > 6 || $0.footprintArea < building.footprintArea * 0.5
        }
        byBuilding[building.id] = others
        notes[building.id] = result.note
        save()
    }

    func forget(_ buildingID: UUID) {
        byBuilding.removeValue(forKey: buildingID)
        notes.removeValue(forKey: buildingID)
        save()
    }

    /// A sentence about what was found, and how much of it was guessed.
    ///
    /// The second half matters more than the first. OpenStreetMap heights are
    /// patchy, and a block where most of them were assumed is a block whose
    /// skyline is partly invented — the user has to know that before reading
    /// anything into which building sways furthest.
    func summary(for buildingID: UUID?) -> String? {
        let neighbours = self.neighbours(of: buildingID)
        guard !neighbours.isEmpty else {
            return buildingID.flatMap { notes[$0] }
        }
        let measured = neighbours.filter { $0.estimatedHeight.isMeasured }.count
        let assumed = neighbours.count - measured
        var text = "\(neighbours.count) neighbouring buildings from OpenStreetMap"
        if assumed > 0 {
            text += ", \(assumed) of which have no height mapped and are drawn at two storeys"
        }
        return text + "."
    }

    // MARK: Persistence

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([UUID: [BlockBuilding]].self, from: data)
        else { return }
        byBuilding = stored
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(byBuilding) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
