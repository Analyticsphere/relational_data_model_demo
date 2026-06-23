-- ============================================================================
-- Connect Event Plane — DRAFT (pending DevOps confirmation of Round-as-encounter)
-- SQL DDL for ERD generation. Generated from data_model_events.dbml.
--
-- Import into draw.io:  Insert "+" menu > Advanced > From SQL...  (then edit/export PNG)
-- Plain column lists only (no FK/key constraints) — draw relationships by hand.
-- Round = the encounter/visit; surveys + collection/kit/incentive/refusal events
-- hang off (connect_id, round).
-- ============================================================================

CREATE TABLE participants (
  connect_id          INT PRIMARY KEY
);

-- = DevOps "activities"; the encounter / visit (~ OMOP visit_occurrence)
CREATE TABLE rounds (
  round_id            INT PRIMARY KEY,
  connect_id          INT,
  round_code          TEXT,
  activity_type       TEXT,
  created_at          DATE
);

-- = DevOps "surveys" table; one per participant x survey administration
CREATE TABLE response_sessions (
  session_id          INT PRIMARY KEY,
  round_id            INT,
  connect_id          INT,
  survey_concept_id   INT,
  status_concept_id   INT,
  started_at          TIMESTAMP,
  completed_at        TIMESTAMP
);

-- survey answers (the module model) attach to the session
CREATE TABLE responses (
  response_id         INT PRIMARY KEY,
  session_id          INT,
  survey_question_id  INT,
  response_concept_id INT
);

-- = DevOps collections + collectionDetails
CREATE TABLE collection_events (
  collection_id       INT PRIMARY KEY,
  round_id            INT,
  specimen_concept_id INT,
  status_concept_id   INT,
  setting_concept_id  INT,
  location_concept_id INT,
  collected_at        DATE,
  accession_id        TEXT,
  sensitivity_tier    TEXT
);

-- = DevOps kits
CREATE TABLE kit_events (
  kit_id              INT PRIMARY KEY,
  round_id            INT,
  kit_type_concept_id INT,
  status_concept_id   INT,
  shipped_at          DATE,
  received_at         DATE
);

-- = DevOps incentives
CREATE TABLE incentive_events (
  incentive_id              INT PRIMARY KEY,
  round_id                  INT,
  payment_status_concept_id INT,
  payment_type_concept_id   INT,
  eligible_at               DATE,
  issued_at                 DATE
);

-- = DevOps refusals
CREATE TABLE refusal_events (
  refusal_id              INT PRIMARY KEY,
  round_id                INT,
  refusal_type_concept_id INT,
  status_concept_id       INT,
  refused_at              DATE,
  reason                  TEXT
);

-- ANALYTIC VIEW = the SMDB Participant Summary (UNION of all event facts + sessions).
-- A view in practice; emitted as a table only so the diagram renders it.
CREATE TABLE v_participant_events (
  connect_id          INT,
  round_id            INT,
  category            TEXT,
  item_concept_id     INT,
  status_concept_id   INT,
  event_date          DATE
);
