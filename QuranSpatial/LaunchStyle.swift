//
//  LaunchStyle.swift
//  QuranSpatial
//
//  Launch UI, 2026-10-05. Visual vocabulary for the launch window: the gold palette, the
//  capsule button style, the identity mark, and the modifier that brings the launch window
//  back when the immersive space closes.
//
//  Everything here is native SwiftUI on visionOS glass. One supplied PNG is bundled: the
//  image set `LaunchLogoMark` is `logo.png` from the launch brief's icon folder (1536 x 1024,
//  RGBA, transparent corners), copied in BYTE-FOR-BYTE at 2x - no crop, recolour, upscale or
//  fringe work (Mohamed's directive, 2026-10-05 evening). It carries the crescent, the
//  calligraphy and the QURANSPATIAL wordmark, and it is the whole identity: the native
//  wordmark and subtitle were removed the same evening. The calligraphy is GENERATED artwork of the
//  word القرآن - a logo, not Quran text, not verified, never used as text; flagged as a
//  pre-App-Store replacement. The icon and button PNGs remain visual reference only.
//

import SwiftUI
import UIKit
import AVFoundation
import os

enum LaunchPalette {
    /// Warm lantern gold from the reference, kept slightly desaturated so it reads as
    /// gold on glass and not as yellow (yellow was the failure mode for the ayah text).
    static let goldLight = Color(red: 0.95, green: 0.84, blue: 0.62)
    static let gold      = Color(red: 0.86, green: 0.70, blue: 0.44)
    static let goldDeep  = Color(red: 0.66, green: 0.49, blue: 0.27)

    static let goldGradient = LinearGradient(colors: [goldLight, gold, goldDeep],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing)
}

/// Capsule button on system glass with native gaze/hand hover feedback.
struct LaunchCapsuleButtonStyle: ButtonStyle {

    enum Prominence { case primary, secondary, quiet }
    let prominence: Prominence

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if prominence == .primary {
                    // Gold wash over the glass: present but translucent, so the glass and
                    // whatever is behind it still read through.
                    Capsule().fill(
                        LinearGradient(colors: [LaunchPalette.gold.opacity(0.42),
                                                LaunchPalette.goldDeep.opacity(0.22)],
                                       startPoint: .top, endPoint: .bottom))
                }
            }
            .glassBackgroundEffect(in: Capsule())
            .overlay {
                Capsule().strokeBorder(borderStyle, lineWidth: prominence == .primary ? 1.5 : 1)
            }
            // Hover feedback is the system's own highlight, clipped to the capsule, so gaze
            // targeting looks exactly like every other visionOS control.
            .contentShape(.hoverEffect, Capsule())
            .contentShape(Capsule())
            .hoverEffect(.highlight)
            // The reference's primary capsule sits in a soft gold halo. A shadow, not a
            // second shape, so it stays outside the hover highlight and the hit shape.
            .shadow(color: LaunchPalette.gold.opacity(prominence == .primary ? 0.5 : 0),
                    radius: prominence == .primary ? 24 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.6)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }

    private var borderStyle: AnyShapeStyle {
        switch prominence {
            case .primary:   AnyShapeStyle(LaunchPalette.goldGradient.opacity(0.9))
            case .secondary: AnyShapeStyle(.white.opacity(0.22))
            case .quiet:     AnyShapeStyle(.white.opacity(0.12))
        }
    }
}

/// Fallback mark if the `LaunchLogoMark` image set is missing: crescent and star, drawn.
struct LaunchCrescentMark: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(LaunchPalette.goldGradient)
                .overlay {
                    Circle()
                        .offset(x: 26, y: -14)
                        .scaleEffect(0.86)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .frame(width: 112, height: 112)
                .rotationEffect(.degrees(-18))

            Image(systemName: "sparkle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(LaunchPalette.goldLight)
                .offset(x: 34, y: -40)
        }
        .frame(width: 140, height: 130)
        .shadow(color: LaunchPalette.gold.opacity(0.45), radius: 18)
        .accessibilityHidden(true)
    }
}

/// Identity block: the supplied logo image alone - it carries the crescent, the calligraphy
/// and the QURANSPATIAL wordmark, so there is no native wordmark or subtitle any more
/// ("remove the native text", 2026-10-05 evening). It fades in (opacity only) on the
/// directive's logo timing. Its frame is laid out from the first frame at opacity 0 - never
/// inserted conditionally - so the buttons below never shift when it appears.
struct LaunchIdentity: View {
    var appeared: Bool
    var reduceMotion: Bool

    var body: some View {
        Group {
            if UIImage(named: "LaunchLogoMark") != nil {
                Image("LaunchLogoMark")
                    .resizable()
                    .scaledToFit()
                    // 210 pt: the directive's 140 pt read small on device, raised 150% at
                    // Mohamed's word (2026-10-05, device check). 1536 x 1024 at 2x is 512 pt
                    // tall, so this is still a 2.4x downscale, never an upscale.
                    .frame(height: 210)
                    .accessibilityLabel("QuranSpatial")
                    .accessibilityAddTraits(.isHeader)
            } else {
                LaunchCrescentMark()
            }
        }
        .launchLogoEntrance(appeared, reduceMotion: reduceMotion)
    }
}

extension View {
    /// The buttons' entrance: a plain fade-in ("show button as a fade in", device check
    /// 2026-10-05), 1.2 s ease-out (0.6 s was "so fast" on device the same evening; doubled
    /// at Mohamed's word), staggered by `delay` - AFTER the logo and chime, which lead.
    /// Reduce Motion: 0.8 s, delay compressed.
    func launchEntrance(_ appeared: Bool, delay: Double, reduceMotion: Bool) -> some View {
        self
            .opacity(appeared ? 1 : 0)
            .animation(reduceMotion ? .easeOut(duration: 0.8).delay(delay * 0.55)
                                    : .easeOut(duration: 1.2).delay(delay),
                       value: appeared)
    }

    /// The mark's entrance: fade only, no rise, no scale, over 3.0 s ease-in-out (0.8 s was
    /// "so fast" on device and 1.6 s "still too fast", 2026-10-05; 3.0 s sits inside the
    /// chime's own 4.25 s swell). The logo
    /// and the chime LEAD the window now ("make the logo and the sound in the same time",
    /// device check 2026-10-05): the chime is fired the moment the window appears and the
    /// fade starts `LaunchChime.onsetLeadSeconds` later, so the audible onset and the fade
    /// begin together. Reduce Motion: same relationship, 0.4 s.
    func launchLogoEntrance(_ appeared: Bool, reduceMotion: Bool) -> some View {
        self
            .opacity(appeared ? 1 : 0)
            .animation(reduceMotion
                       ? .easeInOut(duration: 0.6).delay(LaunchChime.logoMomentSeconds(reduceMotion: true) + LaunchChime.onsetLeadSeconds)
                       : .easeInOut(duration: LaunchChime.logoFadeSeconds).delay(LaunchChime.logoMomentSeconds(reduceMotion: false) + LaunchChime.onsetLeadSeconds),
                       value: appeared)
    }
}

/// The launch chime (directive 2026-10-05, late evening): `Resources/logo_sound.wav`, played
/// ONCE each time the logo fade plays - on first appearance and on every reappearance after
/// the immersive space closes - never looped. Preloaded when the window appears so the first
/// play has no decode delay. Plain `AVAudioPlayer`, no spatial API, modest volume.
///
/// Shared rather than view state: the launch window dismisses itself once the space opens,
/// and a player owned by the view would be torn down with it, cutting a chime that is still
/// sounding. A chime in flight is allowed to finish; the file is 4.25 s, so one fired at
/// 0.9 s ends 5.15 s after the window appeared, and a wearer who enters and holds the dua
/// pose inside that window hears its tail under the first second of recitation. Nothing
/// delays the open. No audio-session change: the session category is first configured when
/// recitation starts, and `AVAudioPlayer` plays under the default category before that and
/// under `.playback` after a return.
@MainActor
final class LaunchChime {
    static let shared = LaunchChime()

    static let resourceName = "logo_sound"
    static let resourceExtension = "wav"

    /// The file's own lead-in, MEASURED on 2026-10-05 against `logo_sound.wav`
    /// SHA-256 3a038a800cd2bc47bacece3ea08a745b5e3e8322f84e5feb0d14a6b9cfff2243
    /// (48 kHz, stereo, 24-bit, 4.254 s, peak -2.32 dBFS): first sample above -60 dBFS at
    /// 108.8 ms, above -40 dBFS at 112.3 ms. `play()` is fired at the logo's moment and the
    /// fade is started this much later, so the audible onset lands on the fade start.
    /// **If the file ever changes, this constant must be re-measured, not kept.**
    static let onsetLeadSeconds: Double = 0.110

    /// When, after the window appears, the chime is fired: immediately, in both motion
    /// settings. The logo fade follows by `onsetLeadSeconds`; the buttons fade in after the
    /// logo has settled (0.9 s and 1.1 s).
    static func logoMomentSeconds(reduceMotion: Bool) -> Double { 0 }

    /// The logo fade's length; the buttons start fading in once it has settled.
    static let logoFadeSeconds: Double = 3.0
    /// Buttons: Enter, then Credits, both after the logo has settled.
    static let enterButtonDelaySeconds: Double = onsetLeadSeconds + logoFadeSeconds        // 3.11 s
    static let creditsButtonDelaySeconds: Double = enterButtonDelaySeconds + 0.2          // 3.31 s

    /// 0.5 was "too quiet" on the headset (2026-10-05); raised to 0.8 for the next pass.
    /// Peaks are -2.3 dBFS, loudest 100 ms -9 dBFS.
    static let volume: Float = 0.8

    private var player: AVAudioPlayer?
    private let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "LaunchChime")

    private init() {}

    /// Loads once and primes the buffers; called on every window appearance, cheap after
    /// the first.
    func prepare() {
        if player == nil {
            guard let url = Bundle.main.url(forResource: Self.resourceName, withExtension: Self.resourceExtension) else {
                logger.error("Launch chime: \(Self.resourceName).\(Self.resourceExtension) not in bundle")
                return
            }
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.numberOfLoops = 0
                p.volume = Self.volume
                player = p
            } catch {
                logger.error("Launch chime: could not load: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        player?.prepareToPlay()
    }

    /// One play from the top. A chime still sounding from a previous appearance is restarted,
    /// never layered.
    func play() {
        guard let player else { logger.error("Launch chime: play() with no player"); return }
        player.currentTime = 0
        let ok = player.play()
        if !ok { logger.error("Launch chime: play() returned false") }
    }
}

/// Applied to the ImmersiveSpace's content. When the space closes - by the Hide button,
/// the Digital Crown, or the system - reopen the launch window if it is not already open.
struct ReopenLaunchWindowOnExit: ViewModifier {
    /// Passed in rather than read from the environment: this modifier sits outside the
    /// `.environment(appModel)` that ImmersiveView receives.
    let appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onDisappear {
            if !appModel.isLaunchWindowOpen {
                openWindow(id: appModel.launchWindowID)
            }
        }
    }
}
