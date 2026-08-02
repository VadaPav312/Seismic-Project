import SwiftUI
import AuthenticationServices
import SeismicCore
import SeismicServices

/// The people who need to know, and the account that keeps them in sync.
///
/// Two things this screen is careful about. Signing in is optional and stays
/// optional — a guest account is a real account, and nothing is taken away for
/// declining. And roles are about *authority over the building*, not about
/// hierarchy: a viewer sees everything and can fire nothing, which is exactly
/// the right shape for a worried relative three hundred miles away.
struct HouseholdScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var services: ServiceHub

    @State private var showingAuth = false
    @State private var newMemberName = ""
    @State private var newMemberRole: Household.Role = .adult
    @State private var newMemberPhone = ""
    @State private var shareableMessage: String?
    @State private var showingInvite = false
    @State private var escalationResult: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.spacingLoose) {
                accountSection

                if let household = services.household {
                    checkInSection(household)
                    membersSection(household)
                    inviteSection(household)
                } else {
                    createSection
                }
            }
            .padding(Theme.Metrics.screenPadding)
            .contentColumn()
        }
        .sheet(isPresented: $showingAuth) { AuthSheet() }
        .sheet(isPresented: Binding(get: { shareableMessage != nil },
                                    set: { if !$0 { shareableMessage = nil } })) {
            if let shareableMessage {
                ActivityShareSheet(items: [shareableMessage])
            }
        }
        .sheet(isPresented: $showingInvite) {
            if let household = services.household { InviteSheet(household: household) }
        }
    }

    // MARK: Account

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Account", systemImage: "person.crop.circle")

            if let account = services.account {
                HStack(spacing: 12) {
                    Image(systemName: account.provider.systemImage)
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(width: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayName)
                            .font(Theme.Typography.headline)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text(account.email ?? account.provider.label)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Spacer()
                    StatusPill(text: account.tier.label, systemImage: account.tier.systemImage,
                               tint: Theme.Palette.textSecondary)
                }

                if account.isGuest {
                    InlineNotice(
                        level: .info,
                        title: "You are using this without an account",
                        message: "Everything works. Your buildings and assessments live on this "
                            + "device only, and are not backed up. Signing in later keeps "
                            + "everything you have already done.",
                        actionTitle: "Sign in",
                        action: { showingAuth = true })
                } else {
                    // A link rather than a button that acts immediately. Signing
                    // out and deleting the account are two very different things
                    // and this is not the screen that can explain the difference
                    // — the one that can is a tap away.
                    NavigationLink {
                        AccountScreen()
                    } label: {
                        HStack(spacing: 6) {
                            Text("Sign out or delete account")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.accent)
                    }
                }
            } else {
                Text("Sign in to back up your buildings and share a household, or carry on "
                     + "without an account — the app is complete either way.")
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    showingAuth = true
                } label: {
                    Label("Sign in", systemImage: "person.crop.circle.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())

                Button("Continue without an account") { services.continueAsGuest() }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.accent)
            }

            if !services.isCloudConfigured {
                Text("No cloud project is configured, so accounts and households are kept on "
                     + "this device. Adding SUPABASE_URL and SUPABASE_ANON_KEY turns on sync; "
                     + "nothing you do now is lost when you do.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    // MARK: Household

    private var createSection: some View {
        DesignedEmptyState(
            icon: "person.3",
            title: "No household yet",
            message: "A household is the people who should be told when your building has been "
                + "shaken — and who can check in so you know they are all right.",
            actionTitle: "Create a household",
            action: {
                services.createHousehold(named: "My household")
                Haptics.shared.play(.selection)
            })
    }

    private func checkInSection(_ household: Household) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Check-in", systemImage: "checkmark.message")

            let unaccounted = household.membersUnaccountedFor
            let needHelp = household.membersNeedingHelp

            if !needHelp.isEmpty {
                InlineNotice(level: .critical,
                             title: "\(needHelp.count) asked for help",
                             message: needHelp.map(\.displayName).joined(separator: ", "))
            } else if unaccounted.isEmpty {
                InlineNotice(level: .info, title: "Everyone has checked in",
                             message: "All \(household.members.count) accounted for.")
            } else {
                InlineNotice(
                    level: .warning,
                    title: "\(unaccounted.count) have not checked in",
                    message: unaccounted.map(\.displayName).joined(separator: ", ")
                        + ". Send them a message, or mark them safe if you have heard.",
                    actionTitle: "Message them",
                    action: { escalate(to: unaccounted) })
            }

            if let escalationResult {
                Text(escalationResult)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private func membersSection(_ household: Household) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel(household.name, systemImage: "person.3",
                         trailing: "\(household.members.count)")

            ForEach(household.members) { member in
                HStack(spacing: 10) {
                    Image(systemName: member.checkInStatus.systemImage)
                        .foregroundStyle(colour(for: member.checkInStatus))
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.displayName)
                            .font(Theme.Typography.callout)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text(member.role.label
                             + (member.role.canControlActuators
                                ? " · can fire actuators" : " · view only")
                             + (member.isReachableBySMS ? "" : " · no number"))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }

                    Spacer()

                    Menu {
                        ForEach([Household.CheckInStatus.safe, .needsHelp, .noAnswer,
                                 .unknown], id: \.rawValue) { status in
                            Button(status.label) {
                                services.setCheckIn(status, for: member.id)
                                Haptics.shared.play(.selection)
                            }
                        }
                        Divider()
                        Button("Remove", role: .destructive) {
                            services.removeMember(member.id)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider().overlay(Theme.Palette.hairline)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Name", text: $newMemberName)
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.callout)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall)
                            .fill(Theme.Palette.surfaceRaised))

                    Picker("Role", selection: $newMemberRole) {
                        ForEach(Household.Role.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.Palette.accent)
                }

                HStack(spacing: 8) {
                    TextField("Phone number (optional)", text: $newMemberPhone)
                        .textFieldStyle(.plain)
                        .keyboardType(.phonePad)
                        .font(Theme.Typography.callout)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall)
                            .fill(Theme.Palette.surfaceRaised))

                    Button {
                        guard !newMemberName.isEmpty else { return }
                        services.addMember(named: newMemberName, role: newMemberRole,
                                           phoneNumber: newMemberPhone.isEmpty ? nil
                                                                               : newMemberPhone)
                        newMemberName = ""
                        newMemberPhone = ""
                        Haptics.shared.play(.selection)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                    }
                    .disabled(newMemberName.isEmpty)
                    .foregroundStyle(Theme.Palette.accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private func inviteSection(_ household: Household) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Invite", systemImage: "qrcode")

            Text("Anyone with this code can join and see your buildings' verdicts. Only you can "
                 + "hand it out, and you can change it at any time.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(household.inviteCode)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .tracking(4)
                    .foregroundStyle(Theme.Palette.accent)
                Spacer()
                Button {
                    showingInvite = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            Text("No vowels and no look-alike characters, so it survives being read out over a "
                 + "bad phone line.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }

    private func colour(for status: Household.CheckInStatus) -> Color {
        switch status {
        case .safe: Theme.Palette.verdictGreen
        case .needsHelp: Theme.Palette.verdictRed
        case .noAnswer: Theme.Palette.verdictAmber
        case .unknown: Theme.Palette.textTertiary
        }
    }

    /// One message per member, sent where there is a number and handed to the
    /// share sheet where there is not. Reporting both outcomes together is the
    /// point: "sent to two, three need you to message them" is actionable in a
    /// way that a single success or failure is not.
    private func escalate(to members: [Household.Member]) {
        let message = EscalationService.message(
            buildingName: env.selectedBuilding?.name ?? "your building",
            verdict: env.latestAssessment?.verdict,
            senderName: services.account?.displayName ?? "Someone")

        Task {
            var sent: [String] = []
            var unreachable: [String] = []

            for member in members {
                let result = await services.escalation.escalate(
                    to: member.phoneNumber ?? "", message: message)
                switch result.value {
                case .sent: sent.append(member.displayName)
                case .handBackToUser: unreachable.append(member.displayName)
                }
            }

            var parts: [String] = []
            if !sent.isEmpty { parts.append("Sent to \(sent.joined(separator: ", ")).") }
            if !unreachable.isEmpty {
                parts.append("\(unreachable.joined(separator: ", ")) "
                             + (unreachable.count == 1 ? "has" : "have")
                             + " no number on file — the message is ready to send yourself.")
                shareableMessage = message
            }
            escalationResult = parts.joined(separator: " ")
        }
    }
}

// MARK: - Sign in

struct AuthSheet: View {
    /// True when this is the first thing shown at launch rather than a sheet
    /// pulled up from the Household screen.
    ///
    /// The difference is only in the framing: a gate has no Close button,
    /// because there is nothing behind it to go back to, and it introduces the
    /// app rather than assuming you already know what it is. The sign-in paths
    /// themselves are identical, which is why this is a flag rather than a
    /// second screen that would drift out of step with this one.
    var isLaunchGate = false

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var services: ServiceHub

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var error: String?
    @State private var isWorking = false

    enum Mode { case signIn, signUp }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: isLaunchGate ? .center : .leading,
                       spacing: Theme.Metrics.spacingLoose) {
                    if isLaunchGate { launchHeader }

                    Text("Signing in backs up your buildings and lets a household share them. "
                         + "It is not required for anything else.")
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(isLaunchGate ? .center : .leading)

                    // Rounded to match every other control on the screen.
                    // `SignInWithAppleButton` draws its own square-cornered
                    // background, so it is clipped to the same capsule the
                    // Google button and the primary style use — otherwise it is
                    // the one hard-edged rectangle in an interface where
                    // nothing else has a corner.
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        handleApple(result)
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: Theme.Metrics.minimumTapTarget)
                    .clipShape(Capsule(style: .continuous))

                    Button {
                        signInWithGoogle()
                    } label: {
                        Label("Continue with Google", systemImage: "globe")
                            .frame(maxWidth: .infinity)
                            .frame(height: Theme.Metrics.minimumTapTarget)
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Divider().overlay(Theme.Palette.hairline)

                    emailForm

                    Button("Continue without an account") {
                        services.continueAsGuest()
                        finish()
                    }
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.Metrics.minimumTapTarget)
                }
                // The launch gate is a full screen rather than a sheet, and a
                // form stretched edge to edge across a 6.9-inch phone reads as
                // unfinished. Wider margins and a measured column give it the
                // same breathing room every other screen has; the cap stops it
                // sprawling on an iPad.
                .frame(maxWidth: isLaunchGate ? 460 : .infinity)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, isLaunchGate ? Theme.Metrics.spacingSection
                                                   : Theme.Metrics.screenPadding)
                .padding(.vertical, isLaunchGate ? Theme.Metrics.spacingSection
                                                 : Theme.Metrics.screenPadding)
            }
            .seismicBackground()
            .navigationTitle(isLaunchGate ? "" : "Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isLaunchGate {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                }
            }
        }
    }

    /// The first thing anybody sees. It says what the app is before asking for
    /// anything, because a sign-in form with no context is a reason to close an
    /// app rather than a reason to use it.
    private var launchHeader: some View {
        VStack(spacing: Theme.Metrics.spacing) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Theme.Palette.accent)

            Text("SEISMIC")
                .font(.system(size: 28, weight: .semibold))
                // Wide tracking needs the trailing space compensated, or a
                // centred wordmark sits visibly left of centre.
                .tracking(6)
                .padding(.leading, 6)
                .foregroundStyle(Theme.Palette.textPrimary)

            Text("Know whether your building is safe to be in — from its own "
                 + "measurements, not from a guess.")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, Theme.Metrics.spacing)
    }

    /// Leaving is only possible when there is somewhere to leave to. As the
    /// launch gate this view is dismissed by the account appearing, which
    /// RootView is already watching for.
    private func finish() {
        guard !isLaunchGate else { return }
        dismiss()
    }

    private var emailForm: some View {
        VStack(alignment: isLaunchGate ? .center : .leading, spacing: Theme.Metrics.spacing) {
            Picker("Mode", selection: $mode) {
                Text("Sign in").tag(Mode.signIn)
                Text("Create an account").tag(Mode.signUp)
            }
            .pickerStyle(.segmented)

            if mode == .signUp {
                field("Name", text: $displayName, secure: false)
            }
            field("Email", text: $email, secure: false)
            field("Password", text: $password, secure: true)

            if let error {
                Text(error)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.verdictRed)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                submit()
            } label: {
                if isWorking {
                    ProgressView().tint(.black)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(mode == .signIn ? "Sign in" : "Create the account")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(email.isEmpty || password.count < 6 || isWorking)

            if !services.isCloudConfigured {
                Text("No cloud project is configured yet, so this will not reach a server. "
                     + "Continue without an account instead — nothing is lost.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, secure: Bool) -> some View {
        VStack(alignment: isLaunchGate ? .center : .leading, spacing: 4) {
            Text(title)
                .font(Theme.Typography.label)
                .tracking(0.8)
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(maxWidth: .infinity,
                       alignment: isLaunchGate ? .center : .leading)
            Group {
                if secure { SecureField("", text: text) } else { TextField("", text: text) }
            }
            .textFieldStyle(.plain)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(Theme.Typography.body)
            .multilineTextAlignment(isLaunchGate ? .center : .leading)
            .padding(.horizontal, Theme.Metrics.s4)
            .frame(height: Theme.Metrics.minimumTapTarget)
            .background(Capsule(style: .continuous).fill(Theme.Palette.surfaceRaised))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(Theme.Palette.hairline, lineWidth: 1))
        }
    }

    private func submit() {
        isWorking = true
        error = nil
        Task {
            let failure = mode == .signIn
                ? await services.signIn(email: email, password: password)
                : await services.signUp(email: email, password: password,
                                        displayName: displayName.isEmpty ? email : displayName)
            isWorking = false
            if let failure { error = failure } else { finish() }
        }
    }

    /// Apple hands back an identity token, which is exchanged for a session.
    /// When there is no cloud project the sign-in still succeeds locally — the
    /// user gets a named account on the device rather than an error.
    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorisation):
            guard let credential = authorisation.credential
                    as? ASAuthorizationAppleIDCredential else { return }
            let name = [credential.fullName?.givenName, credential.fullName?.familyName]
                .compactMap { $0 }.joined(separator: " ")
            let token = credential.identityToken
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Task {
                let failure = await services.signIn(
                    idToken: token, provider: .apple,
                    displayName: name.isEmpty ? "Apple account" : name)
                if failure != nil {
                    // The identity is genuine even if the server is not there.
                    services.account = UserAccount(id: credential.user,
                                                   email: credential.email,
                                                   displayName: name.isEmpty ? "Apple account"
                                                                             : name,
                                                   provider: .apple)
                }
                finish()
            }
        case .failure(let failure):
            let code = (failure as NSError).code
            // Cancelling is not an error and must not be reported as one.
            if code != ASAuthorizationError.canceled.rawValue {
                error = "Apple sign-in did not complete."
            }
        }
    }

    private func signInWithGoogle() {
        error = nil
        isWorking = true
        Task {
            let message = await services.signInWithBrowser(provider: .google)
            isWorking = false
            error = message
            if message == nil, services.account?.isGuest == false { finish() }
        }
    }
}

// MARK: - Invite

struct InviteSheet: View {
    let household: Household
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Metrics.spacingLoose) {
                if let image = QRCode.image(for: household.inviteURL?.absoluteString
                                            ?? household.inviteCode) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .padding(Theme.Metrics.spacing)
                        .background(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius)
                            .fill(.white))
                }

                Text(household.inviteCode)
                    .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                    .tracking(8)
                    .foregroundStyle(Theme.Palette.textPrimary)

                Text("Scan the code, or type the six characters. Both do the same thing — the "
                     + "typed version exists because a camera is no use over the phone.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let url = household.inviteURL {
                    ShareLink(item: url) {
                        Label("Share the link", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .frame(height: Theme.Metrics.minimumTapTarget)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }

                Spacer()
            }
            .padding(Theme.Metrics.screenPadding)
            .seismicBackground()
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// QR generation, via Core Image's built-in generator.
enum QRCode {
    static func image(for string: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        // High correction, so the code still scans with a thumb over a corner.
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

#Preview {
    NavigationStack {
        HouseholdScreen()
            .seismicBackground()
            .navigationTitle("Household")
    }
    .previewEnvironment()
}
