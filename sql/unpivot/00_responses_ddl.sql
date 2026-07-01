-- Target fact + colmap for the responses unpivot. NOT run against production.

CREATE TABLE IF NOT EXISTS `${PROJECT}.relational.responses` (
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
CREATE OR REPLACE VIEW `${PROJECT}.relational.colmap` AS
SELECT
  `table`                    AS table_name,
  `column`                   AS source_column,
  secondary_source_concept_id,
  NULLIF(source_question_concept_id, '') AS current_source_question_concept_id,  -- NULL = standalone question
  question_concept_id,
  COALESCE(SAFE_CAST(NULLIF(loop_number, '') AS INT64), 1) AS loop_instance,  -- default 1 when not looped
  NULLIF(version_tag, '')     AS question_version
FROM `${PROJECT}.relational.survey_columns_clean_mapped`;
