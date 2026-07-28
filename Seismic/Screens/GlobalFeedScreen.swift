import SwiftUI
import SeismicCore
import SeismicGeo
import SeismicData
import SeismicServices

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
                Picker("Window", selection: $feed.window) {
                    ForEach(EarthquakeFeedService.Window.allCases) { window in
                        Text(window.label).tag(window)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: feed.window) { _, _ in Task { await reload() } }

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
                            action: { Task { await reload() } })
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
        .refreshable { await reload() }
        .task { await reload() }
    }

    /// The reference point is the selected building, not the device's location:
    /// what a user wants to know is what an earthquake did to *their building*,
    /// which is usually somewhere they are not standing at the time.
    private func reload() async {
        let reference = env.selectedBuilding.map {
            GeoPoint(latitude: $0.latitude, longitude: $0.longitude)
        }
        await feed.load(fallback: env.earthquakes, userLocation: reference)
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

/// Turns the fetched feed into rows, and works out what each event would have
/// meant *here*.
///
/// The fetching itself belongs to `EarthquakeFeedService`, which is tested,
/// cached and shared; what this adds is the part that is specific to the person
/// holding the phone — how far away it was, and what intensity that implies at
/// their building.
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
    @Published private(set) var origin: ResultOrigin = .live
    @Published private(set) var note: String?
    @Published var window: EarthquakeFeedService.Window = .pastDay

    private let service = EarthquakeFeedService()

    func load(fallback: [EarthquakeRecord], userLocation: GeoPoint? = nil) async {
        isLoading = true
        defer { isLoading = false }

        let result = await service.recent(window)
        origin = result.origin
        note = result.note
        isUsingBundledData = result.origin == .seeded

        events = result.value.map { record in
            var event = Event(
                id: record.id.uuidString,
                magnitude: record.magnitude,
                place: isUsingBundledData ? "\(record.name) (\(record.year))" : record.name,
                time: record.originTime
                    ?? Calendar.current.date(from: DateComponents(year: record.year))
                    ?? Date(),
                depthKm: record.depthKm,
                latitude: record.latitude,
                longitude: record.longitude)

            // The number that actually matters to somebody reading this list is
            // not the magnitude — it is what that magnitude did where they are.
            if let userLocation, record.latitude != 0 || record.longitude != 0 {
                let distance = Geodesy.distanceKm(
                    userLocation, GeoPoint(latitude: record.latitude, longitude: record.longitude))
                event.distanceFromUserKm = distance
                event.expectedIntensityHere = AttenuationModel.predict(
                    magnitude: record.magnitude, distanceKm: distance,
                    depthKm: record.depthKm).mercalli
            }
            return event
        }
        .sorted { $0.magnitude > $1.magnitude }
    }
}

#Preview {
    NavigationStack {
        GlobalFeedScreen()
            .seismicBackground()
            .navigationTitle("Feed")
    }
    .previewEnvironment()
}
