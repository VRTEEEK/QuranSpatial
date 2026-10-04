# Stage 2 plan — the non-AI half of Ask mode

Written 2026-09-30; **revised the same day after review**, with every decision folded in (the
record of them is at the end). **A plan, not an implementation.** Nothing here has been built;
CLAUDE.md, project settings and the deny-listed files are untouched. Line references are to `main`
at `a506e72`, the same commit `docs/stage-1-report.md` was written against.

**Goal.** Everything Ask mode needs that is not AI, built and device-tested before the challenge
starts on 4 October: interruption handling, an audio-session strategy for pause → record → resume,
the pause / pin / resume transport itself, the English layer, and the measurement gate that decides
whether the English layer is in the baseline. The AI parts of Ask (speech, question, answer) are out
of scope and are built during the challenge.

**Standing constraints, restated so the plan can be checked against them.**

- The text pipeline (`ArabicTextRasterizer`, `AyahTextureCache`, `AyahPlaneGeometry`) and the
  dissolve (`Dissolve`, `DissolveDriver`, `DissolveMaterial.usda`) change **only** where B3 or B4
  requires it. Every such change is named in its section under "Touches the text pipeline or
  dissolve". `Dissolve.swift` and `DissolveMaterial.usda` are not touched anywhere in this plan.
- `project.pbxproj`, `*.xcworkspace`, `*.xcscheme` are deny-listed. The one project-level change
  (the microphone usage key, B2) you make in Xcode on 1 October.
- `ExperiencePhase` and `PlaybackState` are yours. States below are tables in prose; no enum code.
- Locked decisions in CLAUDE.md stand: two flat enums, no associated-value prior state; dua is entry
  only; the shader dissolve is the exit transition and no opacity stand-in replaces it. The audio
  fade in B3 is an *audio* volume ramp, not a text fade, and does not touch the material. The
  recall ramp on Ask entry (B3) drives the **existing** dissolve backwards and is, by decision 9,
  not a second dissolve.
- Quran text and the English translation are never typed, edited or normalised. Comparisons use
  `isByteIdentical` (`RecitationText.swift:52–54`). The one hand-typed string in the repo
  (`Ayah.swift:16`) is removed in B3.
- The English translation text stays out of the repo and out of any build installed beyond your own
  devices (Decisions (human), 2026-09-29).

---

## B1. Audio interruptions and route changes

**The bug.** Nothing observes the audio session. If the system pauses the `AVPlayer`, the app stays
in `.playing` / `.reciting` with the dissolve frozen at whatever the clock read, and nothing recovers
(Stage 1b B1). `playbackState` is written only at `RecitationCoordinator.swift:134, 146, 251`.

### Design

One new file, `QuranSpatial/AudioSessionController.swift` (picked up by the synchronized folder; no
project change). It is the only file that imports `AVFAudio` for session purposes. It:

1. Configures the session once (category per B2) and activates it before the first `play()`.
2. Logs a **session snapshot** before it changes anything — category, mode, options, current route,
   `intendedSpatialExperience` — which answers the Stage 1b open question of what the visionOS 27
   default actually is.
3. Observes interruptions through **two code paths that funnel into one handler**:
   - `#available(visionOS 27, *)`: `AVAudioSession.didBecomeInactiveNotification` (read the
     `DeactivationContext`: `source`, `interruptionContext?.reason`) and
     `AVAudioSession.resumptionRecommendationNotification` (read `ResumptionContext.recommendation`).
   - otherwise: `AVAudioSession.interruptionNotification` with `interruptionTypeKey` and
     `interruptionOptionKey` (`shouldResume`). Deprecated from 27.0, not removed — see the SDK table
     in the Stage 1 report, B1.
   - Both produce one internal value: interruption **began**, or **ended** with a resume
     recommendation yes / no / unknown. Everything downstream sees only that value.
4. Observes `AVAudioSession.routeChangeNotification` (not deprecated, no availability gate) and maps
   `routeChangeReason` to the policy table below.
5. Observes `AVAudioSession.mediaServicesWereResetNotification` and logs it at `fault`. Recovery
   from a media services reset (rebuilding the player) is **out of scope**; the log line is so a
   mystery stop can be attributed.

The controller calls two coordinator methods, both new, both on the main actor: `pause(reason:)`
and `resume()`. It never touches the player directly.

### Files and functions touched

| file:line | change |
| --- | --- |
| `QuranSpatial/AudioSessionController.swift` | **new.** Session configuration, snapshot log, two-path interruption observer, route-change observer, media-reset log. Logger category `AudioSession`, subsystem `com.vrteek.quranspatial` |
| `QuranSpatial/RecitationCoordinator.swift:44–52` | new stored properties: `pauseReason` (interruption / route / background / ask / none), `pinnedSegmentIndex: Int?`, `pinEntry` (progress at entry + uptime, B3), `pinReleaseTime: TimeInterval?`, `resumeTargetTime: TimeInterval?`, `runTicket: Int` |
| `RecitationCoordinator.swift:126–137` `start()` | unchanged in behaviour; the controller activates the session on the transition to `.playing` |
| `RecitationCoordinator.swift:141–150` `debugStop()` | also clears the pin, the resume target, cancels any volume ramp, restores the playback category, increments `runTicket` |
| `RecitationCoordinator.swift` (new) `pause(reason:)` | `player.pause()`, `playbackState = .paused`, pin the current segment with the recall ramp (B3), record `resumeTargetTime`, log |
| `RecitationCoordinator.swift` (new) `resume()` | B3's resume path (zero-tolerance seek to the gap start, stepped fade, pin hold). B1 uses it only when the system recommends resuming |
| `RecitationCoordinator.swift:217–226` `reconcile()` | guard stays `playbackState == .playing`; adds the pin-release backstop (B3) |
| `QuranSpatial/ImmersiveView.swift:32–36` | one more `@State`: the controller, created with the coordinator |
| `ImmersiveView.swift:339–343` `.onChange(of: scenePhase)` | keep the flush on any non-`.active` phase; **add `recitation.pause(reason: .background)` on `.background` only; `.inactive` is ignored** (decision 5) |
| `QuranSpatial/DuaDebugHUDView.swift:48–52` | one more row: `audio: <state>/<reason> · <category> · <route>` |
| `QuranSpatialTests/AudioInterruptionTests.swift` | **new.** Feeds synthetic `userInfo` dictionaries through the deprecated-shape parser; asserts began / ended(shouldResume) mapping. The 27-shape cannot be unit-tested: the context classes are `init NS_UNAVAILABLE` (`AVAudioSession.h:571–609`) |

### States added

| state | belongs to | meaning | entered by | left by |
| --- | --- | --- | --- | --- |
| paused | `PlaybackState` | audio halted by the app or the system; position kept; resumable. Distinct from `stopped` (never started) and `finished` (end of file) | `pause(reason:)` — an interruption began, a route loss, the app went to `.background`, or Ask entry (B3) | `resume()` → `playing`; `debugStop()` → `stopped` |
| pause reason | stored property on the coordinator, not a state | why audio is paused: interruption, route, background, ask | set by `pause(reason:)` | cleared by `resume()` / `debugStop()` |

`ExperiencePhase` is unchanged by B1: a system pause keeps `.reciting` (only Ask enters `asking`,
B3). This adds the case CLAUDE.md says nothing can reach — "`PlaybackState` has no `paused` case
because nothing can reach it" — so that sentence, and `PlaybackState.swift:9–12`, become stale the
day this lands. Both are yours to edit.

### Policy table (decided)

| event | action |
| --- | --- |
| interruption began | `pause(reason: .interruption)`: player paused (the system already did), state `paused`, current segment pinned; progress recalls to 0 at the fade-in rate (decision 9) so the frozen half-dissolve becomes settled text |
| interruption ended, resume recommended | `resume()` — the B3 path |
| interruption ended, resume **not** recommended or unknown | **stay paused.** Pinned text remains; audio resumes only through `exitAsk()` / the debug Resume button. Auto-resuming against the system's recommendation is unbidden recitation (decision 3) |
| route change `oldDeviceUnavailable` (AirPods disconnected) | `pause(reason: .route)`; **no auto-resume on reconnect** (decision 4). `newDeviceAvailable` is logged only |
| route change `categoryChange`, `override`, `wakeFromSleep`, `noSuitableRouteForCategory`, `routeConfigurationChange` | log only; `categoryChange` is expected twice per Ask (B2) |
| media services reset | log at `fault`; no recovery in scope |
| scene phase `.background` | `pause(reason: .background)`; `.inactive` ignored; the existing `flushCurrentSegment` stays on any non-`.active` (decision 5) |

**Consequence to hold in mind for the demo:** with decisions 3 and 4, a Siri press or an AirPods
drop during a run leaves the app paused, and the only resume in scope is the debug button. The
out-of-scope Ask trigger, when it arrives, is also the resume control.

### Device test

Build DEBUG with `ImmersiveView.showDebugHUD = true` (`ImmersiveView.swift:30`; flip back before
the baseline). Console.app tethered, filter `subsystem:com.vrteek.quranspatial`.

| # | steps | pass | fail | decided by |
| --- | --- | --- | --- | --- |
| T1 session snapshot | launch, open the space | one log line `Audio session default: category=… mode=… options=… route=… spatial=…` before any configuration | line missing | Console: category `AudioSession` |
| T2 Siri interruption | start via dua; at a settled ayah (progress 0, HUD) press the Digital Crown for Siri; dismiss it | `Interruption began (reason=…, path=27\|legacy)` → `Paused: interruption, segment n pinned, progress 0.00→0`; text stays at full opacity; then `Interruption ended (resume=yes)` → `Resume: target %.3f (gap start of n), fade %.3f s` → `Resume seek landed %.3f (Δ %+.1f ms)` → `Pin released at %.3f`; audible fade before ayah n's first word; `frame-stats.txt` shows **no** `New run:` line | any of: state left at `playing` while audio is silent; text visibly half-dissolved during Siri; `New run: frame stats reset` logged; `Segment desync` logged during the pinned window | Console + `frame-stats.txt` pulled after the run |
| T3 other-app audio | same, but start playback in Music instead of Siri; then stop it | began/ended pair logged; if `resume=no\|unknown`, the app **stays paused** with pinned text and logs `Staying paused: no resume recommendation`; HUD Resume then resumes normally | app resumes on its own; both audible | Console |
| T4 AirPods disconnect | AirPods connected; mid-ayah, put one in its case | `Route change: oldDeviceUnavailable …` → `Paused: route`; on reconnect `Route change: newDeviceAvailable` and **no** resume; HUD Resume works | route change unlogged; audio stops with state `playing`; auto-resume | Console |
| T4b background | mid-ayah, press the Crown to the home view | `Paused: background`; on return the app is paused with pinned text; HUD Resume works | `.inactive` alone pauses; state left `playing` | Console |
| T5 debug abort while paused | T2, but press "Abort run (debug)" during Siri | `Debug stop`, phase `idle`, gate `awaitingRelease`, pin cleared, ramp cancelled, category back to playback | leftover pin or `paused` state after abort | HUD rows + Console |
| T6 26.5 path | **cannot be run**: the only device is on visionOS 27. Covered by `AudioInterruptionTests` and by reading the code | — | — | unit tests |

Whether the deprecated notification is still **posted** on a 27 device is settled by T2's `path=`
field. If both paths fire for one interruption, the handler must debounce on the began/ended edge.

### What could break

- **Gesture path**: nothing. The gate ignores hand state after acceptance
  (`DuaEntryGate.swift:39`), and a pause does not change `experiencePhase`, so
  `handTrackingSession.experienceEnded()` is not called (`ImmersiveView.swift:328–332`).
- **Text**: a pause without a pin would leave `pushProgress` writing whatever the stopped clock says
  (`DissolveDriver.swift:250–286`). The pin in B3 is what makes B1 safe; **B1 cannot ship before
  B3's pin exists.** Build order below respects this.
- **Frame stats**: paused frames stop counting once the guard at `DissolveDriver.swift:303` sees
  `paused` instead of `playing`. The `index < current` reset at `:317–321` is replaced in B3.
- **Boundary observers** do not fire while paused and are not re-installed; the seek completion and
  the 1 Hz reconcile (`RecitationCoordinator.swift:152–158, 191–196`) carry the resume, as today.
- **Session activation** on the main actor can block for tens of milliseconds. Activate once at
  launch and on resume only if the session reports inactive; never per frame. If T2 shows a hitch
  > 50 ms on resume, move activation to the 27-only async `activate(options:completionHandler:)`
  behind availability.

---

## B2. Audio session for pause → record → resume

### Strategy S1 (decided)

**`.playback` while reciting; `.playAndRecord` for the recording window; back to `.playback`
before `resume()`.** Mode `.default` throughout, options `[]`. Sequence on Ask entry:
`pause(reason: .ask)` → `setCategory(.playAndRecord)` → (AI records, out of scope; Stage 2 tests
with the debug probe) → `setCategory(.playback)` → `resume()`. Playback is paused for the whole
recording, so nothing about the recitation is heard under `.playAndRecord`.

Not chosen: S2 (`.playAndRecord` for the whole session — every minute of recitation under an
input-capable category whose output processing may differ, `AVAudioSessionTypes.h:156–162`) and
S3 (`.playback` ↔ `.record` — forecloses playing an answer while the mic is live).

### Risks carried from Stage 1b B1, and what S1 does about each

| risk | S1 handling | still NEEDS DEVICE TEST |
| --- | --- | --- |
| category change raises a route change (`AVAudioSessionTypes.h:434`) | expected exactly twice per Ask; the B1 route handler treats `categoryChange` as log-only | that it is only ever `categoryChange`, not `oldDeviceUnavailable` |
| mode alters output processing / level | mode stays `.default`; category is restored **before** `resume()` so the recitation never plays under the recording category | level and spatialisation identical before and after (T8) |
| echo cancellation unavailable on visionOS (`AVAudioSession.h:203–208`) | not needed: nothing plays while recording | — |
| spatial rendering | `intendedSpatialExperience` left at default and logged in the snapshot; if T8 hears a change, set it explicitly (`AVAudioSession.h:541`) to the value the snapshot showed | — |
| artefacts at pause | `pause()` is immediate; no ramp-out (the resume ramp-in is B3's) | audibility of the cut |
| artefacts at resume | B3's fade covers reactivation; the category is switched while paused | click on reactivation |
| permission prompt | `AVAudioApplication.requestRecordPermission` is called from the **debug probe only** in Stage 2, so the prompt is seen once on your device and never during a run | the prompt's appearance inside the full immersive space |

### What you set in Xcode on 1 October (the only project-level change in this plan)

Target **QuranSpatial** → Build Settings → add **`INFOPLIST_KEY_NSMicrophoneUsageDescription`**
with a user-facing string (wording yours), mirroring `INFOPLIST_KEY_NSHandsTrackingUsageDescription`
(`project.pbxproj:245`). No capability, entitlement or background mode is needed. Without the key
the first input use terminates the app.

### Files and functions touched

| file:line | change |
| --- | --- |
| `AudioSessionController.swift` | `configureForPlayback()`, `configureForRecording()`, each logging `Audio session: category=… mode=… route=…` before and after |
| `RecitationCoordinator.swift` | `enterAsk()` (B3) calls `configureForRecording()` after `pause`; `exitAsk()` calls `configureForPlayback()` before `resume()` |
| `QuranSpatial/AskRecordingProbe.swift` | **new, `#if DEBUG` only** (decision 8: in scope). Requests record permission, records 3 s with `AVAudioRecorder` to `Documents/ask-probe.m4a`, logs the file size. Proves the mic opens under S1; kept dark when the AI half brings its own capture |
| `DuaDebugHUDView.swift:59–66` | one more button beside the abort: "Record probe (debug)" |

No text-pipeline or dissolve file is touched by B2.

### Device test

| # | steps | pass | fail | decided by |
| --- | --- | --- | --- | --- |
| T7 category round-trip | Ask (debug) → HUD "Record probe" → Resume (debug) | logs show `category=playback` → `playAndRecord` → `playback`; route unchanged across all three; `ask-probe.m4a` in Documents, size > 0, `afinfo` duration ≈ 3 s | category not restored; route flips to something other than the starting route; probe file missing or empty | Console + `devicectl device copy from … --source Documents/ask-probe.m4a` |
| T8 level and spatial | listen to the same refrain before an Ask and after resume | no audible level step, no change in where the voice sits | audible change | wearer judgment — recorded as such |
| T9 permission | first probe press on a fresh install | system prompt appears, grant, probe proceeds | app terminates (missing key) | Console crash log |

### What could break

- The `playAndRecord` switch while the space is open is a route change; if T7 shows a route flip,
  S1 is wrong and S3 is the fallback — same call sites, one constant.
- Setting a category with the player paused is safe; setting it while playing would glitch. The
  order in `enterAsk()` / `exitAsk()` protects this and must be kept.

---

## B3. Pause, pin, resume (Ask entry and exit)

Ask is entered through **one function call**, `RecitationCoordinator.enterAsk()`, and left through
`exitAsk()`. The trigger (pinch or gesture) is out of scope; the debug trigger is two HUD buttons.

### Semantics (decided)

- **Anchor** = `currentSegmentIndex` at the instant of `enterAsk()`: the ayah playing.
- **Refused** (decision 13): `enterAsk()` on segment 0 and after `completed` logs
  `Ask refused: <reason>` and does nothing. **Allowed** on ayah 78.
- **Pin** = the anchor overrides what the view shows and what the dissolve driver writes. Today both
  follow the audio clock (`ImmersiveView.swift:356`, `DissolveDriver.swift:256–260`).
- **Recall on entry** (decision 9): if progress at entry is *p* > 0 — the incoming fade or the
  outgoing window — the pin **ramps progress from *p* to 0 at the fade-in rate** (1 / 0.5 s, so it
  takes *p* × 0.5 s), then holds 0. The same rule applies when a system interruption pins. A
  user-invoked recall is not a second dissolve. Implemented as a pure function of the entry
  snapshot and wall-clock time, not an accumulator:
  `pinnedProgress(now) = max(0, p_entry − (now − uptime_entry) / Dissolve.inDuration)`. Nothing is
  integrated across frames, so a dropped frame cannot leave the ramp behind.
- **Resume** = zero-tolerance seek to the **start of the anchor's speech-free gap**
  (`boundary − speech_free_before_boundary_s` from `docs/measurements/b3-preroll.csv`), volume set
  to 0, `play()`, then a **stepped `player.volume` ramp 0 → 1** over
  `fade = min(0.25 s, 0.6 × usable_preroll_s)` (decision 10). Segments 1 and 38 (unmeasured in the
  CSV) fall back to `segment.start` with a 0.15 s fade; Ask is **not** refused on them (decision 11).
  Segment 38 will resume mid-word until its boundary is re-checked (Stage 1 closing list).
- **Every resume seek logs its actual landing time**: `Resume seek landed %.3f (target %.3f,
  Δ %+.1f ms)`, read from `player.currentTime()` in the seek completion.
- **Pin release** = when the clock passes `anchor.start + Dissolve.inDuration` (0.5 s,
  `Dissolve.swift:24`). At that instant the pure function returns 0 for the anchor
  (`Dissolve.swift:71–72, 81`), the value the pin holds, so the hand-over is a visual no-op. That
  equality is why the pin holds *past* the boundary.
- **No layer dissolves twice.** During the pre-roll the audio is inside ayah *n−1*'s last
  0.26–0.59 s — its outgoing window — but the pin shows *n* at 0, never *n−1*, so *n−1* does not
  re-dissolve and *n* does not fade in a second time. The anchor is heard from its start again; that
  repetition is inherent in "resume at the gap start" and is not a visual double dissolve.

### Why a stepped ramp and not an audio mix

An `AVMutableAudioMix` ramp is tied to a **time in the recording**: it re-applies every time playback
crosses that time again — a later Ask, or `start()`'s restart, which does not clear it — and its
volume before the ramp start is unspecified if the seek lands early. A stepped ramp is tied to the
resume *event*: a main-actor `Task` steps `player.volume` every ~16 ms from 0 to 1 over `fade`,
clamps at 1, and is cancelled by `enterAsk()`, `pause(reason:)` and `debugStop()`. `player.volume`
is otherwise only ever set to 1 (`RecitationCoordinator.swift:129, 144`), so there is one writer.
Cost: ~16 volume writes per resume on the main actor; T18 checks they do not hitch.

### How the pin is threaded through the existing code

The coordinator keeps `currentSegmentIndex` as **the audio truth, unchanged in meaning**, so
`reconcile()` (`RecitationCoordinator.swift:217–226`) keeps working and logs no false desyncs. It
adds `pinnedSegmentIndex: Int?` and exposes `displayedSegmentIndex = pinnedSegmentIndex ?? currentSegmentIndex`
and `pinnedProgress: Float?` (the recall function above, nil when not pinned).

- `ImmersiveView.applyCurrentAyah` reads `displayedSegmentIndex` at `:356`. The prefetch window
  `:358–368` is then centred on the anchor — which also covers the resume point in *n−1*. The name
  check at `:376–377` keeps the anchor's plane bound through the whole episode: on the resume seek
  `currentSegmentIndex` becomes *n−1* but `displayedSegmentIndex` stays *n*, so no rebind and no
  texture swap.
- `DissolveDriver.pushProgress` (`:250–286`) evaluates `recitation.pinnedProgress` first: if the
  coordinator reports a pin, that value is written and the audio clock is not consulted. During the
  recall the value changes every frame; once it reaches 0 the `lastAppliedProgress` guard (`:268`)
  makes the hold free.
- Pin release needs an **observable** state change, because `applyCurrentAyah` runs from the
  RealityView `update:` closure (`ImmersiveView.swift:289–292`), which fires only on observed
  changes. `resume()` installs a **one-shot boundary observer** at `anchor.start + inDuration` that
  calls `syncToCurrentTime()` **then** clears `pinnedSegmentIndex`. The sync first closes the Stage
  1b B2 risk that the segment-start observer did not fire after a backward seek: at release the
  displayed index is derived from the clock before the pin lets go, so the plane cannot flash to
  *n−1*. The 1 Hz reconcile is the backstop: if pinned and `currentAudioTime ≥ pinReleaseTime`,
  release.

### The pre-roll table in the app (decision 12)

A new bundled resource `QuranSpatial/Resources/ar-rahman-preroll.json`, generated from
`b3-preroll.csv` by `docs/measurements/b3-preroll.py --json` (a small addition to the script),
carrying per segment `gapStart`, `speechOnset`, `usablePreroll`, `status`, plus the mp3 SHA-256
and the margin it was measured at. Decoded by a new `RecitationPreroll.swift` beside
`RecitationTimings.swift`. Separate from `ar-rahman-timings.json`, so the corrected-by-ear
boundaries are not edited. `resumeTarget(for:)` returns `gapStart` for measured rows and
`segment.start` + the 0.15 s fade for the two others.

### FrameStats and backward seeks (decision 15)

`DissolveDriver.recordFrame` treats a decreasing segment index as a new run and resets the session
totals (`:317–321` — `if index < current { resetSession() }`). Every resume in this plan seeks
backwards into *n−1*. Two protections, both applied:

1. **Measured runs never enter Ask.** B5 and the 3 October full-surah runs are run without the
   debug trigger; the B1 policy can still pause them (Siri, AirPods, background), so:
2. **The heuristic is replaced by an explicit signal.** The coordinator gains `runTicket`,
   incremented in `start()` when it seeks to 0 (`:130–131`) and in `debugStop()` (`:145`). The
   driver resets on a ticket change instead of on `index < current`, and `recordFrame` reads
   `displayedSegmentIndex`. A resume seek then continues the same run; a paused stretch is not
   counted at all (the guard at `:303` sees `paused`). `flushCurrentSegment` (`:370–377`) is
   unchanged.

### Debug trigger (decision 14)

Two `#if DEBUG` buttons in `DuaDebugHUDView` beside the abort (`DuaDebugHUDView.swift:59–66`):
"Ask (debug)" → `recitation.enterAsk()`, "Resume (debug)" → `recitation.exitAsk()`, wired
through the same closure pattern as `onDebugStop` (`ImmersiveView.swift:294–301`). Requires
`showDebugHUD = true` for the test session, as the abort does.

### Removal of the hand-typed probe string (correction)

`Ayah.swift:16` holds `Ayah(surah: 55, ayah: 1, arabicText: "…")`, typed by hand and differing from
the corpus in its first scalar (Stage 1 report, 8.1). It is removed under B3. Its four users take
ayah 1 from the corpus instead — `RecitationTextFile.text(forSegmentIndex: 1)` on the decoded
`ar-rahman-text.json`, which `RecitationDataTests` already does:

| file:line | change |
| --- | --- |
| `QuranSpatial/Ayah.swift:16` | the literal goes; if `Ayah` has no other use, the file is deleted (a synchronized folder needs no project change for that) |
| `QuranSpatial/FontIdentityReport.swift:37` | probe string read from the decoded corpus |
| `QuranSpatialTests/QuranSpatialTests.swift:19, 39, 103, 114` | same; the tests still assert the superscript alef glyph and a non-empty raster, now against the real ayah 1 |

### Stale comments fixed in files B3 edits (decision 31)

`RecitationCoordinator.swift:47` ("Resume restarts this segment from its start" — now true in a
different sense; reworded to describe the gap-start resume) and `DissolveDriver.swift:38–42` (cites
the pre-11d 3.0° em). `ExperiencePhase.swift:22` is yours as you add `asking`.
`AyahTextureCache.swift:13–14` is not among B3's files and is left.

### States added

| state | belongs to | meaning | entered by | left by | note |
| --- | --- | --- | --- | --- | --- |
| paused | `PlaybackState` | as B1 | `enterAsk()` via `pause(reason: .ask)` | `exitAsk()` via `resume()`; `debugStop()` | one case serves Ask and system pauses; the reason is a property (decision 1) |
| asking | `ExperiencePhase` | the wearer is asking about the anchor; audio paused; anchor pinned | `enterAsk()` | `exitAsk()` → `reciting`; `debugStop()` → `idle` | decision 2. A system pause does **not** enter `asking`; it stays `reciting` + `paused` |
| pinned segment | stored property (`pinnedSegmentIndex: Int?`) | which segment the view and driver show regardless of the clock | `enterAsk()`, `pause(reason:)` | the one-shot release observer, or reconcile, at `anchor.start + 0.5 s`; `debugStop()` | outlives `paused` by up to `preroll + 0.5 s` |
| pin entry snapshot | stored property (`progressAtEntry`, `entryUptime`) | inputs to the recall ramp | with the pin | with the pin | makes `pinnedProgress` a pure function of time |
| pin release time | stored property | when the pin lets go | `resume()` | cleared with the pin | — |
| resume target | stored property | absolute seek time for the next `resume()` | `enterAsk()` / `pause(reason:)` | `resume()` | the locked design puts this in a property, not an associated value |
| run ticket | stored property (Int) | "a new run began"; replaces the backward-index heuristic | `start()` from `stopped`/`finished`, `debugStop()` | — | read by `DissolveDriver.recordFrame` |

### Files and functions touched

| file:line | change |
| --- | --- |
| `RecitationCoordinator.swift:44–52` | properties above |
| `RecitationCoordinator.swift` (new) | `enterAsk()` (with the refusals), `exitAsk()`, `pause(reason:)`, `resume()`, `pinCurrentSegment()`, `releasePin()`, `displayedSegmentIndex`, `pinnedProgress`, `runTicket`, the volume-ramp task |
| `RecitationCoordinator.swift:47` | stale comment reworded |
| `RecitationCoordinator.swift:152–158` `seek(toSegment:)` | add `seek(toTime:)` (zero tolerance, logs the landing time); the existing method calls it |
| `RecitationCoordinator.swift:162–203` `installObservers()` | unchanged; `resume()` adds/removes its own one-shot observer |
| `RecitationCoordinator.swift:217–226` `reconcile()` | pin-release backstop |
| `QuranSpatial/RecitationPreroll.swift` + `Resources/ar-rahman-preroll.json` | **new** |
| `docs/measurements/b3-preroll.py` | `--json` output |
| `ImmersiveView.swift:356` | read `displayedSegmentIndex` |
| `ImmersiveView.swift:294–301` | two more closures for the debug buttons |
| `ImmersiveView.swift:328–338` | `.onChange(of: experiencePhase)`: `asking` flushes nothing and ends nothing; only `completed` and `idle` act, as today |
| `DuaDebugHUDView.swift:59–66` | debug Ask / Resume buttons; rows for `pinned: n (p→0)`, `resume→ %.3f`, `audio` |
| `DissolveDriver.swift:38–42` | stale em figure fixed |
| `DissolveDriver.swift:250–286` `pushProgress` | pin override (see "Touches" below) |
| `DissolveDriver.swift:313–321` `recordFrame` | `displayedSegmentIndex`; reset on `runTicket` change |
| `DissolveDriver.swift:382` `reportSession` | verdict fails on `.serious` or worse, not on `.fair` (decision 24); the existing `Thermal state rose to …` log at `:334` already records the first `.fair` |
| `FrameStatsLog.swift:42` | bar text: "thermal below serious" |
| `Ayah.swift`, `FontIdentityReport.swift:37`, `QuranSpatialTests.swift:19, 39, 103, 114` | probe-string removal above |
| `QuranSpatialTests/AskTransitionTests.swift` | **new.** Pure tests: pin-release time equals the first time the pure function returns 0 for the anchor; recall reaches 0 in exactly *p* × 0.5 s; fade ends before `speechOnset` for every measured row of the pre-roll JSON; segments 1 and 38 take the fallback; segment 0 and `completed` refuse |
| `QuranSpatialTests/RecitationProgressionTests.swift` | add: `segmentIndex(at: gapStart(n))` is `n−1` for every measured row |
| `QuranSpatialTests/FrameStatsTests.swift` | add: the verdict with worst thermal `.fair` is PASS, with `.serious` FAIL |

**Touches the text pipeline or dissolve — required by B3:** `DissolveDriver.pushProgress`
(`:250–286`) consults the coordinator's pin before the pure function, and the two documented
housekeeping edits to `DissolveDriver` (`:38–42`, `:313–321`, `:382`). `Dissolve.swift` is
untouched, the material is untouched, `ArabicTextRasterizer` and `AyahTextureCache` are untouched.

### Device test

Build DEBUG, `showDebugHUD = true`. Start via dua. After each test pull `frame-stats.txt`.

| # | steps | pass | fail | decided by |
| --- | --- | --- | --- | --- |
| T10 settled Ask | at ayah ≈5, progress 0: "Ask (debug)"; wait 10 s; "Resume (debug)" | `Ask: entered t=%.3f segment n progress 0.00` → audio stops the same frame, text unchanged; HUD `asking / paused:ask / pinned n`; `Resume: target … fade …`; `Resume seek landed … Δ …`; audible fade before the first word; `Pin released at …`; ayah n plays to its end and dissolves out once; **zero** `Segment desync`; **no** `New run:` | plane flashes to n−1; text re-fades after release; a desync line during the pinned window; a `New run:` reset | Console + HUD + `frame-stats.txt` (same `run started:` header before and after) |
| T11 refrain | same on segment 13 (gap start 69.99 s, onset 70.56 s, fade 0.25 s) | landing Δ within ±20 ms of 69.99; fade complete by 70.24 s; first word intact | landing far off target; clipped first syllable | Console timestamps + ear |
| T12 shortest pre-roll | same on segment 42 (pre-roll 0.26 s, fade 0.156 s) | as T11 | clipped first syllable | ear |
| T12b fallback | Ask on segment 1 | `Resume: target 3.310 (segment start, unmeasured), fade 0.150` | gap-start path taken | Console |
| T13 outgoing-window Ask | on a refrain, press Ask when the HUD progress row reads > 0.3 | `Ask: entered … progress 0.xx`; text recalls smoothly to full over 0.xx × 0.5 s; then as T10 | snap; text stays half-dissolved; a second fade-in after release | eyes + Console |
| T14 incoming-window Ask | press Ask within 0.5 s of a boundary | recall completes the arrival; then as T10 | as T13 | eyes + Console |
| T15 double Ask | Ask, Resume, Ask again **before** `Pin released` | second entry re-pins n at 0 (no recall needed), ramp cancelled, second resume seeks to the same gap start, exactly one `Pin released` per resume | two release observers firing; plane flash | Console |
| T16 abort during Ask | Ask, then "Abort run (debug)" | `idle`, `stopped`, pin cleared, ramp cancelled, `awaitingRelease`, category playback | leftovers | HUD + Console |
| T17 edges | Ask on segment 0; after `completed`; on ayah 78 | `Ask refused: intro`; `Ask refused: completed`; ayah 78 pins, resumes to its gap start and stays on screen (never dissolves out, `Dissolve.swift:75`) | any refusal missing; ayah 78 disappearing | Console + eyes |
| T18 hitch | across T10–T15, `frame-stats.txt` and Console `hitches:` | no hitch > 50 ms on the Ask frame, the resume frame or during the volume ramp | a hitch attributable to `enterAsk`/`resume`/ramp | `frame-stats.txt` + Console |

### What could break

- **Text**: `applyCurrentAyah` reading a different index is the only view change, but it is the one
  that decides which texture is on the plane. A mistake here shows n−1 during the pre-roll. T10's
  "plane flashes" criterion exists for this.
- **Dissolve**: the recall writes progress every frame for up to 0.4 s; it uses the same
  `setParameter` path as the clock. If the material is the `UnlitMaterial` fallback
  (`ImmersiveView.swift:384–396`) the pin and recall are no-ops and the text is already at full
  opacity — correct by accident; log it.
- **Prefetch**: the window follows the displayed index, so while pinned it is {n−1, n, n+1}; the
  resume lands in n−1, whose texture is warm.
- **Reconcile**: `currentSegmentIndex` keeps its meaning, so no false desync logs. If the pin were
  applied to `currentSegmentIndex`, reconcile would fight it every second — do not.
- **Volume ramp**: one writer for `player.volume`; the ramp task must be cancelled on every path
  that pauses or stops, or a late step could raise the volume of a paused player before the next
  resume sets it to 0. `pause(reason:)` cancels first.
- **Gesture**: none. The gate is `.accepted` throughout; `experienceEnded()` is only called on
  `completed` and by the abort.
- **`dissolveTicket`** fires again on the replayed boundary. Unconsumed, harmless.
- **Probe-string removal**: `FontIdentityReport` now depends on the corpus decode at launch; if the
  JSON were missing the report must say so rather than crash (the coordinator already handles that
  absence at `RecitationCoordinator.swift:99–109`).

---

## B4. English translation layer

Canonical edition per Decisions (human): Saheeh International, Quranpedia book 1947, raw SHA-256
`8c08a833…3978`; displayed verbatim; footnotes never rendered; text **out of the repo** and out of
any build beyond your devices. **The intro (segment 0) shows no English** (decision 23).

### How the app gets the text for local builds (decision 21)

The extraction script (outside the repo, beside the raw file) writes
`QuranSpatial/Resources/en-rahman-saheeh-1947.json` with: `edition`, `sourceBook: 1947`,
`sourceURL`, `rawSHA256` (the pinned value), `extractionRules` (the five rules, verbatim from the
decision record), `textSHA256` (SHA-256 over the 78 ayah texts joined by `\n`, UTF-8), and
`ayat[{ayah, text}]`; footnotes are omitted from this file. The file is **gitignored** by a new rule
`QuranSpatial/Resources/en-*.json` — an edit to `.gitignore`, which is not deny-listed and is the
one repo-config change in B4. The loader (`RecitationTranslation.swift`, new) treats absence as a
supported state, exactly as `ArabicTextRasterizer.isShipFontBundled` does: no file → no English
layer, one log line, and the launch report says so. **A build for anyone else is made by not having
the file.**

Integrity without text in the repo: a test hashes the decoded ayat and compares to `textSHA256`,
and a test asserts `rawSHA256` equals the pinned constant. No English word — and, by decision 21,
no punctuation check either — appears in a test.

### Structural cost (from P2, per ayah)

+1 persistent entity; +1 `generatePlane` per transition (main actor); +1 draw call; +1 material
instance; +1 texture per ayah and **+3 resident**; +1 detached raster job, +1 main-actor
`TextureResource` creation, +1 eviction, +1 bind, +1 `ModelComponent` write per transition; +1
explicit sort order; under D1, +1 `setParameter` and +1 `materials` write per frame during both
fades. Texture bytes are `w × h × 4`; English dimensions depend on the em and are measured on device
(`text-placement.txt`, extended).

### Placement P1 (decided)

The Arabic plane is top-anchored on its first baseline; its **bottom edge moves down** by one line
box (2.449 em, CLAUDE.md) per extra line: 69 segments have one line, 9 two, 1 three (ayah 33).
**P1: English top = Arabic bottom − `englishGapDeg`**, in root-local metres derived from
`entry.pixelSize.height × metresPerPixel`, so the English moves down on the 10 multi-line ayat and
never overlaps. The English entity is a **child of `textRoot`** (`ImmersiveView.swift:70, 193–203`)
and inherits distance, pitch and the em-preserving scale. **`englishEmDeg` starts at 1.3°** and
`englishGapDeg` is a constant you tune on device (decision 16); both live in `AyahPlaneGeometry`
beside `textAngularEmDeg` (`:92`). Wrap width: the same 40°. Lines centred, as the Arabic
(decision 19). P2 (fixed under the worst case) was not chosen; P3 was dropped.

### Dissolve D1 (decided), D4 as the fallback

**D1: a second `DissolveDriver` instance** bound to the English plane, with its own
`bound`/`boundIndex`/`lastAppliedProgress`, the same template material, and **its own noise seed**
(`Dissolve.noiseOffset(forSegmentIndex:)` is pure; the English instance offsets the index by a
constant so the two layers break up differently). Requires `DissolveDriver.init(recordsFrameStats:)`
so the second instance does **not** duplicate frame statistics (`:128–142, 290–337`). The pin from
B3 applies to both instances through the same `pinnedProgress`. No `textColor` bind: English is the
same white (decision 20). No USD change: the English raster is opaque white glyphs in a
`premultipliedLast` context (`ArabicTextRasterizer.swift:191–196`), so `ND_image_float` samples
coverage exactly as for Arabic.

**D4 fallback** (if B5 fails): `UnlitMaterial` with the texture, hard-cut at the boundary — no
per-frame writes, no second driver. Not a stand-in fade; there is no fade.

### Font F1 (decided)

The system font via the cascade the rasterizer already falls back to —
`CTFontCreateWithName("System")` → `CTFontCreateForString` (`ArabicTextRasterizer.swift:96, 98`) —
never a PostScript name. A test mirroring `resolvedArabicFontHasSuperscriptAlef`
(`QuranSpatialTests.swift:18`) asserts the resolved English font has glyphs for **U+0101 ā, U+012B ī,
U+2019 ’** (decision 18), read from the font with `hasGlyph` (`:101`), not from the cascade's name.
The launch report logs the resolved PostScript name.

### Files and functions touched

| file:line | change |
| --- | --- |
| `QuranSpatial/RecitationTranslation.swift` | **new.** Decoded shape + `text(forSegmentIndex:)` (nil for 0) + absence handling + hash check |
| `QuranSpatial/Resources/en-rahman-saheeh-1947.json` | **new, gitignored, local only** |
| `.gitignore` | new rule `QuranSpatial/Resources/en-*.json` |
| `ArabicTextRasterizer.swift:141–147` | `rasterizeWrapped` gains `writingDirection: CTWritingDirection = .rightToLeft` and `font: CTFont? = nil` (nil → today's `resolveFont`). Defaults keep the Arabic path byte-for-byte; `:152` and `:220–232` take the direction from the parameter |
| `AyahTextureCache.swift:56–67` | `init(rasterize:)` — the call at `:60` goes through an injected closure; the Arabic instance passes today's call, the English instance the English variant |
| `DissolveDriver.swift:118–142, 290–337` | `init(recordsFrameStats: Bool = true, noiseSeedOffset: Int = 0)`; the English instance passes `false` and a non-zero offset |
| `AyahPlaneGeometry.swift` | `englishEmDeg = 1.3`, `englishGapDeg`, derived `englishFontSizePixels`, `englishPlaneOffset(arabicPlaneHeightMeters:englishEntry:)` for P1 |
| `EnvironmentLighting.swift:272–274` | `englishDrawOrder: Int32 = 2` (P2's sort-order note; `ImmersiveView.swift:204–209`) |
| `ImmersiveView.swift:32–36, 61, 193–215, 349–426` | second `@State` cache and driver; `englishEntity` under `textRoot`; `applyCurrentAyah` factored so one body runs per layer with its cache/driver/entity/offset; `showEnglishLayer` static let for B5's A/B |
| `QuranSpatialTests/TranslationDataTests.swift` | **new.** 78 ayat once each in order; `rawSHA256` equals the pin; decoded text hashes to `textSHA256`; absence path returns nil without throwing; rasterizing English does not mutate it (`isByteIdentical`); the three-glyph font test |
| `QuranSpatialTests/WrappedLayoutTests.swift` | add: the Arabic call with default parameters produces the same `pixelSize`/`lineCount` for every segment as before the signature change |
| `CreditsView.swift` | one line, **only when the file is present**: "English translation: Saheeh International (via Quranpedia)" (decision 22), using the same optional-decode pattern as `:25–28` |

**Touches the text pipeline or dissolve — required by B4:** `rasterizeWrapped`'s two new
defaulted parameters (`ArabicTextRasterizer.swift:141–152, 220–232`); `AyahTextureCache.init`;
`DissolveDriver.init(recordsFrameStats:noiseSeedOffset:)`. No USD change.

### States added

None. The English layer is display only; it reads `displayedSegmentIndex` and the same pin.

### Device test

| # | steps | pass | fail | decided by |
| --- | --- | --- | --- | --- |
| T19 presence | install with the file; launch; open the space | launch report `english: loaded 78 ayat, textSHA256 ok, font <name>`; English visible under the Arabic from ayah 1; intro shows Arabic only | `english: absent` with the file present; hash mismatch | `Documents/` report + eyes |
| T20 absence | delete the file, rebuild, launch | `english: absent`, no English entity, Arabic unchanged, no Credits line | any English drawn; crash | report + eyes |
| T21 wrap and placement | ayat 33 (3 Arabic lines), 39 (2), 1 (1), a refrain | English sits below the Arabic bottom edge with `englishGapDeg` on every one; no overlap; both fit under the pavilion arch (`AyahPlaneGeometry.swift:29–35`) | overlap; English hidden behind stone | eyes; `text-placement.txt` extended with English dimensions |
| T22 dissolve | any boundary | both layers dissolve together with different noise patterns; **no layer dissolves twice** across a boundary and across an Ask (T10 with English on) | double fade on either layer; identical noise | eyes + Console |
| T23 glyphs | ayat 2, 33, 56, 74 (ā/ī) and any with ’ | every glyph drawn, no `.notdef` box | a box or a substituted face (logged name ≠ system font) | eyes + log |
| T24 ask | T10 and T13 with English on | pin and recall hold both planes; release is a no-op for both | English flashes to n−1 or re-fades | eyes + Console |

### What could break

- **The Arabic pipeline itself**: the signature change to `rasterizeWrapped`. Defaults keep
  behaviour, and the `WrappedLayoutTests` addition proves it per segment; run the whole test target
  before the first English device build.
- **Frame statistics**: a second `DissolveDriver` that also records would double-count every frame
  and write a second `frame-stats.txt` header. `recordsFrameStats: false` is the guard.
- **Boundary cost**: every transition does twice the work (P1/P1b). B5 measures it; the 50 ms hitch
  bar is the criterion.
- **Sort order**: without `englishDrawOrder` the distance sort can put the sky dome after the
  English plane (the Stage 8 black rectangle, `ImmersiveView.swift:204–206`).
- **Memory**: +3 textures resident; bounded, and M3 samples the footprint.
- **Licensing**: the file must never be present when building for anyone else. The `.gitignore`
  rule and the absence path are the two guards; the disclosure records the status.

---

## B5. Measurement gate for B4

Runs the Stage 1 report's **M1 + M1b + M2**, A (Arabic only) vs B (Arabic + English), order
**A B B A**, conditions exactly as "Conditions for M1/M1b/M2" in that report.

- **A and B are two builds**, differing only in `ImmersiveView.showEnglishLayer` (decision 25).
  Keep both `.app` bundles and install alternately with `xcrun devicectl device install app`. The
  translation file is present in both, so the difference is the layer, not the load. **Debug HUD
  off in both.**
- **Range**: from the dua acceptance through the end of **ayah 36** (296.62 s): includes ayah 33
  (231.20–265.63 s, the only three-line ayah and the largest raster) and 36 boundaries. About 5 min
  per run; no `debugStop` — run to ayah 36 and end the trace.
- **Cool start**: relaunch for every run; the first `frame-stats.txt` header line
  `New run: frame stats reset, thermal starting at nominal` is the check.
- **M1** RealityKit Trace + **M1b** Time Profiler in one Instruments session per run: render-server
  CPU/GPU frame time and drops over the range; main-thread time per boundary attributed to
  `generatePlane`, `material(forSegmentIndex:)`, `TextureResource.init`, `FrameStatsLog.flush`.
  **M2** `frame-stats.txt` pulled after **each** run to a scratch path
  (`devicectl device copy from … --source Documents/frame-stats.txt`), checked, then kept under
  `docs/measurements/b5/<run>.txt`.
- **Gate (pass = English stays in the baseline)**: in **both** B runs, dropped frames < 1 % and no
  hitch > 50 ms across the range (`FrameStats.swift:27, 30`); worst thermal **below `.serious`**,
  with the first `.fair` logged and reported (decision 24); render-server dropped frames in B not
  worse than A by more than the A–A spread; boundary main-thread cost in B under one 11.1 ms frame.
  Report each run separately plus the A–A and B–B spreads.
- **On fail** (decision 26): drop to **D4** and re-run B B; if that also fails, English is out of
  the baseline and stays a local-build experiment. The four `frame-stats.txt` files and the trace
  are the record either way.

---

## Day-by-day

Today (30 September) is planning only. The device runs visionOS 27; every gesture or audio test is
a device build. Commits are at your call; the plan assumes one per landed item.

**1 October — B1, B2, B3 core. Includes the challenge orientation: the device-test block is
movable.**
1. Morning: B3's coordinator changes first — `paused`, `asking`, pin + recall, run ticket,
   `enterAsk`/`exitAsk` with the refusals, `seek(toTime:)` with landing log, stepped volume ramp,
   pre-roll JSON (`--json`) and loader, probe-string removal, stale comments, thermal verdict; unit
   tests (`AskTransitionTests`, progression and FrameStats additions). B1 depends on the pin, so
   B3's core lands first even though B1 is first in scope.
2. `AudioSessionController` with both interruption paths, the decided policies, snapshot log;
   `AudioInterruptionTests`. `configureForPlayback/Recording` and the DEBUG recording probe (B2).
   You add the microphone key in Xcode.
3. **Device block (movable around orientation, ~2 h):** T1, T10–T12b, T15, T16, T2, T4, T4b, T7,
   T9, in that order — Ask before interruptions, so a B1 failure is not confused with a B3 one.
   T13/T14 are in the same block. Pull `frame-stats.txt` after each. If orientation displaces the
   block, it moves to first thing on 2 October and B4 starts correspondingly later.
4. Evening: fixes from the block. Nothing from B4 starts today.

**2 October — B3 finish, B4, B5 dry run.**
1. Morning: whatever of the 1 October device block did not run; remaining B3 fixes; T17, T18; T3,
   T5, T8. **B3 and B1 must pass their tests before noon or B4 shrinks** (cut list below).
2. Midday: B4 — translation loader and tests, rasterizer parameters with the regression test,
   cache/driver inits, geometry constants (`englishEmDeg` 1.3°, `englishGapDeg` first value), view
   factoring, sort order, Credits line. Generate the local translation JSON from the pinned raw file.
3. Afternoon, device: T19–T24, tuning `englishEmDeg`/`englishGapDeg`. Then one **M2-only** A/B pair
   (no Instruments) to see whether the hitch bar is in danger before committing 3 October's device
   time to the full gate.
4. Evening: fixes. Flip `showDebugHUD` back to `false`. Build the A and B bundles for 3 October.

**3 October — testing, debugging, baseline. Nothing new built.**
1. Morning, cool device: B5 in full — A, B, B, A with Instruments, ~5 min each plus cooling. Decide
   the gate.
2. Midday: **full-surah run** of the chosen configuration (M3): `frame-stats.txt` and a memory
   sample; verdict against the three criteria with the `.serious` bar. One deliberate Siri
   interruption in a second full-surah run if time allows (T2 at full length; expect the app to stay
   paused if Siri does not recommend resuming — resume with the HUD button and note it).
3. Afternoon: debugging only — anything the runs exposed. Re-run the affected test, not the suite.
4. End of day: confirm `git status` shows no `en-*.json`; remove the translation file from any
   build that will leave your devices; tag **`baseline-2026-10-03`** with `docs/` (the Stage 1
   report, this plan, `docs/measurements/` including the B5 results) committed alongside
   (decision 28).

**If it does not fit 1–2 October, cut in this order (decision 27):**
1. **B5 to M2 only** (frame-stats A/B, no Instruments) — the hitch bar is still measured; sub-frame
   cost is not. Restore M1/M1b on 3 October if the morning is free.
2. **B4 dissolve to D4** (English hard-cuts) — removes the second driver and the per-frame writes;
   keeps the layer.
3. **B4 entirely** — the baseline ships Arabic only; the translation can go in no distributed build
   anyway, so the challenge loses a local-only demo layer, not a shippable one.
4. **B2's recording probe** — keep the category switch and the Xcode key; prove the mic during the
   challenge's own capture work.
5. **Never cut B1 or B3.** B1 is a live bug and B3 is what Ask is.

(The former item "B4 to placement P2" is gone with P3; P1 is the only placement.)

---

## Baseline disclosure — what it must contain

Every component in the tagged baseline, its third-party rights, its licence status, and where the
evidence is in the repo. Statuses are as recorded on 2026-09-30; **UNRESOLVED** items block
distribution beyond your devices.

| component | rights holder | licence / status | evidence in the repo |
| --- | --- | --- | --- |
| Quran text, Surah 55, Uthmani | Tanzil Project (Tanzil Quran Text, Uthmani v1.1) | CC BY 3.0 — **satisfied**: verbatim, source named, live link, notice travels with the text | `QuranSpatial/Resources/ar-rahman-text.json` (`source`, `sourceURL`, `sourceSHA256`, `license`, `copyright`); `CreditsView.swift:36–53`; `RecitationDataTests.swift:72` and the byte-identity tests |
| Hand-typed ayah 1 (`Ayah.swift:16`) | — | **removed in B3** (Stage 2); until then, a probe string never displayed, not byte-identical to the corpus | Stage 1 report 8.1; B3 file list above; after removal, `git log` on `Ayah.swift` |
| Recitation audio `rahman-single.mp3` | performance: Qari Ismail Nouri; publisher/channel "Garden of Verses" (from the file's own ID3 tags) | **UNRESOLVED — no licence, terms or permission; open ship blocker** | CLAUDE.md "Recitation audio — unresolved"; `CreditsView.swift:55–63` (provisional credit); `AudioAssetReport.swift`; SHA-256 `bf48c019…c0` in `docs/stage-1-report.md` B3 |
| Timings `ar-rahman-timings.json` | own work (boundaries corrected by ear, validated statistically), derived from the audio above | no third-party rights of its own; inherits the audio's unresolved status as a derivative | `RecitationTimings.swift:8–12`; `RecitationDataTests.swift`, `RecitationProgressionTests.swift` |
| Pre-roll table `ar-rahman-preroll.json` (new in Stage 2) | own measurement over the audio | as the timings | `docs/measurements/b3-preroll.py`, `b3-preroll.csv`; the JSON's `mp3SHA256` and `marginDb` fields |
| Ship font Amiri Quran 1.003 | The Amiri Project Authors, 2010–2022 | SIL OFL 1.1 — **satisfied**; shipped unmodified; no Reserved Font Name | `QuranSpatial/Fonts/AmiriQuran.ttf` + `QuranSpatial/Fonts/OFL.txt`; `CreditsView.swift:65–90`; `QuranSpatialTests.swift:32` |
| KFGQPC Uthmanic Hafs v2.2 | King Fahd Glorious Quran Printing Complex | **not shipped** since 2026-09-04; licence reading recorded but not resolved | absent from the build; CLAUDE.md "KFGQPC licence — the file carries its own grant"; gitignored `scratch/` only |
| English translation, Saheeh International | Saheeh International (translation); distributed via Quranpedia book 1947 | **UNRESOLVED — no licence notice in the file; distribution blocked; text not in the repo; local builds only** | `docs/stage-1-report.md` "Decisions (human)" (raw SHA-256 `8c08a833…3978`, extraction rules); the gitignore rule; `RecitationTranslation.swift` absence path; `TranslationDataTests` hash checks; `CreditsView` line in local builds. Full record: claude.ai Project 'Quran AVP', `claude/english-translation-edition.md` (outside the repo) |
| Quranpedia data (books 1947 and 13638 JSON) | quranpedia.net | **terms unknown**; no licence notice in either file; the dumps manifest does not cover them. Extraction and comparison only; **not shipped** | `docs/stage-1-report.md` "Decisions (human)"; raw files held outside the repo |
| English font (F1: Apple system font) | Apple | platform licence; nothing bundled | `TranslationDataTests` glyph test; launch report logs the resolved name |
| Environment `QuranSpatial_Environment_Corrected.usdz` and its 21 texture maps | **to be supplied by you** (decision 29) — not recorded in the repo or CLAUDE.md | **pending your statement** | `QuranSpatial/Resources/…usdz`; `PavilionEnvironment.swift:38`; CLAUDE.md "Environment asset" records measurements, not provenance |
| RealityKitContent materials (`DissolveMaterial.usda`, `NightSkyMaterial.usda`, `StarSpriteMaterial.usda`, `Immersive.usda`) | own work | — | `Packages/RealityKitContent/…/Materials/` |
| Sky, stars, lighting, star-field mesh, grey-box | own work, procedural | — | `EnvironmentLighting.swift`, `StarFieldMesh.swift`, `GreyBoxEnvironment.swift` |
| Hand-tracking captures `capture/*.json` | your own hand data | personal data, yours; tracked deliberately | `capture/`, CLAUDE.md "Capture workflow" |
| App icon / assets | own work unless stated | — | `Assets.xcassets` |
| Apple SDKs, Core Text, RealityKit, ARKit, AVFoundation | Apple | Xcode / SDK licence; **Xcode 27 is beta** — TestFlight only, no App Store submission from it | CLAUDE.md "Platform" |

The disclosure should also state, in one line each: that the baseline was built with Xcode 27
beta against SDK visionOS 27.0 for deployment target 26.5; that no build containing the English
translation file left your devices; and that the hand-typed probe string was removed before the
tag (or, if B3 slips past the tag, that it is present and never displayed).

---

## Decisions recorded (2026-09-30, after review)

| # | decision |
| --- | --- |
| 1 | `paused` in `PlaybackState`; reason as a property |
| 2 | `asking` added to `ExperiencePhase` |
| 3 | interruption ended without a resume recommendation: stay paused |
| 4 | pause on `oldDeviceUnavailable`; no auto-resume on reconnect |
| 5 | pause on scene phase `.background` only; ignore `.inactive` |
| 6 | session strategy S1 |
| 7 | you add `INFOPLIST_KEY_NSMicrophoneUsageDescription` in Xcode on 1 October |
| 8 | recording probe in scope |
| 9 | on Ask entry (and on a system-interruption pin), progress ramps from its current value to 0 at the fade-in rate, in both the incoming and outgoing windows; a user-invoked recall is not a second dissolve |
| 10 | stepped `player.volume` ramp 0 → 1, `min(0.25 s, 0.6 × pre-roll)`; zero-tolerance seek; every resume seek logs its landing time |
| 11 | segments 1 and 38: `segment.start` with a 0.15 s fade; not refused |
| 12 | separate `ar-rahman-preroll.json` |
| 13 | refuse Ask on segment 0 and after `completed`; allow on ayah 78 |
| 14 | HUD debug buttons |
| 15 | run ticket replaces the backward-index FrameStats reset |
| 16 | placement P1; `englishEmDeg` starts at 1.3°, `englishGapDeg` tuned on device |
| 17 | dissolve D1 with its own noise seed; D4 is the fallback |
| 18 | font F1 (system), with the glyph test for U+0101, U+012B, U+2019 |
| 19 | English lines centred |
| 20 | same white; no `textColor` bind |
| 21 | translation file and gitignore rule as proposed; `textSHA256` over ayat joined by `\n`; no punctuation tests |
| 22 | Credits line in local builds only: "English translation: Saheeh International (via Quranpedia)" |
| 23 | intro shows no English |
| 24 | a run fails on `.serious`; log when `.fair` first appears |
| 25–27 | two-build A/B; gate criteria and on-fail path; cut order — accepted |
| 28 | tag `baseline-2026-10-03`, with `docs/` committed |
| 29 | you supply the environment provenance |
| 30 | `DissolveDriver` single `do`/`catch` left for after the challenge |
| 31 | stale comments fixed in files B3 already edits |
| corrections | audio-mix ramp replaced by the stepped ramp; `Ayah.swift:16` removed; P3 dropped; 1 October device tests movable around orientation |

## Schedule change — 2026-10-02

**Cut items 1 and 2 are in effect.** B5 is **M2-only** (`frame-stats.txt` A/B, no Instruments)
and B4 is built at **D4** (English hard-cuts; one `UnlitMaterial`, no second dissolve driver).
D1 and the Instruments runs (M1/M1b) return **only if time is left on 3 October**, after the
full-surah run and the baseline work. B3's core landed on 1 October (branch `stage-2`, commit
`5e2d22f`, unit-tested, not device-tested); B1, B2 and the HUD debug buttons follow on the
night of 1–2 October; the 1 October device block moved to the morning of 2 October.

## Decisions that change an estimate or the cut order

- **1 October orientation.** The largest change. The device block (~2 h) may slide to the morning
  of 2 October, which pushes B4's start to the afternoon of 2 October and makes cut items 1–2 (B5 to
  M2-only; D4 instead of D1) **likely rather than contingent**. If the block does slide, decide at
  noon on 2 October whether B4 starts at D1 or D4; starting at D4 and upgrading is cheaper than
  the reverse.
- **Decision 9 (recall ramp, also on system pauses).** Adds the entry snapshot, the pure recall
  function and two device tests (T13/T14 now have a definite expected behaviour). About +1.5 h on
  1 October, inside B3. No cut-order change.
- **Decision 10 (stepped ramp, landing log).** Roughly the same effort as the mix ramp it replaces;
  adds one cancellation path per pause/stop and the T18 ramp check. No estimate change.
- **Probe-string removal.** Touches `FontIdentityReport` and four test sites; +1 h on 1 October,
  inside B3. The launch report gains a corpus dependency to guard. No cut-order change.
- **Decision 24 (thermal bar).** Two one-line edits plus a test; +30 min. It also makes the B5 gate
  and the 3 October verdict **easier to pass**: `.fair` no longer fails a run.
- **Decisions 3 and 4 (stay paused).** Slightly less code than auto-resume, but they move a need
  forward: after any Siri press or AirPods drop during the challenge demo, the app stays paused
  until the out-of-scope resume trigger exists. Not an estimate change for Stage 2; a scope note for
  the challenge's first day.
- **Decision 8 (probe in scope)** and **decision 11 (fallback, no refusal)** confirm what the plan
  already costed; no change.
- **P3 dropped** removes one cut item; the cut list is now four items plus the never-cut pair.
