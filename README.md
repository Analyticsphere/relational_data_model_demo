# Connect Data Model

A proposed **relational data model** for the **Connect for Cancer Prevention Cohort Study** (BigQuery) — the foundation for **PR2**, a researcher-facing data warehouse through which Connect will share data with the research community.

It is designed to be **easy to reason about** (a clean star schema over opaque concept IDs), **governed** (per-sensitivity access enforced by BigQuery IAM, in three release tiers), and **lineage-transparent** (every value traceable to source, every derived variable reproducible) — so the community can build shareable tools on a coherent, stable contract.

## Background

Connect is a large-scale prospective cohort study. Participants complete a series of surveys — covering health history, biospecimens, COVID-19, menstrual health, and more — and their responses are stored in Google Firestore.

The full data pipeline from Firestore to analysis-ready tables has three stages:

1. **Firestore → FlatConnect** ([flattener](https://github.com/Analyticsphere/flattener) + [flattener-orchestrator](https://github.com/Analyticsphere/flattener-orchestrator)): exports nested BigQuery tables to Parquet in GCS, uses DuckDB to recursively flatten all leaf fields into wide tables (e.g. `parent_child_grandchild`), expands array fields into binary indicator columns, and loads the result back into BigQuery as `FlatConnect`. Runs daily via an Airflow DAG.
2. **FlatConnect → CleanConnect** ([pr2-transformation](https://github.com/Analyticsphere/pr2-transformation) + [pr2-orchestration](https://github.com/Analyticsphere/pr2-orchestration)): a serverless Cloud Run ETL that standardizes column names, converts binary 0/1 values to concept IDs, and merges multi-version survey tables.
3. **CleanConnect → relational model (this project)**: a normalized relational layer driven by the Connect data dictionary and the Quest survey markup, designed to make the data easy to query, govern, and extend — the basis for the PR2 researcher-facing warehouse.

### Design Decision: Source Layer for Relational Transformation

The relational model can be built from raw `Connect` or from `CleanConnect`. **Current recommendation: build the structural transform from `CleanConnect`**, with the **data dictionary as the schema driver** and **concept IDs as the join key back to raw `Connect`**.

The transform's job is *reshaping* (wide → long), not *cleaning*. CleanConnect has already done the three things that make the reshape tractable and that we would otherwise re-implement from raw: (1) **merged survey versions** (`module1_v1` + `v2` → `module1`), (2) **converted binary 0/1 to concept IDs** on multi-selects, and (3) **standardized column names**. Building on it avoids duplicating that logic in two places.

One guardrail: audit PR2's row-cleaning step to confirm it does not drop values researchers need; where it does, cherry-pick those fields from `Connect`. Every row stays traceable to its concept IDs regardless.

The `schemas/` folder in this repository captures the BigQuery schemas at all three existing stages:

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
- **Rapid schema drift from flattening**: as new answers and fields are added in the upstream application, the flattening step continuously widens tables with new columns. This creates a fast-moving, "dancing schema" that is hard to stabilize for downstream analytics.

- **Loop expansion creates more columns**: looped questions are emitted with `_<loop_number>` suffixes, which further expands table width as loop instances accumulate over time.
- **Version forms coexist as parallel columns**: when a question is revised, both forms persist side-by-side (e.g. `d_899251483_d_812107266` and `d_899251483_d_812107266_v2`), and analysts must hand-reconcile them.
- **Missingness is ambiguous**: a blank cell can mean *not selected*, *not asked* (skip logic), or *survey not taken* — and the wide tables do not distinguish them.

Beyond fixing these, the model must also serve PR2's broader goals: **governed access** by sensitivity (PHI/PII) and **transparent lineage** for curated/derived variables, so researchers can reproduce and critique what they receive.

The **Proposed Data Model** below addresses each of these directly — long/narrow responses, a concept-ID spine, explicit structure/skip-logic/loops/versions, governance, and lineage.

---

## Proposed Data Model

We propose a **two-phase path**: a modest **Phase 1** that lands a fast, low-risk win, then a comprehensive **Phase 2** that realizes the full value. Both share the same long-format thesis — Phase 1 proves it cheaply, Phase 2 builds it out — so Phase 1 is a down payment on Phase 2, not throwaway work.

### Phase 1 — Dictionary-Direct (start here)

The minimal transformation: **adopt the [CIDTool](#cidtool-and-the-conceptvariable-dictionary) data dictionary exactly as it is emitted** (no redesign, no relabeling) and add **one** long-format `responses` table that joins to it. The familiar dictionary you already maintain, plus answers as rows.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/connect_model_a_overview_dark.svg">
  <img alt="Model A: the CIDTool dictionary tables (primary_source, secondary_source, source_question, question, response, variable_metadata) with one added long-format responses table joining to question, source_question, and response." src="docs/connect_model_a_overview.svg">
</picture>

> The dictionary tables are arranged to mirror the CIDTool ERD; `responses` is the only new table. [Full diagram with columns](docs/connect_model_a.svg).

- **Dimensions = CIDTool ERD, verbatim:** `primary_source`, `secondary_source`, `source_question`, `question`, `response`, `question_response` (the question→response list), `variable_metadata`. Loaded from CIDTool's output — we model nothing new.
- **Fact = `responses`** (the one new table): one row per answered cell, keyed on `(connect_id, current_source_question_concept_id, question_concept_id, loop_instance)`, with `response_concept_id` / `value` and `source_column`. It carries the source-question path so reused concepts disambiguate, and joins to the dictionary for every label, type, and flag.

**Why start here:** it adopts existing CIDTool work with no new ontology to defend, kills the dancing-schema pain with a single table, and is a small, low-risk build that demonstrates the long-format value immediately. It is **forward-compatible** with Phase 2: the same `responses` fact is reached by progressively cleaning the dimensions.

**What Phase 1 leaves for Phase 2:** governance/release tiers, sessions and the missingness signal, a placement bridge for clean reused-concept integrity, version/option-set validity, curated marts with lineage, the question-type view library, and researcher-facing naming. (Multi-select/grids also stay as the dictionary's binary sub-question rows rather than one row per selected option.)

### Phase 2 — Functional model (the full vision)

A **relational star schema on BigQuery**, organized in three layers and grounded in two authoritative sources — the **Connect data dictionary** (concept IDs, labels, types) and the **Quest survey markup** (structure, skip logic, loops, grids).

#### Architecture: three layers, one direction

```
Core                  →   Analytic                 →   Marts
normalized source of      pre-joined fact + dims +      curated, pre-derived
truth; long/narrow        aggregates + question-type    variables / risk factors,
responses (below)         view library                  lineage intact to source
```

- **Core** — the normalized, immutable source of truth (tables below).
- **Analytic** — denormalized, pre-joined `fact_response` + dimensions + aggregates + a parameterized **view library by question type**; what researchers and tools actually query.
- **Marts** — curated pre-derived variables (risk factors, scored scales), each with **lineage intact to source** so results are reproducible and critiquable.

Each layer reads only from the one above; Core is never mutated downstream. **dbt** is proposed to build and document the Analytic + Marts layers (automatic column-level lineage, tests, versioned SQL). The Core → downstream boundary is also the governance trust boundary (see *Governance*).

#### Core tables

```
participants        — one enrolled participant
surveys             — one survey instrument/section (the dictionary's Secondary Source)
survey_versions     — one versioned instrument release (v1/v2)
response_sessions   — one participant × survey administration (status + timing + wave),
                      derived from participant metadata; carries the missingness signal
question_types      — lookup: single_select, multi_select, grid, xor, text, … (+ flags)
questions           — reusable concept bank: one question concept, with label & type
response_options    — offered options per question-version (validity + harmonization hook)
survey_questions    — placement bridge: a question concept placed in a version, under a parent,
                      in order; responses key on this (resolves reused concepts + grids/select-all)
skip_logic          — structured branching rules (trigger → action), from Quest
responses           — long/narrow fact: one row per answer atom
                      (session × placement × loop_instance × response value)
biospecimen_events  — biospecimen collection/processing events (event-shaped, kept separate)
```

#### Entity Relationship

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/connect_data_model_overview_dark.svg">
  <img alt="Connect data model overview: responses fact keyed on response_sessions and the survey_questions placement bridge, with surveys, survey_versions, questions, question_types, response_options, skip_logic, and biospecimen_events." src="docs/connect_data_model_overview.svg">
</picture>

<details><summary>ERD as text</summary>

```
participants ──< response_sessions ──< responses >── survey_questions(placement) >── questions ──< response_options
                       │                  │ loop_instance      │  ├ parent (groups grids & select-all;        │
                    surveys               │                    │  │  disambiguates reused concepts)   question_types
                       └─< survey_versions ─────────────────────┴── skip_logic
participants ──< biospecimen_events
```

</details>

> Generated with [dbsketch](https://github.com/jacobmpeters/dbsketch) from the model definition. The overview above is the names-only shape; the **[full ERD with columns and types](docs/connect_data_model.svg)** and a **[clustered view](docs/connect_data_model_clustered.svg)** (dimensions vs. fact, for slides) are also in `docs/`.

#### How it handles Connect's hard cases

Each row is grounded in the real data (see `schemas/`, the data dictionary, and Quest markup).

| Challenge in the wide tables | How the model resolves it |
|---|---|
| **Dancing schema** — new answers keep widening tables | answers are **rows** in `responses`, never new columns |
| **Opaque identifiers** | concept IDs are the keys; human labels live in dimensions from the dictionary |
| **Multi-select / select-all** explode into binary indicator columns | one `responses` row **per selected option**; the offered set lives in `response_options` |
| **Grids** nest as `d_X_d_X_d_Y` | grid rows are sub-questions under a `parent`; no special tables (same shape as select-all) |
| **Loops** emit `_N` suffix columns | `loop_instance` turns loop instances into rows |
| **Reused concepts** (e.g. "age at diagnosis" appears under 153 parents) | responses key on the **placement** (`survey_questions`), which carries the parent path |
| **Version drift** (`v1→v2`, concept `_V2`, label `_vNrM`, follow-up waves) | four explicit axes: `survey_versions`, `survey_questions.concept_version`, lineage, `response_sessions.wave` |
| **Option-set changes** across revisions | `response_options` is version-scoped, with `status` and a deprecated→new mapping |
| **Skip logic invisible** | first-class `skip_logic` rows derived from Quest `displayif` / `->` |
| **Missingness ambiguity** | `response_sessions.status` × skip reachability separates not-administered / not-answered / skipped-by-design |

#### Worked example — select-all, before and after

`899251483` "Have you lost any permanent teeth?" — a select-all that was revised mid-study:

- **Source / wide:** a `REPEATED` array the flattener explodes into binary indicator columns `d_899251483_d_<option>`, plus a parallel `…_v2` set after the revision. A researcher must hand-reconcile ~7 V1/V2 columns and **cannot distinguish "not selected" from "not offered."**
- **This model:** one `responses` row per *selected* option, under one logical question (`899251483`), with `concept_version` separating V1/V2 and `response_options` recording which options each version offered. "What did people select?" becomes a single `GROUP BY`; version drift becomes one attribute.

#### Governance & access (built in, not bolted on)

PR2 grants access **per-data, per-sensitivity, per-business-need**, enforced with **BigQuery IAM**.

- **Sensitivity is data:** every concept carries a `sensitivity_tier` (`non_sensitive` / `PII` / `PHI`, plus finer categories), denormalized onto `responses`. Because the model is long/narrow, sensitivity is **row-level** — enforced with **row-access policies**, not column policy tags.
- **Three release tiers**, each a distinct governed data product:

  | Tier | What a researcher gets |
  |---|---|
  | **Sensitive** | full PHI/PII — real dates, identifiers; highest clearance only |
  | **Core** | de-identified: dates **date-shifted**, some fields masked |
  | **Public** | **aggregate-only** with cell-size suppression |

  > Naming note: the **Core release tier** (de-identified) is distinct from the **Core layer** (the normalized source of truth above). Final tier names are still to be settled.

- Enforced via row-access policies, column policy tags (identifiers on dimensions), and **authorized views** — researchers reach only the Analytic/Marts layers, never the Core layer.

#### Derived variables & lineage

Connect will curate pre-derived variables (risk factors, scored scales) as **marts**. Each exposes its **inputs (source concept IDs), method, and version**, with lineage intact to source — so researchers can reproduce, audit, and improve it, never consume a black box. dbt's model/column lineage is the proposed mechanism.

#### Naming: clarity over dictionary jargon

The model uses researcher-facing names, keeps **concept IDs identical** (they are the join keys), and maintains a crosswalk to the dictionary / CIDTool:

| Dictionary / CIDTool | This model |
|---|---|
| `PRIMARY_SOURCE` | `surveys.domain` (attribute — it is a domain, not an instrument) |
| `SECONDARY_SOURCE` | `surveys` (the instrument/section) |
| `SOURCE_QUESTION` / GridID | `survey_questions.parent_question_concept_id` (grid/select-all group parent) |
| `QUESTION` | `questions` |
| `RESPONSE` | `response_options` |

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
├── model/                # Schema definition (DDL / dbt models) for the relational layers
├── sql/                  # Reusable query library organized by question type
└── docs/                 # ERDs, data-dictionary crosswalk, design notes
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

## Quest: Survey Authoring and the Source of Survey Structure

Connect surveys are authored and delivered with **Quest** ([episphere/quest](https://github.com/episphere/quest), live at [episphere.github.io/quest](https://episphere.github.io/quest)) — a custom, lightweight **markup language for questionnaires**. The Quest markup is the authoritative definition of survey *structure and behavior*, much of which is invisible in the wide BigQuery tables: question order, question types, response options, branching/skip logic, loops, and grids are all explicit in the markup.

The machine-readable Quest markup for the Connect instruments lives as `.txt` files in [episphere/quest/questionnaires](https://github.com/episphere/quest/tree/master/questionnaires) (e.g. `module1.txt`). Human-readable Word/PDF renderings of each survey are kept in [episphere/connect/questionnaires](https://github.com/episphere/connect/tree/master/questionnaires).

A few illustrative constructs (from `module1.txt`, `DansLoopTest.txt`, `gridTest.txt`):

| Construct | Markup | Maps to |
|---|---|---|
| Single-select | `(1) Married` `(99) Prefer not to answer` | `question_type = single_select`; codes → `response_options` |
| Multi-select | `[1] Asian` `[7] White` | `question_type = multi_select`; one chosen option → one `responses` row |
| Numeric / text | `Age: \|__\|__\|min=40 max=70\|` | `question_type = numeric`; validation bounds |
| Inline branch | `(1) Yes -> MARITAL` | `skip_logic` (jump to target on answer) |
| Conditional display | `[Q2,displayif=greaterThanOrEqual(numnames,3)]` | `skip_logic` (predicate over prior answers) |
| Loop | `<loop max=10> … </loop>` with `#loop` index | `responses.loop_instance`; **origin of the `_N` column suffixes** |
| Grid | `\|grid\|id="…"\|prompt\|[ [Q1] …; [Q2] … ]\|(0:None)(1:…)\|` | grid → sub-questions sharing a response set; **origin of `d_X_d_X_d_Y` nesting** |

Quest is thus a **second authoritative source alongside the data dictionary**: the data dictionary / CIDTool supplies concept IDs, labels, and types; Quest supplies structure, ordering, skip logic, loops, and grids. The two are joined on the question identity (markup question IDs ↔ concept IDs via the dictionary's source-question entries). Together they populate the structural dimensions (`survey_questions`, `skip_logic`) that cannot be reconstructed from the response tables alone.

Related Quest resources: [episphere/questionnaires](https://github.com/episphere/questionnaires) (building/versioning questionnaires) and the Quest renderer/engine in [episphere/quest](https://github.com/episphere/quest).

---

## Next Steps

Both phases are grounded in the dictionary, Quest markup, and the BigQuery schemas, and stress-tested against the hardest `module1` structures.

**Phase 1 — Dictionary-Direct (fast win):**
- [ ] Load the CIDTool dictionary tables into BigQuery as-is
- [ ] Build the `responses` unpivot from CleanConnect; join-validate against the dictionary
- [ ] Validate against real participant data (a select-all, a grid, a loop, a versioned/revised question)

**Phase 2 — Functional model (the vision):**
- [ ] Write the DDL / dbt models for the Core tables; generate cleaned dimensions from the dictionary + Quest
- [ ] Build the Analytic layer (`fact_response`, dimensions, aggregates) and a question-type view library
- [ ] Implement governance: `sensitivity_tier` classification, row-access policies, and the three release tiers
- [ ] Prototype one curated mart with full lineage to validate the derived-variable pattern

Open questions still being resolved (see design notes):

- [ ] **Source-layer audit** — confirm CleanConnect's row-cleaning does not drop needed values
- [ ] **Administration waves** — carry `wave` on `response_sessions` vs. treat each wave as a `survey_version`; how baseline vs. follow-up waves enumerate
- [ ] **Select-all encoding** — sparse (one row per selected option) vs. dense (a row per offered option)
- [ ] **Biospecimen scope** — model as response facts, event facts, or a hybrid

---

## Related Resources

### Study and Data Dictionary
- [Connect for Cancer Prevention Study](https://dceg.cancer.gov/research/who-we-study/cohorts/connect)
- [ConnectMasterAndSurveyCombinedDataDictionary](https://github.com/Analyticsphere/ConnectMasterAndSurveyCombinedDataDictionary) — Excel format of the combined master and survey data dictionary
- [episphere/conceptGithubActions](https://github.com/episphere/conceptGithubActions) — canonical CSV/JSON source of truth for the data dictionary; [masterFile.csv](https://raw.githubusercontent.com/episphere/conceptGithubActions/refs/heads/master/csv/masterFile.csv) is the live source

### Survey Authoring (Quest)
- [episphere/quest](https://github.com/episphere/quest) — Quest, the questionnaire markup language and rendering engine used to author/deliver Connect surveys ([live](https://episphere.github.io/quest)); markup `.txt` files in [/questionnaires](https://github.com/episphere/quest/tree/master/questionnaires)
- [episphere/connect/questionnaires](https://github.com/episphere/connect/tree/master/questionnaires) — human-readable Word/PDF renderings of each Connect survey (English + Spanish)
- [episphere/questionnaires](https://github.com/episphere/questionnaires) — building and versioning questionnaires

### Tooling
- [CIDTool](https://github.com/NCI-C4CP/CIDTool) — transforms the data dictionary into a relational JSON representation; [live tool](https://nci-c4cp.github.io/CIDTool/) | [wiki](https://github.com/Analyticsphere/CIDTool/wiki)

### Upstream Pipeline
- [flattener](https://github.com/Analyticsphere/flattener) — Cloud Run service that exports Firestore→BigQuery tables to Parquet, flattens nested structures via DuckDB, and loads `FlatConnect` back into BigQuery
- [flattener-orchestrator](https://github.com/Analyticsphere/flattener-orchestrator) — Airflow DAG that schedules and orchestrates the daily flattening pipeline
- [pr2-documentation](https://github.com/Analyticsphere/pr2-documentation) — PR2 pipeline documentation and issue tracking; includes the [response-centric data model sketch](https://github.com/Analyticsphere/pr2-documentation#could-we-do-better-a-response-centric-relational-data-model-yes) this project develops further
- [pr2-transformation](https://github.com/Analyticsphere/pr2-transformation) — Cloud Run service that cleans `FlatConnect` columns and rows and merges survey versions into `CleanConnect`
- [pr2-orchestration](https://github.com/Analyticsphere/pr2-orchestration) — Airflow DAGs that schedule and coordinate the PR2 ETL
