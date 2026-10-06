//
//  AskSpeechTests.swift
//  QuranSpatialTests
//
//  The silence rule that ends an Ask capture, without a microphone.
//

import Testing
@testable import QuranSpatial

struct SilenceDetectorTests {
    // 2026-10-06: the floor is the minimum 3-buffer mean, and nothing is judged speech until
    // a floor exists, so each case opens with three quiet buffers (one full window). The
    // verdict rules under test are unchanged.
    @Test func stopsOneAndAHalfSecondsAfterTheLastSpeech() {
        var d = SilenceDetector()
        #expect(d.feed(rms: 0.001, at: 0.0) == .keepListening)
        #expect(d.feed(rms: 0.001, at: 0.1) == .keepListening)
        #expect(d.feed(rms: 0.001, at: 0.2) == .keepListening)
        #expect(d.feed(rms: 0.05, at: 0.5) == .keepListening)   // speech
        #expect(d.feed(rms: 0.05, at: 1.0) == .keepListening)   // speech
        #expect(d.feed(rms: 0.001, at: 2.0) == .keepListening)  // 1.0 s of silence
        #expect(d.feed(rms: 0.001, at: 2.49) == .keepListening) // 1.49 s
        #expect(d.feed(rms: 0.001, at: 2.5) == .stopSilence)    // 1.5 s
    }

    @Test func speechAfterASilenceRestartsTheClock() {
        var d = SilenceDetector()
        for t in [0.0, 0.1, 0.2] { _ = d.feed(rms: 0.001, at: t) }
        _ = d.feed(rms: 0.05, at: 0.25)
        _ = d.feed(rms: 0.001, at: 1.5)                          // 1.25 s of silence
        #expect(d.feed(rms: 0.05, at: 1.75) == .keepListening)   // speech restarts the clock
        #expect(d.feed(rms: 0.001, at: 3.0) == .keepListening)   // 1.25 s after the last speech
        #expect(d.feed(rms: 0.001, at: 3.25) == .stopSilence)    // 1.5 s, exact in binary
    }

    @Test func silenceBeforeAnySpeechDoesNotStopUntilTheNoSpeechCap() {
        var d = SilenceDetector()
        #expect(d.feed(rms: 0.001, at: 0.0) == .keepListening)
        #expect(d.feed(rms: 0.001, at: 5.0) == .keepListening)
        #expect(d.feed(rms: 0.001, at: 7.9) == .keepListening)
        #expect(d.feed(rms: 0.001, at: 8.0) == .stopNoSpeech)
    }

    /// Cap lowered 20 s -> 10 s on 2026-10-06. The feed is speech as a microphone hears it,
    /// 0.6 s of words at 0.08 then a 0.4 s pause at 0.02, rather than a constant 0.05: a
    /// perfectly flat level is indistinguishable from a noise floor, and the adaptive
    /// threshold would rightly read it as one. The first pause seeds the floor.
    @Test func theHardCapEndsEvenContinuousSpeech() {
        var d = SilenceDetector()
        var i = 0
        for t in stride(from: 0.0, through: 9.9, by: 0.1) {
            #expect(d.feed(rms: i % 10 < 6 ? 0.08 : 0.02, at: t) == .keepListening); i += 1
        }
        #expect(d.heardSpeech)
        #expect(d.feed(rms: 0.08, at: 10.0) == .stopCap)
        #expect(d.noSpeechCap == 8)
    }

    /// 2026-10-06: a floor of 0.02 (every device Ask ran to the cap under the fixed 0.012)
    /// raises the threshold in force to 0.06; quiet at 0.02 is silence again and the stop
    /// fires 1.5 s after the last word.
    @Test func aRaisedFloorRaisesTheThresholdAndSilenceStopsAgain() {
        var d = SilenceDetector()
        for t in stride(from: 0.0, through: 0.9, by: 0.1) { #expect(d.feed(rms: 0.02, at: t) == .keepListening) }
        #expect(!d.heardSpeech)                      // 0.02 is the floor, not speech
        #expect(d.effectiveThreshold == 0.06)        // 3 x 0.02
        for t in stride(from: 1.0, through: 2.0, by: 0.1) { #expect(d.feed(rms: 0.10, at: t) == .keepListening) }
        #expect(d.heardSpeech)
        #expect(d.lastSpeechAt == 2.0)
        #expect(d.feed(rms: 0.02, at: 2.5) == .keepListening)
        #expect(d.feed(rms: 0.02, at: 3.49) == .keepListening)
        #expect(d.feed(rms: 0.02, at: 3.5) == .stopSilence)     // 1.5 s after the last word
    }

    /// 2026-10-06: a floor under 0.004 leaves the fixed 0.012 in force, so a quiet room
    /// behaves exactly as before the adaptive threshold.
    @Test func aLowFloorLeavesTheFixedThresholdInForce() {
        var d = SilenceDetector()
        _ = d.feed(rms: 0.002, at: 0.0)
        _ = d.feed(rms: 0.003, at: 0.1)
        _ = d.feed(rms: 0.002, at: 0.2)
        #expect(d.effectiveThreshold == 0.012)                   // 3 x 0.0023 is under the bound
        #expect(d.feed(rms: 0.012, at: 0.3) == .keepListening)   // at the fixed threshold: speech
        #expect(d.heardSpeech)
        #expect(d.feed(rms: 0.011, at: 1.79) == .keepListening)
        #expect(d.feed(rms: 0.011, at: 1.8) == .stopSilence)
        #expect(d.hardCap == 10)
    }

    /// Ask addendum, 2026-10-05: `AskSpeechSession` now publishes the tap's RMS as `inputLevel`
    /// for the waveform. That is a read-out beside the detector, not a change to it: the same
    /// RMS sequence must produce the same verdicts, at the same times, as before. Golden
    /// sequence covering speech, a sub-threshold dip, the restart, and the 1.5 s stop.
    @Test func silenceVerdictsAreUnchangedByTheLevelReadout() {
        var d = SilenceDetector()
        let feed: [(Float, Double)] = [
            (0.002, 0.00), (0.003, 0.10), (0.040, 0.20), (0.080, 0.30), (0.011, 0.40),
            (0.060, 0.50), (0.004, 0.60), (0.003, 1.00), (0.002, 1.50), (0.002, 1.99),
            (0.002, 2.00),
        ]
        let verdicts = feed.map { d.feed(rms: $0.0, at: $0.1) }
        let expected: [SilenceDetector.Verdict] = Array(repeating: .keepListening, count: 10) + [.stopSilence]
        #expect(verdicts == expected)
        #expect(d.heardSpeech)
        #expect(d.lastSpeechAt == 0.50)        // 0.011 at 0.40 is under the 0.012 threshold
        #expect(d.threshold == 0.012)
        #expect(d.silenceSeconds == 1.5)
    }

    /// 2026-10-06: seeded with one quiet buffer, because the first buffer now seeds the
    /// running floor and is judged against three times itself. Against a settled floor the
    /// fixed 0.012 is still exactly the boundary.
    @Test func thresholdIsExactlyTheConfiguredRMS() {
        var d = SilenceDetector()
        for t in [0.0, 0.1, 0.2] { _ = d.feed(rms: 0.002, at: t) }
        _ = d.feed(rms: d.threshold, at: 0.3)     // at the threshold counts as speech
        #expect(d.heardSpeech)
        var e = SilenceDetector()
        for t in [0.0, 0.1, 0.2] { _ = e.feed(rms: 0.002, at: t) }
        _ = e.feed(rms: e.threshold - 0.0001, at: 0.3)
        #expect(!e.heardSpeech)
    }

    /// The engine's first buffers can be zeros. They must not pin the floor at 0, or the
    /// adaptive threshold never engages and a 0.02 floor runs to the cap exactly as before.
    @Test func deadAirDoesNotSeedTheFloor() {
        var d = SilenceDetector()
        _ = d.feed(rms: 0.0, at: 0.0)
        _ = d.feed(rms: 0.0002, at: 0.1)
        #expect(d.runningFloor == nil)
        for t in [0.2, 0.3, 0.4] { _ = d.feed(rms: 0.02, at: t) }   // one full live window
        #expect(d.runningFloor == 0.02)
        #expect(d.effectiveThreshold == 0.06)
        #expect(!d.heardSpeech)
    }

    /// 2026-10-06: the floor is a 3-buffer mean, so one dip (a gap between words, a gated
    /// quiet moment) cannot drag it under the room level and hand the threshold back to
    /// 0.012. A 0.004 buffer inside a 0.02 room moves the floor to the window mean, 0.0147,
    /// and the threshold in force stays above the room, so silence is still silence.
    @Test func aSingleDipDoesNotDropTheThresholdUnderTheRoom() {
        var d = SilenceDetector()
        for t in [0.0, 0.1, 0.2] { _ = d.feed(rms: 0.02, at: t) }
        #expect(d.effectiveThreshold == 0.06)
        _ = d.feed(rms: 0.004, at: 0.3)                            // the single dip
        for t in [0.4, 0.5, 0.6] { _ = d.feed(rms: 0.02, at: t) }
        #expect(d.effectiveThreshold > 0.02)                       // still above the room
        #expect(d.effectiveThreshold < 0.06)                       // the dip was not ignored, only bounded
        #expect(!d.heardSpeech)                                    // the room never read as speech
        for t in stride(from: 1.0, through: 2.0, by: 0.1) { _ = d.feed(rms: 0.10, at: t) }
        #expect(d.lastSpeechAt == 2.0)
        #expect(d.feed(rms: 0.02, at: 3.49) == .keepListening)
        #expect(d.feed(rms: 0.02, at: 3.5) == .stopSilence)        // 1.5 s after the last word
    }
}

struct AskDisplayTests {
    @Test func decisionLabelsAreTheFourAgreedOnes() {
        #expect(AskPanelView.decisionLabel("answered") == "From the sources")
        #expect(AskPanelView.decisionLabel("answered-in-part") == "From the sources, in part")
        #expect(AskPanelView.decisionLabel("referred") == "Referred to a scholar")
        #expect(AskPanelView.decisionLabel("declined") == "Not about this ayah")
        // Directive 3 (3c-1): not-covered, and referred with general information attached.
        #expect(AskPanelView.decisionLabel("not-covered") == "Not covered by this app's sources")
        // Redesign 2026-10-05: the title no longer carries the general-information suffix.
        // 2026-10-06: the section label that replaced it is gone too; with passages the panel
        // shows one fixed note line (tested below). The title is the same either way.
        #expect(AskPanelView.decisionLabel("referred", hasPassages: true) == "Referred to a scholar")
        #expect(AskPanelView.decisionLabel("referred", hasPassages: false) == "Referred to a scholar")
    }

    /// 2026-10-06: referred WITH passages shows one fixed line in the note's position and no
    /// section label; the engine's note is substituted on the panel only. A bare referral
    /// keeps the engine's note verbatim.
    @Test func referralNoteIsSubstitutedOnlyWhenPassagesFollow() {
        let engineNote = "This depends on your circumstances; please ask a scholar."
        #expect(AskPanelView.referralNote(engineNote: engineNote, hasPassages: true)
                == "The Quran's general position is below. Your own situation is a question for a scholar.")
        #expect(AskPanelView.referralNote(engineNote: engineNote, hasPassages: false) == engineNote)
        #expect(AskPanelView.referralNote(engineNote: "", hasPassages: false) == "")
    }
}
