//
//  SafetyGate.swift
//  AskCore
//
//  Day 3 (2026-10-04): a safety layer that runs BEFORE any router and refers anything that
//  looks like a request for a ruling. Biased to refer, the way the dua gate is biased to reject.
//
//  Directive 3, stage 3a (2026-10-04): the single yes/no became FIVE categories, checked in
//  order - hadithRequest, personal, qualifiedRuling, plainRuling, none - because the engine does
//  different things with them (see AskEngine): hadith requests and qualified rulings are referred
//  bare; a personal situation is referred with a keyword-matched card as general information
//  (level D); a plain ruling may be answered from a card that is marked answersRuling (today only
//  the alcohol card). Removed as triggers: punish, prayer(s), fasting, ramadan, salah, salat,
//  qibla - "Why do Muslims fast in Ramadan?" is not a ruling request. Kept: "break my fast",
//  "my fast", "prayer valid/invalid", wudu. Definitional questions ("What is a fatwa?") never
//  reach the gate; the engine handles that exemption first. Deterministic, tuned on dev.json only.
//

import Foundation
import os

public enum GateCategory: String, Sendable, Codable, CaseIterable {
    case hadithRequest = "hadith-request"
    case personal
    case qualifiedRuling = "qualified-ruling"
    case plainRuling = "plain-ruling"
    case none
}

public struct RulingSafetyGate: Sendable {
    public init() {}

    // MARK: pattern lists (all compiled by PatternCompileTests)

    /// A request to quote or grade hadith.
    static let hadith: [String] = [
        #"\bhadith\b"#, #"\bhadiths\b"#, #"\bahadith\b"#, #"\bnarrat(ed|ion|ions|or|ors)\b"#, #"\bbukhari\b"#, #"\bsahih muslim\b"#,
        #"\bdid the prophet (say|do)\b"#,
        // Directive 4, part D (Mo, 5 Oct): a hadith request without the word hadith (annex row 6 paraphrase).
        #"\bsayings? of the prophet\b"#, #"\bthe prophet (said|says)\b"#, #"\bprophet muhammad said\b"#,
        #"\bauthentic (hadith|narration|saying|report)\b"#,
        // "sahih" alone, but never "Sahih International" - the name of our translation.
        #"\bsahih\b(?!\s+international)"#,
    ]

    /// Personal frames: the subject is I or we. These make the question PERSONAL on their own.
    static let personalFrames: [String] = [
        #"\b(am|are) (i|we) (allowed|permitted|supposed|required|obliged|obligated)\b"#,
        #"\b(can|could|may|should|must) (i|we) "#, #"\bdo (i|we) (have to|need to)\b"#,
        #"\b(am|are|was|were) (i|we) supposed to\b"#, #"\b(i|we) (am|are) supposed to\b"#,
        #"\bwhat (should|must|do) (i|we) do\b"#, #"\bwhat (am|are) (i|we) supposed to\b"#,
    ]

    /// Impersonal frames: "is it permissible…", "can a Muslim…". These count as RULING VOCABULARY
    /// (3a review, item 1): with a first-person marker the question is personal; with a qualifier
    /// it is a qualified ruling; otherwise a plain ruling, which a card may answer.
    static let impersonalFrames: [String] = [
        #"\bis (it|this|that) (ok|okay|fine|alright|all right|wrong|bad|allowed|permissible|a problem|acceptable)\b"#,
        #"\b(can|could|may|should|must) (one|a (muslim|woman|man|person|believer)|someone) "#,
        #"\b(is|are|was) (it|this|that) (required|necessary|mandatory|needed|compulsory|expected|obligatory)\b"#, #"\brequired to\b"#,
        #"\bis (it|there) (any )?(sin|harm|problem) (in|if|to)\b"#, #"\bwould (it|that) be (ok|okay|wrong|a sin|haram)\b"#,
        #"\b(is|are) (they|he|she) (allowed|permitted|supposed)\b"#, #"\bneed to be\b"#,
    ]

    /// A personal situation brought for judgement.
    static let personalSituation: [String] = [
        #"\bmy (boss|wife|husband|mother|father|mom|dad|son|daughter|brother|sister|friend|neighbou?r|employer|employee|customer|client|landlord|teacher|imam)\b"#,
        #"\b(at|in) (my|the) (shop|store|work|office|business|job|school)\b"#, #"\bi (missed|forgot|skipped|broke|owe|borrowed|lent|sold|bought|cheated|lied)\b"#,
        #"\bshort(ed|ing|change)? (someone|a customer|the customer|people)\b"#,
    ]

    /// First-person markers: a sentence about the asker.
    static let firstPerson: [String] = [#"\b(i|i'm|i’m|im|me|my|mine|we|we're|we’re|our|us)\b"#]

    /// Ruling vocabulary. REMOVED 2026-10-04: punish, prayer(s), fasting, ramadan, salah, salat, qibla.
    static let rulingVocabulary: [String] = [
        #"\bhalal\b"#, #"\bharam\b"#, #"\bhar+am\b"#, #"\bpermissib"#, #"\bpermitted\b"#, #"\ballow(ed|able)\b"#, #"\bforbidden\b"#,
        #"\bprohibit"#, #"\bobligat"#, #"\bwajib\b"#, #"\bfard\b"#, #"\bsunnah to\b"#, #"\bmakruh\b"#, #"\bmustahab"#,
        #"\bruling\b"#, #"\bfatwa\b"#, #"\b(a|any) sin\b"#, #"\bsin (to|if|for)\b"#, #"\bsinful\b"#, #"\bkaffara"#, #"\bexpiat"#,
        #"\bvalid\b"#, #"\binvalid"#, #"\bcount(s)? as\b"#, #"\bbreak(s|ing)? (my|the|your) (fast|wudu|wudhu|prayer|salah)\b"#,
        #"\bwudu\b"#, #"\bwudhu\b"#, #"\bablution"#, #"\bzakat\b"#, #"\bsadaqa"#, #"\bmy fast\b"#, #"\bprayer (valid|invalid)\b"#,
        #"\bhijab\b"#, #"\bmahram\b"#, #"\bnikah"#, #"\bdivorce"#, #"\btalaq"#, #"\binterest\b"#, #"\briba\b"#, #"\bloan\b"#, #"\bmortgage"#,
        #"\bcheat"#, #"\bsteal"#,
    ]

    /// Topic words that are ruling subjects in themselves.
    static let topicWords: [String] = [
        #"\balcohol\b"#, #"\balcoholic\b"#, #"\bwine\b"#, #"\bbeer\b"#, #"\bliquor\b"#, #"\bdrink(ing)? (beer|wine)\b"#, #"\bpork\b"#,
        #"\bgambl"#, #"\binterest\b"#, #"\briba\b"#, #"\busury\b"#, #"\blottery\b"#,
    ]

    /// A qualifier turns a plain ruling into a qualified one, which is always referred.
    static let qualifiers: [String] = [
        #"\bif\b"#, #"\bwhen\b"#, #"\bwhile\b"#, #"\bduring\b"#, #"\bunless\b"#, #"\bexcept\b"#, #"\beven\b"#, #"\bonly\b"#,
        #"\ba little\b"#, #"\bsmall amount"#, #"\btrace"#, #"\bcooked\b"#, #"\bin food\b"#, #"\bmedicin"#, #"\bmedication"#, #"\bperfume"#,
        #"\bsell(ing)?\b"#, #"\bserv(e|ing)\b"#, #"\bwork\b"#, #"\bjob\b"#,
    ]

    /// Every pattern the gate uses, for the compile test.
    public static var allPatterns: [String] { hadith + personalFrames + impersonalFrames + personalSituation + firstPerson + rulingVocabulary + topicWords + qualifiers }

    static func any(_ patterns: [String], in q: String) -> Bool {
        patterns.contains { q.range(of: $0, options: .regularExpression) != nil }
    }

    // MARK: classification

    /// Categories are checked in this order; the first that applies wins.
    public func classify(_ question: String) -> GateCategory {
        let q = TranscriptCleanup.forMatching(question).lowercased()
        if Self.any(Self.hadith, in: q) { return .hadithRequest }
        // Ruling words: vocabulary, a topic word, or an impersonal frame ("is it permissible…").
        let rulingWords = Self.any(Self.rulingVocabulary, in: q) || Self.any(Self.topicWords, in: q) || Self.any(Self.impersonalFrames, in: q)
        if Self.any(Self.personalFrames, in: q) || Self.any(Self.personalSituation, in: q) { return .personal }
        if rulingWords && Self.any(Self.firstPerson, in: q) { return .personal }
        if rulingWords && Self.any(Self.qualifiers, in: q) { return .qualifiedRuling }
        if rulingWords { return .plainRuling }
        return .none
    }

    /// Old callers: true when the question should be referred without consulting any router.
    public func looksLikeRuling(_ question: String) -> Bool { classify(question) != .none }
}

/// Any router, with the safety gate in front of it.
public struct SafetyGatedRouter: AttributingRouter {
    public let inner: any QuestionRouter
    public let gate = RulingSafetyGate()
    public var name: String { "safety+\(inner.name)" }
    public init(_ inner: any QuestionRouter) { self.inner = inner }

    public func route(_ question: String, anchorAyah: Int) async throws -> QuestionRoute {
        try await routeAttributed(question, anchorAyah: anchorAyah).route
    }

    public func routeAttributed(_ question: String, anchorAyah: Int) async throws -> AttributedRoute {
        if gate.looksLikeRuling(question) { return AttributedRoute(route: .ruling, decidedBy: "safety-gate") }
        return AttributedRoute(route: try await inner.route(question, anchorAyah: anchorAyah), decidedBy: inner.name)
    }
}

/// Day 3 hybrid: the safety gate first; then rules only where they are HIGH-CONFIDENCE
/// (unambiguous cue words); then the on-device model for everything else; rules if the model
/// refuses, errors or is absent.
public struct HybridRouter: AttributingRouter {
    public let model: (any QuestionRouter)?
    public let rules = RuleBasedRouter()
    public let gate = RulingSafetyGate()
    public var name: String { "hybrid(\(model?.name ?? "no-model"))" }

    public init(model: (any QuestionRouter)?) { self.model = model }

    /// The cues the rules may decide on alone. Everything else goes to the model.
    static let highConfidence: [(QuestionRoute, [String])] = [
        (.repetition, [#"\brepeat"#, #"\brepetition"#, #"\bagain and again\b"#, #"\bover and over\b"#, #"\brefrain\b"#, // F1 (after heldout-2 k56, "how many times a day do muslims pray"): "how many times" counts only when the
                       // question also points at the text or at repetition, in either order.
                       #"\bhow many (more )?times\b(?=.*\b(this|it|that|repeat|repeated|say|says|said|line|verse|refrain|ayah|aya|eye|question)\b)"#,
                       #"\b(this|it|that|repeat|repeated|say|says|said|line|verse|refrain|ayah|aya|eye|question)\b.*\bhow many (more )?times\b"#,
                       #"\bso many times\b"#, #"\b(same|this|that) (verse|ayah|aya|eye|line|question) (again|keeps|over)\b"#, #"\bkeeps? (coming|popping|showing) (up|back)\b"#, #"\b(twentieth|thirtieth|tenth|fifth|umpteenth) time\b"#, #"\b(already|just) (read|saw|seen|had) (this|that|it)\b"#, #"\bexact same (verse|ayah|aya|line|wording)\b"#,
                       #"\balready\b.*\btimes\b"#, #"\b(back|here) again\b"#, #"\bis it back\b"#, #"\bcome(s)? back\b"#, #"\bhow many were there\b"#, #"\blast one of these\b"#, #"\bfirst time this (line|verse|ayah|aya|eye)\b"#, #"\b(this|that) (line|verse|ayah|aya|eye) (shows|comes|pops) up\b"#, #"\bwisdom behind (saying|repeating) it\b"#]),
        (.related, [#"\b(come|comes|coming) up (again )?(later|elsewhere|before)\b"#, #"\bfurther (down|on|along|up)\b"#, #"\b(later|earlier|elsewhere) in the (sura|surah|chapter)\b"#, #"\bsame as what it says\b"#, #"\bagain later\b"#, #"\bwhere else\b"#, #"\bother (verses?|ayahs?|ayas?|ayat|eyes?|places?|parts?) (in|of|that|which|with)\b"#, #"\bsimilar (to|verse|ayah|aya|one)\b"#, #"\brelated (to|verse|ayah)\b"#, #"\bcompare(d|s)? (to|with)\b"#, #"\bsounds (a lot )?like (the|an|another)\b"#, #"\bearlier (one|verse|ayah|aya)\b"#, #"\bcross.?reference"#, #"\bconnect(ed|ion) (to|with|between)\b"#]),
        (.word, [#"\bin the arabic\b"#, #"\bin this context\b"#, #"^[a-z]+ in this (verse|ayah|aya|eye|line)\b"#, #"\bthe word\b"#, #"\bthis word\b"#, #"\bthat word\b"#, #"\barabic (word|term)\b"#, #"\bword for\b"#, #"\bthe term\b"#, #"\btranslat(ed|ion) (as|for|of|here)\b"#, #"\bright translation\b"#, #"\bliterally mean"#, #"\bwhat does ["'“‘][^"'”’]+["'”’] mean"#, #"\bnever heard (that|this|the) word\b"#, #"\bwhat('s| is) (a|an) [a-z]+\b"#]),
        (.meaning, [#"\bis this (verse |ayah |aya |eye |line |one )?about\b"#, #"\b(its|it's|it is) (talking|speaking) about\b"#, #"\btalking about in this\b"#, #"\bbeing addressed\b"#, #"\baddressed here\b"#, #"\bi don'?t get\b"#, #"\bwhat is this (verse|ayah|aya|eye|line|one) (about|saying|describing|telling)\b"#, #"\bwhat does this (verse|ayah|aya|eye|line|one) (mean|say|teach|tell)\b"#, #"\bwhy (would|does|did|do|is|are) (nobody|no one|everyone|they|he|she|it|this|that|the)\b"#]),
        (.offTopic, [#"\b(weather|forecast|football|soccer|arsenal|liverpool|match|score|bitcoin|stock|crypto|recipe|python|javascript|swift code|for loop|iphone|vision pro|headset|battery|brightness|text (bigger|smaller|larger)|font size|volume|wifi|bluetooth|movie|netflix|song|playlist|capital of|president|election|joke|poem|homework|flight|hotel|restaurant|dinner|lunch|coffee|time is it|what day|birthday|game|car|bus|train|traffic|blurry|blurred|(bring|move) (it|this|the text) closer|too (close|far)|my eyes|eye strain|headache|dizzy)\b"#]),
        // Display-comfort cues (blurry … dizzy) were added 2026-10-04, tuned on dev.json: d62 ("the text is
        // kind of blurry for my eyes is there a way to bring it closer") went to the model and came back
        // "word" once in four runs. The on-topic exception below still applies to them.
    ]

    /// Every high-confidence pattern, for the compile test.
    public static var allPatterns: [String] { highConfidence.flatMap(\.1) }

    /// Filler words that do not count toward a question's substance.
    static let fillers: Set<String> = ["um", "uh", "er", "hmm", "so", "like", "ok", "okay", "yeah", "yes", "no", "and", "then", "the", "a", "an", "wait", "well", "oh", "right", "with", "of", "to", "in", "on", "it", "this", "that", "thing", "stuff", "i", "me", "you"]

    /// A fragment: after removing fillers, one substantive word or none, and no question mark.
    public static func isFragment(_ question: String) -> Bool {
        let words = question.lowercased().split { !$0.isLetter && $0 != "'" && $0 != "’" }.map(String.init)
        let substantive = words.filter { !fillers.contains($0) }
        return substantive.count <= 1 && !question.contains("?")
    }

    public static func highConfidenceRoute(_ question: String) -> QuestionRoute? {
        if isFragment(question) { return .unclear }
        let q = question.lowercased()
        // WHOLE WORDS. "eye" is the speech-recogniser's rendering of "ayah" and must not match
        // "eyes" (held-out h34, "my eyes are hurting", slipped past the off-topic rule this way).
        let onTopic = q.range(of: #"\b(ayah|ayat|aya|ayas|eye|verse|verses|surah|sura|quran|koran|allah|god|lord|jinn|gin|favou?rs?|blessings?|bounties|bounty)\b"#, options: .regularExpression) != nil
        for (route, patterns) in highConfidence where patterns.contains(where: { q.range(of: $0, options: .regularExpression) != nil }) {
            // An off-topic cue inside an on-topic question is not high confidence.
            if route == .offTopic && onTopic { continue }
            return route
        }
        return nil
    }

    public func route(_ question: String, anchorAyah: Int) async throws -> QuestionRoute {
        try await routeAttributed(question, anchorAyah: anchorAyah).route
    }

    /// The deterministic stages alone - gate, fragment, high-confidence rules - or nil when the
    /// question would go on to the model. Used to attribute a past run without re-running it.
    public static func deterministicStage(_ question: String) -> AttributedRoute? {
        if RulingSafetyGate().looksLikeRuling(question) { return AttributedRoute(route: .ruling, decidedBy: "safety-gate") }
        if isFragment(question) { return AttributedRoute(route: .unclear, decidedBy: "fragment") }
        if let sure = highConfidenceRoute(question) { return AttributedRoute(route: sure, decidedBy: "rules-high-confidence") }
        return nil
    }

    public func routeAttributed(_ question: String, anchorAyah: Int) async throws -> AttributedRoute {
        if let decided = Self.deterministicStage(question) { return decided }
        guard let model else {
            return AttributedRoute(route: try await rules.route(question, anchorAyah: anchorAyah), decidedBy: "rules-no-model")
        }
        do {
            return AttributedRoute(route: try await model.route(question, anchorAyah: anchorAyah), decidedBy: model.name)
        } catch {
            let why = String(describing: error).contains("refusal") ? "rules-after-model-refusal" : "rules-after-model-error"
            #if DEBUG
            // The text was discarded until 5 Oct; on the headset two router calls errored and nothing said why.
            Logger(subsystem: "com.vrteek.quranspatial", category: "Ask").notice("Model router error (\(why, privacy: .public)): \(String(describing: error), privacy: .public)")
            #endif
            return AttributedRoute(route: try await rules.route(question, anchorAyah: anchorAyah), decidedBy: why)
        }
    }
}
