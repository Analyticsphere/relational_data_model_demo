-- clustering_benchmark.sql
--
-- PURPOSE:
--   Measure the scan reduction delivered by clustering on the responses table.
--   Results are only meaningful at production scale (200k+ participants, ~55M rows).
--   At stage scale (82k rows / ~10 MB) the entire table fits in a single cluster block
--   and both tables will report identical bytes — run this at the first production load.
--
-- METHODOLOGY:
--   1. Create a non-clustered shadow copy of the responses table (same schema, same data).
--   2. Run five representative query shapes against both tables.
--   3. Pull bytes_processed from INFORMATION_SCHEMA.JOBS and compute the reduction ratio.
--   4. Drop the shadow copy.
--
-- QUERIES ARE INTENTIONALLY IDENTICAL except for the table reference so that the only
-- variable is the presence or absence of clustering.
--
-- ESTIMATED COST: one full table scan to create the shadow copy (~2–3 GB at 200k participants).
--
-- NOTE: substitute real concept IDs from the dimension tables before running.
--   Example IDs below are taken from the stage dataset and are illustrative only.
--   To find representative values at prod scale:
--     SELECT secondary_source_concept_id, COUNT(*) AS n
--     FROM `<project>.relational.responses`
--     GROUP BY 1 ORDER BY 2 DESC;

-- ============================================================
-- STEP 0: Record your start time before running any queries.
--   Run in your terminal:
--     export BM_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
--   or note the current UTC time — you will need it in Step 3.
-- ============================================================

-- ============================================================
-- STEP 1: Create the non-clustered shadow copy (run once).
-- ============================================================

CREATE TABLE `<project>.relational.responses_noclustering`
AS SELECT * FROM `<project>.relational.responses`;


-- ============================================================
-- STEP 2: Benchmark queries — five representative shapes.
--   Run each pair (clustered, then non-clustered) in sequence.
--   BigQuery reports bytes_processed per job in INFORMATION_SCHEMA.
-- ============================================================

-- Shape A: filter by survey (leading cluster key)
-- Expected: high reduction (~90%+ at prod scale; 1/10 surveys)
-- --- CLUSTERED ---
SELECT COUNT(*), AVG(response_value_as_number)
FROM `<project>.relational.responses`
WHERE secondary_source_concept_id = '726699695';  -- module 1; replace with prod value

-- --- NON-CLUSTERED ---
SELECT COUNT(*), AVG(response_value_as_number)
FROM `<project>.relational.responses_noclustering`
WHERE secondary_source_concept_id = '726699695';


-- Shape B: filter by survey + question (first two cluster keys)
-- Expected: very high reduction; most selective typical analyst query
-- --- CLUSTERED ---
SELECT response_value_as_concept_id, COUNT(*) AS n
FROM `<project>.relational.responses`
WHERE secondary_source_concept_id = '726699695'
  AND question_concept_id = '535003378'  -- replace with prod value
GROUP BY 1 ORDER BY 2 DESC;

-- --- NON-CLUSTERED ---
SELECT response_value_as_concept_id, COUNT(*) AS n
FROM `<project>.relational.responses_noclustering`
WHERE secondary_source_concept_id = '726699695'
  AND question_concept_id = '535003378'
GROUP BY 1 ORDER BY 2 DESC;


-- Shape C: filter by question only (second key, no leading-key pruning)
-- Expected: moderate reduction; cluster ranges still help but first key not filtered
-- --- CLUSTERED ---
SELECT secondary_source_concept_id, COUNT(*) AS n
FROM `<project>.relational.responses`
WHERE question_concept_id = '535003378'
GROUP BY 1 ORDER BY 2 DESC;

-- --- NON-CLUSTERED ---
SELECT secondary_source_concept_id, COUNT(*) AS n
FROM `<project>.relational.responses_noclustering`
WHERE question_concept_id = '535003378'
GROUP BY 1 ORDER BY 2 DESC;


-- Shape D: participant lookup (third cluster key)
-- Expected: low reduction; third key yields minimal pruning without first two
-- --- CLUSTERED ---
SELECT question_concept_id, response_value_as_string
FROM `<project>.relational.responses`
WHERE connect_id = '<a real connect_id>';  -- replace with a prod connect_id

-- --- NON-CLUSTERED ---
SELECT question_concept_id, response_value_as_string
FROM `<project>.relational.responses_noclustering`
WHERE connect_id = '<a real connect_id>';


-- Shape E: full aggregation / no filter (expected baseline — no reduction)
-- --- CLUSTERED ---
SELECT secondary_source_concept_id, COUNT(*) AS n
FROM `<project>.relational.responses`
GROUP BY 1 ORDER BY 2 DESC;

-- --- NON-CLUSTERED ---
SELECT secondary_source_concept_id, COUNT(*) AS n
FROM `<project>.relational.responses_noclustering`
GROUP BY 1 ORDER BY 2 DESC;


-- ============================================================
-- STEP 3: Analyze results from INFORMATION_SCHEMA.JOBS.
--   Replace <project>, <BM_START>, and <BM_END> with actual values.
--   <BM_END> can be NOW() or a few minutes after your last query.
-- ============================================================

SELECT
  CASE
    WHEN REGEXP_CONTAINS(query, r'responses_noclustering') THEN 'no_clustering'
    ELSE 'clustered'
  END AS table_variant,
  CASE
    WHEN REGEXP_CONTAINS(query, r'Shape A') THEN 'A: survey filter'
    WHEN REGEXP_CONTAINS(query, r'Shape B') THEN 'B: survey + question'
    WHEN REGEXP_CONTAINS(query, r'Shape C') THEN 'C: question only'
    WHEN REGEXP_CONTAINS(query, r'Shape D') THEN 'D: participant lookup'
    WHEN REGEXP_CONTAINS(query, r'Shape E') THEN 'E: full scan'
    ELSE 'other'
  END AS query_shape,
  ROUND(total_bytes_processed / POW(1024, 3), 3)  AS gb_processed,
  ROUND(total_bytes_billed    / POW(1024, 3), 3)  AS gb_billed,
  ROUND(elapsed_ms / 1000.0, 2)                   AS elapsed_sec,
  job_id,
  creation_time
FROM `<project>.region-us`.INFORMATION_SCHEMA.JOBS
WHERE creation_time BETWEEN '<BM_START>' AND '<BM_END>'
  AND statement_type = 'SELECT'
  AND (
    REGEXP_CONTAINS(query, r'relational\.responses')
    OR REGEXP_CONTAINS(query, r'responses_noclustering')
  )
ORDER BY query_shape, table_variant;


-- ============================================================
-- Pivot for easy comparison (run after the query above to see side-by-side):
-- ============================================================

WITH jobs AS (
  SELECT
    CASE WHEN REGEXP_CONTAINS(query, r'responses_noclustering') THEN 'no_clustering' ELSE 'clustered' END AS variant,
    CASE
      WHEN REGEXP_CONTAINS(query, r'Shape A') THEN 'A: survey filter'
      WHEN REGEXP_CONTAINS(query, r'Shape B') THEN 'B: survey + question'
      WHEN REGEXP_CONTAINS(query, r'Shape C') THEN 'C: question only'
      WHEN REGEXP_CONTAINS(query, r'Shape D') THEN 'D: participant lookup'
      WHEN REGEXP_CONTAINS(query, r'Shape E') THEN 'E: full scan'
    END AS shape,
    ROUND(total_bytes_processed / POW(1024, 3), 4) AS gb
  FROM `<project>.region-us`.INFORMATION_SCHEMA.JOBS
  WHERE creation_time BETWEEN '<BM_START>' AND '<BM_END>'
    AND statement_type = 'SELECT'
    AND REGEXP_CONTAINS(query, r'relational\.responses')
)
SELECT
  shape,
  MAX(IF(variant = 'clustered',     gb, NULL)) AS gb_clustered,
  MAX(IF(variant = 'no_clustering', gb, NULL)) AS gb_no_clustering,
  ROUND(
    1 - MAX(IF(variant = 'clustered', gb, NULL))
          / NULLIF(MAX(IF(variant = 'no_clustering', gb, NULL)), 0),
    3
  ) AS scan_reduction_ratio
FROM jobs
GROUP BY 1
ORDER BY 1;


-- ============================================================
-- STEP 4: Drop the shadow copy once benchmarking is complete.
-- ============================================================

DROP TABLE `<project>.relational.responses_noclustering`;
