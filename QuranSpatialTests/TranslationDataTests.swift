//
//  TranslationDataTests.swift
//  QuranSpatialTests
//
//  The English translation layer's data, WITHOUT any of its text in the repo. Identity is
//  pinned by two hashes: the raw Quranpedia file's and the extracted text's. A regenerated or
//  substituted file fails the second; a corrupted one fails both the loader and the second.
//
//  The file is gitignored and local. Its absence is a supported state, so every test that
//  needs it is a known issue when it is not bundled - the same pattern as the ship font -
//  and starts guarding the moment the file is present.
//

import CoreText
import Foundation
import Testing
@testable import QuranSpatial

struct TranslationDataTests {

    /// Decisions (human), 2026-09-29: Quranpedia book 1947, raw file SHA-256.
    private let pinnedRawSHA256 = "8c08a8332fae34788f556e5d13a78fe45f68f607cf7a2dabd6596a7fad573978"
    /// Pinned 2026-10-02 from the extraction script's output: SHA-256 over the 78 ayah texts
    /// joined by "\n". Changing the text, in any way, changes this.
    private let pinnedTextSHA256 = "c4987b6aa72aaba539fc8d9163a72bdba60cc20f76dcdde1ac85e9e2a5baf90a"

    private var isBundled: Bool {
        Bundle.main.url(forResource: RecitationTranslationFile.resourceName, withExtension: "json") != nil
    }

    private func whenBundled(_ body: () throws -> Void) throws {
        try withKnownIssue(isIntermittent: false) {
            try body()
        } when: {
            !isBundled
        }
    }

    // MARK: Identity

    @Test func fileIsTheCanonicalEditionWithThePinnedHashes() throws {
        try whenBundled {
            let file = try RecitationTranslationFile.loadFromBundle()
            #expect(file.sourceBook == 1947)
            #expect(file.rawSHA256 == pinnedRawSHA256)
            #expect(file.textSHA256 == pinnedTextSHA256)
            #expect(file.computedTextSHA256 == pinnedTextSHA256)
            #expect(file.textIsIntact)
        }
    }

    @Test func fileCoversEveryAyahExactlyOnceInOrderAndNothingForTheIntro() throws {
        try whenBundled {
            let file = try RecitationTranslationFile.loadFromBundle()
            #expect(file.ayat.map(\.ayah) == Array(1...78))
            #expect(file.text(forSegmentIndex: 0) == nil)
            for index in 1...78 {
                let text = try #require(file.text(forSegmentIndex: index))
                #expect(!text.isEmpty)
            }
            #expect(file.text(forSegmentIndex: 79) == nil)
        }
    }

    // MARK: Absence and corruption

    @Test func absenceIsASupportedStateNotAnError() {
        #expect(RecitationTranslationFile.loadIfPresent(resourceName: "en-does-not-exist") == nil)
        #expect(throws: RecitationTranslationFile.LoadError.absent) {
            try RecitationTranslationFile.loadFromBundle(resourceName: "en-does-not-exist")
        }
    }

    /// A file whose text does not hash to its own claim is refused, not displayed.
    @Test func aFileWhoseTextDoesNotMatchItsOwnHashIsRefused() throws {
        let json = """
        {"edition":"x","sourceBook":1,"sourceURL":"u","rawSHA256":"r","extractionRules":[],
         "textSHA256":"0000000000000000000000000000000000000000000000000000000000000000",
         "ayat":[{"ayah":1,"text":"a"}]}
        """
        let file = try JSONDecoder().decode(RecitationTranslationFile.self, from: Data(json.utf8))
        #expect(!file.textIsIntact)
        #expect(file.computedTextSHA256 == RecitationTranslationFile.sha256Hex("a"))
    }

    @Test func textHashIsOverAyatJoinedByNewline() throws {
        let json = """
        {"edition":"x","sourceBook":1,"sourceURL":"u","rawSHA256":"r","extractionRules":[],
         "textSHA256":"\(RecitationTranslationFile.sha256Hex("a\nb"))",
         "ayat":[{"ayah":1,"text":"a"},{"ayah":2,"text":"b"}]}
        """
        let file = try JSONDecoder().decode(RecitationTranslationFile.self, from: Data(json.utf8))
        #expect(file.textIsIntact)
    }

    // MARK: Rendering

    /// Rasterizing through the English path leaves every string byte-identical, exactly as
    /// `rasterizingDoesNotMutateTheText` asserts for the Arabic.
    @Test func rasterizingEnglishDoesNotMutateTheText() throws {
        try whenBundled {
            let before = try RecitationTranslationFile.loadFromBundle().ayat.map(\.text)
            for text in before {
                let raster = AyahTextureCache.english(
                    text, CGFloat(AyahPlaneGeometry.englishFontSizePixels),
                    AyahPlaneGeometry.englishMaxContentWidthPixels,
                    CGFloat(AyahPlaneGeometry.englishPaddingPixels))
                let r = try #require(raster)
                #expect(r.pixelSize.width > 0 && r.pixelSize.height > 0)
                #expect(r.lineCount >= 1)
                #expect(Int(r.pixelSize.width) <= AyahPlaneGeometry.maxTextureWidthPixels)
            }
            let after = try RecitationTranslationFile.loadFromBundle().ayat.map(\.text)
            for (a, b) in zip(before, after) { #expect(isByteIdentical(a, b)) }
        }
    }

    /// Decision F1: the system font, and it must carry the three non-ASCII scalars the
    /// translation uses. Asserted from the font, not from the cascade's name - Core Text
    /// substitutes silently, so a name proves nothing.
    @Test func systemFontHasGlyphsForTheThreeNonASCIIScalars() {
        let probe = "\u{0101}\u{012B}\u{2019}"
        let font = ArabicTextRasterizer.resolveSystemFont(for: probe, size: CGFloat(AyahPlaneGeometry.englishFontSizePixels))
        for scalar: Unicode.Scalar in ["\u{0101}", "\u{012B}", "\u{2019}"] {
            #expect(ArabicTextRasterizer.hasGlyph(font, for: scalar), "U+\(String(scalar.value, radix: 16, uppercase: true))")
        }
    }

    /// The English em is smaller than the Arabic and its wrap width is the same 40 degrees.
    @Test func englishGeometryIsAReadingHierarchyUnderTheArabic() {
        #expect(AyahPlaneGeometry.englishEmDeg < AyahPlaneGeometry.textAngularEmDeg)
        #expect(AyahPlaneGeometry.englishFontSizePixels < AyahPlaneGeometry.fontSizePixels)
        #expect(AyahPlaneGeometry.englishMaxContentWidthPixels < AyahPlaneGeometry.maxTextureWidthPixels)
        // P1: the English top edge sits exactly the gap below the Arabic bottom edge.
        let arabicCenter: Float = 0.1, arabicHeight: Float = 0.5, englishHeight: Float = 0.2
        let center = AyahPlaneGeometry.englishPlaneCenterOffset(arabicCenterOffset: arabicCenter,
                                                                arabicPlaneHeightMeters: arabicHeight,
                                                                englishPlaneHeightMeters: englishHeight)
        let englishTop = center + englishHeight / 2
        let arabicBottom = arabicCenter - arabicHeight / 2
        #expect(abs((arabicBottom - englishTop) - AyahPlaneGeometry.englishGapMeters) < 1e-6)
    }
}
