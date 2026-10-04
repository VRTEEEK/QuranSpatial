//
//  EnvironmentCapture.swift
//  QuranSpatial
//
//  The A/B frame capture for Stage 3: 30s with the environment in the scene, 30s without,
//  same build and same session, and the difference reported as the environment's isolated
//  frame cost.
//
//  Sequenced automatically rather than asking for two separate wearings. A device session
//  is expensive and two builds could not be compared anyway — thermal state, other processes
//  and the wearer's position all drift between them. Running B immediately after A in one
//  session is the closest thing to a controlled comparison available here.
//
//  **The honest limit of that:** run B removes the environment from the scene AND releases
//  the entity, but a process that has already loaded 21 textures is not identical to one
//  that never did. The frame-time difference is sound — nothing of the environment is being
//  drawn in B. The MEMORY difference is a floor, not a true delta, because allocator and
//  caching behaviour need not give everything back. That is stated in the report rather
//  than smoothed over.
//

import Foundation
import RealityKit
import os

@MainActor
final class EnvironmentCapture {

    /// **OFF by default, and it must stay that way.**
    ///
    /// Phase B removes and releases the environment, so with this on, anyone who opens the
    /// immersive space watches the scene vanish after 30 seconds with nothing to explain it.
    /// That is correct behaviour for a measurement and indistinguishable from a crash for
    /// everyone else. Same reasoning as splitting the grey-box flag off the isolation flag:
    /// a measurement switch should not be able to change what an ordinary session looks like.
    ///
    /// Turn it on deliberately for a capture run, and turn it off again.
    static let isEnabled = false

    /// Seconds discarded at the start of each phase. The first frames after a scene change
    /// carry shader compilation, texture upload and the scene graph settling — real costs,
    /// but not steady state, which is what the 2 ms budget is about.
    static let settleSeconds: Double = 2.0

    /// Seconds of steady state measured per phase.
    static let measureSeconds: Double = 30.0

    enum Phase: String {
        case settlingA = "A-settling"
        case measuringA = "A-measuring"
        case settlingB = "B-settling"
        case measuringB = "B-measuring"
        case done = "done"
    }

    private(set) var phase: Phase = .settlingA
    private var phaseStart: Double = CFAbsoluteTimeGetCurrent()

    /// Frame deltas in seconds. Kept as samples rather than folded into a running mean
    /// because a p95 cannot be recovered from summary statistics.
    private var samplesA: [Double] = []
    private var samplesB: [Double] = []
    private var peakA: UInt64 = 0
    private var peakB: UInt64 = 0
    private var framesSinceMemorySample = 0

    /// Called when phase A ends so the caller can take the environment out of the scene.
    var onEnterPhaseB: (() -> Void)?

    /// Hands back the environment entity so residency can be sampled at the end of phase A -
    /// in scene, rendering, at steady state. That is the only moment a texture working set
    /// means anything.
    var environmentProvider: (() -> Entity?)?
    private var residencyAtSteadyState: (count: Int, bytes: UInt64, detail: [String])?
    private var footprintAtSteadyState: UInt64?
    var onFinished: ((String) -> Void)?

    private let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "Capture")

    func begin() {
        phase = .settlingA
        phaseStart = CFAbsoluteTimeGetCurrent()
        samplesA.removeAll(); samplesB.removeAll()
        peakA = 0; peakB = 0
        logger.notice("Capture started: phase A settling")
    }

    /// One frame. `delta` is the frame time; everything else is derived here so the caller
    /// holds no capture state.
    func record(delta: Double) {
        guard phase != .done else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - phaseStart

        // Memory is sampled every 30th frame rather than every frame: task_info is a kernel
        // call and taking one per frame would put the instrument into its own measurement.
        framesSinceMemorySample += 1
        if framesSinceMemorySample >= 30 {
            framesSinceMemorySample = 0
            if let f = MemoryProbe.physFootprint() {
                switch phase {
                case .settlingA, .measuringA: peakA = max(peakA, f)
                case .settlingB, .measuringB: peakB = max(peakB, f)
                case .done: break
                }
            }
        }

        switch phase {
        case .settlingA:
            if elapsed >= Self.settleSeconds { phase = .measuringA; phaseStart = now
                logger.notice("Phase A measuring") }
        case .measuringA:
            if delta.isFinite, delta > 0 { samplesA.append(delta) }
            if elapsed >= Self.measureSeconds {
                // Sampled BEFORE the environment leaves the scene: 30s of rendering in, this
                // is the real working set rather than whatever survives at idle.
                if let e = environmentProvider?() {
                    residencyAtSteadyState = PavilionEnvironment.textureResidency(e)
                }
                footprintAtSteadyState = MemoryProbe.physFootprint()
                phase = .settlingB; phaseStart = now
                logger.notice("Phase A complete (\(self.samplesA.count) frames); removing environment")
                onEnterPhaseB?()
            }
        case .settlingB:
            if elapsed >= Self.settleSeconds { phase = .measuringB; phaseStart = now
                logger.notice("Phase B measuring") }
        case .measuringB:
            if delta.isFinite, delta > 0 { samplesB.append(delta) }
            if elapsed >= Self.measureSeconds {
                phase = .done
                let text = summarise()
                logger.notice("\(text, privacy: .public)")
                onFinished?(text)
            }
        case .done: break
        }
    }

    // MARK: - Statistics

    private struct Stats {
        let count: Int, mean: Double, p95: Double, worst: Double, dropped: Int, droppedPct: Double
    }

    private func stats(_ samples: [Double]) -> Stats? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let mean = samples.reduce(0, +) / Double(samples.count)
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let dropped = samples.filter { $0 > FrameStats.droppedThresholdSeconds }.count
        return Stats(count: samples.count, mean: mean, p95: p95, worst: sorted.last!,
                     dropped: dropped, droppedPct: Double(dropped) / Double(samples.count) * 100)
    }

    private func line(_ label: String, _ s: Stats?, _ peak: UInt64) -> [String] {
        guard let s else { return ["\(label): NO FRAMES RECORDED — not a pass, an absence of evidence"] }
        return [
            "\(label)",
            String(format: "  frames        %d over %.0fs", s.count, Self.measureSeconds),
            String(format: "  mean          %.3f ms", s.mean * 1000),
            String(format: "  p95           %.3f ms", s.p95 * 1000),
            String(format: "  worst         %.3f ms", s.worst * 1000),
            String(format: "  dropped       %d  (%.3f%%, bar <1.000%%)  %@",
                   s.dropped, s.droppedPct, s.droppedPct < 1 ? "PASS" : "FAIL"),
            "  peak footprint \(MemoryProbe.mb(peak == 0 ? nil : peak))",
        ]
    }

    private func summarise() -> String {
        let a = stats(samplesA), b = stats(samplesB)
        var out: [String] = []
        out.append("=== STAGE 3 FRAME CAPTURE ===")
        out.append("written: \(ISO8601DateFormatter().string(from: Date()))")
        out.append(String(format: "settle %.0fs discarded, %.0fs measured per phase", Self.settleSeconds, Self.measureSeconds))
        out.append("")
        out.append(contentsOf: line("RUN A — environment loaded", a, peakA))
        out.append("")
        out.append(contentsOf: line("RUN B — empty immersive scene", b, peakB))
        out.append("")
        if let a, let b {
            let dMean = (a.mean - b.mean) * 1000
            let dP95 = (a.p95 - b.p95) * 1000
            out.append("=== A - B : ISOLATED ENVIRONMENT COST ===")
            out.append(String(format: "  mean  %+.3f ms   against a 2.000 ms budget  -> %@",
                              dMean, dMean < 2.0 ? "WITHIN" : "OVER"))
            out.append(String(format: "  p95   %+.3f ms", dP95))
            out.append(String(format: "  peak footprint delta  %@", MemoryProbe.mbDelta(peakA, peakB)))
            out.append("")
            out.append("Memory delta is a FLOOR, not a true difference: run B follows run A in the")
            out.append("same process, so allocations the loader has already made need not be returned.")
        } else {
            out.append("A - B not computed: one or both phases recorded no frames.")
        }

        out.append("")
        out.append("=== TEXTURE RESIDENCY AT STEADY STATE (in scene, 30s of rendering) ===")
        if let res = residencyAtSteadyState {
            out.append("resident: \(res.count) of \(PavilionEnvironment.authoredTextureCount) authored maps")
            out.append(String(format: "total   : %.2f MB", Double(res.bytes) / 1_048_576))
            out.append(contentsOf: res.detail)
            out.append("4096-wide night sky resident: \(res.detail.contains { $0.contains(" 4096 x") } ? "YES" : "NO")")
        } else {
            out.append("not sampled (no environment entity provided)")
        }
        out.append("footprint at end of phase A: \(MemoryProbe.mb(footprintAtSteadyState))")
        return out.joined(separator: "\n")
    }

    /// **A SEPARATE FILE FROM frame-stats.txt, and that is a bug fix, not a preference.**
    ///
    /// Both this and `FrameStatsLog` were writing `frame-stats.txt`. `FrameStatsLog` rewrites
    /// that file WHOLE from its own row array on every segment report, so anything appended
    /// here was destroyed by the next write - which is why the first A/B attempt came back
    /// carrying only per-ayah dissolve rows and no capture at all. Two writers, one filename,
    /// and the louder one wins silently.
    ///
    /// APPENDS within its own file, so a second session's numbers do not overwrite the
    /// first's: one capture is a data point, not a measurement.
    static let filename = "ab-capture.txt"

    static func write(_ text: String) {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(filename) else { return }
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let combined = existing.isEmpty ? text : existing + "\n\n" + String(repeating: "=", count: 70) + "\n\n" + text
        try? combined.write(to: url, atomically: true, encoding: .utf8)
    }
}
