# Baseline disclosure

Drafted 2026-10-03 against `stage-2` HEAD `9cc35e8` ("D4 English shown only over settled Arabic")
and finalised at the baseline commit described in the next section. For the `baseline-2026-10-03`
tag. **Every `UNKNOWN` is a line Mo has to fill or confirm.** Statuses are as recorded in the repo
at the commit; nothing here is a legal reading.

## The baseline commit

- **Committed on 4 October 2026 at 03:22:47 (Riyadh, UTC+3)** — **3 h 22 min after the
  3 October deadline**, taking the deadline as the end of 3 October, Riyadh time.
- **It contains only work completed by 3 October.** Evidence: every file that was uncommitted when
  the commit was made, with its last-modification time (Riyadh). Nothing was modified on 4 October
  except this disclosure itself, which records the commit, and `ImmersiveView.swift` for the removal
  of the two local-only HUD edits (`showDebugHUD` back to `false`, the one-shot HUD placement
  removed) that were never meant to be committed.
- **No challenge work was started before this commit.** The "Ask" companion in the baseline is a
  lookup only: the Meaning panel shows a stored passage. No speech, no question, no model, no network.

| previously uncommitted file | last modified (Riyadh) |
| --- | --- |
| `docs/stage-1-report.md` | 2026-09-30 19:12 |
| `docs/measurements/b3-preroll.py`, `b3-preroll.csv` | 2026-10-01 00:18 |
| `docs/stage-2-plan.md` | 2026-10-02 01:10 |
| `docs/measurements/environment-review-2026-10-02.md` | 2026-10-02 02:32 |
| `docs/measurements/env-review/report.md` | 2026-10-03 11:10 |
| `QuranSpatial.xcodeproj/project.pbxproj` (microphone usage key, audio-input access) | 2026-10-03 13:01 |
| `docs/measurements/device-2026-10-03/*` (reports pulled from the headset) | 2026-10-03 15:19 (pulled); the review-asset reports are from the 15:24 session |
| `.gitignore`, `QuranSpatial/EnvironmentLighting.swift`, `QuranSpatial/PavilionEnvironment.swift`, `QuranSpatialTests/EnvReviewTests.swift` (environment switch) | 2026-10-03 15:22 |
| `QuranSpatial/ImmersiveView.swift`, `QuranSpatial/MeaningPanelView.swift`, `QuranSpatial/RecitationTranslation.swift`, `QuranSpatialTests/MeaningDataTests.swift` (Meaning panel) | 2026-10-03 15:36 |
| `QuranSpatial/RecitationMeaning.swift`, this file | 2026-10-03 15:36 |

## Device-test status at the baseline — honestly

**Seen on the headset on 3 October** (Mo wearing it, Debug build with the HUD on locally):

- Ask pauses the recitation and pins the ayah.
- The Meaning panel appears on Ask, beside the text.
- The English translation layer shows under the Arabic.
- The new environment loads, with the glow cards hidden.

**NOT completed:** test runs 1–3 of the Stage 2 plan (the audio-session, Ask-transport and
English-layer test tables) and the full-surah performance measurement. No frame-stats run covers
a full surah at this baseline; `docs/measurements/device-2026-10-03/` holds launch reports and one
partial run, not the acceptance measurement.

## New environment adopted (2026-10-03) — known issues

`stage-2` now loads `QuranSpatial_Review.usdz` (see the components table). Adopted with these open
issues, recorded rather than resolved:

- **Memory: about 515 MB more after load** (Mo's observation on the headset). The one launch report
  pulled with this asset (`environment-load-review-asset-1524.txt`) reads 704 MB physical footprint
  after load against 273 MB with the corrected asset, with +262 MB attributable to the load itself
  against +52 MB before.
- **Glow cards hidden.** They render as flat rectangles (`GlowCards_Merged` is a transparent PBR
  with an emissive texture and an opacity texture; `Lantern_08` and `Step_Edge_Glow` are opaque PBR
  with no textures). `EnvironmentLighting.envReviewHideGlowCards = true` disables all three; the
  materials are logged first so the cause can be placed later.
- **Missing names logged.** The asset lacks `Platform`, `Lantern_01`–`08`, `Lantern_Ceiling`,
  `Night_Sky_Dome` and `textures/night_sky_2k.png`, and carries 11 textures against the 22 the code
  expects. Every miss is logged once as `env-review missing: <name>` and falls through as before;
  the consequence is that the lantern lights, the sky dome swap, the IBL from the sky texture and the
  deck-orientation check do not apply to this asset.
- **Provenance stays UNKNOWN until Mo states it.**

## Build

- Built with **Xcode 27.0 beta** (`27A5237l`) against SDK **visionOS 27.0**, deployment target
  **26.5**. A beta-built binary can go to TestFlight, **not** to the App Store.
- Debug configuration for every device test. The debug HUD (`ImmersiveView.showDebugHUD`) is
  `false` in the committed tree; it is flipped locally for test sessions and never committed.
- **No build containing the English translation file has left Mo's devices** — UNKNOWN: confirm.
- Device tests: see "Device-test status at the baseline" above. The test tables (T1–T24) were not
  run to completion; `docs/measurements/device-2026-10-03/` is what exists.

## Components, rights and licence status

| component | rights holder | licence / status | evidence in the repo (at `9cc35e8`) |
| --- | --- | --- | --- |
| Quran text, Surah 55, Uthmani | Tanzil Project (Tanzil Quran Text, Uthmani v1.1) | **CC BY 3.0 — satisfied**: verbatim, source named, live link to tanzil.net, copyright notice travels with the text | `QuranSpatial/Resources/ar-rahman-text.json` (`source`, `sourceURL`, `sourceSHA256`, `license`, `copyright`); `CreditsView.swift` Quran-text section; `RecitationDataTests.swift` byte-identity and non-normalisation tests |
| Recitation audio `rahman-single.mp3` | performance: Qari Ismail Nouri; publisher/channel "Garden of Verses" (from the file's own ID3 tags; no licence stated in the file) | **UNRESOLVED — open ship blocker.** No licence, terms or permission. Must not be distributed. | CLAUDE.md "Recitation audio — unresolved"; `CreditsView.swift` provisional credit; `AudioAssetReport.swift`; file SHA-256 `bf48c019…c0` (Stage 1 report B3) |
| Timings `ar-rahman-timings.json` | own work (boundaries by ear, validated statistically) | no third-party rights of its own; a derivative of listening to the audio above, so it inherits that status in spirit | `RecitationTimings.swift:8–12`; `RecitationDataTests.swift`, `RecitationProgressionTests.swift`. Open: segment 38's boundary lies inside speech and segment 1's sits in the intro's decay tail — **UNKNOWN: listening checks not done** (Stage 1 report, B3) |
| Pre-roll table `ar-rahman-preroll.json` | own measurement over the audio (2026-09-30) | as the timings | `docs/measurements/b3-preroll.py`, `b3-preroll.csv`; the JSON's `mp3SHA256`/`marginDb`; `AskTransitionTests.prerollTableMatchesTheBundledAudioAndTimings` |
| Ship font Amiri Quran 1.003 | The Amiri Project Authors, 2010–2022 | **SIL OFL 1.1 — satisfied**; shipped unmodified; no Reserved Font Name declared | `QuranSpatial/Fonts/AmiriQuran.ttf` + `QuranSpatial/Fonts/OFL.txt`; `CreditsView.swift` Typeface section; `QuranSpatialTests.resolvedFontIsTheBundledShipFontWhenOneIsBundled` |
| KFGQPC Uthmanic Hafs v2.2 | King Fahd Glorious Quran Printing Complex | **not shipped** since 2026-09-04; licence reading recorded, not resolved | absent from the build and **never committed** (verified: no history entry); kept only in gitignored `scratch/` |
| English translation, Saheeh International | Saheeh International (translation); distributed via Quranpedia book 1947 | **UNRESOLVED — distribution blocked.** No licence notice in the file. Text is not in the repo and not in any build beyond Mo's devices (UNKNOWN: confirm) | gitignore rule `QuranSpatial/Resources/en-*.json` (`.gitignore:26`); `RecitationTranslation.swift` absence path and self-hash check; `TranslationDataTests` pin raw SHA-256 `8c08a833…3978` and text SHA-256 `c4987b6a…f90a` without a word of text; `CreditsView` line only when the file is present. Decision record: claude.ai Project 'Quran AVP', `claude/english-translation-edition.md` (outside the repo) |
| Meaning panel text: Al-Mukhtasar fi Tafsir al-Quran, English translation; distributed via Quranpedia book 27824 (Surah 55 only, 78 passages; the source gives all 31 refrains ayah 77's passage verbatim, kept as is) | Tafsir Center for Quranic Studies (Markaz Tafsir), per the book's own description; translation rights holder not stated | **UNRESOLVED — distribution blocked.** No licence notice in the file. **Local builds only; never in the public repo.** Downloaded 2026-10-03T12:33:58Z; raw SHA-256 `4790ae49…ccdc`, text SHA-256 `b2d59ffa…c5ad` | gitignore rule `QuranSpatial/Resources/en-*.json` (covers `en-rahman-mukhtasar-27824.json`); `RecitationMeaning.swift` absence path and self-hash check; `MeaningDataTests` pin both hashes without a word of text; `MeaningPanelView` shows "Meaning not available in this build" when absent. A lookup only: no speech, no model |
| Quranpedia data (books 1947 and 13638 JSON) | quranpedia.net | **terms unknown**; no licence notice in either file; the dumps manifest does not cover them. Used for extraction and comparison only; **not shipped** | Stage 1 report "Decisions (human)"; raw files held outside the repo |
| English font: Apple system font (F1) | Apple | platform licence; nothing bundled | `ArabicTextRasterizer.resolveSystemFont`; `TranslationDataTests.systemFontHasGlyphsForTheThreeNonASCIIScalars`; the resolved PostScript name is logged at launch |
| Environment `QuranSpatial_Environment_Corrected.usdz` (21 texture maps inside) — in the tree, **no longer the loaded environment** since 2026-10-03 | **UNKNOWN — author, source and terms are not recorded anywhere in the repo or CLAUDE.md** | **UNKNOWN** | `QuranSpatial/Resources/Environment/…usdz`; `PavilionEnvironment.swift:38`; CLAUDE.md "Environment asset" records measurements, not provenance |
| Earlier environment exports `QuranSpatial_Environment.usdz`, `night_pavilion.usdc` | as above | **UNKNOWN**; not in the tree, **but in git history** (added then removed) | `git log --all -- QuranSpatial/Resources/Environment/` |
| Review environment `QuranSpatial_Review.usdz` (11 texture maps inside) — **the environment stage-2 loads since 2026-10-03** (`PavilionEnvironment.resourceName`; the corrected asset stays beside it so switching back is one constant) | as above | **UNKNOWN**; **gitignored, never committed** (67,466,117 bytes). SHA-256 `56fd03a3394b485765606c3a6b59910ac8a55c48bcbc88994700638bb3b58fc6`, placed by hand from `scratch/` | `.gitignore` rule; `docs/measurements/env-review/`; `docs/measurements/environment-review-2026-10-02.md` |
| RealityKitContent materials (`DissolveMaterial.usda`, `NightSkyMaterial.usda`, `StarSpriteMaterial.usda`, `Immersive.usda`) | own work | — | `Packages/RealityKitContent/…/Materials/` |
| Sky, stars, lighting rig, star-field mesh, grey-box | own work, procedural | — | `EnvironmentLighting.swift`, `StarFieldMesh.swift`, `GreyBoxEnvironment.swift` |
| Hand-tracking captures `capture/*.json` (two takes) | Mo's own hand and head data | personal data, Mo's; tracked deliberately as irreplaceable reference | `capture/`, CLAUDE.md "Capture workflow" |
| App icon / assets | own work unless stated — UNKNOWN: confirm | — | `Assets.xcassets` |
| Apple SDKs (Core Text, RealityKit, ARKit, AVFoundation) | Apple | Xcode / SDK licence | CLAUDE.md "Platform" |

Also disclosed: the hand-typed probe string that was at `Ayah.swift:16` was **removed** on
2026-10-01 (commit `5e2d22f`); no Quran text is typed in source or tests at this HEAD.

## Tracked files that must NEVER go into a public repository

Checked with `git ls-files` and `git log --all` on 2026-10-03. "In history" means a public push
of this repository, even after deleting the file, would still publish it; a history rewrite would
be required.

| file | why | tracked at HEAD | in git history today |
| --- | --- | --- | --- |
| `QuranSpatial/Resources/rahman-single.mp3` | **unlicensed third-party recitation** | yes | **yes** — added `912a340` (2026-09-04), 1 commit |
| `QuranSpatial/Resources/ar-rahman-timings.json` | derived from the unlicensed recording (segment boundaries); not infringing in itself — UNKNOWN: your call whether it travels with the audio | yes | yes — `912a340` |
| `QuranSpatial/Resources/ar-rahman-preroll.json` | measurement over the recording; same question | yes | yes — `5e2d22f` (2026-10-02) |
| `QuranSpatial/Resources/Environment/QuranSpatial_Environment_Corrected.usdz` | **provenance and terms UNKNOWN** | yes | yes — `7d3b3b4` (2026-09-16) |
| `QuranSpatial/Resources/Environment/QuranSpatial_Environment.usdz`, `night_pavilion.usdc` | earlier exports, same UNKNOWN | no (removed) | **yes — still in history** |
| `capture/dua-capture-2026-09-03T20-10-57Z.json`, `capture/dua-capture-2026-09-03T20-53-24Z.json` | personal biometric-adjacent data (hand joints, head position) — your own, so your decision | yes | yes — `7282757`, `8728dee` |
| `QuranSpatial/Resources/Environment/QuranSpatial_Review.usdz` | **provenance and terms UNKNOWN**; the loaded environment since 2026-10-03. SHA-256 `56fd03a3394b485765606c3a6b59910ac8a55c48bcbc88994700638bb3b58fc6` | no (gitignored) | **no — never committed** |
| `QuranSpatial/Resources/en-rahman-mukhtasar-27824.json` (Meaning panel, Mukhtasar) | **no licence notice in the file; local builds only** | no (gitignored) | **no — never committed** |
| `QuranSpatial/Resources/en-*.json` (translation) | unlicensed translation text | no (gitignored) | **no — never committed** (verified) |
| `scratch/**` (KFGQPC font, review usdz, raw files) | licensing-unresolved material | no (gitignored) | **no — never committed** (verified) |

Everything else tracked is own work or OFL/CC-BY material with its notice in place
(`AmiriQuran.ttf` + `OFL.txt`, `ar-rahman-text.json` + `CreditsView`).

**Consequence for a "public competition repo":** at this HEAD the repository cannot be published
as-is. The mp3 is tracked and in history, and the environment asset's rights are unrecorded.
The options are a fresh public repository built from a filtered export (no `Resources/rahman-*`
audio, no environment binaries unless cleared, captures by your choice), or a history rewrite
of this one before any push. The translation is already outside the repo and the font is clear.

## Open items for Mo before the tag

1. Environment provenance and terms (current asset, earlier exports in history, review asset).
2. Segment 38 and segment 1 listening checks — or record them as not done.
3. Confirm no translation-bearing build left your devices.
4. Decide whether `ar-rahman-timings.json` / `ar-rahman-preroll.json` and the two captures are
   publishable, independent of the audio.
5. Confirm the app icon/assets are own work.
6. The audio itself: permission from the rights holder, or a replacement recording with terms
   that permit distribution — unchanged open ship blocker since Stage 1.
