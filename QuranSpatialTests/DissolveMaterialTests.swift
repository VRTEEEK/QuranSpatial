//
//  DissolveMaterialTests.swift
//  QuranSpatialTests
//
//  Verifies the hand-authored MaterialX graph actually loads and exposes the parameters the
//  driver sets. Hand-written USDA cannot be verified by reading it; this is the check.
//

import Testing
import Foundation
import RealityKit
import RealityKitContent
@testable import QuranSpatial

@MainActor
struct DissolveMaterialTests {

    @Test func dissolveMaterialLoadsAndExposesItsParameters() async throws {
        let material = try await ShaderGraphMaterial(
            named: "/Root/DissolveMaterial",
            from: "Materials/DissolveMaterial",
            in: realityKitContentBundle
        )
        let names = Set(material.parameterNames)
        #expect(names.contains("progress"))
        #expect(names.contains("noiseOffset"))
        #expect(names.contains("edgeWidth"))
        #expect(names.contains("noiseScale"))
        #expect(names.contains("textTexture"))
        #expect(names.contains("textColor"))
    }

    /// The parameters must actually accept the types the driver sets, or the driver fails
    /// silently at runtime.
    @Test func dissolveParametersAcceptTheDriversTypes() async throws {
        var material = try await ShaderGraphMaterial(
            named: "/Root/DissolveMaterial",
            from: "Materials/DissolveMaterial",
            in: realityKitContentBundle
        )
        try material.setParameter(name: "progress", value: .float(0.5))
        try material.setParameter(name: "noiseOffset", value: .simd2Float(SIMD2<Float>(12, 34)))
        try material.setParameter(name: "edgeWidth", value: .float(DissolveDriver.edgeWidth))
        // noiseScale is per-AXIS, not a scalar. It is set from the texture's aspect so a
        // noise cell is square in world space in every ayah; a `.float` here would not just
        // be the wrong type, it would be the wrong idea.
        try material.setParameter(name: "noiseScale", value: .simd2Float(SIMD2<Float>(14, 4.3)))
    }

    /// The driver's constants must be settable on the real material. Hard-coding the values
    /// in this test instead would let the two drift apart silently.
    @Test func materialAcceptsTheDriversStartingValues() async throws {
        var material = try await ShaderGraphMaterial(
            named: DissolveDriver.materialPath,
            from: DissolveDriver.materialResource,
            in: realityKitContentBundle
        )
        try material.setParameter(name: "edgeWidth", value: .float(DissolveDriver.edgeWidth))
        try material.setParameter(
            name: "noiseScale",
            value: .simd2Float(DissolveDriver.noiseScale(forTextureWidth: 894, height: 276))
        )
        // Every ayah's seed, so a corpus-wide offset that the graph rejects is caught here
        // rather than as one ayah dissolving wrong on device.
        for index in 0..<79 {
            try material.setParameter(
                name: "noiseOffset", value: .simd2Float(Dissolve.noiseOffset(forSegmentIndex: index))
            )
        }
    }
}
