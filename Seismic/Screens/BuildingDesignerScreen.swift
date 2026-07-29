import SwiftUI
import SeismicCore
import SeismicGeo
import SeismicStructures

/// Design a building.
///
/// Not a form. The point of this screen is that the consequences are visible
/// while you are making the choice: the model turns as you drag, and the period
/// underneath it moves with every change. Somebody who drags the storey count
/// from eight to forty and watches the period go from 0.9 seconds to 3.4 has
/// learned the thing this app exists to teach, without reading a word of it.
///
/// It is also the honest counterpart to import. Import claims to know a
/// building; this claims nothing except what you told it, and says so.
struct BuildingDesignerScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    /// The building being edited, if this was opened from one.
    var editing: BuildingModel?

    @State private var draft = Draft()
    @StateObject private var scene = BuildingSceneController()

    /// Set while a slider is mid-drag.
    ///
    /// Rebuilding the geometry is the expensive part — it disposes and recreates
    /// every storey — so it happens when a control settles rather than on every
    /// value the slider emits. The number readouts still update continuously,
    /// which is what makes the screen feel live.
    @State private var isDragging = false
    @State private var rebuildToken = 0

    // MARK: The draft

    struct Draft {
        var name = "New building"
        var storeys = 8.0
        var height = 27.0
        var footprintArea = 620.0
        var planShape: PlanShape = .rectangular
        var aspectRatio = 1.6
        var massingStyle: MassingStyle = .uniform
        var massingAmount = 0.45
        var podiumFraction = 0.25
        var material: ConstructionMaterial = .reinforcedConcrete
        var system: StructuralSystem = .momentFrame
        var soil: SoilClass = .stiffSoil
        var retrofit: RetrofitLevel = .none
        var yearBuilt = 1994.0

        /// Whether the height was set by hand.
        ///
        /// Storey count and height are not independent — 40 storeys at 27 m is
        /// not a building. Height follows the storey count until somebody
        /// deliberately changes it, after which it is theirs and is left alone.
        var heightIsManual = false
    }

    enum MassingStyle: String, CaseIterable, Identifiable {
        case uniform, tapered, setback, podium
        var id: String { rawValue }

        var label: String {
            switch self {
            case .uniform: "Uniform"
            case .tapered: "Tapered"
            case .setback: "Setback"
            case .podium: "Podium"
            }
        }

        var explanation: String {
            switch self {
            case .uniform:
                "The same plan from base to roof. What almost every ordinary building is."
            case .tapered:
                "Narrows continuously. Puts mass low and reduces the overturning moment at "
                    + "the base — the Transamerica Pyramid's shape is structural, not stylistic."
            case .setback:
                "Steps in at intervals. Each step is a discontinuity in stiffness and mass, "
                    + "and demand concentrates at the storeys where they happen."
            case .podium:
                "A slim tower on a wide base. The abrupt drop in plan is also an abrupt drop "
                    + "in stiffness, which is one of the configurations codes single out."
            }
        }
    }

    // MARK: Derived

    private var massing: Massing {
        switch draft.massingStyle {
        case .uniform: .uniform
        case .tapered: .tapered(topScale: 1 - draft.massingAmount)
        case .setback: .setback(steps: 3, topScale: 1 - draft.massingAmount)
        case .podium: .podium(podiumFraction: draft.podiumFraction,
                              towerScale: 1 - draft.massingAmount)
        }
    }

    private var building: BuildingModel {
        BuildingModel(
            id: editing?.id ?? UUID(),
            name: draft.name.isEmpty ? "New building" : draft.name,
            address: editing?.address ?? "Designed by you",
            latitude: editing?.latitude ?? 0,
            longitude: editing?.longitude ?? 0,
            storeyCount: Int(draft.storeys.rounded()),
            height: draft.height,
            footprintArea: draft.footprintArea,
            footprint: draft.planShape.polygon(area: draft.footprintArea,
                                               aspectRatio: draft.aspectRatio),
            massing: massing,
            yearBuilt: Int(draft.yearBuilt.rounded()),
            material: draft.material,
            system: draft.system,
            soil: draft.soil,
            retrofit: draft.retrofit,
            notes: "Designed in the app rather than imported. Every figure here is one you "
                + "chose, so the model is exactly as good as those choices.",
            // Everything is entered, and the provenance says so — the same
            // standard an imported building is held to.
            provenance: Dictionary(uniqueKeysWithValues:
                ["height", "storeyCount", "footprintArea", "material", "system", "soil"]
                    .map { ($0, FactProvenance(source: .userEntered, confidence: 0.95,
                                               detail: "Entered by you")) }),
            privacy: .exact)
    }

    private var period: Double {
        ModalAnalysis.fundamentalPeriod(of: ShearBuilding.from(building))
    }

    private var expectedPeriod: Double {
        building.empiricalPeriod
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Metrics.spacingLoose) {
                preview
                dimensions
                planSection
                massingSection
                constructionSection
                verdictOnTheDesign
                saveButton
            }
            .padding(Theme.Metrics.screenPadding)
            .contentColumn()
        }
        .seismicBackground()
        .navigationTitle(editing == nil ? "Design a building" : "Edit building")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let editing { load(editing) }
            rebuild()
        }
        // Rebuilt when a control settles, not on every value it emits.
        .onChange(of: rebuildToken) { _, _ in rebuild() }
    }

    // MARK: Preview

    private var preview: some View {
        VStack(spacing: Theme.Metrics.spacing) {
            BuildingSceneView(controller: scene)
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius,
                                            style: .continuous))

            ReadoutGrid(readouts: [
                Readout(label: "Natural period", value: String(format: "%.2f", period),
                        unit: "s", tint: Theme.Palette.accent, size: .large),
                Readout(label: "Expected for this type",
                        value: String(format: "%.2f", expectedPeriod), unit: "s"),
                Readout(label: "Storeys", value: "\(Int(draft.storeys.rounded()))"),
                Readout(label: "Height", value: String(format: "%.0f", draft.height), unit: "m"),
            ], columns: 2)

            // The two periods disagreeing is not an error, and saying so stops
            // it reading as one. The code formula is a regression through real
            // buildings; the model is this specific arrangement of mass and
            // stiffness. They differ when the design is unusual, which is
            // exactly when that is worth knowing.
            if abs(period - expectedPeriod) / max(expectedPeriod, 0.01) > 0.25 {
                InlineNotice(
                    level: .info,
                    title: "The model and the code formula disagree",
                    message: "The building codes expect about "
                        + String(format: "%.2f s", expectedPeriod)
                        + " for a building this tall with this system. The model says "
                        + String(format: "%.2f s", period)
                        + ", because of how you have arranged its mass and stiffness. "
                        + "A large gap usually means the design is unusual rather than wrong.")
            }
        }
        .instrumentPanel()
    }

    // MARK: Sections

    private var dimensions: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Dimensions", systemImage: "ruler")

            TextField("Name", text: $draft.name)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .padding(.horizontal, Theme.Metrics.s4)
                .frame(height: Theme.Metrics.minimumTapTarget)
                .background(Capsule(style: .continuous).fill(Theme.Palette.surfaceRaised))
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(Theme.Palette.hairline, lineWidth: 1))

            slider("Storeys", value: $draft.storeys, range: 1...80, step: 1,
                   format: { "\(Int($0))" }) {
                // Height follows the storey count until it is set by hand.
                if !draft.heightIsManual {
                    draft.height = draft.storeys * 3.4
                }
            }

            slider("Height", value: $draft.height, range: 3...650, step: 1,
                   format: { String(format: "%.0f m", $0) }) {
                draft.heightIsManual = true
            }

            if draft.heightIsManual {
                HStack {
                    Text(String(format: "That is %.1f m per storey.",
                                draft.height / max(draft.storeys, 1)))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(storeyHeightIsPlausible
                                         ? Theme.Palette.textTertiary
                                         : Theme.Palette.verdictAmber)
                    Spacer()
                    Button("Follow storeys") {
                        draft.heightIsManual = false
                        draft.height = draft.storeys * 3.4
                        settle()
                    }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.accent)
                }
            }

            slider("Floor area", value: $draft.footprintArea, range: 30...8000, step: 10,
                   format: { String(format: "%.0f m²", $0) })

            slider("Year built", value: $draft.yearBuilt, range: 1850...2030, step: 1,
                   format: { String(Int($0)) })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private var storeyHeightIsPlausible: Bool {
        let perStorey = draft.height / max(draft.storeys, 1)
        return perStorey > 2.2 && perStorey < 8
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Plan", systemImage: "square.on.square.dashed")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                      spacing: 8) {
                ForEach(PlanShape.allCases, id: \.self) { shape in
                    Button {
                        draft.planShape = shape
                        settle()
                    } label: {
                        VStack(spacing: 6) {
                            PlanShapeThumbnail(shape: shape)
                                .frame(height: 44)
                            Text(shape.label)
                                .font(Theme.Typography.caption)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall,
                                             style: .continuous)
                                .fill(draft.planShape == shape
                                      ? Theme.Palette.accentDim : Theme.Palette.surfaceRaised)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall,
                                             style: .continuous)
                                .strokeBorder(draft.planShape == shape
                                              ? Theme.Palette.accent : Theme.Palette.hairline,
                                              lineWidth: 1)
                        )
                        .foregroundStyle(draft.planShape == shape
                                         ? Theme.Palette.accent : Theme.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if draft.planShape == .rectangular || draft.planShape == .setbackTower {
                slider("Proportion", value: $draft.aspectRatio, range: 1...6, step: 0.1,
                       format: { String(format: "%.1f : 1", $0) })
            }

            Text(draft.planShape.isIrregular
                 ? "Re-entrant corners concentrate stress, and mass away from the centre of "
                   + "rigidity twists a building rather than simply pushing it. Plan "
                   + "irregularity is among the strongest predictors of earthquake damage there is."
                 : "A regular plan distributes demand evenly and is the easiest shape to make "
                   + "behave predictably.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private var massingSection: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("How it changes with height", systemImage: "building.columns")

            Picker("Massing", selection: $draft.massingStyle) {
                ForEach(MassingStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: draft.massingStyle) { _, _ in settle() }

            if draft.massingStyle != .uniform {
                slider("Narrowing", value: $draft.massingAmount, range: 0.1...0.8, step: 0.05,
                       format: { String(format: "%.0f%%", $0 * 100) })
            }
            if draft.massingStyle == .podium {
                slider("Podium height", value: $draft.podiumFraction, range: 0.1...0.6, step: 0.05,
                       format: { String(format: "%.0f%% of the building", $0 * 100) })
            }

            Text(draft.massingStyle.explanation)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let discontinuity = massing.largestDiscontinuity, discontinuity.drop > 0.25 {
                InlineNotice(
                    level: .warning,
                    title: "Vertical irregularity",
                    message: String(
                        format: "The plan drops by %.0f%% at about %.0f%% of the height. A "
                            + "building fails where its stiffness changes abruptly, not where "
                            + "it is weakest on average — this is the storey to watch.",
                        discontinuity.drop * 100, discontinuity.atHeightFraction * 100))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private var constructionSection: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Construction", systemImage: "hammer")

            picker("Material", selection: $draft.material,
                   options: ConstructionMaterial.allCases.filter { $0 != .unknown },
                   label: \.label)
            picker("Structural system", selection: $draft.system,
                   options: StructuralSystem.allCases.filter { $0 != .unknown },
                   label: \.label)
            picker("Ground", selection: $draft.soil, options: SoilClass.allCases,
                   label: \.label)
            picker("Retrofit", selection: $draft.retrofit, options: RetrofitLevel.allCases,
                   label: \.label)

            if draft.system == .softStorey {
                InlineNotice(
                    level: .critical,
                    title: "A soft storey is the deadliest configuration there is",
                    message: "An open ground floor — shopfronts, or parking — under stiffer "
                        + "storeys concentrates the entire building's drift into one level. "
                        + "The model reflects that: the ground storey is given roughly a third "
                        + "of the stiffness of the ones above it.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    /// What the design implies, said plainly.
    private var verdictOnTheDesign: some View {
        let concerns = designConcerns
        return VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("What this design implies", systemImage: "text.magnifyingglass")

            if concerns.isEmpty {
                InlineNotice(level: .info, title: "Nothing unusual",
                             message: "A regular plan, a uniform stack and a ductile system. "
                                 + "This is the shape codes are written around, and the shape "
                                 + "that behaves most predictably.")
            } else {
                ForEach(Array(concerns.enumerated()), id: \.offset) { _, concern in
                    InlineNotice(level: concern.level, title: concern.title,
                                 message: concern.detail)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private struct Concern {
        let level: InlineNotice.Level
        let title: String
        let detail: String
    }

    private var designConcerns: [Concern] {
        var out: [Concern] = []

        if draft.planShape.isIrregular {
            out.append(Concern(
                level: .warning, title: "Irregular plan",
                detail: "\(draft.planShape.label) buildings twist as well as sway. The corners "
                    + "where the wings meet take far more than their share."))
        }
        if let discontinuity = massing.largestDiscontinuity, discontinuity.drop > 0.25 {
            out.append(Concern(
                level: .warning, title: "Abrupt change in plan",
                detail: "Demand concentrates where stiffness changes suddenly."))
        }
        if draft.material == .unreinforcedMasonry {
            out.append(Concern(
                level: .critical, title: "Unreinforced masonry",
                detail: "It has almost no ductility: it carries load until it cracks, and then "
                    + "it does not carry load. This is the construction that kills people in "
                    + "moderate earthquakes."))
        }
        if draft.soil == .softSoil {
            // Soft sites amplify around a second, which is where mid-rise
            // buildings sit — the coincidence that made 1985 lethal.
            let siteperiod = 1.2
            if abs(period - siteperiod) < 0.4 {
                out.append(Concern(
                    level: .critical, title: "The building and the ground agree",
                    detail: String(
                        format: "Soft ground amplifies motion near %.1f s, and this building's "
                            + "period is %.2f s. That match is what made 1985 in Mexico City so "
                            + "lethal — modest shaking, resonant buildings.", siteperiod, period)))
            } else {
                out.append(Concern(
                    level: .info, title: "Soft ground",
                    detail: "Soft soil amplifies shaking, but this building's period is far "
                        + "enough from the site's that they should not reinforce each other."))
            }
        }
        if draft.storeys > 1, draft.height / draft.storeys < 2.4 {
            out.append(Concern(
                level: .warning, title: "The storeys are very shallow",
                detail: String(format: "%.1f m per storey is below what people can stand up in. "
                               + "Check the height and the storey count against each other.",
                               draft.height / draft.storeys)))
        }
        return out
    }

    private var saveButton: some View {
        VStack(spacing: Theme.Metrics.spacing) {
            Button {
                let model = building
                env.store.upsert(model)
                env.refresh()
                env.selectedBuildingID = model.id
                Haptics.shared.play(.assessmentComplete)
                dismiss()
            } label: {
                Label(editing == nil ? "Add to my library" : "Save changes",
                      systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())

            Text("Everything here is a figure you chose, and the model is exactly as good as "
                 + "those choices. It carries that provenance into the library, the same as an "
                 + "imported building carries its sources.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Controls

    private func slider(_ label: String, value: Binding<Double>,
                        range: ClosedRange<Double>, step: Double,
                        format: @escaping (Double) -> String,
                        onChange: @escaping () -> Void = {}) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(Theme.Typography.numeric)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .contentTransition(.numericText())
            }
            Slider(value: value, in: range, step: step) { editing in
                isDragging = editing
                // Rebuilt when the drag ends. The readouts above track every
                // value; the geometry does not need to.
                if !editing { settle() }
            }
            .tint(Theme.Palette.accent)
            .onChange(of: value.wrappedValue) { _, _ in onChange() }
        }
    }

    private func picker<T: Hashable & CaseIterable>(
        _ label: String, selection: Binding<T>, options: [T],
        label keyPath: KeyPath<T, String>
    ) -> some View {
        HStack {
            Text(label)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer(minLength: Theme.Metrics.s3)
            Picker(label, selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(option[keyPath: keyPath]).tag(option)
                }
            }
            .labelsHidden()
            .tint(Theme.Palette.accent)
            .onChange(of: selection.wrappedValue) { _, _ in settle() }
        }
        .frame(minHeight: Theme.Metrics.minimumTapTarget)
    }

    // MARK: Rebuilding

    /// Marks the design as settled, so the preview catches up.
    private func settle() {
        rebuildToken &+= 1
    }

    private func rebuild() {
        scene.build(building, animated: false)
    }

    private func load(_ model: BuildingModel) {
        draft.name = model.name
        draft.storeys = Double(model.storeyCount)
        draft.height = model.height
        draft.heightIsManual = true
        draft.footprintArea = model.footprintArea
        draft.material = model.material
        draft.system = model.system
        draft.soil = model.soil
        draft.retrofit = model.retrofit
        draft.yearBuilt = Double(model.yearBuilt ?? 1994)
    }
}

/// A small drawing of a plan shape, for the picker.
///
/// Drawn from the same polygon generator the model uses, so the thumbnail
/// cannot drift out of step with the geometry it is selecting.
struct PlanShapeThumbnail: View {
    let shape: PlanShape

    var body: some View {
        Canvas { context, size in
            let ring = shape.polygon(area: 100)
            guard ring.count > 2 else { return }

            let xs = ring.map(\.x)
            let ys = ring.map(\.y)
            let width = (xs.max() ?? 1) - (xs.min() ?? 0)
            let depth = (ys.max() ?? 1) - (ys.min() ?? 0)
            let scale = min(size.width / max(width, 0.001),
                            size.height / max(depth, 0.001)) * 0.78

            var path = Path()
            for (index, point) in ring.enumerated() {
                let location = CGPoint(x: size.width / 2 + point.x * scale,
                                       y: size.height / 2 - point.y * scale)
                if index == 0 { path.move(to: location) } else { path.addLine(to: location) }
            }
            path.closeSubpath()

            context.fill(path, with: .color(Theme.Palette.accent.opacity(0.22)))
            context.stroke(path, with: .color(Theme.Palette.accent), lineWidth: 1.3)
        }
    }
}

#Preview {
    NavigationStack {
        BuildingDesignerScreen()
    }
    .previewEnvironment()
}
