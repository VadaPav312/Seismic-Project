import SwiftUI
import SeismicCore
import SeismicData
import SeismicServices

/// Settings, including the API key manager.
struct SettingsScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var services: ServiceHub
    @EnvironmentObject private var voice: VoiceController
    @EnvironmentObject private var notifications: NotificationCentre
    @EnvironmentObject private var tutorial: TutorialDirector
    @State private var showingLedger = false
    @State private var showingGlossary = false

    var body: some View {
        List {
            Section("Account") {
                NavigationLink { HouseholdScreen().seismicBackground() } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(services.account?.displayName ?? "Not signed in")
                            Text(services.household.map { "\($0.members.count) in \($0.name)" }
                                 ?? "Sign in to back up and share, or carry on without")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                    } icon: {
                        Image(systemName: services.account?.provider.systemImage
                              ?? "person.crop.circle")
                    }
                }
            }

            Section {
                NavigationLink { APIKeysScreen().seismicBackground() } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("API keys")
                            Text("\(env.configuredKeyCount) of "
                                 + "\(SecretKey.allCases.filter(\.isSensitive).count) configured")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                    } icon: {
                        Image(systemName: "key")
                    }
                }

                NavigationLink { LedgerScreen().seismicBackground() } label: {
                    Label("Ledger verification", systemImage: "checkmark.seal")
                }

                NavigationLink { GlossaryScreen().seismicBackground() } label: {
                    Label("Glossary", systemImage: "character.book.closed")
                }

                NavigationLink { AlgorithmCatalogScreen().seismicBackground() } label: {
                    Label("Algorithm catalogue", systemImage: "function")
                }
            } header: {
                Text("Reference")
            } footer: {
                if env.secretsLoadedFromEnv > 0 {
                    Text("\(env.secretsLoadedFromEnv) keys were loaded from your .env file at "
                         + "first launch and moved into the keychain.")
                } else {
                    Text("No .env file was found, which is fine — every feature works without "
                         + "keys, using bundled data and on-device computation.")
                }
            }

            Section("Data") {
                let footprint = env.store.storageFootprint()
                LabeledContent("Buildings", value: "\(env.buildings.count)")
                LabeledContent("Events", value: "\(env.events.count)")
                LabeledContent("Measurements", value: "\(env.observations.count)")
                LabeledContent("Storage",
                               value: ByteCountFormatter.string(
                                fromByteCount: Int64(footprint.documents + footprint.recordings),
                                countStyle: .file))

                Button {
                    if let data = env.store.exportJSON() {
                        exportedData = data
                        showingExport = true
                    }
                } label: {
                    Label("Export everything", systemImage: "square.and.arrow.up")
                }

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete all data", systemImage: "trash")
                }

                // Offered whenever the app has been emptied, so deleting
                // everything is a reversible decision about *your* data rather
                // than a way to end up with an app that does nothing.
                if env.buildings.isEmpty {
                    Button {
                        env.restoreSeedLibrary()
                    } label: {
                        Label("Restore the example library", systemImage: "arrow.clockwise")
                    }
                }
            }

            Section {
                Toggle(isOn: $hapticsEnabled) {
                    Label("Haptics", systemImage: "iphone.radiowaves.left.and.right")
                }

                Toggle(isOn: $voice.speaksAutomatically) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Spoken guidance", systemImage: "speaker.wave.2")
                        Text("Instructions are read aloud so you do not have to look at the "
                             + "screen while getting under a table. The earthquake warning "
                             + "itself is spoken either way.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }

                Toggle(isOn: $voice.isVoiceControlEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Voice control", systemImage: "mic")
                        Text(voice.isSpeechRecognitionAvailable
                             ? "Ask \"is it safe\" or \"read the assessment\" without touching "
                               + "the phone. Anything that fires an actuator still needs a tap."
                             : "Speech recognition is not available on this device.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                .disabled(!voice.isSpeechRecognitionAvailable)

                LabeledContent("Voice") {
                    Text(voice.voiceProvider)
                        .font(Theme.Typography.numericSmall)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            } header: {
                Text("Accessibility and behaviour")
            } footer: {
                if let error = voice.listeningError {
                    Text(error)
                }
            }

            Section {
                NotificationSettingsSection(centre: notifications)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                Button {
                    env.didCompleteOnboarding = false
                } label: {
                    Label("Replay the introduction", systemImage: "arrow.counterclockwise")
                }
                Button {
                    // Clearing the flag is enough: RootView starts the tour
                    // whenever it is unset and the main interface is showing.
                    tutorial.requestReplay()
                } label: {
                    Label("Take the guided tour again", systemImage: "hand.point.up.left")
                }
                Toggle(isOn: $env.isPresentationMode) {
                    Label("Presentation mode", systemImage: "play.rectangle")
                }
            } header: {
                Text("Demonstration")
            } footer: {
                Text("Presentation mode walks through the app's highlights automatically, for "
                     + "showing it to somebody.")
            }

            Section {
                LabeledContent("Version", value: "1.0")
                LabeledContent("Algorithms", value: "\(AlgorithmCatalog.countedAlgorithms) core, "
                               + "\(AlgorithmCatalog.all.count - AlgorithmCatalog.countedAlgorithms) supporting")
            } footer: {
                Text(Assessment.disclaimer)
            }
        }
        .scrollContentBackground(.hidden)
        .seismicBackground()
        .confirmationDialog("Delete everything?",
                            isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete all data", role: .destructive) {
                env.store.deleteEverything()
                env.refresh()
            }
        } message: {
            Text("This removes every building, event, assessment and measurement from this "
                 + "device. It cannot be undone.")
        }
        .sheet(isPresented: $showingExport) {
            if let exportedData,
               let text = String(data: exportedData, encoding: .utf8) {
                NavigationStack {
                    ScrollView {
                        Text(text.prefix(20_000))
                            .font(.system(size: 10, design: .monospaced))
                            .padding()
                    }
                    .navigationTitle("Export")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            ShareLink(item: text)
                        }
                    }
                }
            }
        }
    }

    @State private var showingDeleteConfirmation = false
    @State private var showingExport = false
    @State private var exportedData: Data?
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
}

/// Per-key management, with the status the specification calls for.
struct APIKeysScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var editing: SecretKey?
    @State private var draft = ""
    @AppStorage("apiKeysShowFreeOnly") private var freeOnly = true

    var body: some View {
        List {
            Section {
                Text("Nothing here is required. Every feature works without keys — search falls "
                     + "back to the bundled library, maps to OpenStreetMap, and the analyst to "
                     + "on-device computation. A key simply upgrades one path from simulated to "
                     + "live.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            Section {
                Toggle(isOn: $freeOnly) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Show only the free ones", systemImage: "gift")
                        Text("Every capability in this app has a path that costs nothing. "
                             + "Hiding the paid keys makes it obvious which signups will end "
                             + "at a card form.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            ForEach(SecretKey.Group.allCases) { group in
                let keys = SecretKey.allCases.filter {
                    $0.group == group && (!freeOnly || $0.cost == .free || $0.cost == .none)
                }
                if !keys.isEmpty {
                    Section(group.rawValue) {
                        ForEach(keys) { key in keyRow(key) }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("API keys")
        .sheet(item: $editing) { key in
            KeyEditorSheet(key: key, initialValue: env.secrets.value(for: key) ?? "") { value in
                env.secrets.set(key, to: value.isEmpty ? nil : value)
            }
        }
    }

    private func keyRow(_ key: SecretKey) -> some View {
        Button {
            editing = key
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(key.rawValue)
                        .font(Theme.Typography.numericSmall)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Spacer()
                    statusPill(for: key)
                }

                // What it costs to get, said before the user spends ten minutes
                // discovering it for themselves.
                if key.isSensitive {
                    StatusPill(text: key.cost.label, systemImage: key.cost.systemImage,
                               tint: key.cost == .free ? Theme.Palette.verdictGreen
                                   : (key.cost == .paid ? Theme.Palette.verdictAmber
                                                        : Theme.Palette.textSecondary))
                }
                Text(key.purpose)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !env.secrets.has(key) {
                    // Rather than "missing", say what happens instead. A user
                    // reading this should feel informed, not nagged.
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 8))
                        Text(key.fallbackBehaviour)
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(Theme.Palette.textTertiary)
                } else {
                    Text(env.secrets.fingerprint(for: key))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    private func statusPill(for key: SecretKey) -> some View {
        let status = env.secrets.status(for: key)
        let tint: Color = switch status {
        case .valid: Theme.Palette.verdictGreen
        case .present: Theme.Palette.accent
        case .failing: Theme.Palette.verdictRed
        case .rateLimited: Theme.Palette.verdictAmber
        case .missing: Theme.Palette.textTertiary
        }
        return StatusPill(text: status.label, tint: tint)
    }
}

struct KeyEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let key: SecretKey
    @State var draft: String
    let onSave: (String) -> Void

    init(key: SecretKey, initialValue: String, onSave: @escaping (String) -> Void) {
        self.key = key
        self._draft = State(initialValue: initialValue)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste the value", text: $draft, axis: .vertical)
                        .font(.system(size: 13, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2...6)
                } header: {
                    Text(key.rawValue)
                } footer: {
                    Text(key.purpose)
                }

                Section {
                    Button("Clear this key", role: .destructive) {
                        draft = ""
                        onSave("")
                        dismiss()
                    }
                } footer: {
                    Text("Without it: \(key.fallbackBehaviour)")
                }
            }
            .navigationTitle("Edit key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Ledger verification, with a live demonstration of tamper detection.
struct LedgerScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var verification: EventLedger.Verification?
    @State private var didTamper = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.spacingLoose) {
                if let verification {
                    VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
                        HStack(spacing: 10) {
                            Image(systemName: verification.isIntact
                                  ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(verification.isIntact
                                                 ? Theme.Palette.verdictGreen
                                                 : Theme.Palette.verdictRed)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verification.headline)
                                    .font(Theme.Typography.title)
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                Text("\(verification.entriesChecked) entries checked")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                        }

                        Text(verification.reason)
                            .font(Theme.Typography.callout)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Merkle root: \(env.store.ledger.merkleRoot().prefix(32))…")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .instrumentPanel()
                }

                VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
                    SectionLabel("Prove it")
                    Text("Claiming a ledger is tamper-evident is easy. This alters a historical "
                         + "entry exactly as somebody editing the database would, so you can "
                         + "watch the chain break.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        env.store.ledger.simulateTampering(atIndex: max(env.store.ledger.count / 2, 0))
                        didTamper = true
                        verify()
                        Haptics.shared.play(.warning)
                    } label: {
                        Label("Alter a historical entry", systemImage: "pencil.slash")
                            .frame(maxWidth: .infinity)
                            .frame(height: Theme.Metrics.minimumTapTarget)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(didTamper)

                    if didTamper {
                        InlineNotice(level: .critical, title: "Detected",
                                     message: "The chain no longer verifies. Every entry after "
                                        + "the altered one is invalidated too, which is why a "
                                        + "single quiet edit is not possible.")
                        Button("Reload the ledger from disk") {
                            env.store.load()
                            didTamper = false
                            verify()
                        }
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .instrumentPanel()

                VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
                    SectionLabel("Entries", trailing: "\(env.store.ledger.count)")
                    ForEach(env.store.ledger.entries.suffix(30).reversed(), id: \.id) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: entry.kind.systemImage)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Palette.accent)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.summary)
                                    .font(Theme.Typography.caption.weight(.medium))
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("#\(entry.index + 1) · "
                                     + entry.timestamp.formatted(date: .abbreviated,
                                                                 time: .shortened)
                                     + " · \(entry.hash.prefix(10))…")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Theme.Palette.textTertiary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .instrumentPanel()
            }
            .padding(Theme.Metrics.screenPadding)
            .contentColumn()
        }
        .navigationTitle("Ledger")
        .onAppear { verify() }
    }

    private func verify() {
        verification = env.store.ledger.verify()
    }
}

struct GlossaryScreen: View {
    @State private var query = ""

    var body: some View {
        List {
            ForEach(Glossary.search(query), id: \.term) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.term)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(entry.definition)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !entry.seeAlso.isEmpty {
                        Text("See also: " + entry.seeAlso.joined(separator: ", "))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .scrollContentBackground(.hidden)
        .searchable(text: $query, prompt: "Search terms")
        .navigationTitle("Glossary")
    }
}

#Preview {
    NavigationStack {
        SettingsScreen().navigationTitle("Settings")
    }
    .previewEnvironment()
}
