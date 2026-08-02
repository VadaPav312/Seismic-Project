import Foundation
import SeismicCore
import SeismicData

/// The USGS real-time earthquake feed.
///
/// No key. That is worth stating plainly, because the usual assumption is that
/// live seismicity is a paid data product: the global feed of every earthquake
/// above magnitude 2.5 is public, free and updated every minute, so the Feed
/// screen is live for every user of this app from the first launch.
public actor EarthquakeFeedService {
    public enum Window: String, Sendable, CaseIterable, Identifiable {
        case pastHour, pastDay, pastWeek, pastMonth
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .pastHour: "Past hour"
            case .pastDay: "Past day"
            case .pastWeek: "Past week"
            case .pastMonth: "Past month"
            }
        }

        /// The 2.5+ feeds are the useful ones: below that is mostly instrument
        /// noise and quarry blasts, and the list becomes unreadable.
        var path: String {
            switch self {
            case .pastHour: "2.5_hour"
            case .pastDay: "2.5_day"
            case .pastWeek: "2.5_week"
            case .pastMonth: "2.5_month"
            }
        }
    }

    private let client: ResilientClient
    private var cached: [Window: (fetchedAt: Date, records: [EarthquakeRecord])] = [:]

    public init(transport: HTTPTransport = URLSessionHTTPTransport()) {
        self.client = ResilientClient(transport: transport, requestsPerSecond: 1, burst: 3)
    }

    public func recent(_ window: Window = .pastDay,
                       maximumAge: TimeInterval = 120) async -> Sourced<[EarthquakeRecord]> {
        if let hit = cached[window], Date().timeIntervalSince(hit.fetchedAt) < maximumAge {
            return Sourced(hit.records, origin: .cached, provider: "USGS")
        }

        let url = URL(string: "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/"
                             + "\(window.path).geojson")!
        do {
            let response: USGSFeed = try await client.json(HTTPRequest(url: url, timeout: 20),
                                                           as: USGSFeed.self)
            let records = response.features.compactMap(Self.record(from:))
            guard !records.isEmpty else { throw ServiceError.emptyResult }
            cached[window] = (Date(), records)
            return Sourced(records, origin: .live, provider: "USGS")
        } catch {
            if let hit = cached[window] {
                return Sourced(hit.records, origin: .cached, provider: "USGS",
                               note: "The feed did not answer; showing the last result.")
            }
            return Sourced(SeedLibrary.earthquakes(), origin: .seeded, provider: "Bundled library",
                           note: "The live feed is unavailable, so the historic library is shown. "
                               + "Every one of these can still be run in the simulator.")
        }
    }

    // MARK: History anywhere on Earth

    /// Every earthquake near a point, over a window of years.
    ///
    /// The summary feeds above cover the whole world but only the recent past,
    /// and only as a fixed list. This is the FDSN event service, which is the
    /// same catalogue queried properly: any coordinate, any radius, any time
    /// range, back to the beginning of the instrumental record. Also keyless,
    /// which is what makes a "tap anywhere and see the history" map possible
    /// for every user rather than only for one with an account.
    ///
    /// The magnitude floor scales with the radius on purpose. A 300 km circle
    /// around Tokyo contains tens of thousands of magnitude 2 events over ten
    /// years, which is a slow query returning a list nobody can read; the
    /// events that tell you what a place is like are the ones large enough to
    /// have been felt.
    public func history(latitude: Double, longitude: Double,
                        radiusKm: Double = 250, years: Double = 10,
                        minimumMagnitude: Double? = nil,
                        limit: Int = 500) async -> Sourced<RegionalHistory> {
        let key = HistoryKey(latitude: (latitude * 20).rounded() / 20,
                             longitude: (longitude * 20).rounded() / 20,
                             radiusKm: radiusKm, years: years)
        if let hit = historyCache[key], Date().timeIntervalSince(hit.fetchedAt) < 900 {
            return Sourced(hit.history, origin: .cached, provider: "USGS")
        }

        let floor = minimumMagnitude ?? Self.magnitudeFloor(forRadiusKm: radiusKm)
        let start = Date(timeIntervalSinceNow: -years * 365.25 * 86_400)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var components = URLComponents(
            string: "https://earthquake.usgs.gov/fdsnws/event/1/query")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "geojson"),
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "maxradiuskm", value: String(format: "%.0f", radiusKm)),
            URLQueryItem(name: "starttime", value: formatter.string(from: start)),
            URLQueryItem(name: "minmagnitude", value: String(format: "%.1f", floor)),
            URLQueryItem(name: "orderby", value: "magnitude"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components.url else {
            return Sourced(.empty(radiusKm: radiusKm, years: years, floor: floor),
                           origin: .onDevice, provider: "None",
                           note: "That location could not be turned into a query.")
        }

        do {
            let response: USGSFeed = try await client.json(HTTPRequest(url: url, timeout: 25),
                                                           as: USGSFeed.self)
            let history = RegionalHistory(features: response.features, radiusKm: radiusKm,
                                          years: years, magnitudeFloor: floor)
            historyCache[key] = (Date(), history)
            // An empty answer here is information, not a failure: most of the
            // Earth's surface genuinely has had no felt earthquake in ten
            // years, and saying so is the useful reply.
            return Sourced(history, origin: .live, provider: "USGS")
        } catch {
            if let hit = historyCache[key] {
                return Sourced(hit.history, origin: .cached, provider: "USGS",
                               note: "The catalogue did not answer; showing the last result.")
            }
            return Sourced(.empty(radiusKm: radiusKm, years: years, floor: floor),
                           origin: .onDevice, provider: "None",
                           note: "The earthquake catalogue could not be reached. It needs a "
                               + "network connection; nothing else in the app does.")
        }
    }

    /// Larger area, higher floor. Keeps the answer readable and the query fast.
    static func magnitudeFloor(forRadiusKm radius: Double) -> Double {
        switch radius {
        case ..<60: 2.5
        case ..<150: 3.5
        case ..<400: 4.5
        default: 5.5
        }
    }

    private struct HistoryKey: Hashable {
        var latitude: Double
        var longitude: Double
        var radiusKm: Double
        var years: Double
    }
    private var historyCache: [HistoryKey: (fetchedAt: Date, history: RegionalHistory)] = [:]

    static func record(from feature: USGSFeed.Feature) -> EarthquakeRecord? {
        guard let magnitude = feature.properties.mag,
              feature.geometry.coordinates.count >= 3 else { return nil }
        let longitude = feature.geometry.coordinates[0]
        let latitude = feature.geometry.coordinates[1]
        let depth = feature.geometry.coordinates[2]
        let time = Date(timeIntervalSince1970: (feature.properties.time ?? 0) / 1000)
        let year = Calendar(identifier: .gregorian)
            .dateComponents([.year], from: time).year ?? 0

        // The feed gives magnitude and geometry, not a waveform. Duration and
        // dominant period are estimated from magnitude using the same
        // relationships the synthetic generator uses, so a live event can be
        // played through the simulator immediately rather than being inert.
        let duration = max(6, 2.5 * pow(10, 0.4 * (magnitude - 4)))
        let dominantPeriod = max(0.15, 0.08 * pow(10, 0.28 * (magnitude - 4)))

        return EarthquakeRecord(
            name: feature.properties.place ?? "Unnamed event",
            year: year,
            magnitude: magnitude,
            depthKm: depth,
            latitude: latitude,
            longitude: longitude,
            station: "USGS feed",
            pgaTarget: 0,
            duration: duration,
            dominantPeriod: dominantPeriod,
            summary: feature.properties.place ?? "",
            origin: .liveFeed,
            originTime: time)
    }
}

/// What has happened near a point, and what it did.
///
/// Assembled from the catalogue rather than stored, so the same structure works
/// for anywhere on Earth without a database of places behind it.
///
/// The impact figures deserve a note, because it would be easy to overclaim
/// here. The USGS does not publish a count of collapsed buildings, and no free
/// source does; what it publishes is PAGER, its own model-based estimate of the
/// losses an earthquake caused, as a four-level alert. That is a real,
/// authoritative signal of which events damaged buildings, and it is reported
/// as what it is. Inventing collapse counts to fill the gap would be worse than
/// leaving it open.
public struct RegionalHistory: Sendable, Equatable {

    /// Estimated impact, on the USGS's own scale.
    public enum Impact: String, Sendable, Comparable, CaseIterable {
        case none, green, yellow, orange, red

        public static func < (a: Impact, b: Impact) -> Bool {
            let order: [Impact] = [.none, .green, .yellow, .orange, .red]
            return (order.firstIndex(of: a) ?? 0) < (order.firstIndex(of: b) ?? 0)
        }

        /// What the level actually means, in the USGS's own terms.
        public var meaning: String {
            switch self {
            case .none: "No loss estimate was published for this event."
            case .green: "No significant damage expected."
            case .yellow: "Local damage expected — some buildings damaged, few or no deaths."
            case .orange: "Significant damage expected — many buildings damaged, "
                + "deaths in the hundreds."
            case .red: "Extensive damage — widespread collapse, deaths potentially "
                + "in the thousands."
            }
        }

        /// Whether buildings are expected to have been damaged.
        public var damagedBuildings: Bool { self >= .yellow }
    }

    /// One event, with the parts of it a person looking at a map cares about.
    public struct Event: Sendable, Equatable, Identifiable {
        public var id: String
        public var record: EarthquakeRecord
        public var impact: Impact
        /// Peak instrumental intensity, Modified Mercalli, where measured.
        public var shaking: Double?
        /// How many people reported feeling it.
        public var felt: Int?
        public var causedTsunami: Bool

        public var magnitude: Double { record.magnitude }
        public var date: Date { record.originTime ?? Date.distantPast }
        public var place: String { record.name }
    }

    public var events: [Event]
    public var radiusKm: Double
    public var years: Double
    public var magnitudeFloor: Double

    public init(events: [Event], radiusKm: Double, years: Double, magnitudeFloor: Double) {
        self.events = events
        self.radiusKm = radiusKm
        self.years = years
        self.magnitudeFloor = magnitudeFloor
    }

    public static func empty(radiusKm: Double, years: Double, floor: Double) -> RegionalHistory {
        RegionalHistory(events: [], radiusKm: radiusKm, years: years, magnitudeFloor: floor)
    }

    init(features: [USGSFeed.Feature], radiusKm: Double, years: Double, magnitudeFloor: Double) {
        self.events = features.compactMap { feature in
            guard let record = EarthquakeFeedService.record(from: feature) else { return nil }
            return Event(
                id: feature.id ?? UUID().uuidString,
                record: record,
                impact: feature.properties.alert.flatMap(Impact.init(rawValue:)) ?? .none,
                shaking: feature.properties.mmi ?? feature.properties.cdi,
                felt: feature.properties.felt,
                causedTsunami: (feature.properties.tsunami ?? 0) > 0)
        }
        self.radiusKm = radiusKm
        self.years = years
        self.magnitudeFloor = magnitudeFloor
    }

    // MARK: What it says

    public var largest: Event? { events.max { $0.magnitude < $1.magnitude } }
    public var mostRecent: Event? { events.max { $0.date < $1.date } }

    /// Events the USGS estimated caused damage to buildings.
    public var damaging: [Event] {
        events.filter { $0.impact.damagedBuildings }.sorted { $0.impact > $1.impact }
    }

    /// Events per year above magnitude 5, which is roughly where a well-built
    /// modern building starts to care and a poorly-built one starts to fail.
    public var annualRateAboveFive: Double {
        guard years > 0 else { return 0 }
        return Double(events.filter { $0.magnitude >= 5 }.count) / years
    }

    public var worstImpact: Impact { events.map(\.impact).max() ?? .none }

    /// The whole thing in a sentence or two, which is what a tap on a map
    /// should answer with before any list.
    public var narrative: String {
        guard !events.isEmpty else {
            return "No earthquake above magnitude "
                + String(format: "%.1f", magnitudeFloor)
                + " has been recorded within \(Int(radiusKm)) km of here in the last "
                + "\(Int(years)) years. That is the case for most of the Earth's surface."
        }

        var parts: [String] = []
        parts.append("\(events.count) earthquake\(events.count == 1 ? "" : "s") above magnitude "
                     + String(format: "%.1f", magnitudeFloor)
                     + " within \(Int(radiusKm)) km in \(Int(years)) years.")

        if let largest {
            let year = Calendar(identifier: .gregorian)
                .dateComponents([.year], from: largest.date).year ?? 0
            parts.append("The largest was magnitude "
                         + String(format: "%.1f", largest.magnitude)
                         + " in \(year), \(largest.place).")
        }

        let damaging = damaging
        if damaging.isEmpty {
            parts.append("None of them was estimated to have damaged buildings.")
        } else {
            parts.append("\(damaging.count) of them "
                         + (damaging.count == 1 ? "was" : "were")
                         + " estimated to have damaged buildings. "
                         + (worstImpact.meaning))
        }

        let rate = annualRateAboveFive
        if rate >= 0.1 {
            parts.append(String(format: "That is about %.1f events above magnitude 5 a year.",
                                rate))
        }
        return parts.joined(separator: " ")
    }
}

public struct USGSFeed: Decodable, Sendable {
    public struct Feature: Decodable, Sendable {
        public struct Properties: Decodable, Sendable {
            public var mag: Double?
            public var place: String?
            public var time: Double?
            public var tsunami: Int?
            /// PAGER alert level: the USGS's own estimate of the losses this
            /// event caused. The closest thing to authoritative damage data
            /// that exists without a key.
            public var alert: String?
            /// Peak instrumental intensity, Modified Mercalli.
            public var mmi: Double?
            /// Community-reported intensity, from "Did You Feel It?".
            public var cdi: Double?
            public var felt: Int?
        }
        public struct Geometry: Decodable, Sendable {
            public var coordinates: [Double]
        }
        public var properties: Properties
        public var geometry: Geometry
        /// The catalogue's own identifier, stable across refetches.
        public var id: String?
    }
    public var features: [Feature]
}

// MARK: - Aftershock forecasts

/// USGS Operational Aftershock Forecasts. Also keyless.
///
/// When a live forecast exists it is far better than a generic model, because
/// it has been fitted to *this* sequence. When it does not — most events, most
/// of the time — the app falls back to the Omori-Utsu and Gutenberg-Richter
/// implementation in `SeismicStructures`, which is the same mathematics with
/// generic parameters, and says which one produced the number.
public actor AftershockForecastService {
    private let client: ResilientClient

    public init(transport: HTTPTransport = URLSessionHTTPTransport()) {
        self.client = ResilientClient(transport: transport, requestsPerSecond: 1, burst: 2)
    }

    public struct Forecast: Sendable, Equatable {
        public var windowLabel: String
        public var magnitudeThreshold: Double
        public var probability: Double
        public var expectedCount: Double
    }

    public func forecast(eventID: String) async -> Sourced<[Forecast]>? {
        let url = URL(string: "https://earthquake.usgs.gov/fdsnws/event/1/query"
                             + "?eventid=\(eventID)&format=geojson&producttype=oaf")!
        guard let response = try? await client.send(HTTPRequest(url: url, timeout: 15)),
              response.isSuccess,
              let parsed = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else { return nil }

        // The OAF product is nested and its shape varies between releases, so
        // this reads defensively and returns nil rather than guessing wrong.
        guard let properties = parsed["properties"] as? [String: Any],
              let products = properties["products"] as? [String: Any],
              let oaf = (products["oaf"] as? [[String: Any]])?.first,
              let contents = oaf["contents"] as? [String: Any],
              contents["forecast.json"] != nil else { return nil }
        return Sourced([], origin: .live, provider: "USGS OAF",
                       note: "A live aftershock forecast exists for this sequence.")
    }
}

// MARK: - Temperature

/// Temperature at the building, used to normalise the measured period.
///
/// Ordering matters here and is the opposite of what you would expect: the
/// node's own thermistor is *preferred* over the weather service, because it is
/// bonded to the structure and the structure's temperature is what changes its
/// stiffness. Air temperature from a station some kilometres away is the
/// fallback, not the primary.
public actor TemperatureService {
    private let vault: SecretsVault
    private let client: ResilientClient
    private var cached: (at: Date, celsius: Double)?

    public init(vault: SecretsVault, transport: HTTPTransport = URLSessionHTTPTransport()) {
        self.vault = vault
        self.client = ResilientClient(transport: transport, requestsPerSecond: 1, burst: 2)
    }

    public func temperature(latitude: Double, longitude: Double,
                            nodeReading: Double?) async -> Sourced<Double> {
        if let nodeReading {
            return Sourced(nodeReading, origin: .onDevice, provider: "Node thermistor",
                           note: "Measured on the structure itself, which is what actually "
                               + "changes its stiffness.")
        }
        if let cached, Date().timeIntervalSince(cached.at) < 900 {
            return Sourced(cached.celsius, origin: .cached, provider: "OpenWeather")
        }
        guard let key = vault.value(for: .openWeatherAPIKey), !key.isEmpty else {
            return Sourced(15.0, origin: .onDevice, provider: "Assumed",
                           note: "No temperature source. 15 °C is assumed, and the temperature "
                               + "correction is reported as low confidence because of it.")
        }
        let url = URL(string: "https://api.openweathermap.org/data/2.5/weather?"
                             + "lat=\(latitude)&lon=\(longitude)&units=metric&appid=\(key)")!
        do {
            let response: OpenWeatherResponse =
                try await client.json(HTTPRequest(url: url, timeout: 12),
                                      as: OpenWeatherResponse.self)
            cached = (Date(), response.main.temp)
            vault.setStatus(.valid(checkedAt: Date()), for: .openWeatherAPIKey)
            return Sourced(response.main.temp, origin: .live, provider: "OpenWeather",
                           note: "Air temperature near the building, not on it.")
        } catch let error as ServiceError {
            if let status = error.keyStatus() {
                vault.setStatus(status, for: .openWeatherAPIKey)
            }
            return Sourced(15.0, origin: .onDevice, provider: "Assumed",
                           note: "The weather service did not answer.")
        } catch {
            return Sourced(15.0, origin: .onDevice, provider: "Assumed")
        }
    }
}

struct OpenWeatherResponse: Decodable {
    struct Main: Decodable { var temp: Double }
    var main: Main
}

// MARK: - Key testing

/// Backs Settings → API Keys → Test.
///
/// Each test is the cheapest real call the service offers, so pressing Test
/// costs almost nothing and still proves the key works end to end rather than
/// merely checking it looks like a key.
public actor KeyTester {
    private let vault: SecretsVault
    private let client: ResilientClient

    public init(vault: SecretsVault, transport: HTTPTransport = URLSessionHTTPTransport()) {
        self.vault = vault
        self.client = ResilientClient(transport: transport, requestsPerSecond: 2, burst: 4)
    }

    public func test(_ key: SecretKey) async -> KeyStatus {
        guard let value = vault.value(for: key), !value.isEmpty else {
            vault.setStatus(.missing, for: key)
            return .missing
        }

        guard let request = probe(for: key, value: value) else {
            // No cheap probe exists for this one. Saying "present" is honest;
            // claiming "valid" without having exercised it would not be.
            vault.setStatus(.present, for: key)
            return .present
        }

        do {
            _ = try await client.send(request)
            let status = KeyStatus.valid(checkedAt: Date())
            vault.setStatus(status, for: key)
            return status
        } catch let error as ServiceError {
            let status = error.keyStatus() ?? .failing(reason: error.userFacingReason, at: Date())
            vault.setStatus(status, for: key)
            return status
        } catch {
            let status = KeyStatus.failing(reason: "Unknown error", at: Date())
            vault.setStatus(status, for: key)
            return status
        }
    }

    func probe(for key: SecretKey, value: String) -> HTTPRequest? {
        switch key {
        case .openAIAPIKey:
            HTTPRequest(url: URL(string: "https://api.openai.com/v1/models")!,
                        headers: ["Authorization": "Bearer \(value)"], timeout: 12)
        case .cerebrasAPIKey:
            HTTPRequest(url: URL(string: "https://api.cerebras.ai/v1/models")!,
                        headers: ["Authorization": "Bearer \(value)"], timeout: 12)
        case .geminiAPIKey:
            HTTPRequest(url: URL(string: "https://generativelanguage.googleapis.com/"
                                        + "v1beta/models")!,
                        headers: ["x-goog-api-key": value], timeout: 12)
        case .anthropicAPIKey:
            HTTPRequest(url: URL(string: "https://api.anthropic.com/v1/models")!,
                        headers: ["x-api-key": value, "anthropic-version": "2023-06-01"],
                        timeout: 12)
        case .elevenLabsAPIKey:
            HTTPRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!,
                        headers: ["xi-api-key": value], timeout: 12)
        case .braveSearchAPIKey:
            HTTPRequest(url: URL(string: "https://api.search.brave.com/res/v1/web/search?q=test")!,
                        headers: ["X-Subscription-Token": value, "Accept": "application/json"],
                        timeout: 12)
        case .openWeatherAPIKey:
            HTTPRequest(url: URL(string: "https://api.openweathermap.org/data/2.5/weather?"
                                        + "lat=0&lon=0&appid=\(value)")!, timeout: 12)
        case .supabaseURL:
            URL(string: value).map { HTTPRequest(url: $0, timeout: 12) }
        case .wikidataEndpoint, .overpassEndpoint:
            URL(string: value).map { HTTPRequest(url: $0, timeout: 12) }
        default:
            nil
        }
    }
}
