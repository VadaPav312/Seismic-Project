import Foundation

// ActivityKit exists on macOS as a symbol but every API in it is
// unavailable there, so the guard is on the platform rather than on the import.
#if os(iOS)
import ActivityKit

/// What the Lock Screen and Dynamic Island show during an event.
///
/// This lives in the shared package rather than in either target because the
/// app writes it and the widget extension reads it, and a mismatch between two
/// hand-copied definitions is the classic way Live Activities fail silently in
/// production.
///
/// The content is deliberately spare. Somebody looking at a Lock Screen during
/// an earthquake needs one instruction and one number, and a widget crammed with
/// telemetry is a widget nobody can read while getting under a table.
@available(iOS 16.1, *)
public struct SeismicEventAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable {
        public enum Stage: String, Codable, Hashable {
            case warning            // shaking has not arrived yet
            case shaking
            case measuring
            case assessed

            public var headline: String {
                switch self {
                case .warning: "Earthquake detected"
                case .shaking: "Shaking now"
                case .measuring: "Measuring the building"
                case .assessed: "Assessment ready"
                }
            }

            public var instruction: String {
                switch self {
                case .warning: "Drop, cover, hold on"
                case .shaking: "Stay down until it stops"
                case .measuring: "Stay outside while this finishes"
                case .assessed: "Open Seismic for the detail"
                }
            }

            public var systemImage: String {
                switch self {
                case .warning: "exclamationmark.triangle.fill"
                case .shaking: "waveform.path.ecg"
                case .measuring: "gauge.with.needle"
                case .assessed: "checkmark.shield.fill"
                }
            }
        }

        public var stage: Stage
        /// Seconds until strong shaking arrives, while that is still ahead.
        public var secondsUntilShaking: Int?
        public var estimatedMagnitude: Double?
        public var intensityLabel: String?
        /// Populated once there is a verdict.
        public var verdict: SafetyVerdict?
        public var actuatorsFired: Int
        public var actuatorsConfirmed: Int
        public var isDrill: Bool

        public init(stage: Stage, secondsUntilShaking: Int? = nil,
                    estimatedMagnitude: Double? = nil, intensityLabel: String? = nil,
                    verdict: SafetyVerdict? = nil, actuatorsFired: Int = 0,
                    actuatorsConfirmed: Int = 0, isDrill: Bool = false) {
            self.stage = stage
            self.secondsUntilShaking = secondsUntilShaking
            self.estimatedMagnitude = estimatedMagnitude
            self.intensityLabel = intensityLabel
            self.verdict = verdict
            self.actuatorsFired = actuatorsFired
            self.actuatorsConfirmed = actuatorsConfirmed
            self.isDrill = isDrill
        }

        /// The one line that matters, assembled once so the Lock Screen, the
        /// Dynamic Island and the notification cannot drift apart.
        public var primaryLine: String {
            if let verdict { return verdict.placard }
            if let seconds = secondsUntilShaking, seconds > 0 { return "\(seconds) s" }
            return stage.headline
        }
    }

    public var buildingName: String
    public var startedAt: Date

    public init(buildingName: String, startedAt: Date) {
        self.buildingName = buildingName
        self.startedAt = startedAt
    }
}
#endif

/// The small slice of state a home-screen widget needs.
///
/// Written by the app into the shared container after every change, read by the
/// widget's timeline provider. Kept to a handful of fields on purpose: a widget
/// that decodes the whole store would be slow to refresh and would break
/// whenever the store's schema moved.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public var buildingName: String
    public var verdict: SafetyVerdict?
    public var assessedAt: Date?
    public var periodSeconds: Double?
    public var periodChangePercent: Double?
    public var isNodeConnected: Bool
    public var isSimulated: Bool
    public var lastEventAt: Date?
    public var updatedAt: Date

    public init(buildingName: String, verdict: SafetyVerdict? = nil, assessedAt: Date? = nil,
                periodSeconds: Double? = nil, periodChangePercent: Double? = nil,
                isNodeConnected: Bool = false, isSimulated: Bool = true,
                lastEventAt: Date? = nil, updatedAt: Date = Date()) {
        self.buildingName = buildingName
        self.verdict = verdict
        self.assessedAt = assessedAt
        self.periodSeconds = periodSeconds
        self.periodChangePercent = periodChangePercent
        self.isNodeConnected = isNodeConnected
        self.isSimulated = isSimulated
        self.lastEventAt = lastEventAt
        self.updatedAt = updatedAt
    }

    /// Shown before any real data exists, so a freshly-added widget has
    /// something honest on it rather than a blank rectangle.
    public static let placeholder = WidgetSnapshot(
        buildingName: "Your building",
        verdict: .green,
        assessedAt: Date(),
        periodSeconds: 0.91,
        periodChangePercent: 0.4,
        isNodeConnected: true,
        isSimulated: true)
}

/// Where the app and its widget meet.
///
/// One app group, one file, one type. The reader tolerates every failure —
/// no container, no file, unreadable JSON — by returning the placeholder,
/// because a widget that shows an error is worse than one that shows a
/// plausible default and refreshes a minute later.
public enum WidgetBridge {
    public static let appGroup = "group.app.seismic.ios"
    private static let filename = "widget-snapshot.json"

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    public static func write(_ snapshot: WidgetSnapshot) {
        guard let url = containerURL?.appendingPathComponent(filename) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func read() -> WidgetSnapshot {
        guard let url = containerURL?.appendingPathComponent(filename),
              let data = try? Data(contentsOf: url) else { return .placeholder }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(WidgetSnapshot.self, from: data)) ?? .placeholder
    }
}
