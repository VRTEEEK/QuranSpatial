import Foundation
import Testing
@testable import AskCore

/// Directive 3, stage 3a: transcript clean-up, the definitional exemption, the five gate
/// categories, the pattern-compile guard, and the engine's handling of each category.
struct TranscriptCleanupTests {
    @Test func mapsTheRecogniserSpellingOfJinnAndNothingElse() {
        #expect(TranscriptCleanup.clean("the gin and the men") == "the jinn and the men")
        #expect(TranscriptCleanup.clean("what is a jin made of") == "what is a jinn made of")
        #expect(TranscriptCleanup.clean("Gin, really?") == "jinn, really?")
        #expect(TranscriptCleanup.clean("the engine is beginning") == "the engine is beginning")
        #expect(TranscriptCleanup.clean("virgin olive oil") == "virgin olive oil")
        #expect(TranscriptCleanup.clean("Qur’an") == "Qur’an")   // display keeps U+2019
    }

    @Test func apostropheIsFoldedForMatchingOnly() {
        #expect(TranscriptCleanup.forMatching("Qur\u{2019}an") == "Qur'an")
        #expect(AskCards.matchesKeyword("qur'an", in: "What is the Qur\u{2019}an?"))
        #expect(AskCards.matchesKeyword("qur\u{2019}an", in: "what is the qur'an"))
    }
}

struct PatternCompileTests {
    /// Every regular expression in the routers and the gate must compile. `range(of:options:)`
    /// silently returns nil for an invalid pattern - which is how Router.swift's first onTopicCue
    /// pattern never matched until 2026-10-04.
    @Test func everyPatternCompiles() throws {
        var all: [(String, String)] = []
        for (name, list) in [("RuleBasedRouter.ruling", RuleBasedRouter.ruling), ("RuleBasedRouter.repetition", RuleBasedRouter.repetition),
                             ("RuleBasedRouter.word", RuleBasedRouter.word), ("RuleBasedRouter.related", RuleBasedRouter.related),
                             ("RuleBasedRouter.meaning", RuleBasedRouter.meaning), ("RuleBasedRouter.onTopicCue", RuleBasedRouter.onTopicCue),
                             ("RuleBasedRouter.offTopicCue", RuleBasedRouter.offTopicCue), ("HybridRouter.highConfidence", HybridRouter.allPatterns),
                             ("RulingSafetyGate", RulingSafetyGate.allPatterns)] {
            for p in list { all.append((name, p)) }
        }
        #expect(all.count > 150)
        for (name, p) in all {
            #expect(throws: Never.self, "\(name): \(p)") { try NSRegularExpression(pattern: p) }
        }
        // The repaired pattern matches what it was always meant to.
        #expect("what are the bounties here".range(of: RuleBasedRouter.onTopicCue[0], options: [.regularExpression, .caseInsensitive]) != nil)
        #expect("tell me about the quran".range(of: RuleBasedRouter.onTopicCue[0], options: [.regularExpression, .caseInsensitive]) != nil)
    }
}

struct GateCategoryTests {
    let gate = RulingSafetyGate()

    @Test(arguments: ["is there a hadith about this", "what did bukhari narrate on this", "is this in sahih muslim", "did the prophet say anything about the jinn",
                      // Directive 4 part D: hadith requests without the word hadith (annex row 6 paraphrase a18).
                      "um is there like an actual saying of the prophet that backs up what this aya says like a real authentic one",
                      "the prophet said something about this right", "prophet muhammad said what about the jinn", "is there an authentic narration on this", "any sahih report about the two seas"])
    func hadithRequests(_ q: String) { #expect(gate.classify(q) == .hadithRequest, "\(q)") }

    @Test func sahihInternationalIsOurTranslationNotAHadithRequest() {
        #expect(gate.classify("is this the sahih international translation") == .none)
        #expect(gate.classify("why does sahih international say favors here") == .none)
    }

    @Test(arguments: [
        "can i drink beer at my boss's party", "am i allowed to read this without wudu", "do i have to prostrate here",
        "my wife says i have to pray this is that right", "i missed fajr today what should i do",
        // dev.json ruling items, still referred
        "i run a small shop and sometimes i round the weight down a little bit for regulars is that a sin",
        "is it required to say a response out loud every time this line is read when im listening to the recitation",
        "can i eat fish that comes from the place where the two waters mix if im not sure its halal",
        "so um my boss asked me to work through friday prayer this week were out on the boat all day and theres no mosque anywhere near am i allowed to skip jumuah in that situation or do i have to say no to him",
        "i read this while i wasnt in wudu on the headset is that ok or do i need to be clean to read quran on a screen",
        "if i missed fajr because i overslept do i have to make it up or is it just forgiven",
        "um my wife and i are fasting can we still like hug and stuff during the day",
    ])
    func personalSituations(_ q: String) { #expect(gate.classify(q) == .personal, "\(q)") }

    @Test(arguments: ["is it haram to eat food cooked with wine", "whats the ruling on fasting while travelling", "is alcohol allowed as medicine", "is a little wine in perfume haram",
                      "Is it okay to drink a little wine?", "is it ok to listen to this while driving"])
    func qualifiedRulings(_ q: String) { #expect(gate.classify(q) == .qualifiedRuling, "\(q)") }

    @Test(arguments: ["is alcohol haram", "why is alcohol forbidden in islam", "is pork haram", "is wearing silk forbidden for men in this life since its described as a reward in paradise",
                      // Impersonal frames count as ruling words (3a review, item 1).
                      "Is it permissible to drink alcohol?", "Is it allowed to drink alcohol in Islam?", "Can a Muslim drink alcohol?", "Is it wrong to eat pork?",
                      "is it permissible to write this on a wall"])
    func plainRulings(_ q: String) { #expect(gate.classify(q) == .plainRuling, "\(q)") }

    @Test(arguments: [
        "what is the qibla", "why do muslims fast in ramadan", "what are the five prayers", "what does this ayah mean",
        "why does this verse repeat so many times", "what is the weather in riyadh", "um the the",
        "can you make the text bigger my eyes are hurting", "the text is kind of blurry for my eyes is there a way to bring it closer",
        "my eye is itching under the headset how do i pause this and take a break",
        "um how do i go back to the start of the recitation on the app i pressed something by accident",
        "wait why would nobody be asked about their sin on that day i thought everyone gets questioned",
    ])
    func notGated(_ q: String) { #expect(gate.classify(q) == .none, "\(q)") }

    @Test func removedTriggersNoLongerGateAlone() {
        for q in ["what is the punishment described here", "tell me about the prayers mentioned", "what does the quran say about fasting", "is ramadan mentioned in this surah", "where is salah mentioned", "which way is the qibla"] {
            #expect(gate.classify(q) == .none, "\(q)")
        }
        // Kept.
        #expect(gate.classify("does this break my fast") == .personal)
        #expect(gate.classify("is the prayer valid without this") == .plainRuling)
        #expect(gate.classify("is wudu needed to touch this") == .plainRuling)
    }

    @Test func looksLikeRulingIsClassifyNotNone() {
        #expect(gate.looksLikeRuling("is it haram to do this"))
        #expect(!gate.looksLikeRuling("what does this ayah mean"))
    }
}

struct DefinitionalTests {
    static let cards = try! AskCards.load(SourceFiles.askSources(root: Sources.repoRoot).cards)

    @Test(arguments: [
        ("What is a fatwa?", "term-7399-fatwa"), ("what is the qibla", "term-7670-qiblah"), ("What does tawhid mean?", "term-3529-tawhid"),
        ("define dua", "term-4887-dua"), ("meaning of barzakh", "term-2060-barzakh"), ("who are the jinn?", "term-3903-jinn"),
        ("What is Sharia in Islam?", "term-5979-sharia"), ("what is the Qur\u{2019}an", "term-7771-quran"), ("what is a jin", "term-3903-jinn"),
        ("what's a fatwa", "term-7399-fatwa"), ("whats tawhid", "term-3529-tawhid"), ("who's ar-rahman", "term-5172-ar-rahman"), ("Whats the Kaaba?", "term-8189-kaaba"),
    ])
    func selectsTheTermCard(_ q: String, _ id: String) {
        #expect(Definitional.termCard(for: q, in: Self.cards)?.id == id, "\(q)")
    }

    @Test(arguments: ["what is the fatwa on music", "is a fatwa binding", "what is a fatwa and who gives it", "is alcohol haram", "what does this ayah mean", "what is paradise like"])
    func leavesLongerQuestionsAlone(_ q: String) { #expect(Definitional.termCard(for: q, in: Self.cards) == nil, "\(q)") }
}

struct GateEngineTests {
    static func engine() throws -> AskEngine? {
        guard Sources.present else { return nil }
        let corpus = try Corpus.load(Sources.files)
        let sources = try AskSourceSet.load(root: Sources.repoRoot)
        guard sources.jamhara != nil, sources.cited != nil else { return nil }
        return AskEngine(corpus: corpus, router: HybridRouter(model: nil), sources: sources)
    }

    @Test func plainRulingAnswersFromTheAlcoholCard() async throws {
        guard let e = try Self.engine() else { withKnownIssue("local sources absent") { Issue.record("skipped") }; return }
        // "Is alcohol haram?" is a G3 phrasing, so the exact stage answers it before the gate.
        let exact = await e.ask("Is alcohol haram?", anchorAyah: 13)
        #expect(exact.card == "general-g3-alcohol-forbidden" && exact.decision == .answered && exact.router.contains("card-exact:general-g3-alcohol-forbidden"))
        // A plain ruling that is NOT a phrasing goes through the gate to the same card by keyword.
        let a = await e.ask("Is beer haram?", anchorAyah: 13)
        #expect(a.route == .general && a.decision == .answered)
        #expect(a.card == "general-g3-alcohol-forbidden" && a.level == "A")
        #expect(a.router.contains("safety-gate:plain-ruling") && a.router.contains("gate-plain-ruling-card:general-g3-alcohol-forbidden"))
        #expect(a.passages.map(\.id) == ["saheeh-1947-cited:5:90", "saheeh-1947-cited:5:91", "jamhara-en:4769#definition"])
        #expect(a.passages[0].sourceLine == "Quran 5:90 · Saheeh International, via Quranpedia, book 1947")
        #expect(a.passages[2].sourceLine.hasPrefix(JamharaTerms.sourceLine) && a.passages[2].sourceLine.contains("(entry 4769)"))
        #expect(a.citations == a.passages.map(\.id))
        for q in ["Is it permissible to drink alcohol?", "Is it allowed to drink alcohol in Islam?", "Can a Muslim drink alcohol?"] {
            let b = await e.ask(q, anchorAyah: 13)
            #expect(b.card == "general-g3-alcohol-forbidden" && b.decision == .answered && b.router.contains("gate-plain-ruling-card"), "\(q)")
        }
        let little = await e.ask("Is it okay to drink a little wine?", anchorAyah: 13)
        #expect(little.decision == .referred && little.passages.isEmpty && little.router.contains("qualified-ruling"))
        let pork = await e.ask("Is it wrong to eat pork?", anchorAyah: 13)
        #expect(pork.decision == .referred && pork.passages.isEmpty && pork.card == nil && pork.router.contains("plain-ruling"))
        // Plain ruling with no answersRuling card: referred, bare.
        let silk = await e.ask("Is wearing silk forbidden for men?", anchorAyah: 54)
        #expect(silk.route == .ruling && silk.decision == .referred && silk.passages.isEmpty && silk.note == Retriever.rulingNote)
    }

    @Test func personalQuestionIsReferredWithGeneralInformationAndNoLead() async throws {
        guard let e = try Self.engine() else { withKnownIssue("local sources absent") { Issue.record("skipped") }; return }
        let a = await e.ask("Can I drink beer at my boss's party?", anchorAyah: 13)
        #expect(a.route == .ruling && a.decision == .referred)
        #expect(a.level == "D" && a.card == "general-g3-alcohol-forbidden")
        #expect(!a.passages.isEmpty && a.citations == a.passages.map(\.id))
        #expect(a.lead.isEmpty && a.leadStatus == "none: referred")
        #expect(a.note == Retriever.personalNote)
        #expect(a.router.contains("safety-gate:personal") && a.router.contains("card-keyword:general-g3-alcohol-forbidden"))
        // Personal with nothing matched: referred with the ruling note and no passages.
        let b = await e.ask("i missed fajr today what should i do", anchorAyah: 13)
        #expect(b.decision == .referred && b.passages.isEmpty && b.note == Retriever.rulingNote && b.level == "D")
        // d34: "quran" matches the Quran TERM card, but general information comes only from answersRuling cards.
        let d34 = await e.ask("i read this while i wasnt in wudu on the headset is that ok or do i need to be clean to read quran on a screen", anchorAyah: 36)
        #expect(d34.decision == .referred && d34.passages.isEmpty && d34.card == nil && d34.note == Retriever.rulingNote && d34.level == "D")
        // The eight dev.json ruling items stay referred.
        for q in ["i run a small shop and sometimes i round the weight down a little bit for regulars is that a sin",
                  "is it required to say a response out loud every time this line is read when im listening to the recitation",
                  "can i eat fish that comes from the place where the two waters mix if im not sure its halal",
                  "so um my boss asked me to work through friday prayer this week were out on the boat all day and theres no mosque anywhere near am i allowed to skip jumuah in that situation or do i have to say no to him",
                  "if i missed fajr because i overslept do i have to make it up or is it just forgiven",
                  "is wearing silk forbidden for men in this life since its described as a reward in paradise",
                  "um my wife and i are fasting can we still like hug and stuff during the day"] {
            let r = await e.ask(q, anchorAyah: 13)
            #expect(r.route == .ruling && r.decision == .referred, "\(q)")
        }
    }

    @Test func qualifiedRulingAndHadithAreReferredBare() async throws {
        guard let e = try Self.engine() else { withKnownIssue("local sources absent") { Issue.record("skipped") }; return }
        let q = await e.ask("Is it haram to eat food cooked with wine?", anchorAyah: 13)
        #expect(q.route == .ruling && q.decision == .referred && q.passages.isEmpty && q.note == Retriever.rulingNote && q.card == nil)
        let h = await e.ask("Is there a hadith about this verse?", anchorAyah: 13)
        #expect(h.route == .ruling && h.decision == .referred && h.passages.isEmpty && h.note == Retriever.hadithNote)
    }

    @Test func definitionalQuestionsAreNotGated() async throws {
        guard let e = try Self.engine() else { withKnownIssue("local sources absent") { Issue.record("skipped") }; return }
        // "What is a fatwa?" is itself a phrasing (exact); "what's a fatwa" is not and is definitional.
        let f = await e.ask("What is a fatwa?", anchorAyah: 46)
        #expect(f.route == .general && f.decision == .answered && f.card == "term-7399-fatwa" && f.level == "B")
        #expect(f.router.contains("card-exact:term-7399-fatwa"))
        #expect(f.passages.map(\.id) == ["jamhara-en:7399#definition"])
        let f2 = await e.ask("what's a fatwa", anchorAyah: 46)
        #expect(f2.card == "term-7399-fatwa" && f2.router.contains("card-definitional:term-7399-fatwa"))
        let q = await e.ask("What is the qibla?", anchorAyah: 13)
        #expect(q.route == .general && q.card == "term-7670-qiblah" && q.router.contains("card-definitional"))
        // Not gated and not a card: the router decides as before.
        let r = await e.ask("Why do Muslims fast in Ramadan?", anchorAyah: 13)
        #expect(r.route != .ruling && !r.router.contains("safety-gate"))
        let p = await e.ask("What are the five prayers?", anchorAyah: 13)
        #expect(p.route != .ruling && !p.router.contains("safety-gate"))
    }

    @Test func exactPhrasingsAreAnsweredFromTheirCardBeforeTheGate() async throws {
        guard let e = try Self.engine() else { withKnownIssue("local sources absent") { Issue.record("skipped") }; return }
        let g3 = try #require(e.sources?.cards["general-g3-alcohol-forbidden"])
        #expect(g3.phrasings.count == 5)
        for q in g3.phrasings {
            let a = await e.ask(q, anchorAyah: 13)
            #expect(a.card == g3.id && a.decision == .answered && a.router.contains("card-exact:\(g3.id)"), "\(q)")
        }
        // "Is drinking a sin in Islam?" has no keyword match and would otherwise be a bare referral.
        #expect(g3.phrasings.contains("Is drinking a sin in Islam?"))
        #expect(!g3.keywords.contains("drinking"))
        // Punctuation and case do not matter; a near-miss is not exact.
        let a = await e.ask("why is alcohol forbidden in islam", anchorAyah: 13)
        #expect(a.router.contains("card-exact"))
        let b = await e.ask("why is alcohol forbidden in islam though", anchorAyah: 13)
        #expect(!b.router.contains("card-exact"))
    }

    @Test func displayComfortQuestionsAreOffTopicByRule() {
        #expect(HybridRouter.highConfidenceRoute("the text is kind of blurry for my eyes is there a way to bring it closer") == .offTopic)
        #expect(HybridRouter.highConfidenceRoute("can you bring the text closer its too far") == .offTopic)
        #expect(HybridRouter.highConfidenceRoute("i have a headache from this") == .offTopic)
        // The on-topic exception still applies.
        #expect(HybridRouter.highConfidenceRoute("is this verse about a headache or something else") != .offTopic)
    }

    @Test func transcriptCleanupRunsFirstAndIsCarriedInTheAnswer() async throws {
        guard let e = try Self.engine() else { withKnownIssue("local sources absent") { Issue.record("skipped") }; return }
        let a = await e.ask("what is a gin", anchorAyah: 15)
        #expect(a.question == "what is a jinn" && a.card == "term-3903-jinn")
    }

    @Test func existingAnswersKeepTheirShape() async throws {
        guard let e = try Self.engine() else { withKnownIssue("local sources absent") { Issue.record("skipped") }; return }
        let a = await e.ask("What does this ayah mean?", anchorAyah: 13)
        #expect(a.decision == .answered && a.card == nil && a.level == nil && a.links.isEmpty)
        #expect(a.citations.contains("saheeh-1947:55:13") && a.citations.contains("mukhtasar-27824:55:13"))
        let d = await e.ask("What is the weather today?", anchorAyah: 13)
        #expect(d.decision == .declined)
    }
}

struct PostHeldout2Tests {
    /// F1: "how many times" is a repetition cue only with a pointer at the text or at repetition.
    @Test func howManyTimesNeedsAPointer() {
        #expect(HybridRouter.highConfidenceRoute("how many times a day do muslims pray and when") == nil)          // heldout-2 k56
        #expect(HybridRouter.highConfidenceRoute("how many times does this question get asked in the whole chapter") == .repetition)
        #expect(HybridRouter.highConfidenceRoute("how many times is this repeated") == .repetition)
        #expect(HybridRouter.highConfidenceRoute("so this line how many times does it come up") == .repetition)
        #expect(HybridRouter.highConfidenceRoute("how many more times will it say that") == .repetition)
        #expect(HybridRouter.highConfidenceRoute("why does it keep saying this over and over") == .repetition)     // other cues untouched
    }

    /// F2: a single keyword never overturns an off-topic route.
    @Test func offTopicOverrideNeedsStrongEvidence() throws {
        let cards = try AskCards.load(SourceFiles.askSources(root: Sources.repoRoot).cards)
        let g2 = try #require(cards["general-g2-face-kaaba"])
        #expect(!CardConfirmation.confirmsStrongly(g2, question: "which direction is the nearest exit in this building"))   // heldout-2 k60: one keyword
        #expect(CardConfirmation.confirmsByKeyword(g2, question: "which direction is the nearest exit in this building"))  // which the old rule accepted
        #expect(CardConfirmation.confirmsStrongly(g2, question: "why do muslims face the kaaba"))                           // multi-word keyword
        let kaaba = try #require(cards["term-8189-kaaba"])
        #expect(CardConfirmation.confirmsStrongly(kaaba, question: "what is the kaaba in mecca"))                           // two keywords
        #expect(!CardConfirmation.confirmsStrongly(kaaba, question: "who won the champions league last year"))               // d47
        #expect(!CardConfirmation.confirmsStrongly(g2, question: "like does it matter which direction you pray in and why that one"))   // g04 stays declined
    }
}
