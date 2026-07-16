# OMOP source codes for Usagi — deterministic response hashing

*Design note for `sql/omop/response_source_codes.sql`. No production data is read anywhere; the logic was
validated on synthetic data.*

## Goal

A colleague maps Connect responses to OMOP standard concepts with **Usagi**. Usagi ingests distinct
**source codes** (`source_code` + a human `source_code_description`) and suggests concept mappings. We need a
**stable, deterministic id per unique response** — including **every unique free-text response**, mapped
individually — that is **reproducible across platforms and over time**.

## The one rule: the id hashes only raw, stable inputs

Reproducibility is the whole point, so the id must never move. `response_hash_id` is `SHA-256` (lowercase
hex) of a canonical string built from **four raw columns and nothing else**:

```
secondary_source_concept_id | source_question_concept_id | question_concept_id | response_value_as_string
```

Everything that *could change* is deliberately kept **out** of the hash:

- **No normalization** of the value (no lowercase/trim/Unicode folding). We hash `response_value_as_string`
  **verbatim**. Collapsing `"Aspirin"`/`"aspirin"` is a *downstream* choice (`value_norm`, below) — baking it
  into the id would mean every id changes the day someone tweaks the rule.
- **No classification** (coded vs text vs numeric) feeding the id. That heuristic depends on the dictionary
  bridge and typing, which drift.
- **No typed columns** (`response_value_as_concept_id`, …) in the id. They may be populated later; if the id
  read them, it would move. `response_value_as_string` is filled at unpivot time and never re-typed.

> **Everything else in the table is *decoration*** — `response_kind`, `value_norm`,
> `source_code_description`. Useful, but they **never affect `response_hash_id`**, so they can be changed
> freely.

## The canonical string — freeze this, it is the contract

| Element | Value |
|---|---|
| Fields, in order | `secondary_source_concept_id`, `source_question_concept_id`, `question_concept_id`, `response_value_as_string` |
| NULL | empty string `''` |
| Delimiter | `'|'` — the first three fields are digit-only concept IDs (never contain it); the free-text value is **last**, so any `'|'` inside it can't create ambiguity |
| Encoding | UTF-8 |
| Hash | SHA-256 → **lowercase hex** |

That's the entire spec. Anyone — BigQuery, Snowflake, Python, Usagi's Java — who builds this exact byte
string and SHA-256s it gets the identical id.

## Is it reproducible on other cloud platforms? Yes — with one discipline

SHA-256 is universal and deterministic; **what must match is the input bytes**, not the SQL. The functions
differ per engine, the *result* does not:

| Step | BigQuery | Snowflake | Spark / Databricks | Postgres (pgcrypto) |
|---|---|---|---|---|
| SHA-256 → hex | `TO_HEX(SHA256(x))` | `SHA2(x, 256)` | `sha2(x, 256)` | `encode(digest(x,'sha256'),'hex')` |
| Concatenate | `CONCAT(a,'|',b,…)` | `a \|\| '|' \|\| b` | `concat_ws('|', …)` | `concat_ws('|', …)` |
| NULL → '' | `COALESCE(x,'')` | `COALESCE` | `coalesce` | `coalesce` |

All four produce **lowercase hex**. Because the hash inputs are raw (no NFC, no locale-sensitive casing, no
regex), there are **no cross-engine normalization traps** — the fragile parts live only in the decoration
columns, which don't affect the id.

**The real safeguard is process, not SQL: compute the id ONCE (here), persist it, and have every other
platform and Usagi READ the stored column.** Then "reproducible across platforms" is trivially true because
only one implementation ever runs. The spec above is the fallback for anyone who genuinely must recompute.

### Recompute check (Python / R)

```python
import hashlib
def response_hash(sec, sq, q, value_verbatim):
    parts = [sec or "", sq or "", q or "", value_verbatim]      # NULL -> ""
    return hashlib.sha256("|".join(parts).encode("utf-8")).hexdigest()
```
```r
response_hash <- function(sec, sq, q, value_verbatim) {
  parts <- c(sec %||% "", sq %||% "", q %||% "", value_verbatim)   # NULL/NA -> ""
  openssl::sha256(charToRaw(paste(parts, collapse = "|")))
}
```
Both return the same lowercase hex as `TO_HEX(SHA256(...))` in BigQuery.

## Decisions to make up front (each one re-hashes everything)

Because the recipe is a one-time contract, settle these **before** first use — changing them later invalidates
every previously-issued id:

1. **Is `secondary_source_concept_id` in the key?** IN → survey-specific codes (the same concept mapped once
   per survey). OUT → one code per `(question, answer)` across surveys, leveraging Connect's global concept
   reuse (~8.9% of question concepts span >1 survey). Included by default per the stated intent; drop one
   line to switch. Confirm with your colleague which grain OMOP wants.
2. **Delimiter** `'|'` and **NULL → `''`** — locked above.
3. **Verbatim, not normalized** — the id is over raw text; grouping variants is downstream.

## Free text is mapped individually (and is the PII surface)

Each distinct verbatim free-text string gets its own id and its own Usagi row — that's the point (typed drug
names → RxNorm, condition text → SNOMED, etc.). Two consequences:

- **`value_norm`** (a decoration column: NFC + trim + collapse whitespace + lowercase) is offered *only* as an
  optional grouping key if the volume of near-duplicate strings is painful to map — it does **not** change
  the id.
- **Governance.** A catalog of every distinct free-text string is a PII/PHI surface. Before exporting:
  restrict `response_kind = 'free_text'` rows to a **vetted allow-list of vocabulary-mappable questions**
  (conditions, drugs, procedures, occupation) — not narrative / "other, explain" fields — and govern this
  table (especially `response_value_verbatim`) at the sensitivity tier of its inputs. Filtering is downstream
  and never changes ids.

## Feeding Usagi

- `source_code` = `response_hash_id`
- `source_code_description` = `source_code_description` (coded → question text + answer label from the
  dictionary; free text → question text + the verbatim string)
- optionally carry `question_concept_id` / `response_value_verbatim` so mappings round-trip back to Connect.

## Run

Substitute `${PROJECT}` and ensure `relational.responses` + the `question` / `response` /
`question_response` dims are loaded, then run `sql/omop/response_source_codes.sql`. The output table is
deterministic — re-running reproduces byte-identical `response_hash_id`s.
