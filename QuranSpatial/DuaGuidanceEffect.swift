//
//  DuaGuidanceEffect.swift
//  QuranSpatial
//
//  The shipped hand feedback for the dua gesture, replacing the cyan/magenta joint spheres
//  and the palm-normal bars of `DuaDebugVisualization`, which read as a developer overlay.
//  Nothing here judges the pose: `DuaGuidanceProgress` reads the recognizer's own diagnostics
//  against the recognizer's own enter bounds and turns them into a 0...1 closeness, and the
//  effect spends that closeness on brightness, particle count, trail length and convergence.
//
//  FOURTH PASS, 2026-10-06: real 3D for what is near the hands, one quiet acceptance.
//  Fingertips are small gold BEADS (mesh spheres, metallic, lightly emissive) that show a lit
//  and an unlit side as the hand turns. Around each hand a faint volume of illuminated dust
//  (one particle emitter, 6-10 sprites of 2-6 mm at 0.2-0.4 opacity, drifting slowly in
//  random directions). Once both hands are near the posture, a few tinier beads leave each
//  palm and travel a slow curved path toward the space between the hands, each at its own
//  depth. On acceptance everything near the hands eases toward one point between the palms
//  and dims (0.8 s), holds as one small soft gold light (0.3 s), then rises 12 cm and fades
//  (1.2 s) as the basmala plays. No burst, no ring, no flash, no new particles. The hands are
//  clean 0.5 s after acceptance. Every knob is in `Tuning`, below; `isEnabled` is the ship flag.
//
//  Cost: 22 entities in all (per hand: a pivot, one emitter, 4 fingertip beads, 4 linking
//  beads; plus the acceptance light and the root). Nothing is created or destroyed per
//  frame; transforms, opacity components and emitter parameters are updated in place.
//

import RealityKit
import UIKit
import simd

// MARK: - Progress (pure, tested)

/// Closeness of the current hand metrics to the dua ENTER bounds, 0...1. Pure and unit-tested;
/// the thresholds are `DuaPostureRecognizer`'s own constants, read, never written.
struct DuaGuidanceProgress: Equatable {
    /// Per-hand closeness over inward, towardHead, extension and belowHeadY. 0 when untracked.
    var left: Float = 0
    var right: Float = 0
    /// Whole-posture closeness: both hands and the separation gate; the recognizer's own
    /// commit progress once it is `entering`, and 1 while `held`. 0 unless both hands are tracked.
    var overall: Float = 0
    var leftTracked = false
    var rightTracked = false

    /// Linear ramp from `lo` (0) to `hi` (1), clamped; nil reads as 0.
    static func ramp(_ value: Float?, from lo: Float, to hi: Float) -> Float {
        guard let value else { return 0 }
        return min(1, max(0, (value - lo) / (hi - lo)))
    }

    /// 1 inside [lo, hi], falling to 0 over `falloff` beyond either edge; nil reads as 0.
    static func band(_ value: Float?, lo: Float, hi: Float, falloff: Float) -> Float {
        guard let value else { return 0 }
        if value < lo { return max(0, 1 - (lo - value) / falloff) }
        if value > hi { return max(0, 1 - (value - hi) / falloff) }
        return 1
    }

    static func handCloseness(inward: Float?, towardHead: Float?, fingerExtension: Float?, belowHeadY: Float?) -> Float {
        typealias R = DuaPostureRecognizer
        let a = ramp(inward, from: R.palmInwardDotExitMin, to: R.palmInwardDotEnterMin)
        let b = ramp(towardHead, from: R.palmTowardHeadDotExitMin, to: R.palmTowardHeadDotEnterMin)
        let c = ramp(fingerExtension, from: 1.0, to: R.fingerExtensionEnterMin)
        // Lower is closer for belowHeadY: at or above the enter bound reads 1, 0.2 m past it 0.
        let d = belowHeadY.map { 1 - ramp($0, from: R.maxBelowHeadYEnter, to: R.maxBelowHeadYEnter + 0.2) } ?? 0
        return (a + b + c + d) / 4
    }

    init() {}

    init(diagnostics dg: DuaPostureRecognizer.Diagnostics) {
        typealias R = DuaPostureRecognizer
        leftTracked = dg.leftTracked
        rightTracked = dg.rightTracked
        left = leftTracked
            ? Self.handCloseness(inward: dg.leftPalmInwardDot, towardHead: dg.leftPalmTowardHeadDot,
                                 fingerExtension: dg.leftFingerExtension, belowHeadY: dg.leftBelowHeadY)
            : 0
        right = rightTracked
            ? Self.handCloseness(inward: dg.rightPalmInwardDot, towardHead: dg.rightPalmTowardHeadDot,
                                 fingerExtension: dg.rightFingerExtension, belowHeadY: dg.rightBelowHeadY)
            : 0
        guard leftTracked, rightTracked else { overall = 0; return }
        let separation = Self.band(dg.separation, lo: R.minHandSeparationEnter, hi: R.maxHandSeparationEnter, falloff: 0.1)
        var value = (left + right + separation) / 3
        switch dg.state {
        case .entering:
            // The recognizer is counting its commit window: closeness is already full, and the
            // last stretch is the hold itself.
            let hold = Float((dg.holdProgress ?? 0) / R.commitWindow)
            value = max(value, 0.85 + 0.15 * min(1, max(0, hold)))
        case .held:
            value = 1
        case .idle:
            break
        }
        overall = min(1, max(0, value))
    }
}

// MARK: - The effect

@MainActor
final class DuaGuidanceEffect {

    /// SHIP FLAG. Off, the effect is never added to the scene and costs nothing.
    static let isEnabled = true

    // ======================================================================================
    // TUNING - the one place to adjust after a headset look. Metres, seconds, multipliers.
    // Keys unchanged across passes; meanings as commented for this pass.
    // ======================================================================================
    struct Tuning {
        /// Multiplier on the dust count. 1.0 = 6 sprites per hand at a wrong posture, 10 near the bounds.
        var particleCount: Float = 1.0
        /// Multiplier on the dust sprite size (1.0 = 2-6 mm) and on the beads' scale.
        var particleSize: Float = 1.0
        /// Multiplier on the dust drift speed (1.0 = about 0.8 cm/s).
        var particleSpeed: Float = 1.0
        /// Reserved; no trails in this pass (dust and beads are points).
        var trailLength: Float = 1.0
        /// Depth of the dust volume around each hand, metres (its extent along the palm normal).
        var streamLength: Float = 0.15
        /// Random wander of the dust (noise strength); higher = more meander.
        var streamWidth: Float = 0.03
        /// Multiplier on the beads' emissive intensity and the dust opacity.
        var auraIntensity: Float = 1.0
        /// Radius of the dust volume around each hand across the palm, metres.
        var auraRadius: Float = 0.10
        /// Linking beads per hand (pool size; set before the view is built).
        var convergenceParticleCount: Float = 4
        /// Travel speed of the linking beads along their curved path, m/s.
        var convergenceSpeed: Float = 0.06
        /// Multiplier on the acceptance light's size and brightness.
        var confirmationIntensity: Float = 1.0
    }
    static var tuning = Tuning()

    // Palette: lantern gold for every bead and sprite; amber only as the dust fades.
    private static let goldRGB = (r: CGFloat(0.93), g: CGFloat(0.78), b: CGFloat(0.50))
    private static let gold  = UIColor(red: goldRGB.r, green: goldRGB.g, blue: goldRGB.b, alpha: 1)
    private static let ivory = UIColor(red: 1.00, green: 0.95, blue: 0.82, alpha: 1)
    private static let amber = UIColor(red: 0.95, green: 0.66, blue: 0.30, alpha: 1)
    private static func faded(_ c: UIColor, _ alpha: CGFloat) -> UIColor { c.withAlphaComponent(alpha) }

    // Geometry of the beads.
    private static let tipRadius: Float = 0.006
    private static let linkRadius: Float = 0.0035
    private static let acceptanceLightRadius: Float = 0.005     // ~1 cm across

    // The acceptance, seconds from the gate's accept.
    private static let convergeSeconds: Float = 0.8
    private static let holdSeconds: Float = 0.3
    private static let riseSeconds: Float = 1.2
    private static let riseHeight: Float = 0.12
    private static let handsFadeSeconds: Float = 0.5            // item 5: clean hands by then
    /// After the light has gone, the dust already alive finishes its lifespan (attracted to
    /// the centre and dimming by its own colour curve); the root is switched off after this.
    private static let dustLifeSeconds: Float = 3.5
    private static let fadeInSeconds: Float = 0.3
    private static let fadeOutSeconds: Float = 0.5
    private static let smoothingRate: Float = 5

    private struct LinkBead {
        let entity: ModelEntity
        let phase: Float            // 0..1, where on the path it starts
        let side: Float             // lateral bulge, metres (signed)
        let depth: Float            // toward/away from the wearer, metres (signed)
        var lastPosition = SIMD3<Float>(repeating: 0)
    }

    private struct HandSet {
        let pivot: Entity           // at the palm, +Z along the palm normal
        let dust: Entity            // ParticleEmitterComponent
        let tips: [ModelEntity]     // 4 gold beads
        var links: [LinkBead]
        var intensity: Float = 0
        var palmCenter = SIMD3<Float>(repeating: 0)
        var tracked = false
    }

    private let root: Entity
    private var left: HandSet
    private var right: HandSet
    private let acceptanceLight: ModelEntity
    private var glowTexture: TextureResource?

    private var visibility: Float = 0
    private var overall: Float = 0
    private var clock: Float = 0
    private var confirmAge: Float?
    private var confirmCentre = SIMD3<Float>(0, 1.3, -0.4)
    private var dustEmitting = false

    var entity: Entity { root }
    /// For the report: every entity under the root, plus the root.
    var entityCount: Int { 1 + Self.count(root) }
    private static func count(_ e: Entity) -> Int { e.children.reduce(0) { $0 + 1 + count($1) } }

    init() {
        let root = Entity()
        let t = Self.tuning

        // Materials. Beads: gold, fully metallic, a little rough, lightly emissive - a lit
        // and an unlit side under the scene's light, with a glow that never flattens them.
        func bead(radius: Float, emissive: Float) -> ModelEntity {
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: Self.gold)
            m.metallic = .init(floatLiteral: 1.0)
            m.roughness = .init(floatLiteral: 0.25)
            m.emissiveColor = .init(color: Self.gold)
            m.emissiveIntensity = emissive * t.auraIntensity
            let e = ModelEntity(mesh: .generateSphere(radius: radius), materials: [m])
            e.components.set(OpacityComponent(opacity: 0))
            e.isEnabled = false
            root.addChild(e)
            return e
        }
        func makeSet(seed: Int) -> HandSet {
            let pivot = Entity()
            root.addChild(pivot)
            let dust = Entity()
            dust.components.set(ParticleEmitterComponent())
            pivot.addChild(dust)
            let tips = (0..<4).map { _ in bead(radius: Self.tipRadius, emissive: 0.6) }
            let n = max(1, Int(t.convergenceParticleCount.rounded()))
            let links = (0..<n).map { i -> LinkBead in
                // Spread the beads along the path, alternate the bulge side, and give each a
                // different depth so they never sit on one plane.
                let f = Float(i) / Float(n)
                let side: Float = (i % 2 == 0 ? 1 : -1) * (0.025 + 0.02 * f)
                let depth: Float = (((i + seed) % 3) == 0 ? -1 : (((i + seed) % 3) == 1 ? 0.5 : 1)) * 0.03
                return LinkBead(entity: bead(radius: Self.linkRadius, emissive: 0.3), phase: f, side: side, depth: depth)
            }
            return HandSet(pivot: pivot, dust: dust, tips: tips, links: links)
        }
        left = makeSet(seed: 0)
        right = makeSet(seed: 1)

        // The acceptance light: emissive only, black base, so it is a soft point of gold.
        var lm = PhysicallyBasedMaterial()
        lm.baseColor = .init(tint: .black)
        lm.metallic = .init(floatLiteral: 0)
        lm.roughness = .init(floatLiteral: 1)
        lm.emissiveColor = .init(color: Self.gold)
        lm.emissiveIntensity = 1.6 * t.confirmationIntensity
        let light = ModelEntity(mesh: .generateSphere(radius: Self.acceptanceLightRadius), materials: [lm])
        light.components.set(OpacityComponent(opacity: 0))
        light.isEnabled = false
        root.addChild(light)
        acceptanceLight = light

        self.root = root
        root.isEnabled = false
        configureDust()
    }

    /// Loads the dust sprite. Called once from the RealityView make closure.
    func prepare() async {
        guard glowTexture == nil, let image = Self.makeGlowImage() else { return }
        glowTexture = try? await TextureResource(image: image, options: .init(semantic: .color))
        configureDust()
    }

    /// The dust: one emitter per hand, born throughout a flattened volume around the palm
    /// (`auraRadius` across, `streamLength` deep), drifting slowly in random directions,
    /// 2-6 mm sprites at 0.2-0.4 opacity, additive so overlaps warm rather than whiten.
    private func configureDust() {
        let t = Self.tuning
        for set in [left, right] {
            var d = ParticleEmitterComponent()
            d.emitterShape = .box
            d.emitterShapeSize = SIMD3<Float>(t.auraRadius * 2, t.auraRadius * 2, t.streamLength)
            d.birthLocation = .volume
            d.birthDirection = .normal
            d.speed = 0.008 * t.particleSpeed
            d.speedVariation = 0.005 * t.particleSpeed
            d.particlesInheritTransform = false
            d.mainEmitter.lifeSpan = Double(Self.dustLifeSeconds)
            d.mainEmitter.lifeSpanVariation = 1.0
            d.mainEmitter.size = 0.004 * t.particleSize
            d.mainEmitter.sizeVariation = 0.002 * t.particleSize
            d.mainEmitter.sizeMultiplierAtEndOfLifespan = 0.7
            let peak = CGFloat(min(0.4, max(0.2, 0.32 * t.auraIntensity)))
            d.mainEmitter.color = .evolving(start: .random(a: Self.faded(Self.gold, peak), b: Self.faded(Self.ivory, peak * 0.8)),
                                            end: .single(Self.faded(Self.amber, 0)))
            d.mainEmitter.opacityCurve = .gradualFadeInOut
            d.mainEmitter.blendMode = .additive
            d.mainEmitter.noiseStrength = t.streamWidth
            d.mainEmitter.noiseScale = 0.7
            d.mainEmitter.noiseAnimationSpeed = 0.12
            d.mainEmitter.isLightingEnabled = false
            d.mainEmitter.image = glowTexture
            d.isEmitting = false
            set.dust.components.set(d)
        }
    }

    /// 128 px white radial falloff for the dust sprite.
    private static func makeGlowImage() -> CGImage? {
        let size = 128
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                      CGColor(red: 1, green: 1, blue: 1, alpha: 0.45),
                      CGColor(red: 1, green: 1, blue: 1, alpha: 0.12),
                      CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.22, 0.55, 1]) else { return nil }
        let centre = CGPoint(x: size / 2, y: size / 2)
        ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: 0,
                               endCenter: centre, endRadius: CGFloat(size) / 2, options: [])
        return ctx.makeImage()
    }

    // MARK: Per frame

    private static func smoothstep(_ x: Float) -> Float { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }

    /// Once per rendered frame. `wanted` is the caller's read of the existing state machine:
    /// entry gate armed and the experience idle or completed. Hand state comes straight from
    /// the session; nothing is re-detected here.
    func update(session: HandTrackingSession, wanted: Bool, deltaTime: Float) {
        let dt = min(max(deltaTime, 0), 0.1)
        clock += dt
        let progress = DuaGuidanceProgress(diagnostics: session.diagnostics)
        let anyHand = progress.leftTracked || progress.rightTracked
        let show = wanted && anyHand && confirmAge == nil

        let rate = show ? dt / Self.fadeInSeconds : dt / Self.fadeOutSeconds
        visibility = show ? min(1, visibility + rate) : max(0, visibility - rate)

        if visibility <= 0.001, confirmAge == nil {
            if root.isEnabled { setDust(false); disableAll(); root.isEnabled = false }
            return
        }
        if !root.isEnabled { root.isEnabled = true }

        let k = min(1, Self.smoothingRate * dt)
        overall += (progress.overall - overall) * k

        let leftPose = session.latestLeftPose, rightPose = session.latestRightPose
        left.tracked = leftPose?.isTracked ?? false
        right.tracked = rightPose?.isTracked ?? false
        if let l = leftPose { left.palmCenter = l.palmCenter }
        if let r = rightPose { right.palmCenter = r.palmCenter }
        var centre: SIMD3<Float>?
        if left.tracked, right.tracked { centre = (left.palmCenter + right.palmCenter) / 2 }
        if confirmAge == nil, let centre { confirmCentre = centre }

        if let age = confirmAge {
            updateConfirmation(age: age + dt, head: session.latestHeadPosition)
            return
        }
        updateHand(&left, pose: leftPose, closeness: progress.left, centre: centre, head: session.latestHeadPosition, k: k)
        updateHand(&right, pose: rightPose, closeness: progress.right, centre: centre, head: session.latestHeadPosition, k: k)
    }

    private func updateHand(_ set: inout HandSet, pose: HandPose?, closeness: Float, centre: SIMD3<Float>?,
                            head: SIMD3<Float>?, k: Float) {
        let t = Self.tuning
        guard let pose, pose.isTracked else {
            set.intensity = 0
            setDust(set, false)
            for e in set.tips where e.isEnabled { e.isEnabled = false }
            for b in set.links where b.entity.isEnabled { b.entity.isEnabled = false }
            return
        }
        // Half the hand's own closeness, half the whole posture's.
        let confidence = 0.5 * closeness + 0.5 * overall
        let target = 0.45 + 0.55 * pow(confidence, 1.3)
        set.intensity += (target - set.intensity) * k
        let intensity = set.intensity
        let breath = 0.94 + 0.06 * sin(clock * 1.5)

        let normal = pose.palmNormal
        set.pivot.position = pose.palmCenter + normal * (t.streamLength * 0.25)   // volume sits a little off the palm
        set.pivot.orientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: normal)

        // Dust: 6-10 sprites per hand.
        if var d = set.dust.components[ParticleEmitterComponent.self] {
            let visible = (6 + 4 * confidence) * t.particleCount
            d.mainEmitter.birthRate = visible / Float(d.mainEmitter.lifeSpan) * intensity
            d.mainEmitter.attractionStrength = 0
            d.isEmitting = true
            set.dust.components.set(d)
        }

        // Fingertip beads: gold, slightly larger and brighter near the bounds.
        let tipPositions = [pose.joints.indexTip, pose.joints.middleTip, pose.joints.ringTip, pose.joints.littleTip]
        let tipScale = (0.9 + 0.25 * confidence) * t.particleSize * breath
        let tipOpacity = min(1, visibility * (0.55 + 0.45 * confidence) * intensity)
        for (e, p) in zip(set.tips, tipPositions) {
            e.position = p + normal * 0.003
            e.scale = SIMD3<Float>(repeating: tipScale)
            e.components.set(OpacityComponent(opacity: tipOpacity))
            if !e.isEnabled { e.isEnabled = true }
        }

        // Linking beads: only once both hands are near the posture. Each travels a slow
        // curved path from this palm toward the point between the hands, bulging to its own
        // side and sitting at its own depth, fading in at the palm and out near the centre.
        let gate = centre == nil ? 0 : min(1, max(0, (overall - 0.35) / 0.5))
        guard let centre, gate > 0.01 else {
            for b in set.links where b.entity.isEnabled { b.entity.isEnabled = false }
            return
        }
        let start = pose.palmCenter + normal * 0.02
        let chord = centre - start
        let length = max(0.05, simd_length(chord))
        let dir = chord / length
        let viewDir: SIMD3<Float> = {
            guard let head else { return SIMD3<Float>(0, 0, 1) }
            let v = head - centre
            let l = simd_length(v)
            return l > 0.01 ? v / l : SIMD3<Float>(0, 0, 1)
        }()
        let lateral = simd_normalize(simd_cross(dir, viewDir))
        let depthDir = simd_cross(lateral, dir)
        let period = length / max(0.005, t.convergenceSpeed * t.particleSpeed)
        for i in set.links.indices {
            let b = set.links[i]
            let u = (clock / period + b.phase).truncatingRemainder(dividingBy: 1)
            let bulge = sin(u * .pi)
            let control = start + chord * 0.5 + lateral * b.side * 1.6 + depthDir * b.depth * 1.6
            let p = (1 - u) * (1 - u) * start + 2 * (1 - u) * u * control + u * u * centre
            b.entity.position = p
            set.links[i].lastPosition = p
            b.entity.scale = SIMD3<Float>(repeating: t.particleSize)
            b.entity.components.set(OpacityComponent(opacity: min(1, visibility * gate * (0.35 + 0.65 * sqrt(bulge)))))
            if !b.entity.isEnabled { b.entity.isEnabled = true }
        }
    }

    // MARK: Acceptance

    /// The gesture committed. Over 0.8 s the dust and linking beads ease toward one point
    /// between the palms and dim; one small soft gold light holds there 0.3 s; it rises 12 cm
    /// over 1.2 s and fades. `recitation.start()` has no audio lead: the basmala begins at
    /// acceptance, so the light's rise plays under its opening.
    func confirm(session: HandTrackingSession) {
        if left.tracked, right.tracked { confirmCentre = (left.palmCenter + right.palmCenter) / 2 }
        else if left.tracked { confirmCentre = left.palmCenter }
        else if right.tracked { confirmCentre = right.palmCenter }
        confirmAge = 0
        if !root.isEnabled { root.isEnabled = true }
        // Freeze the beads where they are; they ease from there.
        for set in [left, right] {
            for b in set.links where b.entity.isEnabled { b.entity.position = b.lastPosition }
        }
        // The dust stops being born and is drawn to the centre, dimming on its own curve.
        for set in [left, right] {
            if var d = set.dust.components[ParticleEmitterComponent.self] {
                d.isEmitting = false
                d.mainEmitter.attractionCenter = set.pivot.convert(position: confirmCentre, from: nil)
                d.mainEmitter.attractionStrength = 1.2
                d.mainEmitter.dampingFactor = 1.5
                set.dust.components.set(d)
            }
        }
    }

    private func updateConfirmation(age: Float, head: SIMD3<Float>?) {
        let t = Self.tuning
        let c1 = Self.convergeSeconds, c2 = c1 + Self.holdSeconds, c3 = c2 + Self.riseSeconds

        // Hands clean by 0.5 s: the fingertip beads fade out.
        let handFade = 1 - Self.smoothstep(age / Self.handsFadeSeconds)
        for set in [left, right] {
            for e in set.tips where e.isEnabled {
                e.components.set(OpacityComponent(opacity: handFade * 0.8))
                if handFade <= 0 { e.isEnabled = false }
            }
        }

        if age < c1 {
            // Converge: every linking bead eases from where it was to the centre and dims.
            let u = Self.smoothstep(age / c1)
            for set in [left, right] {
                for b in set.links where b.entity.isEnabled {
                    b.entity.position = b.lastPosition + (confirmCentre - b.lastPosition) * u
                    b.entity.components.set(OpacityComponent(opacity: (1 - u) * 0.9 + 0.1))
                }
            }
        } else {
            for set in [left, right] {
                for b in set.links where b.entity.isEnabled { b.entity.isEnabled = false }
            }
        }

        if age >= c1 * 0.85, age < c3 {
            // The one light: fades in over the last of the convergence, holds, rises, fades.
            let fadeIn = Self.smoothstep((age - c1 * 0.85) / (c1 * 0.15 + 0.05))
            let rise = age < c2 ? 0 : Self.smoothstep((age - c2) / Self.riseSeconds)
            acceptanceLight.position = confirmCentre + SIMD3<Float>(0, Self.riseHeight * rise, 0)
            acceptanceLight.scale = SIMD3<Float>(repeating: t.confirmationIntensity * (1 + 0.15 * sin(clock * 3)))
            acceptanceLight.components.set(OpacityComponent(opacity: min(1, fadeIn * (1 - rise))))
            if !acceptanceLight.isEnabled { acceptanceLight.isEnabled = true }
        } else if acceptanceLight.isEnabled {
            acceptanceLight.isEnabled = false
        }

        if age >= c3 + Self.dustLifeSeconds {
            confirmAge = nil
            setDust(false)
            disableAll()
            root.isEnabled = false
            visibility = 0
            left.intensity = 0; right.intensity = 0; overall = 0
            return
        }
        confirmAge = age
        _ = head
    }

    // MARK: Pool helpers

    private func setDust(_ set: HandSet, _ on: Bool) {
        if var d = set.dust.components[ParticleEmitterComponent.self], d.isEmitting != on {
            d.isEmitting = on
            set.dust.components.set(d)
        }
    }
    private func setDust(_ on: Bool) { setDust(left, on); setDust(right, on) }

    private func disableAll() {
        for set in [left, right] {
            for e in set.tips where e.isEnabled { e.isEnabled = false }
            for b in set.links where b.entity.isEnabled { b.entity.isEnabled = false }
        }
        acceptanceLight.isEnabled = false
    }
}
