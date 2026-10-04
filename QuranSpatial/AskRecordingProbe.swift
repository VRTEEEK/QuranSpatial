//
//  AskRecordingProbe.swift
//  QuranSpatial
//
//  DEBUG ONLY. Proves that the microphone opens under strategy S1: with the session
//  configured for recording (an Ask in progress), request record permission, record three
//  seconds to Documents/ask-probe.m4a and log the file size. The AI half of Ask brings its
//  own capture; this exists so the audio-session strategy can be device-tested before it.
//
//  Requires INFOPLIST_KEY_NSMicrophoneUsageDescription in the target's build settings
//  (set in Xcode, not here) - without it the first input use terminates the app.
//

#if DEBUG
import AVFoundation
import Foundation
import Observation
import os

@MainActor
@Observable
final class AskRecordingProbe {

    static let durationSeconds: TimeInterval = 3
    static let filename = "ask-probe.m4a"

    private(set) var status = "idle"
    private(set) var isRunning = false
    @ObservationIgnored private var recorder: AVAudioRecorder?
    private let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "AskProbe")

    func run(audioSession: AudioSessionController) async {
        guard !isRunning else { return }
        // The probe does not switch the category itself: that is `enterAsk()`'s job, and
        // the test is that the switch already made the mic available.
        guard audioSession.isConfiguredForRecording else {
            status = "refused: session is not configured for recording - press Ask first"
            logger.notice("Record probe refused: \(audioSession.statusLine, privacy: .public)")
            return
        }
        isRunning = true
        defer { isRunning = false }

        status = "requesting permission…"
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            status = "permission denied"
            logger.error("Record probe: microphone permission denied")
            return
        }

        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            status = "no Documents directory"
            return
        }
        let url = documents.appendingPathComponent(Self.filename)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            self.recorder = recorder
            guard recorder.record() else {
                status = "record() returned false"
                logger.error("Record probe: AVAudioRecorder.record() returned false under \(audioSession.statusLine, privacy: .public)")
                return
            }
            status = "recording \(Int(Self.durationSeconds)) s…"
            logger.notice("Record probe: recording started under \(audioSession.statusLine, privacy: .public)")
            try? await Task.sleep(for: .seconds(Self.durationSeconds))
            recorder.stop()
            self.recorder = nil
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            status = "saved \(Self.filename) (\(size) bytes)"
            logger.notice("Record probe: saved \(Self.filename, privacy: .public), \(size) bytes")
        } catch {
            status = "failed: \(error.localizedDescription)"
            logger.error("Record probe failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
