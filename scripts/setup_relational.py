#!/usr/bin/env python3
"""Set up the `relational` BigQuery dataset in the target project for the responses POC.

Idempotent: safe to re-run. Creates the dataset if absent, loads the column mapping with an
explicit schema (concept IDs as STRING), creates the `responses` table + `colmap` view, and
optionally loads the CIDTool-style dimension tables from output/dim/*.csv.

Table schemas are read from schemas/relational/*.json — the single source of truth for BQ types.

Usage:
    python scripts/setup_relational.py                          # responses infra only (defaults to stage)
    python scripts/setup_relational.py --dims                   # also load dimension tables
    python scripts/setup_relational.py --dims --dims-dir output/dim
    python scripts/setup_relational.py --project my-project

SAFETY: The --project flag defaults to the stage project. The script prints the target project
and prompts for confirmation before writing anything. Pass --yes to skip the prompt (CI use).

Requires: pip install google-cloud-bigquery
Auth:     gcloud auth application-default login
"""
import argparse
import json
import sys
from pathlib import Path

STAGE_PROJECT  = "nih-nci-dceg-connect-stg-5519"
DATASET        = "relational"
SCHEMAS_DIR    = Path(__file__).parent.parent / "schemas" / "relational"
DEFAULT_MAPPING = "output/survey_columns_stage_mapped.csv"
LOCATION       = "US"


def bq_client(project):
    try:
        from google.cloud import bigquery
    except ImportError:
        sys.exit("error: google-cloud-bigquery not installed.\n  pip install google-cloud-bigquery")
    try:
        return bigquery.Client(project=project, location=LOCATION), bigquery
    except Exception as exc:
        sys.exit(f"error: could not create BigQuery client: {exc}\n"
                 "  try: gcloud auth application-default login")


def load_schema_json(name):
    """Load a BQ schema from schemas/relational/<name>.json as a list of SchemaField objects."""
    from google.cloud import bigquery
    path = SCHEMAS_DIR / f"{name}.json"
    if not path.exists():
        sys.exit(f"error: schema not found: {path}")
    raw = json.loads(path.read_text())
    fields = raw["fields"] if isinstance(raw, dict) else raw   # object form carries a table description
    return [
        bigquery.SchemaField(
            name=f["name"],
            field_type=f["type"],
            mode=f.get("mode", "NULLABLE"),
            description=f.get("description", ""),
        )
        for f in fields
    ]


def load_table_description(name):
    """Table-level description from schemas/relational/<name>.json (object form); '' if absent."""
    path = SCHEMAS_DIR / f"{name}.json"
    if not path.exists():
        return ""
    raw = json.loads(path.read_text())
    return raw.get("description", "") if isinstance(raw, dict) else ""


COLMAP_VIEW_DESCRIPTION = (
    "Clean-named view over survey_columns_clean_mapped - the column->placement colmap "
    "(table_name, source_column -> survey / source-question / question / loop / version) the responses unpivot joins."
)


def apply_table_descriptions(client, bq, project, include_dims):
    """Set BQ table/view descriptions from the schema JSON (idempotent — only updates when changed)."""
    from google.cloud.exceptions import NotFound
    targets = [("responses", "responses"),
               ("survey_columns_clean_mapped", "survey_columns_clean_mapped")]
    if include_dims:
        targets += [(t, t) for t, _ in DIM_TABLES]
    for tbl, schema_name in targets:
        desc = load_table_description(schema_name)
        if not desc:
            continue
        try:
            t = client.get_table(f"{project}.{DATASET}.{tbl}")
        except NotFound:
            continue
        if t.description != desc:
            t.description = desc
            client.update_table(t, ["description"])
            print(f"  described {tbl}")
    try:  # colmap view has no schema file
        v = client.get_table(f"{project}.{DATASET}.colmap")
        if v.description != COLMAP_VIEW_DESCRIPTION:
            v.description = COLMAP_VIEW_DESCRIPTION
            client.update_table(v, ["description"])
            print("  described colmap")
    except NotFound:
        pass


def ensure_dataset(client, bq, project):
    from google.cloud.exceptions import NotFound
    ds_ref = f"{project}.{DATASET}"
    try:
        client.get_dataset(ds_ref)
        print(f"  dataset {ds_ref} already exists")
    except NotFound:
        ds = bq.Dataset(ds_ref)
        ds.location = LOCATION
        client.create_dataset(ds)
        print(f"  created dataset {ds_ref}")


DEFAULT_DIMS_DIR = "output/dim"

# Dim tables: (BQ table name, CSV filename stem). Ordered to respect FK direction (parents first).
DIM_TABLES = [
    ("primary_source",    "primary_source"),
    ("secondary_source",  "secondary_source"),
    ("source_question",   "source_question"),
    ("question",          "question"),
    ("response",          "response"),
    ("question_response", "question_response"),
    ("concept_relationship", "concept_relationship"),
]


def load_colmap(client, bq, project, mapping_path):
    """Load the column mapping CSV into relational.survey_columns_clean_mapped with explicit schema."""
    from google.cloud.exceptions import NotFound
    table_ref = f"{project}.{DATASET}.survey_columns_clean_mapped"
    schema = load_schema_json("survey_columns_clean_mapped")

    job_config = bq.LoadJobConfig(
        schema=schema,
        source_format=bq.SourceFormat.CSV,
        skip_leading_rows=1,
        write_disposition=bq.WriteDisposition.WRITE_TRUNCATE,  # idempotent replace
    )
    with open(mapping_path, "rb") as f:
        job = client.load_table_from_file(f, table_ref, job_config=job_config)
    job.result()
    tbl = client.get_table(table_ref)
    print(f"  loaded {tbl.num_rows} rows into {table_ref}")


def create_responses_table(client, bq, project):
    """Create the responses fact table from schemas/relational/responses.json if it doesn't exist."""
    table_ref = f"{project}.{DATASET}.responses"
    schema = load_schema_json("responses")
    table = bq.Table(table_ref, schema=schema)
    table.clustering_fields = ["secondary_source_concept_id", "question_concept_id", "connect_id"]
    try:
        client.get_table(table_ref)
        print(f"  responses table already exists — skipping creation")
    except Exception:
        client.create_table(table)
        print(f"  created table {table_ref} (clustered by secondary_source_concept_id, question_concept_id, connect_id)")


def create_colmap_view(client, bq, project):
    """Create or replace the colmap view over survey_columns_clean_mapped."""
    view_ref = f"{project}.{DATASET}.colmap"
    view_query = f"""SELECT
  `table`                    AS table_name,
  `column`                   AS source_column,
  secondary_source_concept_id,
  NULLIF(source_question_concept_id, '') AS current_source_question_concept_id,
  question_concept_id,
  COALESCE(loop_number, 1)   AS loop_instance,
  NULLIF(version_tag, '')    AS question_version
FROM `{project}.{DATASET}.survey_columns_clean_mapped`"""

    view = bq.Table(view_ref)
    view.view_query = view_query
    try:
        client.get_table(view_ref)
        client.update_table(view, ["view_query"])
        print(f"  updated view {view_ref}")
    except Exception:
        client.create_table(view)
        print(f"  created view {view_ref}")


def load_dim_tables(client, bq, project, dims_dir):
    """Load all CIDTool-style dimension tables from CSV with explicit schemas."""
    dims_path = Path(dims_dir)
    for table_name, csv_stem in DIM_TABLES:
        csv_path = dims_path / f"{csv_stem}.csv"
        if not csv_path.exists():
            print(f"  ! {table_name}: CSV not found at {csv_path}, skipping")
            continue
        table_ref = f"{project}.{DATASET}.{table_name}"
        schema = load_schema_json(table_name)
        job_config = bq.LoadJobConfig(
            schema=schema,
            source_format=bq.SourceFormat.CSV,
            skip_leading_rows=1,
            write_disposition=bq.WriteDisposition.WRITE_TRUNCATE,
        )
        with open(csv_path, "rb") as f:
            job = client.load_table_from_file(f, table_ref, job_config=job_config)
        job.result()
        tbl = client.get_table(table_ref)
        print(f"  loaded {tbl.num_rows:>6} rows -> {table_ref}")


def main():
    ap = argparse.ArgumentParser(
        description="Set up the relational dataset in BigQuery (idempotent).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("--project", default=STAGE_PROJECT,
                    help=f"GCP project (default: {STAGE_PROJECT})")
    ap.add_argument("--mapping", default=DEFAULT_MAPPING,
                    help=f"column mapping CSV to load (default: {DEFAULT_MAPPING})")
    ap.add_argument("--dims", action="store_true",
                    help="also load dimension tables (primary_source, secondary_source, etc.)")
    ap.add_argument("--dims-dir", default=DEFAULT_DIMS_DIR,
                    help=f"directory containing dim CSVs (default: {DEFAULT_DIMS_DIR})")
    ap.add_argument("--yes", action="store_true",
                    help="skip confirmation prompt (for CI/scripted use)")
    args = ap.parse_args()

    mapping = Path(args.mapping)
    if not mapping.exists():
        sys.exit(f"error: mapping not found: {mapping}\n"
                 "  run: python scripts/parse_survey_columns.py --layer CleanConnect -o output/survey_columns_stage_clean.csv\n"
                 "       python scripts/map_survey_columns.py output/survey_columns_stage_clean.csv -o output/survey_columns_stage_mapped.csv")

    print(f"\nTarget project : {args.project}")
    print(f"Dataset        : {DATASET}")
    print(f"Mapping file   : {mapping}")
    print(f"Schema dir     : {SCHEMAS_DIR}")
    if args.dims:
        print(f"Dims dir       : {args.dims_dir}")
    print()

    if not args.yes:
        ans = input("Proceed? [y/N] ").strip().lower()
        if ans != "y":
            sys.exit("aborted")

    client, bq = bq_client(args.project)

    print("1. Ensuring dataset exists...")
    ensure_dataset(client, bq, args.project)

    print("2. Loading column mapping with explicit schema...")
    load_colmap(client, bq, args.project, mapping)

    print("3. Creating responses table...")
    create_responses_table(client, bq, args.project)

    print("4. Creating colmap view...")
    create_colmap_view(client, bq, args.project)

    if args.dims:
        print("5. Loading dimension tables...")
        load_dim_tables(client, bq, args.project, args.dims_dir)

    print("6. Applying table descriptions...")
    apply_table_descriptions(client, bq, args.project, args.dims)

    print("\ndone. Run sql/unpivot_stage/unpivot_*.sql to populate responses,")
    print("      then sql/unpivot_stage/type_response_values.sql to populate typed value columns.")


if __name__ == "__main__":
    main()
