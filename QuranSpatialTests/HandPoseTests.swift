//
//  HandPoseTests.swift
//  QuranSpatialTests
//
//  Pure geometry tests against synthesized joint data - no ARKit, no device needed.
//

import Foundation
import Testing
import simd
@testable import QuranSpatial

struct HandPoseTests {

    /// `HandPose.palmNormal`'s cross-product order is chirality-dependent (index-to-little
    /// winds the opposite way on a mirrored hand). This is exactly the bug class where a
    /// recognizer works on one hand and silently inverts on the other - assert both
    /// chiralities resolve to the same target normal from geometry that is itself mirrored
    /// the way a real pair of hands is (index/little knuckle offsets swapped between hands).
    @Test func palmNormalMatchesRequestedDirectionForBothChiralities() {
        let target = normalize(SIMD3<Float>(0.3, 1, 0.4))
        let left = TestHandPoseFixtures.hand(chirality: .left, wrist: .zero, normalDirection: target)
        let right = TestHandPoseFixtures.hand(chirality: .right, wrist: .zero, normalDirection: target)

        #expect(simd_length(left.palmNormal - target) < 0.001)
        #expect(simd_length(right.palmNormal - target) < 0.001)
    }

    @Test func palmNormalDotWithReferenceMatchesConstructedAngle() {
        // Construct a normal at a known 60 degree angle from world-up: cos(60 deg) = 0.5.
        let normal = SIMD3<Float>(0, cos(Float.pi / 3), sin(Float.pi / 3))
        let hand = TestHandPoseFixtures.hand(chirality: .right, wrist: .zero, normalDirection: normal)

        #expect(abs(dot(hand.palmNormal, SIMD3<Float>(0, 1, 0)) - 0.5) < 0.01)
    }

    @Test func fingerExtensionRatioMatchesTipToKnuckleDistanceRatio() {
        let hand = TestHandPoseFixtures.hand(chirality: .right, wrist: .zero, extensionRatio: 1.78)
        #expect(abs(hand.fingerExtension - 1.78) < 0.01)
    }

    @Test func curledFingerExtensionRatioIsNearOne() {
        let hand = TestHandPoseFixtures.hand(chirality: .right, wrist: .zero, extensionRatio: 1.05)
        #expect(abs(hand.fingerExtension - 1.05) < 0.01)
    }
}

/// Synthesizes `HandPose` fixtures whose geometry is chosen to hit known, precomputable
/// values from `HandPose`'s formulas - not meant to look like a real captured hand.
enum TestHandPoseFixtures {

    /// Builds a hand whose `palmNormal` is exactly `normalDirection` (any unit-length-able
    /// vector, not just "up") by solving for index/little knuckle offsets whose cross
    /// product resolves to it - see the derivation in `HandPose.palmNormal`.
    static func hand(
        chirality: HandPose.Chirality,
        wrist: SIMD3<Float>,
        normalDirection: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        extensionRatio: Float = 1.78,
        isTracked: Bool = true,
        timestamp: TimeInterval = 0
    ) -> HandPose {
        let n = normalize(normalDirection)
        // Any axis not parallel to n works as a starting point for building an orthonormal
        // basis {u, v, n} via cross products.
        let axis: SIMD3<Float> = abs(dot(n, SIMD3<Float>(0, 1, 0))) < 0.9
            ? SIMD3<Float>(0, 1, 0)
            : SIMD3<Float>(1, 0, 0)
        let u = normalize(cross(n, axis))
        let v = cross(n, u) // already unit length: n and u are orthonormal

        // Right hand: cross(toIndex, toLittle) = n  =>  toIndex = u, toLittle = v.
        // Left hand:  cross(toLittle, toIndex) = n  =>  toLittle = u, toIndex = v.
        let indexDir = chirality == .right ? u : v
        let littleDir = chirality == .right ? v : u
        let middleDir = normalize(indexDir + n * 0.2)
        let ringDir = normalize(littleDir + n * 0.2)

        let knuckleDistance: Float = 0.09
        let tipDistance: Float = knuckleDistance * extensionRatio

        func knuckle(_ dir: SIMD3<Float>) -> SIMD3<Float> { wrist + dir * knuckleDistance }
        func tip(_ dir: SIMD3<Float>) -> SIMD3<Float> { wrist + dir * tipDistance }

        return HandPose(
            chirality: chirality,
            joints: HandPose.Joints(
                wrist: wrist,
                indexKnuckle: knuckle(indexDir),
                middleKnuckle: knuckle(middleDir),
                ringKnuckle: knuckle(ringDir),
                littleKnuckle: knuckle(littleDir),
                indexTip: tip(indexDir),
                middleTip: tip(middleDir),
                ringTip: tip(ringDir),
                littleTip: tip(littleDir)
            ),
            isTracked: isTracked,
            timestamp: timestamp
        )
    }
}
