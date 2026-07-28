import Foundation
import SwiftUI
import WidgetKit
import SeismicCore
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Drives the Lock Screen during an event, and keeps the home-screen widget fed.
///
/// The Live Activity is the part of this app most people will actually see when
/// it matters. During an earthquake nobody unlocks a phone and finds an app —
/// they glance at a screen that is already lit. So the sequence is started from
/// the first trigger, updated as the picture firms up, and ended deliberately
/// once there is a verdict, rather than being left to expire.
@MainActor
final class LiveActivityController: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var unavailableReason: String?

    #if canImport(ActivityKit)
    private var activity: Any?
    #endif

    /// Whether the system will accept one. Reported rather than assumed, so
    /// Settings can explain why the Lock Screen stayed empty.
    var areActivitiesEnabled: Bool {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        }
        #endif
        return false
    }

    // MARK: Live Activity

    func start(buildingName: String, secondsUntilShaking: Double?,
               magnitude: Double?, intensity: MercalliIntensity?, isDrill: Bool) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else { return }
        guard areActivitiesEnabled else {
            unavailableReason = "Live Activities are switched off for this app in Settings."
            return
        }
        end()

        let attributes = SeismicEventAttributes(buildingName: buildingName, startedAt: Date())
        let state = SeismicEventAttributes.ContentState(
            stage: (secondsUntilShaking ?? 0) > 1 ? .warning : .shaking,
            secondsUntilShaking: secondsUntilShaking.map { Int($0.rounded()) },
            estimatedMagnitude: magnitude,
            intensityLabel: intensity?.shortLabel,
            isDrill: isDrill)

        do {
            // Stale after two minutes: an event that somehow never resolves
            // must not leave a stale warning on somebody's Lock Screen for
            // eight hours.
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state,
                               staleDate: Date().addingTimeInterval(120)),
                pushType: nil)
            isRunning = true
            unavailableReason = nil
        } catch {
            unavailableReason = "The system declined to start a Live Activity."
        }
        #endif
    }

    func update(stage: LiveStage, secondsUntilShaking: Double?, magnitude: Double?,
                intensity: MercalliIntensity?, verdict: SafetyVerdict?,
                actuatorsFired: Int, actuatorsConfirmed: Int, isDrill: Bool) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *),
              let activity = activity as? Activity<SeismicEventAttributes> else { return }

        let state = SeismicEventAttributes.ContentState(
            stage: stage.attributeStage,
            secondsUntilShaking: secondsUntilShaking.map { Int($0.rounded()) },
            estimatedMagnitude: magnitude,
            intensityLabel: intensity?.shortLabel,
            verdict: verdict,
            actuatorsFired: actuatorsFired,
            actuatorsConfirmed: actuatorsConfirmed,
            isDrill: isDrill)

        Task {
            await activity.update(.init(state: state,
                                        staleDate: Date().addingTimeInterval(180)))
        }
        #endif
    }

    /// Ends with the verdict showing, then dismisses after a few minutes.
    ///
    /// Not immediately: the verdict is the most useful thing this app ever
    /// produces, and somebody standing outside their building wants it visible
    /// without unlocking anything.
    func finish(verdict: SafetyVerdict?, buildingName: String) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *),
              let activity = activity as? Activity<SeismicEventAttributes> else { return }

        let state = SeismicEventAttributes.ContentState(stage: .assessed, verdict: verdict)
        Task {
            await activity.end(.init(state: state, staleDate: nil),
                               dismissalPolicy: .after(Date().addingTimeInterval(300)))
        }
        self.activity = nil
        isRunning = false
        #endif
    }

    func end() {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *),
              let activity = activity as? Activity<SeismicEventAttributes> else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        self.activity = nil
        isRunning = false
        #endif
    }

    /// Mirrors the widget's stage enum without the app having to import
    /// ActivityKit types at every call site.
    enum LiveStage {
        case warning, shaking, measuring, assessed

        #if canImport(ActivityKit)
        @available(iOS 16.1, *)
        var attributeStage: SeismicEventAttributes.ContentState.Stage {
            switch self {
            case .warning: .warning
            case .shaking: .shaking
            case .measuring: .measuring
            case .assessed: .assessed
            }
        }
        #endif
    }

    // MARK: Home screen widget

    /// Publishes the handful of fields the widget shows.
    ///
    /// Called after anything that could change them. Writing is cheap; a widget
    /// showing a verdict from three events ago is not.
    func publish(building: BuildingModel?, assessment: Assessment?,
                 isConnected: Bool, isSimulated: Bool, lastEventAt: Date?) {
        let snapshot = WidgetSnapshot(
            buildingName: building?.name ?? "No building",
            verdict: assessment?.verdict,
            assessedAt: assessment?.createdAt,
            periodSeconds: assessment?.periodAfterTemperatureCorrection
                ?? assessment?.periodAfter
                ?? building?.empiricalPeriod,
            periodChangePercent: assessment?.periodChangePercent,
            isNodeConnected: isConnected,
            isSimulated: isSimulated,
            lastEventAt: lastEventAt)

        WidgetBridge.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
