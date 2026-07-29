import Foundation
import Combine
import SeismicCore
import SeismicDevice

/// The live data from the node, published on its own object.
///
/// This exists because of what it costs when it does not. The node snapshot is
/// replaced twenty times a second. While it lived on `AppEnvironment` — which
/// nineteen views observe — every one of those views was invalidated twenty
/// times a second, whether or not it displayed a single sample. The map, the
/// library, the settings screen and the whole onboarding flow were all being
/// re-evaluated at 20 Hz to draw data none of them show.
///
/// SwiftUI's dependency tracking is per *object*, not per property: observing
/// `AppEnvironment` means observing every `@Published` on it. So the fix is not
/// a smarter view, it is a smaller object. Only the four screens that draw live
/// motion observe this one.
///
/// One line of the node's console. Lives here rather than on `AppEnvironment`
/// because the log it belongs to moved here with the rest of the stream.
struct LogLine: Identifiable {
    let id = UUID()
    let text: String
    let at: Date
}

/// Everything here is main-actor state written from the display tick.
@MainActor
final class NodeStream: ObservableObject {

    /// The most recent buffered window. Replaced wholesale each tick.
    @Published private(set) var snapshot: NodeSession.Snapshot?

    /// Newest first, capped. A log that grows without limit is a leak with a
    /// user interface.
    @Published private(set) var log: [LogLine] = []

    @Published private(set) var discovered: [DiscoveredNode] = []

    @Published private(set) var lastSelfTest: SelfTestResult?

    /// A monotonic counter of received snapshots.
    ///
    /// Views that cache expensive derived work key it on this rather than on
    /// the snapshot itself, because `NodeSession.Snapshot` holds arrays of
    /// thousands of samples and comparing two of them for equality costs more
    /// than the work being avoided.
    @Published private(set) var revision: Int = 0

    var isStreaming: Bool { (snapshot?.recent.count ?? 0) > 0 }

    /// Ticks received but not published, so the interface updates at half the
    /// rate the physics runs at.
    private var pending = 0

    func update(_ snapshot: NodeSession.Snapshot) {
        // The node is integrated at 20 Hz because the physics needs it. The
        // interface does not: publishing at that rate means every observing
        // view re-renders twenty times a second, and each of those redraws a
        // Canvas that rescans the whole window. Ten updates a second is still
        // visually continuous — a seismograph trace cannot meaningfully change
        // faster than the eye resolves — and halves everything downstream.
        pending += 1
        guard pending >= 2 else { return }
        pending = 0

        self.snapshot = snapshot
        revision &+= 1
    }

    func append(_ text: String) {
        log.insert(LogLine(text: text, at: Date()), at: 0)
        if log.count > 200 { log.removeLast(log.count - 200) }
    }

    func record(_ node: DiscoveredNode) {
        discovered.removeAll { $0.id == node.id }
        discovered.append(node)
    }

    func recordSelfTest(_ result: SelfTestResult) { lastSelfTest = result }

    /// Clears the buffered view of the world.
    ///
    /// Called when a transport is swapped, so the trace from a node that is no
    /// longer attached cannot be mistaken for the new one's.
    func reset() {
        snapshot = nil
        discovered = []
        revision &+= 1
    }
}
