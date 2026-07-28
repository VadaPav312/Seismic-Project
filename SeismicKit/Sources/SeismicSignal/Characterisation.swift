import Foundation
import SeismicCore

// Algorithms 29–34. Turning a ground motion record into the handful of numbers
// that describe how severe it actually was.

// MARK: - 29. Peak values

public struct PeakValues: Sendable, Equatable, Codable {
    /// m/s²
    public var pga: Double
    /// m/s
    public var pgv: Double
    /// m
    public var pgd: Double
    public var pgaTime: Double
    public var intensity: Double          // continuous MMI

    public init(pga: Double, pgv: Double, pgd: Double, pgaTime: Double) {
        self.pga = pga; self.pgv = pgv; self.pgd = pgd; self.pgaTime = pgaTime
        self.intensity = IntensityScale.fromPGA(pga).continuous
    }

    public var pgaInG: Double { pga / gravity }
    public var mercalli: MercalliIntensity {
        MercalliIntensity(rawValue: Int(intensity.rounded())) ?? .notFelt
    }
}

public enum GroundMotion {

    /// Algorithm 29 — peak ground acceleration, velocity and displacement.
    ///
    /// PGA is what everybody quotes, but PGV correlates far better with damage
    /// to ordinary buildings, and PGD is what matters for long-period
    /// structures. Reporting all three is the difference between a headline and
    /// an assessment.
    public static func peaks(_ acceleration: Waveform) -> PeakValues {
        guard !acceleration.isEmpty else { return PeakValues(pga: 0, pgv: 0, pgd: 0, pgaTime: 0) }

        let pga = acceleration.peakAbsolute
        let peakIndex = acceleration.samples.firstIndex { abs($0) >= pga * 0.9999 } ?? 0

        let (velocity, displacement) = Integration.toVelocityAndDisplacement(
            acceleration: acceleration)

        return PeakValues(pga: pga,
                          pgv: velocity.peakAbsolute,
                          pgd: displacement.peakAbsolute,
                          pgaTime: acceleration.time(at: peakIndex))
    }

    public static func peaks(_ rec: TriaxialRecord) -> PeakValues {
        // Use the vector magnitude: an earthquake does not politely align itself
        // with the sensor's axes.
        peaks(rec.magnitude)
    }
}

// MARK: - 30, 31, 32. Energy measures

public struct EnergyMeasures: Sendable, Equatable, Codable {
    /// Arias intensity, m/s.
    public var arias: Double
    /// Cumulative absolute velocity, m/s.
    public var cav: Double
    /// 5–95% significant duration, seconds.
    public var significantDuration: Double
    public var durationStart: Double
    public var durationEnd: Double
    /// Normalised Arias build-up, for the Husid plot.
    public var husid: [Double]

    public init(arias: Double, cav: Double, significantDuration: Double,
                durationStart: Double, durationEnd: Double, husid: [Double]) {
        self.arias = arias; self.cav = cav
        self.significantDuration = significantDuration
        self.durationStart = durationStart; self.durationEnd = durationEnd
        self.husid = husid
    }

    /// The operational threshold: below about 0.16 m/s CAV, shaking is generally
    /// agreed to be incapable of damaging a well-built structure. It is the
    /// standard used to decide whether a nuclear plant must shut down, and it is
    /// exactly the right question here too.
    public var exceedsDamageThreshold: Bool { cav > 0.16 }

    public var damageThresholdExplanation: String {
        exceedsDamageThreshold
            ? "Cumulative absolute velocity of \(String(format: "%.3f", cav)) m/s is above the "
                + "0.16 m/s threshold generally taken as the level below which shaking cannot "
                + "damage a sound structure."
            : "Cumulative absolute velocity of \(String(format: "%.3f", cav)) m/s is below the "
                + "0.16 m/s threshold, so this shaking was almost certainly incapable of causing "
                + "structural damage on its own."
    }
}

public enum EnergyAnalysis {

    /// Algorithms 30, 31 and 32 together, because they share one integration
    /// pass and are never useful separately.
    public static func compute(_ acceleration: Waveform) -> EnergyMeasures {
        guard acceleration.count > 2 else {
            return EnergyMeasures(arias: 0, cav: 0, significantDuration: 0,
                                  durationStart: 0, durationEnd: 0, husid: [])
        }
        let a = acceleration.samples
        let dt = acceleration.dt

        // Algorithm 30 — Arias intensity: Ia = (π / 2g) ∫ a² dt.
        // It is total energy, so unlike PGA a long moderate shake and a brief
        // violent one are compared fairly.
        //
        // Trapezoidal rather than Simpson, deliberately: the Husid plot derived
        // from this must be monotonically non-decreasing, and with a
        // non-negative integrand the trapezoid rule guarantees that by
        // construction. The accuracy difference at these sample rates is far
        // below the uncertainty in the measurement itself.
        let squared = a.map { $0 * $0 }
        let cumulative = Integration.trapezoidal(squared, dt: dt)
        let scale = Double.pi / (2 * gravity)
        let arias = (cumulative.last ?? 0) * scale

        // Algorithm 31 — cumulative absolute velocity: CAV = ∫ |a| dt.
        let cav = Integration.trapezoidal(a.map(abs), dt: dt).last ?? 0

        // Algorithm 32 — significant duration between 5% and 95% of total Arias.
        let total = cumulative.last ?? 0
        var husid = [Double](repeating: 0, count: cumulative.count)
        if total > 1e-30 { for i in cumulative.indices { husid[i] = cumulative[i] / total } }

        var startIndex = 0, endIndex = cumulative.count - 1
        if total > 1e-30 {
            startIndex = husid.firstIndex { $0 >= 0.05 } ?? 0
            endIndex = husid.firstIndex { $0 >= 0.95 } ?? (cumulative.count - 1)
        }
        let start = acceleration.time(at: startIndex)
        let end = acceleration.time(at: endIndex)

        return EnergyMeasures(arias: Swift.max(arias, 0),
                              cav: cav,
                              significantDuration: Swift.max(end - start, 0),
                              durationStart: start, durationEnd: end,
                              husid: husid)
    }
}

// MARK: - 33. Response spectrum

public struct ResponseSpectrum: Sendable, Equatable {
    public var periods: [Double]
    /// Spectral acceleration, m/s².
    public var sa: [Double]
    /// Spectral velocity, m/s.
    public var sv: [Double]
    /// Spectral displacement, m.
    public var sd: [Double]
    public var damping: Double

    public init(periods: [Double], sa: [Double], sv: [Double], sd: [Double], damping: Double) {
        self.periods = periods; self.sa = sa; self.sv = sv; self.sd = sd; self.damping = damping
    }

    public var isEmpty: Bool { periods.isEmpty }

    /// Spectral acceleration at an arbitrary period — this is how the simulator
    /// answers "what does this earthquake do to *this* building?" in one number.
    public func sa(atPeriod t: Double) -> Double {
        Stats.interpolate(x: t, xs: periods, ys: sa)
    }

    public func sd(atPeriod t: Double) -> Double {
        Stats.interpolate(x: t, xs: periods, ys: sd)
    }

    /// The period at which this ground motion is most dangerous. A building
    /// whose own period sits here is in the worst possible place.
    public var dominantPeriod: Double {
        guard let idx = sa.indices.max(by: { sa[$0] < sa[$1] }) else { return 0 }
        return periods[idx]
    }
}

public enum ResponseSpectrumAnalysis {

    /// Algorithm 33 — response spectrum by Newmark-beta integration.
    ///
    /// For each of a range of periods, a single-degree-of-freedom oscillator is
    /// run through the whole ground motion and its peak response recorded. The
    /// resulting curve is the single most useful thing an engineer can be handed
    /// about an earthquake: it says directly how hard this shaking hits
    /// buildings of every height.
    public static func compute(_ acceleration: Waveform,
                               damping: Double = 0.05,
                               periods: [Double]? = nil) -> ResponseSpectrum {
        let periodList = periods ?? standardPeriods()
        guard acceleration.count > 4 else {
            return ResponseSpectrum(periods: periodList,
                                    sa: [Double](repeating: 0, count: periodList.count),
                                    sv: [Double](repeating: 0, count: periodList.count),
                                    sd: [Double](repeating: 0, count: periodList.count),
                                    damping: damping)
        }

        var sa = [Double](), sv = [Double](), sd = [Double]()
        sa.reserveCapacity(periodList.count)

        for t in periodList {
            let response = sdofResponse(acceleration: acceleration, period: t, damping: damping)
            sd.append(response.peakDisplacement)
            sv.append(response.peakVelocity)
            sa.append(response.peakTotalAcceleration)
        }

        return ResponseSpectrum(periods: periodList, sa: sa, sv: sv, sd: sd, damping: damping)
    }

    /// Log-spaced periods from 0.02 s (a very stiff structure) to 10 s (a very
    /// tall one), which brackets everything this app will ever model.
    public static func standardPeriods(count: Int = 100) -> [Double] {
        let lo = log10(0.02), hi = log10(10.0)
        return (0..<count).map { pow(10, lo + (hi - lo) * Double($0) / Double(count - 1)) }
    }

    public struct SDOFResponse: Sendable, Equatable {
        public var peakDisplacement: Double
        public var peakVelocity: Double
        public var peakTotalAcceleration: Double
        public var displacement: [Double]
    }

    /// Newmark-beta average-acceleration integration of one oscillator.
    ///
    /// β = 1/4, γ = 1/2 — unconditionally stable, which matters because the time
    /// step is fixed by the record while the period being analysed varies over
    /// three orders of magnitude.
    public static func sdofResponse(acceleration: Waveform, period: Double,
                                    damping: Double,
                                    keepHistory: Bool = false) -> SDOFResponse {
        guard period > 0, acceleration.count > 1 else {
            return SDOFResponse(peakDisplacement: 0, peakVelocity: 0,
                                peakTotalAcceleration: 0, displacement: [])
        }

        let omega = 2 * Double.pi / period
        let zeta = Swift.min(Swift.max(damping, 0), 0.999)
        let m = 1.0
        let k = omega * omega * m
        let c = 2 * zeta * omega * m

        var dt = acceleration.dt
        // Sub-step when the record is coarse relative to the period being
        // analysed, otherwise short-period response is badly underestimated.
        var subSteps = 1
        while period / dt < 20, subSteps < 32 { subSteps *= 2; dt = acceleration.dt / Double(subSteps) }

        let beta = 0.25, gamma = 0.5
        let a0 = 1 / (beta * dt * dt), a1 = gamma / (beta * dt)
        let a2 = 1 / (beta * dt), a3 = 1 / (2 * beta) - 1
        let a4 = gamma / beta - 1, a5 = dt / 2 * (gamma / beta - 2)
        let kEff = k + a0 * m + a1 * c

        var u = 0.0, v = 0.0, a = 0.0
        var peakU = 0.0, peakV = 0.0, peakTotal = 0.0
        var history: [Double] = []
        if keepHistory { history.reserveCapacity(acceleration.count) }

        let ag = acceleration.samples
        for i in 0..<(ag.count - 1) {
            for s in 0..<subSteps {
                // Linear interpolation of ground acceleration within the step.
                let frac0 = Double(s) / Double(subSteps)
                let frac1 = Double(s + 1) / Double(subSteps)
                let g0 = ag[i] + (ag[i + 1] - ag[i]) * frac0
                let g1 = ag[i] + (ag[i + 1] - ag[i]) * frac1

                if i == 0 && s == 0 { a = (-m * g0 - c * v - k * u) / m }

                let p = -m * g1
                let pEff = p + m * (a0 * u + a2 * v + a3 * a) + c * (a1 * u + a4 * v + a5 * a)
                let uNext = pEff / kEff
                let aNext = a0 * (uNext - u) - a2 * v - a3 * a
                let vNext = v + dt * ((1 - gamma) * a + gamma * aNext)

                u = uNext; v = vNext; a = aNext

                peakU = Swift.max(peakU, abs(u))
                peakV = Swift.max(peakV, abs(v))
                // Total acceleration is what an accelerometer on the roof would
                // read: relative plus ground.
                peakTotal = Swift.max(peakTotal, abs(a + g1))
            }
            if keepHistory { history.append(u) }
        }

        return SDOFResponse(peakDisplacement: peakU, peakVelocity: peakV,
                            peakTotalAcceleration: peakTotal, displacement: history)
    }
}

// MARK: - 34. Early magnitude estimation

public enum EarlyMagnitude {

    /// Algorithm 34 — magnitude from the first seconds of the P-wave.
    ///
    /// This is the algorithm that buys the warning time. The destructive S-wave
    /// has not arrived yet; all that exists is a few seconds of P-wave. Both the
    /// dominant period of that P-wave (τ_c) and its peak displacement amplitude
    /// (P_d) scale with the eventual magnitude, because a bigger rupture radiates
    /// longer-period energy. Neither is precise — ±0.5 magnitude units is
    /// typical — but knowing within three seconds that this is a magnitude 7
    /// rather than a magnitude 4 is what decides whether to shut the gas off.
    public struct Estimate: Sendable, Equatable {
        public var magnitude: Double
        public var uncertainty: Double
        public var tauC: Double            // characteristic period, s
        public var peakDisplacement: Double // m
        public var secondsOfDataUsed: Double
        public var explanation: String

        public var range: ClosedRange<Double> {
            (magnitude - uncertainty)...(magnitude + uncertainty)
        }
    }

    /// - Parameter distanceKm: hypocentral distance, when it is already known
    ///   from S−P timing or a network solution. During the first seconds it
    ///   usually is not, and a nominal value is assumed with a correspondingly
    ///   wider uncertainty — which is exactly how real early warning behaves.
    public static func estimate(_ acceleration: Waveform,
                                pArrival: Double,
                                windowSeconds: Double = 3.0,
                                distanceKm: Double? = nil) -> Estimate? {
        guard acceleration.count > 8 else { return nil }
        let start = acceleration.index(atTime: pArrival)
        let end = Swift.min(acceleration.index(atTime: pArrival + windowSeconds),
                            acceleration.count - 1)
        guard end > start + 8 else { return nil }

        let window = Waveform(samples: Array(acceleration.samples[start...end]),
                              sampleRate: acceleration.sampleRate,
                              startTime: acceleration.startTime, unit: .acceleration)
        let used = window.duration

        // τ_c — the characteristic period — computed in the frequency domain.
        //
        // The textbook definition is a ratio of integrated velocity and
        // displacement energy, but obtaining those by integrating a three-second
        // window in the time domain does not work: without low-frequency
        // control the double integral is dominated by whatever trend the window
        // happens to contain, and τ_c ends up measuring the window rather than
        // the wave. Deriving both spectra from the acceleration spectrum
        // sidesteps the problem entirely, since |V| = |A|/ω and |D| = |A|/ω²
        // exactly, and the band limits keep the 1/ω⁴ weighting from blowing up
        // near DC.
        let (frequencies, amplitudes) = FFT.amplitudeSpectrum(window.samples,
                                                              sampleRate: window.sampleRate)
        let lowLimit = 0.3
        let highLimit = Swift.min(20, window.sampleRate / 2.5)
        var sumV = 0.0, sumD = 0.0
        for (i, f) in frequencies.enumerated() where f >= lowLimit && f <= highLimit {
            let omega = 2 * Double.pi * f
            let v = amplitudes[i] / omega
            let d = v / omega
            sumV += v * v
            sumD += d * d
        }
        guard sumV > 1e-30, sumD > 1e-30 else { return nil }
        let tauC = 2 * Double.pi * (sumD / sumV).squareRoot()

        // Peak displacement over the same window, obtained the same way to stay
        // consistent — mean-removed double integration is adequate for a *peak*
        // even though it is not for a period.
        let velocitySamples = Detrend.removeDCOffset(
            Integration.trapezoidal(Detrend.removeDCOffset(window.samples), dt: window.dt))
        let displacementSamples = Detrend.removeDCOffset(
            Integration.trapezoidal(velocitySamples, dt: window.dt))
        let pd = Stats.peakAbs(displacementSamples)

        // Two independent regressions, averaged. Both are empirical fits to
        // global datasets; neither is a law of nature, which the uncertainty
        // reflects honestly.
        //
        //   τ_c:  log₁₀ τ_c ≈ 0.21·M − 1.19, inverted.
        //   P_d:  amplitude also depends on how far away it happened, so the
        //         distance term is not optional — omitting it biases every
        //         estimate low by more than a magnitude unit.
        let assumedDistance = distanceKm ?? 30
        let magnitudeFromTauC = 5.67 + 4.76 * log10(Swift.max(tauC, 1e-3))
        let magnitudeFromPd = 5.39 + 1.23 * log10(Swift.max(pd * 100, 1e-9))
            + 1.38 * log10(Swift.max(assumedDistance, 1))

        let both = [magnitudeFromTauC, magnitudeFromPd]
        let magnitude = Swift.min(Swift.max(Stats.mean(both), 1.0), 9.5)
        let disagreement = abs(magnitudeFromTauC - magnitudeFromPd) / 2

        // Uncertainty grows when the two methods disagree, when there is less
        // data, and when the distance had to be assumed rather than measured.
        let dataPenalty = Swift.max(0, (3.0 - used) / 3.0) * 0.6
        let distancePenalty = distanceKm == nil ? 0.3 : 0
        let uncertainty = Swift.min(0.4 + disagreement + dataPenalty + distancePenalty, 2.0)

        return Estimate(
            magnitude: magnitude,
            uncertainty: uncertainty,
            tauC: tauC,
            peakDisplacement: pd,
            secondsOfDataUsed: used,
            explanation: "Estimated from \(String(format: "%.1f", used)) s of P-wave: "
                + "characteristic period \(String(format: "%.2f", tauC)) s suggests M"
                + "\(String(format: "%.1f", magnitudeFromTauC)), peak displacement "
                + "\(String(format: "%.2f", pd * 1000)) mm at "
                + "\(String(format: "%.0f", assumedDistance)) km suggests M"
                + "\(String(format: "%.1f", magnitudeFromPd))."
                + (distanceKm == nil ? " Distance assumed; the range will narrow once S arrives." : ""))
    }
}
