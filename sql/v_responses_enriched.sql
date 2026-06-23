-- ============================================================================
-- v_responses_enriched — Phase 1 analyst convenience view (Model A)
-- Pre-joins the CIDTool dictionary onto the long-format `responses` fact so every
-- answer row is self-describing: zero joins for analysts. Seed of Phase 2 `fact_response`.
--
-- Built over the verbatim Model A tables (see sql/data_model_modest.sql).
-- Survey/domain come from the STAMPED secondary_source_concept_id on the row (so a reused
-- question concept resolves to the survey it was actually answered in, not its "home" survey).
-- All LEFT JOINs, so an answer never drops out when metadata is missing/dirty.
-- Grain: one row per answer atom (driven from `responses` outward — no fan-out).
-- ============================================================================

CREATE OR REPLACE VIEW v_responses_enriched AS
SELECT
  r.response_row_id,
  r.connect_id,
  ps.primary_source         AS domain,
  ss.secondary_source       AS survey,
  sq.source_question_text   AS source_question,
  q.current_question_text   AS question_text,
  q.question_type,
  r.loop_instance,
  r.response_concept_id,
  resp.current_format_value AS response_label,     -- the chosen answer, e.g. "1 = Yes"
  r.value                   AS response_value,      -- free-text / numeric answers
  opt.response_option_set,                          -- the full offered menu for this question
  vm.pii,
  vm.variable_type,
  vm.variable_label,
  -- keys + provenance kept for traceability
  r.question_concept_id,
  r.secondary_source_concept_id,
  r.current_source_question_concept_id,
  r.source_table,
  r.source_column
FROM responses r
LEFT JOIN secondary_source  ss   ON ss.secondary_source_concept_id        = r.secondary_source_concept_id
LEFT JOIN primary_source    ps   ON ps.primary_source_concept_id          = ss.primary_source_concept_id
LEFT JOIN question          q    ON q.question_concept_id                 = r.question_concept_id
LEFT JOIN source_question   sq   ON sq.current_source_question_concept_id = r.current_source_question_concept_id
LEFT JOIN response          resp ON resp.response_concept_id              = r.response_concept_id
LEFT JOIN variable_metadata vm   ON vm.question_concept_id         = r.question_concept_id
                                AND vm.secondary_source_concept_id = r.secondary_source_concept_id
                                AND vm.response_concept_id         = r.response_concept_id
-- offered option set per question: aggregate the allowed-answers bridge into one string.
-- NOTE: source is the dictionary's question_response list (imperfect — e.g. tooth-loss lists the
-- "No" value concept as an option); ordered by response_concept_id since Model A has no display_order
-- (that arrives with Phase 2 response_options).
LEFT JOIN (
  SELECT qr.question_concept_id,
         STRING_AGG(o.current_format_value, '; ' ORDER BY qr.response_concept_id) AS response_option_set
  FROM question_response qr
  LEFT JOIN response o ON o.response_concept_id = qr.response_concept_id
  GROUP BY qr.question_concept_id
) opt ON opt.question_concept_id = r.question_concept_id;
