//
//  HandPose.swift
//  QuranSpatial
//
//  Pure simd/Foundation. No ARKit or RealityKit imports, so gesture recognizers built on
//  this type are unit-testable against recorded joint data without a headset.
//

import Foundation
import simd

/// A snapshot of the hand joints a gesture recognizer needs, already resolved to world
/// space. Deliberately carries only the nine joints the dua recognizer reads, not the
/// full 27-joint `HandSkeleton` — add joints here as new recognizers need them.
struct HandPose: Equatable, Codable {

    enum Chirality: Equatable, Codable {
        case left
        case right
    }

    struct Joints: Equatable, Codable {
        var wrist: SIMD3<Float>
        var indexKnuckle: SIMD3<Float>
        var middleKnuckle: SIMD3<Float>
        var ringKnuckle: SIMD3<Float>
        var littleKnuckle: SIMD3<Float>
        var indexTip: SIMD3<Float>
        var middleTip: SIMD3<Float>
        var ringTip: SIMD3<Float>
        var littleTip: SIMD3<Float>
    }

    let chirality: Chirality
    let joints: Joints
    let isTracked: Bool
    let timestamp: TimeInterval

    /// Stand-in for "center of palm": the average of the wrist and the four knuckles.
    var palmCenter: SIMD3<Float> {
        (joints.wrist + joints.indexKnuckle + joints.middleKnuckle + joints.ringKnuckle + joints.littleKnuckle) / 5
    }

    /// Outward-facing palm normal. The cross-product order is flipped by chirality:
    /// index-to-little winds the opposite way on a mirrored hand, so a single fixed order
    /// would point the correct direction on one hand and the wrong one on the other.
    var palmNormal: SIMD3<Float> {
        let toIndex = joints.indexKnuckle - joints.wrist
        let toLittle = joints.littleKnuckle - joints.wrist
        let normal = chirality == .right ? cross(toIndex, toLittle) : cross(toLittle, toIndex)
        let length = simd_length(normal)
        return length > 0 ? normal / length : .zero
    }

    /// Mean, across the four fingers, of (fingertip distance from wrist) / (knuckle
    /// distance from wrist). Near 1 for a curled or fisted finger, well above it for an
    /// extended one.
    var fingerExtension: Float {
        func ratio(tip: SIMD3<Float>, knuckle: SIMD3<Float>) -> Float {
            let knuckleDistance = simd_length(knuckle - joints.wrist)
            guard knuckleDistance > 0 else { return 0 }
            return simd_length(tip - joints.wrist) / knuckleDistance
        }
        let ratios = [
            ratio(tip: joints.indexTip, knuckle: joints.indexKnuckle),
            ratio(tip: joints.middleTip, knuckle: joints.middleKnuckle),
            ratio(tip: joints.ringTip, knuckle: joints.ringKnuckle),
            ratio(tip: joints.littleTip, knuckle: joints.littleKnuckle)
        ]
        return ratios.reduce(0, +) / Float(ratios.count)
    }
}
