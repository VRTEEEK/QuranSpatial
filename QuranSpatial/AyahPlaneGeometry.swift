//
//  AyahPlaneGeometry.swift
//  QuranSpatial
//
//  Where the ayah plane sits and how big it is. Separated from `ImmersiveView` so the
//  placement maths can be tested without standing up a RealityView.
//

import CoreGraphics
import Foundation
import simd

enum AyahPlaneGeometry {

    /// Vision Pro's effective angular resolution, in raster pixels per degree of visual
    /// angle. Below this density, thin strokes and diacritic marks blur or vanish instead
    /// of resolving to distinct pixels.
    static let pixelsPerDegree: Float = 34

    // MARK: - Placement — the three knobs
    //
    // All ayah placement lives HERE and nowhere else. `ImmersiveView` reads these; it does
    // not hold a position of its own. Changing where the text sits is a change to these
    // three lines and nothing else.

    /// World Y of the FIRST line's baseline. See `firstLineBaselineHeightMeters` for why the
    /// baseline rather than the plane's top edge is the thing anchored.
    ///
    /// **24.5 m as of Stage 8**, from 12.0 m. NOT chosen for composition - DERIVED from the
    /// dome. The arch band's underside is at y=4.27 m on a ring of radius 4.85 m, so a
    /// wearer standing inside the arcade can only see out below a fixed elevation; above
    /// that the text is behind stone. That ceiling is 26.99 deg for a 1.80 m eye, and this
    /// is the tallest baseline whose PLANE TOP EDGE - not its baseline - still clears it at
    /// 60 m. Raising it further hides the top of every ayah from tall wearers.
    static let ayahHeight: Float = 24.5

    /// Metres in front of the wearer, along -Z. Every angular figure in this file is computed
    /// against it, and `metresPerPixel` scales with it — so moving the text further away
    /// makes the plane proportionally larger and leaves its ANGULAR size untouched. That is
    /// the whole point: distance changes where the text is, never how big it reads.
    ///
    /// **60.0 m as of Stage 8**, from 25.0 m. Past roughly 30 m stereo disparity is below
    /// what the eyes resolve, so 60 m reads as genuinely distant - "sky" rather than "a long
    /// way off" - while staying far inside the 2400 m sky dome and nowhere near a
    /// depth-precision concern. The plane grows 2.4x again to hold its angular size.
    static let ayahDistance: Float = 60.0

    /// Degrees of pitch about X, tilting the plane to face a wearer standing below it.
    /// Negative tips the TOP edge away and brings the bottom edge forward, which is the
    /// direction that turns a plane above eye level to face down at the eye.
    ///
    /// **-22.48 deg as of Stage 8**, COMPUTED from the final height and distance rather
    /// than carried forward. A one-line ayah's plane centre sits at y=26.427 m, which is
    /// 22.48 deg above a 1.60 m eye at 60 m, so this points the plane's normal at that eye.
    ///
    /// One pitch cannot serve every segment: the plane is top-anchored, so its centre drops
    /// as line count rises. This is set for the one-line case, which is 69 of the 79
    /// segments and all 31 refrains. Ayah 33, the only three-line segment, centres at
    /// 15.64 deg and is therefore about 6.8 deg off normal - a foreshortening, not a
    /// legibility failure.
    static let ayahPitch: Float = -22.48

    /// Distance the plane is placed at, and the distance every angular figure is computed
    /// against. The plane is fixed, not billboarded, and the viewer is assumed to be at the
    /// world origin.
    ///
    /// Retained as the name the geometry and the tests already read; `ayahDistance` is the
    /// knob. One value, two names, so there is nothing to keep in sync.
    static var assumedViewingDistanceMeters: Float { ayahDistance }

    /// The widest the plane may ever get, in degrees of visual angle. Text wraps rather
    /// than exceeding it.
    static let maxAngularWidthDegrees: Float = 40

    /// **THE ANGULAR EM, and now the source of truth for text size.**
    ///
    /// This is what the glyph actually subtends at the eye, in degrees, and it is
    /// distance-invariant by construction - `metresPerPixel` scales with distance, so moving
    /// the plane changes where the text is and never how big it reads.
    ///
    /// **2.2 deg as of Stage 11d**, from a delivered 3.127 deg. This is the stage's real
    /// mechanism: past about 20 m, stereo disparity is below what the eyes resolve, so further
    /// away stops reading as further away. Angular size is what remains, and smaller text is
    /// what "distant" actually looks like.
    ///
    /// **It also finally resolves the 3.127-vs-3.000 discrepancy, by construction rather than
    /// by correction.** The old `textEmDegrees` was a NOMINAL figure: 3.0 was multiplied by
    /// `pixelsPerDegree` to get a pixel size, but the plane's width maps 40 deg through a
    /// `tan`, so the delivered angle came out 4.2% high at 3.127 deg. `fontSizePixels` is now
    /// inverted from this constant through the same `tan`, so what is written here is what is
    /// delivered - measured at 2.2000 deg.
    static let textAngularEmDeg: Float = 2.2

    /// Margin around the text block, in raster pixels. Fixed because the font size is.
    static let paddingPixels: Float = 48

    // MARK: - English layer (Stage 2 B4, placement P1)
    //
    // The English translation sits BELOW the Arabic plane: its top edge is the Arabic
    // plane's bottom edge less a gap, so it moves down on the ten multi-line ayat and never
    // overlaps. It is a child of the same text root, so distance, pitch and the em-preserving
    // scale come for free. These are the constants you tune on device.

    /// The English em in degrees of visual angle. **1.3 deg to start** (decided 2026-09-30),
    /// against the Arabic 2.2: a reading hierarchy, not a measurement.
    static let englishEmDeg: Float = 1.3

    /// Gap between the Arabic plane's bottom EDGE and the English plane's top EDGE, in degrees.
    /// Note both planes carry padding inside their edges (48 px Arabic, `englishPaddingPixels`
    /// English), so the visible ink-to-ink gap is this plus both paddings. Start small.
    static let englishGapDeg: Float = 0.3

    /// Latin has no overhanging marks to clear, so the English raster needs far less margin
    /// than the Arabic's 48 px.
    static let englishPaddingPixels: Float = 16

    /// Same `tan` inversion as `fontSizePixels`, so the delivered English em is the one named.
    static var englishFontSizePixels: Float {
        Float(maxTextureWidthPixels) * tan(englishEmDeg / 2 * .pi / 180)
            / tan(maxAngularWidthDegrees / 2 * .pi / 180)
    }

    /// Same 40 degree wrap as the Arabic, less the English padding.
    static var englishMaxContentWidthPixels: Int { maxTextureWidthPixels - Int(englishPaddingPixels) * 2 }

    /// The gap in root-local metres at the canonical distance (the root's scale applies on top).
    static var englishGapMeters: Float { assumedViewingDistanceMeters * tan(englishGapDeg * .pi / 180) }

    /// P1: the English plane's centre in root-local Y (first Arabic baseline at 0), given the
    /// Arabic plane's centre offset and height from `planeCenterOffsetFromBaseline`.
    static func englishPlaneCenterOffset(arabicCenterOffset: Float,
                                         arabicPlaneHeightMeters: Float,
                                         englishPlaneHeightMeters: Float) -> Float {
        let arabicBottom = arabicCenterOffset - arabicPlaneHeightMeters / 2
        return arabicBottom - englishGapMeters - englishPlaneHeightMeters / 2
    }

    /// World Y of the FIRST line's baseline, identical for every segment regardless of how
    /// many lines it wraps to.
    ///
    /// Anchoring is on the baseline, not on the plane's top edge: ascent varies between
    /// ayat with the height of their marks, so a fixed top edge would let baselines drift
    /// by exactly that variation. The baseline is the thing the eye tracks.
    ///
    /// Retained as the name the geometry and the tests already read; `ayahHeight` is the
    /// knob. One value, two names, so there is nothing to keep in sync.
    static var firstLineBaselineHeightMeters: Float { ayahHeight }

    // MARK: Derived

    /// Inverted from `textAngularEmDeg` through the SAME `tan` mapping that `maxPlaneWidthMeters`
    /// uses, which is what makes the delivered angle equal the requested one instead of 4.2%
    /// over it.
    static var fontSizePixels: Float {
        Float(maxTextureWidthPixels) * tan(textAngularEmDeg / 2 * .pi / 180)
            / tan(maxAngularWidthDegrees / 2 * .pi / 180)
    }

    /// The angle a glyph actually subtends, computed back from the pixel size rather than
    /// assumed. Used by the reports so the claim is checked, not restated.
    static func deliveredEmDegrees(fontSizePixels: Float = AyahPlaneGeometry.fontSizePixels) -> Float {
        2 * atan(fontSizePixels * tan(maxAngularWidthDegrees / 2 * .pi / 180)
                 / Float(maxTextureWidthPixels)) * 180 / .pi
    }
    static var maxTextureWidthPixels: Int { Int((maxAngularWidthDegrees * pixelsPerDegree).rounded(.up)) }
    static var maxContentWidthPixels: Int { maxTextureWidthPixels - Int(paddingPixels) * 2 }
    static var maxPlaneWidthMeters: Float {
        2 * assumedViewingDistanceMeters * tan(maxAngularWidthDegrees / 2 * .pi / 180)
    }

    /// The single scale from raster pixels to world metres. Fixed, so a glyph rendered at
    /// `fontSizePixels` subtends `textEmDegrees` no matter which ayah it is in.
    static var metresPerPixel: Float { maxPlaneWidthMeters / Float(maxTextureWidthPixels) }

    /// `ayahPitch` as a rotation about X. `generatePlane` lies in the XY plane facing +Z,
    /// so this is the whole of the plane's orientation — there is no yaw or roll.
    static var ayahOrientation: simd_quatf {
        simd_quatf(angle: ayahPitch * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
    }

    // MARK: - Head-relative placement (Stage 11)
    //
    // Placement is now a TRANSFORM ON THE TEXT ROOT, and nothing else. The raster, the
    // layout, the wrap and the dissolve all still run exactly as before and still produce a
    // plane sized for `ayahDistance`; this moves and scales that plane as a rigid body.
    //
    // That separation is the point. The pipeline cannot depend on where the wearer's head is,
    // because rasters are cached per segment and the head pose is not known until the session
    // is running. So the pipeline builds a canonical plane and the root places it.

    /// Metres from the head, along the view direction. Slant range, not horizontal.
    ///
    /// **180 m as of Stage 11d**, restoring the Stage 11b value after 11c's 60 m.
    ///
    /// The reasoning that settles it: beyond roughly 20 m stereo disparity is below what the
    /// eyes resolve, so DISTANCE stops carrying "far" and angular size has to do the work
    /// instead. That is why this stage moves the em rather than the distance - 180 m and
    /// 1000 m would look the same, and the text still reads as near if it subtends 3 degrees.
    static let textDistance: Float = 180.0

    /// The distance in force at the IMMEDIATELY PRECEDING stage (11c), so "farther than
    /// before" compares against what was actually shipped last rather than against an older
    /// value. 11b's own figure was 180 m, which this restores exactly.
    static let previousDistance: Float = 60.0

    /// The distance in force before Stage 11, kept for the Stage 11b record.
    static let preStage11Distance: Float = 60.0

    /// Stage 11c's stated condition. **Reported, not asserted** - see `textDistance`. A fatal
    /// assert here would abort every debug launch over a contradiction in the brief, which
    /// would hide every other finding behind a crash.
    static var distanceIsFartherThanPrevious: Bool { textDistance > previousDistance }

    /// Stage 11b's condition, kept because it still holds and is still worth checking.
    static var distanceIsFartherThanBeforeStage11: Bool { textDistance >= preStage11Distance }

    /// Degrees above the horizontal eye line, measured at the head.
    ///
    /// **25 deg, unchanged since Stage 11b as Stage 11c asks.** No value between 15 and 40 leaves the plane's corners clear
    /// of the pavilion - see the sweep in the placement report - so there was no "clear value
    /// closest to 25" to prefer, and 25 stands as asked.
    static let textElevationDeg: Float = 25

    /// Scale applied to the text root so the angular size is unchanged at `textDistance`.
    ///
    /// The pipeline sizes the plane for `ayahDistance`, so the ratio is the whole correction:
    /// the em subtends the same angle at 5 m scaled by 5/60 as it does at 60 m unscaled.
    /// Derived rather than written down, so changing either distance keeps the em fixed.
    static var textRootScale: Float { textDistance / ayahDistance }

    /// Pitch about X that points the plane's NORMAL at the head, in degrees.
    ///
    /// Equal to the elevation, and that is not a coincidence - it is the condition. A plane
    /// `textElevationDeg` above the eye must tilt by exactly that to face back down at it.
    ///
    /// **SIGN NOTE, because the old `ayahPitch` had it backwards.** `generatePlane` faces +Z.
    /// A right-handed rotation of +θ about X takes that normal to (0, -sin θ, cos θ) - toward
    /// the viewer and DOWNWARD, which is what a plane above the eye needs. The previous
    /// constant was negative (-12, then -22.48), which tilted the normal UP and away, the
    /// opposite of "facing the viewer". Positive is correct here.
    static var textPitchDeg: Float { textElevationDeg }

    /// The root's orientation: pitch only. **Yaw and roll are untouched**, so the plane keeps
    /// facing down -Z exactly as it always has.
    static var textRootOrientation: simd_quatf {
        simd_quatf(angle: textPitchDeg * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
    }

    /// Where the text root sits, given the head position sampled once at experience start.
    ///
    /// The root's ORIGIN is the first line's baseline, which is what keeps top-anchoring
    /// meaningful: every segment puts its first baseline here regardless of line count, and
    /// extra wrapped lines extend downward from it.
    static func textRootPosition(headPosition: SIMD3<Float>) -> SIMD3<Float> {
        let e = textElevationDeg * .pi / 180
        return SIMD3<Float>(headPosition.x,
                            headPosition.y + textDistance * sin(e),
                            headPosition.z - textDistance * cos(e))
    }

    /// The plane's centre in ROOT-LOCAL metres, given where its first baseline falls inside
    /// the bitmap.
    ///
    /// Same top-anchoring as `planeCenterY`, expressed relative to a baseline at local zero
    /// instead of at a world height - because the baseline's world height is now the root's
    /// job. Note this uses the UNSCALED `metresPerPixel`: the root's scale is applied by the
    /// transform hierarchy, so applying it here as well would square it.
    static func planeCenterOffsetFromBaseline(firstBaselineFromTopPixels: CGFloat,
                                              planeHeightMeters: Float) -> Float {
        Float(firstBaselineFromTopPixels) * metresPerPixel - planeHeightMeters / 2
    }

    /// Elevation of a world Y above a standing wearer's eye, in degrees, at `ayahDistance`.
    /// Positive is upward gaze.
    ///
    /// Exists so the comfort figure is derived from the same constants the plane is built
    /// from rather than recomputed by hand each time one of them moves. Ergonomic guidance
    /// puts sustained upward gaze well below sustained downward gaze in tolerability, so
    /// this is the number that decides whether `ayahHeight` is habitable, not how it looks
    /// in a screenshot.
    static func gazeElevationDegrees(worldY: Float, eyeHeightMeters: Float = 1.6) -> Float {
        atan((worldY - eyeHeightMeters) / ayahDistance) * 180 / .pi
    }

    /// World Y for the plane's CENTRE, given where its first baseline falls inside the
    /// bitmap.
    ///
    /// `generatePlane` centres its mesh on the entity's origin, so positioning the entity
    /// here is what top-anchors the text. Additional wrapped lines extend downward only —
    /// the first line never moves up to centre the block.
    static func planeCenterY(firstBaselineFromTopPixels: CGFloat, planeHeightMeters: Float) -> Float {
        let baselineBelowTop = Float(firstBaselineFromTopPixels) * metresPerPixel
        let planeTop = firstLineBaselineHeightMeters + baselineBelowTop
        return planeTop - planeHeightMeters / 2
    }
}
