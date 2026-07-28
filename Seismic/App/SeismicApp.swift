import SwiftUI
import SeismicCore

@main
struct SeismicApp: App {
    /// One object graph, built once, owned by the app. Every screen reads from
    /// it; nothing constructs its own copy of the world.
    @StateObject private var environment = AppEnvironment.live()
    @StateObject private var notifications = NotificationCentre()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .environmentObject(environment.services)
                .environmentObject(environment.voice)
                .environmentObject(notifications)
                // Dark-first: the instrument look is the design, not a theme.
                .preferredColorScheme(.dark)
                .task { await environment.bootstrap() }
        }
    }
}
