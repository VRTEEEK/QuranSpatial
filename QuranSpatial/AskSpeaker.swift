//
//  AskSpeaker.swift
//  QuranSpatial
//
//  Reads an Ask answer aloud, on device, English only (2026-10-06). AVSpeechSynthesizer under
//  the app's existing audio session - no network, no third-party TTS, no session change.
//
//  Manual start only: nothing is spoken until Play is pressed. Stop is immediate, no fade,
//  and is wired to every way the answer can leave the screen (Continue, a new Ask, the panel
//  leaving .answered, the immersive space closing) so speech is never audible while the
//  microphone is open. The bed's duck is a fade and is not that guarantee; this is.
//
//  NEVER speaks Arabic. `AskSpeechScript` builds the lines from the display model and drops
//  any line carrying Arabic-script characters (logged), and never includes links or URLs.
//

import AVFoundation
import Foundation
import os

// MARK: - What is spoken (pure, tested)

enum AskSpeechScript {
    static let fromTheSources = "From the sources."
    static let summaryIntro = "On-device AI summary:"
    static let notAScholar = "Ask is AI-assisted and is not a scholar."

    /// Arabic-script scalars: Arabic, Arabic Supplement, Arabic Extended-A/B, Presentation Forms A/B.
    static func containsArabicScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { s in
            switch s.value {
            case 0x0600...0x06FF, 0x0750...0x077F, 0x0870...0x089F, 0x08A0...0x08FF,
                 0xFB50...0xFDFF, 0xFE70...0xFEFF, 0x1EE00...0x1EEFF:
                return true
            default:
                return false
            }
        }
    }

    static func looksLikeLink(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("http://") || t.contains("https://") || t.contains("www.")
    }

    /// Short source name for "From …": the part after " · " if any, cut at the first comma
    /// or opening parenthesis. "Quran 55:13 · Saheeh International, …" -> "Saheeh International";
    /// "Al-Mukhtasar fi Tafsir al-Quran (English), via …" -> "Al-Mukhtasar fi Tafsir al-Quran".
    static func shortSource(_ sourceLine: String) -> String {
        var s = sourceLine
        if let range = s.range(of: " · ", options: .backwards) { s = String(s[range.upperBound...]) }
        if let comma = s.firstIndex(of: ",") { s = String(s[..<comma]) }
        if let paren = s.range(of: " (") { s = String(s[..<paren.lowerBound]) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The candidate lines in speaking order, before filtering. `referralNote` is the line the
    /// panel shows under "Referred to a scholar" (the panel's substitution when passages follow).
    static func candidateLines(for display: AskDisplay, referralNote: String) -> [String] {
        var lines: [String] = []
        switch display.decision {
        case "answered", "answered-in-part":
            lines.append(fromTheSources)
            if !display.lead.isEmpty { lines.append(summaryIntro); lines.append(display.lead) }
            for p in display.passages {
                lines.append(p.text)
                lines.append("From \(shortSource(p.sourceLine)).")
            }
            lines.append(notAScholar)
        case "referred":
            lines.append("Referred to a scholar.")
            if !referralNote.isEmpty { lines.append(referralNote) }
            for p in display.passages {
                lines.append(p.text)
                lines.append("From \(shortSource(p.sourceLine)).")
            }
            lines.append(notAScholar)
        default:   // not-covered, declined: the label and the note only
            lines.append(AskPanelView.decisionLabel(display.decision) + ".")
            if !display.note.isEmpty { lines.append(display.note) }
        }
        return lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The lines actually spoken: candidates minus anything Arabic-script or link-like.
    /// Returns the skipped lines too, so the caller can log them.
    static func spokenLines(for display: AskDisplay, referralNote: String) -> (spoken: [String], skipped: [String]) {
        var spoken: [String] = [], skipped: [String] = []
        for line in candidateLines(for: display, referralNote: referralNote) {
            if containsArabicScript(line) || looksLikeLink(line) { skipped.append(line) } else { spoken.append(line) }
        }
        return (spoken, skipped)
    }
}

// MARK: - The speaker

@MainActor
@Observable
final class AskSpeaker {
    enum State: Equatable { case idle, speaking, paused }
    private(set) var state: State = .idle

    /// Best male English voice heard on the headset; set after the device voice report. The
    /// selection below falls back to the best-quality male en-* voice, then any en-* voice.
    static let preferredVoiceIdentifier = "com.apple.voice.enhanced.en-US.Evan"
    /// Slightly below the default (0.5), calm. Tuned on the headset.
    static let rate: Float = 0.46
    static let pitch: Float = 0.96
    static let pauseBetweenLines: TimeInterval = 0.35

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let proxy = DelegateProxy()
    @ObservationIgnored private var queued = 0
    @ObservationIgnored private(set) var voice: AVSpeechSynthesisVoice?
    private let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "AskSpeaker")

    init() {
        proxy.onFinishOrCancel = { [weak self] cancelled in self?.utteranceEnded(cancelled: cancelled) }
        synthesizer.delegate = proxy
        voice = Self.chooseVoice(logger: logger)
    }

    // MARK: Voice

    /// Logs every installed en-* voice (name, identifier, gender, quality) and writes the same
    /// list to Documents/ask-voices.txt, then picks: the preferred identifier if installed,
    /// else the best-quality male en-* voice (premium > enhanced > default), else any en-* voice.
    private static func chooseVoice(logger: Logger) -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        func q(_ v: AVSpeechSynthesisVoice) -> Int {
            switch v.quality { case .premium: return 3; case .enhanced: return 2; default: return 1 }
        }
        func g(_ v: AVSpeechSynthesisVoice) -> String {
            switch v.gender { case .male: return "male"; case .female: return "female"; default: return "unspecified" }
        }
        func qn(_ v: AVSpeechSynthesisVoice) -> String {
            switch v.quality { case .premium: return "premium"; case .enhanced: return "enhanced"; default: return "default" }
        }
        var report = "Ask voices (\(english.count) en-* installed):\n"
        for v in english.sorted(by: { q($0) == q($1) ? $0.name < $1.name : q($0) > q($1) }) {
            let line = "  \(v.name)  \(v.identifier)  \(v.language)  \(g(v))  \(qn(v))"
            report += line + "\n"
            logger.notice("Ask voice: \(line, privacy: .public)")
        }
        let chosen: AVSpeechSynthesisVoice? =
            english.first { $0.identifier == preferredVoiceIdentifier }
            ?? english.filter { $0.gender == .male }.max { q($0) < q($1) }
            ?? english.max { q($0) < q($1) }
        report += "chosen: \(chosen.map { "\($0.name)  \($0.identifier)  \(g($0))  \(qn($0))" } ?? "none - system default")\n"
        logger.notice("Ask voice chosen: \(chosen?.identifier ?? "none", privacy: .public)")
        if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("ask-voices.txt") {
            try? report.write(to: url, atomically: true, encoding: .utf8)
        }
        return chosen
    }

    // MARK: Controls

    /// Play from the start, or resume if paused. Never called by anything but the Play button.
    func play(display: AskDisplay, referralNote: String) {
        if state == .paused {
            if synthesizer.continueSpeaking() { state = .speaking }
            return
        }
        stop()
        let script = AskSpeechScript.spokenLines(for: display, referralNote: referralNote)
        for skipped in script.skipped {
            logger.notice("Ask speaker: SKIPPED a line (Arabic script or link), \(skipped.count) chars")
        }
        guard !script.spoken.isEmpty else { return }
        queued = script.spoken.count
        for line in script.spoken {
            let u = AVSpeechUtterance(string: line)
            u.voice = voice
            u.rate = Self.rate
            u.pitchMultiplier = Self.pitch
            u.postUtteranceDelay = Self.pauseBetweenLines
            synthesizer.speak(u)
        }
        state = .speaking
        logger.notice("Ask speaker: speaking \(script.spoken.count) lines via \(self.voice?.identifier ?? "default", privacy: .public)")
    }

    func pause() {
        guard state == .speaking else { return }
        if synthesizer.pauseSpeaking(at: .word) { state = .paused }
    }

    /// Immediate, no fade. Safe to call from any state, any number of times.
    func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused || state != .idle {
            synthesizer.stopSpeaking(at: .immediate)
        }
        queued = 0
        state = .idle
    }

    private func utteranceEnded(cancelled: Bool) {
        if cancelled { queued = 0; state = .idle; return }
        queued = max(0, queued - 1)
        if queued == 0 { state = .idle }
    }

    /// The synthesizer's delegate callbacks are not actor-isolated; this hops them onto the
    /// main actor without making the speaker itself an NSObject.
    private final class DelegateProxy: NSObject, AVSpeechSynthesizerDelegate {
        var onFinishOrCancel: (@MainActor (Bool) -> Void)?
        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            Task { @MainActor [onFinishOrCancel] in onFinishOrCancel?(false) }
        }
        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            Task { @MainActor [onFinishOrCancel] in onFinishOrCancel?(true) }
        }
    }
}
