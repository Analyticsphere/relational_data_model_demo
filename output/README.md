# output/ — derived column-mapping snapshots

Point-in-time, **regenerable** artifacts from the column→dictionary mapping pipeline. Committed during the
exploratory phase so collaborators can review them without running the pipeline. Snapshot built from the
**CleanConnect** schema dumps in `schemas/` + the data dictionary (`masterFile.csv`), 2026-06.

| File | What |
|---|---|
| `survey_columns_clean_mapped.csv` | every CleanConnect survey column → parsed (concept_ids, loop, version) + its fully-qualified dictionary path (primary/secondary source, source_question, question) + QC flags (`leaf_role`, `question_in_dict`, `secondary_source_match`) |
| `columns_needs_review.csv` | the ~3% of columns that don't map cleanly, categorized (`issue` column) with the concept's actual dictionary secondary sources |

`response_concept_id` is intentionally blank — a column is keyed to a *question*; the response is the cell
**value**, populated per row at unpivot time from the data (which we do not query).

## Regenerate

```bash
python scripts/fetch_data_dict.py                                                   # data_dictionary/masterFile.csv
python scripts/fetch_bq_schemas.py CleanConnect                                     # schemas/CleanConnect/*.json (metadata only)
python scripts/parse_survey_columns.py --layer CleanConnect -o output/survey_columns_clean.csv
python scripts/map_survey_columns.py    output/survey_columns_clean.csv  -o output/survey_columns_clean_mapped.csv
python scripts/review_unmapped_columns.py output/survey_columns_clean_mapped.csv -o output/columns_needs_review.csv
```

(`output/survey_columns_clean.csv` — the intermediate parse — and `data_dictionary/masterFile.csv` are
git-ignored; the dictionary is large and drifts upstream, re-fetch as above.)

## Review buckets (current snapshot)

- `source_question_level_column` — a Source-Question concept used directly (e.g. a loop driver); informational.
- `bio_survey_mapping_unconfirmed` — `bioSurvey`/`clinicalBioSurvey` → secondary source is a best guess
  (concepts shared across Blood/Urine, Blood/Urine/Mouthwash, COVID-19); **confirm with DevOps**.
- `concept_absent_from_dictionary` — leaf concept in no dictionary role; **needs a dictionary addition**.
- `reused_concept_survey_not_in_dict` — table stamp is correct; the dictionary under-records cross-survey
  reuse (no action).
