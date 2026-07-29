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
            // A storey cannot vanish, and a plan larger than the stated
            // footprint would enclose more area than the building has.
            self.scale = min(max(scale, 0.05), 1)
        }
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

    /// Plain-language description, for the import screen and the designer.
    public var summary: String {
        if isUniform { return "Uniform plan from base to roof." }
        if let discontinuity = largestDiscontinuity, discontinuity.drop > 0.2 {
            return String(
                format: "The plan drops by %.0f%% at about %.0f%% of the height — a setback, "
                    + "which concentrates demand at that level.",
                discontinuity.drop * 100, discontinuity.atHeightFraction * 100)
        }
        let top = stations.last?.scale ?? 1
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
