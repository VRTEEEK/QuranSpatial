//
//  RecitationText.swift
//  QuranSpatial
//
//  Decoded shape of Resources/ar-rahman-text.json.
//
//  The text is VERBATIM from the Tanzil Project's published Uthmani edition. Nothing in
//  this project generates, transcribes, reconstructs, hand-corrects or normalizes Quranic
//  text, and nothing may mutate, truncate or reorder it as a side effect of anything else.
//
//  The source text is in NO standard Unicode normalization form. Applying NFC or NFD
//  REORDERS its combining marks - shadda (ccc 33) and fatha (ccc 30) swap - and changes the
//  length of the surah from 3510 scalars to 3469 or 3576 respectively. So: never normalize
//  it, and never compare it with Swift's `==`, which uses canonical equivalence and would
//  report a reordered copy as equal to the original.
//

import Foundation

struct RecitationTextFile: Decodable {
    let source: String
    let sourceURL: String
    let sourceSHA256: String
    let license: String
    /// Reproduced because the source's terms require the notice to travel with the text.
    let copyright: String
    let surah: Int
    let script: String
    let normalization: String
    let note: String
    /// The bismillah, matching index 0 of the timings. Carried separately by the source
    /// rather than split out of ayah 1 by us.
    let intro: String
    let ayahCount: Int
    let ayat: [AyahText]
}

struct AyahText: Decodable, Equatable {
    let ayah: Int
    let text: String
}

extension RecitationTextFile {
    /// The text for a timings segment. Index 0 is the intro; index N is ayah N.
    func text(forSegmentIndex index: Int) -> String? {
        index == 0 ? intro : ayat.first { $0.ayah == index }?.text
    }

    /// The bundled corpus. The ONLY source of Quran text for probes, reports and tests -
    /// nothing types an ayah by hand, because a hand-typed string does not match the
    /// source's byte representation (the old probe literal differed in its first scalar).
    static func loadFromBundle() throws -> RecitationTextFile {
        guard let url = Bundle.main.url(forResource: "ar-rahman-text", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(RecitationTextFile.self, from: Data(contentsOf: url))
    }
}

/// Exact scalar-for-scalar comparison. `==` on `String` is canonical-equivalence based, so
/// it cannot see the mark reordering this text is specifically vulnerable to.
func isByteIdentical(_ a: String, _ b: String) -> Bool {
    Array(a.utf8) == Array(b.utf8)
}
