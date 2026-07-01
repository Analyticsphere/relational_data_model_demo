#!/usr/bin/env python3
"""Generate BigQuery SQL that unpivots the wide CleanConnect survey tables into the long `responses` fact.

Metadata-driven: each survey table is melted with BigQuery's UNPIVOT into (connect_id, source_column,
value), then JOINed to a `colmap` (our column→placement mapping) to attach the concept path
(secondary source, source question, question, loop, version). UNPIVOT drops NULL cells, so an
unanswered question produces no row — the long/sparse fact.

**Generated from the SCHEMAS only** (schemas/CleanConnect/*.json) + the mapping
(output/survey_columns_clean_mapped.csv). It does NOT touch production data. Validate later with
`bq query --dry_run` (reads 0 bytes) and against test data.

    python scripts/generate_unpivot_sql.py                       # all CleanConnect survey tables -> sql/unpivot/
    python scripts/generate_unpivot_sql.py module1 mouthwash     # specific tables
    python scripts/generate_unpivot_sql.py --project my-proj --dataset relational

Writes:
    sql/unpivot/00_responses_ddl.sql   the target `responses` table + a clean-named `colmap` view
    sql/unpivot/unpivot_<table>.sql    one INSERT per survey table (UNPIVOT + colmap join)

Value typing: the unpivot fills `response_value_as_string` with the raw cell. `response_value_as_number`
(and a future coded response_concept_id) are left for a SEPARATE downstream step keyed on question_type
— hence the value columns may be unpopulated for now, by design.
"""
import argparse
import csv
import json
import sys
from collections import defaultdict
from pathlib import Path

NON_SURVEY = {"participants", "biospecimen"}


def load_colmap(path):
    """table -> set(columns) present in the column→dictionary mapping (which columns we can place)."""
    m = defaultdict(set)
    for r in csv.DictReader(open(path, encoding="utf-8")):
        m[r["table"]].add(r["column"])
    return m


def bq(name):
    return f"`{name}`"


def gen_table_sql(table, schema, mapped_cols, project, dataset):
    types = {f["name"]: f["type"] for f in schema}
    cols = [c for c in sorted(mapped_cols) if c in types]     # mapped data columns present in the schema
    unmapped_skipped = len(mapped_cols) - len(cols)
    if not cols:
        return None, 0, unmapped_skipped

    # inner SELECT: Connect_ID + each data column, casting non-STRING to STRING (UNPIVOT needs one type)
    inner = ["  SELECT Connect_ID,"]
    for c in cols:
        inner.append(f"    {'CAST('+bq(c)+' AS STRING) AS '+bq(c) if types[c] != 'STRING' else bq(c)},")
    inner[-1] = inner[-1].rstrip(",")
    inner.append(f"  FROM `{project}.CleanConnect.{table}`")
    in_list = ", ".join(bq(c) for c in cols)

    sql = f"""-- Unpivot CleanConnect.{table} -> {dataset}.responses  (GENERATED from schemas/CleanConnect/{table}.json)
-- NOT run against production. Validate later: bq query --dry_run < this file.  {len(cols)} columns unpivoted.
INSERT INTO `{project}.{dataset}.responses`
  (connect_id, secondary_source_concept_id, current_source_question_concept_id, question_concept_id,
   loop_instance, question_version, response_value_as_string, response_value_as_number,
   source_table, source_column)
SELECT
  u.Connect_ID                                       AS connect_id,     -- passthrough belongs to the UNPIVOT alias
  m.secondary_source_concept_id,
  m.current_source_question_concept_id,
  m.question_concept_id,
  m.loop_instance,
  m.question_version,
  u.value                                            AS response_value_as_string,  -- raw cell
  CAST(NULL AS FLOAT64)                              AS response_value_as_number,   -- typed later by question_type
  'CleanConnect.{table}'                             AS source_table,
  u.source_column
FROM (
{chr(10).join(inner)}
) t
UNPIVOT(value FOR source_column IN ({in_list})) u    -- BigQuery UNPIVOT drops NULL cells => unanswered = no row
JOIN `{project}.{dataset}.colmap` m
  ON m.table_name = '{table}' AND m.source_column = u.source_column;
"""
    return sql, len(cols), unmapped_skipped


DDL = """-- Target fact + colmap for the responses unpivot. NOT run against production.

CREATE TABLE IF NOT EXISTS `{project}.{dataset}.responses` (
  connect_id STRING,
  secondary_source_concept_id STRING,           -- the SURVEY (stamped from the table via colmap)
  current_source_question_concept_id STRING,    -- grid / select-all parent; NULL if standalone
  question_concept_id STRING,
  loop_instance INT64,                          -- the _N loop suffix (1 if not looped)
  question_version STRING,                      -- the _v2 question/concept revision tag
  response_value_as_string STRING,              -- raw cell: a response concept id (coded) or a literal
  response_value_as_number FLOAT64,             -- typed numeric answer (populated by the later typing step)
  source_table STRING,
  source_column STRING
);

-- colmap: a clean-named view over the loaded column->placement mapping. Load the mapping first, e.g.
--   bq load --autodetect --source_format=CSV {dataset}.survey_columns_clean_mapped \\
--           gs://<bucket>/survey_columns_clean_mapped.csv
-- (`table`/`column` are reserved words -> backticked and aliased below.)
CREATE OR REPLACE VIEW `{project}.{dataset}.colmap` AS
SELECT
  `table`                    AS table_name,
  `column`                   AS source_column,
  secondary_source_concept_id,
  NULLIF(source_question_concept_id, '') AS current_source_question_concept_id,  -- NULL = standalone question
  question_concept_id,
  SAFE_CAST(NULLIF(loop_number, '') AS INT64) AS loop_instance,
  NULLIF(version_tag, '')     AS question_version
FROM `{project}.{dataset}.survey_columns_clean_mapped`;
"""


def main():
    ap = argparse.ArgumentParser(description="Generate BigQuery unpivot SQL for the responses fact (from schemas).",
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("tables", nargs="*", help="specific CleanConnect table stems (default: all survey tables)")
    ap.add_argument("--schemas-dir", default="schemas/CleanConnect")
    ap.add_argument("--mapping", default="output/survey_columns_clean_mapped.csv")
    ap.add_argument("--out-dir", default="sql/unpivot")
    ap.add_argument("--project", default="${PROJECT}")
    ap.add_argument("--dataset", default="relational")
    args = ap.parse_args()

    schema_dir = Path(args.schemas_dir)
    if not schema_dir.is_dir():
        sys.exit(f"error: {schema_dir} not found (run scripts/fetch_bq_schemas.py CleanConnect)")
    if not Path(args.mapping).exists():
        sys.exit(f"error: mapping not found: {args.mapping} (run parse_survey_columns + map_survey_columns)")
    colmap = load_colmap(args.mapping)

    stems = args.tables or sorted(f.stem for f in schema_dir.glob("*.json") if f.stem not in NON_SURVEY)
    out = Path(args.out_dir); out.mkdir(parents=True, exist_ok=True)
    (out / "00_responses_ddl.sql").write_text(DDL.format(project=args.project, dataset=args.dataset))

    total = 0
    for t in stems:
        sf = schema_dir / f"{t}.json"
        if not sf.exists():
            print(f"  ! no schema: {sf}", file=sys.stderr); continue
        sql, n, skipped = gen_table_sql(t, json.loads(sf.read_text()), colmap.get(t, set()), args.project, args.dataset)
        if sql is None:
            print(f"  ! {t}: no mapped columns, skipped", file=sys.stderr); continue
        (out / f"unpivot_{t}.sql").write_text(sql)
        total += n
        print(f"  {t:18} {n:5} columns unpivoted" + (f"  ({skipped} unmapped skipped)" if skipped else ""))
    print(f"wrote {out}/  ({total} columns across {len(stems)} tables). Validate later with `bq query --dry_run`.")


if __name__ == "__main__":
    main()
