//
//  RecitationProgressionTests.swift
//  QuranSpatialTests
//
//  Progression through all 78 ayat, the end state, and behaviour on bad data.
//

import Testing
import Foundation
@testable import QuranSpatial

struct RecitationProgressionTests {

    private func loadTimings() throws -> RecitationTimingsFile {
        let url = try #require(Bundle.main.url(forResource: AudioAssetReport.timingsResourceName,
                                               withExtension: AudioAssetReport.timingsResourceExtension))
        return try JSONDecoder().decode(RecitationTimingsFile.self, from: Data(contentsOf: url))
    }

    /// Walks the whole timeline and asserts the index only ever moves forward, visits every
    /// segment from the intro through ayah 78, and visits each as one contiguous run.
    @Test func progressionVisitsEverySegmentOnceInOrder() throws {
        let timings = try loadTimings()
        var visited: [Int] = []
        var t = 0.0
        while t <= timings.totalDuration {
            let index = RecitationCoordinator.segmentIndex(at: t, in: timings.segments)
            if visited.last != index { visited.append(index) }
            t += 0.05
        }
        #expect(visited == Array(0...78))
    }

    @Test func theFinalSegmentIsAyah78AndTimeBeyondItStaysThere() throws {
        let timings = try loadTimings()
        let last = try #require(timings.segments.last)
        #expect(last.index == 78)
        #expect(last.ayah == 78)
        for offset in [0.0, 0.5, 30.0, 6000.0] {
            #expect(RecitationCoordinator.segmentIndex(at: timings.totalDuration + offset,
                                                       in: timings.segments) == 78)
        }
    }

    @Test func timeBeforeTheStartResolvesToTheIntroNotToAyahOne() throws {
        let timings = try loadTimings()
        for t in [-100.0, -0.001, 0.0] {
            #expect(RecitationCoordinator.segmentIndex(at: t, in: timings.segments) == 0)
        }
        let intro = try #require(timings.segments.first)
        #expect(intro.kind == .intro)
        #expect(intro.ayah == nil)
        // The first ayah begins where the intro ends, not at zero.
        #expect(RecitationCoordinator.segmentIndex(at: intro.end, in: timings.segments) == 1)
    }

    @Test func emptyTimingDataDoesNotCrashTheLookup() {
        #expect(RecitationCoordinator.segmentIndex(at: 0, in: []) == 0)
        #expect(RecitationCoordinator.segmentIndex(at: 1234, in: []) == 0)
    }

    @Test func malformedTimingDataIsRejectedRatherThanPartiallyDecoded() {
        let decoder = JSONDecoder()
        let cases: [String] = [
            "{}",
            "[]",
            "not json at all",
            #"{"source":"x","surah":55,"name":"n","totalDuration":1,"ayahCount":78,"segmentCount":79}"#,
            #"{"source":"x","surah":55,"name":"n","totalDuration":1,"ayahCount":78,"segmentCount":1,"segments":[{"index":0,"kind":"nonsense","start":0,"end":1,"duration":1}]}"#,
        ]
        for json in cases {
            #expect(throws: (any Error).self) {
                try decoder.decode(RecitationTimingsFile.self, from: Data(json.utf8))
            }
        }
    }

    @Test func malformedTextDataIsRejected() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(RecitationTextFile.self, from: Data("{}".utf8))
        }
    }

    /// An Ask resume seeks to the anchor's gap start, which by construction lies in the
    /// PREVIOUS segment - so `currentSegmentIndex` reads n-1 for the pre-roll while the pin
    /// shows n. This documents that fact for every measured row, and that speech onset is
    /// back inside n.
    @Test func everyMeasuredGapStartResolvesToThePreviousSegment() throws {
        let timings = try loadTimings()
        let preroll = try RecitationPrerollFile.loadFromBundle()
        for row in preroll.segments where row.isMeasured {
            let gapStart = try #require(row.gapStart)
            let onset = try #require(row.speechOnset)
            #expect(RecitationCoordinator.segmentIndex(at: gapStart, in: timings.segments) == row.index - 1,
                    "segment \(row.index)")
            #expect(RecitationCoordinator.segmentIndex(at: onset, in: timings.segments) == row.index,
                    "segment \(row.index)")
        }
    }

    /// The reconciliation observer's job is to notice that the shown segment disagrees with
    /// the audio clock. Its decision rule is `segmentIndex(at:)`, so this asserts the rule
    /// detects a disagreement rather than asserting on the timer.
    @Test func reconciliationDetectsAMismatchBetweenShownSegmentAndClock() throws {
        let timings = try loadTimings()
        let target = try #require(timings.segments.first { $0.index == 40 })
        let clock = target.start + target.duration / 2
        let expected = RecitationCoordinator.segmentIndex(at: clock, in: timings.segments)
        #expect(expected == 40)
        // A stale index disagrees, which is the condition that triggers a correction.
        #expect(expected != 39)
        #expect(expected != 41)
    }
}
