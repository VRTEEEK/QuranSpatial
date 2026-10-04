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
        #expect(verify("The translation and the Mukhtasar passage below give this ayah’s question to jinn and men about the favours of your Lord.") == .accepted)
        #expect(verify("Here is what the sources say about the favours you are asked to deny.") == .accepted)
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
        let engine = AskEngine(corpus: corpus, router: RuleBasedRouter(), leadWriter: writer)
        let probes: [(String, Int)] = [("What does this ayah mean?", 1), ("What does the word \"balance\" mean?", 7), ("why does this repeat", 13), ("What is this verse saying about the sun and the moon?", 5), ("Who gets the two gardens?", 46), ("What is the lesson here?", 29), ("what does this mean", 33), ("Which other verses are similar?", 11)]
        var accepted = 0, rejected: [String] = [], errors = 0
        for (q, n) in probes {
            let a = await engine.ask(q, anchorAyah: n)
            if a.leadStatus == "accepted" { accepted += 1; print("LEAD OK   ayah \(n): \(a.lead)") }
            else if a.leadStatus.hasPrefix("rejected") { rejected.append(a.leadStatus); print("LEAD REJ  ayah \(n): \(a.leadStatus)") }
            else { errors += 1; print("LEAD ERR  ayah \(n): \(a.leadStatus)") }
            // Whatever happened, the passages are untouched and the answer is still sourced.
            #expect(!a.passages.isEmpty && a.citations == a.passages.map(\.id))
            if a.leadStatus != "accepted" { #expect(a.lead.isEmpty) }
        }
        print("LEADS: accepted \(accepted)/\(probes.count), rejected \(rejected.count), errors \(errors)")
    }
}
