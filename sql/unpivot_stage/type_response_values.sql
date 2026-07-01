-- type_response_values.sql — populate typed value columns from response_value_as_string.
--
-- WHY THIS IS A SEPARATE STEP:
--   CleanConnect stores ALL cell values as strings — coded answers (concept IDs like "353358909"),
--   numeric answers ("25", "2024"), date answers ("2024-07-01"), and free text are indistinguishable
--   at unpivot time. This step routes each verbatim value to the correct typed column.
--
-- ROUTING LOGIC (mutually exclusive, applied in priority order):
--   9-digit integer     → response_value_as_concept_id  (coded single/multi-select answer)
--   ISO date YYYY-MM-DD → response_value_as_date        (Special Functions date questions)
--   numeric (non-9-digit, non-date) → response_value_as_number (Num/Year/count question)
--   anything else       → stays only in response_value_as_string (free text / unrecognized)
--
-- The 9-digit pattern is a reliable signal: no natural survey answer (age, year, count, text)
-- is a 9-digit integer — that is the Connect concept ID convention. Verified against the
-- question_response bridge: 71,223 / 71,428 (99.7%) of 9-digit values are on questions confirmed
-- as coded in the bridge; the remaining 0.3% are dictionary gaps but are still concept IDs.
--
-- See docs/value_typing.md for a full account of limitations and edge cases for each routing rule.
--
-- IDEMPOTENT: safe to re-run. NULLs are overwritten; existing non-NULL typed values are replaced.
--
-- Run after all unpivot_*.sql have loaded:
--   bq --project_id=nih-nci-dceg-connect-stg-5519 query --use_legacy_sql=false \
--     < sql/unpivot_stage/type_response_values.sql

-- Step 1: coded answers → response_value_as_concept_id
UPDATE `nih-nci-dceg-connect-stg-5519.relational.responses`
SET response_value_as_concept_id = response_value_as_string
WHERE REGEXP_CONTAINS(response_value_as_string, r'^\d{9}$');

-- Step 2: date answers → response_value_as_date
-- Excludes 9-digit values (already routed as concept IDs).
-- YYYY-MM-DD is the only format emitted by CIDTool; other formats remain in response_value_as_string.
UPDATE `nih-nci-dceg-connect-stg-5519.relational.responses`
SET response_value_as_date = SAFE_CAST(response_value_as_string AS DATE)
WHERE NOT REGEXP_CONTAINS(response_value_as_string, r'^\d{9}$')
  AND REGEXP_CONTAINS(response_value_as_string, r'^\d{4}-\d{2}-\d{2}$')
  AND SAFE_CAST(response_value_as_string AS DATE) IS NOT NULL;

-- Step 3: numeric answers → response_value_as_number
-- Excludes 9-digit values (concept IDs) and ISO date strings (already routed above).
UPDATE `nih-nci-dceg-connect-stg-5519.relational.responses`
SET response_value_as_number = SAFE_CAST(response_value_as_string AS FLOAT64)
WHERE NOT REGEXP_CONTAINS(response_value_as_string, r'^\d{9}$')
  AND NOT REGEXP_CONTAINS(response_value_as_string, r'^\d{4}-\d{2}-\d{2}$')
  AND SAFE_CAST(response_value_as_string AS FLOAT64) IS NOT NULL;
