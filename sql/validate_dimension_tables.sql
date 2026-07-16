-- Reproducible validation of the demo dimension tables built by sql/build_dimension_tables.sql.
-- Run (after building):  duckdb output/connect_dimensions.duckdb < sql/validate_dimension_tables.sql
-- Cross-checks the dictionary-derived source_question against the column-derived one in
-- output/survey_columns_clean_mapped.csv (produced by the parse+map scripts).

.mode markdown

.print '=== 1. row counts ==='
SELECT 'primary_source' AS tbl, count(*) AS n FROM primary_source
UNION ALL SELECT 'secondary_source', count(*) FROM secondary_source
UNION ALL SELECT 'source_question', count(*) FROM source_question
UNION ALL SELECT 'question', count(*) FROM question
UNION ALL SELECT 'response', count(*) FROM response
UNION ALL SELECT 'question_response', count(*) FROM question_response
ORDER BY tbl;

.print '=== 2. referential integrity (all orphan counts should be 0) ==='
SELECT 'secondary->primary orphans' AS check, count(*) AS n
  FROM secondary_source s LEFT JOIN primary_source p USING(primary_source_concept_id)
  WHERE s.primary_source_concept_id IS NOT NULL AND p.primary_source_concept_id IS NULL
UNION ALL SELECT 'question->secondary orphans', count(*)
  FROM question q LEFT JOIN secondary_source s USING(secondary_source_concept_id)
  WHERE q.secondary_source_concept_id IS NOT NULL AND s.secondary_source_concept_id IS NULL
UNION ALL SELECT 'question->source_question orphans', count(*)
  FROM question q LEFT JOIN source_question sq USING(source_question_concept_id)
  WHERE q.source_question_concept_id IS NOT NULL AND sq.source_question_concept_id IS NULL
UNION ALL SELECT 'question_response->question orphans', count(*)
  FROM question_response qr LEFT JOIN question q USING(question_concept_id) WHERE q.question_concept_id IS NULL
UNION ALL SELECT 'question_response->response orphans', count(*)
  FROM question_response qr LEFT JOIN response r USING(response_concept_id) WHERE r.response_concept_id IS NULL;

.print '=== 3. worked example: tooth-loss select-all 899251483 ==='
SELECT q.question_concept_id, q.question_text, q.question_type
FROM question q WHERE q.source_question_concept_id = '899251483' ORDER BY 1;

.print '=== 4. source_question cross-check vs column-derived (output/survey_columns_clean_mapped.csv) ==='
WITH col AS (
  SELECT DISTINCT question_concept_id, source_question_concept_id AS col_sq
  FROM read_csv('output/survey_columns_clean_mapped.csv', header=true, all_varchar=true)
  WHERE question_concept_id <> '' AND source_question_concept_id <> ''
),
per_q AS (SELECT question_concept_id, count(DISTINCT col_sq) AS n_parents FROM col GROUP BY 1)
SELECT
  count(*) AS pairs_compared,
  sum(CASE WHEN c.col_sq = q.source_question_concept_id THEN 1 ELSE 0 END) AS agree_all,
  sum(CASE WHEN p.n_parents = 1 THEN 1 ELSE 0 END) AS single_parent_pairs,
  sum(CASE WHEN p.n_parents = 1 AND c.col_sq = q.source_question_concept_id THEN 1 ELSE 0 END) AS single_parent_agree,
  count(DISTINCT CASE WHEN p.n_parents > 1 THEN c.question_concept_id END) AS reused_concepts
FROM col c JOIN per_q p USING(question_concept_id) JOIN question q USING(question_concept_id);
