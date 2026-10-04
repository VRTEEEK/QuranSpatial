//
//  ExperiencePhase.swift
//  QuranSpatial
//
//  Where the wearer is in the arc of the experience. Deliberately separate from
//  `PlaybackState`, which tracks the audio transport - see the locked decision in
//  CLAUDE.md. The two are not merged, neither nests the other, and neither carries a case
//  holding a prior value of the other.
//
//  Flat by design. The earlier recursive `paused(from:)` shape was removed because it made
//  the state space unbounded and pause/resume unreasonable to test. Anything that needs to
//  remember a position stores it as a property - `RecitationCoordinator.currentSegmentIndex`
//  is the audio's position, `pinnedSegmentIndex` is what the wearer is looking at while it
//  differs, and `resumePlan` is where the audio goes next. None of that lives in a case.
//

import Foundation

enum ExperiencePhase: Equatable {
    /// Nothing has started. Text may be on screen, but no recitation has been requested.
    case idle

    /// Recitation is under way: text is advancing with the audio. The audio may be
    /// `paused` by the system (interruption, route loss, background) without leaving this
    /// phase - only Ask entry moves to `asking`.
    case reciting

    /// The wearer is asking about the anchor ayah (Stage 2, added 2026-10-01). Audio is
    /// `paused`, the anchor is pinned on screen at full opacity, and hand state is still
    /// ignored. Entered only through `RecitationCoordinator.enterAsk()`; left through
    /// `exitAsk()` back to `reciting`, or `debugStop()` to `idle`.
    case asking

    /// The surah has played to its end. Distinct from `.idle` so "finished" and
    /// "never started" are never confused - they look identical from the audio's side.
    case completed
}
