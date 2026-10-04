//
//  FrameStatsTests.swift
//  QuranSpatialTests
//
//  The frame numbers get reported against the acceptance criteria, so the arithmetic that
//  produces them has to be right - a measurement instrument that flatters a bad session is
//  worse than no measurement.
//

import Testing
import Foundation
@testable import QuranSpatial

struct FrameStatsTests {

    /// 90Hz, exactly on cadence: nothing dropped, nothing hitched.
    @Test func aCleanSessionPassesBothBars() {
        var stats = FrameStats()
        for _ in 0..<10_000 { stats.record(frameSeconds: FrameStats.nominalFrameSeconds) }
        #expect(stats.frameCount == 10_000)
        #expect(stats.droppedFrameCount == 0)
        #expect(stats.passesFrameBars)
    }

    /// Ordinary jitter short of 1.5x nominal is not loss. Without the slack, a healthy
    /// session reports a failure.
    @Test func jitterUnderTheThresholdIsNotCountedAsDropped() {
        var stats = FrameStats()
        for _ in 0..<1000 { stats.record(frameSeconds: FrameStats.nominalFrameSeconds * 1.4) }
        #expect(stats.droppedFrameCount == 0)
        #expect(stats.passesDroppedFrameBar)
    }

    @Test func aFrameOverOneAndAHalfNominalIsDropped() {
        var stats = FrameStats()
        stats.record(frameSeconds: FrameStats.nominalFrameSeconds * 1.6)
        #expect(stats.droppedFrameCount == 1)
    }

    /// The bar is *under* 1%, so exactly 1% fails.
    @Test func theDroppedFrameBarIsStrictlyUnderOnePercent() {
        var stats = FrameStats()
        for index in 0..<1000 {
            stats.record(frameSeconds: index < 10 ? 0.030 : FrameStats.nominalFrameSeconds)
        }
        #expect(stats.droppedFrameCount == 10)
        #expect(stats.droppedFraction == 0.01)
        #expect(!stats.passesDroppedFrameBar)
    }

    /// The thermal bar, decided 2026-09-30: `.fair` is reported but does not fail a run;
    /// `.serious` and worse do.
    @Test func thermalBarFailsOnSeriousNotOnFair() {
        #expect(FrameStats.thermalPassesBar(.nominal))
        #expect(FrameStats.thermalPassesBar(.fair))
        #expect(!FrameStats.thermalPassesBar(.serious))
        #expect(!FrameStats.thermalPassesBar(.critical))
    }

    /// The case CLAUDE.md is explicit about: a sustained-90fps session containing one long
    /// stall is a failure, and an average would call it a pass.
    @Test func oneHitchFailsTheSessionEvenAtNinetyFpsAverage() {
        var stats = FrameStats()
        for _ in 0..<10_000 { stats.record(frameSeconds: FrameStats.nominalFrameSeconds) }
        stats.record(frameSeconds: 0.120)
        #expect(stats.meanFrameSeconds < FrameStats.nominalFrameSeconds * 1.02)
        #expect(stats.passesDroppedFrameBar)
        #expect(!stats.passesHitchBar)
        #expect(!stats.passesFrameBars)
    }

    /// 50ms exactly is the bar, not over it.
    @Test func fiftyMillisecondsIsOnTheBarNotOverIt() {
        var stats = FrameStats()
        stats.record(frameSeconds: 0.050)
        #expect(stats.passesHitchBar)
        #expect(stats.hitchCount == 0)

        var worse = FrameStats()
        worse.record(frameSeconds: 0.0501)
        #expect(!worse.passesHitchBar)
        #expect(worse.hitchCount == 1)
    }

    /// A window that recorded nothing must not report a pass. Absence of evidence is how a
    /// run that never rendered gets written up as clean.
    @Test func noFramesIsNotAPass() {
        let stats = FrameStats()
        #expect(!stats.hasEvidence)
        #expect(!stats.passesFrameBars)
        #expect(stats.summary == "no frames recorded")
    }

    /// Individual hitches are kept for the report but cannot grow without bound; the count
    /// keeps rising after the list stops.
    @Test func hitchListIsCappedButTheCountIsNot() {
        var stats = FrameStats()
        for _ in 0..<100 { stats.record(frameSeconds: 0.060) }
        #expect(stats.hitchCount == 100)
        #expect(stats.recordedHitchesSeconds.count == FrameStats.maxRecordedHitches)
    }

    /// A non-finite or non-positive delta is not a frame. RealityKit should never produce
    /// one, but a NaN silently poisoning `totalSeconds` would make every later number wrong.
    @Test func nonsensicalDeltasAreIgnored() {
        var stats = FrameStats()
        stats.record(frameSeconds: .nan)
        stats.record(frameSeconds: .infinity)
        stats.record(frameSeconds: 0)
        stats.record(frameSeconds: -0.01)
        #expect(stats.frameCount == 0)
        #expect(!stats.hasEvidence)
    }

    @Test func worstFrameIsTheMaximumNotTheLast() {
        var stats = FrameStats()
        stats.record(frameSeconds: 0.080)
        stats.record(frameSeconds: FrameStats.nominalFrameSeconds)
        #expect(abs(stats.worstFrameSeconds - 0.080) < 1e-9)
    }
}
