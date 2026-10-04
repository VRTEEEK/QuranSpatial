//
//  AskSpeechTests.swift
//  QuranSpatialTests
//
//  The silence rule that ends an Ask capture, without a microphone.
//

import Testing
@testable import QuranSpatial

struct SilenceDetectorTests {
    @Test func stopsOneAndAHalfSecondsAfterTheLastSpeech() {
        var d = SilenceDetector()
        #expect(d.feed(rms: 0.001, at: 0.0) == .keepListening)
        #expect(d.feed(rms: 0.05, at: 0.5) == .keepListening)   // speech
        #expect(d.feed(rms: 0.05, at: 1.0) == .keepListening)   // speech
        #expect(d.feed(rms: 0.001, at: 2.0) == .keepListening)  // 1.0 s of silence
        #expect(d.feed(rms: 0.001, at: 2.49) == .keepListening) // 1.49 s
        #expect(d.feed(rms: 0.001, at: 2.5) == .stopSilence)    // 1.5 s
    }

    @Test func speechAfterASilenceRestartsTheClock() {
        var d = SilenceDetector()
        _ = d.feed(rms: 0.05, at: 0.0)
        _ = d.feed(rms: 0.001, at: 1.2)
        #expect(d.feed(rms: 0.05, at: 1.5) == .keepListening)
        #expect(d.feed(rms: 0.001, at: 2.75) == .keepListening)  // 1.25 s after the last speech
        #expect(d.feed(rms: 0.001, at: 3.0) == .stopSilence)     // 1.5 s, exact in binary
    }

    @Test func silenceBeforeAnySpeechDoesNotStopUntilTheNoSpeechCap() {
        var d = SilenceDetector()
        #expect(d.feed(rms: 0.001, at: 0.0) == .keepListening)
        #expect(d.feed(rms: 0.001, at: 5.0) == .keepListening)
        #expect(d.feed(rms: 0.001, at: 7.9) == .keepListening)
        #expect(d.feed(rms: 0.001, at: 8.0) == .stopNoSpeech)
    }

    @Test func theHardCapEndsEvenContinuousSpeech() {
        var d = SilenceDetector()
        for t in stride(from: 0.0, through: 19.9, by: 0.1) { #expect(d.feed(rms: 0.05, at: t) == .keepListening) }
        #expect(d.feed(rms: 0.05, at: 20.0) == .stopCap)
    }

    @Test func thresholdIsExactlyTheConfiguredRMS() {
        var d = SilenceDetector()
        _ = d.feed(rms: d.threshold, at: 0)       // at the threshold counts as speech
        #expect(d.heardSpeech)
        var e = SilenceDetector()
        _ = e.feed(rms: e.threshold - 0.0001, at: 0)
        #expect(!e.heardSpeech)
    }
}

struct AskDisplayTests {
    @Test func decisionLabelsAreTheFourAgreedOnes() {
        #expect(AskPanelView.decisionLabel("answered") == "From the sources")
        #expect(AskPanelView.decisionLabel("answered-in-part") == "From the sources, in part")
        #expect(AskPanelView.decisionLabel("referred") == "Referred to a scholar")
        #expect(AskPanelView.decisionLabel("declined") == "Not about this ayah")
    }
}
