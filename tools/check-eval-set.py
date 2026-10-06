#!/usr/bin/env python3
"""tools/check-eval-set.py - deterministic shape checks for an evaluation set, as heldout-2-procedure.md
requires. Never looks at the questions' content beyond these checks; never edits them.

  python3 tools/check-eval-set.py tests/eval/general-dev.json [--expect general-dev|annex12|heldout-2]

Checks: counts per category (or route), distinct anchors, every acceptableCards id exists in
ask-cards.json, the decision mapping (route -> allowed decisions), ZERO 5-gram overlap between any
question and the local source texts (en-*.json passages, Jamhara entries, cited ayat - read locally,
never printed), and no Arabic script in any question (annex12's Arabic header field is exempt).
Exit 1 on any failure."""
import glob, json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "QuranSpatial", "Resources")
ARABIC = re.compile(r"[؀-ۿݐ-ݿࢠ-ࣿﭐ-﷿ﹰ-﻿]")
ALLOWED = {"meaning": {"answered"}, "word": {"answered"}, "unclear": {"answered"}, "repetition": {"answered-in-part"},
           "related": {"answered", "answered-in-part"}, "ruling": {"referred"}, "off-topic": {"declined"},
           "general": {"answered", "not-covered", "referred"}}

def words(s): return re.findall(r"[a-z0-9']+", s.lower())
def grams(ws, n=5): return {tuple(ws[i:i + n]) for i in range(len(ws) - n + 1)}

def source_grams():
    g = set()
    for path in glob.glob(os.path.join(RES, "en-*.json")):
        d = json.load(open(path, encoding="utf-8"))
        texts = []
        if "ayat" in d: texts += [a["text"] for a in d["ayat"]]
        if "entries" in d: texts += [e["title"] + " " + e["definition"] + " " + e["explanation"] for e in d["entries"]]
        for t in texts: g |= grams(words(t))
    return g

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    expect = next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--expect=")), None)
    if not args: sys.exit(__doc__)
    path = args[0]
    d = json.load(open(path, encoding="utf-8"))
    qs = d["questions"]
    cards = {c["id"] for c in json.load(open(os.path.join(RES, "ask-cards.json"), encoding="utf-8"))["cards"]}
    fails = []
    def check(ok, msg):
        print(("  ok    " if ok else "  FAIL  ") + msg)
        if not ok: fails.append(msg)
    # ids and anchors
    ids = [q["id"] for q in qs]
    check(len(ids) == len(set(ids)), f"{len(ids)} items, ids unique")
    anchors = {q["ayah"] for q in qs}
    check(all(1 <= q["ayah"] <= 78 for q in qs), "anchors within 1..78")
    print(f"        distinct anchors: {len(anchors)}")
    # categories
    cats = {}
    for q in qs:
        key = q.get("category") or q.get("expectedRoute") or "/".join(q.get("acceptableRoutes", []))
        cats[key] = cats.get(key, 0) + 1
    print("        per category:", dict(sorted(cats.items())))
    # cards and decisions
    for q in qs:
        for c in q.get("acceptableCards", []): check(c in cards, f"{q['id']}: card id {c} exists")
        routes = [q["expectedRoute"]] if "expectedRoute" in q else q.get("acceptableRoutes", [])
        decs = set(q.get("acceptableDecisions", [])) or ({q["expectedDecision"]} if "expectedDecision" in q else set())
        allowed = set().union(*(ALLOWED.get(r, set()) for r in routes))
        check(bool(decs) and decs <= allowed, f"{q['id']}: decisions {sorted(decs)} allowed for routes {routes}")
        if "general" in routes and "answered" in decs and "not-covered" not in decs:
            check(bool(q.get("acceptableCards")), f"{q['id']}: an answered general item names its card(s)")
    # Arabic script: questions only (annex12's header is exempt)
    for q in qs: check(not ARABIC.search(q["question"]), f"{q['id']}: no Arabic script")
    # 5-gram overlap with the local source texts
    sg = source_grams()
    if not sg: print("  note  no local source texts found; overlap check skipped")
    for q in qs:
        ov = grams(words(q["question"])) & sg
        if ov and q.get("quoteOverlapAllowed"):
            # Only annex row 11 (a deliberate misquote of the verse on screen) may quote the translation.
            print(f"  note  {q['id']}: {len(ov)} overlapping 5-grams allowed - {q['quoteOverlapAllowed']}"); continue
        check(not ov, f"{q['id']}: zero 5-gram overlap with source texts" + (f" ({len(ov)} overlapping)" if ov else ""))
    # expected shapes
    if expect == "general-dev":
        check(len(qs) == 40, "40 items")
        check(cats.get("covered") == 22 and cats.get("uncovered") == 8 and cats.get("personal") == 4 and cats.get("hadith-or-qualified") == 3 and cats.get("trap") == 3, "22/8/4/3/3 shape")
        check(len(anchors) >= 25, "at least 25 distinct anchors")
        covered = [q for q in qs if q.get("category") == "covered"]
        counts = {}
        for q in covered:
            for c in q["acceptableCards"]: counts[c] = counts.get(c, 0) + 1
        for g in [c for c in cards if c.startswith("general-")] + ["gap-quran-authorship"]:
            check(counts.get(g, 0) >= 2, f"{g} acceptable on at least two covered items ({counts.get(g, 0)})")
        check(len({c for c in counts if c.startswith("term-")}) >= 8, f"at least 8 distinct term cards ({len({c for c in counts if c.startswith('term-')})})")
    if expect == "annex12":
        check(len(qs) == 24, "24 items")
        rows = {}
        for q in qs: rows[q["annexRow"]] = rows.get(q["annexRow"], 0) + 1
        check(all(rows.get(r) == 2 for r in range(1, 13)), "each annex row twice (a01-a12 and a13-a24)")
    if expect == "heldout-2":
        check(len(qs) == 60, "60 items")
        ayah_items = [q for q in qs if "expectedDecision" in q]; general_items = [q for q in qs if "category" in q]
        check(len(ayah_items) == 50 and len(general_items) == 10, f"50 ayah items + 10 general items ({len(ayah_items)} + {len(general_items)})")
        rc = {}
        for q in ayah_items: rc[q["expectedRoute"]] = rc.get(q["expectedRoute"], 0) + 1
        want = {"meaning": 14, "word": 7, "repetition": 6, "related": 5, "ruling": 7, "off-topic": 7, "unclear": 4}
        check(rc == want, f"ayah routes {rc} == {want}")
        rel = [q for q in ayah_items if q["expectedRoute"] == "related"]
        check(sum(1 for q in rel if q["ayah"] in (11, 52, 68)) == 2, "two related items on ayah 11/52/68, three elsewhere")
        for q in ayah_items:
            exp = {"meaning": "answered", "word": "answered", "unclear": "answered", "repetition": "answered-in-part", "ruling": "referred", "off-topic": "declined"}.get(q["expectedRoute"])
            if q["expectedRoute"] == "related": exp = "answered" if q["ayah"] in (11, 52, 68) else "answered-in-part"
            check(q["expectedDecision"] == exp, f"{q['id']}: expectedDecision {q['expectedDecision']} matches the mapping ({exp})")
        gc = {}
        for q in general_items: gc[q["category"]] = gc.get(q["category"], 0) + 1
        check(gc == {"covered": 5, "uncovered": 2, "personal": 2, "trap": 1}, f"general categories {gc} == 5/2/2/1")
        check(len(anchors) >= 30, f"at least 30 distinct anchors ({len(anchors)})")
        refrain = {13, 16, 18, 21, 23, 25, 28, 30, 32, 34, 36, 38, 40, 42, 45, 47, 49, 51, 53, 55, 57, 59, 61, 63, 65, 67, 69, 71, 73, 75, 77}
        check(len(anchors & refrain) >= 10, f"at least ten refrain ayat among the anchors ({len(anchors & refrain)})")
        check([q["id"] for q in qs] == [f"k{i:02d}" for i in range(1, 61)], "ids k01-k60 in order")
    print("\n%d failed" % len(fails) if fails else "\nall checks pass")
    sys.exit(1 if fails else 0)

if __name__ == "__main__":
    main()
