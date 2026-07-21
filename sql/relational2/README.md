# sql/relational2/ — SATA option-as-answer A/B dataset

A second BigQuery dataset, `relational2`, for evaluating the alternative **Select-All-That-Apply**
representation against the live `relational` model. No production data is read; logic validated on synthetic
data (`scripts/smoke_test_relational2.py`).

| File | What it does |
|---|---|
| `build_responses.sql` | Creates the `relational2` dataset and `relational2.responses` — `relational.responses` with SATA rows remodeled **option-as-answer** (`question ← parent`, `answer ← option`, `source_question ← NULL`) and `response_unique_id` **recomputed**. Non-SATA rows are identical. |
| `compare_with_relational.sql` | Quantifies the difference (rows, ids changed, id health) between the two datasets. No verbatim values. |

**Controlled A/B:** `relational2.responses` is a *transform* of `relational.responses` (not a re-unpivot), so
the two datasets differ **only** by the SATA remodel. Depends on `relational.responses`, `relational.question`,
and the `relational.response_unique_id` UDF. Run after the `relational` pipeline.

Full rationale, scope (SATA only), the dim implication, and how the id changes →
[`docs/sata_representation.md`](../../docs/sata_representation.md).
