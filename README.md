# Quran Spatial

An Apple Vision Pro app that presents **Surah Ar-Rahman** as an immersive spatial experience:
the Arabic text floats in a night pavilion, shaped by Core Text in the Amiri Quran typeface; a
dua posture (both hands raised) begins the recitation; each ayah dissolves into the next with a
shader effect; and **Ask** lets the wearer look at an ayah, pinch, and ask a question in English,
answered only from verbatim, cited sources - never from the model's own words.

Built by Mohamed at [VRTEEK](https://vrteek.com), a digital heritage and spatial computing studio. App Store target: 3 November 2026.

> **Challenge entry.** This repository is the public mirror of the entry to the
> *AI Challenge Serving Islamic Content* (تحدي الذكاء الاصطناعي في خدمة المحتوى الإسلامي), track 3.
> Start with **[docs/challenge/README-for-judges.md](docs/challenge/README-for-judges.md)** - what
> Ask does, the integrity rules, how to run it on a Mac, and the evaluation numbers. The day-by-day
> log is in `docs/challenge/day-*.md`; sources and licences in
> [docs/challenge/sources-tools-licences.md](docs/challenge/sources-tools-licences.md).

## The experience

| | |
| --- | --- |
| **Text** | All 78 ayat plus the basmala, laid out with Core Text at a fixed 3° em size. No `Text` views, no `NSAttributedString` fallbacks: default renderers mis-shape Arabic. |
| **Entry** | A dua posture recognizer (five gates with hysteresis, 1.5 s commit) is the only way to start the recitation. It is tuned to prefer a missed gesture over an unbidden one. A 3 s onboarding card shows the gesture on every entry. |
| **Recitation** | One continuous audio file with a timings file; `AVFoundation` boundary observers advance the ayah. A quiet ambient bed plays underneath and ducks to silence during an Ask. |
| **Dissolve** | A RealityKit ShaderGraph material; the primary transition between ayat. |
| **Ask** | Pinch on an ayah -> recitation pauses -> speak a question (listening ends on silence) -> a panel shows a decision, the verbatim passages with their source lines, and an optional one-line lead that a deterministic verifier has checked. Play reads the answer aloud on device. Rulings and personal situations are referred to a scholar before any model runs. |

Everything runs on the headset. No network, no accounts, no ads, no in-app purchases.

## Integrity rules

These are enforced in code and tests, not just stated:

1. **The model never produces Quran text, translation or tafsir.** Its two jobs are to pick a
   route (an enum) and to write a short lead that is dropped if it contains Arabic, an ayah
   number that was not retrieved, more than two sentences, or words not found in the passages.
2. **Every answer cites passages actually retrieved, or refers the question, or declines.**
   An answer with no passage behind it cannot be produced.
3. **Source texts are never typed into the repository** and never normalised: the Tanzil corpus
   is checked byte-for-byte (`isByteIdentical`), and the English sources are re-extracted from
   pinned downloads by `tools/fetch-sources.py` with deletion-only rules.

## What is *not* in this repository

The public mirror is produced by `tools/sync-public.sh`, which exports the private HEAD minus a
never-public list and aborts if any passage of the local source texts would be copied. Left out,
with the reasons recorded in [docs/baseline-disclosure.md](docs/baseline-disclosure.md):

- the recitation audio (`rahman-single.mp3`) - licence unresolved, an open ship blocker;
- the English translation, footnotes, tafsir and Jamhara files (`Resources/en-*.json`) - held
  locally until permission is documented; `tools/fetch-sources.py` rebuilds them;
- the environment assets (`*.usdz`, `*.usdc`), the ambience loop and the launch chime -
  provenance not recorded;
- the day-5 evaluation transcripts and prompts, which quote those texts;
- the author's raw hand-tracking captures.

The app builds and runs without them: missing audio is logged and silent, and the Ask cards
that need a missing source answer "not covered".

## Building

- **Xcode 27 beta** (visionOS 27 SDK), deployment target **visionOS 26.5**, a physical Apple
  Vision Pro for anything involving hands. Open `QuranSpatial.xcodeproj`, scheme `QuranSpatial`.
- The Ask engine is a Swift package, **`Packages/AskCore`**, with a command-line harness:

  ```bash
  python3 tools/fetch-sources.py        # fetch + verify the English sources (macOS 26, Xcode 26+)
  cd Packages/AskCore
  swift run qs-ask --ayah 13 "why does this repeat?"
  swift test --skip EvalTests           # unit tests, seconds, no model
  ```

  The full set of commands and the eval procedure are in the judges README.

## Repository map

```
QuranSpatial/            the visionOS app (SwiftUI + RealityKit + ARKit + Core Text)
QuranSpatial/Fonts/      Amiri Quran (SIL OFL 1.1) - the ship font
QuranSpatial/Resources/  timings, text index, Ask cards; the never-public files live here locally
QuranSpatialTests/       app tests (typography, gesture, dissolve, Ask UI, audio)
Packages/AskCore/        the Ask engine, its tests and the qs-ask CLI
tests/eval/              question sets and recorded runs (practice, held-out, annex)
tools/                   source fetcher, eval checker, public-sync script and its guard tests
docs/challenge/          judges README, daily log, held-out procedure, sources and licences
docs/baseline-disclosure.md   what the 3 October baseline contained and what is local-only
docs/measurements/       device reports (frame stats, memory, environment reviews)
design/                  app icon sources
```

## Licences

- Source code: © VRTEEK 2026, all rights reserved. No open-source licence has been chosen yet.
- Amiri Quran typeface: SIL Open Font License 1.1 (`QuranSpatial/Fonts/`).
- Quran text: Tanzil project, used unmodified under its terms.
- English translation (Saheeh International, via Quranpedia), Al-Mukhtasar tafsir, Jamhara
  terms: used locally for development only; see `docs/challenge/sources-tools-licences.md`.
