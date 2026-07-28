import Foundation
import SeismicCore
import SeismicSignal

// Algorithms 46–50. Everything measured so far becomes one defensible answer to
// the only question the user actually has: is it safe to go inside?

// MARK: - 46. Fragility curves

/// A lognormal fragility curve: the probability of reaching or exceeding a
/// damage state, given a level of demand.
///
/// Two numbers describe it — the median demand at which half of buildings of
/// this type reach the state, and the dispersion, which is how much identical
/// buildings differ from one another. The dispersion is large in practice
/// (0.4–0.7), and pretending otherwise is how screening tools end up making
/// confident wrong calls.
public struct FragilityCurve: Sendable, Equatable, Codable {
    public var damageState: DamageState
    /// Median demand — interstorey drift ratio — for this state.
    public var medianDemand: Double
    /// Lognormal standard deviation.
    public var dispersion: Double

    public init(damageState: DamageState, medianDemand: Double, dispersion: Double) {
        self.damageState = damageState
        self.medianDemand = Swift.max(medianDemand, 1e-9)
        self.dispersion = Swift.max(dispersion, 0.05)
    }

    /// Algorithm 46 — probability of exceeding this damage state.
    public func probabilityOfExceedance(demand: Double) -> Double {
        guard demand > 0 else { return 0 }
        let z = log(demand / medianDemand) / dispersion
        return Swift.min(Swift.max(Stats.normalCDF(z), 0), 1)
    }
}

public struct FragilitySet: Sendable, Equatable, Codable {
    public var curves: [FragilityCurve]
    public var systemLabel: String

    public init(curves: [FragilityCurve], systemLabel: String) {
        self.curves = curves.sorted { $0.damageState < $1.damageState }
        self.systemLabel = systemLabel
    }

    /// Derives a set from the drift thresholds, treating each threshold as the
    /// median for its state. Dispersion widens for the more severe states, where
    /// building-to-building variation genuinely matters more.
    public static func from(_ thresholds: DriftThresholds, label: String) -> FragilitySet {
        FragilitySet(curves: [
            FragilityCurve(damageState: .slight, medianDemand: thresholds.slight, dispersion: 0.40),
            FragilityCurve(damageState: .moderate, medianDemand: thresholds.moderate, dispersion: 0.45),
            FragilityCurve(damageState: .extensive, medianDemand: thresholds.extensive, dispersion: 0.55),
            FragilityCurve(damageState: .complete, medianDemand: thresholds.complete, dispersion: 0.65),
        ], systemLabel: label)
    }

    /// Probability of being in *exactly* each damage state — the difference
    /// between successive exceedance probabilities. These sum to one, which is
    /// what makes them presentable as a stacked bar.
    public func stateProbabilities(demand: Double) -> [DamageState: Double] {
        let exceedance = curves.reduce(into: [DamageState: Double]()) {
            $0[$1.damageState] = $1.probabilityOfExceedance(demand: demand)
        }
        let slight = exceedance[.slight] ?? 0
        let moderate = exceedance[.moderate] ?? 0
        let extensive = exceedance[.extensive] ?? 0
        let complete = exceedance[.complete] ?? 0

        return [
            .none: Swift.max(1 - slight, 0),
            .slight: Swift.max(slight - moderate, 0),
            .moderate: Swift.max(moderate - extensive, 0),
            .extensive: Swift.max(extensive - complete, 0),
            .complete: Swift.max(complete, 0),
        ]
    }

    public func mostLikelyState(demand: Double) -> DamageState {
        stateProbabilities(demand: demand).max { $0.value < $1.value }?.key ?? .none
    }
}

// MARK: - 47. Bayesian evidence fusion

/// The heart of the assessment.
///
/// Each independent measurement — a lengthened period, a residual offset, a
/// permanent tilt, a photograph of a crack — shifts the odds that the building
/// is damaged. Fusing them by likelihood ratio has three properties that matter
/// enormously here:
///
///   • Independent weak evidence accumulates. Three mild indications together
///     can justify a verdict none of them would alone.
///   • Contradictory evidence *reduces* confidence rather than being ignored.
///     A large period change with no residual displacement and no tilt is
///     suspicious, and the interval widens to say so.
///   • Missing evidence is not treated as reassuring. A building with no tilt
///     sensor gets a wider interval, not a greener verdict.
public enum BayesianFusion {

    public struct Input: Sendable, Equatable {
        /// Prior probability of damage before any measurement, set by how hard
        /// the building was shaken.
        public var prior: Double
        public var evidence: [Evidence]

        public init(prior: Double, evidence: [Evidence]) {
            self.prior = Swift.min(Swift.max(prior, 0.001), 0.999)
            self.evidence = evidence
        }
    }

    public struct Output: Sendable, Equatable {
        public var probability: Double
        public var interval: ClosedRange<Double>
        public var confidence: Double
        public var verdict: SafetyVerdict
        public var reasoning: String
        /// How much each item moved the answer, in log-odds. Lets the UI rank
        /// the evidence by how much it actually mattered.
        public var contributions: [(evidence: Evidence, logOddsShift: Double)]

        public static func == (a: Output, b: Output) -> Bool {
            a.probability == b.probability && a.verdict == b.verdict
        }
    }

    /// Algorithm 47 — fuse the evidence.
    public static func fuse(_ input: Input) -> Output {
        var logOdds = log(input.prior / (1 - input.prior))
        var contributions: [(Evidence, Double)] = []
        var totalWeight = 0.0
        var informativeCount = 0

        for item in input.evidence {
            // `damageIndication` runs −1 (strongly reassuring) to +1 (strongly
            // incriminating). Scaled by the item's weight, it becomes a
            // log-likelihood ratio.
            let indication = Swift.min(Swift.max(item.damageIndication, -1), 1)
            let weight = Swift.max(item.weight, 0)
            guard weight > 0 else { continue }

            // A source that is not a direct measurement gets discounted.
            let credibility = item.source.baseConfidence
            let shift = indication * weight * 2.2 * credibility
            logOdds += shift
            contributions.append((item, shift))
            totalWeight += weight
            if abs(indication) > 0.15 { informativeCount += 1 }
        }

        let probability = 1 / (1 + exp(-logOdds))

        // Interval width comes from three things: how much evidence there is,
        // how much of it disagrees, and how close the answer is to a boundary.
        let disagreement = disagreementScore(contributions.map(\.1))
        let evidenceFactor = 1 / (1 + totalWeight)
        let spread = Swift.min(0.42 * evidenceFactor + 0.30 * disagreement + 0.04, 0.45)

        let lower = Swift.max(probability - spread, 0)
        let upper = Swift.min(probability + spread, 1)
        let confidence = Swift.min(Swift.max(1 - spread * 2, 0), 1)

        let verdict = decideVerdict(probability: probability, interval: lower...upper,
                                    evidence: input.evidence)

        return Output(probability: probability,
                      interval: lower...upper,
                      confidence: confidence,
                      verdict: verdict,
                      reasoning: explain(probability: probability, spread: spread,
                                         disagreement: disagreement,
                                         informativeCount: informativeCount,
                                         evidence: input.evidence, verdict: verdict),
                      contributions: contributions.map { (evidence: $0.0, logOddsShift: $0.1) })
    }

    /// How much the evidence pulls in opposite directions, 0…1.
    private static func disagreementScore(_ shifts: [Double]) -> Double {
        guard shifts.count > 1 else { return 0 }
        let positive = shifts.filter { $0 > 0 }.reduce(0, +)
        let negative = -shifts.filter { $0 < 0 }.reduce(0, +)
        let total = positive + negative
        guard total > 1e-9 else { return 0 }
        // Maximum when the two sides are equal.
        return 2 * Swift.min(positive, negative) / total
    }

    /// Turning a probability into a placard.
    ///
    /// Deliberately asymmetric. Telling somebody a damaged building is safe is a
    /// far worse error than telling them a sound building needs an inspection,
    /// so the thresholds are set to make the first mistake hard to reach — and
    /// any single piece of *hard* evidence, like a permanent tilt, forces a
    /// severe verdict regardless of what the probability says.
    private static func decideVerdict(probability: Double,
                                      interval: ClosedRange<Double>,
                                      evidence: [Evidence]) -> SafetyVerdict {
        // Overriding physical facts. A building that is permanently leaning has
        // moved off its foundations; no amount of contrary statistics matters.
        if evidence.contains(where: { $0.kind == .permanentTilt && $0.damageIndication > 0.5 }) {
            return .red
        }
        if evidence.contains(where: { $0.kind == .visualDamage && $0.damageIndication > 0.85 }) {
            return .red
        }

        // A wide interval means "we do not know", which is its own answer and
        // must never be rounded down to green.
        let width = interval.upperBound - interval.lowerBound
        if width > 0.55 { return .needsInspection }

        switch probability {
        case ..<0.15:
            // Only call it green if the *upper* bound is also reassuring.
            return interval.upperBound < 0.35 ? .green : .needsInspection
        case 0.15..<0.45:
            return .needsInspection
        case 0.45..<0.72:
            return .amber
        default:
            return .red
        }
    }

    private static func explain(probability: Double, spread: Double, disagreement: Double,
                                informativeCount: Int, evidence: [Evidence],
                                verdict: SafetyVerdict) -> String {
        var parts: [String] = []

        parts.append("Combining \(evidence.count) piece\(evidence.count == 1 ? "" : "s") of "
            + "evidence gives a \(Int((probability * 100).rounded()))% probability that this "
            + "building's structural behaviour has genuinely changed.")

        if informativeCount == 0 {
            parts.append("None of the measurements departed meaningfully from this building's "
                + "established normal behaviour.")
        }

        if disagreement > 0.4 {
            parts.append("The measurements disagree with each other, which widens the range "
                + "considerably — some indicators point to damage while others do not.")
        }

        if spread > 0.3 {
            parts.append("There is not enough independent evidence for a confident answer.")
        }

        switch verdict {
        case .green:
            parts.append("Nothing found suggests structural change.")
        case .amber:
            parts.append("There is real evidence of change. Limit occupancy and arrange an inspection.")
        case .red:
            parts.append("The evidence for structural damage is strong. Stay out until an engineer "
                + "has looked at it.")
        case .needsInspection:
            parts.append("The evidence is inconclusive. This is precisely the case where a "
                + "professional inspection is worth its cost.")
        }

        return parts.joined(separator: " ")
    }

    /// Prior probability of damage given how hard the building was shaken, from
    /// the fragility curves. This is what makes the assessment sensitive to
    /// context: the same 3% period change means something very different after
    /// a violent shake than after a barely felt one.
    public static func prior(fromDemand demand: Double, fragility: FragilitySet) -> Double {
        let moderate = fragility.curves.first { $0.damageState == .moderate }
        return Swift.min(Swift.max(moderate?.probabilityOfExceedance(demand: demand) ?? 0.1,
                                   0.02), 0.9)
    }
}

// MARK: - Evidence construction

/// Builds the evidence list from raw measurements.
///
/// Kept separate from the fusion so the *interpretation* of each measurement is
/// visible and arguable on its own, rather than buried inside a scoring function.
public enum EvidenceBuilder {

    /// Period change is the headline measurement. The literature is consistent:
    /// a 10% lengthening indicates significant damage, 20% is severe. Below
    /// about 3% is within the range that temperature and amplitude alone can
    /// produce, which is why the temperature-corrected value must be used here.
    public static func fromPeriodChange(before: Double, after: Double,
                                        temperatureCorrected: Bool,
                                        measurementConfidence: Double) -> Evidence? {
        guard before > 0, after > 0 else { return nil }
        let change = (after - before) / before
        let percent = change * 100

        // Map the change onto the −1…+1 indication scale.
        let indication: Double
        switch percent {
        case ..<(-3): indication = -0.3     // a *stiffer* building is odd, not reassuring
        case (-3)..<3: indication = -0.55   // genuinely reassuring: no change
        case 3..<7: indication = 0.25
        case 7..<12: indication = 0.6
        case 12..<20: indication = 0.85
        default: indication = 0.97
        }

        let detail: String
        switch percent {
        case ..<(-3):
            detail = "The period got *shorter*, which a damaged building does not do. This usually "
                + "means the two measurements were taken under different conditions rather than "
                + "that anything changed structurally."
        case (-3)..<3:
            detail = "A change this small is within the range that temperature and shaking "
                + "amplitude alone produce. It is not evidence of damage."
        case 3..<7:
            detail = "A small but real lengthening. Worth watching; not on its own a reason to "
                + "stay out."
        case 7..<12:
            detail = "A lengthening of this size normally means the structure has lost measurable "
                + "stiffness — cracked concrete, yielded connections, or similar."
        case 12..<20:
            detail = "A large lengthening. Significant structural damage is the most likely "
                + "explanation."
        default:
            detail = "A very large lengthening. The building has lost a substantial fraction of "
                + "its lateral stiffness."
        }

        return Evidence(
            kind: .periodChange,
            headline: String(format: "%+.1f%% period change", percent),
            detail: detail + (temperatureCorrected
                ? " This figure has been corrected for temperature."
                : " No temperature correction was available, so treat small changes cautiously."),
            value: percent, unit: "%",
            damageIndication: indication,
            weight: (temperatureCorrected ? 1.6 : 1.0) * Swift.max(measurementConfidence, 0.2),
            source: .measured)
    }

    /// A building that ends up displaced from where it started has yielded.
    /// Unlike the period, this cannot be explained away by temperature.
    public static func fromResidualDisplacement(_ metres: Double,
                                                buildingHeight: Double) -> Evidence? {
        guard metres.isFinite, buildingHeight > 0 else { return nil }
        let millimetres = metres * 1000
        let ratio = metres / buildingHeight

        let indication: Double
        let detail: String
        switch millimetres {
        case ..<2:
            indication = -0.5
            detail = "The building returned to where it started, within the sensor's resolution. "
                + "Elastic response, no permanent set."
        case 2..<10:
            indication = 0.3
            detail = "A small permanent offset. Could be genuine minor yielding, or the sensor "
                + "mount settling."
        case 10..<40:
            indication = 0.7
            detail = "A clear permanent offset. Something in the structure deformed and stayed "
                + "deformed."
        default:
            indication = 0.92
            detail = "A large permanent offset. The structure has yielded substantially."
        }

        return Evidence(
            kind: .residualDisplacement,
            headline: String(format: "%.1f mm residual displacement", millimetres),
            detail: detail + String(format: " That is %.3f%% of the building's height.", ratio * 100),
            value: millimetres, unit: "mm",
            damageIndication: indication, weight: 1.3, source: .measured)
    }

    /// Tilt is the bluntest and most decisive measurement there is.
    public static func fromTilt(degrees: Double, tripped: Bool) -> Evidence? {
        guard tripped || degrees > 0.05 else {
            return Evidence(
                kind: .permanentTilt,
                headline: "No permanent tilt",
                detail: "The tilt switch did not latch and the measured inclination is unchanged. "
                    + "The building is still standing plumb.",
                value: degrees, unit: "°",
                damageIndication: -0.6, weight: 1.1, source: .measured)
        }

        let indication: Double = switch degrees {
        case ..<0.3: 0.45
        case 0.3..<1.0: 0.8
        default: 0.98
        }

        return Evidence(
            kind: .permanentTilt,
            headline: String(format: "%.2f° permanent tilt", degrees),
            detail: "The building is no longer plumb. A structure that leans has moved on its "
                + "foundations or lost capacity in a lower storey; either way it should not be "
                + "occupied until an engineer has seen it.",
            value: degrees, unit: "°",
            damageIndication: indication, weight: 1.8, source: .measured)
    }

    /// How hard it was actually shaken. This is context rather than damage: it
    /// sets expectations, and a building that reports damage after trivial
    /// shaking is more likely to have a sensor problem than a structural one.
    public static func fromShakingSeverity(pga: Double, cav: Double,
                                           thresholdExceeded: Bool) -> Evidence {
        let intensity = IntensityScale.fromPGA(pga)
        let indication: Double = thresholdExceeded
            ? Swift.min((intensity.continuous - 5) / 5, 0.6)
            : -0.45

        return Evidence(
            kind: .peakAcceleration,
            headline: String(format: "%.3f g peak, intensity %@", pga / gravity, intensity.intensity.roman),
            detail: thresholdExceeded
                ? "Shaking of this level is capable of damaging buildings like this one. "
                    + intensity.intensity.consequence
                : "This shaking was below the level generally capable of damaging a sound "
                    + "structure, so any measured change is more likely to have another cause.",
            value: pga / gravity, unit: "g",
            damageIndication: indication, weight: 0.8, source: .measured)
    }

    public static func fromDriftDemand(_ drift: Double, storey: Int,
                                       thresholds: DriftThresholds) -> Evidence {
        let state = thresholds.state(for: drift)
        let indication: Double = switch state {
        case .none: -0.4
        case .slight: 0.2
        case .moderate: 0.65
        case .extensive: 0.9
        case .complete: 0.99
        }

        return Evidence(
            kind: .driftDemand,
            headline: String(format: "%.2f%% peak drift at storey %d", drift * 100, storey),
            detail: "Simulated from the recorded ground motion and this building's model. "
                + state.description,
            value: drift * 100, unit: "%",
            damageIndication: indication, weight: 0.9, source: .aiInference)
    }

    public static func fromVisualInspection(severity: Double, note: String,
                                            isProfessional: Bool) -> Evidence {
        Evidence(
            kind: isProfessional ? .humanJudgment : .visualDamage,
            headline: isProfessional ? "Professional inspection" : "Photographed damage",
            detail: note,
            value: severity, unit: "",
            damageIndication: Swift.min(Swift.max(severity * 2 - 1, -1), 1),
            weight: isProfessional ? 2.5 : 1.0,
            source: isProfessional ? .userEntered : .photogrammetry)
    }
}

// MARK: - 48. CUSUM change detection

/// Algorithm 48 — cumulative sum change detection.
///
/// Some damage does not arrive in one event. Repeated moderate shaking,
/// corrosion, foundation settlement — these soften a building by a fraction of a
/// per cent at a time, which no single measurement can distinguish from noise.
/// CUSUM accumulates small deviations from the established baseline, so a
/// persistent drift in one direction eventually crosses a threshold even though
/// no individual reading ever looked unusual.
public enum CUSUM {

    public struct Result: Sendable, Equatable {
        public var upperSums: [Double]
        public var lowerSums: [Double]
        /// Index at which a sustained change was first detected, if any.
        public var changeIndex: Int?
        public var changeDetected: Bool { changeIndex != nil }
        public var direction: Direction
        public var explanation: String

        public enum Direction: String, Sendable { case none, softening, stiffening }
    }

    /// - Parameters:
    ///   - slack: how large a deviation to ignore, in standard deviations.
    ///     Usually half the shift you want to detect.
    ///   - threshold: decision limit, in standard deviations. Five is the
    ///     conventional choice, trading a false alarm every few hundred
    ///     observations for reliable detection.
    public static func detect(_ values: [Double], baseline: Double, standardDeviation: Double,
                              slack: Double = 0.5, threshold: Double = 5.0) -> Result {
        guard !values.isEmpty, standardDeviation > 1e-12 else {
            return Result(upperSums: [], lowerSums: [], changeIndex: nil,
                          direction: .none,
                          explanation: "Not enough history yet to detect a slow trend.")
        }

        var upper = [Double](repeating: 0, count: values.count)
        var lower = [Double](repeating: 0, count: values.count)
        var changeIndex: Int?
        var direction = Result.Direction.none

        for i in 0..<values.count {
            let z = (values[i] - baseline) / standardDeviation
            let previousUpper = i > 0 ? upper[i - 1] : 0
            let previousLower = i > 0 ? lower[i - 1] : 0

            upper[i] = Swift.max(0, previousUpper + z - slack)
            lower[i] = Swift.max(0, previousLower - z - slack)

            if changeIndex == nil {
                if upper[i] > threshold { changeIndex = i; direction = .softening }
                else if lower[i] > threshold { changeIndex = i; direction = .stiffening }
            }
        }

        let explanation: String
        if let index = changeIndex {
            let word = direction == .softening ? "lengthening" : "shortening"
            explanation = "A sustained \(word) trend was detected at observation \(index + 1) of "
                + "\(values.count). No single measurement was unusual, but they have been "
                + "consistently on one side of the baseline — which is how gradual damage "
                + "presents itself."
        } else {
            explanation = "No sustained trend. Measurements are scattered either side of the "
                + "baseline, as they should be."
        }

        return Result(upperSums: upper, lowerSums: lower, changeIndex: changeIndex,
                      direction: direction, explanation: explanation)
    }

    /// Convenience for a period history: baseline and scatter are estimated
    /// robustly from the first portion of the record, so an event at the end
    /// cannot inflate the baseline and hide itself.
    public static func onPeriodHistory(_ periods: [Double],
                                       baselineFraction: Double = 0.4) -> Result {
        guard periods.count >= 8 else {
            return Result(upperSums: [], lowerSums: [], changeIndex: nil, direction: .none,
                          explanation: "At least eight measurements are needed before a slow "
                              + "trend can be separated from ordinary scatter.")
        }
        let baselineCount = Swift.max(Int(Double(periods.count) * baselineFraction), 4)
        let baselineWindow = Array(periods.prefix(baselineCount))
        let baseline = Stats.median(baselineWindow)
        let scatter = Swift.max(Stats.mad(baselineWindow), baseline * 0.002)
        return detect(periods, baseline: baseline, standardDeviation: scatter)
    }
}

// MARK: - 49. Mahalanobis anomaly detection

/// Algorithm 49 — anomaly detection against the building's own learned normal.
///
/// Every building is different, so an absolute threshold is useless: 1.4 s is
/// perfectly normal for one structure and alarming for another. This learns what
/// this specific building normally does across several correlated features and
/// measures how far a new observation sits from that cloud — accounting for the
/// correlations, so a combination that is individually unremarkable but jointly
/// impossible still registers.
public enum AnomalyDetection {

    public struct Model: Sendable, Equatable {
        public var means: [Double]
        /// Inverse covariance matrix.
        public var precision: [[Double]]
        public var featureNames: [String]
        public var sampleCount: Int
        /// Distance beyond which an observation counts as anomalous, set from
        /// the training data rather than assumed.
        public var threshold: Double

        public var isTrained: Bool { sampleCount >= 12 && !means.isEmpty }
    }

    public struct Verdict: Sendable, Equatable {
        public var distance: Double
        public var isAnomalous: Bool
        /// Which features contributed most, for explaining the flag.
        public var featureContributions: [(name: String, contribution: Double)]
        public var explanation: String

        public static func == (a: Verdict, b: Verdict) -> Bool {
            a.distance == b.distance && a.isAnomalous == b.isAnomalous
        }
    }

    /// Trains on historical observations. Each row is one scan; each column a
    /// feature (period, damping, ambient level, temperature…).
    public static func train(observations: [[Double]], featureNames: [String]) -> Model {
        guard let first = observations.first, !first.isEmpty,
              observations.allSatisfy({ $0.count == first.count }) else {
            return Model(means: [], precision: [], featureNames: featureNames,
                         sampleCount: 0, threshold: 0)
        }
        let d = first.count
        let n = observations.count

        let means = (0..<d).map { j in
            observations.reduce(0) { $0 + $1[j] } / Double(n)
        }

        var covariance = [[Double]](repeating: [Double](repeating: 0, count: d), count: d)
        for row in observations {
            for i in 0..<d {
                for j in 0..<d {
                    covariance[i][j] += (row[i] - means[i]) * (row[j] - means[j])
                }
            }
        }
        let divisor = Double(Swift.max(n - 1, 1))
        for i in 0..<d {
            for j in 0..<d { covariance[i][j] /= divisor }
            // Ridge term. Without it a feature that never varies — a node with a
            // stuck thermistor, say — makes the matrix singular and every
            // observation infinitely anomalous.
            covariance[i][i] += 1e-9 + abs(covariance[i][i]) * 1e-6
        }

        guard let precision = invert(covariance) else {
            return Model(means: means, precision: [], featureNames: featureNames,
                         sampleCount: 0, threshold: 0)
        }

        // Threshold from the training distances themselves: the 97.5th
        // percentile, so roughly one normal scan in forty is flagged.
        let distances = observations.map {
            mahalanobis($0, means: means, precision: precision)
        }
        let threshold = Swift.max(Stats.percentile(distances, 97.5), 1e-6)

        return Model(means: means, precision: precision, featureNames: featureNames,
                     sampleCount: n, threshold: threshold)
    }

    public static func evaluate(_ observation: [Double], model: Model) -> Verdict {
        guard model.isTrained, observation.count == model.means.count else {
            return Verdict(distance: 0, isAnomalous: false, featureContributions: [],
                           explanation: "Not enough history yet to know what normal looks like "
                               + "for this building. At least twelve measurements are needed.")
        }

        let distance = mahalanobis(observation, means: model.means, precision: model.precision)
        let isAnomalous = distance > model.threshold

        // Per-feature contribution: how far each one sits from its own mean, in
        // units of its own spread.
        var contributions: [(String, Double)] = []
        for i in 0..<observation.count {
            let variance = model.precision[i][i] > 1e-30 ? 1 / model.precision[i][i] : 1
            let z = (observation[i] - model.means[i]) / Swift.max(variance.squareRoot(), 1e-12)
            let name = i < model.featureNames.count ? model.featureNames[i] : "feature \(i + 1)"
            contributions.append((name, z * z))
        }
        contributions.sort { $0.1 > $1.1 }

        let explanation: String
        if isAnomalous, let worst = contributions.first {
            explanation = "This measurement sits \(String(format: "%.1f", distance)) units away "
                + "from this building's normal behaviour, past the \(String(format: "%.1f", model.threshold)) "
                + "limit learned from \(model.sampleCount) previous scans. "
                + "\(worst.0.capitalizedFirst) departs furthest from normal."
        } else {
            explanation = "Consistent with this building's normal behaviour, learned from "
                + "\(model.sampleCount) previous measurements."
        }

        return Verdict(distance: distance, isAnomalous: isAnomalous,
                       featureContributions: contributions.map { (name: $0.0, contribution: $0.1) },
                       explanation: explanation)
    }

    public static func mahalanobis(_ x: [Double], means: [Double],
                                   precision: [[Double]]) -> Double {
        guard x.count == means.count, precision.count == x.count else { return 0 }
        let delta = zip(x, means).map(-)
        var total = 0.0
        for i in 0..<delta.count {
            for j in 0..<delta.count {
                total += delta[i] * precision[i][j] * delta[j]
            }
        }
        return Swift.max(total, 0).squareRoot()
    }

    /// Matrix inversion by Gauss-Jordan. Small matrices only, which is all this
    /// ever sees.
    public static func invert(_ matrix: [[Double]]) -> [[Double]]? {
        let n = matrix.count
        guard n > 0, matrix.allSatisfy({ $0.count == n }) else { return nil }
        var a = matrix
        var inverse = LinearAlgebra.identity(n)

        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<n where abs(a[r][col]) > abs(a[pivot][col]) { pivot = r }
            guard abs(a[pivot][col]) > 1e-16 else { return nil }
            if pivot != col { a.swapAt(pivot, col); inverse.swapAt(pivot, col) }

            let d = a[col][col]
            for j in 0..<n { a[col][j] /= d; inverse[col][j] /= d }

            for r in 0..<n where r != col {
                let factor = a[r][col]
                guard factor != 0 else { continue }
                for j in 0..<n {
                    a[r][j] -= factor * a[col][j]
                    inverse[r][j] -= factor * inverse[col][j]
                }
            }
        }
        return inverse
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}

// MARK: - 50. Aftershock forecasting

/// Algorithm 50 — Omori-Utsu decay combined with Gutenberg-Richter magnitudes.
///
/// "When can I go back inside?" is the question people actually ask after an
/// earthquake, and it deserves a real answer rather than a shrug. Aftershock
/// rates decay in a well-established way — roughly as 1/time — and magnitudes
/// follow an equally well-established distribution. Together they give a
/// defensible probability that a damaging aftershock will strike within any
/// given window, which is exactly what a re-entry decision needs.
public enum AftershockForecast {

    public struct Parameters: Sendable, Equatable, Codable {
        /// Productivity: the log of the rate constant.
        public var a: Double
        /// Gutenberg-Richter slope. Close to 1.0 nearly everywhere on Earth.
        public var b: Double
        /// Omori decay exponent. Typically 1.0–1.2.
        public var p: Double
        /// Omori offset in days, which stops the rate being infinite at t = 0.
        public var c: Double

        public init(a: Double = -1.67, b: Double = 1.0, p: Double = 1.08, c: Double = 0.05) {
            self.a = a; self.b = b
            self.p = Swift.max(p, 0.5)
            self.c = Swift.max(c, 1e-4)
        }

        /// The generic global parameters, used when a region-specific forecast
        /// is unavailable.
        public static let generic = Parameters()
    }

    public struct Forecast: Sendable, Equatable {
        public var windowHours: Double
        /// Expected number of aftershocks at or above the magnitude of interest.
        public var expectedCount: Double
        /// Probability of at least one.
        public var probabilityOfAtLeastOne: Double
        public var magnitudeThreshold: Double
        public var explanation: String
    }

    /// Expected number of events of magnitude ≥ `magnitude` between
    /// `fromHours` and `toHours` after the mainshock.
    public static func expectedCount(mainshockMagnitude: Double, magnitude: Double,
                                     fromHours: Double, toHours: Double,
                                     parameters: Parameters = .generic) -> Double {
        guard toHours > fromHours, toHours > 0 else { return 0 }
        let t1 = Swift.max(fromHours, 0) / 24
        let t2 = toHours / 24

        // Productivity: N ∝ 10^(a + b·(Mmain − M))
        let productivity = pow(10, parameters.a + parameters.b * (mainshockMagnitude - magnitude))

        // Integrate the Omori rate over the window.
        let p = parameters.p, c = parameters.c
        let integral: Double
        if abs(p - 1) < 1e-6 {
            integral = log((t2 + c) / (t1 + c))
        } else {
            integral = (pow(t2 + c, 1 - p) - pow(t1 + c, 1 - p)) / (1 - p)
        }

        return Swift.max(productivity * integral, 0)
    }

    /// Probability of at least one such event, assuming the events form a
    /// Poisson process within the window — which is the standard assumption and
    /// good enough for a re-entry decision.
    public static func forecast(mainshockMagnitude: Double,
                                magnitudeThreshold: Double? = nil,
                                fromHours: Double = 0, toHours: Double = 24,
                                parameters: Parameters = .generic) -> Forecast {
        // Default threshold: the size capable of finishing off an
        // already-damaged building, about 1.5 units below the mainshock.
        let threshold = magnitudeThreshold ?? Swift.max(mainshockMagnitude - 1.5, 4.0)
        let expected = expectedCount(mainshockMagnitude: mainshockMagnitude,
                                     magnitude: threshold,
                                     fromHours: fromHours, toHours: toHours,
                                     parameters: parameters)
        let probability = 1 - exp(-expected)

        let percent = Int((probability * 100).rounded())
        let window = toHours - fromHours
        let windowLabel = window >= 48
            ? "\(Int(window / 24)) days" : "\(Int(window)) hours"

        return Forecast(
            windowHours: window,
            expectedCount: expected,
            probabilityOfAtLeastOne: probability,
            magnitudeThreshold: threshold,
            explanation: "Over the next \(windowLabel) there is roughly a \(percent)% chance of "
                + "at least one aftershock of magnitude \(String(format: "%.1f", threshold)) or "
                + "greater — large enough to further damage a building already weakened by the "
                + "mainshock. Aftershock rates fall off quickly, so waiting is genuinely "
                + "worthwhile.")
    }

    /// The re-entry guidance the assessment screen shows.
    public struct ReentryGuidance: Sendable, Equatable {
        public var recommendedWaitHours: Double
        public var headline: String
        public var detail: String
        public var forecasts: [Forecast]
    }

    public static func reentryGuidance(mainshockMagnitude: Double,
                                       verdict: SafetyVerdict,
                                       hoursSinceMainshock: Double = 0,
                                       parameters: Parameters = .generic) -> ReentryGuidance {
        let windows: [Double] = [1, 6, 24, 72, 168]
        let forecasts = windows.map {
            forecast(mainshockMagnitude: mainshockMagnitude,
                     fromHours: hoursSinceMainshock,
                     toHours: hoursSinceMainshock + $0,
                     parameters: parameters)
        }

        // How much aftershock risk is tolerable depends entirely on how damaged
        // the building already is. A sound building can take another shake; one
        // that is already cracked may not.
        let acceptable: Double = switch verdict {
        case .green: 0.35
        case .amber: 0.12
        case .red: 0.02
        case .needsInspection: 0.08
        }

        // Find how long until the risk over the *next hour* drops below the
        // acceptable level.
        var wait = 0.0
        for hours in stride(from: 0.0, through: 336, by: 1) {
            let next = forecast(mainshockMagnitude: mainshockMagnitude,
                                fromHours: hoursSinceMainshock + hours,
                                toHours: hoursSinceMainshock + hours + 1,
                                parameters: parameters)
            if next.probabilityOfAtLeastOne <= acceptable { wait = hours; break }
            wait = hours
        }

        let headline: String
        let detail: String
        switch verdict {
        case .red:
            headline = "Do not re-enter"
            detail = "This building should not be entered at all until an engineer has inspected "
                + "it, aftershocks or not. A structure in this condition can fail under a shock "
                + "far smaller than the one that damaged it."
        case .amber:
            headline = wait < 1 ? "Brief essential access only" : "Wait about \(Int(wait.rounded())) hours"
            detail = "The building has measurable damage, so an aftershock matters more than it "
                + "would to an undamaged structure. Limit yourself to short, essential trips, and "
                + "know your exit before you go in."
        case .needsInspection:
            headline = "Limit time inside"
            detail = "Until the evidence is resolved, treat the building as possibly damaged. "
                + "Aftershock probability falls quickly over the first day."
        case .green:
            headline = "Normal occupancy is reasonable"
            detail = "No structural change was detected. Ordinary aftershock precautions apply: "
                + "know where to shelter, and expect to feel more shaking over the coming days."
        }

        return ReentryGuidance(recommendedWaitHours: wait, headline: headline,
                               detail: detail, forecasts: forecasts)
    }
}
