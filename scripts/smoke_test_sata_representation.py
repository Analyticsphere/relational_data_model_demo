#!/usr/bin/env python3
"""Reproducible, PRODUCTION-FREE smoke test of the SATA dual-representation view
(sql/unpivot/v_responses_sata_v2.sql).

Runs the REAL view SQL (only the `${PROJECT}.relational.` prefix stripped) in DuckDB over a synthetic
`responses` fact + `question` dim that mirror the real column names, and proves:
  1. SATA rows are remodeled option-as-answer: question <- parent, answer <- option, source_question <- NULL,
  2. Grid sub-questions are NOT remodeled (scope = SATA only) — a grid row keeps question = sub-item,
  3. Multiple-choice / free-text rows pass through unchanged,
  4. the transform is lossless/reversible via orig_* columns, and row count is preserved (no fan-out/drop).

No production rows are read. Requires: duckdb.

    python scripts/smoke_test_sata_representation.py
"""
import sys
import pathlib
import re

try:
    import duckdb
except ImportError:
    sys.exit("duckdb not installed: pip install duckdb")

VIEW_SQL = pathlib.Path(__file__).resolve().parent.parent / "sql/unpivot/v_responses_sata_v2.sql"


def main():
    con = duckdb.connect()
    # synthetic `question` dim — question_type lives on the OPTION row for SATA (legacy shape)
    con.execute("""
    CREATE TABLE question(
      question_concept_id VARCHAR, question_text VARCHAR, question_type VARCHAR,
      secondary_source_concept_id VARCHAR, source_question_concept_id VARCHAR);
    INSERT INTO question VALUES
      ('165596977','American Indian or Alaska Native','Optional Select All that Apply','100','479143504'),
      ('807884576','Asian','Select All That Apply','100','479143504'),
      ('783167257','Marital status','Multiple Choice','100',NULL),
      ('619765650','Tylenol frequency','Grid with Multiple Choice Sub-Questions','100','542661394'),
      ('395168461','Anything else to tell us','Text only Response','100',NULL);
    """)
    # synthetic `responses` fact (LEGACY option-as-question shape)
    con.execute("""
    CREATE TABLE responses(
      connect_id VARCHAR, secondary_source_concept_id VARCHAR, source_question_concept_id VARCHAR,
      question_concept_id VARCHAR, loop_instance BIGINT, question_version VARCHAR,
      response_value_as_string VARCHAR, response_value_as_number DOUBLE,
      response_value_as_concept_id VARCHAR, source_table VARCHAR, source_column VARCHAR);
    INSERT INTO responses VALUES
      ('A','100','479143504','165596977',1,NULL,'165596977',NULL,NULL,'t','c1'), -- SATA option checked
      ('A','100','479143504','807884576',1,NULL,'807884576',NULL,NULL,'t','c2'), -- SATA option checked
      ('A','100', NULL,      '783167257',1,NULL,'353358909',NULL,NULL,'t','c3'), -- MC single-select
      ('A','100','542661394','619765650',1,NULL,'2',        NULL,NULL,'t','c4'), -- grid sub-question (scale=2)
      ('A','100', NULL,      '395168461',1,NULL,'hello world',NULL,NULL,'t','c5'); -- free text
    """)

    # run the REAL view SQL (strip only the BigQuery project.dataset prefix)
    view_ddl = re.sub(r"`\$\{PROJECT\}\.relational\.(\w+)`", r"\1", VIEW_SQL.read_text())
    con.execute(view_ddl)

    rows = con.execute("""
      SELECT source_column, question_concept_id, source_question_concept_id,
             response_value_as_string, response_value_as_concept_id, sata_remodeled,
             orig_question_concept_id, orig_source_question_concept_id
      FROM v_responses_sata_v2 ORDER BY source_column
    """).fetchall()
    cols = [c[0] for c in con.description]
    R = {r[0]: dict(zip(cols, r)) for r in rows}

    # 0. no fan-out / no drop
    assert len(R) == 5, f"row count changed: {len(R)}"

    # 1. SATA rows remodeled: question <- parent, answer <- option, source_question NULL
    for sc, option in [('c1', '165596977'), ('c2', '807884576')]:
        r = R[sc]
        assert r['sata_remodeled'] is True, f"{sc} not flagged SATA"
        assert r['question_concept_id'] == '479143504', f"{sc} question not parent: {r['question_concept_id']}"
        assert r['source_question_concept_id'] is None, f"{sc} source_question not NULL"
        assert r['response_value_as_concept_id'] == option, f"{sc} answer(concept) != option"
        assert r['response_value_as_string'] == option, f"{sc} answer(string) != option"
        # reversible
        assert r['orig_question_concept_id'] == option
        assert r['orig_source_question_concept_id'] == '479143504'

    # 2. Grid NOT remodeled (scope = SATA only): sub-item stays the question
    g = R['c4']
    assert g['sata_remodeled'] is False, "grid row wrongly remodeled"
    assert g['question_concept_id'] == '619765650', "grid sub-item lost its question identity"
    assert g['source_question_concept_id'] == '542661394', "grid parent dropped"
    assert g['response_value_as_string'] == '2', "grid answer changed"

    # 3. MC + free text pass through unchanged
    mc = R['c3']
    assert mc['sata_remodeled'] is False
    assert mc['question_concept_id'] == '783167257' and mc['source_question_concept_id'] is None
    assert mc['response_value_as_string'] == '353358909'
    ft = R['c5']
    assert ft['sata_remodeled'] is False and ft['question_concept_id'] == '395168461'
    assert ft['response_value_as_string'] == 'hello world'

    # 4. lossless: orig_* reproduces the legacy `responses` placement for every row
    legacy = con.execute("""
      SELECT source_column, question_concept_id, source_question_concept_id FROM responses
    """).fetchall()
    for sc, qc, sq in legacy:
        assert R[sc]['orig_question_concept_id'] == qc
        assert R[sc]['orig_source_question_concept_id'] == sq

    n_remodeled = sum(1 for r in R.values() if r['sata_remodeled'])
    print(f"rows: 5 (unchanged count) — {n_remodeled} SATA options remodeled option-as-answer")
    print("SATA: question<-parent, answer<-option, source_question<-NULL: PASS")
    print("Grid NOT remodeled (SATA-only scope) / MC + free-text unchanged: PASS")
    print("lossless & reversible via orig_* columns: PASS")
    print("PASS")


if __name__ == "__main__":
    main()
