import Foundation
import SeismicCore

// Algorithms 9–14. Deciding that something is happening, deciding exactly when
// it started, and deciding whether to believe it.

// MARK: - 9 & 10. STA/LTA triggering

/// The output of a trigger run, kept in full so the Monitor screen can plot the
/// ratio underneath the trace rather than just flashing a light.
public struct TriggerResult: Sendable, Equatable {
    public var ratio: Waveform
    public var triggeredAt: [Double]      // seconds from record start
    public var detriggeredAt: [Double]
    public var peakRatio: Double
    public var peakRatioTime: Double

    public init(ratio: Waveform, triggeredAt: [Double], detriggeredAt: [Double],
                peakRatio: Double, peakRatioTime: Double) {
        self.ratio = ratio
        self.triggeredAt = triggeredAt
        self.detriggeredAt = detriggeredAt
        self.peakRatio = peakRatio
        self.peakRatioTime = peakRatioTime
    }

    public var didTrigger: Bool { !triggeredAt.isEmpty }
}

public struct STALTAConfig: Sendable, Equatable, Codable {
    /// Short window, seconds. Long enough to average out a single sample of
    /// noise, short enough to respond within a fraction of a second.
    public var shortWindow: Double
    /// Long window, seconds. This is the running estimate of "normal".
    public var longWindow: Double
    /// Ratio at which an event is declared.
    public var triggerThreshold: Double
    /// Ratio at which it is declared over. Lower than the trigger, so a wobbling
    /// ratio does not produce a burst of separate events.
    public var detriggerThreshold: Double

    public init(shortWindow: Double = 0.5, longWindow: Double = 10,
                triggerThreshold: Double = 4.0, detriggerThreshold: Double = 1.8) {
        self.shortWindow = Swift.max(shortWindow, 0.01)
        // Note: clamp against the *clamped* short window, not the raw argument —
        // otherwise a negative short window lets the long window end up shorter
        // than it, and the ratio inverts.
        self.longWindow = Swift.max(longWindow, self.shortWindow * 2)
        self.triggerThreshold = Swift.max(triggerThreshold, 1.05)
        self.detriggerThreshold = Swift.min(Swift.max(detriggerThreshold, 1.0), triggerThreshold * 0.95)
    }

    public static let standard = STALTAConfig()
    /// For a noisy urban site where lorries pass all day.
    public static let conservative = STALTAConfig(shortWindow: 0.6, longWindow: 20,
                                                  triggerThreshold: 6.0, detriggerThreshold: 2.2)
    /// For a quiet site where the earliest possible warning matters most.
    public static let sensitive = STALTAConfig(shortWindow: 0.3, longWindow: 8,
                                               triggerThreshold: 3.0, detriggerThreshold: 1.5)

    public var label: String {
        switch triggerThreshold {
        case ..<3.5: "Sensitive"
        case 3.5..<5.0: "Standard"
        default: "Conservative"
        }
    }
}

public enum STALTA {

    /// Algorithm 9 — classic windowed STA/LTA.
    ///
    /// Compares energy in the last fraction of a second against energy over the
    /// last several seconds. It is the standard because it is scale-free: it
    /// triggers on a change relative to the local background, so the same
    /// settings work in a quiet basement and beside a motorway.
    public static func classic(_ w: Waveform, config: STALTAConfig = .standard) -> TriggerResult {
        let n = w.count
        let shortN = Swift.max(Int(config.shortWindow * w.sampleRate), 1)
        let longN = Swift.max(Int(config.longWindow * w.sampleRate), shortN + 1)
        guard n > longN else {
            return TriggerResult(ratio: Waveform(samples: [Double](repeating: 1, count: n),
                                                 sampleRate: w.sampleRate,
                                                 startTime: w.startTime, unit: .dimensionless),
                                 triggeredAt: [], detriggeredAt: [], peakRatio: 1, peakRatioTime: 0)
        }

        // Characteristic function: squared amplitude of the demeaned signal.
        let demeaned = Detrend.removeDCOffset(w.samples)
        let cf = demeaned.map { $0 * $0 }

        // Prefix sums make both windows O(1) per sample instead of O(window).
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + cf[i] }

        var ratio = [Double](repeating: 1, count: n)
        for i in longN..<n {
            let sta = (prefix[i + 1] - prefix[i + 1 - shortN]) / Double(shortN)
            let lta = (prefix[i + 1] - prefix[i + 1 - longN]) / Double(longN)
            ratio[i] = lta > 1e-20 ? sta / lta : 1
        }

        return evaluate(ratio: ratio, w: w, config: config)
    }

    /// Algorithm 10 — recursive STA/LTA.
    ///
    /// Same idea, exponential averages instead of windows. Constant memory and
    /// three multiplies per sample, which is what actually runs on the node's
    /// microcontroller continuously for months.
    public static func recursive(_ w: Waveform, config: STALTAConfig = .standard) -> TriggerResult {
        let n = w.count
        guard n > 4 else {
            return TriggerResult(ratio: Waveform(samples: [Double](repeating: 1, count: n),
                                                 sampleRate: w.sampleRate,
                                                 startTime: w.startTime, unit: .dimensionless),
                                 triggeredAt: [], detriggeredAt: [], peakRatio: 1, peakRatioTime: 0)
        }
        let demeaned = Detrend.removeDCOffset(w.samples)
        let cf = demeaned.map { $0 * $0 }

        let alphaS = 1 - exp(-1 / (config.shortWindow * w.sampleRate))
        let alphaL = 1 - exp(-1 / (config.longWindow * w.sampleRate))

        // Seed both averages from the first long-window's worth of data so the
        // ratio does not start at a meaningless value.
        let seedCount = Swift.min(Int(config.longWindow * w.sampleRate), n)
        var sta = Stats.mean(Array(cf[0..<seedCount]))
        var lta = sta
        var ratio = [Double](repeating: 1, count: n)

        var state = RecursiveState(sta: sta, lta: lta)
        for i in 0..<n {
            state.update(cf[i], alphaShort: alphaS, alphaLong: alphaL)
            ratio[i] = state.ratio
        }
        sta = state.sta; lta = state.lta
        return evaluate(ratio: ratio, w: w, config: config)
    }

    /// The streaming form, for live data arriving a sample at a time. This is
    /// the exact arithmetic the node performs, mirrored here so the simulated
    /// node and the real one produce identical ratios.
    public struct RecursiveState: Sendable, Equatable {
        public var sta: Double
        public var lta: Double
        /// The long average is frozen while triggered, so the event itself does
        /// not inflate "normal" and detrigger the detector prematurely.
        public var freezeLongAverage = false

        public init(sta: Double = 0, lta: Double = 1e-12) { self.sta = sta; self.lta = lta }

        public mutating func update(_ characteristic: Double,
                                    alphaShort: Double, alphaLong: Double) {
            sta += alphaShort * (characteristic - sta)
            if !freezeLongAverage { lta += alphaLong * (characteristic - lta) }
        }

        public var ratio: Double { lta > 1e-20 ? sta / lta : 1 }
    }

    /// Shared trigger/detrigger state machine, with hysteresis.
    private static func evaluate(ratio: [Double], w: Waveform,
                                 config: STALTAConfig) -> TriggerResult {
        var triggers: [Double] = [], detriggers: [Double] = []
        var armed = false
        var peak = 0.0, peakTime = 0.0

        for (i, r) in ratio.enumerated() {
            if r > peak { peak = r; peakTime = w.time(at: i) }
            if !armed, r >= config.triggerThreshold {
                armed = true
                triggers.append(w.time(at: i))
            } else if armed, r <= config.detriggerThreshold {
                armed = false
                detriggers.append(w.time(at: i))
            }
        }
        if armed { detriggers.append(w.duration) }

        return TriggerResult(
            ratio: Waveform(samples: ratio, sampleRate: w.sampleRate,
                            startTime: w.startTime, unit: .dimensionless),
            triggeredAt: triggers, detriggeredAt: detriggers,
            peakRatio: peak, peakRatioTime: peakTime)
    }
}

// MARK: - 11. AIC picker

public enum ArrivalPicker {

    /// Algorithm 11 — Akaike Information Criterion P-wave picker.
    ///
    /// A threshold tells you an event happened; it does not tell you when it
    /// started, because by the time the amplitude is above threshold the wave
    /// has already been arriving for some time. AIC finds the sample that best
    /// divides the trace into "noise" and "signal", treating each half as its
    /// own autoregressive process. It routinely lands within a couple of samples
    /// of the true onset, which is what makes an S−P distance estimate worth
    /// computing at all.
    public static func aicPick(_ x: [Double]) -> (index: Int, confidence: Double, curve: [Double])? {
        let n = x.count
        guard n > 20 else { return nil }

        // Running variance of the prefix and the suffix, both in one pass each.
        var prefixSum = [Double](repeating: 0, count: n + 1)
        var prefixSumSq = [Double](repeating: 0, count: n + 1)
        for i in 0..<n {
            prefixSum[i + 1] = prefixSum[i] + x[i]
            prefixSumSq[i + 1] = prefixSumSq[i] + x[i] * x[i]
        }

        func variance(from a: Int, to b: Int) -> Double {
            let count = Double(b - a)
            guard count > 1 else { return 0 }
            let sum = prefixSum[b] - prefixSum[a]
            let sumSq = prefixSumSq[b] - prefixSumSq[a]
            return Swift.max((sumSq - sum * sum / count) / count, 1e-30)
        }

        var aic = [Double](repeating: 0, count: n)
        let margin = 3           // AIC is undefined for a window of one sample
        var best = margin
        var bestValue = Double.infinity

        for k in margin..<(n - margin) {
            let left = Double(k) * log(variance(from: 0, to: k))
            let right = Double(n - k - 1) * log(variance(from: k, to: n))
            let value = left + right
            aic[k] = value
            if value < bestValue { bestValue = value; best = k }
        }
        // Flat ends carry no information; hold them at the neighbouring value so
        // the plotted curve does not have spurious cliffs.
        for k in 0..<margin { aic[k] = aic[margin] }
        for k in (n - margin)..<n { aic[k] = aic[n - margin - 1] }

        // Confidence from how deep the minimum is relative to the curve's range.
        let maxValue = aic.max() ?? bestValue
        let depth = maxValue - bestValue
        let scale = Swift.max(abs(maxValue), 1)
        let confidence = Swift.min(Swift.max(depth / scale, 0), 1)

        return (best, confidence, aic)
    }

    /// Picks a P arrival on a waveform, doing the conditioning the picker needs.
    ///
    /// Two things make this work that a naive application of AIC does not:
    ///
    /// 1. The bandpass. AIC on an unfiltered trace picks whatever the largest
    ///    variance change is, which is often a drift step rather than a wave.
    /// 2. The search window. AIC finds the single best split of whatever it is
    ///    given, so run over a whole record containing a long decaying coda it
    ///    happily picks a point in the middle of the coda instead of the onset.
    ///    Using a coarse STA/LTA trigger to bracket the search first, then
    ///    letting AIC refine within a few seconds either side, is the standard
    ///    arrangement — coarse detector for *whether*, AIC for *exactly when*.
    public static func pickP(_ w: Waveform, searchWindow: ClosedRange<Double>? = nil)
        -> (time: Double, confidence: Double)?
    {
        guard w.count > 32 else { return nil }
        let filtered = ButterworthFilter(kind: .bandpass, order: 4, sampleRate: w.sampleRate,
                                         lowCutoff: 1.0, highCutoff: Swift.min(20, w.sampleRate / 2.5))
            .applyZeroPhase(w.samples)
        let filteredWave = Waveform(samples: filtered, sampleRate: w.sampleRate,
                                    startTime: w.startTime, unit: w.unit)

        let range: ClosedRange<Double>
        if let searchWindow {
            range = searchWindow
        } else if let trigger = STALTA.classic(filteredWave, config: .sensitive).triggeredAt.first {
            range = Swift.max(trigger - 6, 0)...Swift.min(trigger + 3, w.duration)
        } else {
            // Nothing tripped the detector; fall back to the whole record rather
            // than refusing to answer.
            range = 0...w.duration
        }

        let a = w.index(atTime: range.lowerBound)
        let b = Swift.min(Swift.max(w.index(atTime: range.upperBound), a + 20), filtered.count)
        guard b - a > 20 else { return nil }

        guard let pick = aicPick(Array(filtered[a..<b])) else { return nil }
        return (w.time(at: a + pick.index), pick.confidence)
    }
}

// MARK: - 12. S-wave detection by polarisation

public enum PolarisationAnalysis {

    /// Algorithm 12 — find the S arrival from the change in particle motion.
    ///
    /// The P-wave pushes along the direction of travel, so the particle motion
    /// is nearly linear and mostly aligned with one axis. The S-wave shears
    /// across it: the motion becomes transverse and much less linear. Tracking
    /// the rectilinearity of the motion in a sliding window finds that moment
    /// even when the S arrival is buried in the P coda and invisible on any
    /// single channel.
    public static func rectilinearity(_ rec: TriaxialRecord, windowSeconds: Double = 1.0)
        -> Waveform
    {
        let n = rec.count
        let windowN = Swift.max(Int(windowSeconds * rec.sampleRate), 8)
        guard n > windowN else {
            return Waveform(samples: [Double](repeating: 0, count: n),
                            sampleRate: rec.sampleRate, startTime: rec.startTime,
                            unit: .dimensionless)
        }

        let xs = Detrend.removeDCOffset(Array(rec.x.samples[0..<n]))
        let ys = Detrend.removeDCOffset(Array(rec.y.samples[0..<n]))
        let zs = Detrend.removeDCOffset(Array(rec.z.samples[0..<n]))

        var out = [Double](repeating: 0, count: n)
        var i = 0
        while i + windowN <= n {
            let cov = covariance(xs, ys, zs, from: i, to: i + windowN)
            let eig = LinearAlgebra.symmetricEigenvalues3x3(cov)
            // Rectilinearity: 1 when all energy is on one axis, 0 when the
            // motion fills a sphere.
            let l1 = eig[0], l2 = eig[1], l3 = eig[2]
            let value = l1 > 1e-30 ? 1 - (l2 + l3) / (2 * l1) : 0
            for j in i..<Swift.min(i + windowN, n) where out[j] == 0 {
                out[j] = Swift.min(Swift.max(value, 0), 1)
            }
            i += Swift.max(windowN / 4, 1)
        }
        // Fill any tail that the stride did not reach.
        if let lastNonZero = out.lastIndex(where: { $0 != 0 }), lastNonZero + 1 < n {
            for j in (lastNonZero + 1)..<n { out[j] = out[lastNonZero] }
        }

        return Waveform(samples: out, sampleRate: rec.sampleRate,
                        startTime: rec.startTime, unit: .dimensionless)
    }

    private static func covariance(_ x: [Double], _ y: [Double], _ z: [Double],
                                   from a: Int, to b: Int) -> [[Double]] {
        let n = Double(b - a)
        guard n > 1 else { return LinearAlgebra.identity(3) }
        var mx = 0.0, my = 0.0, mz = 0.0
        for i in a..<b { mx += x[i]; my += y[i]; mz += z[i] }
        mx /= n; my /= n; mz /= n

        var cxx = 0.0, cyy = 0.0, czz = 0.0, cxy = 0.0, cxz = 0.0, cyz = 0.0
        for i in a..<b {
            let dx = x[i] - mx, dy = y[i] - my, dz = z[i] - mz
            cxx += dx * dx; cyy += dy * dy; czz += dz * dz
            cxy += dx * dy; cxz += dx * dz; cyz += dy * dz
        }
        return [[cxx / n, cxy / n, cxz / n],
                [cxy / n, cyy / n, cyz / n],
                [cxz / n, cyz / n, czz / n]]
    }

    /// Picks the S arrival: the strongest sustained *drop* in rectilinearity
    /// after the P arrival.
    ///
    /// The search is bounded above by the time of peak ground motion, because
    /// physics says so: the S-wave is the strongest arrival, so it cannot come
    /// after the record's peak. Without that bound the picker drifts into the
    /// coda, where the motion is thoroughly scattered and rectilinearity is low
    /// everywhere — and reports an S−P interval three times too long, which
    /// would put the epicentre in the wrong county.
    public static func pickS(_ rec: TriaxialRecord, afterP pTime: Double)
        -> (time: Double, confidence: Double)?
    {
        let rect = rectilinearity(rec, windowSeconds: 1.0)
        guard rect.count > 8 else { return nil }

        // Smoothed energy envelope, to locate the peak of the shaking.
        let magnitude = rec.magnitude
        let envelopeWindow = Swift.max(Int(0.5 * magnitude.sampleRate), 2)
        var energy = [Double](repeating: 0, count: magnitude.count)
        var running = 0.0
        for i in 0..<magnitude.count {
            running += magnitude.samples[i] * magnitude.samples[i]
            if i >= envelopeWindow {
                running -= magnitude.samples[i - envelopeWindow] * magnitude.samples[i - envelopeWindow]
            }
            energy[i] = running
        }
        let peakEnergyIndex = energy.indices.max { energy[$0] < energy[$1] } ?? (energy.count - 1)
        let peakTime = magnitude.time(at: peakEnergyIndex)

        // Start a little after P so the P coda itself is not picked; stop a
        // little after the peak, since S must precede it.
        let startIndex = rect.index(atTime: pTime + 0.3)
        let endIndex = Swift.min(rect.index(atTime: peakTime + 1.5), rect.count - 1)
        guard endIndex > startIndex + 4 else { return nil }

        // Within that window, the S onset is where the *horizontal* motion
        // steps up. Running the same AIC picker used for P over the horizontal
        // channel finds that step precisely; the rectilinearity is then used to
        // score how confident the pick is, since a genuine S arrival must also
        // scatter the particle motion.
        let horizontal = horizontalMagnitude(rec)
        let filtered = ButterworthFilter(kind: .bandpass, order: 4,
                                         sampleRate: horizontal.sampleRate,
                                         lowCutoff: 0.5,
                                         highCutoff: Swift.min(12, horizontal.sampleRate / 2.5))
            .applyZeroPhase(horizontal.samples)

        let a = horizontal.index(atTime: pTime + 0.3)
        let b = Swift.min(horizontal.index(atTime: peakTime + 1.5), filtered.count - 1)
        guard b > a + 20 else { return nil }

        guard let pick = ArrivalPicker.aicPick(Array(filtered[a...b])) else { return nil }
        let index = a + pick.index
        let sTime = horizontal.time(at: index)

        // Confidence: the AIC minimum's depth, tempered by whether the particle
        // motion actually became less rectilinear across the pick.
        let lookback = Swift.max(Int(1.0 * rect.sampleRate), 2)
        let beforeIndex = Swift.max(index - lookback, 0)
        let rectBefore = Stats.mean(Array(rect.samples[beforeIndex...Swift.min(index, rect.count - 1)]))
        let afterEnd = Swift.min(index + lookback, rect.count - 1)
        let rectAfter = Stats.mean(Array(rect.samples[Swift.min(index, afterEnd)...afterEnd]))
        let scattering = Swift.min(Swift.max((rectBefore - rectAfter) * 4 + 0.4, 0), 1)

        return (sTime, Swift.min(pick.confidence * 0.5 + scattering * 0.5, 1))
    }

    /// Combined horizontal motion — the channel the S-wave dominates.
    public static func horizontalMagnitude(_ rec: TriaxialRecord) -> Waveform {
        let n = rec.count
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let x = rec.x.samples[i], y = rec.y.samples[i]
            out[i] = (x * x + y * y).squareRoot()
        }
        return Waveform(samples: out, sampleRate: rec.sampleRate,
                        startTime: rec.startTime, unit: rec.x.unit)
    }

    /// Full pick of both arrivals, which is what the event replay timeline marks
    /// and what the epicentral distance estimate consumes.
    public static func pickArrivals(_ rec: TriaxialRecord) -> ArrivalPicks {
        var picks = ArrivalPicks()
        // Vertical channel is where P is clearest; horizontals carry S.
        if let p = ArrivalPicker.pickP(rec.z) {
            picks.pTime = p.time
            picks.pConfidence = p.confidence
        } else if let p = ArrivalPicker.pickP(rec.magnitude) {
            picks.pTime = p.time
            picks.pConfidence = p.confidence * 0.8
        }
        if let pTime = picks.pTime, let s = pickS(rec, afterP: pTime) {
            picks.sTime = s.time
            picks.sConfidence = s.confidence
        }
        return picks
    }
}

extension LinearAlgebra {
    /// Eigenvalues of a symmetric 3×3 matrix, descending. Closed form — far
    /// faster and more stable than a general solver at this size, and this runs
    /// in a sliding window over every event record.
    public static func symmetricEigenvalues3x3(_ m: [[Double]]) -> [Double] {
        let p1 = m[0][1] * m[0][1] + m[0][2] * m[0][2] + m[1][2] * m[1][2]
        let diag = [m[0][0], m[1][1], m[2][2]]
        if p1 < 1e-30 { return diag.sorted(by: >) }

        let q = (diag[0] + diag[1] + diag[2]) / 3
        let p2 = (diag[0] - q) * (diag[0] - q) + (diag[1] - q) * (diag[1] - q)
            + (diag[2] - q) * (diag[2] - q) + 2 * p1
        let p = (p2 / 6).squareRoot()
        guard p > 1e-30 else { return diag.sorted(by: >) }

        var b = m
        for i in 0..<3 { for j in 0..<3 { b[i][j] = (m[i][j] - (i == j ? q : 0)) / p } }
        let det = b[0][0] * (b[1][1] * b[2][2] - b[1][2] * b[2][1])
            - b[0][1] * (b[1][0] * b[2][2] - b[1][2] * b[2][0])
            + b[0][2] * (b[1][0] * b[2][1] - b[1][1] * b[2][0])

        let r = Swift.min(Swift.max(det / 2, -1), 1)
        let phi = acos(r) / 3
        let e1 = q + 2 * p * cos(phi)
        let e3 = q + 2 * p * cos(phi + 2 * Double.pi / 3)
        let e2 = 3 * q - e1 - e3
        return [e1, e2, e3].sorted(by: >)
    }
}

// MARK: - 13. Sensor fusion voting

/// Algorithm 13 — weighted multi-channel vote.
///
/// One sensor can be wrong. An accelerometer sees a dropped toolbox; a tilt
/// switch sees somebody leaning on the shelf; a sound sensor hears a door. The
/// three of them being wrong in the same half second, in the same way, is
/// dramatically less likely — which is the entire reason the node has more than
/// one kind of sensor.
public enum SensorFusion {

    public struct Decision: Sendable, Equatable {
        public var accepted: Bool
        public var confidence: Double
        public var agreeing: [SensorChannel]
        public var dissenting: [SensorChannel]
        public var explanation: String
    }

    /// - Parameter requiredConfidence: the weighted fraction that must agree.
    ///   0.6 means the accelerometer alone is not quite enough — it needs one
    ///   corroborating channel.
    public static func vote(_ votes: [SensorVote],
                            requiredConfidence: Double = 0.6) -> Decision {
        let relevant = votes.filter { $0.channel.voteWeight > 0 }
        guard !relevant.isEmpty else {
            return Decision(accepted: false, confidence: 0, agreeing: [], dissenting: [],
                            explanation: "No sensor reported. Nothing to decide on.")
        }

        let total = relevant.reduce(0.0) { $0 + $1.channel.voteWeight }
        let agreeing = relevant.filter(\.agreed)
        let agreedWeight = agreeing.reduce(0.0) { $0 + $1.channel.voteWeight }
        let confidence = total > 0 ? agreedWeight / total : 0
        let accepted = confidence >= requiredConfidence

        let agreeingChannels = agreeing.map(\.channel)
        let dissentingChannels = relevant.filter { !$0.agreed }.map(\.channel)

        let explanation: String
        if accepted && dissentingChannels.isEmpty {
            explanation = "Every sensor agreed."
        } else if accepted {
            explanation = "\(agreeingChannels.count) of \(relevant.count) sensors agreed, "
                + "carrying \(Int(confidence * 100))% of the decision weight."
        } else if agreeingChannels.isEmpty {
            explanation = "No sensor agreed this was an earthquake."
        } else {
            explanation = "Only \(Int(confidence * 100))% of the decision weight agreed, "
                + "below the \(Int(requiredConfidence * 100))% needed. Treated as a nuisance trigger."
        }

        return Decision(accepted: accepted, confidence: confidence,
                        agreeing: agreeingChannels, dissenting: dissentingChannels,
                        explanation: explanation)
    }

    /// Builds the votes from raw channel readings, applying each channel's own
    /// notion of what "agreement" means.
    public static func buildVotes(accelerationRatio: Double,
                                  tiltChanged: Bool,
                                  soundLevel: Double,
                                  triggerThreshold: Double,
                                  at time: Date = Date()) -> [SensorVote] {
        [
            SensorVote(channel: .accelerometer,
                       agreed: accelerationRatio >= triggerThreshold,
                       value: accelerationRatio, at: time),
            SensorVote(channel: .tiltSwitch, agreed: tiltChanged,
                       value: tiltChanged ? 1 : 0, at: time),
            // Earthquakes are loud: structures creak and contents rattle. A
            // silent "event" is almost always electrical noise on the ADC.
            SensorVote(channel: .soundSensor, agreed: soundLevel > 0.35,
                       value: soundLevel, at: time),
        ]
    }
}

// MARK: - 14. False-trigger rejection

/// Algorithm 14 — reject nuisance sources by signature.
///
/// Earthquakes have a shape: a comparatively gentle emergent onset, energy
/// spread over a broad low band, and a long decaying coda. A slammed door is the
/// opposite — instantaneous onset, high frequency, gone in under a second.
/// Comparing a candidate against a library of known nuisance signatures throws
/// out the overwhelming majority of false triggers without ever needing a second
/// opinion.
public enum FalseTriggerRejection {

    public struct Signature: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        /// Rise time from 10% to 90% of peak, seconds.
        public var riseTime: ClosedRange<Double>
        /// Centroid of the spectrum, Hz.
        public var spectralCentroid: ClosedRange<Double>
        /// Duration above 20% of peak, seconds.
        public var duration: ClosedRange<Double>
        /// Ratio of vertical to horizontal energy.
        public var verticalDominance: ClosedRange<Double>
        public var guidance: String

        public init(name: String, riseTime: ClosedRange<Double>,
                    spectralCentroid: ClosedRange<Double>, duration: ClosedRange<Double>,
                    verticalDominance: ClosedRange<Double>, guidance: String) {
            self.name = name; self.riseTime = riseTime
            self.spectralCentroid = spectralCentroid; self.duration = duration
            self.verticalDominance = verticalDominance; self.guidance = guidance
        }
    }

    /// The learned library. These are the four things that actually trigger a
    /// building-mounted sensor in ordinary life.
    public static let nuisanceLibrary: [Signature] = [
        Signature(name: "Door slam or impact",
                  riseTime: 0...0.02, spectralCentroid: 15...200, duration: 0...0.8,
                  verticalDominance: 0...0.6,
                  guidance: "Very fast onset and high frequency. A real earthquake takes longer to build."),
        Signature(name: "Footsteps or activity",
                  riseTime: 0.01...0.15, spectralCentroid: 8...40, duration: 0.1...2.0,
                  verticalDominance: 1.2...100,
                  guidance: "Almost entirely vertical, and repeats at walking pace."),
        Signature(name: "Passing vehicle",
                  riseTime: 0.5...6.0, spectralCentroid: 5...30, duration: 2...25,
                  verticalDominance: 0.4...1.4,
                  guidance: "Rises and falls smoothly as the vehicle approaches and leaves."),
        Signature(name: "Sensor knock or handling",
                  riseTime: 0...0.01, spectralCentroid: 30...500, duration: 0...0.4,
                  verticalDominance: 0...100,
                  guidance: "Effectively a step change. Usually means somebody touched the node."),
    ]

    public struct Features: Sendable, Equatable {
        public var riseTime: Double
        public var spectralCentroid: Double
        public var duration: Double
        public var verticalDominance: Double
        public var peak: Double

        public init(riseTime: Double, spectralCentroid: Double, duration: Double,
                    verticalDominance: Double, peak: Double) {
            self.riseTime = riseTime; self.spectralCentroid = spectralCentroid
            self.duration = duration; self.verticalDominance = verticalDominance
            self.peak = peak
        }
    }

    public struct Verdict: Sendable, Equatable {
        public var isEarthquake: Bool
        public var matchedNuisance: String?
        public var reason: String
        public var confidence: Double
    }

    public static func features(of rec: TriaxialRecord) -> Features {
        let mag = rec.magnitude
        let peak = mag.peakAbsolute
        guard peak > 0, mag.count > 4 else {
            return Features(riseTime: 0, spectralCentroid: 0, duration: 0,
                            verticalDominance: 1, peak: 0)
        }

        let peakIndex = mag.samples.firstIndex(where: { abs($0) >= peak * 0.999 }) ?? 0
        // Rise time: 10% to 90% of peak on the way up.
        var i10 = 0, i90 = peakIndex
        for i in stride(from: peakIndex, through: 0, by: -1) {
            if abs(mag.samples[i]) <= peak * 0.9 { i90 = i }
            if abs(mag.samples[i]) <= peak * 0.1 { i10 = i; break }
        }
        let riseTime = Swift.max(Double(i90 - i10) * mag.dt, 0)

        let above = mag.samples.filter { abs($0) > peak * 0.2 }.count
        let duration = Double(above) * mag.dt

        let centroid = Spectrum.centroid(mag)

        let hEnergy = rec.x.samples.reduce(0) { $0 + $1 * $1 }
            + rec.y.samples.reduce(0) { $0 + $1 * $1 }
        let vEnergy = rec.z.samples.reduce(0) { $0 + $1 * $1 }
        let dominance = hEnergy > 1e-20 ? vEnergy / (hEnergy / 2) : 100

        return Features(riseTime: riseTime, spectralCentroid: centroid,
                        duration: duration, verticalDominance: dominance, peak: peak)
    }

    public static func classify(_ f: Features) -> Verdict {
        var bestMatch: (Signature, Double)?

        for sig in nuisanceLibrary {
            var score = 0.0
            var checks = 0.0
            func check(_ value: Double, _ range: ClosedRange<Double>) {
                checks += 1
                if range.contains(value) { score += 1 }
            }
            check(f.riseTime, sig.riseTime)
            check(f.spectralCentroid, sig.spectralCentroid)
            check(f.duration, sig.duration)
            check(f.verticalDominance, sig.verticalDominance)

            let fraction = checks > 0 ? score / checks : 0
            if fraction >= 0.75, fraction > (bestMatch?.1 ?? 0) { bestMatch = (sig, fraction) }
        }

        if let (sig, fraction) = bestMatch {
            return Verdict(isEarthquake: false, matchedNuisance: sig.name,
                           reason: sig.guidance, confidence: fraction)
        }

        // Positive evidence *for* an earthquake, not merely absence of a match.
        var reasons: [String] = []
        if f.riseTime > 0.05 { reasons.append("emergent onset") }
        if f.spectralCentroid < 15 { reasons.append("low-frequency energy") }
        if f.duration > 1.5 { reasons.append("sustained shaking") }
        let confidence = Swift.min(Double(reasons.count) / 3.0, 1)

        return Verdict(
            isEarthquake: confidence >= 0.34,
            matchedNuisance: nil,
            reason: reasons.isEmpty
                ? "Signature does not match any known nuisance source, but also lacks earthquake character."
                : "Consistent with an earthquake: \(reasons.joined(separator: ", ")).",
            confidence: confidence)
    }

    public static func classify(_ rec: TriaxialRecord) -> Verdict { classify(features(of: rec)) }
}
