# Run protocol — `response_unique_id` on `relational.responses` (stage / prod)

How to populate `relational.responses` with the stable `response_unique_id` (the OMOP-compatible id, from the
`response_unique_id` UDF) in a real BigQuery project. This is the end of *this* repo's OMOP responsibility —
the Usagi source-code prep is maintained **downstream** by the OMOP mapping owner. The protocol builds the
whole chain, idempotently, with a dry-run gate before every write. (`scripts/run_pipeline.sh` automates it.)

> **Prod guardrail.** Everything here is safe to run in **stage** yourself. In **prod**, run every step
> yourself on your own machine — the only prod operation anyone else (incl. an assistant) should run is the
> read-only **schema fetch** (Step 0). Nothing else touches prod on your behalf.

## Parameters

|              | Stage | Prod |
|--------------|-------|------|
| `PROJECT`    | `nih-nci-dceg-connect-stg-5519` | `nih-nci-dceg-connect-prod-6d04` |
| mapping CSV  | `output/survey_columns_stage_mapped.csv` | `output/survey_columns_clean_mapped.csv` |
| unpivot dir  | `sql/unpivot_stage/` | `sql/unpivot/` |

```bash
# pick ONE environment, then paste the rest of the protocol
export PROJECT=nih-nci-dceg-connect-stg-5519           # STAGE
export MAPPING=output/survey_columns_stage_mapped.csv
export UNPIVOT_DIR=sql/unpivot_stage

# export PROJECT=nih-nci-dceg-connect-prod-6d04         # PROD (run these yourself)
# export MAPPING=output/survey_columns_clean_mapped.csv
# export UNPIVOT_DIR=sql/unpivot
```

## Prerequisites

- `git checkout main && git pull` (main now contains `sql/omop/`).
- `gcloud` + `bq` CLIs, and `pip install google-cloud-bigquery`.
- Application Default Credentials with access to `$PROJECT`:
  `gcloud auth application-default login`
- `$PROJECT` already has the `CleanConnect.*` survey tables (the unpivot reads them). This is the only step
  that reads real participant data.
- `envsubst` (from `gettext`; `brew install gettext` on macOS if missing) — used to substitute `${PROJECT}`
  in the SQL. It is scoped to `${PROJECT}` only, so other `$` in SQL are left untouched.

## Preflight — is the model already built?

If `relational.responses` and the dims already exist in `$PROJECT`, **skip to Step E**.

```bash
bq --project_id=$PROJECT query --use_legacy_sql=false --format=pretty \
  "SELECT table_id, row_count FROM \`$PROJECT.relational.__TABLES__\`
   WHERE table_id IN ('responses','question','question_response','response')"
# empty / missing table  -> build it (Steps C–D). all present with rows -> skip to Step E.
```

---

## Step 0 — (PROD-ONLY, read-only) refresh schemas

The one prod-safe operation. Optional; only if the CleanConnect schema changed since the committed snapshot.

```bash
python scripts/fetch_bq_schemas.py CleanConnect --project $PROJECT --output-dir schemas/prod
```

## Step A — sanity: run the offline smoke tests (no cloud, no data)

```bash
python scripts/smoke_test_omop_hash.py        # hash + response_unique_id determinism/range/uniqueness
```

## Step B — dry-run everything first (0 bytes billed, syntax/type check)

```bash
for f in "$UNPIVOT_DIR"/unpivot_*.sql; do
  echo "dry-run: $f"
  envsubst '${PROJECT}' < "$f" | bq --project_id=$PROJECT query --use_legacy_sql=false --dry_run || { echo "FAILED: $f"; break; }
done
```

## Step B2 — deploy the `response_unique_id` UDF

```bash
envsubst '${PROJECT}' < sql/omop/response_unique_id_udf.sql | bq --project_id=$PROJECT query --use_legacy_sql=false
```

## Step C — stand up the `relational` dataset + dims + `responses` table/colmap

`setup_relational.py` prints the target project and prompts before writing (drop `--yes` to keep the prompt).
Pass `--recreate` to drop and recreate `responses` with the current schema (required if the schema has
changed since the last run — all rows are deleted and must be reloaded in Steps D and E).

```bash
python scripts/setup_relational.py --project $PROJECT --mapping $MAPPING --dims --recreate  # confirm at the prompt
```

## Step D — populate `responses` (reads real CleanConnect data)

```bash
# one INSERT per survey table (idempotent: each file DELETEs its own source_table rows first)
for f in "$UNPIVOT_DIR"/unpivot_*.sql; do
  echo "loading: $f"
  envsubst '${PROJECT}' < "$f" | bq --project_id=$PROJECT query --use_legacy_sql=false || { echo "FAILED: $f"; break; }
done
# optional: fill typed value columns (response_value_as_number / _as_concept_id)
envsubst '${PROJECT}' < "$UNPIVOT_DIR"/type_response_values.sql | bq --project_id=$PROJECT query --use_legacy_sql=false
```

## Step E — validate `response_unique_id` on `responses` (no verbatim values printed)

```bash
bq --project_id=$PROJECT query --use_legacy_sql=false --format=pretty "
SELECT
  COUNT(*)                                          AS response_rows,
  COUNT(DISTINCT response_unique_id)                AS n_unique_id,
  COUNT(DISTINCT CONCAT(
    COALESCE(secondary_source_concept_id,''), '|',
    COALESCE(source_question_concept_id,''),  '|',
    COALESCE(question_concept_id,''),         '|',
    COALESCE(response_value_as_string,'')))         AS n_distinct_responses,   -- expect = n_unique_id
  COUNTIF(response_unique_id <= 2000000000
       OR response_unique_id >= 9223372036854775807) AS out_of_omop_range        -- expect 0
FROM \`$PROJECT.relational.responses\`
WHERE response_value_as_string IS NOT NULL AND response_value_as_string <> ''"
```

`n_unique_id = n_distinct_responses` (collision-free over the 4-field key) and `out_of_omop_range = 0`
confirm the ids are unique and OMOP-valid. (`sql/unpivot/validate_responses.sql` has broader upstream checks.)

## Governance / PII

`response_value_as_string` on `responses` is free text = PII/PHI. Govern `responses` at its inputs'
sensitivity and don't print verbatim values into logs/tickets. Selecting which free-text questions to export
to Usagi (a vetted allow-list) happens **downstream** and never changes ids. See `docs/omop_source_codes.md`.

## Idempotency / rollback

- Every step is re-runnable: the `response_unique_id` UDF is `CREATE OR REPLACE FUNCTION`;
  `setup_relational.py --recreate` drops and recreates `responses` with the current schema (then re-run the
  unpivots); each `unpivot_*.sql` clears its own rows first.
- To roll back the fact: `bq rm -f -t $PROJECT:relational.responses` (or re-run with `--recreate`). To drop
  the UDF: `bq rm -f --routine $PROJECT:relational.response_unique_id`.

## One-liner recap (stage)

```bash
export PROJECT=nih-nci-dceg-connect-stg-5519 MAPPING=output/survey_columns_stage_mapped.csv UNPIVOT_DIR=sql/unpivot_stage
python scripts/smoke_test_omop_hash.py
sed 's/${PROJECT}/'"$PROJECT"'/g' sql/omop/response_unique_id_udf.sql | bq --project_id=$PROJECT query --use_legacy_sql=false
python scripts/setup_relational.py --project $PROJECT --mapping $MAPPING --dims --recreate
for f in "$UNPIVOT_DIR"/unpivot_*.sql; do bq --project_id=$PROJECT query --use_legacy_sql=false < "$f"; done
# (or just run: scripts/run_pipeline.sh --project $PROJECT)
```
