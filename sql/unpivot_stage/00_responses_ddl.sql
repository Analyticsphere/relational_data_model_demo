-- Target fact + colmap for the responses unpivot. NOT run against production.
--
-- CLUSTERING STRATEGY (for production scale — ~55M rows at 200k participants, ~110M at full cohort):
--
--   Recommended: CLUSTER BY (secondary_source_concept_id, question_concept_id, connect_id)
--   Rationale:
--     1. secondary_source_concept_id first — most queries filter by survey; 10 surveys means
--        each cluster block covers ~10% of the table (good initial pruning).
--     2. question_concept_id second — within a survey, analyses are almost always
--        question-specific ("distribution of answers to Q"); high cardinality (~3,240 concepts)
--        makes this highly selective.
--     3. connect_id third — participant lookups and cohort-level queries benefit from the
--        remaining sort order.
--   Benefit: estimated 70–85% scan reduction for typical question-level and survey-level queries.
--
--   To enable: add OPTIONS(clustering_fields=["secondary_source_concept_id","question_concept_id","connect_id"])
--   to the CREATE TABLE statement before the first load. Recreate the table + re-run unpivot SQL.
--
--   FUTURE — partition by survey_completed_at DATE once response_sessions timestamps are pulled
--   from the participants table (#5 in docs/enhancement_backlog.md). Partition by DATE +
--   retain the clustering — BigQuery's recommended pattern for large event/observation tables.

CREATE TABLE IF NOT EXISTS `nih-nci-dceg-connect-stg-5519.relational.responses` (
  connect_id STRING,
  secondary_source_concept_id STRING,           -- the SURVEY (stamped from the table via colmap)
  current_source_question_concept_id STRING,    -- grid / select-all parent; NULL if standalone
  question_concept_id STRING,
  loop_instance INT64,                          -- the _N loop suffix (1 if not looped)
  question_version STRING,                      -- the _v2 question/concept revision tag
  -- value columns (OMOP observation-style). as_string is ALWAYS the verbatim cell (lossless source of
  -- truth); as_number / as_concept_id are typed extracts filled by a later step keyed on question_type.
  response_value_as_string STRING,              -- verbatim raw cell — always populated
  response_value_as_number FLOAT64,             -- numeric answers (Num/Year/count) for direct AVG/SUM
  response_value_as_concept_id STRING,          -- coded answer (single/multi-select) -> joins response / response_options / concept_relationship
  source_table STRING,
  source_column STRING
);

-- colmap: a clean-named view over the loaded column->placement mapping. Load the mapping first, e.g.
--   bq load --autodetect --source_format=CSV relational.survey_columns_clean_mapped \
--           gs://<bucket>/survey_columns_clean_mapped.csv
-- (`table`/`column` are reserved words -> backticked and aliased below.)
CREATE OR REPLACE VIEW `nih-nci-dceg-connect-stg-5519.relational.colmap` AS
SELECT
  `table`                    AS table_name,
  `column`                   AS source_column,
  secondary_source_concept_id,
  NULLIF(source_question_concept_id, '') AS current_source_question_concept_id,  -- NULL = standalone question
  question_concept_id,
  COALESCE(SAFE_CAST(NULLIF(loop_number, '') AS INT64), 1) AS loop_instance,  -- default 1 when not looped
  NULLIF(version_tag, '')     AS question_version
FROM `nih-nci-dceg-connect-stg-5519.relational.survey_columns_clean_mapped`;
