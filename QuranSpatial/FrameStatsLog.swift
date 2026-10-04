//
//  FrameStatsLog.swift
//  QuranSpatial
//
//  Writes the per-segment frame report to a file, so the numbers can be pulled with
//  `devicectl device copy from` instead of being read off a HUD inside an ImmersiveSpace or
//  through Console.app on a tethered Mac.
//
//  This exists because the instrument was originally unreadable from anywhere except the
//  headset: FrameStats reported to os_log and to the dua HUD, and both of those are exactly
//  the places you cannot get a table out of. A measurement you cannot retrieve is not a
//  measurement.
//
//  The whole file is rewritten each time rather than appended to. It is 80 lines at most,
//  the write is well under a millisecond, and it happens once per ayah rather than per
//  frame - so the simpler thing is also the correct thing here, and a rewrite cannot leave
//  a half-appended row behind if the app is killed mid-write.
//

import Foundation
import os

@MainActor
final class FrameStatsLog {

    static let filename = "frame-stats.txt"

    private var rows: [String] = []
    private let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "FrameStats")

    private static var url: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(filename)
    }

    /// Starts a new run's table. Previous rows are dropped, matching the session reset in
    /// the driver - two runs merged into one table would misreport both.
    func beginRun(note: String) {
        rows = [
            "run started: \(ISO8601DateFormatter().string(from: Date()))",
            note,
            "bar: dropped <1.00%, no frame over 50.0ms, thermal below serious (fair is reported, not failed)",
            "dropped = frame delta over 1.5x nominal (16.7ms at 90Hz)",
            "",
        ]
        flush()
    }

    func append(_ row: String) {
        rows.append(row)
        flush()
    }

    /// Written on every append so a run that is killed - rather than ended - still leaves
    /// every completed row on disk.
    private func flush() {
        guard let url = Self.url else { return }
        do {
            try rows.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Could not write frame stats: \(error.localizedDescription)")
        }
    }
}
