//
//  DuaDebugVisualization.swift
//  QuranSpatial
//
//  Renders the dua recognizer's raw inputs and state directly in the immersive space, so
//  it's visible on device *why* it is or isn't firing - not just whether it is. Debug-only;
//  none of this is part of the shipped experience and it never touches playback or the
//  dissolve.
//

import RealityKit
import UIKit
import simd

@MainActor
final class DuaDebugVisualization {

    private static let jointRadius: Float = 0.006
    private static let normalLineLength: Float = 0.08
    private static let normalLineThickness: Float = 0.004
    private static let stateIndicatorRadius: Float = 0.015
    /// Fixed in front of the wearer, clear of the ayah plane so the two never overlap.
    private static let stateIndicatorPosition = SIMD3<Float>(0.4, 1.75, -1.2)

    private let root = Entity()
    private let leftJointMarkers: [ModelEntity]
    private let rightJointMarkers: [ModelEntity]
    private let leftNormalLine: ModelEntity
    private let rightNormalLine: ModelEntity
    private let stateIndicator: ModelEntity

    var entity: Entity { root }

    init() {
        let jointMesh = MeshResource.generateSphere(radius: Self.jointRadius)
        var leftJointMaterial = UnlitMaterial()
        leftJointMaterial.color = .init(tint: .cyan)
        var rightJointMaterial = UnlitMaterial()
        rightJointMaterial.color = .init(tint: .magenta)

        func makeMarkers(material: UnlitMaterial, into root: Entity) -> [ModelEntity] {
            (0..<9).map { _ in
                let marker = ModelEntity(mesh: jointMesh, materials: [material])
                marker.isEnabled = false
                root.addChild(marker)
                return marker
            }
        }
        leftJointMarkers = makeMarkers(material: leftJointMaterial, into: root)
        rightJointMarkers = makeMarkers(material: rightJointMaterial, into: root)

        let lineMesh = MeshResource.generateBox(
            size: SIMD3<Float>(Self.normalLineThickness, Self.normalLineThickness, Self.normalLineLength)
        )
        var leftLineMaterial = UnlitMaterial()
        leftLineMaterial.color = .init(tint: .yellow)
        var rightLineMaterial = UnlitMaterial()
        rightLineMaterial.color = .init(tint: .orange)

        leftNormalLine = ModelEntity(mesh: lineMesh, materials: [leftLineMaterial])
        rightNormalLine = ModelEntity(mesh: lineMesh, materials: [rightLineMaterial])
        leftNormalLine.isEnabled = false
        rightNormalLine.isEnabled = false
        root.addChild(leftNormalLine)
        root.addChild(rightNormalLine)

        var indicatorMaterial = UnlitMaterial()
        indicatorMaterial.color = .init(tint: .gray)
        stateIndicator = ModelEntity(
            mesh: MeshResource.generateSphere(radius: Self.stateIndicatorRadius),
            materials: [indicatorMaterial]
        )
        stateIndicator.position = Self.stateIndicatorPosition
        root.addChild(stateIndicator)
    }

    /// Call once per frame (e.g. from `RealityView`'s `update` closure) with the latest
    /// session state.
    func update(with session: HandTrackingSession) {
        update(markers: leftJointMarkers, normalLine: leftNormalLine, pose: session.latestLeftPose)
        update(markers: rightJointMarkers, normalLine: rightNormalLine, pose: session.latestRightPose)

        let color: UIColor
        switch session.diagnostics.state {
        case .idle: color = .gray
        case .entering: color = .yellow
        case .held: color = .green
        }
        var material = UnlitMaterial()
        material.color = .init(tint: color)
        stateIndicator.model?.materials = [material]
    }

    private func update(markers: [ModelEntity], normalLine: ModelEntity, pose: HandPose?) {
        guard let pose, pose.isTracked else {
            markers.forEach { $0.isEnabled = false }
            normalLine.isEnabled = false
            return
        }

        let positions = [
            pose.joints.wrist, pose.joints.indexKnuckle, pose.joints.middleKnuckle,
            pose.joints.ringKnuckle, pose.joints.littleKnuckle, pose.joints.indexTip,
            pose.joints.middleTip, pose.joints.ringTip, pose.joints.littleTip
        ]
        for (marker, position) in zip(markers, positions) {
            marker.isEnabled = true
            marker.position = position
        }

        normalLine.isEnabled = true
        let normal = pose.palmNormal
        normalLine.position = pose.palmCenter + normal * (Self.normalLineLength / 2)
        normalLine.orientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: normal)
    }
}
