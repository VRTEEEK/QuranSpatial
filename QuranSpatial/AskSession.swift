//
//  AskSession.swift
//  QuranSpatial
//
//  The Ask flow on the headset (challenge day 2): listen -> transcript -> AskCore -> panel.
//  AskCore is a local Swift package (Packages/AskCore). Until it is linked to the app target in
//  Xcode the flow still compiles and the panel says so; with it linked, the transcript and the
//  pinned ayah go to the engine and the panel shows the decision, the verified lead and the
//  verbatim passages with their source lines. Nothing here generates text about the Quran.
//

import Foundation
import Observation
import os

#if canImport(AskCore)
import AskCore
#endif

/// What the panel renders. A plain value so the view does not depend on AskCore.
struct AskDisplay: Equatable {
    struct Line: Equatable, Identifiable { let id: String; let text: String; let sourceLine: String }
    var question: String
    var decision: String          // answered / answered-in-part / referred / declined / not-covered
    var lead: String
    var passages: [Line]
    var note: String
    var routerLine: String        // e.g. "routed by foundation-models · lead accepted"
    var engineNotice: String      // one small line when the on-device model is unavailable, else ""
    var links: [String] = []      // Directive 3: a gap card's Arabic link, Dorar for the repetition route
    var level: String? = nil      // Directive 3: card level A/B/C, or D for a personal question
}

@MainActor
@Observable
final class AskSession {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking(transcript: String)
        case answered(AskDisplay)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    let speech = AskSpeechSession()
    private let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "AskSession")

    /// One line about the engine, resolved once: which router and whether a lead is possible.
    private(set) var engineStatus = AskEngineBridge.status()

    @ObservationIgnored private var anchor = 0
    @ObservationIgnored private var watcher: Task<Void, Never>?
    /// When the capture stopped (silence, Done or a cap) - the end of speech - for the timing log.
    /// Set from the 100 ms watcher poll, so it carries up to 100 ms of slack.
    @ObservationIgnored private var speechEndedAt: ContinuousClock.Instant?
    @ObservationIgnored private var transcriptFinalAt: ContinuousClock.Instant?
    /// How long the watcher waits in `.finishing` before answering with the partial transcript.
    private static let finishingGiveUp: Duration = .seconds(30)

    func begin(anchor: Int) {
        self.anchor = anchor
        phase = .listening
        watcher?.cancel()
        speechEndedAt = nil; transcriptFinalAt = nil
        watcher = Task { [weak self] in
            guard let self else { return }
            await self.speech.start()
            // Wait for the capture to end (silence, Done, cap, or failure). Every non-terminal
            // case MUST yield: on 5 Oct the `.finishing` case had no await, the loop spun on the
            // main actor, the speech session's finish (a MainActor.run) could never run, and the
            // scene-update watchdog killed the app after 10 s (day-5 report, "Headset test").
            while !Task.isCancelled {
                switch self.speech.state {
                case .finishing:
                    if self.speechEndedAt == nil { self.speechEndedAt = .now }
                    if let ended = self.speechEndedAt, ended.duration(to: .now) > Self.finishingGiveUp {
                        // The recognizer never finalised: answer with what was heard so the panel never hangs.
                        let partial = self.speech.partialTranscript
                        self.transcriptFinalAt = .now
                        self.logger.error("Ask: speech did not finalise within \(Self.finishingGiveUp.components.seconds) s; answering with the partial transcript (\(partial.count) chars)")
                        await self.answer(partial)
                        return
                    }
                case .finished(let transcript, let reason):
                    if self.speechEndedAt == nil { self.speechEndedAt = .now }
                    self.transcriptFinalAt = .now
                    self.logger.notice("Ask: transcript (\(reason, privacy: .public)): \(transcript.count) chars")
                    #if DEBUG
                    self.logger.notice("Ask: transcript text (debug): \(transcript, privacy: .public)")
                    #endif
                    await self.answer(transcript)
                    return
                case .failed(let message):
                    // No microphone or no recognizer: fall through to the ayah's own passages.
                    self.logger.notice("Ask: speech unavailable (\(message, privacy: .public)); answering with no question")
                    await self.answer("")
                    return
                default:
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func done() { speech.stop(reason: "done button") }

    private static func ms(_ d: Duration) -> Int64 {
        let c = d.components
        return c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000
    }

    func end() {
        watcher?.cancel(); watcher = nil
        speech.reset()
        phase = .idle
    }

    private func answer(_ transcript: String) async {
        phase = .thinking(transcript: transcript)
        let display = await AskEngineBridge.ask(transcript, anchor: anchor)
        phase = .answered(display)
        #if DEBUG
        logger.notice("Ask: \(display.decision, privacy: .public) · \(display.routerLine, privacy: .public) · transcript “\(transcript, privacy: .public)”")
        #else
        logger.notice("Ask: \(display.decision, privacy: .public) · \(display.routerLine, privacy: .public)")
        #endif
        // Timing for the headset test: end of speech -> the panel shows the answer. Logs only.
        if let ended = speechEndedAt {
            let shown = ContinuousClock.Instant.now
            let total = ended.duration(to: shown)
            let transcriptPart = transcriptFinalAt.map { ended.duration(to: $0) } ?? .zero
            logger.notice("Ask timing: speech end -> answer shown \(Self.ms(total)) ms (transcript final after \(Self.ms(transcriptPart)) ms, engine \(Self.ms(total - transcriptPart)) ms)")
        }
    }
}

/// The one place that touches AskCore. With the package not linked, it answers from the local
/// Meaning file so the panel still shows the pinned ayah's passage.
enum AskEngineBridge {
    #if canImport(AskCore)
    private static let corpus: Corpus? = {
        guard let files = SourceFiles.inBundle(Bundle.main) else { return nil }
        return try? Corpus.load(files)
    }()
    /// The same router qs-ask runs: safety gate first (see AskRouters). Day 4: this was the model
    /// alone, with no gate, until 2026-10-04.
    private static let router: any QuestionRouter = AskRouters.standard()
    private static let leadWriter: (any LeadWriter)? = LeadSupport.writer()
    /// Directive 3 (3c-1): the Ask cards with their local-only Jamhara and cited-Saheeh files, from
    /// the bundle. Until 2026-10-04 evening the app passed no cards to the engine at all. A missing
    /// local file makes its cards unavailable (not-covered), never the engine.
    private static let sources: AskSourceSet? = {
        let raw = SourceFiles.inBundle(Bundle.main).flatMap { try? Corpus.loadExtracted($0.translation) }?.rawSHA256
        do { return try AskSourceSet.load(bundle: Bundle.main, expectedRawSHA256: raw) } catch {
            Logger(subsystem: "com.vrteek.quranspatial", category: "Ask").error("Ask cards not loaded: \(String(describing: error), privacy: .public)")
            return nil
        }
    }()
    private static let cardPicker: (any CardPicker)? = CardPickerSupport.picker()

    static func status() -> String {
        var parts: [String] = []
        let fm = FoundationModelsSupport.availability
        if fm != "available" { parts.append("On-device model unavailable (\(fm)): safety gate and rules only, no lead.") }
        if let sources {
            let n = sources.availableCount(corpus: corpus), total = sources.cards.count
            if n < total { parts.append("Ask cards: \(n) of \(total) available") }
        } else {
            parts.append("Ask cards not loaded")
        }
        return parts.joined(separator: " · ")
    }

    static func ask(_ question: String, anchor: Int) async -> AskDisplay {
        guard let corpus else {
            return AskDisplay(question: question, decision: "declined", lead: "", passages: [], note: "The source files are not in this build.", routerLine: "no corpus", engineNotice: status())
        }
        // An empty transcript means "tell me about this ayah": routed as unclear -> the ayah's
        // own translation and meaning, which is the baseline Meaning panel.
        let q = question.isEmpty ? "what does this ayah mean" : question
        let answer = await AskEngine(corpus: corpus, router: router, leadWriter: leadWriter, sources: sources, cardPicker: cardPicker).ask(q, anchorAyah: anchor)
        return AskDisplay(
            question: question,
            decision: answer.decision.rawValue,
            lead: answer.lead,
            passages: answer.passages.map { AskDisplay.Line(id: $0.id, text: $0.text, sourceLine: $0.sourceLine) },
            note: answer.note,
            routerLine: "routed by \(answer.router) · lead \(answer.leadStatus)" + (answer.card.map { " · card \($0)" } ?? "") + (answer.level.map { " · level \($0)" } ?? ""),
            engineNotice: status(),
            links: answer.links,
            level: answer.level)
    }
    #else
    static func status() -> String { "Ask engine not linked (add Packages/AskCore to the app target): meaning passage only." }

    static func ask(_ question: String, anchor: Int) async -> AskDisplay {
        let passage = RecitationMeaning.passage(forSegmentIndex: anchor)
        return AskDisplay(
            question: question,
            decision: passage == nil ? "declined" : "answered",
            lead: "",
            passages: passage.map { [AskDisplay.Line(id: "mukhtasar-27824:55:\(anchor)", text: $0, sourceLine: RecitationMeaning.sourceLine)] } ?? [],
            note: passage == nil ? RecitationMeaning.unavailableText : "",
            routerLine: "no router (AskCore not linked)",
            engineNotice: status())
    }
    #endif
}
