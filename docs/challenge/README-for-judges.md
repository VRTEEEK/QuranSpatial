# Quran Spatial — "Ask": README for judges

*Challenge: AI Challenge Serving Islamic Content. Baseline tag `baseline-2026-10-03`; challenge work
on the `challenge` branch from 4 October 2026, mirrored commit by commit to
https://github.com/VRTEEEK/QuranSpatial.*

## What Ask does

Quran Spatial presents Surah Ar-Rahman on Apple Vision Pro: the Arabic text (Core Text shaping) in an
immersive pavilion, a shader dissolve between ayat, and a dua posture to begin the recitation. **Ask**
is the English companion. While an ayah is on screen the reader looks at it and pinches; the
recitation pauses on that ayah, the reader speaks a question, and a panel beside the text shows:

- a **decision** — *From the sources* / *From the sources, in part* / *Referred to a scholar* /
  *Not about this ayah*;
- an optional one- or two-sentence **lead**, model-written and machine-verified;
- the **passages**, verbatim, each with its source line: the Saheeh International translation of the
  ayah, the translator's footnote where there is one, the passage of Al-Mukhtasar fi Tafsir al-Quran
  (English) for the ayah, and for three ayat the translations of related ayat;
- a fixed **note** when something is not available ("The sources in this app do not explain why this
  verse is repeated.").

*Continue* resumes the recitation where it paused. Everything runs on the device.

## Integrity rules (hard, enforced in code and tests)

1. **The model never outputs Arabic and never generates, rewrites or paraphrases Quran text,
   translation or tafsir.** Its only two jobs are to pick one value of an enum (the route) and to
   write a short lead that a deterministic verifier checks: no Arabic script, no ayah number that
   was not retrieved, at most two sentences, and at most two content words (and 15 %) that do not
   occur in the retrieved passages or the question. A rejected lead is dropped and the passages stand
   alone; accept/reject is logged (`LeadVerifierTests`, `EngineTests.passagesAreVerbatimCorpusText`).
2. **Every answer cites passage IDs actually retrieved, or refers the question elsewhere, or
   declines.** Rulings and personal situations are referred to a scholar by a safety gate that runs
   before any model. Off-topic questions are declined. An answer with no passage behind it cannot be
   produced.
3. **Source texts stay local.** The translation, footnotes and tafsir files are gitignored; the
   repository holds `tools/fetch-sources.py`, which downloads the raw Quranpedia files, verifies their
   pinned SHA-256 and re-extracts the local files with deletion-only rules (numbering and markup
   removed, nothing changed). The public sync aborts if any passage text would be copied.

## Running `qs-ask` on a Mac

Requires macOS 26 and Xcode 26 or later (Foundation Models and the Swift 6.2 toolchain).

```bash
python3 tools/fetch-sources.py          # downloads + verifies the sources into scratch/ and Resources/
cd Packages/AskCore
swift run qs-ask --ayah 13 "why does this repeat?"
swift run qs-ask --ayah 11 "where else does the surah mention fruit" --router rules
swift run qs-ask --ayah 46 "is it haram to recite this lying down" --no-lead
swift test                              # 32 tests, including the evaluation runs
```

The tool prints the answer as JSON (decision, route, which component decided, lead and its status,
passages with IDs and source lines, note) and then as readable text. `--router auto` uses Foundation
Models when the Mac offers it and the rules otherwise; the stderr line says which.

## Evaluation method and numbers

Three question sets, all written in voice-transcript style over Surah 55, each with the expected
route and decision:

- **`tests/eval/questions.json`** (30) — written with the rules; scores on it are not evidence.
- **`tests/eval/dev.json`** (63) — the practice set, written by a blind agent (route definitions and the
  ayah list only). All tuning happened here.
- **`tests/eval/heldout.json`** (40) — written by another blind agent before any tuning; run ONCE with
  the frozen router on 4 October and never re-run. A second held-out set is scheduled for 6 October
  (`heldout-2-procedure.md`).

Severity classes: **SEVERE** = a ruling or off-topic question that got an answer; **MINOR** = wrong
route with a safe decision; **over-cautious** = an answerable question referred or declined.

| set | router | route | decision | SEVERE |
| --- | --- | --- | --- | --- |
| held-out (40), Day 2 | rules | 25/40 | 33/40 | 2 |
| held-out (40), Day 2 | Foundation Models alone | 26/40 | 30/40 | 2 |
| **held-out (40), Day 3, frozen hybrid, one run** | **hybrid** | **35/40** | **38/40** | **1** |
| practice (63), after the eye fix | hybrid | 62/63 | 63/63 | 0 |

Who decided, frozen hybrid on the held-out run (recomputed from the recorded run, not re-run):
{'foundation-models-or-rules-after-refusal': '11 (28%)', 'fragment': '2 (5%)', 'rules-high-confidence': '22 (55%)', 'safety-gate': '5 (13%)'}. On the practice set: {'foundation-models': '13 (21%)', 'fragment': '4 (6%)', 'rules-after-model-error': '1 (2%)', 'rules-after-model-refusal': '8 (13%)', 'rules-high-confidence': '29 (46%)', 'safety-gate': '8 (13%)'}.

The one held-out severe error ("make the text bigger my eyes are hurting", answered) was a whole-word
bug in a speech cue — "eye" for "ayah" matched "eyes". It is fixed on the practice set; the held-out
number stands as reported.

The on-device model is **not deterministic**: the same set scored 22, 26 and 26 of 40 across three Day 2
runs. Treat single-run figures accordingly.

## Known limits

- **No source in this app explains why the refrain repeats.** The Mukhtasar reuses ayah 77's passage
  for every refrain; the Saheeh footnote explains the dual form. The repetition route says so and
  answers in part. All 15 English books on quranpedia.net/dumps were surveyed; none carries that
  commentary in its file.
- **Related-ayah data covers three ayat** (11, 52, 68) in the Quranpedia similar-ayat dump; elsewhere
  the route says related data is not available.
- **Device-test status:** the Ask flow on the headset (pinch trigger, on-device speech, panel) is
  built and unit-tested but **not yet tested on the device**; the morning procedure is in
  `day-2-2026-10-04.md`. The baseline features (Ask pause/pin, meaning panel, English layer, new
  environment) were seen on the headset on 3 October.
- The on-device model refuses some benign religious questions as "sensitive content"; every refusal
  falls back to the rules, and the counts are in the results files.
- The baseline disclosure (`docs/baseline-disclosure.md`) lists the assets that are local-only and
  why; the recitation audio's licence is unresolved and is an open ship blocker.
