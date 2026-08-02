import WidgetKit
import SwiftUI
import ActivityKit
import SeismicCore

@main
struct SeismicWidgetBundle: WidgetBundle {
    var body: some Widget {
        BuildingStatusWidget()
        // The Live Activity needs iOS 18, one version above the rest of the app,
        // and that is a deliberate trade rather than an oversight.
        //
        // Putting the countdown on a wrist means declaring a wrist-sized layout
        // with `supplementalActivityFamilies`, which is iOS 18. A widget
        // configuration cannot take a modifier conditionally the way a view can
        // — the modifier returns an opaque type, so the two branches have no
        // common type — and `WidgetBundleBuilder` only supports an availability
        // `if`, with no `else`. So it is one or the other, and registering both
        // would mean two configurations claiming the same activity type.
        //
        // On iOS 17 everything else still works: the full-screen takeover, the
        // haptic countdown, the warning notification and the home-screen widget
        // are all unaffected. What is lost is the Lock Screen card.
        if #available(iOS 18.0, *) {
            SeismicEventActivityOnWrist()
        }
    }
}

// MARK: - Palette

/// The widget carries its own copy of the few colours it needs.
///
/// It cannot import the app's design system — a widget extension is a separate
/// binary — and the alternative, a shared UI module, would drag SwiftUI into
/// the logic package for the sake of four colours. These are the same values,
/// and the verdict colours are the ones that must not drift.
private enum WidgetPalette {
    static let background = Color(red: 0.043, green: 0.051, blue: 0.063)
    static let surface = Color(red: 0.106, green: 0.122, blue: 0.149)
    static let textPrimary = Color(red: 0.937, green: 0.949, blue: 0.965)
    static let textSecondary = Color(red: 0.612, green: 0.647, blue: 0.694)
    static let textTertiary = Color(red: 0.408, green: 0.443, blue: 0.494)
    static let accent = Color(red: 0.227, green: 0.784, blue: 0.910)

    static func colour(for verdict: SafetyVerdict?) -> Color {
        switch verdict {
        case .green: Color(red: 0.298, green: 0.808, blue: 0.478)
        case .amber: Color(red: 0.976, green: 0.694, blue: 0.204)
        case .red: Color(red: 0.937, green: 0.325, blue: 0.314)
        case .needsInspection, .none: Color(red: 0.596, green: 0.612, blue: 0.663)
        }
    }
}

// MARK: - Home screen widget

struct BuildingStatusEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct BuildingStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> BuildingStatusEntry {
        BuildingStatusEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context,
                     completion: @escaping (BuildingStatusEntry) -> Void) {
        completion(BuildingStatusEntry(date: Date(), snapshot: WidgetBridge.read()))
    }

    /// Refreshed on the hour rather than every few minutes.
    ///
    /// A verdict does not change on its own — it changes when an earthquake
    /// happens, and at that moment the app reloads the timeline explicitly. A
    /// short refresh interval would spend the widget's daily budget on
    /// re-rendering an unchanged placard.
    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<BuildingStatusEntry>) -> Void) {
        let entry = BuildingStatusEntry(date: Date(), snapshot: WidgetBridge.read())
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct BuildingStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BuildingStatus", provider: BuildingStatusProvider()) { entry in
            BuildingStatusView(snapshot: entry.snapshot)
                .containerBackground(WidgetPalette.background, for: .widget)
        }
        .configurationDisplayName("Building status")
        .description("The latest verdict for your building, and whether the node is listening.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular,
                            .accessoryCircular])
    }
}

struct BuildingStatusView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .systemMedium: medium
        default: small
        }
    }

    private var verdictColour: Color { WidgetPalette.colour(for: snapshot.verdict) }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: snapshot.verdict?.systemImage ?? "questionmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                Text(snapshot.verdict?.shortLabel.uppercased() ?? "NO DATA")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
            }
            .foregroundStyle(verdictColour)

            Text(snapshot.buildingName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WidgetPalette.textPrimary)
                .lineLimit(2)

            Spacer(minLength: 0)

            if let period = snapshot.periodSeconds {
                Text(String(format: "%.2f s", period))
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(WidgetPalette.textPrimary)
                Text("natural period")
                    .font(.system(size: 9))
                    .foregroundStyle(WidgetPalette.textTertiary)
            }

            statusLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            small
            Divider().overlay(Color.white.opacity(0.08))
            VStack(alignment: .leading, spacing: 8) {
                if let change = snapshot.periodChangePercent {
                    metric(String(format: "%+.1f%%", change), "period change since baseline",
                           tint: abs(change) < 3 ? WidgetPalette.textPrimary : verdictColour)
                }
                if let assessedAt = snapshot.assessedAt {
                    metric(assessedAt.formatted(date: .abbreviated, time: .shortened),
                           "last assessed", tint: WidgetPalette.textSecondary)
                }
                if let lastEventAt = snapshot.lastEventAt {
                    metric(lastEventAt.formatted(.relative(presentation: .numeric)),
                           "last event", tint: WidgetPalette.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metric(_ value: String, _ label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(WidgetPalette.textTertiary)
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.verdict?.placard ?? "NO ASSESSMENT")
                .font(.system(size: 13, weight: .semibold))
            Text(snapshot.buildingName)
                .font(.system(size: 11))
                .lineLimit(1)
            if let period = snapshot.periodSeconds {
                Text(String(format: "%.2f s · %@", period,
                            snapshot.isNodeConnected ? "listening" : "offline"))
                    .font(.system(size: 10, design: .monospaced))
            }
        }
        .widgetAccentable()
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: snapshot.verdict?.systemImage ?? "questionmark.circle")
                .font(.system(size: 20, weight: .semibold))
        }
        .widgetAccentable()
    }

    /// Whether the data behind the placard is live. A widget showing a green
    /// verdict from a node that has been offline for a week is worse than one
    /// admitting it does not know.
    private var statusLine: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(snapshot.isNodeConnected ? WidgetPalette.accent
                                               : WidgetPalette.textTertiary)
                .frame(width: 5, height: 5)
            Text(snapshot.isNodeConnected
                 ? (snapshot.isSimulated ? "Simulated node" : "Node listening")
                 : "Node offline")
                .font(.system(size: 9))
                .foregroundStyle(WidgetPalette.textTertiary)
        }
    }
}

// MARK: - Live Activity

/// The event activity, declaring that it also has a layout small enough for a
/// watch face.
///
/// This is the whole of what it takes to put the countdown on a wrist. A Live
/// Activity started on the phone is already relayed to a paired Apple Watch's
/// Smart Stack; without this declaration the watch has to squeeze the Lock
/// Screen layout, which was designed around a nineteen-point instruction and
/// does not survive the trip. Declaring the small family gets a layout drawn
/// for the size it will actually appear at — see `LockScreenEventView`, which
/// reads `activityFamily` and drops everything except the number and the verb.
@available(iOS 18.0, *)
struct SeismicEventActivityOnWrist: Widget {
    var body: some WidgetConfiguration {
        eventActivityConfiguration()
            .supplementalActivityFamilies([.small])
    }
}

@available(iOS 16.2, *)
private func eventActivityConfiguration() -> some WidgetConfiguration {
    ActivityConfiguration(for: SeismicEventAttributes.self) { context in
            LockScreenEventView(context: context)
                .activityBackgroundTint(WidgetPalette.background)
                .activitySystemActionForegroundColor(WidgetPalette.accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.buildingName)
                            .font(.system(size: 12))
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: context.state.stage.systemImage)
                            .foregroundStyle(WidgetPalette.colour(for: context.state.verdict))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let seconds = context.state.secondsUntilShaking, seconds > 0 {
                        Text("\(seconds) s")
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundStyle(WidgetPalette.colour(for: nil))
                    } else if let magnitude = context.state.estimatedMagnitude {
                        Text(String(format: "M%.1f", magnitude))
                            .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.stage.instruction)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(WidgetPalette.textPrimary)
                        if context.state.actuatorsFired > 0 {
                            Text("\(context.state.actuatorsConfirmed) of "
                                 + "\(context.state.actuatorsFired) actions confirmed")
                                .font(.system(size: 11))
                                .foregroundStyle(WidgetPalette.textSecondary)
                        }
                        if context.state.isDrill {
                            Text("This is a drill.")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(WidgetPalette.accent)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.stage.systemImage)
                    .foregroundStyle(WidgetPalette.colour(for: context.state.verdict))
            } compactTrailing: {
                Text(context.state.primaryLine)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
            } minimal: {
                Image(systemName: context.state.stage.systemImage)
                    .foregroundStyle(WidgetPalette.colour(for: context.state.verdict))
            }
            .keylineTint(WidgetPalette.accent)
        }
}

/// The Lock Screen presentation.
///
/// Built around one instruction in the largest type that fits. Everything else
/// — magnitude, building name, actuator progress — is secondary, because the
/// person reading this may be holding a child under a table.
@available(iOS 16.2, *)
struct LockScreenEventView: View {
    let context: ActivityViewContext<SeismicEventAttributes>

    var body: some View {
        if #available(iOS 18.0, *) {
            FamilyAwareEventView(context: context)
        } else {
            lockScreenLayout
        }
    }

    /// Picks a layout from how big the surface actually is.
    ///
    /// `activityFamily` is `.small` on a watch and `.medium` on the phone's
    /// Lock Screen. Reading it is the difference between a wrist showing "7"
    /// and a wrist showing a truncated sentence about actuator confirmations.
    @available(iOS 18.0, *)
    private struct FamilyAwareEventView: View {
        @Environment(\.activityFamily) private var family
        let context: ActivityViewContext<SeismicEventAttributes>

        var body: some View {
            if family == .small {
                LockScreenEventView(context: context).wristLayout
            } else {
                LockScreenEventView(context: context).lockScreenLayout
            }
        }
    }

    /// A watch face at arm's length, mid-earthquake. Two things fit: how long
    /// you have, and what to do. Nothing else earns its place — the building
    /// name, the magnitude and the actuator tally are all things you would only
    /// read afterwards, and afterwards you will have your phone.
    var wristLayout: some View {
        VStack(spacing: 0) {
            if let seconds = context.state.secondsUntilShaking, seconds > 0 {
                Text("\(seconds)")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(WidgetPalette.textPrimary)
            } else {
                Image(systemName: context.state.stage.systemImage)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(WidgetPalette.colour(for: context.state.verdict))
            }

            Text(context.state.stage.instruction)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(WidgetPalette.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)

            if context.state.isDrill {
                Text("DRILL")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(WidgetPalette.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(6)
    }

    var lockScreenLayout: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(spacing: 2) {
                Image(systemName: context.state.stage.systemImage)
                    .font(.system(size: 22))
                    .foregroundStyle(WidgetPalette.colour(for: context.state.verdict))
                if let seconds = context.state.secondsUntilShaking, seconds > 0 {
                    Text("\(seconds)")
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .foregroundStyle(WidgetPalette.textPrimary)
                    Text("seconds")
                        .font(.system(size: 9))
                        .foregroundStyle(WidgetPalette.textTertiary)
                }
            }
            .frame(width: 68)

            VStack(alignment: .leading, spacing: 4) {
                Text(context.state.stage.instruction)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(WidgetPalette.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)

                HStack(spacing: 6) {
                    Text(context.attributes.buildingName)
                        .font(.system(size: 12))
                        .foregroundStyle(WidgetPalette.textSecondary)
                        .lineLimit(1)
                    if let magnitude = context.state.estimatedMagnitude {
                        Text(String(format: "M%.1f", magnitude))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(WidgetPalette.textSecondary)
                    }
                    if let intensity = context.state.intensityLabel {
                        Text(intensity)
                            .font(.system(size: 12))
                            .foregroundStyle(WidgetPalette.textSecondary)
                    }
                }

                if context.state.actuatorsFired > 0 {
                    Text("\(context.state.actuatorsConfirmed)/\(context.state.actuatorsFired) "
                         + "safety actions confirmed")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(WidgetPalette.accent)
                }

                if context.state.isDrill {
                    Text("DRILL — nothing has actually fired")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(WidgetPalette.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}
