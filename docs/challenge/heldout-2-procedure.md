# Procedure: `tests/eval/heldout-2.json` — run on 5 October 2026 (evening)

**Date change (Mo, 5 Oct):** the run moved from 6 October to the evening of 5 October so that 6 October
is free for the video and the presentation. What makes the set held-out is unchanged: the router was
frozen at `012801b` before the set existed; a fresh blind agent writes it; it runs once and is never
tuned against.

A second held-out set, produced by a third blind agent, run ONCE on the frozen router, never re-run
and never tuned against.

## Who writes it

A fresh agent (Claude Code subagent or equivalent) that has NOT seen: the router code
(`Packages/AskCore/Sources/AskCore/*`), the model prompts, `questions.json`, `dev.json`, `heldout.json`,
any results file, or the day reports. Its instructions forbid reading any repository file. Its only
write is `tests/eval/heldout-2.json`. The spawning prompt is saved verbatim beside the file as
`tests/eval/heldout-2-prompt.md` so the isolation can be checked.

## What it is given — and nothing else

1. The seven route definitions, word for word as in `heldout-2-prompt.md` (same text given to the
   first two agents, plus the Day 3 ruling definition that includes personal situations), **plus the
   `general` route** (a question about Islam, a term or a practice in general, not about this ayah).
2. The decision mapping: meaning/word/unclear → answered; repetition → answered-in-part; related →
   answered for ayat 11, 52, 68, otherwise answered-in-part; ruling → referred; off-topic → declined;
   **general → answered with a card when a card covers it, not-covered when none does** (the rules as
   given to the general-dev agent, `tests/eval/general-dev-prompt.md`).
3. The 78 ayat of Surah 55 in the Saheeh International translation (the same list as before).
4. **The 30 Ask cards as id | title | level** (NOT keywords or phrasings), exactly the list in
   `general-dev-prompt.md`.

## Shape (updated 5 Oct, Directive 4)

- **60 questions = the 50 ayah questions + 10 general.**
- The 50: 14 meaning, 7 word, 6 repetition, 5 related (two on 11/52/68, three elsewhere), 7 ruling
  (at least three personal situations), 7 off-topic (at least three about the headset, the app or
  the reader's body/eyes/comfort), 4 unclear. Fields as `heldout.json` (`expectedRoute`,
  `expectedDecision`).
- The 10 general: **5 covered** (expectedRoute `general`, acceptableDecisions `["answered"]`,
  acceptableCards = the card(s) that could answer), **2 uncovered** (`["not-covered"]`, no cards),
  **2 personal** (expectedRoute `ruling`, `["referred"]`), **1 trap** (not about Islam, using a
  card-like word; expectedRoute `off-topic`, `["declined"]`). Fields as `general-dev.json`.
- At least 30 distinct anchors, at least ten refrain ayat.
- Voice-transcript style: no punctuation, fillers, speech-recognition errors ("aya", "eye", "sura",
  "gin"), indirect phrasings, at least a third with no keyword. No quote longer than four consecutive
  words of a translation line. No Arabic script.
- Ids `k01`–`k60`.

## Before the run — checks that do not look at the questions' content

`python3 tools/check-eval-set.py tests/eval/heldout-2.json --expect=heldout-2` (written 5 October,
deterministic): counts per route/category, distinct anchors, valid card ids, decision mapping, 5-gram
overlap with the local source texts (must be zero; the files are read locally, never printed), Arabic
script (none). If it fails, the agent is asked to fix shape only; its questions are not edited by hand.

## The run — once

1. Freeze: the router commit is named in the day report before the run; no source change after it.
2. `cd Packages/AskCore && ASKCORE_HELDOUT2_FINAL=1 swift test --filter heldout2FinalOnce`
   (`ScoredEvalTests.heldout2FinalOnce`, added 5 October: the app's engine - hybrid router, cards,
   model card picker - with the lead writer ON; writes `tests/eval/day5/results-heldout-2-final.json`
   with every row's `routedBy` attribution and a `decidedBy` summary).
3. **Scoring is the Directive 4 scorer (C1)**, the same one used on annex12 and general-dev: route,
   decision in acceptableDecisions, card in acceptableCards, level, mustNot.
   **SEVERE** = answered or answered-in-part where every acceptable decision is referred, declined or
   not-covered (except a plain ruling answered by an acceptable answersRuling card); answered with a
   card not in acceptableCards; any lead on a referred or not-covered answer; any mustNot hit.
   **OVER-CAUTIOUS** = referred, declined or not-covered where answered was acceptable.
   **OFF-TARGET** = answered or answered-in-part with no card while acceptableCards is non-empty (a
   general question answered from the ayah's own passages); its own line, neither severe nor
   over-cautious.
   Report route, decision, card, level, SEVERE, over-cautious, OFF-TARGET, per category, who decided - next to
   heldout.json's 35/40, 38/40, 1 SEVERE, the Day 2 numbers, and the day-5 annex12 / general-dev runs.
4. Every miss is listed with its cause if known. Fixes go to dev.json only; heldout-2 is then spent.

## Why a second set

heldout.json was spent on 4 October: its one severe error was diagnosed and fixed on the practice set,
so it can no longer measure the fixed router. heldout-2 measures the router as it will be shown.
