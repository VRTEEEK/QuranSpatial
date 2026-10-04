//
//  ArabicTextRasterizer.swift
//  QuranSpatial
//
//  Pure Core Text / Core Graphics. No RealityKit or ARKit imports, so this is
//  unit-testable without a simulator or device.
//

import CoreGraphics
import CoreText
import Foundation

struct RasterizedText {
    let cgImage: CGImage
    let pixelSize: CGSize
}

/// `nonisolated`: pure Core Text over its arguments, and it has always run off the main actor
/// (`AyahTextureCache` rasterizes on a detached task). Under the target's default main-actor
/// isolation the injectable rasterize closures (Stage 2 B4) could not otherwise be `@Sendable`
/// without warnings. Behaviour unchanged (2026-10-02).
nonisolated enum ArabicTextRasterizer {

    // MARK: Ship font

    /// The ship font, named once.
    ///
    /// Amiri Quran 1.003 (SIL OFL 1.1) as of 2026-09-04, replacing KFGQPC Uthmanic Hafs
    /// v2.2. KFGQPC classifies U+06DF as a BASE glyph with a 0.704em advance and carries no
    /// mark-attachment rule for it under any encoding, so it rendered the silent-letter
    /// zero as an inline dotted circle in ayat 8, 9 and 33. Amiri attaches it. See the
    /// shaping investigation in CLAUDE.md.
    ///
    /// This is deliberately a *file* name, not a PostScript name. Requesting a font by
    /// PostScript name fails silently — a wrong name resolves to something non-Arabic with
    /// no error (verified: "SFArabic-Regular" resolves to Helvetica), and a wrong Uthmanic
    /// name would fail exactly the same way. Naming the file instead means the font's
    /// identity comes from the file itself, read back via
    /// `CTFontManagerCreateFontDescriptorsFromURL`, so there is no name to get wrong.
    static let shipFontResourceName = "AmiriQuran"

    /// Probed in order, so the ship font's real container format never has to be guessed
    /// at or renamed into.
    private static let shipFontExtensions = ["ttf", "otf", "ttc"]

    private static func shipFontURL() -> URL? {
        for ext in shipFontExtensions {
            if let url = Bundle.main.url(forResource: shipFontResourceName, withExtension: ext) {
                return url
            }
            if let url = Bundle.main.url(forResource: shipFontResourceName, withExtension: ext, subdirectory: "Fonts") {
                return url
            }
        }
        return nil
    }

    /// Whether the ship font is bundled in this build at all.
    ///
    /// Its absence is a supported state, not a failure: the rasterizer falls back to the
    /// system cascade and still shapes Arabic correctly. That matters for licensing — a
    /// build that must not carry the font is made by removing the file, and the app keeps
    /// working rather than rendering nothing.
    static var isShipFontBundled: Bool { shipFontURL() != nil }

    private static func shipFontDescriptor() -> CTFontDescriptor? {
        guard let url = shipFontURL(),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
        else { return nil }
        return descriptors.first
    }

    /// The bundled ship font's own PostScript name, read from the file. `nil` when the
    /// font is not bundled. Never hardcoded anywhere — this is what a test compares the
    /// *resolved* font against to prove the cascade actually landed on it.
    static func bundledShipFontPostScriptName() -> String? {
        guard let descriptor = shipFontDescriptor() else { return nil }
        return CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
    }

    /// The PostScript name of the font Core Text actually chose for `string`. The whole
    /// point of the cascade is that this can differ from what was asked for, silently.
    static func resolvedFontPostScriptName(for string: String, size: CGFloat) -> String {
        CTFontCopyPostScriptName(resolveFont(for: string, size: size)) as String
    }

    /// Resolves the Arabic-capable font Core Text would actually use to shape `string`,
    /// starting from the ship font when it is bundled and the system font otherwise.
    ///
    /// The `CTFontCreateForString` cascade stays in front of the ship font rather than
    /// being replaced by it. A bundled font is not a guarantee of coverage: if the ship
    /// font lacks even one character of `string`, Core Text substitutes — and does so
    /// without error, which is the same silent-failure class the cascade exists to absorb.
    /// Use `resolvedFontPostScriptName(for:size:)` to see what it actually picked.
    static func resolveFont(for string: String, size: CGFloat) -> CTFont {
        let base: CTFont
        if let descriptor = shipFontDescriptor() {
            base = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        } else {
            base = CTFontCreateWithName("System" as CFString, size, nil)
        }
        return CTFontCreateForString(base, string as CFString, CFRangeMake(0, (string as NSString).length))
    }

    /// The English layer's font (Stage 2 B4, decision F1): the SYSTEM font, through the same
    /// `CTFontCreateForString` cascade - never a PostScript name, which fails silently
    /// (CLAUDE.md, Font resolution). The ship font is deliberately NOT the base here: Amiri
    /// Quran's Latin coverage is unverified, and a missing glyph would be substituted without
    /// error. `TranslationDataTests` asserts the result has glyphs for U+0101, U+012B and
    /// U+2019, the three non-ASCII scalars the translation uses.
    static func resolveSystemFont(for string: String, size: CGFloat) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("System" as CFString, size, nil)
        return CTFontCreateForString(base, string as CFString, CFRangeMake(0, (string as NSString).length))
    }

    static func hasGlyph(_ font: CTFont, for scalar: Unicode.Scalar) -> Bool {
        let units = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        let ok = CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count)
        return ok && glyphs.contains { $0 != 0 }
    }

    // MARK: Wrapped rendering — the recitation path

    /// A rasterized block of text, with the line count that produced it.
    struct WrappedText {
        let cgImage: CGImage
        let pixelSize: CGSize
        let lineCount: Int
        /// The font size actually used, in raster pixels. Constant across the surah.
        let fontSizePixels: CGFloat
        /// Distance from the top edge of the bitmap down to the FIRST line's baseline.
        ///
        /// This is what the plane is anchored on. Anchoring on the bitmap's top edge would
        /// not hold: ascent varies between ayat with mark height, so a fixed top edge lets
        /// baselines drift. Anchoring on the baseline itself does not.
        let firstBaselineFromTopPixels: CGFloat
    }

    /// Rasterizes Arabic at a FIXED font size, wrapping to as many lines as the content
    /// needs within `maxContentWidthPixels`.
    ///
    /// This replaces solving font size from a target width. Under the old scheme a longer
    /// ayah got a smaller font, a shorter texture and — because plane width was derived
    /// from the texture's aspect — a wider plane, so length pushed size down and width up
    /// at once. Here the font size never moves, the width is bounded, and length spends
    /// itself on line count instead.
    ///
    /// **Wrapping is rendering-only.** Core Text breaks at existing whitespace; nothing is
    /// inserted into the string. No line break, ZWJ, ZWNJ or any other character is added,
    /// and the text is not copied, normalized or reordered. The corpus stays byte-identical
    /// to the source.
    ///
    /// Line count is not capped and the font size is never reduced to force one — an ayah
    /// takes the lines it takes.
    ///
    /// `writingDirection` and `font` (Stage 2 B4) exist for the English layer, which goes
    /// through the same framesetter, the same measurement and the same white-on-clear
    /// `premultipliedLast` raster. Their DEFAULTS are the Arabic path exactly - right-to-left,
    /// ship-font cascade - and `WrappedLayoutTests.defaultParametersAreTheArabicPath`
    /// holds them there.
    static func rasterizeWrapped(
        _ string: String,
        fontSizePixels: CGFloat,
        maxContentWidthPixels: Int,
        padding: CGFloat,
        textColor: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        writingDirection: CTWritingDirection = .rightToLeft,
        font explicitFont: CTFont? = nil
    ) -> WrappedText? {
        guard maxContentWidthPixels > 0, fontSizePixels > 0 else { return nil }
        let font = explicitFont ?? resolveFont(for: string, size: fontSizePixels)
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTParagraphStyleAttributeName as NSAttributedString.Key: makeParagraphStyle(direction: writingDirection),
            kCTForegroundColorAttributeName as NSAttributedString.Key: textColor
        ]
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        let contentWidth = CGFloat(maxContentWidthPixels)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRangeMake(0, 0), nil,
            CGSize(width: contentWidth, height: .greatestFiniteMagnitude), nil)
        let framePath = CGPath(rect: CGRect(x: 0, y: 0, width: contentWidth,
                                            height: ceil(suggested.height) + fontSizePixels * 2), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), framePath, nil)
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return nil }

        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), &origins)

        // Measure the block from the lines themselves rather than from the path, so the
        // bitmap is sized to what will actually be drawn.
        var maxLineWidth: CGFloat = 0
        var top = -CGFloat.greatestFiniteMagnitude
        var bottom = CGFloat.greatestFiniteMagnitude
        var firstLineOriginY: CGFloat = 0
        var lineWidths: [CGFloat] = []
        for (index, line) in lines.enumerated() {
            var ascent: CGFloat = 0, descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let width = CTLineGetBoundsWithOptions(line, [.useOpticalBounds]).width
            lineWidths.append(width)
            maxLineWidth = max(maxLineWidth, width)
            top = max(top, origins[index].y + ascent)
            bottom = min(bottom, origins[index].y - descent)
            if index == 0 { firstLineOriginY = origins[index].y }
        }
        let imageWidth = Int(ceil(maxLineWidth + padding * 2))
        let imageHeight = Int(ceil((top - bottom) + padding * 2))
        guard imageWidth > 0, imageHeight > 0 else { return nil }

        guard let context = CGContext(
            data: nil, width: imageWidth, height: imageHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))

        // Lines are centred on the block. A centred block keeps a wrapped ayah symmetric
        // about the plane it lives on, which matters because the plane is centre-anchored.
        for (index, line) in lines.enumerated() {
            let x = padding + (maxLineWidth - lineWidths[index]) / 2
            let y = padding + (origins[index].y - bottom)
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
        }

        guard let image = context.makeImage() else { return nil }
        // Baselines are drawn at `padding + (origin.y - bottom)` measured from the bitmap's
        // BOTTOM, so the first line's distance from the top is the complement of that.
        let firstBaselineFromBottom = padding + (firstLineOriginY - bottom)
        return WrappedText(
            cgImage: image,
            pixelSize: CGSize(width: imageWidth, height: imageHeight),
            lineCount: lines.count,
            fontSizePixels: fontSizePixels,
            firstBaselineFromTopPixels: CGFloat(imageHeight) - firstBaselineFromBottom
        )
    }

    private static func makeParagraphStyle(direction: CTWritingDirection = .rightToLeft) -> CTParagraphStyle {
        var writingDirection = direction
        return withUnsafeBytes(of: &writingDirection) { rawBuffer -> CTParagraphStyle in
            let settings = [
                CTParagraphStyleSetting(
                    spec: .baseWritingDirection,
                    valueSize: MemoryLayout<CTWritingDirection>.size,
                    value: rawBuffer.baseAddress!
                )
            ]
            return CTParagraphStyleCreate(settings, settings.count)
        }
    }

    private static func line(for string: String, font: CTFont, textColor: CGColor?) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTParagraphStyleAttributeName as NSAttributedString.Key: makeParagraphStyle()
        ]
        if let textColor {
            attributes[kCTForegroundColorAttributeName as NSAttributedString.Key] = textColor
        }
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }

    /// DIAGNOSTIC PATH ONLY — not used for recitation. Solves font size to fill a target
    /// width, which makes rendered text size a function of string length. That is exactly
    /// what `rasterizeWrapped` exists to stop doing; this remains only for probes that
    /// genuinely want "fill this width", such as the typography PNGs.
    ///
    /// Shapes and rasterizes a single line of Arabic text at the font size needed to fill
    /// `targetPixelWidth`, so Core Text draws directly at the bitmap's final resolution —
    /// this never renders a small image and scales it up. Line-level geometry only, no
    /// per-glyph bounding boxes.
    ///
    /// `targetPixelWidth` is how many raster pixels the caller has determined the text
    /// needs (see `ImmersiveView.requiredRasterPixelWidth`, which derives it from the
    /// display plane's physical size and viewing distance) — it is not a constant here,
    /// because that need varies with plane size and string length.
    ///
    /// `padding` is 96 because wide marks overhang the line's measured bounds and get
    /// clipped otherwise — see the bounds defect in CLAUDE.md. The worst measured left
    /// overhang is U+06DC at 0.265em; at the font size this solves to for a short ayah at
    /// the current target width, that is ~80px, so 96 clears it with about 20% headroom.
    /// This is a stopgap for a bounds calculation that underestimates ink, not a designed
    /// margin: it does not scale with font size, so a large enough render would clip again.
    static func rasterize(
        _ string: String,
        targetPixelWidth: Int,
        padding: CGFloat = 96,
        textColor: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    ) -> RasterizedText? {
        guard targetPixelWidth > 0 else { return nil }

        // CTLine glyph-run width scales ~linearly with font size for a fixed string, so
        // measure once at an arbitrary reference size and solve for the exact size whose
        // glyph width fills the requested pixel budget, then render once at that size.
        let referenceFontSize: CGFloat = 100
        let referenceFont = resolveFont(for: string, size: referenceFontSize)
        let referenceWidth = CTLineGetBoundsWithOptions(
            line(for: string, font: referenceFont, textColor: nil),
            [.useOpticalBounds]
        ).width
        guard referenceWidth > 0 else { return nil }

        let targetGlyphWidth = CGFloat(targetPixelWidth) - padding * 2
        guard targetGlyphWidth > 0 else { return nil }
        let fontSize = referenceFontSize * (targetGlyphWidth / referenceWidth)

        let font = resolveFont(for: string, size: fontSize)
        let ctLine = line(for: string, font: font, textColor: textColor)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil)
        let bounds = CTLineGetBoundsWithOptions(ctLine, [.useOpticalBounds])

        let imageWidth = Int(ceil(bounds.width + padding * 2))
        let imageHeight = Int(ceil(ascent + descent + padding * 2))
        guard imageWidth > 0, imageHeight > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: imageWidth,
            height: imageHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        context.textPosition = CGPoint(x: padding - bounds.origin.x, y: padding + descent)
        CTLineDraw(ctLine, context)

        guard let image = context.makeImage() else { return nil }
        return RasterizedText(cgImage: image, pixelSize: CGSize(width: imageWidth, height: imageHeight))
    }
}
