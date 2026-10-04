//
//  HandTrackingSession.swift
//  QuranSpatial
//
//  The only file that touches ARKit hand-tracking types. Converts each hand-anchor update
//  into a `HandPose` and feeds `DuaPostureRecognizer`, both of which stay ARKit-free so
//  they're unit-testable without a headset. Detection only - does not trigger playback or
//  the dissolve.
//

import ARKit
import Foundation
import Observation
import simd
import os

@MainActor
@Observable
final class HandTrackingSession {

    private let session = ARKitSession()
    private let handTracking = HandTrackingProvider()
    private let worldTracking = WorldTrackingProvider()
    private var recognizer = DuaPostureRecognizer()
    private var entryGate = DuaEntryGate()

    /// Increments once per accepted dua posture. Observed rather than a callback so the
    /// one-way entry cannot be delivered twice by a re-render.
    private(set) var acceptanceTicket = 0
    var entryGateState: DuaEntryGate.State { entryGate.state }

    let capture = HandPoseCapture()

    private(set) var latestLeftPose: HandPose?
    private(set) var latestRightPose: HandPose?
    private(set) var diagnostics = DuaPostureRecognizer.Diagnostics()

    /// Count of frames dropped because no device anchor was available - surfaced in the
    /// debug HUD so a tuning session can tell "the posture did not score" apart from
    /// "the frame was never judged." Steady growth here invalidates a capture.
    private(set) var framesSkippedWithoutDeviceAnchor = 0

    /// The most recent head position from the device anchor, or nil until one arrives.
    ///
    /// Exposed so PLACEMENT can sample the head ONCE at experience start. It is deliberately
    /// not a placement API: this is the recognizer's own per-frame head reading, published so
    /// something else can take a single snapshot of it. Nothing should follow it per frame -
    /// text that chased the head would swim, and the ayah plane is fixed in the world by
    /// design.
    private(set) var latestHeadPosition: SIMD3<Float>?

    /// Count of hand-anchor updates that arrived carrying no `handSkeleton`, so no
    /// `HandPose` could be built. Paired with `framesSkippedWithoutDeviceAnchor`, this is
    /// what tells a gap in a capture apart from a stall: if neither counter moves across a
    /// hole in the data, ARKit sent nothing at all, which is the benign case.
    private(set) var framesSkippedWithoutHandSkeleton = 0

    private let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "DuaGesture")

    /// Whether the ARKit session itself has been started. Separate from whether anchor
    /// updates are being consumed: leaving the immersive space cancels the consuming task
    /// but does not stop the session, and conflating the two is what made re-entry a no-op.
    private var isSessionRunning = false
    private var isConsumingUpdates = false

    /// Starts hand and world tracking and begins feeding the recognizer from anchor
    /// updates. Hand data only flows while an ImmersiveSpace is open, so this should be
    /// called from there - not before.
    ///
    /// Safe to call again after leaving and re-entering the immersive space. Leaving
    /// cancels the task consuming `anchorUpdates`, which ends the loop below without
    /// stopping the ARKit session; the previous version left a single `isRunning` flag set,
    /// so the guard swallowed every later call and hands were never seen again. That would
    /// have looked exactly like a recognizer failure mid-session.
    func start() async {
        guard !isConsumingUpdates else { return }

        guard HandTrackingProvider.isSupported, WorldTrackingProvider.isSupported else {
            logger.error("Hand or world tracking is not supported on this device.")
            return
        }

        let authorization = await session.requestAuthorization(for: [.handTracking])
        guard authorization[.handTracking] == .allowed else {
            logger.error("Hand tracking authorization not granted: \(String(describing: authorization[.handTracking]))")
            return
        }

        if !isSessionRunning {
            do {
                try await session.run([handTracking, worldTracking])
            } catch {
                logger.error("Failed to start ARKitSession: \(error.localizedDescription)")
                return
            }
            isSessionRunning = true
        }

        // A hold, or a part-accumulated commit window, must not survive leaving and
        // re-entering the space - nor may poses from minutes ago be treated as current.
        recognizer = DuaPostureRecognizer()
        entryGate = DuaEntryGate()
        latestLeftPose = nil
        latestRightPose = nil
        diagnostics = DuaPostureRecognizer.Diagnostics()

        isConsumingUpdates = true
        defer { isConsumingUpdates = false }

        let watchdog = Task { [weak self] in await self?.runReleaseWatchdog() }
        defer { watchdog.cancel() }

        for await update in handTracking.anchorUpdates {
            handle(update.anchor)
        }
    }

    /// Drives `DuaPostureRecognizer.advance` so a hold cannot outlive the hand data that
    /// justified it. Without this the state machine only moves when an anchor arrives, so a
    /// total tracking dropout freezes it - see `advance(to:)`.
    ///
    /// Watchdog releases are deliberately not written to `HandPoseCapture`: there is no
    /// frame to record and no device anchor to record it against, and fabricating one is
    /// exactly what `handle` refuses to do. A replay reconstructs them instead, from the
    /// gaps in recorded timestamps.
    private func runReleaseWatchdog() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let event = recognizer.advance(to: now)
            diagnostics = recognizer.diagnostics
            feedEntryGate(at: now)
            if event == .released {
                logger.notice("Dua posture released by watchdog - hand tracking stopped delivering")
            }
        }
    }

    /// The gate is fed from every path that advances the recognizer, so dwell accrues on
    /// real elapsed time rather than on how often anchors happen to arrive.
    private func feedEntryGate(at timestamp: TimeInterval) {
        if entryGate.update(recognizerState: recognizer.state, timestamp: timestamp) == .accept {
            acceptanceTicket &+= 1
            logger.notice("Dua posture ACCEPTED - entry latched")
        }
    }

    /// The experience finished, or was aborted. Re-arming still needs a release edge.
    func experienceEnded() {
        entryGate.experienceEnded()
    }

    private func handle(_ anchor: HandAnchor) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let pose = HandPose(anchor: anchor, timestamp: timestamp) else {
            framesSkippedWithoutHandSkeleton += 1
            return
        }

        switch anchor.chirality {
        case .left: latestLeftPose = pose
        case .right: latestRightPose = pose
        @unknown default: break
        }

        // Every criterion except finger extension and hand separation is measured
        // against the head, so a frame without a device anchor cannot be judged at all.
        // Substituting a default (a head at world origin, say) would not degrade the
        // reading, it would fabricate one: plausible-looking dots and elevations computed
        // from a position the wearer's head is not in. Skip the frame instead, and let a
        // run of skips lapse a hold through the recognizer's own tracking-gap tolerance.
        guard let headTransform = worldTracking.queryDeviceAnchor(atTimestamp: timestamp)?.originFromAnchorTransform else {
            framesSkippedWithoutDeviceAnchor += 1
            return
        }
        let headColumn = headTransform.columns.3
        let headPosition = SIMD3<Float>(headColumn.x, headColumn.y, headColumn.z)
        latestHeadPosition = headPosition

        let event = recognizer.update(left: latestLeftPose, right: latestRightPose, headPosition: headPosition, timestamp: timestamp)
        diagnostics = recognizer.diagnostics
        capture.record(
            headPosition: headPosition,
            left: latestLeftPose,
            right: latestRightPose,
            timestamp: timestamp,
            state: recognizer.state,
            event: event,
            skippedNoDeviceAnchor: framesSkippedWithoutDeviceAnchor,
            skippedNoHandSkeleton: framesSkippedWithoutHandSkeleton
        )

        feedEntryGate(at: timestamp)

        switch event {
        case .detected:
            logger.notice("Dua posture detected")
        case .released:
            logger.notice("Dua posture released")
        case nil:
            break
        }
    }
}

private extension HandPose {
    /// The only place `HandPose` values are built from ARKit types.
    init?(anchor: HandAnchor, timestamp: TimeInterval) {
        guard let skeleton = anchor.handSkeleton else { return nil }

        func position(_ name: HandSkeleton.JointName) -> SIMD3<Float> {
            let joint = skeleton.joint(name)
            let transform = anchor.originFromAnchorTransform * joint.anchorFromJointTransform
            return SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        }

        self.init(
            chirality: anchor.chirality == .left ? .left : .right,
            joints: Joints(
                wrist: position(.wrist),
                indexKnuckle: position(.indexFingerKnuckle),
                middleKnuckle: position(.middleFingerKnuckle),
                ringKnuckle: position(.ringFingerKnuckle),
                littleKnuckle: position(.littleFingerKnuckle),
                indexTip: position(.indexFingerTip),
                middleTip: position(.middleFingerTip),
                ringTip: position(.ringFingerTip),
                littleTip: position(.littleFingerTip)
            ),
            isTracked: anchor.isTracked,
            timestamp: timestamp
        )
    }
}
