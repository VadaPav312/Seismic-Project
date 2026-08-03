import SwiftUI
import SeismicCore
import SeismicDevice

/// The board, in one place.
///
/// There were three separate destinations for one subject. "Hardware" held the
/// controls and the event sequence, "Sensors" held the six channels and the
/// fusion vote, and "Node" held a connection panel and a power budget — so
/// somebody looking for *why the node decided there was an earthquake* had to
/// already know it lived under the second and not the first or third, and the
/// orb's fan carried three entries that all meant "the board".
///
/// They are panes now. The split that survives is the one that is actually a
/// split: **Control** is what you do to the node, **Sensors** is what the node
/// can tell you. Everything else was navigation for its own sake.
struct HardwareScreen: View {
    @ObservedObject var link: SeismicNodeLink

    /// Remembered, because during a demonstration you come back to the same
    /// pane repeatedly and being returned to the other one each time is a small
    /// tax paid over and over.
    @AppStorage("hardware.pane") private var pane: Pane = .control

    enum Pane: String, CaseIterable, Identifiable {
        case control, sensors
        var id: String { rawValue }

        var title: String {
            switch self {
            case .control: "Control"
            case .sensors: "Sensors"
            }
        }

        var systemImage: String {
            switch self {
            case .control: "slider.horizontal.3"
            case .sensors: "chart.bar.doc.horizontal"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            picker
            Divider().overlay(Theme.Palette.hairline)

            switch pane {
            case .control: DeviceControlScreen(link: link)
            case .sensors: SensorChannelsScreen(link: link)
            }
        }
        .seismicBackground()
    }

    /// Above the content rather than in the toolbar, because the toolbar
    /// already carries Done and a title, and a segmented control squeezed
    /// between them is unreadable at the width a title leaves it.
    private var picker: some View {
        HStack(spacing: Theme.Metrics.s2) {
            ForEach(Pane.allCases) { candidate in
                Button {
                    withAnimation(Theme.Motion.quick) { pane = candidate }
                    Haptics.shared.play(.selection)
                } label: {
                    Label(candidate.title, systemImage: candidate.systemImage)
                        .font(Theme.Typography.callout.weight(.medium))
                        .foregroundStyle(pane == candidate ? Theme.Palette.textPrimary
                                                           : Theme.Palette.textTertiary)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Metrics.minimumTapTarget)
                        .background {
                            if pane == candidate {
                                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall,
                                                 style: .continuous)
                                    .fill(Theme.Palette.accentDim)
                                    .overlay(
                                        RoundedRectangle(
                                            cornerRadius: Theme.Metrics.cornerRadiusSmall,
                                            style: .continuous)
                                            .strokeBorder(Theme.Palette.accent.opacity(0.4),
                                                          lineWidth: 1))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(pane == candidate ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.vertical, Theme.Metrics.s3)
        .contentColumn()
    }
}

#Preview {
    NavigationStack { HardwareScreen(link: SeismicNodeLink()) }
        .previewEnvironment()
}
