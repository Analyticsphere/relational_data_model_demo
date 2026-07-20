-- Unpivot CleanConnect.menstrualSurvey -> relational.responses  (GENERATED from schemas/CleanConnect/menstrualSurvey.json)
-- NOT run against production. Validate later: bq query --dry_run < this file.  4 columns unpivoted.
-- Idempotent: clears this table's rows first, so the file can be re-run without duplicating.
DELETE FROM `${PROJECT}.relational.responses` WHERE source_table = 'CleanConnect.menstrualSurvey';

INSERT INTO `${PROJECT}.relational.responses`
  (connect_id, secondary_source_concept_id, source_question_concept_id, question_concept_id,
   loop_instance, question_version, response_value_as_string, response_value_as_number,
   response_value_as_concept_id, response_unique_id, source_table, source_column)
SELECT
  u.Connect_ID                                       AS connect_id,     -- passthrough belongs to the UNPIVOT alias
  m.secondary_source_concept_id,
  m.source_question_concept_id,
  m.question_concept_id,
  m.loop_instance,                                                      -- 1 when not looped (colmap COALESCEs)
  m.question_version,
  u.value                                            AS response_value_as_string,   -- verbatim raw cell (always)
  CAST(NULL AS FLOAT64)                              AS response_value_as_number,    -- typed later by question_type
  CAST(NULL AS STRING)                               AS response_value_as_concept_id,-- coded answer, set later by question_type
  `${PROJECT}.relational.response_unique_id`(          -- stable integer id; see sql/omop/response_unique_id_udf.sql
    m.secondary_source_concept_id,
    m.source_question_concept_id,
    m.question_concept_id,
    u.value
  )                                                  AS response_unique_id,
  'CleanConnect.menstrualSurvey'                             AS source_table,
  u.source_column
FROM (
  SELECT Connect_ID,
    `d_593467240`,
    `d_784119588`,
    `d_901199566`,
    `d_951357171`
  FROM `${PROJECT}.CleanConnect.menstrualSurvey`
) t
UNPIVOT(value FOR source_column IN (`d_593467240`, `d_784119588`, `d_901199566`, `d_951357171`)) u    -- BigQuery UNPIVOT drops NULL cells => unanswered = no row
JOIN `${PROJECT}.relational.colmap` m
  ON m.table_name = 'menstrualSurvey' AND m.source_column = u.source_column;
