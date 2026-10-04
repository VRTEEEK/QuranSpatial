//
//  PlaybackState.swift
//  QuranSpatial
//
//  The audio transport, and nothing else. Separate from `ExperiencePhase` per the locked
//  decision in CLAUDE.md: not merged, not nested, and with no associated-value case storing
//  a prior state.
//
//  `paused` was added 2026-10-01 for Ask mode (Stage 2). It is reached ONLY by
//  `RecitationCoordinator.pause(reason:)` - Ask entry, a system interruption, a route loss or
//  the app going to the background - and never by hand state. The dua posture is still an
//  ENTRY gesture only: once the surah starts, hand state is ignored entirely and nothing about
//  the hands pauses it. WHY the transport is paused is a stored property on the coordinator
//  (`pauseReason`), not an associated value here, and the position to resume from is another
//  stored property (`resumePlan`) - the case itself carries nothing.
//

import Foundation

enum PlaybackState: Equatable {
    /// Nothing has played. The state before the first acceptance.
    case stopped

    /// Audio is advancing. The only state in which ayah progression happens.
    case playing

    /// Audio halted by the app or the system with its position kept; resumable. Distinct
    /// from `stopped` (never started) and `finished` (end of file). Left only through
    /// `RecitationCoordinator.resume()`, which seeks to the anchor's speech-free gap, or
    /// `debugStop()`.
    case paused

    /// The audio reached the end of the file. Distinct from `.stopped` so "finished the
    /// surah" and "never started" are never confused.
    case finished
}
