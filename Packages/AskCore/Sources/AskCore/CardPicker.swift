//
//  CardPicker.swift
//  AskCore
//
//  Directive 3, stage 3b. The model's part in choosing a card: it picks ONE id from the AVAILABLE
//  card ids plus "none" (plain String output validated against that set - the anyOf schema was
//  refused, see below), greedy sampling, and the pick counts only if the question CONFIRMS it - shares a keyword, or a content word of four or
//  more letters (LeadVerifier.stem), with the card's title or phrasings, generic words ignored.
//  An unconfirmed pick is "none". The model never writes text here, and never sees a passage.
//

import Foundation

public protocol CardPicker: Sendable {
    var name: String { get }
    /// The chosen card id, or "none". Throws when the model refuses, errors or is absent.
    func pick(question: String, from cards: [AskCard]) async throws -> String
}

public enum CardConfirmation {
    /// Words too common to confirm anything.
    public static let genericWords: Set<String> = ["muslim", "muslims", "islam", "islamic", "does", "what", "mean", "means", "meaning", "about", "believe", "people"]

    static func contentStems(_ text: String) -> Set<String> {
        Set(LeadVerifier.contentWords(TranscriptCleanup.forMatching(text)).filter { !genericWords.contains($0) }.map(LeadVerifier.stem))
    }

    /// The strong form: the question contains one of the card's keywords (whole word). This is the
    /// ONLY confirmation that may overturn an off-topic route (d47: a football question shared the
    /// word "last" with the Last Day card's title, which is too thin to overturn a correct decision).
    public static func confirmsByKeyword(_ card: AskCard, question: String) -> Bool {
        card.keywords.contains { AskCards.matchesKeyword($0, in: question) }
    }

    /// The STRONG form (F2, after heldout-2 k60 "which direction is the nearest exit in this building",
    /// which the one-word keyword "direction" had let through): a multi-word keyword of the card matched,
    /// or two or more distinct keywords of the card. The only confirmation that may overturn off-topic.
    public static func confirmsStrongly(_ card: AskCard, question: String) -> Bool {
        let matched = card.keywords.filter { AskCards.matchesKeyword($0, in: question) }
        return matched.contains { $0.contains(" ") } || Set(matched).count >= 2
    }

    /// True when the question shares a keyword, or a content word (4+ letters, stemmed, not generic),
    /// with the card's title or phrasings. Used on the general route.
    public static func confirms(_ card: AskCard, question: String) -> Bool {
        if confirmsByKeyword(card, question: question) { return true }
        let q = contentStems(question)
        guard !q.isEmpty else { return false }
        let cardStems = contentStems(([card.title] + card.phrasings).joined(separator: " "))
        return !q.isDisjoint(with: cardStems)
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
public struct FoundationModelsCardPicker: CardPicker {
    public let name = "foundation-models"
    public init() {}

    /// The id set the answer must come from; anything else is "none".
    static func validate(_ output: String, ids: [String]) -> String {
        // "term-3529-tawhid: What Tawhid means" -> "term-3529-tawhid". Only an exact id counts.
        let token = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: ":\n \t\"'`,.")).first ?? ""
        return ids.contains(token) ? token : "none"
    }

    public func pick(question: String, from cards: [AskCard]) async throws -> String {
        guard FoundationModelsRouter.isAvailable else { throw FoundationModelsRouter.Unavailable.model(FoundationModelsRouter.availabilityDescription) }
        let ids = cards.map(\.id) + ["none"]
        // MEASURED 2026-10-04: a DynamicGenerationSchema(anyOf: ids) over the same list was REFUSED
        // ("May contain sensitive content") on every question tried, under the default AND the
        // permissive guardrails; the plain String response to the same prompt was not. So, as the
        // directive allows, the pick is plain String output under the permissive content-
        // transformation guardrails, VALIDATED against the exact id set (anything else is "none").
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: """
            You match a question to the one list entry (id: title) whose title answers it, or none. \
            Output only the id, nothing else. Never answer the question.
            """)
        var prompt = "Entries:\n"
        for c in cards { prompt += "\(c.id): \(c.title)\n" }
        prompt += "none: nothing fits\n\nQuestion: \(question)"
        let response = try await session.respond(to: prompt, options: GenerationOptions(samplingMode: .greedy))
        return Self.validate(response.content, ids: ids)
    }
}
#endif

public enum CardPickerSupport {
    public static func picker() -> (any CardPicker)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *), FoundationModelsRouter.isAvailable { return FoundationModelsCardPicker() }
        #endif
        return nil
    }
}
