# sql/omop/ — OMOP mapping helpers

Artifacts that prepare the relational model for OMOP mapping. No production data is read; logic is validated
on synthetic data.

| File | What it does |
|---|---|
| `response_source_codes.sql` | Builds `relational.response_source_codes` — one **deterministic** SHA-256 id per unique response (`response_hash_id`), the stable `source_code` a colleague maps to OMOP concepts in **Usagi** (incl. every unique free-text response). Also emits `response_custom_concept_id` — the same id as an integer in OMOP's custom-concept range (>2e9), a pure projection of the hash. |

**Reproducibility contract:** `response_hash_id` hashes **only** four raw, stable fields
(`secondary_source_concept_id | source_question_concept_id | question_concept_id | response_value_as_string`,
`'|'`-joined, `NULL → ''`, UTF-8, SHA-256 → lowercase hex). No normalization, classification, or typed
columns feed the hash, so it can't drift; all other columns are decoration. The same recipe reproduces on
Snowflake / Spark / Postgres / Python — best practice is to **compute once here, store, and read**.

Full spec, cross-platform parity, PII/governance, and the up-front decisions →
[`docs/omop_source_codes.md`](../../docs/omop_source_codes.md).
