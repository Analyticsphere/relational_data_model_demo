-- Demo-quality CIDTool-style dimension tables, normalized from the flat data dictionary (masterFile.csv).
-- These will EVENTUALLY load from CIDTool; this is a stopgap built from the dictionary for demos.
-- Run:  mkdir -p output/dim && duckdb output/connect_dimensions.duckdb < sql/build_dimension_tables.sql
-- (DuckDB ~ BigQuery SQL.) Reads data_dictionary/masterFile.csv (fetch via scripts/fetch_data_dict.py).
--
-- masterFile is one row per (question × response option); hierarchy columns are filled only on the first
-- row of each block (spreadsheet fill-down). We:
--   * forward-fill the SECTION level (primary/secondary) down to question/response rows,
--   * forward-fill the QUESTION id down to its response rows (for the question_response bridge),
--   * take the SOURCE-QUESTION id from the question's own defining row (it is co-located there — no fill),
--   * take response (format/value) per row.
-- Demo caveat: reused question concepts get ONE representative (secondary, source_question) placement.

-- 0. raw load — positional columns (header=false avoids the 5 duplicate "conceptId" headers); '' -> NULL
CREATE OR REPLACE TABLE _raw AS
SELECT row_number() OVER () AS rn,
  NULLIF(column02,'') AS prim_cid, NULLIF(column03,'') AS prim,
  NULLIF(column04,'') AS sec_cid,  NULLIF(column05,'') AS sec,
  NULLIF(column06,'') AS sq_cid,   NULLIF(column07,'') AS sq_text, NULLIF(column09,'') AS sq_v1, NULLIF(column10,'') AS grid_name,
  NULLIF(column13,'') AS q_cid,    NULLIF(column14,'') AS q_text,  NULLIF(column35,'') AS q_type,
  NULLIF(column22,'') AS resp_cid, NULLIF(column23,'') AS resp_fmt
FROM read_csv('data_dictionary/masterFile.csv', header=false, all_varchar=true, skip=1,
              delim=',', quote='"', escape='"', null_padding=true, strict_mode=false);

-- 1. forward-fill section level + question id (for the bridge); keep originals for definer detection
CREATE OR REPLACE TABLE _ff AS
SELECT rn,
  last_value(prim_cid IGNORE NULLS) OVER w AS prim_cid_f,
  last_value(prim     IGNORE NULLS) OVER w AS prim_f,
  last_value(sec_cid  IGNORE NULLS) OVER w AS sec_cid_f,
  last_value(sec      IGNORE NULLS) OVER w AS sec_f,
  last_value(q_cid    IGNORE NULLS) OVER w AS q_cid_f,
  prim_cid, sec_cid, sq_cid, sq_text, sq_v1, grid_name,
  q_cid AS q_cid_o, q_text, q_type, resp_cid, resp_fmt
FROM _raw
WINDOW w AS (ORDER BY rn ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW);

-- 2. the dimension tables ------------------------------------------------------------------------
CREATE OR REPLACE TABLE primary_source AS
SELECT prim_cid AS primary_source_concept_id, any_value(prim) AS primary_source
FROM _raw WHERE prim_cid IS NOT NULL GROUP BY prim_cid;

CREATE OR REPLACE TABLE secondary_source AS
SELECT sec_cid AS secondary_source_concept_id, any_value(sec_f) AS secondary_source,
       any_value(prim_cid_f) AS primary_source_concept_id
FROM _ff WHERE sec_cid IS NOT NULL GROUP BY sec_cid;

CREATE OR REPLACE TABLE source_question AS
SELECT sq_cid AS current_source_question_concept_id, any_value(sq_text) AS source_question_text,
       any_value(sq_v1) AS v1_source_question, any_value(grid_name) AS grid_source_question_name
FROM _ff WHERE sq_cid IS NOT NULL GROUP BY sq_cid;

CREATE OR REPLACE TABLE question AS
SELECT q_cid_o AS question_concept_id, any_value(q_text) AS current_question_text,
       any_value(q_type) AS question_type,
       any_value(sec_cid_f) AS secondary_source_concept_id,
       any_value(sq_cid) AS current_source_question_concept_id   -- co-located on the definer row; NULL = standalone
FROM _ff WHERE q_cid_o IS NOT NULL GROUP BY q_cid_o;

CREATE OR REPLACE TABLE response AS
SELECT resp_cid AS response_concept_id, any_value(resp_fmt) AS current_format_value
FROM _ff WHERE resp_cid IS NOT NULL GROUP BY resp_cid;

CREATE OR REPLACE TABLE question_response AS   -- bridge: allowed responses per question
SELECT DISTINCT q_cid_f AS question_concept_id, resp_cid AS response_concept_id
FROM _ff WHERE resp_cid IS NOT NULL AND q_cid_f IS NOT NULL;

DROP TABLE _raw; DROP TABLE _ff;

-- 3. export reviewable CSVs + report row counts
COPY primary_source    TO 'output/dim/primary_source.csv'    (HEADER);
COPY secondary_source  TO 'output/dim/secondary_source.csv'  (HEADER);
COPY source_question   TO 'output/dim/source_question.csv'   (HEADER);
COPY question          TO 'output/dim/question.csv'          (HEADER);
COPY response          TO 'output/dim/response.csv'          (HEADER);
COPY question_response TO 'output/dim/question_response.csv' (HEADER);

.mode markdown
SELECT 'primary_source' AS tbl, count(*) AS n FROM primary_source
UNION ALL SELECT 'secondary_source', count(*) FROM secondary_source
UNION ALL SELECT 'source_question', count(*) FROM source_question
UNION ALL SELECT 'question', count(*) FROM question
UNION ALL SELECT 'response', count(*) FROM response
UNION ALL SELECT 'question_response', count(*) FROM question_response
ORDER BY tbl;
