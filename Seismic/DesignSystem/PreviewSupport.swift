import SwiftUI

#if DEBUG
/// One object graph for every preview.
///
/// Each screen needs four environment objects and a preview that forgets one
/// crashes on sight. Injecting them from a single modifier means adding a fifth
/// later is one edit rather than twenty, and — more usefully — every preview is
/// looking at the *same* seeded world, so a building that appears in one screen
/// appears in the others.
struct PreviewEnvironment: ViewModifier {
    @StateObject private var environment = AppEnvironment.preview()
    @StateObject private var notifications = NotificationCentre()

    func body(content: Content) -> some View {
        content
            .environmentObject(environment)
            .environmentObject(environment.services)
            .environmentObject(environment.voice)
            .environmentObject(notifications)
            .preferredColorScheme(.dark)
    }
}

extension View {
    func previewEnvironment() -> some View { modifier(PreviewEnvironment()) }
}
#endif
