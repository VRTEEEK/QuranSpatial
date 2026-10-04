//
//  WrappedLayoutTests.swift
//  QuranSpatialTests
//

import Testing
import Foundation
import CoreGraphics
import CoreText
@testable import QuranSpatial

struct WrappedLayoutTests {

    // The shipped geometry, not a copy of it.
    let padding = CGFloat(AyahPlaneGeometry.paddingPixels)
    var fontSizePixels: CGFloat { CGFloat(AyahPlaneGeometry.fontSizePixels) }
    var maxTextureWidth: Int { AyahPlaneGeometry.maxTextureWidthPixels }
    var maxContentWidth: Int { AyahPlaneGeometry.maxContentWidthPixels }

    private func text() throws -> RecitationTextFile {
        let url = try #require(Bundle.main.url(forResource: "ar-rahman-text", withExtension: "json"))
        return try JSONDecoder().decode(RecitationTextFile.self, from: Data(contentsOf: url))
    }

    /// The whole point: no ayah is ever rendered at a different size to any other.
    @Test func fontSizeIsIdenticalForEverySegment() throws {
        let file = try text()
        var sizes = Set<CGFloat>()
        for segment in [file.intro] + file.ayat.map(\.text) {
            let r = try #require(ArabicTextRasterizer.rasterizeWrapped(
                segment, fontSizePixels: fontSizePixels,
                maxContentWidthPixels: maxContentWidth, padding: padding))
            sizes.insert(r.fontSizePixels)
        }
        #expect(sizes == [fontSizePixels])
    }

    @Test func noSegmentExceedsTheMaximumWidth() throws {
        let file = try text()
        for segment in [file.intro] + file.ayat.map(\.text) {
            let r = try #require(ArabicTextRasterizer.rasterizeWrapped(
                segment, fontSizePixels: fontSizePixels,
                maxContentWidthPixels: maxContentWidth, padding: padding))
            #expect(Int(r.pixelSize.width) <= maxTextureWidth)
        }
    }

    /// Long ayat must spend their length on lines, not on a smaller font.
    @Test func longAyatWrapAndShortOnesDoNot() throws {
        let file = try text()
        let short = try #require(file.ayat.first { $0.ayah == 1 })
        let long = try #require(file.ayat.first { $0.ayah == 33 })
        let a = try #require(ArabicTextRasterizer.rasterizeWrapped(
            short.text, fontSizePixels: fontSizePixels, maxContentWidthPixels: maxContentWidth, padding: padding))
        let b = try #require(ArabicTextRasterizer.rasterizeWrapped(
            long.text, fontSizePixels: fontSizePixels, maxContentWidthPixels: maxContentWidth, padding: padding))
        #expect(a.lineCount == 1)
        #expect(b.lineCount > 1)
        #expect(a.fontSizePixels == b.fontSizePixels)
    }

    /// Wrapping is rendering-only. Rasterizing must not touch the source string.
    @Test func rasterizingDoesNotMutateTheText() throws {
        let file = try text()
        let before = file.ayat.map(\.text)
        for segment in before {
            _ = ArabicTextRasterizer.rasterizeWrapped(
                segment, fontSizePixels: fontSizePixels,
                maxContentWidthPixels: maxContentWidth, padding: padding)
        }
        let after = try text().ayat.map(\.text)
        for (a, b) in zip(before, after) { #expect(isByteIdentical(a, b)) }
    }


    /// Regression guard for the Stage 2 B4 signature change: `rasterizeWrapped` gained
    /// `writingDirection` and `font` for the English layer, and their DEFAULTS must be the
    /// Arabic path exactly. Every segment, called with defaults and with the Arabic values
    /// spelled out, must produce the same geometry.
    @Test func defaultParametersAreTheArabicPath() throws {
        let file = try text()
        for segment in [file.intro] + file.ayat.map(\.text) {
            let byDefault = try #require(ArabicTextRasterizer.rasterizeWrapped(
                segment, fontSizePixels: fontSizePixels,
                maxContentWidthPixels: maxContentWidth, padding: padding))
            let explicit = try #require(ArabicTextRasterizer.rasterizeWrapped(
                segment, fontSizePixels: fontSizePixels,
                maxContentWidthPixels: maxContentWidth, padding: padding,
                writingDirection: .rightToLeft,
                font: ArabicTextRasterizer.resolveFont(for: segment, size: fontSizePixels)))
            #expect(byDefault.pixelSize == explicit.pixelSize)
            #expect(byDefault.lineCount == explicit.lineCount)
            #expect(byDefault.firstBaselineFromTopPixels == explicit.firstBaselineFromTopPixels)
            #expect(byDefault.fontSizePixels == explicit.fontSizePixels)
        }
    }

    /// The reason the ship font changed. KFGQPC classified U+06DF as a base glyph with a
    /// 0.704em advance and no attachment rule, so the silent-letter zero rendered as an
    /// inline dotted circle in ayat 8, 9 and 33. Amiri attaches it.
    ///
    /// The threshold is not zero even though Amiri's `hmtx` advance for this glyph IS zero:
    /// `CTRunGetAdvances` reports 0.084em for it, which is a positioning artefact of mark
    /// attachment rather than spacing. What the defect was actually about is whether the
    /// mark consumes a letter's width, so that is what this asserts - 0.084em passes,
    /// KFGQPC's 0.704em would not.
    @Test func silentLetterZeroIsNotLaidOutAsASpacingLetter() throws {
        let file = try text()
        let size: CGFloat = 100
        let font = ArabicTextRasterizer.resolveFont(for: file.ayat[0].text, size: size)
        var units = Array(String(UnicodeScalar(0x06DF)!).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        #expect(CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count))
        let mark = glyphs[0]
        #expect(mark != 0)

        var seen = 0
        for ayah in file.ayat where ayah.text.unicodeScalars.contains(where: { $0.value == 0x06DF }) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: ayah.text,
                attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
            for run in (CTLineGetGlyphRuns(line) as! [CTRun]) {
                let n = CTRunGetGlyphCount(run)
                var gs = [CGGlyph](repeating: 0, count: n)
                CTRunGetGlyphs(run, CFRangeMake(0, n), &gs)
                var advances = [CGSize](repeating: .zero, count: n)
                CTRunGetAdvances(run, CFRangeMake(0, n), &advances)
                for i in 0..<n where gs[i] == mark {
                    seen += 1
                    #expect(advances[i].width < size * 0.15,
                            "U+06DF is laid out as a spacing letter in ayah \(ayah.ayah)")
                }
            }
        }
        // Five occurrences, across ayat 8, 9 and 33.
        #expect(seen == 5)
    }

    /// No ayah may emit a dotted circle. Under KFGQPC one did - not U+25CC, but its own
    /// isolated presentation glyph - so this guards the rendered result rather than a
    /// codepoint.
    @Test func noSegmentEmitsADottedCircle() throws {
        let file = try text()
        let font = ArabicTextRasterizer.resolveFont(for: file.ayat[0].text, size: 100)
        var units = Array(String(UnicodeScalar(0x25CC)!).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        _ = CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
        let dotted = glyphs[0]
        guard dotted != 0 else { return }   // font has no dotted circle to emit
        for segment in [file.intro] + file.ayat.map(\.text) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: segment, attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
            for run in (CTLineGetGlyphRuns(line) as! [CTRun]) {
                let n = CTRunGetGlyphCount(run)
                var gs = [CGGlyph](repeating: 0, count: n)
                CTRunGetGlyphs(run, CFRangeMake(0, n), &gs)
                #expect(!gs.contains(dotted))
            }
        }
    }

    /// Top anchoring, stated as the property that matters: the first line's baseline lands
    /// at the same world Y whatever an ayah wraps to. Extra lines extend downward; the first
    /// line never rises to centre the block.
    ///
    /// The segments are chosen by their MEASURED line count, not by ayah number. The
    /// previous version hardcoded ayat 1, 9 and 33 as the one-, two- and three-line cases;
    /// that was true at the 3.0 degree em and stopped being true at Stage 11d's 2.2 degree
    /// em, when ayah 9 fitted on one line and the premise failed while the property still
    /// held. Which ayah wraps to how many lines is a fact about the em and the font, and a
    /// test about anchoring should not carry a copy of it.
    @Test func firstLineBaselineIsIdenticalAcrossLineCounts() throws {
        let file = try text()
        func baselineWorldY(_ segment: String) throws -> (Float, Int) {
            let r = try #require(ArabicTextRasterizer.rasterizeWrapped(
                segment, fontSizePixels: fontSizePixels,
                maxContentWidthPixels: maxContentWidth, padding: padding))
            let height = Float(r.pixelSize.height) * AyahPlaneGeometry.metresPerPixel
            let centre = AyahPlaneGeometry.planeCenterY(
                firstBaselineFromTopPixels: r.firstBaselineFromTopPixels,
                planeHeightMeters: height)
            let top = centre + height / 2
            return (top - Float(r.firstBaselineFromTopPixels) * AyahPlaneGeometry.metresPerPixel,
                    r.lineCount)
        }

        // One representative per distinct line count, found by measuring the corpus.
        var representatives: [Int: (ayah: Int, y: Float)] = [:]
        for ayah in file.ayat {
            let (y, lines) = try baselineWorldY(ayah.text)
            if representatives[lines] == nil { representatives[lines] = (ayah.ayah, y) }
        }

        // The premise of the test: the corpus wraps somewhere, so there is more than one
        // line count to compare. If this ever fails the em has grown small enough that
        // nothing wraps, and the property is untestable rather than broken.
        let lineCounts = representatives.keys.sorted()
        try #require(lineCounts.count >= 2,
                     "every segment renders on \(lineCounts) line(s); nothing wraps at this em")
        #expect(lineCounts.first == 1)

        let anchor = AyahPlaneGeometry.firstLineBaselineHeightMeters
        for lines in lineCounts {
            let (ayah, y) = representatives[lines]!
            #expect(abs(y - anchor) < 1e-5,
                    "\(lines)-line segment (ayah \(ayah)) baseline drifted to \(y)")
        }
    }

    /// Every segment, not just the three above.
    @Test func everySegmentSharesTheSameFirstBaseline() throws {
        let file = try text()
        let anchor = AyahPlaneGeometry.firstLineBaselineHeightMeters
        for segment in [file.intro] + file.ayat.map(\.text) {
            let r = try #require(ArabicTextRasterizer.rasterizeWrapped(
                segment, fontSizePixels: fontSizePixels,
                maxContentWidthPixels: maxContentWidth, padding: padding))
            let height = Float(r.pixelSize.height) * AyahPlaneGeometry.metresPerPixel
            let centre = AyahPlaneGeometry.planeCenterY(
                firstBaselineFromTopPixels: r.firstBaselineFromTopPixels,
                planeHeightMeters: height)
            let baseline = (centre + height / 2)
                - Float(r.firstBaselineFromTopPixels) * AyahPlaneGeometry.metresPerPixel
            #expect(abs(baseline - anchor) < 1e-5)
        }
    }
}
