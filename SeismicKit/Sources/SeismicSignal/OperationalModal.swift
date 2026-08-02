import Foundation
import SeismicCore

// MARK: - 63. Frequency Domain Decomposition

/// Algorithm 63 — Frequency Domain Decomposition.
///
/// Welch peak-picking, which is what this app used alone, asks one channel at a
/// time "where is the biggest peak". That fails in exactly the case a building
/// most often presents: two modes at nearly the same frequency. A tower sways
/// north-south and east-west at periods a few per cent apart, and a single
/// channel sees one broad hump where there are two peaks — so the app reports a
/// period between two real ones, belonging to neither, and then reports it
/// changing as the two swap dominance.
///
/// FDD fixes it by using all three channels at once. At every frequency it
/// forms the cross-spectral density matrix — how each channel co-varies with
/// each other channel at that frequency — and decomposes it. A genuine mode
/// makes that matrix rank one, because at a resonance every point of the
/// structure moves in phase with a fixed shape; the dominant eigenvalue spikes
/// and the dominant eigenvector *is* the mode shape. Two modes close together
/// produce two large eigenvalues, and the second singular value curve separates
/// them where no single-channel spectrum could.
///
/// This is the standard method of operational modal analysis, and "operational"
/// is the point: it needs no hammer, no shaker and no earthquake, only the
/// building's ordinary ambient wobble.
public enum FrequencyDomainDecomposition {

    public struct Result: Sendable, Equatable {
        /// Frequency of each bin, Hz.
        public var frequencies: [Double]
        /// The first singular value at each bin. Peaks here are candidate modes.
        public var firstSingularValues: [Double]
        /// The second, which is what reveals a close pair.
        public var secondSingularValues: [Double]
        /// The dominant eigenvector at each bin, as three real magnitudes —
        /// the mode shape across the three channels.
        public var dominantShapes: [[Double]]

        public init(frequencies: [Double], firstSingularValues: [Double],
                    secondSingularValues: [Double], dominantShapes: [[Double]]) {
            self.frequencies = frequencies
            self.firstSingularValues = firstSingularValues
            self.secondSingularValues = secondSingularValues
            self.dominantShapes = dominantShapes
        }

        /// Whether two modes are sitting on top of each other near `frequency`.
        ///
        /// The test is the ratio of the second singular value to the first. Well
        /// separated modes leave the second near the noise floor; a close pair
        /// lifts it to within a few decibels of the first. Reported because the
        /// consequence is specific — a period history built through a close pair
        /// will show jumps that are not damage.
        public func hasClosePair(near frequency: Double, tolerance: Double = 0.15) -> Bool {
            guard let index = nearestIndex(to: frequency) else { return false }
            let first = firstSingularValues[index]
            guard first > 0 else { return false }
            return secondSingularValues[index] / first > 0.5 && tolerance > 0
        }

        public func nearestIndex(to frequency: Double) -> Int? {
            frequencies.indices.min { abs(frequencies[$0] - frequency)
                                    < abs(frequencies[$1] - frequency) }
        }
    }

    /// Runs FDD over three channels.
    ///
    /// - Parameter segmentLength: rounded up to a power of two. Longer resolves
    ///   closer modes and averages fewer segments, which is the usual bargain.
    public static func run(_ record: TriaxialRecord,
                           segmentLength: Int = 1024,
                           overlap: Double = 0.5) -> Result? {
        let channels = [record.x.samples, record.y.samples, record.z.samples]
        let n = channels.map(\.count).min() ?? 0
        let size = FFT.nextPowerOfTwo(max(segmentLength, 64))
        guard n >= size else { return nil }

        let step = max(Int(Double(size) * (1 - min(max(overlap, 0), 0.95))), 1)
        let window = Window.hann.coefficients(size)
        let windowPower = window.reduce(0) { $0 + $1 * $1 } / Double(size)
        let bins = size / 2

        // The cross-spectral density matrix, accumulated over segments.
        // G[i][j][bin] = average of X_i(f) * conj(X_j(f)).
        var crossSpectra = [[[Complex]]](
            repeating: [[Complex]](repeating: [Complex](repeating: Complex(0, 0), count: bins),
                                   count: 3),
            count: 3)

        var segments = 0
        var start = 0
        while start + size <= n {
            // Windowed FFT of each channel for this segment.
            var transforms: [[Complex]] = []
            for channel in channels {
                let block = (0..<size).map { channel[start + $0] * window[$0] }
                transforms.append(FFT.realForward(block))
            }
            for i in 0..<3 {
                for j in 0..<3 {
                    for bin in 0..<bins {
                        let a = transforms[i][bin]
                        let b = transforms[j][bin]
                        // a * conj(b)
                        let product = Complex(a.re * b.re + a.im * b.im,
                                              a.im * b.re - a.re * b.im)
                        crossSpectra[i][j][bin] = crossSpectra[i][j][bin] + product
                    }
                }
            }
            segments += 1
            start += step
        }
        guard segments > 0 else { return nil }

        let scale = 1 / (Double(segments) * Double(size) * record.sampleRate * windowPower)
        var frequencies = [Double](repeating: 0, count: bins)
        var first = [Double](repeating: 0, count: bins)
        var second = [Double](repeating: 0, count: bins)
        var shapes = [[Double]](repeating: [0, 0, 0], count: bins)

        for bin in 0..<bins {
            frequencies[bin] = Double(bin) * record.sampleRate / Double(size)

            var matrix = [[Complex]](repeating: [Complex](repeating: Complex(0, 0), count: 3),
                                     count: 3)
            for i in 0..<3 {
                for j in 0..<3 {
                    let value = crossSpectra[i][j][bin]
                    matrix[i][j] = Complex(value.re * scale, value.im * scale)
                }
            }

            let dominant = dominantEigenpair(matrix)
            first[bin] = dominant.value
            shapes[bin] = dominant.vector

            // Deflate and repeat for the second. Because the matrix is
            // Hermitian and positive semi-definite, subtracting λ₁v₁v₁ᴴ leaves
            // the remaining spectrum untouched — which is what makes a second
            // pass legitimate rather than merely convenient.
            let deflated = deflate(matrix, value: dominant.value, vector: dominant.complexVector)
            second[bin] = dominantEigenpair(deflated).value
        }

        return Result(frequencies: frequencies, firstSingularValues: first,
                      secondSingularValues: second, dominantShapes: shapes)
    }

    /// Dominant eigenvalue and eigenvector of a small Hermitian matrix, by
    /// power iteration.
    ///
    /// Power iteration rather than a full decomposition because only the top
    /// one or two pairs are ever wanted, the matrix is three by three, and this
    /// runs once per frequency bin — five hundred times per measurement. The
    /// convergence rate is the ratio of the top two eigenvalues, which for a
    /// real resonance is precisely the case where it converges fastest.
    static func dominantEigenpair(_ matrix: [[Complex]])
        -> (value: Double, vector: [Double], complexVector: [Complex])
    {
        let n = matrix.count
        var v = [Complex](repeating: Complex(1 / Double(n).squareRoot(), 0), count: n)
        var value = 0.0

        for _ in 0..<32 {
            var next = [Complex](repeating: Complex(0, 0), count: n)
            for i in 0..<n {
                for j in 0..<n {
                    next[i] = next[i] + matrix[i][j] * v[j]
                }
            }
            let norm = next.reduce(0) { $0 + $1.re * $1.re + $1.im * $1.im }.squareRoot()
            guard norm > 1e-300 else { return (0, [0, 0, 0], v) }
            for i in 0..<n { next[i] = Complex(next[i].re / norm, next[i].im / norm) }
            value = norm
            // Converged when the vector stops moving.
            let delta = zip(v, next).reduce(0.0) {
                $0 + abs($1.0.re - $1.1.re) + abs($1.0.im - $1.1.im)
            }
            v = next
            if delta < 1e-12 { break }
        }

        let magnitudes = v.map { ($0.re * $0.re + $0.im * $0.im).squareRoot() }
        let peak = magnitudes.max() ?? 1
        return (value, peak > 0 ? magnitudes.map { $0 / peak } : magnitudes, v)
    }

    /// G − λ v vᴴ.
    static func deflate(_ matrix: [[Complex]], value: Double,
                        vector: [Complex]) -> [[Complex]] {
        var out = matrix
        for i in 0..<matrix.count {
            for j in 0..<matrix.count {
                // v_i * conj(v_j)
                let outer = Complex(vector[i].re * vector[j].re + vector[i].im * vector[j].im,
                                    vector[i].im * vector[j].re - vector[i].re * vector[j].im)
                out[i][j] = Complex(out[i][j].re - value * outer.re,
                                    out[i][j].im - value * outer.im)
            }
        }
        return out
    }
}

// MARK: - 64. Prony pole extraction

/// Algorithm 64 — Prony / linear-prediction pole extraction.
///
/// Everything else in this app measures *one* period. A real building has
/// several, and after damage the interesting question is often which of them
/// moved — a soft ground storey shifts the first mode and leaves the third
/// alone, while a uniformly cracked frame moves all of them together. Telling
/// those apart needs every mode at once, with its own damping.
///
/// Prony's method does that. It assumes the free decay is a sum of damped
/// complex exponentials — which for a linear structure it provably is — and
/// solves for them directly. A linear-prediction fit gives the coefficients of
/// a polynomial whose roots are the poles; each root carries both a frequency
/// and a decay rate, so damping falls out of the same fit rather than needing a
/// separate envelope measurement.
///
/// It pairs with `RandomDecrement`, which is what turns ordinary ambient
/// vibration into the free decay this needs. Together they measure every mode
/// and every damping ratio of an occupied building without touching it.
public enum PronyAnalysis {

    public struct Pole: Sendable, Equatable, Identifiable {
        public var id: Int { Int(frequency * 1000) }
        public var frequency: Double        // Hz
        public var damping: Double          // fraction of critical
        /// Contribution to the signal, used to drop numerical junk.
        public var amplitude: Double
        public var period: Double { frequency > 0 ? 1 / frequency : 0 }

        public init(frequency: Double, damping: Double, amplitude: Double) {
            self.frequency = frequency
            self.damping = damping
            self.amplitude = amplitude
        }
    }

    /// Extracts up to `order / 2` damped sinusoids from a decay.
    ///
    /// - Parameter order: the linear-prediction order, twice the number of
    ///   modes sought. Over-specifying is normal and expected: the extra poles
    ///   absorb noise, and the ones that matter are separated afterwards by
    ///   amplitude and by whether they survive a change of order — see
    ///   `StabilisationDiagram`.
    public static func poles(of signal: [Double], sampleRate: Double,
                             order: Int = 12) -> [Pole] {
        let n = signal.count
        let p = max(2, min(order, n / 3))
        guard n > 3 * p, sampleRate > 0 else { return [] }

        // Least-squares linear prediction: find a such that
        // x[k] ≈ -Σ a[i] x[k-1-i]. Solved through the normal equations, which
        // for the orders used here (under about thirty) is stable enough and
        // avoids carrying a QR routine for one call site.
        var normal = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        var rhs = [Double](repeating: 0, count: p)
        for k in p..<n {
            for i in 0..<p {
                rhs[i] -= signal[k - 1 - i] * signal[k]
                for j in 0..<p {
                    normal[i][j] += signal[k - 1 - i] * signal[k - 1 - j]
                }
            }
        }
        // Ridge term. The prediction matrix of a clean two-mode decay is close
        // to singular by construction — that is what having only two modes
        // *means* — so without this the solve fails on exactly the tidiest
        // input rather than on the messiest.
        let trace = (0..<p).reduce(0.0) { $0 + normal[$1][$1] }
        let ridge = max(trace / Double(p), 1e-12) * 1e-9
        for i in 0..<p { normal[i][i] += ridge }

        guard let a = solve(normal, rhs) else { return [] }

        // Roots of z^p + a[0] z^(p-1) + … + a[p-1].
        var coefficients = [Complex(1, 0)]
        coefficients.append(contentsOf: a.map { Complex($0, 0) })
        let roots = durandKerner(coefficients)

        let dt = 1 / sampleRate
        var found: [Pole] = []
        for root in roots {
            let magnitude = (root.re * root.re + root.im * root.im).squareRoot()
            guard magnitude > 1e-9, magnitude < 1.5 else { continue }
            // s = ln(z) / dt
            let sigma = Foundation.log(magnitude) / dt
            let omega = atan2(root.im, root.re) / dt
            // Conjugate pairs describe the same mode; keep the positive one.
            guard omega > 1e-6 else { continue }
            let natural = (sigma * sigma + omega * omega).squareRoot()
            guard natural > 1e-9 else { continue }
            let damping = -sigma / natural
            // A growing pole is a fitting artefact: a building does not gain
            // energy after the shaking stops.
            guard damping > -0.02, damping < 0.99 else { continue }
            found.append(Pole(frequency: omega / (2 * .pi),
                              damping: max(damping, 0),
                              amplitude: magnitude))
        }
        return found.sorted { $0.frequency < $1.frequency }
    }

    /// Gaussian elimination with partial pivoting.
    static func solve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        let n = rhs.count
        var a = matrix, b = rhs
        for column in 0..<n {
            var pivot = column
            for row in (column + 1)..<n where abs(a[row][column]) > abs(a[pivot][column]) {
                pivot = row
            }
            guard abs(a[pivot][column]) > 1e-18 else { return nil }
            if pivot != column { a.swapAt(pivot, column); b.swapAt(pivot, column) }
            for row in (column + 1)..<n {
                let factor = a[row][column] / a[column][column]
                guard factor != 0 else { continue }
                for k in column..<n { a[row][k] -= factor * a[column][k] }
                b[row] -= factor * b[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n { sum -= a[row][k] * x[k] }
            x[row] = sum / a[row][row]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    /// Durand–Kerner simultaneous root finding.
    ///
    /// Chosen over building a companion matrix and running a QR eigensolver
    /// because it is thirty lines, converges on every polynomial that arises
    /// here, and finds all roots at once including complex ones — which is the
    /// entire requirement, since a real mode *is* a complex conjugate pair.
    static func durandKerner(_ coefficients: [Complex],
                             iterations: Int = 500) -> [Complex] {
        guard let leading = coefficients.first,
              leading.re != 0 || leading.im != 0 else { return [] }
        let degree = coefficients.count - 1
        guard degree >= 1 else { return [] }

        let normalised = coefficients.map {
            divide($0, by: leading)
        }

        // Spread the initial guesses around a circle, off the real axis so a
        // polynomial with real coefficients cannot leave them all stuck on it.
        var roots: [Complex] = (0..<degree).map { k in
            let angle = 2 * Double.pi * Double(k) / Double(degree) + 0.35
            return Complex(0.85 * cos(angle), 0.85 * sin(angle))
        }

        for _ in 0..<iterations {
            var moved = 0.0
            for i in 0..<degree {
                var numerator = evaluate(normalised, at: roots[i])
                var denominator = Complex(1, 0)
                for j in 0..<degree where j != i {
                    denominator = denominator * (roots[i] - roots[j])
                }
                let magnitude = denominator.re * denominator.re
                              + denominator.im * denominator.im
                guard magnitude > 1e-300 else { continue }
                numerator = divide(numerator, by: denominator)
                roots[i] = roots[i] - numerator
                moved += abs(numerator.re) + abs(numerator.im)
            }
            if moved < 1e-14 { break }
        }
        return roots
    }

    static func evaluate(_ coefficients: [Complex], at z: Complex) -> Complex {
        var result = Complex(0, 0)
        for coefficient in coefficients { result = result * z + coefficient }
        return result
    }

    static func divide(_ a: Complex, by b: Complex) -> Complex {
        let magnitude = b.re * b.re + b.im * b.im
        guard magnitude > 1e-300 else { return Complex(0, 0) }
        return Complex((a.re * b.re + a.im * b.im) / magnitude,
                       (a.im * b.re - a.re * b.im) / magnitude)
    }
}

// MARK: - 65. Stabilisation diagram

/// Algorithm 65 — the stabilisation diagram.
///
/// Every system-identification method has the same failure: raise the model
/// order and it finds more modes, and it cannot tell you which of them are
/// real. Fit order six to a two-mode building and you get two modes; fit order
/// twenty and you get ten, eight of which are the algorithm modelling the noise
/// floor. Nothing in the fit itself distinguishes them.
///
/// The stabilisation diagram is the standard answer and it is beautifully
/// simple: run the identification at every order from low to high, and keep
/// only the poles that keep coming back. A physical mode is a property of the
/// building, so it appears at order six and is still there at order twenty, at
/// the same frequency and the same damping. A numerical mode is a property of
/// the fit, so it moves every time the fit changes.
///
/// This is what makes an automatic overnight measurement trustworthy enough to
/// write to the record without a person looking at it.
public enum StabilisationDiagram {

    public struct StablePole: Sendable, Equatable, Identifiable {
        public var id: Int { Int(frequency * 1000) }
        public var frequency: Double
        public var damping: Double
        /// How many model orders this pole survived.
        public var appearances: Int
        /// Spread of the frequency across those orders, as a fraction.
        public var frequencyScatter: Double
        /// 0–1. Combines how often it appeared with how still it stayed.
        public var stability: Double

        public init(frequency: Double, damping: Double, appearances: Int,
                    frequencyScatter: Double, stability: Double) {
            self.frequency = frequency
            self.damping = damping
            self.appearances = appearances
            self.frequencyScatter = frequencyScatter
            self.stability = stability
        }
    }

    /// - Parameters:
    ///   - orders: the model orders to try. Defaults to a sweep wide enough
    ///     that a mode surviving all of it is not surviving by chance.
    ///   - frequencyTolerance: how close two poles from different orders have
    ///     to be to count as the same one.
    public static func run(_ signal: [Double], sampleRate: Double,
                           orders: [Int] = Array(stride(from: 4, through: 24, by: 2)),
                           frequencyTolerance: Double = 0.02) -> [StablePole] {
        var clusters: [(frequencies: [Double], dampings: [Double], orders: Set<Int>)] = []

        for order in orders {
            for pole in PronyAnalysis.poles(of: signal, sampleRate: sampleRate, order: order) {
                guard pole.frequency > 0 else { continue }
                if let index = clusters.firstIndex(where: { cluster in
                    let mean = Stats.mean(cluster.frequencies)
                    guard mean > 0 else { return false }
                    return abs(pole.frequency - mean) / mean <= frequencyTolerance
                }) {
                    clusters[index].frequencies.append(pole.frequency)
                    clusters[index].dampings.append(pole.damping)
                    clusters[index].orders.insert(order)
                } else {
                    clusters.append(([pole.frequency], [pole.damping], [order]))
                }
            }
        }

        let total = max(orders.count, 1)
        return clusters.compactMap { cluster in
            let frequency = Stats.mean(cluster.frequencies)
            let damping = Stats.mean(cluster.dampings)
            guard frequency > 0 else { return nil }
            let scatter = cluster.frequencies.count > 1
                ? Stats.stdDev(cluster.frequencies) / frequency
                : 0
            let persistence = Double(cluster.orders.count) / Double(total)
            // Both halves matter. A pole present at every order but wandering in
            // frequency is a fit artefact tracking the noise; one that is rock
            // steady but appears twice is a coincidence.
            let stability = persistence * max(1 - scatter / frequencyTolerance, 0)
            return StablePole(frequency: frequency, damping: damping,
                              appearances: cluster.orders.count,
                              frequencyScatter: scatter,
                              stability: min(max(stability, 0), 1))
        }
        .filter { $0.appearances >= 2 }
        .sorted { $0.stability > $1.stability }
    }
}

// MARK: - 66 and 67. Mode shape comparison

/// Algorithms 66 and 67 — the Modal Assurance Criterion and its coordinate form.
///
/// A period that has lengthened by fifteen per cent says a building has
/// softened. It does not say *where*, and "where" is the difference between an
/// inspection that starts on the right floor and one that starts at the front
/// door.
///
/// The mode shape carries that information, and MAC is how two shapes are
/// compared: it is the squared cosine of the angle between them as vectors, so
/// it is one when they are the same shape at any scale and zero when they are
/// orthogonal. Comparing this month's shape against the baseline gives a single
/// number for "is it still moving the same way".
///
/// COMAC then takes the same idea one coordinate at a time. Instead of asking
/// how similar the shapes are overall, it asks how consistently each storey
/// participates across every mode. A storey that has lost stiffness stops
/// moving with the rest, so its COMAC value drops while its neighbours' stay
/// near one — and that dip is a floor number.
public enum ModeShapeComparison {

    /// Algorithm 66 — MAC between two mode shapes. 1 is identical, 0 is
    /// unrelated.
    public static func mac(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var cross = 0.0, normA = 0.0, normB = 0.0
        for i in a.indices {
            cross += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 1e-18, normB > 1e-18 else { return 0 }
        return (cross * cross) / (normA * normB)
    }

    /// The full MAC matrix between two sets of modes, which is how mode pairing
    /// is done: each new mode is matched to whichever old mode it most
    /// resembles, rather than to whichever happened to come out in the same
    /// position.
    public static func macMatrix(_ before: [[Double]], _ after: [[Double]]) -> [[Double]] {
        before.map { a in after.map { mac(a, $0) } }
    }

    public struct StoreyConsistency: Sendable, Equatable, Identifiable {
        public var id: Int { storey }
        /// Numbered from 1, the lowest occupied storey.
        public var storey: Int
        /// COMAC value. Near 1 is unchanged; a dip is where the change is.
        public var value: Double

        public init(storey: Int, value: Double) {
            self.storey = storey; self.value = value
        }
    }

    /// Algorithm 67 — COMAC, per storey.
    ///
    /// Needs at least two mode pairs to say anything: with one mode, every
    /// coordinate trivially agrees with itself and the result is a row of ones.
    public static func comac(before: [[Double]], after: [[Double]]) -> [StoreyConsistency] {
        guard before.count == after.count, before.count >= 2,
              let coordinates = before.first?.count, coordinates > 0,
              before.allSatisfy({ $0.count == coordinates }),
              after.allSatisfy({ $0.count == coordinates }) else { return [] }

        // Normalise each shape so a change of scale between measurements — a
        // windier night, a heavier lorry — cannot look like a change of shape.
        let a = before.map(normalised)
        let b = after.map(normalised)

        var result: [StoreyConsistency] = []
        for coordinate in 0..<coordinates {
            var numerator = 0.0, sumA = 0.0, sumB = 0.0
            for mode in a.indices {
                numerator += abs(a[mode][coordinate] * b[mode][coordinate])
                sumA += a[mode][coordinate] * a[mode][coordinate]
                sumB += b[mode][coordinate] * b[mode][coordinate]
            }
            let denominator = sumA * sumB
            let value = denominator > 1e-18
                ? min((numerator * numerator) / denominator, 1)
                : 0
            result.append(StoreyConsistency(storey: coordinate + 1, value: value))
        }
        return result
    }

    /// The storey COMAC points at, if any one of them stands out.
    ///
    /// Returns nil rather than the minimum when nothing stands out. A building
    /// whose storeys all read 0.97 has not localised anything, and reporting
    /// "storey four" because it happens to read 0.969 would be inventing a
    /// finding out of rounding.
    public static func mostChangedStorey(_ values: [StoreyConsistency]) -> StoreyConsistency? {
        guard values.count >= 3,
              let lowest = values.min(by: { $0.value < $1.value }) else { return nil }
        // A storey still agreeing with itself to within five per cent has not
        // changed, however much lower than its neighbours it happens to read.
        guard lowest.value < 0.95 else { return nil }

        let others = values.filter { $0.storey != lowest.storey }.map(\.value)
        guard others.count > 1 else { return nil }
        let mean = Stats.mean(others)
        let spread = Stats.stdDev(others)

        // Two standard deviations clear of its neighbours — unless the
        // neighbours are essentially identical, which is the *clearest*
        // possible localisation and not, as an earlier version of this had it,
        // a degenerate case to bail out of. Three storeys at 1.000 and one at
        // 0.31 is the strongest result this function can ever produce, and it
        // has a standard deviation of zero.
        let margin = mean - lowest.value
        return spread > 1e-6 ? (margin > 2 * spread ? lowest : nil)
                             : (margin > 0.05 ? lowest : nil)
    }

    static func normalised(_ shape: [Double]) -> [Double] {
        let norm = shape.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 1e-18 else { return shape }
        return shape.map { $0 / norm }
    }
}
