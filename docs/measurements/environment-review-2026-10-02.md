# Environment review — `QuranSpatial_Review.usdz` against the current pavilion

Inspected 2026-10-02, **inspection only**: never loaded in the app, nothing copied into
`Resources/`, `PavilionEnvironment.resourceName` unchanged, nothing committed.

**Decision (Mo, 2026-10-02): no environment swap before the baseline.** The current
`QuranSpatial_Environment_Corrected.usdz` stays for all device tests, the B5 measurement and
the `baseline-2026-10-03` tag. This record is for the post-challenge stage. The reviewed file
was moved to `scratch/` (gitignored); the stray `QuranSpatial_Review.usdc` that briefly sat in
`Resources/Environment/` must not be there for any build — `Resources` flattens into the bundle
root and would ship it, untextured and unreferenced.

## Files and tools

| | new | current |
| --- | --- | --- |
| file | `QuranSpatial_Review.usdz` (from `~/Documents/_____________---0_Quran/enviroment/version 10/`, now in `scratch/`) | `QuranSpatial/Resources/Environment/QuranSpatial_Environment_Corrected.usdz` |
| size on disk | **67,466,117 bytes (67.47 MB)**; the `.usdc` layer alone is 30.6 MB | 34,038,093 bytes (34.04 MB). CLAUDE.md's "20.67 MB" describes the earlier export, not this file |

Tools: `/usr/bin/usdchecker` (plain and `--arkit`), Blender 5.2's bundled Python 3.13 with
`pxr` (USD 0.26.3), Python `zipfile`/PNG headers for package contents. Scripts were throwaway
(scratchpad); the method is described per row so it can be re-run.

**Method validation.** Every CLAUDE.md figure for the current asset was reproduced first:
identity root, `Platform` extents (10.9, 0.365, 10.9) thinnest in Y, deck top y = 0.0000, zero
lights, 22 textures all inside the package, 208 meshes, 241 draw submissions, arch underside
y = 4.270 m. The one disagreement is the triangle count (below).

## Side by side

| | **new** | **current** |
| --- | --- | --- |
| `usdchecker` | **Success**, no errors, no warnings; `--arkit` also Success | Success |
| up axis / metersPerUnit | Y / 1.0 | Y / 1.0 |
| default prim | `/Environment_Root` | `/Environment_Root` |
| root prims | `Environment_Root` **identity**; `Materials` (untyped); **`Review_Camera`** (Camera) at (0, 1.65, 2.3), pitched 7.21° | `Environment_Root` identity; `_materials` (Scope) |
| `Platform` prim | **NONE.** The deck is `Baked_Floor`: world bounds min (−5.45, −0.365, −5.45) max (5.45, 0.000, 5.45), extents (10.9, 0.365, 10.9), thinnest in Y, **deck top y = 0.000** — same geometry under a different name | `Platform` (Xform): same bounds, deck top 0.0000 |
| lights (UsdLux, any API) | **none** | none |
| texture files in package / shader asset inputs | **11 / 12**, **0 resolving outside the package** | 22 / 27, 0 outside |
| decoded texture memory if all resident (RGBA8, no mips) | **≈472 MB** — see table below | ≈84 MB |
| prims (instances expanded) | 79, no instancing | 574, 164 instances from 11 prototypes |
| meshes | **15** | 208 |
| materials bound | 14 | 17 |
| triangles (sum of faceVertexCounts − 2, every mesh prim) | **147,232** | 343,288 by this method; CLAUDE.md records **254,872 measured at runtime**. The two methods disagree on the same file, so compare 147k with 343k, not with 254k |
| expected draw submissions (mesh instances × material parts) | **16** (`Floor_Lanterns_Merged` has 2 parts) | 241 (25 meshes with 2–3 parts) |
| arch band mesh | `Baked_Architecture`, y 4.319–8.800 m | `Pointed_Arch_Module` ×8, y 4.270–6.120 m |
| arch band underside | **y = 4.319 m**, underside radius 4.45–4.90 m | y = 4.270 m, underside radius 4.54–4.91 m |
| ceiling angle, 1.80 m eye, CLAUDE.md formula `atan((y − eye) / r)` | **29.52° at the inner edge … 27.19° at the outer edge** | 28.57° … 26.73° (CLAUDE.md's 26.99° used r = 4.85) |
| ceiling angle, 1.60 m eye | 31.44° … 29.01° | 30.48° … 28.56° |
| lowest band vertex toward −Z within ±20° azimuth, 1.80 m eye | 27.70° (y 4.319, r 4.80) | 31.70° (y 4.797, r 4.85) |
| column tops | `Baked_Columns` to y = 4.319, r ≈ 4.80 | `Column_*` to y = 4.319 |
| dome / ceiling underside | `Baked_Ceiling` 6.270–8.124 m | `Dome_Decorated_Inner_Shell` 6.270–7.300 m; `Dome_Outer_Shell` to 7.460 m |
| sky dome | `Sky/Night_Sky`, radius **1100 m**, 8192×4096 texture | `Night_Sky_Dome`, radius 2400 m, 2048×1024 texture |
| water | `Water/Lake_Surface/Water_Mesh`, zero-thickness plane at y = −0.430, ±500 m | `Water`, y −0.437…−0.423, ±500 m |
| exterior | `Exterior/Landscape_Merged` (y −1.13…59.17, r ≈ 495), `Shore_Objects_Left/Right`, `GlowCards_Merged` | terrain in the water material set; no shore objects |
| lanterns | **baked**: `Floor_Lanterns_Merged`, `Hanging_Lanterns_Merged`, `Baked_Lantern_Metal`; one 24-triangle glow card `Glow/Lantern_08` | `Lantern_01`…`Lantern_08`, `Lantern_Ceiling` as separate Xforms |

**Clearance verdict.** Essentially unchanged: the band sits 5 cm higher and its inner edge 9 cm
closer to the centre, netting a ceiling about 0.6–0.9° higher than today's by the same formula.
The text at 25° elevation is under it by the same margin; nothing here changes the Stage 8
conclusion in CLAUDE.md.

## Textures inside the new package

| file | size | PNG bytes | decoded RGBA8 |
| --- | --- | --- | --- |
| `Ceiling_baked.png` | 4096 × 4096 | 12.30 MB | 67.1 MB |
| `Columns_baked.png` | 4096 × 4096 | 9.18 MB | 67.1 MB |
| `Floor_baked.png` | 4096 × 4096 | 5.66 MB | 67.1 MB |
| `Architecture_baked.png` | 4096 × 4096 | 2.81 MB | 67.1 MB |
| `night_sky_8k.png` | 8192 × 4096 | 0.84 MB | 134.2 MB |
| `water_reflection.png` | 2048 × 2048 | 3.57 MB | 16.8 MB |
| `shore_objects_atlas.png` | 2048 × 2048 | 0.85 MB | 16.8 MB |
| `landscape_atlas.png` | 2048 × 2048 | 0.56 MB | 16.8 MB |
| `Lantern_Metal_baked.png` | 2048 × 2048 | 0.73 MB | 16.8 MB |
| `hanging_lantern_atlas.png` | 512 × 1024 | 0.31 MB | 2.1 MB |
| `lantern_glow.png` | 256 × 256 | 0.01 MB | 0.3 MB |
| **total** | | | **≈472 MB** |

The current asset's 22 textures are all 1024² or smaller (sky 2048×1024), ≈84 MB decoded.
Residency must be sampled in a rendering scene (CLAUDE.md, "Texture residency must be sampled
IN A RENDERING SCENE"); this figure is the ceiling, not a prediction. **It is the number that
decides whether the swap is viable on device**, ahead of draw calls or triangles, both of which
improve.

## What a swap would break in the Swift side

The lighting and environment code reads names and paths from the loaded hierarchy. None of
these are changed; they are what the post-challenge stage has to reconcile, either in the asset
or in the code:

| code | expects | new asset |
| --- | --- | --- |
| `PavilionEnvironment.swift:368` | entity `Platform` | **absent** (`Baked_Floor`); the orientation/clearance measurement finds nothing |
| `EnvironmentLighting.swift:80–81, 321, 338` | `Lantern_01`…`Lantern_08`, `Lantern_Ceiling` | **absent** — lanterns are baked into merged meshes; the only `Lantern_08` is a glow card. **No lantern light would be placed** |
| `EnvironmentLighting.swift:242` | `Night_Sky_Dome` | **absent** (`Sky/Night_Sky`): sky material **not replaced**, radius **not changed**; the authored 1100 m sphere with its 8k map renders as-is |
| `EnvironmentLighting.swift:281` | `textures/night_sky_2k.png` inside the usdz | **absent** (`night_sky_8k.png`): **IBL not built**; per the code's own note the reflection-only water then renders black |
| `PavilionEnvironment.swift:51` | `authoredTextureCount = 22` | 11 |
| `EnvironmentLighting.describeMaterial(named: "Water")` | an entity named `Water` | present (`Water` Xform) |
| — | no camera | `Review_Camera` at the root ships in the asset; harmless in an immersive space, but it does not belong in a shipping environment |

## Other observations

- The 30.6 MB `.usdc` layer for 147k triangles points to unindexed per-face-vertex normals/UVs
  from the bake: a load-time cost (parse, upload), not a render cost.
- Water is a single zero-thickness plane; the current asset's water has 14 mm of depth
  (−0.437…−0.423), which may matter for the reflection material's normal map.
- The exterior (`Landscape_Merged` to r ≈ 495 m, shore objects to r ≈ 162 m) is new geometry
  the current asset does not have; it is what the extra draw submissions beyond the pavilion
  pay for, and it is inside the 1100 m sky.
