//
//  AskEngine.swift
//  AskCore
//
//  Retrieval and the answer. The anchor ayah comes first; every passage is verbatim with its
//  source line; the lead is empty for now; the decision is answered / referred / declined.
//  Ruling questions are referred to a scholar. Off-topic questions are declined. No answer is
//  ever made without a retrieved passage behind it.
//

import Foundation
import os

public enum Decision: String, Codable, Sendable {
    case answered, referred, declined
}

public struct Answer: Codable, Sendable {
    public let question: String
    public let anchorAyah: Int
    public let route: QuestionRoute
    /// Which router produced the route, e.g. "foundation-models" or "rules" or
    /// "rules (fallback: foundation-models unavailable ...)".
    public let router: String
    public let decision: Decision
    /// Reserved for a model-written lead that cites the passages below. Empty for now.
    public let lead: String
    public let passages: [Passage]
    /// Passage IDs actually retrieved, in display order. Empty means referred or declined.
    public let citations: [String]
    /// A fixed, human-written note about what was or was not found. Never model text.
    public let note: String
}

public struct Retriever: Sendable {
    public let corpus: Corpus
    public init(corpus: Corpus) { self.corpus = corpus }

    /// Anchor ayah first, always.
    public func retrieve(route: QuestionRoute, anchorAyah: Int) -> (passages: [Passage], note: String) {
        guard let record = corpus[anchorAyah] else {
            return ([], "No record for ayah \(anchorAyah) of Surah 55.")
        }
        var out: [Passage] = []
        var note = ""
        switch route {
        case .meaning, .unclear:
            if let t = record.translation { out.append(t) }
            if let m = record.meaning { out.append(m) }
            if route == .unclear { note = "The question could not be classified; the ayah's translation and meaning are shown." }
        case .word:
            if let t = record.translation { out.append(t) }
            out.append(contentsOf: record.footnotes)
            if let m = record.meaning { out.append(m) }
            if record.footnotes.isEmpty {
                note = corpus.footnotesLoaded ? "No translator's footnote on this ayah; the translation and meaning are shown."
                                              : "Translator's footnotes are not loaded in this build; the translation and meaning are shown."
            }
        case .repetition:
            if let t = record.translation { out.append(t) }
            if let m = record.meaning { out.append(m) }
            note = "The retrieved passages give this ayah's translation and meaning. No retrieved source explains why the refrain repeats; a source for that has not been selected yet."
        case .related:
            if let t = record.translation { out.append(t) }
            let refs = corpus.related?.related(to: anchorAyah) ?? []
            for r in refs { if let t = corpus[r]?.translation { out.append(t) } }
            note = refs.isEmpty
                ? "The Quranpedia similar-ayat dump records no related ayat within Surah 55 for this ayah; only the ayah itself is shown."
                : "Related ayat within Surah 55 per the Quranpedia similar-ayat dump: \(refs.map(String.init).joined(separator: ", "))."
        case .ruling:
            note = "Questions about rulings are referred to a qualified scholar; this companion shows translation and meaning only."
        case .offTopic:
            note = "Declined: the question is not about this ayah or Surah Ar-Rahman."
        }
        return (out, note)
    }
}

public struct AskEngine: Sendable {
    public let corpus: Corpus
    public let router: any QuestionRouter
    public let fallback: RuleBasedRouter
    private static let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "Ask")

    public init(corpus: Corpus, router: any QuestionRouter, fallback: RuleBasedRouter = RuleBasedRouter()) {
        self.corpus = corpus; self.router = router; self.fallback = fallback
    }

    public static func decision(for route: QuestionRoute) -> Decision {
        switch route {
        case .ruling: return .referred
        case .offTopic: return .declined
        default: return .answered
        }
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
        let retriever = Retriever(corpus: corpus)
        let (passages, note) = retriever.retrieve(route: route, anchorAyah: anchorAyah)
        var decision = Self.decision(for: route)
        if decision == .answered && passages.isEmpty { decision = .declined }
        return Answer(question: question, anchorAyah: anchorAyah, route: route, router: routerName,
                      decision: decision, lead: "", passages: decision == .answered ? passages : [],
                      citations: decision == .answered ? passages.map(\.id) : [], note: note)
    }
}
