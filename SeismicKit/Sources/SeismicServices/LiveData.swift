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

public struct USGSFeed: Decodable, Sendable {
    public struct Feature: Decodable, Sendable {
        public struct Properties: Decodable, Sendable {
            public var mag: Double?
            public var place: String?
            public var time: Double?
            public var tsunami: Int?
        }
        public struct Geometry: Decodable, Sendable {
            public var coordinates: [Double]
        }
        public var properties: Properties
        public var geometry: Geometry
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
