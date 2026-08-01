import Foundation
import SeismicCore

/// Which parts of a building's plan are curved, and which are corners.
///
/// Every outline in this app is a list of points, because that is how
/// OpenStreetMap stores a building and how the plan generators produce one. A
/// curved wall is therefore not stored as a curve — it arrives as a run of
/// twenty short straight segments, each turning a few degrees from the last.
/// Drawn literally, a circular tower comes out as a visibly faceted drum and a
/// curved facade comes out as a staircase, which is what makes an imported
/// building fail to look like the building.
///
/// The fix is not to add more points. It is to work out which points were meant
/// to be a curve and draw them as one. The distinction is recoverable from the
/// geometry itself: a corner is a single large turn between two long edges, and
/// a curve is a run of small turns, all in the same direction, between short
/// ones. Nothing else in a building plan looks like that.
///
/// This matters beyond appearance. The extruded plan is what the section
/// properties are computed from, and a faceted approximation of a circle has a
/// slightly smaller area and a slightly different second moment than the circle
/// it stands for. The error is small; the point is that it is avoidable.
public enum OutlineCurvature {

    /// A run of consecutive vertices that were meant to be a single curve.
    ///
    /// Indices are into the ring and may wrap past the end, since a curve does
    /// not care where the list happens to have been cut — a circular building
    /// mapped in OSM starts at an arbitrary node, and refusing to look across
    /// that seam would leave one flat facet in every circle.
    public struct Arc: Sendable, Equatable {
        /// Index of the first vertex on the curve.
        public var start: Int
        /// How many vertices the curve spans, counting from `start`.
        public var count: Int
        /// Total turn across the run, radians. Signed, so the direction of the
        /// bend is preserved.
        public var sweep: Double

        public init(start: Int, count: Int, sweep: Double) {
            self.start = start
            self.count = count
            self.sweep = sweep
        }

        /// The ring indices this arc covers, wrapping if it crosses the seam.
        public func indices(ringCount n: Int) -> [Int] {
            guard n > 0 else { return [] }
            return (0..<count).map { (start + $0) % n }
        }
    }

    // MARK: Tuning

    /// Below this, a turn is measurement noise in a wall that is meant to be
    /// straight — OSM nodes are placed by hand off aerial imagery and a
    /// nominally straight facade wanders by a fraction of a degree.
    private static let minimumTurn = 0.6 * .pi / 180
    /// Above this, a turn is a corner.
    ///
    /// Set just under 30° so that a regular twelve-sided plan — which turns
    /// exactly 30° at each vertex — stays a polygon, and so does an octagon at
    /// 45°. Those are shapes an architect chose, and rounding them off would be
    /// as wrong as leaving a circle faceted. Anything tessellated more finely
    /// than twelve sides was standing in for a curve.
    private static let maximumTurn = 28.0 * .pi / 180
    /// A curve has to be at least this many vertices. Two is a chamfered
    /// corner, which is a corner.
    private static let minimumRun = 3

    // MARK: Detection

    /// The arcs in a closed ring.
    ///
    /// The ring must not repeat its first point at the end; `normalised`
    /// below does that if you are unsure.
    public static func arcs(in ring: [Coordinate2D]) -> [Arc] {
        let n = ring.count
        guard n >= minimumRun + 2 else { return [] }

        let turns = turnAngles(ring)

        // Which vertices could be part of a curve at all.
        let bendy = turns.map { abs($0) > minimumTurn && abs($0) < maximumTurn }
        guard bendy.contains(true) else { return [] }

        // Start scanning from a vertex that is *not* part of a curve, so no run
        // is split across the start of the array. If every vertex is bendy the
        // whole ring is one closed curve — a circle — and that is handled
        // directly rather than by scanning.
        guard let anchor = bendy.firstIndex(of: false) else {
            return [Arc(start: 0, count: n, sweep: turns.reduce(0, +))]
        }

        var found: [Arc] = []
        var runStart: Int?
        var runSign = 0.0
        var runSweep = 0.0

        func closeRun(endingBefore offset: Int) {
            guard let start = runStart else { return }
            let count = offset - start
            if count >= minimumRun {
                found.append(Arc(start: (anchor + start) % n, count: count, sweep: runSweep))
            }
            runStart = nil
            runSweep = 0
            runSign = 0
        }

        for offset in 0..<n {
            let index = (anchor + offset) % n
            let turn = turns[index]
            let sign = turn > 0 ? 1.0 : -1.0

            // A curve bends one way. A reversal ends the run and starts a new
            // one, which is what keeps an S-bend from being read as a single
            // arc that cuts straight through the middle of it.
            guard bendy[index], runStart == nil || sign == runSign else {
                closeRun(endingBefore: offset)
                if bendy[index] {
                    runStart = offset
                    runSign = sign
                    runSweep = turn
                }
                continue
            }

            if runStart == nil {
                runStart = offset
                runSign = sign
                runSweep = turn
            } else {
                runSweep += turn
            }
        }
        closeRun(endingBefore: n)

        return found
    }

    /// True for each vertex that lies on a curve rather than at a corner.
    public static func curvedVertices(in ring: [Coordinate2D]) -> [Bool] {
        var flags = [Bool](repeating: false, count: ring.count)
        for arc in arcs(in: ring) {
            for index in arc.indices(ringCount: ring.count) { flags[index] = true }
        }
        return flags
    }

    // MARK: Measures

    /// Polsby–Popper compactness: `4πA / P²`. Exactly 1 for a circle, lower for
    /// anything else, and the standard cheap test for "is this round".
    ///
    /// Useful as a whole-plan check where the per-vertex test is not: a plan
    /// traced coarsely as an octagon has no runs long enough to register as a
    /// curve, but its compactness still says plainly that it is a drum.
    public static func circularity(_ ring: [Coordinate2D]) -> Double {
        let ring = normalised(ring)
        guard ring.count >= 3 else { return 0 }
        var area = 0.0
        var perimeter = 0.0
        for index in ring.indices {
            let a = ring[index], b = ring[(index + 1) % ring.count]
            area += a.x * b.y - b.x * a.y
            perimeter += ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
        }
        guard perimeter > 0 else { return 0 }
        return 4 * .pi * (abs(area) / 2) / (perimeter * perimeter)
    }

    /// Whether the plan is round enough that treating it as a drum is fair.
    ///
    /// The threshold sits above a regular octagon (0.948) is *not* where this
    /// is set — an octagonal plan is a real and different thing, and calling it
    /// a circle would be wrong. 0.96 admits a 12-sided tessellation and above.
    public static func isEssentiallyCircular(_ ring: [Coordinate2D]) -> Bool {
        circularity(ring) > 0.96
    }

    // MARK: Helpers

    /// Drops a repeated closing point and any duplicate consecutive vertices.
    ///
    /// Both are common in real data and both break the turn calculation, which
    /// divides by edge length: a zero-length edge has no direction, so a single
    /// duplicated node would otherwise produce a NaN that propagates through
    /// every subsequent test.
    public static func normalised(_ ring: [Coordinate2D]) -> [Coordinate2D] {
        var out: [Coordinate2D] = []
        out.reserveCapacity(ring.count)
        for point in ring {
            if let last = out.last, abs(last.x - point.x) < 1e-7, abs(last.y - point.y) < 1e-7 {
                continue
            }
            out.append(point)
        }
        if let first = out.first, let last = out.last, out.count > 1,
           abs(first.x - last.x) < 1e-7, abs(first.y - last.y) < 1e-7 {
            out.removeLast()
        }
        return out
    }

    /// Signed turn at each vertex, radians: the angle from the incoming edge to
    /// the outgoing one, positive for a left turn.
    static func turnAngles(_ ring: [Coordinate2D]) -> [Double] {
        let n = ring.count
        guard n >= 3 else { return [Double](repeating: 0, count: n) }
        return (0..<n).map { index in
            let previous = ring[(index + n - 1) % n]
            let current = ring[index]
            let next = ring[(index + 1) % n]

            let inX = current.x - previous.x, inY = current.y - previous.y
            let outX = next.x - current.x, outY = next.y - current.y
            let inLength = (inX * inX + inY * inY).squareRoot()
            let outLength = (outX * outX + outY * outY).squareRoot()
            guard inLength > 1e-9, outLength > 1e-9 else { return 0 }

            // atan2 of the cross and dot products, which is the signed angle
            // between the two edges and is stable at every angle — unlike
            // acos(dot), which loses all precision near zero and is exactly
            // where a gently curving wall lives.
            let cross = inX * outY - inY * outX
            let dot = inX * outX + inY * outY
            return atan2(cross, dot)
        }
    }
}

// MARK: - Smoothing

public extension OutlineCurvature {

    /// One piece of a plan as it should be drawn.
    enum Segment: Sendable, Equatable {
        /// A straight run to a point.
        case line(to: Coordinate2D)
        /// A cubic Bézier to a point, with its two control points. Curved runs
        /// are emitted as these so a round wall is genuinely round rather than
        /// finely faceted.
        case curve(to: Coordinate2D, control1: Coordinate2D, control2: Coordinate2D)
    }

    /// The ring as a drawable path: corners kept sharp, curves made smooth.
    ///
    /// The curve fitting is Catmull–Rom converted to cubic Bézier, which passes
    /// exactly through every original point. That property is the reason for
    /// choosing it over a smoothing spline: the vertices are survey data, and a
    /// curve that merely passes *near* them would move the building's walls to
    /// make them prettier.
    ///
    /// Returns the starting point and the segments that follow it, closing back
    /// to the start.
    static func path(for ring: [Coordinate2D]) -> (start: Coordinate2D, segments: [Segment])? {
        let ring = normalised(ring)
        let n = ring.count
        guard n >= 3, let first = ring.first else { return nil }

        let curved = curvedVertices(in: ring)
        var segments: [Segment] = []
        segments.reserveCapacity(n)

        for index in 0..<n {
            let p1 = ring[index]
            let p2 = ring[(index + 1) % n]

            // The edge from p1 to p2 is drawn as a curve only when both of its
            // ends are on a curve. An edge with one end at a corner is the
            // straight run leading into that corner, and rounding it would eat
            // the corner off.
            guard curved[index], curved[(index + 1) % n] else {
                segments.append(.line(to: p2))
                continue
            }

            let p0 = ring[(index + n - 1) % n]
            let p3 = ring[(index + 2) % n]
            segments.append(.curve(
                to: p2,
                control1: Coordinate2D(x: p1.x + (p2.x - p0.x) / 6,
                                       y: p1.y + (p2.y - p0.y) / 6),
                control2: Coordinate2D(x: p2.x - (p3.x - p1.x) / 6,
                                       y: p2.y - (p3.y - p1.y) / 6)))
        }
        return (first, segments)
    }
}
