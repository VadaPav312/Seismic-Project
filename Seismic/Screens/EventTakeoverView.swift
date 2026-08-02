import SwiftUI
import SeismicCore

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
    let event: AppEnvironment.ActiveEvent

    @State private var pulse = false
    @State private var elapsed: TimeInterval = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

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
        ZStack {
            background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer(minLength: Theme.Metrics.s4)
                countdown
                Spacer(minLength: Theme.Metrics.s4)
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
        .onReceive(ticker) { _ in
            elapsed = Date().timeIntervalSince(event.startedAt)
        }
        .onAppear {
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
    EventTakeoverView(event: .init(startedAt: Date(), triggerRatio: 8.4,
                                   estimatedMagnitude: 6.3,
                                   secondsUntilStrongShaking: 11,
                                   expectedIntensity: .strong,
                                   isDrill: false))
        .previewEnvironment()
}

#Preview("Shaking") {
    EventTakeoverView(event: .init(startedAt: Date().addingTimeInterval(-20),
                                   triggerRatio: 12.1,
                                   estimatedMagnitude: 6.9,
                                   secondsUntilStrongShaking: 8,
                                   expectedIntensity: .severe,
                                   isDrill: false,
                                   actuators: [
                                    .gasValve: .init(kind: .gasValve, state: .confirmed),
                                    .mainsPower: .init(kind: .mainsPower, state: .confirmed),
                                    .waterMain: .init(kind: .waterMain, state: .inProgress),
                                   ]))
        .previewEnvironment()
}
