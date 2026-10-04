//
//  DuaEntryGate.swift
//  QuranSpatial
//
//  Turns the recognizer's pose state into a ONE-WAY entry into the experience.
//
//  The dua posture is an entry gesture only. Once accepted, hand state is ignored
//  entirely: lowering, releasing or re-posing the hands has no effect on audio, ayah
//  progression or phase. There is no pause-on-release and no resume - stopping is the
//  closed-hand gesture's job, and that is a later milestone.
//
//  Because acceptance now commits the wearer to the full surah with no implemented exit, a
//  false positive is expensive in a way it was not when the gesture merely held playback
//  open. Three tightenings, all here rather than in the recognizer:
//
//    1. The recognizer's own enter bounds were raised (see CLAUDE.md).
//    2. `acceptanceDwell` on top of the recognizer's commit window - acceptance is not the
//       first `.held` frame.
//    3. Re-arming requires a release EDGE. After the surah ends, the pose must fall back
//       under the exit bounds at least once before another acceptance is possible;
//       otherwise hands still near dua at ayah 78 re-trigger immediately.
//
//  Pure Swift, no ARKit, so all of this is testable without a headset.
//

import Foundation

struct DuaEntryGate {

    /// How long the recognizer must stay `.held` before the gate accepts. This is on TOP
    /// of `DuaPostureRecognizer.commitWindow`, so the pose is qualified for
    /// 1.5s + 0.4s = 1.9s in total before the surah begins. Deliberately additive: the cost
    /// of a false acceptance is a ten-minute recitation with no way out.
    static let acceptanceDwell: TimeInterval = 0.4

    enum State: Equatable {
        /// Ready to accept a qualifying pose.
        case armed
        /// The experience is running. Hand state is ignored completely in this state.
        case accepted
        /// The experience ended, but the pose has not yet fallen away since acceptance.
        /// Waiting for that release edge before returning to `.armed`.
        case awaitingRelease
    }

    enum Outcome: Equatable {
        case nothing
        /// Fired exactly once per acceptance.
        case accept
    }

    private(set) var state: State = .armed
    private(set) var heldSince: TimeInterval?

    init() {}

    /// Feed the recognizer's state each frame.
    @discardableResult
    mutating func update(recognizerState: DuaPostureRecognizer.State, timestamp: TimeInterval) -> Outcome {
        switch recognizerState {
        case .held:
            if heldSince == nil { heldSince = timestamp }
        case .idle, .entering:
            // Any fall out of `.held` is the release edge. `.entering` counts: the
            // recognizer only re-enters it from `.idle`, so the pose did lapse.
            heldSince = nil
            if state == .awaitingRelease, recognizerState == .idle {
                state = .armed
            }
        }

        guard state == .armed, recognizerState == .held, let heldSince else { return .nothing }
        guard timestamp - heldSince >= Self.acceptanceDwell else { return .nothing }

        state = .accepted
        return .accept
    }

    /// Called when the surah finishes, or when the debug stop aborts a run. Does not re-arm
    /// on its own - that needs the release edge.
    mutating func experienceEnded() {
        guard state == .accepted else { return }
        state = .awaitingRelease
        heldSince = nil
    }

    /// Dwell accumulated so far, for the debug HUD.
    func dwellProgress(at timestamp: TimeInterval) -> TimeInterval? {
        guard let heldSince, state == .armed else { return nil }
        return timestamp - heldSince
    }
}
