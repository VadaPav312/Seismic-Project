import SwiftUI
import MapKit
import SeismicCore
import SeismicGeo
import SeismicData

/// The community picture.
///
/// Every published verdict in the neighbourhood, clustered so it stays legible,
/// filterable by how much it should be trusted, and replayable over time so the
/// hours after an event can be watched unfolding.
struct CommunityMapScreen: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var position: MapCameraPosition = .automatic
    @State private var filters = MapFilters()
    @State private var showingFilters = false
    @State private var selected: CommunityTag?
    @State private var timeSliderHours: Double = 72

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
        env.tags.filter { tag in
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
                ForEach(visibleTags) { tag in
                    Annotation(tag.buildingLabel,
                               coordinate: CLLocationCoordinate2D(latitude: tag.latitude,
                                                                  longitude: tag.longitude)) {
                        TagMarker(tag: tag) { selected = tag }
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
    .environmentObject(AppEnvironment.preview())
    .preferredColorScheme(.dark)
}
