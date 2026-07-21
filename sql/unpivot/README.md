# sql/unpivot/ — wide CleanConnect → long `responses` (the Core transform)

**Generated** BigQuery SQL that melts each wide CleanConnect survey table into the long/narrow
`responses` fact. Produced by `scripts/generate_unpivot_sql.py` from the **schemas only**
(`schemas/prod/CleanConnect/*.json` or `schemas/stage/CleanConnect/*.json`) + the column→placement mapping
(`output/survey_columns_clean_mapped.csv`). **Not run against production** — validate later with
`bq query --dry_run` (reads 0 bytes) and against test data.

## How it works (metadata-driven)

Each table is melted with BigQuery `UNPIVOT` into `(connect_id, source_column, value)`, then JOINed to
`colmap` (a clean-named view over the loaded mapping) to attach the concept path. `UNPIVOT` drops NULL
cells, so an **unanswered question produces no row** — the sparse long fact.

- **Select-all / grid** → one row per checked option (no indicator-column explosion).
- **Loops** → `_N` suffix becomes `loop_instance` (a value, not a column).
- **Reused concepts** → the survey (`secondary_source_concept_id`) and grid/select-all parent
  (`source_question_concept_id`) come from the colmap, i.e. *stamped from the table*, not guessed.

The melt+join logic is verified on synthetic data (multi-select → multiple rows, NULLs dropped, loop
carried) — the pattern, not the data.

## Files

| File | What |
|---|---|
| `00_responses_ddl.sql` | `CREATE TABLE responses` + the `colmap` view over the loaded mapping. Run once. |
| `unpivot_<table>.sql`  | per survey table: a `DELETE` (idempotent) then `INSERT … SELECT` (`UNPIVOT` + colmap join). |
| `type_response_values.sql` | post-load typing step: routes 9-digit strings → `response_value_as_concept_id`, numeric strings → `response_value_as_number`. Run once after all unpivot files. |
| `validate_responses.sql` | post-run checks (volume, grain uniqueness, referential integrity, loop sanity, tooth-loss spot-check). |

**Idempotent:** each `unpivot_<table>.sql` clears that table's rows (`DELETE … WHERE source_table = …`)
before inserting, so it can be re-run without duplicating.

**Very wide tables:** `module1` has ~2,359 columns in one `UNPIVOT`. If that hits a BigQuery
compile/complexity limit, regenerate with chunking — one `DELETE` + several smaller `INSERT`s:

```bash
python scripts/generate_unpivot_sql.py module1 --batch 500
```

## Value typing (OMOP observation-style; extras deferred)

Three value columns, mirroring OMOP `observation` (`value_as_number` / `value_as_string` /
`value_as_concept_id`):

- `response_value_as_string` — **always** the verbatim raw cell (lossless source of truth + safety net).
- `response_value_as_number` — numeric answers (Num/Year/count), for direct `AVG`/`SUM`.
- `response_value_as_concept_id` — the coded answer (single/multi-select), joins to `response` /
  `response_options` / `concept_relationship` (the column that makes this raw-ish layer *derivable*).

The unpivot fills only `as_string`; the two typed extracts are populated by a **separate step keyed on
`question_type`** (a 9-digit coded answer and a numeric answer are both strings in CleanConnect, so
routing needs the question type, not the value alone). They are intentionally unpopulated for now.

**Deferred: a date/datetime column.** The dictionary's `Variable Type` is 62% blank and dirty; only ~270
rows are ISO/date and many "dates" are really `Year`/`Month` (numbers). Instrument timestamps live typed
on `response_sessions`. Add `response_value_as_datetime` only if date-valued *answers* prove needed.

## Regenerate

```bash
python scripts/fetch_bq_schemas.py CleanConnect                                     # schemas/prod/CleanConnect/*.json (metadata only)
python scripts/fetch_bq_schemas.py CleanConnect \
  --project nih-nci-dceg-connect-stg-5519 --output-dir schemas/stage               # schemas/stage/CleanConnect/*.json
python scripts/parse_survey_columns.py --layer CleanConnect -o output/survey_columns_clean.csv
python scripts/map_survey_columns.py    output/survey_columns_clean.csv -o output/survey_columns_clean_mapped.csv
python scripts/generate_unpivot_sql.py                 # -> sql/unpivot/*.sql
```

## Smoke test (no production data)

Exercise the transform *shape* end-to-end without any Connect data — builds a synthetic wide table from
the real schema column names, loads the real colmap, and runs the same `UNPIVOT` + join (DuckDB), checking
that NULL cells drop and the placement is stamped:

```bash
python scripts/smoke_test_unpivot.py            # mouthwash (default); prints responses + PASS/FAIL
python scripts/smoke_test_unpivot.py module4    # any CleanConnect survey table
```

## Run later (once test data + colmap are loaded)

```bash
bq query --dry_run < sql/unpivot/00_responses_ddl.sql   # syntax/type check, 0 bytes scanned
# load the mapping as relational.survey_columns_clean_mapped, then create table + colmap:
bq query < sql/unpivot/00_responses_ddl.sql
for f in sql/unpivot/unpivot_*.sql; do bq query --dry_run < "$f"; done
```
