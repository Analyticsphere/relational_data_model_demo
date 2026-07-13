-- mart_demographics — participant-grain demographics.
-- FIRST PASS: a plain BigQuery VIEW (no dbt / no Jinja yet — to be reworked into a dbt model later).
-- Built on the long `responses` fact.
--
-- DESIGN: for pure code->label recodes we JOIN the dictionary (`response` dim: response_concept_id ->
-- current_format_value) instead of hand-typing CASE maps — the labels stay in sync with the dictionary
-- and can't drift. (Transcribed CASE maps are only needed for *category collapses* or *derived bins*,
-- e.g. BMI category in mart_anthropometry — those are genuine analytic logic, not dictionary labels.)
-- Reference derivations: Analyticsphere/PR2-analyses → PR2_FinalDerivationsCode.rmd.
--
-- The dictionary `current_format_value` is "N = Label" (e.g. "0 = Never married"); we expose both the raw
-- value and a stripped label. Coded answers are read from `response_value_as_string` (always populated).

CREATE OR REPLACE VIEW `${PROJECT}.marts.mart_demographics`(
  connect_id         OPTIONS(description="Participant Connect ID"),
  education_cid      OPTIONS(description="Education answer concept ID (coded; D_367803647_D_367803647)"),
  marital_cid        OPTIONS(description="Marital status answer concept ID (coded; D_783167257)"),
  income_cid         OPTIONS(description="Household income answer concept ID (coded; D_759004335)"),
  education_cat      OPTIONS(description="Education category label from the dictionary response dim ('Missing' if unanswered)"),
  marital_status_cat OPTIONS(description="Marital status category label from the dictionary response dim ('Missing' if unanswered)"),
  income_cat         OPTIONS(description="Household income category label from the dictionary response dim ('Missing' if unanswered)")
)
OPTIONS(description="Participant-grain demographics (education, marital status, income) derived from the responses fact. First-pass BigQuery view (pre-dbt); labels sourced from the dictionary. Transcribed from Analyticsphere/PR2-analyses — validate row-for-row before reporting use.")
AS
WITH pivoted AS (
  SELECT
    connect_id,
    MAX(IF(question_concept_id = '367803647'
           AND current_source_question_concept_id = '367803647',
           response_value_as_string, NULL)) AS education_cid,   -- D_367803647_D_367803647
    MAX(IF(question_concept_id = '783167257', response_value_as_string, NULL)) AS marital_cid,  -- D_783167257
    MAX(IF(question_concept_id = '759004335', response_value_as_string, NULL)) AS income_cid     -- D_759004335
  FROM `${PROJECT}.relational.responses`
  GROUP BY connect_id
)
SELECT
  p.connect_id,

  -- codes (the coded answer concept IDs) kept for lineage / joins
  p.education_cid,
  p.marital_cid,
  p.income_cid,

  -- labels from the dictionary (strip the leading "N = " so it reads like a clean category)
  COALESCE(REGEXP_REPLACE(e.current_format_value, r'^\s*\d+\s*=\s*', ''), 'Missing') AS education_cat,
  COALESCE(REGEXP_REPLACE(m.current_format_value, r'^\s*\d+\s*=\s*', ''), 'Missing') AS marital_status_cat,
  COALESCE(REGEXP_REPLACE(i.current_format_value, r'^\s*\d+\s*=\s*', ''), 'Missing') AS income_cat

FROM pivoted p
LEFT JOIN `${PROJECT}.relational.response` e ON e.response_concept_id = p.education_cid
LEFT JOIN `${PROJECT}.relational.response` m ON m.response_concept_id = p.marital_cid
LEFT JOIN `${PROJECT}.relational.response` i ON i.response_concept_id = p.income_cid;
