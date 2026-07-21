#!/usr/bin/env python3
"""Reproducible, PRODUCTION-FREE smoke test of the response_unique_id contract
(sql/omop/response_unique_id_udf.sql).

response_unique_id is the stable integer identity for each unique response — computed at unpivot time
by the BigQuery UDF and stored on relational.responses:

    response_unique_id = 2000000001 + (first 15 hex chars of
        SHA-256(secondary_source | source_question | question | response_value), base-16)

This test recomputes it two independent ways over a synthetic `responses` fact and proves they agree:
  1. DuckDB — the same SHA-256 -> first-15-hex -> +offset recipe the UDF uses (BigQuery's
     TO_HEX(SHA256(x)) is the same standard SHA-256 -> lowercase hex, so it matches too),
  2. pure Python (hashlib),
and checks: OMOP custom-concept range (integer, >2e9, <2^63-1), the DISTINCT grain, determinism on
re-run, and collision-safety (a pipe inside a free-text value, the same text under two questions, and
NULL secondary_source).

No production rows are ever read. Requires: duckdb.

    python scripts/smoke_test_omop_hash.py
"""
import sys
import hashlib

try:
    import duckdb
except ImportError:
    sys.exit("duckdb not installed: pip install duckdb")

# Canonical recipe (must match sql/omop/response_unique_id_udf.sql AND docs/omop_source_codes.md):
#   fields in order: secondary_source | source_question | question | response_value_as_string
#   NULL -> '' ; delimiter '|' ; UTF-8 ; SHA-256 -> lowercase hex ; id = OFFSET + first-15-hex (base-16)
UNIQUE_ID_OFFSET = 2000000001
INT64_MAX = 9223372036854775807


def py_unique_id(sec, sq, qc, val):
    h = hashlib.sha256("|".join([sec or "", sq or "", qc or "", val or ""]).encode("utf-8")).hexdigest()
    return UNIQUE_ID_OFFSET + int(h[:15], 16)


# DuckDB form of the SAME recipe (mirrors the BigQuery UDF: SHA-256 -> first 15 hex -> +offset)
UID_SQL = f"""
  {UNIQUE_ID_OFFSET} + CAST('0x' || substr(
    sha256( COALESCE(d.secondary_source_concept_id,'') || '|' ||
            COALESCE(d.source_question_concept_id,'')  || '|' ||
            COALESCE(d.question_concept_id,'')         || '|' ||
            COALESCE(d.response_value_as_string,'') ), 1, 15) AS BIGINT)
"""


def main():
    con = duckdb.connect()
    con.execute("""
    CREATE TABLE responses(
      secondary_source_concept_id VARCHAR, source_question_concept_id VARCHAR,
      question_concept_id VARCHAR, response_value_as_string VARCHAR);
    INSERT INTO responses VALUES
      ('10', NULL, '100', '353358909'),        -- coded single-select
      ('10', NULL, '100', '353358909'),        -- DUPLICATE tuple (must dedup)
      ('10', '487','200', '619765650'),        -- coded under a grid parent
      ('10', NULL, '300', '47'),               -- numeric
      ('10', NULL, '301', '2023-05-01'),       -- date
      ('10', NULL, '400', 'Aspirin'),          -- free text
      ('10', NULL, '400', 'Tylenol | 500mg'),  -- free text WITH a pipe in the value
      ('10', NULL, '401', 'Aspirin'),          -- same text, different question
      (NULL, NULL, '500', 'x');                -- NULL secondary_source
    """)

    q = f"""
    WITH distinct_responses AS (
      SELECT DISTINCT secondary_source_concept_id, source_question_concept_id,
             question_concept_id, response_value_as_string
      FROM responses
      WHERE response_value_as_string IS NOT NULL AND response_value_as_string <> ''
    )
    SELECT d.secondary_source_concept_id AS sec, d.source_question_concept_id AS sq,
           d.question_concept_id AS qc, d.response_value_as_string AS v,
           {UID_SQL} AS response_unique_id
    FROM distinct_responses d
    """
    rows = con.execute(q).fetchall()
    cols = [c[0] for c in con.description]
    R = [dict(zip(cols, r)) for r in rows]

    # 1. DISTINCT grain (9 input rows, 1 duplicate -> 8)
    assert len(R) == 8, f"DISTINCT grain wrong: got {len(R)}"
    # 2. cross-engine (DuckDB == Python) AND OMOP custom-concept range
    for r in R:
        exp = py_unique_id(r['sec'], r['sq'], r['qc'], r['v'])
        assert r['response_unique_id'] == exp, f"DuckDB/Python mismatch on {r['v']!r}"
        uid = r['response_unique_id']
        assert isinstance(uid, int) and 2000000000 < uid < INT64_MAX, \
            f"unique_id out of OMOP custom range: {uid}"
    # 3. determinism on re-run
    again = {row[-1] for row in con.execute(q).fetchall()}
    assert again == {r['response_unique_id'] for r in R}, "non-deterministic"
    # 4. collision-safety (incl. pipe-in-value, and the same text under two questions)
    uids = [r['response_unique_id'] for r in R]
    assert len(set(uids)) == len(uids), "unique_id collision"
    asp = {r['qc']: r['response_unique_id'] for r in R if r['v'] == 'Aspirin'}
    assert asp['400'] != asp['401'], "same text under different questions collided"
    assert any(r['sec'] is None for r in R), "NULL secondary_source dropped"

    print(f"rows: 9 in -> {len(R)} distinct responses (1 duplicate collapsed)")
    print("response_unique_id: DuckDB == Python, integer, >2e9, <2^63-1: PASS")
    print("determinism / no-collision / pipe-in-value / NULL secondary_source: PASS")
    print("PASS")


if __name__ == "__main__":
    main()
