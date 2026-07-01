# output/ — derived column-mapping snapshots

Point-in-time, **regenerable** artifacts from the column→dictionary mapping pipeline. Committed during the
exploratory phase so collaborators can review them without running the pipeline. Snapshot built from the
**CleanConnect** schema dumps in `schemas/prod/` + the data dictionary (`masterFile.csv`), 2026-06.

| File | What |
|---|---|
| `survey_columns_clean_mapped.csv` | every CleanConnect survey column → parsed (concept_ids, loop, version) + its fully-qualified dictionary path (primary/secondary source, source_question, question) + QC flags (`leaf_role`, `question_in_dict`, `secondary_source_match`) |
| `columns_needs_review.csv` | the ~3% of columns that don't map cleanly, categorized (`issue` column) with the concept's actual dictionary secondary sources |
| `dim/*.csv` | **demo-quality CIDTool-style dimension tables** normalized from the dictionary: `primary_source` (13), `secondary_source` (80), `source_question` (679), `question` (3240), `response` (1131), `question_response` bridge (8672). Built by `sql/build_dimension_tables.sql`; **will eventually load from CIDTool**. Referential integrity is clean (0 orphans). Caveat: `question.current_source_question_concept_id` is one representative per concept — accurate for non-reused questions (99.6% vs the column-derived placement) but lossy for reused concepts (a *placement* property → the placement-bridge enhancement). |
| `dim/v_data_dictionary.csv` | the dimensions **denormalized back into a flat data-dictionary-like view** (one row per question × allowed response, ~9,973 rows; free-text questions get a NULL-response row). Defined as the `v_data_dictionary` VIEW in the build script — recreate it as a BigQuery view over the loaded dim tables. |
| `dim/concept_relationship.csv` | **demo concept-equivalence plane** (OMOP-style `concept_id_1, concept_id_2, relationship`). Seeds `synonym` links for reused **address-component** concepts (the geocoding use case): 66 "street name of residence" concepts → one canonical, separate from work/school. Built by `sql/build_concept_relationship.sql`. Demo caveat: groups derived by matching question text (mirrors the geocoding repos' label-matching) — the real links come from CIDTool / a curated `question_equivalence`. Lets `WHERE concept_id_2 = <canonical>` replace a 26-branch `case_when`. |

`response_concept_id` is intentionally blank — a column is keyed to a *question*; the response is the cell
**value**, populated per row at unpivot time from the data (which we do not query).

## Regenerate

```bash
python scripts/fetch_data_dict.py                                                   # data_dictionary/masterFile.csv
python scripts/fetch_bq_schemas.py CleanConnect                                     # schemas/prod/CleanConnect/*.json (metadata only)
python scripts/parse_survey_columns.py --layer CleanConnect -o output/survey_columns_clean.csv
python scripts/map_survey_columns.py    output/survey_columns_clean.csv  -o output/survey_columns_clean_mapped.csv
python scripts/review_unmapped_columns.py output/survey_columns_clean_mapped.csv -o output/columns_needs_review.csv

# demo dimension tables (also writes output/connect_dimensions.duckdb — git-ignored binary):
mkdir -p output/dim && duckdb output/connect_dimensions.duckdb < sql/build_dimension_tables.sql
# validate them (row counts, referential integrity, source_question cross-check):
duckdb output/connect_dimensions.duckdb < sql/validate_dimension_tables.sql
# demo concept-equivalence plane (address-field synonyms — the geocoding use case):
duckdb output/connect_dimensions.duckdb < sql/build_concept_relationship.sql
```

The build also writes **`output/dim/*.parquet`** (git-ignored, regenerable) — load-ready for BigQuery,
since Parquet carries the schema/types (concept IDs as STRING; no `--autodetect` needed):

```bash
bq load --source_format=PARQUET connect_dim.question gs://<bucket>/question.parquet   # one per table
# or: CREATE EXTERNAL TABLE … OPTIONS(format='PARQUET', uris=['gs://…/question.parquet'])
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
