import Foundation

// MARK: - 88. Theil–Sen robust regression

/// Algorithm 88 — the Theil–Sen estimator.
///
/// The temperature-frequency regression is the single most load-bearing fit in
/// this app. It is what separates "the building is colder" from "the building
/// is damaged", and every verdict depends on it being right. It is currently
/// ordinary least squares with outliers rejected first — which is a reasonable
/// approach and has a circularity in it: the outliers are identified by their
/// residuals against a fit that the outliers themselves have already moved.
///
/// Theil–Sen has no such step because it has no such weakness. It takes the
/// median of the slopes between every pair of points. A wrong point participates
/// in only a small share of those pairs, and the median ignores the extremes by
/// construction — so the estimator tolerates up to about 29% of the data being
/// arbitrarily wrong before it can be broken at all. Least squares can be
/// broken by one point.
///
/// The specific failure this prevents: a measurement taken while a lorry idled
/// outside, or during a lift movement, or on the one night the heating failed.
/// Each produces a period that is real, wrong for this purpose, and not
/// obviously either — and one of them in a year of nightly measurements is
/// enough to tilt a least-squares line by more than the effect being measured.
public enum TheilSen {

    public struct Fit: Sendable, Equatable {
        public var slope: Double
        public var intercept: Double
        /// Median absolute residual, in the units of y. A robust scale, so a
        /// couple of wild points cannot inflate it the way a standard error
        /// would.
        public var medianAbsoluteResidual: Double
        /// Confidence interval on the slope, from the distribution of pairwise
        /// slopes rather than from an assumed normal error model.
        public var slopeInterval: ClosedRange<Double>
        public var sampleCount: Int

        public init(slope: Double, intercept: Double, medianAbsoluteResidual: Double,
                    slopeInterval: ClosedRange<Double>, sampleCount: Int) {
            self.slope = slope
            self.intercept = intercept
            self.medianAbsoluteResidual = medianAbsoluteResidual
            self.slopeInterval = slopeInterval
            self.sampleCount = sampleCount
        }

        public func predict(_ x: Double) -> Double { intercept + slope * x }

        /// Whether the slope is distinguishable from zero at all.
        ///
        /// Worth checking before using a temperature correction: a building
        /// whose period genuinely does not depend on temperature — a stiff
        /// steel frame in a climate-controlled interior — should not have a
        /// correction applied to it on the strength of a slope that is noise.
        public var isSlopeSignificant: Bool {
            !(slopeInterval.lowerBound <= 0 && slopeInterval.upperBound >= 0)
        }
    }

    /// - Parameter maximumPairs: pairwise slopes grow as the square of the
    ///   sample count, so a decade of nightly measurements would be seven
    ///   million pairs. Beyond the cap the pairs are sampled deterministically
    ///   rather than enumerated, which changes the estimate by far less than
    ///   the measurement noise does.
    public static func fit(x: [Double], y: [Double],
                           maximumPairs: Int = 200_000,
                           seed: UInt64 = 0x7451) -> Fit? {
        guard x.count == y.count, x.count >= 3 else { return nil }
        let n = x.count

        var slopes: [Double] = []
        let totalPairs = n * (n - 1) / 2

        if totalPairs <= maximumPairs {
            slopes.reserveCapacity(totalPairs)
            for i in 0..<(n - 1) {
                for j in (i + 1)..<n {
                    let dx = x[j] - x[i]
                    // Two measurements at the same temperature say nothing
                    // about the slope, and dividing by their difference would
                    // say something infinite.
                    guard abs(dx) > 1e-12 else { continue }
                    slopes.append((y[j] - y[i]) / dx)
                }
            }
        } else {
            var rng = SeededRandom(seed: seed)
            slopes.reserveCapacity(maximumPairs)
            while slopes.count < maximumPairs {
                let i = Int(rng.next() % UInt64(n))
                let j = Int(rng.next() % UInt64(n))
                guard i != j else { continue }
                let dx = x[j] - x[i]
                guard abs(dx) > 1e-12 else { continue }
                slopes.append((y[j] - y[i]) / dx)
            }
        }

        guard slopes.count >= 2 else { return nil }
        slopes.sort()
        let slope = Stats.median(slopes)

        // The intercept is the median of y − slope·x, not the mean. Using the
        // mean here would reintroduce exactly the sensitivity to outliers that
        // the slope estimator just went to such trouble to avoid.
        let intercept = Stats.median((0..<n).map { y[$0] - slope * x[$0] })

        let residuals = (0..<n).map { abs(y[$0] - (intercept + slope * x[$0])) }

        // Interval from the empirical distribution of pairwise slopes. The
        // standard construction uses the Kendall statistic to pick the rank
        // offsets; for the sample sizes here the difference from a plain
        // percentile is immaterial and a percentile cannot go out of bounds.
        let lower = slopes[Int(Double(slopes.count) * 0.025)]
        let upper = slopes[min(Int(Double(slopes.count) * 0.975), slopes.count - 1)]

        return Fit(slope: slope, intercept: intercept,
                   medianAbsoluteResidual: Stats.median(residuals),
                   slopeInterval: min(lower, upper)...max(lower, upper),
                   sampleCount: n)
    }

    /// Ordinary least squares, for comparison.
    ///
    /// Kept here deliberately rather than left elsewhere: the point of the
    /// robust estimator is that it differs from this one under contamination,
    /// and being able to show both side by side is what makes that visible
    /// rather than asserted.
    public static func leastSquares(x: [Double], y: [Double]) -> (slope: Double,
                                                                  intercept: Double)? {
        guard x.count == y.count, x.count >= 2 else { return nil }
        let meanX = Stats.mean(x), meanY = Stats.mean(y)
        var covariance = 0.0, variance = 0.0
        for i in x.indices {
            let dx = x[i] - meanX
            covariance += dx * (y[i] - meanY)
            variance += dx * dx
        }
        guard variance > 1e-18 else { return nil }
        let slope = covariance / variance
        return (slope, meanY - slope * meanX)
    }
}
