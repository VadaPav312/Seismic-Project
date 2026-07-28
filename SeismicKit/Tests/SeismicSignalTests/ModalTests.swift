import XCTest
@testable import SeismicSignal
import SeismicCore

// Algorithms 23–34.

final class HilbertTests: XCTestCase {

    func testEnvelopeOfASineIsItsAmplitude() {
        let w = SyntheticMotion.sine(frequency: 4, seconds: 20, sampleRate: 200, amplitude: 3)
        let envelope = Hilbert.envelope(w.samples)
        // Ignore the ends, where the transform's edge effects live.
        let interior = Array(envelope[400..<3600])
        XCTAssertEqual(Stats.mean(interior), 3, accuracy: 0.15)
        XCTAssertLessThan(Stats.stdDev(interior), 0.2)
    }

    func testEnvelopeTracksAnExponentialDecay() {
        let w = SyntheticMotion.freeDecay(period: 0.5, damping: 0.03, seconds: 20,
                                          sampleRate: 200, amplitude: 1)
        let envelope = Hilbert.envelope(w.samples)
        // Should be monotonically decreasing, roughly.
        let early = Stats.mean(Array(envelope[400..<600]))
        let late = Stats.mean(Array(envelope[3000..<3200]))
        XCTAssertGreaterThan(early, late * 3)
    }

    func testInstantaneousFrequencyOfAPureToneIsConstant() {
        let w = SyntheticMotion.sine(frequency: 6, seconds: 20, sampleRate: 200)
        let f = Hilbert.instantaneousFrequency(w.samples, sampleRate: 200)
        let interior = Array(f[400..<3600])
        XCTAssertEqual(Stats.median(interior), 6, accuracy: 0.2)
    }

    func testInstantaneousFrequencyFollowsAChirp() {
        let sampleRate = 200.0, seconds = 30.0
        let n = Int(seconds * sampleRate)
        var phase = 0.0
        var samples = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let f = 2 + 4 * (Double(i) / Double(n))
            phase += 2 * .pi * f / sampleRate
            samples[i] = sin(phase)
        }
        let f = Hilbert.instantaneousFrequency(samples, sampleRate: sampleRate)
        XCTAssertEqual(Stats.median(Array(f[500..<1000])), 2.2, accuracy: 0.5)
        XCTAssertEqual(Stats.median(Array(f[(n - 1000)..<(n - 500)])), 5.8, accuracy: 0.5)
    }
}

final class DampingTests: XCTestCase {

    func testLogarithmicDecrementRecoversAKnownDampingRatio() {
        for trueDamping in [0.01, 0.02, 0.05] {
            let w = SyntheticMotion.freeDecay(period: 1.0, damping: trueDamping,
                                              seconds: 60, sampleRate: 100)
            let estimate = Damping.logarithmicDecrement(w)
            XCTAssertNotNil(estimate, "no estimate at ζ = \(trueDamping)")
            XCTAssertEqual(estimate!.ratio, trueDamping, accuracy: trueDamping * 0.35,
                           "ζ = \(trueDamping) recovered as \(estimate!.ratio)")
            XCTAssertGreaterThan(estimate!.confidence, 0.8)
        }
    }

    func testLogarithmicDecrementSurvivesModerateNoise() {
        let w = SyntheticMotion.freeDecay(period: 1.2, damping: 0.03, seconds: 60,
                                          sampleRate: 100, noise: 0.01)
        let estimate = Damping.logarithmicDecrement(w)
        XCTAssertNotNil(estimate)
        XCTAssertEqual(estimate!.ratio, 0.03, accuracy: 0.015)
    }

    func testHalfPowerBandwidthRecoversDampingFromTheSpectrum() {
        let w = SyntheticMotion.freeDecay(period: 1.0, damping: 0.05, seconds: 120,
                                          sampleRate: 100, noise: 0.0005)
        let estimate = Damping.halfPowerBandwidth(w, band: 0.5...2)
        XCTAssertNotNil(estimate)
        // Half-power is a blunter instrument than log decrement; a factor of two
        // is the realistic expectation, and the app presents it as a cross-check
        // rather than an answer.
        XCTAssertGreaterThan(estimate!.ratio, 0.015)
        XCTAssertLessThan(estimate!.ratio, 0.15)
    }

    func testBestFallsBackToAnAssumedValueRatherThanFailing() {
        var rng = SeededRandom(seed: 3)
        let noise = Waveform(samples: (0..<2000).map { _ in rng.gaussian(sd: 0.001) },
                             sampleRate: 100)
        let estimate = Damping.best(noise, material: .steel)
        XCTAssertEqual(estimate.ratio, ConstructionMaterial.steel.typicalDamping, accuracy: 0.03)
        XCTAssertFalse(estimate.detail.isEmpty)
    }

    func testAbsurdDampingIsRejectedRatherThanReported() {
        // A signal that does not decay at all cannot give a damping ratio.
        let w = SyntheticMotion.sine(frequency: 1, seconds: 30, sampleRate: 100)
        XCTAssertNil(Damping.logarithmicDecrement(w))
    }

    func testPercentIsJustTheRatioScaled() {
        let e = DampingEstimate(ratio: 0.025, method: .assumed, confidence: 1, detail: "")
        XCTAssertEqual(e.percent, 2.5, accuracy: 1e-12)
    }
}

final class RandomDecrementTests: XCTestCase {

    func testExtractsAFreeDecaySignatureFromAmbientNoise() {
        // Ambient vibration of a building with a 1.5 s period — no earthquake,
        // no shaker, just background. The signature must show that period.
        let ambient = SyntheticMotion.ambient(seconds: 600, sampleRate: 50,
                                              noiseFloor: 0.002,
                                              buildingPeriod: 1.5, buildingDamping: 0.02,
                                              seed: 4242)
        let signature = RandomDecrement.signature(ambient, segmentSeconds: 20)
        XCTAssertNotNil(signature, "no signature extracted from ambient data")

        let period = PeriodEstimation.crossChecked(signature!, band: 0.5...4).consensus
        XCTAssertNotNil(period)
        XCTAssertEqual(period!, 1.5, accuracy: 0.35)
    }

    func testMeasureReturnsAPeriodAndConfidence() {
        let ambient = SyntheticMotion.ambient(seconds: 600, sampleRate: 50,
                                              noiseFloor: 0.002, buildingPeriod: 0.9,
                                              seed: 77)
        let measurement = RandomDecrement.measure(ambient, band: 0.3...3)
        XCTAssertNotNil(measurement)
        XCTAssertEqual(measurement!.period, 0.9, accuracy: 0.3)
        XCTAssertGreaterThan(measurement!.confidence, 0)
    }

    func testTooFewCrossingsReturnsNilRatherThanNonsense() {
        let flat = Waveform(samples: [Double](repeating: 0, count: 5000), sampleRate: 100)
        XCTAssertNil(RandomDecrement.signature(flat))
    }
}

final class ModeTrackingTests: XCTestCase {

    private func peak(_ f: Double, _ power: Double) -> SpectralPeak {
        SpectralPeak(binIndex: Int(f * 10), frequency: f, power: power,
                     prominence: 0.5, halfPowerBandwidth: 0.02)
    }

    func testFirstScanNumbersModesByFrequency() {
        let out = ModeTracking.assign(peaks: [peak(3.1, 0.9), peak(1.0, 0.4)], to: [])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].modeNumber, 1)
        XCTAssertEqual(out[0].frequency, 1.0, accuracy: 1e-12)
        XCTAssertEqual(out[1].frequency, 3.1, accuracy: 1e-12)
    }

    func testModesStayMatchedWhenAmplitudesSwap() {
        // This is the failure mode the algorithm exists to prevent: mode two
        // becomes stronger than mode one, and a naive "sort by power" scheme
        // would silently start comparing the wrong histories.
        let first = ModeTracking.assign(peaks: [peak(1.0, 0.9), peak(3.1, 0.3)], to: [])
        let second = ModeTracking.assign(peaks: [peak(1.02, 0.2), peak(3.05, 0.95)], to: first)

        let mode1 = second.first { $0.modeNumber == 1 }
        let mode2 = second.first { $0.modeNumber == 2 }
        XCTAssertEqual(mode1?.frequency ?? 0, 1.02, accuracy: 1e-9)
        XCTAssertEqual(mode2?.frequency ?? 0, 3.05, accuracy: 1e-9)
    }

    func testAPeakTooFarFromAnyTrackBecomesANewMode() {
        let first = ModeTracking.assign(peaks: [peak(1.0, 0.9)], to: [])
        let second = ModeTracking.assign(peaks: [peak(1.01, 0.9), peak(7.5, 0.4)], to: first)
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(second.map(\.modeNumber).sorted(), [1, 2])
        XCTAssertEqual(second.first { $0.modeNumber == 2 }?.frequency ?? 0, 7.5, accuracy: 1e-9)
    }

    func testAMissingPeakSimplyDropsOutRatherThanBeingMisassigned() {
        let first = ModeTracking.assign(peaks: [peak(1.0, 0.9), peak(3.0, 0.5)], to: [])
        let second = ModeTracking.assign(peaks: [peak(1.01, 0.9)], to: first)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].modeNumber, 1)
    }

    func testHistoryFiltersAndSortsChronologically() {
        let now = Date()
        let observations = [
            ModeObservation(modeNumber: 1, frequency: 1.0, amplitude: 1,
                            at: now.addingTimeInterval(100)),
            ModeObservation(modeNumber: 2, frequency: 3.0, amplitude: 1, at: now),
            ModeObservation(modeNumber: 1, frequency: 1.1, amplitude: 1, at: now),
        ]
        let history = ModeTracking.history(of: 1, in: observations)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].frequency, 1.1, accuracy: 1e-12)
    }
}

final class TemperatureNormalisationTests: XCTestCase {

    private func observations(slope: Double, noise: Double, count: Int,
                              seed: UInt64 = 1) -> [ModeObservation] {
        var rng = SeededRandom(seed: seed)
        return (0..<count).map { i in
            let temperature = 5 + Double(i % 25)
            let frequency = 1.0 + slope * (temperature - 15) + rng.gaussian(sd: noise)
            return ModeObservation(modeNumber: 1, frequency: frequency, amplitude: 1,
                                   at: Date().addingTimeInterval(Double(i) * 3600),
                                   temperature: temperature)
        }
    }

    func testRecoversAKnownTemperatureSlope() {
        let model = TemperatureNormalisation.fit(observations(slope: -0.002, noise: 0.0005, count: 120))
        XCTAssertTrue(model.isReliable)
        XCTAssertEqual(model.slope, -0.002, accuracy: 0.0004)
        XCTAssertGreaterThan(model.r2, 0.7)
    }

    func testOutliersAreRejected() {
        var obs = observations(slope: -0.002, noise: 0.0003, count: 100)
        // Three catastrophically bad scans, of the sort a passing lift produces.
        obs[10] = ModeObservation(modeNumber: 1, frequency: 5.0, amplitude: 1,
                                  temperature: 20)
        obs[40] = ModeObservation(modeNumber: 1, frequency: 0.1, amplitude: 1,
                                  temperature: 10)
        obs[70] = ModeObservation(modeNumber: 1, frequency: 4.4, amplitude: 1,
                                  temperature: 25)

        let model = TemperatureNormalisation.fit(obs)
        XCTAssertGreaterThanOrEqual(model.outliersRejected, 3)
        XCTAssertEqual(model.slope, -0.002, accuracy: 0.0008)
    }

    func testNormalisationRemovesTheSeasonalSwing() {
        let model = TemperatureNormalisation.fit(observations(slope: -0.002, noise: 0.0002, count: 150))
        // Same building, measured on a cold morning and a hot afternoon.
        let cold = 1.0 + (-0.002) * (2 - 15)
        let hot = 1.0 + (-0.002) * (30 - 15)

        let coldCorrected = model.normalise(frequency: cold, measuredAt: 2, referenceTemperature: 15)
        let hotCorrected = model.normalise(frequency: hot, measuredAt: 30, referenceTemperature: 15)

        // Uncorrected they differ by nearly 6%, which is squarely in the
        // "significant damage" band. Corrected they must agree.
        XCTAssertGreaterThan(abs(cold - hot) / hot, 0.04)
        XCTAssertEqual(coldCorrected, hotCorrected, accuracy: 0.002)
    }

    func testUnreliableModelDeclinesToCorrect() {
        let model = TemperatureNormalisation.fit(observations(slope: -0.002, noise: 0.5, count: 6))
        XCTAssertFalse(model.isReliable)
        // Refuses to alter the measurement rather than adding noise to it.
        XCTAssertEqual(model.normalise(frequency: 1.234, measuredAt: 30,
                                       referenceTemperature: 15), 1.234, accuracy: 1e-12)
        XCTAssertTrue(model.explanation.contains("Not enough"))
    }

    func testPeriodNormalisationIsTheReciprocalOfFrequencyNormalisation() {
        let model = TemperatureNormalisation.fit(observations(slope: -0.002, noise: 0.0002, count: 150))
        let period = model.normalise(period: 1 / 0.97, measuredAt: 25, referenceTemperature: 15)
        let frequency = model.normalise(frequency: 0.97, measuredAt: 25, referenceTemperature: 15)
        XCTAssertEqual(period, 1 / frequency, accuracy: 1e-9)
    }

    func testNoObservationsGivesAnEmptyButSafeModel() {
        let model = TemperatureNormalisation.fit([])
        XCTAssertFalse(model.isReliable)
        XCTAssertEqual(model.normalise(frequency: 2, measuredAt: 0, referenceTemperature: 20), 2)
    }
}

final class GroundMotionTests: XCTestCase {

    func testPeakValuesOnAKnownSineAreAnalytic() {
        // a = A sin(ωt) → v amplitude A/ω, d amplitude A/ω².
        let f = 1.0, amplitude = 2.0
        let w = SyntheticMotion.sine(frequency: f, seconds: 60, sampleRate: 200, amplitude: amplitude)
        let peaks = GroundMotion.peaks(w)
        let omega = 2 * Double.pi * f

        XCTAssertEqual(peaks.pga, amplitude, accuracy: 0.01)
        XCTAssertEqual(peaks.pgv, amplitude / omega, accuracy: amplitude / omega * 0.25)
        XCTAssertEqual(peaks.pgd, amplitude / (omega * omega),
                       accuracy: amplitude / (omega * omega) * 0.4)
    }

    func testIntensityIsDerivedFromPGA() {
        let strong = GroundMotion.peaks(
            SyntheticMotion.sine(frequency: 2, seconds: 30, sampleRate: 100, amplitude: 3.0))
        XCTAssertGreaterThan(strong.intensity, 6)
        XCTAssertFalse(strong.mercalli.consequence.isEmpty)
    }

    func testEmptyRecordGivesZerosRatherThanCrashing() {
        let peaks = GroundMotion.peaks(Waveform(samples: [], sampleRate: 100))
        XCTAssertEqual(peaks.pga, 0)
        XCTAssertEqual(peaks.pgv, 0)
    }
}

final class EnergyAnalysisTests: XCTestCase {

    func testAriasIntensityScalesWithTheSquareOfAmplitude() {
        let base = SyntheticMotion.sine(frequency: 2, seconds: 30, sampleRate: 100, amplitude: 1)
        let doubled = Waveform(samples: base.samples.map { $0 * 2 }, sampleRate: 100)
        let a = EnergyAnalysis.compute(base).arias
        let b = EnergyAnalysis.compute(doubled).arias
        XCTAssertEqual(b / a, 4, accuracy: 0.05)
    }

    func testCAVScalesLinearlyWithAmplitude() {
        let base = SyntheticMotion.sine(frequency: 2, seconds: 30, sampleRate: 100, amplitude: 1)
        let doubled = Waveform(samples: base.samples.map { $0 * 2 }, sampleRate: 100)
        let a = EnergyAnalysis.compute(base).cav
        let b = EnergyAnalysis.compute(doubled).cav
        XCTAssertEqual(b / a, 2, accuracy: 0.02)
    }

    func testSignificantDurationIgnoresQuietTails() {
        var samples = [Double](repeating: 0, count: 6000)   // 60 s at 100 Hz
        // Energy only between 20 s and 30 s.
        for i in 2000..<3000 {
            samples[i] = sin(Double(i) * 0.3)
        }
        let measures = EnergyAnalysis.compute(Waveform(samples: samples, sampleRate: 100))
        XCTAssertEqual(measures.significantDuration, 9, accuracy: 1.5)
        XCTAssertEqual(measures.durationStart, 20, accuracy: 1.5)
        XCTAssertEqual(measures.durationEnd, 30, accuracy: 1.5)
    }

    func testHusidRisesMonotonicallyFromZeroToOne() {
        let rec = SyntheticMotion.generate(.init(magnitude: 6, distanceKm: 25, seed: 4))
        let measures = EnergyAnalysis.compute(rec.magnitude)
        XCTAssertEqual(measures.husid.first!, 0, accuracy: 1e-9)
        XCTAssertEqual(measures.husid.last!, 1, accuracy: 1e-9)
        for i in 1..<measures.husid.count {
            XCTAssertGreaterThanOrEqual(measures.husid[i], measures.husid[i - 1] - 1e-12)
        }
    }

    func testDamageThresholdDiscriminatesStrongFromWeakShaking() {
        let tiny = SyntheticMotion.ambient(seconds: 60, noiseFloor: 0.001)
        XCTAssertFalse(EnergyAnalysis.compute(tiny).exceedsDamageThreshold)

        let strong = SyntheticMotion.generate(.init(magnitude: 7.0, distanceKm: 12, seed: 9))
        XCTAssertTrue(EnergyAnalysis.compute(strong.magnitude).exceedsDamageThreshold)
    }

    func testExplanationIsAlwaysPresent() {
        let m = EnergyAnalysis.compute(SyntheticMotion.ambient(seconds: 10))
        XCTAssertFalse(m.damageThresholdExplanation.isEmpty)
    }
}

final class ResponseSpectrumTests: XCTestCase {

    func testResonantOscillatorAmplifiesEnormously() {
        // Drive at exactly 1 Hz; the 1 s oscillator must respond far more than a
        // 0.1 s one. This amplification is the single most important idea in the
        // whole app, so it had better be in the numbers.
        let w = SyntheticMotion.sine(frequency: 1.0, seconds: 60, sampleRate: 200, amplitude: 1)
        let spectrum = ResponseSpectrumAnalysis.compute(w, damping: 0.05,
                                                        periods: [0.1, 0.5, 1.0, 2.0, 5.0])
        let resonant = spectrum.sa[2]
        XCTAssertGreaterThan(resonant, spectrum.sa[0] * 3)
        XCTAssertGreaterThan(resonant, spectrum.sa[4] * 3)
        XCTAssertEqual(spectrum.dominantPeriod, 1.0, accuracy: 1e-9)
    }

    func testResonantAmplificationApproachesTheAnalyticFactor() {
        // Steady-state amplification at resonance is 1/(2ζ). At ζ = 5% that is
        // 10×, and the numerical integration should land in the right region.
        let w = SyntheticMotion.sine(frequency: 1.0, seconds: 120, sampleRate: 200, amplitude: 1)
        let response = ResponseSpectrumAnalysis.sdofResponse(acceleration: w, period: 1.0,
                                                             damping: 0.05)
        XCTAssertGreaterThan(response.peakTotalAcceleration, 6)
        XCTAssertLessThan(response.peakTotalAcceleration, 14)
    }

    func testHigherDampingGivesLowerResponse() {
        let w = SyntheticMotion.generate(.init(magnitude: 6.5, distanceKm: 20, seed: 12)).magnitude
        let light = ResponseSpectrumAnalysis.compute(w, damping: 0.02, periods: [0.5, 1, 2])
        let heavy = ResponseSpectrumAnalysis.compute(w, damping: 0.20, periods: [0.5, 1, 2])
        for i in 0..<3 { XCTAssertLessThan(heavy.sa[i], light.sa[i]) }
    }

    func testVeryShortPeriodResponseApproachesGroundAcceleration() {
        // A perfectly rigid structure just rides the ground.
        let w = SyntheticMotion.generate(.init(magnitude: 6, distanceKm: 30, seed: 3)).magnitude
        let spectrum = ResponseSpectrumAnalysis.compute(w, damping: 0.05, periods: [0.02])
        XCTAssertEqual(spectrum.sa[0], w.peakAbsolute, accuracy: w.peakAbsolute * 0.35)
    }

    func testInterpolationAtArbitraryPeriodWorks() {
        let w = SyntheticMotion.generate(.init(magnitude: 6, distanceKm: 30, seed: 3)).magnitude
        let spectrum = ResponseSpectrumAnalysis.compute(w)
        let value = spectrum.sa(atPeriod: 0.73)
        XCTAssertGreaterThan(value, 0)
        XCTAssertLessThan(value, spectrum.sa.max()! * 1.01)
    }

    func testEmptyRecordGivesAZeroSpectrumNotACrash() {
        let spectrum = ResponseSpectrumAnalysis.compute(Waveform(samples: [], sampleRate: 100))
        XCTAssertFalse(spectrum.isEmpty)
        XCTAssertTrue(spectrum.sa.allSatisfy { $0 == 0 })
    }
}

final class EarlyMagnitudeTests: XCTestCase {

    func testLargerEventsGiveLargerEstimates() {
        var estimates: [Double] = []
        for magnitude in [5.0, 6.0, 7.0] {
            let params = SyntheticMotion.EventParameters(magnitude: magnitude, distanceKm: 40,
                                                         preEventSeconds: 10, seed: 55)
            let rec = SyntheticMotion.generate(params)
            guard let estimate = EarlyMagnitude.estimate(rec.z, pArrival: params.preEventSeconds)
            else { return XCTFail("no estimate for M\(magnitude)") }
            estimates.append(estimate.magnitude)
        }
        XCTAssertLessThan(estimates[0], estimates[1])
        XCTAssertLessThan(estimates[1], estimates[2])
    }

    func testUncertaintyIsWiderWithLessData() {
        let params = SyntheticMotion.EventParameters(magnitude: 6.5, distanceKm: 30,
                                                     preEventSeconds: 10, seed: 8)
        let rec = SyntheticMotion.generate(params)
        let brief = EarlyMagnitude.estimate(rec.z, pArrival: 10, windowSeconds: 1.0)
        let full = EarlyMagnitude.estimate(rec.z, pArrival: 10, windowSeconds: 3.0)
        XCTAssertNotNil(brief); XCTAssertNotNil(full)
        XCTAssertGreaterThan(brief!.uncertainty, full!.uncertainty)
    }

    func testEstimateExplainsItsWorking() {
        let params = SyntheticMotion.EventParameters(magnitude: 6.2, distanceKm: 25,
                                                     preEventSeconds: 10, seed: 2)
        let rec = SyntheticMotion.generate(params)
        let estimate = EarlyMagnitude.estimate(rec.z, pArrival: 10)
        XCTAssertNotNil(estimate)
        XCTAssertTrue(estimate!.explanation.contains("characteristic period"))
        XCTAssertTrue(estimate!.range.contains(estimate!.magnitude))
    }

    func testTooShortARecordReturnsNil() {
        XCTAssertNil(EarlyMagnitude.estimate(Waveform(samples: [1, 2, 3], sampleRate: 100),
                                             pArrival: 0))
    }
}

final class SyntheticMotionTests: XCTestCase {

    func testSameSeedProducesIdenticalRecords() {
        let a = SyntheticMotion.generate(.init(magnitude: 6, distanceKm: 30, seed: 4242))
        let b = SyntheticMotion.generate(.init(magnitude: 6, distanceKm: 30, seed: 4242))
        XCTAssertEqual(a.x.samples, b.x.samples)
    }

    func testDifferentSeedsProduceDifferentRecords() {
        let a = SyntheticMotion.generate(.init(magnitude: 6, distanceKm: 30, seed: 1))
        let b = SyntheticMotion.generate(.init(magnitude: 6, distanceKm: 30, seed: 2))
        XCTAssertNotEqual(a.x.samples, b.x.samples)
    }

    func testPArrivesBeforeSAndBothAfterTheQuietPeriod() {
        let p = SyntheticMotion.EventParameters(magnitude: 6.5, distanceKm: 50, depthKm: 10)
        XCTAssertLessThan(p.pTravelTime, p.sTravelTime)
        XCTAssertGreaterThan(p.sMinusP, 0)
        // The rule of thumb: S−P in seconds is roughly distance/8 km.
        XCTAssertEqual(p.sMinusP, p.hypocentralDistanceKm / 8, accuracy: p.sMinusP * 0.3)
    }

    func testShakingIsQuietBeforeThePWaveArrives() {
        let p = SyntheticMotion.EventParameters(magnitude: 6.5, distanceKm: 30,
                                                preEventSeconds: 15, seed: 11)
        let rec = SyntheticMotion.generate(p)
        let quiet = rec.magnitude.slice(from: 0, to: 10)
        let shaking = rec.magnitude.slice(from: p.preEventSeconds + p.sMinusP,
                                          to: p.preEventSeconds + p.sMinusP + 5)
        XCTAssertGreaterThan(shaking.peakAbsolute, quiet.peakAbsolute * 10)
    }

    func testAmplitudeFallsWithDistance() {
        let near = SyntheticMotion.EventParameters(magnitude: 6.5, distanceKm: 10).expectedPGA
        let far = SyntheticMotion.EventParameters(magnitude: 6.5, distanceKm: 200).expectedPGA
        XCTAssertGreaterThan(near, far * 5)
    }

    func testAmplitudeRisesWithMagnitude() {
        let small = SyntheticMotion.EventParameters(magnitude: 4.5, distanceKm: 30).expectedPGA
        let large = SyntheticMotion.EventParameters(magnitude: 7.0, distanceKm: 30).expectedPGA
        XCTAssertGreaterThan(large, small * 3)
    }

    func testSoftSoilAmplifiesRelativeToRock() {
        let rock = SyntheticMotion.EventParameters(magnitude: 6, distanceKm: 30,
                                                   soil: .rock).expectedPGA
        let soft = SyntheticMotion.EventParameters(magnitude: 6, distanceKm: 30,
                                                   soil: .softSoil).expectedPGA
        XCTAssertGreaterThan(soft, rock * 1.5)
    }

    func testCornerFrequencyFallsWithMagnitude() {
        let small = SyntheticMotion.EventParameters(magnitude: 4).cornerFrequency
        let large = SyntheticMotion.EventParameters(magnitude: 7.5).cornerFrequency
        XCTAssertGreaterThan(small, large)
    }

    func testAftershockSequenceFollowsOmoriAndBath() {
        let sequence = SyntheticMotion.aftershockSequence(mainshockMagnitude: 7.0, hours: 168,
                                                          seed: 9)
        XCTAssertFalse(sequence.isEmpty)
        // Båth: no aftershock within 1.2 magnitude units of the mainshock.
        XCTAssertLessThanOrEqual(sequence.map(\.magnitude).max()!, 7.0 - 1.2 + 1e-9)
        // Omori: far more in the first day than in the last.
        let firstDay = sequence.filter { $0.hoursAfterMainshock < 24 }.count
        let lastDay = sequence.filter { $0.hoursAfterMainshock > 144 }.count
        XCTAssertGreaterThan(firstDay, lastDay * 2)
        // Sorted chronologically.
        XCTAssertEqual(sequence.map(\.hoursAfterMainshock),
                       sequence.map(\.hoursAfterMainshock).sorted())
    }

    func testAmbientWithABuildingPeriodShowsThatPeriod() {
        let ambient = SyntheticMotion.ambient(seconds: 400, sampleRate: 50, noiseFloor: 0.002,
                                              buildingPeriod: 2.0, seed: 6)
        let spectrum = Spectrum.konnoOhmachi(Spectrum.welch(ambient, segmentSeconds: 50))
        let peak = PeakPicking.peaks(in: spectrum, minimumProminence: 0.02,
                                     band: 0.2...2.0).max { $0.power < $1.power }
        XCTAssertNotNil(peak)
        XCTAssertEqual(peak!.period, 2.0, accuracy: 0.6)
    }

    func testGeneratedRecordSurvivesTheWholeAnalysisPipeline() {
        // The end-to-end sanity check: a synthetic event must be detectable,
        // pickable, characterisable and classifiable without any step failing.
        let params = SyntheticMotion.EventParameters(magnitude: 6.4, distanceKm: 35,
                                                     preEventSeconds: 15, seed: 20260727)
        let rec = SyntheticMotion.generate(params)

        XCTAssertTrue(STALTA.classic(rec.magnitude).didTrigger)
        XCTAssertTrue(FalseTriggerRejection.classify(rec).isEarthquake)
        XCTAssertNotNil(PolarisationAnalysis.pickArrivals(rec).pTime)
        XCTAssertGreaterThan(GroundMotion.peaks(rec).pga, 0)
        XCTAssertGreaterThan(EnergyAnalysis.compute(rec.magnitude).arias, 0)
        XCTAssertFalse(ResponseSpectrumAnalysis.compute(rec.magnitude).isEmpty)
    }
}
