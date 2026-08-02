import SwiftUI
import SeismicCore

/// The call screen, for a call that is not happening.
///
/// It looks like a call because that is the point: somebody watching needs to
/// recognise instantly what the app just did on their behalf. But an interface
/// that convincingly imitates a 911 call and does not say so is a bad thing to
/// build, so the banner is the first element, is not dismissible, and stays for
/// the whole call. Everything below it is honest about being a script.
struct EmergencyCallView: View {
    @ObservedObject var call: EmergencyCallController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.08, green: 0.02, blue: 0.05),
                                    Theme.Palette.background],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                banner
                    .padding(.horizontal, Theme.Metrics.screenPadding)
                    .padding(.top, Theme.Metrics.s3)

                header
                    .padding(.horizontal, Theme.Metrics.screenPadding)
                    .padding(.top, Theme.Metrics.s7)

                transcript
                    .padding(.top, Theme.Metrics.s6)

                controls
                    .padding(.horizontal, Theme.Metrics.s6)
                    .padding(.top, Theme.Metrics.s5)
                    // Clear of the home indicator: the end-call button is the
                    // one thing on this screen somebody reaches for in a hurry,
                    // and iOS takes the first part of any upward swipe from the
                    // bottom edge for itself.
                    .padding(.bottom, Theme.Metrics.s6)
            }
            .contentColumn()
        }
    }

    // MARK: The banner that cannot be missed

    private var banner: some View {
        HStack(spacing: Theme.Metrics.s3) {
            Image(systemName: "theatermasks.fill")
                .font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading, spacing: 3) {
                Text("SIMULATED CALL")
                    .font(Theme.Typography.label)
                    .tracking(1.2)
                Text("No call is being placed. Nothing is dialled and nobody is listening. "
                     + "The report itself is real — it is built from this event.")
                    .font(Theme.Typography.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(0.85)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.Palette.verdictAmber)
        .padding(.horizontal, Theme.Metrics.s4)
        .padding(.vertical, Theme.Metrics.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall, style: .continuous)
                .fill(Theme.Palette.verdictAmber.opacity(0.12)))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall, style: .continuous)
                .strokeBorder(Theme.Palette.verdictAmber.opacity(0.4), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    // MARK: Who, and for how long

    private var header: some View {
        VStack(spacing: Theme.Metrics.s3) {
            ZStack {
                Circle()
                    .fill(Theme.Palette.verdictRed.opacity(0.18))
                    .frame(width: 96, height: 96)
                    .scaleEffect(pulse ? 1.12 : 1)
                Image(systemName: "phone.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Theme.Palette.verdictRed)
            }
            .animation(reduceMotion ? nil
                       : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                       value: pulse)
            .onAppear { pulse = true }

            Text("Emergency services")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.textPrimary)

            Text(EmergencyCallController.emergencyNumber)
                .font(Theme.Typography.numericLarge)
                .foregroundStyle(Theme.Palette.textSecondary)

            HStack(spacing: Theme.Metrics.s2) {
                Text(call.stage?.label ?? "")
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textSecondary)
                if call.elapsed >= 1 {
                    Text("·")
                        .foregroundStyle(Theme.Palette.textGhost)
                    Text(duration)
                        .font(Theme.Typography.numeric)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .padding(.top, Theme.Metrics.s1)
        }
        .frame(maxWidth: .infinity)
    }

    @State private var pulse = false

    private var duration: String {
        let total = Int(call.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: What is being said

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
                    ForEach(call.transcript) { line in
                        utterance(line)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, Theme.Metrics.screenPadding)
                .padding(.vertical, Theme.Metrics.s2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: call.currentLine) { _, id in
                guard let id else { return }
                withAnimation(Theme.Motion.gentle) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func utterance(_ line: EmergencyCallController.Utterance) -> some View {
        let isApp = line.speaker == .app
        let isCurrent = call.currentLine == line.id
        return VStack(alignment: isApp ? .trailing : .leading, spacing: Theme.Metrics.s2) {
            Text(isApp ? "SEISMIC" : "DISPATCHER")
                .font(Theme.Typography.label)
                .tracking(1.0)
                .foregroundStyle(isApp ? Theme.Palette.accent : Theme.Palette.textTertiary)

            Text(line.text)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .multilineTextAlignment(isApp ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Metrics.s4)
                .padding(.vertical, Theme.Metrics.s3)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall,
                                     style: .continuous)
                        .fill(isApp ? Theme.Palette.accent.opacity(isCurrent ? 0.26 : 0.14)
                                    : Theme.Palette.glass))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall,
                                     style: .continuous)
                        .strokeBorder(isCurrent ? Theme.Palette.accent.opacity(0.6) : .clear,
                                      lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: isApp ? .trailing : .leading)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .animation(Theme.Motion.gentle, value: isCurrent)
    }

    // MARK: Ending it

    private var controls: some View {
        VStack(spacing: Theme.Metrics.s3) {
            if call.stage == .ended {
                Button {
                    call.dismiss()
                } label: {
                    Text("Close")
                        .font(Theme.Typography.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                }
                .buttonStyle(SecondaryButtonStyle())
            } else {
                Button {
                    Haptics.shared.play(.selection)
                    call.hangUp()
                } label: {
                    Label("End call", systemImage: "phone.down.fill")
                        .font(Theme.Typography.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 62)
                        .foregroundStyle(.white)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius,
                                             style: .continuous)
                                .fill(Theme.Palette.verdictRed.opacity(0.85)))
                }
                .buttonStyle(.plain)
            }

            Text("Ending this changes nothing outside the app.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }
}

/// Presents the call when there is one, and observes it so that happens.
struct EmergencyCallHost: View {
    @ObservedObject var call: EmergencyCallController

    var body: some View {
        Group {
            if call.stage != nil {
                EmergencyCallView(call: call)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Theme.Motion.standard, value: call.stage)
    }
}

#Preview {
    let controller = EmergencyCallController()
    return EmergencyCallView(call: controller)
        .onAppear {
            controller.place(report: [
                "This is an automated report from a seismic monitor at 41 Bryant Street. "
                    + "This is not a person speaking.",
                "An earthquake of estimated magnitude 6.4 was detected by three independent "
                    + "sensors.",
                "Building power and the water main have been shut off and physically confirmed.",
            ])
        }
}
