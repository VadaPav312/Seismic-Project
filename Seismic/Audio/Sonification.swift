import Foundation
import AVFoundation
import Combine

/// Hearing a building.
///
/// A building's natural period is one to three seconds. That is far below
/// hearing, so it is transposed up by whole octaves — a pure multiplication,
/// which preserves every ratio exactly. A period that lengthens by three per
/// cent produces a tone that flattens by three per cent, and nothing else about
/// the sound changes.
///
/// That is what makes the second mode worth having. Play the before-period and
/// the after-period together and the difference stops being a number on a
/// screen: two tones nine hertz apart beat against each other about nine times
/// a second, and you hear the damage as a throb. People who cannot read a
/// spectrum can hear a wobble instantly, and they trust their own ears in a way
/// they will never trust a chart.
@MainActor
final class PeriodSonifier: ObservableObject {

    /// Six octaves up. Chosen so a one-second period lands at 64 Hz — low,
    /// building-like, and still comfortably above the bottom of hearing — while
    /// a fast 0.2 s period lands at 320 Hz rather than somewhere piercing.
    static let octaveShift: Double = 64

    @Published private(set) var isPlaying = false
    @Published private(set) var mode: Mode = .single
    @Published private(set) var describedPitch = "—"
    @Published private(set) var beatRate: Double?

    enum Mode: String, CaseIterable, Identifiable {
        case single, beat, modal
        var id: String { rawValue }

        var label: String {
            switch self {
            case .single: "Single tone"
            case .beat: "Before and after"
            case .modal: "First three modes"
            }
        }

        var explanation: String {
            switch self {
            case .single:
                "The building's period, transposed up six octaves so you can hear it. "
                + "Lower pitch means a longer period, which means a softer building."
            case .beat:
                "Both periods at once. The throb you hear is the difference between them — "
                + "the faster the throb, the bigger the change."
            case .modal:
                "The first three mode shapes together. The higher modes are quieter because "
                + "they carry less of the building's mass."
            }
        }
    }

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var phases: [Double] = [0, 0, 0]
    private var frequencies: [Double] = []
    private var amplitudes: [Double] = []
    private let sampleRate: Double = 44_100
    /// Ramped rather than switched, because a hard start on a sine wave is a
    /// click, and a click is the one sound guaranteed to make somebody stop.
    private var envelope: Double = 0
    private var targetEnvelope: Double = 0

    // MARK: Public control

    /// One period, one tone.
    func play(period: Double) {
        guard period > 0.01 else { return }
        let frequency = Self.audibleFrequency(forPeriod: period)
        mode = .single
        beatRate = nil
        describedPitch = String(format: "%.1f Hz  (period %.3f s)", frequency, period)
        start(frequencies: [frequency], amplitudes: [0.35])
    }

    /// Two periods at once. The beat frequency is their difference in the
    /// transposed domain, which is exactly the period change made audible.
    func playComparison(before: Double, after: Double) {
        guard before > 0.01, after > 0.01 else { return }
        let f1 = Self.audibleFrequency(forPeriod: before)
        let f2 = Self.audibleFrequency(forPeriod: after)
        mode = .beat
        beatRate = abs(f1 - f2)
        describedPitch = String(format: "%.1f Hz against %.1f Hz — beating %.1f times a second",
                                f1, f2, abs(f1 - f2))
        start(frequencies: [f1, f2], amplitudes: [0.28, 0.28])
    }

    /// The first three modes as a chord, weighted by participation so the
    /// balance you hear is the balance of the building's actual response.
    func playModes(periods: [Double], participation: [Double]) {
        let pairs = zip(periods, participation).prefix(3).filter { $0.0 > 0.01 }
        guard !pairs.isEmpty else { return }
        let total = pairs.reduce(0.0) { $0 + abs($1.1) }
        mode = .modal
        beatRate = nil
        let frequencies = pairs.map { Self.audibleFrequency(forPeriod: $0.0) }
        let amplitudes = pairs.map { total > 0 ? 0.45 * abs($0.1) / total : 0.15 }
        describedPitch = frequencies.map { String(format: "%.0f Hz", $0) }
            .joined(separator: " · ")
        start(frequencies: frequencies, amplitudes: amplitudes)
    }

    func stop() {
        targetEnvelope = 0
        // Let the envelope fall before tearing the engine down, so the tone
        // fades rather than cutting.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            self.teardown()
        }
    }

    static func audibleFrequency(forPeriod period: Double) -> Double {
        (1.0 / period) * octaveShift
    }

    // MARK: Engine

    private func start(frequencies: [Double], amplitudes: [Double]) {
        teardown()
        self.frequencies = frequencies
        self.amplitudes = amplitudes
        self.phases = Array(repeating: 0, count: frequencies.count)
        self.envelope = 0
        self.targetEnvelope = 1

        #if os(iOS)
        // Ambient: this is decorative sound and must never interrupt somebody's
        // music, and must never be what is playing when an alert needs to be.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let increment = frequencies.map { 2 * Double.pi * $0 / sampleRate }

        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                // 30 ms attack and release. Slow enough to be inaudible as a
                // transient, fast enough to feel immediate.
                self.envelope += (self.targetEnvelope - self.envelope) * 0.0008
                var sample = 0.0
                for voice in self.phases.indices {
                    sample += sin(self.phases[voice]) * self.amplitudes[voice]
                    self.phases[voice] += increment[voice]
                    if self.phases[voice] > 2 * Double.pi {
                        self.phases[voice] -= 2 * Double.pi
                    }
                }
                let value = Float(sample * self.envelope)
                for buffer in buffers {
                    let pointer = UnsafeMutableBufferPointer<Float>(buffer)
                    if frame < pointer.count { pointer[frame] = value }
                }
            }
            return noErr
        }

        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            isPlaying = true
        } catch {
            // Audio is a nicety. If the session cannot start — another app owns
            // it, a call is in progress — the screen simply stays silent and
            // says so rather than failing.
            isPlaying = false
            describedPitch = "Audio is unavailable right now."
        }
    }

    private func teardown() {
        if engine.isRunning { engine.stop() }
        if let sourceNode {
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
        isPlaying = false
        beatRate = nil
    }

    deinit {
        // Cannot touch main-actor state here; stopping the engine is enough and
        // is safe from any thread.
        engine.stop()
    }
}
