-- relational2.responses — the SATA "option-as-answer" test copy of relational.responses.
-- NOT run against production; logic validated on synthetic data (scripts/smoke_test_relational2.py).
--
-- ┌─ WHAT THIS IS ────────────────────────────────────────────────────────────────────────────────────┐
-- │ relational2 is a controlled A/B copy of the model for evaluating the alternative Select-All-That-   │
-- │ Apply representation. relational2.responses is IDENTICAL to relational.responses EXCEPT that SATA    │
-- │ rows are remodeled option-as-answer and response_unique_id is RECOMPUTED on the new fields:         │
-- │                                                                                                     │
-- │   legacy (relational)          option-as-answer (relational2)                                       │
-- │   question   = the OPTION       question   = the SATA PARENT                                         │
-- │   source_q   = the PARENT       source_q   = NULL                                                   │
-- │   answer     = (raw cell)       answer     = the OPTION concept  (as_string + as_concept_id)        │
-- │   unique_id  = f(sec,parent,option,cell)   unique_id = f(sec,'',parent,option)   ← differs for SATA │
-- │                                                                                                     │
-- │ Non-SATA rows are byte-identical (same fields -> same response_unique_id), so any downstream         │
-- │ difference between relational and relational2 is attributable ONLY to the SATA remodel.             │
-- └─────────────────────────────────────────────────────────────────────────────────────────────────┘
--
-- SCOPE: SATA only. Grids keep question = sub-item (a grid sub-question is a genuinely distinct question);
--   MC single-select is already option-as-answer. Identification is isolated in the `sata` CTE:
--   question_type LIKE '%select all that apply%' (matches Optional/Required/Loops/DisplayIf variants).
--   NB: question_type is ~62% blank/dirty in the dictionary — SATA rows lacking a clean type are NOT
--   remodeled. See docs/sata_representation.md.
--
-- DEPENDS ON: relational.responses (built), relational.question (dim), and the
--   relational.response_unique_id UDF (deployed). Run AFTER the relational pipeline.
-- RUN: sed 's/${PROJECT}/<project>/g' this_file | bq --project_id=<project> query --use_legacy_sql=false

CREATE SCHEMA IF NOT EXISTS `${PROJECT}.relational2`
  OPTIONS(description="A/B test copy of the relational model using the SATA option-as-answer representation. responses = relational.responses with Select-All-That-Apply rows remodeled and response_unique_id recomputed; non-SATA rows identical. See docs/sata_representation.md.");

CREATE OR REPLACE TABLE `${PROJECT}.relational2.responses`
OPTIONS(description="SATA option-as-answer copy of relational.responses. SATA rows: question <- parent, answer <- option, source_question <- NULL, response_unique_id RECOMPUTED. Non-SATA rows identical. Built from relational.responses; see sql/relational2/build_responses.sql.")
AS
WITH sata AS (
  -- questions modeled as Select-All-That-Apply (the type lives on the OPTION row in the legacy shape)
  SELECT question_concept_id
  FROM `${PROJECT}.relational.question`
  WHERE LOWER(question_type) LIKE '%select all that apply%'
),
flagged AS (
  SELECT r.*,
         (s.question_concept_id IS NOT NULL AND r.source_question_concept_id IS NOT NULL) AS is_sata
  FROM `${PROJECT}.relational.responses` r
  LEFT JOIN sata s ON s.question_concept_id = r.question_concept_id
),
remodeled AS (
  SELECT
    connect_id,
    secondary_source_concept_id,
    -- SATA: the parent moves to `question`, so source_question (which only held the parent) is freed
    CASE WHEN is_sata THEN CAST(NULL AS STRING) ELSE source_question_concept_id END AS source_question_concept_id,
    CASE WHEN is_sata THEN source_question_concept_id ELSE question_concept_id END   AS question_concept_id,
    loop_instance,
    question_version,
    -- SATA: the OPTION concept (the legacy question_concept_id) becomes the answer
    CASE WHEN is_sata THEN question_concept_id ELSE response_value_as_string END     AS response_value_as_string,
    source_table,
    source_column
  FROM flagged
)
SELECT
  connect_id,
  secondary_source_concept_id,
  source_question_concept_id,
  question_concept_id,
  loop_instance,
  question_version,
  response_value_as_string,
  -- re-derive typed value columns from the (possibly remodeled) string — same rules as the unpivot
  CASE WHEN REGEXP_CONTAINS(response_value_as_string, r'^\d{9}$')
       THEN response_value_as_string ELSE NULL END                              AS response_value_as_concept_id,
  CASE WHEN NOT REGEXP_CONTAINS(response_value_as_string, r'^\d{9}$')
        AND REGEXP_CONTAINS(response_value_as_string, r'^\d{4}-\d{2}-\d{2}$')
        AND SAFE_CAST(response_value_as_string AS DATE) IS NOT NULL
       THEN SAFE_CAST(response_value_as_string AS DATE) ELSE NULL END            AS response_value_as_date,
  CASE WHEN NOT REGEXP_CONTAINS(response_value_as_string, r'^\d{9}$')
        AND NOT REGEXP_CONTAINS(response_value_as_string, r'^\d{4}-\d{2}-\d{2}$')
       THEN SAFE_CAST(response_value_as_string AS FLOAT64) ELSE NULL END         AS response_value_as_number,
  -- RECOMPUTE the id on the remodeled fields: SATA rows get new ids; non-SATA rows keep the same id
  `${PROJECT}.relational.response_unique_id`(
    secondary_source_concept_id,
    source_question_concept_id,
    question_concept_id,
    response_value_as_string
  )                                                                             AS response_unique_id,
  source_table,
  source_column
FROM remodeled;
