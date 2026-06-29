#!/usr/bin/env python3
"""Build a categorized worklist of survey columns that didn't map cleanly to the dictionary.

Reads the output of `map_survey_columns.py` (which carries leaf_role / question_in_dict /
secondary_source_match) plus the dictionary, and emits one row per column that needs attention,
tagged with an `issue` category and the concept's actual dictionary secondary sources.

Issue categories:
    concept_absent_from_dictionary    leaf concept is in NO dictionary role (needs a dictionary addition)
    concept_present_but_not_as_question leaf is in the dictionary but not as a question/source-question
    source_question_level_column      leaf is a Source-Question concept used directly (no sub-question;
                                      e.g. a loop on a grid parent) — question is implicit/Quest-defined
    bio_survey_mapping_unconfirmed    bioSurvey/clinicalBioSurvey survey stamp is a best guess (concepts
                                      shared across Blood/Urine, Blood/Urine/Mouthwash, COVID-19) — confirm w/ DevOps
    reused_concept_survey_not_in_dict question is in the dictionary but the stamped survey isn't in its
                                      dictionary set (cross-survey reuse the dictionary under-records — table stamp is correct)
    impure_token_present              column carries a non-conforming (SAS-mnemonic) token

Usage:
    python scripts/review_unmapped_columns.py                       # output/..._mapped.csv -> stdout
    python scripts/review_unmapped_columns.py output/survey_columns_clean_mapped.csv -o output/columns_needs_review.csv

Stdlib only. Reads the dictionary (data_dictionary/masterFile.csv) only to look up each concept's roles.
"""
import argparse
import csv
import sys
from collections import Counter, defaultdict
from pathlib import Path

PRIM, SECID, SEC, SQ, Q, R = 2, 4, 5, 6, 13, 22
BIO = {"bioSurvey", "clinicalBioSurvey"}


def load_dict_roles(path):
    rows = list(csv.reader(open(path, encoding="utf-8", errors="replace")))
    question_set, source_question_set, any_role = set(), set(), set()
    secid_name, qcid_to_secids = {}, defaultdict(set)
    cur_q = None
    for r in rows[1:]:
        secid = r[SECID].strip() if SECID < len(r) else ""
        sec = r[SEC].strip() if SEC < len(r) else ""
        sq = r[SQ].strip() if SQ < len(r) else ""
        q = r[Q].strip() if Q < len(r) else ""
        if secid and sec:
            secid_name[secid] = sec
        if sq:
            source_question_set.add(sq)
        if q:
            cur_q = q
            question_set.add(q)
        for c in (r[PRIM].strip() if PRIM < len(r) else "", secid, sq, q, r[R].strip() if R < len(r) else ""):
            if c.isdigit() and len(c) == 9:
                any_role.add(c)
        if cur_q and secid:
            qcid_to_secids[cur_q].add(secid)
    return question_set, source_question_set, any_role, secid_name, qcid_to_secids


def main():
    ap = argparse.ArgumentParser(
        description="Categorized worklist of survey columns that didn't map cleanly.",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("input", nargs="?", default="output/survey_columns_clean_mapped.csv",
                    help="mapped CSV from map_survey_columns.py")
    ap.add_argument("--dict", default="data_dictionary/masterFile.csv", help="dictionary masterFile.csv")
    ap.add_argument("-o", "--output", default=None, help="write CSV here (default: stdout)")
    args = ap.parse_args()
    for p in (args.input, args.dict):
        if not Path(p).exists():
            sys.exit(f"error: not found: {p}")

    question_set, source_question_set, any_role, secid_name, qcid_to_secids = load_dict_roles(args.dict)

    def categorize(r):
        leaf = r.get("question_concept_id") or r.get("source_question_concept_id") or ""
        role = r.get("leaf_role", "")
        if r.get("nonconforming_tokens"):
            return "impure_token_present"
        if role == "source_question":
            return "source_question_level_column"
        if role == "other":
            cid = r.get("question_concept_id") or ""
            return "concept_absent_from_dictionary" if cid not in any_role else "concept_present_but_not_as_question"
        if r.get("secondary_source_match") == "N":
            return "bio_survey_mapping_unconfirmed" if r["table"] in BIO else "reused_concept_survey_not_in_dict"
        return "ok"

    cols = ["issue", "table", "column", "leaf_role", "question_concept_id", "source_question_concept_id",
            "secondary_source_concept_id", "dict_secondary_sources", "version_tag", "loop_number", "nonconforming_tokens"]
    out_fh = open(args.output, "w", newline="") if args.output else sys.stdout
    writer = csv.DictWriter(out_fh, fieldnames=cols, extrasaction="ignore")
    writer.writeheader()

    counts = Counter()
    for r in csv.DictReader(open(args.input, encoding="utf-8")):
        issue = categorize(r)
        if issue == "ok":
            continue
        counts[issue] += 1
        q = r.get("question_concept_id") or ""
        r["issue"] = issue
        r["dict_secondary_sources"] = ";".join(sorted(secid_name.get(s, s) for s in qcid_to_secids.get(q, ())))
        writer.writerow(r)

    if args.output:
        out_fh.close()
    total = sum(counts.values())
    print(f"{total} columns need review" + (f" -> {args.output}" if args.output else ""), file=sys.stderr)
    for issue, n in counts.most_common():
        print(f"  {n:4}  {issue}", file=sys.stderr)


if __name__ == "__main__":
    main()
