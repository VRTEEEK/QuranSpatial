# Procedure: `tests/eval/heldout-2.json` on 6 October 2026

A second held-out set, produced by a third blind agent on 6 October, run ONCE on the final router,
never re-run and never tuned against. Nothing below may be started before 6 October.

## Who writes it

A fresh agent (Claude Code subagent or equivalent) that has NOT seen: the router code
(`Packages/AskCore/Sources/AskCore/*`), the model prompts, `questions.json`, `dev.json`, `heldout.json`,
any results file, or the day reports. Its instructions forbid reading any repository file. Its only
write is `tests/eval/heldout-2.json`. The spawning prompt is saved verbatim beside the file as
`tests/eval/heldout-2-prompt.md` so the isolation can be checked.

## What it is given — and nothing else

1. The seven route definitions, word for word as in `heldout-2-prompt.md` (same text given to the
   first two agents, plus the Day 3 ruling definition that includes personal situations).
2. The decision mapping: meaning/word/unclear → answered; repetition → answered-in-part; related →
   answered for ayat 11, 52, 68, otherwise answered-in-part; ruling → referred; off-topic → declined.
3. The 78 ayat of Surah 55 in the Saheeh International translation (the same list as before).

## Shape

- 50 questions: 14 meaning, 7 word, 6 repetition, 5 related (two on 11/52/68, three elsewhere),
  7 ruling (at least three personal situations), 7 off-topic (at least three about the headset, the
  app or the reader's body/eyes/comfort), 4 unclear.
- At least 30 distinct anchors, at least ten refrain ayat.
- Voice-transcript style: no punctuation, fillers, speech-recognition errors ("aya", "eye", "sura",
  "gin"), indirect phrasings, at least a third with no keyword. No quote longer than four consecutive
  words of a translation line. No Arabic script.
- Format identical to `heldout.json`, ids `k01`–`k50`.

## Before the run — checks that do not look at the questions' content

`tools/check-eval-set.py` (to be written on 5 October, deterministic): counts per route, distinct
anchors, decision mapping, 5-gram overlap with the source texts (must be zero), Arabic script (none).
If it fails, the agent is asked to fix shape only; its questions are not edited by hand.

## The run — once

1. Freeze: the router commit is named in the day report before the run; no source change after it.
2. `cd Packages/AskCore && ASKCORE_HELDOUT2_FINAL=1 swift test --filter heldout2FinalOnce`
   (a test to be added on 5 October, mirroring `heldoutFinalHybridOnce`, writing
   `results-heldout-2-final-hybrid(...).json` with attribution).
3. Report route, decision, SEVERE, over-cautious, per route, who decided — next to heldout.json's
   35/40, 38/40, 1 SEVERE and the Day 2 numbers.
4. Every miss is listed with its cause if known. Fixes go to dev.json only; heldout-2 is then spent.

## Why a second set

heldout.json was spent on 4 October: its one severe error was diagnosed and fixed on the practice set,
so it can no longer measure the fixed router. heldout-2 measures the router as it will be shown.
