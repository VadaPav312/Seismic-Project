import Foundation
import SeismicCore

/// The order to visit buildings in, after an event.
///
/// The scarce resource after an earthquake is not data. Within hours there are
/// thousands of tags on the map and a couple of dozen people qualified to act
/// on them, and the only question that matters is which door to knock on first.
/// A list sorted by distance sends somebody to the nearest green building; a
/// list sorted by severity sends them criss-crossing a city.
///
/// So this scores every tag on three things that have nothing to do with each
/// other, then walks the result greedily so the route is actually walkable.
/// Every stop carries the reason it is where it is, because an inspector who
/// disagrees with the order needs to be able to see what the order was based on
/// and overrule it.
public enum InspectionTriage {

    // MARK: What a stop is

    public struct Stop: Identifiable, Sendable, Equatable {
        public var id: UUID { tag.id }
        public var tag: CommunityTag
        /// Position in the visit order, from 1.
        public var position: Int
        public var priority: Double
        /// Straight-line metres from the previous stop, or from the start for
        /// the first one.
        public var metresFromPrevious: Double
        /// Why this is here, in the order the reasons carried weight. Shown on
        /// screen — a ranking nobody can interrogate is a ranking nobody trusts.
        public var reasons: [String]

        public init(tag: CommunityTag, position: Int, priority: Double,
                    metresFromPrevious: Double, reasons: [String]) {
            self.tag = tag
            self.position = position
            self.priority = priority
            self.metresFromPrevious = metresFromPrevious
            self.reasons = reasons
        }
    }

    // MARK: Scoring

    /// How urgently a verdict needs a human to look.
    ///
    /// Not the same ordering as how bad the verdict is, and the difference is
    /// the point:
    ///
    /// * **Needs inspection** is top. It means nobody knows, and resolving
    ///   exactly that is what an inspector is for.
    /// * **Amber** is next, and it outranks red. A red building has been
    ///   emptied and the decision has already been taken; an amber one has
    ///   people walking in and out under a "limited use" judgement that nobody
    ///   qualified has checked. That is where an unverified guess is still
    ///   carrying weight.
    /// * **Red** is high but below amber: the conservative action is already in
    ///   force, so being wrong about it costs access rather than safety.
    /// * **Green** is last, and still on the list — a wrong green is the most
    ///   dangerous single tag on the map, so it is visited, just not first.
    static func urgency(of verdict: SafetyVerdict) -> Double {
        switch verdict {
        case .needsInspection: 1.0
        case .amber: 0.85
        case .red: 0.6
        case .green: 0.25
        }
    }

    /// How many people a wrong answer here affects, as a 0–1 proxy.
    ///
    /// Storeys, because that is the one occupancy-related figure the app
    /// actually holds. Returns nil rather than a number when the building is
    /// unknown, and the caller uses a neutral weight — a guessed occupancy
    /// would reorder a real inspector's day on the strength of nothing.
    static func exposure(storeys: Int?) -> Double? {
        guard let storeys, storeys > 0 else { return nil }
        // Flattens off deliberately. The difference between two storeys and
        // eight is most of the difference in how many people are inside; the
        // difference between forty and fifty is not, and left linear it would
        // let one tower outrank a whole terrace.
        return min(log(Double(storeys) + 1) / log(21), 1)
    }

    /// How little is known about the tag, 0–1, where 1 is "nobody has confirmed
    /// this and somebody has disputed it".
    ///
    /// Uncertainty *raises* priority. A tag three professionals agree on has
    /// already had the expert attention this queue exists to allocate; a lone
    /// unverified one has had none.
    static func uncertainty(of tag: CommunityTag) -> Double {
        let confidence = min(max(tag.consensusScore, 0), 2) / 2
        let disputed = tag.disputeCount > 0 ? 0.25 : 0
        let unphotographed = tag.photoCount == 0 ? 0.15 : 0
        return min(1 - confidence + disputed + unphotographed, 1)
    }

    /// How stale the tag is, 0–1 over the tag's own expiry window.
    static func staleness(of tag: CommunityTag, now: Date = Date()) -> Double {
        let window = tag.expiresAt.timeIntervalSince(tag.postedAt)
        guard window > 0 else { return 1 }
        return min(max(now.timeIntervalSince(tag.postedAt) / window, 0), 1)
    }

    /// The single number the queue is sorted by.
    ///
    /// The weights are stated here rather than buried in the expression so they
    /// can be argued with. Urgency dominates because it has to; exposure and
    /// uncertainty break ties between buildings of the same colour, which in
    /// practice is most of the list.
    public static func priority(for tag: CommunityTag, storeys: Int?,
                                now: Date = Date()) -> Double {
        let urgencyPart = 0.55 * urgency(of: tag.verdict)
        // A neutral half when the building is unknown — neither promoted nor
        // demoted for a fact nobody has.
        let exposurePart = 0.20 * (exposure(storeys: storeys) ?? 0.5)
        let uncertaintyPart = 0.17 * uncertainty(of: tag)
        let stalenessPart = 0.08 * staleness(of: tag, now: now)
        return urgencyPart + exposurePart + uncertaintyPart + stalenessPart
    }

    static func reasons(for tag: CommunityTag, storeys: Int?,
                        now: Date = Date()) -> [String] {
        var reasons: [String] = []

        switch tag.verdict {
        case .needsInspection:
            reasons.append("Nobody has been able to call it either way.")
        case .amber:
            reasons.append("Limited use — people are still going in, on a judgement "
                           + "no one qualified has checked.")
        case .red:
            reasons.append("Tagged unsafe. Already evacuated, so the cautious action "
                           + "is in force while it waits.")
        case .green:
            reasons.append("Tagged safe. Worth confirming, but not ahead of the rest.")
        }

        if let storeys, storeys >= 6 {
            reasons.append("\(storeys) storeys — a lot of people behind one answer.")
        }
        if tag.disputeCount > 0 {
            reasons.append("\(tag.disputeCount) "
                           + (tag.disputeCount == 1 ? "person disputes" : "people dispute")
                           + " this tag.")
        }
        if tag.tier == .unverified && tag.agreementCount == 0 {
            reasons.append("One unverified report, with nothing corroborating it.")
        }
        if tag.photoCount == 0 {
            reasons.append("No photographs attached.")
        }
        if staleness(of: tag, now: now) > 0.75 {
            reasons.append("Posted \(tag.ageDescription) and close to expiring.")
        }
        return reasons
    }

    // MARK: Building the queue

    /// Ranks the tags, then orders them into a route.
    ///
    /// Two passes, because one cannot do both jobs. Sorting purely by priority
    /// produces a correct list that wastes the day in transit; sorting purely
    /// by distance produces an efficient tour of the wrong buildings. So the
    /// tags are banded by priority first, and within each band the route is
    /// walked nearest-first from wherever the inspector currently is. Somebody
    /// finishes all of the urgent work before any of the routine work, and does
    /// each band as a sensible walk rather than a scatter.
    ///
    /// - Parameters:
    ///   - tags: the tags to consider. Expired ones are dropped.
    ///   - storeysByBuildingID: storey counts for buildings the app knows, used
    ///     as the occupancy proxy. Missing entries are treated as unknown, not
    ///     as zero.
    ///   - start: where the inspector is now, or nil to start from the highest
    ///     priority tag wherever it is.
    ///   - bandWidth: how close two priorities have to be to count as the same
    ///     band and be routed together.
    public static func queue(tags: [CommunityTag],
                             storeysByBuildingID: [UUID: Int] = [:],
                             start: (latitude: Double, longitude: Double)? = nil,
                             bandWidth: Double = 0.08,
                             now: Date = Date()) -> [Stop] {
        let live = tags.filter { now <= $0.expiresAt }
        guard !live.isEmpty else { return [] }

        let scored = live.map { tag -> (tag: CommunityTag, priority: Double, storeys: Int?) in
            let storeys = tag.buildingID.flatMap { storeysByBuildingID[$0] }
            return (tag, priority(for: tag, storeys: storeys, now: now), storeys)
        }
        .sorted { $0.priority > $1.priority }

        // Cut into bands of comparable priority.
        var bands: [[(tag: CommunityTag, priority: Double, storeys: Int?)]] = []
        for entry in scored {
            if let last = bands.last?.first, last.priority - entry.priority <= bandWidth {
                bands[bands.count - 1].append(entry)
            } else {
                bands.append([entry])
            }
        }

        var stops: [Stop] = []
        var current = start.map { (latitude: $0.latitude, longitude: $0.longitude) }

        for band in bands {
            var remaining = band
            while !remaining.isEmpty {
                let index: Int
                let distance: Double
                if let here = current {
                    // Nearest of what is left in this band.
                    var bestIndex = 0
                    var bestDistance = Double.greatestFiniteMagnitude
                    for (i, candidate) in remaining.enumerated() {
                        let d = metres(from: here,
                                       to: (candidate.tag.latitude, candidate.tag.longitude))
                        if d < bestDistance { bestDistance = d; bestIndex = i }
                    }
                    index = bestIndex
                    distance = bestDistance
                } else {
                    // No starting point: begin at the top of the band and let
                    // the walk grow from there.
                    index = 0
                    distance = 0
                }

                let chosen = remaining.remove(at: index)
                stops.append(Stop(
                    tag: chosen.tag,
                    position: stops.count + 1,
                    priority: chosen.priority,
                    metresFromPrevious: distance,
                    reasons: reasons(for: chosen.tag, storeys: chosen.storeys, now: now)))
                current = (chosen.tag.latitude, chosen.tag.longitude)
            }
        }
        return stops
    }

    /// Straight-line metres. Deliberately not a road distance: this orders a
    /// list, and a routing service that has to be online would make the one
    /// feature designed for the hours after an earthquake the one feature that
    /// stops working then.
    static func metres(from: (latitude: Double, longitude: Double),
                       to: (latitude: Double, longitude: Double)) -> Double {
        let earthRadius = 6_371_000.0
        let dLat = (to.latitude - from.latitude) * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let meanLat = (from.latitude + to.latitude) / 2 * .pi / 180
        let x = dLon * cos(meanLat)
        return earthRadius * (dLat * dLat + x * x).squareRoot()
    }

    /// A one-line summary for the top of the queue.
    public static func summary(of stops: [Stop]) -> String {
        guard !stops.isEmpty else {
            return "No live tags in view. Nothing to visit."
        }
        let unknown = stops.filter { $0.tag.verdict == .needsInspection }.count
        let amber = stops.filter { $0.tag.verdict == .amber }.count
        let walk = stops.dropFirst().reduce(0) { $0 + $1.metresFromPrevious }

        var parts = ["\(stops.count) building\(stops.count == 1 ? "" : "s")"]
        if unknown > 0 { parts.append("\(unknown) with no verdict yet") }
        if amber > 0 { parts.append("\(amber) in limited use") }
        parts.append(walk < 1_000
                     ? "\(Int(walk.rounded())) m of walking"
                     : String(format: "%.1f km of walking", walk / 1_000))
        return parts.joined(separator: " · ")
    }
}
