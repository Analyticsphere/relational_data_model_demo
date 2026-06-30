-- Demo concept_relationship table (OMOP-style): concept_id_1, concept_id_2, relationship.
-- Seeds 'synonym' links for reused ADDRESS-COMPONENT concepts — the geocoding harmonization use case.
-- The dictionary has e.g. 106 distinct "street name" question concepts (home/seasonal/previous/employer/
-- school variants); we group them by (component × address class) and link each member to a canonical
-- concept, so "give me every 'street name of residence' concept" is one join instead of the 26-branch
-- case_when the geocoding repos hand-wrote across three codebases.
--
-- Run AFTER build_dimension_tables.sql (needs the `question` table):
--   duckdb output/connect_dimensions.duckdb < sql/build_concept_relationship.sql
--
-- Demo caveats: (1) groups are derived by matching question TEXT (mirrors the geocoding repos'
-- label-string-matching) — the real links would come from CIDTool / a curated question_equivalence;
-- (2) 'synonym' here means "same field type within the same address class" — residence vs work vs school
-- are kept SEPARATE because they are genuinely different questions. relationship is a vocabulary column,
-- so other types ('maps_to', 'is_a', ...) can be added later.

CREATE OR REPLACE TABLE _addr AS
SELECT question_concept_id AS cid, current_question_text AS txt,
  CASE
    WHEN regexp_matches(lower(current_question_text), 'street.*name|full street')      THEN 'street_name'
    WHEN regexp_matches(lower(current_question_text), 'street.*number|number.*street') THEN 'street_number'
    WHEN regexp_matches(lower(current_question_text), 'apartment|apt|unit|suite')      THEN 'apartment'
    WHEN regexp_matches(lower(current_question_text), '\bcity\b|town')                 THEN 'city'
    WHEN regexp_matches(lower(current_question_text), '\bstate\b|province')            THEN 'state'
    WHEN regexp_matches(lower(current_question_text), 'zip|postal')                    THEN 'zip'
    WHEN regexp_matches(lower(current_question_text), 'country')                       THEN 'country'
  END AS component,
  CASE
    WHEN regexp_matches(lower(current_question_text), 'employer|work') THEN 'work'
    WHEN regexp_matches(lower(current_question_text), 'school')        THEN 'school'
    ELSE 'residence'
  END AS address_class
FROM question WHERE current_question_text IS NOT NULL;
DELETE FROM _addr WHERE component IS NULL;

-- canonical = the lowest concept_id in each (component × address class) group
CREATE OR REPLACE TABLE _grp AS
SELECT component, address_class, min(cid) AS canonical_cid FROM _addr GROUP BY component, address_class;

CREATE OR REPLACE TABLE concept_relationship AS
SELECT a.cid AS concept_id_1, g.canonical_cid AS concept_id_2, 'synonym' AS relationship,
       'demo: address ' || g.address_class || ' ' || g.component || ' (matched on question text)' AS relationship_source
FROM _addr a JOIN _grp g USING (component, address_class);   -- includes canonical->canonical (group = WHERE concept_id_2 = canonical)

DROP TABLE _addr; DROP TABLE _grp;

COPY (SELECT * FROM concept_relationship ORDER BY relationship_source, concept_id_1)
  TO 'output/dim/concept_relationship.csv' (HEADER);
COPY (SELECT * FROM concept_relationship ORDER BY relationship_source, concept_id_1)
  TO 'output/dim/concept_relationship.parquet' (FORMAT parquet);

.mode markdown
.print '=== synonym groups built (address component x class) ==='
SELECT relationship_source, count(*) AS n_concepts FROM concept_relationship GROUP BY 1 ORDER BY n_concepts DESC;
.print '=== demo: every "street name of RESIDENCE" concept, in one join (no 26-branch case_when) ==='
SELECT q.question_concept_id, q.current_question_text
FROM concept_relationship cr
JOIN question q ON q.question_concept_id = cr.concept_id_1
WHERE cr.relationship='synonym'
  AND cr.concept_id_2 = (SELECT concept_id_2 FROM concept_relationship
                         WHERE relationship_source = 'demo: address residence street_name (matched on question text)' LIMIT 1)
ORDER BY q.current_question_text LIMIT 10;
