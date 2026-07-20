# Select-All-That-Apply: two representations, side by side

*Design note for `sql/unpivot/v_responses_sata_v2.sql`. No production data is read; the logic is validated on
synthetic data (`scripts/smoke_test_sata_representation.py`).*

## Why this exists

Today a Select-All-That-Apply (SATA) answer is modeled **option-as-question**: each checked option is its own
`responses` row where the *option* is the `question_concept_id` and the SATA parent is the
`source_question_concept_id`. That treats every checkbox as a separate question with an implicit yes/no.

Single-select **Multiple Choice** is already modeled the other way — **option-as-answer**: the question is the
question, and the chosen option is the answer (`response_value_*`). SATA arguably should look the same.

Rather than pick one and migrate, we expose **both** and defer the decision. The base `responses` fact keeps
the legacy shape; the view `v_responses_sata_v2` presents the alternative. They differ only by *relabeling
existing columns*, so the view copies no data and is fully reversible.

## The two shapes (one selected option: "American Indian or Alaska Native" under "Which categories describe you?")

| field | `responses` (legacy, option-as-question) | `v_responses_sata_v2` (option-as-answer) |
|---|---|---|
| `question_concept_id` | `165596977` (the option) | `479143504` (the SATA parent) |
| `source_question_concept_id` | `479143504` (the parent) | `NULL` |
| `response_value_as_concept_id` | *(typed later)* | `165596977` (the chosen option) |
| `response_value_as_string` | the raw cell | `165596977` (the chosen option) |

One row per **selected** option in both — identical grain, just a different labeling. Non-SATA rows are byte-
identical between the two.

## Scope: SATA only (by decision)

- **SATA** → remodeled by the view.
- **Grid** (e.g. "Tylenol frequency", "NSAID frequency" sharing a scale) → **not** remodeled: a grid sub-item
  is a genuinely distinct question, so it keeps `question = sub-item`. Folding it under the grid parent would
  destroy that identity.
- **Multiple Choice** single-select → already option-as-answer; untouched.

The smoke test asserts grid and MC rows pass through unchanged.

## How SATA is identified

A row is remodeled iff its question (the **option** row, in the legacy shape) is typed Select-All-That-Apply in
the `question` dimension **and** it carries a parent:

```sql
LOWER(question_type) LIKE '%select all that apply%'   -- matches Optional / Required / Loops / DisplayIf variants
```

This predicate is isolated in the view's `sata` CTE — the single place to refine. **Caveat:** `question_type`
is ~62% blank / dirty in the dictionary (see `docs/question_types_survey.md`). SATA rows that lack a clean type
will not be remodeled. Cleaning `question_type` (or swapping in a curated SATA allow-list) is the way to make
this exhaustive; it does not change the view's logic.

## Choosing a representation downstream

Point each consumer at the source it wants — nothing else changes:

| Consumer | Legacy | Option-as-answer |
|---|---|---|
| OMOP source codes (`sql/omop/response_source_codes.sql`) | `FROM … relational.responses` | `FROM … relational.v_responses_sata_v2` |
| marts / `v_responses_enriched` | `responses` | `v_responses_sata_v2` |

### ⚠️ Interaction with the OMOP hash

The `response_hash_id` is a function of `(secondary_source, source_question, question,
response_value_as_string)`. For SATA rows, **three of those four fields differ** between the representations, so
the hashed ids differ. Consequences:

- Decide the representation **before** freezing the hash contract / issuing production ids.
- If the choice flips after ids exist, regenerate deterministically and keep an `old_hash → new_hash`
  crosswalk so completed Usagi mappings carry forward. (This is the same "the raw model is part of the key"
  point from `docs/omop_source_codes.md` — a model change is exactly what the hash is *not* invariant to.)

## Reversibility

`v_responses_sata_v2` carries `sata_remodeled` (the flag) plus `orig_question_concept_id` /
`orig_source_question_concept_id` (the legacy placement), so the legacy shape is recoverable from the view and
no lineage is lost.

## Test

```bash
python scripts/smoke_test_sata_representation.py   # runs the real view SQL in DuckDB on synthetic data
```
