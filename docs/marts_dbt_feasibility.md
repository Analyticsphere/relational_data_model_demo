# Migrating PR2 variable derivations to dbt marts — feasibility

*Survey date: 2026-07-13 · Source (code read only, no prod queries): `Analyticsphere/PR2-analyses` → `PR2_FinalDerivationsCode.rmd`*

---

## Purpose

`Analyticsphere/PR2-analyses` holds a colleague's **finalized variable derivations** for PR2 v0.1 — the
recodes/definitions behind Connect's first design paper. The goal is to eventually compute these as **dbt
marts downstream of the relational model** (backlog §8), for **lineage and data-provenance**. This document
assesses feasibility: what the current code does, how amenable it is to dbt, what the model removes, and the
honest constraints. **Analysis reads the code only** — no BigQuery queries were run.

---

## What the current code is

| Attribute | Value |
|---|---|
| Artifact | one R Markdown file, **1,732 lines** (`PR2_FinalDerivationsCode.rmd`) |
| Language / stack | **R** + `bigrquery` + tidyverse/`data.table` |
| Source data | **`FlatConnect` (prod)** — `module1_v1`, `module1_v2`, `module3_v1`, `participants` |
| Grain | **participant** (one row per `Connect_ID`); **no aggregation** (`group_by` = 0) |
| Derived variables | **28** — demographics 11, alcohol 7, smoking 6, anthropometry 3 |
| Concept-ID column references | 155 (`D_<cid>` read straight from the wide tables) |

The 28 variables map directly onto the backlog's mart catalog: `mart_demographics` (race/ethnicity,
education, income, marital, sex, age), `mart_anthropometry` (BMI, height, weight), `mart_smoking`
(status, cig categories, ever-smoker), `mart_alcohol` (drinker status, beer/wine/liquor, drinks/week).

---

## Derivation profile — how dbt-friendly is it?

| Operation | Count | dbt/SQL translation |
|---|---:|---|
| `case_when` / `recode` / `ifelse` / `factor` | 15 / 15 / 12 / 25 | **direct** → `CASE WHEN` + labels |
| `mutate` (column creation) | 18 | **direct** → `SELECT` expressions |
| `group_by` / aggregation | **0** | n/a — all row-level, participant grain |
| `left_join` (on `Connect_ID`) | 3 | **direct** → dbt `ref()` joins |
| `rowSums` over indicator columns | 2 | race-option counting → `COUNT(...) GROUP BY connect_id` on the long fact |
| custom `function()` defs | 7 | **plumbing** (`numbers_only`, `convert_numeric_columns`, `recode_missing`, `add_missing_cols`) — dissolve (see below) |
| date math | ~6 | BigQuery date functions |
| `for`-loops | 0 | — |

**The work is dominated by row-level recodes with no aggregation — the dbt sweet spot.** A representative
case: `education_cat` is a `case_when` mapping **coded concept-ID values → labels**
(`.data[[education]] == 978204320 ~ "Grade school grades 1-8"`, …). That is exactly what the model's
`response_options` / dictionary already carries as data.

---

## What the relational model + dbt *removes* (the amplifier)

A large fraction of the 1,732 lines is boilerplate the model makes unnecessary — leaving mostly the actual
epidemiological definitions to migrate:

| Current hand-work | Lines/mechanism | In dbt-on-the-model |
|---|---|---|
| **v1/v2 merge** | ~50 (`setdiff(intersect(names…))`, `add_missing_cols`, `bind_rows`) | **gone** — `responses` already unifies versions (`GROUP BY question_concept_id`) |
| **Type coercion** | `numbers_only`, `convert_numeric_columns` | **gone** — typed value columns (`response_value_as_number`, enhancement §2) |
| **Race option counting** | `rowSums` over indicator cols | one `COUNT(...) GROUP BY connect_id` on the long fact (no dancing-schema indicator math) |
| **code → label recodes** | many `case_when` mapping `cid → text` | **join to `response_options`** (labels as data, not hand-typed) |
| **opaque `D_<cid>` columns** | 155 references | labeled joins to `question` / `response` |

So the "science" (category collapses, the BMI formula, smoking/alcohol logic) is the real migration payload;
the plumbing is subtracted. This is the same hand-work the pain-exhibit repos show — the model + dbt is what
retires it.

---

## The lineage / provenance win (the motivation)

| Concern | Today (`.rmd`) | dbt marts on the model |
|---|---|---|
| Lineage | buried in a 1,732-line monolith reading prod `FlatConnect` | **automatic column-/model-level DAG** (`dbt docs`): each derived column → `responses` → concept IDs |
| Reproducibility | run the whole `.rmd` | each variable is a versioned SQL model, `ref()`/`source()` enforced |
| Validation | manual eyeballing | dbt **tests** (`accepted_values` for categoricals, ranges e.g. `bmi > 0`, `not_null`) |
| Discoverability | one file | a researcher-facing **catalog** (`exposures`, model docs) |
| Governance | reads prod directly | inherits `sensitivity_tier` from the model; enforced in IAM (§7) |

This is precisely the provenance a design-paper deliverable and PR2 need.

---

## Feasibility verdict: **HIGH** — with a rewrite, not a lift-and-shift

- **Nature of the work fits dbt** (row-level recodes, participant grain, no aggregation, no loops), and the
  model *removes* the hardest R plumbing (v1/v2 merge, type coercion, indicator math, code→label maps).
- **But it is a re-expression, not a port:** the `.rmd` targets `FlatConnect` wide; dbt marts downstream of
  the model must be rewritten against the long `responses` fact. That rewrite is what buys the lineage and
  removes the boilerplate — but it is real work, and the epi definitions must be preserved **exactly** (the
  paper depends on them).

### Constraints & sequencing
1. **Dependency order:** marts sit downstream of the relational model (currently a stage POC) and benefit
   from typed values (§2) + the normalized question-type view (§1). Marts can't precede the model in prod.
2. **Epi fidelity + ownership:** the derivations *are* the science — migration needs the colleague's
   per-variable sign-off. Budget this as real epidemiology review, not a mechanical translation (matches the
   backlog's "each mart needs an owner + epi sign-off").
3. **Timeline:** v0.1 feeds a paper, possibly on a deadline. **dbt marts should not block the paper.**

### Recommendation
- **Build in parallel, reconcile against the `.rmd` as the oracle.** Keep the `.rmd` for the paper now; build
  the dbt marts against the model and **validate output row-for-row** against the `.rmd` results (a dbt
  reconciliation test). The `.rmd` becomes the reference implementation that de-risks the migration and
  proves fidelity.
- **Start with `mart_anthropometry`** (3 vars, BMI is the cleanest, well-defined demo) to prove the pattern
  end-to-end (model → typed values → mart → tests → `dbt docs` lineage), then demographics/smoking/alcohol.
- **Fold the label recodes into `response_options` joins** wherever a recode is just code→label, so only the
  genuine category logic lives in the mart SQL.

---

## Scope summary

| Dimension | Value |
|---|---|
| Derived variables to migrate | 28 (demographics 11 · alcohol 7 · smoking 6 · anthropometry 3) |
| Current implementation | 1,732-line R Markdown, reads `FlatConnect` prod |
| Aggregation in the derivations | none (participant-grain recodes) |
| SQL-translatable ops (case_when/recode/mutate/factor/ifelse) | ~85 occurrences — all direct |
| R plumbing the model removes | v1/v2 merge (~50 lines), 7 helper fns, `rowSums` indicator math, type coercion |
| Genuinely R-specific / untranslatable | none found (no loops; helpers are mechanical) |
| Blocking dependency | the relational model stood up (stage POC → prod) + typed values (§2) |

---

*Design-phase feasibility analysis for the dbt analytics-marts enhancement (backlog §8), scoping migration of
`Analyticsphere/PR2-analyses` (`PR2_FinalDerivationsCode.rmd`). Code was read, not executed; no BigQuery
queries were run.*
