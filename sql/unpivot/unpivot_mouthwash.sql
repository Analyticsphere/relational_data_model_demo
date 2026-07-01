-- Unpivot CleanConnect.mouthwash -> relational.responses  (GENERATED from schemas/CleanConnect/mouthwash.json)
-- NOT run against production. Validate later: bq query --dry_run < this file.  55 columns unpivoted.
INSERT INTO `${PROJECT}.relational.responses`
  (connect_id, secondary_source_concept_id, current_source_question_concept_id, question_concept_id,
   loop_instance, question_version, response_value_as_string, response_value_as_number,
   response_value_as_concept_id, source_table, source_column)
SELECT
  u.Connect_ID                                       AS connect_id,     -- passthrough belongs to the UNPIVOT alias
  m.secondary_source_concept_id,
  m.current_source_question_concept_id,
  m.question_concept_id,
  m.loop_instance,
  m.question_version,
  u.value                                            AS response_value_as_string,   -- verbatim raw cell (always)
  CAST(NULL AS FLOAT64)                              AS response_value_as_number,    -- typed later by question_type
  CAST(NULL AS STRING)                               AS response_value_as_concept_id,-- coded answer, set later by question_type
  'CleanConnect.mouthwash'                             AS source_table,
  u.source_column
FROM (
  SELECT Connect_ID,
    `d_205713835`,
    `d_294886836`,
    `d_318641324`,
    `d_339570897`,
    `d_349659426`,
    `d_350251057`,
    `d_353467497`,
    `d_360678252`,
    `d_406270109_d_259744087`,
    `d_406270109_d_404389800`,
    `d_406270109_d_463302301`,
    `d_406270109_d_523660949`,
    `d_406270109_d_762727133`,
    `d_406270109_d_877842367`,
    `d_406270109_d_886771318`,
    `d_406270109_d_950773275`,
    `d_429994023`,
    `d_430060900`,
    `d_460873842`,
    `d_479143504_d_165596977`,
    `d_479143504_d_184513726`,
    `d_479143504_d_203919683`,
    `d_479143504_d_390351864`,
    `d_479143504_d_578402172`,
    `d_479143504_d_807884576`,
    `d_498984275`,
    `d_499977481`,
    `d_520416570`,
    `d_526973271`,
    `d_542661394_d_167336253`,
    `d_542661394_d_178420302`,
    `d_542661394_d_181769837`,
    `d_542661394_d_215662651`,
    `d_542661394_d_329536041`,
    `d_542661394_d_365685000`,
    `d_542661394_d_656498939`,
    `d_642044281`,
    `d_667908442`,
    `d_724589244`,
    `d_736028153`,
    `d_736393021`,
    `d_766370065`,
    `d_784119588`,
    `d_792134396`,
    `d_800703566`,
    `d_800752981`,
    `d_850585325`,
    `d_877878167`,
    `d_899251483_d_452438775_v2`,
    `d_899251483_d_551489317_v2`,
    `d_899251483_d_812107266_v2`,
    `d_899251483_d_886864375_v2`,
    `d_921972241`,
    `d_957305523`,
    `d_983043203`
  FROM `${PROJECT}.CleanConnect.mouthwash`
) t
UNPIVOT(value FOR source_column IN (`d_205713835`, `d_294886836`, `d_318641324`, `d_339570897`, `d_349659426`, `d_350251057`, `d_353467497`, `d_360678252`, `d_406270109_d_259744087`, `d_406270109_d_404389800`, `d_406270109_d_463302301`, `d_406270109_d_523660949`, `d_406270109_d_762727133`, `d_406270109_d_877842367`, `d_406270109_d_886771318`, `d_406270109_d_950773275`, `d_429994023`, `d_430060900`, `d_460873842`, `d_479143504_d_165596977`, `d_479143504_d_184513726`, `d_479143504_d_203919683`, `d_479143504_d_390351864`, `d_479143504_d_578402172`, `d_479143504_d_807884576`, `d_498984275`, `d_499977481`, `d_520416570`, `d_526973271`, `d_542661394_d_167336253`, `d_542661394_d_178420302`, `d_542661394_d_181769837`, `d_542661394_d_215662651`, `d_542661394_d_329536041`, `d_542661394_d_365685000`, `d_542661394_d_656498939`, `d_642044281`, `d_667908442`, `d_724589244`, `d_736028153`, `d_736393021`, `d_766370065`, `d_784119588`, `d_792134396`, `d_800703566`, `d_800752981`, `d_850585325`, `d_877878167`, `d_899251483_d_452438775_v2`, `d_899251483_d_551489317_v2`, `d_899251483_d_812107266_v2`, `d_899251483_d_886864375_v2`, `d_921972241`, `d_957305523`, `d_983043203`)) u    -- BigQuery UNPIVOT drops NULL cells => unanswered = no row
JOIN `${PROJECT}.relational.colmap` m
  ON m.table_name = 'mouthwash' AND m.source_column = u.source_column;
