//
//  DuaGuidanceTests.swift
//  QuranSpatialTests
//
//  The guidance effect's progress mapping is pure: recognizer diagnostics in, 0...1 out,
//  thresholds read from the recognizer and never duplicated here.
//

import Foundation
import Testing
@testable import QuranSpatial

struct DuaGuidanceTests {
    private func diagnostics(inward: Float, towardHead: Float, fingerExtension: Float, belowHeadY: Float,
                             separation: Float, state: DuaPostureRecognizer.State = .idle,
                             hold: TimeInterval? = nil) -> DuaPostureRecognizer.Diagnostics {
        var d = DuaPostureRecognizer.Diagnostics()
        d.leftTracked = true; d.rightTracked = true
        d.leftPalmInwardDot = inward; d.rightPalmInwardDot = inward
        d.leftPalmTowardHeadDot = towardHead; d.rightPalmTowardHeadDot = towardHead
        d.leftFingerExtension = fingerExtension; d.rightFingerExtension = fingerExtension
        d.leftBelowHeadY = belowHeadY; d.rightBelowHeadY = belowHeadY
        d.separation = separation
        d.state = state
        d.holdProgress = hold
        return d
    }

    @Test func untrackedHandsHaveNoProgress() {
        let p = DuaGuidanceProgress(diagnostics: DuaPostureRecognizer.Diagnostics())
        #expect(p.left == 0 && p.right == 0 && p.overall == 0)
        #expect(!p.leftTracked && !p.rightTracked)
    }

    @Test func aWrongPostureIsNearZeroAndACorrectOneIsFull() {
        // Palms away from each other and from the head, fingers curled, hands in the lap, far apart.
        let wrong = DuaGuidanceProgress(diagnostics: diagnostics(inward: -0.5, towardHead: -0.2, fingerExtension: 0.9,
                                                                   belowHeadY: 0.9, separation: 0.6))
        #expect(wrong.left == 0 && wrong.right == 0 && wrong.overall == 0)
        // Every gate at or past its enter bound.
        typealias R = DuaPostureRecognizer
        let right = DuaGuidanceProgress(diagnostics: diagnostics(inward: R.palmInwardDotEnterMin, towardHead: R.palmTowardHeadDotEnterMin,
                                                                   fingerExtension: R.fingerExtensionEnterMin, belowHeadY: R.maxBelowHeadYEnter,
                                                                   separation: 0.2))
        #expect(right.left == 1 && right.right == 1 && right.overall == 1)
    }

    @Test func gettingCloserRaisesProgressMonotonically() {
        var previous: Float = -1
        for step in 0...10 {
            let f = Float(step) / 10
            let d = diagnostics(inward: 0.25 + 0.33 * f, towardHead: 0.15 + 0.27 * f, fingerExtension: 1.0 + 0.3 * f,
                                belowHeadY: 0.65 - 0.2 * f, separation: 0.2)
            let p = DuaGuidanceProgress(diagnostics: d)
            #expect(p.overall >= previous)
            previous = p.overall
        }
        #expect(previous > 0.999)
    }

    @Test func separationOutsideTheBandLowersOnlyTheWholePostureValue() {
        typealias R = DuaPostureRecognizer
        let d = diagnostics(inward: R.palmInwardDotEnterMin, towardHead: R.palmTowardHeadDotEnterMin,
                            fingerExtension: R.fingerExtensionEnterMin, belowHeadY: 0.3, separation: 0.45)   // 0.10 past the band
        let p = DuaGuidanceProgress(diagnostics: d)
        #expect(p.left == 1 && p.right == 1)
        #expect(p.overall < 1 && p.overall > 0.6)
    }

    @Test func theCommitWindowAndTheHoldReadAsNearlyAndFullyThere() {
        let entering = DuaGuidanceProgress(diagnostics: diagnostics(inward: 0.3, towardHead: 0.2, fingerExtension: 1.1, belowHeadY: 0.6,
                                                                      separation: 0.2, state: .entering(since: 0), hold: 0.75))
        #expect(abs(entering.overall - 0.925) < 0.001)      // 0.85 + 0.15 x (0.75 / 1.5)
        let held = DuaGuidanceProgress(diagnostics: diagnostics(inward: 0.3, towardHead: 0.2, fingerExtension: 1.1, belowHeadY: 0.6,
                                                                  separation: 0.2, state: .held))
        #expect(held.overall == 1)
    }

    @Test func oneTrackedHandGetsItsOwnClosenessButNoWholePostureValue() {
        var d = diagnostics(inward: 0.58, towardHead: 0.42, fingerExtension: 1.3, belowHeadY: 0.3, separation: 0.2)
        d.rightTracked = false
        let p = DuaGuidanceProgress(diagnostics: d)
        #expect(p.left == 1 && p.right == 0 && p.overall == 0)
    }
}
