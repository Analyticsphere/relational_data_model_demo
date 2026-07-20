#!/usr/bin/env bash
# run_pipeline.sh — End-to-end responses pipeline for a single project.
#
# Usage:
#   bash scripts/run_pipeline.sh --project nih-nci-dceg-connect-stg-5519
#   bash scripts/run_pipeline.sh --project nih-nci-dceg-connect-prod-6d04 --refresh-schemas
#   bash scripts/run_pipeline.sh --project nih-nci-dceg-connect-stg-5519 --yes
#
# Steps:
#   A. (--refresh-schemas only) Fetch current BQ schemas + regenerate unpivot SQL
#   B. Offline smoke test (no cloud, no data)
#   C. Deploy response_unique_id UDF
#   D. Set up dataset + responses table (--recreate) + colmap view + dims
#   E. Dry-run all unpivot files (syntax/type check, 0 bytes billed)
#   F. Populate responses (reads real CleanConnect data)
#   G. Type the value columns
#   H. Create/update response_source_codes view
#   I. Validate
#
# Guardrails:
#   - --project is required; there is no default (forces a conscious choice).
#   - Prints the target project and prompts before any write (skip with --yes).
#   - Steps C-H use explicit --project_id on every bq command.
#   - Never runs against production on your behalf — you must invoke this yourself.

set -euo pipefail

# ── parse args ────────────────────────────────────────────────────────────────
PROJECT=""
YES=false
REFRESH_SCHEMAS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)          PROJECT="$2";        shift 2 ;;
    --yes)              YES=true;            shift   ;;
    --refresh-schemas)  REFRESH_SCHEMAS=true; shift  ;;
    *) echo "unknown argument: $1"; exit 1 ;;
  esac
done

if [[ -z "$PROJECT" ]]; then
  echo "error: --project is required"
  echo "  stage: --project nih-nci-dceg-connect-stg-5519"
  echo "  prod:  --project nih-nci-dceg-connect-prod-6d04"
  exit 1
fi

# ── derive paths from project ─────────────────────────────────────────────────
if [[ "$PROJECT" == *"prod"* ]]; then
  MAPPING="output/survey_columns_clean_mapped.csv"
  UNPIVOT_DIR="sql/unpivot"
  SCHEMAS_DIR="schemas/prod/CleanConnect"
else
  MAPPING="output/survey_columns_stage_mapped.csv"
  UNPIVOT_DIR="sql/unpivot_stage"
  SCHEMAS_DIR="schemas/stage/CleanConnect"
fi

# ── helper: substitute ${PROJECT} without requiring envsubst ──────────────────
bq_run() {
  local file="$1"
  sed "s/\${PROJECT}/$PROJECT/g" "$file" \
    | bq --project_id="$PROJECT" query --use_legacy_sql=false
}

bq_dry_run() {
  local file="$1"
  sed "s/\${PROJECT}/$PROJECT/g" "$file" \
    | bq --project_id="$PROJECT" query --use_legacy_sql=false --dry_run 2>&1
}

# ── confirm ───────────────────────────────────────────────────────────────────
echo ""
echo "  Project    : $PROJECT"
echo "  Mapping    : $MAPPING"
echo "  Unpivot dir: $UNPIVOT_DIR"
echo "  Refresh    : $REFRESH_SCHEMAS"
echo ""

if [[ "$YES" != true ]]; then
  read -r -p "Proceed? [y/N] " ans
  [[ "${ans,,}" == "y" ]] || { echo "aborted"; exit 0; }
fi

# ── Step A: refresh schemas + regenerate unpivot SQL (safe mode) ──────────────
if [[ "$REFRESH_SCHEMAS" == true ]]; then
  echo ""
  echo "=== Step A: refreshing schemas and regenerating unpivot SQL ==="
  python3 scripts/fetch_bq_schemas.py CleanConnect \
    --project "$PROJECT" \
    --output-dir "$(dirname "$SCHEMAS_DIR")"
  python3 scripts/generate_unpivot_sql.py \
    --schemas-dir "$SCHEMAS_DIR" \
    --mapping "$MAPPING" \
    --out-dir "$UNPIVOT_DIR" \
    --project "\${PROJECT}"
  echo "  regenerated $UNPIVOT_DIR"
fi

# ── Step B: offline smoke test ────────────────────────────────────────────────
echo ""
echo "=== Step B: offline smoke test ==="
python3 scripts/smoke_test_omop_hash.py

# ── Step C: deploy UDF ────────────────────────────────────────────────────────
echo ""
echo "=== Step C: deploying response_unique_id UDF ==="
bq_run sql/omop/response_unique_id_udf.sql
echo "  UDF deployed"

# ── Step D: set up dataset + responses + dims ─────────────────────────────────
echo ""
echo "=== Step D: setting up dataset, responses table, dims ==="
python3 scripts/setup_relational.py \
  --project "$PROJECT" \
  --mapping "$MAPPING" \
  --dims \
  --recreate \
  --yes

# ── Step E: dry-run all unpivot files ─────────────────────────────────────────
echo ""
echo "=== Step E: dry-run unpivot files (0 bytes billed) ==="
all_ok=true
for f in "$UNPIVOT_DIR"/unpivot_*.sql; do
  result=$(bq_dry_run "$f")
  if echo "$result" | grep -q "ERROR"; then
    echo "  FAILED: $f"
    echo "$result"
    all_ok=false
    break
  else
    echo "  ok: $f"
  fi
done

if [[ "$all_ok" != true ]]; then
  echo "Dry-run failed — aborting before any data is written."
  exit 1
fi

# ── Step F: populate responses ────────────────────────────────────────────────
echo ""
echo "=== Step F: populating responses (reads CleanConnect data) ==="
for f in "$UNPIVOT_DIR"/unpivot_*.sql; do
  echo -n "  loading: $(basename "$f") ... "
  bq --project_id="$PROJECT" query --use_legacy_sql=false < "$f" > /dev/null 2>&1 \
    && echo "ok" || { echo "FAILED"; exit 1; }
done

# ── Step G: type value columns ────────────────────────────────────────────────
echo ""
echo "=== Step G: typing value columns ==="
bq --project_id="$PROJECT" query --use_legacy_sql=false \
  < "$UNPIVOT_DIR/type_response_values.sql"

# ── Step H: create response_source_codes view ─────────────────────────────────
echo ""
echo "=== Step H: creating response_source_codes view ==="
bq_run sql/omop/response_source_codes.sql
echo "  view created/updated"

# ── Step I: validate ──────────────────────────────────────────────────────────
echo ""
echo "=== Step I: validation ==="
bq --project_id="$PROJECT" query --use_legacy_sql=false --format=pretty "
SELECT
  (SELECT COUNT(*) FROM \`$PROJECT.relational.responses\`)          AS responses_rows,
  COUNT(*)                                                           AS source_codes_rows,
  COUNT(DISTINCT response_unique_id)                                 AS n_unique_id,
  COUNTIF(response_unique_id <= 2000000000
       OR response_unique_id >= 9223372036854775807)                 AS out_of_omop_range
FROM \`$PROJECT.relational.response_source_codes\`"

echo ""
echo "=== Pipeline complete ==="
