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
    let voice: VoiceController
    /// The Lock Screen and the home-screen widget.
    let live = LiveActivityController()

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
    @Published private(set) var nodeSnapshot: NodeSession.Snapshot?
    @Published private(set) var nodeLog: [LogLine] = []
    @Published private(set) var discoveredNodes: [DiscoveredNode] = []
    @Published private(set) var lastSelfTest: SelfTestResult?

    /// Set while an event is actually happening. Everything else in the UI gets
    /// out of the way when this is non-nil.
    @Published var activeEvent: ActiveEvent?

    @Published var didCompleteOnboarding: Bool {
        didSet { UserDefaults.standard.set(didCompleteOnboarding, forKey: "didCompleteOnboarding") }
    }

    @Published var isPresentationMode = false

    struct LogLine: Identifiable {
        let id = UUID()
        let text: String
        let at: Date
    }

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
        self.didCompleteOnboarding = UserDefaults.standard.bool(forKey: "didCompleteOnboarding")
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
        simulatedNode = node
        wire(node)
        node.startScanning()
        node.connect(to: node.identifier)
        startTicking()
    }

    #if canImport(CoreBluetooth)
    /// Switches to real hardware. The rest of the app is unaffected — it talks
    /// to `NodeSession`, which cannot tell the difference.
    func attachBluetoothTransport() {
        stopTicking()
        simulatedNode = nil
        let transport = BluetoothTransport()
        wire(transport)
        transport.startScanning()
    }
    #endif

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
            discoveredNodes.removeAll { $0.id == node.id }
            discoveredNodes.append(node)

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
            lastSelfTest = result

        case .log(let message):
            appendLog(message)

        case .telemetry, .highRate, .triggered, .sensorVote,
             .recordingManifest, .recordingChunk, .periodMeasured, .rfidTap:
            break
        }

        nodeSnapshot = session.snapshot()
    }

    private func appendLog(_ text: String) {
        nodeLog.insert(LogLine(text: text, at: Date()), at: 0)
        if nodeLog.count > 200 { nodeLog.removeLast(nodeLog.count - 200) }
    }

    /// A display-linked tick drives the simulated node, so its data arrives in
    /// step with the animation rather than on an unrelated timer.
    private func startTicking() {
        stopTicking()
        timer = Timer.publish(every: tickInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                simulatedNode?.tick(deltaTime: tickInterval)
                nodeSnapshot = session.snapshot()
                updateActiveEvent()
            }
    }

    private func stopTicking() {
        timer?.cancel()
        timer = nil
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
    }

    private func updateActiveEvent() {
        guard let event = activeEvent else { return }

        // One haptic per whole second of the countdown, escalating as it runs
        // out. The comparison is against the previous tick's whole second, so
        // it fires exactly once per boundary rather than on every tick.
        if let remaining = event.secondsRemaining {
            let previous = remaining + tickInterval
            if Int(remaining) != Int(previous) {
                Haptics.shared.play(.countdownTick(secondsRemaining: Int(remaining)))
            }
        }

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
        Haptics.shared.play(.selection)
    }

    func dismissActiveEvent() {
        activeEvent = nil
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
                     lastEventAt: events.first?.startTime)
    }

    /// Runs the warning sequence without firing anything — the drill.
    func startDrill(fireActuators: Bool) {
        activeEvent = ActiveEvent(startedAt: Date(), triggerRatio: 6.2,
                                  estimatedMagnitude: 6.1,
                                  secondsUntilStrongShaking: 9,
                                  expectedIntensity: .strong,
                                  isDrill: true)
        session.send(.drill(fireActuators: fireActuators))
        live.start(buildingName: selectedBuilding?.name ?? "Your building",
                   secondsUntilShaking: 9, magnitude: 6.1,
                   intensity: .strong, isDrill: true)
        Haptics.shared.play(.eventTriggered)
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

        if let telemetry = nodeSnapshot?.telemetry {
            event.residualDisplacement = telemetry.residualDisplacement
            event.permanentTilt = telemetry.permanentTilt
            event.tiltAngle = telemetry.tiltAngle
            event.structureTemperature = telemetry.structureTemperature
            event.gridPowerLost = !telemetry.gridPowerPresent
            event.waterDetected = telemetry.waterDetected
        }
        event.actuatorReports = Array((nodeSnapshot?.actuators ?? [:]).values)
        event.votes = nodeSnapshot?.votes ?? []

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
        nodeSnapshot?.connection ?? .disconnected
    }

    var isUsingSimulatedData: Bool {
        nodeSnapshot?.isSimulated ?? true
    }

    /// The count of configured API keys, for the settings summary.
    var configuredKeyCount: Int { secrets.configuredCount }
}
