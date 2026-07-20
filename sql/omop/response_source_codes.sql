-- response_source_codes — deterministic, reproducible source codes for OMOP mapping via Usagi.
-- NOT run against production; logic validated on synthetic data.
--
-- ┌─ REPRODUCIBILITY IS THE PRIORITY ────────────────────────────────────────────────────────────────┐
-- │ response_hash_id = SHA-256 (lowercase hex) of RAW, VERBATIM, STABLE inputs ONLY:                   │
-- │   secondary_source_concept_id | source_question_concept_id | question_concept_id | response_value_as_string │
-- │ NOTHING else feeds the hash — no classification, no normalization, no typed-value columns, no      │
-- │ dictionary lookups. So the id CANNOT drift when the dictionary, the typing step, or our heuristics  │
-- │ change. Every other column here is DECORATION, computed alongside; it never affects the id.        │
-- └───────────────────────────────────────────────────────────────────────────────────────────────────┘
--
-- CANONICAL STRING — freeze this; it is the contract (see docs/omop_source_codes.md):
--   fields, in fixed order:  secondary_source_concept_id ‖ source_question_concept_id ‖ question_concept_id ‖ response_value_as_string
--   NULL -> ''   delimiter -> '|'   encoding -> UTF-8   hash -> SHA-256 -> lowercase hex
--
-- RAW value on purpose: response_value_as_string is always the verbatim cell — never re-typed.
-- Do NOT normalize case/whitespace; that lets the id move. Downstream grouping -> value_norm column.
--
-- response_unique_id — the integer form of the id (also valid as an OMOP custom concept_id):
--   Stored on relational.responses (computed by the response_unique_id UDF at unpivot time).
--   This table reads it directly — no recomputation here.
--   See sql/omop/response_unique_id_udf.sql for the full derivation.
--
-- DECIDE BEFORE FIRST USE (changing any of these re-hashes EVERYTHING — it is a one-time contract):
--   1. Column set — is `secondary_source_concept_id` in the key? IN = survey-specific codes; OUT = one code
--      per (question, answer) across surveys (leverages Connect's global concept reuse). Included here per
--      the stated intent; drop the line to switch. 2. Delimiter '|'.  3. NULL -> ''.
--
-- GOVERNANCE: `response_value_verbatim` exposes free text = PII. Govern this table at its inputs'
--   sensitivity, and restrict which free-text questions you actually export to Usagi. That filtering is
--   downstream and never changes ids.

CREATE OR REPLACE TABLE `${PROJECT}.relational.response_source_codes`
OPTIONS(description="Deterministic SHA-256 source codes for OMOP/Usagi mapping — one row per unique response. response_hash_id hashes ONLY raw stable inputs (secondary_source, source_question, question, response_value_as_string, '|'-joined, NULL->''), so it never drifts. response_unique_id is read directly from relational.responses (computed there by the response_unique_id UDF). All other columns are decoration (never feed the hash). response_value_verbatim exposes free text -> govern as PII. See docs/omop_source_codes.md.")
AS
WITH distinct_responses AS (
  SELECT DISTINCT
    secondary_source_concept_id,
    source_question_concept_id,
    question_concept_id,
    response_value_as_string,
    response_unique_id
  FROM `${PROJECT}.relational.responses`
  WHERE response_value_as_string IS NOT NULL AND response_value_as_string <> ''
),
hashed AS (
  SELECT
    -- ── THE HASH ID: pure function of the four raw fields, nothing else ──
    -- Computed here (not stored on responses) — response_unique_id is the persisted form.
    TO_HEX(SHA256(CONCAT(
      COALESCE(d.secondary_source_concept_id, ''), '|',
      COALESCE(d.source_question_concept_id,  ''), '|',
      COALESCE(d.question_concept_id,         ''), '|',
      d.response_value_as_string
    ))) AS response_hash_id,
    d.secondary_source_concept_id,
    d.source_question_concept_id,
    d.question_concept_id,
    d.response_value_as_string,
    d.response_unique_id
  FROM distinct_responses d
)
SELECT
  h.response_hash_id,
  h.response_unique_id,

  -- the exact inputs, kept for audit / regeneration
  h.secondary_source_concept_id,
  h.source_question_concept_id,
  h.question_concept_id,
  h.response_value_as_string AS response_value_verbatim,

  -- ── DECORATION below — helpful, but DOES NOT affect the ids (safe to change anytime) ──
  -- convenience classification for choosing what to send to Usagi (coded vs numeric vs free text)
  CASE
    WHEN qr.response_concept_id IS NOT NULL                                        THEN 'coded'
    WHEN SAFE_CAST(h.response_value_as_string AS FLOAT64) IS NOT NULL
      OR REGEXP_CONTAINS(h.response_value_as_string, r'^\d{4}-\d{2}-\d{2}')        THEN 'numeric_or_date'
    ELSE 'free_text'
  END AS response_kind,
  -- optional downstream grouping key for free text (NFC/trim/space/lowercase) — NOT hashed
  LOWER(REGEXP_REPLACE(NORMALIZE(TRIM(h.response_value_as_string), NFC), r'\s+', ' ')) AS value_norm,
  -- Usagi's source_code_description: coded -> question + answer label; else question + verbatim
  CONCAT(COALESCE(q.question_text, ''), ' | ',
         COALESCE(resp.format_value, h.response_value_as_string)) AS source_code_description
FROM hashed h
LEFT JOIN `${PROJECT}.relational.question`          q    USING (question_concept_id)
LEFT JOIN `${PROJECT}.relational.question_response` qr
       ON qr.question_concept_id = h.question_concept_id
      AND qr.response_concept_id = h.response_value_as_string
LEFT JOIN `${PROJECT}.relational.response`          resp
       ON resp.response_concept_id = h.response_value_as_string;
