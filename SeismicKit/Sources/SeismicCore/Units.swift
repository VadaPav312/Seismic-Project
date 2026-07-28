import Foundation

/// Standard gravity, m/s². Every acceleration in the app is stored in m/s² and
/// converted to g only at the moment of display, so no unit ever survives a
/// round trip through the maths.
public let gravity: Double = 9.80665

public extension Double {
    /// m/s² → g
    var inG: Double { self / gravity }
    /// g → m/s²
    var fromG: Double { self * gravity }
    /// Hz → seconds (and seconds → Hz; the relationship is its own inverse).
    var reciprocalOrZero: Double { self == 0 ? 0 : 1 / self }
}

/// The intensity scale ordinary people can act on. Modified Mercalli, expressed
/// as a value with a plain-language consequence attached.
public enum MercalliIntensity: Int, CaseIterable, Codable, Sendable, Comparable {
    case notFelt = 1, weak = 2, slight = 3, light = 4, moderate = 5
    case strong = 6, veryStrong = 7, severe = 8, violent = 9, extreme = 10

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var roman: String {
        ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"][rawValue - 1]
    }

    public var shortLabel: String {
        switch self {
        case .notFelt: "Not felt"
        case .weak: "Weak"
        case .slight: "Slight"
        case .light: "Light"
        case .moderate: "Moderate"
        case .strong: "Strong"
        case .veryStrong: "Very strong"
        case .severe: "Severe"
        case .violent: "Violent"
        case .extreme: "Extreme"
        }
    }

    /// What this level typically does — the sentence that makes a number mean
    /// something to somebody who is not an engineer.
    public var consequence: String {
        switch self {
        case .notFelt: "Detected by instruments only. Nobody feels it."
        case .weak: "Felt by a few people at rest, mostly on upper floors."
        case .slight: "Felt indoors. Hanging objects swing. Often mistaken for a passing truck."
        case .light: "Felt by most indoors. Dishes and windows rattle. Parked cars rock."
        case .moderate: "Felt by nearly everyone. Small objects fall over. Some plaster cracks."
        case .strong: "Everyone feels it and many run outside. Furniture moves. Chimneys crack."
        case .veryStrong: "Hard to stand. Considerable damage to poorly built structures; slight damage to well-built ones."
        case .severe: "Well-built structures take significant damage. Weak masonry partially collapses."
        case .violent: "Substantial damage even to designed structures. Buildings shift off foundations."
        case .extreme: "Most masonry and frame structures destroyed. Ground visibly cracked."
        }
    }
}

/// Wald & Allen style peak-ground-acceleration to intensity conversion.
/// Algorithm support for the intensity translation feature.
public enum IntensityScale {
    /// The regression bends at MMI V, where the two segments meet continuously.
    /// Below it, perception scales gently with shaking; above it, damage sets in
    /// much faster than the acceleration alone suggests.
    private static let breakLogGal = 1.8197   // log10(66 gal) ≈ MMI V

    /// - Parameter pga: peak ground acceleration in m/s².
    public static func fromPGA(_ pga: Double) -> (intensity: MercalliIntensity, continuous: Double) {
        let pgaGal = max(pga * 100, 0.0001)          // m/s² → cm/s² (gal)
        let log = Foundation.log10(pgaGal)
        let raw = log <= breakLogGal ? 1.00 + 2.20 * log : -1.66 + 3.66 * log
        let clamped = min(max(raw, 1), 10)
        return (MercalliIntensity(rawValue: Int(clamped.rounded())) ?? .notFelt, clamped)
    }

    /// Inverse, for turning a target intensity into a shaking level to simulate.
    public static func pgaFor(intensity: Double) -> Double {
        let clamped = min(max(intensity, 1), 10)
        let logGal = clamped <= 5.0 ? (clamped - 1.00) / 2.20 : (clamped + 1.66) / 3.66
        return Foundation.pow(10, logGal) / 100
    }
}
