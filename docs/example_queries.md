# Example queries: wide → Phase 1 → Phase 2

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

### 🙂 Phase 1
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

### 😎 Phase 2
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
**Takeaway:** wide makes you hand-reshape and reconcile v1/v2; Phase 1 collapses that to a filtered group-by; Phase 2 makes it a plain distribution (or a one-line view).

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

### 🙂 Phase 1
```sql
-- Labels via join; swap the concept_id to run it for ANY question — one query, all questions.
SELECT resp.current_format_value AS answer, COUNT(*) AS n
FROM responses r
JOIN response resp USING (response_concept_id)
WHERE r.question_concept_id = 724589244
GROUP BY answer;
```

### 😎 Phase 2
```sql
-- Same join is prebuilt in the analytic layer / view library.
SELECT answer_label AS answer, n
FROM agg_question_distribution
WHERE question_concept_id = 724589244;
```
**Takeaway:** wide needs a bespoke `CASE` per question and can't be generalized; Phase 1 parameterizes by `concept_id`; Phase 2 reads a precomputed distribution.

> **Phase 1 add-on — one query across *all* questions of a type.** `question_type` rides along from the
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
> blank, miscased, or compound. Bounded to type only; typed-value parsing (generic `AVG()` etc.) is Phase 2.

---

## Q3 — "Among people who completed the survey, who actually answered question X?" (completion & true missingness)

The honest one: **Phase 1 does not fully solve this** — it has answers but no session/skip model, so a
missing answer is still ambiguous (not-shown vs. shown-but-skipped). This is a Phase-2 capability.

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

### 🙂 Phase 1
```sql
-- Better (answers are rows), but still no sessions/skip-logic → same ambiguity as wide:
-- "no row" could mean not-asked, not-answered, or survey-not-taken.
SELECT COUNT(*) AS answered_x
FROM responses
WHERE question_concept_id = /* X */ 0;     -- cannot classify the people WITHOUT a row
```

### 😎 Phase 2
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
**Takeaway:** wide and Phase 1 both leave missingness ambiguous; only Phase 2 (sessions + skip logic) answers "completed but didn't answer" correctly. A strong argument for funding Phase 2.

---

## Q4 — "Give a researcher only non-PHI answers" (governance)

Also Phase-2: neither wide nor Phase 1 carries sensitivity, so both rely on a hand-maintained allow-list.

### 😖 Wide
```sql
-- No sensitivity in the schema. The analyst hand-picks "safe" columns from an external list —
-- error-prone, per-table, and unenforced.
SELECT Connect_ID, d_724589244 /* …only columns someone vetted as non-PHI… */
FROM `CleanConnect.mouthwash`;
```

### 🙂 Phase 1
```sql
-- Still no classification; same manual allow-list, now over question_concept_ids.
SELECT * FROM responses
WHERE question_concept_id IN ( /* hand-maintained non-PHI concept list */ );
```

### 😎 Phase 2
```sql
-- Sensitivity is data on every row; a BigQuery row-access policy enforces it, so the researcher's
-- query is unchanged and PHI simply isn't returned for their role.
SELECT * FROM responses WHERE sensitivity_tier = 'non_sensitive';
-- For external sharing, the researcher queries the de-identified release tier (date-shifted/masked)
-- and never sees Core; access is governed by IAM, not by remembering an allow-list.
```
**Takeaway:** wide and Phase 1 make governance a manual convention; Phase 2 makes it data + enforced by IAM — the prerequisite for sharing externally through PR2.

---

## Summary

| Query | Wide | Phase 1 | Phase 2 |
|---|---|---|---|
| Multi-select distribution | 😖 unpivot + v1/v2 COALESCE + known columns | 🙂 filtered group-by, versions pool | 😎 plain group-by / view |
| Distribution with labels, any question | 😖 bespoke `CASE`, no reuse | 🙂 parameterized by `concept_id` | 😎 precomputed aggregate |
| Completion & true missingness | 😖 cross-table, ambiguous | 😖 still ambiguous (no sessions) | 😎 sessions + skip logic |
| Non-PHI extract (governance) | 😖 manual allow-list | 😖 manual allow-list | 😎 sensitivity tier + IAM |

Phase 1 turns "effectively unqueryable" into "queryable and labeled" and pools version drift — a real win
on the first two rows. Phase 2 is what makes the bottom two rows (missingness, governance) possible at all —
the capabilities that make PR2 a trustworthy, shareable research warehouse.
