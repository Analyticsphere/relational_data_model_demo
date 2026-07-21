-- response_unique_id(secondary_source_concept_id, source_question_concept_id,
--                    question_concept_id, response_value_as_string)
--
-- Returns a stable INT64 identity for each unique response — one value per unique
-- (secondary_source | source_question | question | response_value) combination.
--
-- The integer is a pure projection of the SHA-256 hash of those four inputs:
--   response_unique_id = 2000000001 + (first 15 hex chars of SHA-256, read as base-16)
--
-- CANONICAL INPUT STRING — this is the one-time contract; never change it:
--   fields (in order): secondary_source_concept_id | source_question_concept_id |
--                      question_concept_id | response_value_as_string
--   NULL -> ''   delimiter -> '|'   encoding -> UTF-8   hash -> SHA-256 -> lowercase hex
--
-- OMOP: the result sits in the custom-concept range (concept_id > 2,000,000,000) and is
-- always < 9,223,372,036,854,775,807 (signed-64 max), so it doubles as a valid OMOP
-- custom concept_id.  See docs/omop_source_codes.md for the full derivation rationale.

CREATE OR REPLACE FUNCTION `${PROJECT}.relational.response_unique_id`(
  secondary_source_concept_id STRING,
  source_question_concept_id  STRING,
  question_concept_id         STRING,
  response_value_as_string    STRING
)
RETURNS INT64
AS (
  2000000001 + (
    SELECT SUM(
      (STRPOS('0123456789abcdef',
              SUBSTR(TO_HEX(SHA256(CONCAT(
                COALESCE(secondary_source_concept_id, ''), '|',
                COALESCE(source_question_concept_id,  ''), '|',
                COALESCE(question_concept_id,         ''), '|',
                COALESCE(response_value_as_string,    '')
              ))), pos, 1)) - 1)
      * CAST(POW(16, 15 - pos) AS INT64)
    )
    FROM UNNEST(GENERATE_ARRAY(1, 15)) AS pos
  )
);
