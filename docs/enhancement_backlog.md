# Incremental enhancements to the Connect Data Model

## Decision (accepted)

**The Connect Data Model is the Dictionary-Direct model** — the CIDTool data dictionary adopted **as the
source of truth**, plus one long-format `responses` fact that joins to it. This is the officially accepted
path forward.

A larger, redesigned "researcher warehouse" (cleaned/relabeled dimensions, a placement bridge, layered
Core→Analytic→Marts, etc.) was considered and **is not being pursued as a wholesale transformation** —
it would move the source of truth off the dictionary, which we are explicitly not doing.

**However**, several capabilities from that exploration are genuinely valuable, and the model is **open to
adopting them incrementally as additions on top of the Dictionary-Direct model** — as long as each one is
a bounded extension that keeps the dictionary as the source of truth. This document is that backlog: each
entry is a *potential* extension, with its value, a sketch of how it attaches to the current model, and an
honest cost. Nothing here is committed; they are picked up one at a time when a concrete need pulls them in.

**Ground rule for every enhancement:** it adds a column, a lookup table, or a derived view **alongside**
the dictionary + `responses` — it never replaces the dictionary, and it never rewrites `responses` (the
fact stays immutable; enhancements are overlays, attributes, or downstream layers).

---

## The backlog (ordered roughly by value-to-cost)

### 0. Clustering for the `responses` table  *(decided; must apply before production load)*

**Decision:** cluster by `(secondary_source_concept_id, question_concept_id, connect_id)`.
**Partitioning:** deferred — no suitable partition column exists yet; clustering alone is sufficient
at current and near-term projected scale (see rationale below).

**Key order rationale:**
- `secondary_source_concept_id` first — the dominant filter in analytical queries is survey scope;
  10 surveys → ~10% initial pruning per cluster block.
- `question_concept_id` second — within a survey, analyses are almost always question-specific
  ("distribution of answers to Q"); ~3,240 unique concepts, highly selective.
- `connect_id` third — participant lookups and cohort-level self-joins benefit from the remaining sort.
- **Estimated benefit:** 70–85% scan reduction for typical question-level and survey-level queries.

**Why not partition now:**
- No suitable partition column exists. `response_value_as_date` covers only 0.09% of rows (sparse
  Special Functions questions). Ingestion-time `_PARTITIONTIME` would work but forces unnatural
  `WHERE _PARTITIONTIME BETWEEN...` filters on every analytical query.
- Estimated compressed table size at 200k participants: ~2–3 GB. BigQuery partitioning yields its
  biggest gains above ~1 TB; below that, clustering alone provides comparable scan reduction with
  less operational overhead.
- Clustering cannot be added retroactively without recreating the table — it must be applied before
  the first production load.

**Future — partitioning:** once `response_sessions` timestamps are available from the participants
table (backlog §5), add `survey_completed_at DATE` as a partition column and retain the clustering.
`PARTITION BY survey_completed_at CLUSTER BY (secondary_source_concept_id, question_concept_id, connect_id)`
is BigQuery's recommended pattern for large observation/event tables. This requires a one-time
table recreate at that point.

**Implementation:** add `OPTIONS(clustering_fields=["secondary_source_concept_id","question_concept_id","connect_id"])`
to the `CREATE TABLE` in `sql/unpivot_stage/00_responses_ddl.sql` (and `scripts/setup_relational.py`
+ `schemas/relational/responses.json`) before the production load.

### 1. Normalized question-type view  *(smallest, highest bang-for-buck)*
- **What:** one derived view `question_type_norm` mapping the dictionary's messy `question_type` (partial
  coverage, casing/typos, compound strings) to a clean `base_type` + flags (`is_multi`, `has_loop`, …),
  backfilled from Quest where blank.
- **Value:** enables **templated, per-type SQL** ("every single-select", "every loop") — the "common
  abstraction" that makes analyses reusable across surveys.
- **Attaches as:** a view over `question`; dictionary untouched underneath.
- **Cost:** low. Already scoped in the README as the recommended first add-on.

### 2. Typed value columns on `responses`  *(in place)*
- **What:** `response_value_as_string` (verbatim, always), `response_value_as_number`,
  `response_value_as_concept_id`, and `response_value_as_date` — OMOP `observation`-style —
  populated by `sql/unpivot_stage/type_response_values.sql` keyed on value patterns.
- **Value:** direct `AVG()`/`SUM()` on numerics; the coded answer joins labels/option-sets/equivalences;
  date answers are properly typed for date arithmetic.
- **Attaches as:** columns on `responses` (already in the DDL + schema JSON); populated by the type step.
- **Cost:** complete. See `docs/value_typing.md` for routing logic and a full account of limitations.

### 3. Improved version handling (concept `_V2` revisions + option-set validity)
- **What:** treat the `_V2` concept revision as an **attribute** so `GROUP BY question_concept_id` unifies
  V1/V2 answers automatically, with the revision recoverable; make the offered option set **version-scoped**
  so "offered but not selected" is distinguishable from "not offered in this version."
- **Value:** removes the hand-`COALESCE` of parallel V1/V2 columns; makes pooled V1+V2 analysis correct.
- **Attaches as:** a `question_version` attribute (already on `responses`) + a version-scoped
  `response_options` lookup / status flags; optionally a lightweight deprecated→new response mapping.
- **Cost:** medium. Needs the dictionary's V1/V2 columns + Quest to reconcile the offered sets.

### 4. `skip_logic` (structured branching from Quest)
- **What:** first-class rules `(trigger, operator, value, action, enable_behavior, trigger_default)` parsed
  from Quest `displayif` / `-> target`, with a `raw_expression` fallback for the complex tail (~8%).
- **Value:** skip logic becomes **queryable data** instead of buried code; ~85% of the QA/QC rule engine
  (7,025 hand-written rules) becomes generatable; it is also half of the missingness signal (#5).
- **Attaches as:** a `skip_logic` lookup keyed on the dictionary's concept IDs; needs a **Quest parser**
  (net-new; prototype on module1).
- **Cost:** medium–high (the parser is real engineering; the complex tail needs the raw fallback).

### 5. `response_sessions` (survey administration + the missingness signal)
- **What:** one row per participant × survey administration (status / start / complete / wave), **derived**
  by pivoting the participant table's per-survey status+timing triad — no new collection.
- **Value:** separates **not-administered vs. not-answered vs. skipped-by-design** (with `skip_logic`), and
  captures recurring-survey **waves** (3mo/6mo). Missingness is the epi-critical operation the wide tables
  can't answer.
- **Attaches as:** a `response_sessions` dimension keyed to `connect_id` + survey; `responses` can carry a
  `session_id` (optional) or join on `(connect_id, survey, wave)`.
- **Cost:** medium. Directly derivable; pairs with #4 for full missingness classification.

### 6. Concept equivalence plane (`concept_relationship`)  *(demo already built)*
- **What:** OMOP-style `concept_id_1, concept_id_2, relationship` links (e.g. `synonym`) so reused fields —
  the ~27 address variants across home/seasonal/work — are harmonized **once, as data**.
- **Value:** replaces the 26-branch `case_when` that three geocoding repos each rebuilt; harmonization
  authored once, joinable. **A demo already exists** (`sql/build_concept_relationship.sql`).
- **Attaches as:** a standalone `concept_relationship` table keyed on dictionary concept IDs; production
  links come from CIDTool / a curated `question_equivalence`.
- **Cost:** low–medium (the table is trivial; authoring authoritative equivalences is the real work).

### 7. Governance: `sensitivity_tier` + release tiers
- **What:** a per-concept `sensitivity_tier` (`non_sensitive`/`PII`/`PHI`, finer categories), **denormalized
  onto `responses`** so access is **row-level** (row-access policies), plus release-tier transforms
  (date-shift / mask / aggregate+suppress) and IAM groups.
- **Value:** **external-release readiness** — per-sensitivity (PHI/PII) gating is effectively required before
  PR2 opens data to the research community. The Dictionary-Direct model alone is **not** externally
  release-ready without this.
- **Attaches as:** a `sensitivity_tier` column (seeded from the dictionary `PII` flag with question→response
  inheritance) + downstream tier products; enforcement stays in **BigQuery IAM**, not the tables.
- **Cost:** high — mostly **org/policy** (classification, date-shift design, cell-suppression thresholds,
  IRB sign-off), not schema. Start early; it's the long pole for external sharing.

### 8. Curated derived-variable marts (with dbt + lineage)
- **What:** curated risk-factor variables (pack-years, BMI, MET-hours, screening-up-to-date, ADI, …) built
  **downstream** of the model, each with inputs (source concept IDs), method, and version — lineage intact.
- **Value:** researchers reuse trustworthy derivations instead of each re-deriving; reproducible and
  critiquable, never a black box.
- **Attaches as:** dbt models reading the model as a `source` (one mart per construct); the model itself is
  never mutated.
- **Cost:** high and ongoing — each mart is real epidemiological work + an owner + tests (not automatic).

### 9. Event plane (DevOps long-format follow-up events)
- **What:** biospecimen/collection/kit/incentive/refusal events as **per-type long tables** keyed on
  `(connect_id, round)`, with **concept IDs re-attached** so events join the dictionary like surveys.
- **Value:** the same long-format win for operational/follow-up data; a shared `round` ≈ survey session.
- **Attaches as:** separate event tables + a unified event view, coordinated with DevOps.
- **Cost:** medium; depends on DevOps re-attaching concept IDs (see `docs/devops_event_tables_memo.md`).
  Event-plane sketch artifacts: `sql/data_model_events.sql`, `docs/connect_event_plane*.svg`.

---

## What we are *not* doing
- Relabeling / redesigning the dictionary dimensions into new researcher-facing tables — the dictionary
  **is** the model's dimensions.
- A mandatory `survey_questions` placement bridge that `responses` must key on. (Model A instead carries the
  placement coordinates — `secondary_source_concept_id` + `current_source_question_concept_id` — inline on
  the fact.) A bridge could be revisited only if reused-concept integrity demands it, but it is **not** the
  planned path.
- A layered Core→Analytic→Marts rearchitecture as a prerequisite. Marts (#8) can sit downstream without it.
