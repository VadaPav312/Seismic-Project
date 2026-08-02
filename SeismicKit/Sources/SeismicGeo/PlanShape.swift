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
    /// An ellipse — the plan of a great many towers that are described as
    /// "round" and are not, and of every lens-shaped or lozenge block.
    case elliptical
    /// A rectangle with one long side bowed out into an arc: the curved slab.
    case curvedSlab
    case octagonal
    case triangular
    /// A square whose corners are rounded off rather than cut square.
    ///
    /// The plan of most towers built since about 1990, and it is not a
    /// stylistic detail: a sharp corner sheds vortices at a single frequency
    /// and drives across-wind oscillation, so corners get rounded or chamfered
    /// specifically to break that up. Drawing one of these as a sharp square is
    /// wrong about the building's silhouette and about why it has the shape it
    /// has.
    case roundedSquare
    /// A triangle with rounded corners — a lattice tower's base, and a great
    /// many mid-century towers on triangular sites.
    case roundedTriangular
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
        case .elliptical: "Elliptical"
        case .curvedSlab: "Curved slab"
        case .octagonal: "Octagonal"
        case .triangular: "Triangular"
        case .setbackTower: "Setback tower"
        case .roundedSquare: "Rounded square"
        case .roundedTriangular: "Rounded triangle"
        }
    }

    /// Whether this plan has re-entrant corners, which is what the codes
    /// actually care about.
    public var isIrregular: Bool {
        switch self {
        case .lShaped, .tShaped, .uShaped, .cruciform, .triangular,
             .roundedTriangular: true
        case .rectangular, .square, .circular, .elliptical, .curvedSlab,
             .octagonal, .setbackTower, .roundedSquare: false
        }
    }

    /// Whether the plan is bounded by curves rather than straight walls.
    ///
    /// Used to decide how finely to tessellate it: a curve needs enough points
    /// for the smoothing to have something to fit, and a rectangle needs four.
    public var isCurved: Bool {
        switch self {
        case .circular, .elliptical, .curvedSlab, .roundedSquare, .roundedTriangular: true
        default: false
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
            return Self.regularPolygon(sides: 36, area: area)

        case .elliptical:
            // area = π·a·b with a = ratio·b, so b follows directly. Solving it
            // rather than scaling a circle keeps the stated floor area exact,
            // which matters because the floor area is the building's mass.
            let semiMinor = (area / (.pi * ratio)).squareRoot()
            return Self.ellipse(semiMajor: semiMinor * ratio, semiMinor: semiMinor, points: 40)

        case .curvedSlab:
            return Self.curvedSlab(area: area, ratio: ratio)

        case .octagonal:
            return Self.regularPolygon(sides: 8, area: area)

        case .triangular:
            return Self.regularPolygon(sides: 3, area: area)

        case .roundedSquare:
            return Self.rounded(Self.rectangle(width: 1, depth: 1),
                                radiusFraction: 0.26, area: area)

        case .roundedTriangular:
            // A larger fraction than the square, because a triangle's corners
            // are sixty degrees and a modest cut takes very little off them —
            // the base of a lattice tower is visibly closer to a rounded blob
            // than to a triangle with the tips filed down.
            return Self.rounded(Self.regularPolygon(sides: 3, area: 1),
                                radiusFraction: 0.34, area: area)

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
            // Before `circular`, because "elliptical" and "oval" are the words
            // people reach for when a tower is round but not a circle, and a
            // description containing both should land on the more specific one.
            (["elliptic", "oval", "lenticular", "lozenge", "lens-shaped"], .elliptical),
            (["curved slab", "curved facade", "curved façade", "crescent", "bowed",
              "arc-shaped", "banana"], .curvedSlab),
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

    /// An ellipse, sampled at `points` vertices.
    ///
    /// Sampled uniformly in the parameter rather than in arc length, which puts
    /// the points closer together at the ends where the curvature is highest —
    /// exactly where a curve fit needs them.
    private static func ellipse(semiMajor: Double, semiMinor: Double,
                                points: Int) -> [Coordinate2D] {
        let n = max(points, 12)
        return close((0..<n).map { index in
            let angle = 2 * .pi * Double(index) / Double(n)
            return (semiMajor * cos(angle), semiMinor * sin(angle))
        })
    }

    /// A slab with one long face bowed out into a shallow arc.
    ///
    /// The shape of a great many apartment blocks and hotels, and one that has
    /// a real structural consequence rather than a stylistic one: the bow moves
    /// the plan's centroid away from the straight face, so the centre of mass
    /// and the centre of the bracing no longer coincide and the building
    /// twists as it sways.
    private static func curvedSlab(area: Double, ratio: Double) -> [Coordinate2D] {
        // Start from the rectangle of the requested proportions, then bow one
        // side out and shrink the whole thing back to the stated area, so
        // choosing a curved slab does not silently add floor area.
        let depth = (area / ratio).squareRoot()
        let width = depth * ratio
        let halfWidth = width / 2
        let bow = depth * 0.55

        var ring: [(Double, Double)] = [(-halfWidth, -depth / 2), (halfWidth, -depth / 2)]
        // The arc, from the right-hand end back to the left.
        let steps = 28
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let x = halfWidth - width * t
            // A parabola rather than a circular arc: it meets the straight ends
            // without a kink, which is what a bowed facade actually does.
            ring.append((x, depth / 2 + bow * (1 - 4 * (t - 0.5) * (t - 0.5))))
        }

        let raw = close(ring)
        // Rescale to the requested area.
        let enclosed = shoelaceArea(raw)
        guard enclosed > 1e-6 else { return rectangle(width: width, depth: depth) }
        let scale = (area / enclosed).squareRoot()
        return raw.map { Coordinate2D(x: $0.x * scale, y: $0.y * scale) }
    }

    /// Rounds every corner of a closed ring and rescales it to `area`.
    ///
    /// Each corner is replaced by a quadratic Bézier that leaves along one edge
    /// and arrives along the other, with the original vertex as its control
    /// point — so the curve is tangent to both walls and meets them without a
    /// kink, which a circular fillet only manages if its radius is computed per
    /// corner from the angle. The area is measured *after* rounding and the
    /// whole ring scaled to hit the target, because rounding always removes
    /// area and a plan that quietly lost eight per cent of its floor space
    /// would quietly lose the same fraction of the building's mass.
    ///
    /// - Parameter radiusFraction: how far along the shorter of the two edges
    ///   the curve starts, as a fraction of that edge. Clamped below a half,
    ///   above which adjacent corners would overlap.
    private static func rounded(_ ring: [Coordinate2D], radiusFraction: Double,
                                area: Double, segments: Int = 7) -> [Coordinate2D] {
        // The rectangle/polygon helpers return a closed ring; the duplicated
        // last point would be rounded as if it were a corner of its own.
        var points = ring
        if points.count > 1, let first = points.first, let last = points.last,
           abs(first.x - last.x) < 1e-9, abs(first.y - last.y) < 1e-9 {
            points.removeLast()
        }
        guard points.count >= 3 else { return ring }

        let fraction = min(max(radiusFraction, 0.01), 0.49)
        var out: [(Double, Double)] = []

        for index in points.indices {
            let previous = points[(index + points.count - 1) % points.count]
            let vertex = points[index]
            let next = points[(index + 1) % points.count]

            let inLength = hypot(vertex.x - previous.x, vertex.y - previous.y)
            let outLength = hypot(next.x - vertex.x, next.y - vertex.y)
            let cut = fraction * min(inLength, outLength)
            guard cut > 1e-9, inLength > 1e-9, outLength > 1e-9 else {
                out.append((vertex.x, vertex.y))
                continue
            }

            let start = (x: vertex.x + (previous.x - vertex.x) / inLength * cut,
                         y: vertex.y + (previous.y - vertex.y) / inLength * cut)
            let end = (x: vertex.x + (next.x - vertex.x) / outLength * cut,
                       y: vertex.y + (next.y - vertex.y) / outLength * cut)

            for step in 0...segments {
                let t = Double(step) / Double(segments)
                let inverse = 1 - t
                let x = inverse * inverse * start.x + 2 * inverse * t * vertex.x + t * t * end.x
                let y = inverse * inverse * start.y + 2 * inverse * t * vertex.y + t * t * end.y
                out.append((x, y))
            }
        }

        let raw = close(out)
        let enclosed = shoelaceArea(raw)
        guard enclosed > 1e-9 else { return ring }
        let scale = (area / enclosed).squareRoot()
        return raw.map { Coordinate2D(x: $0.x * scale, y: $0.y * scale) }
    }

    private static func shoelaceArea(_ ring: [Coordinate2D]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var sum = 0.0
        for index in ring.indices {
            let a = ring[index], b = ring[(index + 1) % ring.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    private static func close(_ points: [(Double, Double)]) -> [Coordinate2D] {
        var ring = points.map { Coordinate2D(x: $0.0, y: $0.1) }
        if let first = ring.first { ring.append(first) }
        return ring
    }
}
