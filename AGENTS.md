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

## The proposed solution

Store answers as **rows** in a long **`responses`** fact (one row per answer), joined to dimensions generated
from the data dictionary and Quest markup. Pitched in two phases:

- **Phase 1 / Model A — "Dictionary-Direct":** adopt the CIDTool dictionary tables *as emitted* + add **one**
  new `responses` table that joins to them. Low-risk, fast first win; kills the dancing schema; proves the
  long-format thesis. (Model source: `dbml/data_model_modest.dbml`; ERDs in `docs/connect_model_a*.svg`.)
- **Phase 2 / Model B:** cleaned researcher-facing dimensions, a `survey_questions` placement bridge,
  `response_sessions`, structured `skip_logic`, governance (sensitivity tiers + BigQuery IAM), and curated
  marts. (Model source: `dbml/data_model.dbml`.)

## Data dictionary & CIDTool

- **Data dictionary** — `episphere/conceptGithubActions` → `csv/masterFile.csv`: the denormalized "Variable
  Dictionary" (one row per question×response option) carrying concept IDs, labels, types, PII flags, and skip
  hints. Messy/spreadsheet-origin (forward-fill the hierarchy before use).
- **CIDTool** (`NCI-C4CP/CIDTool`) — transforms that flat dictionary into a **relational JSON** representation:
  the five concept tables `PRIMARY_SOURCE → SECONDARY_SOURCE → SOURCE_QUESTION → QUESTION → RESPONSE` plus
  `VARIABLE_METADATA`. It is the **intended authoritative input that generates the model's dimensions** (so
  labels/types can't drift from the dictionary). **Model A adopts CIDTool's emitted tables verbatim**; Model B
  cleans them into researcher-facing dimensions.
- **Quest markup** (`episphere/quest/questionnaires/*.txt`) is the complementary structural source — question
  order, skip logic (`displayif`/`->`), loops, grids — that the dictionary doesn't capture.

## Repository map

| Path | What |
|---|---|
| `README.md` | public-facing summary of the model + motivation |
| `docs/internal_pitch.md` | the kick-off pitch (OMOP framing, pain exhibits, two phases, value props) |
| `docs/example_queries.md` | the same analyses written three ways: wide vs Phase 1 vs Phase 2 |
| `docs/phase2_etl_sketch.md` | design sketch of the Phase 2 ETL (Quest parser, column→placement map, stages) |
| `docs/devops_event_tables_memo.md` | reconciliation memo for the DevOps long-format event tables |
| `docs/source_crosswalk.csv` | dictionary Secondary Source ↔ concept_id ↔ domain ↔ `is_survey` ↔ BQ table ↔ questionnaire file |
| `docs/*.svg` · `docs/Connect_Data_Model_Pitch.pptx` · `docs/build_deck.py` | ERDs + slide deck (regenerable) |
| `dbml/` · `sql/` · `mermaid/` | model sources: dbsketch DBML, DDL, and `erDiagram` twins (+ convenience view, DuckDB demo) |
| `schemas/<layer>/<table>.json` | BigQuery schema dumps (Connect / FlatConnect / CleanConnect) — field-shape ground truth |
| `scripts/` | source-fetch scripts (BQ schemas, data dictionary, surveys) |

## Fetch scripts (`scripts/`, stdlib-only except the BQ one)

```bash
python scripts/fetch_bq_schemas.py CleanConnect   # BQ schemas -> schemas/<dataset>/  (--project defaults to Connect prod)
python scripts/fetch_data_dict.py                 # masterFile.csv -> data_dictionary/  (--json for JSON too)
python scripts/fetch_surveys.py                   # real Quest modules -> surveys/  (--all for everything, --list to see)
```

Each documents its usage/defaults at the top. `fetch_bq_schemas.py` needs
`pip install google-cloud-bigquery` and `gcloud auth application-default login`.

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

## Git

- **Never add a `Co-Authored-By` (or any "Co-authored-by …") trailer to commits.** No AI/assistant attribution, ever.
- Keep commit messages specific; branch off `main` for substantial changes.
- Don't commit generated bytecode (`__pycache__/`) or large fetched data dumps unless the team decides to
  track them; `schemas/` *is* tracked (reviewed ground truth).
