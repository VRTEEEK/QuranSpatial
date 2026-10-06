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

/// 1.5 s of silence after speech ends the capture. Silence is RMS below the threshold in
/// force, `effectiveThreshold`.
///
/// **Adaptive threshold, 2026-10-06.** Three device Asks (AirPods on, AirPods off, speaking
/// from the first frame) all ran to the 20 s cap: speech was heard, and the RMS then never
/// stayed under the fixed 0.012 for 1.5 s. That is a noise floor at or above the threshold,
/// so the detector could not see silence. The threshold in force is now
/// `max(threshold, floorMargin × runningFloor)`, where the running floor is the lowest RMS
/// seen so far in this capture. A floor under 0.004 leaves 0.012 exactly as it was, so every
/// pre-existing verdict holds; a floor of 0.02 raises the bar to 0.06, and quiet at 0.02 is
/// silence again. The floor is the minimum of the mean of `floorWindow` consecutive live
/// buffers (about 255 ms at the tap's cadence), not of single buffers: a single 85 ms dip,
/// a gap between words or a gated quiet moment, would otherwise drag the floor under the
/// room level and put the threshold back at 0.012, the failure this exists to fix. Speech
/// has pauses of 255 ms and more between phrases, which is what seeds the floor when the
/// wearer speaks from the first buffer; perfectly constant speech cannot be told from a
/// floor by level alone. Nothing is judged speech before the floor exists, so a raised
/// floor's opening buffers are never mistaken for a word.
struct SilenceDetector: Equatable {
    var silenceSeconds: TimeInterval = 1.5
    /// The fixed lower bound of the threshold in force. Never the whole story since 2026-10-06.
    var threshold: Float = 0.012
    var floorMargin: Float = 3
    /// Nothing heard yet: the detector waits at most `noSpeechCap` before giving up.
    var noSpeechCap: TimeInterval = 8
    /// Was 20 s. Lowered 2026-10-06: if silence detection fails, the wait must still be bearable.
    var hardCap: TimeInterval = 10

    private(set) var heardSpeech = false
    private(set) var lastSpeechAt: TimeInterval?
    private(set) var startedAt: TimeInterval?
    /// Lowest `floorWindow`-buffer mean seen so far in this capture; nil until the first
    /// full window of live buffers.
    private(set) var runningFloor: Float?
    /// Consecutive live buffers whose mean is one floor sample.
    var floorWindow: Int = 3
    /// Buffers under this are dead air (the engine's first buffers can be zeros), not a floor:
    /// they are left out of the window, since a mean including zeros would pin the floor low
    /// and the adaptive threshold would never engage.
    var deadBufferRMS: Float = 0.0005
    private var liveWindow: [Float] = []

    /// The threshold in force: the fixed bound, or three times the running floor if higher.
    var effectiveThreshold: Float { max(threshold, (runningFloor ?? 0) * floorMargin) }

    enum Verdict: Equatable { case keepListening, stopSilence, stopNoSpeech, stopCap }

    mutating func feed(rms: Float, at time: TimeInterval) -> Verdict {
        if startedAt == nil { startedAt = time }
        // Floor first, then the judgement, and no judgement until a floor exists: a raised
        // floor's opening buffers would otherwise read as speech against the fixed bound and
        // start the silence clock before a word was said.
        if rms >= deadBufferRMS {
            liveWindow.append(rms)
            if liveWindow.count > floorWindow { liveWindow.removeFirst() }
            if liveWindow.count == floorWindow {
                let mean = liveWindow.reduce(0, +) / Float(floorWindow)
                runningFloor = min(runningFloor ?? mean, mean)
            }
        }
        if runningFloor != nil, rms >= effectiveThreshold { heardSpeech = true; lastSpeechAt = time }
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
    /// The RMS the tap already computes for the silence rule, published for the listening
    /// waveform (Ask addendum, 2026-10-05). Written on the main actor from `feedSilence`
    /// BEFORE its state guard, so it is live for every buffer; 0 outside a capture. Updates at
    /// the tap's cadence (4096 frames, ~85 ms at 48 kHz). Read only by the waveform view.
    private(set) var inputLevel: Float = 0
    /// Safety net for the panel (step 6, 2026-10-06): true once listening has run
    /// `stalledAfterSeconds` past the last heard speech (or past the start, if nothing was
    /// heard) without the detector stopping. The Done pill is shown only while this is true.
    /// Not a control: a correctly firing silence stop keeps it false for every Ask.
    private(set) var isStalled = false
    static let stalledAfterSeconds: TimeInterval = 6

    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var analyzerTask: Task<Void, Never>?
    @ObservationIgnored private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var sfRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var sfTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var finalText: [String] = []
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var detector = SilenceDetector()
    /// Every RMS the detector was fed this capture, with its time, for the one stop line below
    /// (instrumentation, 2026-10-06): the device log had no record of what the detector saw.
    @ObservationIgnored private var rmsTrace: [(t: TimeInterval, rms: Float)] = []
    /// When `stop(reason:)` ran, so `finish` can log how long the recogniser's finalisation
    /// took after the detector fired: the panel used to show "Listening…" for all of it.
    @ObservationIgnored private var stopRequestedAt: Date?
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
        stopRequestedAt = Date()
        let summary = stopSummaryLine(reason: reason)
        logger.notice("\(summary, privacy: .public)")
        Self.appendStopRecord(summary)
        inputContinuation?.finish()
        sfRequest?.endAudio()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        inputLevel = 0
        isStalled = false
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
        rmsTrace = []; stopRequestedAt = nil
        inputLevel = 0
        isStalled = false
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
        let gap = stopRequestedAt.map { Date().timeIntervalSince($0) } ?? 0
        logger.notice("Ask speech: finished (\(reason, privacy: .public)), \(trimmed.count) chars via \(self.engineName, privacy: .public), finalised \(String(format: "%.2f", gap), privacy: .public) s after stop")
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
        inputLevel = rms
        guard state == .listening else { return }
        rmsTrace.append((t, rms))
        let verdict = detector.feed(rms: rms, at: t)
        if let since = detector.lastSpeechAt ?? detector.startedAt {
            let stalled = verdict == .keepListening && t - since >= Self.stalledAfterSeconds
            if stalled != isStalled { isStalled = stalled }
        }
        switch verdict {
        case .keepListening: break
        case .stopSilence: stop(reason: "silence 1.5 s")
        case .stopNoSpeech: stop(reason: "no speech heard")
        case .stopCap: stop(reason: "time cap")
        }
    }

    /// The stop line, appended to Documents/ask-stops.txt as well as the log (2026-10-06):
    /// `log collect` needs a wired headset, `devicectl` can pull this file over the air.
    private static func appendStopRecord(_ line: String) {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("ask-stops.txt") else { return }
        let record = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        guard let data = record.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// The one line per listening stop that says what the detector saw: reason, duration,
    /// RMS min / median / max over the capture, the threshold in force, and the last 3 s of
    /// RMS one value per buffer. Three decimals rather than two (agreed 2026-10-06), because
    /// the threshold is 0.012 and two decimals cannot say which side of it a value fell.
    private func stopSummaryLine(reason: String) -> String {
        let values = rmsTrace.map(\.rms)
        guard let first = rmsTrace.first, let last = rmsTrace.last, !values.isEmpty else {
            return "Ask speech stop: reason=\(reason) duration=0.00s buffers=0 threshold=\(String(format: "%.3f", detector.effectiveThreshold)) (no RMS fed)"
        }
        let sorted = values.sorted()
        let median = sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        let tail = rmsTrace.filter { $0.t >= last.t - 3 }.map { String(format: "%.3f", $0.rms) }
        return String(format: "Ask speech stop: reason=%@ duration=%.2fs buffers=%d rms min=%.4f median=%.4f max=%.4f threshold=%.3f (fixed %.3f, floor %.4f x%.0f) last3s=[%@]",
                      reason, last.t - first.t, values.count, sorted[0], median, sorted[sorted.count - 1],
                      detector.effectiveThreshold, detector.threshold, detector.runningFloor ?? 0, detector.floorMargin,
                      tail.joined(separator: " "))
    }
}
