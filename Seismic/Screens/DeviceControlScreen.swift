import SwiftUI
import SeismicCore
import SeismicDevice

/// Everything the hardware can do, from the phone.
///
/// The organising constraint is a live demonstration: the presenter should
/// never have to touch the board. So the button that runs the entire sequence
/// is the largest thing on the screen, the sequence itself is shown stepping
/// through its phases as the *hardware* reports them rather than on a timer
/// here, and every other control states what it did.
///
/// The second constraint is that no control is ever left in an unknown state.
/// A button that looks identical before and after a tap is how a presenter ends
/// up sending DRILL three times, so each one shows idle, sending, acknowledged
/// or failed, and a command the firmware never acknowledges is marked as such
/// rather than spinning for ever.
struct DeviceControlScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject var link: SeismicNodeLink

    @State private var showingScanner = false
    @State private var triggerThreshold: Double = 4.0
    @State private var stepCount: Double = 1024
    @State private var stepDelay: Double = 3000
    @State private var photoThreshold: Double = 600
    @State private var hasLoadedTuning = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Metrics.spacingLoose) {
                connectionCard
                testEarthquake
                commentaryCard
                sequenceCard
                armCard
                actuatorConsole
                maintenance
                tuning
                transferCard
                faults
            }
            .padding(Theme.Metrics.screenPadding)
            .contentColumn()
        }
        .sheet(isPresented: $showingScanner) { FirmwareNodeScannerSheet(link: link) }
        .onChange(of: link.telemetry?.triggerThreshold) { _, value in
            // The node is the authority on its own settings. Adopting its
            // value on the first telemetry line means the sliders start where
            // the hardware actually is rather than at a guess.
            guard let value, !hasLoadedTuning else { return }
            triggerThreshold = value
            hasLoadedTuning = true
        }
    }

    // MARK: Connection

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            HStack {
                SectionLabel("Node", systemImage: "sensor.tag.radiowaves.forward")
                Spacer()
                ConnectionBadge(state: link.connection)
            }

            if case .reconnecting(let attempt, let next) = link.connection {
                Text("Attempt \(attempt), retrying in \(Int(next.rounded())) s. The node keeps "
                     + "running while the link is down and holds its recording; nothing is "
                     + "lost by waiting.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !link.hasAccelerometer {
                InlineNotice(level: .critical, title: "Accelerometer not responding",
                             message: "The firmware expects the MPU6050 at 0x69, which needs "
                                 + "AD0 tied to 3.3 V. Without it the node cannot detect "
                                 + "anything and will not leave its boot loop.")
            }

            HStack(spacing: Theme.Metrics.spacing) {
                Button {
                    showingScanner = true
                } label: {
                    Label("Find a node", systemImage: "dot.radiowaves.left.and.right")
                        .font(Theme.Typography.callout)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Metrics.minimumTapTarget)
                }
                .buttonStyle(SecondaryButtonStyle())

                Button {
                    link.useSimulator()
                } label: {
                    Label("Use simulator", systemImage: "cpu")
                        .font(Theme.Typography.callout)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Metrics.minimumTapTarget)
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            if link.source == .simulated {
                Text("The simulated node emits the same lines the firmware does, through the "
                     + "same parser. Every control on this screen works identically against "
                     + "it — including Test earthquake.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    // MARK: The demo button

    /// The one button the whole demonstration runs from.
    private var testEarthquake: some View {
        VStack(spacing: Theme.Metrics.spacing) {
            Button {
                Haptics.shared.play(.eventTriggered)
                link.send(.drill)
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .font(.system(size: 30, weight: .semibold))
                    Text("TEST EARTHQUAKE")
                        .font(.system(size: 19, weight: .bold))
                        .tracking(1.2)
                    Text(link.isEventRunning ? "Running — follow it below"
                                             : "Runs the node's complete event sequence")
                        .font(Theme.Typography.caption)
                        .opacity(0.85)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 116)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(link.isEventRunning || link.state(of: .drill).isInFlight)

            CommandStateLabel(state: link.state(of: .drill), command: "DRILL")
        }
    }

    // MARK: What the node is doing, in words

    /// The node's own account of itself.
    ///
    /// Everything else on this screen is an instrument — states, ratios, a
    /// timeline — which is the right way to inspect a node and the wrong way to
    /// *watch* one. Somebody standing over the board while it works wants a
    /// running account in the order it happens, and this is that: the same
    /// stream of messages, read a second time in plain English. Newest at the
    /// bottom, so it reads downwards like a transcript rather than jumping.
    @ViewBuilder
    private var commentaryCard: some View {
        if !link.commentary.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
                HStack {
                    SectionLabel("Live commentary", systemImage: "text.bubble")
                    Spacer()
                    if link.isEventRunning {
                        StatusPill(text: "LIVE", tint: Theme.Palette.verdictRed)
                    }
                    // Reads back the last few lines rather than the whole feed:
                    // by the time somebody presses this the interesting part is
                    // what just happened, and a minute of history read from the
                    // beginning is a minute during which the node does more.
                    SpeakButton(link.commentary.suffix(5).map(\.text).joined(separator: " "),
                                compact: true)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
                            ForEach(link.commentary) { line in
                                commentaryLine(line).id(line.id)
                            }
                        }
                        .padding(.vertical, Theme.Metrics.s1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 260)
                    .onChange(of: link.commentary.count) { _, _ in
                        guard let last = link.commentary.last else { return }
                        withAnimation(Theme.Motion.gentle) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .instrumentPanel()
        }
    }

    private func commentaryLine(_ line: FirmwareNarrator.Line) -> some View {
        HStack(alignment: .top, spacing: Theme.Metrics.s3) {
            Circle()
                .fill(tint(for: line.tone))
                .frame(width: 7, height: 7)
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                Text(line.text)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(line.tone == .routine
                                     ? Theme.Palette.textSecondary
                                     : Theme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if line.isSpoken {
                    Label("said aloud", systemImage: "speaker.wave.2.fill")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textGhost)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func tint(for tone: FirmwareNarrator.Tone) -> Color {
        switch tone {
        case .routine: Theme.Palette.textGhost
        case .sensing: Theme.Palette.accent
        case .acting: Theme.Palette.verdictAmber
        case .good: Theme.Palette.verdictGreen
        case .bad: Theme.Palette.verdictRed
        }
    }

    // MARK: The sequence, live

    /// The seven steps, ticked off as the *hardware* reports them.
    ///
    /// Driven by the node's own `phase` and actuator messages rather than by a
    /// timer here. A timeline animated locally would look identical when the
    /// board had stopped responding, which is precisely the situation somebody
    /// needs to be able to see.
    @ViewBuilder
    private var sequenceCard: some View {
        if link.lastTrigger != nil || link.isEventRunning || link.assessment != nil {
            VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
                HStack {
                    SectionLabel("Event sequence", systemImage: "list.number")
                    Spacer()
                    if let trigger = link.lastTrigger, trigger.isDrill {
                        StatusPill(text: "DRILL", tint: Theme.Palette.accent)
                    }
                }

                if let trigger = link.lastTrigger {
                    step(1, "Event declared",
                         detail: String(format: "Ratio %.1f · ", trigger.ratio)
                             + trigger.votes.summary,
                         isDone: true, isActive: false)
                }

                if let countdown = link.countdown {
                    step(2, "Countdown", detail: "\(countdown) — buzzer and display counting",
                         isDone: false, isActive: true, badge: "\(countdown)")
                } else if hasReached(.acting) {
                    step(2, "Countdown", detail: "Five seconds, buzzer accelerating",
                         isDone: true, isActive: false)
                }

                step(3, "Power cut",
                     detail: verificationDetail(for: .power) ?? "Waiting",
                     isDone: link.actuators[.power] == .confirmed,
                     isActive: link.actuators[.power] == .commanded)

                step(4, "Water main closed",
                     detail: waterDetail,
                     isDone: link.actuators[.water] == .confirmed,
                     isActive: link.actuators[.water] == .commanded)

                step(5, "Recording",
                     detail: link.transfer.map { $0.summary } ?? "Ten seconds at 50 Hz",
                     isDone: link.transfer?.isComplete == true,
                     isActive: link.isTransferring || link.phase == .recording)

                step(6, "Period re-measured",
                     detail: link.assessment.map {
                         String(format: "%.3f s → %.3f s", $0.periodBefore, $0.periodAfter)
                     } ?? "Counting zero crossings, about six seconds",
                     isDone: link.assessment != nil,
                     isActive: link.phase == .assessing)

                step(7, "Verdict",
                     detail: link.assessment.map { verdictDetail($0) } ?? "Waiting",
                     isDone: link.assessment != nil,
                     isActive: link.phase == .verdict)

                if let assessment = link.assessment {
                    assessmentSummary(assessment)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .instrumentPanel()
        }
    }

    private func hasReached(_ phase: Firmware.Phase) -> Bool {
        let order: [Firmware.Phase] = [.warning, .acting, .recording, .assessing, .verdict]
        guard let current = link.phase, let a = order.firstIndex(of: current),
              let b = order.firstIndex(of: phase) else { return link.assessment != nil }
        return a >= b
    }

    private func verificationDetail(for actuator: Firmware.Actuator) -> String? {
        guard let verification = link.verifications[actuator] else {
            return link.actuators[actuator].map(\.label)
        }
        return verification.confirmed
            ? "Confirmed — light went \(verification.before) → \(verification.after)"
            : "Not confirmed — light barely moved (\(verification.before) → "
                + "\(verification.after))"
    }

    private var waterDetail: String {
        switch link.actuators[.water] {
        case .confirmed: "Stepper completed its travel"
        case .failed: "Unavailable — stepper disabled to save current"
        case .commanded: "Turning"
        default: "Waiting for the 800 ms gap after the power cut"
        }
    }

    private func verdictDetail(_ assessment: Firmware.Assessment) -> String {
        String(format: "%@ · period %+.1f%%", assessment.verdict.placard,
               assessment.periodChangePercent)
    }

    private func step(_ number: Int, _ title: String, detail: String,
                      isDone: Bool, isActive: Bool, badge: String? = nil) -> some View {
        HStack(alignment: .top, spacing: Theme.Metrics.spacing) {
            ZStack {
                Circle()
                    .fill(isDone ? Theme.Palette.accent
                          : (isActive ? Theme.Palette.accentSecondary
                             : Theme.Palette.surfaceHighest))
                    .frame(width: 26, height: 26)
                if let badge {
                    Text(badge)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: isDone ? "checkmark" : "\(number).circle")
                        .font(.system(size: isDone ? 12 : 13, weight: .semibold))
                        .foregroundStyle(isDone || isActive ? .white : Theme.Palette.textGhost)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.callout.weight(.medium))
                    .foregroundStyle(isDone || isActive ? Theme.Palette.textPrimary
                                                        : Theme.Palette.textSecondary)
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .animation(Theme.Motion.standard, value: isDone)
        .animation(Theme.Motion.standard, value: isActive)
    }

    private func assessmentSummary(_ assessment: Firmware.Assessment) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            Divider().overlay(Theme.Palette.hairline)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%+.1f", assessment.periodChangePercent))
                    .font(Theme.Typography.display(46))
                    .foregroundStyle(assessment.verdict.color)
                Text("%")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                StatusPill(text: assessment.verdict.placard, tint: assessment.verdict.color)
            }

            Text("A structure sways at a period set by its stiffness. Damage reduces "
                 + "stiffness while the mass stays the same, so the period gets longer — "
                 + "typically ten to thirty per cent when the damage is significant. The node "
                 + "measured it before and after.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Corroborating evidence sits beside the headline rather than being
            // folded into it: they fail in different ways, and averaging them
            // would hide exactly the disagreement worth seeing.
            ReadoutGrid(readouts: [
                Readout(label: "Peak ground acceleration",
                        value: String(format: "%.3f", assessment.peakGroundAcceleration),
                        unit: "g", size: .small),
                Readout(label: "Permanent tilt",
                        value: assessment.hasPermanentTilt ? "Yes" : "No",
                        tint: assessment.hasPermanentTilt ? Theme.Palette.verdictRed
                                                          : Theme.Palette.textPrimary,
                        size: .small),
                Readout(label: "Power cut",
                        value: assessment.powerCutConfirmed ? "Confirmed" : "Not confirmed",
                        size: .small),
                Readout(label: "Period",
                        value: String(format: "%.3f → %.3f",
                                      assessment.periodBefore, assessment.periodAfter),
                        unit: "s", size: .small),
            ], columns: 2)

            if link.hasSuspectRecording {
                InlineNotice(
                    level: .warning, title: "Marked suspect",
                    message: "The node restarted around this event, which means its supply "
                        + "dipped. Measurements taken across a brownout are not trustworthy "
                        + "and this verdict should not be relied on.")
            }

            Text("This is a screening aid. It narrows down where a qualified structural "
                 + "engineer should look first; it does not replace an inspection.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Arm

    private var armCard: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            HStack {
                SectionLabel("Armed state", systemImage: "shield")
                Spacer()
                // Unmistakable, because the whole reason to disarm is so the
                // node does not false-trigger mid-sentence — and a presenter
                // needs to know which state they are in at a glance.
                StatusPill(text: link.isArmed ? "ARMED — reacting to shaking"
                                              : "DISARMED — ignoring shaking",
                           tint: link.isArmed ? Theme.Palette.accent
                                              : Theme.Palette.textSecondary)
            }

            HStack(spacing: Theme.Metrics.spacing) {
                commandButton("Arm", systemImage: "shield.fill", command: .arm,
                              isProminent: !link.isArmed)
                commandButton("Disarm", systemImage: "shield.slash", command: .disarm,
                              isProminent: link.isArmed)
            }

            Text("Keep it disarmed until the moment of the demonstration. A lorry outside or "
                 + "a knock on the bench is enough to satisfy two channels, and the node "
                 + "cannot tell that from an earthquake — which is the point being made.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    // MARK: Actuators

    private var actuatorConsole: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Actuators", systemImage: "bolt.shield")

            ForEach(Firmware.Actuator.allCases) { actuator in
                actuatorRow(actuator)
            }

            Text("One motor at a time, eight hundred milliseconds apart. The board runs on "
                 + "USB — about five hundred milliamps — and two motors moving together brown "
                 + "it out. Commands are queued to keep that gap even if you tap quickly, "
                 + "which is also why each action can be followed separately.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private func actuatorRow(_ actuator: Firmware.Actuator) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(actuator.label, systemImage: actuator.systemImage)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(actuator.isAvailableInFirmware
                                     ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
                Spacer()
                if actuator.isAvailableInFirmware {
                    StatusPill(text: (link.actuators[actuator] ?? .idle).label,
                               tint: (link.actuators[actuator] ?? .idle).isProven
                                   ? Theme.Palette.accent : Theme.Palette.textSecondary)
                } else {
                    StatusPill(text: "UNAVAILABLE", tint: Theme.Palette.textSecondary)
                }
            }

            if let reason = actuator.unavailableReason {
                Text(reason)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let verification = link.verifications[actuator] {
                // The evidence, not the claim.
                Text(verification.confirmed
                     ? "Confirmed by the photoresistor: the light went from "
                       + "\(verification.before) to \(verification.after), a change of "
                       + "\(verification.delta). That is the difference between reporting "
                       + "POWER CUT CONFIRMED and merely POWER CUT COMMANDED."
                     : "Not confirmed. The light moved only \(verification.delta), which is "
                       + "below the threshold — so the command was sent and its effect was "
                       + "not observed.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(verification.confirmed ? Theme.Palette.textSecondary
                                                            : Theme.Palette.verdictAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if actuator.isAvailableInFirmware {
                HStack(spacing: Theme.Metrics.spacing) {
                    switch actuator {
                    case .power:
                        commandButton("Cut power", systemImage: "bolt.slash",
                                      command: .power(on: false))
                        commandButton("Restore", systemImage: "bolt",
                                      command: .power(on: true))
                    case .water:
                        commandButton("Close water", systemImage: "drop.fill",
                                      command: .water(closed: true))
                        commandButton("Open", systemImage: "drop",
                                      command: .water(closed: false))
                    case .gas:
                        EmptyView()
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Maintenance

    private var maintenance: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Maintenance", systemImage: "wrench.and.screwdriver")

            HStack(spacing: Theme.Metrics.spacing) {
                commandButton("Calibrate", systemImage: "scope", command: .calibrate)
                commandButton("Reset", systemImage: "arrow.counterclockwise", command: .reset)
            }
            HStack(spacing: Theme.Metrics.spacing) {
                commandButton("Resend recording", systemImage: "arrow.down.doc",
                              command: .resendRecording)
                commandButton("Refresh", systemImage: "arrow.clockwise", command: .status)
            }

            if link.telemetry?.state == .calibrating {
                MeaningfulProgress(
                    title: "Calibrating",
                    detail: "About twelve seconds: relearning gravity, the quiet sound floor, "
                          + "and the building's baseline period. Keep the surface still.")
            } else if let calibration = link.calibration {
                Text(String(format: "Last calibration: gravity %d counts, quiet floor %d, "
                            + "baseline period %.3f s.",
                            calibration.gravity, calibration.soundBaseline, calibration.period))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    // MARK: Tuning

    private var tuning: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Tuning", systemImage: "slider.horizontal.3",
                         trailing: "live, no re-upload")

            tuningSlider(
                title: "Trigger sensitivity",
                value: $triggerThreshold, range: 1.5...12, step: 0.1,
                format: { String(format: "%.1f×", $0) },
                confirmed: link.telemetry?.triggerThreshold,
                explanation: "The STA/LTA ratio at which the accelerometer votes. Lower is "
                    + "more sensitive and catches more traffic; the fusion vote is what stops "
                    + "that becoming a false alarm.",
                command: { .triggerThreshold($0) })

            tuningSlider(
                title: "Stepper travel",
                value: $stepCount, range: 128...2048, step: 64,
                format: { "\(Int($0)) steps" },
                confirmed: nil,
                explanation: "How far the valve turns. A 28BYJ-48 is 2048 steps per "
                    + "revolution in half-step mode.",
                command: { .stepCount(Int($0)) })

            tuningSlider(
                title: "Stepper speed",
                value: $stepDelay, range: 1200...6000, step: 100,
                format: { "\(Int($0)) µs/step" },
                confirmed: nil,
                explanation: "Microseconds between steps. Faster draws more current, and the "
                    + "budget is the reason this is adjustable rather than fixed.",
                command: { .stepDelay(Int($0)) })

            tuningSlider(
                title: "Confirmation threshold",
                value: $photoThreshold, range: 100...900, step: 10,
                format: { "\(Int($0))" },
                confirmed: nil,
                explanation: "How much the photoresistor reading must change before a power "
                    + "cut counts as confirmed. Set it from your own room's readings — the "
                    + "current light level is shown on the channels screen.",
                command: { .photoThreshold(Int($0)) })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private func tuningSlider(title: String, value: Binding<Double>,
                              range: ClosedRange<Double>, step: Double,
                              format: @escaping (Double) -> String,
                              confirmed: Double?,
                              explanation: String,
                              command: @escaping (Double) -> Firmware.Command) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(Theme.Typography.numeric)
                    .foregroundStyle(Theme.Palette.accent)
            }

            Slider(value: value, in: range, step: step) { editing in
                // Sent on release rather than continuously: a slider that
                // writes on every frame floods a 115200-baud link and the node
                // spends the demonstration parsing instead of sampling.
                guard !editing else { return }
                link.send(command(value.wrappedValue))
            }
            .tint(Theme.Palette.accent)

            // Confirmation from the node rather than from the slider. The
            // firmware echoes its accepted value in telemetry, and that is what
            // "acknowledged" should mean here.
            if let confirmed {
                Text(abs(confirmed - value.wrappedValue) < step
                     ? "Node confirms \(format(confirmed))."
                     : "Node still reports \(format(confirmed)).")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(abs(confirmed - value.wrappedValue) < step
                                     ? Theme.Palette.accent : Theme.Palette.verdictAmber)
            }

            Text(explanation)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    // MARK: Transfer

    @ViewBuilder
    private var transferCard: some View {
        if let transfer = link.transfer, transfer.expectedChunks > 0 {
            VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
                SectionLabel("Recording transfer", systemImage: "arrow.down.doc",
                             trailing: "\(transfer.receivedChunks)/\(transfer.expectedChunks)")

                MeaningfulProgress(
                    title: transfer.isComplete ? "Complete" : "Transferring",
                    detail: transfer.summary,
                    progress: Double(transfer.receivedChunks)
                            / Double(max(transfer.expectedChunks, 1)))

                if !transfer.missingChunks.isEmpty {
                    Text(missingChunkSentence(transfer.missingChunks))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.verdictAmber)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        link.send(.resendRecording)
                    } label: {
                        Label("Re-send the whole recording", systemImage: "arrow.clockwise")
                            .font(Theme.Typography.callout)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .instrumentPanel()
        }
    }

    /// Names the gaps, capped so twenty-five missing chunks do not fill the
    /// screen with numbers.
    private func missingChunkSentence(_ missing: [Int]) -> String {
        let shown = missing.prefix(12).map(String.init).joined(separator: ", ")
        let ellipsis = missing.count > 12 ? "…" : ""
        return "Missing chunks: \(shown)\(ellipsis). Each is re-requested individually with "
             + "REC:n rather than re-sending the whole recording, and what already arrived "
             + "is kept."
    }

    // MARK: Faults

    @ViewBuilder
    private var faults: some View {
        if !link.brownouts.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
                SectionLabel("Brownouts", systemImage: "exclamationmark.triangle",
                             trailing: "\(link.brownouts.count)")

                Text("The node restarted without being asked to. That is its supply dipping — "
                     + "almost always two motors moving at once — and it is a distinct fault "
                     + "rather than a seismic trigger. A restart produces a burst of every "
                     + "message at once, which is exactly what a naive reader would take for "
                     + "a large earthquake.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(link.brownouts.suffix(5)) { brownout in
                    HStack {
                        Image(systemName: brownout.duringEvent
                              ? "exclamationmark.octagon" : "bolt.trianglebadge.exclamationmark")
                            .foregroundStyle(brownout.duringEvent ? Theme.Palette.verdictRed
                                                                  : Theme.Palette.verdictAmber)
                        Text(brownout.at.formatted(date: .omitted, time: .standard))
                            .font(Theme.Typography.numericSmall)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        Spacer()
                        if brownout.duringEvent {
                            Text("during an event — recording suspect")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.verdictRed)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .instrumentPanel()
        }
    }

    // MARK: Buttons

    private func commandButton(_ title: String, systemImage: String,
                               command: Firmware.Command,
                               isProminent: Bool = false) -> some View {
        let state = link.state(of: command)
        return Button {
            Haptics.shared.play(.selection)
            link.send(command)
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 5) {
                    if state.isInFlight {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: systemImage).font(.system(size: 14))
                    }
                    Text(title).font(Theme.Typography.callout)
                }
                CommandStateLabel(state: state, command: command.wire, compact: true)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: Theme.Metrics.minimumTapTarget)
        }
        .buttonStyle(isProminent ? AnyButtonStyle(PrimaryButtonStyle())
                                 : AnyButtonStyle(SecondaryButtonStyle()))
        .disabled(state.isInFlight)
    }
}

/// What happened to a command, in words.
///
/// Present on every control because "never leave a button in an unknown state"
/// is a requirement, and the honest states are four rather than two: a command
/// the firmware does not acknowledge is confirmed as *sent* rather than
/// pretending to have been accepted.
struct CommandStateLabel: View {
    let state: SeismicNodeLink.CommandState
    let command: String
    var compact = false

    var body: some View {
        switch state {
        case .idle:
            if !compact {
                Text("Ready")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        case .sending:
            Text("Sending…")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.accentSecondary)
        case .acknowledged(let at):
            Text(compact ? "Acknowledged"
                 : "Acknowledged at \(at.formatted(date: .omitted, time: .standard))")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.accent)
        case .failed(let reason):
            Text(compact ? "Failed" : "Failed — \(reason)")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.verdictAmber)
        }
    }
}

/// Erases a button style so one call site can choose between two.
struct AnyButtonStyle: ButtonStyle {
    private let makeBody: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        makeBody = { configuration in
            AnyView(style.makeBody(configuration: configuration))
        }
    }

    func makeBody(configuration: Configuration) -> some View { makeBody(configuration) }
}

/// Choosing a node, with signal strength so "the one on the bench" is
/// identifiable in a room with three of them.
struct FirmwareNodeScannerSheet: View {
    @ObservedObject var link: SeismicNodeLink
    @Environment(\.dismiss) private var dismiss

    private static let scanExplanation =
        "Everything nearby is listed, not only devices advertising the node's service — these "
        + "serial modules usually advertise a name and nothing else, so a filtered list would be "
        + "empty next to a node that is working perfectly. Anything that did advertise it is "
        + "marked and sorted to the top. One tap pairs and remembers it; after that the app "
        + "reconnects on its own."

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if link.discovered.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Scanning…")
                                .font(Theme.Typography.callout)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                    ForEach(link.discovered.sorted { $0.sortKey > $1.sortKey }) { node in
                        Button {
                            link.connect(to: node.id)
                            dismiss()
                        } label: {
                            row(for: node)
                        }
                        .disabled(!node.isConnectable)
                    }
                } footer: {
                    Text(Self.scanExplanation)
                }

                if let fault = link.log.first(where: { $0.kind == .fault }) {
                    Section("Last problem") {
                        Text(fault.text)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.verdictAmber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle("Find a node")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { link.stopScanning(); dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Scan again") { link.startScanning() }
                }
            }
            .onAppear { link.startScanning() }
        }
    }

    private func row(for node: SeismicNodeLink.DiscoveredPeripheral) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(node.name)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textPrimary)
                HStack(spacing: 6) {
                    Text("\(node.rssi) dBm")
                        .font(Theme.Typography.numericSmall)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    if node.advertisesNodeService {
                        StatusPill(text: "SERIAL SERVICE", tint: Theme.Palette.accent)
                    }
                    if !node.isConnectable {
                        StatusPill(text: "NOT CONNECTABLE", tint: Theme.Palette.textTertiary)
                    }
                }
            }
            Spacer()
            HStack(spacing: 2) {
                ForEach(1...4, id: \.self) { bar in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(bar <= node.signalBars
                              ? Theme.Palette.accent
                              : Theme.Palette.textGhost.opacity(0.3))
                        .frame(width: 3, height: CGFloat(bar) * 4 + 3)
                }
            }
        }
    }
}
