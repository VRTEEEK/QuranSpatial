//
//  AskEngine.swift
//  AskCore
//
//  Retrieval and the answer. The anchor ayah comes first; every passage is verbatim with its
//  source line; the lead is optional, model-written, and VERIFIED before it is shown; the
//  decision is answered / answered-in-part / referred / declined. Ruling questions are referred
//  to a scholar. Off-topic questions are declined. No answer is ever made without a retrieved
//  passage behind it, and nothing is ever generated about the Quran, a translation or a tafsir.
//
//  Day 2 decisions (Mo, 2026-10-04): the repetition route answers in part with what the sources
//  do say and states plainly that they do not explain the repetition; the related route answers
//  only where the similar-ayat dump has data (ayat 11, 52, 68) and says so elsewhere.
//

import Foundation
import os

public enum Decision: String, Codable, Sendable {
    case answered
    case answeredInPart = "answered-in-part"
    case referred
    case declined
}

public struct Answer: Codable, Sendable {
    public let question: String
    public let anchorAyah: Int
    public let route: QuestionRoute
    /// Which router produced the route, e.g. "foundation-models" or "rules" or
    /// "rules (fallback: foundation-models failed ...)".
    public let router: String
    public let decision: Decision
    /// A one- or two-sentence plain-English lead introducing the passages, model-written and
    /// verified. Empty when there is no lead writer, when the lead was rejected, or when the
    /// decision is referred or declined.
    public let lead: String
    /// What happened to the lead: "accepted", "rejected: <reason>", "error: <reason>", or
    /// "none: <reason>". Logged as well.
    public let leadStatus: String
    public let passages: [Passage]
    /// Passage IDs actually retrieved, in display order. Empty means referred or declined.
    public let citations: [String]
    /// A fixed, human-written note about what was or was not found. Never model text.
    public let note: String
}

public struct Retrieval: Sendable {
    public let passages: [Passage]
    public let note: String
    public let decision: Decision
}

public struct Retriever: Sendable {
    public let corpus: Corpus
    public init(corpus: Corpus) { self.corpus = corpus }

    public static let repetitionNote = "The sources in this app do not explain why this verse is repeated."
    public static let relatedUnavailableNote = "Related-ayah data is not available for this ayah."

    /// Anchor ayah first, always.
    public func retrieve(route: QuestionRoute, anchorAyah: Int) -> Retrieval {
        guard let record = corpus[anchorAyah] else {
            return Retrieval(passages: [], note: "No record for ayah \(anchorAyah) of Surah 55.", decision: .declined)
        }
        var out: [Passage] = []
        switch route {
        case .meaning:
            if let t = record.translation { out.append(t) }
            if let m = record.meaning { out.append(m) }
            return Retrieval(passages: out, note: "", decision: .answered)
        case .unclear:
            if let t = record.translation { out.append(t) }
            if let m = record.meaning { out.append(m) }
            return Retrieval(passages: out, note: "The question could not be classified; the ayah's translation and meaning are shown.", decision: .answered)
        case .word:
            if let t = record.translation { out.append(t) }
            out.append(contentsOf: record.footnotes)
            if let m = record.meaning { out.append(m) }
            let note = record.footnotes.isEmpty
                ? (corpus.footnotesLoaded ? "No translator's footnote on this ayah; the translation and meaning are shown."
                                          : "Translator's footnotes are not loaded in this build; the translation and meaning are shown.")
                : ""
            return Retrieval(passages: out, note: note, decision: .answered)
        case .repetition:
            // What the sources DO say: the ayah's translation, the refrain's Mukhtasar passage,
            // and the Saheeh footnote on "you two". Then the plain statement. Never an explanation.
            if let t = record.translation { out.append(t) }
            if let m = record.meaning { out.append(m) }
            if let f = corpus.refrainFootnote { out.append(f) }
            return Retrieval(passages: out, note: Self.repetitionNote, decision: .answeredInPart)
        case .related:
            if let t = record.translation { out.append(t) }
            let refs = corpus.related?.related(to: anchorAyah) ?? []
            if refs.isEmpty {
                if let m = record.meaning { out.append(m) }
                return Retrieval(passages: out, note: Self.relatedUnavailableNote, decision: .answeredInPart)
            }
            for r in refs { if let t = corpus[r]?.translation { out.append(t) } }
            return Retrieval(passages: out, note: "Related ayat within Surah 55 per the Quranpedia similar-ayat dump: \(refs.map(String.init).joined(separator: ", ")).", decision: .answered)
        case .ruling:
            return Retrieval(passages: [], note: "Questions about rulings are referred to a qualified scholar; this companion shows translation and meaning only.", decision: .referred)
        case .offTopic:
            return Retrieval(passages: [], note: "Declined: the question is not about this ayah or Surah Ar-Rahman.", decision: .declined)
        }
    }
}

public struct AskEngine: Sendable {
    public let corpus: Corpus
    public let router: any QuestionRouter
    public let leadWriter: (any LeadWriter)?
    public let fallback: RuleBasedRouter
    private static let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "Ask")

    public init(corpus: Corpus, router: any QuestionRouter, leadWriter: (any LeadWriter)? = nil, fallback: RuleBasedRouter = RuleBasedRouter()) {
        self.corpus = corpus; self.router = router; self.leadWriter = leadWriter; self.fallback = fallback
    }

    /// The decision a route leads to for a given anchor (related depends on the data).
    public static func decision(for route: QuestionRoute, anchorAyah: Int, corpus: Corpus) -> Decision {
        Retriever(corpus: corpus).retrieve(route: route, anchorAyah: anchorAyah).decision
    }

    public func ask(_ question: String, anchorAyah: Int) async -> Answer {
        var route: QuestionRoute
        var routerName = router.name
        do {
            route = try await router.route(question, anchorAyah: anchorAyah)
        } catch {
            route = (try? await fallback.route(question, anchorAyah: anchorAyah)) ?? .unclear
            routerName = "\(fallback.name) (fallback: \(router.name) failed: \(error))"
        }
        Self.logger.notice("Ask routed by \(routerName, privacy: .public): \(route.rawValue, privacy: .public) for ayah \(anchorAyah)")
        let r = Retriever(corpus: corpus).retrieve(route: route, anchorAyah: anchorAyah)
        var decision = r.decision
        if (decision == .answered || decision == .answeredInPart) && r.passages.isEmpty { decision = .declined }
        let showsPassages = decision == .answered || decision == .answeredInPart

        var lead = ""
        var leadStatus = "none: no lead writer"
        if showsPassages, let writer = leadWriter {
            do {
                let candidate = try await writer.lead(question: question, passages: r.passages, anchorAyah: anchorAyah)
                switch LeadVerifier.verify(lead: candidate, passages: r.passages, question: question, anchorAyah: anchorAyah) {
                case .accepted: lead = candidate; leadStatus = "accepted"
                case .rejected(let reason): leadStatus = "rejected: \(reason)"
                }
            } catch {
                leadStatus = "error: \(error)"
            }
            Self.logger.notice("Lead by \(writer.name, privacy: .public): \(leadStatus, privacy: .public)")
        } else if !showsPassages {
            leadStatus = "none: \(decision.rawValue)"
        }

        return Answer(question: question, anchorAyah: anchorAyah, route: route, router: routerName,
                      decision: decision, lead: lead, leadStatus: leadStatus,
                      passages: showsPassages ? r.passages : [],
                      citations: showsPassages ? r.passages.map(\.id) : [], note: r.note)
    }
}
