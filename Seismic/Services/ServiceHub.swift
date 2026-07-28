import Foundation
import SwiftUI
import Combine
import SeismicCore
import SeismicData
import SeismicServices

/// The networked half of the app, in one observable place.
///
/// Everything here degrades. Each property that names a provider is really
/// answering the question "is this live or is this the fallback?", and every
/// screen that uses one shows that answer. There is no state in which a feature
/// simply disappears because a key is missing.
@MainActor
final class ServiceHub: ObservableObject {

    let analyst: AIAnalyst
    let speech: SpeechService
    let search: BuildingSearchService
    let cloud: CloudService
    let feed: EarthquakeFeedService
    let temperature: TemperatureService
    let escalation: EscalationService
    let keyTester: KeyTester

    private let vault: SecretsVault

    // MARK: Published state

    @Published private(set) var liveEarthquakes: [EarthquakeRecord] = []
    @Published private(set) var feedOrigin: ResultOrigin = .seeded
    @Published private(set) var feedNote: String?
    @Published private(set) var isRefreshingFeed = false

    @Published private(set) var keyStatuses: [SecretKey: KeyStatus] = [:]
    @Published private(set) var testingKeys: Set<SecretKey> = []

    @Published var account: UserAccount?
    @Published var household: Household?

    /// Narratives, keyed by assessment. Generated once and then cached, so
    /// re-opening the assessment screen does not re-spend a token budget.
    @Published private(set) var narratives: [UUID: Sourced<AnalystAnswer>] = [:]
    @Published private(set) var generatingNarratives: Set<UUID> = []

    init(vault: SecretsVault, localLibrary: [BuildingModel]) {
        self.vault = vault
        self.analyst = AIAnalyst(vault: vault)
        self.speech = SpeechService(vault: vault)
        self.search = BuildingSearchService(vault: vault, localLibrary: localLibrary)
        self.cloud = CloudService(vault: vault)
        self.feed = EarthquakeFeedService()
        self.temperature = TemperatureService(vault: vault)
        self.escalation = EscalationService(vault: vault)
        self.keyTester = KeyTester(vault: vault)
        refreshKeyStatuses()
        restoreIdentity()
    }

    // MARK: Keys

    func refreshKeyStatuses() {
        var statuses: [SecretKey: KeyStatus] = [:]
        for key in SecretKey.allCases { statuses[key] = vault.status(for: key) }
        keyStatuses = statuses
    }

    func status(for key: SecretKey) -> KeyStatus { keyStatuses[key] ?? .missing }

    func setKey(_ key: SecretKey, to value: String?) {
        vault.set(key, to: value?.trimmingCharacters(in: .whitespacesAndNewlines))
        refreshKeyStatuses()
    }

    func fingerprint(for key: SecretKey) -> String { vault.fingerprint(for: key) }

    func test(_ key: SecretKey) async {
        testingKeys.insert(key)
        _ = await keyTester.test(key)
        testingKeys.remove(key)
        refreshKeyStatuses()
    }

    /// The count of keys that have actually been exercised, as opposed to
    /// merely stored. Settings distinguishes the two because "present" and
    /// "working" are very different things at three in the morning.
    var verifiedKeyCount: Int {
        keyStatuses.values.filter { if case .valid = $0 { return true } else { return false } }.count
    }

    // MARK: Feed

    func refreshFeed(_ window: EarthquakeFeedService.Window = .pastDay) async {
        isRefreshingFeed = true
        let result = await feed.recent(window)
        liveEarthquakes = result.value
        feedOrigin = result.origin
        feedNote = result.note
        isRefreshingFeed = false
    }

    // MARK: Narrative

    /// Produces the paragraph under a verdict.
    ///
    /// The verdict itself is computed before this is ever called and is passed
    /// in as a constraint — the analyst explains, it does not decide.
    func narrative(for assessment: Assessment, building: BuildingModel) async {
        guard narratives[assessment.id] == nil,
              !generatingNarratives.contains(assessment.id) else { return }
        generatingNarratives.insert(assessment.id)
        let answer = await analyst.answer(.narrative(for: assessment, building: building))
        narratives[assessment.id] = answer
        generatingNarratives.remove(assessment.id)
    }

    func narrative(for assessmentID: UUID) -> Sourced<AnalystAnswer>? { narratives[assessmentID] }

    func summary(for building: BuildingModel) async -> Sourced<AnalystAnswer> {
        await analyst.answer(.summary(for: building))
    }

    // MARK: Identity

    private static let accountKey = "seismic.account"
    private static let householdKey = "seismic.household"

    private func restoreIdentity() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.accountKey),
           let stored = try? JSONDecoder().decode(UserAccount.self, from: data) {
            account = stored
        }
        if let data = defaults.data(forKey: Self.householdKey),
           let stored = try? JSONDecoder().decode(Household.self, from: data) {
            household = stored
        }
    }

    private func persistIdentity() {
        let defaults = UserDefaults.standard
        if let account, let data = try? JSONEncoder().encode(account) {
            defaults.set(data, forKey: Self.accountKey)
        } else {
            defaults.removeObject(forKey: Self.accountKey)
        }
        if let household, let data = try? JSONEncoder().encode(household) {
            defaults.set(data, forKey: Self.householdKey)
        } else {
            defaults.removeObject(forKey: Self.householdKey)
        }
    }

    func continueAsGuest() {
        account = .guest()
        persistIdentity()
    }

    /// Signs in and carries the guest's work across.
    ///
    /// A guest who has spent an hour modelling their house must not lose it by
    /// signing in afterwards, so the local data is never cleared on sign-in —
    /// it is simply queued for upload against the new account.
    func signIn(email: String, password: String) async -> String? {
        do {
            let session = try await cloud.signIn(email: email, password: password)
            let wasGuest = account?.isGuest ?? false
            account = session.account
            persistIdentity()
            if wasGuest { queueGuestDataForUpload() }
            return nil
        } catch let error as ServiceError {
            return error.userFacingReason
        } catch {
            return "Sign-in failed."
        }
    }

    func signUp(email: String, password: String, displayName: String) async -> String? {
        do {
            let session = try await cloud.signUp(email: email, password: password,
                                                 displayName: displayName)
            let wasGuest = account?.isGuest ?? false
            account = session.account
            persistIdentity()
            if wasGuest { queueGuestDataForUpload() }
            return nil
        } catch let error as ServiceError {
            return error.userFacingReason
        } catch {
            return "Could not create the account."
        }
    }

    func signIn(idToken: String, provider: AuthProvider, displayName: String) async -> String? {
        do {
            let session = try await cloud.signIn(idToken: idToken, provider: provider,
                                                 displayName: displayName)
            let wasGuest = account?.isGuest ?? false
            account = session.account
            persistIdentity()
            if wasGuest { queueGuestDataForUpload() }
            return nil
        } catch let error as ServiceError {
            return error.userFacingReason
        } catch {
            return "Sign-in failed."
        }
    }

    func signOut() async {
        await cloud.signOut()
        account = nil
        persistIdentity()
    }

    private(set) var pendingMigration = false

    private func queueGuestDataForUpload() {
        // The sync queue in SeismicData already holds every local change. All
        // that changes on sign-in is that it now has somewhere to drain to.
        pendingMigration = true
    }

    // MARK: Household

    func createHousehold(named name: String) {
        var new = Household(name: name)
        if let account {
            new.members = [.init(id: account.id, displayName: account.displayName, role: .owner)]
        }
        household = new
        persistIdentity()
    }

    func addMember(named name: String, role: Household.Role) {
        guard var current = household else { return }
        current.members.append(.init(id: UUID().uuidString, displayName: name, role: role))
        household = current
        persistIdentity()
    }

    func removeMember(_ id: String) {
        guard var current = household else { return }
        current.members.removeAll { $0.id == id }
        household = current
        persistIdentity()
    }

    func setCheckIn(_ status: Household.CheckInStatus, for memberID: String) {
        guard var current = household else { return }
        guard let index = current.members.firstIndex(where: { $0.id == memberID }) else { return }
        current.members[index].checkInStatus = status
        current.members[index].lastCheckIn = Date()
        household = current
        persistIdentity()
    }

    func leaveHousehold() {
        household = nil
        persistIdentity()
    }

    var isCloudConfigured: Bool { cloud.isConfigured }
}
