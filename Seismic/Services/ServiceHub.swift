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

    /// What has happened near any point on Earth, over any window of years.
    ///
    /// Passed straight through rather than cached here — the service does its
    /// own caching, keyed on a rounded coordinate, so panning a map back and
    /// forth over the same city does not re-query the catalogue.
    func history(latitude: Double, longitude: Double,
                 radiusKm: Double = 250, years: Double = 10) async -> Sourced<RegionalHistory> {
        await feed.history(latitude: latitude, longitude: longitude,
                           radiusKm: radiusKm, years: years)
    }

    // MARK: The community map

    /// Publishes a verdict to the neighbourhood.
    func publish(_ tag: CommunityTag) async -> Sourced<Bool> {
        await cloud.publish(tag)
    }

    func vote(onTag id: UUID, agree: Bool) async -> Sourced<Bool> {
        await cloud.vote(onTag: id, agree: agree)
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

        // Lets a screenshot run or a UI test start past the sign-in gate, in
        // the same spirit as SEISMIC_INITIAL_TAB. It grants a guest account and
        // nothing more — there is no way to fake a signed-in account from here,
        // because a guest is exactly what somebody gets for declining anyway.
        if account == nil,
           ProcessInfo.processInfo.environment["SEISMIC_SKIP_SIGN_IN"] == "1" {
            account = .guest()
        }

        // The account above is a name and an id, kept in UserDefaults so the
        // launch screen can render before anything asynchronous happens. The
        // *tokens* live in the keychain and have to be put back too, or every
        // authenticated action degrades silently after the first relaunch —
        // which is exactly how deleting an account came to report "not signed
        // in" over an account displayed on the screen above it.
        if let account, !account.isGuest {
            Task { await cloud.restorePersistedSession() }
        }
        if let data = defaults.data(forKey: Self.householdKey),
           let stored = try? JSONDecoder().decode(Household.self, from: data) {
            household = stored
        }

        // An account already on this device is not a new arrival, even on the
        // first launch after this was added. Without seeding it, the first
        // sign-out-and-back-in by an existing user would look like a different
        // person and replay the introduction over their own work.
        if let account, defaults.string(forKey: Self.lastAccountKey) == nil {
            defaults.set(account.id, forKey: Self.lastAccountKey)
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
        adopt(UserAccount.guest())
    }

    /// Whether the account that just signed in is somebody this device has not
    /// seen before.
    ///
    /// Set by `adopt` and read once by the app, which uses it to put the
    /// introduction back. A phone that has already been through onboarding
    /// keeps `didCompleteOnboarding` set for ever, so the second person to use
    /// it — a partner, a new owner, anybody handed the demo — was dropped
    /// straight into the main interface having been shown nothing.
    @Published private(set) var didAdoptNewAccount = false

    func clearNewAccountFlag() { didAdoptNewAccount = false }

    /// Takes on an account and notices whether it is a new one.
    private func adopt(_ new: UserAccount) {
        let previous = UserDefaults.standard.string(forKey: Self.lastAccountKey)
        // A guest becoming a real account is the same person continuing, not a
        // new one arriving — their work is carried across, and re-running the
        // introduction over the building they just imported would be absurd.
        let wasGuestBecomingReal = (account?.isGuest ?? false) && !new.isGuest
        didAdoptNewAccount = previous != new.id && !wasGuestBecomingReal
        UserDefaults.standard.set(new.id, forKey: Self.lastAccountKey)
        account = new
        persistIdentity()
    }

    private static let lastAccountKey = "seismic.lastAccountID"

    /// Signs in and carries the guest's work across.
    ///
    /// A guest who has spent an hour modelling their house must not lose it by
    /// signing in afterwards, so the local data is never cleared on sign-in —
    /// it is simply queued for upload against the new account.
    func signIn(email: String, password: String) async -> String? {
        do {
            let session = try await cloud.signIn(email: email, password: password)
            let wasGuest = account?.isGuest ?? false
            adopt(session.account)
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
            adopt(session.account)
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
            adopt(session.account)
            if wasGuest { queueGuestDataForUpload() }
            return nil
        } catch let error as ServiceError {
            return error.userFacingReason
        } catch {
            return "Sign-in failed."
        }
    }

    /// Google and anything else that signs in through a browser.
    ///
    /// Returns nil on success, or a sentence to show. Cancelling returns nil
    /// too: the user closed the sheet on purpose and does not need to be told
    /// what they just did.
    func signInWithBrowser(provider: AuthProvider) async -> String? {
        guard let attempt = cloud.beginOAuth(provider: provider) else {
            return "Sign-in needs a Supabase project. Add SUPABASE_URL and "
                 + "SUPABASE_ANON_KEY, then enable Google in Authentication → Providers."
        }
        let signIn = WebSignIn()
        webSignIn = signIn
        defer { webSignIn = nil }

        do {
            let callback = try await signIn.authenticate(attempt)
            let session = try await cloud.completeOAuth(callback: callback, attempt: attempt)
            let wasGuest = account?.isGuest ?? false
            adopt(session.account)
            if wasGuest { queueGuestDataForUpload() }
            return nil
        } catch WebSignIn.Failure.cancelled {
            return nil
        } catch let error as ServiceError {
            return error.userFacingReason
        } catch {
            return "Google sign-in did not complete."
        }
    }

    /// Kept alive for the duration of the browser sheet.
    private var webSignIn: WebSignIn?

    func signOut() async {
        await cloud.signOut()
        account = nil
        persistIdentity()
    }

    /// Deletes the account on the server. Local data is not touched here — see
    /// `AppEnvironment.deleteAccount`, which owns the whole operation.
    ///
    /// A guest never reached a server, so there is nothing to delete and
    /// pretending otherwise would be a lie in the direction that matters.
    func deleteCloudAccount() async -> CloudService.DeletionOutcome? {
        guard let account, !account.isGuest else { return nil }
        return await cloud.deleteAccount()
    }

    /// Forgets who this is, without touching the server.
    func forgetIdentity() {
        account = nil
        household = nil
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

    func addMember(named name: String, role: Household.Role, phoneNumber: String? = nil) {
        guard var current = household else { return }
        current.members.append(.init(id: UUID().uuidString, displayName: name, role: role,
                                     phoneNumber: phoneNumber))
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
