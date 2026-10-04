//
//  AskTransitionTests.swift
//  QuranSpatialTests
//
//  The Ask transport's arithmetic, tested without a player: where the pin lets go, how the
//  recall runs, where a resume lands and how long it fades, what is refused. Every figure
//  comes from the bundled timings and pre-roll table, never from a typed constant that
//  could drift from them.
//

import CryptoKit
import Foundation
import Testing
@testable import QuranSpatial

struct AskTransitionTests {

    private func loadTimings() throws -> RecitationTimingsFile {
        let url = try #require(Bundle.main.url(forResource: AudioAssetReport.timingsResourceName,
                                               withExtension: AudioAssetReport.timingsResourceExtension))
        return try JSONDecoder().decode(RecitationTimingsFile.self, from: Data(contentsOf: url))
    }

    // MARK: Pin release

    /// The pin holds until the FIRST instant the pure dissolve function returns 0 for the
    /// anchor. Earlier and the text would fade in a second time; later buys nothing.
    ///
    /// "Returns 0" is to within floating point: `(start + 0.5) - start` can come out a few
    /// ulps under 0.5 (measured 7e-15 on segment boundaries like 70.4), so at the exact
    /// release instant the function may return ~1e-14 rather than 0. One millisecond later
    /// it is exactly 0. The release fires from a boundary observer and is checked against
    /// the clock a frame later, so the hand-over is exact in practice; the test states the
    /// tolerance rather than pretending IEEE arithmetic is exact.
    @Test func pinReleasesWhereThePureFunctionFirstReturnsZero() throws {
        let timings = try loadTimings()
        let finalIndex = timings.segments.last?.index
        for segment in timings.segments {
            let isFinal = segment.index == finalIndex
            let release = RecitationCoordinator.pinReleaseTime(for: segment)
            #expect(release == segment.start + Dissolve.inDuration)
            #expect(Dissolve.progress(atAudioTime: release, segment: segment, isFinalSegment: isFinal) < 1e-6)
            #expect(Dissolve.progress(atAudioTime: release + 0.001, segment: segment, isFinalSegment: isFinal) == 0)
            #expect(Dissolve.progress(atAudioTime: release - 0.01, segment: segment, isFinalSegment: isFinal) > 0)
            // And the release always precedes the outgoing dissolve, so nothing overlaps.
            if let outStart = Dissolve.outgoingStart(of: segment, isFinalSegment: isFinal) {
                #expect(release < outStart)
            }
        }
    }

    // MARK: Recall

    /// From wherever the dissolve was at entry back to 0 at the fade-in rate: p takes
    /// p x inDuration seconds, never goes below 0, and does not move before time does.
    @Test func recallRunsToZeroAtTheFadeInRate() {
        for p: Float in [0, 0.1, 0.5, 0.83, 1] {
            #expect(RecitationCoordinator.recallProgress(entryProgress: p, elapsed: 0) == p)
            #expect(RecitationCoordinator.recallProgress(entryProgress: p, elapsed: -1) == p)
            let halfway = RecitationCoordinator.recallProgress(entryProgress: p, elapsed: Double(p) * Dissolve.inDuration / 2)
            #expect(abs(halfway - p / 2) < 1e-5)
            let done = RecitationCoordinator.recallProgress(entryProgress: p, elapsed: Double(p) * Dissolve.inDuration)
            #expect(abs(done) < 1e-5)
            #expect(RecitationCoordinator.recallProgress(entryProgress: p, elapsed: 10) == 0)
        }
    }

    // MARK: Resume plan

    /// Every measured row resumes at its gap start with a fade that is over before the
    /// first word, and the rule is the decided one: min(0.25 s, 0.6 x usable pre-roll).
    @Test func fadeEndsBeforeSpeechOnsetForEveryMeasuredRow() throws {
        let timings = try loadTimings()
        let preroll = try RecitationPrerollFile.loadFromBundle()
        var measured = 0
        for row in preroll.segments where row.isMeasured {
            let segment = try #require(timings.segments.first { $0.index == row.index })
            let plan = RecitationPreroll.plan(for: segment, preroll: row)
            let gapStart = try #require(row.gapStart)
            let onset = try #require(row.speechOnset)
            let usable = try #require(row.usablePreroll)
            #expect(plan.measured)
            #expect(plan.targetTime == gapStart)
            #expect(abs(plan.fadeSeconds - min(RecitationPreroll.maxFadeSeconds, RecitationPreroll.fadeFraction * usable)) < 1e-9)
            #expect(plan.fadeSeconds <= RecitationPreroll.maxFadeSeconds)
            #expect(plan.targetTime + plan.fadeSeconds < onset, "segment \(row.index): fade would run into speech")
            // The gap really is before the boundary, and the onset really is after it.
            #expect(gapStart <= segment.start)
            #expect(onset >= segment.start)
            measured += 1
        }
        #expect(measured == 76)
    }

    /// Segments 1 and 38 carry no gap and fall back to their own start with the short fade.
    /// Decided 2026-09-30: fall back, do not refuse. A missing row behaves the same way, so
    /// a build without the table still resumes.
    @Test func unmeasuredRowsAndMissingRowsFallBackToTheSegmentStart() throws {
        let timings = try loadTimings()
        let preroll = try RecitationPrerollFile.loadFromBundle()
        let unmeasured = preroll.segments.filter { !$0.isMeasured }.map(\.index)
        #expect(unmeasured == [1, 38])
        for index in unmeasured {
            let segment = try #require(timings.segments.first { $0.index == index })
            let plan = RecitationPreroll.plan(for: segment, preroll: preroll.segment(forIndex: index))
            #expect(plan == ResumePlan(targetTime: segment.start,
                                       fadeSeconds: RecitationPreroll.fallbackFadeSeconds,
                                       measured: false))
        }
        let anySegment = try #require(timings.segments.first { $0.index == 13 })
        let noRow = RecitationPreroll.plan(for: anySegment, preroll: nil)
        #expect(noRow.targetTime == anySegment.start)
        #expect(noRow.fadeSeconds == RecitationPreroll.fallbackFadeSeconds)
        #expect(!noRow.measured)
    }

    /// The table describes THIS audio and THESE timings: its recorded mp3 hash matches the
    /// bundled file, its boundaries match the timings, and it covers ayat 1-78 exactly once
    /// with no row for the intro.
    @Test func prerollTableMatchesTheBundledAudioAndTimings() throws {
        let timings = try loadTimings()
        let preroll = try RecitationPrerollFile.loadFromBundle()
        let audio = try #require(Bundle.main.url(forResource: AudioAssetReport.audioResourceName,
                                                 withExtension: AudioAssetReport.audioResourceExtension))
        let digest = SHA256.hash(data: try Data(contentsOf: audio)).map { String(format: "%02x", $0) }.joined()
        #expect(preroll.mp3SHA256 == digest)
        #expect(preroll.segments.map(\.index) == Array(1...78))
        for row in preroll.segments {
            let segment = try #require(timings.segments.first { $0.index == row.index })
            #expect(abs(row.boundary - segment.start) < 0.001)
        }
    }

    // MARK: Refusals

    /// Decided 2026-09-30: refused on the intro and after completion, allowed on ayah 78.
    @Test func askIsRefusedOnTheIntroAndAfterCompletionAndAllowedOnAyah78() {
        typealias C = RecitationCoordinator
        #expect(C.askRefusal(phase: .reciting, displayedSegmentIndex: 0, assetsLoaded: true) == "intro")
        #expect(C.askRefusal(phase: .completed, displayedSegmentIndex: 78, assetsLoaded: true) == "completed")
        #expect(C.askRefusal(phase: .idle, displayedSegmentIndex: 5, assetsLoaded: true) == "not started")
        #expect(C.askRefusal(phase: .asking, displayedSegmentIndex: 5, assetsLoaded: true) == "already asking")
        #expect(C.askRefusal(phase: .reciting, displayedSegmentIndex: 5, assetsLoaded: false) == "assets not loaded")
        #expect(C.askRefusal(phase: .reciting, displayedSegmentIndex: 1, assetsLoaded: true) == nil)
        #expect(C.askRefusal(phase: .reciting, displayedSegmentIndex: 5, assetsLoaded: true) == nil)
        #expect(C.askRefusal(phase: .reciting, displayedSegmentIndex: 78, assetsLoaded: true) == nil)
    }

    // MARK: Volume ramp

    /// Silent at the start, full at the end, monotonic in between, and safe for a zero
    /// duration.
    @Test func volumeRampIsMonotonicFromSilenceToFull() {
        typealias C = RecitationCoordinator
        #expect(C.rampVolume(elapsed: 0, duration: 0.25) == 0)
        #expect(C.rampVolume(elapsed: -1, duration: 0.25) == 0)
        #expect(C.rampVolume(elapsed: 0.25, duration: 0.25) == 1)
        #expect(C.rampVolume(elapsed: 5, duration: 0.25) == 1)
        #expect(C.rampVolume(elapsed: 0.1, duration: 0) == 1)
        var last: Float = -1
        for step in 0...20 {
            let v = C.rampVolume(elapsed: Double(step) * 0.0125, duration: 0.25)
            #expect(v >= last)
            last = v
        }
    }
}
