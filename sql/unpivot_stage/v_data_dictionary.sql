-- v_data_dictionary — denormalized flat data dictionary view over the CIDTool-style dimension tables.
-- Mirrors the grain of the source masterFile.csv: one row per (question × allowed response option).
-- Free-text / numeric questions (no response options) get one row with a NULL response.
-- Equivalent to the DuckDB v_data_dictionary in sql/build_dimension_tables.sql, ported to BigQuery.

CREATE OR REPLACE VIEW `nih-nci-dceg-connect-stg-5519.relational.v_data_dictionary` AS
SELECT
  ps.primary_source_concept_id,
  ps.primary_source,
  q.secondary_source_concept_id,
  ss.secondary_source,
  q.current_source_question_concept_id,
  sq.source_question_text,
  sq.grid_source_question_name,
  q.question_concept_id,
  q.current_question_text,
  q.question_type,
  r.response_concept_id,
  r.current_format_value
FROM `nih-nci-dceg-connect-stg-5519.relational.question` q
LEFT JOIN `nih-nci-dceg-connect-stg-5519.relational.secondary_source` ss
  ON ss.secondary_source_concept_id = q.secondary_source_concept_id
LEFT JOIN `nih-nci-dceg-connect-stg-5519.relational.primary_source` ps
  ON ps.primary_source_concept_id = ss.primary_source_concept_id
LEFT JOIN `nih-nci-dceg-connect-stg-5519.relational.source_question` sq
  ON sq.current_source_question_concept_id = q.current_source_question_concept_id
LEFT JOIN `nih-nci-dceg-connect-stg-5519.relational.question_response` qr
  ON qr.question_concept_id = q.question_concept_id
LEFT JOIN `nih-nci-dceg-connect-stg-5519.relational.response` r
  ON r.response_concept_id = qr.response_concept_id
ORDER BY
  primary_source_concept_id,
  secondary_source_concept_id,
  current_source_question_concept_id NULLS FIRST,
  question_concept_id,
  response_concept_id NULLS FIRST;
