//
//  StarFieldMesh.swift
//  QuranSpatial
//
//  The star field as GEOMETRY: one merged mesh of camera-facing quads on the dome sphere,
//  each carrying a mipmapped gaussian sprite.
//
//  WHY THIS REPLACES THE IN-SHADER STARS. The analytic star field failed three size
//  iterations, and the reason is structural rather than a matter of finding the right number:
//  a dot computed in the fragment shader has NO MIP CHAIN. Its edge is evaluated at whatever
//  the sampling rate happens to be, and this MaterialX has no derivative node - no dFdx, no
//  fwidth, no realitykit equivalent - so the edge cannot be widened to match the fragment
//  footprint. Sizing it against foveal resolution left it sub-pixel in the periphery; sizing
//  it against the periphery made it a 6-pixel blob on-axis.
//
//  A textured sprite gets hardware mip selection and filtering, which is exactly the machinery
//  that stops a small bright thing scintillating when the head moves. That is the fix.
//

import Foundation
import RealityKit
import RealityKitContent
import UIKit
import simd
import os

@MainActor
enum StarFieldMesh {

    private static let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "starfield")

    static let materialPath = "/Root/StarSpriteMaterial"
    static let materialResource = "Materials/StarSpriteMaterial"

    /// Brightness tiers baked into the atlas, across its width. Per-star brightness is chosen
    /// by pointing a quad's UVs at one of these.
    ///
    /// This is how per-star variation is achieved WITHOUT a vertex-colour buffer, which
    /// `MeshDescriptor` does not have - it offers positions, normals, tangents, bitangents,
    /// textureCoordinates and triangleIndices and nothing else. The alternative is
    /// `LowLevelMesh` with a declared vertex format, which is a great deal more machinery for
    /// four brightness levels, and would also drag in the @MainActor buffer-access split.
    static let atlasTiers = 4

    struct Stats {
        var quads = 0
        var vertices = 0
        var triangles = 0
        var parts = 0
        var quadSizeMeters: Float = 0
        var angularDiameterDeg: Float = 0
        var radius: Float = 0
    }

    /// Builds the field. ONE `MeshDescriptor` with ONE material, so one draw submission.
    ///
    /// Positions come from a Fibonacci (golden-angle) spiral, which distributes points on a
    /// sphere far more evenly than independent random sampling - no clumps, no bald patches,
    /// and it is deterministic, so the sky is identical every launch. A small hashed jitter
    /// breaks up the spiral's regularity so it does not read as a pattern.
    static func build(radius: Float,
                      count: Int,
                      angularDiameterDeg: Float,
                      stats: inout Stats) -> ModelEntity? {
        guard count > 0, radius > 0 else { return nil }

        // Quad edge length for the requested angular diameter, at this radius. Small-angle is
        // not assumed: tan of the half-angle, doubled.
        let half = angularDiameterDeg * 0.5 * .pi / 180
        let size = 2 * radius * tan(half)

        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(count * 4)
        uvs.reserveCapacity(count * 4)
        indices.reserveCapacity(count * 6)

        let golden: Float = .pi * (3 - Float(5).squareRoot())   // ~2.39996 rad
        let tierWidth = Float(1) / Float(atlasTiers)

        for i in 0..<count {
            // Fibonacci sphere: y sweeps linearly, azimuth advances by the golden angle.
            let t = (Float(i) + 0.5) / Float(count)
            var y = 1 - 2 * t
            let azimuth = golden * Float(i)

            // Deterministic hash from the index, used for jitter and tier choice.
            let h1 = hash(UInt32(i) &* 2_654_435_761)
            let h2 = hash(UInt32(i) &* 1_597_334_677 &+ 17)
            let h3 = hash(UInt32(i) &* 2_246_822_519 &+ 101)

            // Jitter, small enough to break the spiral without clumping.
            y = max(-0.9999, min(0.9999, y + (h1 - 0.5) * (1.6 / Float(count))))
            let r = (1 - y * y).squareRoot()
            let az = azimuth + (h2 - 0.5) * 0.35
            let dir = SIMD3<Float>(r * cos(az), y, r * sin(az))
            let centre = dir * radius

            // BAKED ORIENTATION, facing the dome CENTRE rather than the live camera.
            //
            // Acceptable because the head never leaves the neighbourhood of the origin: the
            // deck is 10.9 m across and the dome is at `radius`, so the worst-case angular
            // error between "faces the origin" and "faces the eye" is about
            // atan(5.45 / radius), which at 2400 m is 0.13 degrees. A true billboard would
            // need a per-frame update of every quad, or a geometry modifier, to buy back a
            // tenth of a degree on a sprite that is radially symmetric anyway.
            let n = -dir                                  // inward, toward the viewer
            let up = abs(n.y) > 0.99 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
            let right = simd_normalize(simd_cross(up, n))
            let realUp = simd_normalize(simd_cross(n, right))

            let hx = right * (size / 2)
            let hy = realUp * (size / 2)
            let base = UInt32(positions.count)

            positions.append(centre - hx - hy)
            positions.append(centre + hx - hy)
            positions.append(centre + hx + hy)
            positions.append(centre - hx + hy)

            // UVs select the brightness tier. Inset by half a texel so bilinear filtering at
            // the tile edge cannot bleed in from the neighbouring tier.
            let tier = Float(min(atlasTiers - 1, Int(h3 * Float(atlasTiers))))
            let u0 = tier * tierWidth + 0.002
            let u1 = (tier + 1) * tierWidth - 0.002
            uvs.append(SIMD2<Float>(u0, 1))
            uvs.append(SIMD2<Float>(u1, 1))
            uvs.append(SIMD2<Float>(u1, 0))
            uvs.append(SIMD2<Float>(u0, 0))

            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }

        var descriptor = MeshDescriptor(name: "StarField")
        descriptor.positions = MeshBuffer(positions)
        descriptor.textureCoordinates = MeshBuffer(uvs)
        descriptor.primitives = .triangles(indices)

        guard let mesh = try? MeshResource.generate(from: [descriptor]) else {
            logger.fault("STAR FIELD MESH GENERATION FAILED")
            return nil
        }

        stats.quads = count
        stats.vertices = positions.count
        stats.triangles = indices.count / 3
        stats.parts = mesh.expectedMaterialCount
        stats.quadSizeMeters = size
        stats.angularDiameterDeg = angularDiameterDeg
        stats.radius = radius

        let entity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .white)])
        entity.name = "StarFieldSprites"
        return entity
    }

    /// Loads the sprite material and binds the level. Separate from `build` so a material
    /// failure is reported as such rather than as an absent sky.
    static func applyMaterial(to entity: ModelEntity, brightness: Float) async -> String {
        do {
            var material = try await ShaderGraphMaterial(named: materialPath,
                                                         from: materialResource,
                                                         in: realityKitContentBundle)
            var failures: [String] = []
            do { try material.setParameter(name: "starFieldBrightness", value: .float(brightness)) }
            catch { failures.append("starFieldBrightness: \(error)") }
            entity.model?.materials = [material]
            return failures.isEmpty
                ? "bound starFieldBrightness \(brightness)"
                : "FAILED \(failures.joined(separator: "; "))"
        } catch {
            logger.fault("STAR SPRITE MATERIAL LOAD FAILED \(String(describing: error), privacy: .public)")
            return "material load FAILED for \(materialPath) from \(materialResource) — \(error)"
        }
    }

    /// Integer hash to a float in [0, 1). Deterministic, so the sky does not change between
    /// launches - a star field that reshuffled every run would make any visual comparison
    /// between builds meaningless.
    private static func hash(_ x: UInt32) -> Float {
        var v = x
        v ^= v >> 16
        v = v &* 0x7feb_352d
        v ^= v >> 15
        v = v &* 0x846c_a68b
        v ^= v >> 16
        return Float(v & 0x00FF_FFFF) / Float(0x0100_0000)
    }
}
