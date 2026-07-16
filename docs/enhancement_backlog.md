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

## Shared dependencies (the critical path)

A few building blocks are prerequisites for **several** enhancements — sequencing them first unblocks the
most downstream value:

- **Quest variable-name → concept-ID map** — Quest expresses structure with short names (`SEX`, `NUMSIB`);
  the model keys on 9-digit concept IDs. Required to operationalize `skip_logic` (§4), and useful for
  backfilling question types from Quest (§1) and reconciling version option-sets (§3). *This is the named
  blocker for §4* — **investigated in [`docs/quest_concept_linkage_survey.md`](quest_concept_linkage_survey.md)**:
  no stored short-name crosswalk exists, but the **compiled/deployed Quest markup is already concept-ID-based**,
  so the fix is to parse that form (not the short-name authoring `.txt`) — reframing the blocker as *sourcing
  the compiled markup*, not authoring a crosswalk.
- **`response_sessions` / wave index (§5)** — needed to disambiguate repeat administrations (§3 Pattern 1),
  to reconstruct loop iterations and classify missingness (§4), and as the eventual source of a partition
  column (§0). Foundational, and directly derivable from the participant status/timing triad.
- **`concept_relationship` successor links (§6)** — needed to pool data across deprecated→replaced concepts
  (§3 Pattern 4). The table is trivial; authoring authoritative links is the real work.

A natural order, then: **sessions (§5) and the Quest-name map early** (they unblock §3/§4), then the
**equivalence links (§6)** as curation capacity allows.

---

## The backlog (ordered roughly by value-to-cost)

### 0. Clustering for the `responses` table  *(decided; must apply before production load)*

**Background — partitioning vs. clustering:**
([BQ partitioned tables docs](https://cloud.google.com/bigquery/docs/partitioned-tables) |
[BQ clustered tables docs](https://cloud.google.com/bigquery/docs/clustered-tables))

*Partitioning* divides a table into physically separate segments based on the values of one column
(typically a date). When a query filters on that column, BigQuery reads only the matching segments
and skips the rest entirely — it never touches the other partitions. This is the most powerful form
of scan reduction, but it requires a high-quality partition column: ideally a date that is both
present on most rows and commonly used as a query filter.

*Clustering* sorts the data within the table (or within each partition) by up to four columns.
BigQuery records the min/max value range for each cluster block and uses those ranges to skip blocks
that cannot match a query's WHERE clause — similar in spirit to a database index. Unlike
partitioning, clustering works on any column type and doesn't require a restructure of the physical
storage into separate segments; it's an ordering hint that BigQuery maintains automatically as data
is loaded. The trade-off is that skipping is probabilistic and proportional — clustering gives
70–85% scan reduction for selective queries, whereas a partition filter can eliminate 90%+ in one
step.

For the `responses` table, clustering is the right current tool because no reliable, commonly-filtered
date column exists yet. The cluster key `(secondary_source_concept_id, question_concept_id, connect_id)`
mirrors the most common query shape — "give me the distribution of answers to question Q in survey S"
— so BigQuery can skip the vast majority of cluster blocks before reading a single row.

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

**Implementation:** clustering is already applied in `sql/unpivot_stage/00_responses_ddl.sql` and
`scripts/setup_relational.py` — the production load uses these same scripts.

**Benchmark:** `sql/benchmark/clustering_benchmark.sql` contains five representative query shapes
run against a paired clustered vs. non-clustered copy of the responses table, with an
`INFORMATION_SCHEMA.JOBS` analysis query to compute per-shape scan reduction ratios. Run this
at the first production load to validate the estimated 70–85% reduction. Not meaningful to run
in stage (82k rows fits in one cluster block regardless of clustering).

### 1. Normalized question-type view  *(smallest, highest bang-for-buck)*
- **What:** one derived view `question_type_norm` mapping the dictionary's messy `question_type` (partial
  coverage, casing/typos, compound strings) to a clean `base_type` + flags (`is_multi`, `has_loop`, …),
  backfilled from Quest where blank.
- **Value:** enables **templated, per-type SQL** ("every single-select", "every loop") — the "common
  abstraction" that makes analyses reusable across surveys.
- **Attaches as:** a view over `question`; dictionary untouched underneath.
- **Cost:** low. Already scoped in the README as the recommended first add-on.
- **Analysis:** see [`docs/question_types_survey.md`](question_types_survey.md) for a full survey of all
  raw `Question Type` values in the dictionary, Quest markup examples for each structural type, and a
  proposed 8-value canonical enum with recommended modifier flags (`is_required`, `has_loop`,
  `has_displayif`, `has_inline_text_box`).

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
- **Proposed `question`-dimension schema** (from the survey doc → "Proposed question dimension additions"):
  `max_version`, `max_revision`, `status`, `deprecated_at`, `successor_cid` (FK → `question` for Pattern-4
  replaced concepts), and `is_repeat_admin`; plus a `v_responses_current` view that routes deprecated
  concepts to their successors via `successor_cid`. Tracked here so the schema change lives in one place.
- **Cost:** medium. Needs the dictionary's V1/V2 columns + Quest to reconcile the offered sets.
- **Analysis:** see [`docs/version_handling_survey.md`](version_handling_survey.md) for a full survey of
  all versioning patterns. Key findings: 81% of survey variables are untouched `v1r0`; the remaining 19%
  fall into four patterns — repeat administration (17 dancing pairs in stage requiring a wave index),
  transparent minor revisions (351 `r`-increment variables), same-CID option-set changes (Pattern 3),
  and new-CID concept replacements (Pattern 4, including the entire COVID-19 module). The biggest lift
  is authoring `successor_cid` links for deprecated→replaced pairs — curation work, not schema work.
- **Design (recommended — SCD Type 4):** keep the current-state dims clean (one row/concept — done) and add a
  `question_version` **history overlay** (one row per concept × version); the fact's `question_version`
  bridges them. Choose the mechanism by whether the source **keeps the concept ID** (Pattern 3 → version
  *attribute* + version-scoped options) or **mints a new ID** (Pattern 4 → `concept_relationship` +
  `successor_concept_id`) — never fabricate per-version IDs. `is_versioned` is a **derived view column, not a
  stored flag**. Added questions (`status = 'New'` — 994 rows, pushed to prod 2022→2026) are a *birth*, not a
  version conflict: denominators must exclude pre-add-date sessions. Full write-up + the SCD 1–4 comparison,
  pooling queries, and dictionary→overlay mapping in
  [`version_handling_survey.md`](version_handling_survey.md) → "Recommended Design: SCD Type 4."

### 4. `skip_logic` (structured branching from Quest)
- **What:** first-class rules `(trigger, operator, value, action, enable_behavior, trigger_default)` parsed
  from Quest `displayif` / `-> target`, with a `raw_expression` fallback for the complex tail (~8%).
- **Value:** skip logic becomes **queryable data** instead of buried code; ~85% of the QA/QC rule engine
  (7,025 hand-written rules) becomes generatable; it is also half of the missingness signal (#5).
- **Attaches as:** a `skip_logic` lookup keyed on the dictionary's concept IDs; needs a **Quest parser**
  (net-new; prototype on module1).
- **Cost:** medium–high (the parser is real engineering; the complex tail needs the raw fallback).
- **Analysis:** see [`docs/skip_logic_survey.md`](skip_logic_survey.md) for a full survey of all skip-logic
  mechanisms in module1 (8 distinct mechanisms; 64% of questions have some form of skip logic), expression
  complexity breakdown (97% parseable as structured rules), key trigger variables, and the critical
  blocker: a Quest variable-name → concept-ID mapping table is required before rules can join the
  `responses` fact.
- **The linkage blocker — investigated:** see [`docs/quest_concept_linkage_survey.md`](quest_concept_linkage_survey.md).
  The Quest short-name (`MARITAL`, `SEX`) is a stored join key **nowhere** (not in `masterFile`'s 37 columns,
  not in the per-concept JSONs); concept IDs are assigned by `Variable Name` + question text in
  `episphere/conceptGithubActions`, and the **deployed markup is concept-ID-based** (`[D_<cid>]`). Heuristics
  from the authoring `.txt` are weak (mnemonic 13%, text-match ~41%). **Resolution: parse the compiled
  concept-ID-form markup** (triggers are already concept IDs → no name resolution needed), not the short-name
  authoring source. This reframes the blocker from "author a crosswalk" to "source the compiled markup."

### 5. `response_sessions` (survey administration + the missingness signal)
- **What:** one row per participant × survey administration (status / start / complete / wave), **derived**
  by pivoting the participant table's per-survey status+timing triad — no new collection.
- **Value:** separates **not-administered vs. not-answered vs. skipped-by-design** (with `skip_logic`), and
  captures recurring-survey **waves** (3mo/6mo). Missingness is the epi-critical operation the wide tables
  can't answer.
- **Attaches as:** a `response_sessions` dimension keyed to `connect_id` + survey; `responses` can carry a
  `session_id` (optional) or join on `(connect_id, survey, wave)`.
- **Cost:** medium. Directly derivable; pairs with #4 for full missingness classification.
- **Feasibility & value:** see [`docs/session_derivation_survey.md`](session_derivation_survey.md). The
  status/timing triad is present and uniform (**15/16 real surveys** have status + start + submit; the status
  value set `0/1/2` is global) and derivable by a wide→long pivot of `participants`. **But this is the one
  enhancement that deviates from the dictionary-driven grain** — so the doc recommends the *minimal* form
  first: unpivot the status/timing concepts (they are themselves dictionary concepts) into `responses` for
  **zero deviation**, and defer a standalone `response_sessions` dimension until `skip_logic` (§4) exists to
  realize the missingness win. The **`wave` axis is weak for surveys** — follow-up rounds live in the event
  plane (§9), not surveys.

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
- **Attaches as:** a `sensitivity_tier` column (from a curated `sensitivity_taxonomy`, **not** the raw `PII`
  flag) + downstream tier products; enforcement stays in **BigQuery IAM**, not the tables.
- **Cost:** high — mostly **org/policy** (classification, date-shift design, cell-suppression thresholds,
  IRB sign-off), not schema. Start early; it's the long pole for external sharing.
- **Feasibility & value:** see [`docs/governance_survey.md`](governance_survey.md). Findings: the `PII` flag
  is **unmaintained** (447 `Yes`, 62% blank; misses **547/844** objective HIPAA direct identifiers), so
  classify **objectively** — ~844 direct-identifier concepts (26%; **654 geo/address**), plus **655 free-text**
  concepts as a cross-cutting risk, plus genetic/geospatial that live in *other* domains. **The long-format
  model is highly amenable to enforcement:** sensitivity is a **row** property, so **~844 sensitive concepts
  collapse to one denormalized `sensitivity_tier` + ~3 row-access policies**, versus **3,867 wide columns** to
  policy-tag. Column-level security is reserved for the free-text value column; physical dataset isolation for
  the top tier only; **policy tags for the wide marts (§8)**. The residual work is a curated
  `sensitivity_taxonomy` + the org/policy pole (date-shift, cell-suppression, IRB).

### 8. Curated derived-variable marts (with dbt + lineage)
- **What:** curated risk-factor variables (pack-years, BMI, MET-hours, screening-up-to-date, ADI, …) built
  **downstream** of the model, each with inputs (source concept IDs), method, and version — lineage intact.
- **Value:** researchers reuse trustworthy derivations instead of each re-deriving; reproducible and
  critiquable, never a black box.
- **Attaches as:** dbt models reading the model as a `source` (one mart per construct); the model itself is
  never mutated.
- **Cost:** high and ongoing — each mart is real epidemiological work + an owner + tests (not automatic).
- **Feasibility & reference implementation:** see [`docs/marts_dbt_feasibility.md`](marts_dbt_feasibility.md).
  `Analyticsphere/PR2-analyses` (`PR2_FinalDerivationsCode.rmd`) is the concrete seed — the finalized v0.1
  derivations for Connect's first design paper: **28 variables** (demographics 11, alcohol 7, smoking 6,
  anthropometry 3), all **row-level participant-grain recodes** (no aggregation) reading `FlatConnect`.
  **Feasibility is high** — the work is `case_when`/`recode` (the dbt sweet spot), and the model *removes*
  the hardest R plumbing (the hand-rolled v1/v2 merge, type coercion, `rowSums` indicator math, code→label
  recodes → `response_options` joins). It's a **re-expression against `responses`, not a lift-and-shift**,
  and the epi definitions need per-variable sign-off. Recommended: build dbt marts **in parallel**, reconcile
  row-for-row against the `.rmd` as the oracle (so the paper isn't blocked); start with `mart_anthropometry`
  (BMI) to prove model→typed-values→mart→tests→`dbt docs` lineage.
- **What:** biospecimen/collection/kit/incentive/refusal events as **per-type long tables** keyed on
  `(connect_id, round)`, with **concept IDs re-attached** so events join the dictionary like surveys.
- **Value:** the same long-format win for operational/follow-up data; a shared `round` ≈ survey session.
- **Attaches as:** separate event tables + a unified event view, coordinated with DevOps.
- **Cost:** medium; depends on DevOps re-attaching concept IDs (see `docs/devops_event_tables_memo.md`).
  Event-plane sketch artifacts: `sql/data_model_events.sql`, `docs/connect_event_plane*.svg`.
- **Note — operational nesting keys in `source_question`:** the `source_question` dimension is
  populated from the full dictionary, which covers all Connect instruments including Study Manager
  and Help Desk. Structural nesting keys for Participants Table operational variables (e.g.,
  `292282660` = `"3 = Payment 3"`, identifying variables nested under the 3rd payment round) are
  valid dictionary entries but look unusual because they use response-option-style labels as keys
  (`"1 = Payment 1"`, `"2 = Payment 2"`, `"3 = Payment 3"`). These are inert in the current model
  (zero `responses` rows reference them) but would become meaningful source questions if the event
  plane is extended to cover Participants Table payment/incentive variables.

---

## What we are *not* doing
- Relabeling / redesigning the dictionary dimensions into new researcher-facing tables — the dictionary
  **is** the model's dimensions.
- A mandatory `survey_questions` placement bridge that `responses` must key on. (Model A instead carries the
  placement coordinates — `secondary_source_concept_id` + `source_question_concept_id` — inline on
  the fact.) A bridge could be revisited only if reused-concept integrity demands it, but it is **not** the
  planned path.
- A layered Core→Analytic→Marts rearchitecture as a prerequisite. Marts (#8) can sit downstream without it.
