#!/usr/bin/env python3
"""Guards on the threshold search's manifest handling.

The holdout is structural so that it cannot be defeated by a typo at week seven. These
assert that it actually cannot. Run: python3 tools/test_manifest_guards.py
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from threshold_search import classify

MAN = dict(true_kinds=["dua"],
           confuser_kinds=["pinch", "lap-rest", "face-wipe"],
           holdout_kinds=["pinch"])

def entry(role, kinds, file="x.json"):
    e = {"file": file, "segments": [{"kind": k, "start": 0, "end": 1} for k in kinds]}
    if role is not None:
        e["role"] = role
    return e

failures = []
def check(name, fn):
    try:
        fn(); print("  ok    %s" % name)
    except AssertionError as e:
        failures.append(name); print("  FAIL  %s: %s" % (name, e))

def held(e):
    role, _, forced = classify(e, MAN)
    assert role == "holdout", "landed in %r, not holdout" % role
    return forced

def raises(e):
    try:
        classify(e, MAN)
    except ValueError:
        return
    raise AssertionError("accepted a manifest it should have rejected")

check("role 'search' cannot pull a pinch capture into the search set",
      lambda: held(entry("search", ["dua", "pinch"])))
check("role 'training' (not a real role) still yields holdout when pinch is present",
      lambda: held(entry("training", ["pinch"])))
check("missing role field still yields holdout when pinch is present",
      lambda: held(entry(None, ["pinch"])))
check("capitalised kind 'Pinch' still forces holdout",
      lambda: held(entry("search", ["Pinch"])))
check("trailing whitespace 'pinch ' still forces holdout",
      lambda: held(entry("search", ["pinch "])))
check("compound kind 'system-pinch' still forces holdout",
      lambda: held(entry("search", ["system-pinch"])))
check("a misspelled kind is an error, not a silent confuser",
      lambda: raises(entry("search", ["pnich"])))
check("an unknown kind is an error even alongside valid ones",
      lambda: raises(entry("search", ["dua", "lap_rest"])))
check("an unrecognised role is an error when nothing forces holdout",
      lambda: raises(entry("training", ["dua", "lap-rest"])))
check("a missing role is an error when nothing forces holdout",
      lambda: raises(entry(None, ["dua"])))

def ordinary():
    role, segs, forced = classify(entry("search", ["dua", "lap-rest"]), MAN)
    assert role == "search" and not forced, "ordinary entry misclassified"
    assert [s["_true"] for s in segs] == [True, False], "true/confuser labelling wrong"
check("an ordinary well-formed entry still works", ordinary)

print("\n%d failed" % len(failures) if failures else "\nall guards hold")
sys.exit(1 if failures else 0)
