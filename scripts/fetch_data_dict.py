#!/usr/bin/env python3
"""Fetch the Connect data dictionary (masterFile.csv) from episphere/conceptGithubActions.

Usage:
    python scripts/fetch_data_dict.py              # -> data_dictionary/masterFile.csv
    python scripts/fetch_data_dict.py --json       # also data_dictionary/masterFile.json (row records)
    python scripts/fetch_data_dict.py -o some/dir

Output: <output-dir>/masterFile.csv  (+ masterFile.json with --json)   (default output-dir: data_dictionary)

Defaults (tuned for this repo): saved under data_dictionary/ as CSV, byte-for-byte as fetched
(faithful provenance). This is the canonical source of truth — the denormalized "Variable
Dictionary" that CIDTool normalizes into the concept tables.

Source: https://raw.githubusercontent.com/episphere/conceptGithubActions/master/csv/masterFile.csv
Note: the header has FIVE columns named "conceptId" (the 5-level hierarchy: primary / secondary /
      source-question / question / response). --json disambiguates them as conceptId, conceptId_2,
      ... in column order so none are lost.
Requires: nothing (stdlib only — urllib + csv).
"""
import argparse
import csv
import io
import json
import sys
import urllib.request
from pathlib import Path

DEFAULT_URL = "https://raw.githubusercontent.com/episphere/conceptGithubActions/master/csv/masterFile.csv"


def dedupe_headers(header):
    """Make duplicate column names unique (e.g. the 5 'conceptId' columns) by index order."""
    seen, out = {}, []
    for name in header:
        name = name or "column"
        if name in seen:
            seen[name] += 1
            out.append(f"{name}_{seen[name]}")
        else:
            seen[name] = 1
            out.append(name)
    return out


def main():
    ap = argparse.ArgumentParser(
        description="Fetch the Connect data dictionary (masterFile.csv) as CSV (and optionally JSON).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("-o", "--output-dir", default="data_dictionary", help="output directory (default: data_dictionary)")
    ap.add_argument("--filename", default="masterFile.csv", help="CSV filename (default: masterFile.csv)")
    ap.add_argument("--url", default=DEFAULT_URL, help="source URL (default: the canonical raw masterFile.csv)")
    ap.add_argument("--json", action="store_true", help="also write a JSON file (list of row objects) alongside the CSV")
    args = ap.parse_args()

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    csv_path = out_dir / args.filename

    try:
        req = urllib.request.Request(args.url, headers={"User-Agent": "fetch-connect-data-dictionary"})
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = resp.read()
    except Exception as exc:
        sys.exit(f"error: download failed for {args.url}\n  {exc}")

    csv_path.write_bytes(data)  # byte-for-byte copy of the upstream CSV
    rows = list(csv.reader(io.StringIO(data.decode("utf-8", errors="replace"))))
    n_rows = max(0, len(rows) - 1)
    n_cols = len(rows[0]) if rows else 0
    print(f"wrote {csv_path}  ({n_rows} rows x {n_cols} columns, {len(data):,} bytes)")

    if args.json:
        if not rows:
            sys.exit("error: CSV appears empty; cannot build JSON")
        header = dedupe_headers(rows[0])
        records = [dict(zip(header, r)) for r in rows[1:]]
        json_path = csv_path.with_suffix(".json")
        json_path.write_text(json.dumps(records, indent=2, ensure_ascii=False) + "\n")
        print(f"wrote {json_path}  ({len(records)} records)")


if __name__ == "__main__":
    main()
