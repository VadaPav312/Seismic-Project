import SwiftUI
import SeismicCore

// The shared vocabulary of the interface. Everything here exists because it
// appears on more than one screen; anything used once lives with its screen.

// MARK: - Section header

/// Wide-tracked small caps, as used to label a region of an instrument panel.
struct SectionLabel: View {
    let text: String
    var trailing: String?
    var systemImage: String?

    init(_ text: String, systemImage: String? = nil, trailing: String? = nil) {
        self.text = text
        self.systemImage = systemImage
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            Text(text.uppercased())
                .font(Theme.Typography.label)
                .tracking(1.1)
                .foregroundStyle(Theme.Palette.textTertiary)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(Theme.Typography.numericSmall)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Numeric readout

/// A labelled figure. The workhorse of the whole interface.
struct Readout: View {
    let label: String
    let value: String
    var unit: String?
    var tint: Color = Theme.Palette.textPrimary
    var size: Size = .medium
    var caption: String?

    enum Size { case small, medium, large, display }

    private var valueFont: Font {
        switch size {
        case .small: Theme.Typography.numericSmall
        case .medium: Theme.Typography.numeric
        case .large: Theme.Typography.numericLarge
        case .display: Theme.Typography.display(44)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: size == .display ? 2 : 3) {
            Text(label.uppercased())
                .font(Theme.Typography.label)
                .tracking(1.0)
                .foregroundStyle(Theme.Palette.textTertiary)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(valueFont)
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(size == .display ? Theme.Typography.callout : Theme.Typography.numericSmall)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)

            if let caption {
                Text(caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value) \(unit ?? "")")
    }
}

/// A row of readouts that wraps sensibly on narrow screens.
struct ReadoutGrid: View {
    let readouts: [Readout]
    var columns: Int = 2

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading),
                                 count: columns),
                  alignment: .leading, spacing: Theme.Metrics.spacing) {
            ForEach(Array(readouts.enumerated()), id: \.offset) { _, readout in
                readout
            }
        }
    }
}

// MARK: - Verdict placard

/// The single most important thing the app ever displays.
///
/// Deliberately enormous, deliberately plain, and never abbreviated. It carries
/// its verdict in four independent channels — colour, glyph, wording and border
/// weight — so it survives colour blindness, greyscale printing, a cracked
/// screen and a glance.
struct VerdictPlacard: View {
    let verdict: SafetyVerdict
    var confidence: Double?
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 8 : 14) {
            Image(systemName: verdict.systemImage)
                .font(.system(size: compact ? 30 : 52, weight: .medium))
                .foregroundStyle(verdict.color)

            Text(verdict.placard)
                .font(compact ? Theme.Typography.headline
                              : .system(size: 30, weight: .bold, design: .default))
                .tracking(compact ? 0.5 : 1.5)
                .foregroundStyle(verdict.color)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)

            if !compact {
                Text(verdict.plainMeaning)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let confidence {
                ConfidenceBar(confidence: confidence, tint: verdict.color)
                    .frame(maxWidth: 220)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(compact ? Theme.Metrics.cardPadding : 26)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusLarge, style: .continuous)
                .fill(verdict.color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusLarge, style: .continuous)
                .strokeBorder(verdict.color.opacity(0.55), lineWidth: verdict.borderWidth)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(verdict.placard)
        .accessibilityValue(verdict.plainMeaning)
    }
}

/// How sure the app is, shown as a bar rather than a number because "72%
/// confident" invites false precision.
struct ConfidenceBar: View {
    let confidence: Double
    var tint: Color = Theme.Palette.accent

    private var descriptor: String {
        switch confidence {
        case ..<0.35: "Low confidence"
        case 0.35..<0.65: "Moderate confidence"
        case 0.65..<0.85: "Good confidence"
        default: "High confidence"
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Palette.surfaceHighest)
                    Capsule()
                        .fill(tint.opacity(0.85))
                        .frame(width: geometry.size.width * min(max(confidence, 0), 1))
                }
            }
            .frame(height: 5)

            Text(descriptor)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Confidence")
        .accessibilityValue(descriptor)
    }
}

// MARK: - Status pill

struct StatusPill: View {
    let text: String
    var systemImage: String?
    var tint: Color = Theme.Palette.textSecondary
    var filled = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(Theme.Typography.label)
                .tracking(0.4)
        }
        .foregroundStyle(filled ? Color.black.opacity(0.85) : tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(filled ? tint : tint.opacity(0.14))
        )
        .overlay(
            Capsule().strokeBorder(filled ? .clear : tint.opacity(0.28), lineWidth: 1)
        )
    }
}

/// Connection state, shown wherever live data appears.
///
/// The requirement is explicit: the user must never wonder whether what they are
/// looking at is real. Simulated data says so, in words, every time.
struct ConnectionBadge: View {
    let state: ConnectionState
    var showsLabel = true

    var body: some View {
        StatusPill(text: showsLabel ? state.label : "",
                   systemImage: state.systemImage,
                   tint: state.color,
                   filled: state.isSimulated)
            .accessibilityLabel("Connection: \(state.label)")
    }
}

// MARK: - Cards

/// A tappable card that expands into a detail view, preserving spatial
/// continuity rather than cutting.
struct BuildingCard: View {
    let building: BuildingModel
    var verdict: SafetyVerdict?
    var subtitle: String?
    var namespace: Namespace.ID?

    var body: some View {
        HStack(spacing: Theme.Metrics.spacing) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall, style: .continuous)
                    .fill(Theme.Palette.surfaceRaised)
                    .frame(width: 54, height: 54)
                Image(systemName: building.thumbnailSystemImage)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Theme.Palette.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(building.name)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)

                Text(subtitle ?? "\(building.storeyCount) storeys · "
                     + "\(Int(building.height)) m · "
                     + String(format: "T ≈ %.2f s", building.empiricalPeriod))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)

                if building.isSandbox {
                    StatusPill(text: "Your building", systemImage: "star.fill",
                               tint: Theme.Palette.accent)
                }
            }

            Spacer(minLength: 0)

            if let verdict {
                VStack(spacing: 3) {
                    Image(systemName: verdict.systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(verdict.color)
                    Text(verdict.shortLabel)
                        .font(Theme.Typography.label)
                        .foregroundStyle(verdict.color)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .instrumentPanel()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Empty and error states

/// Every empty state is designed: an illustration, an explanation of *why* it is
/// empty, and a way forward. There are no blank screens anywhere in this app.
struct DesignedEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var secondaryActionTitle: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Metrics.spacingLoose) {
            ZStack {
                Circle()
                    .fill(Theme.Palette.accent.opacity(0.10))
                    .frame(width: 96, height: 96)
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Theme.Palette.accent)
            }

            VStack(spacing: 8) {
                Text(title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 340)

            VStack(spacing: 10) {
                if let actionTitle, let action {
                    Button(action: action) {
                        Text(actionTitle)
                            .font(Theme.Typography.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: Theme.Metrics.minimumTapTarget)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                if let secondaryActionTitle, let secondaryAction {
                    Button(secondaryActionTitle, action: secondaryAction)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.accent)
                }
            }
            .frame(maxWidth: 320)
        }
        .padding(Theme.Metrics.spacingSection)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// Makes a view take the full height its scroll container can show, so its
    /// contents sit in the middle of the screen rather than at the top of it.
    ///
    /// `maxHeight: .infinity` does not do this inside a `ScrollView`: the scroll
    /// view offers its content unbounded height, so "infinity" resolves to the
    /// content's own natural height and the view stays exactly as tall as what
    /// is inside it. That is why the empty states sat under the navigation bar
    /// with two-thirds of the screen empty beneath them.
    ///
    /// Only for views that are the *entire* contents of a screen. Applied to
    /// something sharing a scroll view with other sections it would push
    /// everything else off the bottom.
    func fillsAvailableHeight(minimum: CGFloat = 360) -> some View {
        containerRelativeFrame(.vertical, alignment: .center) { height, _ in
            Swift.max(height, minimum)
        }
    }
}

/// Errors are plain language with a way forward, never a code.
struct InlineNotice: View {
    enum Level { case info, warning, critical

        var tint: Color {
            switch self {
            case .info: Theme.Palette.accent
            case .warning: Color(red: 0.90, green: 0.72, blue: 0.35)
            case .critical: Theme.Palette.verdictRed
            }
        }

        var icon: String {
            switch self {
            case .info: "info.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .critical: "exclamationmark.octagon.fill"
            }
        }
    }

    let level: Level
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: level.icon)
                .font(.system(size: 15))
                .foregroundStyle(level.tint)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(Theme.Typography.callout.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(message)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(level.tint)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall, style: .continuous)
                .fill(level.tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall, style: .continuous)
                .strokeBorder(level.tint.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

/// Loading is skeleton content or meaningful progress — never an unexplained
/// spinner. The user is told what is happening and roughly how long it will take.
struct MeaningfulProgress: View {
    let title: String
    var detail: String?
    var progress: Double?

    var body: some View {
        VStack(spacing: 12) {
            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(Theme.Palette.accent)
                    .frame(maxWidth: 260)
            } else {
                ProgressView()
                    .tint(Theme.Palette.accent)
            }

            Text(title)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textPrimary)

            if let detail {
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Theme.Metrics.spacingLoose)
        .frame(maxWidth: .infinity)
    }
}

/// Skeleton placeholder, for content that is about to arrive.
struct SkeletonBlock: View {
    var height: CGFloat = 14
    var width: CGFloat?
    @State private var shimmer = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Theme.Palette.surfaceHighest)
            .frame(width: width, height: height)
            .opacity(shimmer ? 0.55 : 1.0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    shimmer = true
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.Palette.accent
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(destructive ? Color.white : Color.black.opacity(0.88))
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall, style: .continuous)
                    .fill(destructive ? Theme.Palette.verdictRed : tint)
                    .opacity(configuration.isPressed ? 0.75 : 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.Palette.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall, style: .continuous)
                    .fill(Theme.Palette.surfaceRaised)
                    .opacity(configuration.isPressed ? 0.7 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall, style: .continuous)
                    .strokeBorder(Theme.Palette.hairlineStrong, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
    }
}

/// A large, unmissable action for use during an event.
struct EmergencyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusLarge, style: .continuous)
                    .fill(Color.white)
                    .opacity(configuration.isPressed ? 0.8 : 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
    }
}

// MARK: - Evidence row

/// One piece of evidence behind a verdict. Every contributing measurement gets
/// one of these; nothing influences a verdict invisibly.
struct EvidenceRow: View {
    let evidence: Evidence
    var showsWeight = true

    private var indicationColor: Color {
        switch evidence.damageIndication {
        case ..<(-0.2): Theme.Palette.verdictGreen
        case (-0.2)..<0.3: Theme.Palette.textSecondary
        case 0.3..<0.7: Theme.Palette.verdictAmber
        default: Theme.Palette.verdictRed
        }
    }

    private var indicationLabel: String {
        switch evidence.damageIndication {
        case ..<(-0.2): "Reassuring"
        case (-0.2)..<0.3: "Neutral"
        case 0.3..<0.7: "Concerning"
        default: "Strong indication"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: evidence.kind.systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(indicationColor)
                    .frame(width: 18)

                Text(evidence.kind.label)
                    .font(Theme.Typography.label)
                    .tracking(0.8)
                    .foregroundStyle(Theme.Palette.textTertiary)

                Spacer(minLength: 0)

                StatusPill(text: indicationLabel, tint: indicationColor)
            }

            Text(evidence.headline)
                .font(Theme.Typography.numeric)
                .foregroundStyle(Theme.Palette.textPrimary)

            Text(evidence.detail)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if showsWeight {
                HStack(spacing: 6) {
                    Text("Source: \(FactProvenance(source: evidence.source).source.label)")
                    Text("·")
                    Text(String(format: "Weight %.1f", evidence.weight))
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel(padding: 13)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Provenance chip

/// Shows where a fact came from and how much to trust it. Attached to every
/// imported attribute, because presenting a guess as a certainty is the fastest
/// way to lose an engineer's trust.
struct ProvenanceChip: View {
    let provenance: FactProvenance

    private var tint: Color {
        provenance.isConfirmed ? Theme.Palette.accent
            : (provenance.confidence > 0.55 ? Theme.Palette.textSecondary
                                            : Color(red: 0.85, green: 0.70, blue: 0.35))
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: provenance.isConfirmed ? "checkmark.seal" : "questionmark.circle")
                .font(.system(size: 9))
            Text(provenance.source.label)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.12)))
        .accessibilityLabel("Source: \(provenance.source.label), "
                            + "confidence \(Int(provenance.confidence * 100)) per cent")
    }
}

// MARK: - Glossary term

/// Long-press any technical term for a plain-language explanation. Available
/// from anywhere in the app.
struct GlossaryTerm: View {
    let term: String
    @State private var showing = false

    var body: some View {
        Text(term)
            .underline(true, pattern: .dot)
            .foregroundStyle(Theme.Palette.accent)
            .onLongPressGesture { showing = true }
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(term)
                        .font(Theme.Typography.headline)
                    Text(Glossary.definition(for: term))
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
                .frame(maxWidth: 320)
                .presentationCompactAdaptation(.popover)
            }
            .accessibilityHint("Double tap and hold for a definition")
    }
}

#Preview("Components") {
    ScrollView {
        VStack(spacing: 16) {
            VerdictPlacard(verdict: .amber, confidence: 0.68)
            VerdictPlacard(verdict: .green, compact: true)
            InlineNotice(level: .warning, title: "Brownout detected",
                         message: NodeFault.brownout.guidance,
                         actionTitle: "Open diagnostics") {}
            EvidenceRow(evidence: Evidence(
                kind: .periodChange, headline: "+11.4% period change",
                detail: "A lengthening of this size normally means the structure has lost "
                    + "measurable stiffness.",
                value: 11.4, unit: "%", damageIndication: 0.6, weight: 1.6))
            HStack {
                ConnectionBadge(state: .simulated)
                ConnectionBadge(state: .connected(rssi: -50))
                ConnectionBadge(state: .reconnecting(attempt: 2, nextRetryIn: 4))
            }
        }
        .padding()
    }
    .seismicBackground()
    .preferredColorScheme(.dark)
}
