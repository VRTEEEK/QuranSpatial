//
//  TextPlacementProbe.swift
//  QuranSpatial
//
//  Reports where the ayah plane actually ends up under the head-relative placement, and
//  whether the pavilion stands between the wearer's eye and its corners.
//
//  This is a REPORT. It reads the placement constants and the loaded pavilion hierarchy and
//  writes a file; it never moves anything. Occlusion is something to know about before
//  deciding what to do, and "the text is behind a column" is not a thing anyone should have
//  to discover by wearing the device and turning their head.
//

import Foundation
import RealityKit
import simd
import os

@MainActor
enum TextPlacementProbe {

    private static let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "placement")

    /// Standing eye height used when no device anchor has arrived yet. A nominal figure for
    /// the provisional placement and for the launch-time occlusion check only - the shipped
    /// placement uses the real sample.
    static let nominalEyeHeight: Float = 1.6

    /// The largest segment in the corpus, in raster pixels: ayah 33, the only three-line
    /// segment. Measured on device with the shipped Amiri at the real constants and recorded
    /// in CLAUDE.md, not estimated here.
    ///
    /// Written down rather than rasterized because this probe must not pull the text pipeline
    /// into app launch. If the font or the wrap constants change, these change with them, and
    /// the corpus pass is where that gets re-measured.
    static let largestSegmentPixels = CGSize(width: 1259, height: 846)

    /// Where the first baseline falls below the plane's top edge, in raster pixels - ascent
    /// plus padding. Constant across the corpus with this font, per CLAUDE.md.
    static let firstBaselineFromTopPixels: CGFloat = 233

    /// A mesh-carrying entity the ray hit, and where.
    struct Hit {
        /// The ANCESTOR PATH, not the leaf name. The instanced prototypes all call their mesh
        /// "Geometry", so a leaf name identifies nothing - every column and every arch reports
        /// the same string. The path says which structure it is.
        let entityName: String
        let distanceAlongRay: Float
        let worldY: Float
        let horizontalRadius: Float
    }

    /// The four world-space corners of the largest segment's plane, under the current
    /// placement, for a head at `headPosition`.
    ///
    /// Built the same way the scene builds it - root position, root pitch, root scale, then
    /// the plane's local top-anchor offset - so this cannot drift from what is rendered
    /// without the transform code changing too.
    static func planeCorners(headPosition: SIMD3<Float>) -> [SIMD3<Float>] {
        let mpp = AyahPlaneGeometry.metresPerPixel
        let scale = AyahPlaneGeometry.textRootScale
        let halfW = Float(largestSegmentPixels.width) / 2 * mpp
        let halfH = Float(largestSegmentPixels.height) / 2 * mpp
        let centreLocalY = AyahPlaneGeometry.planeCenterOffsetFromBaseline(
            firstBaselineFromTopPixels: firstBaselineFromTopPixels,
            planeHeightMeters: Float(largestSegmentPixels.height) * mpp)

        let rootPosition = AyahPlaneGeometry.textRootPosition(headPosition: headPosition)
        let rootRotation = AyahPlaneGeometry.textRootOrientation

        return [(-halfW, halfH), (halfW, halfH), (-halfW, -halfH), (halfW, -halfH)].map { dx, dy in
            // Root-local, before the root's own rotation and scale.
            let local = SIMD3<Float>(dx, centreLocalY + dy, 0)
            return rootPosition + rootRotation.act(local * scale)
        }
    }

    /// The four corners for an ARBITRARY elevation, used by the sweep. `planeCorners` is this
    /// at the shipped `textElevationDeg`.
    static func cornersFor(elevationDeg: Float, headPosition: SIMD3<Float>) -> [SIMD3<Float>] {
        let mpp = AyahPlaneGeometry.metresPerPixel
        let scale = AyahPlaneGeometry.textRootScale
        let halfW = Float(largestSegmentPixels.width) / 2 * mpp
        let halfH = Float(largestSegmentPixels.height) / 2 * mpp
        let centreLocalY = AyahPlaneGeometry.planeCenterOffsetFromBaseline(
            firstBaselineFromTopPixels: firstBaselineFromTopPixels,
            planeHeightMeters: Float(largestSegmentPixels.height) * mpp)
        let rad = elevationDeg * .pi / 180
        let root = SIMD3<Float>(headPosition.x,
                                headPosition.y + AyahPlaneGeometry.textDistance * sin(rad),
                                headPosition.z - AyahPlaneGeometry.textDistance * cos(rad))
        let rot = simd_quatf(angle: rad, axis: SIMD3<Float>(1, 0, 0))
        return [(-halfW, halfH), (halfW, halfH), (-halfW, -halfH), (halfW, -halfH)].map { dx, dy in
            root + rot.act(SIMD3<Float>(dx, centreLocalY + dy, 0) * scale)
        }
    }

    /// Ray/AABB intersection, slab method. Returns the entry distance along the ray if the
    /// segment from `origin` to `target` meets the box.
    ///
    /// AABBs rather than triangles, and that is a deliberate CONSERVATIVE choice: a box around
    /// a column is bigger than the column, so this can report a hit that a triangle test would
    /// miss. For "is the text behind the arcade" an over-report is the safe direction - it
    /// cannot tell you the view is clear when it is not.
    private static func rayHitsBox(origin: SIMD3<Float>, target: SIMD3<Float>,
                                   box: BoundingBox) -> Float? {
        let d = target - origin
        let length = simd_length(d)
        guard length > 1e-6 else { return nil }
        let dir = d / length
        var tMin: Float = 0
        var tMax: Float = length
        for axis in 0..<3 {
            let o = origin[axis], dd = dir[axis]
            let lo = box.min[axis], hi = box.max[axis]
            if abs(dd) < 1e-9 {
                if o < lo || o > hi { return nil }
                continue
            }
            var t1 = (lo - o) / dd
            var t2 = (hi - o) / dd
            if t1 > t2 { swap(&t1, &t2) }
            tMin = max(tMin, t1)
            tMax = min(tMax, t2)
            if tMin > tMax { return nil }
        }
        return tMin
    }

    /// Tests the four corner rays against every mesh-carrying entity in `environment`.
    ///
    /// Entities whose box CONTAINS the eye are skipped: the sky dome and the lake surround the
    /// wearer, so every ray starts inside them and every ray would "hit". That is not
    /// occlusion, it is containment, and reporting it would bury the arcade hits that matter.
    static func occlusion(from eye: SIMD3<Float>, to corners: [SIMD3<Float>],
                          environment: Entity) -> [[Hit]] {
        var boxes: [(String, BoundingBox)] = []
        func path(_ e: Entity) -> String {
            var parts: [String] = []
            var cur: Entity? = e
            while let c = cur, c !== environment {
                if !c.name.isEmpty { parts.append(c.name) }
                cur = c.parent
            }
            return parts.reversed().joined(separator: "/")
        }
        func walk(_ e: Entity) {
            if e.components[ModelComponent.self] != nil {
                let b = e.visualBounds(relativeTo: nil)
                let containsEye = all(b.min .<= eye) && all(b.max .>= eye)
                if !containsEye, b.max.x > b.min.x { boxes.append((path(e), b)) }
            }
            for c in e.children { walk(c) }
        }
        walk(environment)

        return corners.map { corner in
            var hits: [Hit] = []
            for (name, box) in boxes {
                if let t = rayHitsBox(origin: eye, target: corner, box: box) {
                    let p = eye + simd_normalize(corner - eye) * t
                    hits.append(Hit(entityName: name, distanceAlongRay: t, worldY: p.y,
                                    horizontalRadius: simd_length(SIMD2<Float>(p.x, p.z))))
                }
            }
            return hits.sorted { $0.distanceAlongRay < $1.distanceAlongRay }
        }
    }

    /// Rasterizes the longest segment at a given angular em and reports its metrics.
    ///
    /// Rasterizing at launch is normally avoided - the text pipeline should not be dragged
    /// into app start - but "how many lines and how many glyphs per line" cannot be answered
    /// any other way. Core Text shapes Arabic differently on visionOS than on macOS (a 12%
    /// difference was measured on particle counts), so a desktop estimate would not transfer.
    /// This is the measurement, on the device, with the shipped font.
    struct SegmentMetrics {
        var emDeg: Float = 0
        var fontPixels: Float = 0
        var lines = 0
        var glyphs = 0
        var pixelWidth = 0
        var pixelHeight = 0
        var angularWidthDeg: Float = 0
        var glyphsPerLine: Float = 0
    }

    /// The longest segment by rendered ink, per CLAUDE.md: ayah 33.
    static let longestSegmentAyah = 33

    static func loadLongestSegmentText() -> String? {
        guard let url = Bundle.main.url(forResource: "ar-rahman-text", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(RecitationTextFile.self, from: data)
        else { return nil }
        return file.ayat.first { $0.ayah == longestSegmentAyah }?.text
    }

    static func measureSegment(_ text: String, emDeg: Float) -> SegmentMetrics? {
        let fp = Float(AyahPlaneGeometry.maxTextureWidthPixels)
              * tan(emDeg / 2 * .pi / 180)
              / tan(AyahPlaneGeometry.maxAngularWidthDegrees / 2 * .pi / 180)
        guard let r = ArabicTextRasterizer.rasterizeWrapped(
            text,
            fontSizePixels: CGFloat(fp),
            maxContentWidthPixels: AyahPlaneGeometry.maxContentWidthPixels,
            padding: CGFloat(AyahPlaneGeometry.paddingPixels)) else { return nil }

        var m = SegmentMetrics()
        m.emDeg = emDeg
        m.fontPixels = fp
        m.lines = r.lineCount
        // Glyph count, not character count: Arabic shaping merges and reorders, so the two are
        // different numbers and only the glyph count describes what is drawn.
        m.glyphs = text.unicodeScalars.reduce(into: 0) { acc, u in
            acc += (u.properties.generalCategory == .nonspacingMark ? 0 : 1)
        }
        m.pixelWidth = Int(r.pixelSize.width)
        m.pixelHeight = Int(r.pixelSize.height)
        let widthMeters = Float(r.pixelSize.width) * AyahPlaneGeometry.metresPerPixel
                        * AyahPlaneGeometry.textRootScale
        m.angularWidthDeg = 2 * atan(widthMeters / 2 / AyahPlaneGeometry.textDistance) * 180 / .pi
        m.glyphsPerLine = r.lineCount > 0 ? Float(m.glyphs) / Float(r.lineCount) : 0
        return m
    }

    /// Corners for an arbitrary em AND elevation, so the em sweep tests the geometry that em
    /// actually produces rather than the shipped one.
    static func cornersFor(metrics: SegmentMetrics, elevationDeg: Float,
                           headPosition: SIMD3<Float>) -> [SIMD3<Float>] {
        let mpp = AyahPlaneGeometry.metresPerPixel
        let scale = AyahPlaneGeometry.textRootScale
        let halfW = Float(metrics.pixelWidth) / 2 * mpp
        let halfH = Float(metrics.pixelHeight) / 2 * mpp
        let centreLocalY = AyahPlaneGeometry.planeCenterOffsetFromBaseline(
            firstBaselineFromTopPixels: firstBaselineFromTopPixels,
            planeHeightMeters: Float(metrics.pixelHeight) * mpp)
        let rad = elevationDeg * .pi / 180
        let root = SIMD3<Float>(headPosition.x,
                                headPosition.y + AyahPlaneGeometry.textDistance * sin(rad),
                                headPosition.z - AyahPlaneGeometry.textDistance * cos(rad))
        let rot = simd_quatf(angle: rad, axis: SIMD3<Float>(1, 0, 0))
        return [(-halfW, halfH), (halfW, halfH), (-halfW, -halfH), (halfW, -halfH)].map { dx, dy in
            root + rot.act(SIMD3<Float>(dx, centreLocalY + dy, 0) * scale)
        }
    }

    /// Writes the placement report. `environment` is optional so this can run before the
    /// pavilion exists, in which case the occlusion section says so rather than claiming clear.
    static func writeReport(headPosition: SIMD3<Float>, sampled: Bool,
                            environment: Entity? = nil) {
        let mpp = AyahPlaneGeometry.metresPerPixel
        let scale = AyahPlaneGeometry.textRootScale
        let effective = mpp * scale
        let e = AyahPlaneGeometry.textElevationDeg
        let root = AyahPlaneGeometry.textRootPosition(headPosition: headPosition)
        // Measured FIRST, because every section below reports against the raster the current em
        // actually produces. A hardcoded raster size here is exactly the kind of stale literal
        // that got quoted as a measurement once already.
        let longest = loadLongestSegmentText()
        let currentMetrics: SegmentMetrics? = longest.flatMap {
            measureSegment($0, emDeg: AyahPlaneGeometry.textAngularEmDeg)
        }

        let corners = currentMetrics.map {
            cornersFor(metrics: $0, elevationDeg: AyahPlaneGeometry.textElevationDeg,
                       headPosition: headPosition)
        } ?? planeCorners(headPosition: headPosition)

        var out: [String] = []
        out.append("written: \(ISO8601DateFormatter().string(from: Date()))")
        out.append("head position: (\(fmt(headPosition.x)), \(fmt(headPosition.y)), "
                   + "\(fmt(headPosition.z)))  source: "
                   + (sampled ? "DEVICE HEAD ANCHOR, sampled once at experience start"
                              : "NOMINAL \(nominalEyeHeight) m eye at origin - no anchor yet"))
        out.append("")
        out.append("--- PLACEMENT ---")
        out.append("textDistance      \(fmt(AyahPlaneGeometry.textDistance)) m (slant from head)")
        out.append("textElevationDeg  \(fmt(e))")
        out.append("  horizontal       \(fmt(AyahPlaneGeometry.textDistance * cos(e * .pi / 180))) m")
        out.append("  rise above eye   \(fmt(AyahPlaneGeometry.textDistance * sin(e * .pi / 180))) m")
        out.append("textPitchDeg      +\(fmt(AyahPlaneGeometry.textPitchDeg)) "
                   + "(normal points at the head; yaw and roll untouched)")
        out.append("textRootScale     \(fmt(scale))  = textDistance / ayahDistance "
                   + "(\(fmt(AyahPlaneGeometry.textDistance)) / \(fmt(AyahPlaneGeometry.ayahDistance)))")
        out.append("root world pos    (\(fmt(root.x)), \(fmt(root.y)), \(fmt(root.z)))  "
                   + "= the first line's baseline")
        out.append("")
        out.append("--- ANGULAR SIZE ---")
        let fp = AyahPlaneGeometry.fontSizePixels
        let em = fp * effective
        out.append("metresPerPixel    \(fmt6(mpp)) unscaled, \(fmt6(effective)) effective")
        out.append("fontSizePixels    \(fmt(fp))  (derived from textAngularEmDeg, not nominal)")
        out.append("em                \(fmt(em)) m -> subtends "
                   + "\(fmt3(2 * atan(em / 2 / AyahPlaneGeometry.textDistance) * 180 / .pi))"
                   + " deg at \(fmt(AyahPlaneGeometry.textDistance)) m")
        out.append("requested textAngularEmDeg \(fmt3(AyahPlaneGeometry.textAngularEmDeg)) deg, "
                   + "delivered \(fmt3(AyahPlaneGeometry.deliveredEmDegrees())) deg")
        if let m = currentMetrics {
            let w = Float(m.pixelWidth) * effective
            let h = Float(m.pixelHeight) * effective
            out.append("longest segment   \(fmt(w)) x \(fmt(h)) m "
                       + "(\(m.pixelWidth)x\(m.pixelHeight) px, \(m.lines) line(s)) MEASURED")
            out.append("  angular width   \(fmt3(m.angularWidthDeg)) deg")
        } else {
            out.append("longest segment   NOT measured (corpus did not load)")
        }
        out.append("")
        out.append("--- CORNERS of the largest segment's plane (world) ---")
        let labels = ["top-left ", "top-right", "bot-left ", "bot-right"]
        for (i, c) in corners.enumerated() {
            let radius = simd_length(SIMD2<Float>(c.x, c.z))
            let horiz = simd_length(SIMD2<Float>(c.x - headPosition.x, c.z - headPosition.z))
            let elevDeg = atan((c.y - headPosition.y) / horiz) * 180 / .pi
            out.append("\(labels[i])  (\(fmt(c.x)), \(fmt(c.y)), \(fmt(c.z)))"
                       + "  r=\(fmt(radius)) m  elev=\(fmt3(elevDeg)) deg")
        }
        out.append("")
        out.append("--- DISTANCE RULE ---")
        out.append("pre-Stage-11 distance  \(fmt(AyahPlaneGeometry.preStage11Distance)) m")
        out.append("Stage 11b distance     \(fmt(AyahPlaneGeometry.previousDistance)) m")
        out.append("current  distance      \(fmt(AyahPlaneGeometry.textDistance)) m")
        out.append("farther than pre-Stage-11 (>= 60 m): "
                   + (AyahPlaneGeometry.distanceIsFartherThanBeforeStage11 ? "PASS" : "*** FAIL ***"))
        out.append("farther than Stage 11b (> 180 m):    "
                   + (AyahPlaneGeometry.distanceIsFartherThanPrevious ? "PASS" : "*** FAIL ***"))
        if !AyahPlaneGeometry.distanceIsFartherThanPrevious {
            out.append("  NOTE: Stage 11c asked for 60 m AND for the distance to exceed 11b's")
            out.append("  180 m. Both cannot hold. The explicit 60 m is implemented and this")
            out.append("  condition is REPORTED as failing rather than asserted, so the build")
            out.append("  runs and the contradiction is on the record.")
        }
        out.append("")
        // --- longest segment, before and after the em change -------------------------
        out.append("--- LONGEST SEGMENT (ayah \(longestSegmentAyah)) AT BOTH EM SIZES ---")
        if let longest {
            out.append("  em(deg)  fontpx   lines   glyphs   glyphs/line   raster(px)      angular width")
            for em in [Float(3.1273), AyahPlaneGeometry.textAngularEmDeg] {
                if let m = measureSegment(longest, emDeg: em) {
                    out.append(String(format: "  %6.3f  %6.2f  %6d  %7d  %12.1f   %5dx%-5d  %8.3f deg",
                                      m.emDeg, m.fontPixels, m.lines, m.glyphs, m.glyphsPerLine,
                                      m.pixelWidth, m.pixelHeight, m.angularWidthDeg))
                } else {
                    out.append(String(format: "  %6.3f  RASTERIZE FAILED", em))
                }
            }
            out.append("  delivered em check: requested \(fmt3(AyahPlaneGeometry.textAngularEmDeg))"
                       + " deg, delivered \(fmt3(AyahPlaneGeometry.deliveredEmDegrees())) deg")
        } else {
            out.append("  corpus did not load - NOT measured")
        }
        out.append("")

        // --- em ladder: does a smaller em ever clear the columns at 25 deg? -----------
        out.append("--- EM SEARCH at 25 deg elevation, 2.2 down in 0.1 steps (REPORT ONLY) ---")
        if let longest, let environment {
            var cleared: Float?
            for step in 0...12 {
                let em = 2.2 - 0.1 * Float(step)
                guard let m = measureSegment(longest, emDeg: em) else { continue }
                let cs = cornersFor(metrics: m, elevationDeg: 25, headPosition: headPosition)
                let n = occlusion(from: headPosition, to: cs, environment: environment)
                    .reduce(0) { $0 + $1.count }
                out.append(String(format: "  em %.1f deg: %d line(s), %dpx wide, %.2f deg wide -> %@",
                                  em, m.lines, m.pixelWidth, m.angularWidthDeg,
                                  n == 0 ? "CLEAR" : "\(n) hit(s)"))
                if n == 0, cleared == nil { cleared = em }
            }
            out.append(cleared.map { "  FIRST CLEAR EM: \(fmt3($0)) deg" }
                       ?? "  NO em down to 1.0 deg clears the columns at 25 deg.")
        } else {
            out.append("  not run (corpus or environment missing)")
        }
        out.append("")

        out.append("--- ELEVATION SWEEP 15..40 deg, all four corners vs the arcade ---")
        if let environment {
            var clear: [Float] = []
            var lines: [String] = []
            var e2: Float = 15
            while e2 <= 40.001 {
                let probeCorners = currentMetrics.map {
                    cornersFor(metrics: $0, elevationDeg: e2, headPosition: headPosition)
                } ?? cornersFor(elevationDeg: e2, headPosition: headPosition)
                let hits = occlusion(from: headPosition, to: probeCorners, environment: environment)
                let n = hits.reduce(0) { $0 + $1.count }
                if n == 0 { clear.append(e2) }
                if abs(e2.rounded() - e2) < 0.001 && Int(e2) % 5 == 0 {
                    lines.append("  \(fmt(e2)) deg: \(n == 0 ? "CLEAR" : "\(n) hit(s)")")
                }
                e2 += 0.5
            }
            out.append(contentsOf: lines)
            if clear.isEmpty {
                out.append("  NO elevation in 15..40 deg leaves all four corners clear.")
                out.append("  The corner AZIMUTH is set by the plane's angular half-width, which is")
                out.append("  distance-invariant, so the corner rays always cross the arcade inside a")
                out.append("  column's angular span. Keeping \(fmt(e)) deg as asked.")
            } else {
                let best = clear.min { abs($0 - 25) < abs($1 - 25) }!
                out.append("  clear: \(fmt(clear.first!))..\(fmt(clear.last!)) deg, closest to 25 = \(fmt(best))")
            }
        } else {
            out.append("  environment not supplied - sweep NOT run.")
        }
        out.append("")
        out.append("--- OCCLUSION: head -> each corner, against pavilion mesh AABBs ---")
        out.append("Conservative: boxes, not triangles, so this over-reports rather than")
        out.append("under-reports. Entities containing the eye (sky dome, lake) are skipped -")
        out.append("that is containment, not occlusion.")
        if let environment {
            let all = occlusion(from: headPosition, to: corners, environment: environment)
            var total = 0
            for (i, hits) in all.enumerated() {
                if hits.isEmpty {
                    out.append("\(labels[i])  CLEAR")
                } else {
                    total += hits.count
                    let names = hits.prefix(3).map {
                        "\($0.entityName)@\(fmt($0.distanceAlongRay))m(y=\(fmt($0.worldY)),r=\(fmt($0.horizontalRadius)))"
                    }
                    out.append("\(labels[i])  \(hits.count) HIT(S): \(names.joined(separator: ", "))")
                }
            }
            out.append(total == 0
                ? "VERDICT: all four corners clear of the pavilion."
                : "VERDICT: \(total) hit(s). The text is behind pavilion geometry from this eye "
                  + "position. NOT moved to dodge it - reported, per the brief.")
        } else {
            out.append("environment not supplied - occlusion NOT evaluated on this run.")
        }

        let text = out.joined(separator: "\n") + "\n"
        logger.notice("\(text, privacy: .public)")
        if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("text-placement.txt") {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func fmt(_ v: Float) -> String { String(format: "%.3f", v) }
    private static func fmt3(_ v: Float) -> String { String(format: "%.3f", v) }
    private static func fmt6(_ v: Float) -> String { String(format: "%.6f", v) }
}
