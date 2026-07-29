import SwiftUI
import SeismicCore
import SeismicStructures

/// The plain-language reading of a building, in the interface.
///
/// Deliberately placed *above* the technical readouts everywhere it appears.
/// The numbers are the evidence and they stay on the screen, but somebody who
/// opens a building wanting to know what it means for them should not have to
/// scroll past four periods and a bending percentage to find out — and if they
/// read only the first card, they should still have got the honest answer
/// rather than a partial one.
struct PlainReadingCard: View {
    let reading: PlainReading

    /// Collapsed to the headline and the worst two points, with the rest behind
    /// a tap. Everything is present either way; this only decides how much of it
    /// arrives at once.
    @State private var isExpanded = false

    private var tint: Color {
        switch reading.level {
        case .ordinary: Theme.Palette.verdictGreen
        case .worthKnowing: Theme.Palette.verdictAmber
        case .serious: Theme.Palette.verdictRed
        }
    }

    /// Collapsed, exactly the points at the level the header announces — so the
    /// header's count and the list agree. A first version showed the first two
    /// regardless, which had the header say "two things" above a list offering a
    /// third.
    private var visiblePoints: [PlainReading.Point] {
        isExpanded ? reading.points : reading.points.filter { $0.severity == reading.level }
    }

    private var hiddenPoints: [PlainReading.Point] {
        reading.points.filter { $0.severity != reading.level }
    }

    /// What the hidden points are.
    ///
    /// When they are all `ordinary` they are not withheld concerns — they are
    /// the building's redeeming features, and calling them "more reasons" both
    /// misdescribes them and makes the card look worse than the reading is.
    private var disclosureLabel: String {
        let count = hiddenPoints.count
        if reading.level != .ordinary, hiddenPoints.allSatisfy({ $0.severity == .ordinary }) {
            return count == 1 ? "1 point in its favour" : "\(count) points in its favour"
        }
        return count == 1 ? "1 more reason" : "\(count) more reasons"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            header

            Text(reading.summary)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !reading.points.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
                    ForEach(visiblePoints) { point in
                        pointRow(point)
                    }
                }

                if !hiddenPoints.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) { isExpanded.toggle() }
                    } label: {
                        Text(isExpanded ? "Show less" : disclosureLabel)
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.accent)
                    }
                    .buttonStyle(.plain)
                }
            }

            if isExpanded || hiddenPoints.isEmpty {
                Divider().overlay(Theme.Palette.hairline)
                actions
                confidence
            }

            // Always shown, collapsed or not. It is the one line that must never
            // be behind a tap.
            Text(reading.caveat)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .instrumentPanel()
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.spacing) {
            // Glyph as well as colour, so the level survives colour blindness
            // and a greyscale screenshot — the same rule the safety placards use.
            Image(systemName: reading.level.systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(reading.level.label.uppercased())
                    .font(Theme.Typography.label)
                    .foregroundStyle(tint)
                Text(reading.headline)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(reading.level.label). \(reading.headline)")
    }

    private func pointRow(_ point: PlainReading.Point) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(severityTint(point.severity))
                .frame(width: 7, height: 7)
                .padding(.top, 7)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(point.title)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    // Marked inline rather than in a footnote: a point resting on
                    // a guess should carry that with it, wherever it is read.
                    if point.isInferred {
                        Text("inferred")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textGhost)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Theme.Palette.glass))
                    }
                }
                Text(point.meaning)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("What you can do", systemImage: "checklist")
            ForEach(Array(reading.actions.enumerated()), id: \.offset) { _, action in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Palette.accent)
                        .padding(.top, 3)
                        .accessibilityHidden(true)
                    Text(action)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var confidence: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("HOW MUCH OF THIS IS KNOWN")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer(minLength: 0)
                Text("\(Int((reading.confidence * 100).rounded()))%")
                    .font(Theme.Typography.label)
                    .foregroundStyle(reading.confidence < 0.55
                                     ? Theme.Palette.verdictAmber
                                     : Theme.Palette.textSecondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Palette.glass)
                    Capsule()
                        .fill(reading.confidence < 0.55
                              ? Theme.Palette.verdictAmber
                              : Theme.Palette.accent)
                        .frame(width: geometry.size.width * reading.confidence)
                }
            }
            .frame(height: 4)

            Text(reading.confidenceNote)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func severityTint(_ severity: PlainReading.Level) -> Color {
        switch severity {
        case .ordinary: Theme.Palette.verdictGreen
        case .worthKnowing: Theme.Palette.verdictAmber
        case .serious: Theme.Palette.verdictRed
        }
    }
}
