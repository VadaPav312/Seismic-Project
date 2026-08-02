import Foundation
import Combine
import SeismicCore

/// The call the app would place, placed against nothing.
///
/// A node that has just declared an earthquake knows things a person trapped in
/// the building cannot say: where the building is, how tall it is, what it is
/// made of, how strong the shaking was, whether anyone was home, and which
/// utilities are already off. Reading that to a dispatcher takes eleven seconds
/// and is more accurate than anything the occupant could manage while the floor
/// is moving. So the app dials emergency services and reads it out.
///
/// **This never dials.** There is no `tel:` URL anywhere in this file and no
/// telephony framework imported, on purpose: an app that demonstrates an
/// automatic emergency call must not be one wrong tap away from placing one, and
/// a hackathon demonstration that rings a real 911 dispatcher is an offence
/// before it is an embarrassment. Every stage below is a timer, every dispatcher
/// line is a script, and the interface says so in the one place nobody can miss
/// it. What is real is the *report* — it is assembled from the actual event, the
/// actual building and the actual actuator confirmations, so what you hear is
/// what would genuinely be said.
@MainActor
final class EmergencyCallController: ObservableObject {

    enum Stage: Equatable {
        case dialling
        case ringing
        case connected
        case reporting
        case acknowledged
        case ended

        var label: String {
            switch self {
            case .dialling: "Dialling"
            case .ringing: "Ringing"
            case .connected: "Connected"
            case .reporting: "Reporting"
            case .acknowledged: "Report received"
            case .ended: "Call ended"
            }
        }
    }

    struct Utterance: Identifiable, Equatable {
        let id = UUID()
        var speaker: Speaker
        var text: String
        enum Speaker { case dispatcher, app }
    }

    @Published private(set) var stage: Stage?
    @Published private(set) var transcript: [Utterance] = []
    @Published private(set) var startedAt: Date?
    @Published private(set) var elapsed: TimeInterval = 0
    /// The line currently being read, so the interface can highlight it.
    @Published private(set) var currentLine: Utterance.ID?

    var isActive: Bool { stage != nil && stage != .ended }

    /// Spoken lines go out through here, so this object never touches audio.
    var onSpeak: ((String) -> Void)?

    private var task: Task<Void, Never>?
    private var timer: AnyCancellable?

    /// The number that would be dialled, shown but never used.
    ///
    /// Regional, because "call 911" is wrong in most of the world and a system
    /// that only works in one country is not an emergency system. Taken from
    /// the device's own region rather than its language.
    static var emergencyNumber: String {
        switch Locale.current.region?.identifier {
        case "US", "CA": "911"
        case "GB", "IE": "999"
        case "AU": "000"
        case "NZ": "111"
        case "IN": "112"
        case "JP": "119"
        default: "112"
        }
    }

    // MARK: Placing it

    /// Starts the call. `report` is the sequence of sentences the app reads.
    func place(report: [String]) {
        cancel()
        stage = .dialling
        startedAt = Date()
        transcript = []
        elapsed = 0

        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            self.stage = .ringing

            try? await Task.sleep(for: .milliseconds(2600))
            guard !Task.isCancelled else { return }
            self.stage = .connected
            self.say(.dispatcher, "Emergency services. What is your emergency?")

            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled else { return }
            self.stage = .reporting

            for sentence in report {
                guard !Task.isCancelled else { return }
                self.say(.app, sentence)
                // Paced to be read at a natural speaking rate rather than all
                // at once, because the point of the screen is that somebody can
                // follow what is being said on their behalf and correct it.
                let seconds = min(6.0, 1.2 + Double(sentence.count) / 16.0)
                try? await Task.sleep(for: .seconds(seconds))
            }

            guard !Task.isCancelled else { return }
            self.stage = .acknowledged
            self.say(.dispatcher, "Understood. Units are being dispatched to that address. "
                                + "Stay on the line if you are able to.")
        }
    }

    /// Ends it deliberately, leaving the transcript on screen.
    func hangUp() {
        task?.cancel()
        task = nil
        timer?.cancel()
        timer = nil
        stage = .ended
        currentLine = nil
    }

    /// Clears it away entirely.
    func dismiss() {
        cancel()
        stage = nil
        transcript = []
        startedAt = nil
        elapsed = 0
    }

    private func cancel() {
        task?.cancel()
        task = nil
        timer?.cancel()
        timer = nil
        currentLine = nil
    }

    private func say(_ speaker: Utterance.Speaker, _ text: String) {
        let utterance = Utterance(speaker: speaker, text: text)
        transcript.append(utterance)
        currentLine = utterance.id
        // Only the app's own side is spoken aloud. Synthesising a dispatcher's
        // voice would make a recording of this screen genuinely misleading if
        // it ever left the room, and the demonstration loses nothing by having
        // their lines only on screen.
        if speaker == .app { onSpeak?(text) }
    }

    // MARK: The report

    /// What the app would actually say, assembled from what is known.
    ///
    /// Ordered the way a dispatcher needs it rather than the way the app knows
    /// it: location first, because a call that drops after four seconds has
    /// still done its job if the address got through; then whether anyone is
    /// inside; then the hazard; then the detail. Nothing here is invented — a
    /// fact the app does not have is a sentence that is not said.
    static func report(for event: AppEnvironment.ActiveEvent,
                       building: BuildingModel?,
                       occupied: Bool?,
                       householdSize: Int?) -> [String] {
        var lines: [String] = []

        let place = building.map { model -> String in
            let where_ = model.address.isEmpty
                ? String(format: "latitude %.5f, longitude %.5f", model.latitude, model.longitude)
                : model.address
            return "\(model.name), \(where_)"
        } ?? "an address this device could not determine"

        lines.append("This is an automated report from a seismic monitor at \(place). "
                     + "This is not a person speaking.")

        if let building, !building.address.isEmpty {
            lines.append(String(format: "Coordinates are %.5f, %.5f.",
                                building.latitude, building.longitude))
        }

        if let magnitude = event.estimatedMagnitude {
            let intensity = event.expectedIntensity.map { " Expected shaking here was \($0.shortLabel.lowercased())." } ?? ""
            lines.append(String(format: "An earthquake of estimated magnitude %.1f was detected "
                                    + "by three independent sensors.%@", magnitude, intensity))
        } else {
            lines.append("An earthquake was detected by three independent sensors.")
        }

        if let building {
            let age = building.yearBuilt.map { " Built in \($0)." } ?? ""
            lines.append("The building is \(building.storeyCount) storeys of "
                         + "\(building.material.label.lowercased()).\(age)")
        }

        if let occupied {
            if occupied, let size = householdSize, size > 0 {
                lines.append("\(size) \(size == 1 ? "person is" : "people are") registered as "
                             + "living here and the building was occupied at the time.")
            } else if occupied {
                lines.append("The building was occupied at the time.")
            } else {
                lines.append("The building was recorded as unoccupied at the time, though that "
                             + "cannot be confirmed.")
            }
        }

        // Only actuators that were *proven*, not merely commanded. Telling a
        // dispatcher the power is off when it might not be is how a firefighter
        // gets hurt.
        let confirmed = event.actuators.values
            .filter { $0.state == .confirmed }
            .map { $0.kind.label.lowercased() }
            .sorted()
        if !confirmed.isEmpty {
            lines.append("The following have been automatically shut off and physically "
                         + "confirmed: \(list(confirmed)).")
        }
        let unconfirmed = event.actuators.values
            .filter { $0.state == .failed }
            .map { $0.kind.label.lowercased() }
            .sorted()
        if !unconfirmed.isEmpty {
            lines.append("Treat \(list(unconfirmed)) as still live. The shutoff could not be "
                         + "confirmed.")
        }

        lines.append("A structural assessment of this building will follow within a minute of "
                     + "the shaking stopping. End of automated report.")
        return lines
    }

    private static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
}
