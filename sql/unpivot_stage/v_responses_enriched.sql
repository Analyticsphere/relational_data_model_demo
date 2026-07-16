-- v_responses_enriched — analyst convenience view: responses fact pre-joined to the full dictionary
-- context so every answer row is self-describing. Zero joins needed for most analyses.
--
-- Adapted from sql/v_responses_enriched.sql to match the current responses table schema:
--   - uses response_value_as_string / _as_number / _as_concept_id (not legacy `value` / `response_concept_id`)
--   - no response_row_id (not yet added to table)
--   - no variable_metadata join (table not yet loaded; deferred to enhancement backlog)
--
-- Grain: one row per answer atom (driven from `responses` — no fan-out).
-- survey/domain resolved from the STAMPED secondary_source_concept_id on each row, so a reused
-- question concept resolves to the survey it was actually answered in, not its "home" survey.
-- All LEFT JOINs: an answer never drops out when dictionary metadata is missing or dirty.

CREATE OR REPLACE VIEW `nih-nci-dceg-connect-stg-5519.relational.v_responses_enriched` AS
SELECT
  -- participant + survey context
  r.connect_id,
  ps.primary_source                                   AS domain,
  ss.secondary_source                                 AS survey,
  r.secondary_source_concept_id,

  -- question placement context
  sq.source_question_text                             AS source_question,
  r.source_question_concept_id,

  -- question
  q.question_text,
  q.question_type,
  r.question_concept_id,
  r.question_version,
  r.loop_instance,

  -- answer values (OMOP observation-style; as_string is always populated)
  r.response_value_as_string,
  r.response_value_as_number,
  r.response_value_as_concept_id,
  r.response_value_as_date,
  resp.format_value                           AS response_label,  -- human label for coded answers

  -- offered option set for this question (all allowed responses, semicolon-joined)
  opt.response_option_set,

  -- provenance
  r.source_table,
  r.source_column
FROM `nih-nci-dceg-connect-stg-5519.relational.responses` r
LEFT JOIN `nih-nci-dceg-connect-stg-5519.relational.secondary_source` ss
  ON ss.secondary_source_concept_id = r.secondary_source_concept_id
LEFT JOIN `nih-nci-dceg-connect-stg-5519.relational.primary_source` ps
  ON ps.primary_source_concept_id = ss.primary_source_concept_id
LEFT JOIN `nih-nci-dceg-connect-stg-5519.relational.question` q
  ON q.question_concept_id = r.question_concept_id
LEFT JOIN `nih-nci-dceg-connect-stg-5519.relational.source_question` sq
  ON sq.source_question_concept_id = r.source_question_concept_id
LEFT JOIN `nih-nci-dceg-connect-stg-5519.relational.response` resp
  ON resp.response_concept_id = r.response_value_as_concept_id
-- offered option set: aggregate the question_response bridge into one readable string per question
LEFT JOIN (
  SELECT
    qr.question_concept_id,
    STRING_AGG(o.format_value, '; ' ORDER BY qr.response_concept_id) AS response_option_set
  FROM `nih-nci-dceg-connect-stg-5519.relational.question_response` qr
  LEFT JOIN `nih-nci-dceg-connect-stg-5519.relational.response` o
    ON o.response_concept_id = qr.response_concept_id
  GROUP BY qr.question_concept_id
) opt ON opt.question_concept_id = r.question_concept_id;
