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
-- ┌─ response_custom_concept_id — the SAME id as an OMOP custom concept_id ────────────────────────────┐
-- │ OMOP reserves concept_id > 2,000,000,000 for custom (local) concepts, so the source code can also  │
-- │ live in the CONCEPT table as a faux custom concept. We need an INTEGER in that reserved range, so   │
-- │ we PROJECT the hash (never a new input, so it still can't drift):                                   │
-- │   response_custom_concept_id = 2000000001 + (first 15 hex chars of response_hash_id, base-16)       │
-- │ 15 hex chars = 60 bits -> [0, 2^60-1]; +2000000001 -> [2000000001, ~1.153e18]:                      │
-- │   integer ✓   strictly > 2,000,000,000 ✓   << 9,223,372,036,854,775,807 (signed-64 max) ✓          │
-- │ 15 (not 16) hex on purpose: 16 = 64 bits could exceed signed BIGINT and overflow on some engines.   │
-- │ Collision: two responses clash only if 60 hash bits match — ~N^2/2^61 (negligible for our N).       │
-- │ It is a pure function of response_hash_id, so the hex id stays the single source of truth.          │
-- └───────────────────────────────────────────────────────────────────────────────────────────────────┘
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
OPTIONS(description="Deterministic SHA-256 source codes for OMOP/Usagi mapping — one row per unique response. response_hash_id hashes ONLY raw stable inputs (secondary_source, source_question, question, response_value_as_string, '|'-joined, NULL->''), so it never drifts. response_custom_concept_id = 2000000001 + first-15-hex-of-hash (an integer in OMOP's custom-concept range >2e9, a pure projection of the hash). All other columns are decoration (never feed the hash). response_value_verbatim exposes free text -> govern as PII. First pass; see docs/omop_source_codes.md.")
AS
WITH distinct_responses AS (
  SELECT DISTINCT
    secondary_source_concept_id,
    source_question_concept_id,
    question_concept_id,
    response_value_as_string
  FROM `${PROJECT}.relational.responses`
  WHERE response_value_as_string IS NOT NULL AND response_value_as_string <> ''
),
hashed AS (
  SELECT
    -- ── THE ID: pure function of the four raw fields, nothing else ──
    TO_HEX(SHA256(CONCAT(
      COALESCE(d.secondary_source_concept_id, ''), '|',
      COALESCE(d.source_question_concept_id,  ''), '|',
      COALESCE(d.question_concept_id,         ''), '|',
      d.response_value_as_string
    ))) AS response_hash_id,
    d.secondary_source_concept_id,
    d.source_question_concept_id,
    d.question_concept_id,
    d.response_value_as_string
  FROM distinct_responses d
)
SELECT
  h.response_hash_id,

  -- ── THE SAME ID as an OMOP custom concept_id: integer, >2e9, <2^63-1 (see header block) ──
  -- Pure projection of response_hash_id: 2000000001 + base-16 value of its first 15 hex chars.
  -- Portable because the weights are powers of two (exact in FLOAT64/INT64); STRPOS maps each
  -- lowercase-hex nibble to 0..15. Recompute recipe + per-engine equivalents in the doc.
  2000000001 + (
    SELECT SUM(
      (STRPOS('0123456789abcdef', SUBSTR(h.response_hash_id, pos, 1)) - 1)
        * CAST(POW(16, 15 - pos) AS INT64)
    )
    FROM UNNEST(GENERATE_ARRAY(1, 15)) AS pos
  ) AS response_custom_concept_id,

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
