//
//  SafetyGate.swift
//  AskCore
//
//  Day 3 (2026-10-04): a safety layer that runs BEFORE any router and refers anything that
//  looks like a request for a ruling - halal/haram, "am I allowed", "is it permissible", a
//  personal situation asking what to do. Biased to refer, the way the dua gate is biased to
//  reject: a referred meaning question costs a reader one tap; an answered ruling question is
//  the app pretending to be a scholar. Deterministic, and tuned on dev.json only.
//

import Foundation

public struct RulingSafetyGate: Sendable {
    public init() {}

    static let patterns: [String] = [
        // explicit ruling vocabulary
        #"\bhalal\b"#, #"\bharam\b"#, #"\bhar+am\b"#, #"\bpermissib"#, #"\bpermitted\b"#, #"\ballow(ed|able)\b"#, #"\bforbidden\b"#,
        #"\bprohibit"#, #"\bobligat"#, #"\bwajib\b"#, #"\bfard\b"#, #"\bsunnah to\b"#, #"\bmakruh\b"#, #"\bmustahab"#,
        #"\bruling\b"#, #"\bfatwa\b"#, #"\b(a )?sin\b"#, #"\bsinful\b"#, #"\bsins\b"#, #"\bpunish"#, #"\bkaffara"#, #"\bexpiat"#,
        #"\bvalid\b"#, #"\binvalid"#, #"\bcount(s)? as\b"#, #"\bbreak(s|ing)? (my|the|your) (fast|wudu|wudhu|prayer|salah)\b"#,
        #"\bwudu\b"#, #"\bwudhu\b"#, #"\bablution"#, #"\bzakat\b"#, #"\bsadaqa"#, #"\bfasting\b"#, #"\bmy fast\b"#, #"\bramadan\b"#,
        #"\bsalah\b"#, #"\bsalat\b"#, #"\bprayers?\b"#, #"\bprostrat"#, #"\bsajda"#, #"\bsujood"#, #"\bqibla"#,
        #"\bhijab\b"#, #"\bmahram\b"#, #"\bnikah"#, #"\bdivorce"#, #"\btalaq"#, #"\binterest\b"#, #"\briba\b"#, #"\bloan\b"#, #"\bmortgage"#,
        // asking for permission or obligation
        #"\b(am|are) (i|we) (allowed|permitted|supposed|required|obliged|obligated)\b"#, #"\bis (it|this|that) (ok|okay|fine|alright|all right|wrong|bad|allowed|permissible|a problem|acceptable)\b"#,
        #"\b(can|could|may|should|must) (i|we|one|a (muslim|woman|man|person|believer)|someone|you) "#, #"\bdo (i|we) (have to|need to)\b"#,
        #"\b(is|are) (i|we|they|he|she) (allowed|permitted|supposed)\b"#, #"\bwhat (should|must|do) (i|we) do\b"#, #"\bwhat (am|are) (i|we) supposed to\b"#,
        #"\bis (it|there) (any )?(sin|harm|problem) (in|if|to)\b"#, #"\bwould (it|that) be (ok|okay|wrong|a sin|haram)\b"#,
        // a personal situation brought for judgement
        #"\bmy (boss|wife|husband|mother|father|mom|dad|son|daughter|brother|sister|friend|neighbou?r|employer|employee|customer|client|landlord|teacher|imam)\b"#,
        #"\b(at|in) (my|the) (shop|store|work|office|business|job|school)\b"#, #"\bi (missed|forgot|skipped|broke|owe|borrowed|lent|sold|bought|cheated|lied)\b"#,
        #"\bshort(ed|ing|change)? (someone|a customer|the customer|people)\b"#, #"\bcheat"#, #"\bsteal"#, #"\bgambl"#, #"\balcohol\b"#, #"\bdrink(ing)? (beer|wine)\b"#, #"\bpork\b"#,
    ]

    /// True when the question should be referred to a scholar without consulting any router.
    public func looksLikeRuling(_ question: String) -> Bool {
        let q = question.lowercased()
        return Self.patterns.contains { q.range(of: $0, options: .regularExpression) != nil }
    }
}

/// Any router, with the safety gate in front of it.
public struct SafetyGatedRouter: QuestionRouter {
    public let inner: any QuestionRouter
    public let gate = RulingSafetyGate()
    public var name: String { "safety+\(inner.name)" }
    public init(_ inner: any QuestionRouter) { self.inner = inner }

    public func route(_ question: String, anchorAyah: Int) async throws -> QuestionRoute {
        if gate.looksLikeRuling(question) { return .ruling }
        return try await inner.route(question, anchorAyah: anchorAyah)
    }
}

/// Day 3 hybrid: the safety gate first; then rules only where they are HIGH-CONFIDENCE
/// (unambiguous cue words); then the on-device model for everything else; rules if the model
/// refuses, errors or is absent.
public struct HybridRouter: QuestionRouter {
    public let model: (any QuestionRouter)?
    public let rules = RuleBasedRouter()
    public let gate = RulingSafetyGate()
    public var name: String { "hybrid(\(model?.name ?? "no-model"))" }

    public init(model: (any QuestionRouter)?) { self.model = model }

    /// The cues the rules may decide on alone. Everything else goes to the model.
    static let highConfidence: [(QuestionRoute, [String])] = [
        (.repetition, [#"\brepeat"#, #"\brepetition"#, #"\bagain and again\b"#, #"\bover and over\b"#, #"\brefrain\b"#, #"\bhow many times\b"#, #"\bso many times\b"#, #"\b(same|this|that) (verse|ayah|aya|eye|line|question) (again|keeps|over)\b"#, #"\bkeeps? (coming|popping|showing) (up|back)\b"#, #"\b(twentieth|thirtieth|tenth|fifth|umpteenth) time\b"#, #"\b(already|just) (read|saw|seen|had) (this|that|it)\b"#, #"\bexact same (verse|ayah|aya|line|wording)\b"#]),
        (.related, [#"\bwhere else\b"#, #"\bother (verses?|ayahs?|ayas?|ayat|eyes?|places?|parts?) (in|of|that|which|with)\b"#, #"\bsimilar (to|verse|ayah|aya|one)\b"#, #"\brelated (to|verse|ayah)\b"#, #"\bcompare(d|s)? (to|with)\b"#, #"\bsounds (a lot )?like (the|an|another)\b"#, #"\bearlier (one|verse|ayah|aya)\b"#, #"\bcross.?reference"#, #"\bconnect(ed|ion) (to|with|between)\b"#]),
        (.word, [#"\bthe word\b"#, #"\bthis word\b"#, #"\bthat word\b"#, #"\barabic (word|term)\b"#, #"\bword for\b"#, #"\bthe term\b"#, #"\btranslat(ed|ion) (as|for|of|here)\b"#, #"\bright translation\b"#, #"\bliterally mean"#, #"\bwhat does ["'“‘][^"'”’]+["'”’] mean"#, #"\bnever heard (that|this|the) word\b"#, #"\bwhat('s| is) (a|an) [a-z]+\b"#]),
        (.offTopic, [#"\b(weather|forecast|football|soccer|arsenal|liverpool|match|score|bitcoin|stock|crypto|recipe|python|javascript|swift code|for loop|iphone|vision pro|headset|battery|brightness|text (bigger|smaller|larger)|font size|volume|wifi|bluetooth|movie|netflix|song|playlist|capital of|president|election|joke|poem|homework|flight|hotel|restaurant|dinner|lunch|coffee|time is it|what day|birthday|game|car|bus|train|traffic)\b"#]),
    ]

    public static func highConfidenceRoute(_ question: String) -> QuestionRoute? {
        let q = question.lowercased()
        let onTopic = q.range(of: #"\b(ayah|ayat|aya|eye|verse|surah|sura|quran|koran|allah|god|lord|jinn|gin|favou?rs?|blessings?|bount)"#, options: .regularExpression) != nil
        for (route, patterns) in highConfidence where patterns.contains(where: { q.range(of: $0, options: .regularExpression) != nil }) {
            // An off-topic cue inside an on-topic question is not high confidence.
            if route == .offTopic && onTopic { continue }
            return route
        }
        return nil
    }

    public func route(_ question: String, anchorAyah: Int) async throws -> QuestionRoute {
        if gate.looksLikeRuling(question) { return .ruling }
        if let sure = Self.highConfidenceRoute(question) { return sure }
        if let model {
            if let r = try? await model.route(question, anchorAyah: anchorAyah) { return r }
        }
        return try await rules.route(question, anchorAyah: anchorAyah)
    }
}
