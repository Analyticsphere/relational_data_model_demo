#!/usr/bin/env python3
"""Fetch BigQuery table schemas into per-dataset folders, as JSON or CSV.

Usage:
    python scripts/fetch_bq_schemas.py DATASET                  # every table in the dataset
    python scripts/fetch_bq_schemas.py DATASET.TABLE            # one table
    python scripts/fetch_bq_schemas.py PROJECT.DATASET.TABLE    # one table, explicit project
    python scripts/fetch_bq_schemas.py CleanConnect --format csv
    # refresh all three Connect layers:
    for d in Connect FlatConnect CleanConnect; do python scripts/fetch_bq_schemas.py $d; done

Output: <output-dir>/<dataset>/<table>.<json|csv>      (default output-dir: schemas)
    - JSON: the standard BigQuery schema array, identical to `bq show --schema --format=prettyjson`.
    - CSV : one row per column (nested RECORD/STRUCT fields flattened with dotted names).

Defaults (tuned for this repo): output under schemas/<dataset>/ (matches the existing layout),
JSON format, and --project defaults to the Connect prod project (override with --project).

TARGET grammar (project for the 1- and 2-part forms comes from --project / the client default):
    DATASET  ->  every table       DATASET.TABLE  ->  one table       PROJECT.DATASET.TABLE  ->  one table
(To pull a whole dataset under a specific project, pass the dataset name alone with --project.)

Auth: Application Default Credentials — `gcloud auth application-default login`
      (or set GOOGLE_APPLICATION_CREDENTIALS to a service-account key).
Requires: pip install google-cloud-bigquery
"""
import argparse
import csv
import json
import sys
from pathlib import Path

# Connect's production project (the source of the survey/biospecimen datasets). Override with --project.
DEFAULT_PROJECT = "nih-nci-dceg-connect-prod-6d04"


def parse_target(target, default_project):
    """Return (project, dataset, table-or-None) from a 1/2/3-part dotted reference."""
    parts = target.split(".")
    if len(parts) == 1:
        return default_project, parts[0], None          # DATASET (all tables)
    if len(parts) == 2:
        return default_project, parts[0], parts[1]       # DATASET.TABLE
    if len(parts) == 3:
        return parts[0], parts[1], parts[2]              # PROJECT.DATASET.TABLE
    raise ValueError(
        f"cannot parse target {target!r}; expected DATASET, DATASET.TABLE, or PROJECT.DATASET.TABLE"
    )


def flatten_schema(fields, prefix=""):
    """Flatten a (possibly nested) schema into rows for CSV output."""
    rows = []
    for f in fields:
        name = f"{prefix}{f.name}"
        rows.append(
            {
                "column": name,
                "type": f.field_type,
                "mode": f.mode or "NULLABLE",
                "description": (f.description or "").replace("\n", " ").strip(),
            }
        )
        if f.field_type in ("RECORD", "STRUCT") and f.fields:
            rows.extend(flatten_schema(f.fields, prefix=f"{name}."))
    return rows


def write_json(table, path):
    schema = [field.to_api_repr() for field in table.schema]
    path.write_text(json.dumps(schema, indent=2) + "\n")


def write_csv(table, path):
    rows = flatten_schema(table.schema)
    with path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=["column", "type", "mode", "description"])
        writer.writeheader()
        writer.writerows(rows)


def main():
    ap = argparse.ArgumentParser(
        description="Fetch BigQuery table schemas into per-dataset folders (JSON or CSV).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("target", help="DATASET | DATASET.TABLE | PROJECT.DATASET.TABLE")
    ap.add_argument("--project", default=DEFAULT_PROJECT,
                    help=f"GCP project (default: {DEFAULT_PROJECT}; the Connect prod project)")
    ap.add_argument("--format", choices=["json", "csv"], default="json", help="output format (default: json)")
    ap.add_argument("-o", "--output-dir", default="schemas", help="base output directory (default: schemas)")
    ap.add_argument("--location", default=None, help="BigQuery location, e.g. US (optional)")
    ap.add_argument("--tables-only", action="store_true", help="skip VIEW / MATERIALIZED_VIEW / EXTERNAL")
    args = ap.parse_args()

    try:
        from google.cloud import bigquery
    except ImportError:
        sys.exit("error: google-cloud-bigquery is not installed.\n  pip install google-cloud-bigquery")

    try:
        client = bigquery.Client(project=args.project, location=args.location)
    except Exception as exc:  # auth / project resolution
        sys.exit(f"error: could not create a BigQuery client: {exc}\n"
                 "  try: gcloud auth application-default login")

    project, dataset, table = parse_target(args.target, args.project or client.project)
    if not project:
        sys.exit("error: no project; pass --project or set a default (gcloud config set project ...)")

    ds_ref = bigquery.DatasetReference(project, dataset)

    # Resolve the list of tables to export.
    if table:
        table_ids = [table]
    else:
        try:
            items = list(client.list_tables(ds_ref))
        except Exception as exc:
            sys.exit(f"error: could not list tables in {project}.{dataset}: {exc}")
        if args.tables_only:
            items = [t for t in items if t.table_type == "TABLE"]
        table_ids = [t.table_id for t in items]
        if not table_ids:
            sys.exit(f"no tables found in {project}.{dataset}")

    out_dir = Path(args.output_dir) / dataset
    out_dir.mkdir(parents=True, exist_ok=True)

    written, errors = 0, 0
    for tid in table_ids:
        try:
            tbl = client.get_table(ds_ref.table(tid))
        except Exception as exc:
            errors += 1
            hint = ""
            if table and len(args.target.split(".")) == 2:
                hint = "  (if you meant a whole dataset, pass just the dataset name with --project)"
            print(f"  ! skip {dataset}.{tid}: {exc}{hint}", file=sys.stderr)
            continue
        path = out_dir / f"{tid}.{args.format}"
        (write_json if args.format == "json" else write_csv)(tbl, path)
        print(f"  wrote {path}  ({len(tbl.schema)} top-level columns)")
        written += 1

    print(f"done: {written} schema file(s) under {out_dir}/" + (f"  ({errors} skipped)" if errors else ""))
    sys.exit(1 if errors and not written else 0)


if __name__ == "__main__":
    main()
