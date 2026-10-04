# Quran Spatial

visionOS app presenting Surah Ar-Rahman as an immersive spatial experience. The user
raises both hands in a dua posture; that gesture triggers recitation playback and a
dissolve of the on-screen Arabic text.

Ship deadline: **3 November 2026.** When a tradeoff is between scope and the date, cut
scope and say so — do not silently take on work that widens the critical path.

## Platform

Three separate version numbers are in play here. They are not meant to match, and
conflating them has already caused confusion twice:

- **Build SDK: visionOS 27**, via Xcode 27 beta at `/Applications/Xcode-beta.app`.
  Verify with `xcrun --sdk xros --show-sdk-version`.
- **Deployment target: 26.5.** This is the minimum OS a user needs to run the app. Do
  **not** raise it to match the build SDK or the test device — nothing in this project
  uses a 27-only API, and raising it would exclude every user who hasn't updated, for
  zero gain.
- **Test device: Apple Vision Pro running visionOS 27 (beta).**

**Xcode 27 is in beta.** Beta-built binaries can go to TestFlight but **not** to the App
Store. A released (non-beta) Xcode is required before App Store submission.

- Swift, SwiftUI, RealityKit, ARKit, Core Text.
- Physical Apple Vision Pro is available for testing. The simulator is not a substitute
  for anything involving hands (see Testing).

## Identifiers

- App bundle ID: `com.vrteek.quranspatial`
- Test bundle ID: `com.vrteek.quranspatial.tests`
- Scheme: `QuranSpatial`

## Locked decisions

These were argued through already. Do not reopen them, propose alternatives, or quietly
drift toward the rejected option. If you believe one is now wrong, say so explicitly and
wait for a decision before writing code against it.

### Arabic text rendering — Core Text

All Arabic layout and shaping goes through **Core Text**. This is not negotiable:
default text renderers produce incorrectly shaped Arabic — wrong contextual forms,
broken ligatures, mangled bidi. Verified firsthand.

- **No per-glyph bounding boxes in V1.** Line- and run-level geometry only.
- Never fall back to `NSAttributedString` convenience rendering, `Text` with raw Arabic
  for anything the effect touches, or any shaping path other than Core Text.
- Outside the app (tooling, mockups, generated assets), rasterize via HarfBuzz or Pillow
  with a real Arabic-shaping font. Do not assume a PDF or image generator shapes Arabic
  correctly — assume it does not until proven.

### Dissolve effect — shader, primary

**`dissolveTicket` is deliberately unconsumed as of 2026-09-04.** The coordinator fires it
at `end - dissolveLeadTime` for every qualifying segment and nothing listens. That is the
accepted state pending the dissolve milestone, which gets its own directive. **No opacity
fade, alpha ramp or other stand-in is permitted in the meantime** — a stand-in is exactly
the thing that quietly becomes permanent.

On visionOS the dissolve must be a **`ShaderGraphMaterial` authored as a USD asset** (the
Reality Composer Pro path, as `Packages/.../Materials/GridMaterial.usda` already uses).
`CustomMaterial` with a Metal surface shader **is not available on visionOS**.


The shader dissolve is the **primary V1 visual effect**, not a fallback and not a stretch
goal. Do not scaffold a "simple fade for now, shader later" path. If the shader is not
working, the fix is to fix the shader.

**VERIFIED ON DEVICE 2026-09-06. The dissolve renders. It is the BASELINE and nothing about
it changes.** Confirmed by the wearer, not inferred: the HUD reads `dissolve: material
loaded` and the effect is visible. Everything below it in this section is the record of what
it took to get there, and all of it stays true.

Any alternative exit transition — the particle experiment among them — is an **A/B against
this baseline**, never a replacement in flight. The dissolve is not removed, disabled, or
degraded until a wearer has seen both and chosen explicitly.

#### DEFECT — `realitytool` silently drops a material containing certain noise nodes

**Established 2026-09-05 on device.** `realitytool compile` **exits 0** and writes a
`.reality` that contains only the scene's `Root` Xform — no material, no shader nodes. At
runtime every spelling of the path then returns
`ShaderGraphMaterial.LoadError.materialNameNotFound`, which reads exactly like a missing
file or a mistyped path and is neither. Roughly two hours went into the path string before
the compiler was suspected at all.

| node | outcome |
| --- | --- |
| **`ND_fractal2d_float`** | **DROPPED** |
| **`ND_unifiednoise2d_float`** | **DROPPED** |
| **`ND_unifiednoise3d_float`** | **DROPPED** |
| `ND_fractal3d_float` | survives |
| `ND_noise2d_float`, `ND_noise3d_float` | survive |
| `ND_cellnoise2d_float`, `ND_cellnoise3d_float` | survive |
| `ND_worleynoise2d_float`, `ND_worleynoise3d_float` | survive |

`fractal2d` fails bare, with default inputs, and fully connected alike — it is the node's
presence, not its configuration. It is also the only noise node with a **declared**
`target="realitykit"` implementation in the SDK's `apple_implementations.mtlx`, so the
declaration is not evidence that a node works, and its absence is not evidence that one
does not. **`ND_fractal3d_float` is the drop-in replacement**: same
amplitude/octaves/lacunarity/diminish knobs, wants a `vector3`, so widen the seeded UV with
`ND_convert_vector2_vector3` and leave the third component at zero.

**How to test this, and how NOT to.** The check is whether the compiled manifest contains a
`Material` entry for the prim:

```bash
strings -n 4 out.reality | grep -o '{"scenes".*}' | python3 -c \
  "import json,sys; print([a['label'] for a in json.load(sys.stdin)['assets'] if a['typeName']=='Material'])"
```

**Do not judge it by grepping the binary for node names, and do not judge it by exit
code.** A strings-based count saturates — a one-node material and a three-node material
both come out at the same size and the same match count, so the metric reports "fine" for
graphs of wildly different content. Exit code is 0 in every case, including total loss of
the material.

Compile any hand-authored MaterialX change this way **before** building the app. It costs
seconds; discovering it through a device install costs a build, an install and a launch.

#### DEFECT — only `ND_image_float` gets a texture slot from a promoted `asset` input

**Established 2026-09-05 on device.** A runtime-settable texture on a hand-authored
`ShaderGraphMaterial` needs **two** conditions, and missing either produces the identical,
deeply misleading symptom.

1. **The image node must be `ND_image_float`.** Holding the file, the path and the rest of
   the graph constant and varying only the node, the compiled manifest allocates:

   | node | `Texture:` entries |
   | --- | --- |
   | **`ND_image_float`** | **1** |
   | `ND_image_color3` | 0 |
   | `ND_image_color4` | 0 |
   | `ND_RealityKitTexture2D_color4` | 0 |

   Note the last row: RealityKit's *own* texture node does not get a slot from a promoted
   input either, so "it is the RealityKit node, it must be the right one" is wrong.

2. **The default asset path must RESOLVE at compile time.** `@@` allocates no slot.
   The path resolves against **the containing `.usda`'s own directory**, not the
   `.rkassets` root — a material in `Materials/` reaches a texture at the root as
   `@../Textures/x.png@`. This is the single easiest thing to get wrong, and it fails
   silently: nothing warns, and the asset simply is not compiled in.

**The symptom of a missing slot is not "texture rejected".** The parameter still appears in
`parameterNames`, so it looks present. But `getParameter` returns **nil**, and
`setParameter` rejects **every** `MaterialParameters.Value` case with
`incorrectTypeForParameterName` — `.float` and `.bool` included. **That is the diagnostic
tell:** a genuine type mismatch would accept *some* type. A parameter that accepts none has
no slot behind it, and the fix is in the USD, not in the Swift.

**Detect it locally, in seconds, without a device:**

```bash
strings -n 4 out.reality | grep -o '{"scenes".*}' | python3 -c \
  "import json,sys; from collections import Counter; \
   print(Counter(a['typeName'] for a in json.load(sys.stdin)['assets']))"
```

A promoted texture parameter that works shows `Texture: 1`. Zero means the slot was never
allocated, whatever the Swift looks like.

**Sampling a float rather than RGBA costs this project nothing**, which is why the
constraint is survivable: the ayah raster is opaque white glyphs drawn into a
`premultipliedLast` context, so red and alpha are equal at every pixel and a one-channel
sample *is* the glyph coverage. Colour comes from the `textColor` parameter. A design that
needed real per-pixel RGB from a runtime-set texture would have to solve this differently.

Confirmed working on device: `get textTexture -> textureResource(RealityKit.TextureResource)`,
and both `.textureResource` and `.texture` set successfully.

#### PARAMETER TYPE TABLE — bind these cases, not the plausible ones

**Written down because the mistake was measured on the dissolve material and then re-made,
two days later, in the particle driver.** `color3f` binds with `.color`; `.simd3Float` is
rejected. Knowing it once was not enough — it has to be somewhere the next binding gets
checked against.

| parameter | material | declared MaterialX type | binds with |
| --- | --- | --- | --- |
| `progress` | both | `float` | `.float` |
| `edgeWidth` | both | `float` | `.float` |
| `noiseScale` | both | `float2` | `.simd2Float` |
| `noiseOffset` | both | `float2` | `.simd2Float` |
| `textColor` | dissolve | `color3f` | **`.color`** (CGColor) — NOT `.simd3Float` |
| `textTexture` | dissolve | `asset` | `.textureResource` — needs `ND_image_float` and a resolving default |
| `particleColor` | particle | `color3f` | **`.color`** (CGColor) |
| `travelSpan`, `riseHeight`, `spreadWidth`, `driftDepth`, `fadeStart`, `spriteSoftness`, `brightness` | particle | `float` | `.float` |
| `releaseSource`, `debugForceVisible` | particle | `float` | `.float` |

**Hold colour constants as `CGColor` in Swift, never as `SIMD3<Float>`.** The type of the
constant is what stops the call site drifting back to the wrong case.

**Bind parameters INDIVIDUALLY.** A single `try` over a list means one rejected type throws
and the `catch` discards the whole material — so a wrong colour presents as a completely
absent effect, which cannot be diagnosed by looking at it. Both drivers now bind each
parameter in its own `do`/`catch`, name the failures, and keep the material with the rest
applied. A wrong colour should look like a wrong colour.

#### Core Text rasterizes differently on visionOS — device figures are the only valid ones

Compiling `ArabicTextRasterizer` into a macOS tool is a legitimate way to explore, and it is
how the ink and stroke figures above were derived. **But anything downstream of
rasterization does not transfer.** Ayah 1 sampled 285 particles on macOS and **251 on
device** — 12% fewer, from an identically sized raster and a deterministic sampler. Hinting
and antialiasing differ, so different pixels clear the alpha threshold.

Treat macOS numbers as an order-of-magnitude check and nothing more. Particle counts, ink
areas and anything derived from them must be measured on device; `ParticleExitDriver`'s
launch probe reports them into `particle-report.txt` for exactly this reason.

#### REJECTED — particle exit transition (prototyped 2026-09-06, cut the same day)

**Prototyped, evaluated on device across several builds, and CUT on visual grounds. The
dissolve stands as the V1 exit transition.** This restores the position recorded elsewhere
in this file — particles were the pre-agreed cut under scope pressure — but it is now a
tested conclusion rather than a scoping guess.

The work is preserved on branch **`experiment/glyph-particles`**, at design values rather
than the exaggerated diagnostic ones, and is removed from `main`. **Do not rebuild it from
scratch.** If it is ever revisited, start from that branch.

Why it lost: at every setting tried, the particles read as the text breaking into pieces
rather than dissolving into light. Coarse settings looked like rubble; fine settings
(13,847 particles on ayah 33, 2px pitch) were better but still did not beat the shader
dissolve, which stays continuous with the calligraphy in a way a cloud of discrete quads
did not.

**What was learned. This is here so it is not rediscovered at the same cost.**

- **`ParticleEmitterComponent` cannot emit from a mask.** `EmitterShape` is
  point/plane/box/sphere/cone/cylinder/torus; `BirthLocation` is surface/volume or a grid
  subdivision of those; `ParticleEmitter.image` is the particle's own sprite. No texture
  mask, no point list, no per-particle position API. It can only emit from a primitive
  behind the text. Read from the framework interface, not from documentation.
- **`MeshDescriptor` has no vertex-colour buffer.** `MeshBuffers` offers positions, normals,
  tangents, bitangents, textureCoordinates and triangleIndices, and nothing else. Any
  per-vertex payload beyond those requires `LowLevelMesh`, where the vertex format is yours
  to declare.
- **`LowLevelMesh` buffer access and `MeshResource(from:)` are both `@MainActor`.** Heavy
  build work therefore has to be SPLIT: a pure, `Sendable` prepare phase that can run off
  the main actor, and a minimal upload phase that cannot. Building 13,847 particles in one
  main-actor call measured **14.0 ms** — longer than a 90Hz frame, dropping one at the
  segment boundary. Split into prepare-plus-memcpy it measured **0.46 ms**, and stayed
  nearly flat with particle count because what remains is allocation rather than copying.
  **This applies to any future mesh built at runtime, not just to particles.**
- Vertex colour declared `float4` rather than a packed byte format, because a UV quantised
  to 8 bits per channel lands about five raster pixels away from where it should.
- `ND_realitykit_surface_time` and `ND_realitykit_geometry_modifier_time` both exist and are
  both **deprecated** in favour of `ND_time_float`.

### State architecture — two enums### State architecture — two enums

**REVERSED 2026-09-04, on schedule grounds: the enums are no longer hand-written by
Mohamed.** They were, until that date, his to write and maintain; they are now in the repo
as `ExperiencePhase.swift` and `PlaybackState.swift`, written to the design below. The
design itself is UNCHANGED and still binding — only who writes the files changed. The
original line is kept rather than deleted so that reading this in six weeks tells you which
is true.

`ExperiencePhase` and `PlaybackState` are **separate enums**. They are not merged, not
nested, and `PlaybackState` has no associated-value case that stores a prior state.

The earlier recursive `paused(from:)` design was removed deliberately: it made the state
space unbounded and pause-resume unreasonable to test. If you need to resume to a prior
state, store it as a distinct stored property, not as an associated value on the case.

### Gesture model — dua is ENTRY ONLY

**Supersedes every hold-to-play design in this file and in the repo. Decided 2026-09-04.**

- Acceptance of the dua pose is a **one-way transition** into the playing state.
- **After acceptance, hand state is ignored entirely.** Releasing or lowering the hands has
  no effect on audio, ayah progression, or phase. There is no pause-on-release, no resume
  and no restart-current-ayah; those code paths were deleted. **`PlaybackState` gained a
  `paused` case on 2026-10-01 (Stage 2, Ask mode) — reached ONLY by
  `RecitationCoordinator.pause(reason:)`: Ask entry, a system interruption, a route loss or the
  app going to the background. Hand state still cannot reach it.** `ExperiencePhase` gained
  `asking` the same day, entered only through `enterAsk()`. The two enums stay flat and
  separate; the pause reason and the resume position are stored properties, not associated
  values.
- **The closed-hand gesture is the stop interaction**, and it is not in this milestone.

A false positive now commits the wearer to the full surah with no implemented exit, so the
accept side is deliberately tightened three ways:

1. **Enter bounds raised**: `palmInwardDotEnterMin` 0.40 → 0.58 and
   `palmTowardHeadDotEnterMin` 0.30 → 0.42. This is the vector `tools/threshold_search.py`
   selects under the asymmetric objective — zero confuser commits, all seven true commits,
   worst confuser rejection 1.31× M → **3.31× M**, worst true margin 1.98× M → 1.10× M. The
   one-person limitation still applies: this buys margin against the confusers we have.
2. **`DuaEntryGate.acceptanceDwell` = 0.4s**, on top of the recognizer's 1.5s commit window.
   Acceptance is not the first `.held` frame; the pose is qualified for **1.9s total**.
3. **Re-arm requires a release EDGE.** After the surah ends the gate sits in
   `.awaitingRelease` and will not accept again until the pose has fallen back under the
   exit bounds at least once. Without this, hands still near dua at ayah 78 restart the
   surah immediately.

A **debug-only abort** (`RecitationCoordinator.debugStop`, `#if DEBUG`, surfaced in the dua
HUD) returns to idle. Not shipped and not user-facing: without it every accidental
acceptance during device testing costs a ten-minute recitation.

### State machine

Two flat enums, still separate, still not nesting each other. **Updated 2026-10-02 for Ask
mode (Stage 2):** `paused` and `asking` added, both reached only through coordinator calls,
never through hand state.

`ExperiencePhase`: `.idle` → `.reciting` ⇄ `.asking`; `.reciting` → `.completed`.
`PlaybackState`: `.stopped` → `.playing` ⇄ `.paused`; `.playing` → `.finished`.

Alongside, three stored properties that are NOT states: `pauseReason` (ask / interruption /
route / background), `pinnedSegmentIndex` (the ayah held on screen while the audio is
elsewhere; `displayedSegmentIndex` is it or the audio's segment) and `resumePlan` (seek
target and fade for the next resume, from `ar-rahman-preroll.json`).

| from | event | to |
| --- | --- | --- |
| `.idle` / `.stopped` | dua accepted (1.9s qualified) | `.reciting` / `.playing`; `runTicket` increments |
| `.reciting` | hands released, lowered, re-posed | **no change — ignored** |
| `.reciting` | segment boundary crossed | no phase change; `currentSegmentIndex` advances |
| `.reciting` / `.playing` | `enterAsk()` — refused on the intro, after `.completed`, or when already asking; allowed on ayah 78 | `.asking` / `.paused` (reason `ask`); the displayed segment is pinned and its dissolve recalls to 0 at the fade-in rate |
| `.asking` / `.paused` | `exitAsk()` | `.reciting` / `.playing`: zero-tolerance seek to the anchor's speech-free gap start, stepped volume ramp (`min(0.25s, 0.6 × pre-roll)`; segments 1 and 38: segment start, 0.15s), pin held until `anchor.start + 0.5s` then released |
| `.reciting` / `.playing` | system interruption began; route lost (`oldDeviceUnavailable`); scene phase `.background` | `.reciting` / `.paused` (reason recorded) — **phase unchanged**; current segment pinned as above |
| `.reciting` / `.paused` | interruption ended, resume recommended | `.reciting` / `.playing` via the same resume path |
| `.reciting` / `.paused` | interruption ended with no recommendation; route reconnected | **no change — stays paused** (auto-resume would be unbidden recitation); resumes only through `exitAsk()`/the debug Resume |
| `.asking` / `.paused` | system interruption, route loss | **no change** — already paused; the reason stays `ask`, so an interruption ending cannot end the Ask |
| `.reciting` / `.playing` | end of file | `.completed` / `.finished`; pin, ramp and plan cleared |
| `.completed` | gate sees release edge | gate re-arms; phase stays `.completed` until next acceptance |
| any | `debugStop()` (DEBUG only) | `.idle` / `.stopped`, pin cleared, ramp cancelled, `runTicket` increments, gate to `.awaitingRelease` |

**End of surah, explicitly.** Audio stops at the end of the file and is *not* rewound —
`playbackState` becomes `.finished`. Text: **ayah 78 stays on screen**; clearing it would
leave an empty plane with nothing to explain it, and there is no dissolve yet to retire it
with. Phase becomes `.completed`, deliberately distinct from `.idle` so "finished" and
"never started" cannot be confused. Re-arm is **not** immediate — it requires the release
edge above.

**Bismillah is the intro, not ayah 1.** Timings index 0 is the intro and carries no ayah
number; index N is ayah N. Ayah 1 is the single word that opens the surah. Both come from
the source's own fields — the bismillah from the XML `bismillah` attribute, ayah 1 from its
`text` attribute — and **no Quran text is ever typed by hand into source or tests**, which
would not match the source's byte representation and would fail the integrity checks.

**The 1Hz reconciliation observer** recomputes the expected segment from the player clock
and corrects and logs any disagreement. Boundary observers are the fast path;
`syncToCurrentTime()` is the source of truth because observers do not fire on a seek. The
gesture change does not affect any of this.

### Gesture sequencing

The **dua / prayer-posture recognizer must be demonstrably working on device** before any
work begins on the closed-hand recognizer. Do not scaffold the second recognizer "while
we're in here." Do not write a shared abstraction over both until the first one has
shipped behavior.

## Performance acceptance criteria

Judge performance against these, not against a raw fps number:

- Dropped frames **under 1%** across a session
- **No single hitch over 50 ms**
- **No thermal throttling** across a full-length session (full surah, not a 30s clip)

When profiling, report against all three. "It felt smooth" is not a result. A sustained
90fps average that includes a 120 ms hitch is a failure, not a pass.

## Build and run

Use the generic destination. Never hardcode a simulator device name — runtime versions
change and a named destination fails with a misleading "destination not found" error:

```bash
# Simulator
xcodebuild -scheme QuranSpatial \
  -destination 'generic/platform=visionOS Simulator' build

# Device
xcodebuild -scheme QuranSpatial \
  -destination 'generic/platform=visionOS' build

# What's actually available
xcodebuild -scheme QuranSpatial -showdestinations
xcrun simctl list devices available | grep -i vision
```

Pipe build output to a file and grep it rather than dumping full logs into context:

```bash
xcodebuild ... 2>&1 | tee /tmp/build.log
grep -E "error:|warning:" /tmp/build.log
```

### Device build

Discover the device UDID at run time — do not hardcode it, since it will differ per
machine and `devicectl list devices` can return multiple entries (simulated pairings
show up alongside the physical headset; filter on `Reality: physical`):

```bash
# Discover the connected physical Vision Pro's UDID
xcrun devicectl list devices

# Build for device
xcodebuild -scheme QuranSpatial \
  -destination 'generic/platform=visionOS' build

# Install the built .app onto the device
xcrun devicectl device install app --device <UDID> <path-to-.app>

# Launch it
xcrun devicectl device process launch --device <UDID> com.vrteek.quranspatial
```

## Project file rules

- **Never hand-edit `.pbxproj`.** A deny rule in `.claude/settings.json` enforces this,
  but treat it as a rule regardless. Source directories use Xcode's file-system-
  synchronized folders, so new `.swift` files are picked up automatically. Create the file
  in the right directory and stop there.
- If something genuinely requires a project-level change — a new target, a capability, a
  build setting, an entitlement — describe the change and let it be made in Xcode.
- Info.plist keys live in build settings as `INFOPLIST_KEY_*` in this project, not in a
  standalone plist file. `NSHandsTrackingUsageDescription` is already set.
- Never commit `xcuserdata/` or anything else per-user. It's gitignored; keep it that way.

## Testing

- **Hand tracking does not work in the simulator.** Every gesture change requires a device
  build. Do not report a gesture as working based on a simulator run, and do not write
  tests that pretend to exercise the recognizer through the simulator.
- Hand tracking data only flows while an `ImmersiveSpace` is open. Nothing in the Window
  scene will see hands.
- Use the simulator for layout, text rendering, navigation, and audio wiring.
- Keep recognizer logic separable from ARKit types so thresholds and the state machine can
  be unit-tested against recorded joint data without a headset.

### Dua recognizer: on-device status

Validated on device. Capture `dua-capture-2026-09-03T20-53-24Z` (2m17s, 22,231 frames,
162Hz) was recorded on the `fdcbfee` build and carries the recognizer's own `state` and
`event` per frame, so it is a live record, not a replay. Captures from the next session
also carry per-hand pose age and the two skip counters, so staleness is legible without
cross-referencing `isTracked`, and a gap in the data reports its own cause. Five dua postures, each detected
after exactly 1.51s in `entering` — the 1.5s commit window behaving on device as it does
in replay.

**The mushaf confuser is captured and clears nothing.** Two stretches, seated
(25.65–59.35s) and standing (79.60–120.30s). Across both, the longest run satisfying every
gate at enter bounds is **38ms**, against a 1500ms commit window. It is not the commit
window that rejects the mushaf — the gates reject it outright.

Which gate does the work, measured on the seated stretch (no tracking dropout, so this is
clean gate behaviour):

- `inward` rejects it: 0% of frames pass, and it is the *sole* failing gate in 100% of
  them. Holding a book open turns the left palm away from the right hand.
- `towardHead` passes it 100% of the time, weaker hand averaging 0.936 against a 0.30
  bound. It contributes nothing to rejecting a mushaf.
- Every other gate also passes 100%: separation 0.288m, extension 1.91/1.80, both hands
  tracked throughout.

So the static gate design is validated on device, but by `inward` alone — and that is a
narrower result than it sounds. The rejection depends entirely on a book splaying the left
palm away from the right hand, and at its best moment left inward reaches **0.406 against a
0.400 bound**: six thousandths of headroom. A mushaf held palms-inward, or resting open on
one palm, is the untested case that could defeat it outright. Do not treat the mushaf as a
solved confuser on the strength of one grip.

`towardHead` is a candidate for a looser exit bound. It has now passed both captured
confusers at wide margin while ending both true positives in `7282757` by drifting under
its exit bound — it is costing detections and buying nothing. **Pending device feel and at
least one more confuser; do not retune on the current evidence.**

The standing stretch is *not* clean gate evidence: the left hand was untracked for 81% of
it (poses stale up to 32s, though always carrying `isTracked: false`, so the `tracked` gate
rejected them correctly). It is mostly a tracking dropout.

**The headset adjust is captured only as a tracking dropout, not as measured gate
behaviour.** It appears as a 4.70s gap at t=63.69 with no frames at all. The recognizer was
`idle` either side and no hold was affected, but there is no frame data from during the
adjust itself, so nothing can be said about how the gates score a hand at the bezel. The
mechanism is confirmed benign: hand anchors stopped arriving, rather than the record path
stalling while anchors kept updating. Evidence — anchors carrying `isTracked: false` are
recorded normally elsewhere (19% of frames), so an untracked hand alone does not stop
recording; the right pose resumed stale by exactly the gap length, which the
device-anchor skip path could not produce because poses are assigned before that guard;
and frames resume at normal ~6ms cadence with no queue-flush burst.

Next session should capture, deliberately and long enough to measure rather than infer:

- a mushaf held palms-inward, and a mushaf resting open on one palm — the two grips that
  could defeat the `inward` rejection above
- a deliberate 30s lap rest — no take so far has hands more than 0.41m below the head, so
  `belowHeadY` has never rejected anything and is currently unexercised
- a deliberate 30s headset adjust, held long enough to produce frames rather than a hole

### Capture workflow

**Never pull into `capture/`. Pull to a scratch path, verify the file's size and that it
parses, then move it into place.** This is a rule, not a preference. A directory pull that
failed mid-transfer wrote a 0-byte file over the committed reference capture; it was
recoverable only because that file was tracked. The next attempt went to a scratch
directory instead, and that is the only reason the untracked 51MB take survived. A failed
transfer does not leave the destination alone.

Both reference captures are tracked deliberately, against the `capture/` ignore rule. They
are irreplaceable — re-recording costs a headset session and the wearer's time, and
`dua-capture-2026-09-03T20-53-24Z` is the only one with proven replay fidelity.

#### The transfer ceiling is the binding limit, not `maxFrames`

`maxFrames` is 120,000, sized for ten-minute takes. **That limit does not govern.** Pulling
from the device over the wireless link starts failing somewhere under 90MB: a ~40,000-frame
take (~90MB) failed three times with `socket closed unexpectedly` and then
`connection to the remote device is no longer valid`, having truncated one file at exactly
30,000,000 bytes on the way. A full ten-minute take would be roughly 250MB and would not
come off the device at all.

These are two different limits and **the smaller one governs**. A take that the recorder
will happily write is not necessarily a take that can be retrieved. Prefer a wired
connection for anything large, and treat Xcode's Devices and Simulators →
"Download Container" as the fallback when `devicectl` cannot finish.

### Dua recognizer: acceptance criterion

**The mushaf is an adversarial robustness test, not an acceptance criterion.** Someone
holding a physical mushaf while wearing an Apple Vision Pro is not a primary V1 scenario.
Every mushaf capture, finding and regression test stays as evidence and as a regression
guard — delete none of them — but **no signal or gate is added solely to defeat a mushaf
grip.** Add a signal only if the same failure also appears in realistic application use. A
palms-inward mushaf that defeats the recognizer while nothing in normal use does is a
documented limitation, not a work item.

Acceptance is decided by postures that occur while wearing the headset and using the app:
system pinch interaction first, then the face wipe, lap rest, headset adjust,
conversational hand movement, and takbir.

#### The margin M

Tuning stops when no assignment of the five enter bounds separates true postures from
confusers **with margin ≥ M on every gate doing separating work**. M is per gate, in that
gate's own units — a single scalar would be comparing dot products to metres.

| gate | M |
| --- | --- |
| inward | 0.09 |
| towardHead | 0.06 |
| extension | 0.10 |
| belowHeadY | 0.02 m |
| separation | 0.02 m |

Derived as the p95 excursion of each scalar across a sliding 1.5s window (the commit
window) within device-confirmed held segments of `dua-capture-2026-09-03T20-53-24Z`. The
commit window is the right window because a value that passes at its start must still pass
1.5s later. **M rises with evidence and never falls.**

**KNOWN DOWNWARD BIAS — these numbers are too small and are expected to grow.** Held
segments are by construction spans where the gates did not break, so measuring drift inside
them conditions on the pose not having drifted out: holds that wandered were truncated or
never became held segments at all. This is likely part of why the earlier capture's
excursions are 3–7× larger, not only the end-of-hold lowering artifact. The bias does not
invalidate the derivation and "never falls" absorbs it — but **an increase after the next
session is the expected outcome, not a surprise or a regression.**

**M is measured on true positives and applied to confusers, which are two different
variances.** On the true side, margin must exceed within-hold drift — that is what was
measured. On the confuser side it must exceed variation *between instances* of that
confuser, which no capture measures, since each is one person doing the posture a few
times. The proxy is acceptable for now. It is derived for true-positive margin and
**assumed** for confuser rejection.

#### The search objective is asymmetric

A false trigger is worse than a miss, and not only as UX: recitation beginning unbidden
while someone is reading is a discourtesy. The search is lexicographic:

1. **Zero confuser commits.** A hard constraint, not a weighted term.
2. Maximise the minimum margin on confuser rejection.
3. Maximise the count of genuine duas that commit.
4. Maximise true-positive margin.

Never trade a false positive for a true positive, at any margin.

**One capture is held out structurally.** The pinch capture — the most realistic confuser —
is excluded from the search entirely by the harness, not by anyone remembering to exclude
it. The vector is chosen without it and evaluated against it once. A chosen vector that
fails on held-out data is information unobtainable any other way at this sample size.

#### Release is evaluated separately, by inspection

The search optimises **enter** bounds only. The face-wipe failure is an **exit** bound
problem, and it is a timing question rather than a classification one — "how long after the
prayer ends does recitation stop", not "does this posture classify". Folding it into the
same objective would mean optimising two different kinds of quantity against each other.

So the harness **reports** rather than optimises release: for every hold in a capture, the
frame and gate at which release occurred, and the latency from a labelled end-of-intent
marker. Exit bounds are changed only by an argument made against that report, never by the
search.

**Acceptance criterion, confirmed: recitation must stop within 1.0s of the hands beginning
to leave the dua posture.** Measured to the *audio consequence*, not to the state
transition. What matters is how long recitation continues past the point the wearer stopped
praying, so any lag between `.released` and playback actually stopping is **inside** the
1.0s, not outside it. If playback stops instantly on release the two numbers are identical
and nothing is lost by specifying it this way; if it does not, the specification is already
correct and no one has to notice the gap later.

**`towardHead` is now doing two jobs.** Six of the seven releases across both captures fire
on it — the same bound the entry analysis flagged as costing detections while buying nothing
against confusers. It is load-bearing for *release* even while looking useless at *entry*.
Nothing changes today. But if a later capture argues for relaxing it, **check the effect on
release latency as well as on detection before touching it** — a looser exit bound is
exactly what would make recitation run past the end of the prayer.

#### V1 LIMITATION — every frame of tracking data is one person's hands

Dua posture varies between people: palms flat or cupped, chest height or face height,
fingers together or splayed. Thresholds tuned against five instances of one person's dua
may reject someone else's genuine posture, and no capture we have can detect that.

We are not collecting users at eight weeks out, so the purpose of recording this is that it
**caps how much tuning is worth doing.** Effort spent shaving margins to make a marginal
case pass will not generalise to a second person. **This is an argument for stopping
earlier, not for tuning harder.**

#### Contingency, decided in advance

If the dua gesture cannot be made reliable enough, **V1 starts the recitation from an
explicit affordance — gaze plus pinch on a start control — and the dua gesture is demoted
to an optional additional trigger, enabled only if it clears the margin criterion.**

Not a longer commit window: that only helps if confusers are transient, and does nothing
for a posture genuinely inside the true class's region. Not dwell-plus-confirm either: a
gesture that needs confirming is a button with extra steps, and it costs the directness
that made the gesture worth having. The ship date is fixed, the shader dissolve and Core
Text pipeline are V1's actual identity, and an unreliable gesture that sometimes starts the
surah on its own is worse than a control the user chooses to press. This is scope cut and
said out loud rather than the critical path quietly widening.

**Design note for whenever that is built:** if V1 ships a gaze-plus-pinch start control and
the primary confuser is pinch interaction, **the recognizer must be suppressed while that
control is live.** Otherwise a user pressing start has their hands up in exactly the posture
that might also drive the gesture path.

The confuser at 9.62–13.29s in capture `7282757` is a **phone**, not a mushaf. Earlier
notes calling it a mushaf are wrong.

## Environment asset — QuranSpatial_Environment.usdz

Measured on device 2026-09-14. Loaded as an Entity, added exactly as it arrives; nothing
decimated, merged, stripped or re-rooted.

### Ship the .usdz, never the .usdc + textures/ pair

**This project's `Resources` is a file-system-synchronized group and it FLATTENS into the
bundle root.** Verified: `Resources/Environment/night_pavilion.usdc` shipped as
`night_pavilion.usdc`, with no `Environment/` directory in the bundle at all.

The `.usdc` references its 21 maps as `./textures/<name>.png`. Flattened, not one of those
paths resolves — and **it does not error.** RealityKit loads the geometry and renders it
untextured, so the failure presents as an art problem rather than a packaging one. The
`.usdz` carries every map inside a single file: no path to resolve, nothing for the bundle
layout to break, and it is not larger (20.67 MB against 6.86 + 13.8).

### The root IS identity — the geometry is authored true Y-up

**REVERSED 2026-09-16 by `QuranSpatial_Environment_Corrected.usdz`. The previous note said
the opposite and is now wrong in both directions.**

It used to say the Z-up→Y-up conversion sat on `Environment_Root` and must never be
normalised to identity. In the corrected asset **the root transform IS identity** — verified
as an exact 4×4 identity matrix, not "close to" — and the geometry is authored true Y-up.
There is no conversion rotation anywhere to preserve, and nothing to avoid zeroing.

The old warning is kept here only so that anyone who read it before this date knows it was
superseded rather than forgotten. **Do not carry it forward to a new asset without
re-measuring** — it was true of the previous export and false of this one, which is exactly
how a note like this becomes a trap.

**The orientation TEST is unchanged and still the right one.** Do not read the quaternion;
read the geometry. The `Platform` is 10.9 m across and 0.365 m thick, so **it must be
thinnest in Y**. Measured: extents (10.900, 0.365, 10.900), thinnest in Y, deck horizontal.

### CLOSED — deck top is now exactly y = 0.000

The 1.445 m clearance item is closed. `Platform` bounds are
min(−5.4500, **−0.3650**, −5.4500) max(5.4500, **0.0000**, 5.4500): the deck's top surface
is exactly 0, so the 1.450 m text baseline gives a **full 1.450 m of clearance** above the
deck. No 5 mm discrepancy remains and nothing compensates for one.

### RealityKit EXPANDS the USD instancing

208 mesh instances authored from 10 prototypes arrive as **208 separate mesh-carrying
entities, 464 entities total, and 241 draw submissions** — higher than the instance count,
because meshes carrying multiple material parts submit once per part. **No
`MeshInstancesComponent` anywhere.** The authored instancing buys nothing at runtime; plan
against 241, not 208. Triangles arrive exact: **254,872**.

### Lighting is authored in SWIFT, and the import behaviour below is why

**The corrected asset ships ZERO lights, by design.** Lighting lives in
`EnvironmentLighting.swift` — one file, named constants, nothing scattered.

That is not a preference; USD-authored lighting could not have survived import. Measured on
device against the previous export, which did carry a rig of 10:

| authored in USD | arrived in RealityKit |
| --- | --- |
| `Moon_Key` DistantLight, intensity 0.1875, colour (0.37, 0.53, 1.00) | **entity present, light component ABSENT** |
| 8 × `Lantern_Pool_*` SphereLight, intensity 35.01, colour (1.00, 0.45, 0.14) | SpotLight |
| `Ceiling_Lantern_Warm` SphereLight, intensity 82.76, warm | SpotLight |

All nine survivors arrived **identical**: `SpotLight`, intensity 6740.94, inner 90° / outer
90°, attenuation 10 m, colour **(1.000, 1.000, 1.000)**. Three losses, none of which a count
would reveal — the key light entirely, all colour, and the authored intensity ratio (the
ceiling lantern was 2.36× the pools). Confirmed on device, so it is not a macOS artefact.

**Lantern positions are READ FROM THE LOADED HIERARCHY, never hardcoded.** The asset names
them `Lantern_01`…`Lantern_08` and `Lantern_Ceiling`; if the art moves a lantern, the light
moves with it.

### Texture residency must be sampled IN A RENDERING SCENE

Sampled at launch with the entity unparented and nothing drawing, residency oscillated
**3 → 4 → 3 → 27 → 3 textures within 1.6 s** and then held at 3. A naive "wait for it to
stop changing" plateau check *passes* on that — and reports an idle state as if it were the
working set.

Sample while the entity is in the scene and rendering. `EnvironmentCapture` does this at the
end of its 30 s phase A for that reason.

## Working style

- Ask before large refactors. Prefer the smallest change that solves the stated problem.
- When a spec is ambiguous, ask rather than guessing — a wrong guess here costs a device
  build cycle.
- Arabic text in source, comments, and commits is fine and expected. Don't transliterate
  it or strip it.
- This is Quranic content. Text accuracy is not a place for approximation, and text
  handling must never mutate, truncate, or reorder the source text as a side effect of a
  visual effect.
  
### Licences — status by asset

| asset | status |
| --- | --- |
| Quran text (Tanzil, Uthmani v1.1) | **satisfied**, see below |
| Recitation audio | **UNRESOLVED — open ship blocker** |
| **Amiri Quran 1.003 — the ship font** | **satisfied**, SIL OFL 1.1, committed with `OFL.txt` |
| ~~KFGQPC Uthmanic Hafs~~ | **no longer shipped**, replaced 2026-09-04 |

#### Recitation audio — unresolved, ship blocker

Identified from the file's own ID3 tags, not from any external claim:

- **Reciter: Qari Ismail Nouri.**
- **Publisher/channel: “Garden of Verses”** (`TPE1` and `TOPE`).
- Title: “Surah Ar Rahman (سورة الرحمن) | Calm & Peaceful Quran Recitation for Deep Sleep |
  Qari Ismail Nouri”.
- `TDRC` 2026, `TCON` “Music”, `TSSE` `Lavf60.16.100` — re-encoded with FFmpeg, consistent
  with our own deduplication pass rather than being an original master.
- **No licence, terms, distributor or source URL are stated anywhere in the file.**

The title pattern is characteristic of a video-platform upload. **A recitation is a
copyrighted performance separate from the text**, and the text being freely licensed says
nothing about the recording. As it stands we have an unlicensed third-party performance
embedded in the app.

**This is an open ship blocker.** Not resolved here and the audio has not been swapped —
both were explicitly out of scope. Resolving it means either obtaining written permission
from the rights holder, or replacing the recording with one whose terms permit
distribution.

### Ship font — Amiri Quran (decided 2026-09-04)

**Amiri Quran 1.003 is the ship font.** SIL Open Font License 1.1, Copyright 2010–2022 The
Amiri Project Authors, from `github.com/aliftype/amiri`.

Unlike the font it replaced, **it is committed to the repo** — `QuranSpatial/Fonts/` is
deliberately no longer gitignored, and `OFL.txt` ships beside the font and is bundled into
the app. `CreditsView` names the font, its copyright, a live link to the project, the OFL
and a link to `openfontlicense.org`.

**Amiri declares no Reserved Font Name.** Its copyright statement names none, so the OFL's
RFN clause does not bite. The constraints that do apply: the font may not be sold on its
own, and any modified version must remain under the OFL. **We ship it unmodified** — do not
subset, re-export or rename it, which would forfeit that and repeat the KFGQPC provenance
problem in reverse.

**Why the font changed: KFGQPC v2.2 cannot attach U+06DF under any encoding.** It
classifies the rounded zero as a GDEF class-1 base glyph with a 0.704em advance, carries no
`MarkBasePos`/`MarkMarkPos` rule for it, and no GSUB rule reaches an attaching variant — so
the silent-letter zero rendered as an inline dotted circle in ayat 8, 9 and 33. No corpus
and no encoding changes that; the rule does not exist in the file. Amiri gives the same
glyph GDEF class 3, zero `hmtx` advance and `mark` lookups, and renders it above the alif.

**FORBIDDEN: substituting U+06E0 for U+06DF.** KFGQPC *does* attach the rectangular zero
(U+06E0), and it would have made the dotted circle go away. **It is a different sign.** The
rounded zero marks a letter silent in both continuation and pause; the rectangular zero
marks one pronounced at a stop. Swapping them changes the recitation notation — that is a
change to the meaning of the text, not a rendering fix, and it must never be done. This is
the one "fix" that looks cheapest and is categorically off the table.

Verified on the swap, all measured rather than assumed:

- **All five U+06DF occurrences** (ayat 8, 9, 33) no longer lay out as spacing letters —
  0.084em against KFGQPC's 0.704em. `hmtx` is zero; the residue is a mark-positioning
  artefact of `CTRunGetAdvances`, which is why the test asserts a threshold rather than
  equality.
- **No mark regressed.** All 16 corpus marks compared table-by-table across both fonts:
  eleven attaching marks unchanged, U+06DF fixed, and U+06E5/U+06E6 spacing in both — which
  two independent Quranic fonts agreeing confirms is intended, not breakage.
- **No segment emits a dotted circle**, asserted corpus-wide on rendered glyphs.
- **The corpus is byte-identical.** Nothing about the font swap touched the text.

Layout shifted as expected — Amiri's line box is 2.449em against KFGQPC's 1.758em, so
planes are taller: 0.278m for one line (was 0.222m), 0.679m for three (was 0.511m). **Two
ayat gained a line, 37 and 39**, both of which had been sitting just under the cap at 39.65°
and 39.81°. Nothing exceeds 40°; the widest is now ayah 35 at 39.24°. Line counts: 69 on
one line, 9 on two, 1 on three.

The KFGQPC file is **out of the build** — moved to `scratch/fonts/`, which is gitignored —
so no licensing-unresolved font is embedded any more. It is kept only because the shaping
investigation's tooling references it.

### Quranic text — provenance and normalization

The surah text is **verbatim from the Tanzil Project's published Uthmani edition**, fetched
and never written here. `Resources/ar-rahman-text.json` records source, exact URL, the
source file's SHA-256, and the licence notice, which the source's terms require to travel
with the text.

- Source: Tanzil Quran Text (Uthmani, Version 1.1), Creative Commons Attribution 3.0.
- Fetched as the **XML** output, because the plain-text output prepends the bismillah to
  ayah 1 while the XML carries it as a separate `bismillah` attribute. Splitting a combined
  string ourselves would have been editing the text, which the licence forbids and which
  this project forbids anyway. **If a source form needs editing to fit our shape, fetch a
  different form — do not edit it.**
- **Never generate, transcribe, reconstruct or hand-correct Quranic text.** If an
  authoritative source cannot be reached, stop and say so. This includes tests: hand-typed
  Arabic will not match the source's byte representation and will fail the integrity checks
  it was meant to support.

#### Attribution — what the terms require and how we satisfy it

Re-verified against `tanzil.net/download/` on **2026-09-04**. The terms, verbatim:

> Permission is granted to copy and distribute verbatim copies of the Quran text provided
> here, but changing the text is not allowed. The text can be used in any website or
> application, provided that its source (Tanzil Project) is clearly indicated, and a link
> is made to tanzil.net to enable users to keep track of changes.

The downloaded file adds: *“This copyright notice shall be included in all verbatim copies
of the text.”*

| requirement | how it is satisfied |
| --- | --- |
| verbatim, unchanged | text is never normalized, edited or reordered; byte-level tests enforce it |
| source clearly indicated | `CreditsView` names the Tanzil Project as the Quran text source |
| link to tanzil.net | `CreditsView` carries a live `Link` to `https://tanzil.net/` |
| copyright notice travels with copies | reproduced in `ar-rahman-text.json` **and** rendered in `CreditsView` |

**Attribution in JSON alone is not sufficient** — the wearer must be able to reach it, which
is why `CreditsView` exists and is linked from the main window. **Never alter Quran text to
make attribution or integration easier.**

**The text is in NO standard Unicode normalization form**, and this is load-bearing.
Applying NFC or NFD **reorders its combining marks** — shadda (ccc 33) and fatha (ccc 30)
swap — and changes the surah's length from 3510 scalars to 3469 (NFC) or 3576 (NFD). So:

- Never normalize it, anywhere, for any reason.
- **Never compare it with `==`.** Swift's `String` equality is canonical-equivalence based
  and reports a reordered copy as equal to the original — it cannot see the exact failure
  this text is vulnerable to. Use `isByteIdentical(_:_:)`, which compares UTF-8 bytes.
  `textIsNotNormalizedAndMustNotBe` asserts both halves of this.

### Font resolution

Resolve the Arabic font via `CTFontCreateForString` from a system base font. Never
request a font by PostScript name — a wrong name falls back silently to a
non-Arabic font (verified: "SFArabic-Regular" resolves to Helvetica, no error).
Tests must assert the resolved font has a glyph for U+0670 (superscript alef).

**Core Text degrades silently rather than erroring. That is now two verified instances
on this project, and it should be the default assumption about this API, not a
surprise each time.**

1. A wrong PostScript name resolves to a non-Arabic font, no error.
2. `.useOpticalBounds` on `CTLineGetBoundsWithOptions` is a **no-op** for both fonts in
   play. Verified by reading the files directly: neither Geeza Pro nor KFGQPC Uthmanic
   Hafs ships an `opbd` table, so the option silently returns the typographic box. The
   returned box is *not* ink-tight — measured against the rendered alpha channel, actual
   ink sits about 11px inside the padding on each side, and far inside it vertically.

Do not treat a value from either API as evidence of what was actually rendered. Ink
extents are measured by scanning the rasterized alpha channel; the bounds APIs are the
thing under test, so they cannot also be the evidence.

### DEFECT — horizontal bounds underestimate ink for overhanging marks

**This is a defect, not an observation, and the "not ink-tight" note above understates
it.** There the box was merely *loose*. Here it is **smaller than the ink**, so glyphs are
clipped.

Wide marks legitimately overhang the base letter's advance width — that is ordinary Arabic
typography, not a font defect. `CTLineGetBoundsWithOptions` does not account for the
overhang, so the rasterizer sizes the bitmap too narrow and the mark is cut off at the
edge. Measured on device: ب + sukun + U+06D6 rendered with ink touching column 0.

Worst measured overhang, from the glyph bounding boxes:

| mark | overhang |
| --- | --- |
| U+06DC small high seen | **0.265 em to the left** |
| U+06D6 waqf ligature (صلے) | 0.324 em right of a 6.59/100 em advance |

Both appear throughout printed mushafs, so this will happen in real text — it is not an
artifact of synthetic probes.

**Current mitigation is a stopgap:** `ArabicTextRasterizer`'s `padding` default is 96,
chosen to clear 0.265em at the font size a short ayah solves to at the current target
width, with about 20% headroom. It does not scale with font size, so a large enough render
clips again. The real fix is bounds that account for ink, and it belongs to the corpus
pass below.

#### DEFECT — three marks render as spacing glyphs, not attached marks  
**[PARTIALLY SUPERSEDED 2026-09-04 by the shaping investigation below. The U+06DF half stands; the U+06E5 and U+06E6 half does not — two independent fonts agree those two are spacing glyphs by design. Scope narrows from 9 occurrences across 7 ayat to 5 occurrences across 3.]**

**A third, separate defect. Not the per-ayah size defect, not the hhea/fixed-box corpus
issue.** Scanned 2026-09-04 over all 78 ayat plus the bismillah — 3510 scalars, 54
distinct.

**Glyph coverage is complete.** Every scalar in the corpus returns a non-zero glyph from
`CTFontGetGlyphsForCharacters` in `kfgqpchafsuthmanicscript-Reg`. No run in any ayah falls
back to another font. Nothing is missing.

The failure is *positioning*. Every true combining mark in the corpus has a zero advance
and attaches correctly. **Three marks have a real advance width and lay out as spacing
glyphs beside the base instead of attaching above it:**

| mark | advance (em) | occurrences | ayat |
| --- | --- | --- | --- |
| U+06DF ARABIC SMALL HIGH ROUNDED ZERO | **0.70** | 5 | **8, 9, 33** |
| U+06E5 ARABIC SMALL WAW | 0.31 | 1 | **29** |
| U+06E6 ARABIC SMALL YEH | 0.35 | 3 | **39, 43, 46** |

Nine occurrences across seven ayat. For contrast, U+064B–U+0654, U+0670, U+06E2 and U+06ED
all have zero or near-zero advance and render correctly.

**U+06DF additionally renders as a dotted circle.** The font's own glyph 249 is the
*isolated presentation form* — the mark drawn on a dotted-circle placeholder — and it is
emitted inline at 0.70em. Verified on both alif and waw bases.

**It is NOT U+25CC.** The scan initially reported no dotted circles because it searched for
U+25CC's glyph id; that was the wrong test and the conclusion was wrong. U+25CC exists in
the font as glyph 12 and is never emitted. The dotted circle on screen is the ship font
drawing its own U+06DF glyph. Any future check must look at what is drawn, not at whether a
particular codepoint appears.

**The repair is the ship font, and only the ship font.** A face whose GPOS attaches these
marks — a different KFGQPC release, or Amiri Quran, which is already the licensing
fallback. **Never edit, substitute or strip the text to avoid the marks**, and do not add
fallback fonts or per-glyph substitution logic to paper over it: that hides a font problem
inside the rendering path where the next person cannot see it.

This raises the stakes on the unresolved KFGQPC licence — the current ship font is both
unlicensed and incorrect for seven ayat of the surah.

#### INVESTIGATION — Quranic mark shaping, 2026-09-04

Investigation only; nothing was implemented. Amiri Quran was downloaded for comparison
rendering and is **not** in the app.

**Bundled font provenance.** `QuranSpatial/Fonts/UthmanicHafs.ttf`, 297,688 bytes, SHA-256
`a6e59510dcaf3ec99db49427321a035ed94af555ffc7d27e7f430b5fd5e179f8`. Never committed
(gitignored), so git carries no provenance and the download origin is unrecoverable from
the repo. The file itself identifies as **KFGQPC HAFS Uthmanic Script, Version 2.2**,
manufacturer/designer King Fahd Glorious Quran Printing Complex, vendor ID `KFQP`, vendor
URL `fonts.qurancomplex.gov.sa`, unique ID naming Ashfaq Ahmad Niazi and the year 2021.
It is the Quranic Hafs family, not a general-purpose KFGQPC Arabic face.

**It appears authentic, not a re-export or subset.** 18 tables including `DSIG`, `GDEF`,
`GPOS`, `GSUB`, `kern`; nothing shaping-relevant missing; 1572 glyphs; 21 GPOS lookups with
rich mark attachment. A stripped re-export loses positioning tables — this file has them
and uses them.

**The finding: KFGQPC deliberately classifies U+06DF as a BASE glyph, not a mark.**

| glyph | hmtx advance (2048/em) | GDEF class | in any mark coverage? |
| --- | --- | --- | --- |
| U+06DF small high rounded zero | **1442 (0.704em)** | **1 = base** | **no** |
| U+06E5 small waw | 645 | 1 = base | no |
| U+06E6 small yeh | 707 | 1 = base | no |
| U+0651 shadda | 0 | 3 = mark | yes, lookups 5–16 `mark` |
| U+0670 superscript alef | 0 | 3 = mark | yes |
| U+06E2 small high meem | 4 | 3 = mark | yes, incl. `mkmk` |

No `MarkBasePos`, `MarkMarkPos` or `MarkLigPos` lookup lists U+06DF, U+06E5 or U+06E6 as a
mark. No GSUB lookup substitutes them for attaching variants. This is a coherent design
decision in the font, not damage: a stripped table would lose the classes entirely rather
than assign these three `class=1` with deliberate advances.

**Control test — same verbatim Tanzil text, Amiri Quran 1.003 (SIL OFL), same pipeline:**

- **U+06DF: Amiri has advance 0, GDEF class 3, and attaches it via `mark` lookups 19/22.
  It renders correctly above the alif.** KFGQPC renders the isolated dotted-circle
  presentation form inline at 0.704em.
- **U+06E5 and U+06E6: Amiri also gives them non-zero advances and GDEF class 1, with no
  attachment.** Two independent expert Quranic fonts agreeing is strong evidence this is
  intended orthographic behaviour for the small waw and small yeh, **not a defect**.

**Conclusion: H3, a genuine family limitation of authentic KFGQPC v2.2, for U+06DF only.**
H4 (pipeline not activating features) is dead — the `mark` feature is demonstrably applied,
since shadda, superscript alef and small high meem attach correctly in the same runs.
H1 (text/font pairing) is dead for this sign: no text representation using U+06DF can
attach when the font contains no rule for it, and Tanzil's representation attaches fine in
Amiri. H2 (damaged file) is contradicted by the table inventory.

**Step 3 was not run.** Its precondition was Step 1 finding attachment rules present and
Step 2 showing Tanzil failing under Amiri. Neither holds, so no official KFGQPC corpus was
sought and our corpus was not touched.

**The Tanzil text is not at fault and must not be changed.** Its U+06DF is the correct
scalar, renders correctly under a font that attaches it, and switching corpus would not fix
KFGQPC because the rule does not exist in the font at all.

#### FOLLOW-UP — does KFGQPC expect a different encoding for the silent-letter zero?

Answered from inside the bundled file, no downloads. **This refines the entry above; it does
not overturn it.**

**Yes — but for a different sign, which makes it useless as a fix.**

`U+06E0` ARABIC SMALL HIGH UPRIGHT RECTANGULAR ZERO **is** mapped, to glyph 250
`uni06E0`, **GDEF class 3, advance 0**, and it **attaches correctly above the alif**.
So the font does contain an attaching small-zero mark — reachable from a different scalar.

**But U+06E0 is not an alternative encoding of U+06DF. It is a different notation.** The
rounded zero marks a letter silent in both continuation and pause; the rectangular zero
marks one silent in continuation but pronounced at a stop. Encoding one as the other would
change the recitation notation, which is a change to the meaning of the text, not a
rendering fix. **It must not be done.**

For the rounded zero specifically the answer is **B**: no attaching rounded-zero glyph
exists anywhere in the font.

- No glyph name references `06DF` other than `uni06DF` itself — no `.calt`, `.alt` or
  positional variant.
- `uni06DF` appears in **no GSUB lookup at all**, as input or output. No feature, script or
  langsys reaches it. GSUB and GPOS both declare only `arab`/`dflt`.
- No GSUB rule outputs `uni06E0`, `uni06EA`, `uni06E1` or `up` either — the attaching
  circle-like marks are reachable only by their own codepoints.
- Every unmapped class-3 glyph was inspected: they are mark ligatures
  (`afii57457_afii57454` and similar), `.calt` variants of the waqf signs U+06D6–U+06DB, and
  the `k130`–`k140` dots and strokes. **None is a rounded zero.**

**The asymmetry is the finding: KFGQPC v2.2 attaches the rectangular zero and not the
rounded one.** Sitting beside it in the same font, U+06DD, U+06DE, U+06E3, U+06E4, U+06E5,
U+06E6, U+06E9 and U+06EB are *also* class 1 with large advances — a whole family of signs
this font treats as spacing bases. That is consistent with KFGQPC positioning them through
its own typesetting system rather than through OpenType shaping. **We cannot reach that
behaviour through Core Text, and no encoding available to us changes it.**

So the matched-text-and-font hypothesis is dead on the shaping evidence alone: a matched
corpus cannot supply a rule the font does not contain.

#### KFGQPC mushaf TEXT redistribution — unverified, and likely restrictive

Recorded from general knowledge, **not verified this run** — the follow-up excluded
downloads, so this is explicitly weaker evidence than everything above it and must be
checked before being relied on. The King Fahd Complex publishes its mushaf text through
qurancomplex.gov.sa under terms substantially more restrictive than Tanzil's: the Complex
reserves rights over its texts, prohibits modification, and has historically required prior
permission for redistribution rather than offering an open licence. The font EULA we read
grants use, copy and distribute for the *font*; **the text is governed separately and no
comparable grant is known to exist.** If that holds, the matched-pair route is closed on
licensing regardless of shaping — and since the shaping evidence already closes it, the two
findings agree. Verify directly before treating either as settled.

#### KFGQPC licence — the file carries its own grant

Read from the font's own `name` ID 13, which had not been read before:

> Permission is hereby granted, **Free of Cost**, to any person obtaining a copy of this
> Font accompanying this license, the rights to **Use, Copy, Distribute**, subject to the
> following conditions: 1. The Font Software cannot be **Sold, Modified, Altered,
> Translated, Reverse Engineered, Decompiled, Disassembled, Reproduced** …

This is **more permissive than the "enquiry sent, not approved" status recorded above**,
which assumed no grant existed. It appears to permit embedding a verbatim, unmodified copy
at no cost. It also contains internal tension — "Copy, Distribute" granted while
"Reproduced" is prohibited — and **that is a legal reading, not an engineering one.**
Recorded as a finding; **the licence status is NOT hereby declared resolved.** No
`LicenseURL` is present in the file.

The font **is currently embedded in every build**, at the bundle root as
`<App>/UthmanicHafs.ttf`.

#### RESOLVED 2026-09-04 — text size is no longer a function of string length
**[The defect below is FIXED. Kept in place because the mechanism it describes is why the
current design is shaped the way it is. Superseded by "Fixed size and wrapping" beneath
it.]**

#### DEFECT — text size is a function of string length

**Kept as-is for the 78-ayah milestone, deliberately, so all 78 run on device.** Its repair
is a separate pass. **Note the font dependency: any line-break tuning done against the
pipeline-proving font will need redoing against the ship font**, because break positions
are font-metric dependent and KFGQPC's metrics differ substantially from Geeza Pro's.


**Separate item from the corpus fixed-box pass. Do not merge them; the fixes do not
overlap.** The corpus pass is about vertical dead space from the font's `hhea` descent.
This is horizontal and different in kind: the rasterizer solves font size to fill a target
pixel **width**, so a long ayah renders smaller than a short one. Fixing box height does
not touch it.

Across 78 ayat this will be obvious — the refrain is short and will be large, and one
segment runs 34.43s against a 7.68s median, so its text will be small enough to notice. For
scripture, uniform size is not a nicety: text that shrinks as the ayah lengthens reads as
broken.

**Length pushes size DOWN and width UP at the same time.** Measured across all 79
segments on device geometry:

- `targetPixelWidth` is pinned at ~894 for every ayah, so texture *width* never varies.
- Texture *height* is `ascent + descent + 2 * padding`, which shrinks with the solved font
  size.
- Plane width is derived as `physicalPlaneHeightMeters * (texW / texH)` = `0.37 * (894/texH)`.

So a longer ayah gets a smaller font, a shorter texture, and therefore a **wider plane**.
The two effects compound: the text gets smaller *and* the panel it sits on gets wider.

| ayah | font size | texture | plane width | angular width at 1.5m |
| --- | --- | --- | --- | --- |
| 1 (shortest) | 296.31 | 894×713 | 0.464m | 17.6° |
| refrain (×31) | 89.79 | 895×350 | 0.946m | 35.0° |
| 9 | 50.44 | 895×281 | 1.178m | 42.9° |
| 54 | 41.54 | 894×266 | 1.244m | 45.0° |
| **33 (worst)** | **21.65** | **895×231** | **1.434m** | **51.1°** |

**69 of 79 segments exceed 30°; ayat 33 and 54 exceed 45°.** Ayah 33's plane is nearly four
times wider than it is tall. The geometry also assumes the viewer is at the world origin —
the plane is fixed, not billboarded — so standing nearer than the assumed 1.5m widens it
sharply: ayah 9 goes from 42.9° at 1.5m to 61° at 1.0m.

**The intended fix inverts this: pin the angular width, let height vary, and wrap long ayat
across lines.** Not a tweak to the current solve — the current solve derives width from
height, which is exactly backwards for a fixed reading panel.

Accepted as-is for milestone one, deliberately — seeing all 78 go past is what will tell us
how bad it is.

#### Fixed size and wrapping — the current design

Font size is no longer solved from a target width. **One size for the whole surah, one
bounded width, and length spends itself on line count.**

| knob | value | what it controls |
| --- | --- | --- |
| `textEmDegrees` | 3.0° | **the readability knob.** Em size in visual angle, constant across all 79 segments |
| `maxAngularWidthDegrees` | 40° | the only thing bounding width; text wraps rather than exceed it |
| `paddingPixels` | 48 | mark overhang margin — fixed now that the font size is fixed (0.265em ≈ 27px at this em) |
| `metresPerPixel` | derived | **one** scale from raster pixels to world metres, so a glyph is the same physical size in every ayah |

Measured across all 79 segments: **71 render on one line, 7 on two, 1 on three (ayah 33).
Nothing exceeds 40° — the widest is ayah 39 at 39.81°.** Angular width now ranges
10.34°–39.81° and tracks how much text there is, not how small it had to be shrunk. All 31
refrains are byte-identical and now render identically: 894×276px, 0.718m, 26.91°.

**Line count is never capped and the font is never shrunk to force one.** An ayah takes the
lines it takes.

**Wrapping is rendering-only.** Core Text breaks at existing whitespace. **Nothing is
inserted into the text — no line break, ZWJ, ZWNJ or any other character** — and
`rasterizingDoesNotMutateTheText` asserts the corpus is byte-identical before and after
rasterizing every ayah.

**The plane is TOP-ANCHORED on the first line's baseline** (changed from centre-anchoring
on 2026-09-04). `AyahPlaneGeometry.firstLineBaselineHeightMeters` = 1.45m, and every segment
puts its first baseline exactly there regardless of line count — measured across all 79, a
single distinct value. Extra wrapped lines extend downward only; the first line never rises
to centre the block.

Anchoring is on the **baseline**, not the plane's top edge, because mark height can vary the
ascent between ayat and a fixed top edge would let baselines drift by exactly that variation.
**Worth knowing: with Amiri and this corpus it makes no observable difference** — Core Text's
typographic ascent is a font constant rather than per-line ink, so the plane top lands at
1.637m for every segment anyway. The baseline anchoring is still the correct thing to depend
on; it just is not currently doing work a top-edge anchor would fail at.

1.45m was chosen to sit within 2cm of where one-line ayat already sat under centring, so the
change is not also a reposition.

Placement, measured across all 79 segments (viewer assumed at the origin, plane at 1.5m):

| | 1 line (69) | 2 lines (9) | 3 lines (1: ayah 33) |
| --- | --- | --- | --- |
| plane height | 0.278m | 0.479m | 0.679m |
| first baseline Y | **1.450m** | **1.450m** | **1.450m** |
| plane top Y | 1.637m | 1.637m | 1.637m |
| plane bottom Y | 1.360m | 1.159m | 0.958m |
| last baseline Y | 1.450m | 1.249m | 1.049m |

**Ayah 33 is the worst case and it is comfortable, not uncomfortable.** Its last line's
baseline sits at 1.049m — **16.7° below horizontal** for a standing wearer with eyes at 1.5m,
and the plane's bottom edge at 0.958m is 19.9° below. Ergonomic guidance puts relaxed
downward gaze at 15–20°, so the deepest line of the longest ayah in the surah lands inside
that band rather than past it. Seated, with eyes nearer 1.2m, it is 5.7° below and the first
line is 9.5° above.

For comparison, centre-anchoring put ayah 33's last baseline at 1.251m but its first at
1.652m — the top-anchored layout trades 20cm of depth on the last line for a first line that
never moves. That is the right trade for reading: the eye starts every ayah in the same place.

#### Measured raster and ink, per ayah (2026-09-06)

Measured by compiling the real `ArabicTextRasterizer` into a macOS tool with the shipped
`AmiriQuran.ttf` at the real constants — 102px em, 1264px content width, 48px padding — and
counting pixels with alpha ≥ 128. Not estimated from plane heights.

| ayah | raster | lines | ink px | mean horizontal stroke |
| --- | --- | --- | --- | --- |
| **33** (largest ink) | **1259 × 846** | 3 | 62,850 | 9.73 px |
| 51 (median by ink) | 878 × 346 | 1 | 16,117 | 9.72 px |
| 78 | 1229 × 346 | 1 | 21,765 | 9.45 px |
| 1 (shortest) | 308 × 346 | 1 | 4,528 | 9.32 px |

**Ayah 33 is 1259 × 846, not 1238 × 636.** The 636 height is a pre-Amiri figure — KFGQPC's
three-line box was 0.511m against Amiri's 0.679m — and it understates the ink area by about
a third. Anything sized off the old number will be undersized.

Mean stroke width is ~9.7px and, notably, is nearly constant across the corpus. That is the
number any per-pixel effect should be scaled against, not the raster area.

**OPEN QUESTION — should breaks prefer waqf positions?** Core Text currently breaks at
arbitrary whitespace. In mushaf typesetting **where a line ends carries meaning**, and the
waqf marks U+06D6–U+06DB exist precisely to mark permissible stopping points. Breaking
mid-phrase where the orthography marks no stop is a typographic error even when it is
metrically fine. Whether to bias line breaking toward waqf positions is unresolved and is
not a rendering detail — it is a question about faithfulness to the mushaf, and should be
settled with someone qualified to judge it rather than by engineering preference.

#### The two ways to recover the lost text size are NOT equivalent

Padding sits inside the anchored plane box, so raising it came straight out of the glyph
budget (`targetPixelWidth - 2 * padding`). It is a size change wearing a safety-margin
costume. **Current state: padding 96, solved font size ~301 (was ~363), ink ~41% of the
box (was ~52%) — text about 20% smaller than before.** That is a legibility annoyance
that is visible in the headset; the clipped waqf it bought was silent. Deliberately sitting
on that trade.

Two fixes exist and they are not interchangeable:

- **Raising `physicalPlaneHeightMeters` to ~0.47** scales the whole box, dead descent
  included. You pay plane size for text size. **It treats the symptom.**
- **Requesting `requiredRasterPixelWidth() + 2 * padding`** stops padding eating the glyph
  budget at all. **It fixes the cause, and it is the correct end state.**

This is written down because the constant is a one-line change and the raster-width fix is
not. Without the distinction recorded, someone reaches for the constant *because it is
cheap* — and that puts a size correction back inside a constant that names a box, which is
exactly the confusion the `physicalPlaneHeightMeters` rename was meant to prevent.

Take neither yet. Both belong with the bounds work, and the raster-width fix means touching
the width path immediately after the width path became the thing under suspicion — wrong
order.

**Test case: the Ar-Rahman refrain,** `فَبِأَىِّ ءَالَآءِ رَبِّكُمَا تُكَذِّبَانِ`, which
repeats 31 times in the surah and carries a maddah over alef — the construct that blew up
in the synthetic maddah probe (600×5568px, clipped both sides). The size-solve blowup
probably will not reproduce, since it was driven by a very short string and the refrain is
long. The overhang underestimate is orthogonal to string length and will.

**Open question — mark positioning is unverified.** Both fonts have U+0670, U+06DC,
U+0652, U+06D6, U+06E2 and U+06DA in their cmaps. That is *coverage*, and it says nothing
about whether a font places those marks correctly on a stacked cluster, which is a
positioning question. The two fonts do not even use the same shaping technology: Geeza
Pro has no `GPOS`/`GSUB`/`GDEF` at all and positions via AAT (`morx`, `kern`, `feat`),
while KFGQPC uses OpenType `GPOS`/`GSUB`/`GDEF` and no `morx`. Settling this needs a
visual comparison of a stacked cluster, not a resolution or coverage check. Do not record
it as settled until that comparison exists.

The ship font is named exactly once, as `ArabicTextRasterizer.shipFontResourceName`.
Switching to Amiri Quran is that one line plus dropping the file in. It is a *file*
name, not a PostScript name, so the font's identity is read back from the file
itself and there is no name to get wrong.

### Ship font licensing — KFGQPC Uthmanic Hafs is NOT approved

The ship font is **KFGQPC Uthmanic Hafs, for local development only.** The licensing
enquiry has been sent and **has not been approved.** Until approval comes back **in
writing**:

- **It must not be embedded in any App Store submission.** Not a TestFlight build
  destined for review, not an archive, not a "just to check the size" upload.
- It is **not in the repo** and must not be committed. `QuranSpatial/Fonts/` is
  gitignored for this reason. Each machine places its own copy at
  `QuranSpatial/Fonts/UthmanicHafs.ttf` (or `.otf` — the loader probes both).
- A build that must not carry it is made by **removing the file**. Its absence is a
  supported state: `ArabicTextRasterizer.isShipFontBundled` goes false, the rasterizer
  falls back to the system cascade, and the app still shapes Arabic correctly rather
  than rendering nothing. Verify with that property, not by eye.

If approval arrives, record it here with the date and terms before committing the font.
If it is refused, Amiri Quran is the fallback and the switch is the one constant above.

### Plane sizing and texture height

The ayah plane's height is a chosen constant, `ImmersiveView.physicalPlaneHeightMeters`.
The texture supplies only the aspect ratio needed to keep the image undistorted — never
the plane's size. **It names the box, not the text.** Ink fills 82% of it in Geeza Pro and
52% in KFGQPC, so the same value does not give two fonts the same apparent text size, and
a per-font value is correct until the fixed-box work makes the fraction exact. Plane size previously followed `pixelSize`, which coupled the plane's
shape to a font's declared metrics: KFGQPC reserves 0.586em of descent and uses about a
sixth of it, inflating the texture 44% for the same string.

**Rejected: ink-derived per-line texture height.** Per-line heights break vertical
alignment across ayat, give every ayah a different plane size, and change dissolve
behaviour per ayah because the dissolve is parameterised in UV space. If trimming happens
later it is a **fixed box per font, derived from the corpus maximum, applied uniformly** —
never per line.

**Deferred: the corpus measurement pass** that a fixed box would need. Not until the dua
gesture is proven on device.

Its scope has grown. It began as a measurement exercise to reclaim dead vertical space; it
now also carries a known horizontal defect to fix (see the bounds defect above), with a
named test case rather than a synthetic one. Same pass, more definite.

Geeza Pro was the pipeline-proving font and is not a ship candidate.
