# Quran Spatial

An Apple Vision Pro app that presents Surah Ar-Rahman as a spatial recitation: the Arabic text of
the surah, shaped through Core Text, placed in an immersive night pavilion, with a shader dissolve
between ayat and a dua posture (both hands raised) as the way the recitation begins. An English
companion, "Ask", pauses the recitation on the current ayah, pins it, shows its English translation
and the meaning of the ayah, and resumes where the reciter left off.

Built with Swift, SwiftUI, RealityKit, ARKit and Core Text, against the visionOS 27 SDK with a
deployment target of 26.5. Part of the AI Challenge Serving Islamic Content.

## This snapshot is the baseline

This repository holds the project's **baseline as of 3 October 2026**, the state before any
challenge work began. It was committed on **4 October 2026** and is tagged `baseline-2026-10-03`.
What it contains, what was and was not verified on the headset, and the rights status of every
component are recorded in [docs/baseline-disclosure.md](docs/baseline-disclosure.md). Read that
file before anything else in `docs/`.

In the baseline, "Ask" is a lookup only: no speech, no question, no model, no network. Voice
questions and every model step are challenge work and are not in this snapshot.

## Assets that are local-only, and why

The following are **not in this repository**. The app runs without them, degrading in the way each
component's notes describe, and a build for anyone else is made by not having them.

| asset | why it is not published |
| --- | --- |
| Recitation audio (`rahman-single.mp3`) | a third-party performance with no licence or permission on record; an open ship blocker |
| Environment assets (`.usdz`, `.usdc`) | provenance and terms not yet recorded |
| English translation (Saheeh International, Quranpedia book 1947, `en-rahman-saheeh-1947.json`) | no licence notice in the file; local builds only |
| Meaning text (Al-Mukhtasar fi Tafsir al-Quran, English, Quranpedia book 27824, `en-rahman-mukhtasar-27824.json`) | no licence notice in the file; local builds only |
| Hand-tracking captures (`capture/*.json`) | the author's own hand and head tracking data |

What **is** here: all source, the tests, the Reality Composer Pro materials, the Quran text from the
Tanzil Project (verbatim, CC BY 3.0, attribution in the app and in the JSON), the Amiri Quran font
under the SIL Open Font License with its `OFL.txt`, the ayah timings and the pre-roll table, and
the `docs/` folder with the plans, reports and device measurements.

## History

The private development history before the challenge is not published. This snapshot is a single
commit whose tree corresponds to private commit `ff5bec67d719543b89ff755b8191cd7867ee1d9a` (tag `baseline-2026-10-03` in the
private repository), minus the local-only assets listed above.
