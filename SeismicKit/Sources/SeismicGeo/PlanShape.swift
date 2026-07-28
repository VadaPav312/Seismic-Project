import Foundation
import SeismicCore

/// The plan shape of a building, and how to turn it into a footprint polygon.
///
/// This exists for the buildings OpenStreetMap has not mapped. Where there is a
/// real traced outline the app uses it and this is never consulted; where there
/// is not, the alternative used to be a rectangle of the right area, which made
/// every unmapped building look identical and — worse — quietly asserted a
/// symmetry most real buildings do not have.
///
/// The shape is not cosmetic. Plan irregularity is one of the strongest
/// predictors of earthquake damage there is: re-entrant corners concentrate
/// stress, and mass distributed away from the centre of rigidity twists a
/// building rather than simply pushing it. A model that draws an L-shaped
/// hospital wing as a box has thrown that away before the solver ever runs.
public enum PlanShape: String, Codable, Sendable, CaseIterable {
    case rectangular
    case square
    case lShaped
    case tShaped
    case uShaped
    case cruciform
    case circular
    case octagonal
    case triangular
    /// A slab that narrows as it rises — modelled at its base extent here.
    case setbackTower

    public var label: String {
        switch self {
        case .rectangular: "Rectangular"
        case .square: "Square"
        case .lShaped: "L-shaped"
        case .tShaped: "T-shaped"
        case .uShaped: "U-shaped"
        case .cruciform: "Cruciform"
        case .circular: "Circular"
        case .octagonal: "Octagonal"
        case .triangular: "Triangular"
        case .setbackTower: "Setback tower"
        }
    }

    /// Whether this plan has re-entrant corners, which is what the codes
    /// actually care about.
    public var isIrregular: Bool {
        switch self {
        case .lShaped, .tShaped, .uShaped, .cruciform, .triangular: true
        case .rectangular, .square, .circular, .octagonal, .setbackTower: false
        }
    }

    /// A closed polygon in local metres, centred on the origin, enclosing
    /// approximately `area` square metres.
    ///
    /// - Parameters:
    ///   - area: target plan area, m².
    ///   - aspectRatio: long side divided by short side, for the shapes where
    ///     that is meaningful. Clamped to something buildable.
    public func polygon(area: Double, aspectRatio: Double = 1.6) -> [Coordinate2D] {
        let area = max(area, 10)
        let ratio = min(max(aspectRatio, 1), 6)

        switch self {
        case .square:
            return Self.rectangle(width: area.squareRoot(), depth: area.squareRoot())

        case .rectangular, .setbackTower:
            // width * depth = area, width = ratio * depth
            let depth = (area / ratio).squareRoot()
            return Self.rectangle(width: depth * ratio, depth: depth)

        case .circular:
            return Self.regularPolygon(sides: 32, area: area)

        case .octagonal:
            return Self.regularPolygon(sides: 8, area: area)

        case .triangular:
            return Self.regularPolygon(sides: 3, area: area)

        case .lShaped:
            // Two equal legs meeting at a corner. Removing a quarter of the
            // bounding square leaves three quarters, so the square is scaled up
            // to land on the requested area.
            let side = (area / 0.75).squareRoot()
            let half = side / 2
            let notch = side / 2
            return Self.close([
                (-half, -half), (half, -half), (half, -half + notch),
                (-half + notch, -half + notch), (-half + notch, half), (-half, half),
            ])

        case .tShaped:
            // A bar across the top, a stem down the middle. The bar is a
            // quarter of the side deep and the stem half of it wide, so the
            // solid is 0.25 + 0.375 = 0.625 of the bounding square.
            let side = (area / 0.625).squareRoot()
            let half = side / 2
            let stem = side * 0.25
            let barDepth = side * 0.25
            return Self.close([
                (-stem, -half), (stem, -half), (stem, half - barDepth),
                (half, half - barDepth), (half, half), (-half, half),
                (-half, half - barDepth), (-stem, half - barDepth),
            ])

        case .uShaped:
            // A solid base with two arms and a court between them. Arms a
            // quarter of the side wide, base half of it deep:
            // 0.5 + 2(0.25 x 0.5) = 0.75 of the bounding square.
            let side = (area / 0.75).squareRoot()
            let half = side / 2
            let armWidth = side * 0.25
            let baseDepth = side * 0.5
            return Self.close([
                (-half, -half), (half, -half), (half, half),
                (half - armWidth, half), (half - armWidth, -half + baseDepth),
                (-half + armWidth, -half + baseDepth), (-half + armWidth, half),
                (-half, half),
            ])

        case .cruciform:
            // A plus sign: five ninths of its bounding square.
            let side = (area / 0.5556).squareRoot()
            let half = side / 2
            let arm = side / 6
            return Self.close([
                (-arm, -half), (arm, -half), (arm, -arm), (half, -arm), (half, arm),
                (arm, arm), (arm, half), (-arm, half), (-arm, arm), (-half, arm),
                (-half, -arm), (-arm, -arm),
            ])
        }
    }

    /// Maps free text — an AI answer, a Wikipedia sentence — onto a shape.
    ///
    /// Deliberately permissive and deliberately conservative: anything it does
    /// not recognise becomes `nil` rather than a guess, so an unrecognised
    /// description falls back to the honest rectangle instead of inventing a
    /// cruciform hospital.
    public static func parse(_ raw: String) -> PlanShape? {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let exact = PlanShape(rawValue: text) { return exact }

        // Longest, most specific patterns first: "cruciform" before "cross",
        // and anything containing "rectangular" must not match "circular".
        let patterns: [(needles: [String], shape: PlanShape)] = [
            (["cruciform", "cross-shaped", "cross shaped", "plus-shaped"], .cruciform),
            (["l-shaped", "l shaped", "ell-shaped"], .lShaped),
            (["t-shaped", "t shaped"], .tShaped),
            (["u-shaped", "u shaped", "courtyard", "horseshoe"], .uShaped),
            (["circular", "cylindrical", "round tower", "rotunda", "drum"], .circular),
            (["octagon", "octagonal"], .octagonal),
            (["triangul", "wedge", "flatiron"], .triangular),
            (["setback", "stepped", "ziggurat", "tapering", "tapered"], .setbackTower),
            (["square"], .square),
            (["rectangul", "rectilinear", "slab", "oblong", "box"], .rectangular),
        ]
        for (needles, shape) in patterns where needles.contains(where: text.contains) {
            return shape
        }
        return nil
    }

    // MARK: Primitives

    private static func rectangle(width: Double, depth: Double) -> [Coordinate2D] {
        let halfWidth = width / 2, halfDepth = depth / 2
        return close([(-halfWidth, -halfDepth), (halfWidth, -halfDepth),
                      (halfWidth, halfDepth), (-halfWidth, halfDepth)])
    }

    /// A regular polygon of `sides` enclosing `area`.
    ///
    /// The circumradius is solved from the area rather than assumed, so a
    /// circular drum and a rectangular slab of the same stated floor area come
    /// out genuinely the same size — otherwise the shape choice would silently
    /// change the building's mass distribution.
    private static func regularPolygon(sides: Int, area: Double) -> [Coordinate2D] {
        let n = Double(max(sides, 3))
        let radius = (2 * area / (n * sin(2 * .pi / n))).squareRoot()
        return close((0..<Int(n)).map { index in
            let angle = 2 * .pi * Double(index) / n - .pi / 2
            return (radius * cos(angle), radius * sin(angle))
        })
    }

    private static func close(_ points: [(Double, Double)]) -> [Coordinate2D] {
        var ring = points.map { Coordinate2D(x: $0.0, y: $0.1) }
        if let first = ring.first { ring.append(first) }
        return ring
    }
}
