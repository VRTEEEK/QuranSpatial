//
//  AskPanelView.swift
//  QuranSpatial
//
//  The Ask panel (challenge day 2; presentation redesigned 2026-10-05 per the Ask directive,
//  its listening addendum, and the "real visionOS glass" visual fix the same night). It
//  follows the approved reference for the listening state: a wide piece of floating glass
//  with the environment visible through it, a glass mic badge at the left, "Ask · Ayah N"
//  and the question in large type beside it, a hero waveform across the middle, the status
//  bottom-left and a glass capsule bottom-right. One surface, never over the Quran text.
//  Content cross-fades between phases; the panel never disappears and respawns, and its
//  height follows its content rather than reserving space.
//
//  MATERIAL. The glass is the system's `glassBackgroundEffect` and NOTHING is filled behind
//  or over it: no dark rectangle, no black, no grey. Layers, back to front: the environment
//  (through the glass) · the system glass · a faint warm tint gradient · a 1 pt edge whose
//  gold catches at two corners and fades elsewhere, with a restrained bloom · the content.
//
//  DATA HONESTY, non-negotiable: the lead is always labelled as an on-device AI summary and
//  never looks like Quran text or a source; passages are verbatim with their source line
//  directly beneath; the "AI-assisted, not a scholar" line is on every answered state;
//  `engineNotice` and `engineStatus` stay visible as diagnostics; links are selectable text,
//  not tappable. No Logger call or timing log lives here - those are AskSession's.
//

import SwiftUI

struct AskPanelView: View {
    var session: AskSession
    var segmentIndex: Int
    var onDone: () -> Void
    /// Reads the answer aloud on Play; stopped by this view the moment the panel leaves
    /// `.answered`, and by the immersive view on every other exit (2026-10-06).
    var speaker: AskSpeaker
    var onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: Palette and metrics

    /// MATERIAL ISOLATION (directive 2026-10-05 night, step 14): with this `false`, the panel,
    /// badge and buttons are the system glass and their text/glyphs ONLY - no tint, no edge,
    /// no bloom, no inner glow - so the basic transparency can be judged on device before
    /// any decoration is restored. The decorations return one at a time by flipping it.
    static let showDecorations = true   // badge glow, button edges: restored 2026-10-06
    /// Restored first, alone (2026-10-06): the 1 pt edge on the panel body.
    static let showEdge = true

    /// THE BODY MATERIAL. `.frosted` is the system `glassBackgroundEffect`: on device it is
    /// neutral but hides the scene - a column behind it is not recognisable (isolation test,
    /// 2026-10-05 night). `.smoked` is a clear dark tint with no blur, the only construction
    /// on visionOS 26 (no clear-glass variant exists in the SDK) through which the columns,
    /// mountains and stars stay identifiable. Readability then comes from ivory text with a
    /// soft shadow, never from making the body opaque.
    /// `.smokedBlur` (2026-10-06, "transparent, needs a little blur"): a system material
    /// UNDER the same smoke, so the scene softens without disappearing. Ultra-thin passed the
    /// whole acceptance list but wanted more blur; thin is the next grade.
    enum BodyMaterial { case frosted, smoked, smokedBlur }
    static let bodyMaterial: BodyMaterial = .smokedBlur
    /// The smoke: near-black navy. 0.26 was "too transparent" and weak over lanterns on
    /// device (2026-10-05); 0.40 keeps the scene recognisable while giving the text a floor.
    static let smoke = Color(red: 0.02, green: 0.04, blue: 0.09).opacity(0.76)   // 0.40, 0.52 and 0.64 were each "darker" on device, 2026-10-06

    static let gold = Color(red: 0.93, green: 0.78, blue: 0.50)
    static let amber = Color(red: 0.98, green: 0.72, blue: 0.38)
    static let ivory = Color(red: 0.98, green: 0.95, blue: 0.88)
    /// 1280 pt: 1.45x the previous 880. At the attachment's 1360 pt/m that is 0.94 m, which
    /// subtends 26.5° at the 2.0 m it is placed at.
    static let panelWidth: CGFloat = 1280
    /// The answer body scrolls only past this; shorter content takes only what it needs.
    static let contentMaxHeight: CGFloat = 560
    private static let cornerRadius: CGFloat = 56
    private static let padding: CGFloat = 64

    // Type: the question is the LARGEST element; serif only where it stays readable at
    // distance (title, question, status, buttons); sans for the small secondary lines.
    private static let titleSize: CGFloat = 40
    private static let questionSize: CGFloat = 52
    private static let statusSize: CGFloat = 32
    private static let secondarySize: CGFloat = 24
    private static let bodySize: CGFloat = 28
    private static let sourceSize: CGFloat = 21
    static let buttonSize: CGFloat = 30
    private static let badgeSize: CGFloat = 132

    /// The detector (or Cancel) has stopped the capture but the recogniser has not finalised,
    /// so AskSession is still in `.listening` (2026-10-06). UI ONLY: the panel shows the
    /// thinking look from this moment rather than from the final transcript, which arrives
    /// seconds later on the SpeechAnalyzer path. AskSession's phases are untouched.
    private var speechStopped: Bool {
        guard case .listening = session.phase else { return false }
        switch session.speech.state {
        case .finishing, .finished: return true
        default: return false
        }
    }
    private var isListening: Bool { if case .listening = session.phase { return !speechStopped }; return false }
    private var isThinking: Bool { if case .thinking = session.phase { return true }; return speechStopped }
    private var showsWaveform: Bool { isListening || isThinking }

    /// Drives the cross-fade: changes on every phase transition, not on partial text.
    private var phaseKey: Int {
        switch session.phase {
        case .idle: return 0
        case .listening: return speechStopped ? 2 : 1
        case .thinking: return 2
        case .answered: return 3
        case .failed: return 4
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            header
            content
                .id(phaseKey)
                .transition(.opacity)
            footer
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .easeInOut(duration: 0.4), value: phaseKey)
        .padding(Self.padding)
        .frame(width: Self.panelWidth)
        .modifier(AskGlassBody(shape: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)))
        .overlay {
            if Self.showEdge {
                // Light catching the edge of glass: 1 pt, bright at the top-left and
                // bottom-right corners, fading between, with a restrained bloom. No tint
                // over the body - the earlier amber gradient here is what read as beige.
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(Self.edgeGradient, lineWidth: 1)
                    .shadow(color: Self.amber.opacity(0.28), radius: 8)
                    .allowsHitTesting(false)
            }
        }
    }

    private static var edgeGradient: AngularGradient {
        AngularGradient(
            stops: [
                .init(color: gold.opacity(0.95), location: 0.00),   // top-left corner region
                .init(color: gold.opacity(0.25), location: 0.18),
                .init(color: gold.opacity(0.10), location: 0.40),
                .init(color: gold.opacity(0.85), location: 0.55),   // bottom-right
                .init(color: gold.opacity(0.22), location: 0.75),
                .init(color: gold.opacity(0.95), location: 1.00),
            ],
            center: .center, angle: .degrees(-135))
    }

    // MARK: Header - every state

    private var header: some View {
        HStack(alignment: .center, spacing: 40) {
            AskGlassBadge(symbol: showsWaveform ? "mic" : "sparkle", size: Self.badgeSize)
            VStack(alignment: .leading, spacing: 14) {
                Text(segmentIndex > 0 ? "Ask · Ayah \(segmentIndex)" : "Ask")
                    .font(.system(size: Self.titleSize, weight: .regular, design: .serif))
                    .foregroundStyle(Self.ivory.opacity(0.9))
                    .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                if let question = headerQuestion, !question.isEmpty {
                    Text("“\(question)”")
                        .font(.system(size: Self.questionSize, weight: .regular, design: .serif))
                        .foregroundStyle(Self.ivory)
                        .shadow(color: .black.opacity(0.7), radius: 5, y: 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Listening: the live partial transcript, replaced by the final transcript the moment it
    /// arrives. Thinking and answered: the question. Nothing when there is nothing - never
    /// empty quotes.
    private var headerQuestion: String? {
        switch session.phase {
        case .listening:
            if case .finished(let transcript, _) = session.speech.state { return transcript }
            return session.speech.partialTranscript
        case .thinking(let transcript): return transcript
        case .answered(let display): return display.question
        case .idle, .failed: return nil
        }
    }

    // MARK: Content by phase

    private var waveformWidth: CGFloat { (Self.panelWidth - 2 * Self.padding) * 0.78 }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .idle:
            EmptyView()

        case .listening where speechStopped:
            thinkingContent

        case .listening:
            VStack(alignment: .leading, spacing: 30) {
                AskWaveformView(speech: session.speech, mode: .live, reduceMotion: reduceMotion)
                    .frame(width: waveformWidth, height: 220)
                    .frame(maxWidth: .infinity)
                statusLines(primary: "Listening…", secondary: "Speak in English", showBreathing: true)
            }

        case .thinking:
            thinkingContent

        case .answered(let display):
            answered(display)

        case .failed(let message):
            // Neutral. Currently unreachable: AskSession never assigns .failed.
            statusLines(primary: "Something went wrong", secondary: message, showBreathing: false)
        }
    }

    private func statusLines(primary: String, secondary: String?, showBreathing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                if showBreathing { BreathingDot(static: reduceMotion) }
                Text(primary)
                    .font(.system(size: Self.statusSize, weight: .regular, design: .serif))
                    .foregroundStyle(Self.ivory)
            }
            if let secondary, !secondary.isEmpty {
                Text(secondary)
                    .font(.system(size: Self.secondarySize))
                    .foregroundStyle(Self.ivory.opacity(0.62))
                    .padding(.leading, showBreathing ? 26 : 0)
            }
        }
    }

    // MARK: Answered, by decision

    private func answered(_ display: AskDisplay) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(Self.decisionLabel(display.decision))
                .font(.system(size: Self.statusSize, weight: .regular, design: .serif))
                .foregroundStyle(Self.ivory)

            // Sized to its content up to the cap; only past the cap does it scroll. One
            // ScrollView, inside the content; header and buttons stay outside it.
            ViewThatFits(in: .vertical) {
                answerBody(display)
                ScrollView(.vertical) { answerBody(display) }
            }
            .frame(maxHeight: Self.contentMaxHeight)

            Rectangle().fill(Self.gold.opacity(0.4)).frame(height: 1)   // the one divider

            VStack(alignment: .leading, spacing: 6) {
                if !display.engineNotice.isEmpty {
                    Text(display.engineNotice).font(.system(size: 17)).foregroundStyle(Self.ivory.opacity(0.45))
                }
                if !session.engineStatus.isEmpty {
                    Text(session.engineStatus).font(.system(size: 17)).foregroundStyle(Self.ivory.opacity(0.45))
                }
                Text("Ask is AI-assisted and is not a scholar. Every passage is quoted from the source named under it.")
                    .font(.system(size: 19)).foregroundStyle(Self.ivory.opacity(0.6))
            }
        }
    }

    private func answerBody(_ display: AskDisplay) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            switch display.decision {
            case "answered", "answered-in-part":
                if !display.lead.isEmpty { leadBlock(display.lead) }
                passages(display.passages)
                if !display.note.isEmpty { note(display.note) }

            case "referred":
                // Referred WITH passages used to show the engine's note, a section label and
                // the passages, and read as two answers (Mohamed, 2026-10-06). Now one line in
                // the note's position, then the passages directly. Display-only: the engine's
                // personalNote is untouched in AskCore; the bare referral is unchanged.
                let referralNote = Self.referralNote(engineNote: display.note, hasPassages: !display.passages.isEmpty)
                if !referralNote.isEmpty { note(referralNote) }
                passages(display.passages)

            case "not-covered", "declined":
                if !display.note.isEmpty { note(display.note) }

            default:
                if !display.lead.isEmpty { leadBlock(display.lead) }
                passages(display.passages)
                if !display.note.isEmpty { note(display.note) }
            }

            if !display.links.isEmpty {
                sectionLabel("Further reading")
                ForEach(display.links, id: \.self) { link in
                    Text(link)
                        .font(.system(size: Self.sourceSize))
                        .foregroundStyle(Self.ivory.opacity(0.62))
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The thinking look: shown from the moment the capture stops (see `speechStopped`) and
    /// through AskSession's `.thinking`, so the recogniser's finalisation is not shown as
    /// more listening.
    private var thinkingContent: some View {
        VStack(alignment: .leading, spacing: 30) {
            AskWaveformView(speech: session.speech, mode: .processing, reduceMotion: reduceMotion)
                .frame(width: waveformWidth, height: 220)
                .frame(maxWidth: .infinity)
            statusLines(primary: "Looking it up…", secondary: "Searching this app's sources…", showBreathing: false)
        }
    }

    /// The lead, always under its AI label, in a quiet glass inset so it cannot be read as a
    /// quoted source. Never titled "Answer" or "Meaning".
    private func leadBlock(_ lead: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On-device AI summary, checked against the passages below")
                .font(.system(size: Self.sourceSize)).foregroundStyle(Self.ivory.opacity(0.62))
            Text(lead).font(.system(size: Self.bodySize)).foregroundStyle(Self.ivory)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Self.gold.opacity(0.3), lineWidth: 1))
    }

    /// Verbatim passages, each with its source line attached directly beneath it.
    private func passages(_ lines: [AskDisplay.Line]) -> some View {
        ForEach(lines) { p in
            VStack(alignment: .leading, spacing: 8) {
                Text(p.text).font(.system(size: Self.bodySize)).foregroundStyle(Self.ivory)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("— \(p.sourceLine)").font(.system(size: Self.sourceSize)).foregroundStyle(Self.ivory.opacity(0.62))
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: Self.bodySize)).foregroundStyle(Self.ivory.opacity(0.92))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: Self.secondarySize)).foregroundStyle(Self.ivory.opacity(0.62))
    }

    // MARK: Footer - the controls, bottom-right as in the reference

    private var footer: some View {
        HStack(spacing: 20) {
            Spacer(minLength: 0)
            if isListening && session.speech.isStalled {
                // Safety net, not a control (step 6, 2026-10-06): appears only once listening
                // has run 6 s past the last heard speech with no stop. Cancel is the exit.
                Button("Done", action: onDone).buttonStyle(AskGlassPillStyle(prominence: .secondary))
            }
            if showsWaveform {
                Button(isListening ? "Cancel" : "Back to recitation", action: onContinue)
                    .buttonStyle(AskGlassPillStyle(prominence: .primary))
            } else {
                if case .answered(let display) = session.phase {
                    // Read aloud: one Play/Pause capsule, and a quiet Stop while speaking or
                    // paused. Nothing speaks until Play is pressed.
                    if speaker.state != .idle {
                        Button("Stop") { speaker.stop() }
                            .buttonStyle(AskGlassPillStyle(prominence: .secondary))
                            .accessibilityLabel("Stop reading")
                    }
                    Button {
                        if speaker.state == .speaking {
                            speaker.pause()
                        } else {
                            speaker.play(display: display,
                                         referralNote: Self.referralNote(engineNote: display.note,
                                                                         hasPassages: !display.passages.isEmpty))
                        }
                    } label: {
                        Image(systemName: speaker.state == .speaking ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(AskGlassPillStyle(prominence: .secondary))
                    .accessibilityLabel(speaker.state == .speaking ? "Pause reading" : "Read aloud")
                }
                Button("Continue", action: onContinue).buttonStyle(AskGlassPillStyle(prominence: .primary))
            }
        }
        .onChange(of: phaseKey) {
            // Any move off the answer silences it; the immersive view covers the other exits.
            if case .answered = session.phase {} else { speaker.stop() }
        }
    }

    // MARK: Labels (tested)

    /// The note shown under "Referred to a scholar". With passages, ONE fixed line replaces
    /// the engine's note and the former section label; without them, the engine's note as is.
    static let referredWithPassagesNote =
        "The Quran's general position is below. Your own situation is a question for a scholar."

    static func referralNote(engineNote: String, hasPassages: Bool) -> String {
        hasPassages ? referredWithPassagesNote : engineNote
    }

    static func decisionLabel(_ decision: String, hasPassages: Bool = false) -> String {
        switch decision {
        case "answered": return "From the sources"
        case "answered-in-part": return "From the sources, in part"
        case "referred": return "Referred to a scholar"
        case "declined": return "Not about this ayah"
        case "not-covered": return "Not covered by this app's sources"
        default: return decision
        }
    }
}

/// A small piece of illuminated optical glass: system glass in a circle, a soft warm glow
/// inside it, a thin gold edge, the symbol in ivory. Responds to gaze with the system hover.
struct AskGlassBadge: View {
    var symbol: String
    var size: CGFloat

    var body: some View {
        ZStack {
            if AskPanelView.showDecorations {
                // Internal warm illumination, strongest just off-centre.
                Circle()
                    .fill(RadialGradient(colors: [AskPanelView.amber.opacity(0.30), AskPanelView.amber.opacity(0.08), .clear],
                                         center: .init(x: 0.42, y: 0.38), startRadius: 0, endRadius: size * 0.6))
            }
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .regular))
                .foregroundStyle(AskPanelView.ivory)
                .shadow(color: AskPanelView.amber.opacity(AskPanelView.showDecorations ? 0.6 : 0), radius: 10)
        }
        .frame(width: size, height: size)
        .modifier(AskGlassBody(shape: Circle()))
        .overlay {
            if AskPanelView.showDecorations {
                Circle().strokeBorder(AskPanelView.gold.opacity(0.75), lineWidth: 1)
                    .shadow(color: AskPanelView.amber.opacity(0.35), radius: 6)
            }
        }
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.highlight)
        .accessibilityHidden(true)
    }
}

/// Glass capsule control: system glass, thin warm edge, ivory text, system hover. Primary
/// and secondary differ in edge strength and text weight only - no solid fills.
struct AskGlassPillStyle: ButtonStyle {
    enum Prominence { case primary, secondary }
    var prominence: Prominence

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: AskPanelView.buttonSize, weight: .regular, design: .serif))
            .foregroundStyle(AskPanelView.ivory.opacity(prominence == .primary ? 1 : 0.7))
            .padding(.horizontal, prominence == .primary ? 48 : 36)
            .frame(height: 76)
            .modifier(AskGlassBody(shape: Capsule()))
            .overlay {
                if AskPanelView.showDecorations {
                    Capsule().strokeBorder(AskPanelView.gold.opacity(prominence == .primary ? 0.7 : 0.3), lineWidth: 1)
                }
            }
            .contentShape(.hoverEffect, Capsule())
            .contentShape(Capsule())
            .hoverEffect(.highlight)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// The small breathing indicator beside "Listening…": one shape, opacity and scale only.
/// Not a Siri orb. Static under Reduce Motion.
struct BreathingDot: View {
    var `static`: Bool = false
    @State private var on = false
    var body: some View {
        Circle()
            .fill(AskPanelView.amber)
            .frame(width: 12, height: 12)
            .shadow(color: AskPanelView.amber.opacity(0.7), radius: 6)
            .opacity(`static` ? 0.8 : (on ? 1 : 0.4))
            .scaleEffect(`static` ? 1 : (on ? 1.1 : 0.9))
            .onAppear {
                guard !`static` else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { on = true }
            }
            .accessibilityHidden(true)
    }
}

/// The one body material for the panel, the badge and the buttons: system frosted glass or
/// the clear smoked tint, by `AskPanelView.bodyMaterial`. Nothing else is ever filled over
/// or behind the body.
struct AskGlassBody<S: InsettableShape>: ViewModifier {
    var shape: S
    func body(content: Content) -> some View {
        switch AskPanelView.bodyMaterial {
        case .frosted:
            content.glassBackgroundEffect(in: shape)
        case .smoked:
            content.background(shape.fill(AskPanelView.smoke))
        case .smokedBlur:
            // Nearer background first (the smoke), the material behind it.
            content
                .background(shape.fill(AskPanelView.smoke))
                .background(shape.fill(.regularMaterial))   // ultra-thin then thin were "more blur" on device, 2026-10-06
        }
    }
}
