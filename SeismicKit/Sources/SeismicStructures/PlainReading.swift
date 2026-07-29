import Foundation
import SeismicCore

/// What the numbers mean, in words a person who is not an engineer can act on.
///
/// The rest of this framework answers questions an engineer would ask: what is
/// the fundamental period, how much of the deflection is bending, is the
/// torsional mode the softer one. Those are the right questions and the answers
/// are honest, but somebody standing outside a building wanting to know whether
/// to go in cannot use any of them. This translates.
///
/// Three rules govern everything here, because the failure modes of a plain
/// language layer are worse than the failure modes of a number:
///
/// 1. **It never says "safe".** No calculation from a building's age, shape and
///    soil can establish that, and a reassuring word carries far more weight
///    with a reader than the caveat printed after it. It says what is known,
///    what it implies, and what would change the answer.
/// 2. **It says how much of this is guessed.** An imported building's material
///    and structural system are often inferred rather than known, and a reading
///    built on inferences has to be labelled as one — otherwise the app's own
///    uncertainty is laundered into confidence by the act of putting it in
///    words. `confidence` comes from the provenance record, not from a feeling.
/// 3. **Every point gives its reason.** "Built in 1968" means nothing on its
///    own; "built before the code required ductile detailing, so its columns may
///    not hold together once they crack" is something a reader can weigh.
///
/// This is a reading of the building's *inherent* vulnerability — what it is,
/// standing there, before anything has happened to it. That is a different
/// question from `BayesianFusion`, which asks whether a building that has
/// already been shaken has changed. Both are needed and neither substitutes for
/// the other: a strong building can be damaged, and a weak one can be
/// undamaged because nothing has hit it yet.
public struct PlainReading: Sendable, Equatable {

    /// One sentence, in ordinary words, that answers the question actually being
    /// asked. Never a bare adjective.
    public var headline: String

    /// One or two sentences expanding the headline.
    public var summary: String

    /// The limit of the whole exercise, said at every level.
    ///
    /// Held separately from the summary so it can be rendered as the footnote it
    /// is. Folded into the summary it made the reassuring case read as a wall of
    /// hedging, which trains a reader to skip exactly the sentence that matters
    /// most — and it does not become less true when the news is good.
    public var caveat: String

    /// The specific reasons, worst first. Each one names a fact and says what it
    /// means.
    public var points: [Point]

    /// What a reader can actually do about it.
    public var actions: [String]

    /// How much of this rests on facts that are known rather than inferred, 0–1.
    public var confidence: Double

    /// What the confidence figure means, and which facts are shaky.
    public var confidenceNote: String

    /// Overall level, for colour and ordering. Deliberately not called a verdict:
    /// `SafetyVerdict` answers a different question and must not be confused
    /// with this one.
    public var level: Level

    public enum Level: String, Sendable, Codable, CaseIterable, Comparable {
        /// Nothing here stands out as a known vulnerability.
        case ordinary
        /// One or more features that are known to matter.
        case worthKnowing
        /// Features that have repeatedly caused collapse.
        case serious

        public var label: String {
            switch self {
            case .ordinary: "Nothing unusual found"
            case .worthKnowing: "Worth knowing about"
            case .serious: "Serious concerns"
            }
        }

        public var systemImage: String {
            switch self {
            case .ordinary: "checkmark.circle"
            case .worthKnowing: "exclamationmark.triangle"
            case .serious: "exclamationmark.octagon.fill"
            }
        }

        private var order: Int {
            switch self {
            case .ordinary: 0
            case .worthKnowing: 1
            case .serious: 2
            }
        }

        public static func < (a: Level, b: Level) -> Bool { a.order < b.order }
    }

    /// One reason, with its weight and its explanation.
    public struct Point: Sendable, Equatable, Identifiable {
        public var id: String { title }
        /// The fact, in a few words.
        public var title: String
        /// What it means, in one or two plain sentences.
        public var meaning: String
        public var severity: Level
        /// Whether this point rests on an inferred fact rather than a known one.
        public var isInferred: Bool

        public init(title: String, meaning: String, severity: Level,
                    isInferred: Bool = false) {
            self.title = title
            self.meaning = meaning
            self.severity = severity
            self.isInferred = isInferred
        }
    }

    public init(headline: String, summary: String, caveat: String, points: [Point],
                actions: [String], confidence: Double, confidenceNote: String,
                level: Level) {
        self.headline = headline
        self.summary = summary
        self.caveat = caveat
        self.points = points
        self.actions = actions
        self.confidence = confidence
        self.confidenceNote = confidenceNote
        self.level = level
    }
}

// MARK: - Reading a building

public extension PlainReading {

    /// Reads a building.
    ///
    /// `tower` is optional so this works before the 3D analysis has been run —
    /// on a list row, say — and simply omits the points it cannot make. A
    /// missing input costs a point, never a wrong one.
    static func of(_ building: BuildingModel,
                   tower: TowerAnalysis.Result? = nil) -> PlainReading {
        var points: [Point] = []

        points.append(contentsOf: resonancePoints(building))
        points.append(contentsOf: materialAndSystemPoints(building))
        points.append(contentsOf: eraPoints(building))
        points.append(contentsOf: shapePoints(building, tower: tower))
        points.append(contentsOf: retrofitPoints(building))

        // Worst first. A reader gives the first item most of their attention, so
        // it had better be the one that matters most.
        points.sort { $0.severity > $1.severity }

        let level = points.map(\.severity).max() ?? .ordinary
        let (confidence, note) = confidenceOf(building)

        return PlainReading(
            headline: headline(for: level, points: points),
            summary: summary(for: level, confidence: confidence),
            caveat: "This is a reading of what this building is, not of what condition it is "
                + "in. It cannot see cracks, corrosion, alterations, or how well it was actually "
                + "built. Only an engineer inside the building can tell you that.",
            points: points,
            actions: actions(for: level, building: building, points: points),
            confidence: confidence,
            confidenceNote: note,
            level: level)
    }

    // MARK: Resonance with the ground

    /// The one that is never intuitive and matters most.
    ///
    /// A building has a period; so does the ground under it. When they match,
    /// the ground feeds the building in step with its own swaying and the motion
    /// builds instead of dissipating — the same reason a swing goes higher when
    /// pushed at the right moment. It is why the 1985 Mexico City earthquake
    /// destroyed mid-rise buildings on the old lake bed while leaving both
    /// shorter and taller ones standing, and it cannot be seen by looking at a
    /// building.
    private static func resonancePoints(_ building: BuildingModel) -> [Point] {
        let period = building.empiricalPeriod
        let ground = building.soil.resonantPeriod
        guard period > 0.01, ground > 0.01 else { return [] }

        // Compared as a ratio, not a difference: 0.2 s apart means something
        // quite different at 0.3 s than at 3 s.
        let ratio = period / ground
        let nearness = abs(log(ratio))

        var result: [Point] = []

        if nearness < 0.22 {
            result.append(Point(
                title: "It sways at about the rate this ground shakes",
                meaning: String(
                    format: "This building takes about %.1f seconds to sway back and forth, and "
                        + "the ground beneath it tends to shake at about %.1f seconds. When those "
                        + "match, each push from the ground arrives just as the building is "
                        + "already leaning that way, so the movement builds rather than dying "
                        + "away — the same reason a swing goes higher when you push it in time. "
                        + "This is what destroyed mid-rise buildings in Mexico City in 1985 while "
                        + "leaving their taller and shorter neighbours standing, and it is not "
                        + "something you could see by looking at the building.",
                    period, ground),
                severity: .serious,
                isInferred: !building.provenance(for: "soil").isConfirmed))
        } else if nearness < 0.45 {
            result.append(Point(
                title: "Its sway rate is close to this ground's",
                meaning: String(
                    format: "It sways in about %.1f seconds and this ground shakes at around "
                        + "%.1f. Not a match, but near enough that the ground will feed the "
                        + "building's movement more than it would on firmer soil.",
                    period, ground),
                severity: .worthKnowing,
                isInferred: !building.provenance(for: "soil").isConfirmed))
        }

        if building.soil.amplification >= 1.5 {
            result.append(Point(
                title: "Soft ground here, which magnifies shaking",
                meaning: String(
                    format: "%@ amplifies ground motion by roughly %.0f%% compared with rock. "
                        + "The earthquake does not get bigger; what reaches this particular "
                        + "building does. Two identical buildings a mile apart can have very "
                        + "different earthquakes.",
                    building.soil.label, (building.soil.amplification - 1) * 100),
                severity: building.soil == .softSoil ? .serious : .worthKnowing,
                isInferred: !building.provenance(for: "soil").isConfirmed))
        }

        return result
    }

    // MARK: What it is made of, and how it stands up

    private static func materialAndSystemPoints(_ building: BuildingModel) -> [Point] {
        var result: [Point] = []
        let materialInferred = !building.provenance(for: "material").isConfirmed
        let systemInferred = !building.provenance(for: "system").isConfirmed

        switch building.material {
        case .unreinforcedMasonry:
            result.append(Point(
                title: "Unreinforced brick or stone",
                meaning: "Brickwork with no steel through it. It carries weight downwards very "
                    + "well and resists sideways movement badly: there is nothing holding the "
                    + "wall together once it starts to crack, so it can shed sections outwards "
                    + "rather than bending. This is the single most lethal common building type "
                    + "in earthquakes, and it is the reason retrofit programmes exist.",
                severity: .serious,
                isInferred: materialInferred))
        case .masonry:
            result.append(Point(
                title: "Reinforced masonry",
                meaning: "Brick or block with steel through it. Far better than plain masonry, "
                    + "but still stiff and comparatively brittle — it resists movement rather "
                    + "than absorbing it.",
                severity: .worthKnowing,
                isInferred: materialInferred))
        case .timber:
            result.append(Point(
                title: "Timber frame",
                meaning: "Light and flexible, which is a genuine advantage: there is less mass "
                    + "for the earthquake to move, and wood bends without shattering. Timber "
                    + "houses come through shaking well. What tends to fail is the connection to "
                    + "the foundation, and cripple walls in the crawl space underneath.",
                severity: .ordinary,
                isInferred: materialInferred))
        case .steel, .reinforcedConcrete, .hybrid, .unknown:
            break
        }

        switch building.system {
        case .softStorey:
            result.append(Point(
                title: "A weak ground floor",
                meaning: "The ground floor is much more open than the floors above — parking, "
                    + "shopfronts, a lobby with few walls. All the sideways movement of the "
                    + "whole building has to be absorbed by that one level, and everything above "
                    + "it acts as weight pressing down while it deforms. This is the pattern "
                    + "behind the photographs of buildings sitting on a collapsed ground floor "
                    + "with the upper storeys apparently intact.",
                severity: .serious,
                isInferred: systemInferred))
        case .bearingWall:
            result.append(Point(
                title: "The walls hold the building up",
                meaning: "There is no separate frame — the walls carry both the weight and the "
                    + "sideways load. It leaves nothing in reserve: a wall that is damaged "
                    + "resisting the earthquake is also a wall that was holding up the floor "
                    + "above it.",
                severity: .worthKnowing,
                isInferred: systemInferred))
        case .baseIsolated:
            result.append(Point(
                title: "It sits on isolators",
                meaning: "The building rests on bearings that let the ground move underneath it "
                    + "while the building above stays comparatively still. It is the most "
                    + "effective protection there is, and it is why hospitals and emergency "
                    + "centres are built this way.",
                severity: .ordinary,
                isInferred: systemInferred))
        case .momentFrame where building.system.ductility >= 3.5:
            result.append(Point(
                title: "A frame designed to bend",
                meaning: "Beams and columns joined so they can flex and absorb energy rather "
                    + "than resisting rigidly and breaking. Bending is how a building survives "
                    + "an earthquake; this one is built to do it.",
                severity: .ordinary,
                isInferred: systemInferred))
        default:
            break
        }

        return result
    }

    // MARK: When it was built

    /// Age matters because of what the code required at the time, not because of
    /// decay.
    ///
    /// The dates are deliberately broad. Seismic provisions arrived at different
    /// times in different countries and this model has no way to know which code
    /// governed a given building, so the point is phrased as a question to ask
    /// rather than a finding — a 1965 building in a country with early
    /// provisions may be fine, and saying otherwise would be inventing detail
    /// the model does not have.
    private static func eraPoints(_ building: BuildingModel) -> [Point] {
        guard let year = building.yearBuilt else {
            return [Point(
                title: "Its age is unknown",
                meaning: "When a building was built says a great deal about it, because it "
                    + "determines which earthquake rules it was built to. Without a date, that "
                    + "whole line of reasoning is unavailable here.",
                severity: .worthKnowing,
                isInferred: true)]
        }

        let inferred = !building.provenance(for: "yearBuilt").isConfirmed

        if year < 1940 {
            return [Point(
                title: "Built in \(year), before earthquake rules existed",
                meaning: "Buildings from this period were designed for weight and wind, not for "
                    + "shaking. Anything that helps it in an earthquake is there by luck or by "
                    + "later work, not by design. It may still have been strengthened since — "
                    + "that is worth finding out.",
                severity: .serious,
                isInferred: inferred)]
        }
        if year < 1980 {
            return [Point(
                title: "Built in \(year), before modern detailing",
                meaning: "Earthquake rules existed by then but were far less demanding, and in "
                    + "particular did not require the close steel reinforcement that lets a "
                    + "concrete column keep carrying its load after it has cracked. That "
                    + "detailing is most of the difference between a column that sags and one "
                    + "that fails outright. Which rules applied depends on where this is, so "
                    + "treat it as a question to ask rather than a conclusion.",
                severity: .worthKnowing,
                isInferred: inferred)]
        }
        if year >= 2000 {
            return [Point(
                title: "Built in \(year), under modern rules",
                meaning: "Recent enough that it was almost certainly designed to bend and absorb "
                    + "energy rather than to resist rigidly, and detailed accordingly. This is "
                    + "the most reassuring single fact a building can have.",
                severity: .ordinary,
                isInferred: inferred)]
        }
        return []
    }

    // MARK: Its shape

    private static func shapePoints(_ building: BuildingModel,
                                    tower: TowerAnalysis.Result?) -> [Point] {
        var result: [Point] = []

        if let tower, tower.isTorsionallySensitive {
            result.append(Point(
                title: "It twists as readily as it leans",
                meaning: "Its stiff parts are gathered towards the middle rather than spread to "
                    + "the edges, so there is little leverage resisting rotation. A building that "
                    + "rotates moves its corners much further than its centre, and corners are "
                    + "where the columns are — which is why this pattern takes corners off "
                    + "buildings.",
                severity: .worthKnowing,
                isInferred: !building.provenance(for: "system").isConfirmed))
        }

        if let step = building.massing.largestDiscontinuity, step.drop > 0.28 {
            // Named in storeys rather than as a fraction of the height, because
            // "about the fourth floor" is somewhere a person can stand and
            // "0.38 of the way up" is not.
            let storey = max(Int((step.atHeightFraction
                                  * Double(building.storeyCount)).rounded()), 1)
            result.append(Point(
                title: "Its width changes abruptly partway up",
                meaning: String(
                    format: "The floor plan drops by about %.0f%% at around the %d%@ storey. An "
                        + "earthquake finds any abrupt change in a building and concentrates its "
                        + "work there, so the floors at that step carry far more than their "
                        + "share. A building that changes gradually spreads the demand out "
                        + "instead.",
                    step.drop * 100, storey, ordinalSuffix(storey)),
                severity: step.drop > 0.45 ? .serious : .worthKnowing,
                isInferred: false))
        }

        let slenderness = building.height / max(building.footprintArea.squareRoot(), 1)
        if slenderness > 4 {
            result.append(Point(
                title: "Tall and narrow",
                meaning: String(
                    format: "It is about %.0f times taller than it is wide, so it behaves like a "
                        + "mast: it leans far at the top and the whole overturning force lands on "
                        + "the foundations. Slender is not unsafe — it is deliberate, and tall "
                        + "buildings are designed for it — but it means the top will move a great "
                        + "deal, and that movement is alarming long before it is dangerous.",
                    slenderness),
                severity: .ordinary,
                isInferred: false))
        }

        return result
    }

    // MARK: What has been done to it

    private static func retrofitPoints(_ building: BuildingModel) -> [Point] {
        switch building.retrofit {
        case .none:
            return []
        case .partial:
            return [Point(
                title: "Partly strengthened",
                meaning: "Some strengthening work has been done. Partial work helps, but it can "
                    + "also move the weak point rather than removing it — what matters is "
                    + "whether the part that was left alone is now the weakest link.",
                severity: .ordinary)]
        case .full:
            return [Point(
                title: "Fully strengthened",
                meaning: "It has had a full seismic retrofit, which means somebody has assessed "
                    + "this specific building and fixed what they found. That is worth more than "
                    + "anything inferred from its age or type — including everything above.",
                severity: .ordinary)]
        case .baseIsolationRetrofit:
            return [Point(
                title: "Retrofitted with isolators",
                meaning: "Bearings have been installed beneath it so the ground can move without "
                    + "taking the building with it. This is the most thorough retrofit that "
                    + "exists and is normally reserved for buildings judged worth saving "
                    + "outright.",
                severity: .ordinary)]
        }
    }

    // MARK: Assembling the words

    /// Counts rather than quotes.
    ///
    /// A first version put the worst point's own wording in the headline, which
    /// then appeared twice on screen a centimetre apart — the headline said
    /// nothing the list below did not, and the repetition read as padding. The
    /// count is the one thing the list cannot show at a glance.
    private static func headline(for level: Level, points: [Point]) -> String {
        let flagged = points.filter { $0.severity == level }.count

        switch level {
        case .serious:
            return flagged == 1
                ? "One thing here is known to fail in earthquakes"
                : "\(spelled(flagged)) things here are known to fail in earthquakes"
        case .worthKnowing:
            return flagged == 1
                ? "One thing here affects how it will behave"
                : "\(spelled(flagged)) things here affect how it will behave"
        case .ordinary:
            return "Nothing about this building stands out as a known weakness"
        }
    }

    private static func spelled(_ n: Int) -> String {
        switch n {
        case 2: "Two"
        case 3: "Three"
        case 4: "Four"
        case 5: "Five"
        default: "\(n)"
        }
    }

    private static func summary(for level: Level, confidence: Double) -> String {
        var parts: [String] = []

        switch level {
        case .serious:
            parts.append("This building has at least one feature that has repeatedly caused "
                + "buildings to collapse in real earthquakes. That is not a prediction that it "
                + "will — many such buildings stand through large earthquakes — but it is the "
                + "kind of thing an engineer would want to look at.")
        case .worthKnowing:
            parts.append("Nothing here is in the category that causes collapses, but there are "
                + "specific things about this building that affect how it will behave.")
        case .ordinary:
            parts.append("Going on what is known about it, this building has none of the "
                + "features most strongly associated with earthquake damage.")
        }

        if confidence < 0.55 {
            parts.append("Much of what this rests on was inferred rather than confirmed, so "
                + "treat it as a starting point for questions rather than an answer.")
        }

        return parts.joined(separator: " ")
    }

    private static func actions(for level: Level, building: BuildingModel,
                                points: [Point]) -> [String] {
        var result: [String] = []

        if level == .serious {
            result.append("Ask whether this building has had a seismic assessment. For the "
                + "features flagged above, that is a question with a real answer, and often a "
                + "documented one.")
        }

        if points.contains(where: { $0.title.contains("weak ground floor") }) {
            result.append("Ground-floor strengthening — steel frames or added walls at that one "
                + "level — is a well-understood fix and much cheaper than it sounds relative to "
                + "the risk it removes.")
        }

        if building.material == .unreinforcedMasonry {
            result.append("Ask whether the walls have been tied to the floors. That single "
                + "measure is the difference between a wall that stays with the building and one "
                + "that falls away from it.")
        }

        if building.material == .timber {
            result.append("Check that the frame is bolted to its foundation and that any cripple "
                + "walls underneath are braced. It is the commonest weakness in timber houses "
                + "and among the cheapest to fix.")
        }

        // Present at every level, because the app's real value is the baseline
        // it builds before anything happens, and that requires doing it early.
        result.append("Record a baseline now, while nothing has happened. This app compares a "
            + "building against its own past behaviour, and it can only do that if it knows what "
            + "normal looked like beforehand.")

        result.append("Secure what is inside. In most earthquakes the injuries come from "
            + "furniture, glass and falling objects rather than from the structure, and that part "
            + "is entirely within your control.")

        return result
    }

    // MARK: How much of this is known

    /// Confidence from the provenance record, not from a feeling.
    ///
    /// The fields are weighted by how much the reading above actually leans on
    /// them: the structural system and material drive most of the points, the
    /// soil class drives the resonance point that carries the heaviest warning,
    /// and the height is nearly always right because it is the easiest thing to
    /// find. Weighting them equally would let three confidently known trivia
    /// paper over a guessed structural system.
    private static func confidenceOf(_ building: BuildingModel) -> (Double, String) {
        let weighted: [(field: String, weight: Double, name: String)] = [
            ("system", 0.30, "structural system"),
            ("material", 0.25, "material"),
            ("soil", 0.20, "ground conditions"),
            ("yearBuilt", 0.15, "year built"),
            ("height", 0.10, "height"),
        ]

        var score = 0.0
        var guessed: [String] = []
        for entry in weighted {
            let provenance = building.provenance(for: entry.field)
            score += entry.weight * provenance.confidence
            if !provenance.isConfirmed { guessed.append(entry.name) }
        }

        let note: String
        if guessed.isEmpty {
            note = "Everything this reading depends on is confirmed rather than inferred."
        } else if guessed.count >= 4 {
            note = "Most of this is inferred: " + list(guessed) + " were all guessed rather "
                + "than confirmed. Correcting any of them will change the reading, and the app "
                + "will trust your correction over its own guess."
        } else {
            note = "Inferred rather than confirmed: " + list(guessed) + ". Correcting "
                + (guessed.count == 1 ? "it" : "them") + " will change the reading."
        }

        return (min(max(score, 0), 1), note)
    }

    private static func ordinalSuffix(_ n: Int) -> String {
        // 11th, 12th, 13th are the exceptions that catch every naive version.
        if (11...13).contains(n % 100) { return "th" }
        switch n % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}
