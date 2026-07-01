-- type_response_values.sql — populate response_value_as_concept_id and response_value_as_number
-- from the verbatim response_value_as_string already loaded by the unpivot step.
--
-- WHY THIS IS A SEPARATE STEP:
--   CleanConnect stores ALL cell values as strings — coded answers (concept IDs like "353358909"),
--   numeric answers ("25", "2024"), and free text are indistinguishable at unpivot time without
--   knowing the question type. This step routes each verbatim value to the correct typed column.
--
-- ROUTING LOGIC:
--   9-digit integer  → response_value_as_concept_id  (coded single/multi-select answer)
--   numeric (non-9-digit) → response_value_as_number (Num/Year/count question)
--   anything else    → stays only in response_value_as_string (free text)
--
-- The 9-digit pattern is a reliable signal: no natural survey answer (age, year, count, text)
-- is a 9-digit integer — that is the Connect concept ID convention. This is verified against the
-- question_response bridge: 71,223 / 71,428 (99.7%) of 9-digit values are on questions confirmed
-- as coded in the bridge; the remaining 0.3% are dictionary gaps but are still concept IDs.
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

-- Step 2: numeric answers → response_value_as_number
-- Excludes 9-digit values (already routed above) to avoid miscasting concept IDs as numbers.
UPDATE `nih-nci-dceg-connect-stg-5519.relational.responses`
SET response_value_as_number = SAFE_CAST(response_value_as_string AS FLOAT64)
WHERE NOT REGEXP_CONTAINS(response_value_as_string, r'^\d{9}$')
  AND SAFE_CAST(response_value_as_string AS FLOAT64) IS NOT NULL;
