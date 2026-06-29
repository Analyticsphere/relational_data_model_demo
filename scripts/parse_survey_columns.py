#!/usr/bin/env python3
"""Parse survey-table column names into (concept_ids, loop_number, version_tag).

Reads the BigQuery schema dumps in schemas/<layer>/ and, for every survey-table column, extracts the
concept-ID path, the loop instance number, and the version tag — using the same logic as the PR2 pipeline.

Usage:
    python scripts/parse_survey_columns.py                       # all survey tables in schemas/FlatConnect -> stdout CSV
    python scripts/parse_survey_columns.py --layer CleanConnect
    python scripts/parse_survey_columns.py module1_v1 mouthwash_v1
    python scripts/parse_survey_columns.py -o survey_columns.csv
    python scripts/parse_survey_columns.py --all-columns         # include non-concept columns (Connect_ID, token, ...)

Output (CSV): layer, table, column, n_concepts, concept_ids, loop_number, version_tag, nonconforming_tokens
    - concept_ids        : ordered 9-digit IDs, ';'-joined (the d_<parent>_d_<concept>... path)
    - loop_number        : the _N loop instance, or blank
    - version_tag        : the concept revision tag, e.g. _v2, or blank
    - nonconforming_tokens: tokens that aren't D / a digit / a 9-digit CID / vN (SAS mnemonics needing
                            an exception map — see pr2-transformation core/variable_normalizer.py)

Defaults (tuned for this repo): layer FlatConnect (what PR2 parses; D_X_D_Y_vN naming), survey tables
only (skips participants + biospecimen), and only columns that contain a concept ID (use --all-columns
to include the rest). Reads schemas/ locally — run scripts/fetch_bq_schemas.py first to refresh them.

Parsing helpers below are adapted verbatim from Analyticsphere/pr2-transformation
(core/utils.py, core/variable_normalizer.py) so this matches the production transform. Stdlib only.
"""
import argparse
import csv
import json
import re
import sys
from pathlib import Path

NON_SURVEY = {"participants", "biospecimen"}  # present in the survey datasets but not surveys (see docs/source_crosswalk.csv)

# ── parsing helpers (adapted from Analyticsphere/pr2-transformation core/utils.py) ──────────────
def extract_ordered_concept_ids(var: str) -> list:
    """9-digit concept IDs in order of appearance (the d_<parent>_d_<concept>... path)."""
    return re.compile(r"[dD]_(\d{9})").findall(var)


def extract_version_suffix(var_name: str) -> str:
    """Version tag like _v2 / _v3 anywhere in the name; '' if none."""
    m = re.search(r"_[vV](\d+)(?=_|$)", var_name)
    return f"_v{m.group(1)}" if m else ""


def excise_version_from_column_name(column_name: str) -> str:
    """Remove the _vN version tag (any position)."""
    return re.sub(r"_[vV]\d+(?=_|$)", "", column_name)


def extract_loop_number(var_name: str):
    """FlatConnect convention: doubled _N_N (PR2's extract_loop_number). None if not looped."""
    m = re.search(r"_v\d+_(\d+)_\1(?!\d)", var_name, re.IGNORECASE)
    if m:
        return int(m.group(1))
    cleaned = excise_version_from_column_name(var_name)
    matches = re.findall(r"_(\d+)_\1(?!\d)", cleaned)
    if matches:
        return int(matches[0])
    if re.search(r"_(\d+)_\1", cleaned):
        m = re.search(r"_(\d+)$", cleaned)
        if m:
            return int(m.group(1))
    return None


def extract_loop_number_clean(var_name: str):
    """CleanConnect convention: a single trailing _N (1-2 digit) after the concept path = loop instance.
    CleanConnect drops FlatConnect's doubled _N_N; concepts are 9-digit, so a trailing small int is the loop."""
    cleaned = excise_version_from_column_name(var_name)
    m = re.search(r"_(\d{1,2})$", cleaned)
    return int(m.group(1)) if m else None


def nonconforming_tokens(var: str) -> list:
    """Tokens that aren't 'D', a single digit, a 9-digit CID, or vN — i.e. SAS mnemonics that PR2's
    exception_map would map to a concept ID (see core/variable_normalizer.fix_all_variables)."""
    bad = []
    for tok in var.split("_"):
        t = tok.strip()
        if not t or t.upper() == "D":
            continue
        if t.isdigit() and len(t) in (1, 9):
            continue
        if re.fullmatch(r"[vV]\d+", t):
            continue
        bad.append(t)
    return bad


# ── schema reading ──────────────────────────────────────────────────────────────────────────────
def field_names(fields, prefix=""):
    """All column names from a BigQuery schema list (recurses RECORDs, joining with '_')."""
    out = []
    for f in fields:
        name = prefix + f["name"]
        if f.get("fields"):
            out += field_names(f["fields"], name + "_")
        else:
            out.append(name)
    return out


def main():
    ap = argparse.ArgumentParser(
        description="Parse survey-table column names into concept_ids / loop_number / version_tag.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("tables", nargs="*", help="specific table names (schema file stems); default: all survey tables in the layer")
    ap.add_argument("--layer", default="FlatConnect", help="schemas/<layer> to read (default: FlatConnect)")
    ap.add_argument("--schemas-dir", default="schemas", help="base schemas directory (default: schemas)")
    ap.add_argument("-o", "--output", default=None, help="write CSV here (default: stdout)")
    ap.add_argument("--all-columns", action="store_true", help="include columns with no concept ID (Connect_ID, token, ...)")
    ap.add_argument("--loop-style", choices=["auto", "flat", "clean"], default="auto",
                    help="loop-suffix convention: flat = FlatConnect _N_N (PR2); clean = CleanConnect single _N; "
                         "auto = clean for the CleanConnect layer, flat otherwise (default: auto)")
    args = ap.parse_args()

    style = args.loop_style
    if style == "auto":
        style = "clean" if args.layer.lower() == "cleanconnect" else "flat"
    loop_fn = extract_loop_number_clean if style == "clean" else extract_loop_number

    layer_dir = Path(args.schemas_dir) / args.layer
    if not layer_dir.is_dir():
        sys.exit(f"error: {layer_dir} not found (run scripts/fetch_bq_schemas.py {args.layer} first)")

    if args.tables:
        wanted = {t[:-5] if t.endswith(".json") else t for t in args.tables}
        files = [layer_dir / f"{t}.json" for t in sorted(wanted)]
        for f in files:
            if not f.exists():
                print(f"  ! not found: {f}", file=sys.stderr)
        files = [f for f in files if f.exists()]
    else:
        files = sorted(f for f in layer_dir.glob("*.json") if f.stem not in NON_SURVEY)
    if not files:
        sys.exit("error: no schema files to parse (try --layer or name tables; --list via fetch script)")

    out_fh = open(args.output, "w", newline="") if args.output else sys.stdout
    writer = csv.writer(out_fh)
    writer.writerow(["layer", "table", "column", "n_concepts", "concept_ids", "loop_number", "version_tag", "nonconforming_tokens"])

    n_cols = n_rows = n_skipped = 0
    for f in files:
        schema = json.loads(f.read_text())
        for col in field_names(schema):
            n_cols += 1
            cids = extract_ordered_concept_ids(col)
            if not cids and not args.all_columns:
                n_skipped += 1
                continue
            loop = loop_fn(col)
            writer.writerow([
                args.layer, f.stem, col, len(cids), ";".join(cids),
                "" if loop is None else loop,
                extract_version_suffix(col),
                ";".join(nonconforming_tokens(col)),
            ])
            n_rows += 1

    if args.output:
        out_fh.close()
    print(f"parsed {len(files)} table(s), {n_cols} columns -> {n_rows} rows"
          + (f" ({n_skipped} non-concept columns skipped; --all-columns to include)" if n_skipped else "")
          + (f" -> {args.output}" if args.output else ""), file=sys.stderr)


if __name__ == "__main__":
    main()
