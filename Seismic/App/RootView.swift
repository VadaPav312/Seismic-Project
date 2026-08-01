import SwiftUI
import SeismicCore
import SeismicServices
import SeismicStructures

/// The top-level destinations.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case home, monitor, simulator, map, library, node, assess, feed
    case prepare, household, network, shakeTable, analysis, settings
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
        case .prepare: "Preparedness"
        case .household: "Household"
        case .network: "Network"
        case .shakeTable: "Shake table"
        case .analysis: "Analysis"
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
        case .prepare: "checklist"
        case .household: "person.3"
        case .network: "point.3.connected.trianglepath.dotted"
        case .shakeTable: "slider.horizontal.below.rectangle"
        case .analysis: "waveform.and.magnifyingglass"
        case .settings: "gearshape"
        }
    }

    /// The five that get a tab. The rest are reached from Home and from the
    /// More menu — a bar of nine icons is a bar nobody can use in a hurry.
    static let primary: [AppSection] = [.home, .monitor, .simulator, .map, .library]
    /// Reached from the More menu. Settings is deliberately absent — it has its
    /// own button in the toolbar.
    static let secondary: [AppSection] = [.assess, .analysis, .node, .feed, .prepare,
                                          .household, .network, .shakeTable]
}

struct RootView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var services: ServiceHub
    @EnvironmentObject private var voice: VoiceController
    @EnvironmentObject private var notifications: NotificationCentre
    @StateObject private var director = PresentationDirector()
    @StateObject private var tutorial = TutorialDirector()
    /// The tab bar's selection, which can only ever be one of the five primary
    /// sections.
    @State private var selection: AppSection = .home

    /// A section that has no tab of its own, shown over the top of whichever
    /// tab is selected.
    ///
    /// Without this, asking for a secondary section — by voice, by deep link or
    /// by `SEISMIC_INITIAL_TAB` — would set a tab selection that matches no tab
    /// and silently leave the user on Home.
    @State private var presented: AppSection?

    var body: some View {
        ZStack {
            if !env.isBootstrapped {
                LaunchView()
                    .transition(.opacity)
            } else if services.account == nil {
                // Sign-in comes first, before the introduction: the intro ends
                // by importing a real building, and that is worth keeping if
                // an account exists to keep it against.
                //
                // "Continue without an account" creates a guest, which is a
                // real account locally — so this gate always has a way through
                // and never blocks anybody out of the app.
                AuthSheet(isLaunchGate: true)
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

            // Below the takeover in the stack, deliberately: if a real event
            // happens during a demonstration, the demonstration gets out of
            // the way.
            if director.isRunning {
                PresentationOverlay(director: director) {
                    director.stop()
                    env.isPresentationMode = false
                }
                .zIndex(90)
            }

            // Below both of the above: a tour is the least important thing on
            // screen, and an event or a demonstration should bury it.
            if tutorial.isRunning {
                TutorialOverlay(director: tutorial)
                    .zIndex(80)
            }
        }
        .collectsTutorialAnchors(into: tutorial)
        .fullScreenCover(item: $presented) { section in
            NavigationStack {
                destination(for: section)
                    .seismicBackground()
                    .navigationTitle(section.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { presented = nil }
                        }
                    }
            }
            // A cover is its own hierarchy and inherits nothing, so every
            // object a secondary screen expects has to be handed over again.
            // Settings reads the tutorial director; omitting it here would
            // crash the moment somebody opened Settings.
            .environmentObject(tutorial)
        }
        .task {
            // Honours SEISMIC_INITIAL_TAB so a demo, a screenshot run or a UI
            // test can open straight onto any screen — including the ones that
            // have no tab of their own.
            if let requested = ProcessInfo.processInfo.environment["SEISMIC_INITIAL_TAB"]
                .flatMap(AppSection.init(rawValue:)) {
                show(requested)
                return
            }
            startTutorialIfDue()
        }
        // The intro ends by setting this, which is the moment the real interface
        // first appears — and therefore the only moment a tour of it makes sense.
        // Three separate moments can make the tour due, and it needs all of
        // them. `.task` fires before `bootstrap()` has finished, so on a launch
        // where onboarding was already complete the guard below fails and
        // nothing would ever ask again — which is exactly how the tour came to
        // never appear for a returning user.
        .onChange(of: env.isBootstrapped) { _, _ in startTutorialIfDue() }
        .onChange(of: env.didCompleteOnboarding) { _, completed in
            guard completed else { return }
            startTutorialIfDue()
        }
        .onChange(of: tutorial.replayRequested) { _, requested in
            guard requested else { return }
            tutorial.replayRequested = false
            presented = nil          // step out of Settings, which is a cover
            startTutorialIfDue()
        }
        .animation(Theme.Motion.standard, value: env.activeEvent?.id)
        .animation(Theme.Motion.gentle, value: env.isBootstrapped)
        .animation(Theme.Motion.gentle, value: env.didCompleteOnboarding)
        .animation(Theme.Motion.gentle, value: services.account == nil)
        // A recognised command is consumed here rather than in each screen, so
        // "show the map" works from wherever the user happens to be.
        .onChange(of: voice.recognisedCommand) { _, command in
            guard let command else { return }
            perform(command)
        }
        .onChange(of: env.latestAssessment?.id) { _, _ in announceAssessment() }
        // Honours a navigation request made from inside a sheet, which has no
        // other way to reach the tab bar. Cleared immediately so the same
        // request cannot fire twice.
        .onChange(of: env.requestedSection) { _, section in
            guard let section else { return }
            env.requestedSection = nil
            show(section)
        }
        .onChange(of: env.isPresentationMode) { _, isOn in
            if isOn {
                director.start(environment: env) { section in show(section) }
            } else {
                director.stop()
            }
        }
        .alert("Confirm out loud commands", isPresented: Binding(
            get: { voice.pendingConfirmation != nil },
            set: { if !$0 { voice.cancelPending() } })) {
            Button("Do it", role: .destructive) { voice.confirmPending() }
            Button("Cancel", role: .cancel) { voice.cancelPending() }
        } message: {
            Text(voice.pendingConfirmation.map {
                "\($0.confirmation) This one moves something physical, so it needs a tap as "
                + "well as a word."
            } ?? "")
        }
    }

    /// Starts the guided tour, once, after the introduction.
    ///
    /// Deferred by a beat so the first screen has actually laid out — the
    /// spotlight is cut around frames the highlighted views report, and none of
    /// them have reported anything until they have been drawn once.
    private func startTutorialIfDue() {
        guard env.isBootstrapped, env.didCompleteOnboarding,
              services.account != nil, !tutorial.didComplete, !tutorial.isRunning else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !tutorial.didComplete else { return }
            withAnimation(Theme.Motion.gentle) {
                tutorial.start { section in show(section) }
            }
        }
    }

    /// The one way to get anywhere. A primary section changes the tab; a
    /// secondary one is presented over it.
    private func show(_ section: AppSection) {
        if AppSection.primary.contains(section) {
            presented = nil
            selection = section
        } else {
            presented = section
        }
    }

    /// Commands that only navigate run immediately. Anything physical has
    /// already been gated behind the confirmation alert above.
    private func perform(_ command: VoiceCommand) {
        _ = voice.consumeCommand()
        switch command {
        case .status, .isItSafe, .readAssessment:
            show(.assess)
            if let assessment = env.latestAssessment {
                voice.speak(assessment.verdict.placard + ". "
                            + assessment.verdict.plainMeaning, urgency: .calm, force: true)
            } else {
                voice.speak("There is no assessment yet. The building has not been shaken "
                            + "since the baseline was taken.", urgency: .calm, force: true)
            }
        case .startDrill:
            env.startDrill(fireActuators: false)
        case .measureNow:
            env.session.send(.requestPeriodMeasurement)
            show(.monitor)
        case .closeGas:
            env.session.send(.fireActuator(.gasValve))
        case .callHousehold:
            show(.household)
        case .showMap:
            show(.map)
        case .stopSpeaking:
            voice.stopSpeaking()
        }
        Haptics.shared.play(.selection)
    }

    /// The notification that goes out when a verdict lands. Sent from here
    /// because the notification centre is a view-layer concern — the assessment
    /// itself is computed whether or not anybody is allowed to be told.
    /// The second and last place permission is asked for. Somebody who used the
    /// introduction's escape hatches can reach a real verdict without ever
    /// having been asked, and a verdict is the most self-explanatory reason
    /// there is. `requestAuthorisationIfUndecided` makes this a no-op once the
    /// question has been answered either way, so this is not a nag.
    private func announceAssessment() {
        guard let assessment = env.latestAssessment,
              let building = env.selectedBuilding,
              Date().timeIntervalSince(assessment.createdAt) < 60 else { return }
        Task {
            await notifications.requestAuthorisationIfUndecided()
            notifications.announceAssessment(assessment, buildingName: building.name)

            // A verdict is also the moment the other two notifications become
            // meaningful: an event has just happened, so there is now a reason
            // to wait before going back in, and a reason to want to know where
            // everybody is. Both are sent from here rather than from the
            // screens that display the same information, because a user who
            // never opens those screens is exactly the user who needs telling.
            let guidance = AftershockForecast.reentryGuidance(
                mainshockMagnitude: 6.4, verdict: assessment.verdict)
            notifications.scheduleAftershockAdvice(
                afterHours: guidance.recommendedWaitHours,
                headline: "\(building.name): the aftershock risk has dropped",
                detail: guidance.detail)

            for member in services.household?.membersUnaccountedFor ?? [] {
                notifications.askHouseholdToCheckIn(memberName: member.displayName)
            }
        }
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
                }
                .tabItem { Label(section.title, systemImage: section.systemImage) }
                .tag(section)
            }
        }
        .tint(Theme.Palette.accent)
        .environmentObject(tutorial)
    }

    @ToolbarContentBuilder
    private func toolbarContent(for section: AppSection) -> some ToolbarContent {
        // Settings gets its own button rather than living in the overflow menu.
        // It is the one destination people go looking for by habit, and hiding
        // the habitual thing behind a menu is how an app earns a reputation for
        // being hard to use.
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Haptics.shared.play(.selection)
                show(.settings)
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                ForEach(AppSection.secondary) { item in
                    Button {
                        show(item)
                    } label: {
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
            .tutorialAnchor(.moreMenu)
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
        case .prepare: PreparednessScreen()
        case .household: HouseholdScreen()
        case .network: NetworkScreen()
        case .shakeTable: ShakeTableScreen()
        case .analysis: AnalysisScreen()
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
    RootView().previewEnvironment()
}
