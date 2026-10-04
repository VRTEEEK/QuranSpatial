#!/bin/bash
# tools/sync-public.sh - mirror the private repo's HEAD into the public repository.
#
# Copies every file tracked at HEAD EXCEPT the never-public list into the public checkout
# (default ~/src/QuranSpatial-baseline-public), commits there with the same message as the
# private HEAD commit, and pushes. Aborts, before anything is copied into the public checkout,
# if an excluded file would be copied or if any file contains a passage of the local translation
# or tafsir texts. Run it after each green feature so the public history shows the work as it
# was done, with real timestamps.
#
# Never-public list (see docs/baseline-disclosure.md):
#   QuranSpatial/Resources/rahman-single.mp3     recitation audio, licence unresolved
#   *.usdz, *.usdc                               environment assets, provenance not recorded
#   en-*.json                                    translation / tafsir text, no licence notice
#   scratch/                                     raw downloads and unlicensed material
#   capture/*.json                               the author's hand-tracking data
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
DST="${QS_PUBLIC_DIR:-$HOME/src/QuranSpatial-baseline-public}"
EXCLUDE_RE='^(QuranSpatial/Resources/rahman-single\.mp3$|.*\.(usdz|usdc)$|(.*/)?en-[^/]*\.json$|scratch/|capture/.*\.json$)'

cd "$SRC"
# The export is taken from HEAD, so untracked files cannot leak; modified tracked files mean
# HEAD is not what the author is looking at, so they block the sync.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "abort: tracked files are modified; commit first" >&2; exit 1
fi
[ -d "$DST/.git" ] || { echo "abort: $DST is not a git checkout" >&2; exit 1; }

HEAD_HASH=$(git rev-parse HEAD)
MSG="$(git log -1 --pretty=%B)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# 1. Export HEAD, then drop the never-public files from the export.
git archive HEAD | tar -x -C "$STAGE"
( cd "$STAGE" && find . -type f | sed 's#^\./##' | grep -E "$EXCLUDE_RE" | while read -r f; do rm -f "$f"; done
  find . -type d -empty -delete )

# 2. Independent check: nothing matching the list may remain in the export.
LEFT=$( cd "$STAGE" && find . -type f | sed 's#^\./##' | grep -E "$EXCLUDE_RE" || true )
if [ -n "$LEFT" ]; then echo "abort: excluded file(s) in the export:" >&2; echo "$LEFT" >&2; exit 1; fi

# 3. Passage check: no file in the export may contain any ayah text, footnote or tafsir
#    passage from the local source files. Needs the local files to build the needles; if they
#    are absent the check cannot run, so the sync aborts rather than guessing.
python3 - "$SRC" "$STAGE" <<'PY'
import glob, json, os, re, sys
src, stage = sys.argv[1], sys.argv[2]
needles = []
files = glob.glob(os.path.join(src, "QuranSpatial", "Resources", "en-*.json"))
if not files:
    print("abort: no local en-*.json files to build the passage check from", file=sys.stderr); sys.exit(1)
for path in files:
    for a in json.load(open(path, encoding="utf-8"))["ayat"]:
        t = a["text"]; needles.append(t)
        if len(t) > 40: needles += [t[:25], t[len(t)//2:len(t)//2+25]]
raw = os.path.join(src, "scratch", "1947.json")
if os.path.exists(raw):
    for a in json.load(open(raw, encoding="utf-8"))["ayahs"]:
        if a["surah_number"] == 55:
            for m in re.finditer(r"\[\d+\]- (.+)", a["translated_text"]):
                needles.append(m.group(1).strip())
hits = []
for root, _, names in os.walk(stage):
    for n in names:
        p = os.path.join(root, n)
        try: data = open(p, "rb").read().decode("utf-8")
        except Exception: continue
        for nd in needles:
            if nd and nd in data: hits.append((os.path.relpath(p, stage), nd[:40])); break
if hits:
    print("abort: translation/tafsir passage text found in the export:", file=sys.stderr)
    for h in hits: print("  ", h, file=sys.stderr)
    sys.exit(1)
print("passage check: %d needles, 0 hits" % len(needles))
PY

# 4. Mirror into the public checkout (deleting what is no longer tracked), commit, push.
rsync -a --delete --exclude '.git' "$STAGE/" "$DST/"
cd "$DST"
git add -A
if git diff --cached --quiet; then echo "public checkout already matches $HEAD_HASH; nothing to commit"; exit 0; fi
git commit -q -m "$MSG"
git push -q origin HEAD
echo "synced private $HEAD_HASH -> public $(git rev-parse HEAD) at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
