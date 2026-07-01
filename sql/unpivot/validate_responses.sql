-- Post-run validation of the long `responses` fact produced by sql/unpivot/unpivot_*.sql.
-- Run AFTER the first load, against the target (stage) dataset:
--   bq query --use_legacy_sql=false < sql/unpivot/validate_responses.sql
-- Replace ${PROJECT}/${DATASET} first (or pipe through envsubst). Dimension checks assume the demo
-- dimension tables (`question`, `secondary_source`) are loaded in the same dataset — adjust if they live
-- elsewhere. Every check is written so the "bad" number should be 0 (or clearly explained).

-- 1. volume: overall + per survey (sanity — do the counts look plausible per instrument?)
SELECT 'total_rows' AS metric, CAST(COUNT(*) AS STRING) AS value FROM `${PROJECT}.${DATASET}.responses`
UNION ALL SELECT 'distinct_participants', CAST(COUNT(DISTINCT connect_id) AS STRING) FROM `${PROJECT}.${DATASET}.responses`
UNION ALL SELECT 'distinct_source_columns', CAST(COUNT(DISTINCT source_column) AS STRING) FROM `${PROJECT}.${DATASET}.responses`
UNION ALL SELECT 'distinct_surveys', CAST(COUNT(DISTINCT secondary_source_concept_id) AS STRING) FROM `${PROJECT}.${DATASET}.responses`;

SELECT source_table, COUNT(*) AS rows, COUNT(DISTINCT connect_id) AS participants
FROM `${PROJECT}.${DATASET}.responses` GROUP BY source_table ORDER BY rows DESC;

-- 2. grain uniqueness: (connect_id, source_table, source_column, loop_instance) must be unique.
--    dup_rows should be 0. A non-zero value means a source table had >1 row per participant (see ToDo #5)
--    or a column mapped ambiguously.
SELECT COUNT(*) AS dup_grain_keys FROM (
  SELECT connect_id, source_table, source_column, loop_instance, COUNT(*) n
  FROM `${PROJECT}.${DATASET}.responses`
  GROUP BY 1,2,3,4 HAVING n > 1
);

-- 3. value presence: UNPIVOT drops NULL cells, so response_value_as_string should never be NULL.
--    Empty-string answers are surfaced separately (may be legitimate but worth eyeballing).
SELECT
  COUNTIF(response_value_as_string IS NULL) AS null_value_rows,      -- expect 0
  COUNTIF(response_value_as_string = '')    AS empty_string_rows,    -- inspect
  COUNTIF(question_concept_id IS NULL)      AS null_question_rows,   -- expect 0 (every row must place)
  COUNTIF(secondary_source_concept_id IS NULL) AS null_survey_rows   -- expect 0 (survey stamped by colmap)
FROM `${PROJECT}.${DATASET}.responses`;

-- 4. loop_instance sanity: min should be 1 (default), never 0/NULL.
SELECT MIN(loop_instance) AS min_loop, MAX(loop_instance) AS max_loop,
       COUNTIF(loop_instance IS NULL) AS null_loops, COUNTIF(loop_instance < 1) AS sub1_loops
FROM `${PROJECT}.${DATASET}.responses`;

-- 5. referential integrity to the dimensions (orphans should be 0).
SELECT 'question orphans' AS check, COUNT(*) AS n
FROM `${PROJECT}.${DATASET}.responses` r
LEFT JOIN `${PROJECT}.${DATASET}.question` q USING (question_concept_id)
WHERE r.question_concept_id IS NOT NULL AND q.question_concept_id IS NULL
UNION ALL
SELECT 'survey (secondary_source) orphans', COUNT(*)
FROM `${PROJECT}.${DATASET}.responses` r
LEFT JOIN `${PROJECT}.${DATASET}.secondary_source` s USING (secondary_source_concept_id)
WHERE r.secondary_source_concept_id IS NOT NULL AND s.secondary_source_concept_id IS NULL;

-- 6. coverage: mapped columns that produced at least one row, vs mapped columns total (per table).
--    A mapped column with no rows just means it was NULL for every participant (all-unanswered) — expected
--    for rare options; a big gap is worth a look.
WITH produced AS (
  SELECT source_table, COUNT(DISTINCT source_column) AS cols_with_rows
  FROM `${PROJECT}.${DATASET}.responses` GROUP BY 1
),
mapped AS (
  SELECT CONCAT('CleanConnect.', table_name) AS source_table, COUNT(*) AS cols_mapped
  FROM `${PROJECT}.${DATASET}.colmap` GROUP BY 1
)
SELECT m.source_table, m.cols_mapped, IFNULL(p.cols_with_rows, 0) AS cols_with_rows,
       m.cols_mapped - IFNULL(p.cols_with_rows, 0) AS cols_all_null
FROM mapped m LEFT JOIN produced p USING (source_table) ORDER BY cols_all_null DESC;

-- 7. worked spot-check: tooth-loss select-all (899251483). Expect one row per participant per SELECTED
--    option — no binary 0/1 explosion. current_source_question_concept_id should be 899251483.
SELECT question_concept_id, question_version, COUNT(*) AS selections, COUNT(DISTINCT connect_id) AS participants
FROM `${PROJECT}.${DATASET}.responses`
WHERE current_source_question_concept_id = '899251483'
GROUP BY 1, 2 ORDER BY 1, 2;
