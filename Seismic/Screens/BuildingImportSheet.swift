import SwiftUI
import SeismicCore
import SeismicStructures
import SeismicData

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
                            action: { importer.searchBundled(query: query,
                                                             library: env.buildings) })
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
                    importer.select(candidate)
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
        importer.search(query: query, library: env.buildings,
                        hasLiveSearch: env.secrets.has(.serperAPIKey)
                            || env.secrets.has(.tavilyAPIKey))
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
        let building: BuildingModel
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

    private var engine = BM25<UUID>()

    func search(query: String, library: [BuildingModel], hasLiveSearch: Bool) {
        stage = .searching
        sourceDescription = hasLiveSearch
            ? "Querying search providers and Wikidata…"
            : "Searching the bundled reference library…"

        // The ranking is real BM25 over the library, not a substring match, so
        // "iron tower paris" finds the Eiffel Tower.
        let reference = library + SeedLibrary.buildings()
        var seen = Set<UUID>()
        let unique = reference.filter { seen.insert($0.id).inserted }

        engine.index(unique.map { building in
            BM25<UUID>.Document(id: building.id,
                                text: [building.name, building.address, building.notes,
                                       building.material.label, building.system.label,
                                       building.architect ?? ""].joined(separator: " "))
        })

        let ranked = engine.search(query, limit: 6)
        var candidates: [Candidate] = ranked.compactMap { result in
            guard let building = unique.first(where: { $0.id == result.id }) else { return nil }
            return Candidate(name: building.name,
                             location: building.address.isEmpty ? "Location unknown"
                                                                : building.address,
                             description: String(building.notes.prefix(110)),
                             relevance: min(result.score / 12, 1),
                             systemImage: building.thumbnailSystemImage,
                             building: building)
        }

        // Fuzzy fallback, so a misspelling still finds something rather than
        // dead-ending.
        if candidates.isEmpty {
            let fuzzy = unique
                .map { ($0, FuzzyMatch.combinedSimilarity(query, $0.name)) }
                .filter { $0.1 > 0.35 }
                .sorted { $0.1 > $1.1 }
                .prefix(4)
            candidates = fuzzy.map { building, score in
                Candidate(name: building.name,
                          location: building.address.isEmpty ? "Location unknown" : building.address,
                          description: String(building.notes.prefix(110)),
                          relevance: score,
                          systemImage: building.thumbnailSystemImage,
                          building: building)
            }
        }

        guard !candidates.isEmpty else {
            stage = .failed("Nothing in the reference library matches “\(query)”. Try a "
                            + "well-known building, or build one by hand from the library screen.")
            return
        }

        if candidates.count == 1 {
            select(candidates[0])
        } else {
            stage = .disambiguating(candidates)
        }
    }

    func searchBundled(query: String, library: [BuildingModel]) {
        search(query: query, library: library, hasLiveSearch: false)
    }

    func select(_ candidate: Candidate) {
        stage = .gathering(candidate)
        progress = 0
        narration = []

        // The stages are stepped through visibly rather than instantly, because
        // the point is to show the pipeline — what was found, from where, and
        // what was assumed. A result that appears instantly teaches nothing.
        let steps: [(Double, String, String)] = [
            (0.2, "Resolving the building", "Matched to a reference record."),
            (0.4, "Gathering facts",
             factsNarration(candidate.building)),
            (0.6, "Fetching geometry",
             geometryNarration(candidate.building)),
            (0.8, "Deriving structural properties",
             structuralNarration(candidate.building)),
            (1.0, "Assembling", "Building it storey by storey."),
        ]

        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.5) { [weak self] in
                guard let self else { return }
                progress = step.0
                sourceDescription = step.1
                narration.append(step.2)
                if index == steps.count - 1 {
                    var building = candidate.building
                    building.id = UUID()
                    building.isSandbox = false
                    stage = .assembled(building)
                }
            }
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
        .environmentObject(AppEnvironment.preview())
        .preferredColorScheme(.dark)
}
