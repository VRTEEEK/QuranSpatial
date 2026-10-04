//
//  MeaningPanelView.swift
//  QuranSpatial
//
//  The "Meaning" panel (2026-10-03): a RealityView attachment shown BESIDE the Quran text,
//  never over it, while the phase is `asking`. It shows the Mukhtasar passage for the pinned
//  ayah verbatim, the source line, and a Continue button that ends the Ask. No AI anywhere
//  in it - it is a lookup. The Arabic and the English translation layer are untouched.
//

import SwiftUI

struct MeaningPanelView: View {
    /// The pinned segment index (ayah number; 0 would be the intro, where Ask is refused).
    var segmentIndex: Int
    /// The passage, or nil when the file is absent or has no entry for this segment.
    var passage: String?
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(segmentIndex > 0 ? "Meaning · Ayah \(segmentIndex)" : "Meaning")
                .font(.headline)

            ScrollView {
                Text(passage ?? RecitationMeaning.unavailableText)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.disabled)
            }
            .frame(maxHeight: 360)

            if passage != nil {
                Text(RecitationMeaning.sourceLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Continue", action: onContinue)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
        .frame(width: 460)
        .glassBackgroundEffect()
    }
}
