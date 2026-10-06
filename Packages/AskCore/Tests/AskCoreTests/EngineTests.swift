import Foundation
import Testing
@testable import AskCore

struct RuleRouterTests {
    let router = RuleBasedRouter()

    @Test(arguments: [
        ("What does this ayah mean?", QuestionRoute.meaning),
        ("What does the word \"deny\" mean here?", .word),
        ("Why does this verse repeat so many times?", .repetition),
        ("Where else is this mentioned in the surah?", .related),
        ("Is it haram to skip this ayah?", .ruling),
        ("What is the weather in Riyadh?", .offTopic),
        ("??", .unclear),
    ])
    func routes(question: String, expected: QuestionRoute) async throws {
        #expect(try await router.route(question, anchorAyah: 13) == expected)
    }
}

struct EngineTests {
    @Test func decisionsFollowTheRouteAndTheData() throws {
        guard Sources.present else { withKnownIssue("sources absent") { Issue.record("local source files not present") }; return }
        let corpus = try Corpus.load(Sources.files)
        func d(_ r: QuestionRoute, _ ayah: Int = 13) -> Decision { AskEngine.decision(for: r, anchorAyah: ayah, corpus: corpus) }
        #expect(d(.ruling) == .referred)
        #expect(d(.offTopic) == .declined)
        for r in [QuestionRoute.meaning, .word, .unclear] { #expect(d(r) == .answered) }
        #expect(d(.repetition) == .answeredInPart)
        #expect(d(.repetition, 1) == .answeredInPart)
        #expect(d(.related, 11) == .answered && d(.related, 52) == .answered && d(.related, 68) == .answered)
        #expect(d(.related, 13) == .answeredInPart && d(.related, 1) == .answeredInPart)
    }

    /// Day 2 decisions: the repetition route shows what the sources say and states the gap; the
    /// related route answers only where the dump has data.
    @Test func repetitionAnswersInPartWithTheFootnoteAndThePlainStatement() async throws {
        guard Sources.present else { withKnownIssue("sources absent") { Issue.record("local source files not present") }; return }
        let corpus = try Corpus.load(Sources.files)
        let engine = AskEngine(corpus: corpus, router: RuleBasedRouter())
        let a = await engine.ask("why does this keep repeating", anchorAyah: 21)
        #expect(a.route == .repetition && a.decision == .answeredInPart)
        #expect(a.note == Retriever.repetitionNoteWithLink && a.note.hasPrefix(Retriever.repetitionNote))
        #expect(a.links == [Retriever.repetitionDorarLink])
        #expect(a.passages.first?.id == "saheeh-1947:55:21")
        #expect(a.citations.contains("mukhtasar-27824:55:21"))
        if corpus.footnotesLoaded { #expect(a.citations.contains("saheeh-1947-footnote:55:13#1")) }
        #expect(a.lead.isEmpty && a.leadStatus == "none: no lead writer")
        let r = await engine.ask("which other verses are similar to this one?", anchorAyah: 13)
        #expect(r.route == .related && r.decision == .answeredInPart && r.note == Retriever.relatedUnavailableNote)
        #expect(r.passages.map(\.ayah) == [13, 13])
    }

    @Test func answersCiteExactlyTheRetrievedPassagesAnchorFirst() async throws {
        guard Sources.present else { withKnownIssue("sources absent") { Issue.record("local source files not present") }; return }
        let corpus = try Corpus.load(Sources.files)
        let engine = AskEngine(corpus: corpus, router: RuleBasedRouter())
        let a = await engine.ask("What does this ayah mean?", anchorAyah: 13)
        #expect(a.decision == .answered)
        #expect(a.passages.first?.ayah == 13)
        #expect(a.citations == a.passages.map(\.id))
        #expect(a.citations.contains("saheeh-1947:55:13") && a.citations.contains("mukhtasar-27824:55:13"))
        #expect(a.lead.isEmpty)
        let r = await engine.ask("Is it haram to skip this ayah?", anchorAyah: 13)
        #expect(r.decision == .referred && r.passages.isEmpty && r.citations.isEmpty)
        let d = await engine.ask("What is the weather today?", anchorAyah: 13)
        #expect(d.decision == .declined && d.citations.isEmpty)
        let rel = await engine.ask("Which other verses are similar to this one?", anchorAyah: 11)
        #expect(rel.route == .related)
        #expect(rel.passages.map(\.ayah) == [11, 52, 68])
        #expect(rel.passages.allSatisfy { $0.source == .saheehTranslation })
        let none = await engine.ask("Which other verses are similar to this one?", anchorAyah: 13)
        #expect(none.decision == .answeredInPart)
        #expect(none.passages.map(\.ayah) == [13, 13])
    }

    /// Every passage in every answer is byte-identical to a corpus text - nothing is rewritten.
    @Test func passagesAreVerbatimCorpusText() async throws {
        guard Sources.present else { withKnownIssue("sources absent") { Issue.record("local source files not present") }; return }
        let corpus = try Corpus.load(Sources.files)
        let engine = AskEngine(corpus: corpus, router: RuleBasedRouter())
        for (q, n) in [("What does this mean?", 33), ("What does the word \"balance\" mean?", 7), ("why does it repeat?", 77)] {
            let a = await engine.ask(q, anchorAyah: n)
            #expect(!a.passages.isEmpty)
            for p in a.passages {
                let record = try #require(corpus[p.ayah])
                let candidates = [record.translation, record.meaning].compactMap { $0 } + record.footnotes
                #expect(candidates.contains { Array($0.text.utf8) == Array(p.text.utf8) && $0.id == p.id })
            }
        }
    }
}
