import SwiftUI
import UIKit
import SeismicCore
import SeismicSignal
import SeismicStructures
import SeismicData
import SeismicServices

/// The safety verdict, and every piece of evidence behind it.
///
/// The structure of this screen is the argument the app is making: verdict
/// first, because that is what somebody standing outside their building needs;
/// then the evidence, itemised, so an engineer can check the reasoning; then the
/// caveats, because a screening tool that does not say what it cannot see is
/// worse than useless.
struct AssessScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var services: ServiceHub
    @EnvironmentObject private var voice: VoiceController
    @State private var showingReport = false
    @State private var expandedEvidence: UUID?
    @State private var showingPhotoCapture = false

    private var assessment: Assessment? { env.latestAssessment }
    private var building: BuildingModel? { env.selectedBuilding }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Metrics.spacingLoose) {
                if let assessment, let building {
                    verdictSection(assessment)
                    periodSection(assessment, building: building)
                    evidenceSection(assessment)
                    reentrySection(assessment)
                    narrativeSection(assessment)
                    photoSection(assessment)
                    ledgerSection(assessment)
                    disclaimer
                    actions(assessment)
                } else {
                    noAssessment
                }
            }
            .padding(Theme.Metrics.screenPadding)
        }
        .sheet(isPresented: $showingReport) {
            if let assessment, let building {
                ReportPreviewSheet(assessment: assessment, building: building)
            }
        }
        .sheet(isPresented: $showingPhotoCapture) {
            if let building {
                DamageCaptureSheet(building: building,
                                   assessmentID: assessment?.id)
            }
        }
        .task(id: assessment?.id) {
            // The narrative is produced on arrival rather than on a button, so
            // the explanation is simply there when the screen is.
            guard let assessment, let building else { return }
            await services.narrative(for: assessment, building: building)
        }
    }

    // MARK: Sections

    private func verdictSection(_ assessment: Assessment) -> some View {
        VStack(spacing: Theme.Metrics.spacing) {
            VerdictPlacard(verdict: assessment.verdict, confidence: assessment.confidence)

            ReadoutGrid(readouts: [
                Readout(label: "Probability of damage",
                        value: "\(Int((assessment.damageProbability * 100).rounded()))", unit: "%",
                        tint: assessment.verdict.color, size: .large),
                Readout(label: "Plausible range",
                        value: "\(Int(assessment.confidenceInterval.lowerBound * 100))"
                            + "–\(Int(assessment.confidenceInterval.upperBound * 100))", unit: "%",
                        size: .large,
                        caption: "The width of this range is the honest part."),
            ], columns: 2)
            .instrumentPanel()
        }
    }

    private func periodSection(_ assessment: Assessment, building: BuildingModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Period analysis", systemImage: "waveform.path.ecg")

            if let change = assessment.periodChangePercent {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%+.1f", change))
                        .font(Theme.Typography.display(56))
                        .foregroundStyle(abs(change) < 3 ? Theme.Palette.textPrimary
                                                         : assessment.verdict.color)
                        .contentTransition(.numericText())
                    Text("%")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }

                Text(abs(change) < 3
                     ? "Within the range temperature and amplitude alone produce. Not evidence "
                        + "of damage."
                     : "A building's period lengthens when it loses stiffness. That is what "
                        + "structural damage does.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ReadoutGrid(readouts: [
                Readout(label: "Before",
                        value: assessment.periodBefore.map { String(format: "%.3f", $0) } ?? "—",
                        unit: "s"),
                Readout(label: "After",
                        value: assessment.periodAfter.map { String(format: "%.3f", $0) } ?? "—",
                        unit: "s"),
                Readout(label: "After, corrected",
                        value: assessment.periodAfterTemperatureCorrection
                            .map { String(format: "%.3f", $0) } ?? "—",
                        unit: "s", tint: Theme.Palette.accent),
                Readout(label: "Temperature",
                        value: assessment.temperatureAtMeasurement
                            .map { String(format: "%.1f", $0) } ?? "—",
                        unit: "°C"),
            ], columns: 2)

            // The temperature correction gets its own explanation, because it is
            // the single least obvious and most important step in the chain.
            let history = env.observations.filter { $0.modeNumber == 1 }
            let model = TemperatureNormalisation.fit(history)
            InlineNotice(level: model.isReliable ? .info : .warning,
                         title: "Temperature correction",
                         message: model.explanation)

            if history.count > 20 {
                TrendChart(points: history.map { .init(date: $0.at, value: $0.period) },
                           color: Theme.Palette.accent,
                           baseline: assessment.periodBefore,
                           height: 150,
                           valueFormatter: { String(format: "%.3f s", $0) })

                let cusum = CUSUM.onPeriodHistory(history.map(\.period))
                Text(cusum.explanation)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(cusum.changeDetected ? Theme.Palette.verdictAmber
                                                          : Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private func evidenceSection(_ assessment: Assessment) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Evidence", systemImage: "list.bullet.clipboard",
                         trailing: "\(assessment.evidence.count) items")

            Text("Everything that contributed to the verdict is listed here. Nothing "
                 + "influences the result invisibly.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)

            ForEach(assessment.evidence) { item in
                EvidenceRow(evidence: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reentrySection(_ assessment: Assessment) -> some View {
        let guidance = AftershockForecast.reentryGuidance(
            mainshockMagnitude: 6.4, verdict: assessment.verdict)

        return VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Re-entry guidance", systemImage: "clock.arrow.circlepath")

            Text(guidance.headline)
                .font(Theme.Typography.title)
                .foregroundStyle(assessment.verdict.color)

            Text(guidance.detail)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().background(Theme.Palette.hairline)

            ForEach(Array(guidance.forecasts.enumerated()), id: \.offset) { _, forecast in
                HStack {
                    Text(forecast.windowHours >= 48
                         ? "Next \(Int(forecast.windowHours / 24)) days"
                         : "Next \(Int(forecast.windowHours)) hours")
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Spacer()
                    Text("\(Int((forecast.probabilityOfAtLeastOne * 100).rounded()))%")
                        .font(Theme.Typography.numeric)
                        .foregroundStyle(forecast.probabilityOfAtLeastOne > 0.3
                                         ? Theme.Palette.verdictAmber : Theme.Palette.textPrimary)
                }
            }

            Text("Chance of an aftershock large enough to further damage an already weakened "
                 + "building. Rates fall off quickly, which is why waiting helps.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    /// The paragraph under the verdict.
    ///
    /// Whoever wrote it is stated, always. An explanation from a language model
    /// and an explanation assembled on the device are both fine; being unable to
    /// tell which one you are reading is not.
    private func narrativeSection(_ assessment: Assessment) -> some View {
        let generated = services.narrative(for: assessment.id)
        let isWorking = services.generatingNarratives.contains(assessment.id)

        return VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            HStack {
                SectionLabel("Analysis", systemImage: "text.alignleft")
                if let generated {
                    StatusPill(text: generated.value.isAIGenerated
                               ? generated.value.provider : "On device",
                               systemImage: generated.value.isAIGenerated
                               ? "sparkles" : "iphone",
                               tint: generated.value.isAIGenerated
                               ? Theme.Palette.accent : Theme.Palette.textSecondary)
                }
            }

            if isWorking {
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock(height: 12)
                    SkeletonBlock(height: 12)
                    SkeletonBlock(height: 12, width: 220)
                }
            } else {
                Text(generated?.value.text ?? assessment.narrative)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // When a model produced a figure nobody measured, the answer is
            // discarded and the reason is shown rather than hidden.
            if let note = generated?.note {
                Text(note)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Theme.Metrics.spacing) {
                Button {
                    if voice.isSpeaking { voice.stopSpeaking() }
                    else {
                        voice.speak(spokenReadout(assessment,
                                                  narrative: generated?.value.text),
                                    urgency: .calm, force: true)
                    }
                } label: {
                    Label(voice.isSpeaking ? "Stop" : "Read this out",
                          systemImage: voice.isSpeaking ? "stop.fill" : "speaker.wave.2")
                        .font(Theme.Typography.caption)
                }
                .buttonStyle(SecondaryButtonStyle())

                if voice.isSpeaking {
                    Text("Voice: \(voice.voiceProvider)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    /// Spoken form: the verdict first, then what it means, then the analysis.
    /// Somebody listening rather than reading needs the conclusion immediately.
    private func spokenReadout(_ assessment: Assessment, narrative: String?) -> String {
        var parts = [assessment.verdict.placard + ".", assessment.verdict.plainMeaning]
        if let narrative, !narrative.isEmpty { parts.append(narrative) }
        return parts.joined(separator: " ")
    }

    /// Photographs, which are the one piece of evidence a sensor cannot supply.
    ///
    /// The value is not in any single photograph but in the pair: the same
    /// corner before and after, where a crack that has visibly widened settles
    /// an argument that a period measurement can only ever suggest.
    private func photoSection(_ assessment: Assessment) -> some View {
        let notes = env.store.notesList().filter { $0.buildingID == building?.id }

        return VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Photographs", systemImage: "camera",
                         trailing: notes.isEmpty ? nil : "\(notes.count)")

            if notes.isEmpty {
                Text("No photographs yet. A photograph of the same place before and after an "
                     + "event is worth more than any single description of one.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(notes.prefix(8)) { note in
                            DamageNoteThumbnail(note: note)
                        }
                    }
                }
            }

            Button {
                showingPhotoCapture = true
            } label: {
                Label("Add a photograph", systemImage: "camera.fill")
                    .font(Theme.Typography.caption)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private func ledgerSection(_ assessment: Assessment) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Record integrity", systemImage: "checkmark.seal")

            let verification = env.store.ledger.verify()
            HStack(spacing: 8) {
                Image(systemName: verification.isIntact ? "checkmark.seal.fill"
                                                        : "exclamationmark.triangle.fill")
                    .foregroundStyle(verification.isIntact ? Theme.Palette.verdictGreen
                                                           : Theme.Palette.verdictRed)
                Text(verification.headline)
                    .font(Theme.Typography.callout.weight(.medium))
                    .foregroundStyle(Theme.Palette.textPrimary)
            }

            Text(verification.reason)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let hash = assessment.ledgerHash {
                Text("Entry hash \(hash.prefix(24))…")
                    .font(Theme.Typography.numericSmall)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private var disclaimer: some View {
        InlineNotice(level: .warning,
                     title: "This is a screening aid, not an inspection",
                     message: Assessment.disclaimer)
    }

    private func actions(_ assessment: Assessment) -> some View {
        VStack(spacing: Theme.Metrics.spacing) {
            Button {
                showingReport = true
            } label: {
                Label("Generate a report", systemImage: "doc.richtext")
                    .font(Theme.Typography.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.Metrics.minimumTapTarget)
            }
            .buttonStyle(PrimaryButtonStyle())

            Button {
                publish(assessment)
            } label: {
                Label("Publish to the community map", systemImage: "map")
                    .font(Theme.Typography.callout)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.Metrics.minimumTapTarget)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func publish(_ assessment: Assessment) {
        guard let building else { return }
        let tag = CommunityTag(
            buildingID: building.id, verdict: assessment.verdict,
            latitude: building.latitude, longitude: building.longitude,
            buildingLabel: building.privacy == .exact ? building.name : "A nearby building",
            tier: assessment.assessorTier,
            evidenceSummary: assessment.evidence.prefix(2).map(\.headline)
                .joined(separator: "; "),
            notes: "")
        env.store.upsert(tag)
        env.refresh()
        Haptics.shared.play(.assessmentComplete)
    }

    private var noAssessment: some View {
        DesignedEmptyState(
            icon: "checkmark.shield",
            title: "Nothing to assess yet",
            message: "An assessment is produced automatically after an event. Until then there "
                + "is only a baseline — and inventing a verdict from nothing would be worse "
                + "than showing none.",
            actionTitle: "Simulate an event",
            action: { env.simulateEarthquake() },
            secondaryActionTitle: "Run a drill instead",
            secondaryAction: { env.startDrill(fireActuators: false) })
            .frame(minHeight: 420)
    }
}

/// Preview of the generated report.
struct ReportPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let assessment: Assessment
    let building: BuildingModel
    @State private var format: ReportFormat = .summary

    enum ReportFormat: String, CaseIterable, Identifiable {
        case summary, technical, official
        var id: String { rawValue }
        var label: String {
            switch self {
            case .summary: "Summary"
            case .technical: "Technical"
            case .official: "For submission"
            }
        }
        var description: String {
            switch self {
            case .summary: "Two pages, plain language, for the building's occupants."
            case .technical: "Full working: measurements, charts, model assumptions and "
                + "algorithm settings, for an engineer."
            case .official: "Formal layout with the ledger proof and signature block, for "
                + "submission to an authority or insurer."
            }
        }
    }

    @State private var exportedPDF: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.spacingLoose) {
                    Picker("Format", selection: $format) {
                        ForEach(ReportFormat.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Text(format.description)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)

                    ReportDocumentView(assessment: assessment, building: building, format: format)
                }
                .padding(Theme.Metrics.screenPadding)
            }
            .seismicBackground()
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            exportPDF()
                        } label: {
                            Label("Share as PDF", systemImage: "doc.fill")
                        }
                        Button {
                            printPDF()
                        } label: {
                            Label("Print", systemImage: "printer")
                        }
                        ShareLink(item: ReportBuilder.plainText(assessment: assessment,
                                                                building: building)) {
                            Label("Share as plain text", systemImage: "text.alignleft")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(item: $exportedPDF) { url in
                ActivityShareSheet(items: [url])
            }
        }
    }

    /// A real PDF, written to a real file with a real name, because a document
    /// somebody may hand to an insurer should not arrive called "Document.pdf".
    private func exportPDF() {
        exportedPDF = PDFExport.writeToTemporaryFile(assessment: assessment,
                                                     building: building, format: format)
        Haptics.shared.play(.selection)
    }

    private func printPDF() {
        let data = PDFExport.render(assessment: assessment, building: building, format: format)
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = "Seismic assessment — \(building.name)"
        info.outputType = .general
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = data
        controller.present(animated: true)
    }
}

/// `UIActivityViewController`, for the cases SwiftUI's `ShareLink` cannot cover
/// — here, sharing a file that is generated at the moment the button is pressed.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// So a `URL` can drive `.sheet(item:)` directly.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

#Preview {
    NavigationStack {
        AssessScreen()
            .seismicBackground()
            .navigationTitle("Assess")
    }
    .environmentObject(AppEnvironment.preview())
    .preferredColorScheme(.dark)
}
