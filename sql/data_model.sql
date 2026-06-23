-- ============================================================================
-- Connect Relational Data Model — Phase 2 "Functional model" (Model B, v0)
-- SQL DDL for ERD generation. Generated from data_model.dbml.
--
-- Import into draw.io:  Insert "+" menu > Advanced > From SQL...  (then edit/export PNG)
-- Plain column lists only (no FK/key constraints) — draw relationships by hand.
-- ============================================================================

CREATE TABLE participants (
  connect_id          INT PRIMARY KEY,
  enrollment_status   TEXT
);

-- = dictionary Secondary Source (instrument/section)
CREATE TABLE surveys (
  survey_id                   INT PRIMARY KEY,
  name                        TEXT,
  secondary_source_concept_id INT,
  domain                      TEXT
);

-- decomposed from the dirty dictionary "Question Type"
CREATE TABLE question_types (
  question_type_id    INT PRIMARY KEY,
  base_type           TEXT,
  has_loop            BOOLEAN,
  has_displayif       BOOLEAN,
  is_required         BOOLEAN,
  has_text_box        BOOLEAN
);

CREATE TABLE survey_versions (
  survey_version_id   INT PRIMARY KEY,
  survey_id           INT,
  version             TEXT
);

-- one per participant x survey administration; derived from participants metadata triad
CREATE TABLE response_sessions (
  session_id          INT PRIMARY KEY,
  connect_id          INT,
  survey_id           INT,
  wave                TEXT,
  status              TEXT,
  started_at          TIMESTAMP,
  completed_at        TIMESTAMP
);

-- reusable concept bank: one row per question concept (the spine)
CREATE TABLE questions (
  question_concept_id INT PRIMARY KEY,
  label               TEXT,
  question_type_id    INT,
  variable_type       TEXT,
  numeric_min         DOUBLE PRECISION,
  numeric_max         DOUBLE PRECISION,
  pii                 BOOLEAN,
  sensitivity_tier    TEXT
);

-- offered option set PER question-version (response concepts global/reused)
CREATE TABLE response_options (
  option_id                       INT PRIMARY KEY,
  question_concept_id             INT,
  concept_version                 TEXT,
  response_concept_id             INT,
  label                           TEXT,
  value                           TEXT,
  display_order                   INT,
  is_other                        BOOLEAN,
  status                          TEXT,
  status_date                     DATE,
  replaced_by_response_concept_id INT,
  pii                             BOOLEAN,
  sensitivity_tier                TEXT
);

-- bridge/placement: a question concept placed in a version, under a parent
CREATE TABLE survey_questions (
  survey_question_id          INT PRIMARY KEY,
  survey_version_id           INT,
  question_concept_id         INT,
  parent_question_concept_id  INT,
  concept_version             TEXT,
  display_order               INT,
  is_required                 BOOLEAN,
  is_looped                   BOOLEAN,
  loop_max                    INT,
  gcp_document_table          TEXT,
  source_column               TEXT
);

-- structured branching (QuickQ skip_rule shape) from Quest displayif / -> target
CREATE TABLE skip_logic (
  skip_logic_id               INT PRIMARY KEY,
  survey_version_id           INT,
  target_question_concept_id  INT,
  enable_behavior             TEXT,
  trigger_question_concept_id INT,
  operator                    TEXT,
  trigger_value               TEXT,
  trigger_default_value       TEXT,
  action                      TEXT,
  raw_expression              TEXT
);

-- long/narrow fact: one row per answer atom
CREATE TABLE responses (
  response_id         INT PRIMARY KEY,
  session_id          INT,
  survey_question_id  INT,
  loop_instance       INT,
  response_concept_id INT,
  value_string        TEXT,
  value_number        DOUBLE PRECISION,
  value_date          DATE,
  sensitivity_tier    TEXT,
  source_table        TEXT,
  source_column       TEXT
);

-- OPTIONAL (gated): per-(session x placement) reach/answer marker for missingness.
-- DERIVED (session status x skip_logic, corroborated by source 0-vs-NULL); lets "reached but
-- selected none" be answered. Gated on verifying the flattener writes NULL (not 0) for unreached.
CREATE TABLE session_questions (
  session_id          INT,
  survey_question_id  INT,
  reached             BOOLEAN,   -- placement presented/reachable in this administration
  answered            BOOLEAN    -- a `responses` row existed for it
);

-- OFF-SCREEN: biospecimen, recruitment, etc. event facts (out of scope for this view)
CREATE TABLE other_event_tables (
  connect_id          INT,
  event_type          TEXT,
  event_at            TIMESTAMP
);
