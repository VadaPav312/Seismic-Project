import Foundation
import SeismicCore
import SeismicSignal
import SeismicData

/// Measures the building on its own, overnight.
///
/// The whole premise of this app is a comparison: a period today against the
/// same building's period on the same kind of day last winter. That comparison
/// needs history, and history needs somebody to press "Measure now" a few
/// hundred times over a year — which nobody does. The app shipped with a
/// perfectly good `AssessmentEngine.ambientMeasurement`, described in its own
/// documentation as "what runs nightly to build history", and nothing called it.
/// This is the thing that calls it.
///
/// Three conditions have to hold, and all three are about not poisoning the
/// record with a measurement that looks like data and is not:
///
/// 1. **The hour.** Between one and five in the morning by default, when lifts
///    are still, plant is off and nobody is walking about. Ambient measurement
///    reads whatever is exciting the structure; during the day that is mostly
///    the building's occupants, which is not the building.
/// 2. **The noise floor.** The hour is only a proxy, so it is checked against
///    the actual RMS. A generator running at three in the morning has to
///    disqualify the night, and only the measurement itself can know that.
/// 3. **Agreement.** Three independent period estimates are already
///    cross-checked; if they disagree, the answer is thrown away rather than
///    averaged. One bad night in the regression is worse than a missing night,
///    because a missing night is visibly missing.
@MainActor
final class BaselineScheduler: ObservableObject {

    /// Whether to measure automatically at all. Off is a legitimate choice —
    /// somebody on a phone sensor may not want it waking the accelerometer
    /// nightly — so it is a setting rather than an assumption.
    ///
    /// Plain `UserDefaults` behind a `@Published`, not `@AppStorage`: that
    /// property wrapper does not publish from inside an observable object, so a
    /// toggle bound to it appears to do nothing until the next launch. The same
    /// trap is documented on `TutorialDirector.didComplete`.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    /// The quiet window, as hours of the local day.
    @Published var startHour: Int {
        didSet { UserDefaults.standard.set(startHour, forKey: Self.startKey) }
    }
    @Published var endHour: Int {
        didSet { UserDefaults.standard.set(endHour, forKey: Self.endKey) }
    }

    private static let enabledKey = "autoBaselineEnabled"
    private static let startKey = "autoBaselineStartHour"
    private static let endKey = "autoBaselineEndHour"

    init() {
        let defaults = UserDefaults.standard
        // Defaults on a fresh install, rather than the zeros `integer(forKey:)`
        // would otherwise give — a window of 00:00 to 00:00 is no window at all.
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        startHour = defaults.object(forKey: Self.startKey) as? Int ?? 1
        endHour = defaults.object(forKey: Self.endKey) as? Int ?? 5
    }

    /// When the last automatic measurement was taken and what it said. Shown on
    /// screen so an automatic process is never invisible — a thing that
    /// silently writes to your building's record should be able to show you
    /// what it wrote.
    @Published private(set) var lastAttempt: Attempt?
    @Published private(set) var recentAttempts: [Attempt] = []

    struct Attempt: Identifiable, Equatable {
        let id = UUID()
        var at: Date
        var outcome: Outcome

        enum Outcome: Equatable {
            case recorded(period: Double, agreement: Double, temperature: Double?)
            case skipped(reason: String)

            var isRecorded: Bool { if case .recorded = self { return true }; return false }

            var label: String {
                switch self {
                case .recorded(let period, _, _):
                    String(format: "Measured %.3f s", period)
                case .skipped(let reason):
                    reason
                }
            }
        }
    }

    /// A rolling estimate of what quiet actually is for this building.
    ///
    /// Not a fixed threshold: a timber house on a side street and a tower over
    /// a motorway have noise floors an order of magnitude apart, and a constant
    /// that suits one would either measure the other during rush hour or never
    /// measure it at all. So "quiet" means quiet *for here* — at or near the
    /// lowest RMS this building has been seen at.
    private var quietestSeen: Double = .greatestFiniteMagnitude
    private var lastRecordedAt: Date?
    private var lastCheckedAt = Date.distantPast

    /// How long to leave between automatic measurements. Once a night is the
    /// intent; four hours is the guard, so a phone that is opened at 01:00 and
    /// again at 04:00 does not write two entries for the same night.
    private let minimumInterval: TimeInterval = 4 * 3600

    /// How often to even consider it. Called from the 20 Hz display tick, which
    /// is far too often to do anything real on.
    private let checkInterval: TimeInterval = 60

    // MARK: The tick

    /// Called from the app's display tick. Cheap unless it is actually time.
    func consider(environment: AppEnvironment, now: Date = Date()) {
        guard isEnabled else { return }
        guard now.timeIntervalSince(lastCheckedAt) >= checkInterval else { return }
        lastCheckedAt = now

        // Track the noise floor whenever the app is running, day or night. It
        // is the daytime samples that establish what quiet is *not*.
        if let rms = environment.node.snapshot?.telemetry.ambientVibrationRMS, rms > 0 {
            quietestSeen = min(quietestSeen, rms)
        }

        guard let reason = blockingReason(environment: environment, now: now) else {
            measure(environment: environment, now: now)
            return
        }
        // Skips are not recorded. A list of two hundred "not the right hour"
        // entries buries the one that says the building was too noisy all week,
        // which is the only skip anybody needs to see.
        _ = reason
    }

    /// Why it is not measuring, or nil when it should.
    private func blockingReason(environment: AppEnvironment, now: Date) -> String? {
        if environment.activeEvent != nil {
            return "An event is in progress."
        }
        guard environment.connectionState.isLive else {
            return "No sensor is connected."
        }
        guard isWithinQuietHours(now) else {
            return "Outside the quiet hours."
        }
        if let last = lastRecordedAt, now.timeIntervalSince(last) < minimumInterval {
            return "Already measured tonight."
        }
        guard let snapshot = environment.node.snapshot else {
            return "No data yet."
        }
        // Enough buffered signal for a spectrum worth taking a peak off.
        guard snapshot.recent.count > 2_048 else {
            return "Not enough data buffered."
        }
        guard snapshot.telemetry.state == .monitoring || snapshot.telemetry.state == .armed else {
            return "The sensor is busy."
        }
        // Quiet for this building, not quiet in the abstract. The 2.5× allows
        // for a normal night rather than demanding the quietest night ever
        // recorded, which would only ever be met once.
        if quietestSeen < .greatestFiniteMagnitude,
           snapshot.telemetry.ambientVibrationRMS > quietestSeen * 2.5 {
            return "The building is not quiet enough right now."
        }
        return nil
    }

    func isWithinQuietHours(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        // Wraps around midnight, which the obvious comparison does not: a
        // window of 23:00–05:00 is every hour that is either ≥ 23 or < 5.
        return startHour <= endHour
            ? (hour >= startHour && hour < endHour)
            : (hour >= startHour || hour < endHour)
    }

    // MARK: Measuring

    private func measure(environment: AppEnvironment, now: Date) {
        guard let building = environment.selectedBuilding else { return }

        let band = (building.empiricalPeriod * 0.35)...(building.empiricalPeriod * 3.5)
        // Plant noise is cancelled before the period is picked off.
        //
        // An overnight measurement runs unattended in a building whose lift,
        // chiller and transformer nobody characterised, and each of those puts
        // a line into the spectrum that a peak picker will happily mistake for
        // a mode. The vertical channel is the reference: plant shakes a floor
        // in every direction, while a building sways horizontally — so
        // whatever is common to both is the machinery and not the structure.
        let cleaned = denoisedRecord(environment)
        let result = cleaned.map { environment.session.measurePeriod(of: $0, band: band) }
            ?? environment.session.measurePeriodFromAmbient(band: band)

        guard let period = result.consensus, period > 0 else {
            record(Attempt(at: now, outcome: .skipped(
                reason: "No period could be picked out of the noise.")))
            return
        }

        // The three estimates have to agree. This is the same bar the manual
        // path uses, and it is the reason an automatic measurement can be
        // trusted to write to the record without a human looking at it.
        guard result.agreement >= 0.6 else {
            record(Attempt(at: now, outcome: .skipped(
                reason: String(format: "The three estimates only agreed to %.0f%%.",
                               result.agreement * 100))))
            return
        }

        // Temperature is the point of the whole exercise — it is what the
        // regression corrects for — so a measurement without one is recorded
        // *with no temperature* rather than with a plausible number. A phone
        // has no thermometer against the structure; see `PhoneSensorTransport`.
        let temperature: Double? = environment.sensorSource == .phone
            ? nil
            : environment.node.snapshot?.telemetry.structureTemperature

        let observation = ModeObservation(modeNumber: 1, frequency: 1 / period,
                                          amplitude: 1, at: now, temperature: temperature)
        environment.store.append([observation])
        environment.refresh()
        lastRecordedAt = now
        record(Attempt(at: now, outcome: .recorded(period: period,
                                                   agreement: result.agreement,
                                                   temperature: temperature)))
    }

    /// The horizontal channel with plant noise adaptively removed, or nil when
    /// the cancellation could not run or removed so much that it is more likely
    /// to have taken the building with it.
    ///
    /// That second guard is the important one. An adaptive filter given a
    /// reference that shares content with the signal will cheerfully cancel the
    /// signal, and the output looks *cleaner* than the input — which is exactly
    /// what a broken measurement looks like from the outside. Half the energy
    /// is far more than any plant should account for, so above that the result
    /// is discarded and the raw channel used.
    private func denoisedRecord(_ environment: AppEnvironment) -> Waveform? {
        let record = environment.session.bufferedRecord()
        guard record.count > 2_048 else { return nil }

        let horizontal = record.dominantHorizontal
        guard let result = AdaptiveNoiseCancellation.cancel(
            primary: horizontal.samples, reference: record.z.samples,
            taps: 32, stepSize: 0.05) else { return nil }

        guard result.fractionRemoved < 0.5 else { return nil }
        return Waveform(samples: result.cleaned, sampleRate: horizontal.sampleRate,
                        startTime: horizontal.startTime, unit: horizontal.unit)
    }

    private func record(_ attempt: Attempt) {
        lastAttempt = attempt
        recentAttempts.insert(attempt, at: 0)
        if recentAttempts.count > 14 { recentAttempts.removeLast() }
    }

    // MARK: Demonstrating it

    /// Runs the measurement now, ignoring the hour and the noise floor.
    ///
    /// Present because a feature that only ever happens at three in the morning
    /// is a feature nobody can be shown, and one nobody can be shown is one
    /// nobody believes. It says on screen that it bypassed the checks.
    func measureNow(environment: AppEnvironment) {
        lastRecordedAt = nil
        measure(environment: environment, now: Date())
    }

    /// A plain sentence about where the history stands, for the Monitor screen.
    func historySummary(observationCount: Int) -> String {
        guard isEnabled else {
            return "Automatic measurement is off. The temperature correction can only use "
                + "the measurements you take by hand."
        }
        let window = "\(String(format: "%02d:00", startHour))–\(String(format: "%02d:00", endHour))"
        if observationCount == 0 {
            return "Nothing recorded yet. The first automatic measurement will be taken "
                + "between \(window), when the building is quiet."
        }
        return "\(observationCount) measurements on record. One more is taken each night "
            + "between \(window), whenever the building is quiet enough to be worth "
            + "measuring."
    }
}
