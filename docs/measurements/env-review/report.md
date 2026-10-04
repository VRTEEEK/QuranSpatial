# Environment trial — `QuranSpatial_Review.usdz` on device

Trial closed 2026-10-03. **No swap.** The current pavilion (`QuranSpatial_Environment_Corrected.usdz`)
stays for the device tests, the measurement and the baseline tag. Everything below is for the
post-challenge stage.

Branch: `experiment/env-review` (off `stage-2` at `9cc35e8`), commits `cdcfd1a`, `d310f4b`,
`b25872f`. The `.usdz` itself (67.47 MB) was never committed; it now lives in `scratch/`
(gitignored). To revisit: check the branch out, copy the file back to
`QuranSpatial/Resources/Environment/`, build Debug. Pre-trial package inspection:
[`../environment-review-2026-10-02.md`](../environment-review-2026-10-02.md).

## Cost, measured on the device (Debug, 2026-10-02)

From `Documents/environment-load.txt` as written on first rendered frame (launch 2, glow cards
hidden); the current asset's figures from CLAUDE.md and commit `330f420`.

| | **review asset** | **current asset** |
| --- | --- | --- |
| entities in hierarchy | 22 | 464 |
| entities carrying a mesh | 15 | 208 |
| **mesh parts (draw submissions)** | **17** | **241** |
| triangles as RealityKit sees them | 147,232 (equals the pxr count exactly) | 254,872 |
| `Entity(named:)` | 1.711 s | not recorded in CLAUDE.md |
| load start → first rendered frame | 1.853 s | not recorded |
| `phys_footprint` before → after load | 56.99 → **572.38 MB, +515.39 MB** | peak ≈ 200.41 MB in scene (30 s capture) |
| textures resident at the first-frame sample | 1 distinct, 85.33 MB: the 4096² emissive, `rgba8Unorm_srgb`, **13 mips** | 3 at the idle plateau (launch artefact, CLAUDE.md) |
| decoded ceiling if all resident (from the package) | ≈ 472 MB without mips; with mips ≈ 630 MB | ≈ 84 MB |
| lights arrived from USD | 0 | 0 |
| lights the rig placed | 2: moon-key, and a stray 1400 lm point at (0, 0.45, 0) — see below | 10 |
| IBL | **not built** (`textures/night_sky_2k.png` absent) | built from 2048×1024 |
| procedural sky / dome radius | **not applied** (`Night_Sky_Dome` absent); authored 1100 m sphere with its 8k map | replaced; 2400 → 1000 m |
| stars | 1300 quads at r = 985 m, inside the 1100 m dome | at 985 m inside the 1000 m dome |

**Reading.** Draw submissions fall 14×, triangles by 42 %. Memory goes the other way: +515 MB at
load against a ≈200 MB in-scene peak today, consistent with the four 4096² atlases and the
8192×4096 sky decoded with mips. Run 2 (the 30 s in-scene capture) was not run; the in-scene
residency and peak are therefore not measured, only bounded.

## Names the code reads that the asset does not provide

All logged once as `env-review missing: <name>`; every site fell through safely, nothing crashed.
`Platform` · `Lantern_01`…`Lantern_07` · `Lantern_Ceiling` · `Night_Sky_Dome` ·
`textures/night_sky_2k.png` · `authoredTextureCount` 22 vs 11. `Review_Camera` is present at
(0, 1.65, 2.30) and was left in place. **Name collision:** the asset has a 24-triangle glow card
named `Glow/Lantern_08`, so the rig placed a rim-lantern point light at that entity's origin
(0, 0.45, 0) — an accidental light, harmless on this asset (see next section), but it is why the
audit says "2 light entities created" and "7 missing" rather than 1 and 8.

## Finding — the asset is authored entirely as EMISSIVE

Every material in the package has `diffuseColor = (0, 0, 0)` and its atlas connected to
`emissiveColor` (`Baked_Columns`, `Baked_Architecture`, `Baked_Ceiling`, `Baked_Floor`,
`Baked_Lantern_Metal`, `Polished_Marble_Ring`, `Hanging_Lantern`, `Landscape_Atlas`,
`Shore_Objects_Atlas`, `Baked_Water`, `Night_Exterior`); the two constants (`Step_Edge_Amber`,
`Lantern_Honey_Glass`) are emissive too. Consequences:

- **The unlit-baked swap (`envReviewUnlitBaked`) swapped 0 meshes** — correctly: no material has a
  base-colour texture. It was also unnecessary: emissive renders at the texture value regardless
  of lights, so the bake already shows as authored. What run 1 showed *was* the bake.
- The moon light, the missing lantern lights and the missing IBL have **no effect** on these
  surfaces (black diffuse, roughness 1). The lighting audit's "every sampled surface is black —
  scene would be black under any light" is a false alarm for this asset, by construction.
- The water (`Baked_Water`) is emissive from `water_reflection.png`, not a reflective PBR
  surface: it does not need the IBL and does not go black without it. The earlier prediction
  that it would was wrong for this asset.

## Glow cards — cause UNCONFIRMED, two hypotheses

Run 1: every lantern's glow cards rendered as flat orange rectangles (crossed planes), near and
far. Mo's screenshot shows the rectangles are **partly see-through**.

**Package** (pxr, no change made): `GlowCards_Merged` (108 faces, double-sided) →
`Lantern_Glow_Card`: `diffuseColor = (0,0,0)`; `emissiveColor ← lantern_glow.png :rgb`;
`opacity ← lantern_glow.png :a`; `opacityThreshold = 0.0` (authored). `lantern_glow.png` is
256×256 RGBA: alpha 0–31 (max 12 %), 54 % of pixels fully transparent, centre a = 31, all edges
a = 0; **RGB is the constant (255, 174, 76) at every pixel** — the shape lives only in alpha.

**Device** (`GLOW-CARDS:` line): `GlowCards_Merged[0]: PhysicallyBasedMaterial
blending=transparent(scale 1.0, opacityTexture YES) opacityThreshold=nil baseColorTexture=no
emissiveTexture=YES emissiveIntensity=1.0`. So the alpha **is in the package**, **is
connected**, and **is bound on import** as an opacity texture with transparent blending. The
failure is downstream of all three.

| hypothesis | mechanism | what it predicts | fit with the screenshot |
| --- | --- | --- | --- |
| **H1 — opacity sampled from the colour channel** | RealityKit reads the opacity map's R (255 everywhere) rather than A | fully opaque rectangles | weaker: the cards are partly see-through |
| **H2 — emission drawn regardless of opacity** | the opacity map attenuates the (black) diffuse/alpha term, but the emissive term is added unattenuated, so the constant orange shows over the whole quad at near-full strength while the quad still blends | orange rectangles that are partly see-through, strongest where alpha is lowest relative to emission | **matches** |

Not settled on the evidence here; a one-pixel probe (an `UnlitMaterial` quad with the same
texture as opacity, no emission) would separate them. **The asset fix is the same for both:
premultiply the glow colour by the alpha** in `lantern_glow.png` (RGB → RGB × A), so the
emission itself carries the soft shape and the cards fade to black, not to orange, wherever
alpha is low. `Glow/Lantern_08` and `Step_Edge_Glow` are opaque emissive constants and were
never rectangles; they were hidden only because the hide rule takes every `Glow` path.

## Other observations

- The 30.6 MB `.usdc` layer for 147k triangles points to unindexed per-vertex data from the
  bake: load-time cost, which the 1.7 s load reflects.
- The arch band is 5 cm higher and 9 cm closer than today's; the text's 25° elevation clears it
  by about the same margin (ceiling 27.2–29.5° at a 1.80 m eye against 26.7–28.6°).
- Sky dome at 1100 m with an 8192×4096 map (134 MB decoded) that no code replaces; the procedural
  sky and head-follow do not run against this asset.

## What a swap would need (post-challenge)

1. Memory: the four 4096² atlases and the 8k sky against the device budget — measured in scene,
   not bounded. This decides it.
2. Names: `Platform`, `Lantern_01-08`/`Lantern_Ceiling` (or lantern positions from the merged
   meshes), `Night_Sky_Dome`, and either `night_sky_2k.png` or code that reads the 8k map.
3. Glow cards premultiplied; `Review_Camera` removed; the stray `Lantern_08` name collision.
4. The lighting rig and the procedural sky are moot for an emissive-authored asset; decide
   whether the pavilion stays emissive (fixed look, no head-relative lighting) or returns to PBR.
