#!/usr/bin/env python3
"""
Stage 1b B3: speech-free gap around each ayah start boundary in rahman-single.mp3.

Measurement only. Reads the bundled audio and timings, writes b3-preroll.csv beside this
script. Standard library only; decoding goes through afconvert (macOS).

Method (see docs/stage-1-report.md, B3):
  * decode to 16 kHz mono, 300-3400 Hz band-pass (2nd-order high-pass + low-pass)
  * 20 ms frames at a 10 ms hop, energy in dBFS, then a 50 ms mean in the energy domain
  * local bed floor F = 5th percentile of frames within +-10 s of the boundary, excluding
    digital silence and everything before BED_START (the intro carries no bed)
  * speech-free = env < F + MARGIN_DB; above-threshold runs < 60 ms are not speech onset,
    below-threshold runs < 80 ms are closures inside words
  * before = boundary - gap start; after = onset - boundary; usable pre-roll = onset - gap start

Usage: python3 b3-preroll.py [--margin 6] [--repo /path/to/QuranSpatial]
"""
import argparse, array, csv, hashlib, json, math, os, subprocess, sys, tempfile, wave

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
FULL_SCALE_DB = 20 * math.log10(32768)   # int16 full scale, so energies read in dBFS

HOP_S, WIN_S = 0.010, 0.020
SMOOTH_FRAMES = 5                        # 50 ms at a 10 ms hop
FLOOR_WIN_S, FLOOR_Q = 10.0, 0.05
DIGITAL_SILENCE_DBFS = -85.0             # below this a frame is digital silence
BED_START_S = 3.761                      # end of the 3.637-3.761 s digital-silence splice
MIN_SPEECH_S, MIN_GAP_S = 0.06, 0.08
SEARCH_S = 6.0                           # window either side of a boundary

def decode(mp3, wav):
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", mp3, wav],
                   check=True, capture_output=True)

def biquad(sig, b0, b1, b2, a1, a2):
    out = array.array("f", bytes(4 * len(sig))); x1 = x2 = y1 = y2 = 0.0
    for i, v in enumerate(sig):
        o = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, v, y1, o
        out[i] = o
    return out

def coeffs(kind, f0, sr, q=0.7071):
    w0 = 2 * math.pi * f0 / sr; al = math.sin(w0) / (2 * q); c = math.cos(w0); a0 = 1 + al
    b = ((1 + c) / 2, -(1 + c), (1 + c) / 2) if kind == "hp" else ((1 - c) / 2, 1 - c, (1 - c) / 2)
    return b[0] / a0, b[1] / a0, b[2] / a0, -2 * c / a0, (1 - al) / a0

def envelope_dbfs(sig, sr):
    hop, win = int(sr * HOP_S), int(sr * WIN_S)
    out = []
    for s in range(0, len(sig) - win, hop):
        acc = 0.0
        for v in sig[s:s + win]: acc += v * v
        out.append(10 * math.log10(acc / win + 1e-9) - FULL_SCALE_DB)
    return out

def smooth(raw):
    lin = [10 ** (v / 10) for v in raw]; h = SMOOTH_FRAMES // 2
    return [10 * math.log10(sum(lin[max(0, i - h):i + h + 1]) / len(lin[max(0, i - h):i + h + 1]) + 1e-12)
            for i in range(len(lin))]

def runs(mask):
    out, s = [], 0
    for i in range(1, len(mask) + 1):
        if i == len(mask) or mask[i] != mask[s]:
            out.append((mask[s], s, i)); s = i
    return out

def digital_silence_runs(x, sr, min_s=0.005):
    out, s = [], None
    for i, v in enumerate(x):
        if abs(v) <= 2:
            if s is None: s = i
        else:
            if s is not None and i - s >= int(min_s * sr): out.append((s / sr, i / sr))
            s = None
    if s is not None: out.append((s / sr, len(x) / sr))
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--margin", type=float, default=6.0, help="dB above the local floor (default 6)")
    ap.add_argument("--repo", default=DEFAULT_REPO)
    ap.add_argument("--out", default=os.path.join(HERE, "b3-preroll.csv"))
    ap.add_argument("--json", default=None,
                    help="also write the app's resume table (QuranSpatial/Resources/ar-rahman-preroll.json)")
    a = ap.parse_args()
    res = os.path.join(a.repo, "QuranSpatial", "Resources")
    segments = json.load(open(os.path.join(res, "ar-rahman-timings.json")))["segments"]

    mp3 = os.path.join(res, "rahman-single.mp3")
    mp3_sha = hashlib.sha256(open(mp3, "rb").read()).hexdigest()
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "rahman16k.wav")
        decode(mp3, wav)
        w = wave.open(wav); sr = w.getframerate()
        x = array.array("h", w.readframes(w.getnframes()))
    print("decoded %.3f s at %d Hz; digital silence runs >= 5 ms: %s" % (
        len(x) / sr, sr, [(round(p, 3), round(q, 3)) for p, q in digital_silence_runs(x, sr)]))

    band = biquad(biquad(x, *coeffs("hp", 300, sr)), *coeffs("lp", 3400, sr))
    raw = envelope_dbfs(band, sr); env = smooth(raw); hop = HOP_S

    def floor_at(t):
        lo, hi = int(max(t - FLOOR_WIN_S, BED_START_S) / hop), int((t + FLOOR_WIN_S) / hop)
        v = sorted(f for f in raw[max(0, lo):hi] if f > DIGITAL_SILENCE_DBFS)
        return v[int(len(v) * FLOOR_Q)]

    rows = []
    for seg in segments[1:]:
        b = seg["start"]; F = floor_at(b); thr = F + a.margin
        lo, hi = int((b - SEARCH_S) / hop), min(len(env), int((b + SEARCH_S) / hop))
        mask = [env[i] >= thr for i in range(lo, hi)]
        for kind, minlen in ((True, MIN_SPEECH_S), (False, MIN_GAP_S)):
            for v, s, t in runs(mask):
                if v == kind and (t - s) * hop < minlen and s > 0 and t < len(mask):
                    for k in range(s, t): mask[k] = not kind
        bi = int(b / hop) - lo
        rs = runs(mask); here = next(r for r in rs if r[1] <= bi < r[2])
        row = {"segment": seg["index"], "kind": seg["kind"], "boundary_s": b, "floor_dbfs": round(F, 1),
               "before_s": "", "after_s": "", "onset_s": "", "preroll_s": "", "status": "measured", "reason": ""}
        if not here[0]:
            g0, g1 = (lo + here[1]) * hop, (lo + here[2]) * hop
            row.update(before_s=round(b - g0, 2), after_s=round(g1 - b, 2), onset_s=round(g1, 2), preroll_s=round(g1 - g0, 2))
        else:
            prev_q = [r for r in rs if not r[0] and r[2] <= bi]; next_q = [r for r in rs if not r[0] and r[1] > bi]
            fmt = lambda r: "%.2f-%.2f s" % ((lo + r[1]) * hop, (lo + r[2]) * hop)
            row.update(status="suspect", reason=(
                "boundary lies inside continuous speech %s; nearest speech-free gaps %s (before) and %s (after); "
                "energy cannot place the ayah start - needs a listening check"
                % (fmt(here), fmt(prev_q[-1]) if prev_q else "none", fmt(next_q[0]) if next_q else "none")))
        if seg["index"] == 1:
            row.update(before_s="", after_s="", preroll_s="", status="unmeasured", reason=(
                "no bed to measure against: the intro (0-3.637 s) carries no bed and decays below the later floor; "
                "124 ms of digital silence at 3.637-3.761 s (a splice) sits inside segment 1; the boundary at 3.31 s "
                "is in the intro's decay tail. onset_s is the first rise above the post-splice floor + margin"))
        rows.append(row)

    with open(a.out, "w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["segment", "kind", "boundary_s", "local_floor_dbfs", "speech_free_before_boundary_s",
                     "speech_free_after_boundary_s", "speech_onset_s", "usable_preroll_s", "status", "reason"])
        for r in rows:
            wr.writerow([r["segment"], r["kind"], r["boundary_s"], r["floor_dbfs"], r["before_s"], r["after_s"],
                         r["onset_s"], r["preroll_s"], r["status"], r["reason"]])

    if a.json:
        # The app's resume table. Measured rows carry the gap; the two unmeasured rows carry
        # only their status and reason, and the app falls back to the segment start for them.
        table = {
            "source": "rahman-single.mp3",
            "mp3SHA256": mp3_sha,
            "marginDb": a.margin,
            "method": ("300-3400 Hz band energy, 20 ms frames at 10 ms hop, 50 ms smoothing; floor = p5 of "
                       "+-10 s excluding digital silence and t < %.3f s; speech-free = below floor + margin"
                       % BED_START_S),
            "note": "gapStart is where the speech-free gap before the boundary begins; resume there and "
                    "fade in before speechOnset. Segment 0 has no row: it is the intro, never an Ask anchor.",
            "segments": [],
        }
        for r in rows:
            entry = {"index": r["segment"], "kind": r["kind"], "boundary": r["boundary_s"], "status": r["status"]}
            if r["status"] == "measured":
                entry.update(gapStart=round(r["onset_s"] - r["preroll_s"], 2), speechOnset=r["onset_s"],
                             usablePreroll=r["preroll_s"])
            else:
                entry["reason"] = r["reason"]
            table["segments"].append(entry)
        with open(a.json, "w") as f:
            json.dump(table, f, indent=1, ensure_ascii=False); f.write("\n")
        print("wrote", a.json)

    ok = [r for r in rows if r["status"] == "measured"]
    print("margin %.1f dB: %d boundaries, %d measured, %d not: %s" % (
        a.margin, len(rows), len(ok), len(rows) - len(ok), [(r["segment"], r["status"]) for r in rows if r["status"] != "measured"]))
    fl = sorted(r["floor_dbfs"] for r in rows)
    print("floor dBFS: min %.1f median %.1f max %.1f" % (fl[0], fl[len(fl) // 2], fl[-1]))
    for k in ("before_s", "after_s", "preroll_s"):
        v = sorted(r[k] for r in ok); n = len(v)
        print("%-10s min %.2f p10 %.2f median %.2f p90 %.2f max %.2f" % (k, v[0], v[int(n * .1)], v[n // 2], v[int(n * .9)], v[-1]))
    s13 = next(r for r in rows if r["segment"] == 13)
    print("segment 13: floor %.1f dBFS, before %.2f, after %.2f, onset %.2f, preroll %.2f" % (
        s13["floor_dbfs"], s13["before_s"], s13["after_s"], s13["onset_s"], s13["preroll_s"]))
    print("wrote", a.out)

if __name__ == "__main__":
    main()
