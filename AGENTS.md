# AGENTS.md — Connect Relational Data Model

Working guide for collaborators (human and AI agents) in this repository. Read this first.

## What this repo is

A **design effort** for a normalized relational (star-schema) data model for the Connect cohort, to replace
the wide "dancing-schema" survey tables. The deliverables are *design and pitch artifacts* — schema dumps,
ERDs, worked queries, an ETL sketch, and a slide deck — feeding an internal kick-off and the eventual
researcher-facing **PR2** warehouse. **Current status: design phase** — not production pipeline code yet
(no live ETL, dbt models, or table DDL); those come after the model is agreed.

## The study

**Connect for Cancer Prevention (C4CP)** is a large NCI prospective cohort. Participants complete a series of
**surveys** (the baseline modules plus follow-ups: mouthwash, COVID, menstrual, quality-of-life, diet, …) and
provide **biospecimens** over repeated rounds. Surveys are authored/delivered with the **Quest** engine into
Google Firestore, then exported and progressively transformed in BigQuery:
`Connect` (raw) → `FlatConnect` (flattened) → `CleanConnect` (standardized; the recommended structural source).

## The data-modeling challenge

The analysis-ready data is **wide tables of opaque 9-digit concept-ID columns** (e.g. `module1` ≈ 2,360
columns). Concretely:

- **Dancing schema** — every new answer, option, or loop instance adds *columns*; downstream queries and tools
  break as the survey app evolves.
- **Version drift** — a revised question leaves parallel `v1`/`v2` columns analysts reconcile by hand.
- **Invisible structure** — skip logic, loops, and grids are encoded only in column-name conventions; select-all
  and grids explode into families of indicator columns.
- **No shared abstractions / no self-description** — meaning lives in column names, sidecar files, and tribal
  knowledge, so every analysis re-derives it.

## The model (accepted) + incremental enhancements

**The accepted model is "Dictionary-Direct":** adopt the CIDTool dictionary tables *as emitted* (the
dictionary stays the **source of truth**) + add **one** long **`responses`** fact (one row per answer) that
joins to them. Kills the dancing schema; proves the long-format thesis; low-risk. Model source:
`dbml/data_model_modest.dbml`; ERDs in `docs/connect_model_a*.svg`; the wide→long transform in `sql/unpivot/`.

A larger redesigned warehouse was explored but **not** adopted as a wholesale transformation. Its valuable
capabilities are tracked as **potential incremental extensions** to the Dictionary-Direct model — normalized
question-type view, typed value columns, version handling, `skip_logic`, `response_sessions`, concept
equivalence, governance (sensitivity tiers + IAM), **dbt analytics marts**, and the event plane. See
**`docs/enhancement_backlog.md`**. Each attaches to the same `responses` fact without rebuilding it.

## Data dictionary & CIDTool

- **Data dictionary** — `episphere/conceptGithubActions` → `csv/masterFile.csv`: the denormalized "Variable
  Dictionary" (one row per question×response option) carrying concept IDs, labels, types, PII flags, and skip
  hints. Messy/spreadsheet-origin (forward-fill the hierarchy before use).
- **CIDTool** (`NCI-C4CP/CIDTool`) — transforms that flat dictionary into a **relational JSON** representation:
  the five concept tables `PRIMARY_SOURCE → SECONDARY_SOURCE → SOURCE_QUESTION → QUESTION → RESPONSE` plus
  `VARIABLE_METADATA`. It is the **intended authoritative input that generates the model's dimensions** (so
  labels/types can't drift from the dictionary). **The model adopts CIDTool's emitted tables verbatim** — the
  dictionary is the source of truth, not a re-cleaned copy.
- **Quest markup** (`episphere/quest/questionnaires/*.txt`) is the complementary structural source — question
  order, skip logic (`displayif`/`->`), loops, grids — that the dictionary doesn't capture.

## Repository map

| Path | What |
|---|---|
| `README.md` | public-facing summary of the model + motivation |
| `docs/internal_pitch.md` | the kick-off pitch (OMOP framing, pain exhibits, value props) |
| `docs/example_queries.md` | the same analyses written two ways: wide tables vs the model |
| `docs/enhancement_backlog.md` | the accepted-model decision + each candidate enhancement (value, sketch, cost) |
| `docs/devops_event_tables_memo.md` | reconciliation memo for the DevOps long-format event tables |
| `docs/source_crosswalk.csv` | dictionary Secondary Source ↔ concept_id ↔ domain ↔ `is_survey` ↔ BQ table ↔ questionnaire file |
| `docs/*.svg` · `docs/Connect_Data_Model_Pitch.pptx` · `docs/build_deck.py` | ERDs + slide deck (regenerable) |
| `dbml/` · `sql/*.sql` · `mermaid/` | model sources: dbsketch DBML, constraint-free DDL, and `erDiagram` twins (the model + event plane) |
| `sql/unpivot/` | **generated** wide→long `responses` transform (UNPIVOT + colmap join) + `00_responses_ddl.sql` + `validate_responses.sql`. Uses `${PROJECT}` placeholder — run `generate_unpivot_sql.py` to emit. |
| `sql/unpivot_stage/` | Same transform **hardcoded to the stage project** (`nih-nci-dceg-connect-stg-5519`) — safe to run directly without substitution. Regenerated by `generate_unpivot_sql.py` (default). |
| `sql/build_dimension_tables.sql` · `sql/build_concept_relationship.sql` | DuckDB demo dimensions + concept-equivalence (`synonym`) plane — **CIDTool replaces these later** |
| `output/` | regenerable derived artifacts: column→dictionary mapping, demo dim tables (CSV/Parquet), `concept_relationship` |
| `schemas/<env>/<layer>/<table>.json` | BigQuery schema dumps per environment (`prod` / `stage`) — field-shape ground truth |
| `schemas/relational/<table>.json` | **Explicit BQ schemas for the `relational` dataset tables** (concept IDs as STRING). Source of truth for `setup_relational.py` loads — prevents autodetect from casting concept IDs as INTEGER. |
| `scripts/` | fetch scripts **+ the column→dictionary→`responses` pipeline** (see below) |

## Scripts (`scripts/`, stdlib-only except `fetch_bq_schemas.py`, `smoke_test_unpivot.py`, and `setup_relational.py`)

```bash
# fetch source artifacts:
python scripts/fetch_bq_schemas.py CleanConnect                     # BQ schemas -> schemas/prod/<dataset>/  (--project defaults to Connect prod)
python scripts/fetch_bq_schemas.py CleanConnect \
  --project nih-nci-dceg-connect-stg-5519 --output-dir schemas/stage  # stage schemas -> schemas/stage/<dataset>/
python scripts/fetch_data_dict.py                 # masterFile.csv -> data_dictionary/  (--json for JSON too)
python scripts/fetch_surveys.py                   # real Quest modules -> surveys/  (--all for everything, --list to see)

# column -> dictionary path -> responses transform (never queries production; uses schemas + dictionary):
python scripts/parse_survey_columns.py --layer CleanConnect -o output/survey_columns_stage_clean.csv  # defaults to schemas/stage
python scripts/map_survey_columns.py    output/survey_columns_stage_clean.csv -o output/survey_columns_stage_mapped.csv
python scripts/review_unmapped_columns.py output/survey_columns_stage_mapped.csv -o output/columns_needs_review.csv
python scripts/generate_unpivot_sql.py            # -> sql/unpivot_stage/ hardcoded to stage project (default)
python scripts/smoke_test_unpivot.py              # prod-free shape check of the unpivot (PASS/FAIL; needs duckdb)

# set up (or refresh) the relational dataset in BigQuery stage:
python scripts/setup_relational.py --dims --yes   # dataset + colmap + responses table + colmap view + all dim tables
```

Each documents its usage/defaults at the top. `fetch_bq_schemas.py` and `setup_relational.py` need
`pip install google-cloud-bigquery` and `gcloud auth application-default login`; `smoke_test_unpivot.py`
needs `pip install duckdb`. **Never query production data** — the pipeline runs on committed schemas + the
public dictionary only.

## Conventions

- **Concept IDs are the spine.** Every key resolves to a 9-digit concept ID; human labels are attributes,
  **never join keys** — label-as-join-key is the failure mode this model removes.
- **Long over wide.** New answers / options / loops are *rows*, never new columns.
- **Survey vs. not is decided by the dictionary Primary Source** (`Survey` vs. Biospecimen / Recruitment / …);
  see `docs/source_crosswalk.csv`. The four `module1–4` tables map 1:1 to the four baseline survey sections.
- **Model sources come in three formats** (`dbml/` source, `sql/`, `mermaid/`). Change the model → update all
  three (until one is chosen as canonical) and re-render the SVGs/deck.
- **The deck is generated** from `docs/build_deck.py` (`python docs/build_deck.py`) — edit the script, not the `.pptx`.
- **Ground claims in the real artifacts** (schemas, dictionary, Quest, source repos). Cite numbers; be honest
  about cost/uncertainty; don't invent mappings — flag best-guesses (as the crosswalk does).
- **`schemas/relational/*.json` are the BQ type source of truth.** Always pass these to `bq load` via
  `setup_relational.py`; never rely on autodetect (it casts 9-digit concept IDs as INTEGER).
- **`responses` must be clustered before production load.** Cluster on
  `(secondary_source_concept_id, question_concept_id, connect_id)`. See `docs/enhancement_backlog.md` §0
  and the DDL comment in `sql/unpivot_stage/00_responses_ddl.sql` for the full rationale and future
  partitioning plan.
- **Never query production data directly** (project `nih-nci-dceg-connect-prod-6d04`) — not even for spot
  checks. Schema metadata via `fetch_bq_schemas.py` is the only permitted prod access. All data work runs
  against stage (`nih-nci-dceg-connect-stg-5519`).
- **Always pass `--project_id=nih-nci-dceg-connect-stg-5519` explicitly** on every `bq` CLI command — never
  rely on the gcloud default project (which may be prod).

## Git

- **Never add a `Co-Authored-By` (or any "Co-authored-by …") trailer to commits.** No AI/assistant attribution, ever.
- Keep commit messages specific; branch off `main` for substantial changes.
- Don't commit generated bytecode (`__pycache__/`) or large fetched data dumps unless the team decides to
  track them; `schemas/` *is* tracked (reviewed ground truth). Schemas are stored per environment: `schemas/prod/` for prod, `schemas/stage/` for stage.
