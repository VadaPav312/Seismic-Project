import Foundation
import SeismicCore
import SeismicData
import SeismicGeo

/// One thing the user might have meant when they typed a building's name.
public struct BuildingCandidate: Identifiable, Sendable, Equatable, Codable {
    public var id: UUID
    public var name: String
    public var subtitle: String
    public var latitude: Double?
    public var longitude: Double?
    /// Wikidata Q-number, OSM way/relation id, or a URL — whatever the provider
    /// gave us that can be used to fetch the details.
    public var externalID: String?
    public var provider: String
    public var confidence: Double
    public var snippet: String

    public init(id: UUID = UUID(), name: String, subtitle: String = "",
                latitude: Double? = nil, longitude: Double? = nil,
                externalID: String? = nil, provider: String,
                confidence: Double = 0.5, snippet: String = "") {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
        self.externalID = externalID
        self.provider = provider
        self.confidence = confidence
        self.snippet = snippet
    }
}

/// A structural fact retrieved about a building, with where it came from.
///
/// Nothing is silently promoted into the model. Each fact keeps its provenance
/// all the way to the import sheet, where the user sees what is confirmed, what
/// is inferred and what was guessed from the geometry — and can change any of
/// them before pressing Add.
public struct RetrievedFact: Sendable, Equatable, Codable {
    public var field: String
    public var value: String
    public var provenance: FactProvenance

    public init(field: String, value: String, provenance: FactProvenance) {
        self.field = field
        self.value = value
        self.provenance = provenance
    }
}

public struct BuildingFactSet: Sendable, Equatable, Codable {
    public var facts: [String: RetrievedFact] = [:]

    public init(facts: [String: RetrievedFact] = [:]) { self.facts = facts }

    public subscript(field: String) -> RetrievedFact? { facts[field] }

    public var isEmpty: Bool { facts.isEmpty }

    /// Merges another source's facts in.
    ///
    /// Two independent sources agreeing is the strongest signal available
    /// without an engineer, so agreement raises confidence and marks the fact
    /// confirmed. Disagreement keeps the higher-confidence value and records
    /// the conflict in the detail rather than quietly averaging — averaging two
    /// building heights that disagree produces a number neither source claims.
    public mutating func merge(_ other: BuildingFactSet) {
        for (field, incoming) in other.facts {
            guard let existing = facts[field] else {
                facts[field] = incoming
                continue
            }
            if Self.agree(existing.value, incoming.value) {
                var merged = existing.provenance.confidence >= incoming.provenance.confidence
                    ? existing : incoming
                merged.provenance.confidence = min(0.98,
                    max(existing.provenance.confidence, incoming.provenance.confidence) + 0.15)
                merged.provenance.detail = "Agreed by \(existing.provenance.source.label) "
                                         + "and \(incoming.provenance.source.label)"
                facts[field] = merged
            } else if incoming.provenance.confidence > existing.provenance.confidence {
                var kept = incoming
                kept.provenance.detail = "Disagrees with \(existing.provenance.source.label), "
                                       + "which said \(existing.value)"
                kept.provenance.confidence = max(0.3, incoming.provenance.confidence - 0.15)
                facts[field] = kept
            } else {
                var kept = existing
                kept.provenance.detail = "Disagrees with \(incoming.provenance.source.label), "
                                       + "which said \(incoming.value)"
                kept.provenance.confidence = max(0.3, existing.provenance.confidence - 0.15)
                facts[field] = kept
            }
        }
    }

    /// Numeric fields count as agreeing within 10%; text fields case-insensitively.
    static func agree(_ a: String, _ b: String) -> Bool {
        if let x = Double(a), let y = Double(b) {
            let scale = Swift.max(abs(x), abs(y), 1e-9)
            return abs(x - y) / scale < 0.10
        }
        return a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

// MARK: - Provider clients

/// Wikidata. Needs no key, which is worth saying out loud: the highest-quality
/// structured source for named buildings is also the free one, so the import
/// flow's best path is available to every user on first launch.
struct WikidataClient: Sendable {
    let endpoint: URL

    /// Wikidata's own search index, which is a different service from the
    /// SPARQL endpoint and answers in milliseconds.
    static let searchEndpoint = URL(string: "https://www.wikidata.org/w/api.php")!

    /// Details for a known set of entities.
    ///
    /// `VALUES` pins the query to a handful of specific items, so the engine
    /// looks up eight entities instead of scanning the graph.
    ///
    /// This replaces a query that could not work. The previous one matched on
    /// `rdfs:label` with a `CONTAINS` filter *before* narrowing by type, which
    /// asks Wikidata to lowercase and substring-search every label it holds —
    /// hundreds of millions of them — and only then check whether each result
    /// is a building. Measured against the live endpoint it returned nothing at
    /// all in sixty seconds. Searching first and resolving second takes about
    /// eight hundred milliseconds for the same answer.
    static func detailQuery(ids: [String]) -> String {
        // Q-numbers only. These are interpolated into a query, and anything
        // else reaching that string is an injection.
        let values = ids
            .filter { $0.first == "Q" && $0.dropFirst().allSatisfy(\.isNumber) }
            .map { "wd:\($0)" }
            .joined(separator: " ")

        return """
        SELECT ?item ?itemLabel ?height ?floors ?inception ?architectLabel ?coord ?adminLabel
               ?materialLabel WHERE {
          VALUES ?item { \(values) }
          OPTIONAL { ?item wdt:P2048 ?height . }
          OPTIONAL { ?item wdt:P1101 ?floors . }
          OPTIONAL { ?item wdt:P571 ?inception . }
          OPTIONAL { ?item wdt:P84 ?architect . }
          OPTIONAL { ?item wdt:P625 ?coord . }
          OPTIONAL { ?item wdt:P131 ?admin . }
          OPTIONAL { ?item wdt:P186 ?material . }
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
        }
        """
    }

    /// One search hit, before any details have been fetched.
    struct SearchHit: Decodable {
        let id: String
        let label: String?
        let description: String?
    }

    private struct SearchResponse: Decodable {
        let search: [SearchHit]
    }

    /// Finds candidate entities by name, using the indexed search API.
    func entities(matching name: String, client: ResilientClient,
                  limit: Int = 8) async throws -> [SearchHit] {
        var components = URLComponents(url: Self.searchEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "wbsearchentities"),
            URLQueryItem(name: "search", value: name),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "uselang", value: "en"),
            URLQueryItem(name: "type", value: "item"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "origin", value: "*"),
        ]
        guard let url = components?.url else {
            throw ServiceError.notConfigured("Wikidata search")
        }

        let request = HTTPRequest(
            url: url,
            headers: ["Accept": "application/json",
                      "User-Agent": "Seismic/1.0 (structural safety app)"],
            timeout: 10)
        return try await client.json(request, as: SearchResponse.self).search
    }

    /// Fetches the structural facts for a set of entity ids.
    func details(for ids: [String], client: ResilientClient) async throws -> SPARQLResponse {
        guard !ids.isEmpty else {
            return SPARQLResponse(results: .init(bindings: []))
        }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "query", value: Self.detailQuery(ids: ids)),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components?.url else {
            throw ServiceError.notConfigured("Wikidata endpoint")
        }

        let request = HTTPRequest(
            url: url,
            headers: ["Accept": "application/sparql-results+json",
                      "User-Agent": "Seismic/1.0 (structural safety app)"],
            // Well under what the endpoint itself allows. A query that has not
            // answered in fifteen seconds is not going to, and the import flow
            // has a bundled library to fall back on.
            timeout: 15)
        return try await client.json(request, as: SPARQLResponse.self)
    }

    func search(_ name: String, client: ResilientClient) async throws -> [BuildingCandidate] {
        let hits = try await entities(matching: name, client: client)
        guard !hits.isEmpty else { return [] }

        // The description alone is enough to show a candidate list, so results
        // appear immediately; the SPARQL round trip only enriches them.
        let details = (try? await details(for: hits.map(\.id), client: client))
            ?? SPARQLResponse(results: .init(bindings: []))

        var byID: [String: [String: SPARQLResponse.Binding]] = [:]
        for row in details.results.bindings {
            guard let uri = row["item"]?.value,
                  let id = uri.split(separator: "/").last.map(String.init) else { continue }
            byID[id] = row
        }

        return hits.compactMap { hit -> BuildingCandidate? in
            let row = byID[hit.id]
            let coordinate = row?["coord"].flatMap { Self.parsePoint($0.value) }
            let name = hit.label ?? row?["itemLabel"]?.value
            guard let name else { return nil }

            let subtitle = [row?["adminLabel"]?.value ?? hit.description,
                            row?["inception"].map { String($0.value.prefix(4)) }]
                .compactMap { $0 }.joined(separator: " · ")

            return BuildingCandidate(
                name: name,
                subtitle: subtitle,
                latitude: coordinate?.latitude,
                longitude: coordinate?.longitude,
                externalID: hit.id,
                provider: "Wikidata",
                // A hit with structural facts behind it is worth more than a
                // name that merely matched.
                confidence: row?["height"] != nil ? 0.88 : 0.62,
                snippet: [row?["architectLabel"].map { "Architect: \($0.value)" },
                          hit.description]
                    .compactMap { $0 }.joined(separator: ". "))
        }
    }

    /// Facts for a building, by name or by entity id.
    ///
    /// An id is preferred: the candidate the user actually chose already
    /// carries one, and resolving it directly avoids searching for a name that
    /// may match several buildings and picking the wrong one.
    func facts(_ name: String, entityID: String? = nil,
               client: ResilientClient) async throws -> BuildingFactSet {
        let ids: [String]
        if let entityID, entityID.first == "Q" {
            ids = [entityID]
        } else {
            ids = try await entities(matching: name, client: client, limit: 3).map(\.id)
        }

        let response = try await details(for: ids, client: client)
        guard let row = response.results.bindings.first else { throw ServiceError.emptyResult }

        var set = BuildingFactSet()
        let provenance = FactProvenance(source: .wikidata, confidence: 0.85,
                                        detail: "Wikidata structured data", retrievedAt: Date())
        if let height = row["height"]?.value {
            set.facts["height"] = RetrievedFact(field: "height", value: height, provenance: provenance)
        }
        if let floors = row["floors"]?.value {
            set.facts["storeyCount"] = RetrievedFact(field: "storeyCount", value: floors,
                                                     provenance: provenance)
        }
        if let inception = row["inception"]?.value {
            set.facts["yearBuilt"] = RetrievedFact(field: "yearBuilt",
                                                   value: String(inception.prefix(4)),
                                                   provenance: provenance)
        }
        if let architect = row["architectLabel"]?.value {
            set.facts["architect"] = RetrievedFact(field: "architect", value: architect,
                                                   provenance: provenance)
        }
        if let coord = row["coord"]?.value, let point = Self.parsePoint(coord) {
            set.facts["latitude"] = RetrievedFact(field: "latitude", value: "\(point.latitude)",
                                                  provenance: provenance)
            set.facts["longitude"] = RetrievedFact(field: "longitude", value: "\(point.longitude)",
                                                   provenance: provenance)
        }
        return set
    }

    /// Wikidata points arrive as `Point(longitude latitude)` — longitude first,
    /// which is the opposite of the order everything else in this app uses.
    static func parsePoint(_ text: String) -> (latitude: Double, longitude: Double)? {
        guard let open = text.firstIndex(of: "("), let close = text.firstIndex(of: ")") else {
            return nil
        }
        let inner = text[text.index(after: open)..<close]
        let parts = inner.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return (latitude: parts[1], longitude: parts[0])
    }
}

struct SPARQLResponse: Decodable {
    struct Results: Decodable {
        var bindings: [[String: Binding]]
        init(bindings: [[String: Binding]]) { self.bindings = bindings }
    }
    struct Binding: Decodable { var value: String }
    var results: Results

    init(results: Results) { self.results = results }
}

/// Overpass — OpenStreetMap. Also keyless, and the only source that gives a
/// real footprint polygon rather than a rectangle guessed from a floor area.
struct OverpassClient: Sendable {
    let endpoint: URL

    static func query(latitude: Double, longitude: Double, radius: Int = 60) -> String {
        // `building:part` comes back alongside the outlines. Those parts are
        // how OpenStreetMap records that a building is a tower on a podium
        // rather than a prism — each carries its own height and the level it
        // starts at — and they are the only free source of a real massing
        // profile there is. Fetching them in the same round trip costs nothing
        // extra and is what turns an imported skyscraper from a box into its
        // actual shape.
        """
        [out:json][timeout:25];
        (
          way["building"](around:\(radius),\(latitude),\(longitude));
          relation["building"](around:\(radius),\(latitude),\(longitude));
          way["building:part"](around:\(radius),\(latitude),\(longitude));
          relation["building:part"](around:\(radius),\(latitude),\(longitude));
        );
        out tags geom;
        """
    }

    func facts(latitude: Double, longitude: Double, name: String = "",
               client: ResilientClient) async throws -> (BuildingFactSet, [Coordinate2D]) {
        let body = Self.query(latitude: latitude, longitude: longitude)
        let request = HTTPRequest(method: "POST", url: endpoint,
                                  headers: ["Content-Type": "text/plain",
                                            "User-Agent": "Seismic/1.0 (structural safety app)"],
                                  body: Data(body.utf8), timeout: 25)
        let response: OverpassResponse = try await client.json(request, as: OverpassResponse.self)

        // Everything within the search radius, projected once.
        let projected = response.elements.map { element in
            (element: element,
             ring: Self.localFootprint(element.outerGeometry,
                                       originLatitude: latitude, originLongitude: longitude))
        }

        let outlines = projected.filter { $0.element.tags?["building"] != nil }
        let parts = projected.filter {
            $0.element.tags?["building"] == nil && $0.element.tags?["building:part"] != nil
        }

        guard let chosen = Self.best(of: outlines, named: name) else {
            throw ServiceError.emptyResult
        }
        let element = chosen.element
        let footprint = chosen.ring

        var set = BuildingFactSet()
        let provenance = FactProvenance(source: .openStreetMap, confidence: 0.7,
                                        detail: "OpenStreetMap building tags", retrievedAt: Date())
        let tags = element.tags ?? [:]

        if let levels = tags["building:levels"] {
            set.facts["storeyCount"] = RetrievedFact(field: "storeyCount", value: levels,
                                                     provenance: provenance)
        }
        if let height = tags["height"] {
            let numeric = height.filter { $0.isNumber || $0 == "." }
            if !numeric.isEmpty {
                set.facts["height"] = RetrievedFact(field: "height", value: numeric,
                                                    provenance: provenance)
            }
        }
        if let name = tags["name"] {
            set.facts["name"] = RetrievedFact(field: "name", value: name, provenance: provenance)
        }
        if let material = tags["building:material"] {
            set.facts["material"] = RetrievedFact(field: "material", value: material,
                                                  provenance: provenance)
        }
        if let start = tags["start_date"] {
            set.facts["yearBuilt"] = RetrievedFact(field: "yearBuilt",
                                                   value: String(start.prefix(4)),
                                                   provenance: provenance)
        }
        if let street = tags["addr:street"] {
            let number = tags["addr:housenumber"].map { "\($0) " } ?? ""
            set.facts["address"] = RetrievedFact(field: "address", value: number + street,
                                                 provenance: provenance)
        }

        if !footprint.isEmpty {
            let area = Self.polygonArea(footprint)
            if area > 10 {
                set.facts["footprintArea"] = RetrievedFact(
                    field: "footprintArea", value: String(format: "%.0f", area),
                    provenance: FactProvenance(source: .openStreetMap, confidence: 0.8,
                                               detail: "Computed from the OSM footprint polygon",
                                               retrievedAt: Date()))
            }
        }

        // The massing, from the parts that sit inside the chosen outline.
        let mine = parts.filter { !$0.ring.isEmpty && Self.centroid($0.ring).map {
            Self.contains(footprint, $0)
        } ?? false }
        if let profile = Self.massing(fromParts: mine.map {
            (ring: $0.ring, levels: Self.levels(of: $0.element.tags ?? [:]))
        }, baseArea: Self.polygonArea(footprint)),
           let encoded = try? JSONEncoder().encode(profile),
           let json = String(data: encoded, encoding: .utf8) {
            set.facts["massing"] = RetrievedFact(
                field: "massing", value: json,
                provenance: FactProvenance(
                    source: .openStreetMap, confidence: 0.85,
                    detail: "Built from \(mine.count) mapped building parts, each with its own "
                        + "height — this is the building's real profile, not a guess at it",
                    retrievedAt: Date()))
        }

        return (set, footprint)
    }

    // MARK: Choosing the right building

    /// Which of the buildings near the point is *the* building.
    ///
    /// The query returns everything within sixty metres, which in a city centre
    /// is a dozen buildings. Taking the first — which is what this did — meant
    /// importing whichever one the server happened to list first, so a search
    /// for a named tower could come back with the outline of the shop next
    /// door. That single line was the largest single cause of an imported
    /// building not looking like the building.
    ///
    /// The tests are applied in order of how much they prove:
    ///
    /// 1. **The name matches.** Decisive when it happens. A building that says
    ///    it is the one you asked for is the one you asked for.
    /// 2. **It contains the point.** The coordinate came from Wikidata or a
    ///    geocoder and lands inside the right building far more often than not.
    /// 3. **It is the largest.** A last resort, and a fair one: the reason a
    ///    building has a Wikidata entry is usually that it is the big one.
    static func best(of candidates: [(element: OverpassResponse.Element, ring: [Coordinate2D])],
                     named name: String) -> (element: OverpassResponse.Element,
                                             ring: [Coordinate2D])? {
        let usable = candidates.filter { $0.ring.count >= 3 }
        guard !usable.isEmpty else { return candidates.first }

        let wanted = normalise(name)
        if !wanted.isEmpty {
            let named = usable.filter { candidate in
                let tags = candidate.element.tags ?? [:]
                // `name:en` as well as `name`, because the local-language name
                // is what OSM carries for most of the world and the search term
                // will not have been in it.
                return [tags["name"], tags["name:en"], tags["official_name"], tags["alt_name"]]
                    .compactMap { $0 }
                    .contains { matches(normalise($0), wanted) }
            }
            // Still the largest among them: a named complex often has its
            // entrance pavilion tagged with the same name as the tower.
            if let match = named.max(by: { polygonArea($0.ring) < polygonArea($1.ring) }) {
                return match
            }
        }

        // The origin is the projection's own centre, so the point being tested
        // for is (0, 0) by construction.
        let containing = usable.filter { contains($0.ring, Coordinate2D(x: 0, y: 0)) }
        if let inside = containing.max(by: { polygonArea($0.ring) < polygonArea($1.ring) }) {
            return inside
        }

        return usable.max(by: { polygonArea($0.ring) < polygonArea($1.ring) })
    }

    /// Case, accents, punctuation and the noise words that make two spellings
    /// of the same building look different.
    static func normalise(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(separator: " ")
            .filter { !["the", "of", "de", "la", "le", "building", "tower"].contains(String($0)) }
            .joined(separator: " ")
    }

    /// Whether two normalised names refer to the same thing.
    ///
    /// Containment either way rather than equality, because OSM's name is
    /// routinely longer than the search term ("Willis Tower" against "Willis
    /// Tower (Sears Tower)") and occasionally shorter.
    static func matches(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    /// Ray casting. True when the point is inside the ring.
    static func contains(_ ring: [Coordinate2D], _ point: Coordinate2D) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    static func centroid(_ ring: [Coordinate2D]) -> Coordinate2D? {
        guard ring.count >= 3 else { return nil }
        var area = 0.0, x = 0.0, y = 0.0
        for index in ring.indices {
            let a = ring[index], b = ring[(index + 1) % ring.count]
            let cross = a.x * b.y - b.x * a.y
            area += cross
            x += (a.x + b.x) * cross
            y += (a.y + b.y) * cross
        }
        guard abs(area) > 1e-9 else { return nil }
        return Coordinate2D(x: x / (3 * area), y: y / (3 * area))
    }

    // MARK: Massing from mapped parts

    /// The vertical extent of one part, metres above ground.
    ///
    /// `height` and `min_height` where they exist, falling back to storey
    /// counts at a typical floor-to-floor. A part with neither is not usable
    /// and returns nil rather than being assumed to span the whole building —
    /// which would flatten the very profile it was fetched to establish.
    static func levels(of tags: [String: String]) -> (bottom: Double, top: Double)? {
        func metres(_ key: String) -> Double? {
            guard let raw = tags[key] else { return nil }
            let numeric = raw.filter { $0.isNumber || $0 == "." }
            return numeric.isEmpty ? nil : Double(numeric)
        }
        func storeys(_ key: String) -> Double? {
            metres(key).map { $0 * 3.4 }
        }

        let top = metres("height") ?? storeys("building:levels")
        guard let top, top > 0.5 else { return nil }
        let bottom = metres("min_height") ?? storeys("building:min_level") ?? 0
        guard top > bottom else { return nil }
        return (bottom, top)
    }

    /// A massing profile from the parts a building has been mapped in.
    ///
    /// The plan area at any height is the total area of the parts that span it,
    /// and the profile is that area relative to the base, as a linear scale —
    /// so it is the square root, because a tower at half the plan width has a
    /// quarter of the floor area and therefore a quarter of the mass.
    ///
    /// Each boundary gets two stations a hair apart, so a setback comes out as
    /// the ledge it is rather than a chamfer. That distinction is structural:
    /// an abrupt change in plan is an abrupt change in stiffness, and demand
    /// concentrates exactly where it happens.
    static func massing(fromParts parts: [(ring: [Coordinate2D],
                                           levels: (bottom: Double, top: Double)?)],
                        baseArea: Double) -> Massing? {
        let usable = parts.compactMap { part -> (area: Double, bottom: Double, top: Double)? in
            guard let levels = part.levels else { return nil }
            let area = polygonArea(part.ring)
            guard area > 5 else { return nil }
            return (area, levels.bottom, levels.top)
        }
        // One part is just the building again, and says nothing a prism does
        // not already say.
        guard usable.count >= 2 else { return nil }

        let total = usable.map(\.top).max() ?? 0
        guard total > 3 else { return nil }

        func area(at height: Double) -> Double {
            usable.filter { $0.bottom <= height && height < $0.top }
                .reduce(0) { $0 + $1.area }
        }

        let ground = max(area(at: 0.01), baseArea * 0.2, 1)

        // Every level at which some part starts or stops, which is where the
        // plan can actually change.
        var boundaries = Set<Double>([0, total])
        for part in usable {
            boundaries.insert(part.bottom)
            boundaries.insert(part.top)
        }

        var stations: [Massing.Station] = []
        for boundary in boundaries.sorted() {
            let fraction = min(max(boundary / total, 0), 1)
            // Just below the boundary keeps the plan that was there; at it,
            // the new one.
            let below = (area(at: boundary - 0.05) / ground).squareRoot()
            let above = (area(at: boundary + 0.05) / ground).squareRoot()
            if fraction > 0 {
                stations.append(.init(heightFraction: max(fraction - 0.002, 0), scale: below))
            }
            if fraction < 1 {
                stations.append(.init(heightFraction: fraction, scale: above))
            }
        }
        guard stations.count >= 2 else { return nil }

        let profile = Massing(stations: stations)
        // A profile that says the building is a prism is not worth carrying;
        // the default already says that, and more cheaply.
        return profile.isUniform ? nil : profile
    }

    /// Projects the lat/lon ring onto a local metres plane centred on the
    /// building, which is what the extruder and the SceneKit model both want.
    static func localFootprint(_ points: [OverpassResponse.Point],
                               originLatitude: Double,
                               originLongitude: Double) -> [Coordinate2D] {
        guard points.count >= 3 else { return [] }
        let metresPerDegreeLatitude = 111_132.0
        let metresPerDegreeLongitude = 111_320.0 * cos(originLatitude * .pi / 180)
        var ring = points.map { point in
            Coordinate2D(x: (point.lon - originLongitude) * metresPerDegreeLongitude,
                         y: (point.lat - originLatitude) * metresPerDegreeLatitude)
        }
        // OSM closes its ways by repeating the first node; the extruder closes
        // the ring itself, so the duplicate would produce a zero-length edge.
        if let first = ring.first, let last = ring.last,
           abs(first.x - last.x) < 1e-6, abs(first.y - last.y) < 1e-6 {
            ring.removeLast()
        }
        return ring
    }

    static func polygonArea(_ ring: [Coordinate2D]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var sum = 0.0
        for index in ring.indices {
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }
}

struct OverpassResponse: Decodable {
    struct Point: Decodable { var lat: Double; var lon: Double }

    /// One way inside a relation.
    struct Member: Decodable {
        var type: String?
        var role: String?
        var geometry: [Point]?
    }

    struct Element: Decodable {
        var type: String?
        var tags: [String: String]?
        /// Present on ways. Relations carry their geometry on their members.
        var geometry: [Point]?
        var members: [Member]?

        /// The outline to use, whichever kind of element this is.
        ///
        /// Large and interesting buildings are mapped as multipolygon
        /// relations rather than as single ways — anything with a courtyard
        /// has to be, because a hole needs an inner ring. Reading only
        /// `geometry` returned nothing at all for those, so precisely the
        /// buildings somebody would go looking for were the ones that fell
        /// back to a generated rectangle.
        ///
        /// Inner rings are dropped rather than modelled: a courtyard is a hole
        /// in the floor plate, and the extruder takes a single ring. The outer
        /// boundary is still enormously closer to the truth than a box, and
        /// the enclosed area is corrected separately from the tags.
        var outerGeometry: [Point] {
            if let geometry, geometry.count >= 3 { return geometry }
            guard let members else { return [] }
            let outers = members.filter { ($0.role ?? "outer") == "outer" }
                .compactMap(\.geometry)
                .filter { $0.count >= 2 }
            guard !outers.isEmpty else { return [] }
            return OverpassResponse.stitch(outers)
        }
    }

    var elements: [Element]

    /// Joins a relation's outer ways into one ring.
    ///
    /// The ways arrive in no particular order and in either direction, which is
    /// how OSM stores them — the relation says which ways bound the building,
    /// not how to walk them. Each is appended to whichever end it meets,
    /// reversed if that is the end that matches. Anything that cannot be joined
    /// is left out rather than concatenated blindly, which would produce a ring
    /// that jumps across the building.
    static func stitch(_ ways: [[Point]]) -> [Point] {
        var remaining = ways
        guard var ring = remaining.popLast() else { return [] }

        func near(_ a: Point, _ b: Point) -> Bool {
            abs(a.lat - b.lat) < 1e-7 && abs(a.lon - b.lon) < 1e-7
        }

        var joinedSomething = true
        while joinedSomething, !remaining.isEmpty {
            joinedSomething = false
            for (index, way) in remaining.enumerated() {
                guard let first = way.first, let last = way.last,
                      let ringStart = ring.first, let ringEnd = ring.last else { continue }

                if near(ringEnd, first) { ring.append(contentsOf: way.dropFirst()) }
                else if near(ringEnd, last) { ring.append(contentsOf: way.reversed().dropFirst()) }
                else if near(ringStart, last) { ring.insert(contentsOf: way.dropLast(), at: 0) }
                else if near(ringStart, first) {
                    ring.insert(contentsOf: way.reversed().dropLast(), at: 0)
                } else { continue }

                remaining.remove(at: index)
                joinedSomething = true
                break
            }
        }
        return ring
    }
}

/// Serper — Google results as JSON. The broadest recall of the keyed providers,
/// used first when a key exists because a building people can name is usually
/// a building the open web has heard of.
struct SerperClient: Sendable {
    func search(_ query: String, apiKey: String,
                client: ResilientClient) async throws -> [BuildingCandidate] {
        struct Body: Encodable { var q: String; var num: Int }
        let request = try HTTPRequest.json(
            "POST", URL(string: "https://google.serper.dev/search")!,
            headers: ["X-API-KEY": apiKey],
            body: Body(q: query + " building height floors structure", num: 8))
        let response: SerperResponse = try await client.json(request, as: SerperResponse.self)
        return (response.organic ?? []).enumerated().map { index, item in
            BuildingCandidate(name: item.title,
                              subtitle: item.link,
                              externalID: item.link,
                              provider: "Serper",
                              confidence: max(0.35, 0.75 - Double(index) * 0.05),
                              snippet: item.snippet ?? "")
        }
    }
}

struct SerperResponse: Decodable {
    struct Organic: Decodable { var title: String; var link: String; var snippet: String? }
    var organic: [Organic]?
}

/// Tavily — search with the page content already extracted, which is the part
/// that matters here: the structural facts are in the prose, not the title.
struct TavilyClient: Sendable {
    func search(_ query: String, apiKey: String,
                client: ResilientClient) async throws -> [BuildingCandidate] {
        struct Body: Encodable {
            var api_key: String
            var query: String
            var max_results: Int
            var include_answer: Bool
            var search_depth: String
        }
        let request = try HTTPRequest.json(
            "POST", URL(string: "https://api.tavily.com/search")!,
            body: Body(api_key: apiKey,
                       query: query + " building structural system storeys height year built",
                       max_results: 8, include_answer: true, search_depth: "advanced"))
        let response: TavilyResponse = try await client.json(request, as: TavilyResponse.self)
        return (response.results ?? []).enumerated().map { index, item in
            BuildingCandidate(name: item.title,
                              subtitle: item.url,
                              externalID: item.url,
                              provider: "Tavily",
                              confidence: item.score ?? max(0.35, 0.7 - Double(index) * 0.05),
                              snippet: item.content ?? "")
        }
    }
}

struct TavilyResponse: Decodable {
    struct Item: Decodable { var title: String; var url: String; var content: String?; var score: Double? }
    var results: [Item]?
    var answer: String?
}

/// Brave — the fallback web provider.
struct BraveClient: Sendable {
    func search(_ query: String, apiKey: String,
                client: ResilientClient) async throws -> [BuildingCandidate] {
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query + " building structure"),
                                 URLQueryItem(name: "count", value: "8")]
        guard let url = components.url else { throw ServiceError.notConfigured("Brave") }
        let request = HTTPRequest(url: url,
                                  headers: ["X-Subscription-Token": apiKey,
                                            "Accept": "application/json"])
        let response: BraveResponse = try await client.json(request, as: BraveResponse.self)
        return (response.web?.results ?? []).enumerated().map { index, item in
            BuildingCandidate(name: item.title, subtitle: item.url, externalID: item.url,
                              provider: "Brave",
                              confidence: max(0.3, 0.65 - Double(index) * 0.05),
                              snippet: item.description ?? "")
        }
    }
}

struct BraveResponse: Decodable {
    struct Web: Decodable {
        struct Item: Decodable { var title: String; var url: String; var description: String? }
        var results: [Item]?
    }
    var web: Web?
}

/// Exa — semantic search, pointed deliberately at engineering sources. It is
/// the one that finds a retrofit report rather than a tourism page.
struct ExaClient: Sendable {
    func search(_ query: String, apiKey: String,
                client: ResilientClient) async throws -> [BuildingCandidate] {
        struct Contents: Encodable { var text: Bool }
        struct Body: Encodable {
            var query: String
            var numResults: Int
            var type: String
            var contents: Contents
        }
        let request = try HTTPRequest.json(
            "POST", URL(string: "https://api.exa.ai/search")!,
            headers: ["x-api-key": apiKey],
            body: Body(query: "structural engineering description of \(query): lateral system, "
                            + "storeys, height, seismic retrofit",
                       numResults: 6, type: "neural", contents: Contents(text: true)))
        let response: ExaResponse = try await client.json(request, as: ExaResponse.self)
        return (response.results ?? []).enumerated().map { index, item in
            BuildingCandidate(name: item.title ?? query, subtitle: item.url,
                              externalID: item.url, provider: "Exa",
                              confidence: max(0.3, 0.7 - Double(index) * 0.05),
                              snippet: String((item.text ?? "").prefix(400)))
        }
    }
}

struct ExaResponse: Decodable {
    struct Item: Decodable { var title: String?; var url: String; var text: String? }
    var results: [Item]?
}

// MARK: - Extracting facts from prose

/// Pulls structural numbers out of a search snippet.
///
/// Regex over prose is a blunt instrument and is treated as such: everything it
/// finds is tagged `.inferred` with modest confidence, so it can only ever be a
/// starting point the user confirms — never a silent fact in a safety model.
public enum SnippetExtractor {

    public static func facts(from text: String) -> BuildingFactSet {
        var set = BuildingFactSet()
        let provenance = FactProvenance(source: .webSearch, confidence: 0.45,
                                        detail: "Read from a web search result",
                                        retrievedAt: Date())
        let lower = text.lowercased()

        if let storeys = firstNumber(in: lower, before: ["storey", "story", "stories",
                                                         "storeys", "floors", "floor"]),
           storeys >= 1, storeys <= 200 {
            set.facts["storeyCount"] = RetrievedFact(field: "storeyCount",
                                                     value: String(Int(storeys)),
                                                     provenance: provenance)
        }
        if let metres = firstNumber(in: lower, before: ["m tall", "metres tall", "meters tall",
                                                        "m high", "metres high", "meters high",
                                                        "m)", "metres", "meters"]),
           metres >= 3, metres <= 900 {
            set.facts["height"] = RetrievedFact(field: "height",
                                                value: String(format: "%.1f", metres),
                                                provenance: provenance)
        }
        if let year = firstYear(in: lower) {
            set.facts["yearBuilt"] = RetrievedFact(field: "yearBuilt", value: String(year),
                                                   provenance: provenance)
        }
        for (needle, material) in [("reinforced concrete", "reinforcedConcrete"),
                                   ("steel frame", "steel"),
                                   ("structural steel", "steel"),
                                   ("timber", "timber"),
                                   ("unreinforced masonry", "unreinforcedMasonry"),
                                   ("brick", "unreinforcedMasonry")] {
            if lower.contains(needle) {
                set.facts["material"] = RetrievedFact(field: "material", value: material,
                                                      provenance: provenance)
                break
            }
        }
        for (needle, system) in [("shear wall", "shearWall"),
                                 ("moment frame", "momentFrame"),
                                 ("braced frame", "bracedFrame"),
                                 ("base isolat", "baseIsolated"),
                                 ("tube structure", "tube"),
                                 ("outrigger", "outrigger")] {
            if lower.contains(needle) {
                set.facts["system"] = RetrievedFact(field: "system", value: system,
                                                    provenance: provenance)
                break
            }
        }
        if lower.contains("retrofit") || lower.contains("seismic upgrade") {
            set.facts["retrofit"] = RetrievedFact(
                field: "retrofit", value: "partial",
                provenance: FactProvenance(source: .webSearch, confidence: 0.4,
                                           detail: "A retrofit is mentioned, but not its extent",
                                           retrievedAt: Date()))
        }
        return set
    }

    /// Finds the number immediately preceding any of the given phrases.
    static func firstNumber(in text: String, before phrases: [String]) -> Double? {
        for phrase in phrases {
            guard let range = text.range(of: phrase) else { continue }
            let prefix = text[text.startIndex..<range.lowerBound]
            var digits = ""
            for character in prefix.reversed() {
                if character.isNumber || character == "." || character == "," {
                    digits.append(character == "," ? "." : character)
                } else if digits.isEmpty, " -–—(".contains(character) {
                    // "42-storey" and "42 storeys" are both extremely common,
                    // and so is "(152 m)". Skip the separator and keep looking.
                    continue
                } else {
                    break
                }
            }
            let candidate = String(digits.reversed())
            if let value = Double(candidate) { return value }
        }
        return nil
    }

    static func firstYear(in text: String) -> Int? {
        var digits = ""
        for character in text {
            if character.isNumber {
                digits.append(character)
                if digits.count > 4 { digits.removeFirst() }
                if digits.count == 4, let year = Int(digits), (1700...2100).contains(year) {
                    // Only accept it if the surrounding words suggest a build date.
                    if text.contains("built") || text.contains("completed")
                        || text.contains("constructed") || text.contains("opened") {
                        return year
                    }
                }
            } else {
                digits = ""
            }
        }
        return nil
    }
}

// MARK: - The search service

/// Resolves a typed building name into candidates and then into facts.
///
/// The order is deliberate. Wikidata and Overpass come first because they are
/// keyless, structured and precise; the keyed web providers are a widening net
/// after them. If none of it works — no keys, no network, a plane — the local
/// library is searched with BM25 so the user still gets somewhere to go.
public actor BuildingSearchService {
    private let vault: SecretsVault
    private let client: ResilientClient
    private var cache = LRUCache<String, [BuildingCandidate]>(countLimit: 32)
    private let localIndex: [BuildingModel]
    /// Used only to name a plan shape for buildings nobody has mapped. Built
    /// here rather than injected so the fallback needs no wiring at the call
    /// site, and so it degrades on its own when no key is set.
    private let analyst: AIAnalyst

    public init(vault: SecretsVault,
                transport: HTTPTransport = URLSessionHTTPTransport(),
                localLibrary: [BuildingModel] = SeedLibrary.buildings()) {
        self.vault = vault
        self.client = ResilientClient(transport: transport, requestsPerSecond: 3, burst: 6)
        self.localIndex = localLibrary
        self.analyst = AIAnalyst(vault: vault, transport: transport)
    }

    /// The building's three-dimensional form, as the sources describe it.
    ///
    /// Plan shape says what it looks like from above; this says what it does as
    /// it rises. Together they are the difference between a recognisable
    /// building and an extruded brick — and, because massing drives the mass
    /// distribution the modal analysis integrates, between a plausible period
    /// and a wrong one.
    struct ResolvedMassing: Sendable {
        var massing: Massing
        var style: String
        var reason: String
        var confidence: Double
    }

    /// Searches the web for what the building actually looks like.
    ///
    /// The candidate snippets this service already holds came from a search for
    /// structural facts — height, storeys, lateral system — and are usually
    /// silent about shape. This is a second, narrower search aimed at the
    /// architecture: the words that describe a silhouette rather than a frame.
    ///
    /// It exists because the alternative is asking a language model to recall a
    /// specific building's form from memory, which is the sort of question it
    /// answers fluently and often wrongly. Handing it a page to read first
    /// turns recall into reading comprehension.
    ///
    /// Returns empty when no web provider has a key, which is the common case
    /// and not a failure: everything downstream treats an empty description as
    /// "nothing was found" and falls back to the prose already in hand.
    func formDescription(of candidate: BuildingCandidate) async -> String {
        if let cached = formCache[candidate.name] { return cached }

        let query = "\(candidate.name) architecture form shape silhouette facade "
            + "curved tapered massing description"
        var found: [String] = []

        // Tavily and Exa first: both return extracted page text rather than a
        // result title, and a building's shape is described in the prose.
        if let key = vault.value(for: .tavilyAPIKey),
           let results = try? await TavilyClient().search(query, apiKey: key, client: client) {
            found = results.map(\.snippet)
        } else if let key = vault.value(for: .exaAPIKey),
                  let results = try? await ExaClient().search(query, apiKey: key, client: client) {
            found = results.map(\.snippet)
        } else if let key = vault.value(for: .serperAPIKey),
                  let results = try? await SerperClient().search(query, apiKey: key,
                                                                 client: client) {
            found = results.map(\.snippet)
        } else if let key = vault.value(for: .braveSearchAPIKey),
                  let results = try? await BraveClient().search(query, apiKey: key,
                                                                client: client) {
            found = results.map(\.snippet)
        }

        let joined = found.filter { !$0.isEmpty }.joined(separator: " ")
        formCache[candidate.name] = joined
        return joined
    }

    /// One form search per building per session. The answer does not change
    /// while the app is open, and the plan shape and the massing both want it.
    private var formCache: [String: String] = [:]

    /// Reads the massing out of the source text, then asks the model if the
    /// text is silent.
    ///
    /// Text first, and not only to save a request: when a description already
    /// says "tapering" or "on a podium", reading that word is both free and
    /// more trustworthy than asking a model to recall a specific building. The
    /// model is consulted only when the prose says nothing, and its answer is
    /// recorded as an inference so the import screen shows it as one.
    private func massing(for candidate: BuildingCandidate,
                         facts: BuildingFactSet,
                         storeys: Int) async -> ResolvedMassing? {
        let described = [candidate.snippet, candidate.subtitle,
                         facts.facts["notes"]?.value ?? ""]
            .joined(separator: " ")
            .lowercased()

        // Only for buildings tall enough for massing to mean anything. A
        // three-storey block does not have a podium.
        guard storeys >= 6 else { return nil }

        if let described = Self.massingFromText(described) {
            return described
        }

        guard await analyst.hasAnyProvider else { return nil }

        // Read about the building's form before asking about it.
        //
        // The candidate snippet came from a search for structural facts —
        // height, storeys, system — and is usually silent on shape. Asking a
        // model to recall a specific building's silhouette from memory is
        // exactly the kind of question it will answer confidently and wrongly,
        // so it is given something to read first: a search aimed at the
        // architecture rather than the engineering.
        let read = await formDescription(of: candidate)

        // Prose that arrived from that search may name the shape outright, in
        // which case there is nothing to ask.
        if let described = Self.massingFromText(read.lowercased()) {
            return ResolvedMassing(massing: described.massing, style: described.style,
                                   reason: "Described as \(described.style) in what the web says "
                                       + "about its architecture",
                                   confidence: 0.65)
        }

        let request = AnalystRequest(
            task: .buildingSummary,
            subject: candidate.name,
            facts: [
                AnalystFact(label: "Building", value: candidate.name),
                AnalystFact(label: "Location", value: candidate.subtitle),
                AnalystFact(label: "Storeys", value: String(storeys)),
                AnalystFact(label: "What the sources say",
                            value: String(candidate.snippet.prefix(400))),
                AnalystFact(label: "What the web says about its architecture",
                            value: String(read.prefix(1200))),
            ],
            question: "Seen from the side, what is this building's silhouette? Answer with "
                    + "exactly one word and nothing else, from this list: "
                    + "uniform — the same width all the way up; "
                    + "tapered — narrowing steadily along straight edges; "
                    + "concave — narrowing along a curve, fast near the base then slowly, like "
                    + "a cooling tower or a pagoda; "
                    + "barrel — widest somewhere in the middle and closing towards the top, "
                    + "like 30 St Mary Axe; "
                    + "domed — a straight shaft with a rounded crown; "
                    + "setback — stepping inwards abruptly at intervals; "
                    + "podium — a slim tower standing on a wider base. "
                    + "Curved silhouettes are common and must not be reported as tapered: "
                    + "choose tapered only when the edges are genuinely straight. "
                    + "If you do not know this specific building, answer: unknown.")

        let answer = await analyst.answer(request)
        guard answer.value.isAIGenerated else { return nil }

        // Only the first word is read. A model that decides to explain itself
        // must not be able to turn "uniform, although the crown tapers" into a
        // tapered building.
        let first = answer.value.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .first.map(String.init) ?? ""

        guard let resolved = Self.massingNamed(first) else { return nil }
        return ResolvedMassing(
            massing: resolved.massing,
            style: resolved.style,
            reason: "Inferred by \(answer.provider) from what the sources say",
            confidence: 0.45)
    }

    /// Matches the words buildings are actually described with.
    static func massingFromText(_ text: String) -> ResolvedMassing? {
        // Curved forms come first, and deliberately. "Tapering" appears in
        // almost every description of a tall building, including the ones that
        // taper along a curve — so a text that says both "bulging" and
        // "tapering" is a barrel, and matching the commoner word first would
        // flatten every curved tower in the world into a cone.
        let patterns: [(needles: [String], style: String)] = [
            (["bulge", "bulging", "swells", "swelling", "barrel", "gherkin", "bullet-shaped",
              "widest at the middle", "widest in the middle", "cigar", "ovoid", "egg-shaped",
              "convex"], "barrel"),
            (["hyperboloid", "hyperbolic", "concave", "flares at the base", "flared base",
              "cooling tower", "pagoda-like", "waisted"], "concave"),
            (["dome", "domed", "rounded crown", "rounded top", "bulbous top", "onion"], "domed"),
            (["podium", "on a base", "tower rises from", "plinth"], "podium"),
            (["setback", "set-back", "stepped", "ziggurat", "wedding cake"], "setback"),
            (["taper", "tapering", "pyramid", "narrows towards", "conical", "spire-like"],
             "tapered"),
        ]
        for (needles, style) in patterns where needles.contains(where: text.contains) {
            guard let resolved = massingNamed(style) else { continue }
            return ResolvedMassing(massing: resolved.massing, style: style,
                                   reason: "Described as \(style) in the source text",
                                   confidence: 0.7)
        }
        return nil
    }

    /// Sensible defaults for each named form.
    ///
    /// Deliberately moderate. These are inferences from prose, not measurements,
    /// and an exaggerated taper would produce a striking model that misstates
    /// the mass distribution more than a plain prism would.
    static func massingNamed(_ name: String) -> (massing: Massing, style: String)? {
        switch name {
        case "uniform": (Massing.uniform, "uniform")
        case "tapered": (Massing.tapered(topScale: 0.42), "tapered")
        case "setback": (Massing.setback(steps: 3, topScale: 0.55), "setback")
        case "podium": (Massing.podium(podiumFraction: 0.22, towerScale: 0.55), "podium")
        case "barrel": (Massing.barrel(bulge: 0.18, atFraction: 0.35, topScale: 0.5), "barrel")
        case "concave": (Massing.concave(topScale: 0.38), "concave")
        case "domed": (Massing.domed(shoulderFraction: 0.78), "domed")
        default: nil
        }
    }

    /// What the plan looks like from above, when nobody has traced it.
    struct ResolvedPlan: Sendable {
        var shape: PlanShape
        var confidence: Double
        var reason: String
        var source: FactProvenance.Source
    }

    /// Determines the plan shape, cheapest source first.
    ///
    /// The prose is tried before the model, and not only to save a request:
    /// when a description already says "cruciform", reading that word is both
    /// free and more trustworthy than asking a model to recall the building.
    /// The model is consulted only when the text is silent, and its answer is
    /// recorded as an inference so the import screen can show it as one.
    private func planShape(for candidate: BuildingCandidate,
                           facts: BuildingFactSet) async -> ResolvedPlan? {
        let described = [candidate.snippet, candidate.subtitle,
                         facts.facts["notes"]?.value ?? ""].joined(separator: " ")
        if let shape = PlanShape.parse(described) {
            return ResolvedPlan(shape: shape, confidence: 0.7,
                                reason: "Described as \(shape.label.lowercased()) in the source text",
                                source: .webSearch)
        }

        // The same architectural search the massing uses, cached, so this costs
        // nothing extra when both run. A description of the building's form is
        // far likelier to name its plan than a page about its height is.
        let read = await formDescription(of: candidate)
        if !read.isEmpty, let shape = PlanShape.parse(read) {
            return ResolvedPlan(shape: shape, confidence: 0.65,
                                reason: "Described as \(shape.label.lowercased()) in what the "
                                    + "web says about its architecture",
                                source: .webSearch)
        }

        guard await analyst.hasAnyProvider else { return nil }

        let options = PlanShape.allCases.map(\.rawValue).joined(separator: ", ")
        let request = AnalystRequest(
            task: .buildingSummary,
            subject: candidate.name,
            facts: [
                AnalystFact(label: "Building", value: candidate.name),
                AnalystFact(label: "Location", value: candidate.subtitle),
                AnalystFact(label: "Description", value: String(described.prefix(400))),
                AnalystFact(label: "What the web says about its architecture",
                            value: String(read.prefix(1200))),
            ],
            question: "What is this building's footprint shape seen from directly above? "
                    + "Answer with exactly one of these words and nothing else: \(options). "
                    + "Curved plans are common — a great many towers are circular, elliptical "
                    + "or have one bowed face — so do not answer with a rectangular shape "
                    + "unless the walls really are straight. "
                    + "If you do not know this specific building, answer: unknown.")

        let answer = await analyst.answer(request)
        guard answer.value.isAIGenerated else { return nil }

        // Only the first token is read. A model that decides to explain itself
        // must not be able to turn "rectangular, though the north wing is
        // circular" into a circular building.
        let first = answer.value.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "." || $0 == "," })
            .first.map(String.init) ?? ""
        guard let shape = PlanShape.parse(first) else { return nil }

        return ResolvedPlan(shape: shape, confidence: 0.5,
                            reason: "Inferred by \(answer.provider); no mapped outline exists",
                            source: .aiInference)
    }

    /// True when at least one live path exists. Wikidata and Overpass need no
    /// key, so this is true on a fresh install with an internet connection.
    public nonisolated var hasLivePath: Bool {
        vault.has(.wikidataEndpoint) || vault.has(.serperAPIKey)
            || vault.has(.tavilyAPIKey) || vault.has(.braveSearchAPIKey) || vault.has(.exaAPIKey)
    }

    public func search(_ query: String) async -> Sourced<[BuildingCandidate]> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            return Sourced([], origin: .onDevice, provider: "None",
                           note: "Type at least two characters.")
        }
        if let hit = cache.value(forKey: trimmed.lowercased()) {
            return Sourced(hit, origin: .cached, provider: "Cache")
        }

        var found: [BuildingCandidate] = []
        var providersTried: [String] = []

        if let endpoint = vault.value(for: .wikidataEndpoint).flatMap(URL.init(string:)) {
            providersTried.append("Wikidata")
            if let results = try? await WikidataClient(endpoint: endpoint)
                .search(trimmed, client: client) {
                found += results
            }
        }
        if found.count < 5, let key = vault.value(for: .serperAPIKey), !key.isEmpty {
            providersTried.append("Serper")
            if let results = try? await SerperClient().search(trimmed, apiKey: key, client: client) {
                found += results
            }
        }
        if found.count < 5, let key = vault.value(for: .tavilyAPIKey), !key.isEmpty {
            providersTried.append("Tavily")
            if let results = try? await TavilyClient().search(trimmed, apiKey: key, client: client) {
                found += results
            }
        }
        if found.count < 5, let key = vault.value(for: .braveSearchAPIKey), !key.isEmpty {
            providersTried.append("Brave")
            if let results = try? await BraveClient().search(trimmed, apiKey: key, client: client) {
                found += results
            }
        }
        if found.count < 3, let key = vault.value(for: .exaAPIKey), !key.isEmpty {
            providersTried.append("Exa")
            if let results = try? await ExaClient().search(trimmed, apiKey: key, client: client) {
                found += results
            }
        }

        let deduplicated = Self.deduplicate(found)
        if !deduplicated.isEmpty {
            cache.setValue(deduplicated, forKey: trimmed.lowercased())
            return Sourced(deduplicated, origin: .live,
                           provider: providersTried.joined(separator: " + "))
        }

        let local = localMatches(trimmed)
        return Sourced(local, origin: .seeded, provider: "Bundled library",
                       note: providersTried.isEmpty
                           ? "No search provider is configured, so the bundled library was searched."
                           : "No provider answered, so the bundled library was searched.")
    }

    /// Everything known about one candidate, merged across sources.
    public func facts(for candidate: BuildingCandidate) async -> Sourced<BuildingFactSet> {
        var merged = BuildingFactSet()
        var providers: [String] = []

        if let endpoint = vault.value(for: .wikidataEndpoint).flatMap(URL.init(string:)),
           let set = try? await WikidataClient(endpoint: endpoint)
               .facts(candidate.name,
                      entityID: candidate.provider == "Wikidata" ? candidate.externalID : nil,
                      client: client), !set.isEmpty {
            merged.merge(set)
            providers.append("Wikidata")
        }

        if let latitude = candidate.latitude, let longitude = candidate.longitude,
           let endpoint = vault.value(for: .overpassEndpoint).flatMap(URL.init(string:)),
           let (set, footprint) = try? await OverpassClient(endpoint: endpoint)
               .facts(latitude: latitude, longitude: longitude,
                      name: candidate.name, client: client) {
            merged.merge(set)
            if !footprint.isEmpty, let encoded = try? JSONEncoder().encode(footprint) {
                merged.facts["footprint"] = RetrievedFact(
                    field: "footprint",
                    value: String(data: encoded, encoding: .utf8) ?? "",
                    provenance: FactProvenance(source: .openStreetMap, confidence: 0.8,
                                               detail: "Real footprint polygon from OSM",
                                               retrievedAt: Date()))
            }
            providers.append("OpenStreetMap")
        }

        // Plan shape, but only where OSM has not already traced the real one.
        //
        // A mapped outline beats any description of one, so this never
        // overrides it. It exists for the far more common case of a building
        // nobody has drawn, where the alternative is a rectangle that tells the
        // user nothing about their own building.
        if merged.facts["footprint"] == nil,
           let shape = await planShape(for: candidate, facts: merged) {
            merged.facts["planShape"] = RetrievedFact(
                field: "planShape", value: shape.shape.rawValue,
                provenance: FactProvenance(source: shape.source,
                                           confidence: shape.confidence,
                                           detail: shape.reason, retrievedAt: Date()))
            providers.append(shape.source == .aiInference ? "AI plan shape" : "Described plan")
        }

        // How the form changes with height. Needs the storey count, so it runs
        // after the other sources have had their say.
        //
        // Skipped outright when OpenStreetMap has already given a profile built
        // from mapped building parts. That profile came from somebody who
        // measured the building; this one is inferred from prose and, for the
        // handful of famous towers it knows by name, from a table. A described
        // massing must never overwrite a surveyed one — the same rule the
        // footprint follows a few lines above.
        let storeys = Int(merged.facts["storeyCount"]?.value ?? "") ?? 0
        if merged.facts["massing"] == nil,
           let form = await massing(for: candidate, facts: merged, storeys: storeys),
           let encoded = try? JSONEncoder().encode(form.massing),
           let json = String(data: encoded, encoding: .utf8) {
            merged.facts["massing"] = RetrievedFact(
                field: "massing", value: json,
                provenance: FactProvenance(
                    source: form.confidence > 0.6 ? .webSearch : .aiInference,
                    confidence: form.confidence,
                    detail: form.reason, retrievedAt: Date()))
            merged.facts["massingStyle"] = RetrievedFact(
                field: "massingStyle", value: form.style,
                provenance: FactProvenance(
                    source: form.confidence > 0.6 ? .webSearch : .aiInference,
                    confidence: form.confidence,
                    detail: form.reason, retrievedAt: Date()))
            providers.append("Massing")
        }

        if !candidate.snippet.isEmpty {
            let extracted = SnippetExtractor.facts(from: candidate.snippet)
            if !extracted.isEmpty {
                merged.merge(extracted)
                providers.append(candidate.provider)
            }
        }

        if merged.isEmpty {
            return Sourced(merged, origin: .onDevice, provider: "None",
                           note: "Nothing was retrieved. Fill in what you know — every field "
                               + "is editable and the estimate updates as you type.")
        }
        return Sourced(merged, origin: .live, provider: providers.joined(separator: " + "))
    }

    /// Turns a fact set into a building, filling every gap with a stated
    /// estimate rather than a zero. The result is always usable.
    public nonisolated func compose(candidate: BuildingCandidate,
                                    facts: BuildingFactSet) -> BuildingModel {
        func string(_ field: String) -> String? { facts[field]?.value }
        func number(_ field: String) -> Double? { facts[field].flatMap { Double($0.value) } }

        let storeys = Int(number("storeyCount") ?? 0)
        let height = number("height")

        // Whichever of the two is missing is derived from the other at a
        // typical floor-to-floor height, and the derivation is recorded.
        let resolvedStoreys = storeys > 0 ? storeys
            : max(1, Int(((height ?? 12) / 3.4).rounded()))
        let resolvedHeight = height ?? Double(resolvedStoreys) * 3.4

        var provenance: [String: FactProvenance] = [:]
        for (field, fact) in facts.facts { provenance[field] = fact.provenance }
        if storeys == 0 {
            provenance["storeyCount"] = FactProvenance(
                source: .defaultAssumption, confidence: 0.4,
                detail: "Derived from the height at 3.4 m per storey", retrievedAt: Date())
        }
        if height == nil {
            provenance["height"] = FactProvenance(
                source: .defaultAssumption, confidence: 0.4,
                detail: "Derived from the storey count at 3.4 m per storey", retrievedAt: Date())
        }

        let mapped: [Coordinate2D] = {
            guard let raw = string("footprint"), let data = raw.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([Coordinate2D].self, from: data)) ?? []
        }()

        // The massing, if anything worked one out.
        let massing: Massing = {
            guard let raw = string("massing"), let data = raw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(Massing.self, from: data)
            else { return .uniform }
            return decoded
        }()

        // A traced outline wins outright. Failing that, the plan shape becomes
        // a real polygon rather than the rectangle every building used to get.
        let plannedArea = number("footprintArea") ?? (Double(resolvedStoreys) * 40 + 300)
        let footprint: [Coordinate2D] = {
            if !mapped.isEmpty { return mapped }
            guard let shape = string("planShape").flatMap(PlanShape.init(rawValue:)) else {
                return []
            }
            return shape.polygon(area: plannedArea)
        }()

        return BuildingModel(
            name: string("name") ?? candidate.name,
            address: string("address") ?? candidate.subtitle,
            latitude: number("latitude") ?? candidate.latitude ?? 0,
            longitude: number("longitude") ?? candidate.longitude ?? 0,
            storeyCount: resolvedStoreys,
            height: resolvedHeight,
            footprintArea: number("footprintArea")
                ?? (mapped.isEmpty ? plannedArea : OverpassClient.polygonArea(mapped)),
            footprint: footprint,
            massing: massing,
            yearBuilt: number("yearBuilt").map(Int.init),
            material: string("material").flatMap(Self.material) ?? .reinforcedConcrete,
            system: string("system").flatMap(StructuralSystem.init(rawValue:)) ?? .momentFrame,
            soil: .denseSoil,
            retrofit: string("retrofit").flatMap(RetrofitLevel.init(rawValue:)) ?? .none,
            architect: string("architect"),
            notes: candidate.snippet.isEmpty ? "" : String(candidate.snippet.prefix(300)),
            provenance: provenance,
            privacy: .approximate)
    }

    static func material(_ raw: String) -> ConstructionMaterial? {
        if let exact = ConstructionMaterial(rawValue: raw) { return exact }
        let lower = raw.lowercased()
        if lower.contains("concrete") { return .reinforcedConcrete }
        if lower.contains("steel") { return .steel }
        if lower.contains("wood") || lower.contains("timber") { return .timber }
        if lower.contains("brick") || lower.contains("masonry") { return .unreinforcedMasonry }
        return nil
    }

    /// Ranks the bundled library with BM25 so an offline search still lands on
    /// the right building rather than returning nothing.
    private func localMatches(_ query: String) -> [BuildingCandidate] {
        var index = BM25<String>()
        index.index(localIndex.map { building in
            BM25<String>.Document(id: building.id.uuidString,
                          text: [building.name, building.address, building.architect ?? "",
                                 building.material.label, building.system.label,
                                 building.notes].joined(separator: " "))
        })
        let ranked = index.search(query, limit: 6)
        return ranked.compactMap { hit in
            guard let building = localIndex.first(where: { $0.id.uuidString == hit.id }) else {
                return nil
            }
            return BuildingCandidate(
                name: building.name,
                subtitle: building.address,
                latitude: building.latitude, longitude: building.longitude,
                externalID: building.id.uuidString,
                provider: "Bundled library",
                confidence: min(0.9, 0.4 + hit.score / 10),
                snippet: building.notes)
        }
    }

    /// Collapses near-duplicate names across providers, keeping the most
    /// confident and merging the snippets so no retrieved prose is lost.
    static func deduplicate(_ candidates: [BuildingCandidate]) -> [BuildingCandidate] {
        var out: [BuildingCandidate] = []
        for candidate in candidates.sorted(by: { $0.confidence > $1.confidence }) {
            // Edit distance alone is not enough here: providers differ by a
            // leading article far more often than by a typo, and "The Chrysler
            // Building" against "Chrysler Building" scores below any sensible
            // typo threshold. The combined measure drops stop words first.
            if let index = out.firstIndex(where: {
                FuzzyMatch.combinedSimilarity($0.name.lowercased(),
                                              candidate.name.lowercased()) > 0.82
            }) {
                if out[index].latitude == nil {
                    out[index].latitude = candidate.latitude
                    out[index].longitude = candidate.longitude
                }
                if out[index].snippet.count < 400, !candidate.snippet.isEmpty {
                    out[index].snippet += " " + candidate.snippet
                }
                out[index].provider += " + \(candidate.provider)"
                continue
            }
            out.append(candidate)
        }
        return Array(out.prefix(10))
    }
}
