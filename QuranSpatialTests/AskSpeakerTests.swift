//
//  AskSpeakerTests.swift
//  QuranSpatialTests
//
//  The spoken script is pure: display model in, English lines out, Arabic never.
//

import Testing
@testable import QuranSpatial

struct AskSpeakerTests {
    private func display(decision: String, lead: String = "", passages: [(String, String)] = [], note: String = "",
                         links: [String] = []) -> AskDisplay {
        AskDisplay(question: "q", decision: decision, lead: lead,
                   passages: passages.enumerated().map { AskDisplay.Line(id: "\($0.offset)", text: $0.element.0, sourceLine: $0.element.1) },
                   note: note, routerLine: "", engineNotice: "", links: links)
    }

    @Test func answeredSpeaksLabelSummaryPassagesSourcesAndDisclaimerInOrder() {
        let d = display(decision: "answered", lead: "The lead.",
                        passages: [("Passage one.", "Quran 55:13 · Saheeh International, Quran.com"),
                                   ("Passage two.", "Al-Mukhtasar fi Tafsir al-Quran (English), via Quranpedia, book 27824")],
                        note: "A note.", links: ["https://example.org/x"])
        let s = AskSpeechScript.spokenLines(for: d, referralNote: "")
        #expect(s.spoken == ["From the sources.", "On-device AI summary:", "The lead.",
                             "Passage one.", "From Saheeh International.",
                             "Passage two.", "From Al-Mukhtasar fi Tafsir al-Quran.",
                             "Ask is AI-assisted and is not a scholar."])
        #expect(s.skipped.isEmpty)          // links are never candidates at all
    }

    @Test func answeredWithoutALeadSkipsTheSummaryIntro() {
        let d = display(decision: "answered-in-part", passages: [("P.", "Quran 55:1 · Saheeh International, x")])
        let s = AskSpeechScript.spokenLines(for: d, referralNote: "").spoken
        #expect(s == ["From the sources.", "P.", "From Saheeh International.", "Ask is AI-assisted and is not a scholar."])
    }

    @Test func referredSpeaksThePanelLineThenPassagesThenDisclaimer() {
        let line = AskPanelView.referredWithPassagesNote
        let d = display(decision: "referred", passages: [("General.", "Al-Mukhtasar fi Tafsir al-Quran (English), via Quranpedia")], note: "engine note")
        let s = AskSpeechScript.spokenLines(for: d, referralNote: line).spoken
        #expect(s == ["Referred to a scholar.", line, "General.", "From Al-Mukhtasar fi Tafsir al-Quran.",
                      "Ask is AI-assisted and is not a scholar."])
        let bare = AskSpeechScript.spokenLines(for: display(decision: "referred", note: "engine note"), referralNote: "engine note").spoken
        #expect(bare == ["Referred to a scholar.", "engine note", "Ask is AI-assisted and is not a scholar."])
    }

    @Test func notCoveredAndDeclinedSpeakLabelAndNoteOnly() {
        let nc = AskSpeechScript.spokenLines(for: display(decision: "not-covered", note: "Nothing here."), referralNote: "").spoken
        #expect(nc == ["Not covered by this app's sources.", "Nothing here."])
        let dec = AskSpeechScript.spokenLines(for: display(decision: "declined"), referralNote: "").spoken
        #expect(dec == ["Not about this ayah."])
    }

    @Test func arabicScriptLinesAreSkippedAndReported() {
        // The Arabic here is a source NAME fragment as the Jamhara source line carries it, not Quran text.
        let d = display(decision: "answered",
                        passages: [("English passage.", "Jamhara (\u{0645}\u{0648}\u{0633}), English, islamic-content.com"),
                                   ("\u{0628}\u{0633}\u{0645} mixed line", "Quran 55:1 · Saheeh International, x")])
        let s = AskSpeechScript.spokenLines(for: d, referralNote: "")
        // The source short form cut the parenthetical off, so that line is clean; the mixed passage is dropped.
        #expect(s.spoken == ["From the sources.", "English passage.", "From Jamhara.",
                             "From Saheeh International.", "Ask is AI-assisted and is not a scholar."])
        #expect(s.skipped.count == 1)
        #expect(AskSpeechScript.containsArabicScript(s.skipped[0]))
        #expect(AskSpeechScript.containsArabicScript("\u{FEFB}"))         // presentation form
        #expect(!AskSpeechScript.containsArabicScript("plain English, 55:13"))
    }

    @Test func linksAreNeverSpoken() {
        #expect(AskSpeechScript.looksLikeLink("see https://tanzil.net/"))
        let d = display(decision: "not-covered", note: "More at www.example.org")
        let s = AskSpeechScript.spokenLines(for: d, referralNote: "")
        #expect(s.spoken == ["Not covered by this app's sources."])
        #expect(s.skipped == ["More at www.example.org"])
    }

    @Test func shortSourceNames() {
        #expect(AskSpeechScript.shortSource("Quran 55:13 · Saheeh International, Quran.com") == "Saheeh International")
        #expect(AskSpeechScript.shortSource("Al-Mukhtasar fi Tafsir al-Quran (English), via Quranpedia, book 27824") == "Al-Mukhtasar fi Tafsir al-Quran")
        #expect(AskSpeechScript.shortSource("Jamhara (x), English, islamic-content.com") == "Jamhara")
    }
}
