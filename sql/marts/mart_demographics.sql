-- mart_demographics — participant-grain demographics.
-- FIRST PASS: a plain BigQuery VIEW (no dbt / no Jinja yet — to be reworked into a dbt model later).
-- Built on the long `responses` fact. Hardcoded to the stage project (copy-paste runnable); swap the
-- project for prod later. Transcribed from Analyticsphere/PR2-analyses → PR2_FinalDerivationsCode.rmd
-- (validate row-for-row against it before use).
--
-- DESIGN: pure code->label recodes JOIN the dictionary (`response` dim: response_concept_id ->
-- current_format_value, "N = " prefix stripped) instead of hand-typed CASE maps, so labels can't drift.
-- Column order pairs each coded answer with its label: <x>_concept_id, <x>_cat, ...
-- Coded answers are read from `response_value_as_string` (always populated).

CREATE OR REPLACE VIEW `${PROJECT}.marts.mart_demographics`(
  connect_id                OPTIONS(description="Participant Connect ID"),
  education_concept_id      OPTIONS(description="Education answer concept ID (coded; D_367803647_D_367803647)"),
  education_cat             OPTIONS(description="Education category label from the dictionary response dim ('Missing' if unanswered)"),
  marital_status_concept_id OPTIONS(description="Marital status answer concept ID (coded; D_783167257)"),
  marital_status_cat        OPTIONS(description="Marital status category label from the dictionary response dim ('Missing' if unanswered)"),
  income_concept_id         OPTIONS(description="Household income answer concept ID (coded; D_759004335)"),
  income_cat                OPTIONS(description="Household income category label from the dictionary response dim ('Missing' if unanswered)")
)
OPTIONS(description="Participant-grain demographics (education, marital status, income) derived from the responses fact. First-pass BigQuery view (pre-dbt); labels sourced from the dictionary. Transcribed from Analyticsphere/PR2-analyses — validate row-for-row before reporting use.")
AS
WITH pivoted AS (
  SELECT
    connect_id,
    MAX(IF(question_concept_id = '367803647'
           AND current_source_question_concept_id = '367803647',
           response_value_as_string, NULL)) AS education_concept_id,      -- D_367803647_D_367803647
    MAX(IF(question_concept_id = '783167257', response_value_as_string, NULL)) AS marital_status_concept_id,  -- D_783167257
    MAX(IF(question_concept_id = '759004335', response_value_as_string, NULL)) AS income_concept_id            -- D_759004335
  FROM `${PROJECT}.relational.responses`
  GROUP BY connect_id
)
SELECT
  p.connect_id,
  p.education_concept_id,
  COALESCE(REGEXP_REPLACE(e.current_format_value, r'^\s*\d+\s*=\s*', ''), 'Missing') AS education_cat,
  p.marital_status_concept_id,
  COALESCE(REGEXP_REPLACE(m.current_format_value, r'^\s*\d+\s*=\s*', ''), 'Missing') AS marital_status_cat,
  p.income_concept_id,
  COALESCE(REGEXP_REPLACE(i.current_format_value, r'^\s*\d+\s*=\s*', ''), 'Missing') AS income_cat
FROM pivoted p
LEFT JOIN `${PROJECT}.relational.response` e ON e.response_concept_id = p.education_concept_id
LEFT JOIN `${PROJECT}.relational.response` m ON m.response_concept_id = p.marital_status_concept_id
LEFT JOIN `${PROJECT}.relational.response` i ON i.response_concept_id = p.income_concept_id;
