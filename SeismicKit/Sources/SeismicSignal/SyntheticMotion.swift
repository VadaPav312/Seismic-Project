import Foundation
import SeismicCore

/// Physically realistic synthetic ground motion.
///
/// This is the single most important piece of the demo story: with no hardware
/// and no network, the app must produce traces that a seismologist would look at
/// and accept. That means getting the *structure* of the signal right, not just
/// its amplitude —
///
///   • a quiet noise floor that looks like a real MEMS accelerometer,
///   • a P-wave that arrives first, is comparatively weak, and is mostly vertical,
///   • an S-wave that arrives later, is several times stronger, and is transverse,
///   • a coda that decays roughly exponentially rather than stopping dead,
///   • frequency content that falls with magnitude and distance,
///   • and aftershocks that follow Omori's law rather than arriving at random.
///
/// Everything is driven by a seed, so the same event replays identically —
/// essential both for tests and for being able to talk over a live demo.
public enum SyntheticMotion {

    // MARK: - Parameters

    public struct EventParameters: Sendable, Equatable {
        public var magnitude: Double
        public var distanceKm: Double
        public var depthKm: Double
        public var soil: SoilClass
        public var sampleRate: Double
        /// Seconds of quiet before the P-wave arrives, so the trigger has a
        /// background to measure against.
        public var preEventSeconds: Double
        public var noiseFloor: Double        // m/s² RMS
        public var seed: UInt64

        public init(magnitude: Double = 6.2, distanceKm: Double = 30, depthKm: Double = 10,
                    soil: SoilClass = .stiffSoil, sampleRate: Double = 100,
                    preEventSeconds: Double = 12, noiseFloor: Double = 0.004,
                    seed: UInt64 = 20_260_727) {
            self.magnitude = Swift.min(Swift.max(magnitude, 1), 9.5)
            self.distanceKm = Swift.max(distanceKm, 1)
            self.depthKm = Swift.max(depthKm, 1)
            self.soil = soil
            self.sampleRate = Swift.max(sampleRate, 20)
            self.preEventSeconds = Swift.max(preEventSeconds, 0)
            self.noiseFloor = Swift.max(noiseFloor, 0)
            self.seed = seed
        }

        /// Hypocentral distance — the actual path length, which is what the
        /// travel times depend on.
        public var hypocentralDistanceKm: Double {
            (distanceKm * distanceKm + depthKm * depthKm).squareRoot()
        }

        /// P-wave velocity in crustal rock, km/s.
        public static let vP = 6.0
        /// S-wave velocity. The ratio is close to √3 in most crust, which is why
        /// the S−P gap is roughly distance/8 in seconds.
        public static let vS = 3.45

        public var pTravelTime: Double { hypocentralDistanceKm / Self.vP }
        public var sTravelTime: Double { hypocentralDistanceKm / Self.vS }
        public var sMinusP: Double { sTravelTime - pTravelTime }

        /// Rupture duration grows with magnitude — a magnitude 7 simply takes
        /// longer to break than a magnitude 5.
        public var sourceDuration: Double {
            Swift.max(pow(10, 0.5 * magnitude - 2.9), 0.3)
        }

        /// Corner frequency falls with magnitude: bigger events radiate
        /// longer-period energy, which is exactly why they damage tall buildings.
        public var cornerFrequency: Double {
            Swift.min(Swift.max(1 / sourceDuration, 0.08), 12)
        }

        /// Expected PGA at this distance, m/s². A compact attenuation
        /// relationship — magnitude scaling, geometric spreading, anelastic
        /// attenuation, and a site factor.
        public var expectedPGA: Double {
            let r = hypocentralDistanceKm
            let lnPGA = -3.512 + 0.904 * magnitude
                - 1.328 * log((r * r + 0.149 * exp(0.647 * magnitude)).squareRoot())
                - 0.00206 * r
            let gValue = exp(lnPGA)                     // in g
            return gValue * gravity * soil.amplification
        }

        public var totalDuration: Double {
            preEventSeconds + sMinusP + Swift.max(sourceDuration * 6, 12) + 8
        }
    }

    // MARK: - Generation

    /// A complete three-axis record of one event.
    public static func generate(_ p: EventParameters) -> TriaxialRecord {
        let n = Int(p.totalDuration * p.sampleRate)
        guard n > 8 else { return TriaxialRecord.zeros(count: Swift.max(n, 1), sampleRate: p.sampleRate) }

        var rng = SeededRandom(seed: p.seed)
        let dt = 1 / p.sampleRate

        let pArrival = p.preEventSeconds
        let sArrival = p.preEventSeconds + p.sMinusP

        // Amplitude budget. The P-wave carries roughly a fifth of the S-wave's
        // acceleration at typical distances, and is dominated by vertical motion.
        let targetPGA = p.expectedPGA
        let sAmplitude = targetPGA
        let pAmplitude = targetPGA * 0.22

        var x = [Double](repeating: 0, count: n)   // north–south
        var y = [Double](repeating: 0, count: n)   // east–west
        var z = [Double](repeating: 0, count: n)   // vertical

        // Random but fixed back-azimuth, so the two horizontals are not
        // identical — a real event arrives from somewhere.
        let azimuth = rng.uniform(0, 2 * Double.pi)
        let cosA = cos(azimuth), sinA = sin(azimuth)

        // Modulating envelopes, then filtered noise shaped by them. Building the
        // signal as shaped noise rather than as a sum of sinusoids is what makes
        // it look real: earthquakes are broadband and stochastic.
        var pNoise = [Double](repeating: 0, count: n)
        var sNoise1 = [Double](repeating: 0, count: n)
        var sNoise2 = [Double](repeating: 0, count: n)
        for i in 0..<n {
            pNoise[i] = rng.gaussian()
            sNoise1[i] = rng.gaussian()
            sNoise2[i] = rng.gaussian()
        }

        // Both wave trains are shaped around the source corner frequency, so a
        // large event genuinely radiates longer-period energy than a small one.
        // Anchoring the bands to fixed frequencies instead would make every
        // magnitude sound the same, which is not merely unrealistic — it would
        // break the early magnitude estimate, whose whole basis is that the
        // dominant period of the first seconds scales with the eventual size.
        //
        // The P-wave sits above the S-wave in frequency, as it does in reality.
        let nyquistLimit = p.sampleRate / 2.5
        let pBand = ButterworthFilter(
            kind: .bandpass, order: 4, sampleRate: p.sampleRate,
            lowCutoff: Swift.min(Swift.max(p.cornerFrequency * 1.2, 0.4), nyquistLimit * 0.5),
            highCutoff: Swift.min(Swift.max(p.cornerFrequency * 6, 2.5), nyquistLimit))
        let sBand = ButterworthFilter(
            kind: .bandpass, order: 4, sampleRate: p.sampleRate,
            lowCutoff: Swift.min(Swift.max(p.cornerFrequency * 0.4, 0.12), nyquistLimit * 0.3),
            highCutoff: Swift.min(Swift.max(p.cornerFrequency * 2.5, 1.5), nyquistLimit))
        pNoise = pBand.applyZeroPhase(pNoise)
        sNoise1 = sBand.applyZeroPhase(sNoise1)
        sNoise2 = sBand.applyZeroPhase(sNoise2)

        normalise(&pNoise); normalise(&sNoise1); normalise(&sNoise2)

        for i in 0..<n {
            let t = Double(i) * dt

            let pEnv = envelope(t: t, arrival: pArrival,
                               rise: 0.25, duration: p.sourceDuration * 1.2,
                               decay: p.sourceDuration * 2.0)
            let sEnv = envelope(t: t, arrival: sArrival,
                                rise: Swift.max(p.sourceDuration * 0.35, 0.4),
                                duration: p.sourceDuration * 2.2,
                                decay: p.sourceDuration * 4.5 * p.soil.amplification)

            let pMotion = pNoise[i] * pEnv * pAmplitude
            let s1 = sNoise1[i] * sEnv * sAmplitude
            let s2 = sNoise2[i] * sEnv * sAmplitude * 0.85

            // P is mostly vertical and radial; S is mostly transverse.
            z[i] = pMotion * 0.85 + s1 * 0.35
            x[i] = pMotion * 0.35 * cosA + (s1 * cosA - s2 * sinA)
            y[i] = pMotion * 0.35 * sinA + (s1 * sinA + s2 * cosA)
        }

        // Soft soil rings at its own period long after the source has stopped.
        if p.soil.resonantPeriod > 0.3 {
            addSiteResonance(&x, &y, parameters: p, startTime: sArrival, rng: &rng)
        }

        // Sensor noise floor, always present, everywhere.
        for i in 0..<n {
            x[i] += rng.gaussian(sd: p.noiseFloor)
            y[i] += rng.gaussian(sd: p.noiseFloor)
            z[i] += rng.gaussian(sd: p.noiseFloor * 0.9)
        }

        let start = Date()
        return TriaxialRecord(
            x: Waveform(samples: x, sampleRate: p.sampleRate, startTime: start),
            y: Waveform(samples: y, sampleRate: p.sampleRate, startTime: start),
            z: Waveform(samples: z, sampleRate: p.sampleRate, startTime: start))
    }

    /// Ambient background only — no event. This is what the node streams for
    /// months on end, and what the random decrement technique feeds on.
    ///
    /// - Parameter buildingPeriod: when given, the trace carries a faint
    ///   resonance at the building's own period, which is precisely the signal
    ///   the baseline measurement is meant to find.
    public static func ambient(seconds: Double, sampleRate: Double = 100,
                               noiseFloor: Double = 0.004,
                               buildingPeriod: Double? = nil,
                               buildingDamping: Double = 0.02,
                               excitation: Double = 1.0,
                               seed: UInt64 = 99) -> Waveform {
        let n = Swift.max(Int(seconds * sampleRate), 8)
        var rng = SeededRandom(seed: seed)
        var out = [Double](repeating: 0, count: n)

        for i in 0..<n { out[i] = rng.gaussian(sd: noiseFloor) }

        if let period = buildingPeriod, period > 0 {
            // Drive a lightly damped oscillator with white noise: the output is
            // narrowband noise centred on the building's frequency, which is
            // exactly what ambient building vibration is.
            let omega = 2 * Double.pi / period
            let zeta = Swift.max(buildingDamping, 0.005)
            let dt = 1 / sampleRate
            var u = 0.0, v = 0.0
            let amplitude = noiseFloor * 6 * excitation

            for i in 0..<n {
                let force = rng.gaussian(sd: 1)
                let a = force * omega * omega * amplitude - 2 * zeta * omega * v - omega * omega * u
                v += a * dt
                u += v * dt
                // Report acceleration, which is what an accelerometer measures.
                out[i] += a * 0.02
            }
        }

        return Waveform(samples: out, sampleRate: sampleRate)
    }

    /// A clean decaying sinusoid — the idealised free-decay response, used to
    /// validate the damping estimators against a known answer.
    public static func freeDecay(period: Double, damping: Double, seconds: Double,
                                 sampleRate: Double = 100, amplitude: Double = 1,
                                 noise: Double = 0, seed: UInt64 = 5) -> Waveform {
        let n = Swift.max(Int(seconds * sampleRate), 4)
        var rng = SeededRandom(seed: seed)
        let omega = 2 * Double.pi / period
        let omegaD = omega * Swift.max(1 - damping * damping, 0).squareRoot()

        let samples = (0..<n).map { i -> Double in
            let t = Double(i) / sampleRate
            let value = amplitude * exp(-damping * omega * t) * cos(omegaD * t)
            return noise > 0 ? value + rng.gaussian(sd: noise) : value
        }
        return Waveform(samples: samples, sampleRate: sampleRate)
    }

    /// A pure tone, for testing spectral machinery against an exact answer.
    public static func sine(frequency: Double, seconds: Double, sampleRate: Double = 100,
                            amplitude: Double = 1, phase: Double = 0) -> Waveform {
        let n = Swift.max(Int(seconds * sampleRate), 2)
        let samples = (0..<n).map { i in
            amplitude * sin(2 * Double.pi * frequency * Double(i) / sampleRate + phase)
        }
        return Waveform(samples: samples, sampleRate: sampleRate)
    }

    // MARK: - Nuisance sources

    /// The things that trigger a real node and are not earthquakes. Used both to
    /// exercise the rejection algorithm and to demonstrate it working.
    public enum Nuisance: String, CaseIterable, Sendable, Identifiable {
        case doorSlam, footsteps, passingVehicle, sensorKnock
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .doorSlam: "Door slam"
            case .footsteps: "Footsteps"
            case .passingVehicle: "Passing vehicle"
            case .sensorKnock: "Sensor knocked"
            }
        }
    }

    public static func nuisance(_ kind: Nuisance, sampleRate: Double = 100,
                                seed: UInt64 = 31) -> TriaxialRecord {
        var rng = SeededRandom(seed: seed)
        let seconds: Double = switch kind {
        case .doorSlam: 4
        case .footsteps: 8
        case .passingVehicle: 25
        case .sensorKnock: 3
        }
        let n = Int(seconds * sampleRate)
        var x = [Double](repeating: 0, count: n)
        var y = [Double](repeating: 0, count: n)
        var z = [Double](repeating: 0, count: n)
        let dt = 1 / sampleRate

        switch kind {
        case .doorSlam, .sensorKnock:
            // Effectively an impulse: instant onset, high frequency, gone fast.
            let onset = seconds * 0.3
            let decay = kind == .doorSlam ? 0.12 : 0.05
            let frequency = kind == .doorSlam ? 28.0 : 60.0
            let amplitude = kind == .doorSlam ? 0.9 : 1.6
            for i in 0..<n {
                let t = Double(i) * dt - onset
                guard t >= 0 else { continue }
                let env = exp(-t / decay) * amplitude
                let carrier = sin(2 * Double.pi * Swift.min(frequency, sampleRate / 2.5) * t)
                x[i] = env * carrier * 0.7
                y[i] = env * carrier * 0.5
                z[i] = env * carrier * 0.9
            }

        case .footsteps:
            // Repeating vertical impulses at walking pace.
            let cadence = 1.9
            var step = 0.6
            while step < seconds - 0.3 {
                let startIndex = Int(step * sampleRate)
                let amplitude = 0.35 + rng.uniform(-0.08, 0.08)
                for j in 0..<Int(0.25 * sampleRate) where startIndex + j < n {
                    let t = Double(j) * dt
                    let env = exp(-t / 0.04) * amplitude
                    let carrier = sin(2 * Double.pi * 18 * t)
                    z[startIndex + j] += env * carrier
                    x[startIndex + j] += env * carrier * 0.12
                    y[startIndex + j] += env * carrier * 0.1
                }
                step += 1 / cadence + rng.uniform(-0.05, 0.05)
            }

        case .passingVehicle:
            // Smooth approach and departure — a broad Gaussian envelope on
            // mid-frequency noise, with no distinct onset at all.
            let centre = seconds / 2
            let width = seconds / 5
            var noise = (0..<n).map { _ in rng.gaussian() }
            noise = ButterworthFilter(kind: .bandpass, order: 4, sampleRate: sampleRate,
                                      lowCutoff: 6, highCutoff: Swift.min(28, sampleRate / 2.5))
                .applyZeroPhase(noise)
            normalise(&noise)
            for i in 0..<n {
                let t = Double(i) * dt
                let env = exp(-pow(t - centre, 2) / (2 * width * width)) * 0.25
                x[i] = noise[i] * env * 0.9
                y[i] = noise[i] * env * 0.8
                z[i] = noise[i] * env * 0.75
            }
        }

        // Every record has a noise floor.
        for i in 0..<n {
            x[i] += rng.gaussian(sd: 0.003)
            y[i] += rng.gaussian(sd: 0.003)
            z[i] += rng.gaussian(sd: 0.003)
        }

        let start = Date()
        return TriaxialRecord(
            x: Waveform(samples: x, sampleRate: sampleRate, startTime: start),
            y: Waveform(samples: y, sampleRate: sampleRate, startTime: start),
            z: Waveform(samples: z, sampleRate: sampleRate, startTime: start))
    }

    // MARK: - Aftershock sequences

    public struct Aftershock: Sendable, Equatable, Identifiable {
        public var id: UUID = UUID()
        public var hoursAfterMainshock: Double
        public var magnitude: Double
    }

    /// A realistic aftershock sequence: Omori-Utsu timing, Gutenberg-Richter
    /// magnitudes. Together these produce the characteristic pattern of many
    /// small shocks immediately afterwards, thinning out over days, with the
    /// occasional large one — which is exactly the pattern that makes re-entry
    /// decisions hard.
    public static func aftershockSequence(mainshockMagnitude: Double,
                                          hours: Double = 168,
                                          seed: UInt64 = 4242) -> [Aftershock] {
        var rng = SeededRandom(seed: seed)
        var out: [Aftershock] = []

        // Båth's law: the largest aftershock is typically ~1.2 magnitude units
        // below the mainshock.
        let maxAftershock = mainshockMagnitude - 1.2
        let minimumMagnitude = Swift.max(mainshockMagnitude - 4.5, 2.0)
        guard maxAftershock > minimumMagnitude else { return [] }

        // Productivity: how many aftershocks above the minimum, in total.
        let expectedCount = Int(pow(10, 0.8 * (mainshockMagnitude - minimumMagnitude - 1.0)))
        let count = Swift.min(Swift.max(expectedCount, 3), 400)

        for _ in 0..<count {
            // Omori-Utsu with p = 1.1, c = 0.05 days: sample the time by
            // inverting the cumulative rate.
            let u = rng.uniform(0.0001, 0.9999)
            let p = 1.1, c = 0.05
            let tDays = pow(u * (pow(hours / 24 + c, 1 - p) - pow(c, 1 - p)) + pow(c, 1 - p),
                            1 / (1 - p)) - c
            let t = Swift.min(Swift.max(tDays * 24, 0.02), hours)

            // Gutenberg-Richter with b = 1: magnitudes are exponentially
            // distributed above the completeness threshold.
            let v = rng.uniform(0.0001, 0.9999)
            let magnitude = minimumMagnitude - log10(1 - v) / 1.0
            guard magnitude <= maxAftershock else { continue }

            out.append(Aftershock(hoursAfterMainshock: t, magnitude: magnitude))
        }

        return out.sorted { $0.hoursAfterMainshock < $1.hoursAfterMainshock }
    }

    // MARK: - Helpers

    /// Shapes the amplitude of a wave train: a rise, a plateau, an exponential
    /// decay. Getting this shape right is most of what makes a synthetic record
    /// look real.
    private static func envelope(t: Double, arrival: Double, rise: Double,
                                 duration: Double, decay: Double) -> Double {
        guard t >= arrival else { return 0 }
        let elapsed = t - arrival
        if elapsed < rise {
            // Smooth, not linear — a linear ramp has a visible corner.
            let x = elapsed / Swift.max(rise, 1e-6)
            return x * x * (3 - 2 * x)
        }
        if elapsed < rise + duration { return 1 }
        return exp(-(elapsed - rise - duration) / Swift.max(decay, 1e-6))
    }

    /// Soft sites keep ringing at their own period after the source has stopped.
    /// This is why Mexico City in 1985 destroyed buildings 400 km from the
    /// epicentre — and it is a genuinely important thing for the simulator to
    /// reproduce.
    private static func addSiteResonance(_ x: inout [Double], _ y: inout [Double],
                                         parameters p: EventParameters,
                                         startTime: Double, rng: inout SeededRandom) {
        let n = x.count
        let dt = 1 / p.sampleRate
        let omega = 2 * Double.pi / p.soil.resonantPeriod
        let zeta = 0.07
        let amplitude = p.expectedPGA * 0.35 * (p.soil.amplification - 1)
        guard amplitude > 0 else { return }

        let phase = rng.uniform(0, 2 * Double.pi)
        for i in 0..<n {
            let t = Double(i) * dt
            guard t >= startTime else { continue }
            let elapsed = t - startTime
            let env = exp(-zeta * omega * elapsed * 0.35)
            let value = amplitude * env * sin(omega * elapsed + phase)
            x[i] += value * 0.8
            y[i] += value * 0.6
        }
    }

    private static func normalise(_ x: inout [Double]) {
        let peak = Stats.peakAbs(x)
        guard peak > 1e-30 else { return }
        for i in x.indices { x[i] /= peak }
    }
}
