//
//  EnvironmentLighting.swift
//  QuranSpatial
//
//  ALL environment lighting lives here. One file, named constants, nothing scattered —
//  these are the values that get tuned, and hunting them across three files is how tuning
//  turns into archaeology.
//
//  The asset ships zero lights by design, and that is the right call rather than a gap:
//  USD-authored lighting cannot survive RealityKit's importer. Measured on device against
//  the previous export, which did carry a rig of ten — the DistantLight key was dropped
//  outright, and all nine SphereLights arrived as identical white 90-degree spots, losing
//  their colour and their authored intensity ratio. Authoring in Swift is the only way the
//  values that ship are the values that were chosen.
//
//  Positions are READ FROM THE LOADED HIERARCHY. Nothing here hardcodes a coordinate: if
//  the art moves a lantern, its light moves with it, and if the art renames one, this
//  reports the miss rather than silently lighting empty air.
//

import Foundation
import RealityKit
import RealityKitContent
import UIKit
import simd
import os

enum EnvironmentLighting {

    // MARK: - Moon key

    /// Direction the moonlight TRAVELS, not the direction it comes from. Down, and from the
    /// front-left, so the colonnade casts across the deck rather than straight down.
    static let moonDirection = SIMD3<Float>(-0.35, -1.0, 0.25)

    /// Lux. Deliberately dim — this is night, and the lanterns are meant to be the light you
    /// notice. RealityKit's directional default is ~1000 lux, so this is a fraction of a dull
    /// overcast day. **Raise this first if the scene reads as too dark to navigate.**
    ///
    /// **400 as of Stage 6**, raised from 120. The rear terrain has no lantern coverage at
    /// all and depends entirely on the moon and the probe, so it is the surface that decides
    /// this value rather than anything inside the pavilion.
    static let moonIntensity: Float = 400

    /// Cool and slightly blue. Moonlight is reflected sunlight and reads cold against the
    /// lantern warmth; pure white loses the contrast the whole scene is built on.
    static let moonColor = UIColor(red: 0.72, green: 0.80, blue: 1.00, alpha: 1)

    // MARK: - Lanterns

    /// Lumens per rim lantern. RealityKit's point-light default is ~27,000, which at this
    /// scale floods the deck to white. 1400 gives a pool under each lantern that falls off
    /// before it reaches its neighbour.
    /// **Unchanged at 1400.** The lanterns already read correctly; raising them alongside
    /// the ambient would have cost exactly the contrast the scene is built on.
    static let lanternIntensity: Float = 1400

    /// Metres. Slightly under the ~3.1 m spacing between adjacent lanterns on the 4.2 m ring,
    /// so each reads as its own source instead of merging into a ring of even light.
    static let lanternAttenuationRadius: Float = 2.8

    /// Warm candle tone, matching the amber the asset's own lantern glass is painted with.
    static let lanternColor = UIColor(red: 1.00, green: 0.78, blue: 0.52, alpha: 1)

    /// The ceiling pendant hangs at y ≈ 5.75 and lights the whole interior rather than a
    /// pool, so it is brighter and reaches much further than a rim lantern.
    static let ceilingIntensity: Float = 4200
    static let ceilingAttenuationRadius: Float = 9.0
    static let ceilingColor = UIColor(red: 1.00, green: 0.82, blue: 0.58, alpha: 1)

    /// Metres above the lantern entity's own origin to place its light.
    ///
    /// The rim lantern origins sit at y = −0.170, the apron surface — that is the base of the
    /// lantern, not its flame. Lighting from the base throws the lantern's own body into the
    /// pool it should be casting. 0.45 m puts the source inside the chamber.
    static let lanternLightHeightAboveOrigin: Float = 0.45

    /// Entity names in the asset. Named rather than pattern-matched so a rename is a
    /// reported miss instead of a silently unlit lantern.
    static let rimLanternNames = (1...8).map { String(format: "Lantern_%02d", $0) }
    static let ceilingLanternName = "Lantern_Ceiling"

    /// One `env-review missing: <name>` line per name the review asset does not provide,
    /// however many sites look it up (ported from `experiment/env-review`, 2026-10-03). Every caller already
    /// falls through safely; this only makes the miss legible in the Console.
    @MainActor private static var envReviewMissesLogged = Set<String>()
    @MainActor
    static func envReviewMiss(_ name: String) {
        guard envReviewMissesLogged.insert(name).inserted else { return }
        logger.notice("env-review missing: \(name, privacy: .public)")
    }

    // MARK: - The glow cards
    //
    // Run 1 (2026-10-02) showed every lantern's glow cards as flat orange rectangles, near and
    // far. `logGlowCardMaterials` reports what RealityKit made of them so the cause can be
    // placed (package / connection / import); `envReviewHideGlowCards` disables them so the
    // rest of the look can be judged without them. Matched by entity path, because RealityKit
    // does not expose a texture's file name at runtime.

    static let envReviewHideGlowCards = true

    nonisolated static func isGlowCardPath(_ entityPath: String) -> Bool {
        entityPath.lowercased().contains("glow")
    }

    /// What RealityKit made of each glow-card mesh: material type, blending, opacity threshold,
    /// and which slots carry a texture. Logged once per mesh and returned for the report.
    @MainActor
    static func logGlowCardMaterials(in environment: Entity) -> String {
        var lines: [String] = []
        func describe(_ material: any RealityKit.Material) -> String {
            if let pbr = material as? PhysicallyBasedMaterial {
                let blend: String
                switch pbr.blending {
                case .opaque: blend = "opaque"
                case .transparent(let opacity):
                    blend = "transparent(scale \(opacity.scale), opacityTexture \(opacity.texture != nil ? "YES" : "no"))"
                @unknown default: blend = "unknown"
                }
                return "PhysicallyBasedMaterial blending=\(blend) opacityThreshold=\(pbr.opacityThreshold.map { String($0) } ?? "nil") "
                    + "baseColorTexture=\(pbr.baseColor.texture != nil ? "YES" : "no") emissiveTexture=\(pbr.emissiveColor.texture != nil ? "YES" : "no") "
                    + "emissiveIntensity=\(pbr.emissiveIntensity)"
            }
            if let unlit = material as? UnlitMaterial {
                let blend: String
                switch unlit.blending {
                case .opaque: blend = "opaque"
                case .transparent(let opacity):
                    blend = "transparent(scale \(opacity.scale), opacityTexture \(opacity.texture != nil ? "YES" : "no"))"
                @unknown default: blend = "unknown"
                }
                return "UnlitMaterial blending=\(blend) opacityThreshold=\(unlit.opacityThreshold.map { String($0) } ?? "nil") colorTexture=\(unlit.color.texture != nil ? "YES" : "no")"
            }
            return String(describing: type(of: material))
        }
        func walk(_ entity: Entity, path: String) {
            let entityPath = path + "/" + entity.name
            if isGlowCardPath(entityPath), let model = entity.components[ModelComponent.self] {
                for (i, material) in model.materials.enumerated() {
                    let line = "\(entity.name)[\(i)]: \(describe(material))"
                    lines.append(line)
                    logger.notice("env-review glow: \(line, privacy: .public)")
                }
            }
            for child in entity.children { walk(child, path: entityPath) }
        }
        walk(environment, path: "")
        return "GLOW-CARDS: " + (lines.isEmpty ? "no glow-card meshes found" : lines.joined(separator: " | "))
    }

    /// Disables every glow-card entity and returns a report line.
    @MainActor
    static func hideGlowCards(in environment: Entity) -> String {
        guard envReviewHideGlowCards else { return "GLOW-CARDS: shown (envReviewHideGlowCards = false)" }
        var hidden: [String] = []
        func walk(_ entity: Entity, path: String) {
            let entityPath = path + "/" + entity.name
            if isGlowCardPath(entityPath), entity.components[ModelComponent.self] != nil {
                entity.isEnabled = false
                hidden.append(entity.name)
                logger.notice("env-review glow: hid \(entity.name, privacy: .public)")
                return
            }
            for child in entity.children { walk(child, path: entityPath) }
        }
        walk(environment, path: "")
        return "GLOW-CARDS: hidden \(hidden.count) [\(hidden.joined(separator: ", "))]"
    }

    // MARK: - Image-based light
    //
    // **Punctual lights cannot produce ambient or specular response. This is not a tuning
    // problem and raising the moon or lantern values will not fix it** - it makes the lit
    // side brighter while the unlit side stays exactly as black. A PBR surface with no
    // environment probe has nothing to reflect: a low-roughness material like the water
    // reflects the environment and only the environment, so with no IBL it renders black by
    // definition rather than by accident.

    /// Ambient level, as RealityKit's exponent. 0 is the resource's authored level; each +1
    /// doubles it. **This is the ambient knob** - tune it against the moon and lanterns
    /// rather than raising them.
    ///
    /// **2.5 as of Stage 6**, raised from 1.0. At 1.0 the probe resolved — the water read
    /// blue with ripple and a moon reflection — but the overall level was far too dark: rear
    /// terrain near-black, muqarnas capitals barely legible. Each +1 doubles, so this is
    /// roughly 2.8x the ambient of 1.0.
    static let iblIntensityExponent: Float = 2.5

    /// Whether the probe rotates with the entity it is attached to. False keeps the sky
    /// fixed to the world, which is what a sky is.
    static let iblInheritsRotation = false

    // MARK: - Procedural sky
    //
    // These three drive `NightSkyMaterial.usda`, which replaces the sky dome's baked star
    // texture with stars computed per fragment. The reason is resolution, not taste: the
    // baked equirect is 2048x1024 = 5.69 px/degree against a display that resolves about
    // 34, so every star arrives about six times oversized and soft. A procedural star is
    // evaluated at fragment rate and is therefore exactly as sharp as the display.
    //
    // The texture is still used, at 512x256, for the milky way band and the sky gradient -
    // low-frequency signal that loses nothing at low resolution, which is precisely what a
    // texture IS good for.

    /// Fraction of star cells that contain a star. 0 = empty sky; 1 = every cell filled,
    /// which reads as noise rather than as a sky. **This is the count knob.**
    ///
    /// **0.08 as of Stage 9**, from 0.35. 0.35 put far more stars on the sphere than the
    /// display can resolve, and every one of them was a flicker source. Fewer, larger,
    /// steadier stars read as a night sky; a dense field of scintillating points reads as
    /// noise.
    static let starDensity: Float = 0.08

    /// Peak emissive luminance of a star centre, before tone mapping. **The level knob** -
    /// raise this rather than `milkyWayIntensity` if the sky reads as empty.
    ///
    /// **0.6 as of Stage 10**, from 0.9, from 1.6. Contrast is an aliasing multiplier: a
    /// bright point against near-black sky makes whatever sampling error remains maximally
    /// visible, so lowering this is part of the flicker fix rather than a separate taste
    /// change.
    static let starBrightness: Float = 0.6

    /// Multiplier on the low-res equirect, which carries the milky way band AND the sky
    /// gradient - one texture, because they are one low-frequency signal. 0 gives
    /// procedural stars on pure black.
    static let milkyWayIntensity: Float = 0.6

    /// **THE A/B SWITCH between the two star mechanisms. Default FALSE = sprite stars.**
    ///
    /// `false` (shipped): the SPRITE field - one merged mesh of camera-facing quads carrying a
    /// mipmapped gaussian, built by `StarFieldMesh`. The in-shader star graph still exists but
    /// `starBrightness` is bound to 0, so the dome contributes only the dithered band and the
    /// stars are separate geometry.
    ///
    /// `true`: the OLD in-shader procedural field, and no sprite mesh. Kept for comparison
    /// rather than deleted, because "the new one is better" is a claim someone should be able
    /// to check by flipping one constant.
    ///
    /// **The meaning of this flag changed at Stage 11b.** It used to mean "stars on/off". It
    /// now selects WHICH mechanism, and both states draw stars. To ship with no stars at all,
    /// set `starFieldBrightness` to 0 with this false.
    static let proceduralStarsEnabled = false

    // MARK: - Sprite star field

    /// Quads in the merged mesh. ~1,300 is roughly the naked-eye count and matches what the
    /// in-shader field produced at its final density.
    static let starFieldQuadCount = 1300

    /// Angular diameter of one star, in degrees. The sprite's mip chain handles the sampling,
    /// so this is a LOOK setting rather than an anti-aliasing floor - which is the whole
    /// advantage of sprites over the analytic dot.
    static let starFieldAngularDiameterDeg: Float = 0.18

    /// Level for the sprite field. Separate from `starBrightness`, which now only drives the
    /// old in-shader path.
    static let starFieldBrightness: Float = 1.0

    // MARK: - Sky dome placement
    //
    // TWO THINGS MAKE THE SKY READ AS INFINITE, AND THE RADIUS IS THE LESS IMPORTANT ONE.
    //
    // Parallax is what tells the eye how far away something is. A dome fixed in the world has
    // parallax as the wearer moves, however large it is, so it reads as a wall at some finite
    // distance. A dome that FOLLOWS THE HEAD has exactly zero parallax at any radius, which is
    // what "infinitely far" means perceptually. Following the head is the fix; the radius only
    // decides what fits inside.
    //
    // Translation ONLY. Rotation is deliberately not followed - a sky that rotated with the
    // head would smear across every turn, and `iblInheritsRotation` is false for the same
    // reason. The pavilion does not follow anything.

    /// Target dome radius, applied as a SCALE on the dome entity - the asset's geometry is not
    /// edited. Measured authored radius is 2400 m, so the scale is target/measured.
    ///
    /// **Note this is a REDUCTION from the authored 2400 m, not an increase**, and far-plane
    /// clipping was never the constraint: the dome rendered at 2400 m, which demonstrates the
    /// far plane is already beyond that. With the dome following the head the radius no longer
    /// affects parallax at all, so what it actually governs is what stays inside it - the text
    /// at `textDistance`, the lake at 500 m and the rear terrain out to 500 m all do.
    static let skyDomeTargetRadius: Float = 1000

    /// Scales the dome to `skyDomeTargetRadius` and returns a report line.
    ///
    /// A transform, not a geometry edit. The dome is centred on its own origin - its authored
    /// extent is symmetric about zero - so a uniform scale about that origin is exactly a
    /// change of radius and nothing else.
    @MainActor
    static func setSkyDomeRadius(in environment: Entity) -> String {
        guard let dome = environment.findEntity(named: skyDomeEntityName) else {
            envReviewMiss(skyDomeEntityName)
            return "DOME: '\(skyDomeEntityName)' not found; radius NOT changed"
        }
        guard let measured = skyDomeRadius(in: environment), measured > 1 else {
            return "DOME: radius unreadable; NOT changed"
        }
        let factor = skyDomeTargetRadius / measured
        dome.scale = .init(repeating: factor)
        return String(format: "DOME: authored radius %.0f m -> target %.0f m (scale %.5f, "
                            + "transform only, geometry untouched)",
                      measured, skyDomeTargetRadius, factor)
    }

    /// Dome radius, measured from the loaded asset rather than assumed, so the quads land on
    /// the dome rather than at a hardcoded distance.
    static func skyDomeRadius(in environment: Entity) -> Float? {
        guard let dome = environment.findEntity(named: skyDomeEntityName) else { return nil }
        let b = dome.visualBounds(relativeTo: nil)
        let r = max(b.max.x, max(b.max.y, b.max.z))
        return r > 1 ? r : nil
    }

    /// Star cells across the sphere per unit of normalised direction, and the star's angular
    /// radius in cell units. **Bound from here rather than left to the material's defaults**,
    /// so the values in force are readable in Swift and reported at runtime.
    ///
    /// The ratio is what matters: `starSize / starScale` IS the angular radius in radians.
    /// 0.057/36 = 1.583e-3 rad = 0.0907 deg radius, 0.1814 deg diameter.
    ///
    /// **Sized against PERIPHERAL resolution, which is the Stage 10 correction.** 34 px/deg
    /// is the foveal figure; foveated rendering samples off-axis far more coarsely, so Stage
    /// 9's 0.0716 deg star was 2.44 foveal pixels and only ~0.6 peripheral pixels - still
    /// sub-pixel exactly where the blinking was worst. These values give ~1.5 peripheral
    /// pixels at a conservative foveal/4 estimate.
    static let starScale: Float = 36
    static let starSize: Float = 0.057

    /// The dome prim inside the environment asset, by name. Read from the loaded hierarchy
    /// rather than assumed, exactly as the lanterns are.
    static let skyDomeEntityName = "Night_Sky_Dome"

    static let skyMaterialPath = "/Root/NightSkyMaterial"
    static let skyMaterialResource = "Materials/NightSkyMaterial"

    // MARK: - Draw order
    //
    // THIS IS WHAT PUT A BLACK RECTANGLE BEHIND THE AYAH, AND IT IS A STAGE 8 REGRESSION.
    //
    // The sky dome used to carry a UsdPreviewSurface, which compiles OPAQUE and therefore
    // drew in the opaque pass, before anything transparent. Replacing it with a hand-authored
    // ShaderGraphMaterial moved it into the TRANSPARENT pass, because `realitytool` infers
    // blending and every hand-authored graph comes out transparent - measured, by compiling
    // the sky material alone and reading the shader variant out of the binary:
    //
    //     surfaceShaderUnlitTransparent
    //
    // and it stays transparent with a constant `opacity = 1`, and with the PBR surface
    // shader in place of the unlit one. There is no USD attribute to force opaque; the Swift
    // `ShaderGraphMaterial` type exposes only `triangleFillMode` and `faceCulling`.
    //
    // So the sky and the ayah plane are now BOTH transparent, and their relative order is
    // left to RealityKit's distance sort. The dome is a sphere centred on the origin, so it
    // sorts by a centre that is nearer than the plane's - which puts the sky AFTER the text,
    // where it is depth-rejected inside the plane's footprint and simply never drawn. What
    // is left there is the cleared framebuffer: a black rectangle exactly the size of the
    // plane, with the glyphs sitting on it.
    //
    // The fix is to stop leaving the order to a heuristic. Both entities go in ONE sort
    // group with explicit orders, sky first.
    static let skyAndTextSortGroup = ModelSortGroup()
    static let skyDrawOrder: Int32 = 0
    static let ayahDrawOrder: Int32 = 1
    /// The English layer (Stage 2 B4), after the Arabic. Without an explicit order the
    /// distance sort could put the sky dome after it - the same black-rectangle trap.
    static let englishDrawOrder: Int32 = 2

    /// The sky map already inside the usdz - 2048x1024 equirectangular. Used rather than
    /// shipping a second copy of the same pixels.
    static let skyTexturePathInUSDZ = "textures/night_sky_2k.png"

    private static let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "Lighting")

    // MARK: - Build

    struct Result {
        var lights: [Entity] = []
        var placed: [String] = []
        var missing: [String] = []
        var summary: String {
            var s = ["lights created: \(lights.count)"]
            s.append(contentsOf: placed.map { "  " + $0 })
            if !missing.isEmpty {
                s.append("  MISSING (named in EnvironmentLighting, absent from the asset):")
                s.append(contentsOf: missing.map { "    " + $0 })
            }
            return s.joined(separator: "\n")
        }
    }

    /// Builds the rig against a loaded environment and returns the light entities for the
    /// caller to add. They are deliberately NOT parented into the environment: the asset is
    /// added exactly as it arrives, and hanging children off it would change that.
    @MainActor
    static func build(for environment: Entity) -> Result {
        var result = Result()

        // Key light. A DirectionalLightComponent emits along its entity's -Z, so the entity
        // is oriented onto the chosen direction rather than the direction being baked into a
        // vector somewhere.
        let moon = Entity()
        moon.name = "moon-key"
        moon.components.set(DirectionalLightComponent(color: moonColor, intensity: moonIntensity))
        moon.look(at: normalize(moonDirection), from: .zero, relativeTo: nil)
        result.lights.append(moon)
        result.placed.append(String(format: "moon-key  directional  %.0f lux  dir(%.2f, %.2f, %.2f)",
                                    moonIntensity, moonDirection.x, moonDirection.y, moonDirection.z))

        for name in rimLanternNames {
            guard let lantern = environment.findEntity(named: name) else {
                envReviewMiss(name)
                result.missing.append(name)
                continue
            }
            let base = lantern.position(relativeTo: nil)
            let light = Entity()
            light.name = "light-\(name)"
            light.position = SIMD3<Float>(base.x, base.y + lanternLightHeightAboveOrigin, base.z)
            light.components.set(PointLightComponent(color: lanternColor,
                                                     intensity: lanternIntensity,
                                                     attenuationRadius: lanternAttenuationRadius))
            result.lights.append(light)
            result.placed.append(String(format: "%-16s point  %.0f lm  r=%.1fm  at (%.3f, %.3f, %.3f)",
                                        (name as NSString).utf8String!, lanternIntensity,
                                        lanternAttenuationRadius, light.position.x, light.position.y, light.position.z))
        }

        if let ceiling = environment.findEntity(named: ceilingLanternName) {
            let base = ceiling.position(relativeTo: nil)
            let light = Entity()
            light.name = "light-\(ceilingLanternName)"
            light.position = base
            light.components.set(PointLightComponent(color: ceilingColor,
                                                     intensity: ceilingIntensity,
                                                     attenuationRadius: ceilingAttenuationRadius))
            result.lights.append(light)
            result.placed.append(String(format: "%-16s point  %.0f lm  r=%.1fm  at (%.3f, %.3f, %.3f)",
                                        (ceilingLanternName as NSString).utf8String!, ceilingIntensity,
                                        ceilingAttenuationRadius, base.x, base.y, base.z))
        } else {
            envReviewMiss(ceilingLanternName)
            result.missing.append(ceilingLanternName)
        }

        logger.notice("\(result.summary, privacy: .public)")
        return result
    }

    /// Builds the environment probe from the sky map carried inside the usdz.
    ///
    /// The PNG is read straight out of the archive rather than shipped a second time beside
    /// it. usdz is a zip whose entries are stored uncompressed and 64-byte aligned, which is
    /// what makes reading one out of it a slice rather than a decompression.
    @MainActor
    static func makeEnvironmentResource() async -> (resource: EnvironmentResource?, note: String) {
        guard let url = Bundle.main.url(forResource: PavilionEnvironment.resourceName, withExtension: "usdz") else {
            return (nil, "IBL: usdz not found in bundle")
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return (nil, "IBL: could not map usdz")
        }
        guard let png = extractStoredEntry(named: skyTexturePathInUSDZ, from: data) else {
            envReviewMiss(skyTexturePathInUSDZ)
            return (nil, "IBL: \(skyTexturePathInUSDZ) not found inside the usdz")
        }
        guard let provider = CGDataProvider(data: png as CFData),
              let image = CGImage(pngDataProviderSource: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else {
            return (nil, "IBL: sky PNG decoded to no image (\(png.count) bytes)")
        }
        do {
            let resource = try await EnvironmentResource.generate(fromEquirectangular: image,
                                                                 withName: "night-sky")
            return (resource, "IBL: built from \(skyTexturePathInUSDZ), \(image.width)x\(image.height), \(png.count) bytes")
        } catch {
            return (nil, "IBL: EnvironmentResource.generate threw \(String(describing: error))")
        }
    }

    /// Minimal zip reader for STORED entries, which is all a usdz contains.
    ///
    /// Walks the central directory rather than scanning for signatures: a PNG's bytes can
    /// contain anything, including things that look like zip headers, so searching the
    /// payload for a magic number is how you find the wrong offset.
    private static func extractStoredEntry(named wanted: String, from data: Data) -> Data? {
        let n = data.count
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int {
            Int(data[o]) | Int(data[o+1]) << 8 | Int(data[o+2]) << 16 | Int(data[o+3]) << 24
        }
        // End of central directory: scan backwards over the maximum comment length.
        var eocd = -1
        var i = n - 22
        let floor = max(0, n - 22 - 65_535)
        while i >= floor {
            if u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        let count = u16(eocd + 10)
        var offset = u32(eocd + 16)
        for _ in 0..<count {
            guard offset + 46 <= n, u32(offset) == 0x0201_4B50 else { return nil }
            let nameLen = u16(offset + 28)
            let extraLen = u16(offset + 30)
            let commentLen = u16(offset + 32)
            let localOffset = u32(offset + 42)
            let compressed = u16(offset + 10)
            let size = u32(offset + 24)
            let name = String(decoding: data[(offset + 46)..<(offset + 46 + nameLen)], as: UTF8.self)
            if name == wanted {
                guard compressed == 0 else { return nil }       // STORED only
                guard localOffset + 30 <= n, u32(localOffset) == 0x0403_4B50 else { return nil }
                let lNameLen = u16(localOffset + 26)
                let lExtraLen = u16(localOffset + 28)
                let start = localOffset + 30 + lNameLen + lExtraLen
                guard start + size <= n else { return nil }
                return data.subdata(in: start..<(start + size))
            }
            offset += 46 + nameLen + extraLen + commentLen
        }
        return nil
    }

    /// Attaches the probe. The component goes on an entity of its own, and every mesh-
    /// carrying entity is made a RECEIVER of it — a receiver component on the root alone does
    /// not reach 208 descendants, and a probe nothing receives is indistinguishable from no
    /// probe at all.
    @MainActor
    static func attachImageBasedLight(_ resource: EnvironmentResource, to environment: Entity) -> Entity {
        let probe = Entity()
        probe.name = "ibl-night-sky"
        var ibl = ImageBasedLightComponent(source: .single(resource),
                                           intensityExponent: iblIntensityExponent)
        ibl.inheritsRotation = iblInheritsRotation
        probe.components.set(ibl)

        var receivers = 0
        func mark(_ e: Entity) {
            e.components.set(ImageBasedLightReceiverComponent(imageBasedLight: probe))
            receivers += 1
            for c in e.children { mark(c) }
        }
        mark(environment)
        logger.notice("IBL attached, \(receivers) receiver entities")
        return probe
    }

    /// Reports a named material's PBR values as LOADED, so a black surface can be attributed
    /// to the material or to the missing probe rather than guessed at.
    @MainActor
    static func describeMaterial(named name: String, in environment: Entity) -> String {
        var out: [String] = ["--- material '\(name)' as loaded ---"]
        // Descends the named GROUP rather than requiring the mesh itself to carry the name.
        // 'Water' is an Xform; the mesh under it is 'Lake_Surface_Mesh', so a name test on the
        // model-carrying entity found nothing and reported the material as absent.
        func walk(_ e: Entity) {
            if let m = e.components[ModelComponent.self] {
                for (i, mat) in m.materials.enumerated() {
                    guard let p = mat as? PhysicallyBasedMaterial else {
                        out.append("  [\(i)] \(type(of: mat)) (not PBR)"); continue
                    }
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    _ = p.baseColor.tint.getRed(&r, green: &g, blue: &b, alpha: &a)
                    out.append(String(format: "  [%d] baseColor tint (%.3f, %.3f, %.3f) tex=%@  roughness=%@  metallic=%@",
                                      i, r, g, b,
                                      p.baseColor.texture == nil ? "none" : "yes",
                                      String(describing: p.roughness),
                                      String(describing: p.metallic)))
                }
            }
            for c in e.children { walk(c) }
        }
        if let group = environment.findEntity(named: name) { walk(group) }
        if out.count == 1 { out.append("  no group named '\(name)' found, or it carries no meshes") }
        return out.joined(separator: "\n")
    }

    /// A scene with no lights and a scene with broken geometry look identical in a report —
    /// both are black. This asserts the things that would make it black for a reason we could
    /// have caught without a headset: no lights, zero intensities, or an asset whose surfaces
    /// are all black.
    ///
    /// It is NOT a substitute for looking. It cannot see occlusion, an inside-out sky, or a
    /// camera inside geometry.
    @MainActor
    static func audit(environment: Entity, result: Result) -> String {
        var out: [String] = ["--- LIGHTING AUDIT (not a substitute for looking) ---"]
        out.append(result.summary)

        let lit = result.lights.count
        out.append(lit == 0 ? "FAIL: no lights created — the scene WILL be black"
                            : "ok: \(lit) light entities created")
        if !result.missing.isEmpty {
            out.append("FAIL: \(result.missing.count) named lantern(s) not found in the asset")
        }

        // Non-black surfaces: a fully black-albedo asset renders black however it is lit.
        var sampled = 0, nonBlack = 0
        func walk(_ e: Entity) {
            if let m = e.components[ModelComponent.self] {
                for mat in m.materials {
                    guard let pbr = mat as? PhysicallyBasedMaterial, sampled < 40 else { continue }
                    sampled += 1
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    if pbr.baseColor.tint.getRed(&r, green: &g, blue: &b, alpha: &a),
                       r + g + b > 0.03 || pbr.baseColor.texture != nil { nonBlack += 1 }
                }
            }
            for c in e.children { walk(c) }
        }
        walk(environment)
        out.append("base colours sampled: \(sampled), non-black or textured: \(nonBlack)")
        out.append(nonBlack == 0 && sampled > 0
                   ? "FAIL: every sampled surface is black — scene would be black under any light"
                   : "ok: surfaces can reflect light")
        return out.joined(separator: "\n")
    }

    // MARK: - Procedural sky

    /// Replaces the sky dome's baked-star material with the procedural one.
    ///
    /// The GEOMETRY is not touched - the dome mesh, its radius and its UVs are exactly as
    /// authored. Only the material on it is swapped, which is why this is a runtime change
    /// rather than an asset edit.
    ///
    /// Returns a line for the environment report either way. A sky that silently kept its
    /// blurry texture would look like a shader that did nothing, and those are two very
    /// different bugs.
    @MainActor
    static func applyProceduralSky(to environment: Entity) async -> String {
        guard let dome = environment.findEntity(named: skyDomeEntityName) else {
            envReviewMiss(skyDomeEntityName)
            return "SKY: no entity named '\(skyDomeEntityName)' — material NOT replaced"
        }
        // The named prim is an Xform; the mesh sits under it, same as 'Water'.
        var models: [Entity] = []
        func walk(_ e: Entity) {
            if e.components[ModelComponent.self] != nil { models.append(e) }
            for c in e.children { walk(c) }
        }
        walk(dome)
        guard !models.isEmpty else {
            return "SKY: '\(skyDomeEntityName)' found but carries no mesh — material NOT replaced"
        }

        let material: ShaderGraphMaterial
        do {
            material = try await ShaderGraphMaterial(named: skyMaterialPath,
                                                     from: skyMaterialResource,
                                                     in: realityKitContentBundle)
        } catch {
            logger.fault("SKY MATERIAL LOAD FAILED \(String(describing: error), privacy: .public)")
            return "SKY: load failed for \(skyMaterialPath) from \(skyMaterialResource) — \(error)"
        }

        // Bound INDIVIDUALLY. A single `try` over the list means one rejected type throws
        // and the catch discards the whole material, so a wrong parameter presents as a
        // completely absent sky rather than as a wrong-looking one.
        //
        // starScale and starSize are bound here too, rather than left to the material's
        // compiled defaults. They are declared as inputs on the Material prim, so they are
        // promoted and settable - and binding them means the star SIZE is a Swift constant
        // like everything else, tunable without recompiling the asset.
        //
        // THE KILL SWITCH IS APPLIED HERE: with stars off, starBrightness binds to 0, the
        // star graph contributes black, and the band and gradient are untouched.
        var bound = material
        var failures: [String] = []
        // In-shader stars only on the OLD path. With sprites shipped this is 0, so the dome
        // contributes the dithered band alone and the stars are separate geometry.
        let effectiveBrightness = proceduralStarsEnabled ? starBrightness : 0
        for (name, value) in [("starDensity", starDensity),
                              ("starBrightness", effectiveBrightness),
                              ("milkyWayIntensity", milkyWayIntensity),
                              ("starScale", starScale),
                              ("starSize", starSize)] {
            do { try bound.setParameter(name: name, value: .float(value)) }
            catch { failures.append("\(name): \(error)") }
        }

        // READ BACK, so the report states what the material actually holds rather than what
        // we asked it to hold.
        //
        // This exists because the compiled asset turned out to be UNREADABLE offline: a
        // .reality is a zip whose entries use Apple's compression method 0x8063, which
        // neither unzip nor libcompression decodes, so there was no way to confirm from the
        // artifact that a baked star size had actually changed. Reading the parameters back
        // off the loaded material answers that on the device, every launch, for free.
        func readBack(_ name: String) -> String {
            guard let p = bound.getParameter(name: name) else { return "\(name)=<no slot>" }
            if case let .float(f) = p { return String(format: "%@=%.4f", name, f) }
            return "\(name)=\(p)"
        }
        let inForce = ["starDensity", "starBrightness", "milkyWayIntensity",
                       "starScale", "starSize"].map(readBack).joined(separator: ", ")
        let radiusDeg = starSize / starScale * 180 / .pi

        for model in models {
            model.components[ModelComponent.self]?.materials = [bound]
            // Sky FIRST. See the note on `skyAndTextSortGroup`: without this the dome sorts
            // by its origin-centred bounds, lands after the ayah plane, and is depth-rejected
            // inside it - which is the black rectangle.
            model.components.set(ModelSortGroupComponent(group: skyAndTextSortGroup,
                                                         order: skyDrawOrder))
        }
        let note = failures.isEmpty ? "all 5 bound" : "FAILED \(failures.joined(separator: "; "))"
        return "SKY: procedural material applied to \(models.count) mesh(es) under "
             + "'\(skyDomeEntityName)' — \(note)\n"
             + "SKY: star mechanism \(proceduralStarsEnabled ? "OLD in-shader procedural" : "SPRITE MESH")\n"
             + "SKY: read back from the loaded material -> \(inForce)\n"
             + String(format: "SKY: star angular radius %.4f deg, diameter %.4f deg "
                            + "= %.2f foveal px @34ppd, %.2f peripheral px @8.5ppd",
                      radiusDeg, radiusDeg * 2, radiusDeg * 2 * 34, radiusDeg * 2 * 8.5)
    }
}
