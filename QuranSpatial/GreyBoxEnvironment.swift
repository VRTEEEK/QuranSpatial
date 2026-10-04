//
//  GreyBoxEnvironment.swift
//  QuranSpatial
//
//  STEP ONE of the environment: grey-box only. Flat grey, no textures, no IBL, no detail.
//  Every scale, distance and light value is a named constant here so it can be corrected
//  after standing in it — which is the only way any of these get decided.
//
//  WHAT THIS MUST NOT TOUCH: the ayah plane's position (first-line baseline 1.45m,
//  z = -1.5), its typography, its self-lit UnlitMaterial, or the dissolve. The text is not
//  parented to anything here and receives no light from anything here.
//
//  THE ONE GEOMETRIC CONSTRAINT EVERYTHING ELSE BENDS AROUND: the text plane is FIXED at
//  z = -1.5, and the viewer is assumed to be at the world origin. So "text floating over the
//  water" is only true if the platform's front edge is nearer than 1.5m. A platform centred
//  on the viewer would have to be under 1.5m in radius to achieve that, which is a
//  standing-room disc rather than a place. Instead the platform is OFFSET BACKWARD, so the
//  viewer stands near its front edge looking out — which is also the reference composition.
//

import CoreGraphics
import Foundation
import RealityKit
import UIKit
import simd
import os

enum GreyBoxEnvironment {

    // MARK: - Platform

    /// 3.0 m. Big enough to read as a place rather than a pedestal — 6m across is a room,
    /// and leaves clear space behind the viewer for the pavilion to enclose without
    /// crowding. Larger starts to push the pavilion out of peripheral vision, which is where
    /// the sense of enclosure comes from.
    static let platformRadius: Float = 3.0

    /// The platform's centre is pushed BACK from the viewer, so the viewer stands 1.75m
    /// forward of centre and the front rim falls at z = -1.25 — a quarter metre nearer than
    /// the text plane. That is what puts the text over water instead of over stone, without
    /// moving the text.
    static let platformCenterZ: Float = 1.75

    /// 0.2 m. Thick enough that the rim reads as a stone edge from standing height rather
    /// than as a decal on the water.
    static let platformThickness: Float = 0.2

    /// The walking surface, and the origin for everything else vertical. The viewer stands
    /// here; the ayah plane's 1.45m baseline is measured from this.
    static let platformTopY: Float = 0.0

    // MARK: - Water

    /// 5 cm below the platform top. Not zero: coincident planes z-fight, and a visible drop
    /// to the waterline is what makes the platform read as standing IN the lake.
    static let waterY: Float = platformTopY - 0.05

    /// 1000 m square. Not "infinite" — just far enough that its edge falls behind the
    /// mountains at every viewing angle, so the horizon is the mountain line and never a
    /// visible seam.
    static let waterSize: Float = 1000

    // MARK: - Pavilion
    //
    // A full 360° colonnade, built all the way round rather than only across the framed
    // view. Arches are approximated as square lintels at this stage; curved arches are
    // detail and detail is explicitly out of scope for step one.

    /// 3.5 m from the platform centre, i.e. 0.5m clear of the platform rim. The colonnade
    /// stands just off the platform edge so the viewer is inside it but never brushing it.
    static let pavilionInnerRadius: Float = 3.5

    /// 8 columns. Enough to read as an enclosure from any facing; more would start closing
    /// the view to the water. **Angularly offset by half a step so a GAP faces the view
    /// direction** — the text is seen through an opening, never against a column.
    static let pavilionColumnCount = 8

    /// 0.4 m square. Proportionate to a 3.5m column at roughly 1:9, which reads as stone
    /// rather than as a post.
    static let pavilionColumnWidth: Float = 0.4

    /// 3.5 m. Comfortably above standing eye height with headroom to spare, so the structure
    /// encloses without pressing down.
    static let pavilionColumnHeight: Float = 3.5

    /// 0.5 m deep lintel spanning each pair of columns, sitting on top of them. This is the
    /// grey-box stand-in for an arch.
    static let pavilionLintelHeight: Float = 0.5

    // MARK: - Mountains

    /// 300 m out. Far enough to read as background and to sit clearly beyond the water's
    /// visible extent, near enough to still subtend a real silhouette rather than a smudge.
    static let mountainDistance: Float = 300

    /// 50 m, varied per peak. At 300m that subtends about 9.5° — a calm ridge line, not
    /// alpine drama.
    static let mountainHeight: Float = 50

    /// 24 ridge segments around the full circle. Low-poly by intent: this is a silhouette.
    static let mountainSegments = 24

    // MARK: - Sky

    /// 900 m. Inside the water plane's 1000m extent so the two never fight for the horizon,
    /// and well beyond the mountains.
    static let skyRadius: Float = 900

    // MARK: - Lanterns

    /// 8, matching the column count and aligned to the same angles, so lantern and column
    /// share a rhythm instead of beating against one another.
    static let lanternCount = 8

    /// Placed just inside the platform rim rather than on it, so they are not half over the
    /// water and do not read as floating.
    static let lanternRingRadius: Float = platformRadius - 0.4

    /// 0.3 x 0.6 x 0.3 m — a lantern on a low stand, at roughly knee-to-thigh height so it
    /// lights the platform surface rather than the viewer's face.
    static let lanternSize = SIMD3<Float>(0.3, 0.6, 0.3)

    // MARK: - Lighting

    /// Moonlight direction, as the vector the light TRAVELS along. Down and from the front
    /// left, so the pavilion columns cast across the platform rather than straight down.
    static let moonlightDirection = SIMD3<Float>(-0.35, -1.0, 0.25)

    /// Lux. Deliberately dim: this is night, and the lanterns are supposed to be the light
    /// you notice. RealityKit's directional default is ~1000 lux, so this is roughly a
    /// twelfth of a dull overcast day.
    static let moonlightIntensity: Float = 80

    /// Cool, slightly blue — moonlight is not white.
    static let moonlightColor = SIMD3<Double>(0.72, 0.80, 1.0)
    private static var moonlightColorF: SIMD3<Float> {
        SIMD3<Float>(Float(moonlightColor.x), Float(moonlightColor.y), Float(moonlightColor.z))
    }

    /// Lumens per lantern. RealityKit's point-light default is ~27,000, which at this scale
    /// would flood the platform; 900 gives a warm pool underneath each lantern that falls
    /// off before it reaches the next.
    static let lanternIntensity: Float = 900

    /// 2.5 m. Slightly less than the spacing between adjacent lanterns, so each reads as its
    /// own source rather than merging into a ring of uniform light.
    static let lanternAttenuationRadius: Float = 2.5

    /// Warm candle tone.
    static let lanternColor = SIMD3<Double>(1.0, 0.78, 0.52)

    // MARK: - Greys
    //
    // Flat, unlit-looking values that still respond to light, because otherwise the lighting
    // constants above could not be judged at all. Roughness is high and metallic is off
    // everywhere: this is stone, and step one has no material story beyond that.

    static let stoneGrey = SIMD3<Float>(0.55, 0.55, 0.55)
    static let waterGrey = SIMD3<Float>(0.10, 0.11, 0.13)
    static let mountainGrey = SIMD3<Float>(0.16, 0.17, 0.20)
    static let skyGrey = SIMD3<Float>(0.03, 0.035, 0.05)
    static let lanternGrey = SIMD3<Float>(0.75, 0.72, 0.65)
    static let stoneRoughness: Float = 0.9

    private static let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "Environment")

    /// What the build actually produced, so poly count and draw calls are reported from the
    /// scene rather than estimated.
    struct BuildStats {
        var entities = 0
        var meshParts = 0
        var triangles = 0
        var lights = 0
        var summary: String {
            """
            entities: \(entities), mesh parts (draw calls): \(meshParts), \
            triangles: \(triangles), lights: \(lights)
            """
        }
    }

    // MARK: - Build

    /// Builds the whole grey-box environment under one root entity.
    ///
    /// Returned rather than added, so `ImmersiveView` owns placement and the text plane is
    /// never parented beneath any of this.
    @MainActor
    static func build(stats: inout BuildStats) -> Entity {
        let root = Entity()
        root.name = "greybox-environment"

        let stone = material(stoneGrey)

        // --- platform -------------------------------------------------------------
        let platform = ModelEntity(
            mesh: .generateCylinder(height: platformThickness, radius: platformRadius),
            materials: [stone])
        platform.name = "platform"
        // generateCylinder is centred on its own origin, so drop it by half its thickness to
        // put its TOP at platformTopY.
        platform.position = SIMD3<Float>(0, platformTopY - platformThickness / 2, platformCenterZ)
        root.addChild(platform)

        // --- water ----------------------------------------------------------------
        let water = ModelEntity(mesh: .generatePlane(width: waterSize, depth: waterSize),
                                materials: [material(waterGrey, roughness: 0.25)])
        water.name = "water"
        water.position = SIMD3<Float>(0, waterY, 0)
        root.addChild(water)

        // --- pavilion -------------------------------------------------------------
        let pavilion = Entity()
        pavilion.name = "pavilion"
        pavilion.position = SIMD3<Float>(0, 0, platformCenterZ)
        let columnMesh = MeshResource.generateBox(
            width: pavilionColumnWidth, height: pavilionColumnHeight, depth: pavilionColumnWidth)
        let step = 2 * Float.pi / Float(pavilionColumnCount)
        for index in 0..<pavilionColumnCount {
            // + half a step: puts a GAP on the view axis rather than a column.
            let angle = (Float(index) + 0.5) * step
            let x = sin(angle) * pavilionInnerRadius
            let z = -cos(angle) * pavilionInnerRadius
            let column = ModelEntity(mesh: columnMesh, materials: [stone])
            column.name = "column-\(index)"
            column.position = SIMD3<Float>(x, platformTopY + pavilionColumnHeight / 2, z)
            pavilion.addChild(column)
        }
        // Lintels: one box per gap, spanning the chord between neighbouring columns. Rotated
        // to sit tangentially so the ring reads as continuous rather than as eight
        // disconnected beams.
        let chord = 2 * pavilionInnerRadius * sin(step / 2)
        let lintelMesh = MeshResource.generateBox(
            width: chord, height: pavilionLintelHeight, depth: pavilionColumnWidth)
        for index in 0..<pavilionColumnCount {
            let angle = (Float(index) + 1.0) * step   // midway between two columns
            let x = sin(angle) * pavilionInnerRadius
            let z = -cos(angle) * pavilionInnerRadius
            let lintel = ModelEntity(mesh: lintelMesh, materials: [stone])
            lintel.name = "lintel-\(index)"
            lintel.position = SIMD3<Float>(
                x, platformTopY + pavilionColumnHeight + pavilionLintelHeight / 2, z)
            lintel.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
            pavilion.addChild(lintel)
        }
        root.addChild(pavilion)

        // --- mountains ------------------------------------------------------------
        if let ridge = mountainRidge() {
            let mountains = ModelEntity(mesh: ridge, materials: [material(mountainGrey, roughness: 1.0)])
            mountains.name = "mountains"
            mountains.position = SIMD3<Float>(0, waterY, 0)
            root.addChild(mountains)
        }

        // --- sky ------------------------------------------------------------------
        let sky = ModelEntity(mesh: .generateSphere(radius: skyRadius),
                              materials: [UnlitMaterial(color: colour(skyGrey))])
        sky.name = "sky"
        // Seen from INSIDE. UnlitMaterial exposes no faceCulling, so the sphere is mirrored
        // on one axis instead: that reverses the winding order and the inward faces are the
        // ones drawn. Unlit, so the mirrored normals cost nothing.
        sky.scale = SIMD3<Float>(-1, 1, 1)
        root.addChild(sky)

        // --- lanterns and their lights --------------------------------------------
        let lanternMesh = MeshResource.generateBox(size: lanternSize)
        let lanternMaterial = material(lanternGrey, roughness: 0.7)
        let lanternStep = 2 * Float.pi / Float(lanternCount)
        for index in 0..<lanternCount {
            let angle = (Float(index) + 0.5) * lanternStep
            let x = sin(angle) * lanternRingRadius
            let z = platformCenterZ - cos(angle) * lanternRingRadius
            let lantern = ModelEntity(mesh: lanternMesh, materials: [lanternMaterial])
            lantern.name = "lantern-\(index)"
            lantern.position = SIMD3<Float>(x, platformTopY + lanternSize.y / 2, z)
            root.addChild(lantern)

            // The light sits at the lantern's centre, not its base, so the pool of light is
            // centred under it.
            let light = Entity()
            light.name = "lantern-light-\(index)"
            light.position = lantern.position
            light.components.set(PointLightComponent(
                cgColor: cgColour(lanternColor),
                intensity: lanternIntensity,
                attenuationRadius: lanternAttenuationRadius))
            root.addChild(light)
            stats.lights += 1
        }

        // --- moonlight ------------------------------------------------------------
        let moon = Entity()
        moon.name = "moonlight"
        moon.components.set(DirectionalLightComponent(
            color: colour(moonlightColorF), intensity: moonlightIntensity))
        // A DirectionalLight emits along its entity's -Z, so orient -Z onto the chosen
        // direction rather than baking the direction into the vector.
        moon.look(at: normalize(moonlightDirection), from: .zero, relativeTo: nil)
        root.addChild(moon)
        stats.lights += 1

        measure(root, into: &stats)
        // Copied out first: an inout parameter cannot be captured by the logger's escaping
        // autoclosure.
        let summary = stats.summary
        logger.notice("Grey-box environment built: \(summary, privacy: .public)")
        return root
    }

    // MARK: - Helpers

    private static func material(_ rgb: SIMD3<Float>, roughness: Float = stoneRoughness) -> SimpleMaterial {
        // SimpleMaterial rather than UnlitMaterial precisely BECAUSE it takes light: with
        // unlit surfaces the lighting constants above could not be judged at all, which is
        // half of what step one is for. The ayah plane keeps its own UnlitMaterial and is
        // untouched by any of this.
        var m = SimpleMaterial(color: colour(rgb), roughness: .init(floatLiteral: roughness), isMetallic: false)
        m.roughness = .init(floatLiteral: roughness)
        return m
    }

    private static func colour(_ rgb: SIMD3<Float>) -> UIColor {
        UIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
    }

    private static func cgColour(_ rgb: SIMD3<Double>) -> CGColor {
        CGColor(red: rgb.x, green: rgb.y, blue: rgb.z, alpha: 1)
    }

    /// A ring of ridge segments: two triangles per segment from the waterline to a peak
    /// whose height varies deterministically, so the silhouette is uneven without being
    /// random per launch.
    private static func mountainRidge() -> MeshResource? {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        let step = 2 * Float.pi / Float(mountainSegments)
        for index in 0...mountainSegments {
            let angle = Float(index % mountainSegments) * step
            let x = sin(angle) * mountainDistance
            let z = -cos(angle) * mountainDistance
            // Fixed integer mix, so the ridge is identical on every run and every device -
            // the same reason Dissolve.noiseOffset avoids Swift's Hasher.
            var h = UInt64(index % mountainSegments) &+ 0x9E37_79B9_7F4A_7C15
            h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
            h = h ^ (h >> 31)
            let variation = 0.45 + 0.55 * Float(h & 0xFFFF) / Float(0x10000)
            positions.append(SIMD3<Float>(x, 0, z))
            positions.append(SIMD3<Float>(x, mountainHeight * variation, z))
        }
        for index in 0..<mountainSegments {
            let base = UInt32(index * 2)
            indices.append(contentsOf: [base, base + 1, base + 3, base, base + 3, base + 2])
        }
        var descriptor = MeshDescriptor(name: "mountains")
        descriptor.positions = MeshBuffer(positions)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// Walks the built hierarchy and counts what is actually there.
    @MainActor
    private static func measure(_ entity: Entity, into stats: inout BuildStats) {
        stats.entities += 1
        if let model = entity.components[ModelComponent.self] {
            for part in model.mesh.contents.models.flatMap({ $0.parts }) {
                stats.meshParts += 1
                stats.triangles += (part.triangleIndices?.count ?? 0) / 3
            }
        }
        for child in entity.children { measure(child, into: &stats) }
    }
}
