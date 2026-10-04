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
    @Test func decisionsFollowTheRoute() {
        #expect(AskEngine.decision(for: .ruling) == .referred)
        #expect(AskEngine.decision(for: .offTopic) == .declined)
        for r in [QuestionRoute.meaning, .word, .repetition, .related, .unclear] { #expect(AskEngine.decision(for: r) == .answered) }
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
        #expect(none.passages.map(\.ayah) == [13])
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
