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
    var decision: String          // answered / answered-in-part / referred / declined
    var lead: String
    var passages: [Line]
    var note: String
    var routerLine: String        // e.g. "routed by foundation-models · lead accepted"
    var engineNotice: String      // one small line when the on-device model is unavailable, else ""
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

    func begin(anchor: Int) {
        self.anchor = anchor
        phase = .listening
        watcher?.cancel()
        watcher = Task { [weak self] in
            guard let self else { return }
            await self.speech.start()
            // Wait for the capture to end (silence, Done, cap, or failure).
            while !Task.isCancelled {
                switch self.speech.state {
                case .finished(let transcript, let reason):
                    self.logger.notice("Ask: transcript (\(reason, privacy: .public)): \(transcript.count) chars")
                    await self.answer(transcript)
                    return
                case .failed(let message):
                    // No microphone or no recognizer: fall through to the ayah's own passages.
                    self.logger.notice("Ask: speech unavailable (\(message, privacy: .public)); answering with no question")
                    await self.answer("")
                    return
                default:
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }

    func done() { speech.stop(reason: "done button") }

    func end() {
        watcher?.cancel(); watcher = nil
        speech.reset()
        phase = .idle
    }

    private func answer(_ transcript: String) async {
        phase = .thinking(transcript: transcript)
        let display = await AskEngineBridge.ask(transcript, anchor: anchor)
        phase = .answered(display)
        logger.notice("Ask: \(display.decision, privacy: .public) · \(display.routerLine, privacy: .public)")
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
    private static let router: any QuestionRouter = FoundationModelsSupport.router() ?? RuleBasedRouter()
    private static let leadWriter: (any LeadWriter)? = LeadSupport.writer()

    static func status() -> String {
        let fm = FoundationModelsSupport.availability
        if fm == "available" { return "" }
        return "On-device model unavailable (\(fm)): rules router, no lead."
    }

    static func ask(_ question: String, anchor: Int) async -> AskDisplay {
        guard let corpus else {
            return AskDisplay(question: question, decision: "declined", lead: "", passages: [], note: "The source files are not in this build.", routerLine: "no corpus", engineNotice: status())
        }
        // An empty transcript means "tell me about this ayah": routed as unclear -> the ayah's
        // own translation and meaning, which is the baseline Meaning panel.
        let q = question.isEmpty ? "what does this ayah mean" : question
        let answer = await AskEngine(corpus: corpus, router: router, leadWriter: leadWriter).ask(q, anchorAyah: anchor)
        return AskDisplay(
            question: question,
            decision: answer.decision.rawValue,
            lead: answer.lead,
            passages: answer.passages.map { AskDisplay.Line(id: $0.id, text: $0.text, sourceLine: $0.sourceLine) },
            note: answer.note,
            routerLine: "routed by \(answer.router) · lead \(answer.leadStatus)",
            engineNotice: status())
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
