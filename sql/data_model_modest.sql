-- ============================================================================
-- Connect Relational Data Model — Phase 1 "Dictionary-Direct" (Model A)
-- SQL DDL for ERD generation. Generated from data_model_modest.dbml.
--
-- Import into draw.io:  Insert "+" menu > Advanced > From SQL...  (then edit/export PNG)
-- Plain column lists only (no FK/key constraints) — draw relationships by hand.
-- ============================================================================

-- CIDTool dictionary, loaded as emitted
CREATE TABLE primary_source (
  primary_source_concept_id   INT PRIMARY KEY,
  primary_source              TEXT
);

CREATE TABLE source_question (
  current_source_question_concept_id INT PRIMARY KEY,
  source_question_text        TEXT,
  v1_source_question          TEXT,
  grid_source_question_name   TEXT
);

CREATE TABLE secondary_source (
  secondary_source_concept_id INT PRIMARY KEY,
  secondary_source            TEXT,
  primary_source_concept_id   INT
);

CREATE TABLE question (
  question_concept_id                 INT PRIMARY KEY,
  current_source_question_concept_id  INT,
  secondary_source_concept_id         INT,
  current_question_text               TEXT,
  question_type                       TEXT
);

CREATE TABLE response (
  response_concept_id         INT PRIMARY KEY,
  current_format_value        TEXT
);

-- the QUESTION.response_concept_id "list" FK, as a bridge (allowed answers)
CREATE TABLE question_response (
  question_concept_id         INT,
  response_concept_id         INT
);

-- one row per variable; compound key across the 5 concept ids
CREATE TABLE variable_metadata (
  primary_source_concept_id           INT,
  secondary_source_concept_id         INT,
  current_source_question_concept_id  INT,
  question_concept_id                 INT,
  response_concept_id                 INT,
  variable_label              TEXT,
  variable_type               TEXT,
  variable_length             INT,
  pii                         BOOLEAN,
  skip_logic                  TEXT,
  deprecated_new_or_revised   TEXT,
  derivation_notes            TEXT,
  gcp_document_table          TEXT
);

-- the ONE new table: long-format responses that joins to the dictionary
CREATE TABLE responses (
  response_row_id                     INT PRIMARY KEY,
  connect_id                          INT,
  secondary_source_concept_id         INT,
  question_concept_id                 INT,
  current_source_question_concept_id  INT,
  loop_instance                       INT,
  response_concept_id                 INT,
  value                               TEXT,
  source_table                        TEXT,
  source_column                       TEXT
);
