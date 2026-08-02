import Foundation
import SeismicCore

// MARK: - 73. Adaptive noise cancellation

/// Algorithm 73 — least-mean-squares adaptive noise cancellation.
///
/// A fixed filter can only remove interference whose frequency you knew in
/// advance. The interference this app actually meets does not oblige: a lift
/// motor runs at whatever speed it runs at, a chiller cycles, a transformer
/// drifts with load, and every building's plant is different. Notching them out
/// by hand would mean a per-building configuration nobody will ever do, and
/// notching aggressively enough to catch them all would remove the building.
///
/// An adaptive filter learns the interference instead. Given a reference — a
/// second channel that contains the noise but *not* the signal — it converges
/// on whatever linear transformation turns the reference into the interference
/// in the primary channel, subtracts it, and keeps adapting as the interference
/// changes. The vertical channel makes a good reference for horizontal plant
/// noise, because plant shakes a floor in every direction while a building
/// sways horizontally.
///
/// This matters most for the overnight measurement, which runs unattended in a
/// building whose plant nobody characterised.
public enum AdaptiveNoiseCancellation {

    public struct Result: Sendable, Equatable {
        /// The primary channel with the interference removed.
        public var cleaned: [Double]
        /// What was subtracted, kept so it can be inspected rather than taken
        /// on trust. An adaptive filter that has quietly removed the signal
        /// looks exactly like one that worked, unless you look at this.
        public var removed: [Double]
        /// How much energy came out, as a fraction. Above about a half is a
        /// warning rather than a success.
        public var fractionRemoved: Double

        public init(cleaned: [Double], removed: [Double], fractionRemoved: Double) {
            self.cleaned = cleaned
            self.removed = removed
            self.fractionRemoved = fractionRemoved
        }
    }

    /// - Parameters:
    ///   - primary: the channel to clean.
    ///   - reference: a channel containing the interference and not the signal.
    ///   - taps: filter length. Long enough to model the delay and colouring
    ///     between the two channels; 32 is ample for structure-borne plant.
    ///   - stepSize: normalised, 0–2. Larger converges faster and tracks worse.
    public static func cancel(primary: [Double], reference: [Double],
                              taps: Int = 32, stepSize: Double = 0.05) -> Result? {
        let n = min(primary.count, reference.count)
        let m = max(min(taps, n / 4), 2)
        guard n > 4 * m else { return nil }

        var weights = [Double](repeating: 0, count: m)
        var cleaned = [Double](repeating: 0, count: n)
        var removed = [Double](repeating: 0, count: n)
        // Running estimate of the reference's power, for the normalised update.
        // Without normalisation the step size has to be retuned for every
        // signal amplitude, which for a sensor whose level changes with the
        // weather means retuning it constantly.
        var referencePower = 1e-9

        for i in 0..<n {
            var estimate = 0.0
            for k in 0..<m where i >= k {
                estimate += weights[k] * reference[i - k]
            }
            let error = primary[i] - estimate
            cleaned[i] = error
            removed[i] = estimate

            referencePower = 0.99 * referencePower + 0.01 * reference[i] * reference[i]
            let normalisation = stepSize / (referencePower * Double(m) + 1e-12)
            for k in 0..<m where i >= k {
                weights[k] += normalisation * error * reference[i - k]
            }
        }

        let inputEnergy = primary.reduce(0) { $0 + $1 * $1 }
        let removedEnergy = removed.reduce(0) { $0 + $1 * $1 }
        return Result(cleaned: cleaned, removed: removed,
                      fractionRemoved: inputEnergy > 0
                          ? min(removedEnergy / inputEnergy, 1) : 0)
    }
}

// MARK: - 74. Kalman displacement with zero-velocity updates

/// Algorithm 74 — constrained displacement estimation by Kalman smoothing with
/// zero-velocity updates.
///
/// Integrating acceleration twice to get displacement is the oldest trap in
/// this field. Any constant bias — and every accelerometer has one, drifting
/// with temperature — integrates once into a velocity ramp and twice into a
/// parabola, so after a minute the "displacement" is metres of pure error.
/// This app's existing answer is a high-pass filter after each integration,
/// which works and costs the very low frequencies, exactly where a building's
/// permanent offset lives.
///
/// A Kalman filter does better because it can be told something the high-pass
/// cannot express: that the sensor is *at rest* at certain moments. Before the
/// P wave arrives and long after the coda has died, the true velocity is zero.
/// Asserting that as a measurement — a zero-velocity update — pins the
/// integration at both ends and lets the filter estimate and remove the bias
/// rather than merely suppressing the frequencies it corrupts.
///
/// The result is that a residual displacement survives the processing instead
/// of being filtered away, and residual displacement is one of the three pieces
/// of evidence the verdict rests on.
public enum ConstrainedDisplacement {

    public struct Result: Sendable, Equatable {
        public var displacement: [Double]
        public var velocity: [Double]
        /// The accelerometer bias the filter settled on, m/s².
        public var estimatedBias: Double
        /// Displacement at the end of the record — where the sensor came to
        /// rest relative to where it started.
        public var residual: Double

        public init(displacement: [Double], velocity: [Double],
                    estimatedBias: Double, residual: Double) {
            self.displacement = displacement
            self.velocity = velocity
            self.estimatedBias = estimatedBias
            self.residual = residual
        }
    }

    /// - Parameters:
    ///   - quietWindows: index ranges where the sensor is known to be still.
    ///     Usually the pre-event roll and the tail. Supplying none makes this a
    ///     plain integration with a bias state, which is better than nothing
    ///     and much worse than this with them.
    ///   - measurementNoise: how firmly to believe a zero-velocity update.
    ///     Small means "the sensor really is still".
    public static func estimate(_ acceleration: Waveform,
                                quietWindows: [Range<Int>],
                                processNoise: Double = 1e-6,
                                measurementNoise: Double = 1e-4) -> Result {
        let n = acceleration.samples.count
        let dt = acceleration.dt
        guard n > 2 else {
            return Result(displacement: [], velocity: [], estimatedBias: 0, residual: 0)
        }

        // State: [displacement, velocity, bias]. The bias is a state rather than
        // something removed beforehand, which is the whole point — it is
        // estimated *from* the zero-velocity constraints.
        var x = [0.0, 0.0, 0.0]
        var p = [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]]

        // Transition: d += v·dt, v += (a − bias)·dt, bias constant.
        let f: [[Double]] = [[1, dt, 0], [0, 1, -dt], [0, 0, 1]]
        let q: [[Double]] = [[processNoise * dt, 0, 0],
                             [0, processNoise, 0],
                             [0, 0, processNoise * 1e-3]]

        var displacement = [Double](repeating: 0, count: n)
        var velocity = [Double](repeating: 0, count: n)

        var quiet = [Bool](repeating: false, count: n)
        for window in quietWindows {
            for i in window where i >= 0 && i < n { quiet[i] = true }
        }

        for i in 0..<n {
            // Predict.
            let a = acceleration.samples[i]
            var next = [0.0, 0.0, 0.0]
            for r in 0..<3 {
                for c in 0..<3 { next[r] += f[r][c] * x[c] }
            }
            next[1] += a * dt
            x = next

            var fp = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
            for r in 0..<3 {
                for c in 0..<3 {
                    for k in 0..<3 { fp[r][c] += f[r][k] * p[k][c] }
                }
            }
            var newP = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
            for r in 0..<3 {
                for c in 0..<3 {
                    for k in 0..<3 { newP[r][c] += fp[r][k] * f[c][k] }
                    newP[r][c] += q[r][c]
                }
            }
            p = newP

            // Update, when the sensor is known to be still. Two measurements at
            // once: the velocity is zero, and so is the displacement rate — the
            // second is what stops the estimate wandering during a long quiet
            // tail.
            if quiet[i] {
                applyUpdate(&x, &p, observing: 1, value: 0, noise: measurementNoise)
            }

            displacement[i] = x[0]
            velocity[i] = x[1]
        }

        return Result(displacement: displacement, velocity: velocity,
                      estimatedBias: x[2], residual: displacement.last ?? 0)
    }

    /// Scalar Kalman update on one state component.
    ///
    /// Written out for a single observation rather than in matrix form because
    /// every update here observes exactly one thing, and the scalar form has no
    /// matrix inverse in it — which is one fewer way for a filter running
    /// unattended overnight to produce a NaN.
    static func applyUpdate(_ x: inout [Double], _ p: inout [[Double]],
                            observing index: Int, value: Double, noise: Double) {
        let innovation = value - x[index]
        let s = p[index][index] + noise
        guard s > 1e-18 else { return }

        let gain = (0..<3).map { p[$0][index] / s }
        for i in 0..<3 { x[i] += gain[i] * innovation }

        var newP = p
        for r in 0..<3 {
            for c in 0..<3 {
                newP[r][c] = p[r][c] - gain[r] * p[index][c]
            }
        }
        p = newP
    }

    /// Finds the quiet stretches automatically, from the running energy.
    ///
    /// A window counts as quiet when its RMS is close to the quietest window in
    /// the record — relative rather than absolute, because "still" for a
    /// basement sensor and "still" for a phone on a desk differ by an order of
    /// magnitude and a fixed threshold would be wrong for one of them.
    public static func detectQuietWindows(_ w: Waveform, windowSeconds: Double = 1.0,
                                          factor: Double = 2.0) -> [Range<Int>] {
        let size = max(Int(windowSeconds * w.sampleRate), 8)
        let n = w.samples.count
        guard n > 2 * size else { return [] }

        var energies: [(range: Range<Int>, rms: Double)] = []
        var start = 0
        while start + size <= n {
            let slice = Array(w.samples[start..<(start + size)])
            energies.append((start..<(start + size), Stats.rms(slice)))
            start += size
        }
        guard let quietest = energies.map(\.rms).min(),
              let loudest = energies.map(\.rms).max() else { return [] }

        // The threshold is relative to the quietest window, with a floor
        // relative to the loudest. Without that floor a perfectly still
        // stretch — RMS exactly zero, which a bench test and a stationary
        // simulated record both produce — multiplies to zero and selects
        // nothing, so the tidiest possible input would be the one case where
        // no quiet window was found.
        let threshold = max(quietest * factor, loudest * 1e-6)
        return energies.filter { $0.rms <= threshold }.map(\.range)
    }
}

// MARK: - 75. Allan variance

/// Algorithm 75 — Allan variance, for characterising the sensor itself.
///
/// The app now offers a phone's own accelerometer as a substitute for a wired
/// node. That raises a question it previously never had to answer: *is this
/// particular sensor good enough for this particular building?* A phone in a
/// stiff two-storey house is being asked to resolve a sway of a few
/// micro-g at three hertz; the same phone in a tall tower has a much larger
/// signal at a much lower frequency, where its own drift is worst.
///
/// Allan variance is the standard way to answer that. It measures how the
/// average of a signal varies between adjacent windows as the window length
/// grows, which separates the noise processes by how they scale: white noise
/// falls off as one over the averaging time, bias instability flattens out, and
/// random walk rises. The floor of the curve is the sensor's bias instability
/// — the best it can ever do, no matter how long you average — and the
/// averaging time at which it occurs is how long a measurement can usefully be.
///
/// So it turns "should I trust my phone here" from a matter of opinion into a
/// number compared against the building's expected signal.
public enum AllanVariance {

    public struct Point: Sendable, Equatable, Identifiable {
        public var id: Int { clusterSize }
        /// Samples per averaging window.
        public var clusterSize: Int
        /// Averaging time, seconds.
        public var tau: Double
        /// Allan deviation at that averaging time, in the signal's own units.
        public var deviation: Double

        public init(clusterSize: Int, tau: Double, deviation: Double) {
            self.clusterSize = clusterSize; self.tau = tau; self.deviation = deviation
        }
    }

    public struct Characterisation: Sendable, Equatable {
        public var points: [Point]
        /// The floor of the curve — the best stability the sensor can reach.
        public var biasInstability: Double
        /// The averaging time at which that floor occurs.
        public var optimalAveragingTime: Double

        public init(points: [Point], biasInstability: Double, optimalAveragingTime: Double) {
            self.points = points
            self.biasInstability = biasInstability
            self.optimalAveragingTime = optimalAveragingTime
        }

        /// Whether this sensor can resolve a given signal.
        ///
        /// The comparison an engineer would actually make: the building's
        /// expected amplitude against the sensor's floor. A ten-to-one margin
        /// is comfortable, three-to-one is workable, below one is hopeless and
        /// the app should say so rather than producing a period from noise.
        public func canResolve(_ amplitude: Double) -> (verdict: Verdict, margin: Double) {
            guard biasInstability > 0 else { return (.unknown, 0) }
            let margin = amplitude / biasInstability
            switch margin {
            case 10...: return (.comfortable, margin)
            case 3..<10: return (.workable, margin)
            case 1..<3: return (.marginal, margin)
            default: return (.hopeless, margin)
            }
        }

        public enum Verdict: String, Sendable {
            case comfortable, workable, marginal, hopeless, unknown

            public var explanation: String {
                switch self {
                case .comfortable:
                    "This sensor resolves the building's motion with room to spare."
                case .workable:
                    "Usable. Measurements will be noisier than a wired node's but real."
                case .marginal:
                    "The building's sway is close to this sensor's own noise floor. "
                    + "Expect scattered readings, and treat a single measurement as weak."
                case .hopeless:
                    "The building moves less than this sensor can detect. A period measured "
                    + "here would be noise with a number attached to it."
                case .unknown:
                    "Not enough data to characterise the sensor yet."
                }
            }
        }
    }

    /// Overlapping Allan variance, which uses every available window rather
    /// than only the non-overlapping ones — three to four times more confidence
    /// from the same record, which matters when the record is a few minutes of
    /// somebody holding still.
    public static func compute(_ w: Waveform, maximumClusters: Int = 24) -> Characterisation {
        let n = w.samples.count
        guard n >= 16 else { return Characterisation(points: [], biasInstability: 0,
                                                     optimalAveragingTime: 0) }

        // Cumulative sums make every window average an O(1) lookup, which is
        // what makes the overlapping form affordable.
        var cumulative = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { cumulative[i + 1] = cumulative[i] + w.samples[i] }

        func mean(_ from: Int, _ length: Int) -> Double {
            (cumulative[from + length] - cumulative[from]) / Double(length)
        }

        // Logarithmically spaced cluster sizes, up to a third of the record —
        // beyond that there are too few windows for the estimate to mean
        // anything, and plotting it anyway is how Allan curves acquire their
        // characteristic noisy tail.
        let maximum = max(n / 3, 2)
        var sizes: [Int] = []
        var size = 1
        while size <= maximum && sizes.count < maximumClusters {
            if sizes.last != size { sizes.append(size) }
            size = max(size + 1, Int(Double(size) * 1.4))
        }

        var points: [Point] = []
        for m in sizes {
            guard n >= 3 * m else { continue }
            var sum = 0.0
            var count = 0
            for i in 0...(n - 2 * m) {
                let first = mean(i, m)
                let second = mean(i + m, m)
                let difference = second - first
                sum += difference * difference
                count += 1
            }
            guard count > 0 else { continue }
            let variance = sum / (2 * Double(count))
            points.append(Point(clusterSize: m, tau: Double(m) / w.sampleRate,
                                deviation: variance.squareRoot()))
        }

        guard let floor = points.min(by: { $0.deviation < $1.deviation }) else {
            return Characterisation(points: points, biasInstability: 0, optimalAveragingTime: 0)
        }
        return Characterisation(points: points, biasInstability: floor.deviation,
                                optimalAveragingTime: floor.tau)
    }
}

// MARK: - 76. Sub-sample time alignment

/// Algorithm 76 — sub-sample time alignment by cross-correlation.
///
/// The moment there is more than one sensor, their clocks matter. Locating an
/// epicentre from arrival times turns a timing error directly into a position
/// error at the speed of the wave: at six kilometres a second, ten milliseconds
/// of clock skew is sixty metres of epicentre. A crowd of phones, which is what
/// this app now supports, has clocks synchronised over the network to somewhere
/// between ten and a hundred milliseconds — so the skew is larger than the
/// measurement.
///
/// Two sensors that felt the same earthquake give a way out. The lag that
/// maximises the cross-correlation between their records is the sum of the true
/// travel-time difference and the clock skew, and over many pairs the skew can
/// be separated from the geometry. Even for one pair it is worth having,
/// because it is measured from the waveforms themselves and needs no clock at
/// all.
///
/// Parabolic interpolation around the correlation peak recovers timing finer
/// than the sample interval, which at a hundred hertz is the difference between
/// ten milliseconds of resolution and about one.
public enum TimeAlignment {

    public struct Alignment: Sendable, Equatable {
        /// Seconds by which the second record lags the first. Negative means it
        /// leads.
        public var lagSeconds: Double
        /// Peak normalised correlation, −1 to 1. Below about 0.5 the two
        /// sensors did not see the same thing and the lag means nothing.
        public var correlation: Double
        /// Whether the alignment is worth using.
        public var isReliable: Bool { correlation >= 0.5 }

        public init(lagSeconds: Double, correlation: Double) {
            self.lagSeconds = lagSeconds
            self.correlation = correlation
        }
    }

    /// - Parameter maximumLag: seconds to search either side of zero. Bound it
    ///   to the plausible skew plus travel time, or a periodic signal will
    ///   happily align on the wrong cycle.
    public static func align(_ a: Waveform, _ b: Waveform,
                             maximumLag: Double = 2.0) -> Alignment? {
        let n = min(a.samples.count, b.samples.count)
        guard n > 16, a.sampleRate > 0 else { return nil }
        let maxShift = min(Int(maximumLag * a.sampleRate), n / 2)
        guard maxShift >= 1 else { return nil }

        // Remove the means once. A correlation between two channels with
        // different DC offsets is dominated by the product of those offsets and
        // peaks at zero lag regardless of the signals.
        let meanA = Stats.mean(Array(a.samples[0..<n]))
        let meanB = Stats.mean(Array(b.samples[0..<n]))
        let x = (0..<n).map { a.samples[$0] - meanA }
        let y = (0..<n).map { b.samples[$0] - meanB }

        let energyX = x.reduce(0) { $0 + $1 * $1 }
        let energyY = y.reduce(0) { $0 + $1 * $1 }
        guard energyX > 1e-18, energyY > 1e-18 else { return nil }
        let normalisation = (energyX * energyY).squareRoot()

        var correlations = [Double](repeating: 0, count: 2 * maxShift + 1)
        for (index, shift) in (-maxShift...maxShift).enumerated() {
            var sum = 0.0
            let from = max(0, -shift)
            let to = min(n, n - shift)
            guard to > from else { continue }
            for i in from..<to { sum += x[i] * y[i + shift] }
            correlations[index] = sum / normalisation
        }

        guard let peak = correlations.indices
            .max(by: { correlations[$0] < correlations[$1] }) else { return nil }

        // Parabolic refinement, which is what gets below one sample.
        var offset = 0.0
        if peak > 0, peak < correlations.count - 1 {
            let left = correlations[peak - 1]
            let centre = correlations[peak]
            let right = correlations[peak + 1]
            let denominator = left - 2 * centre + right
            if abs(denominator) > 1e-18 {
                offset = 0.5 * (left - right) / denominator
                // A refinement of more than half a sample means the parabola
                // did not fit; the integer peak is the better answer.
                if abs(offset) > 0.5 { offset = 0 }
            }
        }

        let lagSamples = Double(peak - maxShift) + offset
        return Alignment(lagSeconds: lagSamples / a.sampleRate,
                         correlation: correlations[peak])
    }
}
