import Foundation
import UserNotifications
import SwiftUI
import SeismicCore

/// Notifications, and the rule they all obey.
///
/// A safety app that cries wolf is worse than no app, because the second time
/// it fires nobody moves. So there are exactly four things this app will ever
/// interrupt somebody for, each is listed below in plain words, and each can be
/// turned off individually — including the earthquake warning itself, because a
/// person who works nights and does not want to be woken is entitled to that
/// choice and will otherwise simply mute everything.
@MainActor
final class NotificationCentre: NSObject, ObservableObject {

    enum Kind: String, CaseIterable, Identifiable {
        case earlyWarning
        case assessmentReady
        case householdCheckIn
        case aftershockWindow

        var id: String { rawValue }

        var title: String {
            switch self {
            case .earlyWarning: "Earthquake warning"
            case .assessmentReady: "Assessment finished"
            case .householdCheckIn: "Household check-in"
            case .aftershockWindow: "Aftershock advice"
            }
        }

        var explanation: String {
            switch self {
            case .earlyWarning:
                "Seconds before strong shaking reaches you. This is the one that matters."
            case .assessmentReady:
                "When the measurement after an event has finished and there is a verdict."
            case .householdCheckIn:
                "When somebody in your household has not checked in after an event."
            case .aftershockWindow:
                "Once, when the aftershock risk has dropped enough to matter."
            }
        }

        var defaultsKey: String { "notify.\(rawValue)" }

        /// The warning bypasses Do Not Disturb; nothing else does.
        var isCritical: Bool { self == .earlyWarning }
    }

    @Published private(set) var authorisation: UNAuthorizationStatus = .notDetermined
    @Published var enabled: [Kind: Bool] = [:]

    private let centre = UNUserNotificationCenter.current()

    override init() {
        super.init()
        for kind in Kind.allCases {
            enabled[kind] = UserDefaults.standard.object(forKey: kind.defaultsKey) as? Bool ?? true
        }
        centre.delegate = self
        Task { await refreshAuthorisation() }
    }

    func setEnabled(_ isEnabled: Bool, for kind: Kind) {
        enabled[kind] = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: kind.defaultsKey)
    }

    func refreshAuthorisation() async {
        authorisation = await centre.notificationSettings().authorizationStatus
    }

    /// Asked for at a moment when the reason is obvious — after the first
    /// assessment, not on the launch screen. A permission prompt shown before
    /// the user knows what the app does is a permission prompt that gets denied.
    @discardableResult
    func requestAuthorisation() async -> Bool {
        do {
            let granted = try await centre.requestAuthorization(
                options: [.alert, .sound, .badge, .criticalAlert])
            await refreshAuthorisation()
            return granted
        } catch {
            await refreshAuthorisation()
            return false
        }
    }

    // MARK: Sending

    func notify(_ kind: Kind, title: String, body: String, after delay: TimeInterval = 0) {
        guard enabled[kind] ?? true else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.interruptionLevel = kind.isCritical ? .critical : .active
        content.sound = kind.isCritical
            ? .defaultCriticalSound(withAudioVolume: 1.0)
            : .default
        content.threadIdentifier = kind.rawValue

        let trigger = delay > 0
            ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            : nil
        centre.add(UNNotificationRequest(identifier: "\(kind.rawValue)-\(UUID().uuidString)",
                                         content: content, trigger: trigger))
    }

    func announceAssessment(_ assessment: Assessment, buildingName: String) {
        notify(.assessmentReady,
               title: "\(buildingName): \(assessment.verdict.placard)",
               body: assessment.verdict.plainMeaning)
    }

    func askHouseholdToCheckIn(memberName: String) {
        notify(.householdCheckIn,
               title: "\(memberName) has not checked in",
               body: "Tap to send a message, or mark them safe if you have heard from them.")
    }

    /// Scheduled once, for when the aftershock rate has fallen far enough that
    /// re-entry advice changes. Deliberately a single notification rather than a
    /// running commentary on every aftershock.
    func scheduleAftershockAdvice(afterHours hours: Double, headline: String, detail: String) {
        guard hours > 0 else { return }
        notify(.aftershockWindow, title: headline, body: detail, after: hours * 3600)
    }

    func cancelAll() {
        centre.removeAllPendingNotificationRequests()
    }
}

extension NotificationCentre: UNUserNotificationCenterDelegate {
    /// Shown even when the app is open. During an event the user may be looking
    /// at a different screen, and the warning must not be swallowed.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

/// The settings block, so the four kinds can be seen and switched individually.
struct NotificationSettingsSection: View {
    @ObservedObject var centre: NotificationCentre

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Notifications", systemImage: "bell")

            if centre.authorisation == .denied {
                InlineNotice(
                    level: .warning,
                    title: "Notifications are switched off for this app",
                    message: "The early warning cannot reach you while they are. Everything "
                        + "inside the app still works.",
                    actionTitle: "Open Settings",
                    action: {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    })
            } else if centre.authorisation == .notDetermined {
                Button {
                    Task { await centre.requestAuthorisation() }
                } label: {
                    Label("Allow notifications", systemImage: "bell.badge")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            ForEach(NotificationCentre.Kind.allCases) { kind in
                Toggle(isOn: Binding(
                    get: { centre.enabled[kind] ?? true },
                    set: { centre.setEnabled($0, for: kind) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(kind.title)
                                    .font(Theme.Typography.callout)
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                if kind.isCritical {
                                    StatusPill(text: "Breaks through silence",
                                               tint: Theme.Palette.accent)
                                }
                            }
                            Text(kind.explanation)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(Theme.Palette.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }
}
