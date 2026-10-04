//
//  AskSpeechSession.swift
//  QuranSpatial
//
//  On-device English speech recognition for the Ask question (challenge day 2, 2026-10-04).
//  SpeechAnalyzer + SpeechTranscriber (visionOS 26, on-device by design) when the locale is
//  supported; otherwise SFSpeechRecognizer with on-device recognition REQUIRED. Nothing leaves
//  the device. Listening stops after 1.5 s of silence following speech, on Done, or at the cap.
//
//  The silence rule is a pure value type (`SilenceDetector`) so it is unit-tested without a
//  microphone; everything audio-bound is in `start()`/`stop()`.
//

import AVFoundation
import Foundation
import Observation
import Speech
import os

/// 1.5 s of silence after speech ends the capture. Silence is RMS below `threshold`.
struct SilenceDetector: Equatable {
    var silenceSeconds: TimeInterval = 1.5
    var threshold: Float = 0.012
    /// Nothing heard yet: the detector waits at most `noSpeechCap` before giving up.
    var noSpeechCap: TimeInterval = 8
    var hardCap: TimeInterval = 20

    private(set) var heardSpeech = false
    private(set) var lastSpeechAt: TimeInterval?
    private(set) var startedAt: TimeInterval?

    enum Verdict: Equatable { case keepListening, stopSilence, stopNoSpeech, stopCap }

    mutating func feed(rms: Float, at time: TimeInterval) -> Verdict {
        if startedAt == nil { startedAt = time }
        if rms >= threshold { heardSpeech = true; lastSpeechAt = time }
        let elapsed = time - (startedAt ?? time)
        if elapsed >= hardCap { return .stopCap }
        if let last = lastSpeechAt, heardSpeech, time - last >= silenceSeconds { return .stopSilence }
        if !heardSpeech, elapsed >= noSpeechCap { return .stopNoSpeech }
        return .keepListening
    }
}

@MainActor
@Observable
final class AskSpeechSession {
    enum State: Equatable {
        case idle
        case requestingPermission
        case listening
        case finishing
        case finished(transcript: String, reason: String)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Live partial text while listening (volatile results), for the panel.
    private(set) var partialTranscript = ""
    private(set) var engineName = "none"
    /// Whether the last finish was triggered by silence, Done, or a cap - for the log and HUD.
    private(set) var lastStopReason = ""

    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var analyzerTask: Task<Void, Never>?
    @ObservationIgnored private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var sfRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var sfTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var finalText: [String] = []
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var detector = SilenceDetector()
    private let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "AskSpeech")

    var isListening: Bool { state == .listening }

    func start() async {
        guard state == .idle || isTerminal else { return }
        reset()
        state = .requestingPermission
        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else { fail("microphone permission denied"); return }

        let supported = await SpeechTranscriber.supportedLocales
        if SpeechTranscriber.isAvailable, supported.contains(where: { $0.identifier.hasPrefix("en") }) {
            await startAnalyzer()
        } else {
            await startSFSpeechRecognizer()
        }
    }

    /// Done button, or the silence detector.
    func stop(reason: String) {
        guard state == .listening, !stopRequested else { return }
        stopRequested = true
        lastStopReason = reason
        state = .finishing
        logger.notice("Ask speech: stopping (\(reason, privacy: .public)) via \(self.engineName, privacy: .public)")
        inputContinuation?.finish()
        sfRequest?.endAudio()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        if engineName.hasPrefix("SFSpeechRecognizer") {
            // The SF task delivers its final result after endAudio; give it a moment, then settle.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                self.finishIfStillFinishing()
            }
        }
    }

    func reset() {
        analyzerTask?.cancel(); analyzerTask = nil
        inputContinuation?.finish(); inputContinuation = nil
        sfTask?.cancel(); sfTask = nil; sfRequest = nil
        audioEngine?.inputNode.removeTap(onBus: 0); audioEngine?.stop(); audioEngine = nil
        finalText = []; partialTranscript = ""; stopRequested = false; detector = SilenceDetector()
        state = .idle
    }

    private var isTerminal: Bool {
        if case .finished = state { return true }
        if case .failed = state { return true }
        return false
    }

    private func fail(_ message: String) {
        logger.error("Ask speech failed: \(message, privacy: .public)")
        state = .failed(message)
    }

    private func finish(_ text: String, reason: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.notice("Ask speech: finished (\(reason, privacy: .public)), \(trimmed.count) chars via \(self.engineName, privacy: .public)")
        state = .finished(transcript: trimmed, reason: reason)
    }

    private func finishIfStillFinishing() {
        if state == .finishing { finish((finalText + [partialTranscript]).joined(separator: " "), reason: lastStopReason) }
    }

    // MARK: SpeechAnalyzer path (visionOS 26, on device)

    private func startAnalyzer() async {
        engineName = "SpeechAnalyzer"
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .progressiveTranscription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                logger.notice("Ask speech: installing transcriber assets")
                try await request.downloadAndInstall()
            }
        } catch {
            fail("speech assets: \(error.localizedDescription)"); return
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            fail("no compatible audio format"); return
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        // Results: volatile results replace the partial; final results accumulate.
        let resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await MainActor.run {
                        guard let self else { return }
                        if result.isFinal { self.finalText.append(text); self.partialTranscript = "" }
                        else { self.partialTranscript = text }
                    }
                }
            } catch {
                await MainActor.run { [weak self] in self?.logger.error("Ask speech results: \(error.localizedDescription, privacy: .public)") }
            }
        }

        do {
            try startAudioEngine(targetFormat: format) { [continuation] input in continuation.yield(input) }
        } catch {
            resultsTask.cancel(); fail("audio engine: \(error.localizedDescription)"); return
        }
        state = .listening
        logger.notice("Ask speech: listening via SpeechAnalyzer, format \(format.sampleRate) Hz")

        analyzerTask = Task { [weak self] in
            do {
                try await analyzer.start(inputSequence: stream)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                await MainActor.run { [weak self] in self?.fail("analyzer: \(error.localizedDescription)") }
                resultsTask.cancel(); return
            }
            _ = await resultsTask.result
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.finish((self.finalText + [self.partialTranscript]).joined(separator: " "), reason: self.lastStopReason)
            }
        }
    }

    // MARK: SFSpeechRecognizer path (on-device required)

    private func startSFSpeechRecognizer() async {
        engineName = "SFSpeechRecognizer (on-device)"
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else { fail("speech recognition permission \(status.rawValue)"); return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            fail("speech recognizer unavailable"); return
        }
        guard recognizer.supportsOnDeviceRecognition else { fail("on-device recognition not supported for en-US"); return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        sfRequest = request
        do {
            try startAudioEngine(targetFormat: nil) { [request] input in request.append(input.buffer) }
        } catch { fail("audio engine: \(error.localizedDescription)"); return }
        state = .listening
        logger.notice("Ask speech: listening via SFSpeechRecognizer (on-device)")
        sfTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.partialTranscript = result.bestTranscription.formattedString
                    if result.isFinal { self.finish(self.partialTranscript, reason: self.lastStopReason.isEmpty ? "final" : self.lastStopReason) }
                }
                if let error, self.state == .listening { self.fail("recognition: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: Audio capture with the silence detector

    private func startAudioEngine(targetFormat: AVAudioFormat?, sink: @escaping @Sendable (AnalyzerInput) -> Void) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        let converter = targetFormat.flatMap { native == $0 ? nil : AVAudioConverter(from: native, to: $0) }
        let target = targetFormat ?? native
        let started = Date()
        input.installTap(onBus: 0, bufferSize: 4096, format: native) { [weak self] buffer, _ in
            // RMS for the silence rule, on the native buffer.
            var rms: Float = 0
            if let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var sum: Float = 0
                for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
                rms = (sum / Float(buffer.frameLength)).squareRoot()
            }
            let t = Date().timeIntervalSince(started)
            // Deliver audio.
            if let converter {
                let frames = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / native.sampleRate) + 16
                guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames) else { return }
                var consumed = false
                var convError: NSError?
                converter.convert(to: out, error: &convError) { _, status in
                    if consumed { status.pointee = .noDataNow; return nil }
                    consumed = true; status.pointee = .haveData; return buffer
                }
                if convError == nil, out.frameLength > 0 { sink(AnalyzerInput(buffer: out)) }
            } else {
                sink(AnalyzerInput(buffer: buffer))
            }
            Task { @MainActor in self?.feedSilence(rms: rms, at: t) }
        }
        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    private func feedSilence(rms: Float, at t: TimeInterval) {
        guard state == .listening else { return }
        switch detector.feed(rms: rms, at: t) {
        case .keepListening: break
        case .stopSilence: stop(reason: "silence 1.5 s")
        case .stopNoSpeech: stop(reason: "no speech heard")
        case .stopCap: stop(reason: "time cap")
        }
    }
}
