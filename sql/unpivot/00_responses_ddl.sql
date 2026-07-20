-- Target responses fact table + colmap view for the responses unpivot.
-- Schema source of truth: schemas/relational/responses.json (used by scripts/setup_relational.py).
-- NOT run against production. Run scripts/setup_relational.py to create these objects.
CREATE TABLE IF NOT EXISTS `${PROJECT}.relational.responses` (
  connect_id STRING,
  secondary_source_concept_id STRING,           -- the SURVEY (stamped from the table via colmap)
  source_question_concept_id STRING,    -- grid / select-all parent; NULL if standalone
  question_concept_id STRING,
  loop_instance INT64,                          -- the _N loop suffix (1 if not looped)
  question_version STRING,                      -- the _v2 question/concept revision tag
  response_value_as_string STRING,              -- verbatim raw cell — always populated
  response_value_as_number FLOAT64,             -- numeric answers (Num/Year/count)
  response_value_as_concept_id STRING,          -- coded answer (single/multi-select)
  response_unique_id INT64,                     -- stable OMOP-compatible integer id; see sql/omop/response_unique_id_udf.sql
  source_table STRING,
  source_column STRING
);

CREATE OR REPLACE VIEW `${PROJECT}.relational.colmap` AS
SELECT
  `table`                    AS table_name,
  `column`                   AS source_column,
  secondary_source_concept_id,
  NULLIF(source_question_concept_id, '') AS source_question_concept_id,  -- NULL = standalone question
  question_concept_id,
  COALESCE(loop_number, 1)   AS loop_instance,                                   -- default 1 when not looped (INTEGER in table)
  NULLIF(version_tag, '')    AS question_version
FROM `${PROJECT}.relational.survey_columns_clean_mapped`;
