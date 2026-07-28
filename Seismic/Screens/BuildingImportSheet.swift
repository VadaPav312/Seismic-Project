import SwiftUI
import SeismicCore
import SeismicStructures
import SeismicData
import SeismicServices

/// Building search and import.
///
/// The pipeline, made visible: search, disambiguate, gather facts with their
/// sources, derive structural properties with their assumptions stated, and
/// assemble in 3D storey by storey.
///
/// With no search keys configured it runs against the bundled reference
/// library, and says so. The stages are identical either way — which is what
/// makes the offline path a genuine demonstration rather than a mock-up.
struct BuildingImportSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @EnvironmentObject private var services: ServiceHub
    @StateObject private var importer = BuildingImporter()
    @State private var query = ""
    @StateObject private var controller = BuildingSceneController()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.spacingLoose) {
                    searchField

                    switch importer.stage {
                    case .idle:
                        suggestions
                    case .searching:
                        MeaningfulProgress(title: "Searching",
                                           detail: importer.sourceDescription)
                    case .disambiguating(let candidates):
                        candidateList(candidates)
                    case .gathering(let candidate):
                        MeaningfulProgress(title: "Gathering facts about \(candidate.name)",
                                           detail: importer.sourceDescription,
                                           progress: importer.progress)
                    case .assembled(let building):
                        assembled(building)
                    case .failed(let message):
                        DesignedEmptyState(
                            icon: "exclamationmark.magnifyingglass",
                            title: "Nothing found",
                            message: message,
                            actionTitle: "Try the bundled library",
                            action: { Task { await importer.searchBundled(query: query,
                                                                          service: services.search,
                                                                          library: env.buildings) } })
                    }
                }
                .padding(Theme.Metrics.screenPadding)
            }
            .seismicBackground()
            .navigationTitle("Import a building")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.Palette.textTertiary)
                TextField("A building name, address or landmark", text: $query)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .onSubmit { search() }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall)
                .fill(Theme.Palette.surfaceRaised))

            if !env.secrets.has(.serperAPIKey) && !env.secrets.has(.tavilyAPIKey) {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle").font(.system(size: 10))
                    Text("No search key configured, so this searches the bundled reference "
                         + "library. Every other step is identical.")
                        .font(.system(size: 10))
                }
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Try one of these")
            ForEach(["Eiffel Tower", "Transamerica Pyramid", "Tokyo Skytree",
                     "Torre Latinoamericana", "Christchurch Cathedral"], id: \.self) { name in
                Button {
                    query = name
                    search()
                } label: {
                    HStack {
                        Image(systemName: "building.2")
                            .foregroundStyle(Theme.Palette.accent)
                        Text(name)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    .font(Theme.Typography.callout)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private func candidateList(_ candidates: [BuildingImporter.Candidate]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Which one?", trailing: "\(candidates.count) matches")
            Text("Several buildings match. Pick the one you meant — guessing would be worse "
                 + "than asking.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)

            ForEach(candidates) { candidate in
                Button {
                    Task { await importer.select(candidate, service: services.search) }
                } label: {
                    HStack(spacing: Theme.Metrics.spacing) {
                        ZStack {
                            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall)
                                .fill(Theme.Palette.surfaceRaised)
                                .frame(width: 48, height: 48)
                            Image(systemName: candidate.systemImage)
                                .foregroundStyle(Theme.Palette.accent)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.name)
                                .font(Theme.Typography.headline)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Text(candidate.location)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                            Text(candidate.description)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Text(String(format: "%.0f%%", candidate.relevance * 100))
                            .font(Theme.Typography.numericSmall)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    .instrumentPanel()
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func assembled(_ building: BuildingModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacingLoose) {
            BuildingSceneView(controller: controller)
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius,
                                            style: .continuous))
                .onAppear {
                    controller.build(building, animated: true)
                    // A faint tick per storey as it appears. Small, and it makes
                    // the assembly feel like something being made.
                    for index in 0..<building.storeyCount {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.09) {
                            Haptics.shared.play(.buildingStorey)
                        }
                    }
                }

            VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
                Text(building.name)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)

                if !importer.narration.isEmpty {
                    ForEach(Array(importer.narration.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "quote.opening")
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.Palette.accent)
                                .padding(.top, 3)
                            Text(line)
                                .font(Theme.Typography.callout)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .instrumentPanel()

            Button {
                env.store.upsert(building)
                env.refresh()
                env.selectedBuildingID = building.id
                Haptics.shared.play(.assessmentComplete)
                dismiss()
            } label: {
                Label("Add to my library", systemImage: "plus.circle")
                    .font(Theme.Typography.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.Metrics.minimumTapTarget)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func search() {
        guard !query.isEmpty else { return }
        Task { await importer.search(query: query, service: services.search,
                                     library: env.buildings) }
    }
}

/// Drives the import pipeline.
@MainActor
final class BuildingImporter: ObservableObject {

    struct Candidate: Identifiable {
        let id = UUID()
        let name: String
        let location: String
        let description: String
        let relevance: Double
        let systemImage: String
        /// What the retrieval layer returned.
        let remote: BuildingCandidate
        /// The bundled library's version of the same building, when there is
        /// one. Used to keep the richer description rather than overwrite it.
        let building: BuildingModel?
    }

    enum Stage {
        case idle
        case searching
        case disambiguating([Candidate])
        case gathering(Candidate)
        case assembled(BuildingModel)
        case failed(String)
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var sourceDescription = ""
    @Published private(set) var narration: [String] = []
    @Published private(set) var origin: ResultOrigin = .seeded

    /// Searches for real.
    ///
    /// The service tries Wikidata first — which needs no key, so this path is
    /// live on a fresh install — then the keyed providers, and finally the
    /// bundled library. Whichever answered is reported, because a user deciding
    /// whether to trust a height needs to know whether it came from a database
    /// or from a paragraph of prose.
    func search(query: String, service: BuildingSearchService,
                library: [BuildingModel]) async {
        stage = .searching
        sourceDescription = service.hasLivePath
            ? "Querying Wikidata and any configured search providers…"
            : "Searching the bundled reference library…"

        let result = await service.search(query)
        origin = result.origin
        sourceDescription = "\(result.origin.label) · \(result.provider)"

        let candidates = result.value.map { candidate in
            Candidate(name: candidate.name,
                      location: candidate.subtitle.isEmpty ? "Location unknown"
                                                           : candidate.subtitle,
                      description: String(candidate.snippet.prefix(110)),
                      relevance: candidate.confidence,
                      systemImage: "building.2",
                      remote: candidate,
                      building: library.first { $0.name == candidate.name })
        }

        guard !candidates.isEmpty else {
            stage = .failed(result.note
                            ?? "Nothing matched “\(query)”. Try a well-known building, or build "
                             + "one by hand from the library screen.")
            return
        }

        // One confident match is not a question worth asking.
        if candidates.count == 1 {
            await select(candidates[0], service: service)
        } else {
            stage = .disambiguating(candidates)
        }
    }

    func searchBundled(query: String, service: BuildingSearchService,
                       library: [BuildingModel]) async {
        await search(query: query, service: service, library: library)
    }

    /// Gathers the facts and assembles the model, narrating each step.
    ///
    /// The narration is the point of this screen. A building that appears
    /// instantly teaches nothing; one that says "height from Wikidata, footprint
    /// from OpenStreetMap, mass assumed at 500 kg per square metre" tells the
    /// user exactly how much of what they are looking at is known.
    func select(_ candidate: Candidate, service: BuildingSearchService) async {
        stage = .gathering(candidate)
        progress = 0
        narration = []

        progress = 0.25
        sourceDescription = "Gathering facts"
        let facts = await service.facts(for: candidate.remote)
        origin = facts.origin

        if facts.value.isEmpty {
            narration.append(facts.note ?? "Nothing was retrieved for this one.")
        } else {
            for (field, fact) in facts.value.facts.sorted(by: { $0.key < $1.key }) {
                narration.append("\(Self.label(for: field)): \(fact.value) "
                                 + "— \(fact.provenance.source.label)"
                                 + (fact.provenance.detail.map { ", \($0.lowercased())" } ?? ""))
            }
        }

        progress = 0.6
        sourceDescription = "Assembling the model"
        var building = service.compose(candidate: candidate.remote, facts: facts.value)

        // A bundled match keeps the library's richer description and any
        // structural detail the retrieval could not supply.
        if let known = candidate.building {
            building.notes = known.notes.isEmpty ? building.notes : known.notes
            building.system = facts.value["system"] == nil ? known.system : building.system
            building.soil = known.soil
            building.retrofit = facts.value["retrofit"] == nil ? known.retrofit : building.retrofit
            building.notableEvents = known.notableEvents
        }

        narration.append(geometryNarration(building))
        progress = 0.85
        narration.append(structuralNarration(building))

        building.id = UUID()
        building.isSandbox = false
        progress = 1
        stage = .assembled(building)
    }

    private static func label(for field: String) -> String {
        switch field {
        case "storeyCount": "Storeys"
        case "height": "Height"
        case "yearBuilt": "Year built"
        case "footprintArea": "Footprint area"
        case "footprint": "Footprint outline"
        case "material": "Material"
        case "system": "Structural system"
        case "architect": "Architect"
        case "address": "Address"
        case "latitude", "longitude": "Position"
        default: field.capitalizedFirstLetter
        }
    }

    private func factsNarration(_ building: BuildingModel) -> String {
        var parts: [String] = []
        parts.append("\(building.storeyCount) storeys, "
                     + String(format: "%.0f metres", building.height))
        if let year = building.yearBuilt { parts.append("built in \(year)") }
        parts.append(building.material.label.lowercased())
        let sourceLabel = building.provenance(for: "height").source.label
        return parts.joined(separator: ", ").capitalizedFirstLetter
            + ". Height and storey count from \(sourceLabel)."
    }

    private func geometryNarration(_ building: BuildingModel) -> String {
        "Footprint of about \(Int(building.footprintArea)) m² from the mapped outline. "
            + "No photorealistic tile coverage, so the massing is generated parametrically "
            + "from the facts."
    }

    private func structuralNarration(_ building: BuildingModel) -> String {
        let model = ShearBuilding.from(building)
        let period = ModalAnalysis.fundamentalPeriod(of: model)
        return String(format: "Expected natural period %.2f s, from the empirical relationship "
                      + "for a %@ of this height. Mass assumed at %d kg per m² of floor. "
                      + "Damping assumed at %.0f%%.",
                      period, building.system.label.lowercased(),
                      Int(building.material.floorMassPerArea), building.damping * 100)
    }
}

private extension String {
    var capitalizedFirstLetter: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}

#Preview {
    BuildingImportSheet()
        .previewEnvironment()
}
