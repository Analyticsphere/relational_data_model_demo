-- v_responses_sata_v2 — the SELECT-ALL-THAT-APPLY "option-as-answer" representation.
-- NOT run against production. A pure VIEW over relational.responses (no data copied).
--
-- ┌─ TWO REPRESENTATIONS OF SATA, side by side, until we pick one ─────────────────────────────────────┐
-- │ The `responses` fact is the LEGACY representation ("option-as-question"): each checked Select-All   │
-- │ option is its own row with                                                                          │
-- │     question_concept_id        = the OPTION      (e.g. 165596977, "American Indian or Alaska Native")│
-- │     source_question_concept_id = the SATA PARENT (e.g. 479143504, "Which categories describe you?")  │
-- │ This VIEW exposes the ALTERNATIVE ("option-as-answer"), matching how single-select Multiple Choice  │
-- │ is already modeled (question -> chosen answer):                                                     │
-- │     question_concept_id           = the SATA PARENT   (the question)                                │
-- │     response_value_as_concept_id  = the OPTION        (the chosen answer)                           │
-- │     source_question_concept_id    = NULL              (was only holding the parent)                 │
-- │ One row per SELECTED option, same as MC. Non-SATA rows pass through UNCHANGED.                       │
-- └───────────────────────────────────────────────────────────────────────────────────────────────────┘
--
-- SCOPE: SATA only. Grids are deliberately NOT remodeled — a grid sub-item (e.g. "Tylenol frequency") is a
--   genuinely distinct question, so it keeps question = sub-item. MC single-select is already option-as-answer.
--
-- IDENTIFYING SATA: a row is remodeled iff its question (the OPTION row in the legacy shape) is typed
--   Select-All-That-Apply in the `question` dimension AND it carries a parent. The predicate is isolated in
--   the `sata` CTE — the ONE place to refine as the dictionary's question_type is cleaned. It matches every
--   variant (Optional / Required / Loops / DisplayIf …) via LIKE '%select all that apply%'.
--
-- REVERSIBLE / LOSSLESS: orig_question_concept_id + orig_source_question_concept_id retain the legacy
--   placement, and `sata_remodeled` flags which rows were swapped — so the legacy shape is recoverable and
--   downstream code can choose a source explicitly (see docs/sata_representation.md).
--
-- HASH NOTE: the OMOP source-code hash (sql/omop/response_source_codes.sql) is a function of
--   (secondary_source, source_question, question, response_value_as_string). SATA rows differ between the two
--   representations in three of those fields, so ids differ by representation — decide the representation
--   BEFORE freezing the hash contract.

CREATE OR REPLACE VIEW `${PROJECT}.relational.v_responses_sata_v2` AS
WITH sata AS (
  -- questions modeled as Select-All-That-Apply (type lives on the OPTION row in the legacy shape)
  SELECT question_concept_id
  FROM `${PROJECT}.relational.question`
  WHERE LOWER(question_type) LIKE '%select all that apply%'
)
SELECT
  r.connect_id,
  r.secondary_source_concept_id,

  -- SATA row  -> question becomes the PARENT; everything else -> unchanged
  CASE WHEN is_sata THEN r.source_question_concept_id ELSE r.question_concept_id END AS question_concept_id,
  -- the parent was the only thing source_question held for SATA; free it
  CASE WHEN is_sata THEN CAST(NULL AS STRING) ELSE r.source_question_concept_id END  AS source_question_concept_id,

  r.loop_instance,
  r.question_version,

  -- SATA row  -> the OPTION concept is the ANSWER (as string AND as concept_id)
  CASE WHEN is_sata THEN r.question_concept_id ELSE r.response_value_as_string END     AS response_value_as_string,
  r.response_value_as_number,
  CASE WHEN is_sata THEN r.question_concept_id ELSE r.response_value_as_concept_id END AS response_value_as_concept_id,

  -- lineage: keep the legacy placement so this is lossless / reversible
  is_sata                                                                   AS sata_remodeled,
  r.question_concept_id                                                     AS orig_question_concept_id,
  r.source_question_concept_id                                              AS orig_source_question_concept_id,
  r.source_table,
  r.source_column
FROM (
  SELECT r.*, (s.question_concept_id IS NOT NULL
               AND r.source_question_concept_id IS NOT NULL) AS is_sata
  FROM `${PROJECT}.relational.responses` r
  LEFT JOIN sata s ON s.question_concept_id = r.question_concept_id
) r;
