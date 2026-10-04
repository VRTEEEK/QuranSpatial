//
//  QuranSpatialTests.swift
//  QuranSpatialTests
//
//  Created by Mohamed ElEryan on 31/08/2026.
//

import Testing
import CoreGraphics
import Foundation
@testable import QuranSpatial

struct QuranSpatialTests {

    /// Ayah 1 from the bundled corpus. Never typed: the hand-typed literal this replaced
    /// (`Ayah.arRahman1`, removed 2026-10-01) differed from the source in its first scalar.
    private func ayah1() throws -> String {
        try #require(RecitationTextFile.loadFromBundle().text(forSegmentIndex: 1))
    }

    /// Core Text's Arabic-fallback resolution is platform-dependent and must be
    /// re-verified on visionOS: a font cascade that carries U+0670 on macOS is not
    /// guaranteed to on-device or in-simulator.
    @Test func resolvedArabicFontHasSuperscriptAlef() throws {
        let font = ArabicTextRasterizer.resolveFont(for: try ayah1(), size: 96)
        #expect(ArabicTextRasterizer.hasGlyph(font, for: "\u{0670}"))
    }

    /// Guards the silent-substitution failure for the ship font specifically. Bundling a
    /// font does not guarantee Core Text uses it: if it lacks one character of the string,
    /// `CTFontCreateForString` substitutes without error. Both names are read at runtime -
    /// the expected one from the font file itself - so nothing here hardcodes a PostScript
    /// name.
    ///
    /// Inert until the ship font is bundled, and deliberately so: its absence is a
    /// supported state (see `isShipFontBundled`). This asserts nothing in a build that
    /// carries no ship font, and starts guarding the moment one is added.
    @Test func resolvedFontIsTheBundledShipFontWhenOneIsBundled() throws {
        try withKnownIssue(isIntermittent: false) {
            let expected = try #require(
                ArabicTextRasterizer.bundledShipFontPostScriptName(),
                "no ship font bundled - nothing to check"
            )
            let resolved = ArabicTextRasterizer.resolvedFontPostScriptName(
                for: try ayah1(),
                size: 96
            )
            #expect(resolved == expected)
        } when: {
            !ArabicTextRasterizer.isShipFontBundled
        }
    }

    /// Bundle lookups fail silently: a wrong path builds cleanly and returns nil, and the
    /// symptom is playback doing nothing. Verified against the built product that
    /// synchronised folder references land flat at the bundle root, so these must resolve
    /// with no `subdirectory:` argument.
    @Test func recitationAssetsResolveFromTheBundleRoot() throws {
        let audio = try #require(
            Bundle.main.url(forResource: AudioAssetReport.audioResourceName,
                            withExtension: AudioAssetReport.audioResourceExtension),
            "rahman-single.mp3 did not resolve from the bundle root"
        )
        let timings = try #require(
            Bundle.main.url(forResource: AudioAssetReport.timingsResourceName,
                            withExtension: AudioAssetReport.timingsResourceExtension),
            "ar-rahman-timings.json did not resolve from the bundle root"
        )
        #expect(FileManager.default.fileExists(atPath: audio.path))
        #expect(FileManager.default.fileExists(atPath: timings.path))
    }

    /// A present-but-unparseable timings file fails as silently as a missing one, and the
    /// segment structure is what every later assumption rests on.
    @Test func recitationTimingsDecodeWithTheExpectedShape() throws {
        let url = try #require(Bundle.main.url(forResource: AudioAssetReport.timingsResourceName,
                                               withExtension: AudioAssetReport.timingsResourceExtension))
        let file = try JSONDecoder().decode(RecitationTimingsFile.self, from: Data(contentsOf: url))

        #expect(file.surah == 55)
        #expect(file.segments.count == file.segmentCount)
        #expect(file.segments.count == 79)
        #expect(file.ayahCount == 78)

        // Index 0 is the intro and carries no ayah number; index N is ayah N.
        let intro = try #require(file.segments.first)
        #expect(intro.index == 0)
        #expect(intro.kind == .intro)
        #expect(intro.ayah == nil)
        for segment in file.segments.dropFirst() {
            #expect(segment.ayah == segment.index)
        }

        // The refrain is 31 occurrences; that count is what validated the alignment.
        #expect(file.segments.filter { $0.kind == .refrain }.count == 31)

        // Segments must tile the file without gaps or overlaps, or ayah advance drifts.
        for (previous, next) in zip(file.segments, file.segments.dropFirst()) {
            #expect(abs(previous.end - next.start) < 0.001)
        }
        #expect(abs(file.segments.last!.end - file.totalDuration) < 0.001)
        for segment in file.segments {
            #expect(abs((segment.end - segment.start) - segment.duration) < 0.001)
            #expect(segment.duration > 0)
        }
    }

    @Test func rasterizesArRahman1ToNonEmptyImage() throws {
        let result = try #require(ArabicTextRasterizer.rasterize(try ayah1(), targetPixelWidth: 894))
        #expect(result.pixelSize.width > 0)
        #expect(result.pixelSize.height > 0)
        #expect(result.cgImage.width == Int(result.pixelSize.width))
        #expect(result.cgImage.height == Int(result.pixelSize.height))
    }

    /// The rasterizer must render Core Text directly at the requested resolution, not
    /// render small and scale a bitmap up — so the output width should track the
    /// requested target width closely (ceil/font-size rounding only).
    @Test func rasterizedWidthTracksRequestedTargetPixelWidth() throws {
        let result = try #require(ArabicTextRasterizer.rasterize(try ayah1(), targetPixelWidth: 894))
        #expect(abs(result.pixelSize.width - 894) < 2)
    }

}
