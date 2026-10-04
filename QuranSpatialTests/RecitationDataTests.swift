//
//  RecitationDataTests.swift
//  QuranSpatialTests
//
//  Integrity of the recitation data, and of the two files agreeing with each other.
//

import Testing
import Foundation
@testable import QuranSpatial

struct RecitationDataTests {

    private func loadText() throws -> RecitationTextFile {
        let url = try #require(Bundle.main.url(forResource: "ar-rahman-text", withExtension: "json"))
        return try JSONDecoder().decode(RecitationTextFile.self, from: Data(contentsOf: url))
    }

    private func loadTimings() throws -> RecitationTimingsFile {
        let url = try #require(Bundle.main.url(forResource: AudioAssetReport.timingsResourceName,
                                               withExtension: AudioAssetReport.timingsResourceExtension))
        return try JSONDecoder().decode(RecitationTimingsFile.self, from: Data(contentsOf: url))
    }

    @Test func textFileHasEveryAyahExactlyOnceInOrder() throws {
        let text = try loadText()
        #expect(text.surah == 55)
        #expect(text.ayahCount == 78)
        #expect(text.ayat.count == 78)
        #expect(text.ayat.map(\.ayah) == Array(1...78))
        #expect(!text.intro.isEmpty)
        for ayah in text.ayat {
            #expect(!ayah.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// The cross-check that validates the two files against each other rather than taking
    /// either one's word. If the 31 segments the timings mark `refrain` really are the
    /// refrain, they must all carry the same text - and identical means scalar-for-scalar,
    /// not canonically equivalent, because `==` on String would not see a mark reordering.
    @Test func everyRefrainSegmentCarriesByteIdenticalText() throws {
        let text = try loadText()
        let timings = try loadTimings()

        let refrainAyat = timings.segments.filter { $0.kind == .refrain }.compactMap(\.ayah)
        #expect(refrainAyat.count == 31)

        let texts = try refrainAyat.map { try #require(text.text(forSegmentIndex: $0)) }
        let first = try #require(texts.first)
        for candidate in texts {
            #expect(isByteIdentical(candidate, first))
        }

        // And the marking must be exact: no ayah outside that set carries the same text.
        let refrainSet = Set(refrainAyat)
        for ayah in text.ayat where !refrainSet.contains(ayah.ayah) {
            #expect(!isByteIdentical(ayah.text, first))
        }
    }

    @Test func everyTimingsSegmentResolvesToText() throws {
        let text = try loadText()
        let timings = try loadTimings()
        for segment in timings.segments {
            #expect(text.text(forSegmentIndex: segment.index) != nil)
        }
    }

    /// The source text is in no standard normalization form, and normalizing it reorders
    /// combining marks. This asserts the shipped file is still in the source's own form, so
    /// an accidental normalization anywhere in the pipeline fails here rather than shipping.
    @Test func textIsNotNormalizedAndMustNotBe() throws {
        let text = try loadText()
        let body = text.intro + text.ayat.map(\.text).joined()
        #expect(!isByteIdentical(body, body.precomposedStringWithCanonicalMapping))
        #expect(!isByteIdentical(body, body.decomposedStringWithCanonicalMapping))
        // `==` cannot see the difference - which is exactly why isByteIdentical exists.
        #expect(body == body.precomposedStringWithCanonicalMapping)
    }

    @Test func segmentLookupIsCorrectAtBoundaries() throws {
        let timings = try loadTimings()
        let segments = timings.segments
        func index(_ t: Double) -> Int { RecitationCoordinator.segmentIndex(at: t, in: segments) }

        #expect(index(-5) == 0)
        #expect(index(0) == 0)
        for segment in segments {
            #expect(index(segment.start) == segment.index)
            #expect(index(segment.start + segment.duration / 2) == segment.index)
        }
        #expect(index(timings.totalDuration + 10) == 78)
    }
}
