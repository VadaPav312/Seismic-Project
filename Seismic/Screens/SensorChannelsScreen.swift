import SwiftUI
import Charts
import SeismicCore
import SeismicDevice

/// Six sensors, shown separately, with one combined answer above them.
///
/// The layout is the argument. A single "shaking: 84%" number would be smaller,
/// prettier and would destroy the only interesting thing this node does —
/// which is that no individual sensor can tell an earthquake from a lorry, and
/// the way around that is to make three of them agree.
///
/// So the fusion vote is the largest element on the screen, and the moment it
/// says "1 of 3 — not declared" is the moment the whole design becomes obvious
/// to somebody watching. The six channels sit underneath, each with its own
/// live reading, so the claim can be checked rather than believed.
struct SensorChannelsScreen: View {
    @ObservedObject var link: SeismicNodeLink

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Metrics.spacingLoose) {
                fusionVerdict
                trace
                shakeChannels
                supportingChannels
            }
            .padding(Theme.Metrics.screenPadding)
            .contentColumn()
        }
    }

    // MARK: The combined answer

    /// Is this an earthquake?
    private var fusionVerdict: some View {
        let votes = link.votes
        return VStack(spacing: Theme.Metrics.spacing) {
            Text("IS THIS AN EARTHQUAKE")
                .font(Theme.Typography.label)
                .tracking(1.6)
                .foregroundStyle(Theme.Palette.textTertiary)

            Text(votes.summary)
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(votes.isDeclared ? Theme.Palette.verdictAmber
                                                  : Theme.Palette.textPrimary)
                .multilineTextAlignment(.center)
                .contentTransition(.numericText())
                .animation(Theme.Motion.standard, value: votes.count)

            // Three lamps, one per channel. Lit means that channel is currently
            // voting; the ring is what it is voting *about*.
            HStack(spacing: Theme.Metrics.spacing) {
                voteLamp("Accelerometer", "waveform.path.ecg", votes.accelerometer)
                voteLamp("Tilt", "gyroscope", votes.tilt)
                voteLamp("Sound", "waveform", votes.sound)
            }

            Text(votes.isDeclared
                 ? "Two of the three shake channels agreed inside six hundred milliseconds, "
                   + "so the node declared an event and began its sequence."
                 : "An event needs at least two of the three to agree within six hundred "
                   + "milliseconds. One channel on its own is a lorry, a slammed door or "
                   + "somebody leaning on the bench — and rejecting those is what the vote "
                   + "is for.")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if link.canNudge {
                Button {
                    link.nudgeSingleChannel()
                    Haptics.shared.play(.selection)
                } label: {
                    Label("Fire one channel only", systemImage: "1.circle")
                        .font(Theme.Typography.callout)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            if let telemetry = link.telemetry {
                Divider().overlay(Theme.Palette.hairline)
                HStack {
                    StatusPill(text: telemetry.state.label,
                               tint: telemetry.state.isArmed ? Theme.Palette.accent
                                                             : Theme.Palette.textSecondary)
                    Spacer()
                    if telemetry.isOccupied {
                        // Escalation: somebody is in the building.
                        StatusPill(text: "OCCUPIED", tint: Theme.Palette.verdictAmber)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .instrumentPanel()
    }

    private func voteLamp(_ title: String, _ symbol: String, _ isVoting: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(isVoting ? Theme.Palette.verdictAmber.opacity(0.22)
                                   : Theme.Palette.surfaceHighest)
                    .frame(width: 54, height: 54)
                Circle()
                    .strokeBorder(isVoting ? Theme.Palette.verdictAmber
                                           : Theme.Palette.hairline,
                                  lineWidth: isVoting ? 2.5 : 1)
                    .frame(width: 54, height: 54)
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(isVoting ? Theme.Palette.verdictAmber
                                              : Theme.Palette.textGhost)
            }
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isVoting ? Theme.Palette.textPrimary
                                          : Theme.Palette.textTertiary)
            Text(isVoting ? "YES" : "—")
                .font(Theme.Typography.numericSmall)
                .foregroundStyle(isVoting ? Theme.Palette.verdictAmber
                                          : Theme.Palette.textGhost)
        }
        .frame(maxWidth: .infinity)
        .animation(Theme.Motion.quick, value: isVoting)
    }

    // MARK: Trace

    private var trace: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Live motion", systemImage: "waveform.path",
                         trailing: link.trace.isEmpty ? nil : "\(link.trace.count) samples")

            if link.trace.count > 4 {
                let points = Array(link.trace.enumerated()).map {
                    TracePoint(id: $0.offset, value: $0.element)
                }
                Chart(points) { point in
                    LineMark(x: .value("Sample", point.id),
                             y: .value("Acceleration", point.value))
                        .foregroundStyle(Theme.Palette.accent)
                }
                .chartXAxis(.hidden)
                .chartYAxisLabel("m/s²")
                .frame(height: 130)
            } else {
                Text("Waiting for samples. The node streams about ten a second while it is "
                     + "monitoring or disarmed, and stops while it is running an event — the "
                     + "recording is transferred whole afterwards instead.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private struct TracePoint: Identifiable {
        let id: Int
        let value: Double
    }

    // MARK: The three shake channels

    private var shakeChannels: some View {
        VStack(spacing: Theme.Metrics.spacingLoose) {
            accelerometerChannel
            tiltChannel
            soundChannel
        }
    }

    private var accelerometerChannel: some View {
        let telemetry = link.telemetry
        let ratio = telemetry?.ratio ?? 1
        let threshold = telemetry?.triggerThreshold ?? 4

        return channel(
            title: "1 · Accelerometer",
            subtitle: "Primary shake channel",
            systemImage: "waveform.path.ecg",
            isVoting: link.votes.accelerometer,
            explanation: "A short-term average of the motion divided by a long-term one. At "
                + "rest the two are the same and the ratio sits near 1.0; shaking drives the "
                + "short-term average up and the ratio with it. Comparing a signal against "
                + "its own recent history is what makes this work in a noisy building "
                + "instead of needing a fixed threshold per site."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ReadoutGrid(readouts: [
                    Readout(label: "Trigger ratio", value: String(format: "%.2f", ratio),
                            unit: "×",
                            tint: ratio >= threshold ? Theme.Palette.verdictAmber
                                                     : Theme.Palette.textPrimary,
                            size: .large),
                    Readout(label: "Votes at", value: String(format: "%.1f", threshold),
                            unit: "×", size: .large),
                ], columns: 2)

                // The ratio against its threshold, as a bar. A number moving
                // between 1.0 and 1.1 is invisible; a bar filling towards a
                // marked line is not.
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Theme.Palette.surfaceHighest)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(ratio >= threshold ? Theme.Palette.verdictAmber
                                                     : Theme.Palette.accent)
                            .frame(width: proxy.size.width
                                   * min(ratio / max(threshold * 1.5, 1), 1))
                        Rectangle()
                            .fill(Theme.Palette.textSecondary)
                            .frame(width: 1.5)
                            .offset(x: proxy.size.width
                                    * min(threshold / max(threshold * 1.5, 1), 1))
                    }
                }
                .frame(height: 14)
            }
        }
    }

    private var tiltChannel: some View {
        let isTilted = link.telemetry?.isTilted ?? false
        let isPermanent = link.assessment?.hasPermanentTilt ?? false

        return channel(
            title: "2 · Tilt switch",
            subtitle: "Independent shake confirmation",
            systemImage: "gyroscope",
            isVoting: link.votes.tilt,
            explanation: "A ball in a tube. It rattles when the bench moves, which is a "
                + "completely different physical principle from the accelerometer — so the "
                + "two failing together needs two unrelated things to go wrong at once. "
                + "After an event it means something else entirely: a tilt that is still "
                + "there once the shaking has stopped is a building that ended up leaning, "
                + "and that forces a red verdict on its own."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    StatusPill(text: isTilted ? "ACTIVE" : "AT REST",
                               tint: isTilted ? Theme.Palette.verdictAmber
                                              : Theme.Palette.textSecondary)
                    Spacer()
                }
                if isPermanent {
                    InlineNotice(
                        level: .critical,
                        title: "Permanent tilt",
                        message: "The switch is still active after the shaking stopped. The "
                            + "structure ended up leaning, which no temperature effect can "
                            + "explain and which is enough for a red verdict by itself.")
                }
            }
        }
    }

    private var soundChannel: some View {
        let level = link.telemetry?.soundLevel ?? 0
        let baseline = link.calibration?.soundBaseline ?? 118

        return channel(
            title: "3 · Sound sensor",
            subtitle: "Independent shake confirmation",
            systemImage: "waveform",
            isVoting: link.votes.sound,
            explanation: "Earthquakes are loud: structures creak, contents rattle, and a "
                + "building resonates. A silent event is almost always electrical noise on "
                + "the analogue input rather than anything mechanical — so this channel is "
                + "cheap and rejects a whole class of false trigger the accelerometer cannot."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ReadoutGrid(readouts: [
                    Readout(label: "Level", value: "\(level)", size: .large,
                            caption: "0–1023"),
                    Readout(label: "Learned quiet floor", value: "\(baseline)", size: .large,
                            caption: "set by calibration"),
                ], columns: 2)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Theme.Palette.surfaceHighest)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(level > baseline + 60 ? Theme.Palette.verdictAmber
                                                        : Theme.Palette.accent)
                            .frame(width: proxy.size.width * min(Double(level) / 1023, 1))
                        // The learned baseline, drawn as the reference line.
                        Rectangle()
                            .fill(Theme.Palette.textSecondary)
                            .frame(width: 1.5)
                            .offset(x: proxy.size.width * min(Double(baseline) / 1023, 1))
                    }
                }
                .frame(height: 14)
            }
        }
    }

    // MARK: The three supporting channels

    /// Only the channels the board is actually reporting.
    ///
    /// A sensor that is not fitted, or whose divider is reading a rail, has
    /// nothing to say — and a panel of warnings about hardware that is not
    /// there is a worse answer than a shorter list. They come back on their own
    /// the moment they start reporting, because this is derived from live
    /// telemetry rather than from a setting somebody has to remember to change.
    ///
    /// What is missing is still named, once, at the bottom. Hiding a dead
    /// sensor is tidy; pretending the node has six working channels when it has
    /// five would be a lie, and this screen's whole argument is that each
    /// channel is independently accountable.
    @ViewBuilder
    private var supportingChannels: some View {
        VStack(spacing: Theme.Metrics.spacingLoose) {
            occupancyChannel
            if isTemperatureReporting { temperatureChannel }
            if isPhotoresistorReporting { photoresistorChannel }

            if !absentChannels.isEmpty {
                Text(absentSentence)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The thermistor announces its own failure: the firmware sends −99 when
    /// the divider reads a rail, which means open or shorted rather than very
    /// cold.
    private var isTemperatureReporting: Bool {
        link.telemetry?.isTemperatureValid ?? false
    }

    /// A photoresistor that is not fitted leaves the analogue pin floating, and
    /// a floating pin sits at one rail or the other. A real cell in a real room
    /// is never at either.
    private var isPhotoresistorReporting: Bool {
        guard let reading = link.telemetry?.photoresistor else { return false }
        return reading > 2 && reading < 1021
    }

    private var absentChannels: [String] {
        var missing: [String] = []
        if !isTemperatureReporting { missing.append("the thermistor") }
        if !isPhotoresistorReporting { missing.append("the photoresistor") }
        return missing
    }

    private var absentSentence: String {
        let list = absentChannels.count > 1
            ? absentChannels.dropLast().joined(separator: ", ") + " and " + absentChannels[absentChannels.count - 1]
            : absentChannels.first ?? ""
        let verb = absentChannels.count > 1 ? "are" : "is"
        return "\(list.capitalisedSentence) \(verb) not reporting, so \(absentChannels.count > 1 ? "those channels are" : "that channel is") not shown. "
            + "They appear here the moment the board starts sending values for them. "
            + "Without the thermistor a period comparison carries the seasonal drift "
            + "uncorrected, which the assessment says where it matters."
    }

    private var occupancyChannel: some View {
        let isOccupied = link.telemetry?.isOccupied ?? false
        let verdict = link.assessment?.verdict

        return channel(
            title: "4 · Occupancy",
            subtitle: "Alert escalation",
            systemImage: "figure.walk.motion",
            isVoting: nil,
            explanation: "A passive infrared sensor. It takes no part in the vote — motion is "
                + "not evidence of an earthquake — but it changes what the answer is *for*: "
                + "an empty building that needs evacuating is a notification, and an occupied "
                + "one is an emergency."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                StatusPill(text: isOccupied ? "SOMEBODY IS PRESENT" : "CLEAR",
                           tint: isOccupied ? Theme.Palette.verdictAmber
                                            : Theme.Palette.textSecondary)

                if isOccupied, let verdict, verdict == .red || verdict == .amber {
                    InlineNotice(
                        level: .critical,
                        title: "Occupied, and just tagged \(verdict.placard.lowercased())",
                        message: "Motion was detected after a verdict that says this building "
                            + "should not be occupied. Somebody may still be inside.")
                }
            }
        }
    }

    private var temperatureChannel: some View {
        let telemetry = link.telemetry
        let temperature = telemetry?.temperatureCelsius ?? 0
        let isValid = telemetry?.isTemperatureValid ?? false

        return channel(
            title: "5 · Thermistor",
            subtitle: "Measurement normalisation",
            systemImage: "thermometer.medium",
            isVoting: nil,
            explanation: "A structure's natural period drifts with temperature — cold "
                + "concrete is stiffer, so a building genuinely sways faster on a January "
                + "morning than a July afternoon, by about as much as real damage would. "
                + "Ignoring that is the main cause of false alarms in real monitoring "
                + "systems, and it is why this channel exists on a node that is otherwise "
                + "entirely about shaking."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if isValid {
                    Readout(label: "Ambient", value: String(format: "%.1f", temperature),
                            unit: "°C", size: .large)
                } else {
                    InlineNotice(
                        level: .warning, title: "Thermistor not reading",
                        message: "The divider is reading a rail, which means the sensor is "
                            + "open or shorted rather than that the room is very cold. Any "
                            + "period comparison made now carries the seasonal effect with "
                            + "it uncorrected.")
                }

                if let assessment = link.assessment {
                    Text(String(format: "The verdict was computed from a period change of "
                                + "%+.1f%%, measured at this temperature.",
                                assessment.periodChangePercent))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var photoresistorChannel: some View {
        let reading = link.telemetry?.photoresistor ?? 0
        let verification = link.verifications[.power]

        return channel(
            title: "6 · Photoresistor",
            subtitle: "Self-verification",
            systemImage: "light.max",
            isVoting: nil,
            explanation: "It watches the lamp on the building-power circuit. This is the "
                + "sensor that lets the node report POWER CUT CONFIRMED rather than merely "
                + "POWER CUT COMMANDED — a command that was sent is a rumour, and a command "
                + "whose effect was measured is a fact. Only one of those belongs in a safety "
                + "report."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Readout(label: "Light level", value: "\(reading)", size: .large,
                        caption: "0–1023 · use this to set the confirmation threshold")

                if let verification {
                    HStack(spacing: Theme.Metrics.spacing) {
                        evidenceBox("Before", verification.before, isDark: false)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Palette.textTertiary)
                        evidenceBox("After", verification.after, isDark: true)
                    }

                    // Visually distinct, because the difference between these
                    // two states is the entire point of the channel.
                    if verification.confirmed {
                        InlineNotice(
                            level: .info, title: "POWER CUT CONFIRMED",
                            message: "The light changed by \(verification.delta) counts when "
                                + "the relay opened. The cut was not merely commanded — its "
                                + "effect was observed.")
                    } else {
                        InlineNotice(
                            level: .warning, title: "POWER CUT COMMANDED, NOT CONFIRMED",
                            message: "The relay was told to open and the light barely moved "
                                + "(\(verification.delta) counts). Either the lamp is not in "
                                + "view of the sensor, the threshold is set too high, or the "
                                + "cut did not happen.")
                    }
                }
            }
        }
    }

    private func evidenceBox(_ label: String, _ value: Int, isDark: Bool) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(white: isDark ? 0.12 : 0.85))
                .frame(height: 34)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.Palette.hairline))
            Text("\(label) \(value)")
                .font(Theme.Typography.numericSmall)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Shared shape

    /// One channel's panel. Each keeps its own reading, its own vote state and
    /// its own explanation — never merged into a combined number.
    private func channel<Content: View>(
        title: String, subtitle: String, systemImage: String,
        isVoting: Bool?, explanation: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(title, systemImage: systemImage)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer()
                if let isVoting {
                    StatusPill(text: isVoting ? "VOTING YES" : "NOT VOTING",
                               tint: isVoting ? Theme.Palette.verdictAmber
                                              : Theme.Palette.textSecondary)
                }
            }

            content()

            Text(explanation)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }
}


private extension String {
    var capitalisedSentence: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
