import SwiftUI
import SeismicCore
import SeismicServices

/// Signing out, and leaving for good.
///
/// The two are kept visibly far apart and described in terms of what happens to
/// the user's data, because that is the only thing they actually differ in and
/// the only thing anybody cares about at the moment of tapping. "Sign out" and
/// "Delete account" one above the other, in the same colour, with no
/// explanation, is how somebody destroys a year of measurements meaning to end
/// a session.
///
/// Deletion asks for the word to be typed. Not as ceremony — as the one
/// interaction a mis-tap cannot produce.
struct AccountScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var services: ServiceHub

    @State private var showingSignOut = false
    @State private var showingDelete = false
    @State private var typedConfirmation = ""
    @State private var isWorking = false
    @State private var report: AppEnvironment.AccountExitReport?

    private var account: UserAccount? { services.account }
    private var isGuest: Bool { account?.isGuest ?? true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.s6) {
                identityCard
                if let report { outcomeCard(report) }
                signOutGroup
                deleteGroup
            }
            .padding(Theme.Metrics.screenPadding)
            .contentColumn()
        }
        .scrollContentBackground(.hidden)
        .seismicBackground()
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Sign out?", isPresented: $showingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task { report = await env.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your buildings, events and assessments stay on this device and will be here "
                 + "when you sign back in. Nothing is deleted.")
        }
        .sheet(isPresented: $showingDelete) { deleteSheet }
    }

    // MARK: Who you are

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
            SectionLabel("Signed in as", systemImage: "person.crop.circle")

            HStack(spacing: Theme.Metrics.s4) {
                Image(systemName: account?.provider.systemImage ?? "person.crop.circle")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Theme.Palette.accentDim))

                VStack(alignment: .leading, spacing: 3) {
                    Text(account?.displayName ?? "Not signed in")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if isGuest {
                InlineNotice(
                    level: .info,
                    title: "This is a guest account",
                    message: "It exists only on this phone — nothing has ever been sent to a "
                        + "server, so there is nothing on one to delete. Everything below still "
                        + "works; it simply has less to do.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private var subtitle: String {
        guard let account else { return "Sign in to back up and share your buildings." }
        if account.isGuest { return "Local only. Nothing leaves this device." }
        return account.email ?? account.provider.label
    }

    // MARK: Signing out

    private var signOutGroup: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
            SectionLabel("Sign out", systemImage: "rectangle.portrait.and.arrow.right")

            Text("Ends this session. Every building, event, assessment and measurement stays on "
                 + "this device exactly as it is, and is there again the moment you sign back "
                 + "in. Anything waiting to sync waits until then.")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showingSignOut = true
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(Theme.Typography.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.Metrics.minimumTapTarget)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(account == nil || isWorking)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    // MARK: Deleting

    private var deleteGroup: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
            SectionLabel("Delete account", systemImage: "trash")

            Text("Removes your account and everything in it. This cannot be undone and there is "
                 + "no copy anywhere afterwards.")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                consequence("Your buildings, events, assessments, measurements and recordings, "
                            + "from this device")
                if !isGuest {
                    consequence("The same records from the server, and any verdicts you "
                                + "published to the community map")
                    consequence("Your sign-in itself, so the email or Apple ID can be used to "
                                + "create a fresh account later")
                }
                consequence("Your household, and your membership of it")
            }
            .padding(.vertical, Theme.Metrics.s1)

            Text("Export your data first if you want to keep any of it — Settings → Data → "
                 + "Export. Once this is done there is nothing left to export from.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                typedConfirmation = ""
                showingDelete = true
            } label: {
                Label("Delete my account", systemImage: "trash")
                    .font(Theme.Typography.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.Metrics.minimumTapTarget)
                    .foregroundStyle(Theme.Palette.verdictRed)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(account == nil || isWorking)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private func consequence(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Metrics.s3) {
            Image(systemName: "minus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.Palette.verdictRed)
                .padding(.top, 5)
            Text(text)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: The confirmation

    private var deleteSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.s5) {
                    Text("This is permanent.")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Palette.textPrimary)

                    Text("Type DELETE below to confirm. Nothing happens until you do — this is "
                         + "the one action in the app that a mis-tap cannot start.")
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("DELETE", text: $typedConfirmation)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(Theme.Typography.numeric)
                        .padding(Theme.Metrics.s4)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall,
                                             style: .continuous)
                                .fill(Theme.Palette.surfaceRaised))

                    Button {
                        Task { await performDeletion() }
                    } label: {
                        Group {
                            if isWorking {
                                ProgressView().controlSize(.small).tint(.white)
                            } else {
                                Text("Delete my account")
                                    .font(Theme.Typography.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .foregroundStyle(.white)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius,
                                             style: .continuous)
                                .fill(Theme.Palette.verdictRed
                                    .opacity(isConfirmed ? 0.85 : 0.25)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isConfirmed || isWorking)
                }
                .padding(Theme.Metrics.screenPadding)
                .contentColumn()
            }
            .scrollContentBackground(.hidden)
            .seismicBackground()
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingDelete = false }
                }
            }
        }
    }

    private var isConfirmed: Bool {
        typedConfirmation.trimmingCharacters(in: .whitespaces).uppercased() == "DELETE"
    }

    private func performDeletion() async {
        isWorking = true
        let result = await env.deleteAccount()
        isWorking = false
        showingDelete = false
        report = result
        Haptics.shared.play(result.isComplete ? .assessmentComplete : .warning)
    }

    // MARK: What actually happened

    /// Reports the outcome rather than assuming it.
    ///
    /// A deletion that half-worked is the case worth designing for: the rows
    /// went but the identity did not, or a file on disk was locked. Saying
    /// "deleted" over either of those would be a lie, and the user needs to know
    /// precisely enough to do something about it.
    private func outcomeCard(_ report: AppEnvironment.AccountExitReport) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
            if report.isComplete {
                InlineNotice(level: .info, title: heading(for: report),
                             message: summary(for: report))
            } else {
                InlineNotice(level: .critical, title: "Partly done",
                             message: summary(for: report))
                VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                    ForEach(report.problems, id: \.self) { problem in
                        Text("• " + problem)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.verdictAmber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private func heading(for report: AppEnvironment.AccountExitReport) -> String {
        report.localDocumentsRemoved > 0 ? "Account deleted" : "Signed out"
    }

    private func summary(for report: AppEnvironment.AccountExitReport) -> String {
        var parts: [String] = []
        if report.localDocumentsRemoved > 0 || report.localRecordingsRemoved > 0 {
            parts.append("\(report.localDocumentsRemoved) files and "
                         + "\(report.localRecordingsRemoved) recordings removed from this device")
        }
        if !report.cloudTablesCleared.isEmpty {
            parts.append("\(report.cloudTablesCleared.count) sets of records cleared from the "
                         + "server")
        }
        if report.identityRemovedFromServer {
            parts.append("your sign-in removed")
        }
        if parts.isEmpty {
            return "You are signed out. Everything on this device was left as it was."
        }
        return parts.joined(separator: ", ").capitalisedFirstCharacter + "."
    }
}

private extension String {
    var capitalisedFirstCharacter: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}

#Preview {
    NavigationStack { AccountScreen() }
        .previewEnvironment()
}
