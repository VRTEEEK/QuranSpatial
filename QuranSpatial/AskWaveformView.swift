//
//  AskWaveformView.swift
//  QuranSpatial
//
//  The Ask panel's hero waveform (Ask addendum and the glass visual fix, 2026-10-05):
//  overlapping sine strands drawn in a Canvas at 30 fps, each as a wide amber glow stroke
//  under a thin ivory core. While LISTENING the amplitude follows the microphone RMS that
//  `AskSpeechSession.inputLevel` publishes - smoothed with an ~80 ms attack and ~300 ms
//  release, mapped so ordinary speech fills about 70% of the height and silence leaves a low
//  ripple. While PROCESSING the voice no longer drives it: it settles low and a slow pulse
//  travels along it. The amplitude tapers to zero at both ends.
//
//  This is the ONLY view that reads `inputLevel`, so the rest of the panel does not
//  re-render at the tap's ~12 Hz. No particles, no blur filter, no shader; strokes only.
//
//  Reduce Motion: a static line (no phase drift, no travelling pulse) whose opacity follows
//  the level.
//

import SwiftUI

struct AskWaveformView: View {

    enum Mode: Equatable {
        /// Amplitude follows the microphone.
        case live
        /// Settled low, with a slow pulse travelling across; not voice-driven.
        case processing
    }

    var speech: AskSpeechSession
    var mode: Mode
    var reduceMotion: Bool

    /// Per-frame smoothing state. A reference type so the Canvas can update it while
    /// drawing without invalidating the view.
    @State private var smoother = Smoother()

    static let frameInterval: Double = 1.0 / 30.0

    // Mapping from RMS to amplitude. `SilenceDetector.threshold` is 0.012; quiet rooms sit
    // around 0.002-0.005 and ordinary speech at this microphone around 0.03-0.08.
    private static let silenceFloor: Float = 0.004
    private static let speechFull: Float = 0.06
    private static let restingAmplitude: Float = 0.10      // the ripple in silence
    private static let speechAmplitude: Float = 0.72       // normal speech, of half-height
    private static let processingAmplitude: Float = 0.12   // settled, under the pulse
    private static let pulseAmplitude: Float = 0.30        // the travelling pulse's peak
    private static let attackSeconds: Float = 0.08
    private static let releaseSeconds: Float = 0.30
    private static let settleSeconds: Float = 0.7

    private static let ivory = Color(red: 0.99, green: 0.95, blue: 0.86)
    private static let amber = Color(red: 0.98, green: 0.72, blue: 0.38)

    var body: some View {
        TimelineView(.animation(minimumInterval: Self.frameInterval, paused: false)) { timeline in
            // Reading `inputLevel` here is what ties this view, and only this view, to it.
            let level = mode == .live ? speech.inputLevel : 0
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let amplitude = smoother.step(level: level, mode: mode, now: now)
                let time = reduceMotion ? 0 : now
                let pulseCentre: Double? = (mode == .processing && !reduceMotion)
                    ? Self.pulseCentre(at: now) : nil
                Self.draw(in: &context, size: size, amplitude: amplitude, time: time,
                          pulseCentre: pulseCentre,
                          opacityScale: reduceMotion ? CGFloat(0.4 + 0.6 * amplitude) : 1)
            }
        }
        .accessibilityHidden(true)
    }

    /// Where the processing pulse is, 0...1 across the width, travelling left to right every
    /// 2.8 s with a pause off-screen between passes.
    private static func pulseCentre(at now: Double) -> Double {
        let period = 2.8
        let u = (now.truncatingRemainder(dividingBy: period)) / period   // 0..1
        return -0.2 + u * 1.4
    }

    // MARK: Drawing

    private struct Strand {
        let cycles: Double        // sine cycles across the width
        let speed: Double         // phase drift, radians per second
        let phase: Double
        let opacity: Double
        let coreWidth: CGFloat
        let amplitudeScale: Double
    }

    private static let strands: [Strand] = [
        Strand(cycles: 2.0, speed: 1.5, phase: 0.0, opacity: 1.0, coreWidth: 2.6, amplitudeScale: 1.0),
        Strand(cycles: 2.6, speed: -1.0, phase: 1.1, opacity: 0.6, coreWidth: 2.0, amplitudeScale: 0.78),
        Strand(cycles: 1.5, speed: 0.75, phase: 2.3, opacity: 0.42, coreWidth: 1.6, amplitudeScale: 0.6),
        Strand(cycles: 3.3, speed: 0.5, phase: 3.9, opacity: 0.25, coreWidth: 1.2, amplitudeScale: 0.45),
    ]

    private static func draw(in context: inout GraphicsContext, size: CGSize, amplitude: Float,
                             time: Double, pulseCentre: Double?, opacityScale: CGFloat) {
        let midY = size.height / 2
        let halfH = size.height / 2
        let width = size.width

        // The faint baseline under the strands, fading at both ends.
        var base = Path()
        base.move(to: CGPoint(x: 0, y: midY)); base.addLine(to: CGPoint(x: width, y: midY))
        context.stroke(base, with: .linearGradient(
            Gradient(colors: [.clear, amber.opacity(0.35 * opacityScale), .clear]),
            startPoint: CGPoint(x: 0, y: midY), endPoint: CGPoint(x: width, y: midY)), lineWidth: 1)

        let step: CGFloat = 3
        for strand in strands {
            var path = Path()
            var x: CGFloat = 0
            var first = true
            while x <= width {
                let u = Double(x / width)
                let taper = pow(sin(u * .pi), 1.3)                  // zero at both ends
                var local = Double(amplitude) * strand.amplitudeScale
                if let c = pulseCentre {
                    let d = (u - c) / 0.10
                    local += Double(pulseAmplitude) * strand.amplitudeScale * exp(-0.5 * d * d)
                }
                let angle = u * strand.cycles * 2 * .pi + strand.phase + time * strand.speed
                let y = midY - CGFloat(local * taper * sin(angle)) * halfH
                if first { path.move(to: CGPoint(x: x, y: y)); first = false } else { path.addLine(to: CGPoint(x: x, y: y)) }
                x += step
            }
            // Amber glow under an ivory core.
            // Two glow passes - wide and faint, then narrower and warmer - under the ivory core.
            context.stroke(path, with: .color(amber.opacity(0.18 * strand.opacity * opacityScale)),
                           style: StrokeStyle(lineWidth: strand.coreWidth * 9, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(amber.opacity(0.42 * strand.opacity * opacityScale)),
                           style: StrokeStyle(lineWidth: strand.coreWidth * 4, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(ivory.opacity(strand.opacity * opacityScale)),
                           style: StrokeStyle(lineWidth: strand.coreWidth, lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: Smoothing

    final class Smoother {
        private var amplitude: Float = AskWaveformView.restingAmplitude
        private var lastTime: Double?

        /// One step of attack/release smoothing toward the target for this mode. Returns the
        /// amplitude to draw, as a fraction of half-height.
        func step(level: Float, mode: Mode, now: Double) -> Float {
            let dt = Float(min(max(now - (lastTime ?? now), 0), 0.25))
            lastTime = now
            let target: Float
            switch mode {
            case .live:
                let norm = min(max((level - silenceFloor) / (speechFull - silenceFloor), 0), 1)
                target = restingAmplitude + (speechAmplitude - restingAmplitude) * norm
            case .processing:
                target = processingAmplitude
            }
            let tau: Float = mode == .processing ? settleSeconds
                : (target > amplitude ? attackSeconds : releaseSeconds)
            let k = dt <= 0 ? 1 : 1 - exp(-dt / tau)
            amplitude += (target - amplitude) * k
            return amplitude
        }
    }
}
