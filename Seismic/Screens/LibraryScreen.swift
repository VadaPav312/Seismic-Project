import SwiftUI
import SeismicCore
import SeismicStructures
import SeismicData

/// The building library, and the search that fills it.
struct LibraryScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var query = ""
    @State private var showingImport = false
    @State private var showingDesigner = false
    @State private var detail: BuildingModel?

    private var filtered: [BuildingModel] {
        guard !query.isEmpty else { return env.buildings }
        return env.buildings.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.address.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Metrics.spacing) {
                importPrompt

                if filtered.isEmpty {
                    DesignedEmptyState(
                        icon: "magnifyingglass",
                        title: "Nothing matches “\(query)”",
                        message: "Your library has \(env.buildings.count) buildings. Try a "
                            + "different term, or search the web for any building in the world "
                            + "and pull it in.",
                        actionTitle: "Search the web instead",
                        action: { showingImport = true },
                        secondaryActionTitle: "Design one from scratch",
                        secondaryAction: { showingDesigner = true })
                        .frame(minHeight: 320)
                } else {
                    ForEach(filtered) { building in
                        Button {
                            detail = building
                        } label: {
                            BuildingCard(building: building,
                                         verdict: env.assessment(for: building.id)?.verdict)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(Theme.Metrics.screenPadding)
            .contentColumn()
        }
        .searchable(text: $query, prompt: "Search your library")
        .toolbar {
            // Two ways to get a building, because they are genuinely different
            // acts: import claims to know a real one, designing claims nothing
            // except what you entered.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingImport = true
                    } label: {
                        Label("Import a real building", systemImage: "globe")
                    }
                    Button {
                        showingDesigner = true
                    } label: {
                        Label("Design one from scratch", systemImage: "square.on.square.dashed")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add a building")
            }
        }
        .task {
            // A screenshot run or a UI test can open the designer directly, in
            // the same spirit as SEISMIC_INITIAL_TAB. It grants nothing that
            // tapping the plus button would not.
            if ProcessInfo.processInfo.environment["SEISMIC_SHOW_DESIGNER"] == "1" {
                showingDesigner = true
            }
        }
        .sheet(isPresented: $showingImport) { BuildingImportSheet() }
        .sheet(isPresented: $showingDesigner) {
            NavigationStack {
                BuildingDesignerScreen()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingDesigner = false }
                        }
                    }
            }
        }
        .sheet(item: $detail) { building in
            BuildingDetailSheet(building: building)
        }
    }

    private var importPrompt: some View {
        Button { showingImport = true } label: {
            HStack(spacing: Theme.Metrics.spacing) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall,
                                     style: .continuous)
                        .fill(Theme.Palette.accent.opacity(0.14))
                        .frame(width: 54, height: 54)
                    Image(systemName: "globe.europe.africa")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.Palette.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import any building in the world")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Type a name or an address. Seismic finds its facts, works out how it "
                         + "should behave, and builds it in 3D.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .instrumentPanel()
        }
        .buttonStyle(.plain)
    }
}

/// Everything known about one building, with each fact's source beside it.
struct BuildingDetailSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let building: BuildingModel

    @StateObject private var controller = BuildingSceneController()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.spacingLoose) {
                    BuildingSceneView(controller: controller, framingMargin: 1.3)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius,
                                                    style: .continuous))

                    // Before the facts and the derived numbers, not after them.
                    // Somebody opening a building wants to know what it means
                    // for them; the evidence for that answer is still below, in
                    // full, for anyone who wants to check it.
                    PlainReadingCard(reading: PlainReading.of(
                        building, tower: TowerAnalysis.analyse(building)))

                    if !building.notes.isEmpty {
                        Text(building.notes)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    factsSection
                    derivedSection
                        .task(id: building.id) {
                            // Computed once when the screen opens, off the
                            // render path.
                            let model = ShearBuilding.from(building)
                            derived = (ModalAnalysis.modes(of: model),
                                       DriftThresholds.forSystem(building.system,
                                                                 material: building.material))
                        }

                    if !building.notableEvents.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel("Notable events")
                            ForEach(building.notableEvents, id: \.self) { event in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 4))
                                        .padding(.top, 6)
                                    Text(event)
                                        .font(Theme.Typography.callout)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .foregroundStyle(Theme.Palette.textSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .instrumentPanel()
                    }
                }
                .padding(Theme.Metrics.screenPadding)
            }
            .seismicBackground()
            .navigationTitle(building.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Simulate") {
                        env.selectedBuildingID = building.id
                        dismiss()
                    }
                }
            }
            .onAppear { controller.build(building, animated: true) }
        }
    }

    /// Every attribute, with where it came from. The provenance chip is not
    /// decoration: a height from Wikidata and a structural system inferred by a
    /// language model deserve very different amounts of trust, and hiding that
    /// distinction is how a tool loses an engineer.
    private var factsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Facts", systemImage: "list.bullet.rectangle")

            factRow("Height", String(format: "%.1f m", building.height), "height")
            factRow("Storeys", "\(building.storeyCount)", "storeyCount")
            factRow("Floor area", String(format: "%.0f m²", building.footprintArea),
                    "footprintArea")
            if let year = building.yearBuilt { factRow("Year built", "\(year)", "yearBuilt") }
            factRow("Material", building.material.label, "material")
            factRow("Structural system", building.system.label, "system")
            factRow("Foundation", building.foundation.label, "foundation")
            factRow("Site class", building.soil.label, "soil")
            factRow("Retrofit", building.retrofit.label, "retrofit")
            if let architect = building.architect {
                factRow("Architect", architect, "architect")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private func factRow(_ label: String, _ value: String, _ key: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(value)
                    .font(Theme.Typography.numericSmall)
                    .foregroundStyle(Theme.Palette.textPrimary)
                ProvenanceChip(provenance: building.provenance(for: key))
            }
        }
    }

    /// Derived structural properties, each with the assumption stated in words.
    /// Cached, because computing it is a full eigendecomposition.
    ///
    /// As a computed property this ran on every body evaluation of the detail
    /// screen — every toggle, every scroll that changed state, every time the
    /// environment published anything. The building does not change while the
    /// screen is open, so neither do its modes.
    @State private var derived: (modes: [ModeShape], thresholds: DriftThresholds)?

    /// The three-dimensional picture, from the building's real cross-section.
    private var towerAnalysis: some View {
        let result = TowerAnalysis.analyse(building)
        let section = SectionProperties.of(building.footprint)

        return VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            ReadoutGrid(readouts: [
                Readout(label: "Stiff axis", value: String(format: "%.2f", result.majorAxisPeriod),
                        unit: "s", size: .small),
                Readout(label: "Weak axis", value: String(format: "%.2f", result.minorAxisPeriod),
                        unit: "s", tint: Theme.Palette.accent, size: .small),
                Readout(label: "Torsion", value: String(format: "%.2f", result.torsionalPeriod),
                        unit: "s", size: .small),
                Readout(label: "Bending",
                        value: String(format: "%.0f", result.flexuralFraction * 100),
                        unit: "%", size: .small),
            ], columns: 2)

            Text(section.interpretation)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(result.isBendingDominated
                 ? "Tall enough to behave as a cantilever — most of its movement is bending."
                 : "Squat enough to deform mostly by shearing, storey against storey.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if result.isTorsionallySensitive {
                // The uncoupled ratio, for the reason given in the designer.
                Text(String(
                    format: "Its twisting mode is %.0f%% as slow as its swaying one, so it "
                        + "rotates about as readily as it leans. The corners will travel "
                        + "further than the centre.", result.torsionalRatio * 100))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.verdictAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(Theme.Palette.hairline)
        }
    }

    private var derivedSection: some View {
        let model = ShearBuilding.from(building)
        let modes = derived?.modes ?? ModalAnalysis.modes(of: model)
        let thresholds = derived?.thresholds
            ?? DriftThresholds.forSystem(building.system, material: building.material)

        return VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Derived properties", systemImage: "function")

            towerAnalysis

            ReadoutGrid(readouts: [
                Readout(label: "Natural period",
                        value: String(format: "%.2f", modes.first?.period ?? 0), unit: "s",
                        tint: Theme.Palette.accent, size: .large),
                Readout(label: "Damping",
                        value: String(format: "%.1f", building.damping * 100), unit: "%",
                        size: .large),
                Readout(label: "Total mass",
                        value: String(format: "%.0f", model.totalMass / 1000), unit: "t"),
                Readout(label: "Ductility",
                        value: String(format: "%.1f", building.system.ductility)),
            ], columns: 2)

            Divider().background(Theme.Palette.hairline)

            assumption("Period", "Estimated from the empirical relationship for a "
                       + "\(building.system.label.lowercased()) of this height, then used to "
                       + "calibrate the model's storey stiffnesses.")
            assumption("Mass", "Assumed at \(Int(building.material.floorMassPerArea)) kg per m² "
                       + "of floor, typical for \(building.material.label.lowercased()).")
            assumption("Damping", "Standard value for this material at low amplitude. Measured "
                       + "damping from a real event would replace it.")
            assumption("Drift thresholds",
                       String(format: "Slight at %.1f%%, moderate at %.1f%%, extensive at %.1f%%.",
                              thresholds.slight * 100, thresholds.moderate * 100,
                              thresholds.extensive * 100))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private func assumption(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(text)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    NavigationStack {
        LibraryScreen()
            .seismicBackground()
            .navigationTitle("Library")
    }
    .previewEnvironment()
}
