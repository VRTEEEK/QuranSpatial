//
//  FrameStats.swift
//  QuranSpatial
//
//  Frame timing, measured against the three acceptance criteria in CLAUDE.md rather than
//  against an fps average: dropped frames under 1%, no single hitch over 50ms, no thermal
//  throttling across a full-length session. An average is exactly what hides all three - a
//  sustained 90fps mean happily contains a 120ms stall.
//
//  A pure value type over frame deltas, so the arithmetic is testable without a headset.
//  The headset supplies the deltas; nothing in here knows or cares where they came from.
//

import Foundation

struct FrameStats: Equatable {

    /// Vision Pro's render cadence. A frame longer than this missed at least one vsync.
    static let nominalFrameSeconds: Double = 1.0 / 90.0

    /// A frame counts as dropped once it overruns the nominal frame by half again.
    ///
    /// The 1.5x is deliberate slack rather than a fudge: a delta of exactly one frame
    /// period is never *measured* as exactly one frame period, and counting ordinary
    /// scheduling jitter as loss would report a failure on a session that dropped nothing.
    /// At 90Hz this is 16.7ms - past it, a vsync really was missed.
    static let droppedThresholdSeconds: Double = nominalFrameSeconds * 1.5

    /// The hitch bar. This type reports against it; it does not enforce it.
    static let hitchThresholdSeconds: Double = 0.050

    /// Most individual hitches kept. A run that blows past this has already failed, and the
    /// first 32 say what kind of failure it is; the count keeps rising either way.
    static let maxRecordedHitches = 32

    private(set) var frameCount = 0
    private(set) var droppedFrameCount = 0
    private(set) var hitchCount = 0
    private(set) var worstFrameSeconds: Double = 0
    private(set) var totalSeconds: Double = 0
    /// Individual hitches, capped at `maxRecordedHitches`, so a report can name them rather
    /// than only count them.
    private(set) var recordedHitchesSeconds: [Double] = []

    mutating func record(frameSeconds delta: Double) {
        guard delta.isFinite, delta > 0 else { return }
        frameCount += 1
        totalSeconds += delta
        if delta > Self.droppedThresholdSeconds { droppedFrameCount += 1 }
        if delta > Self.hitchThresholdSeconds {
            hitchCount += 1
            if recordedHitchesSeconds.count < Self.maxRecordedHitches {
                recordedHitchesSeconds.append(delta)
            }
        }
        if delta > worstFrameSeconds { worstFrameSeconds = delta }
    }

    // MARK: Verdicts

    var droppedFraction: Double {
        frameCount == 0 ? 0 : Double(droppedFrameCount) / Double(frameCount)
    }

    var meanFrameSeconds: Double {
        frameCount == 0 ? 0 : totalSeconds / Double(frameCount)
    }

    /// **A window with no frames in it passes nothing.** Zero frames is the absence of
    /// evidence, and reporting it as a pass is how a run that never rendered gets written
    /// up as clean.
    var hasEvidence: Bool { frameCount > 0 }

    var passesDroppedFrameBar: Bool { hasEvidence && droppedFraction < 0.01 }
    var passesHitchBar: Bool { hasEvidence && worstFrameSeconds <= Self.hitchThresholdSeconds }

    /// Both frame criteria. Thermal state is the third and is not measurable from deltas -
    /// `DissolveDriver` samples it separately.
    var passesFrameBars: Bool { passesDroppedFrameBar && passesHitchBar }

    /// The thermal bar, decided 2026-09-30: a run FAILS on `.serious` or worse. `.fair` does
    /// not fail it - it is logged when it first appears (the driver's "Thermal state rose to"
    /// line) and reported as the worst state, so a run that warmed is visible without being
    /// called a failure.
    static func thermalPassesBar(_ state: ProcessInfo.ThermalState) -> Bool {
        state.severity < ProcessInfo.ThermalState.serious.severity
    }

    var summary: String {
        guard hasEvidence else { return "no frames recorded" }
        return String(
            format: "%d frames, %d dropped (%.2f%%, bar <1.00%%) %@, worst %.1fms (bar 50.0ms) %@, mean %.2fms",
            frameCount,
            droppedFrameCount,
            droppedFraction * 100,
            passesDroppedFrameBar ? "PASS" : "FAIL",
            worstFrameSeconds * 1000,
            passesHitchBar ? "PASS" : "FAIL",
            meanFrameSeconds * 1000
        )
    }
}
