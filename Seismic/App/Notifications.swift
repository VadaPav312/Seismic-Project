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

    /// Whether critical alerts — the ones that sound through a silent switch
    /// and Do Not Disturb — were actually granted.
    ///
    /// They need an entitlement Apple grants case by case. Asking for them
    /// without it makes the *entire* authorisation request fail, which for a
    /// safety app means no notifications at all rather than merely quieter
    /// ones, so the request falls back and the interruption level follows what
    /// was really granted rather than what was hoped for.
    @Published private(set) var hasCriticalAlerts = false
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
        let settings = await centre.notificationSettings()
        authorisation = settings.authorizationStatus
        hasCriticalAlerts = settings.criticalAlertSetting == .enabled
    }

    /// Asks only if the system has never asked before.
    ///
    /// This is what the app calls at the two moments the reason is obvious —
    /// the end of the first assessment in the introduction, and the arrival of
    /// the first real verdict. Both can happen more than once and either can
    /// happen first, so the decision of *whether* to prompt belongs here rather
    /// than being duplicated at each call site. Once the user has answered,
    /// `.denied` and `.authorized` both mean "do not ask again": iOS shows the
    /// system prompt exactly once, and re-requesting after a denial returns
    /// false silently, which would leave a caller believing it had asked.
    @discardableResult
    func requestAuthorisationIfUndecided() async -> Bool {
        // A screenshot or demonstration run must not be interrupted by a system
        // alert it has no way to answer. Same escape hatch as
        // `SEISMIC_SKIP_SIGN_IN`, and it only ever *suppresses* a prompt — there
        // is no path here that grants anything.
        if ProcessInfo.processInfo.environment["SEISMIC_SKIP_SIGN_IN"] == "1" { return false }
        await refreshAuthorisation()
        guard authorisation == .notDetermined else { return authorisation == .authorized }
        return await requestAuthorisation()
    }

    /// Asked for at a moment when the reason is obvious — after the first
    /// assessment, not on the launch screen. A permission prompt shown before
    /// the user knows what the app does is a permission prompt that gets denied.
    @discardableResult
    func requestAuthorisation() async -> Bool {
        let ordinary: UNAuthorizationOptions = [.alert, .sound, .badge]
        do {
            let granted = try await centre.requestAuthorization(
                options: ordinary.union(.criticalAlert))
            await refreshAuthorisation()
            return granted
        } catch {
            // Almost always the missing critical-alert entitlement. Ask again
            // for what this build can actually have, rather than leaving the
            // user with nothing.
            do {
                let granted = try await centre.requestAuthorization(options: ordinary)
                await refreshAuthorisation()
                return granted
            } catch {
                await refreshAuthorisation()
                return false
            }
        }
    }

    // MARK: Sending

    func notify(_ kind: Kind, title: String, body: String, after delay: TimeInterval = 0) {
        guard enabled[kind] ?? true else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Only claim to be critical if the system agreed. Setting a critical
        // level or sound without the entitlement makes the request fail, so an
        // over-claiming warning is a warning that never arrives.
        let breaksThrough = kind.isCritical && hasCriticalAlerts
        content.interruptionLevel = breaksThrough ? .critical : .active
        content.sound = breaksThrough ? .defaultCriticalSound(withAudioVolume: 1.0) : .default
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
    ///
    /// "Once" has to be enforced, not merely intended. A verdict arrives after
    /// every event, and an aftershock sequence produces a great many of them —
    /// so each one was queueing another advice notification at its own wait
    /// time, and somebody sheltering through a bad night would have been told
    /// four separate times that it was safe to go back in, at four different
    /// hours, each one out of date the moment the next shock arrived. Only the
    /// most recent forecast is worth anything, so the pending one is replaced.
    func scheduleAftershockAdvice(afterHours hours: Double, headline: String, detail: String) {
        cancelPending(.aftershockWindow)
        guard hours > 0 else { return }
        notify(.aftershockWindow, title: headline, body: detail, after: hours * 3600)
    }

    /// Drops anything of one kind that has not fired yet.
    ///
    /// Identifiers are `kind-uuid`, so the prefix is what identifies a kind.
    func cancelPending(_ kind: Kind) {
        centre.getPendingNotificationRequests { requests in
            let stale = requests.map(\.identifier)
                .filter { $0.hasPrefix(kind.rawValue + "-") }
            guard !stale.isEmpty else { return }
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: stale)
        }
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

            if !centre.hasCriticalAlerts, centre.authorisation == .authorized {
                Text("This build cannot sound through a silent switch — critical alerts need "
                     + "an entitlement Apple grants case by case. The earthquake warning still "
                     + "arrives; it just obeys your ringer like everything else.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
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
                                    StatusPill(text: centre.hasCriticalAlerts
                                               ? "Breaks through silence"
                                               : "Normal alert",
                                               tint: centre.hasCriticalAlerts
                                               ? Theme.Palette.accent
                                               : Theme.Palette.textSecondary)
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
