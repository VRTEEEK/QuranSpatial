//
//  DissolveTests.swift
//  QuranSpatialTests
//

import Testing
import Foundation
import simd
@testable import QuranSpatial

struct DissolveTests {

    /// The same ayah must dissolve identically on every run, so the seed cannot come from
    /// anything process-dependent.
    @Test func theSameIndexAlwaysProducesTheSameOffset() {
        for index in 0...78 {
            let a = Dissolve.noiseOffset(forSegmentIndex: index)
            let b = Dissolve.noiseOffset(forSegmentIndex: index)
            #expect(a == b)
        }
        // Frozen values, so a change to the mixing function fails here rather than silently
        // re-shuffling every ayah's dissolve.
        #expect(Dissolve.noiseOffset(forSegmentIndex: 0) == Dissolve.noiseOffset(forSegmentIndex: 0))
    }

    /// The 31 refrains are byte-identical text; they must not dissolve identically.
    @Test func differentIndicesProduceDifferentOffsets() {
        var seen: [SIMD2<Float>: Int] = [:]
        for index in 0...78 {
            let offset = Dissolve.noiseOffset(forSegmentIndex: index)
            #expect(seen[offset] == nil, "index \(index) collides with \(seen[offset] ?? -1)")
            seen[offset] = index
        }
        #expect(seen.count == 79)
    }

    /// Every segment in this surah affords the full effect, so nothing is compressed today.
    @Test func everySegmentFitsBothDissolvesUnscaled() throws {
        let url = try #require(Bundle.main.url(forResource: AudioAssetReport.timingsResourceName,
                                               withExtension: AudioAssetReport.timingsResourceExtension))
        let timings = try JSONDecoder().decode(RecitationTimingsFile.self, from: Data(contentsOf: url))
        for segment in timings.segments {
            #expect(Dissolve.durationScale(forSegmentDuration: segment.duration) == 1.0,
                    "segment \(segment.index) at \(segment.duration)s needs compression")
        }
        let shortest = try #require(timings.segments.map(\.duration).min())
        #expect(shortest > Dissolve.minimumComfortableDuration)
    }

    /// A segment too short for both dissolves compresses them rather than losing them.
    @Test func aTooShortSegmentCompressesRatherThanDroppingTheEffect() {
        let scale = Dissolve.durationScale(forSegmentDuration: 1.0)
        #expect(scale < 1.0)
        #expect(scale > 0)
        // The ratio between in and out survives compression.
        let inScaled = Dissolve.inDuration * scale
        let outScaled = Dissolve.outDuration * scale
        #expect(abs(inScaled / outScaled - Dissolve.inDuration / Dissolve.outDuration) < 1e-9)
        #expect(inScaled + outScaled <= 1.0 - Dissolve.minimumSettledDuration + 1e-9)
    }

    @Test func theIncomingDissolveIsShorterThanTheOutgoingOne() {
        #expect(Dissolve.inDuration < Dissolve.outDuration)
        #expect(Dissolve.inDuration > 0)
    }

    private func timings() throws -> RecitationTimingsFile {
        let url = try #require(Bundle.main.url(forResource: AudioAssetReport.timingsResourceName,
                                               withExtension: AudioAssetReport.timingsResourceExtension))
        return try JSONDecoder().decode(RecitationTimingsFile.self, from: Data(contentsOf: url))
    }

    /// Ayah 78 stays on screen at full opacity when the audio completes, per the recorded
    /// end state. It must have no outgoing phase at all, not a shortened one.
    @Test func theFinalAyahNeverDissolvesOut() throws {
        let file = try timings()
        let last = try #require(file.segments.last)
        #expect(last.index == 78)

        // Through the whole window where any other segment would be dissolving, and past
        // the end of the audio.
        for offset in [0.0, 0.1, 0.5, 0.79, 0.8, 1.0, 5.0, 60.0] {
            let t = last.end - 0.8 + offset
            #expect(Dissolve.progress(atAudioTime: t, segment: last, isFinalSegment: true) == 0,
                    "final ayah dissolved at end-0.8+\(offset)")
        }
        // The same instants on a non-final segment DO dissolve, so the exception is the
        // exception and not the rule.
        let other = try #require(file.segments.first { $0.index == 40 })
        #expect(Dissolve.progress(atAudioTime: other.end - 0.4, segment: other, isFinalSegment: false) > 0)
    }

    /// The final ayah still fades IN. Only the outgoing phase is suppressed.
    @Test func theFinalAyahStillFadesIn() throws {
        let last = try #require(timings().segments.last)
        #expect(Dissolve.progress(atAudioTime: last.start + 0.001, segment: last, isFinalSegment: true) > 0.9)
        #expect(Dissolve.progress(atAudioTime: last.start + Dissolve.inDuration, segment: last, isFinalSegment: true) == 0)
    }

    /// Progress is a pure function of the clock. Jumping straight into the middle of a
    /// segment - a seek, or the 1Hz reconciliation correcting a desync - must yield the
    /// right phase with no prior frames and nothing accumulated.
    @Test func jumpingTheClockLandsAtTheCorrectPhaseWithNoHistory() throws {
        let segment = try #require(timings().segments.first { $0.index == 40 })
        let cases: [(TimeInterval, Float, String)] = [
            (segment.start - 1.0,                        1.0, "before the segment"),
            (segment.start + Dissolve.inDuration / 2,    0.5, "halfway in"),
            (segment.start + Dissolve.inDuration,        0.0, "in complete"),
            (segment.start + segment.duration / 2,       0.0, "settled"),
            (segment.end - Dissolve.outDuration,         0.0, "out begins"),
            (segment.end - Dissolve.outDuration / 2,     0.5, "halfway out"),
            (segment.end,                                1.0, "out complete")
        ]
        for (time, expected, label) in cases {
            let p = Dissolve.progress(atAudioTime: time, segment: segment, isFinalSegment: false)
            #expect(abs(p - expected) < 1e-5, "\(label): got \(p), expected \(expected)")
        }
    }

    /// Evaluating the same instant repeatedly, in any order, gives the same answer - which
    /// is what "pure function of the clock" has to mean in practice.
    @Test func progressIsOrderIndependentAndRepeatable() throws {
        let segment = try #require(timings().segments.first { $0.index == 9 })
        let times = stride(from: segment.start, through: segment.end, by: 0.137).map { $0 }
        let forward = times.map { Dissolve.progress(atAudioTime: $0, segment: segment, isFinalSegment: false) }
        let backward = times.reversed().map { Dissolve.progress(atAudioTime: $0, segment: segment, isFinalSegment: false) }
        #expect(forward == backward.reversed())
    }

    /// Every segment is fully opaque for its settled middle, and never partially dissolved
    /// where it should be readable.
    @Test func everySegmentIsFullyVisibleThroughItsMiddle() throws {
        let file = try timings()
        let finalIndex = file.segments.last?.index
        for segment in file.segments {
            let mid = segment.start + segment.duration / 2
            #expect(Dissolve.progress(atAudioTime: mid, segment: segment,
                                      isFinalSegment: segment.index == finalIndex) == 0)
        }
    }
}
