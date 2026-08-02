import Foundation
import SeismicCore

/// Where the model expects a building to crack, and whether a photograph agrees.
///
/// A photograph filed under "storey three" is an archive entry. The same
/// photograph next to the sentence "storey three is where this building bends
/// hardest" is evidence — and next to "the model bends hardest at storey seven"
/// it is a question worth asking, which is more useful still.
///
/// The prediction is deliberately made from the building alone rather than from
/// a particular earthquake. The first mode shape is a property of the structure:
/// it says where the storeys shear against each other when it sways, whatever
/// is shaking it. That means this works before any event has happened, which is
/// exactly when somebody is walking round with a phone looking at cracks.
public enum ExpectedDamage {

    /// Per-storey interstorey drift under the first mode, normalised so the
    /// worst storey is 1.
    ///
    /// Interstorey drift, not displacement. The top of a building moves furthest
    /// and cracks least: what damages a storey is the *difference* between the
    /// floor above it and the floor below, and a naive reading of mode shape
    /// amplitude gets this exactly backwards — which is how you end up telling
    /// somebody to inspect the roof.
    public static func driftProfile(of building: ShearBuilding) -> [Double] {
        let modes = ModalAnalysis.modes(of: building)
        guard let first = modes.first, first.shape.count == building.storeys.count else {
            return Array(repeating: 0, count: building.storeys.count)
        }

        var drifts: [Double] = []
        drifts.reserveCapacity(first.shape.count)
        var below = 0.0                      // the ground does not move
        for (index, amplitude) in first.shape.enumerated() {
            let height = max(building.storeys[index].height, 0.1)
            drifts.append(abs(amplitude - below) / height)
            below = amplitude
        }

        let peak = drifts.max() ?? 0
        guard peak > 0 else { return Array(repeating: 0, count: drifts.count) }
        return drifts.map { $0 / peak }
    }

    /// The storey the model expects to be worst, numbered from 1.
    public static func worstStorey(of building: ShearBuilding) -> Int? {
        let profile = driftProfile(of: building)
        guard let index = profile.indices.max(by: { profile[$0] < profile[$1] }),
              profile[index] > 0 else { return nil }
        return index + 1
    }

    /// How a photograph pinned to a storey sits against the prediction.
    public struct Agreement: Sendable, Equatable {
        /// The storey the photograph was pinned to.
        public var storey: Int
        /// That storey's expected drift, 0–1 against the worst storey.
        public var expected: Double
        /// The storey the model expects to be worst.
        public var worstStorey: Int
        public var verdict: Verdict
        /// One sentence, for the screen.
        public var explanation: String

        public enum Verdict: String, Sendable, Equatable {
            /// The crack is where the model bends hardest.
            case confirms
            /// Somewhere the model bends a fair amount, but not most.
            case plausible
            /// Somewhere the model barely bends at all.
            case unexpected
        }
    }

    /// Compares a pinned photograph against the prediction.
    ///
    /// The wording matters more than the number here, so it is written once,
    /// centrally, rather than in the view. In particular, `unexpected` is
    /// phrased as a question rather than a dismissal: a crack somewhere the
    /// model does not bend is usually non-structural, and occasionally it is
    /// the most important thing in the building — a short column, a missing
    /// wall, something the shear model does not represent. Telling somebody
    /// their crack "does not match" would be both wrong and dangerous.
    public static func agreement(forStorey storey: Int,
                                 in building: ShearBuilding) -> Agreement? {
        let profile = driftProfile(of: building)
        guard storey >= 1, storey <= profile.count,
              let worst = worstStorey(of: building) else { return nil }
        let expected = profile[storey - 1]

        let verdict: Agreement.Verdict
        let explanation: String
        switch expected {
        case 0.85...:
            verdict = .confirms
            explanation = storey == worst
                ? "This is the storey the model bends hardest. A crack here is where one "
                    + "would be expected, which makes it worth measuring rather than "
                    + "explaining away."
                : "This storey bends almost as hard as the worst one (storey \(worst)). "
                    + "A crack here is consistent with how the building moves."
        case 0.45..<0.85:
            verdict = .plausible
            explanation = "This storey takes a moderate share of the bending — the model "
                + "works hardest at storey \(worst). Consistent, but not the first place "
                + "to look."
        default:
            verdict = .unexpected
            explanation = "The model barely bends here; it works hardest at storey \(worst). "
                + "That usually means a crack at this level is non-structural — plaster, "
                + "render, a partition. Occasionally it means the opposite, and something "
                + "the model does not represent is carrying load. Worth a second look "
                + "either way."
        }

        return Agreement(storey: storey, expected: expected, worstStorey: worst,
                         verdict: verdict, explanation: explanation)
    }
}
