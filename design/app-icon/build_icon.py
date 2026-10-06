#!/usr/bin/env python3
"""Build the three visionOS app-icon layers from the six source components (design/app-icon/source).

Outputs (design/app-icon/):
  QuranSpatial_AppIcon_Background_1024.png   opaque: navy + 03_night_environment cropped to its solid
                                             rectangle, scaled uniformly to cover the canvas, shifted so
                                             the crescent sits inside the arch opening
  QuranSpatial_AppIcon_Middle_1024.png       transparent: platform, then arch, then lanterns
  QuranSpatial_AppIcon_Foreground_1024.png   transparent: the floating Quran, page text blocks smeared
  qa/                                        flat and circular previews at 1024 / 128 / 64, page zooms
Pure PIL. Every geometric choice is measured from the layers and printed.
"""
import os, sys, json
from PIL import Image, ImageDraw, ImageFilter, ImageChops

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "source"); QA = os.path.join(HERE, "qa")
N = 1024
NAVY = (10, 16, 40, 255)

def load(name): return Image.open(os.path.join(SRC, name)).convert("RGBA")

def solid_rect(a, thr=248, frac=0.97):
    """The axis-aligned rectangle where alpha >= thr on at least `frac` of each row and column
    (a few interior pixels - star cores, glow - carry soft alpha, so an all-pixels rule over-tightens)."""
    W, H = a.size; px = a.load()
    rows = [y for y in range(H) if sum(1 for x in range(W) if px[x, y] >= thr) > W * 0.5]
    cols = [x for x in range(W) if sum(1 for y in range(H) if px[x, y] >= thr) > H * 0.5]
    x0, x1, y0, y1 = cols[0], cols[-1], rows[0], rows[-1]
    def row_ok(y): return sum(1 for x in range(x0, x1 + 1) if px[x, y] >= thr) >= frac * (x1 - x0 + 1)
    def col_ok(x): return sum(1 for y in range(y0, y1 + 1) if px[x, y] >= thr) >= frac * (y1 - y0 + 1)
    while not row_ok(y0): y0 += 1
    while not row_ok(y1): y1 -= 1
    while not col_ok(x0): x0 += 1
    while not col_ok(x1): x1 -= 1
    soft = sum(1 for y in range(y0, y1 + 1) for x in range(x0, x1 + 1) if px[x, y] < thr)
    print(f"   soft pixels inside the rectangle: {soft} of {(x1-x0+1)*(y1-y0+1)}")
    return x0, y0, x1 + 1, y1 + 1   # PIL box

def bbox_where(im, pred, box=None):
    px = im.load(); W, H = im.size
    xs = []; ys = []
    bx0, by0, bx1, by1 = box or (0, 0, W, H)
    for y in range(by0, by1):
        for x in range(bx0, bx1):
            if pred(px[x, y]): xs.append(x); ys.append(y)
    return (min(xs), min(ys), max(xs) + 1, max(ys) + 1) if xs else None

def fix_alpha(im, thr=248):
    """Solid pixels (alpha >= thr) become fully opaque; softer edge alpha is left alone."""
    r, g, b, a = im.split()
    a = a.point(lambda v: 255 if v >= thr else v)
    return Image.merge("RGBA", (r, g, b, a))

# ---------------------------------------------------------------- measurements
env, arch, book, plat, lant = load("03_night_environment.png"), load("02_gold_arch.png"), load("04_floating_quran.png"), load("05_gold_platform.png"), load("06_lanterns.png")
rect = solid_rect(env.getchannel("A"))
print("03 solid rectangle (PIL box):", rect, "size", rect[2] - rect[0], "x", rect[3] - rect[1])

# crescent: bright warm pixels in the sky part of the environment
sky_box = (rect[0], rect[1], rect[2], rect[1] + int((rect[3] - rect[1]) * 0.45))
# Bright crescent body only (the warm Milky Way glow to its right is excluded by the stricter thresholds),
# then padded for the glow around the moon.
cres = bbox_where(env, lambda p: p[3] > 240 and p[0] > 245 and p[1] > 225 and p[2] < 200, sky_box)
GLOW = 16
cres = (cres[0] - GLOW, cres[1] - GLOW, cres[2] + GLOW, cres[3] + GLOW)
print("crescent bbox in 03:", cres)

# horizon: the first row (top-down) inside the rect whose centre strip is mostly dark-blue mountain/lake rather than sky
# simpler: row of maximum brightness transition in the centre column band -> use the lake's top reflection; we take the
# row where mean luminance across the middle third drops below the sky mean - measured below from the mountain ridge.
def row_mean(im, y, x0, x1):
    px = im.load(); return sum(sum(px[x, y][:3]) / 3 for x in range(x0, x1)) / (x1 - x0)
mid0, mid1 = rect[0] + (rect[2] - rect[0]) // 3, rect[2] - (rect[2] - rect[0]) // 3
ridge = None
for y in range(rect[1] + int((rect[3] - rect[1]) * 0.4), rect[3]):
    if row_mean(env, y, mid0, mid1) < 70: ridge = y; break
print("mountain ridge / horizon band starts at y ~", ridge)

# arch opening: inside the arch bbox, the transparent interior at a given row is the span between the ring walls
ab = arch.getbbox(); print("arch bbox:", ab)
apx = arch.getchannel("A").load()
def _opening_scan(y):
    """Transparent span strictly inside the arch ring at row y: scan from the centre outwards."""
    cx = (ab[0] + ab[2]) // 2
    if apx[cx, y] > 10: return None
    l = cx
    while l > ab[0] and apx[l, y] <= 10: l -= 1
    r = cx
    while r < ab[2] and apx[r, y] <= 10: r += 1
    return l + 1, r
_openings = {y: _opening_scan(y) for y in range(ab[1], ab[3])}
def opening_at(y): return _openings.get(y)
peak = next(y for y in range(ab[1], ab[3]) if opening_at(y))
print("arch opening peak y:", peak, "; opening spans:", {y: opening_at(y) for y in (peak + 40, 300, 360, 420, 470)})

# columns: rows where the arch has two solid vertical bands far apart (the pillars)
cols_top = next(y for y in range(ab[1], ab[3]) if apx[ab[0] + 20, y] > 10 and apx[ab[2] - 21, y] > 10)
print("pillar tops at y ~", cols_top, "; arch bottom", ab[3])

# ---------------------------------------------------------------- background
crop = env.crop(rect)
cw, ch = crop.size
base_scale = max(N / cw, N / ch)
# Placement. Scale = the uniform cover scale (about 1.29x). After that scale the crescent's top rises above
# the arch peak, so the image is shifted DOWN until the crescent sits inside the opening, and LEFT/RIGHT to
# centre it. "Inside" is checked ROW BY ROW against the crescent's actual bright extent (a crescent is thin
# at its horn, which sits well inside the pointed arch where a bounding box would not). The band exposed at
# the top by the downward shift is filled by mirroring the scaled sky (not by feathering into navy, which
# the review found still reads as an edge). The scale grows in small steps only if nothing fits.
cmask = Image.new("L", (N, N), 0); cmp_ = cmask.load(); epx = env.load()
for y in range(cres[1], cres[3]):
    for x in range(cres[0], cres[2]):
        q = epx[x, y]
        if q[3] > 240 and q[0] > 245 and q[1] > 225 and q[2] < 200: cmp_[x, y] = 255
cmask = cmask.filter(ImageFilter.MaxFilter(17))          # ~8 px of glow around the bright body
cm = cmask.load()
crows = {}
for y in range(cres[1] - 12, cres[3] + 12):
    xs = [x for x in range(cres[0] - 12, cres[2] + 12) if cm[x, y]]
    if xs: crows[y] = (xs[0], xs[-1] + 1)
margin = 10
MAX_STRIP = 48          # the right-hand strip that may be mirror-filled when the shift exceeds the cover width
best = None
s_try = base_scale
while best is None and s_try < base_scale * 1.2:
    sw, sh = round(cw * s_try), round(ch * s_try)
    def fits(dx, dy):
        for y, (x0, x1) in crows.items():
            cy = (y - rect[1]) * s_try + dy
            kx0, kx1 = (x0 - rect[0]) * s_try + dx, (x1 - rect[0]) * s_try + dx
            if cy < peak + 4: return False
            sp = opening_at(min(max(int(cy), ab[1]), ab[3] - 1))
            if not sp or kx0 < sp[0] + margin or kx1 > sp[1] - margin: return False
        return True
    cands = []
    for dy in range(0, 200, 2):
        hz = (ridge - rect[1]) * s_try + dy
        if not (cols_top + 20 < hz < ab[3] - 60) or sh + dy < N: continue
        for dx in range(-(sw - N) - MAX_STRIP, 1, 2):
            if fits(dx, dy):
                strip = max(0, -dx - (sw - N))
                cands.append((strip, dy, abs(dx), dx, hz))
    if os.environ.get("ICON_SCAN"):
        if cands:
            by_dy = min(cands, key=lambda c: (c[1], c[0])); by_strip = min(cands)
            print(f"  scale {s_try:.4f}: min-dy candidate dy {by_dy[1]} strip {by_dy[0]} dx {by_dy[3]} hz {by_dy[4]:.0f} | min-strip candidate strip {by_strip[0]} dy {by_strip[1]} dx {by_strip[3]}")
        else: print(f"  scale {s_try:.4f}: no fit")
        s_try = round(s_try + 0.01, 4)
        if s_try >= base_scale * 1.12: sys.exit("scan done")
        continue
    if cands:
        strip, dy, _, dx, hz = min(cands)
        kb = ((cres[0] - rect[0]) * s_try + dx, (cres[1] - rect[1]) * s_try + dy, (cres[2] - rect[0]) * s_try + dx, (cres[3] - rect[1]) * s_try + dy)
        best = (s_try, sw, sh, dx, dy, kb, hz, strip)
    else:
        s_try = round(s_try + 0.01, 4)
if not best: sys.exit("no placement satisfies the constraints")
s, sw, sh, dx, dy, kb, hz, strip = best
print(f"background: scale {s:.4f} (cover {base_scale:.4f}), scaled {sw}x{sh}, offset ({dx},{dy}); crescent on canvas {tuple(round(v) for v in kb)}; horizon y {hz:.0f}; mirrored top band {max(dy,0)} px, mirrored right strip {strip} px")
scaled = crop.resize((sw, sh), Image.LANCZOS)
bg = Image.new("RGBA", (N, N), NAVY)
# Exposed bands are filled by MIRRORING the scaled image's own edge (a reflection about the band's inner
# edge), never by feathering into navy. Right strip first, then the top band across the full width.
if strip > 0:
    right = scaled.crop((sw - strip, 0, sw, sh)).transpose(Image.FLIP_LEFT_RIGHT)
    bg.alpha_composite(right, (sw + dx, dy))
bg.alpha_composite(scaled, (dx, dy))
if dy > 0:
    band = bg.crop((0, dy, N, 2 * dy)).transpose(Image.FLIP_TOP_BOTTOM)
    bg.alpha_composite(band, (0, 0))
bg = Image.merge("RGBA", bg.split()[:3] + (Image.new("L", (N, N), 255),))
assert bg.getchannel("A").getextrema() == (255, 255)

# ---------------------------------------------------------------- foreground: smear the page text blocks
# The two text blocks are FIXED, hand-measured outlines (Mo's review, 5 Oct 2026, measured on the source
# at 5x), in 1024 px Foreground coordinates. Automatic detection (stroke hull, gutter walk, frame-shape
# rules) was tried through several rounds and each version either stopped short of the gutter or ran
# over a border; a fixed outline is checked once, by eye, and does not move. Filled with no feathering.
bb = book.getbbox(); print("book bbox:", bb)
LEFT_BLOCK = [(396.6, 579), (430, 585.5), (470, 599), (494.8, 608.5), (494.8, 685.4), (470, 678), (430, 664.4),
              (382.4, 649), (376.4, 640), (382.4, 626), (387, 612), (392, 594)]
RIGHT_BLOCK = [(529, 608), (547, 602), (565, 595), (595, 585), (627.4, 579), (636, 600), (643, 620), (647.4, 637),
               (645, 645), (617, 656.4), (575, 669.4), (545, 679.4), (529, 684.4)]
m = Image.new("L", (N, N), 0); md = ImageDraw.Draw(m)
md.polygon(LEFT_BLOCK, fill=255); md.polygon(RIGHT_BLOCK, fill=255)
mask_count = sum(1 for v in m.getdata() if v)
print("page mask pixels (two fixed polygons):", mask_count)

# Masked horizontal mean, K = 61 px: sum(pixel * mask) / sum(mask) over the window, so the frame and the
# page margin never bleed in; then a 1.2 px soften; both composited back through the same mask.
K = 61
mp = m.load()
def masked_hmean(ch):
    W, H = ch.size; src = ch.load(); out = ch.copy(); dst = out.load(); half = K // 2
    for y in range(bb[1], bb[3]):
        if not any(mp[x, y] for x in range(bb[0], bb[2])): continue
        vals = [src[x, y] if mp[x, y] else 0 for x in range(W)]
        wts = [1 if mp[x, y] else 0 for x in range(W)]
        cv = [0] * (W + 1); cw = [0] * (W + 1)
        for x in range(W): cv[x + 1] = cv[x] + vals[x]; cw[x + 1] = cw[x] + wts[x]
        for x in range(bb[0], bb[2]):
            if not mp[x, y]: continue
            lo, hi = max(0, x - half), min(W, x + half + 1)
            w = cw[hi] - cw[lo]
            if w: dst[x, y] = int(round((cv[hi] - cv[lo]) / w))
    return out
rgb = book.convert("RGB")
smeared = Image.merge("RGB", [masked_hmean(ch) for ch in rgb.split()])
fg_rgb = Image.composite(smeared.filter(ImageFilter.GaussianBlur(1.2)), rgb, m)
fg = Image.merge("RGBA", fg_rgb.split() + (book.getchannel("A"),))
fg = fix_alpha(fg)

# ACCEPTANCE (Mo's review, 5 Oct): nothing changes near the alpha edge; every changed RGB pixel lies inside
# the two polygons; the borders are untouched by construction (they are outside the polygons).
src_px = rgb.load(); out_px = fg.convert("RGB").load()
near_soft = book.getchannel("A").point(lambda v: 255 if v < 250 else 0).filter(ImageFilter.MaxFilter(9)).load()
changed = [(x, y) for y in range(bb[1], bb[3]) for x in range(bb[0], bb[2]) if src_px[x, y] != out_px[x, y]]
changed_near_edge = sum(1 for x, y in changed if near_soft[x, y])
changed_outside = sum(1 for x, y in changed if not mp[x, y])
print(f"ACCEPT changed RGB pixels: {len(changed)}; within 4 px of alpha<250: {changed_near_edge}; outside the polygons: {changed_outside}")
def local_contrast(im_rgb, mask):
    g = im_rgb.convert("L"); gb = g.filter(ImageFilter.GaussianBlur(3))
    diff = ImageChops.difference(g, gb); d = diff.load(); mq = mask.load()
    vals = [d[x, y] for y in range(bb[1], bb[3]) for x in range(bb[0], bb[2]) if mq[x, y]]
    vals.sort(); return (round(sum(vals) / len(vals), 1), vals[int(len(vals) * 0.99)], max(vals))
print("page-interior local contrast (mean, p99, max) before:", local_contrast(rgb, m))
print("page-interior local contrast (mean, p99, max) after :", local_contrast(fg.convert("RGB"), m))

# ---------------------------------------------------------------- middle
mid = Image.new("RGBA", (N, N), (0, 0, 0, 0))
for layer in (plat, arch, lant): mid.alpha_composite(layer)
mid = fix_alpha(mid)

# ---------------------------------------------------------------- outputs
for im, name in ((bg, "Background"), (mid, "Middle"), (fg, "Foreground")):
    im.save(os.path.join(HERE, f"QuranSpatial_AppIcon_{name}_1024.png"), optimize=True)
flat = bg.copy(); flat.alpha_composite(mid); flat.alpha_composite(fg)
circle = Image.new("L", (N, N), 0); ImageDraw.Draw(circle).ellipse((0, 0, N - 1, N - 1), fill=255)
for size in (1024, 128, 64):
    f = flat.resize((size, size), Image.LANCZOS); f.save(os.path.join(QA, f"flat_{size}.png"))
    c = Image.new("RGBA", (size, size), (40, 40, 40, 255)); c.paste(f, (0, 0), circle.resize((size, size), Image.LANCZOS)); c.save(os.path.join(QA, f"circle_{size}.png"))
# page zooms before/after, the review crops at 4x, and the mask
zoom_box = (bb[0], bb[1], bb[2], bb[3])
before = book.crop(zoom_box).resize(((bb[2] - bb[0]) * 2, (bb[3] - bb[1]) * 2), Image.LANCZOS)
after = fg.crop(zoom_box).resize(((bb[2] - bb[0]) * 2, (bb[3] - bb[1]) * 2), Image.LANCZOS)
pair = Image.new("RGBA", (before.width, before.height * 2 + 10), (40, 40, 40, 255)); pair.alpha_composite(before, (0, 0)); pair.alpha_composite(after, (0, before.height + 10)); pair.save(os.path.join(QA, "pages_before_after_2x.png"))
maskv = Image.merge("RGBA", (m, m, m, Image.new("L", (N, N), 255))).crop(zoom_box); maskv.save(os.path.join(QA, "page_mask.png"))
def crop4x(box, name):
    cw4, ch4 = (box[2] - box[0]) * 4, (box[3] - box[1]) * 4
    ci = Image.new("RGBA", (cw4, ch4 * 2 + 10), (40, 40, 40, 255))
    ci.alpha_composite(book.crop(box).resize((cw4, ch4), Image.NEAREST), (0, 0)); ci.alpha_composite(fg.crop(box).resize((cw4, ch4), Image.NEAREST), (0, ch4 + 10))
    ci.save(os.path.join(QA, name))
crop4x((400, 555, 630, 625), "top_gutter_crop_4x.png")
crop4x((370, 640, 660, 700), "bottom_borders_crop_4x.png")
bgq = bg.copy(); d = ImageDraw.Draw(bgq); d.rectangle(tuple(round(v) for v in kb), outline=(255, 0, 0, 255), width=3)
if dy > 0: d.line((0, dy, N, dy), fill=(255, 0, 255, 255), width=2)
if strip > 0: d.line((sw + dx, 0, sw + dx, N), fill=(255, 0, 255, 255), width=2)
d.ellipse((0, 0, N - 1, N - 1), outline=(0, 255, 0, 255), width=2)
bgq.alpha_composite(arch); bgq.save(os.path.join(QA, "background_crescent_in_arch.png"))
# alpha report
for im, name in ((bg, "Background"), (mid, "Middle"), (fg, "Foreground")):
    h = im.getchannel("A").histogram()
    print(f"{name}: alpha 255 {h[255]}, 248-254 {sum(h[248:255])}, 1-247 {sum(h[1:248])}, 0 {h[0]}; mode {im.mode}")
json.dump({"mirroredTopBand": max(dy, 0), "mirroredRightStrip": strip, "solidRect": rect, "crescentBBox": cres, "archOpeningPeakY": peak, "pillarTopY": cols_top, "ridgeY": ridge,
           "backgroundScale": s, "backgroundOffset": [dx, dy], "crescentOnCanvas": [round(v) for v in kb], "horizonY": round(hz),
           "smearKernel": K, "pageMaskPixels": mask_count, "changedPixels": len(changed), "leftBlock": LEFT_BLOCK, "rightBlock": RIGHT_BLOCK}, open(os.path.join(HERE, "build_icon_measurements.json"), "w"), indent=1)
print("done")
