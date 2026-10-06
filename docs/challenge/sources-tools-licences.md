# Sources, tools and licences — log

Kept current at every commit that adds a source or a tool. Hashes are SHA-256 of the file as held
locally; "status" is the engineering status, not a legal reading.

## Texts

| source | what | hash | licence evidence | status |
| --- | --- | --- | --- | --- |
| Quran text, Surah 55, Uthmani — Tanzil Project (Uthmani v1.1) | `QuranSpatial/Resources/ar-rahman-text.json`, verbatim, byte-tested | source file `203f0f1bf3158b1e5be4ab9f8f6870e570aab6d9a626fe6192a70b75d4afe0fd` | CC BY 3.0; terms re-verified 2026-09-04; notice travels in the JSON and in `CreditsView` | **satisfied**, committed |
| Saheeh International translation — Quranpedia book 1947 | raw `scratch/1947.json`; extracted `en-rahman-saheeh-1947.json` (text SHA-256 `c4987b6a…f90a`), footnotes `en-rahman-saheeh-1947-footnotes.json` (`82855314…0cbd`) | raw `8c08a8332fae34788f556e5d13a78fe45f68f607cf7a2dabd6596a7fad573978` | **none in the file**; Quranpedia dumps LICENSE.md (2026-10-03) says translations remain their authors' property | **local only**, gitignored, never committed |
| Al-Mukhtasar fi Tafsir al-Quran, English — Quranpedia book 27824 (Tafsir Center for Quranic Studies) | raw `scratch/27824.json`; extracted `en-rahman-mukhtasar-27824.json` (text SHA-256 `b2d59ffa…c5ad`) | raw `4790ae49369d80d40c63ed8f197c0d6db909bcee23d63288fb12159cab4eccdc` | **none in the file**; same LICENSE.md remark | **local only**, gitignored |
| Quranpedia similar-ayat dump | raw `scratch/similar.json.gz` / `.json`; derived refs-only `related-55-quranpedia-similar.json` (numbers, no text) | gz `396eb434b92cbe1b951091de8cc2c786806b30cfa7cbcad5c1f7746568dc84b0`; json `6716ea2913cfe40626728d969c750f543179cb3cdb92d785219283bb5a5f48b2` | **present**: Quranpedia.net Data License v2026-10-03 inside the file and `dumps/LICENSE.md` — free to use inside apps; republishing as a dataset requires credit + dump version | raw local; refs file **committed** |
| 13 further English books (1948, 13602–13605, 13638, 13640, 13644, 13645, 13661, 13662, 27811, 27833) | `scratch/*.json`, surveyed for 55:13 only (`scratch/english-books-55-13.md`) | in `scratch/english-books-download.txt` | none in any file | **not used**, not shipped |

## Audio, fonts, environment (baseline, unchanged by the challenge)

| asset | hash | licence evidence | status |
| --- | --- | --- | --- |
| Recitation `rahman-single.mp3` (Qari Ismail Nouri, "Garden of Verses", from ID3) | `bf48c019846310aac307d1c0edb64918a0cb39ef4ec79796e9f2377f3f7be8c0` | none | **unresolved — open ship blocker**; local only in the public mirror |
| Amiri Quran 1.003 `AmiriQuran.ttf` + `OFL.txt` | `e2a47644762d16bdfb6d33e0d8db8c6ff30beae84150ef5a705316bbd829455c` | SIL OFL 1.1 in the repo | **satisfied**, committed, unmodified |
| Environment `QuranSpatial_Review.usdz` (loaded since 2026-10-03) | `56fd03a3394b485765606c3a6b59910ac8a55c48bcbc88994700638bb3b58fc6` | **UNKNOWN** (provenance not stated) | gitignored, local only |
| Environment `QuranSpatial_Environment_Corrected.usdz` (previous) | `21f91d7d773f60cd03e419889edb7a789d58ef3604a22282a35558f8c1ce12aa` | **UNKNOWN** | tracked in the private repo; excluded from the public mirror |

## Tools and models

| tool / model | use | version | terms |
| --- | --- | --- | --- |
| **Apple Foundation Models** (`SystemLanguageModel.default`, on device) | the question router (output: a `@Generable` enum; permissive content-transformation guardrails) and the lead writer (free text, default guardrails, verified) | macOS 26.5 / visionOS 26 SDK 27.0 (Xcode 27.0 beta `27A5237l`) | Apple platform SDK licence; runs on device, no network |
| **Apple Speech framework** — `SpeechAnalyzer` + `SpeechTranscriber`, fallback `SFSpeechRecognizer` with `requiresOnDeviceRecognition` | on-device English transcription of the spoken question | same SDK | same |
| Apple RealityKit, ARKit, Core Text, AVFoundation, SwiftUI | the app (baseline) | same | same |
| **Claude Code (Anthropic), model Claude Fable 5.1** | development assistant: wrote and ran the build, test and sync tooling, the AskCore package, the app wiring and these documents under Mo's direction; each commit carries `Co-Authored-By: Claude Fable 5.1`. The two blind question-set authors were separate Claude agents given only the route definitions and the ayah list. | — | Anthropic terms of service |
| curl, python3, git, gh, shasum | downloads, hashing, extraction scripts, public mirror | system | — |
| Quranpedia.net | source of the translation books and the similar-ayat dump | dumps manifest version 2026-10-02 | see above |

## Decisions that bind the use of these sources

- Texts are never normalised, compared with `==`, generated, transcribed or hand-corrected.
- Extraction is deletion-only and recorded in each extracted file's `extractionRules`; a hash
  mismatch stops the build scripts rather than updating a pin.
- The public repository receives the scripts and the hashes, never the texts; `tools/sync-public.sh`
  aborts on any passage.

## Organisers' guidance (4 Oct 2026)

Relayed by the organisers on 4 October 2026, recorded here as guidance and **not as a licence grant**:

- any source may be used if it is named and documented;
- the committee will verify the Tanzil comparison (`scratch/tanzil-vs-quranpedia-55.md`);
- documentation is required.

What this changes: nothing about distribution. The Jamhara (islamic-content.com) English entries in
`en-jamhara-terms.json`, the Saheeh ayat the cards cite in `en-saheeh-1947-cited.json`, and the Dorar
English overall meaning in `en-dorar-55-overall.json` **stay local only** — gitignored, named in
`tools/sync-public.sh`'s never-tracked list (the sync aborts if one is staged or committed;
`tools/test_sync_public_guard.py`), and reproduced by `tools/fetch-sources.py` with pinned hashes.
Permission to redistribute has been requested from each publisher; none has been granted. The
committed `ask-cards.json` carries references only.

## Day 4 Ask sources (4 Oct 2026) — status by file

| file | source | fetched by | retrieved | hashes | status |
| --- | --- | --- | --- | --- | --- |
| `ask-cards.json` | written for this project; references only (Jamhara ids, Quran refs, dawa.center links) | — | — | — | **committed** |
| `en-jamhara-terms.json` | Jamhara English entries, `https://islamic-content.com/dictionary/word/<id>/en`, 22 ids; robots.txt `User-agent: *` permits `/dictionary/` | `tools/fetch-sources.py` (2 s between requests, 429 → 30 s, 3 retries; none occurred) | 2026-10-04 08:05 UTC | per-entry `rawSHA256` (HTML) and `textSHA256`; file `8fe69b0a…f34ed` pinned | **local only**, permission requested |
| `en-saheeh-1947-cited.json` | Saheeh International, Quranpedia book 1947, the 11 ayat the cards cite, same deletion-only rules as the Surah 55 file | `tools/fetch-sources.py` | from the pinned raw `8c08a833…3978` | text `cf1833da…1180` pinned | **local only** |
| QuranEnc `english_saheeh` | `https://quranenc.com/api/v1/translation/sura/english_saheeh/{sura}`, version **1.1.2**, last_update 1750772247 (2025-06-24) | check only, `scratch/quranenc/compare.py` | 2026-10-04 08:03 UTC | — | **check only, not a source.** Surah 55: translation **78/78** byte-identical to our 1947 extraction, footnotes 14/14. 112:1-4: 0/4 — Quranpedia's field ends with one U+0020 SPACE in every ayah of 112 that QuranEnc does not have; nothing else differs. 2:144 and 5:90-91: 3/3 identical. 2:144 footnote: Quranpedia's block is `____<br /><span class="text-danger">\n[53]-</span> text`, markup our Surah-55 rules do not strip; QuranEnc's note is plain. 5:90-91: 1/1 note identical. |
| `en-dorar-55-overall.json` | Dorar English overall meaning, `https://dorar.net/en/tafseer/1030`–`1038` | **not fetched** | 2026-10-04 08:07 UTC attempt | — | **blocked**: dorar.net's Cloudflare returned HTTP 403 ("Sorry, you have been blocked") to `robots.txt` and to all nine pages. Not worked around. The guards (gitignore, never-tracked list) are in place for when the pages can be obtained. |

### Saheeh International — source of record and the QuranEnc cross-check

**Saheeh International: source of record is Quranpedia book 1947 (annex-named).** Byte-identical to
QuranEnc `english_saheeh` v1.1.2 for surah 55 (78/78 translations, 14/14 footnotes), 2:144 and 5:90-91;
112:1-4 differ only by a trailing U+0020 SPACE on the Quranpedia side. QuranEnc's terms permit unmodified
republication with attribution and version (seven conditions, quoted below; note 6 requires tracking the latest version). Read from https://quranenc.com/en/home/about on 2026-10-04
(saved as `scratch/quranenc/about.html`), verbatim:

> Contents of the translations can be downloaded and re-published, with the following terms and conditions: 1. No modification, addition, or deletion of the content. 2. Clearly referring to the publisher and the source (QuranEnc.com). 3. Mentioning the version number when re-publishing the translation. 4. Keeping the transcript information inside the document. 5. Notifying the source (QuranEnc.com) of any note on the translation. 6. Updating the translation according to the latest version issued from the source (QuranEnc.com). 7. Inappropriate advertisements must not be included when displaying translations of the meanings of the Noble Quran.

This is recorded as the terms of a *second* publisher of the same text; the file we ship is still the
Quranpedia 1947 extraction, and the Quranpedia dumps' LICENSE.md leaves translations to their authors.

**Correction to part 1's report (4 Oct 2026):** 11 of the 22 Jamhara entries carry an explanation
("الشرح المختصر"), not 6 as first reported. The file itself was right; the summary line was wrong.

## App icon (5 Oct 2026)

| asset | source | processing | status |
| --- | --- | --- | --- |
| App icon (`QuranSpatial/Assets.xcassets/AppIcon.solidimagestack`, three 1024 px layers) | six image components generated by Mo with ChatGPT image generation on 4 Oct 2026 (`design/app-icon/source/`, with the concept board and the brief) | composited by `design/app-icon/build_icon.py` (Pillow): environment cropped to its solid rectangle, scaled 1.2962× and shifted so the crescent sits in the arch opening, exposed bands mirrored from the image's own edge; **the AI-generated imitation Arabic page text and ayah-marker-like diamonds were removed** by a horizontal smear inside each page's frame (this app never shows generated Quranic text); solid alpha normalised to 255; glass shell (`01_glass_shell`) **unused** | AI-generated for this project with ChatGPT; no stock or third-party artwork; committed after the headset check |

## Ask cards and their sources (5 Oct 2026, Directive 4)

**`QuranSpatial/Resources/ask-cards.json`** (committed, references only): 30 cards - 21 term cards (one
Jamhara entry each), 8 general cards, 1 gap card. Each carries an id, a title, an annex content level
(A stable / B explanation / C disputed or sensitive), whole-word keywords, 3-5 phrasings, Jamhara ids,
Quran refs and, for two cards, an Arabic link. No source text.

**Change on 5 Oct (A2, Mo's decision):** `gap-quran-authorship` became a **general** card answered from
Jamhara entry 7771 ("The Qur'an"), level B, keeping its Arabic link as further reading, because annex
row 2 expects a documented definitional answer. `gap-spread-by-sword` stays a gap card (no English
source in the app covers it) and answers "not-covered" with its link.

**Arabic links shown to the reader (as selectable text, never fetched by the app):**

| link | used by | role |
| --- | --- | --- |
| https://dawa.center/file/7937 — "بينات: أسئلة وأجوبة عن الإسلام" (annex: the primary source for doubts) | `gap-quran-authorship` (further reading), `gap-spread-by-sword` (the only answer) | annex-named |
| https://dorar.net/tafseer/55/2 | the repetition route's note | annex-named (dorar.net/tafseer) |

**Jamhara entries used** (`en-jamhara-terms.json`, local only, trim-only extraction, each entry hashed;
`https://islamic-content.com/dictionary/word/<id>/en`, all retrieved 2026-10-04 08:05 UTC):

| id | title (as published) | URL |
| --- | --- | --- |
| 3529 | Monotheism | https://islamic-content.com/dictionary/word/3529/en |
| 5172 | The Lord of Grace | https://islamic-content.com/dictionary/word/5172/en |
| 5170 | Mercy | https://islamic-content.com/dictionary/word/5170/en |
| 7771 | The Qur'an | https://islamic-content.com/dictionary/word/7771/en |
| 10849 | Revelation | https://islamic-content.com/dictionary/word/10849/en |
| 6732 | Worship | https://islamic-content.com/dictionary/word/6732/en |
| 5979 | The sharia | https://islamic-content.com/dictionary/word/5979/en |
| 7399 | Fatwa | https://islamic-content.com/dictionary/word/7399/en |
| 3911 | Heaven | https://islamic-content.com/dictionary/word/3911/en |
| 3903 | The jinn | https://islamic-content.com/dictionary/word/3903/en |
| 484 | The life to come / the hereafter | https://islamic-content.com/dictionary/word/484/en |
| 11207 | The Last Day | https://islamic-content.com/dictionary/word/11207/en |
| 9661 | The return | https://islamic-content.com/dictionary/word/9661/en |
| 196 | Ijtihad | https://islamic-content.com/dictionary/word/196/en |
| 9210 | School of fiqh | https://islamic-content.com/dictionary/word/9210/en |
| 4887 | Supplication | https://islamic-content.com/dictionary/word/4887/en |
| 5023 | Remembrance | https://islamic-content.com/dictionary/word/5023/en |
| 7670 | The qiblah | https://islamic-content.com/dictionary/word/7670/en |
| 8189 | The KaꜤbah | https://islamic-content.com/dictionary/word/8189/en |
| 2060 | Barzakh | https://islamic-content.com/dictionary/word/2060/en |
| 454 | Disagreement | https://islamic-content.com/dictionary/word/454/en |
| 4769 | Wine | https://islamic-content.com/dictionary/word/4769/en |

Cited Saheeh ayat outside Surah 55 (`en-saheeh-1947-cited.json`, local only, from the pinned raw
Quranpedia book 1947): 2:144, 5:90-91, 112:1-4 (and 55:1, 55:26-27, 55:46 from the Surah 55 file).
