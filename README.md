# Connect Data Model

Proposed relational data model for the **Connect for Cancer Prevention Cohort Study**, built on BigQuery.

## Background

Connect is a large-scale prospective cohort study. Participants complete a series of surveys — covering health history, biospecimens, COVID-19, menstrual health, and more — and their responses are stored in Google Firestore.

The full data pipeline from Firestore to analysis-ready tables has three stages:

1. **Firestore → FlatConnect** ([flattener](https://github.com/Analyticsphere/flattener) + [flattener-orchestrator](https://github.com/Analyticsphere/flattener-orchestrator)): exports nested BigQuery tables to Parquet in GCS, uses DuckDB to recursively flatten all leaf fields into wide tables (e.g. `parent_child_grandchild`), expands array fields into binary indicator columns, and loads the result back into BigQuery as `FlatConnect`. Runs daily via an Airflow DAG.
2. **FlatConnect → CleanConnect** ([pr2-transformation](https://github.com/Analyticsphere/pr2-transformation) + [pr2-orchestration](https://github.com/Analyticsphere/pr2-orchestration)): a serverless Cloud Run ETL that standardizes column names, converts binary 0/1 values to concept IDs, and merges multi-version survey tables.
3. **CleanConnect → (this project)**: proposes a normalized relational layer above CleanConnect, driven by the Connect data dictionary, to support repeatable analyses across question types.

The `schemas/` folder in this repository captures the BigQuery schemas at stages 1 and 2:

The current BigQuery representation has two layers:

| Dataset | Description |
|---|---|
| `schemas/Connect/` | Raw hierarchical BigQuery dataset as exported from Firestore. Field names are opaque concept identifiers (e.g. `D_224791140`). Nested `RECORD` types reflect Firestore document structure. Some survey versions are empty stubs pending population. (Each JSON file represents a table in this dataset.) |
| `schemas/FlatConnect/` | Flattened BigQuery dataset produced by the flattener pipeline. Wide tables where nested paths become underscore-delimited column names (e.g. `parent_child_grandchild`) and array fields become binary indicator columns. (Each JSON file represents a table in this dataset.) |
| `schemas/CleanConnect/` | Cleaned and standardized BigQuery dataset produced by the PR2 pipeline. Further processing of FlatConnect: column names standardized, binary values converted to concept IDs, multi-version tables merged. (Each JSON file represents a table in this dataset.) |

### Surveys and Schema Sizes

| Survey | Raw (Connect/) | Flattened (FlatConnect/) | Clean (CleanConnect/) |
|---|---|---|---|
| `participants` | 280 fields | 462 fields | 452 fields |
| `module1` | 645 / 1,085 fields (v1/v2) | (flattened) | 2,360 fields |
| `module2` | 487 fields (v2) | (flattened) | 774 fields |
| `module3` | 487 fields | (flattened) | 403 fields |
| `module4` | 331 fields | (flattened) | 813 fields |
| `bioSurvey` | 156 fields | 351 fields | 323 fields |
| `clinicalBioSurvey` | 137 fields | (flattened) | 295 fields |
| `covid19Survey` | 295 fields | (flattened) | 528 fields |
| `experience2024` | 45 fields | (flattened) | 86 fields |
| `biospecimen` | 43 fields | (flattened) | 340 fields |
| `mouthwash` | 41 fields | (flattened) | 56 fields |
| `menstrualSurvey` | (empty) | (empty) | 5 fields |
| `promis` | (empty) | 63 fields | — |

---

## Motivation for a New Data Model

The current wide-table approach has several limitations:

- **Opaque identifiers**: field names are numeric concept codes with no human-readable labels embedded in the schema.
- **No shared abstractions**: similar question types (e.g. single-select, multi-select, date, numeric) require bespoke SQL in every analysis.
- **No explicit survey structure**: relationships between surveys, versions, questions, and responses are implicit in the column names rather than first-class entities.
- **Skip logic is invisible**: complex branching logic that governs which questions a participant sees is not represented anywhere in the data.
- **Hard to version**: when surveys gain new questions (e.g. `module1_v1` → `module1_v2`), there is no formal mechanism to track what changed.

---

## Proposed Data Model

The goal is a **relational star schema** in BigQuery where:

1. Responses are stored in a long/narrow `responses` fact table keyed on participant × question × response instance.
2. All survey structure and question metadata lives in reusable dimension tables, populated from the Connect data dictionary.
3. Skip logic is represented as first-class rows in a `skip_logic` table so it can be queried and documented.
4. A small library of parameterized SQL views covers the most common analysis patterns by question type.

### Proposed Tables

```
participants          — one row per enrolled participant
surveys               — one row per survey instrument (module1, bioSurvey, …)
survey_versions       — one row per versioned survey release
questions             — one row per question concept, with human-readable label
question_types        — lookup: single_select, multi_select, numeric, date, text, …
response_options      — valid coded responses for categorical questions
survey_questions      — bridge: which questions appear in which survey version, in what order
skip_logic            — conditions under which a question is shown or hidden
responses             — fact table: participant × survey_version × question × response value
biospecimen_events    — biospecimen collection and processing events
```

### Entity Relationship (Draft)

```
participants ──< responses >── survey_questions >── questions
                    │                │
              survey_versions    question_types
                    │
                 surveys
                    │
              survey_questions >── skip_logic
```

### Key Design Decisions

| Decision | Rationale |
|---|---|
| Long/narrow `responses` table | Enables generic SQL across question types; avoids thousands of sparse columns |
| Concept IDs preserved as `concept_id` | Maintains traceability back to the raw Firestore data |
| `question_types` dimension | Common analytic patterns (e.g. "sum up multi-select flags") can be templated once |
| `survey_versions` dimension | Accommodates v1/v2 variation and future survey updates without schema changes |
| Skip logic as data, not code | Makes branching rules auditable and queryable |
| Metadata from data dictionary | Dimension tables (`surveys`, `questions`, `response_options`) are generated from the Connect data dictionary, keeping labels in sync |

---

## Repository Structure

```
connect_data_model/
├── README.md
└── schemas/
    ├── Connect/          # BigQuery dataset: raw Firestore export
    ├── FlatConnect/      # BigQuery dataset: flattened by flattener pipeline
    ├── CleanConnect/     # BigQuery dataset: cleaned by PR2 pipeline
    │   └── *.json        # Each file = table schema in the dataset (e.g., module1.json → table `CleanConnect.module1`)
    └── relational/       # (future) BigQuery dataset: proposed normalized model
```

As the model develops, this repository is expected to grow to include:

```
├── sql/                  # Reusable query library organized by question type
└── docs/                 # ERDs, data dictionary mappings, design notes
```

---

## Prior Work and Upstream Context

This repository builds directly on prior work documented in the **PR2 pipeline**:

- The **flattener pipeline** ([flattener](https://github.com/Analyticsphere/flattener) + [flattener-orchestrator](https://github.com/Analyticsphere/flattener-orchestrator)) converts the nested Firestore-exported BigQuery tables into `FlatConnect` — wide tables where nested paths become underscore-delimited column names and array fields become binary indicator columns.
- The **PR2 transformation pipeline** (`FlatConnect → CleanConnect`) is a serverless ETL built on Cloud Run + Airflow + BigQuery. It handles column cleaning, row cleaning, and version merging but produces the wide-table schemas described above. See [pr2-documentation](https://github.com/Analyticsphere/pr2-documentation) and [pr2-transformation](https://github.com/Analyticsphere/pr2-transformation).
- A [response-centric relational data model was sketched in the PR2 documentation](https://github.com/Analyticsphere/pr2-documentation#could-we-do-better-a-response-centric-relational-data-model-yes) as a proposed middle layer between the operational (raw) data and end-user-curated datasets. That conceptual sketch — explicitly described as not fully cooked — is the direct ancestor of the model being developed here.

The goal of this repo is to take that sketch to a production-ready, fully specified relational model.

---

## CIDTool and the Concept/Variable Dictionary

The **CIDTool** ([NCI-C4CP/CIDTool](https://github.com/NCI-C4CP/CIDTool)) is a JavaScript tool under active development that transforms the Connect data dictionary into a structured relational representation exported as JSON. Its output schemas directly inform the dimension tables of the proposed data model.

The CIDTool ERD (`cid_tool_erd.drawio.png` in this repo) defines two logical groups:

### Core Concept Dictionary — grain: one row per *concept*

| Table | Key Fields |
|---|---|
| `PRIMARY_SOURCE` | `primary_source_concept_id` (PK), `primary_source` |
| `SECONDARY_SOURCE` | `secondary_source_concept_id` (PK), `secondary_source`, `primary_source_concept_id` (FK) |
| `SOURCE_QUESTION` | `current_source_question_concept_id` (PK), `source_question_text`, `v1_source_question`, `grid_source_question_name` |
| `QUESTION` | `question_concept_id` (PK), `current_source_question_concept_id` (FK), `secondary_source_concept_id` (FK), `response_concept_id` (FK, list), `current_question_text`, `question_type` |
| `RESPONSE` | `response_concept_id` (PK), `current_format_value` |

### Variable Dictionary — grain: one row per *variable*

| Table | Description |
|---|---|
| `VARIABLE_METADATA` | Compound PK across `primary_source_concept_id`, `secondary_source_concept_id`, `current_source_question_concept_id`, `response_concept_id`, and `question_concept_id`. Carries human-readable labels, `variable_type`, `variable_length`, `pii` flag, skip logic hints, deprecation history, derivation notes, and `gcp_document_table` (the source BigQuery table name). |

Note from the ERD: PII can be flagged at either the question level or the response level. If a response is not PII but its parent question is, the variable inherits the question-level PII designation.

The CIDTool JSON output is the intended **authoritative source** for populating the concept and metadata dimension tables in this data model. The CSV source of truth for the data dictionary is maintained at [episphere/conceptGithubActions](https://github.com/episphere/conceptGithubActions) and is available as a [raw CSV](https://raw.githubusercontent.com/episphere/conceptGithubActions/refs/heads/master/csv/masterFile.csv).

---

## Next Steps

- [ ] Map Connect concept IDs to human-readable labels from the data dictionary
- [ ] Enumerate question types present across all surveys
- [ ] Define the `responses` fact table schema
- [ ] Model skip logic rules and identify their representation in the raw data
- [ ] Draft dimension table schemas (`surveys`, `survey_versions`, `questions`, `response_options`, `skip_logic`)
- [ ] Prototype the SQL query library for at least two question types
- [ ] Validate proposed model against a sample of real participant response data

---

## Related Resources

### Study and Data Dictionary
- [Connect for Cancer Prevention Study](https://dceg.cancer.gov/research/who-we-study/cohorts/connect)
- [ConnectMasterAndSurveyCombinedDataDictionary](https://github.com/Analyticsphere/ConnectMasterAndSurveyCombinedDataDictionary) — Excel format of the combined master and survey data dictionary
- [episphere/conceptGithubActions](https://github.com/episphere/conceptGithubActions) — canonical CSV/JSON source of truth for the data dictionary; [masterFile.csv](https://raw.githubusercontent.com/episphere/conceptGithubActions/refs/heads/master/csv/masterFile.csv) is the live source

### Tooling
- [CIDTool](https://github.com/NCI-C4CP/CIDTool) — transforms the data dictionary into a relational JSON representation; [live tool](https://nci-c4cp.github.io/CIDTool/) | [wiki](https://github.com/Analyticsphere/CIDTool/wiki)

### Upstream Pipeline
- [flattener](https://github.com/Analyticsphere/flattener) — Cloud Run service that exports Firestore→BigQuery tables to Parquet, flattens nested structures via DuckDB, and loads `FlatConnect` back into BigQuery
- [flattener-orchestrator](https://github.com/Analyticsphere/flattener-orchestrator) — Airflow DAG that schedules and orchestrates the daily flattening pipeline
- [pr2-documentation](https://github.com/Analyticsphere/pr2-documentation) — PR2 pipeline documentation and issue tracking; includes the [response-centric data model sketch](https://github.com/Analyticsphere/pr2-documentation#could-we-do-better-a-response-centric-relational-data-model-yes) this project develops further
- [pr2-transformation](https://github.com/Analyticsphere/pr2-transformation) — Cloud Run service that cleans `FlatConnect` columns and rows and merges survey versions into `CleanConnect`
- [pr2-orchestration](https://github.com/Analyticsphere/pr2-orchestration) — Airflow DAGs that schedule and coordinate the PR2 ETL
