import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreHaptics)
import CoreHaptics
#endif

/// Haptics as a language rather than as feedback.
///
/// Each event in the app has its own distinct pattern, and they are consistent
/// everywhere. The intent is that a user who has lived with the app for a while
/// knows what has happened before looking at the screen — which matters most in
/// exactly the situation where they cannot look at the screen, because they are
/// getting under a table.
@MainActor
final class Haptics: ObservableObject {

    static let shared = Haptics()

    enum Pattern {
        case connectionEstablished
        case connectionLost
        case eventTriggered
        case actuatorFired
        case actuatorConfirmed
        case actuatorFailed
        case assessmentComplete
        case verdictGreen
        case verdictAmber
        case verdictRed
        case selection
        case buildingStorey
        case countdownTick(secondsRemaining: Int)
        case warning

        var description: String {
            switch self {
            case .connectionEstablished: "Two rising taps"
            case .connectionLost: "Two falling taps"
            case .eventTriggered: "Sharp double pulse"
            case .actuatorFired: "Single firm tap"
            case .actuatorConfirmed: "Light tap"
            case .actuatorFailed: "Buzz"
            case .assessmentComplete: "Soft swell"
            case .verdictGreen: "Single soft tap"
            case .verdictAmber: "Two medium taps"
            case .verdictRed: "Three firm taps"
            case .selection: "Tick"
            case .buildingStorey: "Faint tick per storey"
            case .countdownTick: "Escalating pulse"
            case .warning: "Sustained rumble"
            }
        }
    }

    @Published var isEnabled = true

    #if canImport(CoreHaptics)
    private var engine: CHHapticEngine?
    private var countdownPlayer: CHHapticPatternPlayer?
    private var supportsHaptics: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }
    #endif

    /// Scheduled taps for devices with no Taptic Engine, held so they can be
    /// cancelled — a countdown that keeps tapping after the user has said they
    /// are safe is a countdown nobody trusts twice.
    private var fallbackWork: [DispatchWorkItem] = []

    private init() { prepare() }

    func prepare() {
        #if canImport(CoreHaptics)
        guard supportsHaptics else { return }
        engine = try? CHHapticEngine()
        // The engine is stopped by the system whenever the app is backgrounded
        // or another app takes the haptic hardware; without these handlers it
        // silently never works again.
        engine?.resetHandler = { [weak self] in try? self?.engine?.start() }
        engine?.stoppedHandler = { _ in }
        try? engine?.start()
        #endif
    }

    func play(_ pattern: Pattern) {
        guard isEnabled else { return }
        #if canImport(UIKit)
        switch pattern {
        case .connectionEstablished:
            sequence([(0.0, .light), (0.09, .medium)])
        case .connectionLost:
            sequence([(0.0, .medium), (0.09, .light)])
        case .eventTriggered:
            notify(.warning)
            sequence([(0.05, .heavy), (0.14, .heavy)])
        case .actuatorFired:
            impact(.medium)
        case .actuatorConfirmed:
            impact(.light)
        case .actuatorFailed:
            notify(.error)
        case .assessmentComplete:
            sequence([(0.0, .light), (0.08, .light), (0.18, .medium)])
        case .verdictGreen:
            notify(.success)
        case .verdictAmber:
            sequence([(0.0, .medium), (0.13, .medium)])
        case .verdictRed:
            sequence([(0.0, .heavy), (0.12, .heavy), (0.24, .heavy)])
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .buildingStorey:
            impact(.soft, intensity: 0.4)
        case .countdownTick(let remaining):
            // Escalates as the seconds fall away: this is the pattern that tells
            // somebody how long they have without them looking.
            switch remaining {
            case ...3: impact(.heavy, intensity: 1.0)
            case 4...7: impact(.medium, intensity: 0.8)
            default: impact(.light, intensity: 0.55)
            }
        case .warning:
            notify(.warning)
        }
        #endif
    }

    // MARK: The countdown you can feel

    /// Plays the whole countdown as one choreographed pattern.
    ///
    /// The problem this solves is not "the phone should buzz". The app already
    /// tapped once per second from the display tick. The problem is that the
    /// display tick is a main-thread timer: it stops when the screen locks,
    /// stutters when a 3D scene is being drawn, and cannot produce a sustained
    /// vibration at all — `UIImpactFeedbackGenerator` only does discrete taps.
    /// So the one moment the phone most needed to be in somebody's pocket
    /// telling them something was the moment it went quiet.
    ///
    /// Handing the entire sequence to the haptic engine up front fixes all
    /// three. The engine schedules it against the audio clock, so it plays on
    /// time regardless of what the app is doing, and it can hold a continuous
    /// rumble for the arrival.
    ///
    /// The pattern is a language, and it is meant to be learnable:
    ///
    /// * far out — soft, widely spaced taps, one a second
    /// * closing — the taps sharpen and get closer together
    /// * last three seconds — two hard taps a second, unmistakable
    /// * arrival — a two-second continuous rumble, the only sustained
    ///   vibration this app ever produces
    ///
    /// Nobody learns that during an earthquake, which is why it can be
    /// rehearsed from Preparedness.
    func startCountdown(seconds: Double) {
        #if canImport(CoreHaptics)
        guard isEnabled, supportsHaptics else {
            // Without a Taptic Engine there is still a phone that can vibrate.
            // Falling back to the old per-second tap is much worse, and much
            // better than silence.
            fallbackCountdown(seconds: seconds)
            return
        }
        stopCountdown()
        if engine == nil { prepare() }

        var events: [CHHapticEvent] = []
        let total = min(max(seconds, 0), 60)

        var t = 0.0
        while t < total {
            let remaining = total - t
            // Intensity and sharpness both climb as the time runs out, so the
            // taps do not merely speed up — they harden.
            let urgency = 1 - min(remaining / 12, 1)
            let intensity = Float(0.45 + 0.55 * urgency)
            let sharpness = Float(0.3 + 0.7 * urgency)
            events.append(CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    .init(parameterID: .hapticIntensity, value: intensity),
                    .init(parameterID: .hapticSharpness, value: sharpness),
                ],
                relativeTime: t))

            // Inside the last three seconds there is a second tap between the
            // beats. The doubling is the cue that means "now".
            if remaining <= 3 {
                events.append(CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        .init(parameterID: .hapticIntensity, value: 1.0),
                        .init(parameterID: .hapticSharpness, value: 1.0),
                    ],
                    relativeTime: t + 0.5))
            }
            t += 1
        }

        // Arrival. The only continuous event in the app, so it cannot be
        // confused with anything else it does.
        events.append(CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                .init(parameterID: .hapticIntensity, value: 1.0),
                .init(parameterID: .hapticSharpness, value: 0.55),
            ],
            relativeTime: total, duration: 2.0))

        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            countdownPlayer = try engine?.makePlayer(with: pattern)
            try countdownPlayer?.start(atTime: CHHapticTimeImmediate)
        } catch {
            fallbackCountdown(seconds: total)
        }
        #else
        fallbackCountdown(seconds: seconds)
        #endif
    }

    func stopCountdown() {
        #if canImport(CoreHaptics)
        try? countdownPlayer?.stop(atTime: CHHapticTimeImmediate)
        countdownPlayer = nil
        #endif
        fallbackWork.forEach { $0.cancel() }
        fallbackWork.removeAll()
    }

    /// Whether the choreographed version is what will actually play. Reported so
    /// the rehearsal screen can describe what the user is about to feel rather
    /// than promising a pattern this device cannot produce.
    var canPlayChoreographedCountdown: Bool {
        #if canImport(CoreHaptics)
        return supportsHaptics
        #else
        return false
        #endif
    }

    private func fallbackCountdown(seconds: Double) {
        #if canImport(UIKit)
        guard isEnabled else { return }
        let total = Int(min(max(seconds, 0), 60))
        for second in 0..<total {
            let remaining = total - second
            let item = DispatchWorkItem { [weak self] in
                self?.play(.countdownTick(secondsRemaining: remaining))
            }
            fallbackWork.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(second), execute: item)
        }
        #endif
    }

    /// Continuous vibration matched to simulated shaking, so the phone moves
    /// with the building on screen.
    func playShaking(intensity: Double) {
        guard isEnabled else { return }
        #if canImport(UIKit)
        let clamped = min(max(intensity, 0), 1)
        guard clamped > 0.08 else { return }
        let style: UIImpactFeedbackGenerator.FeedbackStyle =
            clamped > 0.7 ? .heavy : (clamped > 0.35 ? .medium : .light)
        impact(style, intensity: clamped)
        #endif
    }

    #if canImport(UIKit)
    private func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle,
                        intensity: Double = 1.0) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred(intensity: min(max(intensity, 0), 1))
    }

    private func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }

    private func sequence(_ steps: [(TimeInterval, UIImpactFeedbackGenerator.FeedbackStyle)]) {
        for (delay, style) in steps {
            if delay == 0 {
                impact(style)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.impact(style)
                }
            }
        }
    }
    #endif
}

extension View {
    /// Fires a haptic when a value changes, without cluttering the view body.
    func haptic<V: Equatable>(_ pattern: Haptics.Pattern, on value: V) -> some View {
        onChange(of: value) { _, _ in Haptics.shared.play(pattern) }
    }
}
