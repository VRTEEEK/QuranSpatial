//
//  EnglishLayerVisibilityTests.swift
//  QuranSpatialTests
//
//  The D4 visibility rule, run over the real dissolve function and the real timings: the
//  English is up only while the Arabic is settled, hides the moment the outgoing dissolve
//  starts, returns when the incoming fade completes, and stays up under an Ask pin.
//

import Foundation
import Testing
@testable import QuranSpatial

struct EnglishLayerVisibilityTests {

    private func loadTimings() throws -> RecitationTimingsFile {
        let url = try #require(Bundle.main.url(forResource: AudioAssetReport.timingsResourceName,
                                               withExtension: AudioAssetReport.timingsResourceExtension))
        return try JSONDecoder().decode(RecitationTimingsFile.self, from: Data(contentsOf: url))
    }

    private func visible(at time: TimeInterval, _ segment: RecitationSegment, isFinal: Bool, pinned: Bool = false) -> Bool {
        EnglishLayerVisibility.isVisible(
            arabicProgress: Dissolve.progress(atAudioTime: time, segment: segment, isFinalSegment: isFinal),
            isPinned: pinned)
    }

    /// Every segment: hidden through the incoming fade, shown once settled, hidden from the
    /// first instant of the outgoing dissolve to the end. The final segment never hides.
    @Test func englishShowsOnlyWhileTheArabicIsSettled() throws {
        let timings = try loadTimings()
        let finalIndex = timings.segments.last?.index
        for segment in timings.segments {
            let isFinal = segment.index == finalIndex
            let settled = segment.start + Dissolve.inDuration + 0.001   // +1 ms: see AskTransitionTests on the 1e-14 at the exact instant
            let outStart = Dissolve.outgoingStart(of: segment, isFinalSegment: isFinal)

            #expect(!visible(at: segment.start, segment, isFinal: isFinal), "segment \(segment.index): boundary")
            #expect(!visible(at: segment.start + Dissolve.inDuration / 2, segment, isFinal: isFinal), "segment \(segment.index): mid fade-in")
            #expect(visible(at: settled, segment, isFinal: isFinal), "segment \(segment.index): fade-in complete")
            #expect(visible(at: (segment.start + segment.end) / 2, segment, isFinal: isFinal), "segment \(segment.index): mid-ayah")

            if let outStart {
                #expect(visible(at: outStart - 0.001, segment, isFinal: isFinal), "segment \(segment.index): just before out")
                // Exactly at outStart progress is 0 (the ramp begins there); one frame later it is not.
                #expect(!visible(at: outStart + 1.0 / 90.0, segment, isFinal: isFinal), "segment \(segment.index): first frame of out")
                #expect(!visible(at: segment.end - 0.001, segment, isFinal: isFinal), "segment \(segment.index): end")
            } else {
                #expect(isFinal)
                #expect(visible(at: segment.end - 0.001, segment, isFinal: isFinal), "final segment stays up to the end")
                #expect(visible(at: segment.end + 10, segment, isFinal: isFinal))
            }
        }
    }

    /// Under a pin the English stays up whatever the progress - through the recall ramp
    /// (progress still > 0) and through the pre-roll (clock in the previous ayah).
    @Test func thePinKeepsTheEnglishUpRegardlessOfProgress() throws {
        let timings = try loadTimings()
        let segment = try #require(timings.segments.first { $0.index == 13 })
        let outStart = try #require(Dissolve.outgoingStart(of: segment, isFinalSegment: false))
        #expect(visible(at: outStart + 0.4, segment, isFinal: false, pinned: true))
        #expect(visible(at: segment.start, segment, isFinal: false, pinned: true))
        #expect(visible(at: segment.start - 0.3, segment, isFinal: false, pinned: true))
        for p: Float in [0, 0.001, 0.5, 1] {
            #expect(EnglishLayerVisibility.isVisible(arabicProgress: p, isPinned: true))
        }
    }

    /// The rule itself: exactly 0 shows, anything above hides, and no bound material (the
    /// hard-cutting fallback, where the Arabic is at full opacity) shows.
    @Test func exactlyZeroShowsAndAnythingElseHides() {
        #expect(EnglishLayerVisibility.isVisible(arabicProgress: 0, isPinned: false))
        #expect(!EnglishLayerVisibility.isVisible(arabicProgress: 1e-6, isPinned: false))
        #expect(!EnglishLayerVisibility.isVisible(arabicProgress: 0.5, isPinned: false))
        #expect(!EnglishLayerVisibility.isVisible(arabicProgress: 1, isPinned: false))
        #expect(EnglishLayerVisibility.isVisible(arabicProgress: nil, isPinned: false))
    }
}
