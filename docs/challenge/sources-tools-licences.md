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
