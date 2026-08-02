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

    /// What the pins are showing.
    ///
    /// Two genuinely different questions get asked of the same map — "is my
    /// street safe right now" and "what does this place get" — and they want
    /// different data at different scales. Drawing both at once produces a mess
    /// in which neither is legible, so they are layers.
    @State private var layer: MapLayer = .community

    // Where the camera is, kept so a query can be made about it.
    @State private var centre = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    @State private var radiusKm: Double = 25

    // Seismic history: for the visible region, and for a tapped point.
    @State private var regionHistory: RegionalHistory?
    @State private var isLoadingHistory = false
    @State private var inspected: InspectedPlace?

    // Place search, worldwide.
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false

    @State private var isPublishing = false
    @State private var publishNote: String?

    /// How far back the history goes. Ten years is long enough to contain the
    /// events that define a place and short enough that the catalogue query
    /// stays fast.
    private let historyYears: Double = 10

    enum MapLayer: String, CaseIterable, Identifiable {
        case community, earthquakes
        var id: String { rawValue }

        var label: String {
            switch self {
            case .community: "Buildings"
            case .earthquakes: "Earthquakes"
            }
        }

        var systemImage: String {
            switch self {
            case .community: "building.2"
            case .earthquakes: "waveform.path.ecg"
            }
        }
    }

    /// A point somebody asked about, and the answer.
    struct InspectedPlace: Identifiable {
        var id = UUID()
        var coordinate: CLLocationCoordinate2D
        var name: String
        var history: RegionalHistory?
        var note: String?
        var nearbyTags: [CommunityTag]
    }

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
            // MapReader is what makes "tap anywhere" possible: it hands back a
            // proxy that converts a point in the view to a coordinate on the
            // Earth, so the question can be asked about somewhere nobody has
            // put a pin.
            MapReader { proxy in
                Map(position: $position) {
                    if layer == .community {
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
                                        // Zooming in is what a cluster is
                                        // *for*: it splits as the cell shrinks.
                                        zoom(to: CLLocationCoordinate2D(
                                            latitude: cluster.centre.latitude,
                                            longitude: cluster.centre.longitude),
                                             degrees: 0.012)
                                    }
                                }
                            }
                        }
                    } else {
                        ForEach(regionHistory?.events ?? []) { event in
                            Annotation(event.place, coordinate: CLLocationCoordinate2D(
                                latitude: event.record.latitude,
                                longitude: event.record.longitude)) {
                                EpicentreMarker(event: event) {
                                    inspect(CLLocationCoordinate2D(
                                        latitude: event.record.latitude,
                                        longitude: event.record.longitude),
                                            named: event.place)
                                }
                            }
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                .onTapGesture { screenPoint in
                    guard let coordinate = proxy.convert(screenPoint, from: .local) else { return }
                    inspect(coordinate, named: "")
                }
            }

            VStack(spacing: Theme.Metrics.spacing) {
                searchBar
                layerPicker
                if layer == .community { summaryBar } else { seismicityBar }
                Spacer()
                if layer == .community { timeSlider } else { historyHint }
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
                .disabled(layer != .community)
            }
            // Reading everybody's reports without ever being able to add your
            // own makes this a broadcast rather than a network — and the map's
            // whole premise is that after an earthquake there are not enough
            // engineers, so what people can establish about their own buildings
            // is the only thing that scales.
            ToolbarItem(placement: .topBarTrailing) {
                Button { publishMyVerdict() } label: {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
                .accessibilityLabel("Publish my building's verdict")
                .disabled(env.latestAssessment == nil || isPublishing)
            }
        }
        .alert("Published", isPresented: Binding(
            get: { publishNote != nil }, set: { if !$0 { publishNote = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(publishNote ?? "")
        }
        .sheet(isPresented: $showingFilters) {
            MapFilterSheet(filters: $filters)
        }
        .sheet(item: $selected) { tag in
            TagDetailSheet(tag: tag)
        }
        .sheet(item: $inspected) { place in
            PlaceHistorySheet(place: place, years: historyYears)
        }
        .onAppear { centreOnBuilding() }
        .onMapCameraChange(frequency: .onEnd) { context in
            let span = context.region.span.latitudeDelta * 111_320
            visibleSpanMetres = max(span, 100)
            centre = context.region.center
            // Half the diagonal of what is on screen, so the query covers what
            // the user can actually see and nothing much beyond it.
            radiusKm = max(span / 2000, 5)
            if layer == .earthquakes { Task { await fetchRegionHistory() } }
        }
        .onChange(of: layer) { _, newLayer in
            guard newLayer == .earthquakes else { return }
            Task { await fetchRegionHistory() }
        }
        .task { await fetchCommunityTags() }
        .refreshable {
            await fetchCommunityTags()
            if layer == .earthquakes { await fetchRegionHistory() }
        }
        .overlay(alignment: .bottom) {
            if let remoteNote, layer == .community {
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

    // MARK: Layers, search and inspection

    private var layerPicker: some View {
        Picker("Layer", selection: $layer) {
            ForEach(MapLayer.allCases) { option in
                Label(option.label, systemImage: option.systemImage).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .background(.ultraThinMaterial, in: Capsule())
    }

    /// Worldwide place search.
    ///
    /// `MKLocalSearch` with no region hint searches the planet, which is the
    /// point: the map is not about one city, and typing "Kathmandu" should go
    /// to Kathmandu whether or not the camera is anywhere near it.
    private var searchBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.Palette.textTertiary)
                TextField("Search anywhere in the world", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.callout)
                    .submitLabel(.search)
                    .onSubmit { Task { await runSearch() } }
                if isSearching {
                    ProgressView().controlSize(.small)
                } else if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)

            if !searchResults.isEmpty {
                Divider().overlay(Theme.Palette.hairline)
                ForEach(searchResults.prefix(5), id: \.self) { item in
                    Button {
                        go(to: item)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name ?? "Unnamed")
                                    .font(Theme.Typography.callout)
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                if let subtitle = item.placemark.title {
                                    Text(subtitle)
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(Theme.Palette.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius,
                                         style: .continuous))
    }

    private func runSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        // Cities, countries and landmarks as well as businesses. Without this
        // the search is a shop finder.
        request.resultTypes = [.address, .pointOfInterest]
        searchResults = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []

        // One unambiguous answer goes straight there rather than making
        // somebody tap a list of one.
        if searchResults.count == 1, let only = searchResults.first { go(to: only) }
    }

    private func go(to item: MKMapItem) {
        let coordinate = item.placemark.coordinate
        searchResults = []
        searchText = item.name ?? searchText
        zoom(to: coordinate, degrees: 0.35)
        centre = coordinate
        radiusKm = 40
        inspect(coordinate, named: item.name ?? "")
        if layer == .earthquakes { Task { await fetchRegionHistory() } }
    }

    private func zoom(to coordinate: CLLocationCoordinate2D, degrees: Double) {
        withAnimation(Theme.Motion.standard) {
            position = .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: degrees, longitudeDelta: degrees)))
        }
    }

    /// Asks the catalogue what has happened at a point, and opens the answer.
    ///
    /// Named separately from the region fetch because they answer different
    /// questions: this one is about a place somebody pointed at, at a fixed
    /// radius, so the reply does not change meaning with the zoom level.
    private func inspect(_ coordinate: CLLocationCoordinate2D, named name: String) {
        Haptics.shared.play(.selection)
        let id = UUID()
        inspected = InspectedPlace(id: id, coordinate: coordinate,
                                   name: name.isEmpty ? "This place" : name,
                                   history: nil, note: nil,
                                   nearbyTags: tagsNear(coordinate))

        Task {
            let result = await services.history(latitude: coordinate.latitude,
                                                longitude: coordinate.longitude,
                                                radiusKm: 150, years: historyYears)
            // Only if the user has not already tapped somewhere else. A slow
            // answer arriving after they moved on would replace the sheet's
            // contents with a different place's history under the same title.
            guard inspected?.id == id else { return }
            inspected?.history = result.value
            inspected?.note = result.note

            if name.isEmpty { await nameIt(id: id, at: coordinate) }
        }
    }

    /// Reverse geocodes the tapped point so the sheet says where it is.
    private func nameIt(id: UUID, at coordinate: CLLocationCoordinate2D) async {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first,
              inspected?.id == id else { return }
        inspected?.name = [mark.locality, mark.administrativeArea, mark.country]
            .compactMap { $0 }.first ?? "This place"
    }

    private func tagsNear(_ coordinate: CLLocationCoordinate2D) -> [CommunityTag] {
        let all = (env.tags + remoteTags)
        return all.filter { tag in
            let dx = (tag.longitude - coordinate.longitude) * 111.0
                * cos(coordinate.latitude * .pi / 180)
            let dy = (tag.latitude - coordinate.latitude) * 111.0
            return (dx * dx + dy * dy).squareRoot() < 5
        }
        .sorted { $0.consensusScore > $1.consensusScore }
    }

    /// Puts this building's verdict on the neighbourhood map.
    ///
    /// The position is the published one rather than the true one: a tag
    /// inherits the building's privacy setting, and an exact pin on a damaged
    /// house is an advertisement to a burglar. The tier comes from the
    /// assessment rather than from the person — a verdict backed by a sensor
    /// carries more weight than one backed by a look, and the map says which
    /// it is.
    private func publishMyVerdict() {
        guard let building = env.selectedBuilding, let assessment = env.latestAssessment
        else { return }
        isPublishing = true

        let published = LocationPrivacy.approximate(
            GeoPoint(latitude: building.latitude, longitude: building.longitude),
            precision: building.privacy == .exact ? 9 : 7)

        let tag = CommunityTag(
            buildingID: building.id,
            verdict: assessment.verdict,
            latitude: published.latitude,
            longitude: published.longitude,
            buildingLabel: building.name,
            tier: assessment.assessorTier,
            evidenceSummary: assessment.verdict.plainMeaning,
            notes: assessment.narrative)

        env.store.upsert(tag)
        env.refresh()
        Haptics.shared.play(.assessmentComplete)

        Task {
            let result = await services.publish(tag)
            isPublishing = false
            publishNote = result.value
                ? "\(building.name) is on the map as \(assessment.verdict.placard). It expires "
                    + "in three days, because a verdict from last week says nothing about a "
                    + "building that has been through aftershocks since."
                : (result.note ?? "It is saved on this device.")
            await fetchCommunityTags()
        }
    }

    private func fetchRegionHistory() async {
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        let result = await services.history(latitude: centre.latitude,
                                            longitude: centre.longitude,
                                            radiusKm: min(radiusKm, 2_000),
                                            years: historyYears)
        regionHistory = result.value
    }

    /// The earthquake layer's counterpart to the verdict summary bar.
    private var seismicityBar: some View {
        HStack(spacing: 0) {
            statistic("Events", regionHistory.map { "\($0.events.count)" } ?? "—")
            statistic("Largest", regionHistory?.largest.map {
                String(format: "M%.1f", $0.magnitude)
            } ?? "—")
            statistic("Damaging", regionHistory.map { "\($0.damaging.count)" } ?? "—")
            statistic("Per year", regionHistory.map {
                String(format: "%.1f", $0.annualRateAboveFive)
            } ?? "—")
        }
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(alignment: .trailing) {
            if isLoadingHistory {
                ProgressView().controlSize(.small).padding(.trailing, 12)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Seismic history of the visible area over "
                            + "\(Int(historyYears)) years")
    }

    private func statistic(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(Theme.Typography.numeric)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var historyHint: some View {
        Text("Tap anywhere for that place's earthquake history over the last "
             + "\(Int(historyYears)) years, what the largest one was, and which of them "
             + "damaged buildings.")
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius,
                                             style: .continuous))
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

/// An epicentre.
///
/// Sized by magnitude and coloured by what the USGS estimated it did, so a
/// glance separates the thousands of events that shook nothing from the handful
/// that damaged buildings — which is the only distinction that matters when you
/// are asking what a place is like.
struct EpicentreMarker: View {
    let event: RegionalHistory.Event
    let action: () -> Void

    private var size: CGFloat {
        // Magnitude is logarithmic, so the marker is too — linear sizing makes
        // a magnitude 8 look barely larger than a 6, when it releases a
        // thousand times the energy.
        CGFloat(min(max(6 + (event.magnitude - 3) * 4.5, 7), 40))
    }

    private var tint: Color {
        switch event.impact {
        case .red: Theme.Palette.verdictRed
        case .orange: Color.orange
        case .yellow: Theme.Palette.verdictAmber
        case .green, .none: Theme.Palette.accent
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(tint.opacity(0.28)).frame(width: size, height: size)
                Circle().strokeBorder(tint, lineWidth: event.impact.damagedBuildings ? 2 : 1)
                    .frame(width: size, height: size)
                if event.magnitude >= 6 {
                    Text(String(format: "%.0f", event.magnitude))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(format: "Magnitude %.1f at %@. %@",
                                   event.magnitude, event.place, event.impact.meaning))
    }
}

/// What has happened at a place, and what it did.
struct PlaceHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let place: CommunityMapScreen.InspectedPlace
    let years: Double

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.spacingLoose) {
                    if let history = place.history {
                        summary(history)
                        if !history.damaging.isEmpty { damagingSection(history) }
                        if !history.events.isEmpty { largestSection(history) }
                    } else {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Asking the USGS catalogue what has happened here.")
                                .font(Theme.Typography.callout)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .instrumentPanel()
                    }

                    if !place.nearbyTags.isEmpty { neighbours }

                    if let note = place.note {
                        InlineNotice(level: .info, title: "About this answer", message: note)
                    }

                    Text(String(format: "%.4f, %.4f. History covers a 150 km radius over "
                                + "%d years, from the USGS catalogue — the same source used "
                                + "everywhere on Earth, so this works for anywhere you tap.",
                                place.coordinate.latitude, place.coordinate.longitude,
                                Int(years)))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Metrics.screenPadding)
                .contentColumn()
            }
            .seismicBackground()
            .navigationTitle(place.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }

    private func summary(_ history: RegionalHistory) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("The last \(Int(years)) years", systemImage: "clock.arrow.circlepath")

            Text(history.narrative)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if !history.events.isEmpty {
                Divider().overlay(Theme.Palette.hairline)
                ReadoutGrid(readouts: [
                    Readout(label: "Events", value: "\(history.events.count)", size: .large),
                    Readout(label: "Largest",
                            value: String(format: "%.1f", history.largest?.magnitude ?? 0),
                            unit: "M", tint: Theme.Palette.accent, size: .large),
                    Readout(label: "Damaging", value: "\(history.damaging.count)"),
                    Readout(label: "Above M5 a year",
                            value: String(format: "%.1f", history.annualRateAboveFive)),
                ], columns: 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    /// The events that actually damaged buildings.
    ///
    /// The USGS does not publish collapse counts and neither does anybody else
    /// for free, so this reports what it does publish — PAGER, its own
    /// model-based estimate of an earthquake's losses — and says in words what
    /// each level means rather than implying a precision that is not there.
    private func damagingSection(_ history: RegionalHistory) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Earthquakes that damaged buildings",
                         systemImage: "exclamationmark.triangle")

            ForEach(history.damaging.prefix(6)) { event in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(String(format: "M%.1f", event.magnitude))
                            .font(Theme.Typography.numeric)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text(event.place)
                            .font(Theme.Typography.callout)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(event.date, format: .dateTime.year())
                            .font(Theme.Typography.numericSmall)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    Text(event.impact.meaning)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.verdictAmber)
                        .fixedSize(horizontal: false, vertical: true)
                    if let shaking = event.shaking {
                        Text(String(format: "Peak shaking intensity %.0f on the Mercalli scale.",
                                    shaking))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                .padding(.vertical, 3)
            }

            Text("Damage levels are the USGS's own loss estimates, published with each event. "
                 + "No free source counts individual collapsed buildings, so none is claimed "
                 + "here.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private func largestSection(_ history: RegionalHistory) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Largest recorded", systemImage: "chart.bar")
            ForEach(history.events.sorted { $0.magnitude > $1.magnitude }.prefix(8)) { event in
                HStack {
                    Text(String(format: "M%.1f", event.magnitude))
                        .font(Theme.Typography.numericSmall)
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(width: 48, alignment: .leading)
                    Text(event.place)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(event.date, format: .dateTime.year())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    /// What people have said about the buildings right there.
    private var neighbours: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Buildings reported within 5 km", systemImage: "building.2")
            ForEach(place.nearbyTags.prefix(8)) { tag in
                HStack(spacing: 8) {
                    Image(systemName: tag.verdict.systemImage)
                        .foregroundStyle(tag.verdict.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tag.buildingLabel)
                            .font(Theme.Typography.callout)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                        Text("\(tag.tier.label) · \(tag.ageDescription)")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Text(tag.verdict.shortLabel)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(tag.verdict.color)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }
}

struct TagDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var services: ServiceHub
    let tag: CommunityTag

    @State private var myVote: Bool?
    @State private var isVoting = false
    @State private var voteNote: String?

    /// Records the vote locally, then tries to share it.
    ///
    /// Local first, deliberately. The count on screen has to move the instant
    /// somebody presses the button whether or not there is a network — the
    /// alternative is a button that appears broken in exactly the conditions
    /// this app exists for, which are the hours after an earthquake when the
    /// network is the first thing to go.
    private func vote(agree: Bool) {
        guard myVote != agree else { return }
        Haptics.shared.play(.selection)
        isVoting = true

        var updated = tag
        // Changing your mind moves the vote rather than adding a second one.
        if myVote == true { updated.agreementCount = max(updated.agreementCount - 1, 0) }
        if myVote == false { updated.disputeCount = max(updated.disputeCount - 1, 0) }
        if agree { updated.agreementCount += 1 } else { updated.disputeCount += 1 }
        env.store.upsert(updated)
        env.refresh()
        myVote = agree

        Task {
            let result = await services.vote(onTag: tag.id, agree: agree)
            isVoting = false
            voteNote = result.value ? nil : result.note
        }
    }

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

                    // These two buttons used to play a haptic and nothing else,
                    // which is worse than not having them: somebody who
                    // disputes a green tag on a building they can see is
                    // cracked has every reason to believe they have warned
                    // their neighbours.
                    HStack(spacing: Theme.Metrics.spacing) {
                        Button {
                            vote(agree: true)
                        } label: {
                            Label(myVote == true ? "You agree" : "I agree",
                                  systemImage: myVote == true ? "hand.thumbsup.fill"
                                                              : "hand.thumbsup")
                                .frame(maxWidth: .infinity)
                                .frame(height: Theme.Metrics.minimumTapTarget)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(isVoting)

                        Button {
                            vote(agree: false)
                        } label: {
                            Label(myVote == false ? "You disagree" : "I disagree",
                                  systemImage: myVote == false ? "hand.thumbsdown.fill"
                                                               : "hand.thumbsdown")
                                .frame(maxWidth: .infinity)
                                .frame(height: Theme.Metrics.minimumTapTarget)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(isVoting)
                    }

                    if let voteNote {
                        Text(voteNote)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
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
