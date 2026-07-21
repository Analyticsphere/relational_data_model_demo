# Select-All-That-Apply: two representations, tested side by side (`relational` vs `relational2`)

*Design note for `sql/relational2/build_responses.sql`. No production data is read; the logic is validated on
synthetic data (`scripts/smoke_test_relational2.py`).*

## Why this exists

Today a Select-All-That-Apply (SATA) answer is modeled **option-as-question**: each checked option is its own
`responses` row where the *option* is the `question_concept_id` and the SATA parent is the
`source_question_concept_id`. That treats every checkbox as a separate question.

Single-select **Multiple Choice** is already modeled the other way — **option-as-answer**: the question is the
question, and the chosen option is the answer. SATA arguably should look the same.

Rather than pick one and migrate, we build a second dataset, **`relational2`**, that holds the alternative,
so both can be evaluated against real data before deciding. `relational` stays untouched.

## The two shapes (one selected option: "American Indian or Alaska Native" under "Which categories describe you?")

| field | `relational` (legacy, option-as-question) | `relational2` (option-as-answer) |
|---|---|---|
| `question_concept_id` | `165596977` (the option) | `479143504` (the SATA parent) |
| `source_question_concept_id` | `479143504` (the parent) | `NULL` |
| `response_value_as_string` / `_as_concept_id` | the raw cell | `165596977` (the chosen option) |
| `response_unique_id` | `f(sec, parent, option, cell)` | `f(sec, '', parent, option)` — **recomputed, differs** |

One row per **selected** option in both — identical grain, just a different labeling and a recomputed id.

## How `relational2` is built

`sql/relational2/build_responses.sql` is a **controlled A/B copy**: `relational2.responses` is
`relational.responses` transformed, not re-unpivoted. So the two datasets differ *only* by the SATA remodel.

- **SATA rows** → `question ← parent`, `source_question ← NULL`, `answer ← option` (string + concept_id),
  and **`response_unique_id` is recomputed** by the `relational.response_unique_id` UDF on the new fields.
- **Non-SATA rows** → byte-identical, so their `response_unique_id` is unchanged. Any downstream difference
  between `relational` and `relational2` is therefore attributable **only** to the SATA remodel.

### Scope: SATA only

- **SATA** → remodeled. **Grid** → *not* remodeled (a grid sub-item is a genuinely distinct question, so it
  keeps `question = sub-item`). **MC** single-select → already option-as-answer. The smoke test asserts grid
  and MC rows are untouched.

### Identifying SATA

A row is remodeled iff its question (the **option** row, in the legacy shape) is typed Select-All-That-Apply
**and** it carries a parent — isolated in the `sata` CTE:

```sql
LOWER(question_type) LIKE '%select all that apply%'   -- matches Optional / Required / Loops / DisplayIf variants
```

**Caveat:** `question_type` is ~62% blank/dirty in the dictionary (see `docs/question_types_survey.md`). SATA
rows lacking a clean type are **not** remodeled. Cleaning `question_type` (or a curated allow-list) is the way
to make it exhaustive; it does not change the build logic.

## The id changes for SATA — that is the point

`response_unique_id` is a function of `(secondary_source, source_question, question, response_value)`. The
SATA remodel changes three of those, so **SATA ids differ between `relational` and `relational2`**; non-SATA
ids are identical. This is by design — it's exactly what makes the two representations comparable. Because
`relational` and `relational2` are both live, no id is "lost": pick a representation *before* any ids are
treated as a frozen contract downstream (Usagi).

## A dim implication to evaluate

In the legacy shape the SATA **parent** lives in the `source_question` dim and the **options** live in the
`question` dim. Option-as-answer flips that: the parent becomes the *question* and options become *answers*.
So a fully-enriched `relational2` would want the SATA parents promoted into the `question` dim and the options
represented in the `response` dim. `relational2.responses` alone doesn't require this, but any enrichment view
over it will — this is one of the things the A/B test is meant to surface.

## Run

```bash
# after the relational pipeline has built relational.responses + dims + the response_unique_id UDF:
sed 's/${PROJECT}/'"$PROJECT"'/g' sql/relational2/build_responses.sql | bq --project_id=$PROJECT query --use_legacy_sql=false
# compare the two representations (counts, how many ids changed, id health — no verbatim values):
sed 's/${PROJECT}/'"$PROJECT"'/g' sql/relational2/compare_with_relational.sql | bq --project_id=$PROJECT query --use_legacy_sql=false
```

Expected from the comparison: `total_rows` equal in both, `ids_changed_sata = sata_parent_freed` (the
remodeled SATA rows), `r2_distinct_ids = r2_distinct_combos` (collision-free), `r2_out_of_omop_range = 0`.

## Test

```bash
python scripts/smoke_test_relational2.py   # synthetic; mirrors build_responses.sql
```
