import SwiftUI
import PhotosUI
import UIKit
import SeismicCore
import SeismicData
import SeismicServices

/// Where photographs live.
///
/// On disk beside the recordings, not in the JSON store: a document file that
/// has to be parsed to open the app should never contain megabytes of JPEG.
/// Thumbnails are generated once and cached, because a scroll view that decodes
/// full-resolution photographs stutters and a stuttering scroll view reads as a
/// broken app.
@MainActor
final class PhotoStore: ObservableObject {
    static let shared = PhotoStore()

    private let directory: URL
    private var thumbnails = NSCache<NSString, UIImage>()

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).jpg")
    }

    @discardableResult
    func save(_ image: UIImage, id: UUID = UUID()) -> UUID? {
        // Long edge capped at 2048: plenty to see a crack width, small enough
        // that a hundred photographs do not fill somebody's phone.
        let resized = image.resized(longestEdge: 2048)
        guard let data = resized.jpegData(compressionQuality: 0.82) else { return nil }
        do {
            try data.write(to: url(for: id), options: .atomic)
            return id
        } catch {
            return nil
        }
    }

    func image(_ id: UUID) -> UIImage? {
        UIImage(contentsOfFile: url(for: id).path)
    }

    func thumbnail(_ id: UUID) -> UIImage? {
        let key = id.uuidString as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let full = image(id) else { return nil }
        let small = full.resized(longestEdge: 300)
        thumbnails.setObject(small, forKey: key)
        return small
    }

    func base64JPEG(_ id: UUID, longestEdge: CGFloat = 1024) -> String? {
        guard let full = image(id) else { return nil }
        return full.resized(longestEdge: longestEdge)
            .jpegData(compressionQuality: 0.75)?
            .base64EncodedString()
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
        thumbnails.removeObject(forKey: id.uuidString as NSString)
    }
}

extension UIImage {
    func resized(longestEdge: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > longestEdge, longest > 0 else { return self }
        let scale = longestEdge / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}

// MARK: - Capture

/// Photographing damage.
///
/// The location label is required rather than optional, and it is the first
/// field. A photograph of a crack with no record of where it was taken cannot
/// be compared with anything later, which throws away most of its value — so
/// the sheet asks for the one piece of information that makes the photograph
/// worth keeping before it asks for the photograph.
struct DamageCaptureSheet: View {
    let building: BuildingModel
    var assessmentID: UUID?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var services: ServiceHub
    @EnvironmentObject private var voice: VoiceController
    @StateObject private var photos = PhotoStore.shared

    @State private var image: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var locationLabel = ""
    @State private var storey: Int?
    @State private var severity: Double = 0.4
    @State private var noteText = ""
    @State private var description: Sourced<AnalystAnswer>?
    @State private var isDescribing = false

    /// Locations already used for this building. Reusing one is what makes a
    /// before-and-after pair possible, so previous labels are offered first.
    private var existingLabels: [String] {
        Array(Set(env.store.notesList()
            .filter { $0.buildingID == building.id }
            .map(\.locationLabel)
            .filter { !$0.isEmpty })).sorted()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.spacingLoose) {
                    locationField
                    imageArea
                    if image != nil {
                        descriptionArea
                        severityField
                        noteField
                    }
                }
                .padding(Theme.Metrics.screenPadding)
            }
            .seismicBackground()
            .navigationTitle("Photograph")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(image == nil || locationLabel.isEmpty)
                }
            }
            .sheet(isPresented: $showingCamera) {
                CameraPicker(image: $image)
                    .ignoresSafeArea()
            }
            .onChange(of: pickerItem) { _, item in
                Task {
                    guard let data = try? await item?.loadTransferable(type: Data.self),
                          let loaded = UIImage(data: data) else { return }
                    image = loaded
                    await describe(loaded)
                }
            }
            .onChange(of: image) { _, new in
                guard let new else { return }
                Task { await describe(new) }
            }
        }
    }

    // MARK: Fields

    private var locationField: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Where was this taken", systemImage: "mappin.and.ellipse")
            TextField("Third floor, north-east column", text: $locationLabel)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall)
                    .fill(Theme.Palette.surfaceRaised))

            if !existingLabels.isEmpty {
                Text("Reuse a place you have photographed before, and the two shots will be "
                     + "shown side by side.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(existingLabels, id: \.self) { label in
                            Button(label) { locationLabel = label }
                                .font(Theme.Typography.label)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Theme.Palette.surfaceHighest))
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                }
            }

            Picker("Storey", selection: $storey) {
                Text("Not specified").tag(Int?.none)
                ForEach(1...building.storeyCount, id: \.self) { level in
                    Text("Storey \(level)").tag(Int?.some(level))
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.Palette.accent)
        }
    }

    @ViewBuilder
    private var imageArea: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius,
                                            style: .continuous))
            Button("Choose a different photograph") { self.image = nil; description = nil }
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.accent)
        } else {
            VStack(spacing: Theme.Metrics.spacing) {
                Button {
                    showingCamera = true
                } label: {
                    Label("Take a photograph", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Metrics.minimumTapTarget)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Choose from your library", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Metrics.minimumTapTarget)
                }
                .buttonStyle(SecondaryButtonStyle())

                if !UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Text("This device has no camera available, so choose from the library "
                         + "instead.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var descriptionArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("What this looks like", systemImage: "eye")
                if let description {
                    StatusPill(text: description.value.isAIGenerated
                               ? description.provider : "On device",
                               systemImage: description.origin.systemImage,
                               tint: description.origin.isLive ? Theme.Palette.accent
                                                               : Theme.Palette.textSecondary)
                }
            }

            if isDescribing {
                SkeletonBlock(height: 12)
                SkeletonBlock(height: 12, width: 200)
            } else if let description {
                Text(description.value.text)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = description.note {
                    Text(note)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .instrumentPanel()
    }

    private var severityField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel("How bad does it look")
                Spacer()
                Text(severityLabel)
                    .font(Theme.Typography.numericSmall)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Slider(value: $severity, in: 0...1).tint(Theme.Palette.accent)
            Text("Your own judgment is recorded as evidence in its own right, separately from "
                 + "anything measured. It is weighted, not ignored and not trusted blindly.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var severityLabel: String {
        switch severity {
        case ..<0.2: "Cosmetic"
        case ..<0.45: "Minor"
        case ..<0.7: "Noticeable"
        case ..<0.9: "Serious"
        default: "Severe"
        }
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("Note", systemImage: "text.alignleft")
                Spacer()
                Button {
                    if voice.isListening { voice.stopListening() } else { voice.startListening() }
                } label: {
                    Label(voice.isListening ? "Stop" : "Dictate",
                          systemImage: voice.isListening ? "stop.circle" : "mic")
                        .font(Theme.Typography.caption)
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            TextField("Anything worth remembering", text: $noteText, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall)
                    .fill(Theme.Palette.surfaceRaised))

            if voice.isListening {
                Text(voice.transcript.isEmpty ? "Listening…" : voice.transcript)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.accent)
                    .onChange(of: voice.transcript) { _, new in
                        if !new.isEmpty { noteText = new }
                    }
            }
        }
    }

    // MARK: Behaviour

    private func describe(_ image: UIImage) async {
        isDescribing = true
        defer { isDescribing = false }
        guard let base64 = image.resized(longestEdge: 1024)
            .jpegData(compressionQuality: 0.75)?.base64EncodedString() else { return }
        description = await services.analyst.describePhoto(
            jpegBase64: base64, subject: building.name, locationLabel: locationLabel)
    }

    private func save() {
        guard let image else { return }
        var photoIDs: [UUID] = []
        if let id = photos.save(image) { photoIDs.append(id) }

        let combined = [noteText, description?.value.isAIGenerated == true
                        ? "Automatic description: " + (description?.value.text ?? "") : ""]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        let note = DamageNote(buildingID: building.id,
                              text: combined.isEmpty ? "Photograph" : combined,
                              locationLabel: locationLabel,
                              storey: storey,
                              wasDictated: voice.isListening || !voice.transcript.isEmpty,
                              photoIDs: photoIDs,
                              severity: severity)
        env.store.upsert(note)
        env.refresh()
        Haptics.shared.play(.assessmentComplete)
        dismiss()
    }
}

// MARK: - Camera

struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera)
            ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: { image = $0; dismiss() }, onCancel: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        private let onPick: (UIImage) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info:
                                   [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onPick(image) }
            else { onCancel() }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onCancel() }
    }
}

// MARK: - Display

struct DamageNoteThumbnail: View {
    let note: DamageNote
    @State private var showingDetail = false

    var body: some View {
        Button {
            showingDetail = true
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall)
                        .fill(Theme.Palette.surfaceHighest)
                    if let id = note.photoIDs.first,
                       let thumbnail = PhotoStore.shared.thumbnail(id) {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "text.alignleft")
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall,
                                            style: .continuous))

                Text(note.locationLabel.isEmpty ? "Unlabelled" : note.locationLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .frame(width: 96, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingDetail) { DamageNoteDetail(note: note) }
    }
}

/// One note, and — when there is more than one photograph of the same place —
/// the comparison that makes the whole exercise worthwhile.
struct DamageNoteDetail: View {
    let note: DamageNote
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var env: AppEnvironment

    private var siblings: [DamageNote] {
        env.store.notesList()
            .filter { $0.buildingID == note.buildingID
                   && $0.locationLabel == note.locationLabel
                   && !$0.locationLabel.isEmpty
                   && !$0.photoIDs.isEmpty }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.spacingLoose) {
                    if siblings.count > 1 {
                        PhotoComparison(notes: siblings)
                    } else if let id = note.photoIDs.first,
                              let image = PhotoStore.shared.image(id) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(note.locationLabel.isEmpty ? "Note" : note.locationLabel,
                                     trailing: note.createdAt.formatted(date: .abbreviated,
                                                                        time: .shortened))
                        Text(note.text)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if note.wasDictated {
                            StatusPill(text: "Dictated", systemImage: "mic")
                        }
                    }
                    .instrumentPanel()
                }
                .padding(Theme.Metrics.screenPadding)
            }
            .seismicBackground()
            .navigationTitle("Photograph")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// Two photographs of the same place, with a wipe between them.
///
/// A slider rather than a side-by-side pair, because the eye is very good at
/// spotting a line that moves when everything around it stays put, and very bad
/// at comparing two images an inch apart.
struct PhotoComparison: View {
    let notes: [DamageNote]
    @State private var earlierIndex = 0
    @State private var laterIndex = 1
    @State private var wipe: Double = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.spacing) {
            SectionLabel("Then and now", systemImage: "arrow.left.and.right")

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    if let later = image(at: laterIndex) {
                        Image(uiImage: later)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                    if let earlier = image(at: earlierIndex) {
                        Image(uiImage: earlier)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: geometry.size.width * wipe)
                            }
                    }
                    Rectangle()
                        .fill(Theme.Palette.accent)
                        .frame(width: 2)
                        .offset(x: geometry.size.width * wipe - 1)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    wipe = min(max(value.location.x / geometry.size.width, 0), 1)
                })
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius,
                                        style: .continuous))

            HStack {
                Text(dateLabel(earlierIndex))
                Spacer()
                Text(dateLabel(laterIndex))
            }
            .font(Theme.Typography.numericSmall)
            .foregroundStyle(Theme.Palette.textTertiary)

            Text("Drag across the photograph to wipe between the two. A crack that has widened "
                 + "between them is worth more than any single measurement.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            earlierIndex = 0
            laterIndex = max(notes.count - 1, 0)
        }
    }

    private func image(at index: Int) -> UIImage? {
        guard notes.indices.contains(index), let id = notes[index].photoIDs.first else {
            return nil
        }
        return PhotoStore.shared.image(id)
    }

    private func dateLabel(_ index: Int) -> String {
        guard notes.indices.contains(index) else { return "—" }
        return notes[index].createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}
