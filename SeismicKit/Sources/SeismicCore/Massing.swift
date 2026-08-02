import Foundation

/// How a building's plan changes as it rises.
///
/// Until now every storey shared one footprint, so every building was a prism:
/// the Transamerica Pyramid came out a square box, and a tower on a podium came
/// out as if the podium were the whole building. That is not only a drawing
/// problem. Mass distribution up the height is what the modal analysis is
/// integrating, and a podium puts a large fraction of a building's mass in its
/// bottom few storeys — which is exactly the case where getting it wrong
/// changes the answer rather than the picture.
///
/// A massing is a profile: the plan scale at a series of heights, interpolated
/// between. That covers the shapes real buildings actually take — uniform,
/// tapered, stepped back, and tower-on-podium — without modelling arbitrary
/// geometry the app has no way to obtain.
public struct Massing: Codable, Sendable, Equatable {

    /// One control point: a fraction of the total height, and the plan scale
    /// there, where 1 is the full footprint.
    public struct Station: Codable, Sendable, Equatable {
        public var heightFraction: Double
        public var scale: Double

        public init(heightFraction: Double, scale: Double) {
            self.heightFraction = min(max(heightFraction, 0), 1)
            // A storey cannot vanish. The upper bound is above 1 because
            // buildings really do overhang their own base — 30 St Mary Axe is
            // widest a third of the way up, and a great many towers cantilever
            // out over a smaller ground floor. Capping at 1 made every profile
            // monotonically narrowing by construction, which quietly ruled out
            // an entire family of shapes. The ceiling is a sanity limit, not a
            // statement about architecture.
            self.scale = min(max(scale, 0.05), Self.maximumScale)
        }

        /// The widest a floor may be relative to the ground plan.
        public static let maximumScale = 1.6
    }

    public var stations: [Station]

    public init(stations: [Station]) {
        // Sorted and de-duplicated: the interpolation walks this in order, and
        // a station out of sequence would fold the building back on itself.
        let sorted = stations.sorted { $0.heightFraction < $1.heightFraction }
        var unique: [Station] = []
        for station in sorted where unique.last?.heightFraction != station.heightFraction {
            unique.append(station)
        }
        self.stations = unique.isEmpty
            ? [Station(heightFraction: 0, scale: 1), Station(heightFraction: 1, scale: 1)]
            : unique
    }

    // MARK: Standard profiles

    /// A prism. What almost every ordinary building is.
    public static let uniform = Massing(stations: [
        .init(heightFraction: 0, scale: 1),
        .init(heightFraction: 1, scale: 1),
    ])

    /// Narrows continuously, like the Transamerica Pyramid.
    ///
    /// The taper is structural rather than stylistic: it puts mass low and
    /// reduces the overturning moment at the base.
    public static func tapered(topScale: Double = 0.25) -> Massing {
        Massing(stations: [
            .init(heightFraction: 0, scale: 1),
            .init(heightFraction: 1, scale: topScale),
        ])
    }

    /// Steps in at intervals — the classic setback tower.
    public static func setback(steps: Int = 3, topScale: Double = 0.45) -> Massing {
        let count = max(steps, 1)
        var stations: [Station] = [.init(heightFraction: 0, scale: 1)]
        for step in 1...count {
            let fraction = Double(step) / Double(count + 1)
            let scale = 1 - (1 - topScale) * (Double(step) / Double(count))
            // Two stations per step, a hair apart, so the plan changes abruptly
            // rather than sloping — a setback is a ledge, not a chamfer.
            stations.append(.init(heightFraction: fraction - 0.001,
                                  scale: stations.last?.scale ?? 1))
            stations.append(.init(heightFraction: fraction, scale: scale))
        }
        stations.append(.init(heightFraction: 1, scale: topScale))
        return Massing(stations: stations)
    }

    /// A slim tower standing on a wide podium.
    ///
    /// Worth its own case because of what it does structurally: the abrupt drop
    /// in plan area is also an abrupt drop in stiffness and mass, and that
    /// discontinuity concentrates demand at exactly the storey where it happens.
    public static func podium(podiumFraction: Double = 0.25,
                              towerScale: Double = 0.45) -> Massing {
        let fraction = min(max(podiumFraction, 0.05), 0.6)
        return Massing(stations: [
            .init(heightFraction: 0, scale: 1),
            .init(heightFraction: fraction, scale: 1),
            .init(heightFraction: fraction + 0.001, scale: towerScale),
            .init(heightFraction: 1, scale: towerScale),
        ])
    }

    // MARK: Curved profiles

    /// How finely a curved profile is sampled.
    ///
    /// The stations are interpolated linearly between, so a curve is a
    /// polyline — the same compromise the plan shapes make. Twenty-four
    /// segments put the largest deviation from the true curve well under a
    /// percent of the plan width, which is far below the accuracy of anything
    /// feeding into it.
    private static let curveSamples = 24

    private static func sampled(_ scale: (Double) -> Double) -> Massing {
        Massing(stations: (0...curveSamples).map { step in
            let t = Double(step) / Double(curveSamples)
            return Station(heightFraction: t, scale: scale(t))
        })
    }

    /// Swells to a maximum part way up, then closes towards the top.
    ///
    /// The shape of 30 St Mary Axe, Torre Agbar, and a long line of towers that
    /// are widest in the middle. It is not a stylistic flourish: moving mass
    /// away from the base raises the overturning moment, and closing the crown
    /// reduces the wind and inertia loads where the lever arm is longest, so a
    /// barrel is a considered trade rather than an arbitrary curve.
    ///
    /// - Parameters:
    ///   - bulge: how much wider than the ground plan the widest floor is.
    ///   - atFraction: where that widest floor sits.
    ///   - topScale: the crown, as a fraction of the ground plan.
    public static func barrel(bulge: Double = 0.2, atFraction: Double = 0.35,
                              topScale: Double = 0.45) -> Massing {
        let peak = min(max(atFraction, 0.1), 0.9)
        let widest = 1 + min(max(bulge, 0), Station.maximumScale - 1)
        let top = min(max(topScale, 0.05), widest)
        return sampled { t in
            // Two cosine half-waves meeting at the peak, so the curve is
            // smooth there rather than showing a kink at its widest point.
            if t <= peak {
                let u = t / peak
                return 1 + (widest - 1) * (1 - cos(u * .pi)) / 2
            }
            let u = (t - peak) / (1 - peak)
            return widest + (top - widest) * (1 - cos(u * .pi)) / 2
        }
    }

    /// Narrows quickly at first and then hardly at all — a hyperboloid.
    ///
    /// The silhouette of a cooling tower, of the Tokyo Skytree, and of the
    /// pagodas the Skytree borrows from. Structurally it is the efficient
    /// answer to a cantilever: the bending moment is largest at the base and
    /// falls off fast, so the material follows it.
    public static func concave(topScale: Double = 0.3) -> Massing {
        let top = min(max(topScale, 0.05), 1)
        // scale(t) = 1 / (1 + k·t), with k chosen so scale(1) lands exactly on
        // `top`. A width falling as the reciprocal of height is the classic
        // hyperbolic taper, and it bends far harder low down than any
        // polynomial through the same two endpoints — which is the whole
        // difference between this and `tapered`.
        let k = (1 / top) - 1
        return sampled { t in 1 / (1 + k * t) }
    }

    /// A vertical shaft that rounds over into a dome.
    ///
    /// The form of a great many observation towers and of any building with a
    /// domed crown. Kept separate from a taper because the structure below the
    /// shoulder is genuinely uniform, and treating the whole height as a taper
    /// would understate the mass in the shaft.
    public static func domed(shoulderFraction: Double = 0.75) -> Massing {
        let shoulder = min(max(shoulderFraction, 0.2), 0.95)
        return sampled { t in
            guard t > shoulder else { return 1 }
            // A quarter ellipse from the shoulder to the crown.
            let u = (t - shoulder) / (1 - shoulder)
            return max((1 - u * u).squareRoot(), 0.05)
        }
    }

    // MARK: Evaluation

    /// The plan scale at a height fraction, linearly interpolated.
    public func scale(at heightFraction: Double) -> Double {
        let target = min(max(heightFraction, 0), 1)
        guard let first = stations.first else { return 1 }
        if target <= first.heightFraction { return first.scale }
        guard let last = stations.last else { return 1 }
        if target >= last.heightFraction { return last.scale }

        for index in 1..<stations.count {
            let lower = stations[index - 1]
            let upper = stations[index]
            guard target <= upper.heightFraction else { continue }

            let span = upper.heightFraction - lower.heightFraction
            guard span > 1e-9 else { return upper.scale }
            let t = (target - lower.heightFraction) / span
            return lower.scale + (upper.scale - lower.scale) * t
        }
        return last.scale
    }

    /// The scale for each storey of a building, sampled at each storey's middle.
    ///
    /// Sampled at the middle rather than the base so a storey represents its own
    /// average plan; sampling at the base would make every setback appear one
    /// storey too high.
    public func scales(storeys: Int) -> [Double] {
        guard storeys > 0 else { return [] }
        return (0..<storeys).map { index in
            scale(at: (Double(index) + 0.5) / Double(storeys))
        }
    }

    /// True when the plan changes by more than a few per cent anywhere.
    public var isUniform: Bool {
        guard let first = stations.first?.scale else { return true }
        return stations.allSatisfy { abs($0.scale - first) < 0.02 }
    }

    /// The sharpest single change in plan, and where it happens.
    ///
    /// This is the number an engineer would look for. A large abrupt reduction
    /// is a vertical irregularity, and vertical irregularity is what makes a
    /// building fail at one level rather than distributing the damage.
    public var largestDiscontinuity: (atHeightFraction: Double, drop: Double)? {
        var worst: (Double, Double)?
        for index in 1..<max(stations.count, 1) {
            let lower = stations[index - 1]
            let upper = stations[index]
            // Only abrupt changes count. A gradual taper is not a discontinuity
            // however much total narrowing it adds up to.
            guard upper.heightFraction - lower.heightFraction < 0.02 else { continue }
            let drop = lower.scale - upper.scale
            guard drop > 0 else { continue }
            if worst == nil || drop > worst!.1 {
                worst = (upper.heightFraction, drop)
            }
        }
        return worst.map { (atHeightFraction: $0.0, drop: $0.1) }
    }

    /// The widest floor, and where it is.
    public var widest: (atHeightFraction: Double, scale: Double) {
        guard let first = stations.first else { return (0, 1) }
        var best = (first.heightFraction, first.scale)
        for station in stations where station.scale > best.1 {
            best = (station.heightFraction, station.scale)
        }
        return best
    }

    /// True when the building is wider somewhere above its base than at it.
    public var bulges: Bool { widest.scale > (stations.first?.scale ?? 1) + 0.02 }

    /// How far the profile departs from a straight line between its ends.
    ///
    /// This is what separates a curve from a taper. A straight taper scores
    /// zero however steep it is; a hyperbolic narrowing or a barrel scores well
    /// above it. Signed, so the direction of the bend survives: positive where
    /// the profile bows outside the straight line between its ends, which is a
    /// barrel; negative where it falls inside, which is a reciprocal taper
    /// shedding width faster near the base than a straight edge would.
    public var curvature: Double {
        guard let first = stations.first, let last = stations.last,
              last.heightFraction - first.heightFraction > 1e-9 else { return 0 }
        var worst = 0.0
        for station in stations {
            let t = (station.heightFraction - first.heightFraction)
                / (last.heightFraction - first.heightFraction)
            let straight = first.scale + (last.scale - first.scale) * t
            let deviation = station.scale - straight
            if abs(deviation) > abs(worst) { worst = deviation }
        }
        return worst
    }

    /// True when the profile is a curve rather than straight edges.
    ///
    /// Abrupt steps are excluded: a setback deviates from the straight line
    /// too, and it is emphatically not a curve — the distinction matters
    /// because a step concentrates demand at one storey and a curve does not.
    public var isCurved: Bool {
        largestDiscontinuity == nil && abs(curvature) > 0.04
    }

    /// Plain-language description, for the import screen and the designer.
    public var summary: String {
        if isUniform { return "Uniform plan from base to roof." }

        // Any abrupt step at all makes this a setback, not a taper.
        //
        // The threshold used to be a 20% drop in a *single* step, which meant a
        // building stepping in three times by 17% each described itself as
        // tapering — smooth language for the one profile that is emphatically
        // not smooth. How much the largest step matters is a separate question
        // from what the shape is called, and it is answered in the sentence.
        if let discontinuity = largestDiscontinuity {
            let severity = discontinuity.drop > 0.2
                ? "which concentrates demand at that level."
                : "small enough that no one level dominates, but the steps are still where "
                    + "stiffness changes abruptly."
            return String(
                format: "The plan steps in, the largest drop being %.0f%% at about %.0f%% of "
                    + "the height — a setback, %@",
                discontinuity.drop * 100, discontinuity.atHeightFraction * 100, severity)
        }

        let top = stations.last?.scale ?? 1
        if bulges {
            let peak = widest
            return String(
                format: "Swells to %.0f%% of the ground plan at about %.0f%% of the height, then "
                    + "closes to %.0f%%. Carrying mass outward and upward raises the overturning "
                    + "moment at the base, which is the price of the shape.",
                peak.scale * 100, peak.atHeightFraction * 100, top * 100)
        }
        if isCurved {
            // A dome and a reciprocal taper are both curves and both end
            // narrower than they start, so the endpoints cannot tell them
            // apart — but they are opposite shapes, and describing a crown as
            // "narrows quickly at first" is simply the wrong way round.
            if scale(at: 0.5) > (stations.first?.scale ?? 1) - 0.02 {
                return String(
                    format: "A straight shaft that rounds over into a crown, closing to about "
                        + "%.0f%% of the plan at the top. The structure below the shoulder is "
                        + "uniform, so its mass is carried the whole way up.", top * 100)
            }
            return String(
                format: "Narrows along a curve to about %.0f%% of the base plan, quickly at "
                    + "first and then hardly at all — the profile follows the bending moment, "
                    + "which is largest at the base and falls away fast.", top * 100)
        }
        return String(format: "Tapers to about %.0f%% of the base plan, which puts mass low "
                      + "and reduces the moment at the base.", top * 100)
    }
}

// MARK: - Per-storey outlines

public extension Massing {
    /// The footprint of each storey: the base outline scaled by the profile.
    func outlines(base: [Coordinate2D], storeys: Int) -> [[Coordinate2D]] {
        scales(storeys: storeys).map { scale in
            base.map { Coordinate2D(x: $0.x * scale, y: $0.y * scale) }
        }
    }

    /// The floor area of each storey.
    ///
    /// Area scales with the square of a linear scale, which is the thing most
    /// worth being careful about here: a tower at half the plan width has a
    /// quarter of the floor area, and therefore a quarter of the mass.
    func floorAreas(baseArea: Double, storeys: Int) -> [Double] {
        scales(storeys: storeys).map { baseArea * $0 * $0 }
    }
}
