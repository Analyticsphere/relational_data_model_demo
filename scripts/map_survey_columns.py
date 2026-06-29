#!/usr/bin/env python3
"""Map parsed survey columns to their fully-qualified dictionary path.

Takes the output of `parse_survey_columns.py` (table, column, concept_ids, loop_number, version_tag, …)
and appends the variable's place in the dictionary hierarchy, getting us most of the way to the rows of
the long-format `responses` fact:

    primary_source_concept_id, secondary_source_concept_id,
    source_question_concept_id (null if the question is standalone),
    question_concept_id, response_concept_id (null — see below)

How each is resolved (verified against the dictionary):
    - question_concept_id        = the LEAF concept in the column path (≈99% are real dict questions).
    - source_question_concept_id = the column's outermost PARENT concept (grid / Source-Question group);
                                   blank for a flat single-concept column.
    - secondary_source_concept_id= STAMPED from the table via docs/source_crosswalk.csv — NOT looked up
                                   from the concept, which is ambiguous (a concept is reused across surveys).
    - primary_source_concept_id  = the secondary source's domain (secondary→primary is single-valued).
    - response_concept_id        = blank. A column is keyed to a QUESTION; the response is the cell VALUE,
                                   populated per-row at unpivot time from the data (not from the schema).

Also emits QC flags: question_in_dict (is the leaf a known dictionary question?) and
secondary_source_match (is the stamped secondary among the concept's dictionary secondary sources?).

Usage:
    python scripts/map_survey_columns.py                          # survey_columns.csv -> stdout CSV
    python scripts/map_survey_columns.py survey_columns.csv -o survey_columns_mapped.csv
    python scripts/map_survey_columns.py --dict data_dictionary/masterFile.csv --crosswalk docs/source_crosswalk.csv

Inputs (defaults): the parsed CSV from parse_survey_columns.py, the dictionary masterFile.csv
(fetch with scripts/fetch_data_dict.py), and docs/source_crosswalk.csv. Stdlib only.
"""
import argparse
import csv
import sys
from collections import defaultdict
from pathlib import Path

# masterFile.csv concept-ID column positions (0-indexed): primary, secondary, source-question, question, response
PRIM, SECID, SQ, Q = 2, 4, 6, 13


def load_dictionary(path):
    """Returns (question_set, secid_to_primid, qcid_to_secids) from the flat dictionary."""
    rows = list(csv.reader(open(path, encoding="utf-8", errors="replace")))
    question_set = set()
    secid_to_primid = {}
    qcid_to_secids = defaultdict(set)
    last_prim = last_secid = ""
    cur_q = None
    for r in rows[1:]:
        prim = r[PRIM].strip() if PRIM < len(r) else ""
        secid = r[SECID].strip() if SECID < len(r) else ""
        q = r[Q].strip() if Q < len(r) else ""
        if prim:
            last_prim = prim
        if secid:
            last_secid = secid
            secid_to_primid.setdefault(secid, last_prim)
        if q:
            cur_q = q
            question_set.add(q)
        if cur_q and last_secid:
            qcid_to_secids[cur_q].add(last_secid)
    return question_set, secid_to_primid, qcid_to_secids


def load_crosswalk(path):
    """Returns base_table -> secondary_source_concept_id (survey tables only).

    A table can map to >1 secondary source in the crosswalk (e.g. covid19Survey -> COVID-19 + Post-Pandemic;
    menstrualSurvey -> the 'Menstrual cycle'/'Menstrual Cycle' casing pair). The crosswalk lists the canonical
    secondary source FIRST, so we keep the first occurrence (setdefault)."""
    table_to_secid = {}
    for row in csv.DictReader(open(path, encoding="utf-8")):
        tbl = (row.get("bq_table") or "").strip()
        secid = (row.get("secondary_source_concept_id") or "").strip()
        if tbl and secid:
            table_to_secid.setdefault(tbl, secid)
    return table_to_secid


def base_table(name):
    """module1_v1 -> module1 ; covid19Survey_v1 -> covid19Survey ; experience2024 -> experience2024."""
    import re
    return re.sub(r"_[vV]\d+$", "", name)


def main():
    ap = argparse.ArgumentParser(
        description="Append the fully-qualified dictionary path to parsed survey columns.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("input", nargs="?", default="survey_columns.csv",
                    help="parsed CSV from parse_survey_columns.py (default: survey_columns.csv)")
    ap.add_argument("--dict", default="data_dictionary/masterFile.csv", help="dictionary masterFile.csv")
    ap.add_argument("--crosswalk", default="docs/source_crosswalk.csv", help="table↔secondary-source crosswalk")
    ap.add_argument("-o", "--output", default=None, help="write CSV here (default: stdout)")
    args = ap.parse_args()

    for p, label in [(args.input, "parsed input"), (args.dict, "dictionary"), (args.crosswalk, "crosswalk")]:
        if not Path(p).exists():
            sys.exit(f"error: {label} not found: {p}")

    question_set, secid_to_primid, qcid_to_secids = load_dictionary(args.dict)
    table_to_secid = load_crosswalk(args.crosswalk)

    reader = csv.DictReader(open(args.input, encoding="utf-8"))
    extra = ["primary_source_concept_id", "secondary_source_concept_id", "source_question_concept_id",
             "question_concept_id", "response_concept_id", "question_in_dict", "secondary_source_match"]
    fieldnames = reader.fieldnames + [c for c in extra if c not in reader.fieldnames]

    out_fh = open(args.output, "w", newline="") if args.output else sys.stdout
    writer = csv.DictWriter(out_fh, fieldnames=fieldnames)
    writer.writeheader()

    n = n_q_in_dict = n_sec_match = n_unmapped_table = 0
    for row in reader:
        n += 1
        cids = [c for c in (row.get("concept_ids") or "").split(";") if c]
        question = cids[-1] if cids else ""
        source_question = cids[0] if len(cids) >= 2 else ""

        secid = table_to_secid.get(base_table(row["table"]), "")
        if not secid:
            n_unmapped_table += 1
        primid = secid_to_primid.get(secid, "")

        q_in_dict = question in question_set
        sec_match = secid in qcid_to_secids.get(question, set()) if (secid and question) else False
        n_q_in_dict += q_in_dict
        n_sec_match += sec_match

        row.update({
            "primary_source_concept_id": primid,
            "secondary_source_concept_id": secid,
            "source_question_concept_id": source_question,
            "question_concept_id": question,
            "response_concept_id": "",  # the response is the cell value, filled at unpivot from data
            "question_in_dict": "Y" if q_in_dict else "N",
            "secondary_source_match": "Y" if sec_match else "N",
        })
        writer.writerow(row)

    if args.output:
        out_fh.close()
    print(f"mapped {n} columns: {n_q_in_dict} leaf-is-known-question, {n_sec_match} secondary-source-match"
          + (f", {n_unmapped_table} from tables with no crosswalk entry" if n_unmapped_table else "")
          + (f" -> {args.output}" if args.output else ""), file=sys.stderr)


if __name__ == "__main__":
    main()
