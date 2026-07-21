# sql/omop/ — OMOP mapping helpers

Artifacts that prepare the relational model for OMOP mapping. No production data is read; logic is validated
on synthetic data.

| File | What it does |
|---|---|
| `response_unique_id_udf.sql` | Persistent BigQuery UDF `relational.response_unique_id(...)` — the single canonical definition of the id contract. Returns a stable **INT64** per unique response, in OMOP's custom-concept range (`> 2e9`). Called in every unpivot `INSERT`, so the id lands on `relational.responses`. |
| [`../../scripts/smoke_test_omop_hash.py`](../../scripts/smoke_test_omop_hash.py) | Production-free smoke test of the id recipe (DuckDB == Python, OMOP range, determinism, collision-safety). |

**Reproducibility contract:** `response_unique_id = 2000000001 + (first 15 hex chars of SHA-256(x))`, where
`x` joins **only** four raw, stable fields
(`secondary_source_concept_id | source_question_concept_id | question_concept_id | response_value_as_string`,
`'|'`-joined, `NULL → ''`, UTF-8). No normalization, classification, or typed columns feed it, so it can't
drift; the same recipe reproduces on Snowflake / Spark / Postgres / Python. Best practice: **compute once at
unpivot time, store on `responses`, and read.**

> The Usagi source-code projection (distinct responses + `source_code_description`) is maintained
> **downstream** by the OMOP mapping owner. This repo's OMOP responsibility ends at `response_unique_id` on
> `relational.responses`.

Full spec, cross-platform parity, PII/governance →
[`docs/omop_source_codes.md`](../../docs/omop_source_codes.md).
