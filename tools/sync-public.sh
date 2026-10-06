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
#     (en-jamhara-terms.json, en-saheeh-1947-cited.json, en-dorar-55-overall.json named explicitly:
#      the Ask cards' local sources, day 4)
#   scratch/                                     raw downloads and unlicensed material
#   capture/*.json                               the author's hand-tracking data
#   QuranSpatial/Resources/background.m4a        immersive ambience loop, source not recorded
#                                                (metadata: iMovie export, "My Movie 24")
#   QuranSpatial/Resources/logo_sound.wav        launch chime, source not recorded
#   tests/eval/day5/results-*.json, leads-audit.csv, heldout-2-prompt.md, annex12-paraphrase-prompt.md
#                                                day-5 eval transcripts and prompts: the model's answers and
#                                                the prompts quote the local translation / tafsir texts
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
DST="${QS_PUBLIC_DIR:-$HOME/src/QuranSpatial-baseline-public}"
EXCLUDE_RE='^(QuranSpatial/Resources/rahman-single\.mp3$|QuranSpatial/Resources/background\.m4a$|QuranSpatial/Resources/logo_sound\.wav$|.*\.(usdz|usdc)$|(.*/)?en-[^/]*\.json$|scratch/|capture/.*\.json$|tests/eval/day5/leads-audit-passages\.csv$|tests/eval/heldout-2-prompt-full\.md$|tests/eval/day5/results-[^/]*\.json$|tests/eval/day5/leads-audit\.csv$|tests/eval/heldout-2-prompt\.md$|tests/eval/annex12-paraphrase-prompt\.md$)'
# Never-TRACKED list: unlike the audio and environment assets, which are tracked privately and merely
# dropped from the export, these may not be in the index or at HEAD at all. If one is staged or
# committed the sync ABORTS before anything is exported. tools/test_sync_public_guard.py tests this.
NEVER_TRACKED_RE='^((.*/)?en-[^/]*\.json|QuranSpatial/Resources/en-jamhara-terms\.json|QuranSpatial/Resources/en-saheeh-1947-cited\.json|QuranSpatial/Resources/en-dorar-55-overall\.json|tests/eval/day5/leads-audit-passages\.csv|tests/eval/heldout-2-prompt-full\.md)$'

cd "$SRC"
# Never-tracked source text: checked FIRST, so the abort names the file whether it is staged or at HEAD.
TRACKED=$( (git ls-files --cached; git ls-tree -r --name-only HEAD) | sort -u | grep -E "$NEVER_TRACKED_RE" || true )
if [ -n "$TRACKED" ]; then
  echo "abort: never-tracked source text is staged or committed:" >&2; echo "$TRACKED" >&2; exit 1
fi
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
def add(t):
    t = (t or "").strip()
    if not t: return
    needles.append(t)
    if len(t) > 40: needles.extend([t[:25], t[len(t)//2:len(t)//2+25]])
for path in files:
    d = json.load(open(path, encoding="utf-8"))
    # Two schemas: translation/tafsir files carry ayat[].text; the Jamhara terms file
    # (day 4) carries entries[].definition / .explanation. Both are passage text.
    if "ayat" in d:
        for a in d["ayat"]: add(a["text"])
    elif "entries" in d:
        for e in d["entries"]:
            add(e.get("definition")); add(e.get("explanation"))
    else:
        print("abort: %s has neither 'ayat' nor 'entries'; passage check cannot run" % path, file=sys.stderr); sys.exit(1)
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
