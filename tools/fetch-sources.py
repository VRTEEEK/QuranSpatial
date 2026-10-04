#!/usr/bin/env python3
"""tools/fetch-sources.py - download and VERIFY the local source texts the app and AskCore use.

The texts themselves are never in the repository (no licence notice in the files). What is in the
repository is this script, the pinned hashes, and the deletion-only extraction rules. Running it
reproduces, byte for byte, the three local files:

  scratch/1947.json                                   raw Quranpedia book 1947 (Saheeh International)
  scratch/27824.json                                  raw Quranpedia book 27824 (Al-Mukhtasar, English)
  scratch/similar.json(.gz)                           raw Quranpedia similar-ayat dump
  QuranSpatial/Resources/en-rahman-saheeh-1947.json   extracted Surah 55 (gitignored)
  QuranSpatial/Resources/en-rahman-mukhtasar-27824.json (gitignored)

and checks the committed refs-only file QuranSpatial/Resources/related-55-quranpedia-similar.json
against the raw dump. A hash mismatch is a hard failure: the upstream file changed, and the pinned
hashes in the tests must be re-examined by a human, never updated by this script.
"""
import hashlib, json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRATCH = os.path.join(ROOT, "scratch")
RES = os.path.join(ROOT, "QuranSpatial", "Resources")

PINNED = {
    "1947.json": "8c08a8332fae34788f556e5d13a78fe45f68f607cf7a2dabd6596a7fad573978",
    "27824.json": "4790ae49369d80d40c63ed8f197c0d6db909bcee23d63288fb12159cab4eccdc",
    "similar.json": "6716ea2913cfe40626728d969c750f543179cb3cdb92d785219283bb5a5f48b2",
}
TEXT_SHA = {
    "en-rahman-saheeh-1947.json": "c4987b6aa72aaba539fc8d9163a72bdba60cc20f76dcdde1ac85e9e2a5baf90a",
    "en-rahman-mukhtasar-27824.json": "b2d59ffa4409bbb985a910c78046a32de5859a78f2494d812c9e31e1203bc5ad",
    # Pinned 2026-10-04 from the first extraction; see tools/fetch-sources.py extract_1947_footnotes.
    "en-rahman-saheeh-1947-footnotes.json": "82855314515949dcc58467f5ad523afff5eb28f63978ff8661e39846dff10cbd",
}
URLS = {
    "1947.json": "https://quranpedia.net/translation-books/1947.json",
    "27824.json": "https://quranpedia.net/translation-books/27824.json",
    "similar.json.gz": "https://quranpedia.net/dumps/similar.json.gz",
}

def sha256(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()

def fetch(name):
    path = os.path.join(SCRATCH, name)
    if not os.path.exists(path):
        print("downloading", URLS[name])
        subprocess.run(["curl", "-sS", "-L", "-A", "curl/8 QuranSpatial-fetch-sources", "-o", path, URLS[name]], check=True)
    if name.endswith(".gz"):
        plain = path[:-3]
        if not os.path.exists(plain):
            subprocess.run(["gunzip", "-k", "-f", path], check=True)
        return plain
    return path

def verify_raw(path):
    name = os.path.basename(path)
    actual = sha256(path)
    if actual != PINNED[name]:
        sys.exit(f"HASH MISMATCH {name}: pinned {PINNED[name]}, actual {actual}. Upstream changed; stop and re-examine.")
    print(f"ok   {name} raw SHA-256 matches pin")

def surah55(raw_path):
    d = json.load(open(raw_path, encoding="utf-8"))
    return sorted([a for a in d["ayahs"] if a["surah_number"] == 55], key=lambda a: a["ayah_number"])

def extract_1947(raw_path):
    ayat = []
    for a in surah55(raw_path):
        t = a["translated_text"]
        body = t.split("<br />", 1)[0]
        m = re.match(r"^\(%d\) " % a["ayah_number"], body)
        if not m: sys.exit(f"1947 ayah {a['ayah_number']}: prefix does not match")
        body = body[m.end():]
        body = re.sub(r"\[\d+\]", "", body)
        ayat.append({"ayah": a["ayah_number"], "text": body})
    return ayat

def extract_27824(raw_path):
    ayat = []
    for a in surah55(raw_path):
        t = a["translated_text"]
        m = re.match(r"^\d+\. ", t)
        if not m: sys.exit(f"27824 ayah {a['ayah_number']}: no numbering prefix")
        text = t[m.end():]
        if (m.group(0) + text) != t: sys.exit("27824: round-trip failed")
        ayat.append({"ayah": a["ayah_number"], "text": text})
    return ayat

def write_app_file(name, ayat, edition, book, url, raw_sha, rules):
    joined = "\n".join(a["text"] for a in ayat)
    text_sha = hashlib.sha256(joined.encode("utf-8")).hexdigest()
    if TEXT_SHA.get(name) is None:
        print(f"NOTE {name}: no pinned text hash yet; extracted text SHA-256 is {text_sha} - pin it")
    elif text_sha != TEXT_SHA[name]:
        sys.exit(f"TEXT HASH MISMATCH {name}: pinned {TEXT_SHA[name]}, extracted {text_sha}")
    out = {"edition": edition, "sourceBook": book, "sourceURL": url, "rawSHA256": raw_sha,
           "extractionRules": rules, "textSHA256": text_sha, "ayat": ayat}
    path = os.path.join(RES, name)
    if os.path.exists(path):
        existing = json.load(open(path, encoding="utf-8"))
        if existing["textSHA256"] == text_sha and existing["ayat"] == ayat:
            print(f"ok   {name} already present and identical"); return
    json.dump(out, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    open(path, "a", encoding="utf-8").write("\n")
    print(f"wrote {name} (text SHA-256 matches pin)")

def extract_1947_footnotes(raw_path):
    """Deletion-only, by the recorded rules: the footnote block after the first "<br />", minus the
    leading rule line, split on "<br />\n", each note's "[<digits>]- " marker removed. One entry per
    note, in ayah order then note order; several entries may share an ayah."""
    notes = []
    for a in surah55(raw_path):
        parts = a["translated_text"].split("<br />")
        if len(parts) < 2: continue
        block = "<br />".join(parts[1:])
        rule = "\n____________________<br />\n"
        if block.startswith(rule): block = block[len(rule):]
        for note in block.split("<br />\n"):
            note = note.strip("\n")
            if not note: continue
            m = re.match(r"^\[\d+\]- ", note)
            notes.append({"ayah": a["ayah_number"], "text": note[m.end():] if m else note})
    return notes

def check_related(similar_path):
    refs_path = os.path.join(RES, "related-55-quranpedia-similar.json")
    refs = json.load(open(refs_path, encoding="utf-8"))
    if refs["rawSHA256"] != sha256(similar_path):
        sys.exit("related-55-quranpedia-similar.json was derived from a different similar.json")
    d = json.load(open(similar_path, encoding="utf-8"))
    derived = {}
    for e in d["data"]:
        if e["surah"] != 55: continue
        within = set()
        for g in e["similar"]:
            for a in g.get("ayahs", []):
                info = a.get("info", {})
                if info.get("surah_id") == 55 and info.get("number") != e["ayah"]: within.add(info["number"])
        derived[str(e["ayah"])] = sorted(within)
    committed = {k: v["within55"] for k, v in refs["related"].items()}
    if derived != committed: sys.exit("related refs file does not match the raw dump")
    print(f"ok   related-55-quranpedia-similar.json matches the raw dump ({len(derived)} anchors)")

if __name__ == "__main__":
    os.makedirs(SCRATCH, exist_ok=True)
    p1947 = fetch("1947.json"); verify_raw(p1947)
    p27824 = fetch("27824.json"); verify_raw(p27824)
    psim = fetch("similar.json.gz"); verify_raw(psim)
    write_app_file("en-rahman-saheeh-1947.json", extract_1947(p1947), "Saheeh International", 1947, URLS["1947.json"], PINNED["1947.json"], [
        'Split the field at the first "<br />": before it is the ayah text, after it the footnote block.',
        'Remove the leading "(<ayah number>) " prefix; it must match the ayah number exactly.',
        'Remove footnote markers of the form "[<digits>]" from the ayah text. Bracketed words are translator insertions and are kept.',
        'Footnote block: drop the leading "\\n____________________<br />\\n" rule; split the rest on "<br />\\n"; each note is "[<digits>]- <text>".',
        'No other change. No whitespace, punctuation or Unicode normalisation.'])
    write_app_file("en-rahman-mukhtasar-27824.json", extract_27824(p27824), "Al-Mukhtasar fi Tafsir al-Quran (English)", 27824, URLS["27824.json"], PINNED["27824.json"], [
        'Field: "translated_text" of each entry with surah_number 55, taken in ayah_number order. The source has no "<br />", no footnotes and no HTML in this surah.',
        'Remove the leading "<digits>. " prefix (digits, full stop, one space). Nothing else is removed.',
        'The prefix number is NOT required to match the ayah number: the source numbers every refrain ayah (13, 16, 18, 21, 23, 25, 28, 30, 32, 34, 36, 38, 40, 42, 45, 47, 49, 51, 53, 55, 57, 59, 61, 63, 65, 67, 69, 71, 73, 75) as "77." and gives it ayah 77\'s passage verbatim. The 47 other ayat carry their own number. Each extracted text was verified to round-trip to its raw field as prefix + text, byte for byte.',
        'No other change. No whitespace, punctuation or Unicode normalisation.'])
    write_app_file("en-rahman-saheeh-1947-footnotes.json", extract_1947_footnotes(p1947), "Saheeh International (translator's footnotes)", 1947, URLS["1947.json"], PINNED["1947.json"], [
        'Field: "translated_text" of each Surah 55 entry. The footnote block is everything after the first "<br />".',
        'Drop the leading "\\n____________________<br />\\n" rule line; split the rest on "<br />\\n"; one entry per note, in ayah order then note order (several entries may share an ayah).',
        'Remove the leading "[<digits>]- " marker from each note. Nothing else is removed.',
        'No other change. No whitespace, punctuation or Unicode normalisation.'])
    check_related(psim)
    print("all sources present and verified")
