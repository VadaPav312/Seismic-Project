import Foundation
import SeismicCore

// Algorithms 1–8. Everything in this file runs before any interpretation
// happens, and every later stage assumes it has been done.

// MARK: - 1. DC offset removal and linear detrending

public enum Detrend {

    /// Algorithm 1a — remove the sensor's resting bias.
    ///
    /// An accelerometer at rest does not read zero. Left in place, that constant
    /// becomes a ramp after one integration and a parabola after two, which is
    /// precisely how a stationary building appears to walk off down the street.
    public static func removeDCOffset(_ x: [Double]) -> [Double] {
        guard !x.isEmpty else { return x }
        let m = Stats.mean(x)
        return x.map { $0 - m }
    }

    /// Algorithm 1b — remove a linear trend by least squares.
    ///
    /// Thermal drift makes the bias itself move slowly. Subtracting the fitted
    /// line removes that without touching the seismic band.
    public static func linear(_ x: [Double]) -> [Double] {
        guard x.count > 1 else { return removeDCOffset(x) }
        let n = Double(x.count)
        // Closed form for regression against the sample index — no need to
        // materialise an index array for what is a hot path.
        let sumX = n * (n - 1) / 2
        let sumXX = (n - 1) * n * (2 * n - 1) / 6
        var sumY = 0.0, sumXY = 0.0
        for (i, v) in x.enumerated() { sumY += v; sumXY += Double(i) * v }
        let denom = n * sumXX - sumX * sumX
        guard abs(denom) > 1e-12 else { return removeDCOffset(x) }
        let slope = (n * sumXY - sumX * sumY) / denom
        let intercept = (sumY - slope * sumX) / n
        return x.enumerated().map { $1 - (slope * Double($0) + intercept) }
    }

    /// Detrends with a polynomial of the given order. Order 0 is DC removal,
    /// order 1 is the linear case; higher orders are occasionally needed for a
    /// record with a badly behaved baseline.
    public static func polynomial(_ x: [Double], order: Int) -> [Double] {
        guard order >= 0 else { return x }
        if order == 0 { return removeDCOffset(x) }
        if order == 1 { return linear(x) }
        guard x.count > order else { return linear(x) }

        // Normal equations on the Vandermonde system, solved by Gaussian
        // elimination. Orders above ~3 are ill-conditioned, which is why the
        // caller is never offered them.
        let n = x.count
        let m = order + 1
        var ata = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)
        var atb = [Double](repeating: 0, count: m)
        for i in 0..<n {
            let t = Double(i) / Double(Swift.max(n - 1, 1))   // scale to 0…1 for conditioning
            var powers = [Double](repeating: 1, count: m)
            for k in 1..<m { powers[k] = powers[k - 1] * t }
            for r in 0..<m {
                atb[r] += powers[r] * x[i]
                for c in 0..<m { ata[r][c] += powers[r] * powers[c] }
            }
        }
        guard let coeffs = LinearAlgebra.solve(ata, atb) else { return linear(x) }
        return (0..<n).map { i in
            let t = Double(i) / Double(Swift.max(n - 1, 1))
            var p = 1.0, fit = 0.0
            for k in 0..<m { fit += coeffs[k] * p; p *= t }
            return x[i] - fit
        }
    }
}

/// Just enough dense linear algebra for the polynomial fits and the eigenvalue
/// solver. Deliberately not a general library.
public enum LinearAlgebra {

    /// Gaussian elimination with partial pivoting. Returns nil for a singular
    /// system rather than producing confident nonsense.
    public static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        guard a.count == n, a.allSatisfy({ $0.count == n }) else { return nil }
        var m = a, y = b

        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<n where abs(m[r][col]) > abs(m[pivot][col]) { pivot = r }
            guard abs(m[pivot][col]) > 1e-14 else { return nil }
            if pivot != col { m.swapAt(pivot, col); y.swapAt(pivot, col) }

            let d = m[col][col]
            for r in (col + 1)..<n {
                let factor = m[r][col] / d
                guard factor != 0 else { continue }
                for c in col..<n { m[r][c] -= factor * m[col][c] }
                y[r] -= factor * y[col]
            }
        }

        var out = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = y[r]
            for c in (r + 1)..<n { s -= m[r][c] * out[c] }
            out[r] = s / m[r][r]
        }
        return out
    }

    public static func matMul(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        let n = a.count, k = b.count, p = b.first?.count ?? 0
        var out = [[Double]](repeating: [Double](repeating: 0, count: p), count: n)
        for i in 0..<n {
            for j in 0..<p {
                var s = 0.0
                for l in 0..<k { s += a[i][l] * b[l][j] }
                out[i][j] = s
            }
        }
        return out
    }

    public static func matVec(_ a: [[Double]], _ v: [Double]) -> [Double] {
        a.map { row in zip(row, v).reduce(0) { $0 + $1.0 * $1.1 } }
    }

    public static func identity(_ n: Int) -> [[Double]] {
        (0..<n).map { i in (0..<n).map { $0 == i ? 1.0 : 0.0 } }
    }
}

// MARK: - 2. Butterworth filtering

/// One second-order section. Direct form II transposed, which is the numerically
/// well-behaved choice for the low frequencies we care about.
public struct Biquad: Sendable, Equatable {
    public var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var z1: Double = 0, z2: Double = 0

    public init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = b0 / a0; self.b1 = b1 / a0; self.b2 = b2 / a0
        self.a1 = a1 / a0; self.a2 = a2 / a0
    }

    public mutating func reset() { z1 = 0; z2 = 0 }

    /// Pre-loads the delay line so the filter starts in steady state with the
    /// given input. Without this, every filtered record begins with a transient
    /// that looks exactly like a P-wave arrival.
    public mutating func prime(with x: Double) {
        let denom = 1 + a1 + a2
        guard abs(denom) > 1e-12 else { z1 = 0; z2 = 0; return }
        let y = (b0 + b1 + b2) / denom * x      // DC gain applied to a constant input
        z2 = b2 * x - a2 * y
        z1 = b1 * x - a1 * y + z2
    }

    public mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    /// Magnitude response at a normalised frequency (cycles/sample, 0…0.5).
    public func magnitude(atNormalised f: Double) -> Double {
        let w = 2 * Double.pi * f
        let cw = cos(w), sw = sin(w), c2w = cos(2 * w), s2w = sin(2 * w)
        let nr = b0 + b1 * cw + b2 * c2w
        let ni = -(b1 * sw + b2 * s2w)
        let dr = 1 + a1 * cw + a2 * c2w
        let di = -(a1 * sw + a2 * s2w)
        let num = (nr * nr + ni * ni).squareRoot()
        let den = (dr * dr + di * di).squareRoot()
        return den > 0 ? num / den : 0
    }
}

/// Algorithm 2 — Butterworth bandpass, as a cascade of second-order sections.
///
/// The band matters: below about 0.05 Hz there is nothing but drift, and above
/// about 25 Hz there is nothing but electrical noise and the accelerometer's own
/// hiss. Filtering to the seismic band is what makes every later number stable.
public struct ButterworthFilter: Sendable {
    public enum Kind: Sendable, Equatable { case lowpass, highpass, bandpass }

    public let kind: Kind
    public let order: Int
    public let sampleRate: Double
    public let lowCutoff: Double
    public let highCutoff: Double
    private var sections: [Biquad]

    public init(kind: Kind, order: Int = 4, sampleRate: Double,
                lowCutoff: Double = 0.1, highCutoff: Double = 25) {
        self.kind = kind
        // Butterworth sections come in pairs of poles, so the order is rounded
        // up to even. An odd order would need a one-pole section as well.
        self.order = Swift.max(2, (order / 2) * 2)
        self.sampleRate = sampleRate
        let nyquist = sampleRate / 2
        self.lowCutoff = Swift.min(Swift.max(lowCutoff, 1e-4), nyquist * 0.98)
        self.highCutoff = Swift.min(Swift.max(highCutoff, lowCutoff * 1.01), nyquist * 0.98)

        var built: [Biquad] = []
        switch kind {
        case .lowpass:
            built = Self.sections(cutoff: self.highCutoff, sampleRate: sampleRate,
                                  order: self.order, highpass: false)
        case .highpass:
            built = Self.sections(cutoff: self.lowCutoff, sampleRate: sampleRate,
                                  order: self.order, highpass: true)
        case .bandpass:
            built = Self.sections(cutoff: self.lowCutoff, sampleRate: sampleRate,
                                  order: self.order, highpass: true)
                + Self.sections(cutoff: self.highCutoff, sampleRate: sampleRate,
                                order: self.order, highpass: false)
        }
        self.sections = built
    }

    /// Per-section Q values for a Butterworth cascade: the poles sit at equal
    /// angles on a semicircle, which is what makes the passband maximally flat.
    private static func sections(cutoff: Double, sampleRate: Double,
                                 order: Int, highpass: Bool) -> [Biquad] {
        let count = order / 2
        guard count > 0 else { return [] }
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let cosW = cos(w0), sinW = sin(w0)

        return (0..<count).map { k in
            let theta = Double.pi * (2 * Double(k) + 1) / (2 * Double(order))
            let q = 1 / (2 * cos(theta))
            let alpha = sinW / (2 * q)

            if highpass {
                let b0 = (1 + cosW) / 2
                return Biquad(b0: b0, b1: -(1 + cosW), b2: b0,
                              a0: 1 + alpha, a1: -2 * cosW, a2: 1 - alpha)
            } else {
                let b0 = (1 - cosW) / 2
                return Biquad(b0: b0, b1: 1 - cosW, b2: b0,
                              a0: 1 + alpha, a1: -2 * cosW, a2: 1 - alpha)
            }
        }
    }

    /// Single pass. Introduces phase distortion, which is fine for a live
    /// display but not for arrival picking.
    public func apply(_ x: [Double]) -> [Double] {
        guard !x.isEmpty else { return x }
        var s = sections
        for i in s.indices { s[i].reset(); s[i].prime(with: x[0]) }
        var out = x
        for i in s.indices {
            for j in out.indices { out[j] = s[i].process(out[j]) }
        }
        return out
    }

    /// How many samples the filter needs to settle.
    ///
    /// This is set by the *lowest* corner, not by the order: a 0.05 Hz high-pass
    /// has a time constant of several seconds regardless of how many poles it
    /// has. Sizing the edge padding by order instead — the obvious thing to do —
    /// leaves a slow filter still ringing when the record starts, which inflates
    /// the peak of an integrated trace by double figures of per cent.
    public var settlingSamples: Int {
        switch kind {
        case .lowpass:
            return 6 * order
        case .highpass, .bandpass:
            return Swift.max(Int(3 * sampleRate / Swift.max(lowCutoff, 1e-6)), 6 * order)
        }
    }

    /// Forward-backward pass: zero phase, so a picked arrival time is not
    /// shifted by the filter that cleaned the trace. Doubles the effective
    /// order, which the caller should account for.
    public func applyZeroPhase(_ x: [Double]) -> [Double] {
        guard x.count > 3 else { return apply(x) }
        // Reflect the ends before filtering so the edge transients happen in
        // padding that gets thrown away rather than in the record.
        let pad = Swift.min(settlingSamples, x.count - 1)
        var padded = [Double]()
        padded.reserveCapacity(x.count + 2 * pad)
        // Mirror (even) reflection, not the odd reflection `2·x[0] − x[i]` that
        // short-padding filters conventionally use. Odd reflection of an
        // oscillating signal about an endpoint sitting at an extreme produces a
        // padding with three times the true amplitude — harmless over a dozen
        // samples, ruinous over the thousands of samples a 0.05 Hz filter needs
        // to settle. Mirroring preserves amplitude exactly.
        for i in stride(from: pad, to: 0, by: -1) { padded.append(x[i]) }
        padded.append(contentsOf: x)
        let n = x.count
        for i in stride(from: n - 2, through: n - 1 - pad, by: -1) where i >= 0 {
            padded.append(x[i])
        }

        let forward = apply(padded)
        let reversed = Array(forward.reversed())
        let back = apply(reversed)
        let restored = Array(back.reversed())
        guard restored.count >= pad + n else { return apply(x) }
        return Array(restored[pad..<(pad + n)])
    }

    public func apply(_ w: Waveform) -> Waveform { w.mapped { applyZeroPhase($0) } }

    /// The magnitude response, for the processing-chain screen. A filter the
    /// user cannot see the shape of is a filter they cannot trust.
    public func frequencyResponse(points: Int = 256) -> [(frequency: Double, gain: Double)] {
        let nyquist = sampleRate / 2
        return (0..<points).map { i in
            let f = nyquist * Double(i) / Double(points - 1)
            let normalised = f / sampleRate
            let gain = sections.reduce(1.0) { $0 * $1.magnitude(atNormalised: normalised) }
            return (f, gain)
        }
    }
}

// MARK: - 3. Windowing

/// Algorithm 3 — taper functions and overlapped framing.
///
/// A rectangular window smears energy across every frequency bin, which invents
/// peaks that are not there. Since the whole point is finding a real peak and
/// tracking it to within a per cent, tapering is not optional.
public enum Window: String, CaseIterable, Sendable, Identifiable {
    case rectangular, hann, hamming, blackman
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .rectangular: "Rectangular (none)"
        case .hann: "Hann"
        case .hamming: "Hamming"
        case .blackman: "Blackman"
        }
    }

    public var explanation: String {
        switch self {
        case .rectangular: "No taper. Sharpest possible resolution, worst possible leakage."
        case .hann: "The default. Clean sidelobes, mild widening. Right for modal peaks."
        case .hamming: "Slightly narrower main lobe than Hann, at the cost of a higher first sidelobe."
        case .blackman: "Heaviest taper. Use when a strong peak is drowning a weak neighbour."
        }
    }

    public func coefficients(_ n: Int) -> [Double] {
        guard n > 1 else { return [Double](repeating: 1, count: Swift.max(n, 0)) }
        let denom = Double(n - 1)
        return (0..<n).map { i in
            let t = Double(i) / denom
            switch self {
            case .rectangular: return 1
            case .hann: return 0.5 - 0.5 * cos(2 * .pi * t)
            case .hamming: return 0.54 - 0.46 * cos(2 * .pi * t)
            case .blackman: return 0.42 - 0.5 * cos(2 * .pi * t) + 0.08 * cos(4 * .pi * t)
            }
        }
    }

    /// Coherent gain — the factor a window removes from the signal amplitude,
    /// which must be divided back out or every spectrum reads low.
    public func coherentGain(_ n: Int) -> Double {
        let c = coefficients(n)
        return c.isEmpty ? 1 : Stats.mean(c)
    }

    /// Noise power bandwidth, needed to scale a power spectral density correctly.
    public func noisePowerBandwidth(_ n: Int) -> Double {
        let c = coefficients(n)
        guard !c.isEmpty else { return 1 }
        let sumSq = c.reduce(0) { $0 + $1 * $1 }
        let sum = c.reduce(0, +)
        return Double(n) * sumSq / (sum * sum)
    }

    public func apply(_ x: [Double]) -> [Double] {
        let c = coefficients(x.count)
        return zip(x, c).map(*)
    }
}

public enum Framing {
    /// Splits a signal into overlapped frames. Returns whole frames only —
    /// zero-padding a short tail would bias every statistic computed from it.
    public static func frames(_ x: [Double], length: Int, overlap: Double = 0.5) -> [[Double]] {
        guard length > 0, x.count >= length else { return [] }
        let clampedOverlap = Swift.min(Swift.max(overlap, 0), 0.95)
        let hop = Swift.max(Int(Double(length) * (1 - clampedOverlap)), 1)
        var out: [[Double]] = []
        var start = 0
        while start + length <= x.count {
            out.append(Array(x[start..<(start + length)]))
            start += hop
        }
        return out
    }
}

// MARK: - 4. Baseline correction

public enum BaselineCorrection {

    /// Algorithm 4 — the classic acceleration baseline correction.
    ///
    /// Even after detrending, a strong-motion record usually has a small
    /// residual velocity at the end, which is physically impossible: the ground
    /// stops moving. Fitting and removing the acceleration correction that makes
    /// the final velocity zero is what makes the displacement trace believable.
    public static func apply(_ x: [Double], sampleRate: Double) -> [Double] {
        guard x.count > 4 else { return Detrend.removeDCOffset(x) }
        // DC removal, not a least-squares line.
        //
        // Fitting a line to an oscillatory record that does not end on a whole
        // cycle finds a slope that is an artefact of where the record happens to
        // stop. Subtracting it *injects* a genuine linear acceleration trend,
        // which the second integration turns into a parabola — the displacement
        // then comes out several times too large. Removing the mean cannot do
        // that, and the actual drift is handled by the high-pass afterwards.
        let detrended = Detrend.removeDCOffset(x)
        let dt = 1 / sampleRate

        // Integrate to velocity, fit a line to it, and differentiate that line
        // back into an acceleration correction.
        let velocity = Integration.trapezoidal(detrended, dt: dt)
        let t = (0..<velocity.count).map { Double($0) * dt }
        let fit = Stats.linearRegression(x: t, y: velocity)

        // d/dt of (slope·t + intercept) is just the slope: a constant offset.
        return detrended.map { $0 - fit.slope }
    }

    /// Iterative variant that also drives the *end* velocity to zero, used for
    /// records where the simple correction leaves a visible residual.
    public static func iterative(_ x: [Double], sampleRate: Double,
                                 iterations: Int = 3) -> [Double] {
        var out = apply(x, sampleRate: sampleRate)
        let dt = 1 / sampleRate
        for _ in 0..<Swift.max(iterations - 1, 0) {
            let v = Integration.trapezoidal(out, dt: dt)
            guard let endVelocity = v.last, abs(endVelocity) > 1e-9 else { break }
            let correction = endVelocity / (Double(out.count) * dt)
            out = out.map { $0 - correction }
        }
        return out
    }
}

// MARK: - 5 & 6. Integration and post-integration drift removal

public enum Integration {

    /// Algorithm 5 — trapezoidal cumulative integration.
    ///
    /// The accelerometer measures acceleration, but an engineer reasons about
    /// displacement. Two integrations separate the two, and each one amplifies
    /// low-frequency error enormously — hence algorithm 6 immediately after.
    public static func trapezoidal(_ x: [Double], dt: Double) -> [Double] {
        guard x.count > 1 else { return [Double](repeating: 0, count: x.count) }
        var out = [Double](repeating: 0, count: x.count)
        for i in 1..<x.count {
            out[i] = out[i - 1] + 0.5 * (x[i] + x[i - 1]) * dt
        }
        return out
    }

    /// Simpson's rule, for smooth integrands where the extra accuracy is worth
    /// having.
    ///
    /// Note the odd indices: the naive composite recurrence
    /// `out[i] = out[i−2] + …` advances two independent interleaved chains, so
    /// even a strictly non-negative integrand can produce a cumulative curve
    /// that dips. Anything read as a monotonic build-up — a Husid plot above all
    /// — must not use that form. Here the even points take the Simpson step and
    /// the odd points close the gap with a trapezoid from their own predecessor.
    public static func simpson(_ x: [Double], dt: Double) -> [Double] {
        guard x.count > 2 else { return trapezoidal(x, dt: dt) }
        var out = [Double](repeating: 0, count: x.count)
        for i in 1..<x.count {
            if i % 2 == 0 {
                out[i] = out[i - 2] + dt / 3 * (x[i - 2] + 4 * x[i - 1] + x[i])
            } else {
                out[i] = out[i - 1] + 0.5 * (x[i - 1] + x[i]) * dt
            }
        }
        return out
    }

    /// Algorithm 6 — high-pass the result of an integration.
    ///
    /// Integration turns a tiny constant error into a ramp. A gentle high-pass
    /// afterwards removes exactly that, and nothing a building does.
    public static func removeDrift(_ x: [Double], sampleRate: Double,
                                   cornerFrequency: Double = 0.05) -> [Double] {
        guard x.count > 8 else { return Detrend.removeDCOffset(x) }
        let hp = ButterworthFilter(kind: .highpass, order: 2, sampleRate: sampleRate,
                                   lowCutoff: cornerFrequency)
        // Mean removal only — see the note in `BaselineCorrection.apply` on why a
        // least-squares detrend here would defeat the whole purpose. The filter
        // removes the actual drift, and it settles inside its own padding.
        return hp.applyZeroPhase(Detrend.removeDCOffset(x))
    }

    /// The full, correct path from a raw acceleration record to velocity and
    /// displacement. This is what the event replay screen plots.
    public static func toVelocityAndDisplacement(
        acceleration: Waveform, cornerFrequency: Double = 0.05
    ) -> (velocity: Waveform, displacement: Waveform) {
        let dt = acceleration.dt
        let corrected = BaselineCorrection.iterative(acceleration.samples,
                                                     sampleRate: acceleration.sampleRate)

        let rawVelocity = trapezoidal(corrected, dt: dt)
        let velocity = removeDrift(rawVelocity, sampleRate: acceleration.sampleRate,
                                   cornerFrequency: cornerFrequency)

        let rawDisplacement = trapezoidal(velocity, dt: dt)
        let displacement = removeDrift(rawDisplacement, sampleRate: acceleration.sampleRate,
                                       cornerFrequency: cornerFrequency)

        return (
            Waveform(samples: velocity, sampleRate: acceleration.sampleRate,
                     startTime: acceleration.startTime, unit: .velocity),
            Waveform(samples: displacement, sampleRate: acceleration.sampleRate,
                     startTime: acceleration.startTime, unit: .displacement)
        )
    }

    /// Central-difference differentiation, the inverse operation. Used to turn a
    /// simulated displacement history back into the acceleration a sensor would
    /// have seen, so simulated and measured records can be compared like for like.
    public static func differentiate(_ x: [Double], dt: Double) -> [Double] {
        guard x.count > 2 else { return [Double](repeating: 0, count: x.count) }
        var out = [Double](repeating: 0, count: x.count)
        out[0] = (x[1] - x[0]) / dt
        out[x.count - 1] = (x[x.count - 1] - x[x.count - 2]) / dt
        for i in 1..<(x.count - 1) { out[i] = (x[i + 1] - x[i - 1]) / (2 * dt) }
        return out
    }
}

// MARK: - 7. Reservoir sampling

/// Algorithm 7 — a statistically fair sample of a stream with no end, in fixed
/// memory.
///
/// The node runs for months. Long-run statistics — the ambient vibration
/// distribution, the temperature-period relationship — have to be built from a
/// sample that is not biased towards whenever the app happened to be open.
public struct ReservoirSampler<T>: Sendable where T: Sendable {
    public private(set) var reservoir: [T] = []
    public private(set) var seen: Int = 0
    public let capacity: Int
    private var rng: SeededRandom

    public init(capacity: Int, seed: UInt64 = 0x5E15_1C00_0000_0001) {
        self.capacity = Swift.max(capacity, 1)
        self.rng = SeededRandom(seed: seed)
        reservoir.reserveCapacity(self.capacity)
    }

    public mutating func add(_ item: T) {
        seen += 1
        if reservoir.count < capacity {
            reservoir.append(item)
        } else {
            // Algorithm R: replace with probability capacity/seen, which keeps
            // every element ever seen equally likely to be in the reservoir.
            let j = Int(rng.uniform(0, Double(seen)))
            if j < capacity { reservoir[j] = item }
        }
    }

    public mutating func add(contentsOf items: [T]) { for i in items { add(i) } }

    public var isSaturated: Bool { seen > capacity }

    /// The fraction of the stream retained — shown on the diagnostics screen so
    /// the user knows how heavily the long-run statistics are subsampled.
    public var retentionFraction: Double {
        seen == 0 ? 1 : Double(Swift.min(reservoir.count, capacity)) / Double(seen)
    }
}

// MARK: - 8. Douglas-Peucker decimation

public enum Decimation {

    /// Algorithm 8 — Douglas-Peucker polyline simplification.
    ///
    /// A one-minute record at 200 Hz is 12,000 points being drawn into maybe 350
    /// pixels. Naive subsampling drops the peaks, which are the only part
    /// anybody cares about. Douglas-Peucker keeps every point that changes the
    /// shape by more than a tolerance, so the peak always survives.
    public static func douglasPeucker(_ points: [(x: Double, y: Double)],
                                      tolerance: Double) -> [(x: Double, y: Double)] {
        guard points.count > 2, tolerance > 0 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true

        // Iterative rather than recursive: a pathological input could otherwise
        // recurse 12,000 deep and blow the stack on a background thread.
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var maxDist = 0.0
            var index = first

            let ax = points[first].x, ay = points[first].y
            let bx = points[last].x, by = points[last].y
            let dx = bx - ax, dy = by - ay
            let lenSq = dx * dx + dy * dy

            for i in (first + 1)..<last {
                let px = points[i].x - ax, py = points[i].y - ay
                let dist: Double
                if lenSq < 1e-18 {
                    dist = (px * px + py * py).squareRoot()
                } else {
                    // Perpendicular distance to the chord.
                    dist = abs(px * dy - py * dx) / lenSq.squareRoot()
                }
                if dist > maxDist { maxDist = dist; index = i }
            }

            if maxDist > tolerance {
                keep[index] = true
                stack.append((first, index))
                stack.append((index, last))
            }
        }

        return points.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    /// Convenience for a waveform: decimates to roughly `targetPoints`, choosing
    /// the tolerance from the signal's own amplitude so it works on a 0.001 m/s²
    /// ambient trace and a 10 m/s² event record alike.
    public static func forDisplay(_ w: Waveform, targetPoints: Int) -> [(x: Double, y: Double)] {
        guard w.count > targetPoints, targetPoints > 2 else {
            return w.samples.enumerated().map { (w.time(at: $0.offset), $0.element) }
        }
        let points = w.samples.enumerated().map { (x: w.time(at: $0.offset), y: $0.element) }
        let amplitude = Swift.max(w.peakAbsolute, 1e-12)

        // Binary search the tolerance that lands near the target count. Two or
        // three iterations is plenty; exactness is not the point.
        var lo = amplitude * 1e-6, hi = amplitude
        var best = points
        for _ in 0..<12 {
            let mid = (lo * hi).squareRoot()          // geometric bisection
            let candidate = douglasPeucker(points, tolerance: mid)
            if candidate.count > targetPoints {
                lo = mid
            } else {
                hi = mid
                best = candidate
                if candidate.count > targetPoints / 2 { break }
            }
        }
        return best
    }

    /// Min/max decimation — the other honest way to draw a dense trace. For each
    /// output column it keeps both the highest and lowest sample, so the drawn
    /// envelope is exactly the true envelope.
    public static func minMax(_ w: Waveform, columns: Int) -> [(x: Double, min: Double, max: Double)] {
        guard w.count > 0, columns > 0 else { return [] }
        let per = Swift.max(w.count / columns, 1)
        var out: [(x: Double, min: Double, max: Double)] = []
        out.reserveCapacity(columns)
        var i = 0
        while i < w.count {
            let end = Swift.min(i + per, w.count)
            var lo = w.samples[i], hi = w.samples[i]
            for j in i..<end {
                lo = Swift.min(lo, w.samples[j])
                hi = Swift.max(hi, w.samples[j])
            }
            out.append((w.time(at: i), lo, hi))
            i = end
        }
        return out
    }
}
