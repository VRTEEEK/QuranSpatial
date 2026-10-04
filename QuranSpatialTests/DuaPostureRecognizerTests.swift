//
//  DuaPostureRecognizerTests.swift
//  QuranSpatialTests
//
//  Drives DuaPostureRecognizer against synthesized HandPose fixtures - no ARKit, no
//  device needed. See TestHandPoseFixtures in HandPoseTests.swift.
//

import Foundation
import Testing
import simd
@testable import QuranSpatial

struct DuaPostureRecognizerTests {

    private let headPosition = SIMD3<Float>(0, 1.6, 0)
    private let leftWrist = SIMD3<Float>(-0.1, 1.3, -0.3) // 0.3m below head, close together
    private let rightWrist = SIMD3<Float>(0.1, 1.3, -0.3)

    /// The direction a palm needs to face to satisfy both orientation criteria at once:
    /// partway between "toward the other hand" and "toward the head" - the cupped,
    /// face-angled shape a real dua posture measured on device.
    ///
    /// The blend weight is SOLVED against the current enter bounds rather than hardcoded.
    /// When `palmInwardDotEnterMin` was raised 0.40 -> 0.58 for entry-only acceptance, a
    /// fixed blend stopped qualifying and every recognizer test failed at once - the
    /// fixtures were encoding the old thresholds. Deriving the weight means a threshold
    /// change moves the fixtures with it, and a test that fails after one is reporting a
    /// real regression rather than its own staleness.
    private func comfortableNormal(from wrist: SIMD3<Float>, towardOther other: SIMD3<Float>) -> SIMD3<Float> {
        blended(from: wrist, towardOther: other, weight: Self.solvedBlendWeight)
    }

    private func blended(from wrist: SIMD3<Float>, towardOther other: SIMD3<Float>, weight: Float) -> SIMD3<Float> {
        let toOther = normalize(other - wrist)
        let toHead = normalize(headPosition - wrist)
        return normalize(toOther * weight + toHead * (1 - weight))
    }

    /// Blend weight maximising the tightest margin over all four orientation criteria.
    /// Solved once, on the real constructed poses - `palmCenter` shifts as a hand rotates,
    /// so the criteria cannot be evaluated in closed form from the target normal alone.
    private static let solvedBlendWeight: Float = {
        let head = SIMD3<Float>(0, 1.6, 0)
        let leftWrist = SIMD3<Float>(-0.1, 1.3, -0.3)
        let rightWrist = SIMD3<Float>(0.1, 1.3, -0.3)

        func normalFor(_ wrist: SIMD3<Float>, _ other: SIMD3<Float>, _ w: Float) -> SIMD3<Float> {
            let toOther = normalize(other - wrist)
            let toHead = normalize(head - wrist)
            return normalize(toOther * w + toHead * (1 - w))
        }

        var best: Float = 0.5
        var bestMargin = -Float.infinity
        for step in 0...40 {
            let w = 0.2 + Float(step) * 0.02
            let left = TestHandPoseFixtures.hand(chirality: .left, wrist: leftWrist,
                                                 normalDirection: normalFor(leftWrist, rightWrist, w))
            let right = TestHandPoseFixtures.hand(chirality: .right, wrist: rightWrist,
                                                  normalDirection: normalFor(rightWrist, leftWrist, w))
            let lc = left.palmCenter, rc = right.palmCenter
            let margin = min(
                dot(left.palmNormal, normalize(rc - lc)) - DuaPostureRecognizer.palmInwardDotEnterMin,
                dot(right.palmNormal, normalize(lc - rc)) - DuaPostureRecognizer.palmInwardDotEnterMin,
                dot(left.palmNormal, normalize(head - lc)) - DuaPostureRecognizer.palmTowardHeadDotEnterMin,
                dot(right.palmNormal, normalize(head - rc)) - DuaPostureRecognizer.palmTowardHeadDotEnterMin
            )
            if margin > bestMargin { bestMargin = margin; best = w }
        }
        return best
    }()

    /// The left hand's inward dot for a given drift angle, measured on the constructed
    /// pose rather than predicted from the target normal.
    private func inwardDot(driftDegrees degrees: Float) -> Float {
        let left = openLeft(normalDirection: normalDrifted(fromWrist: leftWrist, towardOther: rightWrist, byDegrees: degrees))
        let right = openRight()
        return dot(left.palmNormal, normalize(right.palmCenter - left.palmCenter))
    }

    /// Smallest drift that lands the inward dot inside `range`. Scanned rather than
    /// derived, for the same `palmCenter` coupling reason.
    private func driftAngle(landingInwardIn range: ClosedRange<Float>) -> Float {
        for tenths in 0...1200 {
            let degrees = Float(tenths) / 10
            if range.contains(inwardDot(driftDegrees: degrees)) { return degrees }
        }
        Issue.record("no drift angle produced an inward dot in \(range)")
        return 0
    }

    private var betweenBoundsDrift: Float {
        driftAngle(landingInwardIn:
            (DuaPostureRecognizer.palmInwardDotExitMin + 0.01)...(DuaPostureRecognizer.palmInwardDotEnterMin - 0.01))
    }

    private var belowExitBoundDrift: Float {
        driftAngle(landingInwardIn: -1...(DuaPostureRecognizer.palmInwardDotExitMin - 0.05))
    }

    /// Rotates the comfortable normal around the `toHead` axis, which sweeps
    /// `palmInwardDot` while mostly leaving `palmTowardHeadDot` alone.
    private func normalDrifted(fromWrist wrist: SIMD3<Float>, towardOther other: SIMD3<Float>, byDegrees degrees: Float) -> SIMD3<Float> {
        let toHead = normalize(headPosition - wrist)
        let comfortable = comfortableNormal(from: wrist, towardOther: other)
        let rotation = simd_quatf(angle: degrees * .pi / 180, axis: toHead)
        return rotation.act(comfortable)
    }

    private func openLeft(normalDirection: SIMD3<Float>? = nil, isTracked: Bool = true) -> HandPose {
        TestHandPoseFixtures.hand(
            chirality: .left,
            wrist: leftWrist,
            normalDirection: normalDirection ?? comfortableNormal(from: leftWrist, towardOther: rightWrist),
            isTracked: isTracked
        )
    }

    private func openRight(normalDirection: SIMD3<Float>? = nil, isTracked: Bool = true) -> HandPose {
        TestHandPoseFixtures.hand(
            chirality: .right,
            wrist: rightWrist,
            normalDirection: normalDirection ?? comfortableNormal(from: rightWrist, towardOther: leftWrist),
            isTracked: isTracked
        )
    }

    /// Runs the canonical dua pose forward until it has fired (or a generous timeout),
    /// returning the recognizer at that point.
    private func reachHeld() -> DuaPostureRecognizer {
        var recognizer = DuaPostureRecognizer()
        var t: TimeInterval = 0
        while t <= DuaPostureRecognizer.commitWindow + 0.2 {
            recognizer.update(left: openLeft(), right: openRight(), headPosition: headPosition, timestamp: t)
            t += 0.05
        }
        return recognizer
    }

    @Test func firesDetectedOnceAfterHoldDuration() {
        var recognizer = DuaPostureRecognizer()
        var events: [DuaPostureRecognizer.Event] = []
        var t: TimeInterval = 0
        while t <= DuaPostureRecognizer.commitWindow + 0.5 {
            if let event = recognizer.update(left: openLeft(), right: openRight(), headPosition: headPosition, timestamp: t) {
                events.append(event)
            }
            t += 0.05
        }

        #expect(events == [.detected])
        #expect(recognizer.state == .held)
    }

    @Test func restingHandsNeverEnter() {
        var recognizer = DuaPostureRecognizer()
        let low = SIMD3<Float>(-0.15, headPosition.y - 1.0, -0.2)
        let restingLeft = TestHandPoseFixtures.hand(chirality: .left, wrist: low)
        let restingRight = TestHandPoseFixtures.hand(chirality: .right, wrist: low + SIMD3<Float>(0.3, 0, 0))

        var t: TimeInterval = 0
        while t <= 2.0 {
            recognizer.update(left: restingLeft, right: restingRight, headPosition: headPosition, timestamp: t)
            t += 0.05
        }
        #expect(recognizer.state == .idle)
    }

    /// The world-up test this replaced would have accepted this. Palms pointing straight
    /// down must still be rejected under the new body-relative criteria.
    @Test func palmsDownNeverEnter() {
        var recognizer = DuaPostureRecognizer()
        let down = SIMD3<Float>(0, -1, 0)

        var t: TimeInterval = 0
        while t <= 2.0 {
            recognizer.update(
                left: openLeft(normalDirection: down),
                right: openRight(normalDirection: down),
                headPosition: headPosition,
                timestamp: t
            )
            t += 0.05
        }
        #expect(recognizer.state == .idle)
    }

    /// Palms facing away from the wearer (e.g. pushing something away) must be rejected.
    @Test func palmsForwardNeverEnter() {
        var recognizer = DuaPostureRecognizer()
        let forward = SIMD3<Float>(0, 0, -1) // away from head, which sits at z = 0

        var t: TimeInterval = 0
        while t <= 2.0 {
            recognizer.update(
                left: openLeft(normalDirection: forward),
                right: openRight(normalDirection: forward),
                headPosition: headPosition,
                timestamp: t
            )
            t += 0.05
        }
        #expect(recognizer.state == .idle)
    }

    @Test func singleTrackedHandNeverEnters() {
        var recognizer = DuaPostureRecognizer()
        var t: TimeInterval = 0
        while t <= 2.0 {
            recognizer.update(left: openLeft(), right: nil, headPosition: headPosition, timestamp: t)
            t += 0.05
        }
        #expect(recognizer.state == .idle)
    }

    @Test func curledFingersNeverEnter() {
        var recognizer = DuaPostureRecognizer()
        let fistLeft = TestHandPoseFixtures.hand(
            chirality: .left, wrist: leftWrist,
            normalDirection: comfortableNormal(from: leftWrist, towardOther: rightWrist),
            extensionRatio: 1.05
        )
        let fistRight = TestHandPoseFixtures.hand(
            chirality: .right, wrist: rightWrist,
            normalDirection: comfortableNormal(from: rightWrist, towardOther: leftWrist),
            extensionRatio: 1.05
        )

        var t: TimeInterval = 0
        while t <= 2.0 {
            recognizer.update(left: fistLeft, right: fistRight, headPosition: headPosition, timestamp: t)
            t += 0.05
        }
        #expect(recognizer.state == .idle)
    }

    @Test func handsTooFarApartNeverEnter() {
        var recognizer = DuaPostureRecognizer()
        let farLeftWrist = SIMD3<Float>(-0.4, 1.3, -0.3)
        let farRightWrist = SIMD3<Float>(0.4, 1.3, -0.3)
        let farLeft = TestHandPoseFixtures.hand(
            chirality: .left, wrist: farLeftWrist,
            normalDirection: comfortableNormal(from: farLeftWrist, towardOther: farRightWrist)
        )
        let farRight = TestHandPoseFixtures.hand(
            chirality: .right, wrist: farRightWrist,
            normalDirection: comfortableNormal(from: farRightWrist, towardOther: farLeftWrist)
        )

        var t: TimeInterval = 0
        while t <= 2.0 {
            recognizer.update(left: farLeft, right: farRight, headPosition: headPosition, timestamp: t)
            t += 0.05
        }
        #expect(recognizer.state == .idle)
    }

    /// The core of the hysteresis design: once held, a value between the exit and enter
    /// bounds must NOT drop the hold - only crossing below the (looser) exit bound may.
    /// Perturbs only the LEFT hand's orientation, leaving the right hand at its comfortable
    /// value: `palmCenter` (used for `toOther`/`toHead`) is the average of the wrist and
    /// four knuckles, and those knuckle offsets are large enough relative to the hand
    /// separation used in these fixtures that `palmCenter` itself shifts as a hand's
    /// orientation rotates - so drifting both hands by the same angle at once compounds
    /// unevenly between them. Perturbing one hand in isolation avoids that and is a more
    /// targeted test regardless. 60 degrees was chosen empirically (not derived in closed
    /// form, for the reason above) by computing the fixture's actual palmInwardDot at a
    /// range of angles: it lands at ~0.27, inside the gap between palmInwardDotExitMin
    /// (0.25) and palmInwardDotEnterMin (0.4), while palmTowardHeadDot stays ~0.81, well
    /// clear of its own exit bound.
    @Test func holdSurvivesDriftBetweenExitAndEnterBounds() {
        var recognizer = reachHeld()
        #expect(recognizer.state == .held)

        let driftedLeftNormal = normalDrifted(fromWrist: leftWrist, towardOther: rightWrist, byDegrees: betweenBoundsDrift)

        let event = recognizer.update(
            left: openLeft(normalDirection: driftedLeftNormal),
            right: openRight(),
            headPosition: headPosition,
            timestamp: DuaPostureRecognizer.commitWindow + 0.25
        )

        #expect(event == nil)
        #expect(recognizer.state == .held)
    }

    /// The mirror of `holdSurvivesDriftBetweenExitAndEnterBounds`, on the other side of the
    /// commit. The same 60-degree between-bounds drift that a committed hold tolerates must
    /// reset an *uncommitted* one, because the commit window is sustained at the enter
    /// bounds - a pose cannot touch the enter bound once and then coast to a detection at
    /// exit-bound quality.
    @Test func driftBetweenBoundsDuringCommitWindowNeverCommits() {
        var recognizer = DuaPostureRecognizer()
        recognizer.update(left: openLeft(), right: openRight(), headPosition: headPosition, timestamp: 0)
        #expect(recognizer.state == .entering(since: 0))

        let driftedLeftNormal = normalDrifted(fromWrist: leftWrist, towardOther: rightWrist, byDegrees: betweenBoundsDrift)
        var events: [DuaPostureRecognizer.Event?] = []
        var t: TimeInterval = 0.05
        while t <= DuaPostureRecognizer.commitWindow + 0.5 {
            events.append(recognizer.update(
                left: openLeft(normalDirection: driftedLeftNormal),
                right: openRight(),
                headPosition: headPosition,
                timestamp: t
            ))
            t += 0.05
        }

        #expect(events.allSatisfy { $0 == nil })
        #expect(recognizer.state == .idle)
    }

    /// Same single-hand-perturbation approach as `holdSurvivesDriftBetweenExitAndEnterBounds`,
    /// but at 70 degrees: the fixture's `palmInwardDot` lands at ~0.12, below
    /// `palmInwardDotExitMin` (0.25), which should break the hold.
    @Test func droppingBelowExitBoundWhileHeldReleases() {
        var recognizer = reachHeld()
        #expect(recognizer.state == .held)

        let farLeftNormal = normalDrifted(fromWrist: leftWrist, towardOther: rightWrist, byDegrees: belowExitBoundDrift)
        let event = recognizer.update(
            left: openLeft(normalDirection: farLeftNormal),
            right: openRight(),
            headPosition: headPosition,
            timestamp: DuaPostureRecognizer.commitWindow + 0.25
        )

        #expect(event == .released)
        #expect(recognizer.state == .idle)
    }

    /// The state machine only moves when an anchor arrives, so a total tracking dropout
    /// freezes it: a hold would persist for the length of the dropout and release only when
    /// tracking resumed. Once detection drives playback that is recitation continuing
    /// through an abandoned gesture.
    @Test func advanceReleasesAHeldPoseWhenDataStopsArriving() {
        var recognizer = reachHeld()
        #expect(recognizer.state == .held)

        // Inside the tolerance: nothing yet.
        #expect(recognizer.advance(to: DuaPostureRecognizer.commitWindow + 0.1) == nil)
        #expect(recognizer.state == .held)

        let event = recognizer.advance(
            to: DuaPostureRecognizer.commitWindow + DuaPostureRecognizer.maxTrackingGap + 0.3
        )
        #expect(event == .released)
        #expect(recognizer.state == .idle)
    }

    /// The same rule must abandon a part-accumulated commit window, and must never
    /// announce anything for one - nothing was detected, so nothing can be released.
    @Test func advanceAbandonsAnUncommittedPoseSilently() {
        var recognizer = DuaPostureRecognizer()
        recognizer.update(left: openLeft(), right: openRight(), headPosition: headPosition, timestamp: 0)
        #expect(recognizer.state == .entering(since: 0))

        let event = recognizer.advance(to: DuaPostureRecognizer.maxTrackingGap + 0.2)
        #expect(event == nil)
        #expect(recognizer.state == .idle)
    }

    /// `advance` applies only the gap rule. It must never be able to start or sustain a
    /// hold, whatever the clock says.
    @Test func advanceCannotStartAHold() {
        var recognizer = DuaPostureRecognizer()
        #expect(recognizer.advance(to: 10) == nil)
        #expect(recognizer.state == .idle)
    }

    /// Cupped-together dua hands are exactly the geometry most likely to have one hand
    /// briefly occlude the other from the headset's hand-tracking cameras - a hold must
    /// survive a short dropout rather than resetting the hold timer.
    @Test func briefTrackingDropoutWhileEnteringDoesNotResetHoldTimer() {
        var recognizer = DuaPostureRecognizer()

        recognizer.update(left: openLeft(), right: openRight(), headPosition: headPosition, timestamp: 0)
        guard case .entering = recognizer.state else {
            Issue.record("expected .entering, got \(recognizer.state)")
            return
        }

        // Dropout well inside maxTrackingGap (0.15s).
        let dropoutTime: TimeInterval = 0.1
        recognizer.update(left: nil, right: nil, headPosition: headPosition, timestamp: dropoutTime)
        guard case .entering = recognizer.state else {
            Issue.record("expected .entering to survive a brief dropout, got \(recognizer.state)")
            return
        }

        // Resume tracking; the hold should still complete measured from the ORIGINAL start.
        var fired = false
        var t = dropoutTime + 0.05
        while t <= DuaPostureRecognizer.commitWindow + 0.2 {
            if recognizer.update(left: openLeft(), right: openRight(), headPosition: headPosition, timestamp: t) == .detected {
                fired = true
            }
            t += 0.05
        }
        #expect(fired)
    }

    @Test func trackingGapLongerThanToleranceResetsToIdle() {
        var recognizer = DuaPostureRecognizer()

        recognizer.update(left: openLeft(), right: openRight(), headPosition: headPosition, timestamp: 0)
        guard case .entering = recognizer.state else {
            Issue.record("expected .entering, got \(recognizer.state)")
            return
        }

        // Dropout past maxTrackingGap (0.15s).
        recognizer.update(left: nil, right: nil, headPosition: headPosition, timestamp: 0.3)
        #expect(recognizer.state == .idle)
    }

    /// The near-zero-`toHead` guard, exercised directly: a hand positioned right next to
    /// the head (as when adjusting the headset) must not pass `palmTowardHeadDot` by
    /// accident just because the too-short reference vector happened to normalize toward
    /// something plausible-looking. Separation and extension are kept otherwise valid so
    /// this isolates the guard rather than failing for an unrelated reason.
    @Test func nearHeadHandDoesNotFalselyPassTowardHeadCriterion() {
        var recognizer = DuaPostureRecognizer()
        let nearHeadWrist = headPosition + SIMD3<Float>(0.02, 0, 0) // well under minReferenceVectorLength (0.03m)
        let otherWrist = nearHeadWrist + SIMD3<Float>(0.2, 0, 0) // separation still in-band

        let nearHeadHand = TestHandPoseFixtures.hand(
            chirality: .left,
            wrist: nearHeadWrist,
            normalDirection: normalize(otherWrist - nearHeadWrist) // pointed straight at the other hand
        )
        let otherHand = TestHandPoseFixtures.hand(
            chirality: .right,
            wrist: otherWrist,
            normalDirection: normalize(nearHeadWrist - otherWrist)
        )

        var t: TimeInterval = 0
        while t <= 2.0 {
            recognizer.update(left: nearHeadHand, right: otherHand, headPosition: headPosition, timestamp: t)
            t += 0.05
        }
        #expect(recognizer.state == .idle)
    }

    /// Same guard, the `toOther` side: coincident hands must not crash or produce a
    /// garbage direction. In practice the separation-band check already rejects this, but
    /// the guard should hold regardless of gating order.
    @Test func coincidentHandsDoNotFalselyPassInwardCriterion() {
        var recognizer = DuaPostureRecognizer()
        let wrist = SIMD3<Float>(0, 1.3, -0.3)
        let left = TestHandPoseFixtures.hand(chirality: .left, wrist: wrist)
        let right = TestHandPoseFixtures.hand(chirality: .right, wrist: wrist + SIMD3<Float>(0.01, 0, 0))

        var t: TimeInterval = 0
        while t <= 2.0 {
            recognizer.update(left: left, right: right, headPosition: headPosition, timestamp: t)
            t += 0.05
        }
        #expect(recognizer.state == .idle)
    }
}
