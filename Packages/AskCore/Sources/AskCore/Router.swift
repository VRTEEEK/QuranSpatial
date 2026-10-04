//
//  Router.swift
//  AskCore
//
//  Classifies a question about the anchor ayah into one route. Two implementations behind one
//  protocol: Foundation Models (on-device, a @Generable enum, where available) and a rule-based
//  fallback. The router only ever produces a route - never text.
//

import Foundation

public enum QuestionRoute: String, Codable, Sendable, CaseIterable {
    case meaning
    case word
    case repetition
    case related
    case ruling
    case offTopic = "off-topic"
    case unclear
}

public protocol QuestionRouter: Sendable {
    var name: String { get }
    func route(_ question: String, anchorAyah: Int) async throws -> QuestionRoute
}

/// A route with the component that decided it, for the evaluation's attribution counts.
public struct AttributedRoute: Sendable, Equatable {
    public let route: QuestionRoute
    /// One of: "safety-gate", "fragment", "rules-high-confidence", "foundation-models",
    /// "rules-after-model-refusal", "rules-after-model-error", "rules-no-model", or a plain
    /// router's own name.
    public let decidedBy: String
    public init(route: QuestionRoute, decidedBy: String) { self.route = route; self.decidedBy = decidedBy }
}

/// Routers made of several components report which one decided.
public protocol AttributingRouter: QuestionRouter {
    func routeAttributed(_ question: String, anchorAyah: Int) async throws -> AttributedRoute
}

/// Rule-based classifier: ordered keyword rules. Deterministic, dependency-free, and the
/// fallback when the on-device model is not available.
public struct RuleBasedRouter: QuestionRouter {
    public let name = "rules"
    public init() {}

    private static func matches(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    static let ruling = [#"\bharam\b"#, #"\bhalal\b"#, #"\bpermissib"#, #"\bpermitted\b"#, #"\ballowed\b"#, #"\bforbidden\b"#, #"\bruling\b"#, #"\bfatwa\b"#, #"\bsinful\b"#, #"\ba sin\b"#, #"\bobligatory\b"#, #"\bmakruh\b"#, #"\bis it (ok|okay|fine|wrong) to\b"#, #"\b(can|may|should) (i|we|one|a muslim|someone)\b"#, #"\bdo i have to\b"#, #"\bam i allowed\b"#, #"\bbreak (my|the) (fast|wudu)\b"#, #"\bzakat\b"#, #"\bprayer (valid|invalid)\b"#]
    static let repetition = [#"\brepeat"#, #"\brepetition"#, #"\bagain and again\b"#, #"\bover and over\b"#, #"\b31 times\b"#, #"\bthirty.one\b"#, #"\brefrain\b"#, #"\bhow many times\b"#, #"\bso many times\b"#, #"\bkeeps? (coming|appearing|saying|asking)\b"#, #"\bsame (verse|ayah|line|question) (again|so often|many times)\b"#, #"\b(verse|ayah|line) (again|recur)"#, #"\brecur"#]
    static let word = [#"\bthe word\b"#, #"\bthis word\b"#, #"\barabic word\b"#, #"\bword for\b"#, #"\bmeaning of the word\b"#, #"\bwhat does ["'“‘][^"'”’]+["'”’] mean\b"#, #"\bwhat is ["'“‘][^"'”’]+["'”’]\b"#, #"\btranslat(e|ion of) (the )?word\b"#, #"\bwhat does (deny|favors?|favours?|balance|jinn|lord|merciful|mercy|bounties|gardens?|pearls?|coral|ships?|spirit|sun|moon|stars?|trees?|scale|clay|pottery|fire|smoke|sinners?|flames?|brass|signs?|dual|two) mean\b"#, #"\bmean(s|ing)? by ["'“‘]"#, #"\bwhy ["'“‘]"#, #"\bthe term\b"#, #"\bvocabulary\b"#, #"\bliterally\b"#, #"\bwhy (does it|is it) (say|written|translated)\b"#, #"\btranslated as\b"#]
    static let related = [#"\brelated\b"#, #"\bsimilar\b"#, #"\belsewhere\b"#, #"\bwhere else\b"#, #"\bother (verses?|ayahs?|ayat|surahs?|places?|parts?)\b"#, #"\bconnect(ed|ion)?\b"#, #"\blink(ed|s)?\b"#, #"\balso (mention|appear|talk|describ)"#, #"\bcompare\b"#, #"\bcross.?reference"#, #"\bparallel\b"#, #"\bmentioned (again|before|earlier|later)\b"#]
    static let meaning = [#"\bmean"#, #"\bexplain"#, #"\btafsir\b"#, #"\binterpret"#, #"\bunderstand"#, #"\bwhat is (this|the) (verse|ayah|surah|passage|line) (about|saying|teaching)\b"#, #"\bwhat (is|was) (meant|intended|being said)\b"#, #"\bwho\b"#, #"\bwhom\b"#, #"\bwhat\b"#, #"\bwhich\b"#, #"\bwhy\b"#, #"\bhow\b"#, #"\bwhen\b"#, #"\bwhere\b"#, #"\bmessage\b"#, #"\blesson"#, #"\brefer(s|ring)? to\b"#, #"\bcontext\b"#, #"\bpoint of\b"#, #"\bsignifican"#, #"\bteach"#, #"\bdescrib"#, #"\btell me about\b"#, #"\bwhich (favors?|favours?|blessings?|gardens?)\b"#]
    /// Something that ties the question to the Quran, the surah or the ayah on screen.
    static let onTopicCue = [#"\b(ayah|ayat|verse|verses|surah|quran|qur'an|qur’an|koran|allah|god|lord|rahman|merciful|mercy|jinn|favou?rs?|blessings?|bount"#, #"\b(this|it|here|the line|the text|the passage|these|that line)\b"#, #"\b(deny|balance|garden|paradise|hell|creation|sun|moon|pearl|coral|ship|heaven|earth|recit|tafsir|translation|meaning)"#, #"\b(prophet|muhammad|islam|muslim|revelation|makkah|mecca|medina|madinah)\b"#]
    /// Cues of subjects that are not this ayah or the surah at all.
    static let offTopicCue = [#"\bweather\b"#, #"\bfootball\b"#, #"\bsoccer\b"#, #"\bstock"#, #"\bbitcoin\b"#, #"\brecipe\b"#, #"\bpython\b"#, #"\bjavascript\b"#, #"\bcode\b"#, #"\biphone\b"#, #"\bvision pro\b"#, #"\bmovie\b"#, #"\bsong\b"#, #"\bcapital of\b"#, #"\bpresident\b"#, #"\belection\b"#, #"\bjoke\b"#, #"\bpoem\b"#, #"\bessay\b"#, #"\bhomework\b"#, #"\bmath\b"#, #"\btranslate .* (into|to) (french|spanish|german|urdu|turkish)\b"#, #"\bflight\b"#, #"\bhotel\b"#, #"\brestaurant\b"#, #"\bdinner\b"#, #"\bcoffee\b"#, #"\btime is it\b"#, #"\bwhat day\b"#, #"\bbirthday\b"#, #"\bgame\b"#, #"\bcar\b"#, #"\bbus\b"#, #"\btrain\b"#]

    public func route(_ question: String, anchorAyah: Int) async throws -> QuestionRoute {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 3 else { return .unclear }
        let onTopic = Self.matches(q, Self.onTopicCue)
        let offCue = Self.matches(q, Self.offTopicCue)
        if offCue && !Self.matches(q, Self.ruling) && !Self.matches(q, Self.repetition) && !Self.matches(q, [#"\b(ayah|verse|surah|quran|qur'an|qur’an|allah|lord|jinn|favou?rs?)\b"#]) {
            return .offTopic
        }
        if Self.matches(q, Self.ruling) { return .ruling }
        if Self.matches(q, Self.repetition) { return .repetition }
        if Self.matches(q, Self.word) { return .word }
        if Self.matches(q, Self.related) { return .related }
        if Self.matches(q, Self.meaning) { return onTopic ? .meaning : .unclear }
        if !onTopic { return .offTopic }
        return .unclear
    }
}
