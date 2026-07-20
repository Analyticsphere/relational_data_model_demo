-- Unpivot CleanConnect.menstrualSurvey -> relational.responses  (GENERATED from schemas/CleanConnect/menstrualSurvey.json)
-- NOT run against production. Validate later: bq query --dry_run < this file.  4 columns unpivoted.
-- Idempotent: clears this table's rows first, so the file can be re-run without duplicating.
DELETE FROM `nih-nci-dceg-connect-stg-5519.relational.responses` WHERE source_table = 'CleanConnect.menstrualSurvey';

INSERT INTO `nih-nci-dceg-connect-stg-5519.relational.responses`
  (connect_id, secondary_source_concept_id, source_question_concept_id, question_concept_id,
   loop_instance, question_version, response_value_as_string, response_value_as_number,
   response_value_as_concept_id, source_table, source_column)
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
  'CleanConnect.menstrualSurvey'                             AS source_table,
  u.source_column
FROM (
  SELECT Connect_ID,
    `d_593467240`,
    `d_784119588`,
    `d_901199566`,
    `d_951357171`
  FROM `nih-nci-dceg-connect-stg-5519.CleanConnect.menstrualSurvey`
) t
UNPIVOT(value FOR source_column IN (`d_593467240`, `d_784119588`, `d_901199566`, `d_951357171`)) u    -- BigQuery UNPIVOT drops NULL cells => unanswered = no row
JOIN `nih-nci-dceg-connect-stg-5519.relational.colmap` m
  ON m.table_name = 'menstrualSurvey' AND m.source_column = u.source_column;
