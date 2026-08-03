import SwiftUI
import SeismicCore
import SeismicDevice

/// The warning.
///
/// Everything about this screen is subordinated to one job: getting somebody who
/// may be asleep, or holding a child, or halfway up a staircase, to do the right
/// thing in the next few seconds.
///
/// So: the countdown is enormous, there is exactly one instruction, there is
/// exactly one button, and nothing else is on the screen at all. No tab bar, no
/// navigation, no charts, no branding. The actuator status is present but small,
/// because it is reassurance rather than an action — the node has already fired
/// them without waiting to be asked.
struct EventTakeoverView: View {
    @EnvironmentObject private var env: AppEnvironment
    /// Observed explicitly. Both are their own ObservableObjects held by the
    /// environment, and a change inside one does not republish the object
    /// holding it — so without these the call banner never appears and the
    /// live line never changes.
    @ObservedObject var link: SeismicNodeLink
    @ObservedObject var call: EmergencyCallController
    let event: AppEnvironment.ActiveEvent

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The clock this screen reads, driven by `TimelineView` rather than by a
    /// `Timer.publish` held on the view.
    ///
    /// That timer was a `let` on a `View` struct, and a `View` struct is rebuilt
    /// every time anything it observes changes — which, during an event, is
    /// twenty times a second. So each rebuild constructed a *new* publisher and
    /// `onReceive` resubscribed to it, and none of them ever survived the tenth
    /// of a second it needed to fire once. The countdown sat on its opening
    /// number for the entire warning: the single most important number on the
    /// most important screen in the app, frozen.
    ///
    /// A timeline is owned by SwiftUI rather than by the struct, so rebuilding
    /// the struct does not restart it.
    @State private var now = Date()

    private var elapsed: TimeInterval { now.timeIntervalSince(event.startedAt) }

    private var secondsRemaining: Int {
        guard let total = event.secondsUntilStrongShaking else { return 0 }
        return max(Int((total - elapsed).rounded(.up)), 0)
    }

    private var hasShakingArrived: Bool {
        guard let total = event.secondsUntilStrongShaking else { return true }
        return elapsed >= total
    }

    private var background: Color {
        if event.isDrill { return Color(red: 0.10, green: 0.14, blue: 0.24) }
        return hasShakingArrived
            ? Color(red: 0.22, green: 0.05, blue: 0.06)
            : Color(red: 0.20, green: 0.11, blue: 0.02)
    }

    var body: some View {
        TimelineView(.periodic(from: event.startedAt, by: 0.1)) { context in
            content(at: context.date)
        }
    }

    private func content(at date: Date) -> some View {
        ZStack {
            background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                callBanner
                Spacer(minLength: Theme.Metrics.s4)
                countdown
                Spacer(minLength: Theme.Metrics.s4)
                reEntryVerdict
                liveUpdate
                instruction
                actuatorStrip
                safeButton
            }
            // The horizontal inset is wider than a normal screen's because
            // everything here is centred display type that reads badly when it
            // reaches the bezel, and the vertical insets are separate: the
            // status bar is hidden, so the top has to buy back the clearance
            // it would have given, and the bottom sits above the home
            // indicator rather than under it. A single symmetric padding put
            // "I'M SAFE" hard against the gesture area, where iOS takes the
            // first part of any upward swipe for itself.
            .padding(.horizontal, Theme.Metrics.s6)
            .padding(.top, Theme.Metrics.s5)
            .padding(.bottom, Theme.Metrics.s4)
            .contentColumn()
        }
        // Assigned from the timeline rather than from a timer of our own, and
        // only when the whole second changes, so the rest of the screen is not
        // rebuilt ten times a second for a number that did not move.
        .onChange(of: Int(date.timeIntervalSince(event.startedAt))) { _, _ in
            now = date
        }
        .onAppear {
            now = Date()
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .statusBarHidden()
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: event.isDrill ? "figure.run" : "exclamationmark.triangle.fill")
                Text(event.isDrill ? "DRILL — NOT A REAL EVENT" : "EARTHQUAKE DETECTED")
            }
            .font(.system(size: 15, weight: .heavy))
            .tracking(1.4)
            .foregroundStyle(.white)

            Spacer()

            if let magnitude = event.estimatedMagnitude {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "M %.1f", magnitude))
                        .font(Theme.Typography.numeric.weight(.semibold))
                    Text("estimated")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .foregroundStyle(.white)
            }
        }
        .padding(.top, 6)
    }

    /// That the call is happening, and nothing else.
    ///
    /// The call used to be a second full-screen page laid over this one, with
    /// the whole dispatcher transcript on it — so during the ten seconds that
    /// matter most the countdown and the instruction were both hidden behind a
    /// conversation nobody needs to read while getting under a table. One line
    /// at the top says the thing worth knowing. The transcript is still there
    /// afterwards, on the Hardware screen's log, for anybody who wants it.
    @ViewBuilder
    private var callBanner: some View {
        if let stage = call.stage, stage != .ended {
            HStack(spacing: 8) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 12, weight: .bold))
                    .opacity(pulse ? 1 : 0.35)
                Text(stage == .acknowledged
                     ? "\(EmergencyCallController.emergencyNumber) HAS THE REPORT"
                     : "CALLING \(EmergencyCallController.emergencyNumber)")
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(1.3)
                Text("· simulated")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(0.6)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Metrics.s4)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.28), in: Capsule(style: .continuous))
            .padding(.top, Theme.Metrics.s3)
            .transition(.opacity)
            .accessibilityLabel("Calling emergency services. This is simulated.")
        }
    }

    /// The node's own account of itself, one line at a time.
    ///
    /// During an event the phone is face down or being held by somebody under
    /// a table, and the takeover deliberately shows almost nothing. But what
    /// the board is *doing* — cutting the power, closing the water, confirming
    /// it — is the one thing worth glancing at, and it was only visible on a
    /// screen this one covers. Each line appears briefly and gives way to the
    /// next, so it never becomes a wall of text competing with the countdown.
    @ViewBuilder
    private var liveUpdate: some View {
        if let line = link.commentary.last, !hasShakingArrived || link.isEventRunning {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.top, 2)
                Text(line.text)
                    .font(Theme.Typography.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, Theme.Metrics.s4)
            .padding(.vertical, Theme.Metrics.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.24),
                        in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall,
                                             style: .continuous))
            .padding(.bottom, Theme.Metrics.s4)
            .id(line.id)
            .transition(.asymmetric(insertion: .push(from: .bottom).combined(with: .opacity),
                                    removal: .opacity))
            .animation(Theme.Motion.gentle, value: line.id)
        }
    }

    /// Whether it is safe to go back in.
    ///
    /// This is the question the whole system exists to answer, and until now it
    /// only ever appeared on a screen two taps away — so the moment somebody is
    /// standing outside their building deciding what to do, they were looking
    /// at a countdown that had finished. The node measures the structure's
    /// period again after the shaking, compares it against the baseline it
    /// learned before, and this states the consequence in the only words that
    /// matter.
    @ViewBuilder
    private var reEntryVerdict: some View {
        if let assessment = link.assessment {
            let safe = assessment.verdict == .green
            VStack(spacing: Theme.Metrics.s2) {
                Text(safe ? "SAFE TO GO BACK IN" : "DO NOT GO BACK IN")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .tracking(0.8)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                Text(reEntryReason(assessment))
                    .font(Theme.Typography.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(0.9)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Metrics.s4)
            .padding(.vertical, Theme.Metrics.s4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                    .fill((safe ? Theme.Palette.verdictGreen : Theme.Palette.verdictRed)
                        .opacity(0.30))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius,
                                         style: .continuous)
                            .strokeBorder(safe ? Theme.Palette.verdictGreen
                                               : Theme.Palette.verdictRed, lineWidth: 2)))
            .padding(.bottom, Theme.Metrics.s4)
            .transition(.scale(scale: 0.94).combined(with: .opacity))
            .animation(Theme.Motion.standard, value: assessment.verdict)
        }
    }

    /// The measurement behind the verdict, in one sentence.
    ///
    /// Never the verdict on its own. A building that says "do not enter" and
    /// gives no reason is a building people walk into anyway; the period
    /// changing by a stated percentage is a fact somebody can weigh.
    private func reEntryReason(_ assessment: Firmware.Assessment) -> String {
        let before = String(format: "%.2f", assessment.periodBefore)
        let after = String(format: "%.2f", assessment.periodAfter)
        let change = abs(assessment.periodChangePercent)

        switch assessment.verdict {
        case .green:
            return "The building sways as it did before — \(before) s then \(after) s. "
                + "No stiffness was lost, so nothing structural has changed."
        case .amber:
            return String(format: "Sway went from %@ s to %@ s, %.0f%% slower. Something has "
                          + "softened. Have it looked at before you stay in it.",
                          before, after, change)
        case .red:
            return String(format: "Sway went from %@ s to %@ s — %.0f%% slower. A building "
                          + "loses stiffness when it is damaged, and that much means "
                          + "structural damage. Stay out.", before, after, change)
        case .needsInspection:
            return "The measurement is not clear enough to call either way, and a guess is "
                + "worse than nothing here. Treat it as unsafe until somebody qualified "
                + "has looked."
        }
    }

    private var countdown: some View {
        VStack(spacing: 6) {
            if hasShakingArrived {
                Text("SHAKING NOW")
                    .font(.system(size: 54, weight: .black, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.white)
                    .scaleEffect(pulse ? 1.03 : 1.0)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            } else {
                // Numerals as large as the screen allows. Somebody reads this
                // from across a room, or with a phone lying on a table.
                Text("\(secondsRemaining)")
                    .font(.system(size: 190, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy(duration: 0.2), value: secondsRemaining)
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)

                Text(secondsRemaining == 1 ? "SECOND UNTIL STRONG SHAKING"
                                           : "SECONDS UNTIL STRONG SHAKING")
                    .font(.system(size: 14, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
            }

            if let intensity = event.expectedIntensity {
                Text("Expected intensity \(intensity.roman) — \(intensity.shortLabel.lowercased())")
                    .font(Theme.Typography.callout)
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.top, 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasShakingArrived
            ? "Strong shaking now"
            : "\(secondsRemaining) seconds until strong shaking")
    }

    /// One instruction. Not a list, not a leaflet.
    private var instruction: some View {
        VStack(spacing: 10) {
            Text(hasShakingArrived ? "STAY DOWN" : "DROP, COVER, HOLD ON")
                .font(.system(size: 32, weight: .black, design: .rounded))
                .tracking(1)
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Text(hasShakingArrived
                 ? "Stay where you are until the shaking stops. Do not run outside."
                 : "Get under a sturdy table. Cover your head and neck. Hold on until it stops.")
                .font(Theme.Typography.body)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, Theme.Metrics.spacingLoose)
    }

    /// The node has already acted. This says so, quietly.
    private var actuatorStrip: some View {
        HStack(spacing: 8) {
            ForEach(ActuatorKind.allCases) { kind in
                let report = event.actuators[kind]
                HStack(spacing: 5) {
                    Image(systemName: report?.state == .confirmed
                          ? "checkmark.circle.fill" : kind.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                    Text(kind.label)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(color(for: report?.state))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.white.opacity(0.10)))
            }
        }
        .padding(.bottom, Theme.Metrics.spacing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Safety actions: " + ActuatorKind.allCases.map {
            "\($0.label) \(event.actuators[$0]?.state.label ?? "pending")"
        }.joined(separator: ", "))
    }

    private func color(for state: ActuatorState?) -> Color {
        switch state {
        case .confirmed: Color(red: 0.55, green: 0.95, blue: 0.65)
        case .inProgress, .queued, .commanded: .white
        case .failed: Color(red: 1.0, green: 0.65, blue: 0.6)
        default: .white.opacity(0.45)
        }
    }

    /// One button, the full width of the screen, impossible to miss and
    /// impossible to hit by accident because nothing else is tappable.
    private var safeButton: some View {
        VStack(spacing: Theme.Metrics.s4) {
            if event.userAcknowledged {
                HStack(spacing: Theme.Metrics.s3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Marked safe.\nYour household has been told.")
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .font(Theme.Typography.callout.weight(.medium))
                .foregroundStyle(.white)
                // Padded inside the pill rather than given a fixed height. The
                // sentence is long enough to reach both rounded corners on a
                // narrow phone, and a fixed 68 points clipped it outright at
                // the larger accessibility text sizes.
                .padding(.horizontal, Theme.Metrics.s5)
                .padding(.vertical, Theme.Metrics.s4)
                .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusLarge,
                                     style: .continuous)
                        .fill(.white.opacity(0.16)))

                Button("Dismiss") { env.dismissActiveEvent() }
                    .font(Theme.Typography.callout)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(height: Theme.Metrics.minimumTapTarget)
            } else {
                Button("I'M SAFE") { env.acknowledgeActiveEvent() }
                    .buttonStyle(EmergencyButtonStyle())
                    .accessibilityHint("Tells your household you are unhurt")

                if event.isDrill {
                    Button("End drill") { env.dismissActiveEvent() }
                        .font(Theme.Typography.callout)
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(height: Theme.Metrics.minimumTapTarget)
                }
            }
        }
    }
}

#Preview("Countdown") {
    EventTakeoverView(link: SeismicNodeLink(), call: EmergencyCallController(),
                      event: .init(startedAt: Date(), triggerRatio: 8.4,
                                   estimatedMagnitude: 6.3,
                                   secondsUntilStrongShaking: 11,
                                   expectedIntensity: .strong,
                                   isDrill: false))
        .previewEnvironment()
}

#Preview("Shaking") {
    EventTakeoverView(link: SeismicNodeLink(), call: EmergencyCallController(),
                      event: .init(startedAt: Date().addingTimeInterval(-20),
                                   triggerRatio: 12.1,
                                   estimatedMagnitude: 6.9,
                                   secondsUntilStrongShaking: 8,
                                   expectedIntensity: .severe,
                                   isDrill: false,
                                   actuators: [
                                    .mainsPower: .init(kind: .mainsPower, state: .confirmed),
                                    .waterMain: .init(kind: .waterMain, state: .inProgress),
                                   ]))
        .previewEnvironment()
}
