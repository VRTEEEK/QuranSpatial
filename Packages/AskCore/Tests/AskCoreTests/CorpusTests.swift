import Foundation
import Testing
@testable import AskCore

/// The source files are local (gitignored). When absent, the tests that need them are known
/// issues, not failures - the same pattern as the app's tests.
enum Sources {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static var files: SourceFiles { SourceFiles.inRepository(root: repoRoot) }
    static var present: Bool { FileManager.default.fileExists(atPath: files.translation.path) && FileManager.default.fileExists(atPath: files.meaning.path) }
    static func whenPresent(_ body: () throws -> Void) throws {
        try withKnownIssue(isIntermittent: false) { try body() } when: { !present }
    }
}

struct CorpusTests {
    @Test func locatesTheRepositoryFromThePackageDirectory() {
        let found = SourceFiles.locateRepository(startingAt: Sources.repoRoot.appendingPathComponent("Packages/AskCore"))
        #expect(found != nil)
        #expect(found?.translation.lastPathComponent == "en-rahman-saheeh-1947.json")
    }

    @Test func loadsAllSeventyEightAyatWithPinnedHashes() throws {
        try Sources.whenPresent {
            let corpus = try Corpus.load(Sources.files)
            #expect(corpus.ayahCount == 78)
            #expect(corpus[0] == nil)
            for n in 1...78 {
                let r = try #require(corpus[n])
                #expect(r.translation?.text.isEmpty == false)
                #expect(r.meaning?.text.isEmpty == false)
                #expect(r.translation?.id == "saheeh-1947:55:\(n)")
                #expect(r.meaning?.id == "mukhtasar-27824:55:\(n)")
            }
            let t = try Corpus.loadExtracted(Sources.files.translation)
            #expect(t.textSHA256 == "c4987b6aa72aaba539fc8d9163a72bdba60cc20f76dcdde1ac85e9e2a5baf90a")
            let m = try Corpus.loadExtracted(Sources.files.meaning)
            #expect(m.textSHA256 == "b2d59ffa4409bbb985a910c78046a32de5859a78f2494d812c9e31e1203bc5ad")
            #expect(m.rawSHA256 == "4790ae49369d80d40c63ed8f197c0d6db909bcee23d63288fb12159cab4eccdc")
        }
    }

    @Test func footnotesComeFromTheRawFileAndTieToTheBundledText() throws {
        try Sources.whenPresent {
            let corpus = try Corpus.load(Sources.files)
            try withKnownIssue("raw 1947.json not in scratch/", isIntermittent: false) {
                #expect(corpus.footnotesLoaded)
                let r13 = try #require(corpus[13])
                #expect(r13.footnotes.count == 1)
                #expect(r13.footnotes.first?.id == "saheeh-1947-footnote:55:13#1")
                #expect(r13.footnotes.first?.text.isEmpty == false)
                #expect(r13.footnotes.first?.text.hasPrefix("[") == false)
                #expect(corpus[1]?.footnotes.isEmpty == true)
            } when: { !corpus.footnotesLoaded }
        }
    }

    @Test func aCorruptedExtractedFileIsRefused() throws {
        let json = """
        {"edition":"x","sourceBook":1,"sourceURL":"u","rawSHA256":"r","extractionRules":[],
         "textSHA256":"0000000000000000000000000000000000000000000000000000000000000000",
         "ayat":[{"ayah":1,"text":"a"}]}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("askcore-corrupt-\(UUID()).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: CorpusError.self) { try Corpus.loadExtracted(url) }
    }

    @Test func relatedIndexCarriesReferencesOnlyAndCoversTheThreeAnchors() throws {
        let data = try Data(contentsOf: Sources.files.related!)
        let index = try JSONDecoder().decode(RelatedIndex.self, from: data)
        #expect(index.related(to: 11) == [52, 68])
        #expect(index.related(to: 52) == [11, 68])
        #expect(index.related(to: 68) == [11, 52])
        #expect(index.related(to: 13) == [])
        // No text: the file is numbers, names and hashes only.
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("deny") && !text.contains("favor"))
    }
}
