import Foundation
import SwiftUI
import Combine
import SeismicCore
import SeismicSignal
import SeismicStructures
import SeismicGeo
import SeismicDevice
import SeismicData
import SeismicServices

/// The application's object graph.
///
/// Everything the app can do hangs off this one observable object. It is built
/// once at launch and injected into the view tree, so no screen ever constructs
/// its own store, its own node connection, or its own copy of the library.
@MainActor
final class AppEnvironment: ObservableObject {

    // MARK: Configuration

    let secrets: SecretsVault
    let store: SeismicStore
    let session: NodeSession

    /// The networked half of the app. Separate because everything in it
    /// degrades independently: the app has to work with all of it switched off.
    let services: ServiceHub

    /// Empties the sync queue whenever there is an account, a network and
    /// something to send.
    let sync: SyncEngine
    let voice: VoiceController
    /// The Lock Screen and the home-screen widget.
    let live = LiveActivityController()

    /// Measures the building on its own, overnight, so the temperature
    /// regression fills in without anybody pressing anything.
    let baseline = BaselineScheduler()

    /// The neighbouring buildings, per building, for the simulator's street.
    let block = BlockContext()

    /// The Arduino node: the radio, the protocol, and everything it has said.
    ///
    /// Owned here rather than by a screen because two screens read it — the
    /// hardware controls and the sensor channels — and a link that reconnected
    /// every time one of them appeared would drop the demonstration at exactly
    /// the wrong moment.
    let link = SeismicNodeLink()

    /// The automatic call to emergency services, which never dials anything.
    /// See `EmergencyCallController` for why.
    let emergencyCall = EmergencyCallController()

    /// How many credentials were found in `.env` at first launch. Surfaced once,
    /// in Settings, and never as a prompt — the app owes the user a working
    /// experience whether or not they ever add a key.
    @Published private(set) var secretsLoadedFromEnv = 0
    @Published private(set) var isBootstrapped = false
    @Published private(set) var bootstrapStage = "Starting"

    // MARK: Live state

    @Published private(set) var buildings: [BuildingModel] = []
    @Published private(set) var events: [SeismicEvent] = []
    @Published private(set) var assessments: [Assessment] = []
    @Published private(set) var earthquakes: [EarthquakeRecord] = []
    @Published private(set) var tags: [CommunityTag] = []
    @Published private(set) var observations: [ModeObservation] = []

    @Published var selectedBuildingID: UUID?

    /// A screen something has asked to be shown, cleared once the request has
    /// been honoured.
    ///
    /// Navigation lives in `RootView`, which owns the tab selection — but the
    /// things that want to navigate are often several levels down inside a
    /// sheet, with no path back up to it. The Library's "Simulate" button was
    /// exactly this: it selected the building, dismissed its own sheet, and
    /// left the user looking at the Library wondering what had happened.
    /// Routing the request through the one object every screen already has is
    /// simpler than threading a callback through each of them.
    @Published var requestedSection: AppSection?

    /// Live motion data, deliberately on its own object rather than published
    /// here. See `NodeStream` — publishing a 20 Hz stream from this object was
    /// re-rendering every screen in the app twenty times a second.
    let node = NodeStream()

    /// Set while an event is actually happening. Everything else in the UI gets
    /// out of the way when this is non-nil.
    @Published var activeEvent: ActiveEvent?

    @Published var didCompleteOnboarding: Bool {
        didSet { UserDefaults.standard.set(didCompleteOnboarding, forKey: "didCompleteOnboarding") }
    }

    @Published var isPresentationMode = false

    /// Which presentation to run when `isPresentationMode` turns on.
    ///
    /// Separate from the flag so both entry points — the toolbar toggle and the
    /// full showcase button — drive the same single switch rather than each
    /// owning a running director.
    @Published var presentationMode: PresentationDirector.Mode = .brief

    /// An event in progress, driving the full-screen takeover.
    struct ActiveEvent: Equatable {
        var id = UUID()
        var startedAt: Date
        var triggerRatio: Double
        var estimatedMagnitude: Double?
        var secondsUntilStrongShaking: Double?
        var expectedIntensity: MercalliIntensity?
        var isDrill: Bool
        var userAcknowledged = false
        var actuators: [ActuatorKind: ActuatorReport] = [:]

        /// Seconds still to go, now.
        ///
        /// `secondsUntilStrongShaking` is the estimate made when the P wave
        /// arrived and never changes; this is what is left of it. The takeover
        /// screen derives the same thing from `startedAt`, and the Lock Screen
        /// needs it too — handing it the original total is how a Live Activity
        /// ends up showing a countdown frozen at nine seconds for the whole
        /// event.
        var secondsRemaining: Double? {
            guard let total = secondsUntilStrongShaking else { return nil }
            return max(total - Date().timeIntervalSince(startedAt), 0)
        }

        var hasShakingArrived: Bool {
            guard let remaining = secondsRemaining else { return true }
            return remaining <= 0
        }
    }

    /// When the Lock Screen was last told anything.
    ///
    /// The tick runs at 20 Hz; a Live Activity updated 20 times a second is
    /// throttled by the system and burns battery for nothing. Once a second is
    /// as fast as a countdown in whole seconds can usefully change.
    private var lastLiveActivityUpdate = Date.distantPast

    private var timer: AnyCancellable?
    private var simulatedNode: SimulatedNode?
    private var phoneSensor: PhoneSensorTransport?
    /// The real board, when one is in use. Held so the whole app's data comes
    /// from it and not only the Hardware screen.
    private var hardwareTransport: FirmwareNodeTransport?

    /// Where the motion on screen is coming from.
    ///
    /// Three sources, and the app is honest about the order: a wired node is
    /// the best of them, this phone is a real but weaker substitute, and the
    /// simulator is neither. Published so a screen can say which one it is
    /// looking at without interrogating the transport.
    enum SensorSource: String, CaseIterable, Identifiable, Sendable {
        case node, phone, simulated
        var id: String { rawValue }

        var title: String {
            switch self {
            case .node: "Seismic node"
            case .phone: "This phone"
            case .simulated: "Simulator"
            }
        }

        var systemImage: String {
            switch self {
            case .node: "sensor.tag.radiowaves.forward"
            case .phone: "iphone.gen3.radiowaves.left.and.right"
            case .simulated: "cpu"
            }
        }

        /// One line, and it has to be the true one. This is the whole basis on
        /// which somebody decides whether to trust what follows.
        var accuracyNote: String {
            switch self {
            case .node:
                "Bolted to the structure, with a thermometer against the concrete and "
                + "actuators wired in. The only source that can apply the temperature "
                + "correction or close your gas valve."
            case .phone:
                "Real measured motion, but resting on furniture rather than fixed to the "
                + "structure, and with no thermometer — so period changes keep the "
                + "seasonal effect in them. Good enough to detect and to warn."
            case .simulated:
                "Physically realistic synthetic data. Nothing here was measured."
            }
        }
    }

    @Published private(set) var sensorSource: SensorSource = .simulated

    /// The display tick. Named because the countdown haptic compares against
    /// the previous tick and needs to know how long ago that was.
    private let tickInterval = 1.0 / 20.0

    // MARK: Construction

    init(secrets: SecretsVault, store: SeismicStore, session: NodeSession) {
        self.secrets = secrets
        self.store = store
        self.session = session
        // `.env` is read before the hub is built so a key found there is
        // already in the vault by the time any client asks for it.
        self.secretsLoadedFromEnv = secrets.bootstrapFromEnvFile(at: Self.bundledEnvFileURL)
        let hub = ServiceHub(vault: secrets, localLibrary: store.buildingsList())
        self.services = hub
        self.voice = VoiceController(speech: hub.speech)
        self.sync = SyncEngine(store: store, cloud: hub.cloud) { [weak hub] in hub?.account }
        self.didCompleteOnboarding = UserDefaults.standard.bool(forKey: "didCompleteOnboarding")
        wireNode()
    }

    /// Connects the node's own account of itself to the rest of the app.
    ///
    /// The link deliberately knows nothing about speech or about events; these
    /// two closures are the whole of its outward coupling. Set up in `init` so
    /// they are in place before the first line ever arrives — a node that
    /// declares an earthquake during launch is not a hypothetical, it is what
    /// happens when the app is opened after the board has already been shaking.
    private func wireNode() {
        link.onSpokenLine = { [weak self] sentence in
            self?.voice.speak(sentence, urgency: .normal)
        }
        link.onDeclaredEvent = { [weak self] isDrill in
            self?.nodeDeclaredEvent(isDrill: isDrill)
        }
    }

    static func live() -> AppEnvironment {
        #if canImport(Security)
        let storage: SecretStorage = KeychainSecretStorage()
        #else
        let storage: SecretStorage = InMemorySecretStorage()
        #endif
        return AppEnvironment(secrets: SecretsVault(storage: storage),
                              store: SeismicStore(),
                              session: NodeSession())
    }

    /// An environment with nothing persistent behind it, for previews and tests.
    static func preview() -> AppEnvironment {
        let environment = AppEnvironment(secrets: SecretsVault(storage: InMemorySecretStorage()),
                                         store: SeismicStore.ephemeral(),
                                         session: NodeSession())
        environment.reloadFromStore(environment.store.load())
        environment.isBootstrapped = true
        return environment
    }

    // MARK: Launch

    /// Never blocks on a network call, never prompts, never fails. If every
    /// single step went wrong the app would still open onto a working library.
    func bootstrap() async {
        guard !isBootstrapped else { return }

        bootstrapStage = "Reading configuration"
        services.refreshKeyStatuses()

        bootstrapStage = "Loading your library"
        let snapshot = store.load()
        reloadFromStore(snapshot)
        selectedBuildingID = buildings.first(where: \.isSandbox)?.id ?? buildings.first?.id

        // Opens on a named building, for a screenshot run or a UI test — the
        // same idea as SEISMIC_INITIAL_TAB, and the thing that makes it
        // possible to check a render against a photograph of the real building
        // without a person tapping through the picker each time. Matched
        // loosely so "transamerica" finds the pyramid.
        if let wanted = ProcessInfo.processInfo.environment["SEISMIC_INITIAL_BUILDING"]?
            .lowercased(), !wanted.isEmpty,
           let match = buildings.first(where: { $0.name.lowercased().contains(wanted) }) {
            selectedBuildingID = match.id
        }

        bootstrapStage = "Starting the node"
        attachSimulatedNode()

        bootstrapStage = "Ready"
        isBootstrapped = true
        publishWidgetState()

        // Everything after this point is optional and happens off the launch
        // path, so a slow network can never delay the first frame.
        Task { await services.refreshFeed() }
        Task { await services.speech.prewarmEmergencyLines() }
    }

    private func reloadFromStore(_ snapshot: SeismicStore.Snapshot) {
        buildings = snapshot.buildings
        events = snapshot.events
        assessments = snapshot.assessments
        earthquakes = snapshot.earthquakes
        tags = snapshot.tags
        observations = snapshot.observations
    }

    func refresh() {
        reloadFromStore(store.snapshot())
    }

    /// Puts the bundled example library back.
    ///
    /// Deleting everything is honest — it really does remove the lot — but an
    /// app with no buildings in it has nothing to show and no obvious way
    /// forward. This is the way back, offered wherever that emptiness is
    /// visible rather than hidden in Settings.
    func restoreSeedLibrary() {
        store.seed()
        refresh()
        selectedBuildingID = buildings.first(where: \.isSandbox)?.id ?? buildings.first?.id
        attachSimulatedNode()
        publishWidgetState()
        Haptics.shared.play(.assessmentComplete)
    }

    // MARK: Leaving

    /// What a sign-out or a deletion actually did.
    struct AccountExitReport: Equatable {
        var signedOut = false
        var localDocumentsRemoved = 0
        var localRecordingsRemoved = 0
        var cloudTablesCleared: [String] = []
        var identityRemovedFromServer = false
        /// Everything that did not work, in words, ready to be shown.
        var problems: [String] = []

        var isComplete: Bool { problems.isEmpty }
    }

    /// Signs out and leaves the data on the device.
    ///
    /// Deliberately two separate operations, because they are two separate
    /// decisions and conflating them is how somebody loses a year of
    /// measurements by tapping the wrong one. Signing out ends the session; the
    /// buildings, events and assessments stay exactly where they are and are
    /// there again at the next sign-in. The UI says so before the tap, not
    /// after.
    @discardableResult
    func signOut() async -> AccountExitReport {
        var report = AccountExitReport()
        await services.signOut()
        report.signedOut = true
        // The link and any live event belong to the session that just ended.
        emergencyCall.dismiss()
        activeEvent = nil
        return report
    }

    /// Deletes the account on the server and erases this device.
    ///
    /// Order matters and is not interchangeable: the rows go first, then the
    /// identity, then the device. Deleting the identity first revokes the token
    /// that authorises the row deletions, which would leave the user's data on
    /// the server for ever with nobody able to reach it — the exact opposite of
    /// what they asked for. And the device is erased last so that a server-side
    /// failure still leaves something to retry from.
    ///
    /// Nothing here is claimed on faith. Every step reports what it did, and a
    /// step that failed is named in the result rather than swallowed, because
    /// "your account has been deleted" over data that is still on a server is
    /// the worst sentence this app could print.
    func deleteAccount() async -> AccountExitReport {
        var report = AccountExitReport()

        if let outcome = await services.deleteCloudAccount() {
            report.cloudTablesCleared = outcome.clearedTables
            report.identityRemovedFromServer = outcome.identityRemoved
            for (table, reason) in outcome.failures.sorted(by: { $0.key < $1.key }) {
                report.problems.append("\(table) could not be deleted from the server: \(reason)")
            }
            if let reason = outcome.identityFailure {
                report.problems.append("Your sign-in could not be removed from the server: "
                                       + "\(reason)")
            }
        }

        let erased = store.eraseEverything()
        report.localDocumentsRemoved = erased.documentsRemoved.count
        report.localRecordingsRemoved = erased.recordingsRemoved
        for (file, reason) in erased.failures.sorted(by: { $0.key < $1.key }) {
            report.problems.append("\(file) could not be removed from this device: \(reason)")
        }

        services.forgetIdentity()
        report.signedOut = true

        // Back to a launch-shaped state rather than a half-empty one. Every
        // published list is cleared explicitly: leaving them populated would
        // show the deleted buildings until the next launch.
        emergencyCall.dismiss()
        activeEvent = nil
        buildings = []; events = []; assessments = []
        earthquakes = []; tags = []; observations = []
        selectedBuildingID = nil
        didCompleteOnboarding = false
        UserDefaults.standard.removeObject(forKey: "didCompleteOnboarding")
        publishWidgetState()

        return report
    }

    /// `.env` is read from the app bundle if it was copied in at build time, and
    /// otherwise from the documents directory, which is where a developer can
    /// drop one onto a device without rebuilding.
    static var bundledEnvFileURL: URL? {
        let manager = FileManager.default

        // Copied in by a debug-only build phase from the repository root.
        // `Bundle.url(forResource:)` is unreliable for a name that begins with
        // a dot, so the bundle directory is searched directly.
        let bundled = Bundle.main.bundleURL.appendingPathComponent(".env")
        if manager.fileExists(atPath: bundled.path) { return bundled }
        if let named = Bundle.main.url(forResource: "env", withExtension: nil) { return named }

        // And the documents directory, which is how a `.env` gets onto a real
        // device — through the Files app — without rebuilding.
        if let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let candidate = documents.appendingPathComponent(".env")
            if manager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: Node

    /// Connects the simulated node.
    ///
    /// This happens automatically at launch and is not a fallback or a debug
    /// mode: the product is specified to be fully demonstrable with no hardware,
    /// so the simulated node is a first-class citizen that happens to also be
    /// what most users will see first.
    func attachSimulatedNode() {
        let building = selectedBuilding ?? store.buildingsList().first
        let node = SimulatedNode(configuration: .init(
            buildingPeriod: building?.empiricalPeriod ?? 0.85,
            buildingDamping: building?.damping ?? 0.045,
            sampleRate: 100))
        releaseTransports()
        simulatedNode = node
        sensorSource = .simulated
        wire(node)
        node.startScanning()
        node.connect(to: node.identifier)
        startTicking()
    }

    /// Uses the phone's own accelerometer.
    ///
    /// The fallback when there is no hardware, and the thing that makes the
    /// crowd version of this app possible: a street with forty phones in it has
    /// forty sensors. It goes through the same `NodeTransport` seam the node
    /// and the simulator use, so the monitor, the detector, the recorder and
    /// the assessment did not need a line changing to accept it.
    func attachPhoneSensor() {
        guard PhoneSensorTransport.isAvailable else {
            appendLog("This device has no motion sensor available, so it cannot be used "
                      + "as one. Staying on the current source.")
            return
        }
        let transport = PhoneSensorTransport()
        releaseTransports()
        phoneSensor = transport
        sensorSource = .phone
        node.reset()
        wire(transport)
        transport.startScanning()
        transport.connect(to: transport.identifier)
        startTicking()
        publishWidgetState()
    }

    #if canImport(CoreBluetooth)
    /// Switches to real hardware and starts looking for it.
    ///
    /// Goes through `SeismicNodeLink`, which speaks the protocol `arduino.ino`
    /// actually emits. The older `BluetoothTransport` speaks `NodeProtocol` —
    /// binary, framed, checksummed — which the firmware does not send a single
    /// byte of, so it would have connected and then parsed nothing for ever.
    /// Nothing attached it in the first place, which is why the sensor picker
    /// only ever listed the simulated node.
    ///
    /// The rest of the app is unaffected: it talks to `NodeSession`, which
    /// cannot tell what is underneath it.
    func attachHardwareNode() {
        stopTicking()
        releaseTransports()
        sensorSource = .node
        node.reset()
        let transport = FirmwareNodeTransport(link: link)
        hardwareTransport = transport
        wire(transport)
        transport.startScanning()
        startTicking()
    }

    /// Connects to a device the scan turned up, and remembers it.
    func connectToHardwareNode(_ id: UUID) {
        if hardwareTransport == nil { attachHardwareNode() }
        hardwareTransport?.connect(to: id.uuidString)
    }

    var isUsingHardwareNode: Bool { hardwareTransport != nil }
    #endif

    /// Lets go of whichever transport was in use.
    ///
    /// The phone one has to be told explicitly: CoreMotion updates keep running
    /// against a released object's queue otherwise, and the accelerometer stays
    /// powered for the rest of the session.
    private func releaseTransports() {
        phoneSensor?.disconnect()
        phoneSensor = nil
        simulatedNode = nil
        // Not disconnected: swapping the app's *source* away from the node is
        // not a reason to drop a radio link that the Hardware screen may still
        // be driving. Only released, so nothing further is forwarded.
        hardwareTransport = nil
    }

    private func wire(_ transport: NodeTransport) {
        session.attach(transport)

        session.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        session.onTriggered = { [weak self] ratio, at in
            Task { @MainActor in self?.beginActiveEvent(ratio: ratio, at: at) }
        }
        session.onRecordingComplete = { [weak self] eventID, result in
            Task { @MainActor in self?.completeRecording(eventID: eventID, result: result) }
        }
    }

    private func handle(_ event: NodeEvent) {
        switch event {
        case .discovered(let node):
            self.node.record(node)

        case .connectionChanged(let state):
            Haptics.shared.play(state.isLive ? .connectionEstablished : .connectionLost)
            appendLog(state.label)

        case .actuatorReport(let report):
            if activeEvent != nil { activeEvent?.actuators[report.kind] = report }
            switch report.state {
            case .inProgress: Haptics.shared.play(.actuatorFired)
            case .confirmed: Haptics.shared.play(.actuatorConfirmed)
            case .failed: Haptics.shared.play(.actuatorFailed)
            default: break
            }

        case .fault(let fault):
            appendLog("Fault: \(fault.label)")
            Haptics.shared.play(.warning)

        case .selfTestResult(let result):
            node.recordSelfTest(result)

        case .log(let message):
            appendLog(message)

        case .telemetry, .highRate, .triggered, .sensorVote,
             .recordingManifest, .recordingChunk, .periodMeasured, .rfidTap:
            break
        }

        node.update(session.snapshot())
    }

    private func appendLog(_ text: String) { node.append(text) }

    /// A display-linked tick drives the simulated node, so its data arrives in
    /// step with the animation rather than on an unrelated timer.
    private func startTicking() {
        stopTicking()
        timer = Timer.publish(every: tickInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                simulatedNode?.tick(deltaTime: tickInterval)
                phoneSensor?.tick(deltaTime: tickInterval)
                node.update(session.snapshot())
                updateActiveEvent()
                // Rate-limits itself hard — a minute between even considering
                // it — so this costs a date comparison twenty times a second.
                baseline.consider(environment: self)
            }
    }

    private func stopTicking() {
        timer?.cancel()
        timer = nil
    }

    // MARK: The node declaring an event

    /// The board decided, and the phone acts on it.
    ///
    /// Two things follow from the node's declaration that do not follow from
    /// the phone's own detector: the takeover appears even if the phone felt
    /// nothing (it may be on a desk in the next building), and the automatic
    /// call to emergency services is placed. The node has the better claim —
    /// three sensors bolted to the structure against one phone that might be in
    /// a pocket — so it is allowed to raise the event on its own.
    private func nodeDeclaredEvent(isDrill: Bool) {
        if activeEvent == nil {
            let trigger = link.lastTrigger?.ratio ?? 0
            activeEvent = ActiveEvent(startedAt: Date(), triggerRatio: trigger,
                                      estimatedMagnitude: nil,
                                      secondsUntilStrongShaking: 5,
                                      expectedIntensity: nil,
                                      isDrill: isDrill)
            Haptics.shared.startCountdown(seconds: 5)
            live.start(buildingName: selectedBuilding?.name ?? "Your building",
                       secondsUntilShaking: 5, magnitude: nil, intensity: nil, isDrill: isDrill)
        }
        placeEmergencyCall()
    }

    /// Places the (simulated) call to emergency services.
    ///
    /// Deliberately not gated on it being a drill. A drill that skipped the
    /// call would be a drill that never rehearsed the part most likely to go
    /// wrong — and since nothing is ever dialled, there is no cost to running
    /// it every time. The banner on the screen is what keeps that honest.
    func placeEmergencyCall() {
        guard let event = activeEvent, !emergencyCall.isActive else { return }
        emergencyCall.onSpeak = { [weak self] sentence in
            self?.voice.speak(sentence, urgency: .emergency, force: true)
        }
        let members = services.household?.members.count
        let report = EmergencyCallController.report(for: event,
                                                    building: selectedBuilding,
                                                    occupied: link.telemetry?.isOccupied,
                                                    householdSize: members)
        emergencyCall.place(report: report)
    }

    // MARK: Events

    private func beginActiveEvent(ratio: Double, at: Date) {
        guard activeEvent == nil else { return }
        Haptics.shared.play(.eventTriggered)

        // The warning is issued from the P-wave alone, before the damaging wave
        // arrives. The numbers are estimates and the UI says so.
        let record = session.bufferedRecord()
        var magnitude: Double?
        var seconds: Double?
        var intensity: MercalliIntensity?

        if let pick = ArrivalPicker.pickP(record.z),
           let estimate = EarlyMagnitude.estimate(record.z, pArrival: pick.time) {
            magnitude = estimate.magnitude
            // Without a distance yet, assume a nominal one and widen later.
            let assumedDistance = 30.0
            seconds = AttenuationModel.warningTime(distanceKm: assumedDistance)
            intensity = AttenuationModel.predict(magnitude: estimate.magnitude,
                                                 distanceKm: assumedDistance).mercalli
        }

        activeEvent = ActiveEvent(startedAt: at, triggerRatio: ratio,
                                  estimatedMagnitude: magnitude,
                                  secondsUntilStrongShaking: seconds,
                                  expectedIntensity: intensity,
                                  isDrill: false)

        // Handed over in one piece, now, while the app is definitely running.
        // Everything after this the user can feel with the phone in a pocket
        // and the screen dark.
        Haptics.shared.startCountdown(seconds: seconds ?? 0)

        live.start(buildingName: selectedBuilding?.name ?? "Your building",
                   secondsUntilShaking: seconds, magnitude: magnitude,
                   intensity: intensity, isDrill: false)

        // Spoken immediately, and deliberately not routed through the analyst:
        // this sentence is fixed, pre-rendered and available offline, because
        // it is the one sentence that must never wait for anything.
        if let seconds, seconds > 2 {
            voice.announceEmergency("Earthquake detected. Strong shaking expected in "
                                    + "\(Int(seconds.rounded())) seconds. "
                                    + "Drop, cover and hold on.")
        } else {
            voice.announceEmergency("Earthquake detected. Drop, cover and hold on.")
        }

        // And the call, a beat later — the warning has to be heard first, and
        // an automated report read over the top of "drop, cover and hold on" is
        // two voices saying different things at the worst possible moment.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            self?.placeEmergencyCall()
        }
    }

    private func updateActiveEvent() {
        guard let event = activeEvent else { return }

        // The countdown haptic is no longer driven from here. The whole
        // sequence is handed to the haptic engine the moment the event begins,
        // because this tick is a main-thread timer: it stops the instant the
        // screen locks, which is exactly when the phone is in a pocket and the
        // taps are the only channel left. See `Haptics.startCountdown`.

        // The takeover clears itself once the shaking is over and the user has
        // acknowledged, so nobody is left staring at a stale warning.
        if event.userAcknowledged,
           Date().timeIntervalSince(event.startedAt) > 45 {
            activeEvent = nil
            live.end()
            return
        }

        // Re-published so any view reading `secondsRemaining` re-evaluates.
        activeEvent = event

        guard Date().timeIntervalSince(lastLiveActivityUpdate) >= 1 else { return }
        lastLiveActivityUpdate = Date()

        let confirmed = event.actuators.values.filter { $0.state == .confirmed }.count
        live.update(stage: event.hasShakingArrived ? .shaking : .warning,
                    secondsUntilShaking: event.secondsRemaining,
                    magnitude: event.estimatedMagnitude,
                    intensity: event.expectedIntensity,
                    verdict: nil,
                    actuatorsFired: event.actuators.count,
                    actuatorsConfirmed: confirmed,
                    isDrill: event.isDrill)
    }

    func acknowledgeActiveEvent() {
        activeEvent?.userAcknowledged = true
        // Somebody who has said they are safe does not need to be tapped at for
        // another nine seconds.
        Haptics.shared.stopCountdown()
        Haptics.shared.play(.selection)
    }

    func dismissActiveEvent() {
        activeEvent = nil
        Haptics.shared.stopCountdown()
        live.end()
    }

    /// Pushes the current state out to the home-screen widget.
    ///
    /// Called at launch and after anything that changes what the widget shows,
    /// so a glance at the Home Screen is never looking at last week's verdict.
    func publishWidgetState() {
        live.publish(building: selectedBuilding,
                     assessment: latestAssessment,
                     isConnected: connectionState.isLive,
                     isSimulated: isUsingSimulatedData,
                     lastEventAt: selectedBuilding
                        .flatMap { building in
                            events.first { $0.buildingID == building.id }?.startTime
                        })
    }

    /// Runs the warning sequence without firing anything — the drill.
    func startDrill(fireActuators: Bool) {
        activeEvent = ActiveEvent(startedAt: Date(), triggerRatio: 6.2,
                                  estimatedMagnitude: 6.1,
                                  secondsUntilStrongShaking: 9,
                                  expectedIntensity: .strong,
                                  isDrill: true)
        session.send(.drill(fireActuators: fireActuators))
        Haptics.shared.startCountdown(seconds: 9)
        live.start(buildingName: selectedBuilding?.name ?? "Your building",
                   secondsUntilShaking: 9, magnitude: 6.1,
                   intensity: .strong, isDrill: true)
        Haptics.shared.play(.eventTriggered)
    }

    /// The countdown on its own, with nothing on screen.
    ///
    /// Rehearsal, and the reason the pattern is worth having at all: a haptic
    /// language nobody has ever felt is not a language. This runs it with the
    /// phone face down on a table, which is how it will actually arrive.
    func rehearseCountdown(seconds: Double = 9) {
        Haptics.shared.startCountdown(seconds: seconds)
    }

    /// Injects a simulated earthquake — the demo affordance, available from the
    /// node screen and from presentation mode.
    func simulateEarthquake(magnitude: Double = 6.4, distanceKm: Double = 22) {
        simulatedNode?.injectSyntheticEvent(magnitude: magnitude, distanceKm: distanceKm)
        appendLog("Injecting a simulated magnitude "
                  + String(format: "%.1f", magnitude) + " at \(Int(distanceKm)) km.")
    }

    func introduceSimulatedDamage() {
        simulatedNode?.introduceSimulatedDamage()
        appendLog("Simulated damage introduced. Re-measure to see the assessment change.")
    }

    func simulateConnectionLoss() { simulatedNode?.simulateConnectionLoss() }
    func restoreConnection() { simulatedNode?.restoreConnection() }

    private func completeRecording(eventID: UUID, result: ChunkReassembler.Result) {
        appendLog(result.summary)
        guard let record = result.record else { return }

        var event = SeismicEvent(
            id: eventID,
            buildingID: selectedBuildingID,
            nodeID: session.attachedTransport?.identifier,
            startTime: record.startTime,
            triggerRatio: activeEvent?.triggerRatio ?? 0,
            record: record,
            isComplete: result.isComplete,
            missingChunks: result.missingChunks,
            isSimulated: session.attachedTransport?.isSimulated ?? true,
            label: "Recorded event")

        if let telemetry = node.snapshot?.telemetry {
            event.residualDisplacement = telemetry.residualDisplacement
            event.permanentTilt = telemetry.permanentTilt
            event.tiltAngle = telemetry.tiltAngle
            event.structureTemperature = telemetry.structureTemperature
            event.gridPowerLost = !telemetry.gridPowerPresent
            event.waterDetected = telemetry.waterDetected
        }
        event.actuatorReports = Array((node.snapshot?.actuators ?? [:]).values)
        event.votes = node.snapshot?.votes ?? []

        store.upsert(event)
        refresh()

        // An assessment is produced automatically: the user should not have to
        // ask whether their building is safe.
        if let building = selectedBuilding {
            let assessment = AssessmentEngine.assess(building: building, event: event,
                                                     history: observations,
                                                     store: store)
            store.upsert(assessment)
            refresh()
            Haptics.shared.play(.assessmentComplete)
            Haptics.shared.play(assessment.verdict == .green ? .verdictGreen
                                : (assessment.verdict == .red ? .verdictRed : .verdictAmber))

            voice.speak(assessment.verdict.plainMeaning, urgency: .calm)
            live.finish(verdict: assessment.verdict, buildingName: building.name)
            publishWidgetState()
            Task { await services.narrative(for: assessment, building: building) }
        }
    }

    // MARK: Derived

    var selectedBuilding: BuildingModel? {
        guard let selectedBuildingID else { return buildings.first }
        return buildings.first { $0.id == selectedBuildingID } ?? buildings.first
    }

    var latestAssessment: Assessment? {
        guard let id = selectedBuilding?.id else { return nil }
        return assessments.first { $0.buildingID == id }
    }

    func assessment(for buildingID: UUID) -> Assessment? {
        assessments.first { $0.buildingID == buildingID }
    }

    func events(for buildingID: UUID) -> [SeismicEvent] {
        events.filter { $0.buildingID == buildingID }
    }

    var connectionState: ConnectionState {
        node.snapshot?.connection ?? .disconnected
    }

    var isUsingSimulatedData: Bool {
        node.snapshot?.isSimulated ?? true
    }

    /// The count of configured API keys, for the settings summary.
    var configuredKeyCount: Int { secrets.configuredCount }
}
