import Foundation
import Testing
@testable import AskCore

/// The verifier is the integrity gate on the only free text the model produces. Adversarial
/// leads first; then the threshold is pinned.
struct LeadVerifierTests {
    /// SYNTHETIC fixtures: no source text may appear in the repository, so these are made-up
    /// sentences that merely share the vocabulary the tests exercise (favours, deny, jinn, men).
    let passages = [
        Passage(source: .saheehTranslation, ayah: 13, text: "Which favours of your Lord would you then deny?"),
        Passage(source: .mukhtasar, ayah: 13, text: "A question put to jinn and men about the many favours of Allah that they deny."),
    ]
    let question = "why does this repeat?"
    func verify(_ lead: String) -> LeadVerifier.Verdict { LeadVerifier.verify(lead: lead, passages: passages, question: question, anchorAyah: 13) }

    @Test func acceptsAPlainIntroductionBuiltFromThePassages() {
        // (Reworded 5 Oct: the earlier wording copied six consecutive words of the Mukhtasar stand-in.)
        #expect(verify("The translation and the Mukhtasar passage below give this ayah’s question for jinn and men, on your Lord’s favours.") == .accepted)
        #expect(verify("What the sources say about the favours you are asked to deny is below.") == .accepted)
    }

    @Test func rejectsArabicScript() {
        #expect(verify("The passage below renders بِسْمِ in English.") == .rejected("contains Arabic script"))
        #expect(LeadVerifier.containsArabicScript("ﷲ"))
        #expect(!LeadVerifier.containsArabicScript("Allah’s favours"))
    }

    @Test func rejectsAnAyahOrNumberThatWasNotRetrieved() {
        #expect(verify("Ayah 14 below explains the favours.") == .rejected("mentions a number not retrieved: 14"))
        #expect(verify("This question is repeated 31 times in the surah.") == .rejected("mentions a number not retrieved: 31"))
        // The surah number and the retrieved ayah are fine.
        #expect(verify("Ayah 13 of surah 55 below asks which favours you deny.") == .accepted)
    }

    @Test func rejectsContentWordsAbsentFromThePassages() {
        // An explanation the sources do not give: new nouns and verbs.
        if case .rejected(let reason) = verify("The refrain repeats to emphasise gratitude after each blessing of creation and paradise.") {
            #expect(reason.hasPrefix("introduces content not in the passages:"))
            #expect(reason.contains("emphasise") || reason.contains("gratitude"))
        } else { Issue.record("an invented explanation was accepted") }
        #expect(verify("Pharaoh and Moses are the favours named here.") != .accepted)
    }

    @Test func rejectsEmptyOverlongAndMultiSentenceLeads() {
        #expect(verify("") == .rejected("empty"))
        #expect(verify("   ") == .rejected("empty"))
        #expect(verify("One. Two. Three sentences about the favours.") == .rejected("too many sentences: 3"))
        let long = Array(repeating: "favours", count: 61).joined(separator: " ")
        if case .rejected(let r) = verify(long) { #expect(r.hasPrefix("too long")) } else { Issue.record("overlong lead accepted") }
    }

    /// THE THRESHOLD, pinned: at most 2 novel content words AND at most 15% of content words.
    @Test func thresholdIsTwoNovelWordsAndFifteenPercent() {
        #expect(LeadVerifier.maxNovelContentWords == 2)
        #expect(LeadVerifier.maxNovelFraction == 0.15)
        // 18 content words, 2 novel ("gently", "briefly") -> 11% -> accepted.
        let twoNovel = "The translation and the Mukhtasar passage below present this ayah’s question about which favours of your Lord the jinn and men would deny, gently and briefly."
        #expect(verify(twoNovel) == .accepted, "\(verify(twoNovel))")
        // 3 novel -> rejected on count regardless of fraction.
        let threeNovel = twoNovel.replacingOccurrences(of: "briefly", with: "briefly and warmly")
        #expect(verify(threeNovel) == .rejected("introduces content not in the passages: briefly, gently, warmly"))
        // 2 novel out of 4 content words -> 50% -> rejected on fraction.
        #expect(verify("Favours gently, deny briefly.") == .rejected("introduces content not in the passages: briefly, gently"))
    }

    // MARK: 3c-2, stricter

    @Test func questionWordsNoLongerCountSoAFalsePremiseCannotBeEchoed() {
        // The question asserts something the passages do not say; a lead that repeats it is rejected.
        let loaded = LeadVerifier.verify(lead: "The passages below address why this ayah was revealed in Makkah about trade.",
                                         passages: passages, question: "why was this ayah revealed in makkah about trade", anchorAyah: 13)
        if case .rejected(let r) = loaded { #expect(r.hasPrefix("introduces content not in the passages:") && r.contains("makkah")) } else { Issue.record("question echo accepted") }
        // Before 3c-2 this was accepted because "questioning" and "repeats" came from the question.
        #expect(verify("You are questioning why the sources repeat the same question.") != .accepted)
    }

    @Test(arguments: ["The passages do not explain the favours.", "No passage below names the jinn.", "Nothing here is about men.",
                      "The sources never deny the favours.", "This isn’t about the favours.", "The translation doesn't mention jinn.", "Neither passage is about the favours.", "The favours cannot be denied here."])
    func rejectsNegation(_ lead: String) {
        if case .rejected(let r) = verify(lead) { #expect(r.hasPrefix("contains a negation:"), "\(lead): \(r)") } else { Issue.record("negation accepted: \(lead)") }
    }

    @Test(arguments: ["You should read the favours below.", "Jinn and men must deny nothing.", "You ought to see the passages.", "You have to read the translation.", "Readers need to see the favours."])
    func rejectsAdvice(_ lead: String) {
        if case .rejected(let r) = verify(lead) { #expect(r.hasPrefix("contains advice wording:") || r.hasPrefix("contains a negation:"), "\(lead): \(r)") } else { Issue.record("advice accepted: \(lead)") }
        #expect(!LeadVerifier.framingVocabulary.contains("should"))
    }

    @Test func allowedNumbersDependOnTheRoute() {
        // Ayah routes: 55 plus every retrieved passage's ayah (a related answer may name ayah 52); not 14.
        let related = passages + [Passage(source: .saheehTranslation, ayah: 52, text: "Within each of the two are a pair of gushing springs.")]
        #expect(LeadVerifier.verify(lead: "Ayah 13 of surah 55 below asks which favours you deny.", passages: related, question: question, anchorAyah: 13) == .accepted)
        #expect(LeadVerifier.verify(lead: "Ayah 52 below is about two springs.", passages: related, question: question, anchorAyah: 13) == .accepted)
        #expect(LeadVerifier.verify(lead: "Ayah 14 below is about two springs.", passages: related, question: question, anchorAyah: 13) == .rejected("mentions a number not retrieved: 14"))
        // General route: each Quran passage's surah and ayah; 55 is not automatically allowed.
        let general = [Passage(id: "saheeh-1947-cited:112:1", source: .saheehCited, surah: 112, ayah: 1, text: "Say, He is Allah, who is One,", sourceLine: "Quran 112:1 · x"),
                       Passage(id: "jamhara-en:1#definition", source: .jamharaEnglish, surah: 0, ayah: 0, text: "Setting Allah apart in all that belongs to Him alone.", sourceLine: "y")]
        #expect(LeadVerifier.verify(lead: "Quran 112:1 below says He is One.", passages: general, question: "what is tawhid", anchorAyah: 13, route: .general) == .accepted)
        #expect(LeadVerifier.verify(lead: "Surah 55 is below.", passages: general, question: "what is tawhid", anchorAyah: 13, route: .general) == .rejected("mentions a number not retrieved: 55"))
        #expect(LeadVerifier.verify(lead: "Ayah 0 is below.", passages: general, question: "what is tawhid", anchorAyah: 13, route: .general) == .rejected("mentions a number not retrieved: 0"))
    }

    // MARK: Directive 4 part D (5 Oct) - from the leads audit. The rejected examples are real accepted
    // leads from the day-5 runs (g02, g09, g10, a23, run3 g15), against synthetic passages here.

    @Test func rejectsMetaTextNewlinesAndQuestions() {
        #expect(verify("Here is the lead-in for the Quran reading app:\n\nThe favours of your Lord are put to jinn and men.") == .rejected("contains a newline"))
        #expect(verify("Here is the lead-in for the Quran reading app: the favours of your Lord are put to jinn and men.") == .rejected("meta text"))
        #expect(verify("Here's what the passages say about the favours.") == .rejected("meta text"))
        #expect(verify("The passages below give a lead in to the favours.") == .rejected("meta text"))
        #expect(verify("Which favours of your Lord would you then deny?") == .rejected("ends with a question"))
    }

    @Test func rejectsALeadThatSpeaksForASource() {
        // g09: "The Quran states that paradise is an eternal place of bliss." over a Jamhara-only passage.
        if case .rejected(let r) = verify("The Quran states that the favours are for jinn and men.") { #expect(r.hasPrefix("speaks for a source")) } else { Issue.record("accepted") }
        // g10: "The verse you are looking at describes the meeting of the two seas."
        if case .rejected(let r) = verify("The verse you are looking at describes the favours of your Lord.") { #expect(r.hasPrefix("speaks for a source")) } else { Issue.record("accepted") }
        for lead in ["This ayah says the favours are many.", "The surah teaches the favours of your Lord.", "Allah says the jinn and men deny the favours.", "God tells the jinn about the favours."] {
            if case .rejected(let r) = verify(lead) { #expect(r.hasPrefix("speaks for a source"), "\(lead)") } else { Issue.record("accepted: \(lead)") }
        }
        // Naming the source as the thing shown is still fine.
        #expect(verify("The translation and the Mukhtasar passage below give this ayah’s question for jinn and men, on your Lord’s favours.") == .accepted)
    }

    @Test func rejectsCopyingSixOrMoreConsecutiveWordsFromAPassage() {
        // a23: the lead was the Mukhtasar refrain verbatim; run3 g15 copied a Jamhara definition whole.
        #expect(verify("A question put to jinn and men about the many favours of Allah that they deny.") == .rejected("copies 6+ consecutive words from a passage"))
        #expect(verify("The passage says which favours of your Lord would you then deny, to jinn and men.") == .rejected("copies 6+ consecutive words from a passage"))
        // Five consecutive words are allowed ("many favours of Allah that" would be five; the lead uses four).
        #expect(verify("The passages put a question about many favours of Allah to the jinn.") == .accepted)
        #expect(LeadVerifier.maxCopiedRun == 5)
    }

    @Test func stemmingTreatsInflectionsAsTheSameWord() {
        #expect(LeadVerifier.stem("favours") == LeadVerifier.stem("favour"))
        #expect(LeadVerifier.stem("denies") == LeadVerifier.stem("deny"))
        #expect(LeadVerifier.stem("repeated") == LeadVerifier.stem("repeat"))
        #expect(LeadVerifier.stem("Lord’s".lowercased()) == "lord")
    }
}

/// Lead generation on this Mac, report-only: how many model leads the verifier accepts.
struct LeadGenerationReport {
    @Test func foundationModelsLeadsThroughTheVerifier() async throws {
        guard Sources.present else { withKnownIssue("sources absent") { Issue.record("local source files not present") }; return }
        guard let writer = LeadSupport.writer() else { print("LEADS: NOT RUN — Foundation Models \(FoundationModelsSupport.availability)"); return }
        let corpus = try Corpus.load(Sources.files)
        let sources = try? AskSourceSet.load(root: Sources.repoRoot)
        let engine = AskEngine(corpus: corpus, router: RuleBasedRouter(), leadWriter: writer, sources: sources)
        // The first eight are the day-2 probes (ayah routes); the last two are general-route cards (3c-2).
        let probes: [(String, Int)] = [("What does this ayah mean?", 1), ("What does the word \"balance\" mean?", 7), ("why does this repeat", 13), ("What is this verse saying about the sun and the moon?", 5), ("Who gets the two gardens?", 46), ("What is the lesson here?", 29), ("what does this mean", 33), ("Which other verses are similar?", 11),
                                       ("What is tawhid?", 13), ("Why is alcohol forbidden in Islam?", 13)]
        var accepted = 0, rejected: [String] = [], errors = 0
        for (q, n) in probes {
            let a = await engine.ask(q, anchorAyah: n)
            if a.leadStatus == "accepted" { accepted += 1; print("LEAD OK   ayah \(n) [\(a.route.rawValue)]: \(a.lead)") }
            else if a.leadStatus.hasPrefix("rejected") {
                rejected.append(a.leadStatus); print("LEAD REJ  ayah \(n) [\(a.route.rawValue)]: \(a.leadStatus)")
                // The engine discards a rejected candidate; a SEPARATE call shows what the model tends to write.
                if let sample = try? await writer.lead(question: q, passages: a.passages, anchorAyah: n, route: a.route) { print("          sample candidate (separate call): \(sample.replacingOccurrences(of: "\n", with: " ⏎ "))") }
            }
            else { errors += 1; print("LEAD ERR  ayah \(n): \(a.leadStatus)") }
            // Whatever happened, the passages are untouched and the answer is still sourced.
            #expect(!a.passages.isEmpty && a.citations == a.passages.map(\.id))
            if a.leadStatus != "accepted" { #expect(a.lead.isEmpty) }
        }
        print("LEADS: accepted \(accepted)/\(probes.count), rejected \(rejected.count), errors \(errors)")
    }
}
