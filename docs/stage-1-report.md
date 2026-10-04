# Stage 1 report — English translation layer: inspection

Status: **inspection only.** Nothing implemented, no instrumentation changed, no capture run.
Line references are to `main` at `a506e72`.

---

## Performance evidence — accepted constraints (C1–C8)

C1. **There is currently NO full-surah performance capture.** No `frame-stats.txt`,
   `ab-capture.txt` or other performance output is in the repo or its history.

C2. **The only recorded on-device result is commit `330f420`** (2026-09-16, the 30-second
   Stage 5 A/B), recorded in the commit message only:

   | phase | frames | dropped | peak footprint |
   | --- | --- | --- | --- |
   | environment loaded | 2701 | 0 | 200.41 MB |
   | empty scene | 2701 | 0 | 188.74 MB |

   "0 dropped" means **the app's update loop missed no refresh.** It says nothing about the
   render server.

C3. **`SceneEvents.Update.deltaTime` is vsync-quantized** in the observed capture (mean, p95
   and worst all exactly 11.111 ms = 1/90 s). **Do not use mean/p95 `deltaTime`, or the
   environment-vs-empty `deltaTime` difference, as evidence of rendering cost or remaining
   frame budget.**

C4. **RealityKit content is rendered by the visionOS render server, outside the app process.**
   Render-server deadline misses can occur with no change in app-side `deltaTime`. Treated as
   documented platform behaviour, not a hypothesis. (Source: Apple's WWDC23 session "Optimize
   app power and performance for spatial computing", which introduces RealityKit Trace and
   the render-server frame metrics. Not re-fetched for this report.)

C5. **Existing instrumentation may be used for:**
   - missed refreshes in the app's update loop
   - large app-side hitches, at refresh-interval (11.1 ms) resolution
   - `ProcessInfo` thermal-state observation
   - app memory-footprint observations (`MemoryProbe`, `phys_footprint`)

C6. **It does NOT establish:**
   - actual CPU or GPU rendering cost
   - render-server dropped frames
   - remaining time inside the 11.111 ms frame budget
   - the claimed 2 ms rendering headroom
   - full-session thermal stability

C7. **Actual cost of adding an English translation layer: NEEDS DEVICE TEST.**

C8. **FrameStats instrumentation is not modified during Stage 1. No new capture is run.**

### Instrumentation, for reference

| file | role |
| --- | --- |
| `QuranSpatial/FrameStats.swift` | pure value type; dropped = delta > 16.7 ms (`:27`), hitch = delta > 50 ms (`:30`) |
| `QuranSpatial/DissolveDriver.swift:290` | `recordFrame`: counts only frames while `.playing` (`:302`), discards the first frame (`:293`) |
| `QuranSpatial/FrameStatsLog.swift` | writes `Documents/frame-stats.txt` on device |
| `QuranSpatial/EnvironmentCapture.swift` | A/B capture to `Documents/ab-capture.txt`; off (`:38`) |

Per-ayah hitch durations go to os_log only (`DissolveDriver.swift:360`), not to the file. The
file holds the **latest run only**: `beginRun` (`FrameStatsLog.swift:38`) replaces all rows,
and fires on the first playing frame of every run, including a new launch.

---

## P1. Observer effect — FrameStatsLog writes (report only)

**Thread / queue.** Main thread. `FrameStatsLog` is `@MainActor` (`FrameStatsLog.swift:22`);
its caller `DissolveDriver` is `@MainActor` (`DissolveDriver.swift:24`); the call chain starts
in the `SceneEvents.Update` handler, which runs its body under `MainActor.assumeIsolated`
(`ImmersiveView.swift:251–252`).

**Synchronous.** Yes. `flush()` (`FrameStatsLog.swift:56–63`) joins every row into one string
and calls `String.write(to:atomically: true, encoding:)` inline — no `Task`, no dispatch, no
background queue. `atomically: true` means Foundation writes a temporary file and renames it
over the target. The **whole file** is rewritten on every append (`:49–52`).

**How many writes, and when.**

| trigger | writes | call site |
| --- | --- | --- |
| first playing frame of a run | 1 (header) | `DissolveDriver.swift:305–310` → `FrameStatsLog.swift:38` |
| each ayah boundary | 1 (one row) | `DissolveDriver.swift:315` → `reportSegment` `:354` |
| surah complete | 3 (last ayah row, blank, SESSION) | `ImmersiveView.swift:331` → `DissolveDriver.swift:380–388` |
| run ends early (idle / backgrounded) | 3 | `ImmersiveView.swift:336, 341` → `DissolveDriver.swift:370–377` |

A full surah is therefore ~1 + 78 + 3 synchronous whole-file rewrites; the file is at most
~85 lines. Each boundary write also makes one `os_log` call (`DissolveDriver.swift:355–361`)
and sets the observed property `latestSegmentReport` (`:353`), which the debug HUD reads
(`DuaDebugHUDView.swift:107`).

**Timing relative to the dissolve at an ayah boundary.**

- The segment index changes when the AVPlayer boundary observer fires on the main queue and
  hops to `@MainActor` (`RecitationCoordinator.swift:167–169`), setting `currentSegmentIndex`
  (`:230`).
- The row is written on the **first `SceneEvents.Update` tick after that change**, inside
  `tick` → `recordFrame` (`DissolveDriver.swift:245–246, 313–315`).
- `tick` calls `recordFrame` **before** `pushProgress` (`:246–247`), so on that tick the
  write happens before the frame's progress value is set.
- At that moment the outgoing ayah's 0.8 s dissolve has just finished (`Dissolve.swift:77–79`)
  and the incoming ayah is at `progress == 1`, the start of its 0.5 s fade-in
  (`Dissolve.swift:69–72`, `DissolveDriver.swift:215`). **The write lands on the first frame
  of the incoming fade-in, when the text is fully dissolved.**
- The same boundary also triggers, on the main actor, the RealityView `update:` closure →
  `applyCurrentAyah` (`ImmersiveView.swift:289–292, 350`): new material bind and a new plane
  mesh. **The order of that closure relative to the `SceneEvents.Update` tick within a frame
  cannot be determined from the code.**
- **Self-measurement:** the delta recorded on the writing tick was measured *before* the
  write. Any cost of the write shows up in the **next** tick's delta, which is attributed to
  the **new** ayah's row, not the one being written.

### Follow-up P1a — which frame does texture creation run in?

**Not the boundary frame, in the ordinary case. It runs during the previous segment, through
the 3-texture cache.**

- On the boundary into segment *n*, `applyCurrentAyah` prefetches *n*, *n+1* and *n−1*
  (`ImmersiveView.swift:358–367`). *n* and *n−1* are already cached, so only *n+1* starts a
  job (`AyahTextureCache.swift:57`).
- The texture for *n* was requested one boundary earlier, on entering *n−1*, as that
  segment's *n+1* neighbour. Its main-actor `TextureResource(image:)` call (`finish`,
  `AyahTextureCache.swift:69–83`) ran when that raster job completed, **during segment *n−1***.
- The job started on the boundary frame is for *n+1*. Its `finish` comes back to the main actor
  through `await` (`AyahTextureCache.swift:65`), in a **later** main-actor turn than the one that
  started it. The code does not fix how many frames later. The cache's own header gives the
  scale: a five-glyph string rasterizes in 43 ms (`AyahTextureCache.swift:7–8`).

**Exception — the texture is not ready at the boundary.** If *n*'s raster has not finished (the
first segment, a seek, or a segment shorter than its neighbour's raster time),
`applyCurrentAyah` returns at `ImmersiveView.swift:370` and the old plane stays. When `finish`
later writes `entries` (`AyahTextureCache.swift:81`), which the update closure reads through
`entry(for:)` (`:52`), the closure re-runs. **Then texture creation, material bind and plane
rebuild all fall in one burst of main-actor work, off the boundary frame.**

**Side effect of every `finish`, not only the late one:** writing `entries` re-runs the update
closure once per completed texture. That pass is cheap: three prefetch no-ops, one evict, and an
early return on the name match at `ImmersiveView.swift:377`.

### Follow-up P1b — everything on the main actor around the boundary frame

The boundary frame is not guaranteed to be a single frame. The index change, the update
closure and the `SceneEvents.Update` tick are three separate main-actor entries whose relative
order and frame placement the code does not fix. Everything triggered by the boundary:

1. **Index change.** The AVPlayer boundary observer fires on `DispatchQueue.main` and hops again
   via `Task { @MainActor }` (`RecitationCoordinator.swift:164–169`). `syncToCurrentTime` reads
   the player clock and binary-searches segments (`:209–215`). `apply` sets
   `currentSegmentIndex` and `currentText` (`:228–232`). Both are observed
   (`RecitationCoordinator.swift:21, 48, 54`).
2. **RealityView update closure** (`ImmersiveView.swift:289–292`):
   - `duaDebugVisualization.update(with:)` (`:290`)
   - `applyCurrentAyah` (`:350–426`):
     - 3 × `prefetch` (`:358–367`), 1 of which inserts into `inFlight` and spawns a detached
       task
     - `evict` (`:368`), releasing segment *n−2*'s `TextureResource` (`AyahTextureCache.swift:86–90`)
     - material bind: a copy of the template plus 4 `setParameter` calls
       (`DissolveDriver.swift:199–231`)
     - `MeshResource.generatePlane` + `ModelComponent` assignment (`ImmersiveView.swift:403–406`)
     - position, orientation and name writes (`:414–425`)
3. **`SceneEvents.Update` tick** (`ImmersiveView.swift:251–289`):
   - sky dome and star field `setPosition` (`:270–271`)
   - `dissolve.tick` (`:284`) → `recordFrame` → `reportSegment` (`DissolveDriver.swift:349–362`):
     - string formatting of the summary
     - a write to observed `latestSegmentReport` (`:353`)
     - **the synchronous whole-file write** (`FrameStatsLog.swift:56–63`)
     - one `os_log` call (`DissolveDriver.swift:355–361`)
   - the thermal-state read, on the ticks where the 90-frame counter rolls over (`:328–337`)
   - `pushProgress` (`:250–287`): computes progress. On the boundary it is 1 and equal to
     `lastAppliedProgress`, which the bind set to 1 (`:230`), so the `setParameter` and
     `materials` writes are skipped (`:268`). If the tick runs **before** the closure, it still
     evaluates the outgoing segment, which is past its end and clamped to 1, so it is also
     skipped.
4. **SwiftUI re-evaluation of `DuaDebugHUDView`**, because `latestSegmentReport` changed
   (`DuaDebugHUDView.swift:107`). The attachment is built even when the HUD is not added to the
   scene (`ImmersiveView.swift:219–222`). Whether SwiftUI re-renders an attachment that is not in
   the scene is not determinable from the code.

**Not in the boundary frame:** `TextureResource` creation (P1a), the Core Text raster (detached),
and the outgoing `dissolveTicket` increment, which fires 0.8 s *before* the boundary
(`RecitationCoordinator.swift:186–189`).

---

## P2. English layer inventory — what it would add per ayah

Counts are what the **current Arabic path** does per ayah, and what a second layer built the
same way would add. Counts and code paths only; no timing estimates.

### Current Arabic path, per ayah

| item | count | where |
| --- | --- | --- |
| entities | **1**, persistent — `ayahEntity` is reused, not rebuilt | `ImmersiveView.swift:61, 203` |
| meshes | **1 generated per ayah transition** (`MeshResource.generatePlane`, main actor) | `ImmersiveView.swift:403–406` |
| draw calls | **1** (one plane, one material part) | `ImmersiveView.swift:405` |
| materials | **1** `ShaderGraphMaterial` copy per ayah, 4 parameters set at bind | `DissolveDriver.swift:199–216` |
| per-frame material writes | 1 `setParameter("progress")` + 1 `materials` assignment per frame **while progress is changing** (0.5 s in + 0.8 s out); skipped when constant | `DissolveDriver.swift:250–287` |
| textures | **1 per ayah**; **3 resident** (prev / current / next) | `AyahTextureCache.swift:12–14`; `ImmersiveView.swift:358–368` |
| texture format | RGBA8 premultiplied, `.color` semantic, **no mipmaps** → `w × h × 4` bytes | `ArabicTextRasterizer.swift:191–195`; `AyahTextureCache.swift:75–77` |
| texture width | ≤ **1360 px** (`ceil(40° × 34 px/°)`) | `AyahPlaneGeometry.swift:124` |
| texture height | `(line block height) + 2 × 48 px`, grows with line count | `ArabicTextRasterizer.swift:186–187` |
| sort order | its own `ModelSortGroupComponent` order in the sky/text group | `ImmersiveView.swift:207–209`; `EnvironmentLighting.swift:272–274` |

### Work at each ayah transition (Arabic, today)

1. **1 new Core Text raster job**, off the main actor: `Task.detached(priority: .userInitiated)`
   running `rasterizeWrapped` (framesetter, frame, per-line `CTLineDraw` into a `CGContext`)
   for segment *n+1* (`AyahTextureCache.swift:59–66`; `ArabicTextRasterizer.swift:141–215`).
2. **1 `TextureResource(image:)` creation on the main actor** when that job finishes — some
   time after the boundary, at a point not fixed by the code (`AyahTextureCache.swift:69–83`).
3. **1 eviction** of segment *n−2* (`AyahTextureCache.swift:86–90`).
4. **1 material bind** (4 `setParameter` calls) + **1 `generatePlane`** + **1 `ModelComponent`
   assignment**, main actor, in the RealityView `update:` closure (`ImmersiveView.swift:376–425`).

### What a second, English layer built the same way would add, per ayah

| item | added |
| --- | --- |
| entities | +1 (persistent) |
| meshes | +1 `generatePlane` per transition, main actor |
| draw calls | +1 |
| materials | +1 material instance; if it also dissolves, +1 `setParameter` and +1 `materials` write per frame during both fades |
| textures | +1 per ayah; **+3 resident** in the window; RGBA8, no mips, `w × h × 4` bytes each |
| transition work | +1 detached Core Text raster job; +1 main-actor `TextureResource` creation; +1 eviction; +1 material bind; +1 `ModelComponent` assignment |
| sort order | +1 explicit draw order in the sky/text sort group — without one, RealityKit's distance sort decides (the Stage 8 black-rectangle trap noted at `ImmersiveView.swift:204–206`) |

### Code-path findings affecting an English layer (no decisions taken)

- **`rasterizeWrapped` is Arabic-specific.** It hardcodes a right-to-left base writing
  direction (`ArabicTextRasterizer.swift:220–231`) and resolves its font from the Amiri ship
  font via `CTFontCreateForString` (`:91–98`). English cannot go through it unchanged; the font
  and writing direction are open decisions.
- **Dissolve material compatibility.** The material samples one float channel through
  `ND_image_float` and takes its colour from `textColor` (CLAUDE.md). An English raster drawn
  as opaque white glyphs in the same format would fit that contract. A raster that needed real
  per-pixel colour would not.
- **Texture dimensions for English are not measurable from the repo.** They depend on font,
  em size and wrap width, none of which is decided.

---

## P3. Thermal bar — open decision

Session PASS currently requires the worst thermal state to be **`.nominal` throughout**
(`DissolveDriver.swift:382`). Reaching `.fair` at any point fails the run. The state is
sampled every 90 recorded frames (`:142, 328–337`) and the worst value is kept.

**Open decision; not changed.** Whether `.fair` should fail a ten-minute session is for the
project to decide, not something to adjust inside Stage 1.

---

## 8. Quran text + English translation

**English edition decided 2026-09-29 — see [Decisions (human)](#decisions-human).**

Status key: **IMPLEMENTED** (file:line + snippet) · **DOCUMENTED ONLY** (where) · **ABSENT** ·
**NEEDS DEVICE TEST**. Inspection only; nothing was fetched, selected or changed.

The directive's competition/demo design is **not** the locked V1 and is not treated as a decision
here. English placement, vertical offset, dissolve sharing, typography and rendering architecture
are **not decided** in this report.

### 8.1 Current Quran text presentation

**Where the Arabic text comes from — IMPLEMENTED.** One bundled local file,
`QuranSpatial/Resources/ar-rahman-text.json`, decoded once at launch.

- `RecitationCoordinator.swift:104` — `Bundle.main.url(forResource: "ar-rahman-text", withExtension: "json")`
- `RecitationCoordinator.swift:112` — `textFile = try JSONDecoder().decode(RecitationTextFile.self, …)`
- Segment → text: `RecitationText.swift:45–46` — `index == 0 ? intro : ayat.first { $0.ayah == index }?.text`
- The file carries `source`, `sourceURL`, `sourceSHA256`, `license` and `copyright` (Tanzil
  Uthmani 1.1, CC BY 3.0), decoded at `RecitationText.swift:21–26`.

Side finding: `Ayah.swift:16` holds a **hand-typed** ayah 1:
`Ayah(surah: 55, ayah: 1, arabicText: "الرَّحْمَٰنُ")`. It is **not byte-identical** to the corpus,
which begins with U+0671 alif wasla (ٱ) where the literal has U+0627 (ا). It is **not displayed**.
It is used only as a probe string (`FontIdentityReport.swift:37`;
`QuranSpatialTests.swift:19, 39, 103, 114`). CLAUDE.md forbids hand-typed Quran text in source and
tests. Recorded, not fixed.

**How the displayed ayah is selected — IMPLEMENTED, derived from the audio clock.**

- Player time → segment: `RecitationCoordinator.swift:259` — `static func segmentIndex(at seconds: Double, in segments: [RecitationSegment]) -> Int` (binary search).
- Applied from three places: segment-start boundary observers (`:167` — `player.addBoundaryTimeObserver(forTimes: starts, queue: queue)`), the 1 Hz reconciliation (`:191`), and each seek's completion (`:154–156`).
- State write: `RecitationCoordinator.swift:229–230` — `guard index != currentSegmentIndex || currentText == nil else { return }` / `currentSegmentIndex = index`.
- View side: `ImmersiveView.swift:356` — `let index = recitation.currentSegmentIndex`, then the texture lookup at `:370` and bind/rebuild at `:376–425`.
- `currentText` (`RecitationCoordinator.swift:54`) is written but has **no consumer** outside the coordinator. The view reads text by index (`ImmersiveView.swift:359`).

**How the dissolve/transition is triggered — IMPLEMENTED as a pure function of the audio clock. No event triggers it.**

- `DissolveDriver.swift:256–260` — `Dissolve.progress(atAudioTime: recitation.currentAudioTime, segment: segment, isFinalSegment: …)`, evaluated every `SceneEvents.Update` tick (`ImmersiveView.swift:284`).
- Shape: fade-in over 0.5 s from segment start and fade-out over the last 0.8 s. The final segment never fades out (`Dissolve.swift:17, 24, 58–82`).
- `dissolveTicket` is **incremented and never consumed**: `RecitationCoordinator.swift:235` — `dissolveTicket &+= 1`, with no other reference in the app. CLAUDE.md calls it deliberately unconsumed. It is not what drives the dissolve.

**Can the displayed text be pinned? — ABSENT.** The app has no pin, anchor-ayah, hold or Ask-mode
state. Searching `QuranSpatial/`, `QuranSpatialTests/`, `tools/` and `Packages/` for `pin`,
`anchor ayah`, `Ask`, `LLM` and `translation` finds nothing relevant. The displayed ayah is always
what `segmentIndex(at:)` returns for the player's current time. "Pinned to the anchor ayah during
Ask mode" has no code path to attach to today.

**Does seeking control the text directly or indirectly? — IMPLEMENTED, indirectly.**
`seek(toSegment:)` moves the **player**. The index is re-derived from the new player time only in
the seek's completion handler:

- `RecitationCoordinator.swift:152–156` — `player?.seek(to: CMTime(seconds: segment.start, …)) { … syncToCurrentTime() }`
- Called with **0 only**: `:131` (restart, in `start()`) and `:145` (`debugStop()`, `#if DEBUG`). **ABSENT:** a user-facing seek, and a seek to any other segment, including an anchor ayah.
- Stale comment, DOCUMENTED ONLY: `RecitationCoordinator.swift:47` — "Resume restarts this segment from its start." No resume path exists (CLAUDE.md: dua is entry-only).

### 8.2 Seeking, restart and the not-ready path

Folded in from the prepared section. The boundary-frame analysis is P1a/P1b.

**When the path is taken — IMPLEMENTED.** The plane changes only once the texture exists:
`ImmersiveView.swift:370` — `guard let entry = textures.entry(for: index) else { return }`. The
texture for *n* is normally requested one segment ahead (P1a). It is not ready in four cases:

| case | code | status |
| --- | --- | --- |
| restart after completion | `RecitationCoordinator.swift:130–131` — `if playbackState == .finished \|\| playbackState == .stopped { seek(toSegment: 0) }`. The cache then holds {77, 78, 79} (`ImmersiveView.swift:368`), so segment 0 is always cold | IMPLEMENTED |
| debug abort | `RecitationCoordinator.swift:145` — `seek(toSegment: 0)`. Segment 0 is cold unless the abort came during segment 0 or 1 | IMPLEMENTED (DEBUG only) |
| first segment, first launch | `.task` prefetch when the view appears, `ImmersiveView.swift:306–309` | whether acceptance ever beats the raster: **NEEDS DEVICE TEST** |
| slow raster | any boundary where *n*'s raster outlasts segment *n−1* | raster time is not instrumented (8.5): **NEEDS DEVICE TEST** |

`start()` calls `syncToCurrentTime()` (`RecitationCoordinator.swift:136`) before the asynchronous
seek completes. Which segment that first call sees: **NEEDS DEVICE TEST**.

**What the plane shows until the texture arrives — code path IMPLEMENTED; appearance NEEDS DEVICE TEST.**

- Mesh and material are unchanged, because the early return at `ImmersiveView.swift:370` comes before every entity write.
- Progress follows the **old** bound segment: `DissolveDriver.swift:251–253` — `guard var material = bound, let index = boundIndex, let segment = recitation.segment(forIndex: index)`.
  - Forward boundary, bound segment not final: progress clamps to 1 (`Dissolve.swift:77–79`, the out-phase branch at `elapsed >= outStart`). The old text stays invisible.
  - Seek back to 0 (debug abort): `Dissolve.swift:69` — `guard elapsed > 0 else { return 1 }`. Invisible.
  - **Restart after completion:** the bound segment is ayah 78, held at 0 by `Dissolve.swift:75` — `guard !isFinalSegment else { return 0 }`. When the seek lands, `elapsed ≤ 0` and progress becomes 1 on one tick. **Finding: ayah 78 disappears in one frame instead of dissolving out.** Recorded, not fixed.
- First launch, before any texture: `bound` is nil, so `pushProgress` returns (`DissolveDriver.swift:251–254`). The entity has no `ModelComponent` yet (`ImmersiveView.swift:61` — `@State private var ayahEntity = ModelEntity()`), so nothing is drawn.

**What progress is applied when the late texture lands — IMPLEMENTED.**

1. The bind sets progress to 1: `DissolveDriver.swift:216` — `try material.setParameter(name: "progress", value: .float(1))`, and `:230` — `lastAppliedProgress = 1`.
2. The next tick evaluates segment *n* at the live time, *L* seconds into it (`DissolveDriver.swift:256–260`):

| *L* | progress | source |
| --- | --- | --- |
| ≤ 0 | 1 | `Dissolve.swift:69` |
| 0 < *L* < 0.5 s | `1 − L/0.5`: fade-in starts partway | `Dissolve.swift:71–72` |
| 0.5 s ≤ *L* < out-start | **0: full opacity in one frame** | `Dissolve.swift:81` |
| ≥ out-start | already partly dissolved out | `Dissolve.swift:77–79` |

**Finding:** rows 3 and 4 contradict `Dissolve.swift:22–23`, "The next ayah is never hard-cut in."
The rule holds only when the texture is ready at the boundary. Recorded, not fixed. Whether it
happens in practice: **NEEDS DEVICE TEST**.

Fallback variant: a failed bind installs `UnlitMaterial` at full opacity regardless of *L*
(`ImmersiveView.swift:392–395`). It is not retried within the segment (see Other findings).

**Directive target: "seeking/restarting the anchor ayah must not cause either text layer to
dissolve twice." Current behaviour:** no seek to a non-zero segment exists (ABSENT), so this cannot
happen today. What the pure function would return can be read from the code. A seek to the
**current** segment's start leaves the index unchanged (`RecitationCoordinator.swift:229` guard),
so there is no rebind. Progress jumps to 1 at `elapsed ≤ 0` (`Dissolve.swift:69`), then fades in
over 0.5 s: one cut out plus one fade in, not two dissolves. **On-screen result: NEEDS DEVICE
TEST.** For English, the not-ready path would exist for each layer if each has its own texture and
entry check; see P2.

### 8.3 English translation infrastructure — what exists

| question | answer | status and evidence |
| --- | --- | --- |
| Does the repo contain English translation data? | **No** | **ABSENT.** Tracked resources are `ar-rahman-text.json`, `ar-rahman-timings.json`, `rahman-single.mp3`, the environment `.usdz` and the font. `ar-rahman-text.json` has the keys `source, sourceURL, sourceSHA256, license, copyright, surah, script, normalization, note, intro, ayahCount, ayat[{ayah, text}]`, with no translation field. No match for `translat`, `english`, `sahih`, `pickthall`, `yusuf`, `hilali`, `tafsir`, `quranpedia` or `quran.com` in code, tests, tools or packages. The only untracked path is `docs/` |
| Exact source and storage location | none | ABSENT |
| Is translation displayed? | No | ABSENT. The only text path is `recitation.text(forSegmentIndex:)`, which returns Arabic (`ImmersiveView.swift:359`) |
| Is it synchronized with Arabic? | n/a | ABSENT |
| Local data or generated? | n/a | ABSENT. The app has no LLM or network text-generation code |
| Licensing/attribution evidence | none for English | **LICENSING EVIDENCE NOT FOUND** |

For comparison only (this is the Arabic, not English): Tanzil attribution is IMPLEMENTED in
`ar-rahman-text.json` (the `copyright` field) and at `CreditsView.swift:37–38` —
`Text(textFile?.source ?? …)` / `Link("tanzil.net", destination: URL(string: "https://tanzil.net/")!)`.
No translation source was searched for or selected.

### 8.4 Text rasterizer — reusable for another language without changing Arabic?

**Parameters — IMPLEMENTED:** `ArabicTextRasterizer.swift:141–147` —
`rasterizeWrapped(_ string:, fontSizePixels:, maxContentWidthPixels:, padding:, textColor:)`.

| parameterized by | status |
| --- | --- |
| text content | yes, `string` |
| font size, wrap width, padding, colour | yes, arguments |
| **font** | **no** (P2) |
| **writing direction** | **no** (P2) |
| **alignment** | **no** (below) |
| **language** | **no.** No language or locale argument, and nothing sets `kCTLanguageAttributeName` |

Hardwired points **already covered in P2** and not repeated: the ship-font constant and the
`CTFontCreateForString` cascade (`ArabicTextRasterizer.swift:36, 91–98`), and the right-to-left
base writing direction (`:220–231`).

Hardwired points **not covered by P2**:

**Alignment**

- Each line is centred by hand: `ArabicTextRasterizer.swift:201` — `let x = padding + (maxLineWidth - lineWidths[index]) / 2`. There is no alignment argument, and the paragraph style sets writing direction only (`:220–231`).
- Line width comes from `.useOpticalBounds`: `:180` — `CTLineGetBoundsWithOptions(line, [.useOpticalBounds]).width`. CLAUDE.md records this option as a no-op for the fonts tested and as **underestimating** ink where Arabic marks overhang (DOCUMENTED ONLY: CLAUDE.md, "Core Text degrades silently" and "horizontal bounds underestimate ink"). Its behaviour with a Latin font: **NEEDS DEVICE TEST** (CLAUDE.md: macOS Core Text figures do not transfer).

**Sizing and layout**

- Font size comes from one angular em chosen for the Arabic: `AyahPlaneGeometry.swift:92` — `static let textAngularEmDeg: Float = 2.2`, through `fontSizePixels` (`:113–116`). It is a single global with no per-layer size, passed in at `ImmersiveView.swift:362`.
- Wrap width: `AyahPlaneGeometry.swift:73` — `static let maxAngularWidthDegrees: Float = 40`, giving `maxContentWidthPixels` (`:125`). Single global.
- Padding: `AyahPlaneGeometry.swift:95` — `static let paddingPixels: Float = 48`. The rationale (Arabic mark overhang, 0.265 em) is DOCUMENTED ONLY, in CLAUDE.md under "Fixed size and wrapping".
- Raster height comes from the lines' typographic ascent and descent: `ArabicTextRasterizer.swift:179` — `CTLineGetTypographicBounds(line, &ascent, &descent, nil)`, and `:188` — `let imageHeight = Int(ceil((top - bottom) + padding * 2))`.
- Placement has one text root and one anchor. The first baseline sits at a fixed world height, `AyahPlaneGeometry.swift:35` — `static let ayahHeight: Float = 24.5`, and the plane is offset from it at `ImmersiveView.swift:414–421` via `planeCenterOffsetFromBaseline` (`AyahPlaneGeometry.swift:227`). The pitch is chosen for the one-line Arabic case (`AyahPlaneGeometry.swift:56–61`, comment). No second anchor exists.
- One entity and one cache, keyed by segment index only: `ImmersiveView.swift:61` (`ayahEntity`), `AyahTextureCache.swift:48` — `private var entries: [Int: Entry] = [:]`, and the entity name at `ImmersiveView.swift:376` — `"ayah-\(index)-…"`. A second language in the same cache would collide on that key.
- The text source is Arabic by construction: `ImmersiveView.swift:359` — `recitation.text(forSegmentIndex: neighbour)`.

**Texture and UV**

- Pixel format is RGBA8 premultiplied, device RGB: `ArabicTextRasterizer.swift:191–194` — `bitsPerComponent: 8 … bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue`. The texture is `.color` with no mipmaps: `AyahTextureCache.swift:76` — `options: .init(semantic: .color, mipmapsMode: .none)`.
- Glyphs are drawn **white** by default argument: `ArabicTextRasterizer.swift:146` — `textColor: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)`.
- The material samples **one float channel** as glyph coverage: `DissolveMaterial.usda:98` — `info:id = "ND_image_float"`. Colour comes from `inputs:textColor` (`:47` — `color3f inputs:textColor = (1, 1, 1)`, wired at `:211`). **No Swift code sets `textColor`**; only `DissolveMaterialReport.swift:144` probes it. So any layer through this material renders in the authored colour, which is white.
- UV is the plane's own 0–1 texture coordinate: `DissolveMaterial.usda:77, 101` — `ND_texcoord_vector2` feeds `TextImage.inputs:texcoord`. The plane is sized to the raster by one fixed scale (`ImmersiveView.swift:401–402` — `Float(entry.pixelSize.width) * AyahPlaneGeometry.metresPerPixel`), so the UV maps 1:1 onto the raster.
- Noise scale is normalised to the **Arabic** maximum raster width: `DissolveDriver.swift:114` — `noiseCellsAcrossWidth * width / Float(AyahPlaneGeometry.maxTextureWidthPixels)`. The cell count was chosen against the Arabic em (`DissolveDriver.swift:38–42`, a comment that still cites the pre-11d 3.0° em). A layer at a different em would get noise cells of the same angular size, not the same size relative to its letters.

**Conclusion:** the rasterizer **cannot be reused for English as it stands**. Its signature would
have to change, or a separate path be added. Font, writing direction, alignment and language are
all fixed inside it. Which option to take is a design decision and is not made here.

### 8.5 Structural rendering cost — the existing Arabic layer

No FPS estimate is made. **Actual frame impact of a second text layer: NEEDS DEVICE TEST.**
Frame-stats evidence is in C1–C8 and P1. Per-ayah structure, and what English would add, is in P2.
The status of each metric the directive asks for:

| metric | value | status |
| --- | --- | --- |
| texture dimensions | width ≤ 1360 px (`AyahPlaneGeometry.swift:124`); height = line block + 96 px (`ArabicTextRasterizer.swift:188`). **Per-ayah values at the current 2.2° em are not in the repo.** `TextPlacementProbe` writes them on device to `Documents/text-placement.txt`; no copy is in the repo. Its hardcoded `largestSegmentPixels = CGSize(width: 1259, height: 846)` (`TextPlacementProbe.swift:36`) was measured at the old 102 px em and is stale (Other findings) | bound IMPLEMENTED; per-ayah values **not recorded** |
| pixel format | RGBA8 premultiplied, no mipmaps | IMPLEMENTED (8.4) |
| textures per displayed ayah | 1; 3 resident (previous, current, next) | IMPLEMENTED (P2) |
| entities per displayed ayah | 1, persistent and reused | IMPLEMENTED (P2) |
| materials per displayed ayah | 1 `ShaderGraphMaterial` copy per ayah, from one loaded template | IMPLEMENTED (P2) |
| draw calls | **Not exposed by existing instrumentation for the text layer.** Only the star field reports its own draw calls (`ImmersiveView.swift:155–157`). "1 per plane" is a structural count (P2), not a measurement | **ABSENT** as a measurement |
| rasterization time | **Not recorded.** Nothing times `rasterizeWrapped` or `TextureResource(image:)`. The only figure is a comment, "a five-glyph string in 43ms" (`AyahTextureCache.swift:7–8`) | **ABSENT** (the comment is DOCUMENTED ONLY) |
| texture memory | `width × height × 4` bytes per texture (RGBA8, no mips), so at most `1360 × height × 4`; 3 resident. Not calculable per ayah without the dimensions above | formula known; values **not recorded** |
| recreated or reused per ayah | entity **reused**; mesh **recreated** (`generatePlane`, `ImmersiveView.swift:404`); material **re-bound** from the template (`DissolveDriver.swift:202`); texture **recreated** for each ayah and evicted outside the window (`AyahTextureCache.swift:75, 86–90`) | IMPLEMENTED |

### 8.6 Licensing (English)

**LICENSING EVIDENCE NOT FOUND.** No English translation is present, so there is no source,
notice or attribution requirement to report. No external search was made. Nothing here implies
that availability through any service grants App Store redistribution rights.

---

## Other findings from this inspection (report only)

Recorded as findings and **deliberately not fixed** in Stage 1: DissolveDriver parameter
binding, stale raster-size documentation, FrameStats logging (P1), English rendering
(P2, 8.4). The same applies to every item below.

- **Parameter binding is not individual in the dissolve driver.**
  `DissolveDriver.material(forSegmentIndex:)` binds `textTexture`, `noiseScale`,
  `noiseOffset` and `progress` inside **one** `do`/`catch` (`DissolveDriver.swift:207–226`).
  One rejected parameter returns `nil` and the plane falls back to `UnlitMaterial`
  (`ImmersiveView.swift:384–396`). CLAUDE.md says "both drivers now bind each parameter in its
  own `do`/`catch`"; this path does not. Relevant if an English layer reuses this binding code.
  - **Follow-up — logging. Yes, the catch logs.** It sets `loadFailure` (`DissolveDriver.swift:218`)
    and calls `logger.fault` with `DISSOLVE PARAMETER BIND FAILED` and the full failure
    description, `privacy: .public` (`:220–224`). The logger is subsystem
    **`com.vrteek.quranspatial`**, category **`Dissolve`** (`:156`). `fault` level persists in
    release logging. `loadFailure` is also shown by the debug HUD (`DuaDebugHUDView.swift:79`).
    The log names the call site ("parameter bind, segment *n*") but **not which of the four
    parameters threw.**
  - **Consequence found while tracing it — a failed bind is not retried for that ayah.**
    `isMaterialLoaded` is `template != nil` (`DissolveDriver.swift:98`), and a bind failure
    does not clear `template`. So `expectedName` still ends in `-shader`
    (`ImmersiveView.swift:376`), the fallback `UnlitMaterial` is installed under that name
    (`:384–396, 425`), and the early return at `:377` then matches on every later pass. The plane
    shows the fallback under a name that says "shader" until the segment changes. The next
    segment attempts the shader again.
- **CLAUDE.md's per-ayah raster table is stale.** It was measured at a 102 px em.
  `textAngularEmDeg` is now 2.2° (`AyahPlaneGeometry.swift:92`), which the formula at `:113–116`
  puts at ≈ 71.7 px (computed from the constants, not measured). The 1259 × 846 / 878 × 346
  figures do not describe the current build. The current per-ayah dimensions are written by
  `TextPlacementProbe` to `Documents/text-placement.txt` on device; no copy is in the repo.
  The same stale figure is **hardcoded in source**: `TextPlacementProbe.swift:36` —
  `static let largestSegmentPixels = CGSize(width: 1259, height: 846)`, with
  `firstBaselineFromTopPixels: CGFloat = 233` beside it (`:40`), also measured at the old em.
- **Hand-typed Quran text in source (section 8.1).** `Ayah.swift:16` holds ayah 1 typed by hand.
  It differs from the Tanzil corpus in its first scalar (U+0627 against U+0671). It is used only as
  a probe string and in tests, and is never displayed.
- **Ayah 78 disappears in one frame on restart, and a late texture can appear at full opacity
  (section 8.2).** Both happen only when the texture is not ready at the boundary.
- **Stale comments.** `RecitationCoordinator.swift:47` still describes a resume path that does not
  exist, and `DissolveDriver.swift:38–42` still cites the pre-11d 3.0° em.

---

## Recommended measurements: A (Arabic only) vs B (Arabic + English)

The minimum needed later. **Not run in Stage 1.**

### M1 — RealityKit Trace, A vs B (sub-frame cost)

Instruments' RealityKit Trace template, RealityKit Frames track: render-server CPU and GPU
frame time and render-server dropped frames, per frame, over the same ayah range for A and B.

- **Can establish:** the render-server CPU/GPU cost difference of the English layer;
  render-server frame drops; how much of the 11.111 ms budget each configuration uses; whether
  the transition frames (mesh generation, texture creation, material bind) spike.
- **Cannot establish:** full-session thermal behaviour is only established if a full-session
  trace is recorded; the trace adds its own overhead. App-side main-thread stalls are not
  established unless the Time Profiler (M1b) is recorded alongside.

### M2 — `frame-stats.txt` over the same runs (app-side hitches only)

The existing instrument, unchanged, captured alongside M1.

- **Can establish:** missed refreshes in the app's update loop; app-side hitches over 50 ms at
  11.1 ms resolution; which ayah they fall in.
- **Cannot establish:** rendering cost, render-server drops, or headroom. **Do not read mean or
  p95 from it, and do not difference A against B on `deltaTime`.**

### M1b — Time Profiler on the main thread, recorded alongside M1

A main-thread CPU profile (Instruments Time Profiler) in the **same** trace session as
RealityKit Trace, over the same ayah boundaries. Signposts are not needed: the four
candidates are separate call stacks, so the profile tells them apart **without modifying
FrameStats**:

| work | symbol to look for | where |
| --- | --- | --- |
| stats write | `FrameStatsLog.flush` → `String.write(to:atomically:encoding:)` | `FrameStatsLog.swift:56–63` |
| plane rebuild | `MeshResource.generatePlane` under `applyCurrentAyah` | `ImmersiveView.swift:403–406` |
| material bind | `DissolveDriver.material(forSegmentIndex:)` → `setParameter` | `DissolveDriver.swift:199–231` |
| texture creation | `AyahTextureCache.finish` → `TextureResource.init(image:options:)` | `AyahTextureCache.swift:69–83` |

- **Can establish:** app main-thread CPU time per boundary, attributed to each of the four;
  whether texture creation lands near the boundary or in the previous segment (P1a); the same
  split for B's added English work.
- **Cannot establish:** render-server or GPU cost (that is M1); anything about rendering on
  frames where the main thread is idle. Sampling resolution limits it: a sub-millisecond call
  can be missed or under-counted in a single boundary, so read totals across many boundaries
  rather than one.

### Conditions for M1/M1b/M2 — identical for A and B

- **Same ayah range, including transitions**, and including ayah 33 (the only three-line
  ayah and the largest raster).
- Playback **and** the dissolve running; environment **on**.
- **Debug HUD in the same state in A and B, off if possible** (`ImmersiveView.showDebugHUD`,
  `ImmersiveView.swift:30`). It redraws at every boundary (follow-up P1b, step 4) and the
  shipping build will not have it.
- **The FrameStats logger is present in both A and B.** Its boundary write (P1) is part of
  both configurations' cost, not of the difference between them.
- Device **cool at start**, and the same time since launch.
- **Alternating order: A, B, B, A**, so thermal drift is not read as layer cost. Report each
  run separately, and the A–A and B–B spreads alongside the A–B difference.

### M3 — one full-surah run of the chosen configuration (thermal and memory)

Run once the configuration is chosen, with `frame-stats.txt` and a memory-footprint sample.

- **Can establish:** thermal state across a full-length session (against the open `.nominal`
  vs `.fair` decision, P3); peak app memory footprint with 3 + 3 textures resident; app-side
  hitches across all 79 transitions.
- **Cannot establish:** render-server cost or drops, unless a RealityKit Trace runs for the full
  session too. It is one run, so it is a data point, not a distribution.

### Retrieval

Pull on-device files to a scratch path, check size and that they parse, then move them.
Never pull into `capture/` (CLAUDE.md, Capture workflow). `frame-stats.txt` holds the latest
run only, so pull it after **each** run of the A, B, B, A sequence, before starting the next.

---

## Decisions (human)

Recorded 2026-09-29. These are decisions, not inspection findings. Stage 1 rules still apply:
nothing is implemented, no data is imported, and CLAUDE.md is not edited.

### English translation

- **Canonical edition: Saheeh International, Quranpedia book 1947.** Raw file SHA-256
  `8c08a8332fae34788f556e5d13a78fe45f68f607cf7a2dabd6596a7fad573978`, downloaded
  2026-09-28T21:44:25Z. Held outside the repo; **not imported.**
- **Quranpedia book 13638** is a different edition of the same translation (9 of 78 ayat in
  Surah 55 differ). **Comparison/reference only.**
- **Integrity: display verbatim; no runtime or model rewriting.** "Verbatim" means
  byte-identical to the text field produced from the pinned file by the extraction rules:
  strip the `(n) ` prefix, strip `[digits]` footnote markers, drop the footnote block. Nothing
  else. No Unicode, whitespace or punctuation normalisation. Compare with `isByteIdentical`
  over UTF-8, **never Swift `==`** — the text contains ā, ī and ’.
- **Verbatim includes punctuation as published.** 14 ayat end with ` -` (including refrains
  38, 47, 57, 63, 71, 73, 75) and 22 end mid-sentence.
- **Footnotes** (14 in Surah 55): metadata / Ask mode only; **never rendered as part of the
  ayah.**
- **Distribution blocked until a licence or permission is documented:** no translation text
  in the repo, in the public competition repo, or in any build installed beyond Mo's own
  devices.
- **Open:** English for segment 0 (the intro). Neither file has it under Surah 55.

Full decision record: claude.ai Project 'Quran AVP', doc
claude/english-translation-edition.md (outside the repo).

---

## Stage 1b — audio session, seeking, gaps, gesture (inspection)

Status: **inspection only.** Nothing implemented, CLAUDE.md and project settings untouched. Line
references are to `main` at `a506e72`. Status key as in item 8: **IMPLEMENTED** (file:line +
snippet) · **DOCUMENTED ONLY** (where) · **ABSENT** · **NEEDS DEVICE TEST**. SDK facts are quoted
from the visionOS 27.0 SDK headers in `/Applications/Xcode-beta.app` and are DOCUMENTED ONLY: they
say what the API declares, not what the device does.

### B1. Audio session

**Current configuration — ABSENT.** Nothing in the app touches `AVAudioSession`. No
`setCategory`, `setMode`, `setActive`, category options, interruption or route-change observer
exists in `QuranSpatial/` or `QuranSpatialTests/`. The only audio object is a bare player:

- `RecitationCoordinator.swift:118` — `player = AVPlayer(url: audioURL)`
- `:133` — `player.play()`; `:143` — `player?.pause()` (in `debugStop()`, `#if DEBUG`, the only pause)

So the session runs on the platform default. **Which category, mode and options that default is
on visionOS 27, and what `AVAudioSession.sharedInstance()` reports while the recitation plays:
NEEDS DEVICE TEST.** The SDK headers do not state the default (`AVAudioSessionTypes.h:95–103`
describes the categories without naming one as default). Not inferred from iOS.

Also ABSENT: `setIntendedSpatialExperience` (visionOS-only, `AVAudioSession.h:541`), so the system
chooses how the recitation is spatialized; `isNowPlayingCandidate` (`:560–561`).

**Microphone permission — ABSENT.** The only usage string in build settings is
`INFOPLIST_KEY_NSHandsTrackingUsageDescription` (`project.pbxproj:245`). There is no
`NSMicrophoneUsageDescription`. Recording cannot be added without it, and adding it is a build
setting, so it is a change for Xcode (CLAUDE.md, Project file rules). The record-permission calls on
`AVAudioSession` are deprecated in favour of `AVAudioApplication` (`AVAudioSession.h:123, 133`).

**Pause and resume today.** The planned flow is pause, record, resume. None of these steps exists:

- **Pause — ABSENT** outside `debugStop()`. `PlaybackState` has no paused case by design:
  `PlaybackState.swift:9` — "There is no `paused`."
- **Resume — ABSENT, and `start()` cannot be used for it.** If `playbackState` is left at
  `.playing` during the pause, `start()` returns early: `RecitationCoordinator.swift:128` —
  `guard playbackState != .playing else { return }`. If it is set to `.stopped`, `start()` rewinds
  to the intro: `:130–131` — `if playbackState == .finished || playbackState == .stopped { seek(toSegment: 0) }`.
- Stale comments, DOCUMENTED ONLY. `ExperiencePhase.swift:22` describes `.reciting` as "audio is
  playing or paused mid-surah". `AyahTextureCache.swift:13–14` mentions "a seek backwards or a
  release-and-resume". `RecitationCoordinator.swift:47` says "Resume restarts this segment from its
  start". No pause or resume path exists.

**Pausing the player without a matching state change does the following. Each item is read from
the code:**

- The dissolve freezes wherever the clock stopped. Progress is a pure function of
  `currentAudioTime` (`DissolveDriver.swift:256–260`). A pause inside an ayah's last 0.8 s leaves
  the text partly dissolved for the whole recording. How that looks: NEEDS DEVICE TEST.
- Frame statistics count the paused frames as playback: `DissolveDriver.swift:303` —
  `guard recitation.playbackState == .playing || …`. The segment's frame row then includes the
  recording time.
- Reconciliation does not treat a stopped clock as a fault. `reconcile()` compares segment
  indices only (`RecitationCoordinator.swift:221–224`).

**Interruptions and route changes — ABSENT, and this is a risk today, before any recording
exists.** Nothing observes the player's rate or `timeControlStatus`, or the session's
interruption or route-change notifications. `playbackState` is written only at
`RecitationCoordinator.swift:134, 146, 251`. If the system stops the player, the app stays in
`.playing` / `.reciting`. The text holds on the current ayah with its dissolve frozen, and there is
no recovery path. Whether a category change, a route change or a system interruption pauses this
`AVPlayer` on visionOS: **NEEDS DEVICE TEST.**

**SDK facts relevant to the deployment target (DOCUMENTED ONLY, read from the installed SDK).**
All paths below are under
`/Applications/Xcode-beta.app/Contents/Developer/Platforms/XROS.platform/Developer/SDKs/XROS27.0.sdk/System/Library/Frameworks/AVFAudio.framework/Headers/`.

| symbol | header:line | availability as declared |
| --- | --- | --- |
| `AVAudioSessionInterruptionNotification` | `AVAudioSessionTypes.h:229` | `API_DEPRECATED("Use AVAudioSessionDidBecomeInactiveNotification and AVAudioSessionResumptionRecommendationNotification instead", ios(6.0, 27.0), watchos(2.0, 27.0), tvos(9.0, 27.0), visionos(1.0, 27.0))` |
| `AVAudioSessionInterruptionTypeKey` | `AVAudioSessionTypes.h:331` | same deprecation, `visionos(1.0, 27.0)` |
| `AVAudioSessionInterruptionOptionKey` | `AVAudioSessionTypes.h:334` | same deprecation, `visionos(1.0, 27.0)` |
| `AVAudioSessionInterruptionReasonKey` | `AVAudioSessionTypes.h:337` | `API_DEPRECATED("Use AVAudioSessionDeactivationContext.interruptionDetails.reason instead", … visionos(1.0, 27.0))` |
| `AVAudioSessionInterruptionType` (enum) | `AVAudioSessionTypes.h:640–643` | deprecated `visionos(1.0, 27.0)`, same message as the notification |
| `AVAudioSessionInterruptionOptions` (`ShouldResume`) | `AVAudioSessionTypes.h:647–650` | `API_DEPRECATED("Use AVAudioSessionResumptionRecommendationNotification instead", … visionos(1.0, 27.0))` |
| **replacement** `AVAudioSessionDidBecomeActiveNotification` | `AVAudioSessionTypes.h:311` | `API_AVAILABLE(ios(27.0), watchos(27.0), tvos(27.0), visionos(27.0))` |
| **replacement** `AVAudioSessionDidBecomeInactiveNotification` | `AVAudioSessionTypes.h:316` | `API_AVAILABLE(… visionos(27.0))` |
| **replacement** `AVAudioSessionResumptionRecommendationNotification` | `AVAudioSessionTypes.h:321` | `API_AVAILABLE(… visionos(27.0))` |
| userInfo key `AVAudioSessionDeactivationContextKey` | `AVAudioSessionTypes.h:377` | `API_AVAILABLE(… visionos(27.0))` |
| userInfo key `AVAudioSessionResumptionContextKey` | `AVAudioSessionTypes.h:382` | `API_AVAILABLE(… visionos(27.0))` |
| `AVAudioSession.InterruptionContext` (`reason`) | `AVAudioSession.h:571–574` | `API_AVAILABLE(… visionos(27.0))`; `init` is `NS_UNAVAILABLE`, so it cannot be constructed in a test |
| `AVAudioSession.DeactivationContext` (`source`, `interruptionContext`) | `AVAudioSession.h:586–589` | `API_AVAILABLE(… visionos(27.0))`; `init NS_UNAVAILABLE` |
| `AVAudioSession.ResumptionContext` (`recommendation`) | `AVAudioSession.h:606–609` | `API_AVAILABLE(… visionos(27.0))`; `init NS_UNAVAILABLE` |
| `activate(options:completionHandler:)` | `AVAudioSession.h:278` | `API_AVAILABLE(ios(27.0), watchos(5.0), tvos(27.0), visionos(27.0))` |
| `deactivate(options:completionHandler:)` | `AVAudioSession.h:287–289` | `API_AVAILABLE(… visionos(27.0))` |
| `AVAudioSessionRouteChangeNotification` | `AVAudioSessionTypes.h:237` | `API_AVAILABLE(ios(6.0), watchos(2.0), tvos(9.0))` — **not deprecated**, no visionOS-specific gate |
| `AVAudioSessionMediaServicesWereResetNotification` | `AVAudioSessionTypes.h:253` | `API_AVAILABLE(ios(6.0), watchos(2.0), tvos(9.0))` — not deprecated |

Reading: the deprecation is `visionos(1.0, 27.0)`, meaning **deprecated from 27.0, not removed**.
With the deployment target at 26.5 (`project.pbxproj:261`), the deprecated notification is the only
interruption API that exists on a 26.5 device, and the replacements exist only behind
`#available(visionOS 27, *)`. Handling interruptions therefore needs both paths. Whether the
deprecated notification is still **posted** on a visionOS 27 device: NEEDS DEVICE TEST.

**Risks of recording after the pause and resuming after the recording.** Each is a risk to test.
None is an observed behaviour.

| risk | what the code and SDK establish | status |
| --- | --- | --- |
| Category change | Recording needs a category that allows input. The app has no category at all today, so the first recording is also the first category change. The session header lists `AVAudioSessionRouteChangeReasonCategoryChange` (`AVAudioSessionTypes.h:434`), so a category change can itself raise a route change | effect on the paused player and on resume: **NEEDS DEVICE TEST** |
| Mode change | Mode affects playback as well as input. `AVAudioSessionModeVideoRecording` "may engage appropriate system-supplied signal processing" (`:156–157`). `…ModeMeasurement` notes "a lower output playback level" (`:160–162`). If the mode is not restored, the recitation can come back quieter or processed | **NEEDS DEVICE TEST** |
| Echo cancellation | `setPrefersEchoCancelledInput` is `API_UNAVAILABLE(visionos)` (`AVAudioSession.h:203–208`). Pausing before recording avoids needing it. Recording while the recitation plays would not be able to use it | DOCUMENTED ONLY (SDK) |
| Route change | Nothing observes it (ABSENT). A route change that pauses the player leaves the state machine in `.playing` (see above) | **NEEDS DEVICE TEST** |
| Spatial rendering | No intended spatial experience is set (ABSENT). Whether a category or mode change alters how the recitation is spatialized after resume | **NEEDS DEVICE TEST** |
| Artifacts at pause | `pause()` is an immediate stop. The app ramps nothing: `player.volume` is only ever set to 1 (`RecitationCoordinator.swift:129, 144`). Whether stopping mid-phoneme is audible | **NEEDS DEVICE TEST** |
| Artifacts at resume | Resuming at the paused time restarts mid-word unless the pause fell in a gap. Resuming at an ayah start is a seek (B2), which lands in bed-only audio for 76 of 78 boundaries (B3). Whether session reactivation adds a click or level step | **NEEDS DEVICE TEST** |

**States this implies. Not decided and not written as code.** The pause-for-recording flow
reaches a state that CLAUDE.md says nothing can reach: "`PlaybackState` has no `paused` case
because nothing can reach it" (CLAUDE.md, Gesture model). Voice recording would be such a path.
That is a decision for you. The candidates below are listed so the decision has something concrete
to rule on:

| candidate | belongs to | meaning | entered by | left by | note |
| --- | --- | --- | --- | --- | --- |
| paused for voice capture | `PlaybackState` | audio halted with its position kept, and resumable. Distinct from `.stopped` (never started) and `.finished` (end of file) | pause before recording | resume after recording, or an abort | Per the locked design, the resume position is a stored property, not an associated value |
| asking / listening | `ExperiencePhase`, or not a phase at all | the wearer is recording, and text is held on the anchor ayah (item 8's pin, ABSENT) | start of recording | end of recording | Whether this is a phase, or `.reciting` with audio paused, is open. `ExperiencePhase.swift:22` already reads as if it were the latter |
| resume target | stored property, not a state | the exact paused time, or the start of the current ayah | set at pause | consumed at resume | Resuming to the ayah start is the "restart-current-ayah" behaviour CLAUDE.md records as deleted for the hand-release path. Choosing it again for recording is a separate decision |

The session category (playback-only or play-and-record) is configuration, not app state. It still
has to be sequenced: pause, reconfigure, record, reconfigure, resume.

### B2. Seeking to an ayah

**The seek call — IMPLEMENTED for any index, called only with 0.**
`RecitationCoordinator.swift:152–157`:
`player?.seek(to: CMTime(seconds: segment.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in … self?.syncToCurrentTime() }`.
The completion ignores its `finished` flag, so a superseded seek still calls
`syncToCurrentTime()`. That is harmless because the sync re-reads the clock.

**Playing from ayah *n* from a standing start — ABSENT.** `start()` rewinds to 0 whenever it
starts from `.stopped` or `.finished` (`:130–131`). Calling `seek(toSegment: n)` and then `start()`
issues a second seek to 0. Which of the two lands: NEEDS DEVICE TEST. The code gives no ordering
guarantee. A seek while already `.playing` is mechanically possible, because the method is not
private.

**Segment index — IMPLEMENTED, correct if the clock reads the exact target.** The completion calls
`segmentIndex(at:)` (`:259–272`), which returns *n* for any time in `[start, end)`. Measured: all 79
`start` values lie exactly on the 1/600 s grid, so `CMTime(seconds:preferredTimescale: 600)`
represents each one exactly, with no rounding below the start. A test covers the segment-1 case
only: `RecitationProgressionTests.swift:54` —
`segmentIndex(at: intro.end, …) == 1`. **Whether `player.currentTime()` equals the target after a
zero-tolerance seek on an MP3, or lands a sample short and reports *n − 1*: NEEDS DEVICE TEST.**
Before the completion runs, the index still shows the old segment. What `currentTime()` returns
while a seek is pending: NEEDS DEVICE TEST.

**Boundary observers — IMPLEMENTED once at load and never reinstalled.** `:166–169` registers all
79 segment starts. `:179–189` registers the dissolve times, whose target `dissolveTicket` is
unconsumed (`:235`). **Does the advance observer fire correctly after a backward seek? NEEDS DEVICE
TEST. The code does not prove it.** What the code does prove:

- Correctness does not depend on it. The seek completion sets the index for the landing segment.
  For later boundaries, a missed observer is caught by the 1 Hz reconciliation (`:191–196`), which
  corrects the index and logs `"Segment desync: showing …, audio is at …. Correcting."` (`:223`).
  The worst case is therefore about 1 s of the wrong text, and it is logged. That log line is the
  instrument for the device test. Reconciliation runs only in `.playing` (`:218`).
- A double fire is harmless. A seek landing exactly on a boundary time may fire the observer as
  well as the completion. `apply` is idempotent: `:229` —
  `guard index != currentSegmentIndex || currentText == nil else { return }`.

**Dissolve progress — IMPLEMENTED as a pure function of the clock and the bound segment.** Read
from the code, for a seek from segment *m* to segment *n ≠ m*:

| moment | bound segment | progress | source |
| --- | --- | --- | --- |
| seek has landed, texture for *n* not yet bound | *m* | **1 in one frame.** For a backward seek, elapsed ≤ 0. For a forward seek, elapsed ≥ out-start and clamps. This holds for the final segment too | `Dissolve.swift:69`, `:77–79` |
| texture for *n* bound | *n* | 1 at bind, then the pure function | `DissolveDriver.swift:216`, `:256–260` |
| *n* bound at or near its start | *n* | fade-in over 0.5 s from the boundary | `Dissolve.swift:71–72` |
| *n* bound late | *n* | partial fade-in, or a hard cut in (8.2 table) | 8.2 |

So **any seek to another segment removes the current text in one frame instead of dissolving it**.
This generalises the 8.2 finding about restart after completion. How it looks: NEEDS DEVICE TEST.
Seeking back to the *current* segment's start is the 8.2 case: one cut out, then a fade in.

**Seeking into the pre-roll (B3) shows the previous ayah mid-dissolve.** A target before *n*'s
boundary resolves to *n − 1*. The median pre-roll starts 0.32 s before the boundary, which is
inside *n − 1*'s 0.8 s outgoing window, so *n − 1* appears at about 0.6 progress and then hands
over at the boundary. It also needs *n − 1*'s texture, which is cold for an arbitrary *n*.

**Texture cache — IMPLEMENTED; warm only for the current, previous and next segment.** On the first
update after the index changes: prefetch *n*, *n + 1*, *n − 1*, and evict everything else
(`ImmersiveView.swift:358–368`). The texture bound to the plane is dropped from the cache, but the
entity's material still holds it. The plane changes only once *n*'s entry exists
(`ImmersiveView.swift:370` — `guard let entry = textures.entry(for: index) else { return }`), so
for any *n* outside the old window, audio for ayah *n* plays with no text until rasterization
finishes. Raster time is not instrumented (8.5): **NEEDS DEVICE TEST.**
In-flight rasters for the old window are not cancelled (`AyahTextureCache.swift:59` —
`Task.detached`). `finish` inserts regardless of the window (`:81`), so the cache briefly holds
more than 3 entries until the next evict.

**Frame statistics — IMPLEMENTED, and a backward seek breaks their assumption.**
`DissolveDriver.swift:317–321`: "The segment index only ever goes backwards when a new run has
begun" → `if index < current { resetSession() }`. A backward seek mid-run would reset the session's
dropped-frame and thermal totals as though a new run had started.

### B3. Speech-free gap before each ayah (measured)

Measured with a throwaway script over `QuranSpatial/Resources/rahman-single.mp3` (SHA-256
`bf48c019…c0`) and `ar-rahman-timings.json`. The script is saved as
`docs/measurements/b3-preroll.py` and its per-boundary output as `docs/measurements/b3-preroll.csv`
(both uncommitted; re-running the script reproduces every figure below). Nothing in the app was
changed.

**Method.** The file was decoded with `afconvert` to 16 kHz mono. Energy was measured in 20 ms
frames at a 10 ms hop, in the 300–3400 Hz band (2nd-order high-pass and low-pass), smoothed over
50 ms in the energy domain.

- **Local bed floor F** = 5th percentile of frames within ±10 s of the boundary. Digital silence is
  excluded, and so is everything before 3.761 s (see segment 1 below).
- **Speech-free** = level < F + **6 dB**. Runs above the threshold shorter than 60 ms count as
  speech-free. Speech-free runs shorter than 80 ms count as speech (closures inside words).
- **Before** = boundary − gap start. **After** = onset − boundary. **Usable pre-roll** = onset − gap
  start.

**Floor measured.** F ranges from −36.1 to −29.0 dBFS, median −32.2 dBFS (band-limited RMS). The bed
never drops to digital silence after 3.761 s.

**Why the margin is 6 dB.** Inside the detected gaps the bed sits at F + 1.2 dB median, F + 5.0 dB
at p95 and F + 7.0 dB at most. Speech from 30 to 300 ms after onset sits at F + 13.3 dB median.
6 dB clears the bed's p95 by 1 dB. Results at 4 dB and 8 dB are given for sensitivity.

**Distribution, 76 boundaries.** 78 ayah boundaries, minus segment 1 (not measurable against a
bed) and segment 38 (boundary inside speech). Seconds:

| M | measure | min | p10 | median | p90 | max |
| --- | --- | --- | --- | --- | --- | --- |
| 6 dB | before boundary | 0.15 | 0.26 | 0.32 | 0.47 | 0.59 |
| 6 dB | after boundary, to onset | 0.04 | 0.13 | 0.24 | 0.32 | 0.43 |
| **6 dB** | **usable pre-roll** | **0.26** | **0.49** | **0.57** | **0.68** | **1.00** |
| 4 dB | usable pre-roll | 0.15 | 0.33 | 0.53 | 0.67 | 0.94 |
| 8 dB | usable pre-roll | 0.27 | 0.52 | 0.62 | 0.73 | 1.09 |

At M = 4 dB, segment 2's boundary falls on a 60 ms blip above the threshold, so that row covers 75
boundaries.

- **Segment 13 (refrain):** F = −29.7 dBFS. Gap 69.99–70.56 s against a boundary at 70.40 s:
  **0.41 s before, 0.16 s after, pre-roll 0.57 s.** At 4 dB: 0.39 / 0.15 / 0.54. At 8 dB: 0.43 /
  0.16 / 0.59.
- **Refrains vs other ayat:** refrain median pre-roll 0.57 s (n = 30, min 0.26); other ayat
  0.58 s (n = 46, min 0.47). The three shortest are all refrains: **42 (0.26 s), 16 (0.32 s),
  63 (0.44 s)**.
- **Onset within 100 ms of the boundary:** segments 9, 16, 27, 35, 72 (0.04–0.09 s). A seek to
  these starts lands just ahead of speech.
- Largest pre-rolls: 28 (1.00 s), 33 (0.96 s), 43 (0.81 s), 58 (0.78 s).
- **Segment 38 — the boundary is inside speech.** 305.35 s lies in a continuous 1.56 s run above
  the threshold (304.40–305.96 s). The nearest gaps are 304.11–304.40 s (ending 0.95 s before the
  boundary) and 305.96–306.48 s (starting 0.61 s after). Energy cannot tell which is the true
  start of ayah 38. **Needs a listening check.** Not inferred.
- **Segment 1 — not measurable against a bed.** The intro (0–3.637 s) carries **no bed**: it
  decays to about −55 to −48 dBFS, below the later floor. Then comes **124 ms of digital silence
  at 3.637–3.761 s**, inside segment 1, which starts at 3.31 s. The bed is present from there on,
  and speech rises at about 3.98 s. The waveform looks like a splice. The boundary at 3.31 s sits in
  the intro's decay tail.
- Other digital silence: 0–0.385 s (file start) and 678.167 s to end.

**Limits of the measurement.** Energy says where the bed is exceeded, not where recitation is.
Breaths and soft onsets near the threshold move the edges by tens of milliseconds, which is what
the 4 and 8 dB rows show. The decoder's handling of the MP3's 576 priming samples (13 ms), relative
to `AVPlayer`'s t = 0, was not verified. The decoded length is 678.230 s against 678.243 s in the
timings file, so read the figures as ±20 ms. Gaps inside ayat were not measured.

### B4. Gesture

**Candidate onset, distinct from commit — IMPLEMENTED as a state, ABSENT as an event.**

- The onset timestamp exists: `DuaPostureRecognizer.swift:102` — `case entering(since: TimeInterval)`,
  set at `:267` — `state = .entering(since: timestamp)` on the first frame at enter-bound quality.
  Commit follows at least `commitWindow` = 1.5 s later (`:92`, `:272–274`). The gate's acceptance
  follows a further 0.4 s later (`DuaEntryGate.swift:34`, `:73`).
- No event: `enum Event { case detected; case released }` (`:106–109`), and `update` returns only
  those. The only ticket the session publishes is acceptance
  (`HandTrackingSession.swift:29, 144`).
- Exposed indirectly: `HandTrackingSession.diagnostics` is observable (`:36`, updated at `:182`
  and `:132`). It carries `state`, including `since`, and `holdProgress` (`DuaPostureRecognizer.swift:300–303`).
  A consumer can observe the state changing to `.entering`. It cannot receive an onset event.
- An onset can lapse and recur any number of times before a commit: `.entering` returns to
  `.idle` on the first frame below enter bounds (`:276–277`), or through the watchdog (`:159–160`).
- In captures, the per-frame `state` is written as the string `"entering"` without `since`
  (`HandPoseCapture.swift:117–121`). Onsets are recoverable as the first `"entering"` frame after
  any other state.
- No new recognizer state is implied. An onset *event* would be a new output of the existing
  `.entering` state.

**Joints and rate.**

- **Sampled: 9 of 27 joints per hand.** Wrist, the four finger knuckles and the four fingertips.
  `HandTrackingSession.swift:218–230` — `wrist: position(.wrist), indexKnuckle: position(.indexFingerKnuckle), … littleTip: position(.littleFingerTip)`.
  `HandPose.swift:13–14`: "Deliberately carries only the nine joints the dua recognizer reads".
  **Not sampled:** all four thumb joints, the metacarpals, both intermediate joints of every finger,
  and the forearm joints (`hand_skeleton.h:36–62` lists all 27).
- **Tracking flag is per hand only.** `isTracked: anchor.isTracked` (`HandTrackingSession.swift:231`).
  ARKit has a per-joint flag (`skeleton_joint.h:137` — `ar_skeleton_joint_is_tracked`). It is not
  sampled.
- **Rate.** One update per hand-anchor update (`:113–115`). There is no fixed rate in code.
  Measured from the committed captures: the median interval between updates is **10 ms per hand
  (100 Hz)** in both, which is 199 Hz combined when both hands track continuously
  (`dua-capture-2026-09-03T20-10-57Z`) and 162 Hz when the left hand was untracked for long
  stretches (`…T20-53-24Z`). Both were recorded on the 2026-09-03 build and OS. The rate on the
  current visionOS 27 beta: NEEDS DEVICE TEST.

**Can per-finger curl be derived from joints already sampled? Partly.**

- **Derivable:** a per-finger extension proxy. For each finger, (tip–wrist distance) ÷
  (knuckle–wrist distance). That is exactly what `HandPose.fingerExtension` computes before
  averaging the four fingers together (`HandPose.swift:58–71`). The angle between the
  wrist→knuckle and knuckle→tip vectors is also derivable.
- **Not derivable:** flexion at the individual finger joints, which needs the intermediate joints,
  and **anything about the thumb**, which is not sampled at all.
- **Existing captures cannot be re-mined for the missing joints.** They store the same 9 joints
  (checked: joint keys in both files).
- Whether the tip-based proxy separates a fist from dua, pinch or relaxed hands, and how reliably
  curled fingertips track when occluded inside a fist: **NEEDS DEVICE TEST.** No fist data exists.

**Can the existing capture tooling record fist takes and confusers without code changes? No, as
the repo stands.**

- **Blocker: the record button is not in the scene.** It lives in the debug HUD
  (`DuaDebugHUDView.swift:115–131`, `capture.startRecording()` at `:128`), and that is the only
  caller of `startRecording`. The HUD is added only when a constant is on:
  `ImmersiveView.swift:30` — `static let showDebugHUD = false`, checked at `:222`. Default OFF
  since `9912c42`. Recording needs that one constant flipped, which is a code change.
- **With it on, the recorder does not care what the hands are doing.** `capture.record` runs for
  every judged frame whatever the recognizer or gate state (`HandTrackingSession.swift:183–192`),
  including during recitation after acceptance. Frames without a device anchor or skeleton are not
  recorded, but they are counted (`:157, 174`).
- **Labels are data, not code, but the vocabulary needs extending.** Takes are labelled after the
  fact in `tools/captures.json`. `fist` is in neither `true_kinds` nor `confuser_kinds`, and the
  harness rejects unknown kinds (`threshold_search.py:334–338` —
  `raise ValueError("unknown segment kind …")`). Adding the kind is a manifest edit. As a *dua
  confuser*, a fist take would feed the existing search. **There is no fist recognizer to
  evaluate** (ABSENT, and per CLAUDE.md's gesture sequencing, not to be scaffolded here).
- **Joint set.** Fist takes recorded today would carry only the 9 joints above: no thumb and no
  intermediate joints. If the closed-hand design needs those, they must be added to `HandPose`
  (a code change) *before* capturing, or the takes would have to be re-recorded.
- **Take length.** The binding limit is the transfer ceiling, under about 90 MB, which is roughly
  40,000 frames or about 3.3 min at 199 Hz. The 120,000-frame cap does not bind (DOCUMENTED ONLY:
  CLAUDE.md, "The transfer ceiling is the binding limit"; `HandPoseCapture.swift:64`).
- Cosmetic: every take is named `dua-capture-…json` (`HandPoseCapture.swift:151`), fist takes
  included.

---

## Stage 1 closed

Closed 2026-09-30. Inspection only throughout; nothing implemented, no data imported, CLAUDE.md
untouched. The B3 measurement script and results are saved under `docs/measurements/`.

Open human decisions raised in this report, one line each, with the section that raised them:

- **P3** — Thermal bar: does reaching `.fair` at any point fail a ten-minute session? Needed before
  the 3 October full-surah verdict, which uses this bar.
- **8 / P2** — English layer: placement below variable-height Arabic, vertical offset, shared or
  independent dissolve, font and em size, writing-direction handling in the rasterizer. Not decided;
  options with structural cost are in `docs/stage-2-plan.md`, B4.
- **Decisions (human)** — English text for segment 0 (the intro): open. Neither Quranpedia file has
  it under Surah 55.
- **Decisions (human)** — Licence or permission for Quranpedia book 1947: open. Distribution stays
  blocked until it is documented.
- **B1** — A resumable paused state in `PlaybackState`, which CLAUDE.md says nothing can reach; and
  whether "asking" is an `ExperiencePhase` or `.reciting` with audio paused. (The resume target was
  settled by the Stage 2 brief on 2026-09-30: the start of the anchor's speech-free gap.)
- **B1** — Interruption and route-change policy: what the app does after a system interruption ends
  without a resume recommendation, and on each route-change reason.
- **B3** — Segment 38: its boundary lies inside 1.56 s of continuous speech. Listening check, then
  decide whether the boundary in `ar-rahman-timings.json` changes.
- **B3** — Segment 1: the 3.31 s boundary sits in the intro's decay tail, with a 124 ms
  digital-silence splice at 3.637–3.761 s. Decide whether the intro/ayah-1 boundary is revisited.
- **B4** — Joint set: extend `HandPose` (thumb, intermediate joints, per-joint tracked flag) before
  recording fist takes, or record with the current nine joints.
- **B4** — Whether the recognizer should emit a candidate-onset event, distinct from commit.
- **8.1 / Other findings** — Hand-typed ayah 1 in `Ayah.swift:16`, against CLAUDE.md: remove or leave.
- **Other findings** — `DissolveDriver.material(forSegmentIndex:)` binds four parameters in one
  `do`/`catch`, against CLAUDE.md's individual-binding rule: fix or leave.
- **8.2** — Ayah 78 disappears in one frame on restart after completion, and a late texture can
  hard-cut in: accept for V1 or fix.
