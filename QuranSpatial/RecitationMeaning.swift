//
//  RecitationMeaning.swift
//  QuranSpatial
//
//  The "Meaning" panel's data: the English translation of Al-Mukhtasar fi Tafsir al-Quran,
//  Quranpedia book 27824, Surah 55 only, extracted with deletion-only rules (2026-10-03).
//  A LOOKUP, nothing else - no speech, no model. Shown beside the Quran text while the
//  phase is `asking`, for the pinned ayah, verbatim.
//
//  THE FILE IS NOT IN THE REPO: `Resources/en-rahman-mukhtasar-27824.json` is covered by the
//  `en-*.json` gitignore rule and placed by hand for local builds, exactly like the Saheeh
//  International file. It carries no licence notice (see docs/baseline-disclosure.md), so its
//  absence is a supported state: no file, and the panel reads `unavailableText`.
//
//  Same shape as the translation file, so the same decoder, the same self-hash check and the
//  same refusal of a corrupted copy apply (`RecitationTranslationFile`).
//
//  Source anomaly, recorded rather than repaired: the book numbers all 31 refrain ayat as
//  "77." and gives each of them ayah 77's passage verbatim. The extraction deletes the prefix
//  and keeps the passage; the tests assert the 31 are byte-identical to 77's.
//

import Foundation

enum RecitationMeaning {
    static let resourceName = "en-rahman-mukhtasar-27824"
    static let sourceBook = 27824

    /// The attribution line under the passage, verbatim as decided (2026-10-03).
    static let sourceLine = "Al-Mukhtasar fi Tafsir al-Quran (English), via Quranpedia, book 27824"

    /// What the panel says when the file is not bundled.
    static let unavailableText = "Meaning not available in this build"

    /// Loaded once, on first use. `nil` when the file is absent or fails its own hash.
    static let file: RecitationTranslationFile? =
        RecitationTranslationFile.loadIfPresent(resourceName: resourceName)

    /// The passage for a segment index (0 = intro, no passage; N = ayah N), or nil.
    static func passage(forSegmentIndex index: Int) -> String? {
        file?.text(forSegmentIndex: index)
    }
}
