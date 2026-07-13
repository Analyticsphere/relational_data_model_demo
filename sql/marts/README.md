# sql/marts/ — curated derived-variable marts (first pass, plain BigQuery views)

Participant-grain "derived variable" marts (backlog §8), built **on the long `responses` fact**. This is a
**first pass written as plain BigQuery `CREATE VIEW`s — no dbt, no Jinja yet**; they will be reworked into
dbt models later (for lineage, tests, and `dbt docs`).

The derivations are transcribed from **`Analyticsphere/PR2-analyses` → `PR2_FinalDerivationsCode.rmd`** (the
finalized v0.1 definitions for Connect's first design paper). See `docs/marts_dbt_feasibility.md`.

**No production data** is read anywhere here: the views are *definitions* over the model
(`relational.responses`, built from CleanConnect), and their logic was validated on **synthetic** data in
DuckDB, never against prod.

| File | Domain | Variables |
|---|---|---|
| `mart_demographics.sql` | demographics | `education_cat`, `marital_status_cat`, `income_cat` (+ coded IDs) |
| `mart_anthropometry.sql` | anthropometry | `height_*`, `weight`, `bmi_derived`, `bmi_category` |
| `mart_smoking.sql` | smoking | base recodes (`smoker_status`, `cigs_lifetime`, `smoke_cigs_now`, `cigs_lasttime`) + derived `ever_smoker_override`, `cigarette_cats` (Never/Current/Former) |

**Complexity gradient (increasing):** demographics/anthropometry (clean recodes + one formula) → smoking
(recodes + a multi-condition Never/Current/Former collapse, done on concept IDs) → **alcohol** (the hard one).

*(TODO — `mart_alcohol`* and the multi-select *race/ethnicity* variables.)* Alcohol is qualitatively harder and
needs the colleague's per-variable sign-off before transcription: it combines (a) a **multi-select** "types of
alcohol" question → long-fact aggregation (`alc_beer/liquor/wine/other`, `alc_type_any`); (b) **quantification
lookups** that map coded frequency/quantity answers to *numbers* (e.g. "2-3×/week" → 2.5) — these are **analyst
decisions, not dictionary labels**, so they belong in an explicit lookup (an ideal **dbt seed** later, with its
own lineage); (c) **computed** `beer_dwk`/`wine_dwk`/drinks-per-week + a multi-condition `alc_derived` status.

## Design: dictionary labels vs. hand-coded `CASE`

A recode falls into one of three shapes — only the third is hand-typed:

1. **Pure code → label** (education, marital, income): **JOIN the dictionary** (`response` dim:
   `response_concept_id → current_format_value`, `"N = Label"` stripped) rather than hand-typing the labels.
   The labels stay in sync with the dictionary and can't drift — the whole point of the model.
2. **Category collapse** (e.g. grouping several codes into one bucket): a `CASE` over the coded values — but
   it still references concept IDs, not labels. *(none in this first pass; add as needed.)*
3. **Derived bin / formula** (BMI category from a computed number): a `CASE` on the derived value. Not a
   dictionary label, so it stays explicit (see `mart_anthropometry.sql`).

Multi-select variables (e.g. race "select all") aren't a pivot-and-recode — they aggregate on the long fact
(`COUNT(...) GROUP BY connect_id`); deferred to their own mart.

## Run / rework

- Substitute `${PROJECT}` and ensure `relational.responses` + the `relational.response` dictionary dim are
  loaded; the views write to a `marts` dataset.
- **Validate row-for-row against the `.rmd`** before any reporting use — the `.rmd` is the reference oracle.
- Rework into dbt later: each view becomes a model with `ref()`/`source()`, tests (`bmi_derived > 0`,
  `accepted_values`), and `dbt docs` lineage.
