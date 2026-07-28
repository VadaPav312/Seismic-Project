import SwiftUI
import SeismicCore
import SeismicStructures

/// What to do before, during and after — specific to this building.
///
/// Generic preparedness advice is everywhere and nobody reads it. What makes
/// this worth opening is that every item is derived from the building already
/// modelled in the app: an unreinforced masonry house gets different advice from
/// a base-isolated tower, a soft-storey car park is named as the thing to worry
/// about, and the shelter recommendation depends on where the drift is actually
/// concentrated. Advice you can see the reason for is advice people follow.
struct PreparednessScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var voice: VoiceController

    @State private var completed: Set<String> = Self.loadCompleted()
    @State private var phase: Phase = .before

    enum Phase: String, CaseIterable, Identifiable {
        case before, during, after
        var id: String { rawValue }

        var label: String {
            switch self {
            case .before: "Before"
            case .during: "During"
            case .after: "After"
            }
        }
    }

    private var building: BuildingModel? { env.selectedBuilding }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.spacingLoose) {
                Picker("Phase", selection: $phase) {
                    ForEach(Phase.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                if let building {
                    buildingSpecific(building)
                }

                ForEach(items(for: phase)) { item in
                    PreparednessRow(item: item,
                                    isDone: completed.contains(item.id),
                                    toggle: { toggle(item) })
                }

                if phase == .before, !items(for: .before).isEmpty {
                    progressSummary
                }

                Button {
                    let spoken = items(for: phase)
                        .prefix(6)
                        .map { "\($0.title). \($0.detail)" }
                        .joined(separator: " ")
                    voice.speak(spoken, urgency: phase == .during ? .emergency : .calm,
                                force: true)
                } label: {
                    Label("Read this out", systemImage: "speaker.wave.2")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(Theme.Metrics.screenPadding)
        }
    }

    // MARK: Building-specific

    private func buildingSpecific(_ building: BuildingModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("For \(building.name)", systemImage: "building.2")

            ForEach(Array(specificAdvice(building).enumerated()), id: \.offset) { _, advice in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: advice.icon)
                        .font(.system(size: 14))
                        .foregroundStyle(advice.isWarning ? Theme.Palette.verdictAmber
                                                          : Theme.Palette.accent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(advice.headline)
                            .font(Theme.Typography.callout.weight(.medium))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text(advice.detail)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private struct Advice {
        var headline: String
        var detail: String
        var icon: String
        var isWarning: Bool
    }

    /// Derived from the model, not from a lookup table of platitudes.
    private func specificAdvice(_ building: BuildingModel) -> [Advice] {
        var advice: [Advice] = []

        let period = building.empiricalPeriod
        advice.append(Advice(
            headline: String(format: "This building sways with a %.1f second rhythm", period),
            detail: period > 1.5
                ? "A slow, long sway rather than a sharp jolt. It will feel alarming and last "
                  + "longer than you expect. Tall furniture is the hazard, not the frame."
                : "A quick, sharp shake. Things will be thrown off shelves before you can react, "
                  + "so what is fixed down matters more here than in a tall building.",
            icon: "waveform.path.ecg", isWarning: false))

        switch building.material {
        case .unreinforcedMasonry:
            advice.append(Advice(
                headline: "Unreinforced masonry — stay away from the outside walls",
                detail: "This is the construction type that fails worst in earthquakes. Brick "
                      + "and stone have almost no tensile strength, so walls can peel away from "
                      + "the floors. Shelter towards the middle of the building, and get out "
                      + "afterwards rather than staying put.",
                icon: "exclamationmark.triangle", isWarning: true))
        case .timber:
            advice.append(Advice(
                headline: "Timber frame — light and forgiving",
                detail: "Timber buildings survive shaking well because they are light and "
                      + "flexible. The usual failures are at the foundation connection and in "
                      + "an open garage below the living space.",
                icon: "checkmark.shield", isWarning: false))
        case .reinforcedConcrete, .steel, .masonry, .hybrid, .unknown:
            advice.append(Advice(
                headline: "\(building.material.label) frame",
                detail: "The frame is designed to bend and absorb energy. What hurts people in "
                      + "these buildings is almost never the frame — it is ceilings, light "
                      + "fittings, glass and unsecured furniture.",
                icon: "building.columns", isWarning: false))
        }

        if building.system == .baseIsolated {
            advice.append(Advice(
                headline: "Base isolated — expect it to move, a lot, slowly",
                detail: "The building is meant to slide on its bearings. The movement will feel "
                      + "extreme and is the system working. Keep clear of the gap at ground "
                      + "level, which is where the relative movement actually happens.",
                icon: "arrow.left.and.right", isWarning: false))
        }

        if building.retrofit == .none, let year = building.yearBuilt, year < 1980 {
            advice.append(Advice(
                headline: "Built in \(year), with no retrofit recorded",
                detail: "Seismic codes changed substantially after the 1970s. A building of this "
                      + "age without a recorded retrofit is worth having assessed properly — "
                      + "not because it will fail, but because the margin is unknown.",
                icon: "calendar.badge.exclamationmark", isWarning: true))
        }

        if building.soil == .softSoil || building.soil == .stiffSoil {
            let soilPeriod = building.soil.resonantPeriod
            let ratio = soilPeriod > 0 ? period / soilPeriod : 0
            if ratio > 0.7 && ratio < 1.4 {
                advice.append(Advice(
                    headline: "The ground here resonates near this building's own period",
                    detail: String(format: "The site amplifies motion around %.1f s and this "
                                   + "building responds around %.1f s. When those coincide the "
                                   + "shaking at the building can be several times what the "
                                   + "bedrock delivered.", soilPeriod, period),
                    icon: "waveform.badge.exclamationmark", isWarning: true))
            }
        }

        if building.storeyCount >= 4 {
            advice.append(Advice(
                headline: "Shelter on a lower floor if you have a choice",
                detail: "Movement grows with height. In this building the top floor moves "
                      + String(format: "roughly %.0f times as far as the second.",
                               max(Double(building.storeyCount) / 2, 1))
                      + " Lifts will stop; the stairs are the way out, afterwards, not during.",
                icon: "arrow.down.to.line", isWarning: false))
        }

        return advice
    }

    // MARK: Checklist

    private func items(for phase: Phase) -> [PreparednessItem] {
        switch phase {
        case .before:
            [
                PreparednessItem(id: "strap", title: "Strap down anything tall",
                     detail: "Bookcases, wardrobes and water heaters kill and injure far more "
                           + "people than collapsing frames do. Two brackets and an hour.",
                     icon: "wrench.and.screwdriver"),
                PreparednessItem(id: "water", title: "Three days of water per person",
                     detail: "Four litres a day each. Mains water is usually the first utility "
                           + "to go and among the last to come back.",
                     icon: "drop"),
                PreparednessItem(id: "shoes", title: "Shoes and a torch beside every bed",
                     detail: "Broken glass on the floor in the dark is the most common injury "
                           + "after an earthquake, and it is entirely preventable.",
                     icon: "shoe"),
                PreparednessItem(id: "gas", title: "Know where the gas shut-off is",
                     detail: "If you have a node fitted it will close the valve for you. Know "
                           + "how to do it by hand anyway, and keep the spanner with the valve.",
                     icon: "flame"),
                PreparednessItem(id: "meet", title: "Agree a meeting place outside",
                     detail: "Phone networks fail exactly when everybody tries to use them. A "
                           + "place agreed in advance needs no network at all.",
                     icon: "figure.2"),
                PreparednessItem(id: "documents", title: "Photograph your documents",
                     detail: "Insurance, deeds, prescriptions. Keep them somewhere that is not "
                           + "the building they describe.",
                     icon: "doc.on.doc"),
                PreparednessItem(id: "drill", title: "Run a drill in this app",
                     detail: "The whole warning sequence, without firing anything. Ten seconds "
                           + "of practice is worth more than any amount of reading.",
                     icon: "play.circle"),
            ]
        case .during:
            [
                PreparednessItem(id: "drop", title: "Drop, cover, hold on",
                     detail: "Get low before the shaking knocks you over, get under something "
                           + "solid, and hold it — furniture moves during an earthquake.",
                     icon: "figure.fall"),
                PreparednessItem(id: "stay", title: "Stay where you are",
                     detail: "Most injuries happen to people moving during the shaking. "
                           + "Doorways are no stronger than the rest of a modern building.",
                     icon: "hand.raised"),
                PreparednessItem(id: "outside", title: "If you are outside, stay outside",
                     detail: "Move away from walls, glass and anything overhead. The most "
                           + "dangerous place is immediately outside a building's entrance.",
                     icon: "figure.walk"),
                PreparednessItem(id: "bed", title: "If you are in bed, stay in bed",
                     detail: "Cover your head with a pillow. The floor around a bed is where "
                           + "the broken glass lands.",
                     icon: "bed.double"),
            ]
        case .after:
            [
                PreparednessItem(id: "check", title: "Check yourself, then the people near you",
                     detail: "Adrenaline hides injuries. Look before you decide you are fine.",
                     icon: "cross.case"),
                PreparednessItem(id: "smell", title: "Smell for gas before anything electrical",
                     detail: "No switches, no lighters, no phone torch if you smell gas. Open a "
                           + "window and get out.",
                     icon: "flame.circle"),
                PreparednessItem(id: "measure", title: "Let the node measure the building",
                     detail: "The measurement takes a few minutes and is far more informative "
                           + "than a walk round with a torch.",
                     icon: "waveform.path.ecg"),
                PreparednessItem(id: "photos", title: "Photograph anything cracked",
                     detail: "Same spot, same angle, every time. A pair of photographs settles "
                           + "arguments that a single one starts.",
                     icon: "camera"),
                PreparednessItem(id: "aftershock", title: "Expect aftershocks",
                     detail: "The largest aftershock is typically about one magnitude below the "
                           + "mainshock, and the first hour is the most active by far.",
                     icon: "clock.arrow.circlepath"),
                PreparednessItem(id: "tag", title: "Tag your building on the map",
                     detail: "Your neighbours cannot see your verdict unless you publish it, "
                           + "and a street with real tags on it is worth more than any "
                           + "individual assessment.",
                     icon: "map"),
            ]
        }
    }

    private var progressSummary: some View {
        let all = items(for: .before)
        let done = all.filter { completed.contains($0.id) }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(done) of \(all.count) done")
                    .font(Theme.Typography.numeric)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                if done == all.count {
                    StatusPill(text: "Complete", systemImage: "checkmark",
                               tint: Theme.Palette.verdictGreen)
                }
            }
            ProgressView(value: Double(done), total: Double(max(all.count, 1)))
                .tint(Theme.Palette.accent)
            Text("None of this is about the building surviving. It is about the people in it "
                 + "being uninjured and able to leave.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .instrumentPanel()
    }

    private func toggle(_ item: PreparednessItem) {
        if completed.contains(item.id) { completed.remove(item.id) }
        else {
            completed.insert(item.id)
            Haptics.shared.play(.selection)
        }
        UserDefaults.standard.set(Array(completed), forKey: "preparedness.completed")
    }

    private static func loadCompleted() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "preparedness.completed") ?? [])
    }
}

/// One checklist line. A separate type so the screen's body stays readable and
/// the row can be previewed on its own.
struct PreparednessItem: Identifiable {
    var id: String
    var title: String
    var detail: String
    var icon: String
}

private struct PreparednessRow: View {
    let item: PreparednessItem
    let isDone: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isDone ? Theme.Palette.verdictGreen
                                            : Theme.Palette.textTertiary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.accent)
                        Text(item.title)
                            .font(Theme.Typography.callout.weight(.medium))
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .strikethrough(isDone, color: Theme.Palette.textTertiary)
                    }
                    Text(item.detail)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .instrumentPanel()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isDone ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    NavigationStack {
        PreparednessScreen()
            .seismicBackground()
            .navigationTitle("Preparedness")
    }
    .previewEnvironment()
}
