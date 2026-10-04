//
//  AudioAssetReport.swift
//  QuranSpatial
//
//  Launch-time backstop for the recitation assets, alongside FontIdentityReport and for
//  the same reason: a wrong bundle lookup builds cleanly and returns nil at runtime, so
//  the failure surfaces as playback silently doing nothing rather than as an error.
//
//  Verified against the built product, not inferred: synchronised folder references put
//  their contents at the bundle ROOT, flat. `QuranSpatial/Resources/rahman-single.mp3`
//  lands at `<App>/rahman-single.mp3`, so no `subdirectory:` argument is wanted and passing
//  "Resources" would return nil. The probe below still tries the subdirectory second and
//  records which lookup succeeded, so a future change in that behaviour shows up in the
//  report rather than as silence.
//

import AVFoundation
import Foundation
import os

enum AudioAssetReport {

    static let filename = "audio-assets.txt"

    static let audioResourceName = "rahman-single"
    static let audioResourceExtension = "mp3"
    static let timingsResourceName = "ar-rahman-timings"
    static let timingsResourceExtension = "json"

    private static let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "AudioAssets")

    /// Resolves a bundled resource, reporting which lookup found it.
    static func locate(_ name: String, _ ext: String) -> (url: URL, how: String)? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return (url, "bundle root")
        }
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Resources") {
            return (url, "Resources/ subdirectory")
        }
        return nil
    }

    static var bothAssetsResolve: Bool {
        locate(audioResourceName, audioResourceExtension) != nil
            && locate(timingsResourceName, timingsResourceExtension) != nil
    }

    @discardableResult
    static func write() async -> URL? {
        var lines: [String] = ["written: \(ISO8601DateFormatter().string(from: Date()))"]
        var problems: [String] = []

        let audio = locate(audioResourceName, audioResourceExtension)
        let timings = locate(timingsResourceName, timingsResourceExtension)

        func describe(_ label: String, _ found: (url: URL, how: String)?, _ name: String, _ ext: String) {
            guard let found else {
                lines.append("\(label): NOT FOUND - \(name).\(ext) did not resolve from the bundle")
                problems.append("\(name).\(ext) missing")
                return
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: found.url.path)[.size] as? Int) ?? nil
            lines.append("\(label): found via \(found.how), \(size.map(String.init) ?? "?") bytes")
        }

        describe("audio", audio, audioResourceName, audioResourceExtension)
        describe("timings", timings, timingsResourceName, timingsResourceExtension)

        // Decoding here rather than only checking existence: a present-but-unparseable
        // timings file fails exactly as silently as a missing one.
        var declaredTotal: Double?
        if let timings {
            do {
                let data = try Data(contentsOf: timings.url)
                let file = try JSONDecoder().decode(RecitationTimingsFile.self, from: data)
                declaredTotal = file.totalDuration
                lines.append("timings decoded: \(file.segments.count) segments, ayahCount \(file.ayahCount), totalDuration \(file.totalDuration)")
                let kinds = Dictionary(grouping: file.segments, by: { $0.kind.rawValue }).mapValues(\.count)
                lines.append("timings kinds: " + kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            } catch {
                lines.append("timings decode: FAILED - \(error)")
                problems.append("timings unparseable")
            }
        }

        // The timings are keyed to this particular file, so a mismatched pair is worth
        // catching at launch rather than as drift that grows across the surah.
        if let audio {
            let asset = AVURLAsset(url: audio.url)
            if let duration = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(duration)
                lines.append(String(format: "audio duration: %.3fs", seconds))
                if let declaredTotal {
                    let delta = abs(seconds - declaredTotal)
                    lines.append(String(format: "duration vs timings totalDuration: %+.3fs", seconds - declaredTotal))
                    if delta > 1.0 {
                        problems.append(String(format: "audio and timings disagree by %.3fs", delta))
                    }
                }
            } else {
                lines.append("audio duration: could not be loaded")
                problems.append("audio duration unreadable")
            }
        }

        lines.append(problems.isEmpty
                     ? "verdict: OK - both assets resolved and agree"
                     : "verdict: PROBLEM - " + problems.joined(separator: "; "))

        if problems.isEmpty {
            logger.notice("Recitation assets OK")
        } else {
            logger.error("Recitation asset problem: \(problems.joined(separator: "; "))")
        }

        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = documents.appendingPathComponent(filename)
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            logger.error("Could not write audio asset report: \(error.localizedDescription)")
            return nil
        }
    }
}
