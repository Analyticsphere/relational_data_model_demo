-- response_source_codes — deterministic, reproducible source codes for OMOP mapping via Usagi.
-- FIRST PASS on the long `responses` fact. NOT run against production; logic validated on synthetic data.
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
--   NULL            -> empty string ''
--   delimiter       -> '|'   (the first three fields are digit-only concept IDs and never contain it;
--                             the free-text value is LAST, so any '|' inside it cannot create ambiguity)
--   encoding        -> UTF-8 ;  hash -> SHA-256 -> lowercase hex
--
-- RAW value on purpose: we hash `response_value_as_string` verbatim (always populated; never re-typed).
-- We do NOT normalize case/whitespace and do NOT COALESCE with the typed columns — either would let the id
-- move later. If you want to collapse "Aspirin"/"aspirin", do it DOWNSTREAM (see the derived `value_norm`
-- column); the id stays fixed forever.
--
-- REPRODUCES ANYWHERE (identical bytes -> identical hash):
--   BigQuery  TO_HEX(SHA256(x))            Snowflake SHA2(x, 256)         Spark  sha2(x, 256)
--   Postgres  encode(digest(x,'sha256'),'hex')   Python hashlib.sha256(x.encode()).hexdigest()
--   BEST PRACTICE: compute ONCE here, store it, and have every tool (incl. Usagi) READ this column.
--   Do not recompute in multiple places.
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
OPTIONS(description="Deterministic SHA-256 source codes for OMOP/Usagi mapping — one row per unique response. response_hash_id hashes ONLY raw stable inputs (secondary_source, source_question, question, response_value_as_string, '|'-joined, NULL->''), so it never drifts. All other columns are decoration (never feed the hash). response_value_verbatim exposes free text -> govern as PII. First pass; see docs/omop_source_codes.md.")
AS
WITH distinct_responses AS (
  SELECT DISTINCT
    secondary_source_concept_id,
    source_question_concept_id,
    question_concept_id,
    response_value_as_string
  FROM `${PROJECT}.relational.responses`
  WHERE response_value_as_string IS NOT NULL AND response_value_as_string <> ''
)
SELECT
  -- ── THE ID: pure function of the four raw fields, nothing else ──
  TO_HEX(SHA256(CONCAT(
    COALESCE(d.secondary_source_concept_id, ''), '|',
    COALESCE(d.source_question_concept_id,  ''), '|',
    COALESCE(d.question_concept_id,         ''), '|',
    d.response_value_as_string
  ))) AS response_hash_id,

  -- the exact inputs, kept for audit / regeneration
  d.secondary_source_concept_id,
  d.source_question_concept_id,
  d.question_concept_id,
  d.response_value_as_string AS response_value_verbatim,

  -- ── DECORATION below — helpful, but DOES NOT affect response_hash_id (safe to change anytime) ──
  -- convenience classification for choosing what to send to Usagi (coded vs numeric vs free text)
  CASE
    WHEN qr.response_concept_id IS NOT NULL                                        THEN 'coded'
    WHEN SAFE_CAST(d.response_value_as_string AS FLOAT64) IS NOT NULL
      OR REGEXP_CONTAINS(d.response_value_as_string, r'^\d{4}-\d{2}-\d{2}')        THEN 'numeric_or_date'
    ELSE 'free_text'
  END AS response_kind,
  -- optional downstream grouping key for free text (NFC/trim/space/lowercase) — NOT hashed
  LOWER(REGEXP_REPLACE(NORMALIZE(TRIM(d.response_value_as_string), NFC), r'\s+', ' ')) AS value_norm,
  -- Usagi's source_code_description: coded -> question + answer label; else question + verbatim
  CONCAT(COALESCE(q.question_text, ''), ' | ',
         COALESCE(resp.format_value, d.response_value_as_string)) AS source_code_description
FROM distinct_responses d
LEFT JOIN `${PROJECT}.relational.question`          q    USING (question_concept_id)
LEFT JOIN `${PROJECT}.relational.question_response` qr
       ON qr.question_concept_id = d.question_concept_id
      AND qr.response_concept_id = d.response_value_as_string
LEFT JOIN `${PROJECT}.relational.response`          resp
       ON resp.response_concept_id = d.response_value_as_string;
