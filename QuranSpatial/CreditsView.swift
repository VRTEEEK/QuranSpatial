//
//  CreditsView.swift
//  QuranSpatial
//
//  Attribution surface. This exists to satisfy the Tanzil Project's terms of use, which
//  are not satisfied by a field in a JSON file the wearer never sees.
//
//  Verified against tanzil.net/download/ on 2026-09-04, the terms are:
//
//    "Permission is granted to copy and distribute verbatim copies of the Quran text
//     provided here, but changing the text is not allowed. The text can be used in any
//     website or application, provided that its source (Tanzil Project) is clearly
//     indicated, and a link is made to tanzil.net to enable users to keep track of
//     changes."
//
//  So this view must do three things and does: name the Tanzil Project as the source of
//  the Quran text, carry a LIVE link to tanzil.net, and reproduce the copyright notice
//  that the downloaded file requires to travel with verbatim copies.
//

import SwiftUI

struct CreditsView: View {

    private let textFile = try? JSONDecoder().decode(
        RecitationTextFile.self,
        from: Data(contentsOf: Bundle.main.url(forResource: "ar-rahman-text", withExtension: "json")!)
    )

    /// Present only in local builds that carry the (unlicensed, undistributed) translation
    /// file. Its absence removes the section; nothing is claimed for a build without it.
    private let translation = RecitationTranslationFile.loadIfPresent()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Credits")
                    .font(.largeTitle)

                section("Quran text") {
                    Text(textFile?.source ?? "Tanzil Quran Text (Uthmani), Tanzil Project")
                    Link("tanzil.net", destination: URL(string: "https://tanzil.net/")!)
                        .font(.body.weight(.semibold))
                    Text("The text is reproduced verbatim and is never modified. "
                         + "Follow the link above to keep track of changes to the text.")
                        .foregroundStyle(.secondary)
                    if let notice = textFile?.copyright {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let license = textFile?.license {
                        Text("Licence: \(license)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                section("Recitation") {
                    Text("Qari Ismail Nouri")
                    Text("Published as “Garden of Verses”.")
                        .foregroundStyle(.secondary)
                    Text("Licensing for this recording is unresolved. See CLAUDE.md — it is "
                         + "an open ship blocker and this credit is provisional.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if translation != nil {
                    section("English translation") {
                        Text("English translation: Saheeh International (via Quranpedia)")
                    }
                }

                section("Typeface") {
                    Text("Amiri Quran")
                    Text("Copyright 2010–2022 The Amiri Project Authors.")
                        .foregroundStyle(.secondary)
                    Link("github.com/aliftype/amiri",
                         destination: URL(string: "https://github.com/aliftype/amiri")!)
                        .font(.body.weight(.semibold))
                    Text("This Font Software is licensed under the SIL Open Font License, "
                         + "Version 1.1. The licence is available with a FAQ at "
                         + "openfontlicense.org, and the full text ships with this app as "
                         + "OFL.txt.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link("openfontlicense.org",
                         destination: URL(string: "https://openfontlicense.org")!)
                        .font(.footnote)
                    // Amiri's copyright statement names no Reserved Font Name, so the RFN
                    // clause of the OFL does not bite here. The constraints that do: the
                    // font may not be sold on its own, and any modified version must stay
                    // under the OFL. We ship it unmodified.
                    Text("No Reserved Font Name is declared. The font is bundled unmodified; "
                         + "under the OFL it may not be sold by itself, and any modified "
                         + "version must remain under the same licence.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            content()
        }
    }
}
