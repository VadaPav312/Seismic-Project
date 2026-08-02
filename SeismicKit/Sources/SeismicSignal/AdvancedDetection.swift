import Foundation
import SeismicCore

// MARK: - 77. Matched-filter template detection

/// Algorithm 77 — matched-filter (template) detection of repeating events.
///
/// The STA/LTA detector this app runs finds events by energy: something got
/// loud, so something happened. That works for the mainshock and fails for the
/// sequence afterwards, where the aftershocks that matter most are the small
/// ones — too small to lift the ratio above threshold, and the ones that decide
/// whether it is safe to go back inside.
///
/// A matched filter finds them anyway, because it looks for *shape* rather than
/// size. Aftershocks on the same fault patch as the mainshock produce very
/// nearly the same waveform at the same station: same path, same site response,
/// same radiation pattern, scaled down. Correlating the record against the
/// mainshock as a template lights up on every repeat.
///
/// It is worth being precise about *how* it beats the noise, because the
/// obvious story is wrong. A buried event does not produce a correlation
/// coefficient near one — the coefficient is normalised by the whole analysis
/// window, so a small event in a noisy window scores a few hundredths however
/// good the match is. What it produces is a value wildly improbable for noise
/// at that lag. The gain is in the *significance*, not the coefficient, which
/// is why the threshold is measured against the correlation trace's own scatter
/// rather than set at an absolute number. See `Threshold`.
///
/// This is how modern catalogues find ten times more aftershocks than a
/// threshold detector, and it is the difference between the re-entry advice in
/// this app resting on four aftershocks or on forty.
public enum MatchedFilter {

    public struct Detection: Sendable, Equatable, Identifiable {
        public var id: Int { sampleIndex }
        public var sampleIndex: Int
        public var time: Double
        /// Normalised correlation with the template, −1 to 1.
        public var correlation: Double
        /// How much smaller than the template this event was, by amplitude.
        public var relativeAmplitude: Double

        public init(sampleIndex: Int, time: Double, correlation: Double,
                    relativeAmplitude: Double) {
            self.sampleIndex = sampleIndex
            self.time = time
            self.correlation = correlation
            self.relativeAmplitude = relativeAmplitude
        }
    }

    /// How to decide what counts as a detection.
    ///
    /// The distinction matters more than it looks. A correlation *coefficient*
    /// is normalised by the whole analysis window, so a genuinely small
    /// aftershock buried in noise produces a coefficient of a few hundredths —
    /// tiny in absolute terms, and enormous compared with what noise alone
    /// produces at that lag. Thresholding on the absolute value therefore finds
    /// only the events that were never hard to find.
    ///
    /// Real earthquake catalogues threshold on the second form: some multiple
    /// of the median absolute deviation of the correlation trace itself. That
    /// asks the right question — "is this lag unusual for this record" — and it
    /// is what lets a matched filter pull events out from under the noise.
    public enum Threshold: Sendable, Equatable {
        /// A fixed correlation coefficient. Simple, and only suitable when the
        /// events sought are comparable in size to the template.
        case absolute(Double)
        /// A multiple of the correlation trace's own median absolute deviation
        /// above its median.
        ///
        /// The multiple should follow the length of the record, because it is
        /// really a false-positive budget spread over every lag examined. Eight
        /// to twelve is standard for a catalogue processing a day at a time —
        /// tens of millions of lags, where even a one-in-a-million coincidence
        /// happens repeatedly. For a single event record of a few minutes, four
        /// to six is the equivalent bar and eight throws away real detections:
        /// measured on a synthetic buried at half the noise amplitude, the
        /// event scores just under five times the MAD, which is unmistakable
        /// among ten thousand lags and invisible among ten million.
        case medianAbsoluteDeviation(multiple: Double)
    }

    /// - Parameters:
    ///   - template: a window cut around a known event. Two to ten seconds
    ///     starting just before the P arrival is the usual choice.
    ///   - threshold: see `Threshold`.
    ///   - minimumSeparation: seconds between detections, so one event is not
    ///     reported as five.
    public static func detect(in signal: Waveform, template: [Double],
                              threshold: Threshold = .medianAbsoluteDeviation(multiple: 9),
                              minimumSeparation: Double = 1.0) -> [Detection] {
        let m = template.count
        let n = signal.samples.count
        guard m >= 8, n > m else { return [] }

        // Zero-mean the template once. A template with an offset correlates
        // with the record's offset rather than with its shape.
        let templateMean = Stats.mean(template)
        let t = template.map { $0 - templateMean }
        let templateEnergy = t.reduce(0) { $0 + $1 * $1 }
        guard templateEnergy > 1e-18 else { return [] }
        let templateNorm = templateEnergy.squareRoot()

        // Running sums, so each window's mean and energy is O(1) rather than
        // O(m). Without this a ten-minute record against a five-second template
        // is a hundred million multiplications for the normalisation alone.
        var cumulative = [Double](repeating: 0, count: n + 1)
        var cumulativeSquares = [Double](repeating: 0, count: n + 1)
        for i in 0..<n {
            cumulative[i + 1] = cumulative[i] + signal.samples[i]
            cumulativeSquares[i + 1] = cumulativeSquares[i]
                                     + signal.samples[i] * signal.samples[i]
        }

        var correlations = [Double](repeating: 0, count: n - m + 1)
        for start in 0...(n - m) {
            let sum = cumulative[start + m] - cumulative[start]
            let sumSquares = cumulativeSquares[start + m] - cumulativeSquares[start]
            let mean = sum / Double(m)
            let energy = sumSquares - Double(m) * mean * mean
            guard energy > 1e-18 else { continue }

            var dot = 0.0
            for k in 0..<m { dot += t[k] * (signal.samples[start + k] - mean) }
            correlations[start] = dot / (templateNorm * energy.squareRoot())
        }

        // Resolve the threshold against the correlation trace itself when asked
        // to. MAD rather than standard deviation because the trace contains the
        // very detections being looked for, and a handful of large values would
        // inflate a standard deviation enough to hide the rest of them — the
        // estimator would be raising the bar using the evidence.
        let level: Double
        switch threshold {
        case .absolute(let value):
            level = value
        case .medianAbsoluteDeviation(let multiple):
            let median = Stats.median(correlations)
            let deviation = Stats.mad(correlations)
            level = deviation > 1e-12 ? median + multiple * deviation : 1
        }

        // Non-maximum suppression: take the strongest correlation first, blank
        // out everything within a dead time of it, and repeat.
        //
        // The dead time is at least one template length, and that floor is not
        // optional. A single event correlates above threshold for roughly the
        // template's whole duration as it slides in and out of alignment, so a
        // dead time shorter than the template reports the same earthquake twice
        // — once on the way in and once on the way out. Two real events closer
        // together than one template length cannot be separated by this method
        // at all, so nothing is lost by refusing to try.
        let separation = max(Int(minimumSeparation * signal.sampleRate), m)

        // Strongest first, rather than left to right. Scanning forwards locks
        // onto the leading edge of a peak — the first lag that happens to clear
        // the threshold — instead of its summit, which biases every arrival
        // time early by a fraction of the template.
        let candidates = correlations.indices
            .filter { correlations[$0] >= level }
            .sorted { correlations[$0] > correlations[$1] }

        var accepted: [Int] = []
        for candidate in candidates {
            guard !accepted.contains(where: { abs($0 - candidate) < separation }) else {
                continue
            }
            accepted.append(candidate)
        }

        return accepted.sorted().map { index in
            let windowEnergy = (cumulativeSquares[index + m] - cumulativeSquares[index])
                             .squareRoot()
            return Detection(
                sampleIndex: index,
                time: Double(index) / signal.sampleRate,
                correlation: correlations[index],
                relativeAmplitude: templateNorm > 0 ? windowEnergy / templateNorm : 0)
        }
    }
}

// MARK: - 78. Kurtosis onset picker

/// Algorithm 78 — the higher-order-statistics (kurtosis) onset picker.
///
/// The app's existing picker minimises the Akaike Information Criterion, which
/// is excellent and has one specific weakness: it assumes the noise before the
/// arrival and the signal after it differ in *variance*. For an impulsive
/// arrival that is a good assumption. For an emergent one — a distant
/// earthquake whose energy builds over a second or two, which is exactly the
/// case where the extra warning seconds matter most — the variance rises
/// gradually and the AIC minimum smears out across the ramp.
///
/// Kurtosis measures something else entirely: how heavy the tails of the
/// distribution are. Ambient noise is close to Gaussian and has a kurtosis near
/// three; the onset of a transient is emphatically not Gaussian, because a few
/// large samples have arrived among many small ones, and kurtosis jumps sharply
/// the moment they do. It is sensitive to the *arrival of structure*, not to
/// the arrival of energy, and it therefore fires earlier and more crisply on an
/// emergent onset.
///
/// The two pickers disagreeing is itself informative and is reported: it means
/// the onset is emergent, which means the source is distant, which means there
/// is more warning time than a nearby event would give.
public enum KurtosisPicker {

    public struct Pick: Sendable, Equatable {
        public var time: Double
        public var sampleIndex: Int
        /// Peak kurtosis rise, as a multiple of the background level. Larger is
        /// a more confident pick.
        public var sharpness: Double

        public init(time: Double, sampleIndex: Int, sharpness: Double) {
            self.time = time; self.sampleIndex = sampleIndex; self.sharpness = sharpness
        }
    }

    /// - Parameter windowSeconds: the sliding window. Short enough to time the
    ///   onset, long enough that the fourth moment is estimated from enough
    ///   samples to mean anything — a kurtosis from twenty samples is noise.
    public static func pick(_ w: Waveform, windowSeconds: Double = 1.0) -> Pick? {
        let size = max(Int(windowSeconds * w.sampleRate), 32)
        let n = w.samples.count
        guard n > 3 * size else { return nil }

        var kurtosis = [Double](repeating: 0, count: n)
        for end in size..<n {
            let window = Array(w.samples[(end - size)..<end])
            let mean = Stats.mean(window)
            var second = 0.0, fourth = 0.0
            for value in window {
                let d = value - mean
                let d2 = d * d
                second += d2
                fourth += d2 * d2
            }
            second /= Double(size)
            fourth /= Double(size)
            guard second > 1e-24 else { continue }
            kurtosis[end] = fourth / (second * second)
        }

        // The pick is where kurtosis rises fastest, not where it is highest.
        // The maximum sits somewhere inside the transient; the steepest rise is
        // its leading edge, which is the arrival.
        let smoothed = SavitzkyGolay.smooth(kurtosis, windowLength: 11, order: 2)
        var derivative = [Double](repeating: 0, count: n)
        for i in 1..<n { derivative[i] = smoothed[i] - smoothed[i - 1] }

        // Only look after the first full window, where the statistic exists.
        let searchFrom = size + 10
        guard searchFrom < n - 1,
              let peak = (searchFrom..<n).max(by: { derivative[$0] < derivative[$1] }),
              derivative[peak] > 0 else { return nil }

        let background = Stats.mean(Array(kurtosis[searchFrom..<min(searchFrom + size, n)]))
        let sharpness = background > 1e-9 ? kurtosis[peak] / background : 0

        return Pick(time: Double(peak) / w.sampleRate, sampleIndex: peak,
                    sharpness: sharpness)
    }

    /// How far apart two pickers landed, and what that says.
    ///
    /// Reported rather than resolved. When an energy-based picker and a
    /// shape-based picker agree, the onset is impulsive and the arrival is
    /// certain; when they differ by more than a few tenths of a second, the
    /// onset is emergent, which is a fact about the source rather than a fault
    /// in either picker.
    public static func compare(kurtosisPick: Double, aicPick: Double)
        -> (differenceSeconds: Double, interpretation: String)
    {
        let difference = kurtosisPick - aicPick
        if abs(difference) < 0.15 {
            return (difference, "Both pickers agree. The onset is impulsive, which usually "
                              + "means the source is close.")
        }
        return (difference, "The two pickers differ by "
                          + String(format: "%.2f", abs(difference))
                          + " s, which means the onset is emergent rather than sharp. "
                          + "That is characteristic of a more distant earthquake — and a "
                          + "more distant earthquake gives more warning.")
    }
}

// MARK: - 79. Polarisation analysis

/// Algorithm 79 — polarisation analysis by covariance eigen-decomposition.
///
/// One three-axis sensor can do something that sounds impossible: tell you
/// which *direction* the earthquake came from. Not how far — that needs the S
/// minus P time this app already computes — but the bearing, from a single
/// station with no network at all.
///
/// It works because a P wave is a compression: the ground moves back and forth
/// *along* the direction the wave is travelling. So in the few tenths of a
/// second after the P arrival, the three channels are not independent — the
/// motion is confined almost to a line, and that line points at the source.
/// Forming the covariance matrix of the three channels over that window and
/// taking its eigenvectors recovers it: the dominant eigenvector is the
/// direction of motion, and the ratio of the eigenvalues says how confidently
/// linear the motion was.
///
/// For the crowd version of this app it is the difference between a single
/// phone reporting "something shook me" and reporting "something shook me, from
/// the north-north-east, and I am confident because the motion was ninety-four
/// per cent rectilinear".
/// Extends the existing polarisation code rather than standing beside it.
/// Algorithm 12 already forms particle motion to find the S arrival; the
/// bearing falls out of the same covariance and belongs in the same place.
extension PolarisationAnalysis {

    public struct Bearing: Sendable, Equatable {
        /// Degrees clockwise from north, 0–360. The direction the ground moved
        /// along, which for a P wave is the direction back to the source — or
        /// directly away from it; see `isAmbiguous`.
        public var backAzimuth: Double
        /// Angle from vertical, degrees. A steeply incident wave came from
        /// nearly below, meaning a deep or very close source.
        public var incidence: Double
        /// 0–1. One is perfectly linear motion, zero is motion filling all
        /// three dimensions equally.
        public var rectilinearity: Double
        /// P-wave motion is linear; S-wave motion is not. Below about 0.6 this
        /// window is not a clean P arrival and the azimuth should not be used.
        public var isReliable: Bool { rectilinearity >= 0.6 }
        /// A line has two ends. The azimuth is known modulo 180° from
        /// polarisation alone; resolving it needs the sign of the vertical
        /// first motion, which is what `backAzimuth` has already been corrected
        /// by when the vertical channel is clean.
        public var isAmbiguous: Bool

        public init(backAzimuth: Double, incidence: Double,
                    rectilinearity: Double, isAmbiguous: Bool) {
            self.backAzimuth = backAzimuth
            self.incidence = incidence
            self.rectilinearity = rectilinearity
            self.isAmbiguous = isAmbiguous
        }

        /// The bearing as a compass point, for a screen.
        public var compassPoint: String {
            let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                          "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
            let index = Int(((backAzimuth.truncatingRemainder(dividingBy: 360) + 360)
                             .truncatingRemainder(dividingBy: 360) / 22.5).rounded())
            return points[index % 16]
        }
    }

    /// - Parameters:
    ///   - record: three channels, x north, y east, z vertical.
    ///   - from: seconds into the record where the P arrival was picked.
    ///   - windowSeconds: how much of the P onset to analyse. Short — the S
    ///     wave arriving inside the window destroys the linearity that the
    ///     whole method depends on.
    public static func analyse(_ record: TriaxialRecord, from: Double,
                               windowSeconds: Double = 0.5) -> Bearing? {
        let rate = record.sampleRate
        let start = max(Int(from * rate), 0)
        let length = max(Int(windowSeconds * rate), 16)
        let n = record.count
        guard start + length <= n else { return nil }

        let x = Array(record.x.samples[start..<(start + length)])
        let y = Array(record.y.samples[start..<(start + length)])
        let z = Array(record.z.samples[start..<(start + length)])

        let meanX = Stats.mean(x), meanY = Stats.mean(y), meanZ = Stats.mean(z)
        let channels = [x.map { $0 - meanX }, y.map { $0 - meanY }, z.map { $0 - meanZ }]

        // The 3×3 covariance matrix of the three channels over the window.
        var covariance = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        for i in 0..<3 {
            for j in 0..<3 {
                var sum = 0.0
                for k in 0..<length { sum += channels[i][k] * channels[j][k] }
                covariance[i][j] = sum / Double(length)
            }
        }

        let (values, vectors) = symmetricEigen(covariance)
        guard let largest = values.indices.max(by: { values[$0] < values[$1] }),
              values[largest] > 1e-24 else { return nil }

        let principal = (0..<3).map { vectors[$0][largest] }
        let sorted = values.sorted(by: >)
        // Rectilinearity in the standard form: how much the two minor axes are
        // suppressed relative to the major one.
        let rectilinearity = sorted[0] > 1e-24
            ? 1 - (sorted[1] + sorted[2]) / (2 * sorted[0])
            : 0

        // The eigenvector is a line, so its sign is arbitrary. For a P wave the
        // ground first moves *away* from the source on a compression, so the
        // convention is to flip the vector to point upward and read the
        // horizontal projection as pointing back along the ray.
        let sign: Double = principal[2] < 0 ? -1 : 1
        let north = principal[0] * sign
        let east = principal[1] * sign
        let vertical = principal[2] * sign

        var azimuth = atan2(east, north) * 180 / .pi
        // Back-azimuth: the direction *towards* the source, opposite the
        // direction of first motion.
        azimuth += 180
        azimuth = azimuth.truncatingRemainder(dividingBy: 360)
        if azimuth < 0 { azimuth += 360 }

        let horizontal = (north * north + east * east).squareRoot()
        let incidence = atan2(horizontal, abs(vertical)) * 180 / .pi

        return Bearing(backAzimuth: azimuth, incidence: incidence,
                       rectilinearity: max(min(rectilinearity, 1), 0),
                       // Without a clean vertical first motion the two ends of
                       // the line cannot be told apart.
                       isAmbiguous: abs(vertical) < 0.1)
    }

    /// Jacobi eigenvalue iteration for a small symmetric matrix.
    ///
    /// Self-contained rather than reaching for the solver in the structures
    /// module, which would make the signal module depend on it for one 3×3
    /// decomposition. Jacobi is unconditionally convergent for symmetric
    /// matrices and needs no pivoting strategy, which for a matrix this size
    /// makes it both the simplest and the most robust choice.
    public static func symmetricEigen(_ input: [[Double]]) -> (values: [Double],
                                                        vectors: [[Double]]) {
        let n = input.count
        var a = input
        var v = (0..<n).map { i in (0..<n).map { j in i == j ? 1.0 : 0.0 } }

        for _ in 0..<64 {
            // Largest off-diagonal element.
            var p = 0, q = 1, largest = 0.0
            for i in 0..<n {
                for j in (i + 1)..<n where abs(a[i][j]) > largest {
                    largest = abs(a[i][j]); p = i; q = j
                }
            }
            if largest < 1e-18 { break }

            let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let t = (theta >= 0 ? 1.0 : -1.0)
                  / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1 / (t * t + 1).squareRoot()
            let s = t * c

            for k in 0..<n {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[k][q] = s * akp + c * akq
            }
            for k in 0..<n {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = c * apk - s * aqk
                a[q][k] = s * apk + c * aqk
            }
            for k in 0..<n {
                let vkp = v[k][p], vkq = v[k][q]
                v[k][p] = c * vkp - s * vkq
                v[k][q] = s * vkp + c * vkq
            }
        }
        return ((0..<n).map { a[$0][$0] }, v)
    }
}
