//
//  HandPoseCapture.swift
//  QuranSpatial
//
//  Records HandPose sequences to a JSON file, so a real device session can be captured
//  once during tuning and turned into unit-test fixtures instead of re-posing in the
//  headset for every threshold change. Pure data in, file out - no ARKit or RealityKit
//  imports, consistent with keeping this debug tool as testable as the recognizer itself.
//  Debug tooling only; not part of the shipped experience.
//

import Foundation
import simd

@MainActor
@Observable
final class HandPoseCapture {

    /// One frame of the same data `DuaPostureRecognizer.update` consumes, plus what the
    /// recognizer made of it on device.
    ///
    /// `state` and `event` are what separate a live take from a replay. Without them the
    /// file records only inputs, and any claim about on-device behaviour is really a claim
    /// about re-running the recognizer over those inputs afterwards. With them, the
    /// device's own verdict is in the file and a replay can be checked against it.
    /// Both are optional, so captures recorded before this existed still decode.
    struct Frame: Codable {
        var timestamp: TimeInterval
        var headPosition: SIMD3<Float>
        var left: HandPose?
        var right: HandPose?
        var state: String?
        var event: String?

        /// Seconds between this frame and the last update of each hand. The recognizer
        /// retains the most recent pose for a hand that stops updating, so a frame can
        /// carry joint positions tens of seconds old - one standing capture reached 32s.
        /// `isTracked` does flag it, but only if you go looking; recording the age makes a
        /// stale pose legible in the file on its own terms.
        var leftPoseAge: TimeInterval?
        var rightPoseAge: TimeInterval?

        /// Running totals of hand-anchor updates that arrived but produced no frame,
        /// carried on the next frame that *is* recorded. A gap in the capture is otherwise
        /// silent about its own cause: these separate "ARKit sent nothing" (neither counter
        /// moves across the gap) from "anchors arrived but were unusable" (one of them
        /// jumps by roughly the number of missing frames).
        var skippedNoDeviceAnchor: Int?
        var skippedNoHandSkeleton: Int?
    }

    /// Safety cap so a forgotten "still recording" doesn't grow without bound across a
    /// long session.
    ///
    /// The old value assumed 100Hz and claimed ten minutes; both were wrong. `record` is
    /// called once per *hand anchor* update and there are two hands, so the real rate is
    /// roughly double a single hand's: the two device takes so far measured 199Hz (hands
    /// tracked 99% of the time) and 162Hz (81%, a session with a headset adjust and
    /// occluded holds). At 200Hz the old 60,000 frames was five minutes, not ten.
    ///
    /// 120,000 restores the intended ten minutes at the rate actually observed. Note the
    /// file that produces: the 137s take was 51MB, so a full ten minutes is roughly 250MB
    /// of JSON to write on device and pull off it.
    private static let maxFrames = 120_000

    private(set) var isRecording = false
    private(set) var frameCount = 0
    private var frames: [Frame] = []

    /// True once `maxFrames` is reached. Recording has stopped, but the frames are still
    /// in memory and still saveable - reaching the cap must not strand a take.
    private(set) var reachedCapacity = false

    /// Whether there are recorded frames that have not been written to disk. The debug HUD
    /// uses this to keep offering "save" instead of "record" after a capped take, so the
    /// next button press cannot silently discard it.
    var hasUnsavedFrames: Bool { !frames.isEmpty }

    func startRecording() {
        frames.removeAll()
        frameCount = 0
        reachedCapacity = false
        isRecording = true
    }

    func record(
        headPosition: SIMD3<Float>,
        left: HandPose?,
        right: HandPose?,
        timestamp: TimeInterval,
        state: DuaPostureRecognizer.State,
        event: DuaPostureRecognizer.Event?,
        skippedNoDeviceAnchor: Int,
        skippedNoHandSkeleton: Int
    ) {
        guard isRecording else { return }
        guard frames.count < Self.maxFrames else {
            isRecording = false
            reachedCapacity = true
            return
        }
        frames.append(Frame(
            timestamp: timestamp,
            headPosition: headPosition,
            left: left,
            right: right,
            state: Self.label(state),
            event: event.map(Self.label),
            leftPoseAge: left.map { timestamp - $0.timestamp },
            rightPoseAge: right.map { timestamp - $0.timestamp },
            skippedNoDeviceAnchor: skippedNoDeviceAnchor,
            skippedNoHandSkeleton: skippedNoHandSkeleton
        ))
        frameCount = frames.count
    }

    private static func label(_ state: DuaPostureRecognizer.State) -> String {
        switch state {
        case .idle: "idle"
        case .entering: "entering"
        case .held: "held"
        }
    }

    private static func label(_ event: DuaPostureRecognizer.Event) -> String {
        switch event {
        case .detected: "detected"
        case .released: "released"
        }
    }

    /// Stops recording and writes the captured frames as JSON to the app's Documents
    /// directory. Pull the file off with Xcode's Window > Devices and Simulators > select
    /// the device > select QuranSpatial > "Download Container..." - no file-sharing
    /// entitlement needed, so this doesn't require a project-file change.
    ///
    /// On success the buffer is cleared, so `hasUnsavedFrames` goes false and the HUD
    /// returns to offering a fresh recording. On failure the frames are deliberately kept,
    /// so a write error is retryable rather than losing the take.
    @discardableResult
    func stopAndSave() -> URL? {
        isRecording = false
        guard !frames.isEmpty else { return nil }

        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        let filename = "dua-capture-\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")).json"
        let url = documents.appendingPathComponent(filename)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(frames)
            try data.write(to: url, options: .atomic)
            frames.removeAll()
            frameCount = 0
            reachedCapacity = false
            return url
        } catch {
            return nil
        }
    }
}
