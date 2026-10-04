//
//  StackedClusterProbe.swift
//  QuranSpatial
//
//  Renders dense mark clusters in the ship font so mark *positioning* can be eyeballed on
//  device.
//
//  Why this exists: every mark-positioning result verified on this project so far came
//  from Geeza Pro, which has no GPOS/GSUB/GDEF and positions via AAT (`morx`). The ship
//  font, KFGQPC Uthmanic Hafs, has GPOS and no `morx`. The Core Text spike therefore proved
//  rasterization, not OpenType Arabic shaping - a different code path from the one the ship
//  font actually uses. Risk is low, since Core Text handles both, but a wrong answer costs
//  a font change with licensing lead time, which the schedule cannot absorb.
//
//  These strings are synthetic probes, deliberately NOT Quranic text. They are carrier
//  letters with marks attached to exercise stacking, and must never be presented as
//  scripture or used as a source of it.
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

enum StackedClusterProbe {

    struct Probe {
        let name: String
        let string: String
        /// What this combination is meant to stress, in plain words.
        let stresses: String
    }

    private static let baa = "\u{0628}"       // ب, carrier
    private static let alef = "\u{0627}"      // ا, carrier for maddah
    private static let sad = "\u{0635}"       // ص, the carrier U+06DC actually goes over
    private static let kasra = "\u{0650}"     // below
    private static let fatha = "\u{064E}"     // above
    private static let damma = "\u{064F}"     // above
    private static let shadda = "\u{0651}"    // above, other marks stack on it
    private static let sukun = "\u{0652}"     // above
    private static let superscriptAlef = "\u{0670}"   // above, sits highest
    private static let maddah = "\u{0653}"    // above
    private static let smallHighSeen = "\u{06DC}"     // above
    private static let smallHighLigatureSad = "\u{06D6}" // waqf, above
    private static let smallHighMeem = "\u{06E2}"     // waqf, above

    /// The densest realistic cluster: a low mark and two stacked high marks on one base.
    /// Marks are in canonical combining order (kasra 32, shadda 33, superscript alef 35),
    /// so this is what normalization would produce and what a shaper should expect.
    static let worstCase = Probe(
        name: "worst-case",
        string: baa + kasra + shadda + superscriptAlef,
        stresses: "low mark below the base, plus a mark stacked above another mark above it"
    )

    static let all: [Probe] = [
        worstCase,
        Probe(name: "shadda-damma", string: baa + shadda + damma,
              stresses: "vowel stacked directly on shadda - the commonest stacked pair"),
        // U+06DC goes over ص, marking that the letter is read as س - يَبْصُۜطُ,
        // بَصْۜطَةً, ٱلْمُصَۜيْطِرُونَ. That is essentially its whole job in the mushaf.
        // An earlier probe put it over ب, which is not a sequence that occurs; the font's
        // contextual GSUB collapsed the vowel and the mark into a single glyph placed near
        // the baseline, and the result looked broken. It was the probe that was wrong, not
        // the font. Over ص the marks stay separate glyphs and place correctly. Do not
        // reintroduce a carrier that the orthography never puts this mark on.
        Probe(name: "high-seen-on-sad-damma", string: sad + damma + smallHighSeen,
              stresses: "small high seen over its real carrier, with a vowel"),
        Probe(name: "high-seen-on-sad-sukun", string: sad + sukun + smallHighSeen,
              stresses: "small high seen over its real carrier, with a sukun"),
        Probe(name: "sukun-plus-waqf", string: baa + sukun + smallHighLigatureSad,
              stresses: "waqf sign above a sukun"),
        Probe(name: "shadda-fatha-superscript-alef", string: baa + shadda + fatha + superscriptAlef,
              stresses: "three marks above one base"),
        Probe(name: "maddah-on-alef", string: alef + maddah,
              stresses: "maddah, which sits high and wide"),
        Probe(name: "waqf-meem", string: baa + damma + smallHighMeem,
              stresses: "isolated waqf meem above a vowel")
    ]

    private static let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "TypographyProbe")

    /// Rasterizes every probe through the production path and writes each as a PNG next to
    /// the font identity report, so they can be pulled off the device and inspected at
    /// full resolution as well as looked at in the immersive space.
    @discardableResult
    static func writePNGs(targetPixelWidth: Int = 600) -> [URL] {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        // Clear previously written probes first. The probe set changes as invalid
        // sequences are found and removed, and a stale PNG from a superseded set is
        // indistinguishable from a current one once it has been pulled off the device.
        if let stale = try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil) {
            for url in stale where url.lastPathComponent.hasPrefix("probe-") && url.pathExtension == "png" {
                try? FileManager.default.removeItem(at: url)
            }
        }

        var written: [URL] = []
        for probe in all {
            guard let raster = ArabicTextRasterizer.rasterize(probe.string, targetPixelWidth: targetPixelWidth) else {
                logger.error("Probe \(probe.name) failed to rasterize")
                continue
            }
            let url = documents.appendingPathComponent("probe-\(probe.name).png")
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
            ) else { continue }
            CGImageDestinationAddImage(destination, raster.cgImage, nil)
            if CGImageDestinationFinalize(destination) {
                written.append(url)
            }
        }
        logger.notice("Wrote \(written.count) typography probe PNGs")
        return written
    }
}
