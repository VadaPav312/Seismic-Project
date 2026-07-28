import Foundation

/// Plain-language definitions, reachable from anywhere by long-pressing a term.
///
/// The app is full of words that mean something precise to an engineer and
/// nothing at all to the person whose house it is. Rather than avoiding those
/// words — which would make the app useless to the engineer — every one of them
/// is defined in a sentence a non-specialist can act on.
enum Glossary {

    struct Entry {
        let term: String
        let definition: String
        let seeAlso: [String]
    }

    static let entries: [Entry] = [
        Entry(term: "Natural period",
              definition: "How long a building takes to sway back and forth once, on its own. "
                + "A short building takes a fraction of a second; a skyscraper takes several. "
                + "It is fixed by the building's stiffness and weight, which is why measuring "
                + "it tells you about its condition.",
              seeAlso: ["Stiffness", "Resonance", "Mode shape"]),

        Entry(term: "Stiffness",
              definition: "How hard it is to push a building sideways. Cracking concrete or "
                + "bending steel makes a building less stiff, and a less stiff building sways "
                + "more slowly — which is what this app measures.",
              seeAlso: ["Natural period"]),

        Entry(term: "Resonance",
              definition: "When the ground shakes at close to a building's own natural rhythm, "
                + "each push arrives at exactly the right moment to add to the last. The sway "
                + "builds up enormously, like a child on a swing being pushed in time. It is "
                + "the single most dangerous thing an earthquake can do to a building.",
              seeAlso: ["Natural period", "Response spectrum"]),

        Entry(term: "P-wave",
              definition: "The first wave to arrive from an earthquake. It travels fastest, is "
                + "comparatively weak, and mostly pushes up and down. Detecting it is what "
                + "gives you seconds of warning before the damaging wave arrives.",
              seeAlso: ["S-wave", "Early warning"]),

        Entry(term: "S-wave",
              definition: "The second wave to arrive, and the one that does the damage. It "
                + "shakes side to side and is several times stronger than the P-wave. The gap "
                + "between the two tells you how far away the earthquake was.",
              seeAlso: ["P-wave", "Epicentral distance"]),

        Entry(term: "Storey drift",
              definition: "How far one floor moves sideways relative to the floor below it, as "
                + "a fraction of the storey height. It is the measure engineers actually use, "
                + "because damage depends on how much a storey deforms rather than on how far "
                + "the whole building moved.",
              seeAlso: ["Damage state"]),

        Entry(term: "Damping",
              definition: "How quickly a building's sway dies away after the shaking stops. "
                + "High damping is good: the energy turns into heat in the structure instead of "
                + "continuing to shake it.",
              seeAlso: ["Base isolation"]),

        Entry(term: "Base isolation",
              definition: "Putting a building on flexible bearings so the ground can move "
                + "underneath it without dragging it along. It works by making the building's "
                + "period much longer than the shaking's, moving it away from resonance.",
              seeAlso: ["Resonance", "Damping"]),

        Entry(term: "Soft storey",
              definition: "A floor much weaker than the ones above it — usually a ground floor "
                + "opened up for parking or shops. Nearly all the building's movement "
                + "concentrates there, and it is the most common cause of collapse worldwide.",
              seeAlso: ["Storey drift"]),

        Entry(term: "PGA",
              definition: "Peak ground acceleration: the hardest single shove the ground gave, "
                + "usually quoted as a fraction of gravity. 0.1 g is clearly felt; 0.5 g is "
                + "violent. It is the most quoted number and not the most useful one.",
              seeAlso: ["Arias intensity", "Intensity"]),

        Entry(term: "Arias intensity",
              definition: "The total energy the shaking delivered, rather than its single "
                + "worst instant. A long moderate shake can do more damage than a brief violent "
                + "one, and this is the number that captures that.",
              seeAlso: ["PGA", "Significant duration"]),

        Entry(term: "Intensity",
              definition: "A description of what the shaking actually did, on a scale from I "
                + "(instruments only) to X (near-total destruction). Unlike magnitude, it is "
                + "specific to where you were standing.",
              seeAlso: ["Magnitude", "PGA"]),

        Entry(term: "Magnitude",
              definition: "How big the earthquake was at its source. One number for the whole "
                + "event, regardless of where you were. Each step up the scale is about thirty "
                + "times more energy released.",
              seeAlso: ["Intensity"]),

        Entry(term: "Epicentral distance",
              definition: "How far you are from the point on the surface directly above where "
                + "the earthquake started. A single sensor can work this out from the gap "
                + "between the P-wave and the S-wave.",
              seeAlso: ["P-wave", "S-wave"]),

        Entry(term: "Response spectrum",
              definition: "A chart showing how hard a particular earthquake hits buildings of "
                + "every different period. Find your building's period along the bottom and "
                + "read off how much it would have been shaken.",
              seeAlso: ["Natural period", "Resonance"]),

        Entry(term: "Mode shape",
              definition: "The characteristic pattern a building bends into when it sways. The "
                + "first mode is a simple lean; higher modes have the building bending in an S "
                + "and carry much less of its weight.",
              seeAlso: ["Natural period"]),

        Entry(term: "Damage state",
              definition: "A standard classification from none through slight, moderate and "
                + "extensive to complete. It describes structural condition, not whether the "
                + "wallpaper is torn.",
              seeAlso: ["Storey drift", "Fragility curve"]),

        Entry(term: "Fragility curve",
              definition: "The probability that a building of a given type reaches a given "
                + "level of damage, for a given amount of shaking. It is probabilistic because "
                + "two identical buildings genuinely do behave differently.",
              seeAlso: ["Damage state"]),

        Entry(term: "STA/LTA",
              definition: "Short-term average over long-term average: the detector that decides "
                + "an earthquake has started. It compares the energy of the last fraction of a "
                + "second against the last several seconds, so it triggers on a change rather "
                + "than on a fixed threshold.",
              seeAlso: ["P-wave"]),

        Entry(term: "Residual displacement",
              definition: "How far the building ended up from where it started. A building that "
                + "returns exactly to its original position behaved elastically; one that does "
                + "not has permanently deformed.",
              seeAlso: ["Damage state"]),

        Entry(term: "Aftershock",
              definition: "A smaller earthquake following the main one, on the same fault. They "
                + "are most frequent immediately afterwards and thin out over days to weeks. A "
                + "building already damaged by the mainshock is far more vulnerable to them.",
              seeAlso: ["Omori's law"]),

        Entry(term: "Omori's law",
              definition: "The observation that aftershocks become less frequent roughly in "
                + "proportion to one over the time since the mainshock. It is what makes "
                + "\"wait a few hours\" a defensible piece of advice rather than a guess.",
              seeAlso: ["Aftershock"]),

        Entry(term: "Liquefaction",
              definition: "When shaking turns saturated loose soil temporarily into something "
                + "closer to a liquid. Buildings can sink, tilt or float upwards regardless of "
                + "how well the structure itself was built.",
              seeAlso: ["Site class"]),

        Entry(term: "Site class",
              definition: "A classification of the ground beneath a building, from hard rock to "
                + "soft clay. Soft ground amplifies shaking substantially, and amplifies slow "
                + "shaking most — which is why tall buildings on soft ground are a bad "
                + "combination.",
              seeAlso: ["Liquefaction", "Resonance"]),

        Entry(term: "Significant duration",
              definition: "How long the shaking actually mattered for, measured between the "
                + "points where 5% and 95% of the total energy had arrived. It ignores the "
                + "quiet tails at either end.",
              seeAlso: ["Arias intensity"]),

        Entry(term: "Temperature correction",
              definition: "Adjusting a measured period to account for how warm the building "
                + "was. Concrete stiffens as it cools, so a building genuinely sways faster on "
                + "a cold morning — by about as much as real damage would change it. Without "
                + "this correction the system would cry wolf every winter.",
              seeAlso: ["Natural period", "Stiffness"]),
    ]

    private static let index: [String: Entry] = {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.term.lowercased(), $0) })
    }()

    static func definition(for term: String) -> String {
        if let entry = index[term.lowercased()] { return entry.definition }
        // Try a loose match before giving up, so "natural period of the
        // building" still resolves.
        if let entry = entries.first(where: {
            term.lowercased().contains($0.term.lowercased())
        }) {
            return entry.definition
        }
        return "No definition recorded for \"\(term)\" yet."
    }

    static func entry(for term: String) -> Entry? { index[term.lowercased()] }

    static func search(_ query: String) -> [Entry] {
        guard !query.isEmpty else { return entries.sorted { $0.term < $1.term } }
        let lowered = query.lowercased()
        return entries
            .filter { $0.term.lowercased().contains(lowered)
                || $0.definition.lowercased().contains(lowered) }
            .sorted { $0.term < $1.term }
    }
}
