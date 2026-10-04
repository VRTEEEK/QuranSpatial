//
//  FontIdentityReport.swift
//  QuranSpatial
//
//  Writes the ship font's identity to a file at launch, so on-device font resolution can
//  be confirmed by pulling the app container rather than by running the test target.
//
//  This is not a stand-in for the unit test. Resource bundling and font registration are
//  exactly where the simulator and the device diverge — a font that resolves in the
//  simulator can silently fail to register on device, with no error, which is the same
//  failure family as requesting a font by PostScript name. The test proves the logic; this
//  proves the build that is actually running on the headset.
//

import CoreText
import Foundation
import os

enum FontIdentityReport {

    static let filename = "font-identity.txt"

    private static let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "FontIdentity")

    /// True when a ship font is bundled and Core Text resolved to that exact font.
    /// False means either no ship font in this build (expected for a submission build, see
    /// the licensing section of CLAUDE.md) or - the case worth catching - a bundled font
    /// that silently did not take.
    static var isShipFontResolved: Bool {
        guard let bundled = ArabicTextRasterizer.bundledShipFontPostScriptName(),
              let probe = probeString else { return false }
        return ArabicTextRasterizer.resolvedFontPostScriptName(for: probe, size: probeSize) == bundled
    }

    /// The string identity is checked against: ayah 1, READ FROM THE CORPUS. Uses the real
    /// ayah rather than a synthetic probe, because substitution depends on the characters
    /// actually being shaped. It is not typed here - the hand-typed literal this replaced
    /// differed from the source in its first scalar, which is exactly why CLAUDE.md forbids
    /// typing Quran text. `nil` means the corpus itself did not load, and the report says so
    /// rather than probing with something else.
    private static let probeString: String? = (try? RecitationTextFile.loadFromBundle())?.text(forSegmentIndex: 1)
    private static let probeSize: CGFloat = 96

    @discardableResult
    static func write() -> URL? {
        let bundled = ArabicTextRasterizer.bundledShipFontPostScriptName()
        let resolved = probeString.map { ArabicTextRasterizer.resolvedFontPostScriptName(for: $0, size: probeSize) }
        let verdict: String
        switch (bundled, resolved) {
        case (_, nil): verdict = "NO CORPUS - ar-rahman-text.json did not load, so nothing was probed"
        case (nil, _): verdict = "NO SHIP FONT BUNDLED - falling back to the system cascade"
        case let (b?, r?) where b == r: verdict = "OK - resolved to the bundled ship font"
        default: verdict = "MISMATCH - bundled font did not take, Core Text substituted"
        }

        let report = """
        written: \(ISO8601DateFormatter().string(from: Date()))
        shipFontResourceName: \(ArabicTextRasterizer.shipFontResourceName)
        isShipFontBundled: \(ArabicTextRasterizer.isShipFontBundled)
        probe: \(probeString == nil ? "<corpus unavailable>" : "ayah 1 from the corpus")
        bundledPostScriptName: \(bundled ?? "<none>")
        resolvedPostScriptName: \(resolved ?? "<not probed>")
        verdict: \(verdict)
        """

        if bundled != nil && resolved != nil && bundled != resolved {
            logger.error("Ship font did not take: bundled \(bundled ?? "<none>"), resolved \(resolved ?? "<not probed>")")
        } else {
            logger.notice("Font identity: \(verdict)")
        }

        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = documents.appendingPathComponent(filename)
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            logger.error("Could not write font identity report: \(error.localizedDescription)")
            return nil
        }
    }
}
