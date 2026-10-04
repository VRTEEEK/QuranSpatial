//
//  PavilionEnvironment.swift
//  QuranSpatial
//
//  STAGE 3: load QuranSpatial_Environment.usdz and measure what RealityKit made of it.
//
//  NO COMPOSITION CHANGES. Added exactly as loaded — not reparented, rotated, scaled or
//  offset. The asset's root deliberately carries Blender's Z-up → Y-up conversion and the
//  package README is explicit that it must be kept, so "correcting" it here would tip the
//  environment on its side. Nothing is decimated, merged or stripped whatever the numbers
//  say; this stage measures, it does not optimise.
//
//  Nothing here touches the text pipeline, the dissolve material, or PlaybackState.
//

import CoreGraphics
import Foundation
import Metal
import RealityKit
import UIKit
import simd
import os

enum PavilionEnvironment {

    /// **The .usdz, not the .usdc + textures/ pair, and the bundle layout decides it.**
    ///
    /// This project's Resources are a file-system-synchronized group, which FLATTENS into
    /// the bundle root — verified: `Resources/Environment/night_pavilion.usdc` shipped as
    /// `night_pavilion.usdc` with no `Environment/` directory. The .usdc references its maps
    /// as `./textures/<name>.png`, 21 of them. Flattened, every one of those paths resolves
    /// to nothing.
    ///
    /// It would not error. RealityKit would load the geometry and render it untextured, and
    /// the failure would look like an art problem rather than a packaging one. The .usdz
    /// carries all 21 maps inside a single file, so there is no path to resolve and nothing
    /// for the bundle layout to break. The corrected asset ships as a .usdz for the same reason.
    ///
    /// **SWITCHED 2026-10-03 (Mo): `stage-2` now loads `QuranSpatial_Review`**, brought over
    /// from `experiment/env-review`. `QuranSpatial_Environment_Corrected.usdz` stays in the
    /// same folder so switching back is this one constant. The review asset lacks several
    /// names this code looks up (Platform, Lantern_01-08, Lantern_Ceiling, Night_Sky_Dome,
    /// textures/night_sky_2k.png) and carries 11 textures, not 22; every such miss is logged
    /// as `env-review missing: <name>` and otherwise falls through exactly as before. The
    /// file is gitignored (67 MB); its SHA-256 is recorded in docs/baseline-disclosure.md.
    static let resourceName = "QuranSpatial_Review"

    /// Was `true`, and that is why the ayah text was missing from the scene: it gated
    /// `content.add(ayahEntity)`. Nothing about the text pipeline was broken — the plane was
    /// simply never added.
    ///
    /// Now false. It no longer has anything to do with the grey-box, which has its own
    /// constant below: flipping this back on to isolate a measurement should not also
    /// resurrect a superseded environment.
    static let isolateForMeasurement = false

    /// Maps inside the usdz. Named rather than written inline in a report string, because a
    /// stale literal there reported "6 of 21" against an asset carrying 22.
    static let authoredTextureCount = 22

    /// The grey-box is superseded by the USD asset and stays out of the scene regardless of
    /// the isolation flag. Kept as a constant rather than deleted so the grey-box path is
    /// still reachable if the asset ever has to be backed out.
    static let showGreyBoxEnvironment = false

    private static let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "Pavilion")

    struct LoadResult {
        var entity: Entity?
        var loadSeconds: Double = 0
        var failure: String?

        var totalEntities = 0
        var modelEntities = 0
        var meshParts = 0
        var triangles = 0
        var instancedEntities = 0
        var instanceCount = 0

        var textureCount = 0
        var textureBytes: UInt64 = 0
        var textureDetail: [String] = []

        var lights: [String] = []

        var footprintBefore: UInt64?
        var footprintAfter: UInt64?
    }

    // MARK: - Load

    @MainActor
    static func load() async -> LoadResult {
        var result = LoadResult()
        result.footprintBefore = MemoryProbe.physFootprint()
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let entity = try await Entity(named: resourceName, in: nil)
            result.loadSeconds = CFAbsoluteTimeGetCurrent() - start
            result.entity = entity
            var seenTextures = Set<ObjectIdentifier>()
            measure(entity, into: &result, seenTextures: &seenTextures)
            result.footprintAfter = MemoryProbe.physFootprint()
        } catch {
            result.loadSeconds = CFAbsoluteTimeGetCurrent() - start
            result.failure = String(describing: error)
            logger.fault("ENVIRONMENT FAILED TO LOAD: \(String(describing: error), privacy: .public)")
        }
        return result
    }

    @MainActor
    private static func measure(_ entity: Entity, into r: inout LoadResult,
                                seenTextures: inout Set<ObjectIdentifier>) {
        r.totalEntities += 1

        // Instancing, if RealityKit kept any: a MeshInstancesComponent means one mesh drawn
        // many times rather than many entities each drawn once.
        if let instances = entity.components[MeshInstancesComponent.self] {
            r.instancedEntities += 1
            var n = 0
            for index in 0..<8 { if instances[partIndex: index] != nil { n += 1 } }
            r.instanceCount += max(n, 1)
        }

        if let model = entity.components[ModelComponent.self] {
            r.modelEntities += 1
            let parts = model.mesh.contents.models.flatMap { $0.parts }
            r.meshParts += parts.count
            for part in parts { r.triangles += (part.triangleIndices?.count ?? 0) / 3 }
            for material in model.materials { collectTextures(material, into: &r, seen: &seenTextures) }
        }
        for child in entity.children { measure(child, into: &r, seenTextures: &seenTextures) }
    }

    /// Sums texture memory from the textures RealityKit actually created, deduplicated by
    /// identity — 208 meshes share 21 maps, so counting per-binding would multiply the same
    /// allocation many times over and report a number that does not exist.
    @MainActor
    private static func collectTextures(_ material: any RealityKit.Material,
                                        into r: inout LoadResult,
                                        seen: inout Set<ObjectIdentifier>) {
        guard let pbr = material as? PhysicallyBasedMaterial else { return }
        let candidates: [(String, PhysicallyBasedMaterial.Texture?)] = [
            ("baseColor", pbr.baseColor.texture),
            ("normal", pbr.normal.texture),
            ("roughness", pbr.roughness.texture),
            ("metallic", pbr.metallic.texture),
            ("emissiveColor", pbr.emissiveColor.texture),
            ("ambientOcclusion", pbr.ambientOcclusion.texture),
            ("clearcoat", pbr.clearcoat.texture),
        ]
        for (slot, texture) in candidates {
            guard let resource = texture?.resource else { continue }
            let id = ObjectIdentifier(resource)
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            let bytes = byteSize(of: resource)
            r.textureCount += 1
            r.textureBytes += bytes
            r.textureDetail.append(String(
                format: "  %-16s %5d x %-5d  %-28s mips %-2d  %7.2f MB",
                (slot as NSString).utf8String!, resource.width, resource.height,
                (pixelFormatName(resource.pixelFormat) as NSString).utf8String!,
                resource.mipmapLevelCount, Double(bytes) / 1_048_576))
        }
    }

    /// Resident size of one texture, from the pixel format RealityKit chose rather than from
    /// the PNG on disk — the two are unrelated, and the PNG size says nothing about VRAM.
    @MainActor
    private static func byteSize(of texture: TextureResource) -> UInt64 {
        let bpp = bitsPerPixel(texture.pixelFormat)
        var total: UInt64 = 0
        var w = texture.width, h = texture.height
        for _ in 0..<max(1, texture.mipmapLevelCount) {
            total += UInt64((w * h * bpp + 7) / 8)
            w = max(1, w / 2); h = max(1, h / 2)
        }
        return total
    }

    /// MTLPixelFormat's own description prints a raw value, which is unreadable in a
    /// report. Only the formats RealityKit plausibly picks are named; anything else prints
    /// its raw value so an unexpected choice is visible rather than mislabelled.
    static func pixelFormatName(_ f: MTLPixelFormat) -> String {
        switch f {
        case .r8Unorm: return "r8Unorm"
        case .rg8Unorm: return "rg8Unorm"
        case .rgba8Unorm: return "rgba8Unorm"
        case .rgba8Unorm_srgb: return "rgba8Unorm_srgb"
        case .bgra8Unorm: return "bgra8Unorm"
        case .bgra8Unorm_srgb: return "bgra8Unorm_srgb"
        case .rgba16Float: return "rgba16Float"
        case .bc1_rgba: return "bc1_rgba"
        case .bc1_rgba_srgb: return "bc1_rgba_srgb"
        case .bc3_rgba: return "bc3_rgba"
        case .bc3_rgba_srgb: return "bc3_rgba_srgb"
        case .bc4_rUnorm: return "bc4_rUnorm"
        case .bc5_rgUnorm: return "bc5_rgUnorm"
        case .bc7_rgbaUnorm: return "bc7_rgbaUnorm"
        case .bc7_rgbaUnorm_srgb: return "bc7_rgbaUnorm_srgb"
        case .astc_4x4_ldr: return "astc_4x4_ldr"
        case .astc_4x4_srgb: return "astc_4x4_srgb"
        case .astc_6x6_ldr: return "astc_6x6_ldr"
        case .astc_6x6_srgb: return "astc_6x6_srgb"
        case .astc_8x8_ldr: return "astc_8x8_ldr"
        case .astc_8x8_srgb: return "astc_8x8_srgb"
        case .eac_r11Unorm: return "eac_r11Unorm"
        default: return "raw(\(f.rawValue))"
        }
    }

    private static func bitsPerPixel(_ format: MTLPixelFormat) -> Int {
        switch format {
        case .r8Unorm, .r8Unorm_srgb, .a8Unorm: return 8
        case .rg8Unorm, .r16Float, .rg8Unorm_srgb: return 16
        case .bgra8Unorm, .bgra8Unorm_srgb, .rgba8Unorm, .rgba8Unorm_srgb, .rg16Float: return 32
        case .rgba16Float: return 64
        case .bc1_rgba, .bc1_rgba_srgb: return 4
        case .bc3_rgba, .bc3_rgba_srgb, .bc5_rgUnorm, .bc7_rgbaUnorm, .bc7_rgbaUnorm_srgb: return 8
        case .astc_4x4_srgb, .astc_4x4_ldr: return 8
        case .astc_6x6_srgb, .astc_6x6_ldr: return 4      // 128 bits / 36 texels ≈ 3.56, rounded up
        case .astc_8x8_srgb, .astc_8x8_ldr: return 2
        default: return 32                                 // conservative; flagged in the report
        }
    }

    // MARK: - Texture plateau

    struct Plateau {
        var secondsToPlateau: Double = 0
        var polls = 0
        var reachedPlateau = false
        var count = 0
        var bytes: UInt64 = 0
        var detail: [String] = []
        var sawFourK = false
        var trace: [String] = []
    }

    /// Polls until texture residency stops changing.
    ///
    /// **A single sample is meaningless here.** Texture loading continues asynchronously
    /// after `Entity(named:)` returns — three macOS samples of the same load gave 5, 6 and
    /// 11 textures purely by sampling at different moments. Anything read once is a
    /// timestamp, not a measurement.
    ///
    /// Settled means count AND bytes unchanged across 8 consecutive 250ms polls, i.e. 2s of
    /// quiet. Bails at 30s and says so rather than reporting the last value as if it had
    /// converged.
    @MainActor
    static func waitForTexturePlateau(_ entity: Entity) async -> Plateau {
        var p = Plateau()
        let start = CFAbsoluteTimeGetCurrent()
        var stableFor = 0
        var lastCount = -1
        var lastBytes: UInt64 = .max
        var settledAt: Double = 0

        while CFAbsoluteTimeGetCurrent() - start < 30 {
            var seen = Set<ObjectIdentifier>()
            var r = LoadResult()
            collectAllTextures(entity, into: &r, seen: &seen)
            p.polls += 1
            let now = CFAbsoluteTimeGetCurrent() - start

            if r.textureCount == lastCount && r.textureBytes == lastBytes {
                if stableFor == 0 { settledAt = now }
                stableFor += 1
            } else {
                stableFor = 0
                p.trace.append(String(format: "   %6.2fs  %2d textures  %7.2f MB",
                                      now, r.textureCount, Double(r.textureBytes) / 1_048_576))
            }
            lastCount = r.textureCount
            lastBytes = r.textureBytes
            p.count = r.textureCount
            p.bytes = r.textureBytes
            p.detail = r.textureDetail

            if stableFor >= 8 {
                p.reachedPlateau = true
                p.secondsToPlateau = settledAt
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if !p.reachedPlateau { p.secondsToPlateau = CFAbsoluteTimeGetCurrent() - start }
        p.sawFourK = p.detail.contains { $0.contains(" 4096 x") }
        return p
    }

    /// Residency right now, for a caller that can sample at a moment worth sampling.
    ///
    /// **Must be called while the entity is IN A RENDERING SCENE.** Sampled at launch with
    /// the entity unparented and nothing drawing, residency oscillated 3 -> 4 -> 3 -> 27 -> 3
    /// within 1.6s: RealityKit had no reason to keep anything resident, so what settled was
    /// an idle state rather than a working set.
    @MainActor
    static func textureResidency(_ entity: Entity) -> (count: Int, bytes: UInt64, detail: [String]) {
        var seen = Set<ObjectIdentifier>()
        var r = LoadResult()
        collectAllTextures(entity, into: &r, seen: &seen)
        return (r.textureCount, r.textureBytes, r.textureDetail)
    }

    @MainActor
    private static func collectAllTextures(_ entity: Entity, into r: inout LoadResult,
                                           seen: inout Set<ObjectIdentifier>) {
        if let model = entity.components[ModelComponent.self] {
            for material in model.materials { collectTextures(material, into: &r, seen: &seen) }
        }
        for child in entity.children { collectAllTextures(child, into: &r, seen: &seen) }
    }

    // MARK: - Lights

    /// Walks for every light component type RealityKit has, so "partially imported" is
    /// distinguishable from "ignored" — a count alone cannot tell those apart.
    @MainActor
    static func collectLights(_ entity: Entity, into lights: inout [String], path: String = "") {
        let name = path.isEmpty ? entity.name : "\(path)/\(entity.name)"
        let world = entity.position(relativeTo: nil)
        if let l = entity.components[DirectionalLightComponent.self] {
            lights.append(String(format: "DirectionalLight  %-28s intensity %.3f", (name as NSString).utf8String!, l.intensity))
        }
        if let l = entity.components[PointLightComponent.self] {
            lights.append(String(format: "PointLight        %-28s intensity %.3f  attenuation %.2f m  pos(%.2f, %.2f, %.2f)",
                                 (name as NSString).utf8String!, l.intensity, l.attenuationRadius, world.x, world.y, world.z))
        }
        if let l = entity.components[SpotLightComponent.self] {
            lights.append(String(format: "SpotLight         %-26s intensity %.2f  inner %.1f deg  outer %.1f deg  atten %.2f m  color %@",
                                 (name as NSString).utf8String!, l.intensity,
                                 l.innerAngleInDegrees, l.outerAngleInDegrees, l.attenuationRadius,
                                 describeColor(l.color)))
        }
        if entity.components[ImageBasedLightComponent.self] != nil {
            lights.append("ImageBasedLight   \(name)")
        }
        for child in entity.children { collectLights(child, into: &lights, path: name) }
    }

    /// Components, not names: the question is whether the warm authored colour survived
    /// import, so the value has to be printed rather than summarised.
    @MainActor
    private static func describeColor(_ c: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "<unreadable>" }
        return String(format: "(%.3f, %.3f, %.3f)", r, g, b)
    }

    // MARK: - Report

    @MainActor
    static func report(_ r: LoadResult, firstFrameSeconds: Double? = nil) -> String {
        var lines: [String] = []
        lines.append("written: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("asset: \(resourceName).usdz  (self-contained; see the note in the source)")
        lines.append("isolateForMeasurement: \(isolateForMeasurement)")
        lines.append("")

        guard let entity = r.entity else {
            lines.append("LOAD FAILED after \(String(format: "%.3f", r.loadSeconds))s: \(r.failure ?? "?")")
            return lines.joined(separator: "\n")
        }

        lines.append("--- 1. ORIENTATION (uncorrected) ---")
        let o = entity.orientation
        let ang = 2 * acos(min(1, max(-1, o.real))) * 180 / .pi
        lines.append(String(format: "root T=(%.4f, %.4f, %.4f)  S=(%.4f, %.4f, %.4f)",
                            entity.position.x, entity.position.y, entity.position.z,
                            entity.scale.x, entity.scale.y, entity.scale.z))
        lines.append(String(format: "root orientation %.2f deg about (%.3f, %.3f, %.3f)  [kept, not corrected]",
                            ang, o.axis.x, o.axis.y, o.axis.z))
        if let platform = entity.findEntity(named: "Platform") {
            let b = platform.visualBounds(relativeTo: nil)
            let s = b.extents
            let thin = s.x < s.y && s.x < s.z ? "X" : (s.y < s.x && s.y < s.z ? "Y" : "Z")
            lines.append(String(format: "Platform bounds  min(%.3f, %.3f, %.3f) max(%.3f, %.3f, %.3f)",
                                b.min.x, b.min.y, b.min.z, b.max.x, b.max.y, b.max.z))
            lines.append(String(format: "Platform extents (%.3f, %.3f, %.3f)  -> THINNEST IN %@", s.x, s.y, s.z, thin))
            lines.append(String(format: "deck top-surface world Y = %.4f m", b.max.y))
            lines.append(thin == "Y"
                ? "VERDICT: UPRIGHT — deck is horizontal."
                : "VERDICT: NOT UPRIGHT — deck is thin in \(thin), so it is standing on edge.")
        } else {
            EnvironmentLighting.envReviewMiss("Platform")
            lines.append("Platform entity not found by name.")
        }
        lines.append("")

        lines.append("--- 2. INSTANCING / DRAW CALLS ---")
        lines.append("entities in hierarchy       : \(r.totalEntities)")
        lines.append("entities carrying a mesh    : \(r.modelEntities)")
        lines.append("mesh parts (draw submissions): \(r.meshParts)")
        lines.append("MeshInstancesComponent found: \(r.instancedEntities) entit(y/ies), \(r.instanceCount) instance part(s)")
        lines.append(r.instancedEntities > 0
            ? "-> instancing PRESERVED in some form"
            : "-> NO MeshInstancesComponent anywhere: USD instancing was EXPANDED on import")
        // DELIBERATELY NO AUTHORED-INSTANCE LINE HERE, AND DO NOT ADD ONE BACK.
        //
        // This used to print "USD authored 208 mesh instances from 10 prototypes" as a
        // literal. It was wrong - the asset has 164 instanceable prims over 11 prototypes in
        // /_GeometryLibrary - and it was wrong in the worst way, because it sat in the middle
        // of measured figures and read exactly like one of them. It was quoted as fact in a
        // report before anyone checked it against the file.
        //
        // It cannot simply be corrected to 164/11, because those numbers are not measurable
        // from here: RealityKit EXPANDS the instancing on import, which is the very finding
        // the line above reports. By the time this code runs there is nothing left to count.
        // Reading them means parsing the USD, which this app does not do and should not
        // start doing to fill in a report line.
        //
        // If the authored counts are needed, measure them from the asset with usdcat, and
        // keep the answer where it can be re-derived - not baked into a string in here.
        lines.append("")

        lines.append("--- 3. TRIANGLES ---")
        lines.append("triangles as RealityKit sees them: \(r.triangles)")
        lines.append("")

        lines.append("--- 4. TEXTURE MEMORY ---")
        lines.append(String(format: "distinct textures resident: %d, total %.2f MB",
                            r.textureCount, Double(r.textureBytes) / 1_048_576))
        lines.append(contentsOf: r.textureDetail)
        lines.append("")

        lines.append("--- 5. TOTAL FOOTPRINT ---")
        lines.append("phys_footprint before load : \(MemoryProbe.mb(r.footprintBefore))")
        lines.append("phys_footprint after load  : \(MemoryProbe.mb(r.footprintAfter))")
        lines.append("delta attributable to load : \(MemoryProbe.mbDelta(r.footprintAfter, r.footprintBefore))")
        lines.append("")

        lines.append("--- 6. LIGHTS ---")
        lines.append("USD authored 10: 1 DistantLight (Moon_Key) + 9 SphereLight (8 lantern pools + 1 ceiling)")
        lines.append("arrived in RealityKit: \(r.lights.count)")
        if r.lights.isEmpty {
            lines.append("  NONE — every authored light was dropped on import.")
        } else {
            lines.append(contentsOf: r.lights.map { "  " + $0 })
        }
        lines.append("")

        lines.append("--- 7. LOAD TIME ---")
        lines.append(String(format: "Entity(named:) returned in %.3f s", r.loadSeconds))
        if let ff = firstFrameSeconds {
            lines.append(String(format: "load start -> first rendered frame: %.3f s  [ON DEVICE]", ff))
        } else {
            lines.append("load start -> first rendered frame: needs the ImmersiveSpace open")
        }
        return lines.joined(separator: "\n")
    }

    /// Items 4, 5 and 9, measured at launch and needing no ImmersiveSpace: warm the
    /// framework, take a baseline, load, poll texture residency to a plateau, then sample
    /// the footprint and the light components.
    @MainActor
    static func runLaunchMeasurement() async {
        // RealityKit is warmed BEFORE the baseline. Measuring from a cold process attributes
        // Metal device creation, shader caches and allocator startup to the asset - that
        // mistake produced a +391 MB figure on macOS against a true +316 MB.
        _ = ModelEntity(mesh: .generateBox(size: 0.1), materials: [SimpleMaterial()])
        try? await Task.sleep(nanoseconds: 500_000_000)

        let baseline = MemoryProbe.physFootprint()
        let start = CFAbsoluteTimeGetCurrent()
        var r = LoadResult()
        r.footprintBefore = baseline
        do {
            let entity = try await Entity(named: resourceName, in: nil)
            r.loadSeconds = CFAbsoluteTimeGetCurrent() - start
            r.entity = entity
            var seen = Set<ObjectIdentifier>()
            measure(entity, into: &r, seenTextures: &seen)
            collectLights(entity, into: &r.lights)

            let plateau = await waitForTexturePlateau(entity)
            r.footprintAfter = MemoryProbe.physFootprint()
            r.textureCount = plateau.count
            r.textureBytes = plateau.bytes
            r.textureDetail = plateau.detail
            logEnvReviewNotes(entity, texturesSeen: plateau.count)

            // The lighting rig is built here too, purely to confirm it RESOLVES - every
            // named lantern found, every light created with a non-zero intensity. That is
            // the half of "is the scene black" answerable without a headset.
            let rig = EnvironmentLighting.build(for: entity)
            var text = report(r)
            text += "\n\n" + EnvironmentLighting.audit(environment: entity, result: rig) + "\n"
            // The glow-card diagnosis on the launch copy too, so the GLOW-CARDS line lands
            // in environment-load.txt without a headset session.
            text += EnvironmentLighting.logGlowCardMaterials(in: entity) + "\n"
            // The sky swap is asset loading and material binding - it needs no ImmersiveSpace.
            // Doing it HERE as well as in the view means the SKY: line lands in the launch
            // report, which can be pulled off the device without anyone wearing it. Before
            // this, the only SKY: line was written on first frame, so confirming the material
            // bound required a headset session for a fact that a file could answer.
            text += "\n" + (await EnvironmentLighting.applyProceduralSky(to: entity)) + "\n"
            // Occlusion against the pavilion, from a nominal standing eye. Runs here because
            // the geometry is loaded and the answer needs no headset - "is the text behind a
            // column" should not cost a device session to find out.
            TextPlacementProbe.writeReport(headPosition: SIMD3<Float>(0, TextPlacementProbe.nominalEyeHeight, 0),
                                           sampled: false, environment: entity)
            // The sprite star field is mesh generation plus a material load - no scene needed -
            // so it is built and measured here too. That is what makes "one draw call" a
            // reported fact rather than a design intention.
            // Dome radius as a transform, reported here so it is checkable without a headset.
            text += EnvironmentLighting.setSkyDomeRadius(in: entity) + "\n"
            if !EnvironmentLighting.proceduralStarsEnabled {
                // TARGET radius, not the measured one - the dome has just been scaled, and stars
                // placed on the authored 2400 m sphere would sit outside it.
                do {
                    let r = EnvironmentLighting.skyDomeTargetRadius
                    var st = StarFieldMesh.Stats()
                    if let field = StarFieldMesh.build(
                        radius: r * 0.985,
                        count: EnvironmentLighting.starFieldQuadCount,
                        angularDiameterDeg: EnvironmentLighting.starFieldAngularDiameterDeg,
                        stats: &st) {
                        let bind = await StarFieldMesh.applyMaterial(
                            to: field, brightness: EnvironmentLighting.starFieldBrightness)
                        text += "STARS: sprite mesh \(st.quads) quads, \(st.vertices) verts, "
                              + "\(st.triangles) tris, material parts \(st.parts) -> "
                              + "\(st.parts) DRAW CALL(S)\n"
                        text += String(format: "STARS: quad %.3f m = %.3f deg at r=%.0f m; %@\n",
                                       st.quadSizeMeters, st.angularDiameterDeg, st.radius, bind)
                    } else {
                        text += "STARS: sprite mesh generation FAILED\n"
                    }
                }
            } else {
                text += "STARS: old in-shader path selected\n"
            }
            text += "\n--- 4b. TEXTURE RESIDENCY, POLLED TO PLATEAU (AT LAUNCH - NOT VALID, see note) ---\n"
            text += "Sampled with the entity unparented and nothing rendering, so this is an\n"
            text += "IDLE state, not a working set. The figure that counts is sampled in scene\n"
            text += "at the end of capture phase A. Kept only to show the oscillation.\n"
            text += plateau.reachedPlateau
                ? String(format: "PLATEAU reached at %.2f s (%d polls, 8 consecutive unchanged)\n",
                         plateau.secondsToPlateau, plateau.polls)
                : String(format: "NO PLATEAU within 30 s (%d polls) - still changing when sampling stopped\n",
                         plateau.polls)
            text += "resident at plateau: \(plateau.count) of 21 authored maps\n"
            text += String(format: "total texture memory: %.2f MB\n", Double(plateau.bytes) / 1_048_576)
            text += "4096-wide night sky resident: \(plateau.sawFourK ? "YES" : "NO")\n"
            text += "residency over time (only changes shown):\n"
            text += plateau.trace.joined(separator: "\n")
            text += "\n\n--- 5b. FOOTPRINT AFTER PLATEAU (RealityKit warmed first) ---\n"
            text += "baseline after warm-up: \(MemoryProbe.mb(baseline))\n"
            text += "after load + plateau  : \(MemoryProbe.mb(r.footprintAfter))\n"
            text += "ENVIRONMENT DELTA     : \(MemoryProbe.mbDelta(r.footprintAfter, baseline))\n"
            text += "\n--- 9. MOON_KEY ---\n"
            text += "Moon_Key entity present: \(entity.findEntity(named: "Moon_Key") != nil)\n"
            text += "Moon_Key has DirectionalLightComponent: "
                 + "\(entity.findEntity(named: "Moon_Key")?.components[DirectionalLightComponent.self] != nil)\n"
            logger.notice("\(text, privacy: .public)")
            if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("environment-load.txt") {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            logger.fault("LAUNCH MEASUREMENT FAILED: \(String(describing: error), privacy: .public)")
        }
    }

    /// Review-asset notes: a camera prim that should not ship,
    /// and the authored texture count the report assumes against what the asset carries. One
    /// line each; nothing is changed.
    @MainActor
    static func logEnvReviewNotes(_ entity: Entity, texturesSeen: Int) {
        if let camera = entity.findEntity(named: "Review_Camera") {
            let p = camera.position(relativeTo: nil)
            let kinds = camera.components.map { String(describing: type(of: $0)) }.sorted().joined(separator: ", ")
            logger.notice("env-review note: Review_Camera present at (\(p.x, format: .fixed(precision: 2)), \(p.y, format: .fixed(precision: 2)), \(p.z, format: .fixed(precision: 2))), components [\(kinds, privacy: .public)] - left in place")
        }
        if texturesSeen != authoredTextureCount {
            logger.notice("env-review missing: authoredTextureCount expects \(authoredTextureCount) maps, asset resident set at launch is \(texturesSeen) (package carries 11)")
        }
    }

    @MainActor
    static func writeReport(firstFrameSeconds: Double? = nil, sceneResult: LoadResult? = nil,
                            lightingAudit: String = "") async {
        let result: LoadResult
        if let sceneResult { result = sceneResult } else { result = await load() }
        var r = result
        if let e = r.entity, r.lights.isEmpty { collectLights(e, into: &r.lights) }
        var text = report(r, firstFrameSeconds: firstFrameSeconds)
        if !lightingAudit.isEmpty { text += "\n\n" + lightingAudit }
        logger.notice("\(text, privacy: .public)")
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("environment-load.txt") else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
