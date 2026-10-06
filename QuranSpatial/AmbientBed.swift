//
//  AmbientBed.swift
//  QuranSpatial
//
//  The immersive experience's looping background ambience (Mohamed, 2026-10-06):
//  `Resources/background.m4a` - 3:09, stereo AAC 48 kHz, quiet by design (peak -16 dBFS,
//  average about -43 dBFS, ends at about -52 dBFS so the loop seam is soft). Plays for the
//  whole time the ImmersiveSpace is open, under the recitation, and DUCKS TO SILENCE while
//  an Ask is in progress so nothing from the speakers reaches the microphone or the silence
//  detector. Plain `AVAudioPlayer`, infinite loop, no spatial API. No audio-session change:
//  the recitation coordinator owns the category, and this player follows it.
//

import AVFoundation
import Foundation
import os

@MainActor
final class AmbientBed {

    static let resourceName = "background"
    static let resourceExtension = "m4a"

    /// Full-scale on this file is still quiet, so the bed starts high and is tuned on the
    /// headset against the recitation. The recitation is the voice; this is the room.
    static let volume: Float = 0.5   // 0.9 was "too loud", 0.45 then set to 0.5 by ear on device, 2026-10-06
    /// Seconds for the fades at start, stop and the Ask duck.
    static let fadeSeconds: TimeInterval = 0.6

    private var player: AVAudioPlayer?
    private var isDucked = false
    private let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "AmbientBed")

    /// Begins the loop from the top with a fade-in. Idempotent while playing.
    func start() {
        if player == nil {
            guard let url = Bundle.main.url(forResource: Self.resourceName, withExtension: Self.resourceExtension) else {
                logger.error("Ambient bed: \(Self.resourceName).\(Self.resourceExtension) not in bundle")
                return
            }
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.numberOfLoops = -1
                p.prepareToPlay()
                player = p
            } catch {
                logger.error("Ambient bed: could not load: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        guard let player, !player.isPlaying else { return }
        player.volume = 0
        player.currentTime = 0
        if player.play() {
            player.setVolume(isDucked ? 0 : Self.volume, fadeDuration: Self.fadeSeconds)
            logger.notice("Ambient bed: started (loop, volume \(Self.volume))")
        } else {
            logger.error("Ambient bed: play() returned false")
        }
    }

    /// Fades out and stops. The player is kept for the next start.
    func stop() {
        guard let player, player.isPlaying else { return }
        player.setVolume(0, fadeDuration: Self.fadeSeconds)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.fadeSeconds))
            guard let self, let p = self.player, p.volume == 0 else { return }
            p.pause()
            self.logger.notice("Ambient bed: stopped")
        }
    }

    /// Ask in progress: silence the bed so the microphone hears only the wearer. Restores
    /// the level when the Ask ends. Playback itself continues, so the loop position is kept.
    func setDucked(_ ducked: Bool) {
        guard isDucked != ducked else { return }
        isDucked = ducked
        guard let player, player.isPlaying else { return }
        player.setVolume(ducked ? 0 : Self.volume, fadeDuration: Self.fadeSeconds)
        logger.notice("Ambient bed: \(ducked ? "ducked for Ask" : "restored after Ask", privacy: .public)")
    }
}
