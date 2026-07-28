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
    private var supportsHaptics: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }
    #endif

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
