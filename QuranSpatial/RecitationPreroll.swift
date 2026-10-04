//
//  RecitationPreroll.swift
//  QuranSpatial
//
//  Decoded shape of Resources/ar-rahman-preroll.json, and the rule that turns it into a
//  resume plan. Pure Foundation, no AVFoundation, so the arithmetic is testable without a
//  player.
//
//  Provenance: measured 2026-09-30 by docs/measurements/b3-preroll.py over the bundled
//  rahman-single.mp3 (SHA-256 recorded in the file) - the recording has a continuous tonal
//  bed, so "speech-free" is relative to the local bed floor, not digital silence. Segments 1
//  and 38 carry no gap (segment 1 has no bed to measure against; segment 38's boundary lies
//  inside speech) and fall back to the segment start. Kept SEPARATE from the timings file so
//  the corrected-by-ear boundaries are never edited by a measurement pass.
//

import Foundation

struct RecitationPrerollFile: Decodable {
    let source: String
    let mp3SHA256: String
    let marginDb: Double
    let segments: [PrerollSegment]

    func segment(forIndex index: Int) -> PrerollSegment? {
        segments.first { $0.index == index }
    }

    static func loadFromBundle() throws -> RecitationPrerollFile {
        guard let url = Bundle.main.url(forResource: "ar-rahman-preroll", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(RecitationPrerollFile.self, from: Data(contentsOf: url))
    }
}

/// One ayah boundary's speech-free gap, in absolute audio seconds.
struct PrerollSegment: Decodable, Equatable {
    let index: Int
    let boundary: Double
    let status: String
    /// Where the speech-free gap before the boundary begins. The resume target.
    let gapStart: Double?
    /// Where speech resumes after the boundary. The fade must be complete by here.
    let speechOnset: Double?
    /// `speechOnset - gapStart`.
    let usablePreroll: Double?

    var isMeasured: Bool {
        status == "measured" && gapStart != nil && speechOnset != nil && usablePreroll != nil
    }
}

/// Where and how a paused recitation comes back.
struct ResumePlan: Equatable {
    /// Absolute audio time to seek to, zero tolerance.
    let targetTime: Double
    /// Seconds over which `player.volume` steps from 0 to 1 after the seek lands.
    let fadeSeconds: Double
    /// True when the target is a measured gap start; false for the segment-start fallback.
    let measured: Bool
}

enum RecitationPreroll {

    /// Longest fade. The median usable pre-roll is 0.57 s, so most ayat get the full ramp.
    static let maxFadeSeconds: Double = 0.25

    /// Fraction of the usable pre-roll the ramp may occupy, so it ends before speech onset
    /// with margin. On the shortest measured pre-roll (0.26 s, segment 42) this is a 0.156 s
    /// ramp that finishes 0.10 s before the first word.
    static let fadeFraction: Double = 0.6

    /// Fade for the two unmeasured segments, which resume at their own start. Decided
    /// 2026-09-30: fall back, do not refuse.
    static let fallbackFadeSeconds: Double = 0.15

    /// The rule, in one place: `min(0.25 s, 0.6 x usable pre-roll)` from the gap start for a
    /// measured row; the segment start with a 0.15 s fade otherwise (including a missing
    /// table, so a build without the JSON still resumes).
    static func plan(for segment: RecitationSegment, preroll: PrerollSegment?) -> ResumePlan {
        if let preroll, preroll.isMeasured,
           let gapStart = preroll.gapStart, let usable = preroll.usablePreroll, usable > 0 {
            return ResumePlan(targetTime: gapStart,
                              fadeSeconds: min(maxFadeSeconds, fadeFraction * usable),
                              measured: true)
        }
        return ResumePlan(targetTime: segment.start, fadeSeconds: fallbackFadeSeconds, measured: false)
    }
}
