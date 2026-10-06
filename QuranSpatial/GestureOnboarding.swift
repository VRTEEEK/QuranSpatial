//
//  GestureOnboarding.swift
//  QuranSpatial
//
//  The 3 s hand-gesture onboarding card (directive 2026-10-06). One supplied transparent PNG
//  (`GestureOnboarding` image set) shown as a RealityView attachment inside the immersive
//  space - no window, no chrome, no background drawn behind it - placed once from the head
//  when the environment is rendering, held about 3 s, faded out and removed. Shown on EVERY
//  entry into the space (Mohamed, 2026-10-06) - the state is this view's, made afresh each
//  time the space opens.
//
//  PRESENTATION ONLY. The dua recognizer, the entry gate, the coordinator and Ask are not
//  touched. The card says what the app already does: dua to begin the recitation, gaze at
//  the Arabic and pinch to ask about an ayah.
//
//  Timing: 0.00-0.35 s fade and scale in (opacity 0 -> 1, scale 0.97 -> 1.0);
//          0.35-2.65 s fully visible; 2.65-3.00 s fade out; then the entity is removed.
//

import Observation
import SwiftUI

@MainActor
@Observable
final class GestureOnboarding {
    enum Phase: Equatable { case pending, showing, finished }

    static let fadeInSeconds: Double = 0.35
    static let holdUntilSeconds: Double = 2.65
    static let totalSeconds: Double = 3.0
    /// Points, for the whole image; the clipped body is about 85% of it. 1640 pt gives a
    /// body of ~1395 pt = 1.03 m at the attachment's 1360 pt/m, about 32° across at 1.8 m,
    /// the size that passed the readability check.
    static let widthPoints: CGFloat = 1640

    private(set) var phase: Phase = .pending
    /// Drives the view's opacity/scale; flipped on by `begin()` and off at 2.65 s.
    private(set) var isVisible = false
    private var timer: Task<Void, Never>?

    func begin() {
        guard phase == .pending else { return }
        phase = .showing
        isVisible = true
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.holdUntilSeconds))
            guard let self, !Task.isCancelled else { return }
            self.isVisible = false
            try? await Task.sleep(for: .seconds(Self.totalSeconds - Self.holdUntilSeconds))
            guard !Task.isCancelled else { return }
            self.phase = .finished
        }
    }
}

/// The card itself: the PNG as supplied inside, CLIPPED to a true rounded rectangle at the
/// card body's measured bounds, with one crisp gold edge and a uniform soft glow drawn on
/// top. The generated artwork's own frame wobbles and blurs ("edges not clean" on device,
/// 2026-10-06); the clip replaces that outer edge and nothing else - the glass, hands,
/// rings and text are the artwork's own pixels. Bounds measured on the mid-lines of the
/// 1672 x 941 image at alpha >= 128: insets left 129, top 86, right 124, bottom 59 px.
struct GestureOnboardingView: View {
    var onboarding: GestureOnboarding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let gold = Color(red: 0.95, green: 0.78, blue: 0.48)
    private static let amber = Color(red: 0.98, green: 0.72, blue: 0.38)
    // Fractions of the image's width and height outside the body, per edge.
    private static let insetL: CGFloat = 0.0772, insetR: CGFloat = 0.0742   // 129 and 124 px of 1672
    private static let insetT: CGFloat = 0.0914, insetB: CGFloat = 0.0627   // 86 and 59 px of 941
    private static let imageAspect: CGFloat = 1672.0 / 941.0
    private static let cornerRadius: CGFloat = 96   // ~100 px in the artwork, from the edge profile

    var body: some View {
        let imageWidth = GestureOnboarding.widthPoints
        let imageHeight = imageWidth / Self.imageAspect
        let bodyRect = CGRect(x: imageWidth * Self.insetL, y: imageHeight * Self.insetT,
                              width: imageWidth * (1 - Self.insetL - Self.insetR),
                              height: imageHeight * (1 - Self.insetT - Self.insetB))
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)

        Image("GestureOnboarding")
            .resizable()
            .frame(width: imageWidth, height: imageHeight)
            // Shift so the body's top-left sits at the origin, then size to the body and clip.
            .offset(x: -bodyRect.minX, y: -bodyRect.minY)
            .frame(width: bodyRect.width, height: bodyRect.height, alignment: .topLeading)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Self.gold.opacity(0.9), lineWidth: 1.5)
                    .shadow(color: Self.amber.opacity(0.55), radius: 10)
                    .shadow(color: Self.amber.opacity(0.25), radius: 26)
            }
            .opacity(onboarding.isVisible ? 1 : 0)
            .scaleEffect(onboarding.isVisible || reduceMotion ? 1.0 : 0.97)
            .animation(.easeInOut(duration: GestureOnboarding.fadeInSeconds), value: onboarding.isVisible)
            .allowsHitTesting(false)
            .accessibilityLabel("Hand gestures. Raise both hands open in a natural dua position and hold to begin the recitation. Look at the Arabic text and pinch to ask about an ayah.")
    }
}
