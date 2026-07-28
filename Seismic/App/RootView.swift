import SwiftUI
import SeismicCore

/// The top-level destinations.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case home, monitor, simulator, map, library, node, assess, feed, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .monitor: "Monitor"
        case .simulator: "Simulator"
        case .map: "Map"
        case .library: "Library"
        case .node: "Node"
        case .assess: "Assess"
        case .feed: "Feed"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .monitor: "waveform.path.ecg"
        case .simulator: "cube.transparent"
        case .map: "map"
        case .library: "building.2"
        case .node: "sensor.tag.radiowaves.forward"
        case .assess: "checkmark.shield"
        case .feed: "globe.americas"
        case .settings: "gearshape"
        }
    }

    /// The five that get a tab. The rest are reached from Home and from the
    /// More menu — a bar of nine icons is a bar nobody can use in a hurry.
    static let primary: [AppSection] = [.home, .monitor, .simulator, .map, .library]
    static let secondary: [AppSection] = [.assess, .node, .feed, .settings]
}

struct RootView: View {
    @EnvironmentObject private var env: AppEnvironment
    /// Honours `SEISMIC_INITIAL_TAB` so a demo, a screenshot run or a UI test
    /// can open straight onto a given screen instead of navigating there.
    @State private var selection: AppSection =
        ProcessInfo.processInfo.environment["SEISMIC_INITIAL_TAB"]
            .flatMap(AppSection.init(rawValue:)) ?? .home

    var body: some View {
        ZStack {
            if !env.isBootstrapped {
                LaunchView()
                    .transition(.opacity)
            } else if !env.didCompleteOnboarding {
                OnboardingFlow()
                    .transition(.opacity)
            } else {
                mainInterface
            }

            // Life safety outranks everything. During an event this covers the
            // entire screen and nothing competes with it — not a tab bar, not a
            // navigation title, not a sheet.
            if let event = env.activeEvent {
                EventTakeoverView(event: event)
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
                    .zIndex(100)
            }
        }
        .animation(Theme.Motion.standard, value: env.activeEvent?.id)
        .animation(Theme.Motion.gentle, value: env.isBootstrapped)
        .animation(Theme.Motion.gentle, value: env.didCompleteOnboarding)
    }

    private var mainInterface: some View {
        TabView(selection: $selection) {
            ForEach(AppSection.primary) { section in
                NavigationStack {
                    destination(for: section)
                        .seismicBackground()
                        .navigationTitle(section.title)
                        .navigationBarTitleDisplayMode(section == .simulator ? .inline : .large)
                        .toolbar { toolbarContent(for: section) }
                        .navigationDestination(for: AppSection.self) { pushed in
                            destination(for: pushed)
                                .seismicBackground()
                                .navigationTitle(pushed.title)
                        }
                }
                .tabItem { Label(section.title, systemImage: section.systemImage) }
                .tag(section)
            }
        }
        .tint(Theme.Palette.accent)
    }

    @ToolbarContentBuilder
    private func toolbarContent(for section: AppSection) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                ForEach(AppSection.secondary) { item in
                    NavigationLink(value: item) {
                        Label(item.title, systemImage: item.systemImage)
                    }
                }
                Divider()
                Button {
                    env.isPresentationMode.toggle()
                } label: {
                    Label(env.isPresentationMode ? "Stop presentation" : "Presentation mode",
                          systemImage: "play.rectangle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private func destination(for section: AppSection) -> some View {
        switch section {
        case .home: HomeScreen()
        case .monitor: MonitorScreen()
        case .simulator: SimulatorScreen()
        case .map: CommunityMapScreen()
        case .library: LibraryScreen()
        case .node: NodeScreen()
        case .assess: AssessScreen()
        case .feed: GlobalFeedScreen()
        case .settings: SettingsScreen()
        }
    }
}

/// Shown for the fraction of a second the store takes to load. It says what it
/// is doing rather than showing a bare spinner, because even a brief unexplained
/// wait reads as a hang.
struct LaunchView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .strokeBorder(Theme.Palette.accent.opacity(0.25), lineWidth: 1)
                    .frame(width: pulse ? 130 : 90, height: pulse ? 130 : 90)
                    .opacity(pulse ? 0 : 1)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(Theme.Palette.accent)
            }
            .frame(height: 130)

            Text("SEISMIC")
                .font(.system(size: 26, weight: .semibold))
                .tracking(6)
                .foregroundStyle(Theme.Palette.textPrimary)

            Text(env.bootstrapStage)
                .font(Theme.Typography.numericSmall)
                .foregroundStyle(Theme.Palette.textTertiary)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .seismicBackground()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

#Preview {
    RootView().environmentObject(AppEnvironment.preview())
}
