import Foundation
import Testing
@testable import AskCore

/// Directive 3, stage 3b: precedence between ayah routes and cards, card selection, not-covered.
/// Model-free: a stub picker stands in for Foundation Models so the chain is deterministic.
struct StubPicker: CardPicker {
    let name = "stub"
    let answer: String
    func pick(question: String, from cards: [AskCard]) async throws -> String { answer }
}
struct FailingPicker: CardPicker {
    let name = "failing"
    struct Refusal: Error, CustomStringConvertible { var description: String { "refusal(stub)" } }
    func pick(question: String, from cards: [AskCard]) async throws -> String { throw Refusal() }
}

struct PrecedenceTests {
    static let cards = try! AskCards.load(SourceFiles.askSources(root: Sources.repoRoot).cards)
    let anchor15 = ["He made the jinn out of a smokeless flame of fire.", "Allah created the jinn from a flame of fire."]  // synthetic stand-ins
    let anchor2 = ["Taught the Qur'an.", "He taught the Quran to whom He willed."]

    @Test func anchorCues() {
        #expect(Precedence.hasAnchorCue("what does this ayah mean"))
        #expect(Precedence.hasAnchorCue("what does jinn mean here"))
        #expect(Precedence.hasAnchorCue("who is addressed in this"))
        #expect(!Precedence.hasAnchorCue("what is a fatwa"))
        // References to the surah on screen (d60).
        #expect(Precedence.hasAnchorCue("the sura ends by blessing the name of god why end it like that"))
        #expect(Precedence.hasAnchorCue("Why is this surah called Ar-Rahman?"))
        #expect(Precedence.hasAnchorCue("where in surah rahman is the balance mentioned"))
        #expect(Precedence.hasAnchorCue("what is the chapter about"))
        #expect(!Precedence.hasAnchorCue("who is ar-rahman"))
    }

    @Test func surahReferencesKeepTheAyahRoute() {
        let rahman = [Self.cards["term-5172-ar-rahman"]!]
        #expect(Precedence.apply(route: .meaning, question: "the sura ends by blessing the name of god why end it like that", matched: rahman, anchorTexts: ["Blessed be the name of your Lord."]) == .keep)
        #expect(Precedence.apply(route: .general, question: "Why is this surah called Ar-Rahman?", matched: rahman, anchorTexts: anchor2) == .toMeaning)
    }

    @Test func generalWithAnchorCueBecomesMeaning() {
        #expect(Precedence.apply(route: .general, question: "what is this ayah about", matched: [], anchorTexts: anchor15) == .toMeaning)
        #expect(Precedence.apply(route: .general, question: "what is tawhid", matched: [], anchorTexts: anchor15) == .keep)
    }

    @Test func ayahRoutesWithForeignCardKeywordsBecomeGeneral() {
        let fatwa = [Self.cards["term-7399-fatwa"]!]
        #expect(Precedence.apply(route: .meaning, question: "what is the point of a fatwa", matched: fatwa, anchorTexts: anchor15) == .toGeneral)
        #expect(Precedence.apply(route: .unclear, question: "fatwa", matched: fatwa, anchorTexts: anchor15) == .toGeneral)
        // The keyword occurs in the anchor ayah: stay with the ayah.
        let jinn = [Self.cards["term-3903-jinn"]!]
        #expect(Precedence.apply(route: .meaning, question: "why are the jinn mentioned", matched: jinn, anchorTexts: anchor15) == .keep)
        // An anchor cue keeps the ayah route even with a foreign keyword.
        #expect(Precedence.apply(route: .meaning, question: "is this ayah about a fatwa", matched: fatwa, anchorTexts: anchor15) == .keep)
        #expect(Precedence.apply(route: .meaning, question: "who is addressed", matched: [], anchorTexts: anchor15) == .keep)
    }

    @Test func wordRouteAboutATermInTheAyahKeepsWordAndAddsTheCard() {
        let jinn = [Self.cards["term-3903-jinn"]!]
        #expect(Precedence.apply(route: .word, question: "what does jinn mean here", matched: jinn, anchorTexts: anchor15) == .wordPlusTerm(cardID: "term-3903-jinn"))
        #expect(Precedence.apply(route: .word, question: "what does jinn mean", matched: jinn, anchorTexts: anchor15) == .wordPlusTerm(cardID: "term-3903-jinn"))
        // A term not in the ayah and no cue: general.
        #expect(Precedence.apply(route: .word, question: "what does the word fatwa mean", matched: [Self.cards["term-7399-fatwa"]!], anchorTexts: anchor15) == .toGeneral)
    }

    @Test func uncoveredGeneralTopicsBecomeGeneralWithoutACardKeyword() {
        // Directive 4, part D: general-dev's uncovered items, routed unclear/meaning/related by the rules or the model.
        for q in ["what does jihad actually mean", "what is the sunnah", "um do muslims believe in angels and what do they do",
                  "why do people not eat all day during ramadan", "the money muslims have to give to the poor every year what's that called"] {
            #expect(Precedence.apply(route: .unclear, question: q, matched: [], anchorTexts: anchor15) == .toGeneral, "\(q)")
            #expect(Precedence.apply(route: .meaning, question: q, matched: [], anchorTexts: anchor15) == .toGeneral, "\(q)")
        }
        #expect(Precedence.apply(route: .related, question: "how many prophets are there in islam and who was the first one", matched: [], anchorTexts: anchor15) == .toGeneral)
        // Ayah questions keep their route: a screen reference, an anchor cue, or no general topic word.
        #expect(Precedence.apply(route: .meaning, question: "um what does it mean that the sun and moon are calculated", matched: [], anchorTexts: anchor15) == .keep)
        #expect(Precedence.apply(route: .meaning, question: "so like it says the gin were made from fire what does that tell us", matched: [], anchorTexts: anchor15) == .keep)
        #expect(Precedence.apply(route: .meaning, question: "what does islam say about this verse", matched: [], anchorTexts: anchor15) == .keep)
        #expect(Precedence.apply(route: .meaning, question: "is this about muslims or everyone", matched: [], anchorTexts: anchor15) == .keep)
        // Word questions are never redirected by the topic list ("what are the cushions called in the arabic").
        #expect(Precedence.apply(route: .word, question: "what are the cushions called in the arabic", matched: [], anchorTexts: anchor15) == .keep)
        #expect(Precedence.apply(route: .repetition, question: "why does islam repeat this", matched: [], anchorTexts: anchor15) == .keep)
    }

    @Test func ayahQuestionsThatShareAContentWordWithTheAnchorStay() {
        // Directive 4 part D: the guard runs before any redirect to general. Anchor texts are synthetic stand-ins.
        let seas = ["Two seas are set loose so that they meet each other.", "The salty sea and the sweet sea run side by side and meet."]
        #expect(Precedence.apply(route: .meaning, question: "why does the quran talk about two seas meeting", matched: [], anchorTexts: seas) == .keep)
        let clay = ["Mankind was fashioned out of dry clay, the sort potters use.", "People were shaped from clay that rings like pottery."]
        #expect(Precedence.apply(route: .meaning, question: "does the quran say humans were made from clay like pottery", matched: [], anchorTexts: clay) == .keep)
        let marks = ["The criminals are recognised by the marks on them.", "The guilty will be known by their faces and seized."]
        #expect(Precedence.apply(route: .meaning, question: "how will the criminals be known on the day of judgment", matched: [], anchorTexts: marks) == .keep)
        // g29 shares nothing with its anchor (ayah 60's reward line) and still goes general.
        let reward = ["Is the recompense for excellence anything but excellence?", "Those who did well receive bliss in return."]
        #expect(Precedence.apply(route: .unclear, question: "the money muslims have to give to the poor every year what's that called", matched: [], anchorTexts: reward) == .toGeneral)
        // A card keyword in the question still yields to a shared content word with the anchor.
        let jinn = [Self.cards["term-3903-jinn"]!]
        #expect(Precedence.apply(route: .meaning, question: "why were the jinn made from smokeless flame", matched: jinn, anchorTexts: anchor15) == .keep)
        #expect(!Precedence.sharesContentWord("what does this mean", anchorTexts: seas))        // generic words only
        #expect(Precedence.sharesContentWord("the two seas meeting", anchorTexts: seas))
    }

    @Test func strongKeywordFallbackNeedsAPhraseOrTwoKeywords() {
        let all = Self.cards.cards
        #expect(CardSelector.strongKeywordFallback("why do you all worship the kaaba", among: all)?.id == "general-g2-face-kaaba")   // multi-word keyword
        #expect(CardSelector.strongKeywordFallback("is jannah the same as paradise", among: all) != nil)                             // two keywords of one card
        #expect(CardSelector.strongKeywordFallback("what is sharia", among: all) == nil)                                             // one single-word keyword only
        #expect(CardSelector.strongKeywordFallback("tell me about the weather", among: all) == nil)
    }

    @Test func offTopicOnlyYieldsToAConfirmedCard() {
        #expect(Precedence.apply(route: .offTopic, question: "the text isn't facing me", matched: [], anchorTexts: anchor15) == .offTopicNeedsConfirmedCard)
        #expect(Precedence.apply(route: .repetition, question: "why again", matched: [Self.cards["term-7399-fatwa"]!], anchorTexts: anchor15) == .keep)
    }
}

struct CardSelectionTests {
    static let cards = try! AskCards.load(SourceFiles.askSources(root: Sources.repoRoot).cards)

    @Test func confirmationNeedsASharedKeywordOrContentWord() {
        let tawhid = Self.cards["term-3529-tawhid"]!, fatwa = Self.cards["term-7399-fatwa"]!
        #expect(CardConfirmation.confirms(tawhid, question: "what is the oneness of god"))        // keyword
        #expect(CardConfirmation.confirms(tawhid, question: "explain monotheism to me"))           // keyword
        #expect(CardConfirmation.confirms(fatwa, question: "are fatwas binding on everyone"))      // content word, stemmed
        #expect(!CardConfirmation.confirms(fatwa, question: "what do muslims believe about islam")) // generic words only
        #expect(!CardConfirmation.confirms(fatwa, question: "how do i write a for loop in swift"))
    }

    @Test func keywordFallbackScoresAndBreaksTies() {
        let all = Self.cards.cards
        // Two keywords beat one ("face the kaaba" + "pray towards" on G2 against "kaaba" on the term card).
        #expect(CardSelector.keywordFallback("why do muslims face the kaaba and pray towards it", among: all)?.id == "general-g2-face-kaaba")
        // And the other way round: "kaaba" + "mecca" on the term card against one phrase on G2.
        #expect(CardSelector.keywordFallback("why do muslims face the kaaba in mecca", among: all)?.id == "term-8189-kaaba")
        // Same score: the longer matched keyword wins ("after death" over "death").
        #expect(CardSelector.keywordFallback("what is after death", among: all)?.id == "general-g4-after-death")
        // Same score and length: general before term ("jannah" on G5 and the term card).
        #expect(CardSelector.keywordFallback("tell me about jannah", among: all)?.id == "general-g5-what-jannah-is")
        #expect(CardSelector.keywordFallback("how do i write a for loop", among: all) == nil)
    }

    @Test func exactMatchIgnoresCaseAndEndPunctuation() {
        let all = Self.cards.cards
        #expect(CardSelector.exactMatch("WHO WROTE THE QURAN?!", among: all)?.id == "gap-quran-authorship")   // id unchanged after A2
        #expect(CardSelector.exactMatch("Is the Quran the word of God?", among: all)?.id == "term-7771-quran")
        #expect(CardSelector.exactMatch("is the quran the word of god or not", among: all) == nil)
    }
}

struct CardEngineTests {
    static func engine(picker: (any CardPicker)? = nil) throws -> AskEngine? {
        guard Sources.present else { return nil }
        let corpus = try Corpus.load(Sources.files)
        let sources = try AskSourceSet.load(root: Sources.repoRoot)
        guard sources.jamhara != nil, sources.cited != nil else { return nil }
        return AskEngine(corpus: corpus, router: HybridRouter(model: nil), sources: sources, cardPicker: picker)
    }

    @Test func step8Examples() async throws {
        guard let e = try Self.engine() else { withKnownIssue("local sources absent") { Issue.record("skipped") }; return }
        // Ayah 46, "What is a fatwa?" -> general / fatwa card (exact, before anything else).
        let f = await e.ask("What is a fatwa?", anchorAyah: 46)
        #expect(f.route == .general && f.card == "term-7399-fatwa" && f.decision == .answered)
        // Ayah 15, "what does jinn mean here" -> word plus the jinn card's Jamhara passages after the ayah's.
        let j = await e.ask("what does jinn mean here", anchorAyah: 15)
        #expect(j.route == .word && j.decision == .answered && j.card == "term-3903-jinn")
        #expect(j.passages.first?.id == "saheeh-1947:55:15")
        #expect(j.passages.last?.id == "jamhara-en:3903#explanation")
        #expect(j.passages.contains { $0.id == "jamhara-en:3903#definition" })
        #expect(j.router.contains("precedence:word+term:term-3903-jinn"))
        // d60: a question about the surah stays on the ayah route even though "name of god" is a card keyword.
        let d60 = await e.ask("the sura ends by blessing the name of god why end it like that what ties it back to the first aya", anchorAyah: 78)
        #expect(d60.route == .meaning && d60.decision == .answered && d60.card == nil && !d60.router.contains("precedence"))
        // Definitional questions are unchanged by the cue list.
        // ("Who is Ar-Rahman?" is a phrasing, so the exact stage claims it; "who's ar-rahman" is definitional.)
        let who = await e.ask("who is ar-rahman", anchorAyah: 1)
        #expect(who.card == "term-5172-ar-rahman" && who.router.contains("card-exact"))
        let whos = await e.ask("who's ar-rahman", anchorAyah: 1)
        #expect(whos.card == "term-5172-ar-rahman" && whos.router.contains("card-definitional"))
        let what = await e.ask("What is tawhid?", anchorAyah: 1)
        #expect(what.card == "term-3529-tawhid" && what.router.contains("card-exact"))
        // Ayah 2, "Is the Quran the word of God?" -> general / Quran card (a phrasing: exact).
        let q = await e.ask("Is the Quran the word of God?", anchorAyah: 2)
        #expect(q.route == .general && q.card == "term-7771-quran" && q.decision == .answered)
        #expect(q.passages.map(\.id) == ["jamhara-en:7771#definition", "jamhara-en:7771#explanation"])
        // d61 and d62 stay declined (the rules decide them off-topic; keywords never override it).
        // d63 is decided by the model stage and is covered by the dev run, not here.
        for q in ["can you make the text bigger my eyes are hurting", "the text is kind of blurry for my eyes is there a way to bring it closer"] {
            let a = await e.ask(q, anchorAyah: 47)
            #expect(a.decision == .declined, "\(q)")
        }
    }

    @Test func notCoveredCases() async throws {
        guard let e = try Self.engine() else { withKnownIssue("local sources absent") { Issue.record("skipped") }; return }
        // Gap card: not-covered with the Arabic link.
        let g = await e.ask("Did Islam spread by the sword?", anchorAyah: 13)
        #expect(g.decision == .notCovered && g.card == "gap-spread-by-sword" && g.level == "C")
        #expect(g.links == ["https://dawa.center/file/7937"] && g.note == Retriever.gapNote && g.passages.isEmpty)
        // A2: the authorship card answers from Jamhara 7771 and keeps its link as further reading.
        let auth = await e.ask("Who wrote the Quran?", anchorAyah: 13)
        #expect(auth.decision == .answered && auth.card == "gap-quran-authorship" && auth.level == "B")
        #expect(auth.passages.map(\.id) == ["jamhara-en:7771#definition", "jamhara-en:7771#explanation"])
        #expect(auth.links == ["https://dawa.center/file/7937"] && auth.note == Retriever.furtherReadingNote)
        // ("fatwa" is ruling vocabulary and would be gated; "ijtihad" is a card keyword and is not.)
        let q = "what is the point of ijtihad in daily life"
        // General with no card (stub picker says none).
        let none = try #require(try Self.engine(picker: StubPicker(answer: "none")))
        let n = await none.ask(q, anchorAyah: 13)
        #expect(n.route == .general && n.decision == .notCovered && n.note == Retriever.generalNotCoveredNote && n.card == nil)
        #expect(n.router.contains("precedence:card-keywords->general") && n.router.contains("card-model-none"))
        // Unconfirmed pick -> none, not the keyword fallback.
        let wrong = try #require(try Self.engine(picker: StubPicker(answer: "term-8189-kaaba")))
        let u = await wrong.ask(q, anchorAyah: 13)
        #expect(u.decision == .notCovered && u.router.contains("card-model-unconfirmed:term-8189-kaaba"))
        // Confirmed pick answers.
        let right = try #require(try Self.engine(picker: StubPicker(answer: "term-196-ijtihad")))
        let c = await right.ask(q, anchorAyah: 13)
        #expect(c.decision == .answered && c.card == "term-196-ijtihad" && c.router.contains("card-model:term-196-ijtihad"))
        // Model refusal -> keyword fallback: "ijtihad" is on the term card and on G6; same score and
        // length, so general comes before term.
        let refused = try #require(try Self.engine(picker: FailingPicker()))
        let k = await refused.ask(q, anchorAyah: 13)
        #expect(k.decision == .answered && k.card == "general-g6-why-scholars-differ" && k.router.contains("card-keyword-after-model-refusal:general-g6-why-scholars-differ"))
    }

    @Test func unconfirmedOrNonePickFallsBackOnStrongKeywordsOnly() async throws {
        guard let none = try Self.engine(picker: StubPicker(answer: "none")) else { withKnownIssue("local sources absent") { Issue.record("skipped") }; return }
        // "worship the kaaba" is a multi-word keyword of G2: strong -> answered from G2 after the model's "none".
        // (With "in mecca" the Kaaba term card's two single keywords, kaaba + mecca, would also be strong and outrank G2.)
        let a = await none.ask("why do you all worship the kaaba", anchorAyah: 5)
        #expect(a.decision == .answered && a.card == "general-g2-face-kaaba" && a.router.contains("card-keyword-after-model-none:general-g2-face-kaaba"))
        // A single one-word keyword ("sharia") is weak: not-covered.
        let b = await none.ask("what is sharia actually", anchorAyah: 5)
        #expect(b.decision == .notCovered && b.card == nil && b.router.contains("card-model-none"))
        // An unconfirmed pick with strong keywords elsewhere falls back too.
        let wrong = try #require(try Self.engine(picker: StubPicker(answer: "term-7670-qiblah")))
        let c = await wrong.ask("why do you all worship the kaaba", anchorAyah: 5)
        #expect(c.decision == .answered && c.card == "general-g2-face-kaaba" && c.router.contains("card-keyword-after-model-unconfirmed:term-7670-qiblah->general-g2-face-kaaba"))
    }

    @Test func unavailableCardIsNotCovered() async throws {
        guard Sources.present else { withKnownIssue("sources absent") { Issue.record("skipped") }; return }
        let corpus = try Corpus.load(Sources.files)
        // Cards only, no local Jamhara or cited files: every term/general card is unavailable.
        let cardsOnly = AskSourceSet(cards: try AskCards.load(SourceFiles.askSources(root: Sources.repoRoot).cards), jamhara: nil, cited: nil)
        #expect(cardsOnly.availableCount(corpus: corpus) == 1)   // the one gap card (sword)
        let e = AskEngine(corpus: corpus, router: HybridRouter(model: nil), sources: cardsOnly)
        let a = await e.ask("What is a fatwa?", anchorAyah: 13)
        #expect(a.decision == .notCovered && a.card == "term-7399-fatwa" && a.note == Retriever.unavailableNote && a.passages.isEmpty)
        // A personal question then has no general information to attach.
        let p = await e.ask("Can I drink beer at my boss's party?", anchorAyah: 13)
        #expect(p.decision == .referred && p.passages.isEmpty && p.card == nil)
    }

    @Test func levelCNoteAndOffTopicWithoutConfirmation() async throws {
        guard let e = try Self.engine(picker: StubPicker(answer: "general-g6-why-scholars-differ")) else { withKnownIssue("local sources absent") { Issue.record("skipped") }; return }
        let a = await e.ask("why do scholars differ so much on things", anchorAyah: 13)
        #expect(a.decision == .answered && a.card == "general-g6-why-scholars-differ" && a.level == "C" && a.note == CardRetriever.levelCNote)
        #expect(a.passages.map(\.id) == ["jamhara-en:454#definition", "jamhara-en:454#explanation", "jamhara-en:196#definition"])
        // Off-topic is overturned only by a pick that a card KEYWORD confirms: a shared content word
        // ("last" with the Last Day card's title) is not enough. "football"/"match" make the rules
        // route this off-topic, as the model does for d47.
        let lastDay = try #require(try Self.engine(picker: StubPicker(answer: "term-11207-last-day")))
        let football = await lastDay.ask("who won the football match last year", anchorAyah: 55)
        #expect(football.decision == .declined && football.card == nil && !football.router.contains("precedence:off-topic->general"))
        // F2 (heldout-2 k60): the rules route "nearest exit in this building" off-topic? Not by cue; use a
        // rules-off-topic wording with the single G2 keyword "direction": still declined.
        let g2pick = try #require(try Self.engine(picker: StubPicker(answer: "general-g2-face-kaaba")))
        let exit = await g2pick.ask("which direction is the weather coming from today", anchorAyah: 61)
        #expect(exit.decision == .declined && exit.card == nil)
        // Off-topic stays declined when no card can be confirmed, whatever the picker would say.
        // ("the text isn't facing me" is off-topic only through the model router; the rules read
        // "the text" as on-topic, so a rules-decided off-topic question is used here.)
        let d = await e.ask("whats the weather in riyadh", anchorAyah: 13)
        #expect(d.decision == .declined && d.card == nil && !d.router.contains("card-model"))
    }
}

#if canImport(FoundationModels)
struct CardPickerValidationTests {
    @Test func onlyAnExactIdCounts() {
        let ids = ["term-3529-tawhid", "general-g1-tawhid-newcomer", "none"]
        if #available(macOS 26.0, *) {
            #expect(FoundationModelsCardPicker.validate("term-3529-tawhid", ids: ids) == "term-3529-tawhid")
            #expect(FoundationModelsCardPicker.validate("term-3529-tawhid: What Tawhid means", ids: ids) == "term-3529-tawhid")
            #expect(FoundationModelsCardPicker.validate("  general-g1-tawhid-newcomer\n", ids: ids) == "general-g1-tawhid-newcomer")
            #expect(FoundationModelsCardPicker.validate("none", ids: ids) == "none")
            #expect(FoundationModelsCardPicker.validate("term-3529-tawhid-extra", ids: ids) == "none")
            #expect(FoundationModelsCardPicker.validate("The card is term-3529-tawhid", ids: ids) == "none")
            #expect(FoundationModelsCardPicker.validate("", ids: ids) == "none")
        }
    }
}
#endif
