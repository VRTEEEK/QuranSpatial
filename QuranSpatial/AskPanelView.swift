//
//  AskPanelView.swift
//  QuranSpatial
//
//  The Ask panel (challenge day 2), beside the Quran text, never over it. Phases: listening
//  (with Done), the transcript while the engine works, then the decision, the optional verified
//  lead, and the verbatim passages with their source lines. Continue resumes the recitation.
//  Replaces the baseline MeaningPanelView; an empty question still shows the ayah's passages.
//

import SwiftUI

struct AskPanelView: View {
    var session: AskSession
    var segmentIndex: Int
    var onDone: () -> Void
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(segmentIndex > 0 ? "Ask · Ayah \(segmentIndex)" : "Ask")
                .font(.headline)

            switch session.phase {
            case .idle:
                Text("…").foregroundStyle(.secondary)
            case .listening:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Listening…").font(.body)
                }
                if !session.speech.partialTranscript.isEmpty {
                    Text(session.speech.partialTranscript).font(.callout).foregroundStyle(.secondary)
                }
                Text("Ask about this ayah, then pause. Stops after 1.5 s of silence.")
                    .font(.caption).foregroundStyle(.secondary)
            case .thinking(let transcript):
                if !transcript.isEmpty { Text("“\(transcript)”").font(.callout) }
                HStack(spacing: 10) { ProgressView(); Text("Looking it up…") }
            case .answered(let display):
                if !display.question.isEmpty { Text("“\(display.question)”").font(.callout).foregroundStyle(.secondary) }
                Text(Self.decisionLabel(display.decision)).font(.subheadline.weight(.semibold))
                if !display.lead.isEmpty { Text(display.lead).font(.body) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(display.passages) { p in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.text).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                                Text("— \(p.sourceLine)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if !display.note.isEmpty { Text(display.note).font(.callout).foregroundStyle(.secondary) }
                    }
                }
                .frame(maxHeight: 380)
                if !display.engineNotice.isEmpty { Text(display.engineNotice).font(.caption2).foregroundStyle(.tertiary) }
            case .failed(let message):
                Text(message).font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                if !session.engineStatus.isEmpty, session.phase == .listening {
                    Text(session.engineStatus).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                if session.phase == .listening {
                    Button("Done", action: onDone).buttonStyle(.bordered)
                }
                Button("Continue", action: onContinue).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
        .glassBackgroundEffect()
    }

    static func decisionLabel(_ decision: String) -> String {
        switch decision {
        case "answered": return "From the sources"
        case "answered-in-part": return "From the sources, in part"
        case "referred": return "Referred to a scholar"
        case "declined": return "Not about this ayah"
        default: return decision
        }
    }
}
