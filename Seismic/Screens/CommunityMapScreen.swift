import SwiftUI
import MapKit
import SeismicCore
import SeismicGeo
import SeismicData
import SeismicServices

/// The community picture.
///
/// Every published verdict in the neighbourhood, clustered so it stays legible,
/// filterable by how much it should be trusted, and replayable over time so the
/// hours after an event can be watched unfolding.
struct CommunityMapScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var services: ServiceHub

    /// Tags fetched from the community service, kept separate from the local
    /// ones so the map can say which is which rather than blending them.
    @State private var remoteTags: [CommunityTag] = []
    @State private var remoteNote: String?
    @State private var isFetching = false

    @State private var position: MapCameraPosition = .automatic
    @State private var filters = MapFilters()
    @State private var showingFilters = false
    @State private var selected: CommunityTag?
    @State private var timeSliderHours: Double = 72
    /// Roughly how wide the visible map is, kept so the cluster cell size can
    /// follow the zoom rather than being fixed.
    @State private var visibleSpanMetres: Double = 5_000

    struct MapFilters {
        var verdicts: Set<SafetyVerdict> = Set(SafetyVerdict.allCases)
        var minimumTier: VerificationTier = .unverified
        var sensorVerifiedOnly = false
        var includeExpired = false

        var isDefault: Bool {
            verdicts.count == SafetyVerdict.allCases.count
                && minimumTier == .unverified && !sensorVerifiedOnly && !includeExpired
        }
    }

    private var visibleTags: [CommunityTag] {
        var seen = Set<UUID>()
        let combined = (env.tags + remoteTags).filter { seen.insert($0.id).inserted }
        return combined.filter { tag in
            guard filters.verdicts.contains(tag.verdict) else { return false }
            guard tag.tier >= filters.minimumTier else { return false }
            if filters.sensorVerifiedOnly && tag.tier == .unverified { return false }
            if !filters.includeExpired && tag.isExpired { return false }
            let age = Date().timeIntervalSince(tag.postedAt) / 3600
            return age <= timeSliderHours
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $position) {
                ForEach(clusters) { cluster in
                    Annotation(cluster.isSingle
                               ? (cluster.items.first?.buildingLabel ?? "")
                               : "\(cluster.count) buildings",
                               coordinate: CLLocationCoordinate2D(
                                latitude: cluster.centre.latitude,
                                longitude: cluster.centre.longitude)) {
                        if cluster.isSingle, let tag = cluster.items.first {
                            TagMarker(tag: tag) { selected = tag }
                        } else {
                            ClusterMarker(cluster: cluster) {
                                // Zooming in is what a cluster is *for*: it
                                // splits as the cell shrinks.
                                withAnimation(Theme.Motion.standard) {
                                    position = .region(MKCoordinateRegion(
                                        center: CLLocationCoordinate2D(
                                            latitude: cluster.centre.latitude,
                                            longitude: cluster.centre.longitude),
                                        span: MKCoordinateSpan(latitudeDelta: 0.012,
                                                               longitudeDelta: 0.012)))
                                }
                            }
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))

            VStack(spacing: Theme.Metrics.spacing) {
                summaryBar
                Spacer()
                timeSlider
            }
            .padding(Theme.Metrics.screenPadding)
            .contentColumn()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingFilters = true } label: {
                    Image(systemName: filters.isDefault
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel("Filters")
            }
        }
        .sheet(isPresented: $showingFilters) {
            MapFilterSheet(filters: $filters)
        }
        .sheet(item: $selected) { tag in
            TagDetailSheet(tag: tag)
        }
        .onAppear { centreOnBuilding() }
        .onMapCameraChange(frequency: .onEnd) { context in
            let span = context.region.span.latitudeDelta * 111_320
            visibleSpanMetres = max(span, 100)
        }
        .task { await fetchCommunityTags() }
        .refreshable { await fetchCommunityTags() }
        .overlay(alignment: .bottom) {
            if let remoteNote {
                Text(remoteNote)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall))
                    .padding(Theme.Metrics.screenPadding)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Pulls in what other people have published nearby.
    ///
    /// With no community service configured this returns nothing and says so,
    /// which is the honest outcome: an empty map that claims to be live would
    /// read as "nobody near me has any damage".
    private func fetchCommunityTags() async {
        guard let building = env.selectedBuilding else { return }
        isFetching = true
        let result = await services.cloud.nearbyTags(latitude: building.latitude,
                                                     longitude: building.longitude,
                                                     radiusKm: 10)
        remoteTags = result.value
        remoteNote = result.note
        isFetching = false
    }

    /// Grid clustering in screen space, with the cell size following the zoom.
    ///
    /// Without it a street after a real earthquake is an unreadable pile of
    /// overlapping pins — and the pile hides exactly the thing somebody is
    /// looking for, which is whether any of them are red.
    private var clusters: [MapCluster<CommunityTag>] {
        let cellSize = MarkerClustering.cellSize(forVisibleSpanMetres: visibleSpanMetres)
        return MarkerClustering.cluster(
            visibleTags.map { tag in
                // Published position, not true position: a tag inherits the
                // building's privacy setting, and an exact pin on a damaged
                // house is an advertisement to a burglar.
                let point = LocationPrivacy.approximate(
                    GeoPoint(latitude: tag.latitude, longitude: tag.longitude),
                    precision: tag.tier == .professional ? 9 : 7)
                return (item: tag, point: point)
            },
            cellSizeMetres: cellSize)
    }

    private func centreOnBuilding() {
        guard let building = env.selectedBuilding else { return }
        position = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: building.latitude,
                                           longitude: building.longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.045, longitudeDelta: 0.045)))
    }

    private var summaryBar: some View {
        let counts = Dictionary(grouping: visibleTags, by: \.verdict).mapValues(\.count)
        return HStack(spacing: 0) {
            ForEach(SafetyVerdict.allCases) { verdict in
                VStack(spacing: 2) {
                    HStack(spacing: 3) {
                        Image(systemName: verdict.systemImage)
                            .font(.system(size: 10, weight: .bold))
                        Text("\(counts[verdict] ?? 0)")
                            .font(Theme.Typography.numeric)
                    }
                    .foregroundStyle(verdict.color)
                    Text(verdict.shortLabel)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Neighbourhood summary")
    }

    /// The time slider: watching the picture fill in over the hours after an
    /// event is the single most compelling thing about a community map.
    private var timeSlider: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Showing reports from the last")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Text(timeSliderHours >= 71
                     ? "3 days"
                     : (timeSliderHours < 1.5 ? "1 hour" : "\(Int(timeSliderHours)) hours"))
                    .font(Theme.Typography.numericSmall)
                    .foregroundStyle(Theme.Palette.accent)
            }
            Slider(value: $timeSliderHours, in: 1...72, step: 1)
                .tint(Theme.Palette.accent)
        }
        .padding(12)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius,
                                         style: .continuous))
    }
}

/// A map marker. Shape as well as colour, so it survives colour blindness and
/// the sun.
struct TagMarker: View {
    let tag: CommunityTag
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(tag.verdict.color)
                    .frame(width: tag.tier == .professional ? 26 : 20,
                           height: tag.tier == .professional ? 26 : 20)
                Image(systemName: tag.verdict.systemImage)
                    .font(.system(size: tag.tier == .professional ? 12 : 9, weight: .bold))
                    .foregroundStyle(.black.opacity(0.75))

                // Sensor-verified and professional tags are visually distinct,
                // because the whole point of the tiers is that they carry
                // different weight.
                if tag.tier != .unverified {
                    Circle()
                        .strokeBorder(.white.opacity(0.9),
                                      style: StrokeStyle(lineWidth: 2,
                                                         dash: tag.tier == .sensorVerified
                                                            ? [3, 2] : []))
                        .frame(width: tag.tier == .professional ? 30 : 24,
                               height: tag.tier == .professional ? 30 : 24)
                }
            }
            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
        }
        .accessibilityLabel("\(tag.verdict.placard) at \(tag.buildingLabel), "
                            + "\(tag.tier.label), \(tag.ageDescription)")
    }
}

struct TagDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let tag: CommunityTag

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.spacingLoose) {
                    VerdictPlacard(verdict: tag.verdict, compact: true)

                    VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
                        SectionLabel("Evidence")
                        Text(tag.evidenceSummary)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        if !tag.notes.isEmpty {
                            Divider().background(Theme.Palette.hairline)
                            Text(tag.notes)
                                .font(Theme.Typography.callout)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .instrumentPanel()

                    VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
                        SectionLabel("Who reported this")

                        HStack {
                            Image(systemName: tag.tier.systemImage)
                                .foregroundStyle(tag.tier == .professional
                                                 ? Theme.Palette.accent
                                                 : Theme.Palette.textSecondary)
                            Text(tag.tier.label)
                                .font(Theme.Typography.callout.weight(.medium))
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Spacer()
                            Text(tag.ageDescription)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }

                        Text(tierExplanation)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: Theme.Metrics.spacingLoose) {
                            Label("\(tag.agreementCount) agree", systemImage: "hand.thumbsup")
                            Label("\(tag.disputeCount) dispute", systemImage: "hand.thumbsdown")
                        }
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .instrumentPanel()

                    if tag.isExpired {
                        InlineNotice(level: .warning, title: "This report has expired",
                                     message: "It was published \(tag.ageDescription) and may no "
                                        + "longer describe the building's condition, especially "
                                        + "if there have been aftershocks since.")
                    }

                    HStack(spacing: Theme.Metrics.spacing) {
                        Button {
                            Haptics.shared.play(.selection)
                        } label: {
                            Label("I agree", systemImage: "hand.thumbsup")
                                .frame(maxWidth: .infinity)
                                .frame(height: Theme.Metrics.minimumTapTarget)
                        }
                        .buttonStyle(SecondaryButtonStyle())

                        Button {
                            Haptics.shared.play(.selection)
                        } label: {
                            Label("I disagree", systemImage: "hand.thumbsdown")
                                .frame(maxWidth: .infinity)
                                .frame(height: Theme.Metrics.minimumTapTarget)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(Theme.Metrics.screenPadding)
            }
            .seismicBackground()
            .navigationTitle(tag.buildingLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var tierExplanation: String {
        switch tag.tier {
        case .professional:
            "A reviewed structural engineer or official inspector. Their assessment supersedes "
                + "community reports for the same building."
        case .sensorVerified:
            "Posted by somebody with an instrumented building, so the verdict is backed by "
                + "measurements rather than only by eye."
        case .unverified:
            "A community report. Valuable, but based on what somebody could see rather than on "
                + "instrumentation."
        }
    }
}

struct MapFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filters: CommunityMapScreen.MapFilters

    var body: some View {
        NavigationStack {
            Form {
                Section("Verdict") {
                    ForEach(SafetyVerdict.allCases) { verdict in
                        Toggle(isOn: Binding(
                            get: { filters.verdicts.contains(verdict) },
                            set: { on in
                                if on { filters.verdicts.insert(verdict) }
                                else { filters.verdicts.remove(verdict) }
                            })) {
                            Label {
                                Text(verdict.placard.capitalized)
                            } icon: {
                                Image(systemName: verdict.systemImage)
                                    .foregroundStyle(verdict.color)
                            }
                        }
                    }
                }

                Section("Trust") {
                    Toggle("Sensor-verified only", isOn: $filters.sensorVerifiedOnly)
                    Picker("Minimum tier", selection: $filters.minimumTier) {
                        ForEach(VerificationTier.allCases, id: \.self) { tier in
                            Text(tier.label).tag(tier)
                        }
                    }
                }

                Section {
                    Toggle("Include expired reports", isOn: $filters.includeExpired)
                } footer: {
                    Text("Reports expire after three days. A green tag from last week says "
                         + "nothing about a building that has been through aftershocks since.")
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        CommunityMapScreen()
            .navigationTitle("Map")
    }
    .previewEnvironment()
}


/// A group of tags too close together to draw individually.
///
/// The count is secondary; the colour is the worst verdict in the group,
/// because "one of these eleven is red" is the fact somebody scanning a street
/// actually needs, and averaging it away would be the wrong summary.
struct ClusterMarker: View {
    let cluster: MapCluster<CommunityTag>
    let tap: () -> Void

    private var worst: SafetyVerdict {
        let order: [SafetyVerdict] = [.red, .needsInspection, .amber, .green]
        return order.first { verdict in cluster.items.contains { $0.verdict == verdict } }
            ?? .needsInspection
    }

    var body: some View {
        Button(action: tap) {
            ZStack {
                Circle()
                    .fill(worst.color.opacity(0.22))
                    .frame(width: 40, height: 40)
                Circle()
                    .strokeBorder(worst.color, lineWidth: 1.5)
                    .frame(width: 40, height: 40)
                Text("\(cluster.count)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(cluster.count) buildings, worst verdict \(worst.shortLabel). "
                            + "Double tap to zoom in.")
    }
}
