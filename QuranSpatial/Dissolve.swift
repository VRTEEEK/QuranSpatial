//
//  Dissolve.swift
//  QuranSpatial
//
//  Timing and seeding for the dissolve. No shader work here — this is the part that has to
//  be right before any material exists, and it is testable without one.
//

import Foundation
import simd

/// `nonisolated`: every member is a pure function of its arguments or a constant. Under the
/// target's default main-actor isolation this would otherwise be unreachable from the
/// nonisolated pure rules in `RecitationCoordinator` (recall, pin release) without a warning
/// that becomes an error in Swift 6 mode. Behaviour unchanged (2026-10-02).
nonisolated enum Dissolve {

    /// How long the OUTGOING dissolve takes. Equal to
    /// `RecitationCoordinator.dissolveLeadTime`, so the effect finishes exactly as the ayah
    /// ends rather than being cut off by the swap.
    static let outDuration: TimeInterval = 0.8

    /// How long the INCOMING dissolve takes — the same material run in reverse.
    ///
    /// Deliberately shorter than `outDuration`: an ayah leaving should feel like it is
    /// being let go, an ayah arriving should not keep the reader waiting. **The next ayah
    /// is never hard-cut in.**
    static let inDuration: TimeInterval = 0.5

    /// The least settled, fully-opaque time an ayah must get between its two dissolves.
    /// Used by the fit guard below; the transition is compressed rather than dropped if a
    /// segment cannot afford both dissolves plus this.
    static let minimumSettledDuration: TimeInterval = 0.5

    /// Shortest segment that can carry the full effect: in + settled + out.
    static var minimumComfortableDuration: TimeInterval {
        inDuration + minimumSettledDuration + outDuration
    }

    /// Scale to apply to BOTH dissolve durations so they fit inside `duration`, preserving
    /// the in:out ratio. 1.0 when the segment is long enough, which is every segment in
    /// this surah — the shortest is the 3.310s intro against a 1.800s requirement.
    ///
    /// This exists so a corpus change cannot silently produce a segment whose dissolves
    /// overlap or outlast it.
    static func durationScale(forSegmentDuration duration: TimeInterval) -> Double {
        guard duration < minimumComfortableDuration else { return 1.0 }
        let available = max(0, duration - minimumSettledDuration)
        return max(0, available / (inDuration + outDuration))
    }

    /// Dissolve amount at a given audio time. **0 = fully visible, 1 = fully dissolved.**
    ///
    /// A pure function of the clock. Nothing is accumulated across frames, so a seek, the
    /// 1Hz reconciliation, or a first frame arriving anywhere inside a segment all land at
    /// the correct phase with no history to rebuild. There is no state to get out of sync,
    /// because there is no state.
    ///
    /// **Ayah 78 never dissolves out.** The recorded end state is that the last ayah stays
    /// on screen at full opacity when the audio completes, so `isFinalSegment` suppresses
    /// the outgoing phase entirely rather than shortening it.
    static func progress(
        atAudioTime time: TimeInterval,
        segment: RecitationSegment,
        isFinalSegment: Bool
    ) -> Float {
        let scale = durationScale(forSegmentDuration: segment.duration)
        let fadeIn = inDuration * scale
        let fadeOut = outDuration * scale
        let elapsed = time - segment.start

        // Before the segment begins there is nothing to show yet.
        guard elapsed > 0 else { return 1 }

        if elapsed < fadeIn, fadeIn > 0 {
            return Float(max(0, min(1, 1 - elapsed / fadeIn)))
        }

        guard !isFinalSegment else { return 0 }

        let outStart = segment.duration - fadeOut
        if elapsed >= outStart, fadeOut > 0 {
            return Float(max(0, min(1, (elapsed - outStart) / fadeOut)))
        }
        return 0
    }

    /// When the outgoing dissolve begins for a segment, in absolute audio time. `nil` for
    /// the final segment, which has none.
    static func outgoingStart(of segment: RecitationSegment, isFinalSegment: Bool) -> TimeInterval? {
        guard !isFinalSegment else { return nil }
        let scale = durationScale(forSegmentDuration: segment.duration)
        return segment.end - outDuration * scale
    }

    /// Per-ayah noise offset, so the 31 refrain occurrences break up differently while any
    /// given ayah dissolves identically on every run.
    ///
    /// **Deliberately not Swift's `Hasher`.** `Hasher` is seeded randomly per process, so
    /// it would give a different pattern on every launch — the opposite of the requirement.
    /// This is a fixed integer mix (SplitMix64's finalizer), so the mapping is frozen in the
    /// source and reproducible across runs, devices and builds.
    ///
    /// MaterialX noise nodes take no seed input; they are seeded by offsetting the position
    /// they sample. So this is returned as a 2D offset to add to the texture coordinate,
    /// not as a scalar "seed" parameter.
    static func noiseOffset(forSegmentIndex index: Int) -> SIMD2<Float> {
        var x = UInt64(bitPattern: Int64(index)) &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x = x ^ (x >> 31)
        // Two independent 24-bit slices, scaled into a large offset so different ayat land
        // in unrelated regions of the noise field rather than neighbouring ones.
        let u = Float(x & 0xFF_FFFF) / Float(0x100_0000)
        let v = Float((x >> 32) & 0xFF_FFFF) / Float(0x100_0000)
        return SIMD2<Float>(u * 512, v * 512)
    }
}
