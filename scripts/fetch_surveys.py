#!/usr/bin/env python3
"""Fetch Connect survey markup (.txt questionnaires) from episphere/quest.

Usage:
    python scripts/fetch_surveys.py                  # real Connect surveys -> surveys/
    python scripts/fetch_surveys.py module1          # just module1.txt
    python scripts/fetch_surveys.py --all            # include test/demo/bug fixtures too
    python scripts/fetch_surveys.py --list           # list everything available, download nothing
    python scripts/fetch_surveys.py -o surveys

Output: <output-dir>/<survey>.txt          (default output-dir: surveys)

Defaults (tuned for data-model development): questionnaires/ mixes real instruments with many
test/demo/bug fixtures, and most dictionary surveys aren't published here as standalone files. By
default we fetch only the real Connect MODULES (an allowlist that maps to the dictionary's Secondary
Source column). The four modules map 1:1 to the four baseline sections (module1 = Background and
Overall Health, module2 = Medications/Reproductive/Exercise/Sleep, module3 = Smoking/Alcohol/Sun,
module4 = Where You Live and Work). Only module1.txt is published in quest today; module2-4 are
included automatically if/when added. Use --all to fetch everything, --list to see the full set, or
name specific files to fetch them regardless of the filter.
See docs/source_crosswalk.csv for the dictionary-name <-> table <-> questionnaire-file mapping.

These are Quest markup files — the authoritative source of survey STRUCTURE (question order, skip
logic / displayif, loops, grids) — complementing the data dictionary (concept ids + labels + types).
Set GITHUB_TOKEN to raise the API rate limit (60/hr). Requires: nothing (stdlib only — urllib).
"""
import argparse
import json
import os
import sys
import urllib.request
from pathlib import Path

REPO = "episphere/quest"
PATH = "questionnaires"
REF = "main"
# Real Connect survey instruments — the files that map to the dictionary's Secondary Source column.
# Everything else in questionnaires/ is a test/demo/bug fixture. Default fetch = these that exist.
# The four modules map 1:1 to the four baseline Survey secondary sources:
#   module1 = "Background and Overall Health"
#   module2 = "Medications, Reproductive Health, Exercise, and Sleep"
#   module3 = "Smoking, Alcohol, and Sun Exposure"
#   module4 = "Where You Live and Work"
# As of 2026-06 only module1.txt is published in quest; module2-4 are picked up automatically if/when
# added. Other dictionary surveys (Mouthwash, COVID-19, ...) aren't published here as .txt files.
# See docs/source_crosswalk.csv for the full dictionary-name <-> table <-> questionnaire-file mapping.
REAL_SURVEYS = {"module1", "module2", "module3", "module4"}


def is_real(name):
    return (name[:-4] if name.endswith(".txt") else name) in REAL_SURVEYS


def gh_get(url):
    headers = {"User-Agent": "fetch-surveys", "Accept": "application/vnd.github+json"}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=120) as resp:
        return resp.read()


def list_txt(repo, path, ref):
    url = f"https://api.github.com/repos/{repo}/contents/{path}?ref={ref}"
    items = json.loads(gh_get(url))
    return [it for it in items if it.get("type") == "file" and it["name"].endswith(".txt")]


def main():
    ap = argparse.ArgumentParser(
        description="Fetch Connect survey markup (.txt questionnaires) from episphere/quest.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("surveys", nargs="*",
                    help="specific survey names (e.g. module1 or module1.txt); default: the real surveys")
    ap.add_argument("-o", "--output-dir", default="surveys", help="output directory (default: surveys)")
    ap.add_argument("--all", action="store_true",
                    help="fetch every .txt file, not just the real surveys (includes test/demo fixtures)")
    ap.add_argument("--repo", default=REPO, help=f"GitHub repo (default: {REPO})")
    ap.add_argument("--path", default=PATH, help=f"directory in the repo (default: {PATH})")
    ap.add_argument("--ref", default=REF, help=f"branch/tag/SHA (default: {REF})")
    ap.add_argument("--list", action="store_true", help="list available survey files and exit")
    args = ap.parse_args()

    try:
        files = list_txt(args.repo, args.path, args.ref)
    except Exception as exc:
        sys.exit(f"error: could not list {args.repo}/{args.path}@{args.ref}: {exc}")
    if not files:
        sys.exit(f"no .txt files found in {args.repo}/{args.path}@{args.ref}")

    if args.list:
        for name in sorted(f["name"] for f in files):
            print(f"  {name}" + ("   <- real survey" if is_real(name) else ""))
        n_real = sum(1 for f in files if is_real(f["name"]))
        print(f"({len(files)} files: {n_real} real survey(s) + {len(files) - n_real} other) in {args.repo}/{args.path}")
        return

    if args.surveys:
        # explicit names bypass the real-survey allowlist
        wanted = {s if s.endswith(".txt") else f"{s}.txt" for s in args.surveys}
        present = {f["name"] for f in files}
        for missing in sorted(wanted - present):
            print(f"  ! not found: {missing}", file=sys.stderr)
        files = [f for f in files if f["name"] in wanted]
    elif not args.all:
        # default: real Connect instruments only (the allowlist that maps to dictionary Secondary Source)
        skipped = [f["name"] for f in files if not is_real(f["name"])]
        files = [f for f in files if is_real(f["name"])]
        if skipped:
            print(f"  (fetching real surveys only; skipping {len(skipped)} other files — use --all for everything)")

    if not files:
        sys.exit("error: nothing to fetch — none matched (try --list to see what's available)")

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    written, errors = 0, 0
    for it in sorted(files, key=lambda f: f["name"]):
        try:
            data = gh_get(it["download_url"])
        except Exception as exc:
            errors += 1
            print(f"  ! skip {it['name']}: {exc}", file=sys.stderr)
            continue
        path = out_dir / it["name"]
        path.write_bytes(data)
        print(f"  wrote {path}  ({len(data):,} bytes)")
        written += 1

    print(f"done: {written} survey file(s) under {out_dir}/" + (f"  ({errors} skipped)" if errors else ""))
    sys.exit(1 if errors and not written else 0)


if __name__ == "__main__":
    main()
