import SwiftUI
import SeismicCore
import SeismicStructures
import SeismicData

/// The building library, and the search that fills it.
struct LibraryScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var query = ""
    @State private var showingImport = false
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
                        action: { showingImport = true })
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
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingImport = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Import a building")
            }
        }
        .sheet(isPresented: $showingImport) { BuildingImportSheet() }
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
                    BuildingSceneView(controller: controller)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius,
                                                    style: .continuous))

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

    private var derivedSection: some View {
        let model = ShearBuilding.from(building)
        let modes = derived?.modes ?? ModalAnalysis.modes(of: model)
        let thresholds = derived?.thresholds
            ?? DriftThresholds.forSystem(building.system, material: building.material)

        return VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Derived properties", systemImage: "function")

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
