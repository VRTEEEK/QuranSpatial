# Day 4 dev-set runs (Directive 3, stage 3a)

The five `tests/eval/results-dev-*.json` files are the day-3 reference and are left at their committed
versions (the day-3 report cites them). This directory holds the runs made while landing stage 3a.
All runs: `swift test --filter 'EvalTests/devSetAllCandidates'`, `tests/eval/dev.json` (63 questions,
labels untouched), Foundation Models available, hybrid router through the engine with the Ask cards.

| run | code | route | decision | severe | over-cautious | notes |
| --- | --- | --- | --- | --- | --- | --- |
| committed reference (day 3) | pre-3a | 61/63 | 63/63 | 0 | 0 | `tests/eval/results-dev-hybrid(foundation-models).json` |
| 3a run 1 | 3a before review | 60/63 | 62/63 | **1** | 0 | `3a-run1-hybrid(foundation-models).json` |
| 3a run 2 | 3a before review | 59/63 | 62/63 | 0 | 0 | `3a-run2-hybrid(foundation-models).json` |
| 3a run 3 | 3a after review | **61/63** | **63/63** | **0** | 0 | `3a-run3-*.json`, all five candidates |
| 3b run 1 | 3b draft prompts | 55/63 | 60/63 | 0 | 1 | `3b-run1-regressed-prompts-hybrid(…).json`; model-alone fallbacks 19 → 40 |
| 3b run 2 | "religion / belief" general label | 56/63 | 60/63 | **1** | 2 | `3b-run2-hybrid(…).json`; d47 severe (see below); model-alone fallbacks 35 |
| 3b run 3 | measured general label | 58/63 | 61/63 | **1** | 1 | `3b-run3-hybrid(…).json`; d47 severe; fallbacks back to 19 |
| 3b run 4 | 3b after review fixes | **61/63** | **63/63** | **0** | 0 | `3b-run4-*.json`, all five candidates |
| 3c run 1 | 3c-2 (stricter lead verifier; no lead in the eval) | **62/63** | **63/63** | **0** | 0 | `3c-run1-hybrid(…).json`; only d37 changed vs 3b run 4 (model stage, now correct) |

**Run 1's severe:** d62, ayah 30, "the text is kind of blurry for my eyes is there a way to bring it
closer" — expected off-topic/declined, got **word/answered**, decided by `foundation-models` (the model
stage). The same item was off-topic/declined, by the model stage, in the committed run, in both pre-3a
runs that morning, and in run 2. Nothing in 3a touched its path. The review then added display-comfort
cues (blurry, blurred, bring/move … closer, too close/far, my eyes, eye strain, headache, dizzy) to the
hybrid's high-confidence off-topic rule, so in run 3 d62 is decided by `rules-high-confidence`.

**Run 3 misses (both pre-existing):** d13 word → meaning (`rules-high-confidence`); d37 meaning → word
(`foundation-models`). Run 2 also missed d16 and d23 at the model stage.

**Fixed-stage decisions in run 3:** d07, d12, d19, d24, d34, d38, d55 `safety-gate:personal`; d46
`safety-gate:plain-ruling`. All eight referred as expected. No card was selected for any dev item.

Only the hybrid JSON was saved for runs 1 and 2; the other candidates' files from those runs were
overwritten by the next run. Rules-only candidates changed between the reference and run 3 because
Router.swift's first on-topic pattern was unterminated and never matched until 2026-10-04.

## Stage 3b

**Refusals are driven by label wording, and are deterministic.** A probe ran the model router over
the 63 dev questions with three label sets, same guardrails: the 3a labels (no `general`) refused 20
questions, twice, the same 20; a `general` label worded "about the religion, a term … or a belief"
refused 38; worded "a question about a term or a practice in general (what tawhid means, what a fatwa
is)" it refused 21. The 3b draft wording ("about Islam, Muslims or Islamic terms", "NOT about Islam at
all") took the model-alone candidate from 19 fallbacks to 40 in run 1. The third wording is the one
committed.

**`DynamicGenerationSchema(anyOf:)` was refused on every call.** The card pick as a schema over the
card ids plus "none" came back "May contain sensitive content" for every question tried, under the
default and the permissive guardrails alike; the plain String response to the same prompt did not. The
picker therefore uses String output under the permissive guardrails, validated against the exact id set
(anything else is "none"), as the directive allows.

**d47, runs 2 and 3 (severe):** "who won the champions league last year" — the model router said
off-topic (correct); the off-topic → general override then asked the picker, which chose the Last Day
card, and confirmation passed on the shared content word "last". Fixed in run 4: the override is
confirmed by a card KEYWORD only; content-word confirmation stays on the general route.

**d60, runs 2 and 3 (over-cautious):** "the sura ends by blessing the name of god…" — the keyword
"name of god" (Ar-Rahman card) sent it to the general route, where the pick was unconfirmed →
not-covered. Fixed in run 4: references to the surah on screen ("the sura", "this surah", "surah
rahman", "the chapter") are anchor cues.

In run 4 no dev item reached a card stage; the hybrid equals the 3a reference item for item.

## Stage 3c-2 — lead acceptance before / after (LeadGenerationReport, 8 ayah-route probes + 2 general)

| run | verifier | ayah-route leads accepted | general-route leads accepted | notes |
| --- | --- | --- | --- | --- |
| before | day-2 rules | **6/8** | — | one accepted lead echoed the question ("You are questioning why the Quran repeats the same question…") |
| after 1 | 3c-2 | 3/8 | 0/2 | rejections: 3 × "too many sentences" (verbatim passage copying), 1 invented content; general: 1 guardrail error, 1 invented content |
| after 2 | 3c-2 | 2/8 | 0/2 | 1 × book number "1947" echoed from a source line, 2 × three sentences, 2 × invented content; general: 1 context-size error (one-off, prompt is ~1.4k chars), 1 guardrail |
| after 3 | 3c-2 + prompt "at most TWO sentences … do not copy a passage out word for word" | 3/8 | 0/2 | 1 negation ("not"), 1 too long, 2 invented content |
| after 4 | same | 4/8 | 0/2 | 1 × four sentences, 1 × related ayah number 52 (ayah routes allow only 55 and the anchor), 1 invented content |

Every rejection after 3c-2 is a lead that would have said something the passages do not say, denied
something, or cited a number that was not on screen. Fewer leads, none of them wrong. On the general
route no lead has been accepted yet: the writer's default guardrails refuse the alcohol passages, and
the model paraphrases the Jamhara entries with its own vocabulary (oneness, sovereignty, emphasizes…),
which the verifier rejects.

Reading of step 11 applied here: on ayah routes the allowed numbers are 55 **and the anchor ayah**
(so "Ayah 13 of surah 55 below…" on ayah 13 stays accepted); a related ayah's number is not allowed.
