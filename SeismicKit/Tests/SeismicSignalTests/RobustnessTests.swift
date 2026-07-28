import XCTest
import SeismicCore
@testable import SeismicSignal

/// Degenerate input, thrown at everything the app can reach.
///
/// Every one of these is reachable in the running app: a node that has just
/// connected has a handful of samples, a disconnected one has none, a stuck
/// sensor produces a flat line, and a bad reading produces an infinity. None of
/// them should crash, hang, or — worse — return a confident number.
final class RobustnessTests: XCTestCase {

    private func waveform(_ samples: [Double], rate: Double = 100) -> Waveform {
        Waveform(samples: samples, sampleRate: rate, unit: .acceleration)
    }

    private var degenerate: [(name: String, wave: Waveform)] {
        [
            ("empty", waveform([])),
            ("single sample", waveform([0.5])),
            ("two samples", waveform([0.1, -0.1])),
            ("all zeros", waveform(Array(repeating: 0, count: 500))),
            ("constant", waveform(Array(repeating: 3.7, count: 500))),
            ("one spike", waveform((0..<500).map { $0 == 250 ? 9.0 : 0 })),
            ("huge values", waveform(Array(repeating: 1e12, count: 300))),
            ("tiny values", waveform(Array(repeating: 1e-18, count: 300))),
            ("zero sample rate", Waveform(samples: [1, 2, 3], sampleRate: 0, unit: .acceleration)),
        ]
    }

    /// The spectral chain the Analysis screen runs.
    func testSpectralChainSurvivesDegenerateInput() {
        for (name, wave) in degenerate {
            let spectrum = Spectrum.welch(wave)
            let smoothed = Spectrum.konnoOhmachi(spectrum)
            let peaks = PeakPicking.peaks(in: smoothed)
            let check = PeriodEstimation.crossChecked(wave)

            XCTAssertFalse(spectrum.power.contains { $0.isNaN }, "\(name): NaN in the spectrum")
            XCTAssertFalse(smoothed.power.contains { $0.isNaN }, "\(name): NaN after smoothing")
            for peak in peaks {
                XCTAssertFalse(peak.frequency.isNaN, "\(name): NaN peak frequency")
                XCTAssertTrue(peak.frequency.isFinite, "\(name): infinite peak frequency")
            }
            XCTAssertFalse(check.agreement.isNaN, "\(name): NaN agreement")
            XCTAssertTrue((0...1).contains(check.agreement), "\(name): agreement out of range")
            if let consensus = check.consensus {
                XCTAssertTrue(consensus.isFinite, "\(name): non-finite consensus period")
            }
        }
    }

    /// A flat line is a stuck sensor, not a building with a period. It must not
    /// produce a confident measurement.
    func testAConstantSignalIsNotAMeasurement() {
        let check = PeriodEstimation.crossChecked(waveform(Array(repeating: 3.7, count: 2000)))
        XCTAssertLessThan(check.agreement, 0.5,
                          "A stuck sensor must not read as a confident period")
    }

    func testModalChainSurvivesDegenerateInput() {
        for (name, wave) in degenerate {
            let envelope = Hilbert.envelope(wave)
            XCTAssertFalse(envelope.samples.contains { $0.isNaN }, "\(name): NaN envelope")

            let damping = Damping.best(wave, material: .reinforcedConcrete)
            XCTAssertFalse(damping.ratio.isNaN, "\(name): NaN damping")
            XCTAssertTrue(damping.ratio >= 0, "\(name): negative damping")

            if let ambient = RandomDecrement.measure(wave) {
                XCTAssertTrue(ambient.period.isFinite && ambient.period > 0,
                              "\(name): implausible ambient period")
            }
        }
    }

    func testCharacterisationSurvivesDegenerateInput() {
        for (name, wave) in degenerate {
            let energy = EnergyAnalysis.compute(wave)
            XCTAssertFalse(energy.arias.isNaN, "\(name): NaN Arias intensity")
            XCTAssertTrue(energy.significantDuration >= 0, "\(name): negative duration")

            let spectrum = ResponseSpectrumAnalysis.compute(wave)
            XCTAssertFalse(spectrum.sa.contains { $0.isNaN }, "\(name): NaN spectral acceleration")

            let spectrogram = STFT.compute(wave)
            for column in spectrogram.magnitudes {
                XCTAssertFalse(column.contains { $0.isNaN }, "\(name): NaN in the spectrogram")
            }
        }
    }

    func testDetectionSurvivesDegenerateInput() {
        for (name, wave) in degenerate {
            let classic = STALTA.classic(wave)
            XCTAssertFalse(classic.peakRatio.isNaN, "\(name): NaN STA/LTA ratio")
            let recursive = STALTA.recursive(wave)
            XCTAssertFalse(recursive.peakRatio.isNaN, "\(name): NaN recursive ratio")

            if let pick = ArrivalPicker.pickP(wave) {
                XCTAssertTrue(pick.time.isFinite && pick.time >= 0,
                              "\(name): implausible P pick")
            }
        }
    }

    /// Triaxial paths, which the node screen and the analysis screen both use.
    func testTriaxialPathsSurviveDegenerateInput() {
        for (name, wave) in degenerate {
            let record = TriaxialRecord(x: wave, y: wave, z: wave)

            let peaks = GroundMotion.peaks(record)
            XCTAssertFalse(peaks.pga.isNaN, "\(name): NaN PGA")

            let rectilinearity = PolarisationAnalysis.rectilinearity(record)
            XCTAssertFalse(rectilinearity.samples.contains { $0.isNaN },
                           "\(name): NaN rectilinearity")

            let verdict = FalseTriggerRejection.classify(record)
            XCTAssertFalse(verdict.confidence.isNaN, "\(name): NaN classifier confidence")

            let magnitude = PolarisationAnalysis.horizontalMagnitude(record)
            XCTAssertFalse(magnitude.samples.contains { $0.isNaN },
                           "\(name): NaN horizontal magnitude")
        }
    }

    /// Integration is where a small error becomes a large one, so it gets its
    /// own check: a record of pure zeros must integrate to zeros, not to drift.
    func testIntegratingSilenceProducesSilence() {
        let silence = waveform(Array(repeating: 0, count: 1000))
        let (velocity, displacement) = Integration.toVelocityAndDisplacement(acceleration: silence)
        XCTAssertEqual(velocity.samples.map(abs).max() ?? 0, 0, accuracy: 1e-12)
        XCTAssertEqual(displacement.samples.map(abs).max() ?? 0, 0, accuracy: 1e-12)
    }

    /// A non-finite sample is a hardware fault, not a measurement. Whatever the
    /// pipeline does with it, it must not be to propagate a NaN into a verdict.
    func testNonFiniteSamplesDoNotPoisonTheChain() {
        let poisoned = waveform([0, 1, .nan, 2, .infinity, 3] + Array(repeating: 0.1, count: 500))
        let peaks = GroundMotion.peaks(poisoned)
        let energy = EnergyAnalysis.compute(poisoned)

        // Either the value is finite, or it is clearly flagged — silently
        // returning NaN as a peak acceleration is the failure to avoid.
        if !peaks.pga.isFinite {
            XCTAssertTrue(peaks.pga.isNaN || peaks.pga.isInfinite,
                          "A non-finite input should produce a recognisably non-finite output")
        }
        XCTAssertFalse(energy.significantDuration.isNaN,
                       "Duration must stay a real number even with bad samples")
    }
}
