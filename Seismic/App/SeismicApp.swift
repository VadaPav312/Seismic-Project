import SwiftUI
import SeismicCore

@main
struct SeismicApp: App {
    /// One object graph, built once, owned by the app. Every screen reads from
    /// it; nothing constructs its own copy of the world.
    @StateObject private var environment = AppEnvironment.live()
    @StateObject private var notifications = NotificationCentre()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .environmentObject(environment.services)
                .environmentObject(environment.node)
                .environmentObject(environment.voice)
                .environmentObject(environment.sync)
                .environmentObject(notifications)
                // Dark-first: the instrument look is the design, not a theme.
                .preferredColorScheme(.dark)
                .task { await environment.bootstrap() }
                // Coming back to the foreground is the most reliable moment to
                // find both a network and a queue with something in it — and
                // the only moment at which a permission the user just changed
                // in iOS Settings can be noticed, since nothing tells an app
                // that its notification authorisation was revoked.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await environment.sync.sync() }
                    Task { await notifications.refreshAuthorisation() }
                }
        }
    }
}
