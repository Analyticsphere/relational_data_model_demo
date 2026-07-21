-- Compare relational vs relational2 — quantify what the SATA option-as-answer remodel changed.
-- No verbatim values are selected. Rows correspond 1:1 (relational2 is a transform of relational),
-- joined on (connect_id, source_table, source_column, loop_instance) — the per-cell natural key.
-- RUN: sed 's/${PROJECT}/<project>/g' this_file | bq --project_id=<project> query --use_legacy_sql=false

SELECT
  COUNT(*)                                                        AS total_rows,          -- r1 == r2 (no fanout/drop)
  COUNTIF(r1.response_unique_id =  r2.response_unique_id)         AS ids_unchanged,       -- non-SATA rows
  COUNTIF(r1.response_unique_id <> r2.response_unique_id)         AS ids_changed_sata,    -- remodeled SATA rows
  COUNTIF(r1.source_question_concept_id IS NOT NULL
      AND r2.source_question_concept_id IS NULL)                  AS sata_parent_freed,   -- expect = ids_changed_sata
  -- relational2 id health (should mirror relational: unique per distinct combo, all in OMOP range)
  COUNT(DISTINCT r2.response_unique_id)                           AS r2_distinct_ids,
  COUNT(DISTINCT CONCAT(
    COALESCE(r2.secondary_source_concept_id,''), '|',
    COALESCE(r2.source_question_concept_id,''),  '|',
    COALESCE(r2.question_concept_id,''),         '|',
    COALESCE(r2.response_value_as_string,'')))                    AS r2_distinct_combos,   -- expect = r2_distinct_ids
  COUNTIF(r2.response_unique_id <= 2000000000
       OR r2.response_unique_id >= 9223372036854775807)           AS r2_out_of_omop_range  -- expect 0
FROM `${PROJECT}.relational.responses`  r1
JOIN `${PROJECT}.relational2.responses` r2
  USING (connect_id, source_table, source_column, loop_instance);
