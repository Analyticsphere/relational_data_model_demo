#!/usr/bin/env python3
"""Reproducible, PRODUCTION-FREE smoke test of the OMOP response hashing (sql/omop/response_source_codes.sql).

Proves the deterministic source-code id without any Connect data:
  1. builds synthetic dims + a `responses` fact using the REAL column names,
  2. computes `response_hash_id` in DuckDB using the SAME canonical recipe as the BigQuery SQL,
  3. INDEPENDENTLY recomputes it in pure Python (hashlib) and asserts byte-identical output
     — this is the cross-engine reproducibility guarantee: DuckDB == Python, and BigQuery's
     TO_HEX(SHA256(x)) is the same standard SHA-256 -> lowercase hex, so it matches too,
  4. checks the DISTINCT grain, determinism on re-run, collision-safety (incl. a pipe inside a
     free-text value, and the same text under two questions), and NULL secondary_source handling.

No production rows are ever read. Requires: duckdb.

    python scripts/smoke_test_omop_hash.py
"""
import sys
import hashlib

try:
    import duckdb
except ImportError:
    sys.exit("duckdb not installed: pip install duckdb")

# Canonical recipe (must match sql/omop/response_source_codes.sql AND docs/omop_source_codes.md):
#   fields in order: secondary_source | source_question | question | response_value_as_string
#   NULL -> '' ; delimiter '|' ; UTF-8 ; SHA-256 -> lowercase hex
def py_hash(sec, sq, qc, val):
    return hashlib.sha256("|".join([sec or "", sq or "", qc or "", val]).encode("utf-8")).hexdigest()

HASH_SQL = """
  sha256( COALESCE(d.secondary_source_concept_id,'') || '|' ||
          COALESCE(d.source_question_concept_id,'')  || '|' ||
          COALESCE(d.question_concept_id,'')         || '|' ||
          d.response_value_as_string )
"""

def main():
    con = duckdb.connect()
    con.execute("""
    CREATE TABLE responses(
      secondary_source_concept_id VARCHAR, source_question_concept_id VARCHAR,
      question_concept_id VARCHAR, response_value_as_string VARCHAR,
      response_value_as_number DOUBLE, response_value_as_date DATE, response_value_as_concept_id VARCHAR);
    INSERT INTO responses VALUES
      ('10', NULL, '100', '353358909', NULL, NULL, NULL),            -- coded single-select
      ('10', NULL, '100', '353358909', NULL, NULL, NULL),            -- DUPLICATE tuple (must dedup)
      ('10', '487','200', '619765650', NULL, NULL, NULL),            -- coded under a grid parent
      ('10', NULL, '300', '47',        47,   NULL, NULL),            -- numeric
      ('10', NULL, '301', '2023-05-01',NULL, DATE '2023-05-01', NULL),-- date
      ('10', NULL, '400', 'Aspirin',   NULL, NULL, NULL),            -- free text
      ('10', NULL, '400', 'Tylenol | 500mg', NULL, NULL, NULL),      -- free text WITH a pipe
      ('10', NULL, '401', 'Aspirin',   NULL, NULL, NULL),            -- same text, diff question
      (NULL, NULL, '500', 'x',         NULL, NULL, NULL);            -- NULL secondary_source
    CREATE TABLE question(question_concept_id VARCHAR, question_text VARCHAR);
    INSERT INTO question VALUES ('100','Ever smoked?'),('200','Tylenol use'),('300','Age'),
      ('301','Date'),('400','Other meds'),('401','Other meds 2'),('500','Q500');
    CREATE TABLE question_response(question_concept_id VARCHAR, response_concept_id VARCHAR);
    INSERT INTO question_response VALUES ('100','353358909'),('200','619765650');
    CREATE TABLE response(response_concept_id VARCHAR, format_value VARCHAR);
    INSERT INTO response VALUES ('353358909','1 = Yes'),('619765650','1 = Yes, past day');
    """)

    q = f"""
    WITH distinct_responses AS (
      SELECT DISTINCT secondary_source_concept_id, source_question_concept_id,
             question_concept_id, response_value_as_string
      FROM responses
      WHERE response_value_as_string IS NOT NULL AND response_value_as_string <> ''
    )
    SELECT {HASH_SQL} AS response_hash_id,
      d.secondary_source_concept_id, d.source_question_concept_id,
      d.question_concept_id, d.response_value_as_string AS v,
      CASE WHEN qr.response_concept_id IS NOT NULL THEN 'coded'
           WHEN TRY_CAST(d.response_value_as_string AS DOUBLE) IS NOT NULL
             OR regexp_matches(d.response_value_as_string, '^\\d{{4}}-\\d{{2}}-\\d{{2}}') THEN 'numeric_or_date'
           ELSE 'free_text' END AS response_kind
    FROM distinct_responses d
    LEFT JOIN question q USING (question_concept_id)
    LEFT JOIN question_response qr ON qr.question_concept_id=d.question_concept_id
                                  AND qr.response_concept_id=d.response_value_as_string
    LEFT JOIN response resp ON resp.response_concept_id=d.response_value_as_string
    """
    cols = None
    rows = con.execute(q).fetchall()
    cols = [c[0] for c in con.description]
    R = [dict(zip(cols, r)) for r in rows]

    # 1. DISTINCT grain (9 input rows, 1 duplicate -> 8)
    assert len(R) == 8, f"DISTINCT grain wrong: got {len(R)}"
    # 2. cross-engine: DuckDB == Python for every row
    for r in R:
        exp = py_hash(r['secondary_source_concept_id'], r['source_question_concept_id'],
                      r['question_concept_id'], r['v'])
        assert r['response_hash_id'] == exp, f"DuckDB/Python mismatch on {r['v']!r}"
    # 3. determinism
    again = {x[0] for x in con.execute(q).fetchall()}
    assert again == {r['response_hash_id'] for r in R}, "non-deterministic"
    # 4. collision-safety
    ids = [r['response_hash_id'] for r in R]
    assert len(set(ids)) == len(ids), "hash collision"
    asp = {r['question_concept_id']: r['response_hash_id'] for r in R if r['v'] == 'Aspirin'}
    assert asp['400'] != asp['401'], "same text under diff question collided"
    assert any(r['secondary_source_concept_id'] is None for r in R), "NULL secondary_source dropped"

    print(f"rows: 9 in -> {len(R)} distinct codes (1 duplicate collapsed)")
    print("cross-engine (DuckDB sha256 == Python hashlib): PASS for all 8")
    print("determinism / no-collision / pipe-in-value / NULL secondary_source: PASS")
    print("PASS")

if __name__ == "__main__":
    main()
