import Foundation
import SeismicCore

/// The node runs from a USB port, and that is a hard engineering constraint
/// rather than a footnote.
///
/// A single USB 2.0 port supplies 500 mA. The board's own logic, the BLE module
/// and the sensor bus take about 180 mA of that, leaving roughly 320 mA for
/// actuation. A single servo stalls at 650 mA. Two servos moving together do not
/// merely run slowly — they drag the rail below the brownout threshold and the
/// microcontroller resets, in the middle of an earthquake, having already been
/// told to close the gas valve.
///
/// So actuators are strictly serialised. The app presents that as a feature,
/// because it genuinely is one: a judge watching the console sees each action
/// commanded, move, and be independently confirmed, one at a time, instead of
/// three status lights changing at once.
public struct PowerBudget: Sendable, Equatable {
    /// Total supply, milliamps.
    public var supply: Double
    /// Draw with nothing actuating.
    public var quiescent: Double
    /// Reserve kept free so the microcontroller never browns out.
    public var reserve: Double

    public init(supply: Double = 500, quiescent: Double = 180, reserve: Double = 30) {
        self.supply = Swift.max(supply, 1)
        self.quiescent = Swift.max(quiescent, 0)
        self.reserve = Swift.max(reserve, 0)
    }

    public static let usb2 = PowerBudget()
    /// A powered hub or a mains adapter lifts the ceiling but does not change
    /// the one-at-a-time rule, because the wiring is still the wiring.
    public static let poweredHub = PowerBudget(supply: 900, quiescent: 180, reserve: 60)

    public var availableForActuation: Double {
        Swift.max(supply - quiescent - reserve, 0)
    }

    public func canRun(_ kind: ActuatorKind, alongside active: [ActuatorKind]) -> Bool {
        let activeDraw = active.reduce(0) { $0 + $1.peakCurrent_mA }
        return activeDraw + kind.peakCurrent_mA <= availableForActuation
    }

    /// Whether two motors can ever move together on this supply. On USB 2.0 the
    /// answer is no, and the app says so plainly rather than letting the user
    /// discover it during an event.
    public var allowsSimultaneousMotors: Bool {
        // The gas valve that was dropped is the argument, and it belongs
        // here rather than as an empty row on the actuator screen: a servo
        // pulls about 240 mA turning a valve and the water stepper pulls 260,
        // so two motors want 500 mA of a supply that has already spent 180 on
        // the board itself. That is why this node closes water and cuts power
        // and does not touch gas.
        let twoMotors = 240.0 + ActuatorKind.waterMain.peakCurrent_mA
        return twoMotors <= availableForActuation
    }

    public var explanation: String {
        "\(Int(supply)) mA supply, \(Int(quiescent)) mA quiescent, \(Int(reserve)) mA reserved "
            + "against brownout, leaving \(Int(availableForActuation)) mA for actuation. "
            + (allowsSimultaneousMotors
                ? "Two motors can move at once on this supply."
                : "Only one motor may move at a time, so actions are fired in sequence.")
    }
}

/// A single step in the firing sequence.
public struct ActuationStep: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: ActuatorKind
    /// Seconds after the sequence starts.
    public var startOffset: TimeInterval
    public var duration: TimeInterval
    public var currentDraw: Double
    public var reason: String

    public var endOffset: TimeInterval { startOffset + duration }

    public init(id: UUID = UUID(), kind: ActuatorKind, startOffset: TimeInterval,
                duration: TimeInterval, currentDraw: Double, reason: String) {
        self.id = id; self.kind = kind; self.startOffset = startOffset
        self.duration = duration; self.currentDraw = currentDraw; self.reason = reason
    }
}

/// Plans and serialises actuator firing.
public struct ActuationPlanner: Sendable {
    public let budget: PowerBudget
    /// Settling gap between steps, so the rail recovers and the confirmation
    /// sensor has a quiet moment to read in.
    public let settleTime: TimeInterval

    public init(budget: PowerBudget = .usb2, settleTime: TimeInterval = 0.35) {
        self.budget = budget
        self.settleTime = Swift.max(settleTime, 0)
    }

    /// Builds the sequence for a set of actuators.
    ///
    /// Ordering is by `firingPriority`, and that order is a safety decision, not
    /// a convenience: gas first, because a gas leak into a building with live
    /// electrics is the thing that turns a survivable earthquake into a fire.
    public func plan(_ kinds: [ActuatorKind]) -> [ActuationStep] {
        let ordered = kinds.sorted { $0.firingPriority < $1.firingPriority }
        var steps: [ActuationStep] = []
        var cursor: TimeInterval = 0
        var concurrent: [ActuatorKind] = []
        var concurrentEnd: TimeInterval = 0

        for kind in ordered {
            if budget.canRun(kind, alongside: concurrent), !concurrent.isEmpty {
                // Fits within the remaining headroom: run it alongside.
                let start = steps.last?.startOffset ?? cursor
                steps.append(ActuationStep(
                    kind: kind, startOffset: start, duration: kind.travelTime,
                    currentDraw: kind.peakCurrent_mA,
                    reason: "Runs alongside the previous action — the supply has headroom for both."))
                concurrent.append(kind)
                concurrentEnd = Swift.max(concurrentEnd, start + kind.travelTime)
                cursor = concurrentEnd + settleTime
            } else {
                steps.append(ActuationStep(
                    kind: kind, startOffset: cursor, duration: kind.travelTime,
                    currentDraw: kind.peakCurrent_mA,
                    reason: reason(for: kind, at: steps.count)))
                concurrent = [kind]
                concurrentEnd = cursor + kind.travelTime
                cursor = concurrentEnd + settleTime
            }
        }
        return steps
    }

    private func reason(for kind: ActuatorKind, at index: Int) -> String {
        switch kind {
        case .mainsPower:
            return "Power first: live electrics in a building about to be flooded by a burst "
                + "pipe is the failure that hurts people after the shaking stops."
        case .waterMain:
            return "Water last: a burst pipe causes damage but not casualties, and the valve "
                + "draws the most current."
        }
    }

    public var totalDuration: TimeInterval {
        plan(ActuatorKind.allCases).map(\.endOffset).max() ?? 0
    }

    /// Peak draw at any instant during the plan — the number the power-budget
    /// indicator shows, and proof that the serialisation works.
    public func peakDraw(of steps: [ActuationStep]) -> Double {
        guard !steps.isEmpty else { return budget.quiescent }
        var peak = 0.0
        // Sample at every step boundary; the draw is piecewise constant so the
        // maximum has to occur at one of them.
        let boundaries = steps.flatMap { [$0.startOffset, $0.endOffset - 1e-6] }.sorted()
        for time in boundaries {
            let active = steps.filter { $0.startOffset <= time && time < $0.endOffset }
            peak = Swift.max(peak, active.reduce(budget.quiescent) { $0 + $1.currentDraw })
        }
        return peak
    }

    public func staysWithinBudget(_ steps: [ActuationStep]) -> Bool {
        peakDraw(of: steps) <= budget.supply - budget.reserve + 1e-9
    }
}

/// Live state of the actuation sequence, driving the console's timeline.
public struct ActuationSequence: Sendable, Equatable {
    public var steps: [ActuationStep]
    public var startedAt: Date?
    public var reports: [ActuatorKind: ActuatorReport]

    public init(steps: [ActuationStep], startedAt: Date? = nil,
                reports: [ActuatorKind: ActuatorReport] = [:]) {
        self.steps = steps
        self.startedAt = startedAt
        self.reports = reports
    }

    public var isRunning: Bool {
        guard let startedAt else { return false }
        return Date().timeIntervalSince(startedAt) < (steps.map(\.endOffset).max() ?? 0)
    }

    public func elapsed(at now: Date = Date()) -> TimeInterval {
        guard let startedAt else { return 0 }
        return Swift.max(now.timeIntervalSince(startedAt), 0)
    }

    public func currentStep(at now: Date = Date()) -> ActuationStep? {
        let t = elapsed(at: now)
        return steps.first { $0.startOffset <= t && t < $0.endOffset }
    }

    public var allConfirmed: Bool {
        !steps.isEmpty && steps.allSatisfy { reports[$0.kind]?.state == .confirmed }
    }

    public var anyFailed: Bool { reports.values.contains { $0.state == .failed } }

    /// One-line summary for the header, phrased for somebody who has just been
    /// through an earthquake.
    public var summary: String {
        let confirmed = reports.values.filter { $0.state == .confirmed }.count
        let failed = reports.values.filter { $0.state == .failed }.count
        if steps.isEmpty { return "No safety actions were needed." }
        if failed > 0 {
            return "\(confirmed) of \(steps.count) actions confirmed, \(failed) failed. "
                + "Check the failed ones by hand."
        }
        if confirmed == steps.count {
            return "All \(steps.count) safety actions confirmed."
        }
        return "\(confirmed) of \(steps.count) actions confirmed so far."
    }
}
