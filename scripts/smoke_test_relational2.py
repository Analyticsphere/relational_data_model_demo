#!/usr/bin/env python3
"""PRODUCTION-FREE smoke test of relational2.responses (sql/relational2/build_responses.sql).

Builds a synthetic relational.responses (legacy option-as-question shape) + question dim in DuckDB,
applies the same remodel as build_responses.sql (SATA rows -> option-as-answer, response_unique_id
recomputed on the new fields), and proves:
  1. grain preserved (no fanout / no drop),
  2. SATA rows remodeled: question <- parent, source_question <- NULL, answer (as_string & as_concept_id) <- option,
  3. non-SATA rows unchanged (fields AND response_unique_id identical to relational),
  4. response_unique_id RECOMPUTED: differs from the legacy id for SATA rows, identical for non-SATA,
  5. every relational2 id is in OMOP's custom-concept range.

The response_unique_id recipe here mirrors sql/omop/response_unique_id_udf.sql (DuckDB has no BQ UDF).
No production rows are read. Requires: duckdb.

    python scripts/smoke_test_relational2.py
"""
import sys
import hashlib

try:
    import duckdb
except ImportError:
    sys.exit("duckdb not installed: pip install duckdb")

OFFSET = 2000000001
INT64_MAX = 9223372036854775807


def uid(sec, sq, qc, val):
    h = hashlib.sha256("|".join([sec or "", sq or "", qc or "", val or ""]).encode("utf-8")).hexdigest()
    return OFFSET + int(h[:15], 16)


# DuckDB form of the UDF recipe (SHA-256 -> first 15 hex -> +offset), over the REMODELED fields
UID_SQL = f"""{OFFSET} + CAST('0x' || substr(sha256(
    COALESCE(secondary_source_concept_id,'') || '|' || COALESCE(source_question_concept_id,'') || '|' ||
    COALESCE(question_concept_id,'') || '|' || COALESCE(response_value_as_string,'')), 1, 15) AS BIGINT)"""


def main():
    con = duckdb.connect()
    con.execute("""
    CREATE TABLE question(question_concept_id VARCHAR, question_text VARCHAR, question_type VARCHAR);
    INSERT INTO question VALUES
      ('165596977','American Indian or Alaska Native','Optional Select All that Apply'),
      ('807884576','Asian','Select All That Apply'),
      ('783167257','Marital status','Multiple Choice'),
      ('619765650','Tylenol frequency','Grid with Multiple Choice Sub-Questions'),
      ('395168461','Anything else','Text only Response');
    CREATE TABLE responses(
      connect_id VARCHAR, secondary_source_concept_id VARCHAR, source_question_concept_id VARCHAR,
      question_concept_id VARCHAR, loop_instance BIGINT, question_version VARCHAR,
      response_value_as_string VARCHAR, response_unique_id BIGINT, source_table VARCHAR, source_column VARCHAR);
    """)

    # legacy rows (option-as-question); legacy response_unique_id computed on legacy fields.
    # SATA raw cell is a selection marker ('1'), deliberately != the option concept, so the test proves
    # the remodel sources the answer from question_concept_id, not from the raw string.
    legacy = [
        # connect, sec,  source_q,     question,     string,        table, column
        ('A', '100', '479143504', '165596977', '1',           't', 'c1'),  # SATA option checked
        ('A', '100', '479143504', '807884576', '1',           't', 'c2'),  # SATA option checked
        ('A', '100', None,        '783167257', '353358909',   't', 'c3'),  # MC single-select
        ('A', '100', '542661394', '619765650', '2',           't', 'c4'),  # grid sub-question
        ('A', '100', None,        '395168461', 'hello world', 't', 'c5'),  # free text
    ]
    for connect, sec, sq, qc, s, st, sc in legacy:
        con.execute("INSERT INTO responses VALUES (?,?,?,?,1,NULL,?,?,?,?)",
                    [connect, sec, sq, qc, s, uid(sec, sq, qc, s), st, sc])
    legacy_ids = {sc: uid(sec, sq, qc, s) for (_, sec, sq, qc, s, _, sc) in legacy}

    # relational2 transform (mirrors sql/relational2/build_responses.sql)
    q2 = f"""
    WITH sata AS (
      SELECT question_concept_id FROM question WHERE LOWER(question_type) LIKE '%select all that apply%'
    ),
    flagged AS (
      SELECT r.*, (s.question_concept_id IS NOT NULL AND r.source_question_concept_id IS NOT NULL) AS is_sata
      FROM responses r LEFT JOIN sata s ON s.question_concept_id = r.question_concept_id
    ),
    remodeled AS (
      SELECT connect_id, secondary_source_concept_id,
        CASE WHEN is_sata THEN NULL ELSE source_question_concept_id END              AS source_question_concept_id,
        CASE WHEN is_sata THEN source_question_concept_id ELSE question_concept_id END AS question_concept_id,
        CASE WHEN is_sata THEN question_concept_id ELSE response_value_as_string END   AS response_value_as_string,
        is_sata, source_column
      FROM flagged
    )
    SELECT source_column, is_sata, source_question_concept_id, question_concept_id, response_value_as_string,
      CASE WHEN regexp_matches(response_value_as_string, '^[0-9]{{9}}$')
           THEN response_value_as_string ELSE NULL END AS response_value_as_concept_id,
      {UID_SQL} AS response_unique_id
    FROM remodeled
    """
    R = {row[0]: dict(zip([c[0] for c in con.description], row))
         for row in con.execute(q2).fetchall()}

    # 1. grain preserved
    assert len(R) == 5, f"grain changed: {len(R)}"
    # 2 & 4. SATA rows remodeled option-as-answer + id recomputed and DIFFERENT from legacy
    for sc, opt in [('c1', '165596977'), ('c2', '807884576')]:
        r = R[sc]
        assert r['is_sata'], f"{sc} not flagged SATA"
        assert r['question_concept_id'] == '479143504', f"{sc} question not parent"
        assert r['source_question_concept_id'] is None, f"{sc} source_question not NULL"
        assert r['response_value_as_string'] == opt, f"{sc} answer(string) != option"
        assert r['response_value_as_concept_id'] == opt, f"{sc} answer(concept) != option"
        assert 2000000000 < r['response_unique_id'] < INT64_MAX, f"{sc} id out of OMOP range"
        assert r['response_unique_id'] != legacy_ids[sc], f"{sc} id did not change under remodel"
        assert r['response_unique_id'] == uid('100', None, '479143504', opt), f"{sc} id wrong"
    # 3. non-SATA rows unchanged (fields AND response_unique_id)
    for sc in ['c3', 'c4', 'c5']:
        assert not R[sc]['is_sata'], f"{sc} wrongly remodeled"
        assert R[sc]['response_unique_id'] == legacy_ids[sc], f"{sc} non-SATA id changed"
    # grid keeps its sub-item as the question (SATA-only scope)
    assert R['c4']['question_concept_id'] == '619765650' and R['c4']['source_question_concept_id'] == '542661394'

    print("grain preserved (5 -> 5); 2 SATA rows remodeled option-as-answer")
    print("SATA: question<-parent, answer<-option, source_question<-NULL, id RECOMPUTED (differs): PASS")
    print("non-SATA (MC / grid / free-text): fields AND response_unique_id unchanged: PASS")
    print("PASS")


if __name__ == "__main__":
    main()
