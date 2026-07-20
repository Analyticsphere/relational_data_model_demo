# Run protocol — `relational.response_source_codes` in stage / prod

How to materialize the OMOP source-code table (`sql/omop/response_source_codes.sql`) in a real BigQuery
project. The OMOP step is the *last* step of a chain — it reads `relational.responses` + the dimension tables,
so those must exist first. This protocol builds the whole chain, idempotently, with a dry-run gate before
every write.

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
for f in "$UNPIVOT_DIR"/unpivot_*.sql "$UNPIVOT_DIR"/type_response_values.sql sql/omop/response_source_codes.sql; do
  echo "dry-run: $f"
  envsubst '${PROJECT}' < "$f" | bq --project_id=$PROJECT query --use_legacy_sql=false --dry_run || { echo "FAILED: $f"; break; }
done
```

## Step C — stand up the `relational` dataset + dims + `responses` table/colmap

`setup_relational.py` prints the target project and prompts before writing (drop `--yes` to keep the prompt).
It creates the dataset, loads the column mapping, creates the empty `responses` table + `colmap` view, and
loads the dimension tables from `output/dim/*.csv` (built offline from the data dictionary — no participant
data).

```bash
python scripts/setup_relational.py --project $PROJECT --mapping $MAPPING --dims       # confirm at the prompt
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

## Step E — build the OMOP source-code table

```bash
envsubst '${PROJECT}' < sql/omop/response_source_codes.sql | bq --project_id=$PROJECT query --use_legacy_sql=false
```

## Step F — validate (counts + id uniqueness; NO verbatim values printed)

```bash
bq --project_id=$PROJECT query --use_legacy_sql=false --format=pretty "
SELECT
  COUNT(*)                                   AS n_rows,
  COUNT(DISTINCT response_hash_id)           AS n_hash,        -- expect = n_rows
  COUNT(DISTINCT response_unique_id)         AS n_unique_id,   -- expect = n_rows (no 60-bit collisions)
  MIN(response_unique_id)                    AS min_id,        -- expect > 2000000000
  MAX(response_unique_id)                    AS max_id,        -- expect < 9223372036854775807
  COUNTIF(response_unique_id <= 2000000000
       OR response_unique_id >= 9223372036854775807) AS out_of_omop_range  -- expect 0
FROM \`$PROJECT.relational.response_source_codes\`"
```

`n_hash = n_unique_id = n_rows` and `out_of_omop_range = 0` confirm the ids are unique and OMOP-valid.
(Repo `sql/unpivot/validate_responses.sql` has broader upstream checks for the `responses` fact.)

## Governance / PII

`response_value_verbatim` is free text = PII/PHI. Govern this table at its inputs' sensitivity, and restrict
which free-text (`response_kind = 'free_text'`) questions you export to Usagi to a vetted allow-list. Do not
print verbatim values into logs/tickets. See `docs/omop_source_codes.md`.

## Idempotency / rollback

- Every step is re-runnable: `setup_relational.py` is idempotent, each `unpivot_*.sql` clears its own rows
  first, and `response_source_codes.sql` is `CREATE OR REPLACE TABLE`.
- To roll back just the OMOP step: `bq rm -f -t $PROJECT:relational.response_source_codes`.

## One-liner recap (stage)

```bash
export PROJECT=nih-nci-dceg-connect-stg-5519 MAPPING=output/survey_columns_stage_mapped.csv UNPIVOT_DIR=sql/unpivot_stage
python scripts/smoke_test_omop_hash.py
python scripts/setup_relational.py --project $PROJECT --mapping $MAPPING --dims
for f in "$UNPIVOT_DIR"/unpivot_*.sql; do envsubst '${PROJECT}' < "$f" | bq --project_id=$PROJECT query --use_legacy_sql=false; done
envsubst '${PROJECT}' < sql/omop/response_source_codes.sql | bq --project_id=$PROJECT query --use_legacy_sql=false
```
