import SwiftUI
import SeismicCore
import SeismicGeo
import SeismicData

/// Earthquakes worldwide, tappable straight into the simulator.
///
/// Backed by the USGS feed, which needs no key at all. When there is no network
/// the bundled historic library takes its place, clearly labelled — an empty
/// list would be indistinguishable from a quiet day, and that ambiguity is worse
/// than a stale list.
struct GlobalFeedScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var feed = EarthquakeFeed()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Metrics.spacing) {
                if feed.isLoading && feed.events.isEmpty {
                    ForEach(0..<5, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonBlock(height: 16, width: 180)
                            SkeletonBlock(height: 11, width: 240)
                            SkeletonBlock(height: 11, width: 120)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .instrumentPanel()
                    }
                } else {
                    if feed.isUsingBundledData {
                        InlineNotice(
                            level: .info,
                            title: "Showing the historic library",
                            message: "The live feed could not be reached, so these are the "
                                + "bundled records instead. They shake buildings exactly the "
                                + "same way.",
                            actionTitle: "Try again",
                            action: { Task { await feed.load(fallback: env.earthquakes) } })
                    }

                    ForEach(feed.events) { event in
                        EarthquakeFeedRow(event: event) {
                            env.selectedBuildingID = env.selectedBuilding?.id
                            Haptics.shared.play(.selection)
                        }
                    }
                }
            }
            .padding(Theme.Metrics.screenPadding)
        }
        .refreshable { await feed.load(fallback: env.earthquakes) }
        .task { await feed.load(fallback: env.earthquakes) }
    }
}

struct EarthquakeFeedRow: View {
    let event: EarthquakeFeed.Event
    let onSimulate: () -> Void

    private var magnitudeColor: Color {
        switch event.magnitude {
        case ..<4: Theme.Palette.textSecondary
        case 4..<5.5: Theme.Palette.accent
        case 5.5..<7: Theme.Palette.verdictAmber
        default: Theme.Palette.verdictRed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: Theme.Metrics.spacing) {
                VStack(spacing: 1) {
                    Text(String(format: "%.1f", event.magnitude))
                        .font(Theme.Typography.numericLarge)
                        .foregroundStyle(magnitudeColor)
                    Text("M")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .frame(width: 52)

                VStack(alignment: .leading, spacing: 3) {
                    Text(event.place)
                        .font(Theme.Typography.callout.weight(.medium))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Label(String(format: "%.0f km deep", event.depthKm),
                              systemImage: "arrow.down.to.line")
                        if let distance = event.distanceFromUserKm {
                            Label(String(format: "%.0f km away", distance),
                                  systemImage: "location")
                        }
                    }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)

                    Text(event.time.formatted(date: .abbreviated, time: .shortened))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }

                Spacer(minLength: 0)
            }

            if let intensity = event.expectedIntensityHere {
                HStack(spacing: 5) {
                    Image(systemName: "waveform")
                        .font(.system(size: 10))
                    Text("Would have felt like intensity \(intensity.roman) here — "
                         + intensity.shortLabel.lowercased())
                        .font(Theme.Typography.caption)
                }
                .foregroundStyle(Theme.Palette.textSecondary)
            }

            Button(action: onSimulate) {
                Label("Shake my building with it", systemImage: "cube.transparent")
                    .font(Theme.Typography.caption.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .instrumentPanel()
        .accessibilityElement(children: .combine)
    }
}

/// Fetches the live feed, and falls back cleanly.
@MainActor
final class EarthquakeFeed: ObservableObject {

    struct Event: Identifiable {
        let id: String
        let magnitude: Double
        let place: String
        let time: Date
        let depthKm: Double
        let latitude: Double
        let longitude: Double
        var distanceFromUserKm: Double?
        var expectedIntensityHere: MercalliIntensity?
    }

    @Published private(set) var events: [Event] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isUsingBundledData = false

    /// The USGS feed needs no key, which is worth stating plainly because a
    /// reader will assume otherwise.
    private let feedURL = URL(string:
        "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/2.5_day.geojson")!

    func load(fallback: [EarthquakeRecord], userLocation: GeoPoint? = nil) async {
        isLoading = true
        defer { isLoading = false }

        do {
            var request = URLRequest(url: feedURL)
            request.timeoutInterval = 8
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode(USGSResponse.self, from: data)
            events = decoded.features.compactMap { feature in
                guard let magnitude = feature.properties.mag,
                      feature.geometry.coordinates.count >= 3 else { return nil }
                let longitude = feature.geometry.coordinates[0]
                let latitude = feature.geometry.coordinates[1]
                let depth = feature.geometry.coordinates[2]

                var event = Event(
                    id: feature.id, magnitude: magnitude,
                    place: feature.properties.place ?? "Unknown location",
                    time: Date(timeIntervalSince1970: feature.properties.time / 1000),
                    depthKm: depth, latitude: latitude, longitude: longitude)

                if let userLocation {
                    let distance = Geodesy.distanceKm(
                        userLocation, GeoPoint(latitude: latitude, longitude: longitude))
                    event.distanceFromUserKm = distance
                    event.expectedIntensityHere = AttenuationModel.predict(
                        magnitude: magnitude, distanceKm: distance, depthKm: depth).mercalli
                }
                return event
            }
            .sorted { $0.time > $1.time }
            isUsingBundledData = false
        } catch {
            // Offline, rate limited, or the feed changed shape. Any of those is
            // a reason to show the bundled library rather than nothing.
            events = fallback.map { record in
                Event(id: record.id.uuidString, magnitude: record.magnitude,
                      place: "\(record.name) (\(record.year))",
                      time: Calendar.current.date(from: DateComponents(year: record.year)) ?? Date(),
                      depthKm: record.depthKm,
                      latitude: record.latitude, longitude: record.longitude)
            }
            isUsingBundledData = true
        }
    }

    private struct USGSResponse: Decodable {
        let features: [Feature]
        struct Feature: Decodable {
            let id: String
            let properties: Properties
            let geometry: Geometry
        }
        struct Properties: Decodable {
            let mag: Double?
            let place: String?
            let time: Double
        }
        struct Geometry: Decodable {
            let coordinates: [Double]
        }
    }
}

#Preview {
    NavigationStack {
        GlobalFeedScreen()
            .seismicBackground()
            .navigationTitle("Feed")
    }
    .environmentObject(AppEnvironment.preview())
    .preferredColorScheme(.dark)
}
