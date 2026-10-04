//
//  DuaDebugHUDView.swift
//  QuranSpatial
//
//  Plain SwiftUI readout of DuaPostureRecognizer.Diagnostics, rendered as a RealityView
//  attachment so it's legible next to the on-hand markers in DuaDebugVisualization. Also
//  hosts the fixture-capture controls (see HandPoseCapture) - record a real dua pose once
//  on device, pull the JSON off, turn it into test fixtures instead of re-posing in the
//  headset for every threshold change. Debug-only.
//

import SwiftUI

struct DuaDebugHUDView: View {
    var session: HandTrackingSession
    /// Optional so the preview and any non-immersive use still compile. Debug-only, like
    /// the rest of this HUD.
    var dissolve: DissolveDriver?
    /// Transport readout and the Ask debug trigger (Stage 2). Optional like `dissolve`.
    var recitation: RecitationCoordinator?
    var onAsk: (() -> Void)?
    var onResume: (() -> Void)?
    var onDebugStop: (() -> Void)?

    @State private var lastSavedFilename: String?
    #if DEBUG
    @State private var probe = AskRecordingProbe()
    #endif

    var body: some View {
        let diagnostics = session.diagnostics
        VStack(alignment: .leading, spacing: 4) {
            Text("dua: \(stateLabel(diagnostics.state))")
                .bold()
            row("L tracked", diagnostics.leftTracked ? "yes" : "no")
            row("R tracked", diagnostics.rightTracked ? "yes" : "no")
            row("L inward", format(diagnostics.leftPalmInwardDot))
            row("R inward", format(diagnostics.rightPalmInwardDot))
            row("L towardHead", format(diagnostics.leftPalmTowardHeadDot))
            row("R towardHead", format(diagnostics.rightPalmTowardHeadDot))
            row("L ext", format(diagnostics.leftFingerExtension))
            row("R ext", format(diagnostics.rightFingerExtension))
            row("L belowHead", format(diagnostics.leftBelowHeadY))
            row("R belowHead", format(diagnostics.rightBelowHeadY))
            row("separation", format(diagnostics.separation))
            if session.framesSkippedWithoutDeviceAnchor > 0 {
                row("no-head skips", "\(session.framesSkippedWithoutDeviceAnchor)")
            }
            if let progress = diagnostics.holdProgress {
                row("hold", String(format: "%.2fs / %.2fs", progress, DuaPostureRecognizer.commitWindow))
            }

            row("gate", gateLabel)

            if let dissolve {
                Divider()
                    .padding(.vertical, 2)
                dissolveRows(dissolve)
            }

            if let recitation {
                Divider()
                    .padding(.vertical, 2)
                transportRows(recitation)
            }

            Divider()
                .padding(.vertical, 2)

            captureControls

            #if DEBUG
            Divider()
                .padding(.vertical, 2)
            // Debug only: the Ask trigger is out of scope, so these stand in for it on
            // device. Every accidental acceptance otherwise costs a ten-minute recitation
            // before the device can be tested again.
            HStack {
                Button("Ask (debug)") { onAsk?() }
                Button("Resume (debug)") { onResume?() }
            }
            if let recitation {
                Button(probe.isRunning ? "Recording…" : "Record probe (debug)") {
                    Task { await probe.run(audioSession: recitation.audioSession) }
                }
                .disabled(probe.isRunning)
                row("probe", probe.status)
            }
            Button("Abort run (debug)") { onDebugStop?() }
                .tint(.orange)
            #endif
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(10)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
    }

    /// The material's load result and the running frame report. Both matter on device and
    /// neither is visible any other way without a Mac attached: the acceptance criteria are
    /// measured across a ten-minute session, and nobody is going to sit through one tethered.
    @ViewBuilder
    private func dissolveRows(_ dissolve: DissolveDriver) -> some View {
        if let failure = dissolve.loadFailure {
            // Sized and coloured to be READ AND PHOTOGRAPHED through the headset, not to
            // match the rest of this HUD. The diagnostics above are glanceable telemetry;
            // this is a string someone has to transcribe, and at 10pt grey-on-black it was
            // not transcribable. White on red, 15pt, and wrapped rather than truncated -
            // `lineLimit(nil)` with a fixed width, because a truncated error is the same as
            // no error.
            VStack(alignment: .leading, spacing: 6) {
                Text("DISSOLVE MATERIAL FAILED")
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                Text(failure.multilineDescription)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("no dissolve - text is hard-cutting between ayat")
                    .font(.system(size: 13, design: .monospaced))
            }
            .foregroundStyle(.white)
            .frame(width: 460, alignment: .leading)
            .padding(12)
            .background(Color(red: 0.62, green: 0.05, blue: 0.05),
                        in: RoundedRectangle(cornerRadius: 8))
        } else {
            row("dissolve", dissolve.isMaterialLoaded ? "material loaded" : "loading")
        }
        // Updated once per ayah, never per frame - a per-frame SwiftUI dependency here
        // would re-render this HUD 90 times a second and corrupt the numbers it is showing.
        if let report = dissolve.latestSegmentReport {
            Text(report)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    /// Phase, transport, pin and audio session. Written at most a few times per ayah, so
    /// observing them here costs nothing per frame.
    @ViewBuilder
    private func transportRows(_ recitation: RecitationCoordinator) -> some View {
        row("phase", String(describing: recitation.experiencePhase))
        row("playback", recitation.playbackState == .paused
            ? "paused:\(recitation.pauseReason.rawValue)" : String(describing: recitation.playbackState))
        row("pinned", recitation.pinnedSegmentIndex.map { "segment \($0)" } ?? "-")
        if let plan = recitation.resumePlan {
            row("resume→", String(format: "%.3f s, fade %.3f%@", plan.targetTime, plan.fadeSeconds,
                                  plan.measured ? "" : " (fallback)"))
        }
        row("audio", recitation.audioSession.statusLine)
        if let event = recitation.audioSession.lastEventDescription {
            row("last", event)
        }
    }

    private var captureControls: some View {
        // Anything unsaved - still recording, or stopped at the frame cap - offers save.
        // Only an empty buffer offers a fresh recording, so a press can never discard a
        // take that has not been written to disk.
        let capture = session.capture
        let offersSave = capture.isRecording || capture.hasUnsavedFrames

        return VStack(alignment: .leading, spacing: 4) {
            Button(buttonTitle) {
                if offersSave {
                    lastSavedFilename = capture.stopAndSave()?.lastPathComponent
                } else {
                    lastSavedFilename = nil
                    capture.startRecording()
                }
            }
            .tint(capture.reachedCapacity ? .orange : (capture.isRecording ? .red : .accentColor))

            if capture.reachedCapacity {
                Text("frame cap reached - recording stopped, take still unsaved")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.orange)
            }

            if let lastSavedFilename {
                Text("saved: \(lastSavedFilename)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.green)
            }
        }
    }

    private var buttonTitle: String {
        let capture = session.capture
        if capture.reachedCapacity {
            return "Save capped take (\(capture.frameCount) frames)"
        }
        if capture.isRecording {
            return "Stop && Save (\(capture.frameCount) frames)"
        }
        if capture.hasUnsavedFrames {
            return "Save (\(capture.frameCount) frames)"
        }
        return "Record"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 12)
            Text(value)
        }
    }

    private func format(_ value: Float?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "-"
    }

    private var gateLabel: String {
        switch session.entryGateState {
        case .armed: "armed"
        case .accepted: "accepted (hands ignored)"
        case .awaitingRelease: "awaiting release"
        }
    }

    private func stateLabel(_ state: DuaPostureRecognizer.State) -> String {
        switch state {
        case .idle: "idle"
        case .entering: "entering"
        case .held: "held"
        }
    }
}
