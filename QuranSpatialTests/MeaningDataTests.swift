//
//  MeaningDataTests.swift
//  QuranSpatialTests
//
//  The Meaning panel's data (Al-Mukhtasar, Quranpedia book 27824), WITHOUT any of its text in
//  the repo: identity pinned by the raw file's SHA-256 and the extracted text's, as for the
//  translation. The file is gitignored and local; absence is a supported state, so the tests
//  that need it are known issues until it is bundled.
//

import Foundation
import Testing
@testable import QuranSpatial

struct MeaningDataTests {

    /// Downloaded 2026-10-03T12:33:58Z from the source URL; raw file SHA-256.
    private let pinnedRawSHA256 = "4790ae49369d80d40c63ed8f197c0d6db909bcee23d63288fb12159cab4eccdc"
    /// SHA-256 over the 78 extracted passages joined by "\n". Changing the text changes this.
    private let pinnedTextSHA256 = "b2d59ffa4409bbb985a910c78046a32de5859a78f2494d812c9e31e1203bc5ad"

    private let refrains = [13, 16, 18, 21, 23, 25, 28, 30, 32, 34, 36, 38, 40, 42, 45, 47, 49, 51,
                            53, 55, 57, 59, 61, 63, 65, 67, 69, 71, 73, 75, 77]

    private var isBundled: Bool {
        Bundle.main.url(forResource: RecitationMeaning.resourceName, withExtension: "json") != nil
    }

    private func whenBundled(_ body: () throws -> Void) throws {
        try withKnownIssue(isIntermittent: false) { try body() } when: { !isBundled }
    }

    @Test func fileIsTheMukhtasarEditionWithThePinnedHashes() throws {
        try whenBundled {
            let file = try RecitationTranslationFile.loadFromBundle(resourceName: RecitationMeaning.resourceName)
            #expect(file.sourceBook == RecitationMeaning.sourceBook)
            #expect(file.sourceBook == 27824)
            #expect(file.rawSHA256 == pinnedRawSHA256)
            #expect(file.textSHA256 == pinnedTextSHA256)
            #expect(file.computedTextSHA256 == pinnedTextSHA256)
            #expect(file.textIsIntact)
        }
    }

    @Test func fileCoversEveryAyahExactlyOnceAndNothingForTheIntro() throws {
        try whenBundled {
            let file = try RecitationTranslationFile.loadFromBundle(resourceName: RecitationMeaning.resourceName)
            #expect(file.ayat.map(\.ayah) == Array(1...78))
            #expect(file.text(forSegmentIndex: 0) == nil)
            for index in 1...78 {
                let text = try #require(file.text(forSegmentIndex: index))
                #expect(!text.isEmpty)
                #expect(isByteIdentical(text, text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    /// The source's own anomaly, pinned so a regenerated file that "fixes" it is noticed:
    /// every refrain carries ayah 77's passage verbatim, and no other two ayat share a text.
    @Test func allThirtyOneRefrainsCarryAyah77sPassageVerbatim() throws {
        try whenBundled {
            let file = try RecitationTranslationFile.loadFromBundle(resourceName: RecitationMeaning.resourceName)
            let p77 = try #require(file.text(forSegmentIndex: 77))
            for ayah in refrains {
                let text = try #require(file.text(forSegmentIndex: ayah))
                #expect(isByteIdentical(text, p77), "ayah \(ayah)")
            }
            let others = file.ayat.filter { !refrains.contains($0.ayah) }.map(\.text)
            #expect(others.count == 47)
            #expect(Set(others).count == 47)
        }
    }

    /// No numbering prefix survives extraction, and nothing in the surah had markup to remove.
    @Test func noPassageStartsWithANumberingPrefixOrContainsMarkup() throws {
        try whenBundled {
            let file = try RecitationTranslationFile.loadFromBundle(resourceName: RecitationMeaning.resourceName)
            for entry in file.ayat {
                #expect(entry.text.range(of: #"^\d+\. "#, options: .regularExpression) == nil, "ayah \(entry.ayah)")
                #expect(!entry.text.contains("<"), "ayah \(entry.ayah)")
                #expect(entry.text.range(of: #"\[\d+\]"#, options: .regularExpression) == nil, "ayah \(entry.ayah)")
            }
        }
    }

    @Test func absenceReadsAsUnavailableNotAsAnError() {
        #expect(RecitationTranslationFile.loadIfPresent(resourceName: "en-rahman-mukhtasar-missing") == nil)
        #expect(RecitationMeaning.unavailableText == "Meaning not available in this build")
        #expect(RecitationMeaning.sourceLine == "Al-Mukhtasar fi Tafsir al-Quran (English), via Quranpedia, book 27824")
    }

    /// The panel's lookup goes through the same accessor as the translation: intro has none.
    @Test func panelLookupHasNothingForTheIntro() {
        #expect(RecitationMeaning.passage(forSegmentIndex: 0) == nil)
    }
}
