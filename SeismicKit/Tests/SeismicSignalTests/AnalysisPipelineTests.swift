import XCTest
import SeismicCore
@testable import SeismicSignal

/// The exact chain the Analysis screen runs, end to end.
///
/// The individual stages are tested elsewhere against analytic answers. What
/// this adds is that the *composition* recovers the right number — which is the
/// thing a user reads off the screen, and the thing that breaks when a stage is
/// wired up in the wrong order or with the wrong argument.
final class AnalysisPipelineTests: XCTestCase {

    /// Ambient motion of a building whose period is known exactly.
    private func ambient(period: Double, seconds: Double = 120,
                         sampleRate: Double = 100) -> Waveform {
        SyntheticMotion.ambient(seconds: seconds, sampleRate: sampleRate,
                                buildingPeriod: period, seed: 20260727)
    }

    func testTheScreensChainRecoversAKnownPeriod() {
        let truth = 0.911
        let record = ambient(period: truth)

        let spectrum = Spectrum.welch(record, window: .hann)
        let smoothed = Spectrum.konnoOhmachi(spectrum)
        let peaks = PeakPicking.peaks(in: smoothed)

        let strongest = try? XCTUnwrap(peaks.first)
        XCTAssertNotNil(strongest, "Ambient motion with a resonance must produce a peak")
        guard let strongest else { return }

        // Within 10%: a Welch spectrum's resolution is set by the segment
        // length, so this is about as tight as it can honestly be asked to be.
        XCTAssertEqual(strongest.period, truth, accuracy: truth * 0.10,
                       "The strongest peak should be the building's own period")
    }

    /// The cross-check panel's whole purpose is that three methods failing in
    /// different ways rarely fail the same way at once.
    func testCrossCheckAgreesOnACleanSignal() {
        let truth = 0.911
        let check = PeriodEstimation.crossChecked(ambient(period: truth))

        XCTAssertGreaterThanOrEqual(check.methodsAgreeing, 2,
                                    "At least two of three methods should agree on a clean signal")
        let consensus = try? XCTUnwrap(check.consensus)
        XCTAssertNotNil(consensus)
        if let consensus {
            XCTAssertEqual(consensus, truth, accuracy: truth * 0.15)
        }
        XCTAssertGreaterThan(check.agreement, 0.5)
    }

    /// A record of pure noise must not produce a confident period. Inventing a
    /// mode from noise is the failure that would put a wrong number under a
    /// verdict.
    func testNoiseDoesNotProduceAConfidentPeriod() {
        var rng = SeededRandom(seed: 99)
        let noise = Waveform(samples: (0..<12_000).map { _ in rng.gaussian() * 0.004 },
                             sampleRate: 100, unit: .acceleration)
        let check = PeriodEstimation.crossChecked(noise)
        XCTAssertLessThan(check.agreement, 0.9,
                          "Pure noise must not read as three methods agreeing")
    }

    /// The response spectrum is what the Analysis screen draws against the
    /// building's own period, so its peak must land near the driving period.
    func testResponseSpectrumPeaksNearTheDrivingPeriod() {
        let drivingPeriod = 0.5
        let drive = SyntheticMotion.sine(frequency: 1 / drivingPeriod, seconds: 40,
                                         sampleRate: 100, amplitude: 1.0)
        let spectrum = ResponseSpectrumAnalysis.compute(drive)

        guard let index = spectrum.sa.indices.max(by: { spectrum.sa[$0] < spectrum.sa[$1] }) else {
            return XCTFail("No response spectrum computed")
        }
        XCTAssertEqual(spectrum.periods[index], drivingPeriod,
                       accuracy: drivingPeriod * 0.25,
                       "A single-frequency drive should excite oscillators of that period most")
    }
}
