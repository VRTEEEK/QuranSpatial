//
//  ImmersiveView.swift
//  QuranSpatial
//
//  Created by Mohamed ElEryan on 31/08/2026.
//

import SwiftUI
import RealityKit
import RealityKitContent
import CoreText
import os

struct ImmersiveView: View {

    private static let duaDebugHUDAttachmentID = "duaDebugHUD"
    /// The "Meaning" panel (2026-10-03): shown beside the text while the phase is `asking`.
    private static let meaningPanelAttachmentID = "meaningPanel"
    /// Where the panel goes, relative to the head sampled at Ask entry: to the right and a
    /// little below eye level, about 1.3 m away. The text sits at azimuth 0 within ±20° and
    /// 17–30° above the eye; this is 34° to the right and 5° below, so it can never overlap it.
    private static let meaningPanelOffsetFromHead = SIMD3<Float>(0.75, -0.1, -1.1)
    /// Clear of the state indicator sphere in `DuaDebugVisualization`.
    private static let duaDebugHUDPosition = SIMD3<Float>(-0.4, 1.75, -1.2)

    /// **OFF by default, and it must stay that way.**
    ///
    /// The dua HUD is a debug instrument — recognizer gate scalars, the dissolve material's
    /// load result and the running frame report — and it is a lit panel floating a metre and
    /// a bit in front of the wearer. On by default it is in every screenshot taken to judge
    /// the scene, which makes it a measurement switch that changes what an ordinary run looks
    /// like. Same reasoning as `EnvironmentCapture.isEnabled` and the grey-box flag.
    ///
    /// **Turning this off also removes the debug abort button**, which is the only way out of
    /// an accidental dua acceptance short of sitting through the full recitation. Turn it on
    /// deliberately for a gesture or dissolve session, and turn it off again before shooting
    /// the scene.
    static let showDebugHUD = false

    /// The English layer's A/B switch for the B5 measurement (Stage 2 B4): the A build is this
    /// set to `false`, the B build `true`, with the translation file present in both so the
    /// difference is the layer and not the load. Licensing is NOT governed by this - it is
    /// governed by the file's absence (`RecitationTranslationFile.loadIfPresent`).
    static let showEnglishLayer = true

    /// Loaded once, on first use. `nil` when the gitignored translation file is not bundled or
    /// does not hash to its own `textSHA256`; the English layer is then simply not there.
    private static let translation = RecitationTranslationFile.loadIfPresent()

    @State private var handTrackingSession = HandTrackingSession()
    @State private var duaDebugVisualization = DuaDebugVisualization()
    @State private var recitation = RecitationCoordinator()
    @State private var textures = AyahTextureCache()
    @State private var dissolve = DissolveDriver()

    /// The English layer's own window of three textures, left-to-right in the system font.
    @State private var englishTextures = AyahTextureCache(rasterize: AyahTextureCache.english)

    /// Retained because an `EventSubscription` cancels itself when it is released, and a
    /// dissolve that stops on the frame after it starts is a very confusing bug.
    @State private var updateSubscription: EventSubscription?

    /// So the first-frame timing is taken once rather than every frame.
    @State private var hasReportedFirstFrame = false
    /// The Ask panel's attachment entity; enabled only while asking.
    @State private var meaningEntity: Entity?
    /// The Ask flow: speech, engine, display (challenge day 2).
    @State private var askSession = AskSession()

    /// Stage 3's A/B capture. Sequences both phases in one wearing.
    @State private var capture = EnvironmentCapture()

    /// Recorded so the first-frame report can carry it — a dark scene and a broken scene
    /// look identical in a report.
    @State private var lightingAudit = ""

    /// The grey-box environment root. Held so the text plane is never parented beneath it -
    /// the text keeps its own transform and its own unlit material.
    @State private var environmentRoot = Entity()

    /// Stage 2: the loaded pavilion USD, added exactly as it arrives.
    @State private var pavilionRoot = Entity()

    /// The one plane the recitation text lives on. Held rather than rebuilt so a texture
    /// swap cannot interrupt whatever the material is doing.
    @State private var ayahEntity = ModelEntity()

    /// The English plane (Stage 2 B4, D4): an `UnlitMaterial` that hard-cuts at the boundary.
    /// No dissolve driver touches it. A sibling of `ayahEntity` under the same text root, so
    /// it inherits placement, and it reads the same `displayedSegmentIndex`, so the Ask pin
    /// holds it too.
    @State private var englishEntity = ModelEntity()

    /// The TEXT ROOT. Carries the whole of the placement - distance, elevation, pitch and the
    /// scale that preserves the em - and `ayahEntity` hangs off it.
    ///
    /// Separated so placement is one transform on one entity. The pipeline underneath still
    /// builds a plane sized for `ayahDistance` and still top-anchors it; the root decides
    /// where that plane is in the room. Nothing about shaping, layout or the dissolve knows
    /// this exists.
    @State private var textRoot = Entity()

    /// The sky dome and the sprite star field, held so the per-frame follow can move them.
    /// Both are moved by TRANSLATION only.
    @State private var skyDomeEntity: Entity?
    @State private var starFieldEntity: Entity?

    /// Set once, when the head is first sampled at experience start. Guards against
    /// re-placing: the text is fixed in the world, not parented to the head.
    @State private var hasPlacedText = false

    /// Backgrounding is the ordinary way a device session ends - the wearer takes the
    /// headset off, or switches app - and it is the case that would otherwise silently drop
    /// the ayah in progress.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RealityView { content, attachments in
            // Before any texture is bound: `applyCurrentAyah` picks its material from
            // whether this succeeded, and a segment bound to the fallback while the load was
            // still in flight would keep the fallback until the ayah changed.
            await dissolve.load()

            // STAGE 2. Loaded and added EXACTLY as it arrives - no reparenting, no
            // rotation, no scale, no offset. If it comes in rotated that is the finding, and
            // a corrective transform here would destroy it.
            let pavilionStart = CFAbsoluteTimeGetCurrent()
            let pavilion = await PavilionEnvironment.load()
            if let loaded = pavilion.entity {
                pavilionRoot = loaded
                content.add(pavilionRoot)

                // Lighting is app-side because USD lighting cannot survive import. The
                // lights are siblings of the environment, not children: the asset is added
                // exactly as it arrives, and parenting into it would change that.
                let rig = EnvironmentLighting.build(for: pavilionRoot)
                for light in rig.lights { content.add(light) }

                // The environment probe. Punctual lights give a PBR surface nothing to
                // reflect, so without this the water - low roughness, reflection-only -
                // renders black by definition, and every unlit face stays black too.
                let (resource, note) = await EnvironmentLighting.makeEnvironmentResource()
                var iblNote = note
                if let resource {
                    let probe = EnvironmentLighting.attachImageBasedLight(resource, to: pavilionRoot)
                    content.add(probe)
                    iblNote += "  -> attached, exponent \(EnvironmentLighting.iblIntensityExponent)"
                } else {
                    iblNote += "  -> NOT ATTACHED"
                }
                // Procedural stars. The dome's GEOMETRY is untouched - only the material on
                // it is replaced, because a 2048x1024 equirect is 5.69 px/degree against a
                // display that resolves about 34 and no texture budget fixes that.
                let skyNote = await EnvironmentLighting.applyProceduralSky(to: pavilionRoot)

                // Radius as a TRANSFORM on the dome - the asset's geometry is untouched.
                let domeNote = EnvironmentLighting.setSkyDomeRadius(in: pavilionRoot)
                skyDomeEntity = pavilionRoot.findEntity(named: EnvironmentLighting.skyDomeEntityName)
                if skyDomeEntity == nil {
                    // Review asset: no dome by that name, so the sky does not follow the head
                    // (parallax at the authored 1100 m is negligible). Logged once.
                    EnvironmentLighting.envReviewMiss(EnvironmentLighting.skyDomeEntityName)
                }

                // SPRITE STAR FIELD. One merged mesh, one material, one draw submission -
                // added as a sibling of the environment, on the dome's own radius read from
                // the loaded asset rather than a hardcoded distance.
                var starNote = "STARS: old in-shader path selected; no sprite mesh built"
                if !EnvironmentLighting.proceduralStarsEnabled {
                    // Built at the TARGET radius, not the measured one: the dome is
                    // about to be scaled, and stars placed on the authored 2400 m sphere would
                    // end up outside it.
                    if true {
                        let r = EnvironmentLighting.skyDomeTargetRadius
                        var st = StarFieldMesh.Stats()
                        if let field = StarFieldMesh.build(
                            radius: r * 0.985,
                            count: EnvironmentLighting.starFieldQuadCount,
                            angularDiameterDeg: EnvironmentLighting.starFieldAngularDiameterDeg,
                            stats: &st) {
                            let bind = await StarFieldMesh.applyMaterial(
                                to: field, brightness: EnvironmentLighting.starFieldBrightness)
                            // Same sort group as the dome, one order later: the stars must
                            // blend OVER the sky rather than be depth-rejected by it, which is
                            // the same trap the ayah plane fell into in Stage 8.
                            field.components.set(ModelSortGroupComponent(
                                group: EnvironmentLighting.skyAndTextSortGroup,
                                order: EnvironmentLighting.skyDrawOrder + 1))
                            content.add(field)
                            starFieldEntity = field
                            starNote = "STARS: sprite mesh \(st.quads) quads, \(st.vertices) verts, "
                                     + "\(st.triangles) tris, \(st.parts) material part(s) = "
                                     + "\(st.parts) DRAW CALL(S); quad \(st.quadSizeMeters) m "
                                     + "= \(st.angularDiameterDeg) deg at r=\(st.radius) m; \(bind)"
                        } else {
                            starNote = "STARS: sprite mesh generation FAILED"
                        }
                    } else {
                        starNote = "STARS: dome radius unreadable; sprite mesh NOT built"
                    }
                }

                // What RealityKit made of the glow cards, then hide them (they render as
                // flat rectangles; see EnvironmentLighting.envReviewHideGlowCards).
                let glowNote = EnvironmentLighting.logGlowCardMaterials(in: pavilionRoot)
                    + "\n" + EnvironmentLighting.hideGlowCards(in: pavilionRoot)

                lightingAudit = EnvironmentLighting.audit(environment: pavilionRoot, result: rig)
                    + "\n" + glowNote
                    + "\n" + iblNote
                    + "\n" + skyNote
                    + "\n" + domeNote
                    + "\n" + starNote
                    + "\n" + EnvironmentLighting.describeMaterial(named: "Water", in: pavilionRoot)
            }

            // The grey-box is skipped while measuring, so the frame cost is of the USD
            // environment and nothing else. Two environments in one scene would measure
            // neither.
            if PavilionEnvironment.showGreyBoxEnvironment {
                var environmentStats = GreyBoxEnvironment.BuildStats()
                environmentRoot = GreyBoxEnvironment.build(stats: &environmentStats)
                content.add(environmentRoot)
                EnvironmentReport.write(stats: environmentStats)
            }

            // Add the initial RealityKit content
            if let immersiveContentEntity = try? await Entity(named: "Immersive", in: realityKitContentBundle) {
                content.add(immersiveContentEntity)

                // Put skybox here.  See example in World project available at
                // https://developer.apple.com/
            }

            // Placement lives on the ROOT. The plane's own transform is now a local offset
            // that top-anchors it on the first baseline, and nothing else - no world position,
            // no pitch, no scale.
            textRoot.orientation = AyahPlaneGeometry.textRootOrientation
            textRoot.scale = .init(repeating: AyahPlaneGeometry.textRootScale)
            // Provisional, until the head anchor arrives: a nominal standing eye at the world
            // origin. Replaced by the real sample at experience start, and the text is fully
            // dissolved until then, so nothing is visible in the meantime.
            textRoot.position = AyahPlaneGeometry.textRootPosition(
                headPosition: SIMD3<Float>(0, TextPlacementProbe.nominalEyeHeight, 0))
            textRoot.addChild(ayahEntity)
            // Text AFTER the sky, in the same sort group. Both materials are transparent, so
            // without an explicit order RealityKit's distance sort decides - and it puts the
            // origin-centred sky dome after the plane, which is the black rectangle.
            ayahEntity.components.set(
                ModelSortGroupComponent(group: EnvironmentLighting.skyAndTextSortGroup,
                                        order: EnvironmentLighting.ayahDrawOrder))
            // The English plane: same root, one order later than the Arabic. Disabled until
            // it has something to show, and never enabled at all in the A build.
            textRoot.addChild(englishEntity)
            englishEntity.components.set(
                ModelSortGroupComponent(group: EnvironmentLighting.skyAndTextSortGroup,
                                        order: EnvironmentLighting.englishDrawOrder))
            englishEntity.isEnabled = false
            Self.logEnglishLayerState()
            // Under isolation the plane is simply not ADDED. Nothing about the text pipeline,
            // its geometry, its material or the dissolve is altered - it is the same code,
            // just not in the scene for this measurement.
            if !PavilionEnvironment.isolateForMeasurement {
                content.add(textRoot)
            }

            content.add(duaDebugVisualization.entity)

            // Built either way - the attachment is cheap and gating its construction would
            // mean two code paths for the same panel. It is simply not ADDED unless asked
            // for, exactly as the ayah plane is handled under isolation.
            if Self.showDebugHUD, let hud = attachments.entity(for: Self.duaDebugHUDAttachmentID) {
                hud.position = Self.duaDebugHUDPosition
                hud.components.set(BillboardComponent())
                content.add(hud)
            }

            // The Meaning panel: in the scene from the start, DISABLED until an Ask begins,
            // positioned from the head at that moment and then left alone (not head-locked).
            if let panel = attachments.entity(for: Self.meaningPanelAttachmentID) {
                panel.components.set(BillboardComponent())
                panel.isEnabled = false
                content.add(panel)
                meaningEntity = panel
            }

            // The dissolve driver, and the only per-frame work in the app.
            //
            // `SceneEvents.Update` rather than the RealityView `update:` closure: that
            // closure fires when observed state changes, which is not the same thing as
            // once per rendered frame, and the dissolve needs the frame.
            //
            // `deltaTime` is used ONLY to measure frame cost. The effect itself reads the
            // audio player's clock every frame and integrates nothing, so this subscription
            // is not a second clock - it is a heartbeat that asks the first one what time it
            // is.
            // Phase B takes the environment out of the scene and releases it. Nothing is
            // decimated or altered - it is removed whole, which is what "not loaded" means
            // for a comparison run.
            capture.onEnterPhaseB = {
                pavilionRoot.removeFromParent()
                pavilionRoot = Entity()
            }
            if EnvironmentCapture.isEnabled {
                capture.environmentProvider = { pavilionRoot }
                capture.onFinished = { EnvironmentCapture.write($0) }
                capture.begin()
            }

            updateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                MainActor.assumeIsolated {
                    if EnvironmentCapture.isEnabled { capture.record(delta: event.deltaTime) }

                    // SKY FOLLOWS THE HEAD. Translation only, every frame.
                    //
                    // This, not the radius, is what makes the sky read as infinitely far: a
                    // world-fixed dome has parallax as the wearer moves, however large it is,
                    // and parallax is precisely the cue that says "finite distance". Pinning
                    // the dome to the head gives it exactly zero.
                    //
                    // Rotation is NOT followed - a sky that turned with the head would smear on
                    // every glance, and it is the same reason `iblInheritsRotation` is false.
                    // The pavilion, the text and the lights follow nothing.
                    //
                    // `setPosition(_:relativeTo: nil)` rather than assigning `position`, because
                    // the dome sits inside the asset's hierarchy and its parents' transforms are
                    // not this code's business.
                    if let head = handTrackingSession.latestHeadPosition {
                        skyDomeEntity?.setPosition(head, relativeTo: nil)
                        starFieldEntity?.setPosition(head, relativeTo: nil)
                    }
                    // The one figure that genuinely needs the render loop: load start to the
                    // first frame actually drawn. Recorded once.
                    if !hasReportedFirstFrame {
                        hasReportedFirstFrame = true
                        let elapsed = CFAbsoluteTimeGetCurrent() - pavilionStart
                        Task { @MainActor in
                            await PavilionEnvironment.writeReport(firstFrameSeconds: elapsed,
                                                                  sceneResult: pavilion,
                                                                  lightingAudit: lightingAudit)
                        }
                    }
                    dissolve.tick(deltaSeconds: event.deltaTime,
                                  recitation: recitation,
                                  entity: ayahEntity)

                    // D4 visibility: English only over SETTLED Arabic (progress exactly 0)
                    // or under an Ask pin. Evaluated after the tick so it reads this frame's
                    // progress; written only on change, so settled text costs no write.
                    let englishVisible = englishEntity.model != nil
                        && EnglishLayerVisibility.isVisible(arabicProgress: dissolve.currentProgress,
                                                            isPinned: recitation.pinnedSegmentIndex != nil)
                    if englishEntity.isEnabled != englishVisible {
                        englishEntity.isEnabled = englishVisible
                    }
                }
            }
        } update: { _, _ in
            duaDebugVisualization.update(with: handTrackingSession)
            // Meaning panel visibility follows the phase: shown on Ask entry beside the text,
            // gone on Continue (exitAsk) or any other way out of `asking`.
            if let panel = meaningEntity {
                let asking = recitation.experiencePhase == .asking
                if panel.isEnabled != asking {
                    if asking {
                        let head = handTrackingSession.latestHeadPosition
                            ?? SIMD3<Float>(0, TextPlacementProbe.nominalEyeHeight, 0)
                        panel.setPosition(head + Self.meaningPanelOffsetFromHead, relativeTo: nil)
                    }
                    panel.isEnabled = asking
                }
            }
            Self.applyCurrentAyah(recitation: recitation, textures: textures,
                                  dissolve: dissolve, to: ayahEntity)
            Self.applyEnglish(recitation: recitation, englishTextures: englishTextures,
                              arabicTextures: textures, to: englishEntity)
        } attachments: {
            Attachment(id: Self.meaningPanelAttachmentID) {
                AskPanelView(session: askSession, segmentIndex: recitation.displayedSegmentIndex,
                             onDone: { askSession.done() },
                             onContinue: { recitation.exitAsk() })
            }
            Attachment(id: Self.duaDebugHUDAttachmentID) {
                DuaDebugHUDView(session: handTrackingSession, dissolve: dissolve, recitation: recitation,
                                onAsk: { recitation.enterAsk() },
                                onResume: { recitation.exitAsk() }) {
                    #if DEBUG
                    recitation.debugStop()
                    handTrackingSession.experienceEnded()
                    #endif
                }
            }
        }
        // The real Ask trigger: look at the Arabic and pinch. The ayah entity carries an
        // InputTargetComponent and a collision box sized to the plane (set where the plane is
        // built), so the system's gaze-and-pinch lands on it at any distance.
        .gesture(TapGesture().targetedToEntity(ayahEntity).onEnded { _ in
            recitation.enterAsk()
        })
        .onChange(of: recitation.experiencePhase) {
            if recitation.experiencePhase == .asking {
                askSession.begin(anchor: recitation.displayedSegmentIndex)
            } else {
                askSession.end()
            }
        }
        .task {
            await handTrackingSession.start()
        }
        .task {
            Self.applyCurrentAyah(recitation: recitation, textures: textures,
                                  dissolve: dissolve, to: ayahEntity)
            Self.applyEnglish(recitation: recitation, englishTextures: englishTextures,
                              arabicTextures: textures, to: englishEntity)
        }
        // Entry only. Acceptance starts the surah; after that hand state is ignored
        // entirely and nothing here listens to it again.
        .onChange(of: handTrackingSession.acceptanceTicket) {
            // EXPERIENCE START. The head is sampled ONCE, here, and the text is placed from
            // that sample and then left alone. Not hardcoded, and deliberately not tracked:
            // text that followed the head would swim against the pavilion, and the ayah plane
            // is world-fixed by design.
            //
            // If the anchor is missing at this instant the provisional nominal placement set
            // at build time stands, and the report says so rather than guessing a head pose.
            if !hasPlacedText, let head = handTrackingSession.latestHeadPosition {
                hasPlacedText = true
                textRoot.position = AyahPlaneGeometry.textRootPosition(headPosition: head)
                TextPlacementProbe.writeReport(headPosition: head, sampled: true)
            }
            recitation.start()
        }
        // End of surah hands the gate back, which re-arms only after a release edge.
        .onChange(of: recitation.experiencePhase) {
            if recitation.experiencePhase == .completed {
                handTrackingSession.experienceEnded()
                dissolve.reportSession()
            }
            // A debug abort returns to .idle from .reciting; that is a run ending mid-ayah
            // and the partial row is worth keeping.
            if recitation.experiencePhase == .idle {
                dissolve.flushCurrentSegment(reason: "returned to idle")
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active {
                dissolve.flushCurrentSegment(reason: "scene phase \(scenePhase)")
            }
            // `.background` only; `.inactive` is ignored (decided 2026-09-30). The audio
            // would otherwise run on with the text frozen wherever the app left it.
            if scenePhase == .background {
                recitation.pause(reason: .background)
            }
        }
    }

    /// Keeps the plane showing whatever segment the coordinator is on, and keeps the
    /// window of prefetched neighbours around it. Idempotent - it runs from the RealityView
    /// update closure, which fires far more often than the text changes.
    @MainActor
    private static func applyCurrentAyah(
        recitation: RecitationCoordinator,
        textures: AyahTextureCache,
        dissolve: DissolveDriver,
        to entity: ModelEntity
    ) {
        // The DISPLAYED segment, not the audio's. They differ only while an Ask pin is held:
        // the anchor stays on the plane while the resumed audio runs through the previous
        // ayah's tail, and the prefetch window is centred on the anchor so that tail's
        // texture is warm too. Outside a pin this is `currentSegmentIndex`.
        let index = recitation.displayedSegmentIndex

        for neighbour in [index, index + 1, index - 1] {
            if let text = recitation.text(forSegmentIndex: neighbour) {
                textures.prefetch(
                    index: neighbour, text: text,
                    fontSizePixels: CGFloat(AyahPlaneGeometry.fontSizePixels),
                    maxContentWidthPixels: AyahPlaneGeometry.maxContentWidthPixels,
                    padding: CGFloat(AyahPlaneGeometry.paddingPixels)
                )
            }
        }
        textures.evict(keeping: Set([index - 1, index, index + 1]))

        guard let entry = textures.entry(for: index) else { return }

        // The name records WHICH material the plane was built with, not just which ayah.
        // Without that, a segment bound to the fallback before the graph finished loading
        // would keep the fallback for as long as it stayed on screen - and on the very first
        // segment that is the bismillah, hard-cutting while every later ayah dissolves.
        let expectedName = "ayah-\(index)-\(dissolve.isMaterialLoaded ? "shader" : "fallback")"
        if entity.components[ModelComponent.self] != nil, entity.name == expectedName { return }

        let material: any RealityKit.Material
        if let shader = dissolve.material(forSegmentIndex: index,
                                          texture: entry.texture,
                                          texturePixelSize: entry.pixelSize) {
            material = shader
        } else {
            // The graph did not load. Fall back to the plain unlit material this app used
            // before the dissolve existed: the text hard-cuts between ayat.
            //
            // Deliberately NOT an opacity ramp. A stand-in fade is the thing that quietly
            // becomes permanent, and CLAUDE.md forbids one. This failure is meant to be
            // visible as an absent effect, and it is logged by the driver besides.
            dissolve.unbind()
            var unlit = UnlitMaterial()
            unlit.color = .init(texture: .init(entry.texture))
            unlit.blending = .transparent(opacity: .init(scale: 1))
            material = unlit
        }

        // Both dimensions come from the raster through ONE fixed scale, so a glyph is the
        // same physical size in every ayah. Width is bounded by the wrap; height grows with
        // line count.
        let planeWidth = Float(entry.pixelSize.width) * AyahPlaneGeometry.metresPerPixel
        let planeHeight = Float(entry.pixelSize.height) * AyahPlaneGeometry.metresPerPixel
        // Pinch target (challenge day 2): a thin box the size of the plane, in the plane's own
        // local space, so it scales with the text root exactly as the mesh does.
        entity.components.set(CollisionComponent(shapes: [.generateBox(width: planeWidth, height: planeHeight, depth: 0.01)]))
        entity.components.set(InputTargetComponent())
        entity.components.set(HoverEffectComponent())
        entity.model = ModelComponent(
            mesh: .generatePlane(width: planeWidth, height: planeHeight),
            materials: [material]
        )
        // TOP-ANCHORED on the first line's baseline. `generatePlane` centres its mesh on
        // the entity origin, so the entity is offset to put that baseline at a fixed world
        // Y. Extra wrapped lines extend downward; the first line never rises to centre the
        // block.
        // LOCAL to the text root, which carries the placement. Y only: the root's origin IS
        // the first line's baseline, so this offset is purely the top-anchoring that keeps
        // every segment's first baseline in the same place whatever it wraps to.
        entity.position = SIMD3<Float>(
            0,
            AyahPlaneGeometry.planeCenterOffsetFromBaseline(
                firstBaselineFromTopPixels: entry.firstBaselineFromTopPixels,
                planeHeightMeters: planeHeight
            ),
            0
        )
        // Identity: the pitch is the ROOT's, not the plane's. Reset explicitly rather than
        // left alone, so an old per-plane pitch cannot survive here and compound with it.
        entity.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
        entity.name = expectedName
    }

    /// One launch line for the English layer, so T19/T20 can be read from the Console.
    @MainActor
    private static func logEnglishLayerState() {
        let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "Translation")
        guard showEnglishLayer else {
            logger.notice("English layer: DISABLED by showEnglishLayer (A build)")
            return
        }
        guard let translation else {
            logger.notice("English layer: no translation loaded; Arabic only")
            return
        }
        // The font is resolved for the real first ayah, as the raster will resolve it.
        let probe = translation.text(forSegmentIndex: 1) ?? ""
        let font = CTFontCopyPostScriptName(ArabicTextRasterizer.resolveSystemFont(
            for: probe, size: CGFloat(AyahPlaneGeometry.englishFontSizePixels))) as String
        logger.notice("English layer: \(translation.ayat.count) ayat, em \(AyahPlaneGeometry.englishEmDeg) deg, gap \(AyahPlaneGeometry.englishGapDeg) deg, font \(font, privacy: .public), D4 hard cut")
    }

    /// The English plane, D4: same displayed segment as the Arabic, prefetched the same way,
    /// placed under the Arabic plane (P1), swapped as a hard cut. It waits for the ARABIC
    /// texture too, because its position is derived from the Arabic plane's height - without
    /// that it would land at a guessed height for a frame and then jump.
    ///
    /// This decides CONTENT (model, size, position). VISIBILITY is the per-frame rule in the
    /// update subscription (`EnglishLayerVisibility`): shown only while the Arabic is settled
    /// or pinned, so the swap made here happens while the plane is hidden.
    @MainActor
    private static func applyEnglish(
        recitation: RecitationCoordinator,
        englishTextures: AyahTextureCache,
        arabicTextures: AyahTextureCache,
        to entity: ModelEntity
    ) {
        guard showEnglishLayer, let translation else { return }
        let index = recitation.displayedSegmentIndex

        for neighbour in [index, index + 1, index - 1] {
            if let text = translation.text(forSegmentIndex: neighbour) {
                englishTextures.prefetch(
                    index: neighbour, text: text,
                    fontSizePixels: CGFloat(AyahPlaneGeometry.englishFontSizePixels),
                    maxContentWidthPixels: AyahPlaneGeometry.englishMaxContentWidthPixels,
                    padding: CGFloat(AyahPlaneGeometry.englishPaddingPixels)
                )
            }
        }
        englishTextures.evict(keeping: Set([index - 1, index, index + 1]))

        // The intro has no English (decided 2026-09-30): nothing is drawn, and the previous
        // ayah's English does not linger either.
        guard translation.text(forSegmentIndex: index) != nil else {
            // No content: the model goes, and the visibility rule keeps the plane hidden.
            entity.model = nil
            entity.name = "english-\(index)-none"
            return
        }
        guard let entry = englishTextures.entry(for: index),
              let arabic = arabicTextures.entry(for: index) else { return }

        let expectedName = "english-\(index)"
        if entity.components[ModelComponent.self] != nil, entity.name == expectedName { return }

        // D4: plain unlit, full opacity, hard cut. Not an opacity ramp and not a dissolve -
        // the decided fallback, with D1 (a second dissolve driver) returning only if time
        // allows on 3 October.
        var unlit = UnlitMaterial()
        unlit.color = .init(texture: .init(entry.texture))
        unlit.blending = .transparent(opacity: .init(scale: 1))

        let planeWidth = Float(entry.pixelSize.width) * AyahPlaneGeometry.metresPerPixel
        let planeHeight = Float(entry.pixelSize.height) * AyahPlaneGeometry.metresPerPixel
        entity.model = ModelComponent(
            mesh: .generatePlane(width: planeWidth, height: planeHeight),
            materials: [unlit]
        )

        let arabicHeight = Float(arabic.pixelSize.height) * AyahPlaneGeometry.metresPerPixel
        let arabicCenter = AyahPlaneGeometry.planeCenterOffsetFromBaseline(
            firstBaselineFromTopPixels: arabic.firstBaselineFromTopPixels,
            planeHeightMeters: arabicHeight)
        entity.position = SIMD3<Float>(
            0,
            AyahPlaneGeometry.englishPlaneCenterOffset(arabicCenterOffset: arabicCenter,
                                                       arabicPlaneHeightMeters: arabicHeight,
                                                       englishPlaneHeightMeters: planeHeight),
            0
        )
        entity.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
        entity.name = expectedName
    }

}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
}
