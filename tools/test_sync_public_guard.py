#!/usr/bin/env python3
"""Guard test for tools/sync-public.sh: the sync must ABORT, before exporting anything, when a
never-tracked source-text file is staged or committed. Builds a throwaway git repository, copies the
script in, stages (then commits) each file name, runs the script and expects exit 1 naming the file.
Also checks the export pattern still matches them. Run: python3 tools/test_sync_public_guard.py"""
import os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "sync-public.sh")
NAMES = ["QuranSpatial/Resources/en-jamhara-terms.json", "QuranSpatial/Resources/en-saheeh-1947-cited.json",
         "QuranSpatial/Resources/en-dorar-55-overall.json", "tests/eval/day5/leads-audit-passages.csv", "tests/eval/heldout-2-prompt-full.md"]
failures = []
def check(name, fn):
    try: fn(); print("  ok    %s" % name)
    except AssertionError as e: failures.append(name); print("  FAIL  %s: %s" % (name, e))

src = open(SCRIPT).read()
exclude = re.search(r"^EXCLUDE_RE='(.*)'$", src, re.M).group(1)
never = re.search(r"^NEVER_TRACKED_RE='(.*)'$", src, re.M).group(1)
for n in NAMES:
    check("%s is in the export exclude pattern" % n, lambda n=n: (_ for _ in ()).throw(AssertionError("no match")) if not re.search(exclude, n) else None)
    check("%s is in the never-tracked pattern" % n, lambda n=n: (_ for _ in ()).throw(AssertionError("no match")) if not re.search(never, n) else None)

def run(cwd, *args, env=None):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True, env=env)

def repo_with(name, commit):
    d = tempfile.mkdtemp(prefix="sync-guard-")
    run(d, "git", "init", "-q"); run(d, "git", "config", "user.email", "t@t"); run(d, "git", "config", "user.name", "t")
    os.makedirs(os.path.join(d, "tools")); shutil.copy(SCRIPT, os.path.join(d, "tools", "sync-public.sh"))
    open(os.path.join(d, "README.md"), "w").write("x\n")
    run(d, "git", "add", "-A"); run(d, "git", "commit", "-q", "-m", "base")
    os.makedirs(os.path.dirname(os.path.join(d, name)), exist_ok=True)
    open(os.path.join(d, name), "w").write('{"ayat":[]}\n')
    run(d, "git", "add", "-f", name)
    if commit: run(d, "git", "commit", "-q", "-m", "oops")
    pub = tempfile.mkdtemp(prefix="sync-guard-pub-"); run(pub, "git", "init", "-q")
    return d, pub

def aborts(name, commit):
    d, pub = repo_with(name, commit)
    env = dict(os.environ, QS_PUBLIC_DIR=pub)
    r = run(d, "bash", os.path.join(d, "tools", "sync-public.sh"), env=env)
    shutil.rmtree(d); shutil.rmtree(pub)
    assert r.returncode == 1, "exit %d, stderr: %s" % (r.returncode, r.stderr)
    assert "abort" in r.stderr and name in r.stderr, "did not name the file: %s" % r.stderr
    assert "synced" not in r.stdout, "exported something"

for n in NAMES:
    check("sync aborts when %s is STAGED" % n, lambda n=n: aborts(n, commit=False))
    check("sync aborts when %s is COMMITTED" % n, lambda n=n: aborts(n, commit=True))

print("\n%d failed" % len(failures) if failures else "\nall guards hold")
sys.exit(1 if failures else 0)
