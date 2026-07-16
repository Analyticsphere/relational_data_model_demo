#!/usr/bin/env python3
"""Reproducible, PRODUCTION-FREE smoke test of the responses unpivot (sql/unpivot/).

Proves the transform *shape* without any Connect data:
  1. builds a synthetic wide table using the REAL column names from schemas/prod/CleanConnect/<table>.json
     (fake cell values; most left NULL = unanswered),
  2. loads the REAL colmap (output/survey_columns_clean_mapped.csv),
  3. runs the same BigQuery `UNPIVOT` + colmap join the generated SQL uses (DuckDB dialect),
  4. checks the long `responses` shape: NULL cells drop, each answered cell → one row, and the
     placement (survey / grid-parent / question / loop / version) is stamped from the colmap.

No production rows are ever read — only committed schemas + the mapping.

    python scripts/smoke_test_unpivot.py                 # mouthwash (default)
    python scripts/smoke_test_unpivot.py module4 --seeded 6
"""
import argparse
import json
import sys
from pathlib import Path

import duckdb

MAPPING = "output/survey_columns_clean_mapped.csv"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("table", nargs="?", default="mouthwash", help="CleanConnect table stem (default: mouthwash)")
    ap.add_argument("--schemas-dir", default="schemas/prod/CleanConnect",
                    help="CleanConnect schema dir (default: schemas/prod/CleanConnect)")
    ap.add_argument("--seeded", type=int, default=4, help="how many columns to give participant P1 a value (default 4)")
    args = ap.parse_args()

    schema_path = Path(args.schemas_dir) / f"{args.table}.json"
    if not schema_path.exists():
        sys.exit(f"error: no schema {schema_path}")
    if not Path(MAPPING).exists():
        sys.exit(f"error: no mapping {MAPPING} (run parse_survey_columns + map_survey_columns)")

    data_cols = [f["name"] for f in json.loads(schema_path.read_text()) if f["name"] != "Connect_ID"]
    con = duckdb.connect()

    # colmap: clean-named view over the real mapping, filtered to this table (mirrors 00_responses_ddl.sql)
    con.execute(f"""
        CREATE VIEW colmap AS
        SELECT "column" AS source_column, secondary_source_concept_id,
               NULLIF(source_question_concept_id,'') AS source_question_concept_id,
               question_concept_id,
               COALESCE(TRY_CAST(NULLIF(loop_number,'') AS INTEGER), 1) AS loop_instance,
               NULLIF(version_tag,'')          AS question_version
        FROM read_csv('{MAPPING}', header=true, all_varchar=true)
        WHERE "table" = '{args.table}'
    """)
    mapped = {r[0] for r in con.execute("SELECT source_column FROM colmap").fetchall()}
    cols = [c for c in data_cols if c in mapped]          # unpivot only mapped columns (as the generator does)
    if len(cols) < 2:
        sys.exit(f"error: {args.table} has too few mapped columns ({len(cols)}) to smoke-test")
    seeded = min(args.seeded, len(cols) - 1)

    # synthetic wide table: P1 answers `seeded` columns, P2 answers just the first; everything else NULL
    def row(cid, n_answered):
        cells = [f"'{cid}' AS Connect_ID"]
        for i, c in enumerate(cols):
            cells.append((f"'353358909'" if i < n_answered else "NULL::VARCHAR") + f' AS "{c}"')
        return "SELECT " + ", ".join(cells)
    con.execute(f"CREATE TABLE wide AS {row('P1', seeded)} UNION ALL BY NAME {row('P2', 1)}")

    in_list = ", ".join(f'"{c}"' for c in cols)
    responses = con.execute(f"""
        SELECT u.Connect_ID AS connect_id, m.secondary_source_concept_id AS survey,
               m.source_question_concept_id AS parent_sq, m.question_concept_id AS question,
               m.loop_instance AS loop, m.question_version AS qver,
               u.value AS response_value_as_string, u.source_column
        FROM wide t
        UNPIVOT(value FOR source_column IN ({in_list})) u
        JOIN colmap m ON m.source_column = u.source_column
        ORDER BY u.Connect_ID, u.source_column
    """).fetchall()

    print(f"table={args.table}  mapped_columns={len(cols)}  synthetic_rows=2 (P1 answered {seeded}, P2 answered 1)\n")
    hdr = ["connect_id", "survey", "parent_sq", "question", "loop", "qver", "as_string", "source_column"]
    print("  " + " | ".join(hdr))
    for r in responses:
        print("  " + " | ".join("" if v is None else str(v) for v in r))

    # checks: exactly seeded+1 rows survive (NULLs dropped), and every row got a survey stamped
    expected = seeded + 1
    got = len(responses)
    all_stamped = all(r[1] for r in responses)
    ok = got == expected and all_stamped
    print(f"\n  rows: expected {expected} (seeded {seeded} + 1), got {got} — NULL cells dropped")
    print(f"  every row has a survey (secondary_source) stamped from colmap: {all_stamped}")
    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
