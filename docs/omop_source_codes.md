# OMOP source codes for Usagi — response_unique_id

*Design note for `sql/omop/response_unique_id_udf.sql` — the `response_unique_id` contract.
No production data is read anywhere; the logic was validated on synthetic data.*

## Goal

A colleague maps Connect responses to OMOP standard concepts with **Usagi**. Usagi ingests distinct
**source codes** (`source_code` + a human `source_code_description`) and suggests concept mappings. We need a
**stable, deterministic id per unique response** — including **every unique free-text response**, mapped
individually — that is **reproducible across platforms and over time**.

## The id: `response_unique_id`

`response_unique_id` is a stable `INT64` identity stored directly on `relational.responses` — one value per
unique `(secondary_source_concept_id, source_question_concept_id, question_concept_id, response_value_as_string)`
combination. It is computed at unpivot time by the `response_unique_id` UDF
(`sql/omop/response_unique_id_udf.sql`) and never changes once written.

It satisfies all three of OMOP's custom-concept requirements:
1. **Integer** ✓
2. **> 2,000,000,000** ✓
3. **< 9,223,372,036,854,775,807** (signed-64 max) ✓

So it can live in the OMOP `CONCEPT` table as a [custom concept](https://ohdsi.github.io/CommonDataModel/customConcepts.html)
and as `*_source_concept_id` on facts.

## The one rule: the id hashes only raw, stable inputs

Reproducibility is the whole point, so the id must never move. Under the hood, the UDF computes
`SHA-256` of a canonical string built from **four raw columns and nothing else**, then projects it to
an integer:

```
response_unique_id = 2000000001 + (first 15 hex chars of SHA-256, read as base-16)
```

Everything that *could change* is deliberately kept **out** of the hash:

- **No normalization** of the value (no lowercase/trim/Unicode folding). `response_value_as_string`
  is hashed **verbatim**. Collapsing `"Aspirin"`/`"aspirin"` is a *downstream* choice (`value_norm`) — baking
  it in would invalidate every id the day someone tweaks the rule.
- **No classification** (coded vs text vs numeric) feeding the id. That heuristic depends on the
  dictionary bridge and typing, which drift.
- **No typed columns** (`response_value_as_concept_id`, …) in the id. `response_value_as_string` is
  filled at unpivot time and never re-typed.

> **The id depends on nothing else.** Anything derived *around* it — the Usagi `source_code_description`,
> free-text grouping keys, coded/numeric/text classification — is **decoration** and **never affects
> `response_unique_id`**, so it can change freely. Those live downstream (see *Feeding Usagi*), not in this
> repo.

## The canonical string — freeze this, it is the contract

| Element | Value |
|---|---|
| Fields, in order | `secondary_source_concept_id`, `source_question_concept_id`, `question_concept_id`, `response_value_as_string` |
| NULL | empty string `''` |
| Delimiter | `'|'` — the first three fields are digit-only concept IDs (never contain it); the free-text value is **last**, so any `'|'` inside it can't create ambiguity |
| Encoding | UTF-8 |
| Hash | SHA-256 → lowercase hex → first 15 chars as base-16 + 2000000001 |

### Recompute check (Python / R)

```python
import hashlib
def response_unique_id(sec, sq, q, value):
    parts = [sec or "", sq or "", q or "", value or ""]
    h = hashlib.sha256("|".join(parts).encode("utf-8")).hexdigest()
    return 2000000001 + int(h[:15], 16)
```
```r
response_unique_id <- function(sec, sq, q, value) {
  parts <- c(sec %||% "", sq %||% "", q %||% "", value %||% "")
  h <- openssl::sha256(charToRaw(paste(parts, collapse = "|")))
  bit64::as.integer64(2000000001) +
    Reduce(function(a, d) a * 16L + d,
           strtoi(strsplit(substr(h, 1, 15), "")[[1]], 16L),
           bit64::as.integer64(0))
}
```

## Decisions to make up front (each one re-hashes everything)

Because the recipe is a one-time contract, settle these **before** first use — changing them later
invalidates every previously-issued id:

1. **Is `secondary_source_concept_id` in the key?** IN → survey-specific codes (the same concept
   mapped once per survey). OUT → one code per `(question, answer)` across surveys, leveraging
   Connect's global concept reuse (~8.9% of question concepts span >1 survey). Included by default
   per the stated intent; drop one line from the UDF to switch.
2. **Delimiter** `'|'` and **NULL → `''`** — locked above.
3. **Verbatim, not normalized** — the id is over raw text; grouping variants is downstream.

## Free text is mapped individually (and is the PII surface)

Each distinct verbatim free-text string gets its own id and its own Usagi row — that's the point
(typed drug names → RxNorm, condition text → SNOMED, etc.). Two consequences:

- **`response_value_norm`** (a decoration column: NFC + trim + collapse whitespace + lowercase) is offered
  *only* as an optional grouping key if the volume of near-duplicate strings is painful to map — it
  does **not** change the id.
- **Governance.** A catalog of every distinct free-text string is a PII/PHI surface. Before
  exporting: restrict `response_kind = 'free_text'` rows to a **vetted allow-list of
  vocabulary-mappable questions** (conditions, drugs, procedures, occupation) — not narrative /
  "other, explain" fields — and govern this table (especially `response_value_verbatim`) at the
  sensitivity tier of its inputs. Filtering is downstream and never changes ids.

## Feeding Usagi (downstream)

This repo produces `response_unique_id` on `relational.responses`; the Usagi source-code prep is
maintained **downstream** by the OMOP mapping owner. For reference, the expected shape there is:

- `source_code` = `CAST(response_unique_id AS STRING)`
- `source_code_description` — coded → question text + answer label from the dictionary; free text →
  question text + the verbatim string (a distinct-response projection joined to the dims)
- optionally carry `question_concept_id` / the verbatim value so mappings round-trip back to Connect.
- `response_unique_id` is already the OMOP custom `concept_id` — use it as `*_source_concept_id` on
  facts without any further transformation.

## Run

Deploy the UDF (`sql/omop/response_unique_id_udf.sql`) into the target project's `relational` dataset;
the unpivot `INSERT`s then call it so every `relational.responses` row carries `response_unique_id`.
See [`docs/omop_run_protocol.md`](omop_run_protocol.md). Re-running is deterministic — identical
`response_unique_id` values every time.
