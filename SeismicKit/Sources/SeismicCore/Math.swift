import Foundation

/// Small statistical helpers shared by every module. Deliberately allocation
/// light: these run inside the sample loop during a live event.
public enum Stats {
    public static func mean(_ x: [Double]) -> Double {
        x.isEmpty ? 0 : x.reduce(0, +) / Double(x.count)
    }

    public static func variance(_ x: [Double]) -> Double {
        guard x.count > 1 else { return 0 }
        let m = mean(x)
        return x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count - 1)
    }

    public static func stdDev(_ x: [Double]) -> Double { sqrt(variance(x)) }

    public static func median(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        let s = x.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }

    /// Median absolute deviation, scaled to be a consistent estimator of sigma
    /// for normal data. Used wherever an outlier would otherwise poison a fit.
    public static func mad(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        let m = median(x)
        return 1.4826 * median(x.map { abs($0 - m) })
    }

    public static func percentile(_ x: [Double], _ p: Double) -> Double {
        guard !x.isEmpty else { return 0 }
        let s = x.sorted()
        let rank = (p / 100) * Double(s.count - 1)
        let lo = Int(floor(rank)), hi = Int(ceil(rank))
        if lo == hi { return s[lo] }
        return s[lo] + (rank - Double(lo)) * (s[hi] - s[lo])
    }

    public static func rms(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        return sqrt(x.reduce(0) { $0 + $1 * $1 } / Double(x.count))
    }

    public static func peakAbs(_ x: [Double]) -> Double {
        x.reduce(0) { Swift.max($0, abs($1)) }
    }

    /// Ordinary least squares. Returns the fit plus an R² so callers can decide
    /// whether to trust it — a temperature correction built on a bad fit is
    /// worse than no correction at all.
    public static func linearRegression(x: [Double], y: [Double])
        -> (slope: Double, intercept: Double, r2: Double)
    {
        guard x.count == y.count, x.count > 1 else { return (0, mean(y), 0) }
        let mx = mean(x), my = mean(y)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<x.count {
            let dx = x[i] - mx, dy = y[i] - my
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        guard sxx > 0 else { return (0, my, 0) }
        let slope = sxy / sxx
        let r2 = syy > 0 ? (sxy * sxy) / (sxx * syy) : 0
        return (slope, my - slope * mx, r2)
    }

    /// Pearson correlation.
    public static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        linearRegression(x: a, y: b).r2.squareRoot()
            * (linearRegression(x: a, y: b).slope >= 0 ? 1 : -1)
    }

    /// Standard normal CDF, via the error function. Underpins fragility curves
    /// and every confidence interval in the assessment.
    public static func normalCDF(_ z: Double) -> Double {
        0.5 * erfc(-z / 2.0.squareRoot())
    }

    /// Inverse standard normal CDF (Acklam's rational approximation, accurate to
    /// ~1e-9 — far beyond what any of our inputs justify, but cheap).
    public static func inverseNormalCDF(_ p: Double) -> Double {
        guard p > 0, p < 1 else { return p <= 0 ? -.infinity : .infinity }
        let a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
                 1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
        let b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
                 6.680131188771972e+01, -1.328068155288572e+01]
        let c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
                 -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
        let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
                 3.754408661907416e+00]
        let pLow = 0.02425, pHigh = 1 - pLow
        if p < pLow {
            let q = (-2 * Foundation.log(p)).squareRoot()
            return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        if p > pHigh {
            let q = (-2 * Foundation.log(1 - p)).squareRoot()
            return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        let q = p - 0.5, r = q * q
        return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q
            / (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
    }

    /// Linear interpolation over a monotonically increasing x table.
    public static func interpolate(x: Double, xs: [Double], ys: [Double]) -> Double {
        guard xs.count == ys.count, !xs.isEmpty else { return 0 }
        if x <= xs[0] { return ys[0] }
        if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
        var lo = 0, hi = xs.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if xs[mid] <= x { lo = mid } else { hi = mid }
        }
        let t = (x - xs[lo]) / (xs[hi] - xs[lo])
        return ys[lo] + t * (ys[hi] - ys[lo])
    }
}

/// Deterministic pseudo-random source. The simulator must produce the *same*
/// earthquake twice — a demo that looks different every run is impossible to
/// talk over, and a test that cannot be reproduced is not a test.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }

    public mutating func next() -> UInt64 {
        // splitmix64
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    public mutating func uniform(_ lo: Double = 0, _ hi: Double = 1) -> Double {
        lo + (Double(next() >> 11) * (1.0 / 9007199254740992.0)) * (hi - lo)
    }

    /// Box-Muller. The noise floor of a real accelerometer is Gaussian; using a
    /// uniform distribution here would make the simulated trace look wrong to
    /// anyone who has seen a real one.
    public mutating func gaussian(mean: Double = 0, sd: Double = 1) -> Double {
        let u1 = Swift.max(uniform(), 1e-12), u2 = uniform()
        return mean + sd * (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
    }
}
