-- Long-format analytics demo (the Dictionary-Direct model) — tiny synthetic data for the kick-off.
-- Runnable: duckdb :memory: < sql/demo_long_format.sql   (DuckDB ~ BigQuery SQL)
-- Shows: (1) codes + labels side by side in long form, (2) pivot a subset back to wide,
-- (3) counts as a simple GROUP BY. Data is fictional, for presentation only.

-- ── dimensions (a slice of the dictionary) ──────────────────────────────────
CREATE TABLE question (question_concept_id BIGINT, question_text VARCHAR, question_type VARCHAR);
INSERT INTO question VALUES
  (100001,'Sex','single_select'),
  (100002,'Age','number'),
  (100003,'Smoking Status','single_select'),
  (100004,'Education','single_select'),
  (899251483,'Have you lost any permanent teeth?','multi_select');

CREATE TABLE response (response_concept_id BIGINT, label VARCHAR);
INSERT INTO response VALUES
  (536341288,'Female'),(654207589,'Male'),
  (700000001,'Never'),(700000002,'Former'),(700000003,'Current'),
  (404564707,'High School Graduate or GED'),(875342283,'Bachelor''s Degree'),(598242454,'Advanced Degree'),
  (812107266,'Yes, from accident or injury'),(452438775,'Yes, from tooth decay or disease'),
  (886864375,'Yes, for some other reason'),(551489317,'No, I haven''t lost any teeth');

-- ── the long fact: one row per answer ───────────────────────────────────────
CREATE TABLE responses (connect_id BIGINT, question_concept_id BIGINT, response_concept_id BIGINT, value VARCHAR);
INSERT INTO responses VALUES
  -- 1001
  (1001,100001,536341288,NULL),(1001,100002,NULL,'47'),(1001,100003,700000002,NULL),(1001,100004,875342283,NULL),
  (1001,899251483,812107266,NULL),(1001,899251483,452438775,NULL),
  -- 1002
  (1002,100001,654207589,NULL),(1002,100002,NULL,'62'),(1002,100003,700000003,NULL),(1002,100004,404564707,NULL),
  (1002,899251483,551489317,NULL),
  -- 1003
  (1003,100001,536341288,NULL),(1003,100002,NULL,'55'),(1003,100003,700000001,NULL),(1003,100004,598242454,NULL),
  (1003,899251483,812107266,NULL),
  -- 1004 (no tooth-loss answer)
  (1004,100001,654207589,NULL),(1004,100002,NULL,'39'),(1004,100003,700000001,NULL),(1004,100004,875342283,NULL),
  -- 1005
  (1005,100001,536341288,NULL),(1005,100002,NULL,'71'),(1005,100003,700000002,NULL),(1005,100004,404564707,NULL),
  (1005,899251483,452438775,NULL),(1005,899251483,886864375,NULL);

-- the analyst's one join: concept ids + human labels side by side
CREATE VIEW v_long AS
SELECT r.connect_id,
       r.question_concept_id, q.question_text,
       r.response_concept_id, resp.label AS response_label,
       r.value,
       q.question_type,
       COALESCE(resp.label, r.value) AS answer   -- categorical label or literal value
FROM responses r
JOIN question q USING (question_concept_id)
LEFT JOIN response resp USING (response_concept_id);

.mode markdown
.print '--- Q1: long format — codes and labels side by side ---'
SELECT * FROM v_long ORDER BY connect_id, question_text LIMIT 12;

.print '--- Q2: pivot a subset back to wide — DYNAMIC, no hardcoded columns ---'
-- SQL (DuckDB): columns are DISCOVERED from the data — must project to id+name+value first
PIVOT (FROM v_long SELECT connect_id, question_text, answer WHERE question_type <> 'multi_select')
  ON question_text USING any_value(answer)
  ORDER BY connect_id;
-- BigQuery: PIVOT lists the values, e.g. PIVOT(ANY_VALUE(answer) FOR question_text IN ('Sex','Age',...))
--           or generate that IN-list with dynamic SQL (EXECUTE IMMEDIATE).
-- Python (pandas): long.pivot(index='connect_id', columns='question_text', values='answer')
-- R (tidyr):        pivot_wider(long, id_cols=connect_id, names_from=question_text, values_from=answer)

.print '--- Q3a: counts in long format — a simple GROUP BY ---'
SELECT response_label AS smoking_status, COUNT(*) AS n
FROM v_long WHERE question_text='Smoking Status'
GROUP BY response_label ORDER BY n DESC;

.print '--- Q3b: select-all counts — where long format is *easier* than wide ---'
SELECT response_label AS tooth_loss_reason, COUNT(*) AS n
FROM v_long WHERE question_concept_id=899251483
GROUP BY response_label ORDER BY n DESC;
