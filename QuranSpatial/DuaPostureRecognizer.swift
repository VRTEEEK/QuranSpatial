//
//  DuaPostureRecognizer.swift
//  QuranSpatial
//
//  Pure Swift. No ARKit or RealityKit imports, so this is unit-testable against recorded
//  `HandPose` fixtures without a headset. Detection only: this does not trigger playback
//  or the dissolve. Per CLAUDE.md, no closed-hand recognizer or shared abstraction over
//  both until this one is proven on device.
//

import Foundation
import simd

/// Detects the dua posture - both hands raised, open, cupped toward each other and the
/// face, close together - from a stream of per-hand `HandPose` updates.
///
/// Orientation is judged relative to the wearer's own body, not world-up: an on-device
/// reading of a genuine dua posture scored only 0.25 against world-up (palms ~75° off
/// horizontal), because dua cups the palms toward each other and the face rather than
/// holding them flat. The two orientation criteria below (`palmInwardDot`,
/// `palmTowardHeadDot`) replace that world-up test with body-relative references instead.
///
/// Threshold values below are starting points for on-device tuning, not settled numbers.
/// Enter/exit pairs are intentionally asymmetric (a Schmitt trigger): the enter bound is
/// stricter than the exit bound, so a hold in progress tolerates more drift than starting
/// a new one requires. That prevents flicker right at a boundary.
///
/// The asymmetry applies only once a pose has *committed* (`.held`). Reaching that point
/// takes `commitWindow` of continuous enter-bound quality - the exit bounds do nothing
/// during the window itself, so a pose cannot enter on one good frame and then coast to a
/// detection at exit-bound quality.
struct DuaPostureRecognizer {

    // MARK: Tunable thresholds

    /// Dot of palm normal against the direction toward the *other* hand's palm, required
    /// to *begin* a hold - palms cupped toward each other, not flat or facing away.
    ///
    /// Raised 0.40 -> 0.58 on 2026-09-04 when the gesture became entry-only. A false
    /// acceptance now commits the wearer to the full surah with no implemented exit, so the
    /// accept side is deliberately tightened. This is the value
    /// `tools/threshold_search.py` selects under the asymmetric objective: on the available
    /// captures it holds zero confuser commits and all seven true commits, moving worst
    /// confuser rejection from 1.31x M to 3.31x M at the cost of worst true margin dropping
    /// from 1.98x M to 1.10x M. The one-person caveat in the V1 limitation still applies -
    /// this buys margin against the confusers we have, not against another person's dua.
    static let palmInwardDotEnterMin: Float = 0.58
    /// Looser inward bound tolerated to *keep* a hold already in progress.
    static let palmInwardDotExitMin: Float = 0.25

    /// Dot of palm normal against the direction toward the head, required to *begin* a
    /// hold - palms angled back toward the wearer's face, not facing away or downward.
    /// Raised 0.30 -> 0.42 with `palmInwardDotEnterMin`, same vector, same reasoning.
    static let palmTowardHeadDotEnterMin: Float = 0.42
    static let palmTowardHeadDotExitMin: Float = 0.15

    /// Below this distance (meters), a reference direction (to the other hand, or to the
    /// head) is too short to be reliable - normalizing a near-zero vector amplifies
    /// tracking noise into an essentially arbitrary direction. Treated as failing whatever
    /// criterion it would have fed, never skipped or coerced into a pass. This is a
    /// numerical safety floor, not the primary defense against a hand near the head (e.g.
    /// adjusting the headset) - finger extension and the both-hands-tracked gate do that;
    /// this only exists so a hand that ends up close to the head can't produce a garbage
    /// direction that happens to score well by accident.
    static let minReferenceVectorLength: Float = 0.03

    /// Finger-extension ratio (see `HandPose.fingerExtension`) required to count a hand as
    /// open, rather than resting/curled or a fist.
    static let fingerExtensionEnterMin: Float = 1.3
    static let fingerExtensionExitMin: Float = 1.15

    /// Max distance (meters) a palm may sit below head height.
    static let maxBelowHeadYEnter: Float = 0.45
    static let maxBelowHeadYExit: Float = 0.60

    /// Bimanual separation band (meters): close together, not touching, not spread apart.
    static let minHandSeparationEnter: Float = 0.04
    static let maxHandSeparationEnter: Float = 0.35
    static let minHandSeparationExit: Float = 0.02
    static let maxHandSeparationExit: Float = 0.45

    /// Commit window: how long a pose satisfying the gates must hold *continuously*
    /// before this fires `.detected`. A pose that lapses before the window elapses never
    /// reaches `.held` at all - there is no detection to cancel, and no `.released`
    /// follows, because none was ever announced.
    ///
    /// 1.5s is not arbitrary. In the reference capture (commit 7282757) a phone hold
    /// satisfied every gate continuously for 1.45s and fired a false `.detected` under the
    /// previous 0.7s window; the two genuine dua holds satisfied them for 7.8s and 7.6s.
    /// The window sits in that gap, close to the false positive rather than centred, so it
    /// buys rejection at the cost of a longer wait before a real dua commits.
    static let commitWindow: TimeInterval = 1.5

    /// How long a tracking dropout (e.g. hands briefly occluding each other while cupped)
    /// may last mid-hold without resetting it.
    static let maxTrackingGap: TimeInterval = 0.15

    // MARK: State

    enum State: Equatable {
        case idle
        case entering(since: TimeInterval)
        case held
    }

    enum Event: Equatable {
        case detected
        case released
    }

    /// Per-criterion instantaneous values, exposed for the debug overlay - not consulted
    /// for control flow beyond what already fed `state`. A `nil` orientation dot means the
    /// corresponding reference direction was too short to trust (see
    /// `minReferenceVectorLength`), not that it was skipped.
    struct Diagnostics {
        var leftTracked = false
        var rightTracked = false
        var leftPalmInwardDot: Float?
        var rightPalmInwardDot: Float?
        var leftPalmTowardHeadDot: Float?
        var rightPalmTowardHeadDot: Float?
        var leftFingerExtension: Float?
        var rightFingerExtension: Float?
        var leftBelowHeadY: Float?
        var rightBelowHeadY: Float?
        var separation: Float?
        var state: State = .idle
        var holdProgress: TimeInterval?
    }

    private(set) var state: State = .idle
    private(set) var diagnostics = Diagnostics()
    private var lastTrackedTimestamp: TimeInterval?

    init() {}

    /// Advances the clock without new hand data, letting the tracking-gap tolerance
    /// actually expire.
    ///
    /// `update` is only ever called from a hand-anchor update, so when anchors stop
    /// arriving altogether the state machine simply stops: a pose frozen in `.held` would
    /// persist for the whole length of the dropout and release only when tracking resumed.
    /// Once detection drives playback that is recitation continuing through a gesture the
    /// wearer has already abandoned — the hold-that-will-not-release failure, arriving by a
    /// mechanism we already know about. A caller that knows no data has arrived calls this.
    ///
    /// Deliberately does not fabricate a frame: it applies only the gap rule, and touches
    /// no criterion. Nothing here can *start* or *sustain* a hold.
    @discardableResult
    mutating func advance(to timestamp: TimeInterval) -> Event? {
        guard let last = lastTrackedTimestamp, timestamp - last > Self.maxTrackingGap else {
            return nil
        }

        var event: Event?
        switch state {
        case .idle:
            break
        case .entering:
            state = .idle
        case .held:
            state = .idle
            event = .released
        }

        diagnostics.state = state
        diagnostics.holdProgress = nil
        return event
    }

    /// Feed one frame of hand data. `headPosition` is the device (head) anchor's
    /// world-space position, used both for head-relative elevation and as the reference
    /// for `palmTowardHeadDot`.
    @discardableResult
    mutating func update(left: HandPose?, right: HandPose?, headPosition: SIMD3<Float>, timestamp: TimeInterval) -> Event? {
        let leftTracked = left?.isTracked ?? false
        let rightTracked = right?.isTracked ?? false

        /// `nil` if `target - origin` is too short to normalize reliably.
        func direction(from origin: SIMD3<Float>, to target: SIMD3<Float>) -> SIMD3<Float>? {
            let vector = target - origin
            let length = simd_length(vector)
            guard length >= Self.minReferenceVectorLength else { return nil }
            return vector / length
        }

        func orientationDot(_ pose: HandPose?, toward reference: SIMD3<Float>?) -> Float? {
            guard let pose, let reference else { return nil }
            return dot(pose.palmNormal, reference)
        }

        let leftToHead = left.flatMap { direction(from: $0.palmCenter, to: headPosition) }
        let rightToHead = right.flatMap { direction(from: $0.palmCenter, to: headPosition) }

        var leftToOther: SIMD3<Float>?
        var rightToOther: SIMD3<Float>?
        if let left, let right {
            leftToOther = direction(from: left.palmCenter, to: right.palmCenter)
            rightToOther = direction(from: right.palmCenter, to: left.palmCenter)
        }

        let leftInwardDot = orientationDot(left, toward: leftToOther)
        let rightInwardDot = orientationDot(right, toward: rightToOther)
        let leftTowardHeadDot = orientationDot(left, toward: leftToHead)
        let rightTowardHeadDot = orientationDot(right, toward: rightToHead)

        let leftExtension = left?.fingerExtension
        let rightExtension = right?.fingerExtension
        let leftBelowHeadY = left.map { headPosition.y - $0.palmCenter.y }
        let rightBelowHeadY = right.map { headPosition.y - $0.palmCenter.y }
        let separation: Float? = {
            guard let left, let right else { return nil }
            return simd_length(left.palmCenter - right.palmCenter)
        }()

        let enterSatisfied = leftTracked && rightTracked
            && (leftInwardDot ?? -1) >= Self.palmInwardDotEnterMin
            && (rightInwardDot ?? -1) >= Self.palmInwardDotEnterMin
            && (leftTowardHeadDot ?? -1) >= Self.palmTowardHeadDotEnterMin
            && (rightTowardHeadDot ?? -1) >= Self.palmTowardHeadDotEnterMin
            && (leftExtension ?? 0) >= Self.fingerExtensionEnterMin
            && (rightExtension ?? 0) >= Self.fingerExtensionEnterMin
            && (leftBelowHeadY ?? .infinity) <= Self.maxBelowHeadYEnter
            && (rightBelowHeadY ?? .infinity) <= Self.maxBelowHeadYEnter
            && (separation.map { $0 >= Self.minHandSeparationEnter && $0 <= Self.maxHandSeparationEnter } ?? false)

        let exitSatisfied = leftTracked && rightTracked
            && (leftInwardDot ?? -1) >= Self.palmInwardDotExitMin
            && (rightInwardDot ?? -1) >= Self.palmInwardDotExitMin
            && (leftTowardHeadDot ?? -1) >= Self.palmTowardHeadDotExitMin
            && (rightTowardHeadDot ?? -1) >= Self.palmTowardHeadDotExitMin
            && (leftExtension ?? 0) >= Self.fingerExtensionExitMin
            && (rightExtension ?? 0) >= Self.fingerExtensionExitMin
            && (leftBelowHeadY ?? .infinity) <= Self.maxBelowHeadYExit
            && (rightBelowHeadY ?? .infinity) <= Self.maxBelowHeadYExit
            && (separation.map { $0 >= Self.minHandSeparationExit && $0 <= Self.maxHandSeparationExit } ?? false)

        let anyTracked = leftTracked || rightTracked
        let withinTrackingGap: Bool
        if anyTracked {
            lastTrackedTimestamp = timestamp
            withinTrackingGap = true
        } else if let last = lastTrackedTimestamp {
            withinTrackingGap = (timestamp - last) <= Self.maxTrackingGap
        } else {
            withinTrackingGap = false
        }

        let toleratedDropout = !anyTracked && withinTrackingGap

        // An uncommitted pose has to hold full enter-bound quality for the whole commit
        // window. Touching the enter bound for a single frame and then coasting at the
        // looser exit bound is not a hold, and letting it count was what allowed a
        // marginal pose to accumulate commit time it had not earned.
        let sustainsCommitWindow = enterSatisfied || toleratedDropout

        // Only a *committed* pose gets the looser bounds - that asymmetry is the
        // hysteresis, and it applies after `.detected`, not during the window leading up
        // to it.
        let staysHeld = exitSatisfied || toleratedDropout

        var event: Event?

        switch state {
        case .idle:
            if enterSatisfied {
                state = .entering(since: timestamp)
            }

        case .entering(let since):
            if sustainsCommitWindow {
                if timestamp - since >= Self.commitWindow {
                    state = .held
                    event = .detected
                }
            } else {
                state = .idle
            }

        case .held:
            if !staysHeld {
                state = .idle
                event = .released
            }
        }

        diagnostics = Diagnostics(
            leftTracked: leftTracked,
            rightTracked: rightTracked,
            leftPalmInwardDot: leftInwardDot,
            rightPalmInwardDot: rightInwardDot,
            leftPalmTowardHeadDot: leftTowardHeadDot,
            rightPalmTowardHeadDot: rightTowardHeadDot,
            leftFingerExtension: leftExtension,
            rightFingerExtension: rightExtension,
            leftBelowHeadY: leftBelowHeadY,
            rightBelowHeadY: rightBelowHeadY,
            separation: separation,
            state: state,
            holdProgress: {
                if case .entering(let since) = state { return timestamp - since }
                return nil
            }()
        )

        return event
    }
}
