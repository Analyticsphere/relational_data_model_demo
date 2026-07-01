# Example queries: wide tables → the model

The same standard analyst questions, written against each model. Concept IDs are real (from the
[data dictionary](https://raw.githubusercontent.com/episphere/conceptGithubActions/refs/heads/master/csv/masterFile.csv));
table names and value encodings are illustrative of CleanConnect conventions. The point is the **shape** of
the SQL, not exact identifiers.

Worked example throughout: the mouthwash survey's tooth-loss select-all
(`899251483` "Have you lost any permanent teeth? Select all that apply") with options
`812107266` accident · `452438775` tooth decay · `886864375` other reason · `551489317` "No" (v2) ·
`104430631` "No" (v1, deprecated); and its follow-up single-select `724589244` "How many teeth lost?".

Legend: 😖 challenging · 🙂 easier · 😎 breezy

---

## Q1 — "How many people selected each reason for tooth loss?" (multi-select distribution)

### 😖 Wide
```sql
-- One indicator column per option, DOUBLED across the v1/v2 revision; unpivot + COALESCE by hand,
-- and you must already know every option column AND that 886864375 ("other") is v2-only.
SELECT reason, COUNTIF(sel = '353358909') AS n          -- 353358909 = "Yes" (selected)
FROM (
  SELECT 'accident'    AS reason, COALESCE(d_899251483_d_812107266_v2, d_899251483_d_812107266) AS sel
  FROM `CleanConnect.mouthwash`
  UNION ALL SELECT 'tooth decay',  COALESCE(d_899251483_d_452438775_v2, d_899251483_d_452438775)
  FROM `CleanConnect.mouthwash`
  UNION ALL SELECT 'other reason', d_899251483_d_886864375_v2     -- no v1 column exists
  FROM `CleanConnect.mouthwash`
)
GROUP BY reason;
```

### 🙂 The model
```sql
-- One table, no column enumeration. Labels via join. v1/v2 columns both unpivoted to the same
-- question_concept_id, so the revision pools automatically (no COALESCE).
SELECT q.current_question_text AS reason, COUNT(*) AS n
FROM responses r
JOIN question q USING (question_concept_id)
WHERE r.current_source_question_concept_id = 899251483   -- the select-all group
  AND r.response_concept_id = 353358909                  -- "Yes" (selected)
GROUP BY reason;
```

### 😎 With enhancements
```sql
-- Multi-select = one row per selected option; just GROUP BY the option. No binary filter,
-- no version thinking (it's an attribute), offered-set is known.
SELECT o.label AS reason, COUNT(*) AS n
FROM responses r
JOIN survey_questions sq ON sq.survey_question_id = r.survey_question_id
JOIN response_options o  ON o.question_concept_id = sq.question_concept_id
                        AND o.response_concept_id = r.response_concept_id
WHERE sq.question_concept_id = 899251483
GROUP BY reason;
-- …or simply:  SELECT label, n FROM v_select_all WHERE question = 'tooth_loss_reason';
```
**Takeaway:** wide makes you hand-reshape and reconcile v1/v2; the model collapses that to a filtered group-by (versions pool automatically once the version-handling enhancement lands).

---

## Q2 — "Answer distribution for a question, with human-readable labels" (genericity)

Using the single-select follow-up `724589244` ("How many teeth lost?").

### 😖 Wide
```sql
-- Hardcode the value→label map for THIS question; nothing generalizes to other questions.
SELECT CASE d_724589244
         WHEN '349122068' THEN '1'        WHEN '194129782' THEN '2 to 4'
         WHEN '922737557' THEN '5 to 9'   WHEN '945387130' THEN '10 or more'
         WHEN '383505459' THEN 'More than one, unsure' WHEN '832322940' THEN "Don't know"
       END AS answer,
       COUNT(*) AS n
FROM `CleanConnect.mouthwash`
GROUP BY answer;
```

### 🙂 The model
```sql
-- Labels via join; swap the concept_id to run it for ANY question — one query, all questions.
SELECT resp.current_format_value AS answer, COUNT(*) AS n
FROM responses r
JOIN response resp USING (response_concept_id)
WHERE r.question_concept_id = 724589244
GROUP BY answer;
```

### 😎 With enhancements
```sql
-- Same join is prebuilt in the analytic layer / view library.
SELECT answer_label AS answer, n
FROM agg_question_distribution
WHERE question_concept_id = 724589244;
```
**Takeaway:** wide needs a bespoke `CASE` per question and can't be generalized; the model parameterizes by `concept_id` (a precomputed aggregate is a downstream-mart enhancement).

> **With the normalized question-type view (enhancement #1) — one query across *all* questions of a type.** `question_type` rides along from the
> dictionary, but its raw values are inconsistent (partial coverage, casing, typos, compound strings). A thin
> derived `question_type_norm` view (messy string → clean `base_type` + flags, backfilled from Quest) lets a
> single query span every question of a type — the "common abstraction" goal:
> ```sql
> SELECT t.base_type, r.question_concept_id, resp.current_format_value AS answer, COUNT(*) AS n
> FROM responses r
> JOIN question_type_norm t USING (question_concept_id)
> JOIN response resp        USING (response_concept_id)
> WHERE t.base_type = 'single_select'
> GROUP BY t.base_type, r.question_concept_id, answer;
> ```
> Without normalization, `WHERE question_type = 'single_select'` silently drops questions whose type cell was
> blank, miscased, or compound. Bounded to type only; typed-value parsing (generic `AVG()` etc.) is the typed-value-columns enhancement (#2).

---

## Q3 — "Among people who completed the survey, who actually answered question X?" (completion & true missingness)

The honest one: **the base model does not fully solve this** — it has answers but no session/skip model, so a
missing answer is still ambiguous (not-shown vs. shown-but-skipped). This needs the **sessions + skip_logic** enhancement.

### 😖 Wide
```sql
-- Completion flag lives in participants; the answer lives in the survey table (join on Connect_ID).
-- A NULL answer cannot distinguish "not shown (skip logic)" from "shown but left blank".
SELECT
  COUNTIF(p.d_949302066 = '231311385') AS submitted_m1,                         -- status = Submitted
  COUNTIF(p.d_949302066 = '231311385' AND m.d_QUESTION_X IS NOT NULL) AS answered_x
FROM `CleanConnect.participants` p
LEFT JOIN `CleanConnect.module1` m USING (Connect_ID);
```

### 🙂 The model
```sql
-- Better (answers are rows), but still no sessions/skip-logic → same ambiguity as wide:
-- "no row" could mean not-asked, not-answered, or survey-not-taken.
SELECT COUNT(*) AS answered_x
FROM responses
WHERE question_concept_id = /* X */ 0;     -- cannot classify the people WITHOUT a row
```

### 😎 With enhancements
```sql
-- Sessions give status + timing; skip_logic gives reachability. Missingness becomes classifiable.
SELECT
  s.status,
  COUNT(DISTINCT s.connect_id)                                          AS participants,
  COUNT(DISTINCT IF(r.response_id IS NOT NULL, s.connect_id, NULL))     AS answered_x
FROM response_sessions s
JOIN survey_questions sq ON sq.question_concept_id = /* X */ 0
LEFT JOIN responses r    ON r.session_id = s.session_id
                        AND r.survey_question_id = sq.survey_question_id
WHERE s.survey_id = /* Module 1 */ 0 AND s.wave = 'baseline'
GROUP BY s.status;
-- + join skip_logic to separate "not shown by design" from "shown but skipped".
```
**Takeaway:** wide and the base model both leave missingness ambiguous; only the **sessions + skip_logic** enhancement answers "completed but didn't answer" correctly — a strong reason to prioritize it.

---

## Q4 — "Give a researcher only non-PHI answers" (governance)

Neither wide nor the base model carries sensitivity, so both rely on a hand-maintained allow-list — this needs the **governance** enhancement (#7).

### 😖 Wide
```sql
-- No sensitivity in the schema. The analyst hand-picks "safe" columns from an external list —
-- error-prone, per-table, and unenforced.
SELECT Connect_ID, d_724589244 /* …only columns someone vetted as non-PHI… */
FROM `CleanConnect.mouthwash`;
```

### 🙂 The model
```sql
-- Still no classification; same manual allow-list, now over question_concept_ids.
SELECT * FROM responses
WHERE question_concept_id IN ( /* hand-maintained non-PHI concept list */ );
```

### 😎 With enhancements
```sql
-- Sensitivity is data on every row; a BigQuery row-access policy enforces it, so the researcher's
-- query is unchanged and PHI simply isn't returned for their role.
SELECT * FROM responses WHERE sensitivity_tier = 'non_sensitive';
-- For external sharing, the researcher queries the de-identified release tier (date-shifted/masked)
-- and never sees Core; access is governed by IAM, not by remembering an allow-list.
```
**Takeaway:** wide and the base model make governance a manual convention; the **governance** enhancement makes it data + enforced by IAM — the prerequisite for sharing externally through PR2.

---

## Q5 — "For a given answer, reconstruct its full hierarchy: domain → survey → source-question → question → response"

The dictionary is a tree (`Primary → Secondary → Source Question → Question → Response`). Given one answer, name every level it sits under.

### 😖 Wide
```sql
-- There is no hierarchy in the data — it's encoded in the table you queried and the column name.
-- To name the levels you leave SQL and look each concept id up in the dictionary CSV by hand:
--   table  = CleanConnect.mouthwash       -> the survey
--   column = d_899251483_d_812107266_v2    -> source-question 899251483 · option 812107266 · rev v2
SELECT d_899251483_d_812107266_v2 FROM `CleanConnect.mouthwash` WHERE Connect_ID = @id;
```

### 🙂 The model
```sql
-- Every level is one join away. The survey (and therefore the domain) is read from the fact's
-- STAMPED secondary_source_concept_id — NOT via question.secondary_source_concept_id, which would
-- pick the single "home" survey and mislabel a reused concept.
SELECT
  ps.primary_source        AS domain,           -- e.g. Survey
  ss.secondary_source      AS survey,           -- e.g. Mouthwash
  sq.source_question_text  AS source_question,  -- NULL when the question is standalone
  q.current_question_text  AS question,
  COALESCE(resp.current_format_value, r.value) AS answer
FROM responses r
JOIN secondary_source ss     USING (secondary_source_concept_id)    -- survey  (stamped on the fact)
JOIN primary_source  ps      USING (primary_source_concept_id)      -- domain  (follows by FK)
LEFT JOIN source_question sq USING (current_source_question_concept_id)
JOIN question q              USING (question_concept_id)
LEFT JOIN response resp      USING (response_concept_id)            -- NULL for free-text / numeric answers
WHERE r.response_row_id = @row;
```

### 😎 With enhancements
```sql
-- The placement (survey_questions) already encodes the whole path; the survey's domain is an attribute.
SELECT
  s.domain,
  s.name                 AS survey,
  parent.label           AS source_question,    -- the parent placement; NULL when top-level
  q.label                AS question,
  COALESCE(o.label, r.value_string, CAST(r.value_number AS STRING)) AS answer
FROM responses r
JOIN survey_questions sq     ON sq.survey_question_id = r.survey_question_id
JOIN survey_versions sv      ON sv.survey_version_id  = sq.survey_version_id
JOIN surveys s               ON s.survey_id           = sv.survey_id
JOIN questions q             ON q.question_concept_id = sq.question_concept_id
LEFT JOIN questions parent   ON parent.question_concept_id = sq.parent_question_concept_id
LEFT JOIN response_options o ON o.question_concept_id = sq.question_concept_id
                            AND o.response_concept_id = r.response_concept_id
WHERE r.response_id = @row;
```
**Takeaway:** wide hides the hierarchy in column names (a manual dictionary lookup); the model makes every level a join and reads the survey straight off the fact.

---

## Q6 — "Filter to exactly the slice you want"

The hierarchy coordinates on each `responses` row are your filter knobs — pick a level, constrain it, mix and match.

### 😖 Wide
```sql
-- "Filtering" means knowing which column in which table holds what you want, by name. Pooling one
-- question across surveys is impossible — each survey is a different table with a differently-named column.
SELECT Connect_ID, d_899251483_d_812107266_v2
FROM `CleanConnect.mouthwash`
WHERE d_899251483_d_812107266_v2 = '353358909';     -- and repeat, per table, for every other survey
```

### 🙂 The model
```sql
-- One table; each coordinate is an optional WHERE knob. Drop a line to widen the slice.
SELECT *
FROM responses r
WHERE secondary_source_concept_id     = 390351864     -- survey      = Mouthwash
  AND current_source_question_concept_id = 899251483   -- group       = tooth-loss select-all
  AND question_concept_id             = 812107266      -- sub-question= "accident"
  AND response_concept_id             = 353358909      -- answer      = "Yes"
  AND loop_instance                   = 1;             -- loop iter   (default 1)
```

| To get… | Filter |
|---|---|
| Everything in one **survey** | `secondary_source_concept_id = 390351864` |
| Everything in a whole **domain** | `JOIN secondary_source ss USING (secondary_source_concept_id)` → `WHERE ss.primary_source_concept_id = 129084651` (Survey) |
| One **question, pooled across every survey** it appears in | `question_concept_id = 784119588` ("Survey Language", all 15 instruments) |
| **The payoff** — that shared question, but only **in one survey** | `question_concept_id = 784119588 AND secondary_source_concept_id = 390351864` |
| A whole **grid / select-all group** | `current_source_question_concept_id = 899251483` |
| A specific **loop iteration** | `question_concept_id = 206625031 AND loop_instance = 3` |

The fourth row is the one the wide model and verbatim dictionary cannot do: isolating a deliberately-reused concept to a single survey is only possible because the survey is stamped on the fact.

### 😎 With enhancements
```sql
-- Same coordinates, resolved through the placement — or a named view.
SELECT r.*
FROM responses r
JOIN survey_questions sq ON sq.survey_question_id = r.survey_question_id
JOIN survey_versions sv  ON sv.survey_version_id  = sq.survey_version_id
WHERE sq.question_concept_id = 812107266
  AND sv.survey_id = 390351864;        -- one survey
-- or simply:  SELECT * FROM v_select_all WHERE survey = 'mouthwash' AND question = 'tooth_loss_reason';
```
**Takeaway:** wide forces you to know columns and can't pool across surveys; the model turns each hierarchy level into a filter knob — including slicing a reused concept to one survey (named views over these are a downstream convenience).

---

## Convenience view — *zero* joins for the analyst

The queries above show labels are "one join away." We can make it **zero joins** by shipping a denormalized view that pre-joins the dictionary onto `responses` — every answer row arrives self-describing. This is the most tangible day-one win for analysts (a convenience view over the model).

```sql
-- Built once, over the verbatim dictionary tables. Survey/domain come from the STAMPED
-- secondary_source_concept_id on the row (so reused concepts resolve to the right survey),
-- not from the question. All LEFT JOINs so an answer never drops out.
CREATE OR REPLACE VIEW v_responses_enriched AS
SELECT
  r.response_row_id, r.connect_id,
  ps.primary_source        AS domain,
  ss.secondary_source      AS survey,
  sq.source_question_text  AS source_question,
  q.current_question_text  AS question_text,
  q.question_type,
  r.loop_instance,
  r.response_concept_id,
  resp.current_format_value AS response_label,   -- "1 = Yes"
  r.value                   AS response_value,    -- free-text / numeric
  vm.pii, vm.variable_type, vm.variable_label,
  opt.response_option_set,                         -- the full offered menu for this question
  r.question_concept_id, r.secondary_source_concept_id,
  r.current_source_question_concept_id, r.source_table, r.source_column   -- provenance kept
FROM responses r
LEFT JOIN secondary_source  ss   ON ss.secondary_source_concept_id        = r.secondary_source_concept_id
LEFT JOIN primary_source    ps   ON ps.primary_source_concept_id          = ss.primary_source_concept_id
LEFT JOIN question          q    ON q.question_concept_id                 = r.question_concept_id
LEFT JOIN source_question   sq   ON sq.current_source_question_concept_id = r.current_source_question_concept_id
LEFT JOIN response          resp ON resp.response_concept_id              = r.response_concept_id
LEFT JOIN variable_metadata vm   ON vm.question_concept_id         = r.question_concept_id
                                AND vm.secondary_source_concept_id = r.secondary_source_concept_id
                                AND vm.response_concept_id         = r.response_concept_id
-- offered option set per question: aggregate the allowed-answers bridge into one string
LEFT JOIN (
  SELECT qr.question_concept_id,
         STRING_AGG(o.current_format_value, '; ' ORDER BY qr.response_concept_id) AS response_option_set
  FROM question_response qr
  LEFT JOIN response o ON o.response_concept_id = qr.response_concept_id
  GROUP BY qr.question_concept_id
) opt ON opt.question_concept_id = r.question_concept_id;
```

The analyst then never sees a concept ID unless they want one:
```sql
SELECT survey, question_text, response_label, COUNT(*) AS n
FROM v_responses_enriched
WHERE question_concept_id = 724589244          -- "How many teeth lost?"
GROUP BY survey, question_text, response_label;
```

**Notes:** grain stays one-row-per-answer (driven from `responses` outward → no fan-out — `opt` and `vm` are each ≤1 row per question/key); if the dictionary has dupes, dedupe `vm` in a CTE first. `response_option_set` shows the **offered menu** for the question (e.g. `"0 = No; 1 = Yes"`), independent of what the participant picked (`response_label`) — handy for select-all interpretation and for seeing valid values inline. Its caveats: it comes from the `question_response` allowed-answers bridge (imperfect — e.g. tooth-loss lists the "No" *value* concept as an option), and ordering is by `response_concept_id` since the model has no `display_order` (a version-handling enhancement via `response_options`). It's a convenience surface, not the contract — raw `responses` + the dictionary stay reachable.

---

## Summary

| Query | Wide (today) | The model | With enhancements |
|---|---|---|---|
| Multi-select distribution | 😖 unpivot + v1/v2 COALESCE + known columns | 🙂 filtered group-by, versions pool | 😎 plain group-by / view |
| Distribution with labels, any question | 😖 bespoke `CASE`, no reuse | 🙂 parameterized by `concept_id` | 😎 precomputed aggregate |
| Completion & true missingness | 😖 cross-table, ambiguous | 😖 still ambiguous (no sessions) | 😎 sessions + skip logic |
| Non-PHI extract (governance) | 😖 manual allow-list | 😖 manual allow-list | 😎 sensitivity tier + IAM |
| Reconstruct full hierarchy for an answer | 😖 parse column name + manual dictionary lookup | 🙂 every level one join, survey off the fact | 😎 placement carries the path |
| Filter to a slice (incl. reused concept in one survey) | 😖 know columns; can't pool across surveys | 🙂 hierarchy coordinates as filter knobs | 😎 same knobs via placement / views |

The model turns "effectively unqueryable" into "queryable and labeled": it pools version drift, parameterizes
by `concept_id`, reconstructs the full hierarchy by joins, and turns every hierarchy level into a filter knob
— including the slice the wide tables simply can't do, isolating a deliberately-reused concept to one survey.
The sessions and governance enhancements are what make missingness and access-control possible at all — the capabilities that make PR2 a
trustworthy, shareable research warehouse.
