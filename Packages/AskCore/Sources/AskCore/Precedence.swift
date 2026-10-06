//
//  Precedence.swift
//  AskCore
//
//  Directive 3, stage 3b, step 8: the deterministic rule between the ayah routes and the cards,
//  applied by the engine AFTER routing. `anchorCue` = the question points at the ayah on screen.
//  K = the available cards matched by whole-word keyword.
//

import Foundation

public enum Precedence {
    /// A question about the surah on screen is about the text, not general (d60: "the sura ends by…").
    static let anchorCues = [#"\b(this|that) (ayah|aya|verse|line|eye)\b"#, #"\bhere\b"#, #"\bin this\b"#, #"\bthis one\b"#,
                             #"\b(the|this) (sura|surah|chapter)\b"#, #"\bsurah? (ar-?)?rahman\b"#]

    /// Directive 4, part D (5 Oct 2026): a question about Islam in general that names a general topic and
    /// points at nothing on screen is GENERAL, even when no card keyword matched - without this, the rules
    /// (after a model refusal) returned unclear/meaning and the ayah's own passages were shown for "what does
    /// jihad actually mean" (general-dev: 6 of the 8 uncovered items were answered from the ayah; severe).
    /// Tuned on general-dev; checked against dev.json offline (no ayah item of dev is caught).
    static let generalTopics = #"\b(islam|islamic|muslims?|jihad|hajj|umrah|pilgrimage|sunnah|angels?|ramadan|fasting|zakat|charity|prophets?|shahada|pillars?|mosque|imam|sharia|halal|haram|arabic|quran|koran)\b"#
    /// Words that point at the text on screen; with one of these the ayah route stands.
    static let screenReference = #"\b(this|it|here|these|those|the line|the text|the passage|the verse|the ayah|the aya|the eye)\b"#   // not "that": "what's that called"
    public static func isGeneralTopic(_ question: String) -> Bool {
        let q = question.lowercased()
        return q.range(of: generalTopics, options: .regularExpression) != nil && !hasAnchorCue(q) && q.range(of: screenReference, options: .regularExpression) == nil
    }

    /// Directive 4, part D (Mo, 5 Oct): BEFORE any redirect to general, keep the ayah route when the question
    /// shares a content word (4+ letters, LeadVerifier.stem) with the anchor ayah's translation or meaning.
    /// Function words and this generic list are ignored.
    static let genericWords: Set<String> = ["what", "does", "mean", "means", "meaning", "about", "this", "that", "with", "from", "have", "there", "their", "they", "will", "would", "could", "should", "when", "where", "which", "really", "actually", "like", "just", "know", "tell", "said", "says", "saying", "quran", "koran", "allah", "lord", "god", "your", "favors", "favours", "deny", "kind", "thing", "stuff", "give", "people", "life", "world", "good", "time", "make", "come", "take", "want", "need", "live", "verse", "ayah", "surah"]
    public static func sharesContentWord(_ question: String, anchorTexts: [String]) -> Bool {
        let q = Set(LeadVerifier.contentWords(TranscriptCleanup.forMatching(question)).filter { !genericWords.contains($0) }.map(LeadVerifier.stem))
        guard !q.isEmpty else { return false }
        let a = Set(anchorTexts.flatMap { LeadVerifier.contentWords($0) }.filter { !genericWords.contains($0) }.map(LeadVerifier.stem))
        return !q.isDisjoint(with: a)
    }

    public static func hasAnchorCue(_ question: String) -> Bool {
        let q = question.lowercased()
        return anchorCues.contains { q.range(of: $0, options: .regularExpression) != nil }
    }

    /// The matched keywords of a card that occur, whole-word, in the anchor ayah's own texts.
    static func keywordsInAnchor(_ card: AskCard, question: String, anchorTexts: [String]) -> Bool {
        let joined = anchorTexts.joined(separator: "\n")
        return card.keywords.contains { k in AskCards.matchesKeyword(k, in: question) && AskCards.matchesKeyword(k, in: joined) }
    }

    public enum Outcome: Equatable, Sendable {
        /// Keep the route as routed.
        case keep
        /// The question points at the ayah: a general route becomes meaning.
        case toMeaning
        /// An ayah route with card keywords that do not occur in the anchor ayah becomes general.
        case toGeneral
        /// Word route about a term the ayah itself contains: keep word, append this term card's Jamhara passages.
        case wordPlusTerm(cardID: String)
        /// Off-topic may become general only through a card chosen by exact, definitional or confirmed model selection.
        case offTopicNeedsConfirmedCard
    }

    /// `anchorTexts`: the anchor ayah's translation and meaning texts.
    public static func apply(route: QuestionRoute, question: String, matched K: [AskCard], anchorTexts: [String]) -> Outcome {
        let cue = hasAnchorCue(question)
        switch route {
        case .general:
            return cue ? .toMeaning : .keep
        case .offTopic:
            return .offTopicNeedsConfirmedCard
        case .word, .meaning, .unclear:
            if route == .word, let term = K.first(where: { $0.kind == .term }), cue || keywordsInAnchor(term, question: question, anchorTexts: anchorTexts) {
                return .wordPlusTerm(cardID: term.id)
            }
            // The guard: a question that shares a content word with the ayah on screen is about that ayah.
            if sharesContentWord(question, anchorTexts: anchorTexts) { return .keep }
            if route != .word, K.isEmpty, isGeneralTopic(question) { return .toGeneral }
            guard !K.isEmpty else { return .keep }
            let anyInAnchor = K.contains { keywordsInAnchor($0, question: question, anchorTexts: anchorTexts) }
            if !cue && !anyInAnchor { return .toGeneral }
            return .keep
        case .related:
            // A general-topic question with no card keyword that the model called "related" (general-dev g28,
            // "how many prophets are there in islam"): general, not a related-ayat answer - unless it shares a
            // content word with the ayah on screen.
            if sharesContentWord(question, anchorTexts: anchorTexts) { return .keep }
            return (K.isEmpty && isGeneralTopic(question)) ? .toGeneral : .keep
        case .repetition, .ruling:
            return .keep
        }
    }
}
