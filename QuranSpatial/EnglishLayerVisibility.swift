//
//  EnglishLayerVisibility.swift
//  QuranSpatial
//
//  D4, refined 2026-10-02: the English plane is shown ONLY while the Arabic is settled - its
//  dissolve progress exactly 0 - or while an Ask pin holds the anchor. It hides the frame the
//  outgoing dissolve starts and reappears the frame the incoming fade completes, so the hard
//  cut between ayat happens while the plane is hidden and is never seen. No second dissolve
//  driver: this is a rule over the Arabic driver's own progress, evaluated once per frame.
//

import Foundation

nonisolated enum EnglishLayerVisibility {

    /// `arabicProgress` is what the dissolve driver last wrote (0 = fully visible,
    /// 1 = dissolved), or nil when no shader material is bound - the `UnlitMaterial`
    /// fallback, where the Arabic is at full opacity and hard-cuts, so the English shows too.
    /// `isPinned` is the Ask pin: while it holds, the English stays up through the recall
    /// ramp and the pre-roll.
    static func isVisible(arabicProgress: Float?, isPinned: Bool) -> Bool {
        if isPinned { return true }
        guard let arabicProgress else { return true }
        return arabicProgress == 0
    }
}
