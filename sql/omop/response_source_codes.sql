-- response_source_codes — Usagi input table for OMOP mapping.
-- NOT run against production; logic validated on synthetic data.
--
-- One row per distinct (secondary_source, source_question, question, response_value) combination,
-- deduplicated from relational.responses.
--
-- response_unique_id is the stable integer identity for each unique response — computed at unpivot
-- time by the response_unique_id UDF and stored on relational.responses. This table reads it
-- directly. It satisfies OMOP's custom-concept requirements (integer, > 2,000,000,000, < signed-64
-- max) and is Usagi's source_code (as a string cast). See sql/omop/response_unique_id_udf.sql.
--
-- GOVERNANCE: response_value_verbatim exposes free text = PII. Govern this table at its inputs'
--   sensitivity, and restrict which free-text questions you actually export to Usagi. That filtering
--   is downstream and never changes ids.

CREATE OR REPLACE TABLE `${PROJECT}.relational.response_source_codes`
OPTIONS(description="Usagi input — one row per distinct response. response_unique_id (from relational.responses) is the stable OMOP-compatible integer id and Usagi source_code. response_value_verbatim exposes free text -> govern as PII. See docs/omop_source_codes.md.")
AS
WITH distinct_responses AS (
  SELECT DISTINCT
    secondary_source_concept_id,
    source_question_concept_id,
    question_concept_id,
    response_value_as_string,
    response_unique_id
  FROM `${PROJECT}.relational.responses`
  WHERE response_value_as_string IS NOT NULL AND response_value_as_string <> ''
)
SELECT
  d.response_unique_id,

  -- the exact inputs, kept for audit / round-tripping back to responses
  d.secondary_source_concept_id,
  d.source_question_concept_id,
  d.question_concept_id,
  d.response_value_as_string AS response_value_verbatim,

  -- ── DECORATION — helpful, but never affects response_unique_id (safe to change anytime) ──
  -- convenience classification for choosing what to send to Usagi
  CASE
    WHEN qr.response_concept_id IS NOT NULL                                         THEN 'coded'
    WHEN SAFE_CAST(d.response_value_as_string AS FLOAT64) IS NOT NULL
      OR REGEXP_CONTAINS(d.response_value_as_string, r'^\d{4}-\d{2}-\d{2}')        THEN 'numeric_or_date'
    ELSE 'free_text'
  END AS response_kind,
  -- optional downstream grouping key for free text (NFC/trim/space/lowercase)
  LOWER(REGEXP_REPLACE(NORMALIZE(TRIM(d.response_value_as_string), NFC), r'\s+', ' ')) AS response_value_norm,
  -- Usagi's source_code_description: coded -> question + answer label; else question + verbatim
  CONCAT(COALESCE(q.question_text, ''), ' | ',
         COALESCE(resp.format_value, d.response_value_as_string)) AS source_code_description
FROM distinct_responses d
LEFT JOIN `${PROJECT}.relational.question`          q    USING (question_concept_id)
LEFT JOIN `${PROJECT}.relational.question_response` qr
       ON qr.question_concept_id = d.question_concept_id
      AND qr.response_concept_id = d.response_value_as_string
LEFT JOIN `${PROJECT}.relational.response`          resp
       ON resp.response_concept_id = d.response_value_as_string;
