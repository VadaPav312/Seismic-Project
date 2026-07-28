import Foundation
import AVFoundation
import Combine
import SeismicCore
import SeismicServices
#if canImport(Speech)
import Speech
#endif

/// Everything spoken, and everything heard.
///
/// Two things are deliberate here. Speech output falls back to the on-device
/// voice rather than going silent — during an earthquake the local voice is
/// arguably the better product, because it cannot be delayed by the congested
/// cell tower that the earthquake just congested. And speech *input* only ever
/// proposes an action: anything physical is confirmed before it happens,
/// because a misheard word must not be able to shut off somebody's gas.
@MainActor
final class VoiceController: NSObject, ObservableObject {

    @Published private(set) var isSpeaking = false
    @Published private(set) var lastSpoken = ""
    @Published private(set) var voiceProvider = "System voice"

    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    @Published private(set) var recognisedCommand: VoiceCommand?
    @Published var pendingConfirmation: VoiceCommand?
    @Published private(set) var listeningError: String?

    /// Off unless the user turns it on. Nothing in this app opens a microphone
    /// without being asked to.
    @Published var isVoiceControlEnabled = false {
        didSet {
            UserDefaults.standard.set(isVoiceControlEnabled, forKey: "voiceControlEnabled")
            if !isVoiceControlEnabled { stopListening() }
        }
    }

    @Published var speaksAutomatically = true {
        didSet { UserDefaults.standard.set(speaksAutomatically, forKey: "speaksAutomatically") }
    }

    private let speech: SpeechService
    private let synthesiser = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?

    #if canImport(Speech)
    private let recogniser = SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
        ?? SFSpeechRecognizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    #endif

    init(speech: SpeechService) {
        self.speech = speech
        super.init()
        synthesiser.delegate = self
        let defaults = UserDefaults.standard
        isVoiceControlEnabled = defaults.bool(forKey: "voiceControlEnabled")
        speaksAutomatically = defaults.object(forKey: "speaksAutomatically") as? Bool ?? true
    }

    // MARK: Speaking

    func speak(_ text: String, urgency: SpeechService.Urgency = .normal, force: Bool = false) {
        guard force || speaksAutomatically else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastSpoken = trimmed

        Task { @MainActor in
            let result = await speech.speak(trimmed, urgency: urgency)
            voiceProvider = result.provider
            switch result.value {
            case .audio(let data, _):
                playAudio(data)
            case .systemVoice(let spoken, let rate):
                speakLocally(spoken, rate: rate, urgency: urgency)
            }
        }
    }

    /// The line said during an event. Spoken with `force`, because somebody who
    /// muted the app's chatter last week still needs to hear this one.
    func announceEmergency(_ text: String) {
        speak(text, urgency: .emergency, force: true)
    }

    func stopSpeaking() {
        synthesiser.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        isSpeaking = false
    }

    private func speakLocally(_ text: String, rate: Double,
                              urgency: SpeechService.Urgency) {
        configureSession(forSpeaking: true, urgency: urgency)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(rate) * AVSpeechUtteranceDefaultSpeechRate / 0.5
        utterance.pitchMultiplier = urgency == .emergency ? 0.95 : 1.0
        utterance.postUtteranceDelay = 0.1
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
            ?? AVSpeechSynthesisVoice(language: "en-US")
        isSpeaking = true
        synthesiser.speak(utterance)
    }

    private func playAudio(_ data: Data) {
        configureSession(forSpeaking: true, urgency: .normal)
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            self.player = player
            isSpeaking = true
        } catch {
            // The synthesised audio would not decode. The words still matter,
            // so they are said by the device instead of being dropped.
            speakLocally(lastSpoken, rate: 0.48, urgency: .normal)
        }
    }

    private func configureSession(forSpeaking speaking: Bool,
                                  urgency: SpeechService.Urgency) {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // An emergency announcement interrupts and ducks everything else; the
        // ordinary readout politely mixes with whatever is playing.
        let options: AVAudioSession.CategoryOptions =
            urgency == .emergency ? [.duckOthers, .defaultToSpeaker] : [.mixWithOthers]
        try? session.setCategory(.playback, mode: .spokenAudio, options: options)
        try? session.setActive(speaking)
        #endif
    }

    // MARK: Listening

    var isSpeechRecognitionAvailable: Bool {
        #if canImport(Speech)
        return recogniser?.isAvailable ?? false
        #else
        return false
        #endif
    }

    func requestPermissions() async -> Bool {
        #if canImport(Speech)
        let speechAuthorised = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechAuthorised else { return false }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #else
        return false
        #endif
    }

    func startListening() {
        #if canImport(Speech)
        guard !isListening else { return }
        guard let recogniser, recogniser.isAvailable else {
            listeningError = "Speech recognition is not available on this device."
            return
        }

        Task { @MainActor in
            guard await requestPermissions() else {
                listeningError = "Microphone or speech access was declined. "
                               + "Voice control is off; everything else is unaffected."
                isVoiceControlEnabled = false
                return
            }
            beginRecognition(with: recogniser)
        }
        #else
        listeningError = "Speech recognition is not available on this platform."
        #endif
    }

    #if canImport(Speech)
    private func beginRecognition(with recogniser: SFSpeechRecognizer) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            listeningError = "The microphone is in use by something else."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On-device where the hardware allows it. A safety app has no business
        // sending a live microphone feed to a server if it does not have to.
        request.requiresOnDeviceRecognition = recogniser.supportsOnDeviceRecognition
        recognitionRequest = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            listeningError = "Could not start the microphone."
            return
        }

        isListening = true
        listeningError = nil
        transcript = ""

        recognitionTask = recogniser.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if let command = VoiceCommand.parse(self.transcript) {
                        self.handle(command)
                    }
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.stopListening()
                }
            }
        }
    }
    #endif

    func stopListening() {
        #if canImport(Speech)
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        #endif
        isListening = false
    }

    /// A recognised command either runs or waits for a tap, depending on
    /// whether it moves anything physical.
    private func handle(_ command: VoiceCommand) {
        if command.requiresConfirmation {
            pendingConfirmation = command
            recognisedCommand = nil
            speak("Say that again by tapping to confirm: \(command.confirmation)",
                  urgency: .normal, force: true)
        } else {
            recognisedCommand = command
            if !command.confirmation.isEmpty {
                speak(command.confirmation, urgency: .normal)
            }
        }
        stopListening()
    }

    func confirmPending() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        recognisedCommand = pending
    }

    func cancelPending() {
        pendingConfirmation = nil
        speak("Cancelled.", urgency: .calm)
    }

    func consumeCommand() -> VoiceCommand? {
        defer { recognisedCommand = nil }
        return recognisedCommand
    }
}

extension VoiceController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}

extension VoiceController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
