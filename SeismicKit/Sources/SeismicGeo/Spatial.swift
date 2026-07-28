import Foundation
import SeismicCore

// Supporting spatial infrastructure: geohash indexing, marker clustering,
// polygon geometry and point-in-polygon tests. None of these count toward the
// fifty, but the map and the 3D simulator are unusable without them.

// MARK: - Geohash

/// Geohash encoding.
///
/// The map has to answer "what tags are near here?" thousands of times as the
/// user pans, and doing that with a distance test against every tag is quadratic
/// and immediately too slow. A geohash turns a position into a string whose
/// prefix length corresponds to a bounding box, so nearby things share a prefix
/// and the query becomes a dictionary lookup.
///
/// It also does double duty for privacy: truncating a geohash *is* the
/// approximate-location feature. Six characters is about a 600 m box — enough to
/// say "this block", not enough to say "this house".
public enum Geohash {

    private static let base32 = Array("0123456789bcdefghjkmnpqrstuvwxyz")

    /// Approximate box dimensions for each precision, in metres.
    public static func approximateSize(precision: Int) -> (width: Double, height: Double) {
        switch Swift.min(Swift.max(precision, 1), 12) {
        case 1: (5_000_000, 5_000_000)
        case 2: (1_250_000, 625_000)
        case 3: (156_000, 156_000)
        case 4: (39_100, 19_500)
        case 5: (4_890, 4_890)
        case 6: (1_220, 610)
        case 7: (153, 153)
        case 8: (38, 19)
        case 9: (4.8, 4.8)
        default: (1.2, 0.6)
        }
    }

    public static func encode(latitude: Double, longitude: Double, precision: Int = 9) -> String {
        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var hash = ""
        var bit = 0
        var index = 0
        var isEven = true

        let target = Swift.min(Swift.max(precision, 1), 12)
        while hash.count < target {
            if isEven {
                let mid = (lonRange.0 + lonRange.1) / 2
                if longitude >= mid { index = index * 2 + 1; lonRange.0 = mid }
                else { index *= 2; lonRange.1 = mid }
            } else {
                let mid = (latRange.0 + latRange.1) / 2
                if latitude >= mid { index = index * 2 + 1; latRange.0 = mid }
                else { index *= 2; latRange.1 = mid }
            }
            isEven.toggle()
            bit += 1
            if bit == 5 {
                hash.append(base32[index])
                bit = 0
                index = 0
            }
        }
        return hash
    }

    public static func encode(_ point: GeoPoint, precision: Int = 9) -> String {
        encode(latitude: point.latitude, longitude: point.longitude, precision: precision)
    }

    /// Decodes to the centre of the box, plus the box's half-extents so callers
    /// can draw the actual area of uncertainty rather than a misleadingly
    /// precise pin.
    public static func decode(_ hash: String)
        -> (centre: GeoPoint, latitudeError: Double, longitudeError: Double)?
    {
        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var isEven = true

        for character in hash.lowercased() {
            guard let index = base32.firstIndex(of: character) else { return nil }
            for mask in [16, 8, 4, 2, 1] {
                if isEven {
                    let mid = (lonRange.0 + lonRange.1) / 2
                    if index & mask != 0 { lonRange.0 = mid } else { lonRange.1 = mid }
                } else {
                    let mid = (latRange.0 + latRange.1) / 2
                    if index & mask != 0 { latRange.0 = mid } else { latRange.1 = mid }
                }
                isEven.toggle()
            }
        }

        return (GeoPoint(latitude: (latRange.0 + latRange.1) / 2,
                         longitude: (lonRange.0 + lonRange.1) / 2),
                (latRange.1 - latRange.0) / 2,
                (lonRange.1 - lonRange.0) / 2)
    }

    /// The eight surrounding cells plus the cell itself. A radius query has to
    /// include the neighbours, because a point just across a cell boundary is
    /// near in space but shares no prefix at all.
    public static func neighbours(of hash: String) -> [String] {
        guard let (centre, latError, lonError) = decode(hash), !hash.isEmpty else { return [hash] }
        let precision = hash.count
        var out: Set<String> = [hash]
        for dLat in [-1.0, 0, 1] {
            for dLon in [-1.0, 0, 1] {
                let lat = Swift.min(Swift.max(centre.latitude + dLat * latError * 2, -90), 90)
                var lon = centre.longitude + dLon * lonError * 2
                if lon > 180 { lon -= 360 }
                if lon < -180 { lon += 360 }
                out.insert(encode(latitude: lat, longitude: lon, precision: precision))
            }
        }
        return Array(out).sorted()
    }

    /// Precision whose cell is closest to the given radius — how a map region is
    /// turned into a set of prefixes to fetch.
    public static func precision(forRadiusMetres radius: Double) -> Int {
        for p in 1...12 {
            let size = approximateSize(precision: p)
            if Swift.min(size.width, size.height) < radius * 2 { return Swift.max(p - 1, 1) }
        }
        return 12
    }
}

/// A spatial index over anything with a position. Backed by geohash buckets, so
/// a radius query touches only the handful of cells that can possibly contain a
/// result.
public struct SpatialIndex<Item: Identifiable> {
    private var buckets: [String: [Item]] = [:]
    private var positions: [String: GeoPoint] = [:]
    public let precision: Int

    public init(precision: Int = 6) {
        self.precision = Swift.min(Swift.max(precision, 1), 12)
    }

    public private(set) var count: Int = 0

    public mutating func insert(_ item: Item, at point: GeoPoint) {
        let hash = Geohash.encode(point, precision: precision)
        buckets[hash, default: []].append(item)
        positions["\(item.id)"] = point
        count += 1
    }

    public mutating func removeAll() {
        buckets.removeAll(); positions.removeAll(); count = 0
    }

    /// Everything within a radius, exactly — the geohash narrows the candidates,
    /// then a true distance test rejects the corners of the cells.
    public func items(near centre: GeoPoint, radiusMetres: Double) -> [(item: Item, distance: Double)] {
        let queryPrecision = Swift.min(Geohash.precision(forRadiusMetres: radiusMetres), precision)
        let coarse = Geohash.encode(centre, precision: queryPrecision)
        let cells = Set(Geohash.neighbours(of: coarse))

        var out: [(Item, Double)] = []
        for (hash, items) in buckets {
            let prefix = String(hash.prefix(queryPrecision))
            guard cells.contains(prefix) else { continue }
            for item in items {
                guard let position = positions["\(item.id)"] else { continue }
                let distance = Geodesy.distance(centre, position)
                if distance <= radiusMetres { out.append((item, distance)) }
            }
        }
        return out.sorted { $0.1 < $1.1 }
    }

    public func allItems() -> [Item] { buckets.values.flatMap { $0 } }
}

// MARK: - Marker clustering

public struct MapCluster<Item>: Identifiable {
    public let id: String
    public var centre: GeoPoint
    public var items: [Item]
    public var count: Int { items.count }
    public var isSingle: Bool { items.count == 1 }

    public init(id: String, centre: GeoPoint, items: [Item]) {
        self.id = id; self.centre = centre; self.items = items
    }
}

public enum MarkerClustering {

    /// Grid-based clustering in screen space.
    ///
    /// Distance-based clustering re-partitions as the map moves, so markers
    /// visibly jump around while panning. Snapping to a grid whose cell size is
    /// tied to the zoom level makes clusters stable: pan the map and a cluster
    /// stays exactly where it was.
    public static func cluster<Item>(_ items: [(item: Item, point: GeoPoint)],
                                     cellSizeMetres: Double) -> [MapCluster<Item>] {
        guard !items.isEmpty else { return [] }
        guard cellSizeMetres > 0 else {
            return items.enumerated().map {
                MapCluster(id: "single-\($0.offset)", centre: $0.element.point,
                           items: [$0.element.item])
            }
        }

        let latStep = cellSizeMetres / Geodesy.metresPerDegreeLatitude
        var grid: [String: [(Item, GeoPoint)]] = [:]

        for (item, point) in items {
            // Longitude cells must widen towards the poles or clusters become
            // absurdly narrow slivers at high latitude.
            let metresPerLon = Swift.max(
                Geodesy.metresPerDegreeLongitude(atLatitude: point.latitude), 1)
            let lonStep = cellSizeMetres / metresPerLon
            let row = (point.latitude / latStep).rounded(.down)
            let column = (point.longitude / lonStep).rounded(.down)
            grid["\(Int(row)):\(Int(column))", default: []].append((item, point))
        }

        return grid.map { key, members in
            // Cluster centre is the mean of its members, so it sits where the
            // markers actually are rather than at an arbitrary cell centre.
            let latitude = members.reduce(0) { $0 + $1.1.latitude } / Double(members.count)
            let longitude = members.reduce(0) { $0 + $1.1.longitude } / Double(members.count)
            return MapCluster(id: key,
                              centre: GeoPoint(latitude: latitude, longitude: longitude),
                              items: members.map(\.0))
        }
        .sorted { $0.id < $1.id }
    }

    /// A sensible cell size for a given map span — roughly 60 points on screen.
    public static func cellSize(forVisibleSpanMetres span: Double, screenPoints: Double = 390) -> Double {
        guard screenPoints > 0 else { return span / 6 }
        return Swift.max(span / screenPoints * 60, 1)
    }
}

// MARK: - Polygon geometry

public enum Polygon {

    /// Shoelace formula. Signed, so the sign also reveals the winding order —
    /// which matters when extruding, because a reversed polygon extrudes
    /// inside-out and renders with its faces pointing the wrong way.
    public static func signedArea(_ points: [Coordinate2D]) -> Double {
        guard points.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    public static func area(_ points: [Coordinate2D]) -> Double { abs(signedArea(points)) }

    public static func isCounterClockwise(_ points: [Coordinate2D]) -> Bool {
        signedArea(points) > 0
    }

    public static func madeCounterClockwise(_ points: [Coordinate2D]) -> [Coordinate2D] {
        isCounterClockwise(points) ? points : points.reversed()
    }

    public static func centroid(_ points: [Coordinate2D]) -> Coordinate2D {
        guard points.count >= 3 else {
            guard !points.isEmpty else { return Coordinate2D(x: 0, y: 0) }
            let x = points.reduce(0) { $0 + $1.x } / Double(points.count)
            let y = points.reduce(0) { $0 + $1.y } / Double(points.count)
            return Coordinate2D(x: x, y: y)
        }
        let a = signedArea(points)
        guard abs(a) > 1e-12 else {
            let x = points.reduce(0) { $0 + $1.x } / Double(points.count)
            let y = points.reduce(0) { $0 + $1.y } / Double(points.count)
            return Coordinate2D(x: x, y: y)
        }
        var cx = 0.0, cy = 0.0
        for i in 0..<points.count {
            let p = points[i], q = points[(i + 1) % points.count]
            let cross = p.x * q.y - q.x * p.y
            cx += (p.x + q.x) * cross
            cy += (p.y + q.y) * cross
        }
        return Coordinate2D(x: cx / (6 * a), y: cy / (6 * a))
    }

    public static func perimeter(_ points: [Coordinate2D]) -> Double {
        guard points.count >= 2 else { return 0 }
        var total = 0.0
        for i in 0..<points.count {
            let a = points[i], b = points[(i + 1) % points.count]
            total += ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
        }
        return total
    }

    public static func boundingBox(_ points: [Coordinate2D])
        -> (min: Coordinate2D, max: Coordinate2D)
    {
        guard let first = points.first else {
            return (Coordinate2D(x: 0, y: 0), Coordinate2D(x: 0, y: 0))
        }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x)
            minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y)
        }
        return (Coordinate2D(x: minX, y: minY), Coordinate2D(x: maxX, y: maxY))
    }

    /// Ray-casting point-in-polygon test.
    ///
    /// Decides which building a tap belongs to, whether a node is inside a
    /// footprint, and which tags fall within a neighbourhood boundary. Counts
    /// how many edges a ray to infinity crosses: odd means inside.
    public static func contains(_ point: Coordinate2D, polygon: [Coordinate2D]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            // The `(a.y > point.y) != (b.y > point.y)` test handles the vertex
            // case consistently: an edge counts only if it straddles the ray,
            // using a half-open convention so a ray through a vertex is not
            // counted twice.
            if (a.y > point.y) != (b.y > point.y) {
                let t = (point.y - a.y) / (b.y - a.y)
                if point.x < a.x + t * (b.x - a.x) { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Converts a geographic ring into local metres about its own centroid,
    /// which is the coordinate space the 3D simulator builds in.
    public static func toLocalMetres(_ ring: [GeoPoint]) -> (points: [Coordinate2D], origin: GeoPoint) {
        guard !ring.isEmpty else { return ([], GeoPoint(latitude: 0, longitude: 0)) }
        let latitude = ring.reduce(0) { $0 + $1.latitude } / Double(ring.count)
        let longitude = ring.reduce(0) { $0 + $1.longitude } / Double(ring.count)
        let origin = GeoPoint(latitude: latitude, longitude: longitude)
        let metresPerLon = Geodesy.metresPerDegreeLongitude(atLatitude: latitude)

        let points = ring.map {
            Coordinate2D(x: ($0.longitude - longitude) * metresPerLon,
                         y: ($0.latitude - latitude) * Geodesy.metresPerDegreeLatitude)
        }
        return (points, origin)
    }

    /// Simplifies a footprint. OpenStreetMap outlines frequently carry a hundred
    /// vertices describing a rectangle with bay windows; the solver does not care
    /// and the renderer should not pay for them.
    public static func simplify(_ points: [Coordinate2D], tolerance: Double) -> [Coordinate2D] {
        guard points.count > 4, tolerance > 0 else { return points }
        let asPairs = points.map { (x: $0.x, y: $0.y) }
        let simplified = simplifyClosedRing(asPairs, tolerance: tolerance)
        return simplified.map { Coordinate2D(x: $0.x, y: $0.y) }
    }

    private static func simplifyClosedRing(_ points: [(x: Double, y: Double)],
                                           tolerance: Double) -> [(x: Double, y: Double)] {
        // Split the ring at its two most distant points and simplify each arc,
        // because Douglas-Peucker on a closed ring with coincident endpoints
        // degenerates.
        guard points.count > 4 else { return points }
        var farthest = (0, 1, 0.0)
        for i in 0..<points.count {
            let a = points[i]
            for j in (i + 1)..<points.count {
                let b = points[j]
                let d = (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
                if d > farthest.2 { farthest = (i, j, d) }
            }
        }
        let (i, j, _) = farthest
        let firstArc = Array(points[i...j])
        let secondArc = Array(points[j...]) + Array(points[...i])

        let a = simplifyOpen(firstArc, tolerance: tolerance)
        let b = simplifyOpen(secondArc, tolerance: tolerance)
        var out = a
        out.append(contentsOf: b.dropFirst().dropLast())
        return out.count >= 3 ? out : points
    }

    private static func simplifyOpen(_ points: [(x: Double, y: Double)],
                                     tolerance: Double) -> [(x: Double, y: Double)] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true; keep[points.count - 1] = true

        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var maxDistance = 0.0, index = first
            let ax = points[first].x, ay = points[first].y
            let dx = points[last].x - ax, dy = points[last].y - ay
            let lengthSquared = dx * dx + dy * dy

            for k in (first + 1)..<last {
                let px = points[k].x - ax, py = points[k].y - ay
                let distance = lengthSquared < 1e-18
                    ? (px * px + py * py).squareRoot()
                    : abs(px * dy - py * dx) / lengthSquared.squareRoot()
                if distance > maxDistance { maxDistance = distance; index = k }
            }
            if maxDistance > tolerance {
                keep[index] = true
                stack.append((first, index)); stack.append((index, last))
            }
        }
        return points.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }
}

// MARK: - Privacy offsetting

public enum LocationPrivacy {

    /// Offsets a position to the centre of its geohash cell.
    ///
    /// Deliberately deterministic rather than randomised. A random jitter
    /// re-rolled on every publish would let anyone who collects a few reports
    /// average them back to the true position — the exact opposite of the
    /// intent. Snapping to a fixed grid cell leaks the cell and nothing more,
    /// however many times it is published.
    public static func approximate(_ point: GeoPoint, precision: Int = 6) -> GeoPoint {
        let hash = Geohash.encode(point, precision: precision)
        return Geohash.decode(hash)?.centre ?? point
    }

    public static func apply(_ level: BuildingModel.PrivacyLevel, to point: GeoPoint) -> GeoPoint? {
        switch level {
        case .privateOnly: nil
        case .household: point
        case .approximate: approximate(point, precision: 6)
        case .exact: point
        }
    }

    /// Human-readable description of how much precision is being given away.
    public static func description(for level: BuildingModel.PrivacyLevel) -> String {
        switch level {
        case .privateOnly:
            return "Not shared."
        case .household:
            return "Exact position, visible only to your household."
        case .approximate:
            let size = Geohash.approximateSize(precision: 6)
            return "Snapped to a \(Int(size.width)) × \(Int(size.height)) m grid cell — "
                + "about a city block. Publishing repeatedly does not narrow it down."
        case .exact:
            return "Exact position, visible to everyone."
        }
    }
}
