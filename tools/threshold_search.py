#!/usr/bin/env python3
"""Threshold search over recorded dua captures.

Replays HandPoseCapture JSON through a reimplementation of DuaPostureRecognizer's gate
logic, searches the five ENTER bounds under an asymmetric objective, and reports the best
achievable margin. See the "Dua recognizer: acceptance criterion" section of CLAUDE.md -
this script is the thing that makes "no assignment exists" a computed result rather than a
judgement made at week six under deadline pressure.

Two structural guards, both deliberately not optional:

  FIDELITY   The gate maths here duplicates Swift, and a silent divergence would
             invalidate every number this prints. Any capture carrying the device's own
             per-frame `state` is replayed at the shipped thresholds first and must match
             it exactly. A mismatch aborts.

  HOLDOUT    Captures containing a segment of a holdout kind (pinch) are excluded from the
             search entirely, by this script, not by anyone remembering to. The vector is
             chosen without them and evaluated against them once, afterwards.

Usage:  python3 tools/threshold_search.py [manifest]
"""

import json, math, sys, os, itertools, random

# ---------------------------------------------------------------- shipped constants
SHIPPED = dict(inward=0.58, towardHead=0.42, extension=1.30, belowHeadY=0.45,
               sepMin=0.04, sepMax=0.35)
EXIT = dict(inward=0.25, towardHead=0.15, extension=1.15, belowHeadY=0.60,
            sepMin=0.02, sepMax=0.45)
COMMIT_WINDOW = 1.5
MAX_TRACKING_GAP = 0.15
MIN_REF = 0.03

# Per-gate margin M, in each gate's own units. See CLAUDE.md: derived from p95 excursion
# across a commit window within held segments, KNOWN TO BE BIASED LOW, rises never falls.
M = dict(inward=0.09, towardHead=0.06, extension=0.10, belowHeadY=0.02, separation=0.02)

# ---------------------------------------------------------------- geometry (mirrors HandPose.swift)
def sub(a, b): return (a[0]-b[0], a[1]-b[1], a[2]-b[2])
def add(a, b): return (a[0]+b[0], a[1]+b[1], a[2]+b[2])
def scale(a, k): return (a[0]*k, a[1]*k, a[2]*k)
def dot(a, b): return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]
def cross(a, b): return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])
def norm(a): return math.sqrt(dot(a, a))

def palm_center(j):
    t = tuple(j["wrist"])
    for k in ("indexKnuckle", "middleKnuckle", "ringKnuckle", "littleKnuckle"):
        t = add(t, tuple(j[k]))
    return scale(t, 0.2)

def palm_normal(j, chirality):
    to_index = sub(tuple(j["indexKnuckle"]), tuple(j["wrist"]))
    to_little = sub(tuple(j["littleKnuckle"]), tuple(j["wrist"]))
    n = cross(to_index, to_little) if chirality == "right" else cross(to_little, to_index)
    L = norm(n)
    return scale(n, 1.0/L) if L > 0 else (0.0, 0.0, 0.0)

def finger_extension(j):
    w = tuple(j["wrist"]); rs = []
    for tip, kn in (("indexTip", "indexKnuckle"), ("middleTip", "middleKnuckle"),
                    ("ringTip", "ringKnuckle"), ("littleTip", "littleKnuckle")):
        kd = norm(sub(tuple(j[kn]), w))
        rs.append(0.0 if kd == 0 else norm(sub(tuple(j[tip]), w))/kd)
    return sum(rs)/len(rs)

def direction(o, t):
    d = sub(t, o); L = norm(d)
    return None if L < MIN_REF else scale(d, 1.0/L)

def chirality(h): return "left" if "left" in h["chirality"] else "right"

# ---------------------------------------------------------------- per-frame scalars
def load(path):
    frames = json.load(open(path))
    rows = []
    for f in frames:
        head = tuple(f["headPosition"]); l = f.get("left"); r = f.get("right")
        if not l or not r:
            continue
        lc, rc = palm_center(l["joints"]), palm_center(r["joints"])
        ln = palm_normal(l["joints"], chirality(l))
        rn = palm_normal(r["joints"], chirality(r))
        d = lambda n, v: None if v is None else dot(n, v)
        rows.append(dict(
            t=f["timestamp"],
            tracked=bool(l["isTracked"] and r["isTracked"]),
            anyTracked=bool(l["isTracked"] or r["isTracked"]),
            inwardL=d(ln, direction(lc, rc)), inwardR=d(rn, direction(rc, lc)),
            headL=d(ln, direction(lc, head)), headR=d(rn, direction(rc, head)),
            extL=finger_extension(l["joints"]), extR=finger_extension(r["joints"]),
            belowL=head[1]-lc[1], belowR=head[1]-rc[1],
            sep=norm(sub(lc, rc)),
            devState=f.get("state"),
        ))
    t0 = rows[0]["t"]
    for x in rows:
        x["rel"] = x["t"] - t0
    return rows

def slacks(x, v):
    """Per-gate signed slack: >= 0 passes. Native units, so divide by M to normalise."""
    def lo(a, b, bound): return min(-1e9 if a is None else a, -1e9 if b is None else b) - bound
    return dict(
        inward=lo(x["inwardL"], x["inwardR"], v["inward"]),
        towardHead=lo(x["headL"], x["headR"], v["towardHead"]),
        extension=lo(x["extL"], x["extR"], v["extension"]),
        belowHeadY=v["belowHeadY"] - max(x["belowL"], x["belowR"]),
        separation=min(x["sep"] - v["sepMin"], v["sepMax"] - x["sep"]),
    )

def passes(x, v):
    return x["tracked"] and all(s >= 0 for s in slacks(x, v).values())

# ---------------------------------------------------------------- state machine
def replay(rows, enter, exit_bounds):
    """Returns per-frame state, mirroring DuaPostureRecognizer including the watchdog.

    Watchdog releases are reconstructed from gaps in recorded timestamps: they are not
    written to the capture, because there is no frame and no device anchor to record one
    against. See runReleaseWatchdog in HandTrackingSession.
    """
    state, since, last_tracked = "idle", None, None
    out = []
    prev_t = None
    for x in rows:
        t = x["rel"]
        if prev_t is not None and t - prev_t > MAX_TRACKING_GAP:
            if state == "entering":
                state = "idle"
            elif state == "held":
                state = "idle"
        prev_t = t
        if x["anyTracked"]:
            last_tracked = t; within = True
        else:
            within = last_tracked is not None and t - last_tracked <= MAX_TRACKING_GAP
        dropout = (not x["anyTracked"]) and within
        E = passes(x, enter)
        X = passes(x, exit_bounds)
        if state == "idle":
            if E:
                state, since = "entering", t
        elif state == "entering":
            if E or dropout:
                if t - since >= COMMIT_WINDOW:
                    state = "held"
            else:
                state = "idle"
        elif state == "held":
            if not (X or dropout):
                state = "idle"
        out.append(state)
    return out

def commits_in(rows, states, a, b):
    """Did a commit (idle/entering -> held) occur inside [a, b]?"""
    for i in range(1, len(states)):
        if states[i] == "held" and states[i-1] != "held" and a <= rows[i]["rel"] <= b:
            return True
    return False

def _sliding_min(vals, win):
    """Window minima in O(n), so per-gate margins are cheap enough to report per segment."""
    from collections import deque
    dq, out = deque(), []
    for i, x in enumerate(vals):
        while dq and vals[dq[-1]] >= x:
            dq.pop()
        dq.append(i)
        if dq[0] <= i - win:
            dq.popleft()
        if i >= win - 1:
            out.append(vals[dq[0]])
    return out

def closeness(rows, a, b, v, hz, want_gate=False):
    """max over commit-length windows of (min over gates of normalised slack).

    >= 0 means some window passes every gate: the segment commits. Below 0, its magnitude
    is how much margin the rejection has, in units of M. With want_gate, also returns the
    gate that was binding at the best window - i.e. the one actually doing the separating.
    """
    seg = [x for x in rows if a <= x["rel"] <= b]
    if not seg:
        return (None, None) if want_gate else None
    win = min(max(1, int(COMMIT_WINDOW * hz)), len(seg))
    gates = list(M.keys())
    per_gate = {g: [] for g in gates}
    for x in seg:
        sl = slacks(x, v)
        for g in gates:
            val = sl[g]/M[g]
            if not x["tracked"]:
                val = min(val, -1e6)
            per_gate[g].append(val)
    mins = {g: _sliding_min(per_gate[g], win) for g in gates}
    n = len(next(iter(mins.values())))
    best, best_gate = -1e9, None
    for i in range(n):
        worst_gate = min(gates, key=lambda g: mins[g][i])
        worst = mins[worst_gate][i]
        if worst > best:
            best, best_gate = worst, worst_gate
    return (best, best_gate) if want_gate else best

# ---------------------------------------------------------------- objective
def evaluate(dataset, v):
    """Lexicographic, asymmetric. Higher is better on every returned component."""
    false_commits, true_commits = 0, 0
    conf_margins, true_margins = [], []
    for rows, states, segs, hz in dataset:
        st = replay(rows, v, EXIT)
        for seg in segs:
            if seg.get("discard"):
                continue
            a, b, kind = seg["start"], seg["end"], seg["kind"]
            c = closeness(rows, a, b, v, hz)
            if c is None:
                continue
            fired = commits_in(rows, st, a, b)
            if seg["_true"]:
                true_commits += 1 if fired else 0
                true_margins.append(c)
            else:
                false_commits += 1 if fired else 0
                conf_margins.append(-c)
    conf = min(conf_margins) if conf_margins else 0.0
    true = min(true_margins) if true_margins else 0.0
    # Confuser margin is SATISFICED at 1.0 x M, not maximised without bound. Maximising it
    # outright is degenerate: the search buys margin by rejecting everything, which trivially
    # gives zero false commits and zero true commits too. Asymmetry means false positives are
    # unacceptable and margin must be adequate - not that margin is worth any number of
    # missed duas. Past adequacy, extra margin is only a tiebreak.
    return (
        -false_commits,        # 1. hard constraint: must be 0
        min(conf, 1.0),        # 2. confuser rejection, adequate at M
        true_commits,          # 3. genuine duas that commit
        min(true, 1.0),        # 4. true-positive margin, adequate at M
        conf,                  # 5. tiebreak: more confuser margin
        true,                  # 6. tiebreak: more true margin
    )

# ---------------------------------------------------------------- search
GRID = dict(
    inward=[round(0.20 + 0.02*i, 3) for i in range(21)],
    towardHead=[round(0.10 + 0.02*i, 3) for i in range(21)],
    extension=[round(1.10 + 0.03*i, 3) for i in range(21)],
    belowHeadY=[round(0.25 + 0.02*i, 3) for i in range(21)],
    sepMin=[round(0.01 + 0.01*i, 3) for i in range(11)],
    sepMax=[round(0.20 + 0.02*i, 3) for i in range(16)],
)

def search(dataset, restarts=6, sweeps=4, seed=17):
    rng = random.Random(seed)
    best_v, best_score = None, None
    for r in range(restarts):
        v = dict(SHIPPED) if r == 0 else {k: rng.choice(GRID[k]) for k in GRID}
        score = evaluate(dataset, v)
        for _ in range(sweeps):
            improved = False
            for gate in GRID:
                for candidate in GRID[gate]:
                    if candidate == v[gate]:
                        continue
                    trial = dict(v); trial[gate] = candidate
                    if trial["sepMin"] >= trial["sepMax"]:
                        continue
                    s = evaluate(dataset, trial)
                    if s > score:
                        v, score, improved = trial, s, True
            if not improved:
                break
        if best_score is None or score > best_score:
            best_v, best_score = v, score
    return best_v, best_score

# ---------------------------------------------------------------- fidelity guard
# The thresholds a capture was RECORDED under. Fidelity must be checked against these,
# not against whatever is shipping now: the guard exists to catch this file's gate maths
# diverging from Swift's, and replaying an old capture at new thresholds would flag a
# deliberate threshold change as a maths bug. Captures recorded before 2026-09-04 used the
# pre-tightening vector below; a manifest entry may override with "recordedThresholds".
HISTORIC = dict(inward=0.40, towardHead=0.30, extension=1.30, belowHeadY=0.45,
                sepMin=0.04, sepMax=0.35)

def check_fidelity(rows, path, recorded=None):
    if rows[0]["devState"] is None:
        return None
    st = replay(rows, recorded or HISTORIC, EXIT)
    bad = sum(1 for x, m in zip(rows, st) if x["devState"] != m)
    if bad:
        print("FIDELITY FAILURE in %s: %d/%d frames disagree with the device's own state."
              % (os.path.basename(path), bad, len(rows)))
        print("The gate maths here has diverged from Swift. Every number below would be")
        print("meaningless, so the search is not run. Reconcile before continuing.")
        sys.exit(2)
    return len(rows)

# ---------------------------------------------------------------- main
def normalise(kind):
    return str(kind).strip().lower()

def classify(entry, man):
    """Decide (role, is_true_by_segment) for one manifest entry, defensively.

    The holdout must not be defeatable by a typo at week seven, so:
      - kinds are normalised before matching, and a holdout kind matches as a substring,
        so "Pinch", "pinch ", "system-pinch" and "pinch-menu" all force the holdout;
      - a kind that is in neither the true nor the confuser list is an ERROR, not a
        silently-assumed confuser, because that is what a misspelling looks like;
      - an unrecognised role is an ERROR unless the entry is force-held-out anyway, in
        which case the safe outcome already happened and there is nothing to warn about.
    """
    true_kinds = {normalise(k) for k in man["true_kinds"]}
    conf_kinds = {normalise(k) for k in man["confuser_kinds"]}
    hold_kinds = [normalise(k) for k in man["holdout_kinds"]]

    segs, forced = [], False
    for raw in entry["segments"]:
        seg = dict(raw)
        kind = normalise(seg.get("kind", ""))
        # Holdout matching runs FIRST and wins. A kind naming a holdout family is
        # self-classifying - it is a confuser and it is held out - so it does not need to
        # be enumerated, and an unlisted "system-pinch" must be caught rather than rejected
        # as a typo. Ordering these the other way round meant the vocabulary check fired
        # first and a pinch-like kind aborted the run instead of being held out.
        if any(h in kind for h in hold_kinds):
            forced = True
            seg["_true"] = False
            segs.append(seg)
            continue
        if kind not in true_kinds and kind not in conf_kinds:
            raise ValueError(
                "unknown segment kind %r in %s - not in true_kinds or confuser_kinds, and "
                "not a holdout kind either. This is what a misspelling looks like, so it "
                "is an error rather than an assumed confuser." % (seg.get("kind"), entry.get("file")))
        seg["_true"] = kind in true_kinds
        segs.append(seg)

    role = entry.get("role")
    if forced:
        return "holdout", segs, True
    if role not in ("search", "holdout"):
        raise ValueError(
            "unrecognised role %r in %s - expected 'search' or 'holdout'. Refusing to "
            "guess, because guessing 'search' is the unsafe direction." % (role, entry.get("file")))
    return role, segs, False

def main():
    manifest_path = sys.argv[1] if len(sys.argv) > 1 else "tools/captures.json"
    man = json.load(open(manifest_path))

    search_set, holdout_set = [], []
    print("CAPTURES")
    for entry in man["captures"]:
        path = entry["file"]
        if not os.path.exists(path):
            print("  MISSING  %s  (skipped)" % path); continue
        rows = load(path)
        hz = len(rows)/(rows[-1]["rel"] or 1)
        n = check_fidelity(rows, path, entry.get("recordedThresholds"))
        role, segs, forced = classify(entry, man)
        bucket = holdout_set if role == "holdout" else search_set
        bucket.append((rows, None, segs, hz))
        print("  %-46s %5d frames %6.1fHz  %-7s%s  fidelity=%s"
              % (os.path.basename(path), len(rows), hz, role,
                 " (FORCED: contains a holdout kind)" if forced else "",
                 "verified" if n else "n/a, no device state"))

    if not search_set:
        print("\nNo search captures. Nothing to do."); return

    print("\nSHIPPED VECTOR")
    report(search_set, holdout_set, SHIPPED)

    print("\nSEARCHING (coordinate descent, multi-restart - a local search, not exhaustive)")
    best, score = search(search_set)
    print("\nBEST VECTOR FOUND")
    for k in ("inward", "towardHead", "extension", "belowHeadY", "sepMin", "sepMax"):
        flag = "" if best[k] == SHIPPED[k] else "   <- changed from %.3f" % SHIPPED[k]
        print("  %-11s %.3f%s" % (k, best[k], flag))
    report(search_set, holdout_set, best)

    fc, conf, tc, tm = unpack(evaluate(search_set, best))
    print("\nVERDICT")
    if fc > 0:
        print("  NOT SEPARABLE: no vector found with zero confuser commits.")
    elif conf < 1.0:
        print("  NOT SEPARABLE AT THE REQUIRED MARGIN: best confuser rejection is %.2f x M"
              % conf)
        print("  (needs >= 1.00). Per CLAUDE.md this is where tuning stops and the")
        print("  contingency is considered - it is not licence to lower M.")
    else:
        print("  Separable at >= 1.00 x M on the search set (worst confuser %.2f x M)." % conf)
        print("  This is a local search over few captures from one person's hands; see the")
        print("  V1 limitation in CLAUDE.md before reading it as more than that.")

def unpack(e):
    """(false commits, raw confuser margin, true commits, raw true margin).

    Components 2 and 4 of the objective are clamped at 1.0 because margin is satisficed,
    not maximised - report the raw values, or every adequate vector looks identical."""
    return -e[0], e[4], e[2], e[5]

def report(search_set, holdout_set, v):
    fc, conf, tc, tm = unpack(evaluate(search_set, v))
    print("  search set : false commits %d | worst confuser rejection %.2f x M | "
          "true commits %d | worst true margin %.2f x M" % (fc, conf, tc, tm))
    if holdout_set:
        h = unpack(evaluate(holdout_set, v))
        print("  HELD OUT   : false commits %d | worst confuser rejection %.2f x M | "
              "true commits %d | worst true margin %.2f x M" % h)
    else:
        print("  HELD OUT   : none yet - the pinch capture does not exist. Until it does,")
        print("               every number above is fitted to the captures it was chosen on.")
    per_segment_report(search_set, v, "search set")
    sweep_report(search_set, v)
    if holdout_set:
        per_segment_report(holdout_set, v, "HELD OUT")
    release_report(search_set + holdout_set, v)

def per_segment_report(dataset, v, label):
    """Per-segment margins. The aggregate min hides whether every true posture clears the
    line comfortably or one of them is scraping it - and with all data from one person,
    variation between their own repetitions is the closest thing we have to a second
    person's hands. It is more informative than the aggregate."""
    print("  per-segment margins (%s):" % label)
    print("    %-22s %14s %8s %9s  %-11s %6s"
          % ("kind", "span", "commits", "margin", "binding gate", "sep"))
    for rows, _, segs, hz in dataset:
        st = replay(rows, v, EXIT)
        for seg in segs:
            if seg.get("discard"):
                continue
            a, b = seg["start"], seg["end"]
            c, gate = closeness(rows, a, b, v, hz, want_gate=True)
            if c is None:
                continue
            fired = commits_in(rows, st, a, b)
            expected_fire = seg["_true"]
            flag = "" if fired == expected_fire else "   <-- WRONG"
            margin = c if seg["_true"] else -c
            print("    %-22s %6.1f-%-7.1f %8s %8.2fx %-11s %5.3fm%s"
                  % (seg["kind"], a, b, "yes" if fired else "no", margin,
                     gate or "-", mean_sep(rows, a, b), flag))

def mean_sep(rows, a, b):
    vals = [x["sep"] for x in rows if a <= x["rel"] <= b]
    return sum(vals)/len(vals) if vals else float("nan")

def sweep_report(dataset, v):
    """True postures ordered by measured separation, so a deliberate sweep along that axis
    reads as a sweep rather than as unlabelled repetitions.

    separation is the gate expected to vary most between people - hand size, arm length,
    how close someone naturally cups - and on the first captures it already bound the two
    tightest duas at roughly half the margin of the three that bound on inward. A narrow
    posture binding near 1.0 x M is a finding about the gate, not about the take.
    """
    entries = []
    for rows, _, segs, hz in dataset:
        st = replay(rows, v, EXIT)
        for seg in segs:
            if seg.get("discard") or not seg["_true"]:
                continue
            a, b = seg["start"], seg["end"]
            c, gate = closeness(rows, a, b, v, hz, want_gate=True)
            if c is None:
                continue
            entries.append((mean_sep(rows, a, b), seg["kind"], a, b, c, gate,
                            commits_in(rows, st, a, b)))
    if not entries:
        return
    entries.sort()
    print("  separation sweep across true postures (ordered by measured separation):")
    print("    %6s  %-16s %8s %9s  %s" % ("sep", "kind", "commits", "margin", "binding gate"))
    for sep, kind, a, b, c, gate, fired in entries:
        near = "   <-- near the line" if c < 1.5 else ""
        print("    %5.3fm  %-16s %8s %8.2fx %-11s%s"
              % (sep, kind, "yes" if fired else "no", c, gate or "-", near))
    span = entries[-1][0] - entries[0][0]
    margins = [e[4] for e in entries]
    print("    spans %.3fm of separation; margin %.2fx to %.2fx; binding gates: %s"
          % (span, min(margins), max(margins), ", ".join(sorted({e[5] for e in entries}))))

def release_report(dataset, v):
    """Release is reported, never optimised - see CLAUDE.md. Exit bounds are not searched."""
    lines = []
    for rows, _, segs, hz in dataset:
        st = replay(rows, v, EXIT)
        for i in range(1, len(st)):
            if st[i] != "held" and st[i-1] == "held":
                t = rows[i]["rel"]
                s = slacks(rows[i], EXIT)
                gate = min(s, key=lambda g: s[g]) if rows[i]["tracked"] else "tracked"
                seg = next((x for x in segs if x["start"] <= t <= x["end"] + 5), None)
                latency = ""
                if seg and "intent_end" in seg:
                    latency = "  latency %+.2fs from intent_end" % (t - seg["intent_end"])
                lines.append("    release at %7.2fs on %-11s%s" % (t, gate, latency))
    if lines:
        print("  releases (reported, not optimised):")
        for l in lines[:12]:
            print(l)

if __name__ == "__main__":
    main()
