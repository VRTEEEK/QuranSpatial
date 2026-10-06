import Foundation
import Testing
@testable import AskCore

/// Loaders for the Ask card data. Fixtures are SYNTHETIC - made-up words, hashed in the test - so no
/// source text is in the repository. The committed cards file is checked for shape; the local-only
/// files, when present, are checked for consistency with it.
struct AskSourcesTests {
    static func temp(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("asksources-\(UUID()).json")
        try json.write(to: url, atomically: true, encoding: .utf8); return url
    }
    static func sha(_ s: String) -> String { Corpus.sha256Hex(s) }

    // MARK: cards

    static let cardsFixture = """
    {"note":"fixture","cardCount":3,"cards":[
     {"id":"term-1-alpha","kind":"term","level":"A","title":"Alpha","jamharaIDs":[1],"quranRefs":[],"keywords":["alpha","eye"],"phrasings":["a?","b?","c?"],"answersRuling":false},
     {"id":"general-g9-beta","kind":"general","level":"C","title":"Beta","jamharaIDs":[1,2],"quranRefs":["112:1-4","55:1"],"keywords":["drinking alcohol"],"phrasings":["a?","b?","c?"],"answersRuling":true},
     {"id":"gap-gamma","kind":"gap","level":"B","title":"Gamma","jamharaIDs":[],"quranRefs":[],"keywords":["gamma"],"phrasings":["a?","b?","c?"],"answersRuling":false,"arabicLink":"https://example.invalid/x"}]}
    """

    @Test func loadsASyntheticCardsFile() throws {
        let cards = try AskCards.load(try Self.temp(Self.cardsFixture))
        #expect(cards.count == 3)
        #expect(cards["general-g9-beta"]?.level == .C)
        #expect(cards["general-g9-beta"]?.answersRuling == true)
        #expect(cards["gap-gamma"]?.arabicLink == "https://example.invalid/x")
        #expect(cards["term-1-alpha"]?.kind == .term)
    }

    @Test func refusesACardsFileWhoseCountOrShapeIsWrong() throws {
        let wrongCount = Self.cardsFixture.replacingOccurrences(of: "\"cardCount\":3", with: "\"cardCount\":4")
        #expect(throws: AskSourcesError.self) { try AskCards.load(try Self.temp(wrongCount)) }
        let gapWithoutLink = Self.cardsFixture.replacingOccurrences(of: ",\"arabicLink\":\"https://example.invalid/x\"", with: "")
        #expect(throws: AskSourcesError.self) { try AskCards.load(try Self.temp(gapWithoutLink)) }
        // A general card may carry a link (A2); a term card may not.
        let generalWithLink = Self.cardsFixture.replacingOccurrences(of: "\"answersRuling\":true}", with: "\"answersRuling\":true,\"arabicLink\":\"https://example.invalid/g\"}")
        #expect(try AskCards.load(try Self.temp(generalWithLink))["general-g9-beta"]?.arabicLink == "https://example.invalid/g")
        let badRef = Self.cardsFixture.replacingOccurrences(of: "\"112:1-4\"", with: "\"112:4-1\"")
        #expect(throws: AskSourcesError.self) { try AskCards.load(try Self.temp(badRef)) }
    }

    @Test func keywordsMatchWholeWordsOnly() {
        #expect(AskCards.matchesKeyword("eye", in: "which eye was that"))
        #expect(!AskCards.matchesKeyword("eye", in: "my eyes are hurting"))
        #expect(AskCards.matchesKeyword("Alpha", in: "what is alpha?"))
        #expect(!AskCards.matchesKeyword("alpha", in: "alphabet soup"))
        #expect(AskCards.matchesKeyword("drinking alcohol", in: "is drinking alcohol allowed"))
        #expect(!AskCards.matchesKeyword("drinking alcohol", in: "is drinking alcoholic"))
        #expect(AskCards.matchesKeyword("ar-rahman", in: "who is ar-rahman?"))
    }

    @Test func quranRefsExpand() {
        #expect(QuranRef.expand("112:1-4")?.map(\.ayah) == [1, 2, 3, 4])
        #expect(QuranRef.expand("55:1")?.count == 1)
        #expect(QuranRef.expand("5:90-91")?.map { "\($0.surah):\($0.ayah)" } == ["5:90", "5:91"])
        #expect(QuranRef.expand("115:1") == nil)
        #expect(QuranRef.expand("55") == nil)
        #expect(QuranRef.expand("55:3-2") == nil)
    }

    // MARK: Jamhara

    static func jamharaFixture(corruptEntry: Bool = false, corruptFile: Bool = false) -> String {
        let e1 = "Alpha\nA made-up definition.\nA made-up explanation.", e2 = "Beta\nAnother made-up definition.\n"
        let h1 = corruptEntry ? String(repeating: "0", count: 64) : sha(e1)
        let fileHash = corruptFile ? String(repeating: "1", count: 64) : sha(e1 + "\n" + e2)
        return """
        {"source":"fixture","urlPattern":"u","extractionRules":[],"textSHA256":"\(fileHash)","entries":[
         {"id":1,"url":"u1","retrievedAt":"t","rawSHA256":"r","title":"Alpha","definitionHeading":"x","definition":"A made-up definition.","explanation":"A made-up explanation.","textSHA256":"\(h1)"},
         {"id":2,"url":"u2","retrievedAt":"t","rawSHA256":"r","title":"Beta","definitionHeading":"y","definition":"Another made-up definition.","explanation":"","textSHA256":"\(sha(e2))"}]}
        """
    }

    @Test func loadsJamharaEntriesWhoseHashesHold() throws {
        let terms = try JamharaTerms.load(try Self.temp(Self.jamharaFixture()))
        #expect(terms.count == 2)
        #expect(terms[1]?.title == "Alpha")
        #expect(terms[2]?.explanation == "")
        #expect(terms[3] == nil)
    }

    @Test func refusesJamharaWhenAnEntryOrTheFileHashIsWrong() throws {
        #expect(throws: AskSourcesError.self) { try JamharaTerms.load(try Self.temp(Self.jamharaFixture(corruptEntry: true))) }
        #expect(throws: AskSourcesError.self) { try JamharaTerms.load(try Self.temp(Self.jamharaFixture(corruptFile: true))) }
    }

    // MARK: cited Saheeh

    static func citedFixture(hash: String? = nil) -> String {
        let texts = ["one", "two", "three"]
        return """
        {"edition":"fixture","sourceBook":1,"sourceURL":"u","rawSHA256":"raw","extractionRules":[],"refs":["7:1-2","9:5"],
         "textSHA256":"\(hash ?? sha(texts.joined(separator: "\n")))",
         "ayat":[{"surah":7,"ayah":1,"text":"one"},{"surah":7,"ayah":2,"text":"two"},{"surah":9,"ayah":5,"text":"three"}]}
        """
    }

    @Test func loadsCitedAyatAndResolvesRefs() throws {
        let cited = try CitedSaheeh.load(try Self.temp(Self.citedFixture()), expectedRawSHA256: "raw")
        #expect(cited.count == 3)
        #expect(cited.passages(for: "7:1-2")?.map(\.id) == ["saheeh-1947:7:1", "saheeh-1947:7:2"])
        #expect(cited.passage(surah: 9, ayah: 5)?.text == "three")
        #expect(cited.passages(for: "9:6") == nil)
        #expect(throws: AskSourcesError.self) { try CitedSaheeh.load(try Self.temp(Self.citedFixture()), expectedRawSHA256: "other") }
        #expect(throws: AskSourcesError.self) { try CitedSaheeh.load(try Self.temp(Self.citedFixture(hash: String(repeating: "0", count: 64)))) }
    }

    // MARK: the committed file, and the local files when present

    @Test func committedCardsFileHasTheApprovedShapeAndNoSourceText() throws {
        let paths = SourceFiles.askSources(root: Sources.repoRoot)
        let cards = try AskCards.load(paths.cards)
        #expect(cards.count == 30)
        #expect(cards.cards.filter { $0.kind == .term }.count == 21)
        #expect(cards.cards.filter { $0.kind == .general }.count == 8)
        #expect(cards.cards.filter { $0.kind == .gap }.count == 1)
        // Directive 4 (A2): the authorship card is a sourced general card that keeps its Arabic link.
        let authorship = try #require(cards["gap-quran-authorship"])
        #expect(authorship.kind == .general && authorship.jamharaIDs == [7771] && authorship.level == .B && authorship.arabicLink == "https://dawa.center/file/7937")
        #expect(cards.cards.filter(\.answersRuling).map(\.id) == ["general-g3-alcohol-forbidden"])
        #expect(cards["term-5172-ar-rahman"]?.quranRefs == ["55:1"])
        #expect(cards["general-g6-why-scholars-differ"]?.level == .C)
        // No Arabic script and no source passages: the file is references only.
        let text = try String(contentsOf: paths.cards, encoding: .utf8)
        #expect(text.range(of: #"[\u{0600}-\u{06FF}]"#, options: .regularExpression) == nil)
        #expect(!text.contains("Singling") && !text.contains("favor"))
        // The whole-word rule is stated in the file, where the engine will read it.
        #expect(text.contains("WHOLE WORDS ONLY"))
    }

    @Test func localJamharaAndCitedFilesCoverEveryCardReference() throws {
        let paths = SourceFiles.askSources(root: Sources.repoRoot)
        let cards = try AskCards.load(paths.cards)
        try withKnownIssue("local Jamhara / cited files absent (run tools/fetch-sources.py)", isIntermittent: false) {
            let terms = try JamharaTerms.load(try #require(paths.jamhara))
            #expect(terms.count == 22)
            for c in cards.cards { for id in c.jamharaIDs { #expect(terms[id] != nil, "\(c.id) -> Jamhara \(id)") } }
            let translation = try Corpus.loadExtracted(Sources.files.translation)
            let cited = try CitedSaheeh.load(try #require(paths.cited), expectedRawSHA256: translation.rawSHA256)
            #expect(cited.count == 11)
            for c in cards.cards { for r in c.quranRefs { #expect(cited.passages(for: r) != nil, "\(c.id) -> \(r)") } }
            // 55:1 here must be byte-identical to 55:1 in the Surah 55 file: same raw file, same rules.
            let a = cited.passage(surah: 55, ayah: 1)?.text, b = translation.ayat.first { $0.ayah == 1 }?.text
            #expect(a != nil && a.map { Array($0.utf8) } == b.map { Array($0.utf8) })
        } when: { paths.jamhara == nil || paths.cited == nil || !Sources.present }
    }
}
