//
//  RecitationTimings.swift
//  QuranSpatial
//
//  Decoded shape of Resources/ar-rahman-timings.json. Pure Foundation, no AVFoundation or
//  RealityKit, so it is testable without a device.
//
//  Provenance, recorded so it is not re-derived: the original upload contained the surah
//  twice (0.988 sample correlation between halves at a 43ms offset). rahman-single.mp3 is
//  the deduplicated first pass. Segment boundaries were corrected by ear and then validated
//  statistically - the 31 refrain ayat come out at cv=0.097 on duration against 0.62 for
//  non-refrain, and that is what confirms the alignment.
//

import Foundation

struct RecitationTimingsFile: Decodable {
    let source: String
    let surah: Int
    let name: String
    let totalDuration: Double
    let ayahCount: Int
    let segmentCount: Int
    let note: String?
    let segments: [RecitationSegment]
}

/// One timed span of `rahman-single.mp3`.
///
/// Index 0 is the intro (basmala) and carries no ayah number; index N is ayah N.
struct RecitationSegment: Decodable, Equatable {
    enum Kind: String, Decodable {
        case intro
        case ayah
        /// The 31 occurrences of فَبِأَىِّ ءَالَآءِ رَبِّكُمَا تُكَذِّبَانِ.
        case refrain
    }

    let index: Int
    let ayah: Int?
    let kind: Kind
    let start: Double
    let end: Double
    let duration: Double
}
