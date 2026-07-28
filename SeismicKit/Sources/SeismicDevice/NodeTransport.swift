import Foundation
import SeismicCore

/// What the app sees of a node, real or simulated.
///
/// The simulated node implements this identically to the Bluetooth one, which is
/// the single most important architectural decision in the device layer: every
/// screen, every state machine and every test is written against this protocol,
/// so nothing in the app can tell the difference — and nothing in the app can
/// quietly depend on hardware being present.
public protocol NodeTransport: AnyObject, Sendable {
    var identifier: String { get }
    var displayName: String { get }
    var isSimulated: Bool { get }

    /// Events the transport pushes upward.
    var eventHandler: (@Sendable (NodeEvent) -> Void)? { get set }

    func startScanning()
    func stopScanning()
    func connect(to nodeID: String)
    func disconnect()
    func send(_ command: NodeCommand)
}

/// Everything a node can tell the app.
public enum NodeEvent: Sendable {
    case discovered(DiscoveredNode)
    case connectionChanged(ConnectionState)
    case telemetry(NodeTelemetry)
    case highRate(HighRateBatch)
    case triggered(ratio: Double, channel: SensorChannel, at: Date)
    case sensorVote(SensorVote)
    case actuatorReport(ActuatorReport)
    case recordingManifest(RecordingManifest)
    case recordingChunk(RecordingChunk)
    case fault(NodeFault)
    case selfTestResult(SelfTestResult)
    case periodMeasured(period: Double, confidence: Double, temperature: Double)
    case rfidTap(tag: String, at: Date)
    case log(String)
}

public struct SelfTestResult: Sendable, Equatable {
    public struct Check: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        public var passed: Bool
        public var detail: String
        public init(name: String, passed: Bool, detail: String) {
            self.name = name; self.passed = passed; self.detail = detail
        }
    }

    public var checks: [Check]
    public var passed: Bool { checks.allSatisfy(\.passed) }
    public var failedChecks: [Check] { checks.filter { !$0.passed } }

    public init(checks: [Check]) { self.checks = checks }

    public var summary: String {
        passed
            ? "All \(checks.count) checks passed. The node is ready."
            : "\(failedChecks.count) of \(checks.count) checks failed: "
                + failedChecks.map(\.name).joined(separator: ", ") + "."
    }
}
