# sql/unpivot/ — wide CleanConnect → long `responses` (the Core transform)

**Generated** BigQuery SQL that melts each wide CleanConnect survey table into the long/narrow
`responses` fact. Produced by `scripts/generate_unpivot_sql.py` from the **schemas only**
(`schemas/CleanConnect/*.json`) + the column→placement mapping
(`output/survey_columns_clean_mapped.csv`). **Not run against production** — validate later with
`bq query --dry_run` (reads 0 bytes) and against test data.

## How it works (metadata-driven)

Each table is melted with BigQuery `UNPIVOT` into `(connect_id, source_column, value)`, then JOINed to
`colmap` (a clean-named view over the loaded mapping) to attach the concept path. `UNPIVOT` drops NULL
cells, so an **unanswered question produces no row** — the sparse long fact.

- **Select-all / grid** → one row per checked option (no indicator-column explosion).
- **Loops** → `_N` suffix becomes `loop_instance` (a value, not a column).
- **Reused concepts** → the survey (`secondary_source_concept_id`) and grid/select-all parent
  (`current_source_question_concept_id`) come from the colmap, i.e. *stamped from the table*, not guessed.

The melt+join logic is verified on synthetic data (multi-select → multiple rows, NULLs dropped, loop
carried) — the pattern, not the data.

## Files

| File | What |
|---|---|
| `00_responses_ddl.sql` | `CREATE TABLE responses` + the `colmap` view over the loaded mapping. Run once. |
| `unpivot_<table>.sql`  | one `INSERT … SELECT` per survey table (`UNPIVOT` + colmap join). |

## Value typing (deliberately deferred)

The unpivot fills `response_value_as_string` with the raw cell. `response_value_as_number` (and a future
coded `response_concept_id`) are left for a **separate downstream step keyed on `question_type`** — a
9-digit coded answer and a numeric answer are both strings in CleanConnect, so splitting them needs the
question type, not the value alone. Hence those columns may be unpopulated for now, by design.

## Regenerate

```bash
python scripts/fetch_bq_schemas.py CleanConnect        # schemas/CleanConnect/*.json (metadata only)
python scripts/parse_survey_columns.py --layer CleanConnect -o output/survey_columns_clean.csv
python scripts/map_survey_columns.py    output/survey_columns_clean.csv -o output/survey_columns_clean_mapped.csv
python scripts/generate_unpivot_sql.py                 # -> sql/unpivot/*.sql
```

## Run later (once test data + colmap are loaded)

```bash
bq query --dry_run < sql/unpivot/00_responses_ddl.sql   # syntax/type check, 0 bytes scanned
# load the mapping as relational.survey_columns_clean_mapped, then create table + colmap:
bq query < sql/unpivot/00_responses_ddl.sql
for f in sql/unpivot/unpivot_*.sql; do bq query --dry_run < "$f"; done
```
