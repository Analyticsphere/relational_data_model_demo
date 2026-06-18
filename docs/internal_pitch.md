# Connect Data Model — Internal Pitch

**The ask:** build a relational layer over CleanConnect that stores survey answers in one long `responses`
table joined to the dictionary — in two phases. **Phase 1** is a small, fast win we can ship now; **Phase 2**
is the researcher-grade, governed warehouse PR2 needs.

---

## Why — the problems we all live with

Our analysis-ready data is wide tables of opaque concept-ID columns. Concretely:

- **Dancing schema** — every new answer, option, or loop instance adds columns; downstream queries, views, and pipelines break as the upstream app evolves.
- **Not generically queryable** — every analysis hardcodes column names; nothing reuses across questions or surveys.
- **Version drift** — a revised question leaves parallel `v1`/`v2` columns analysts reconcile by hand.
- **Ambiguous missingness** — a blank cell could mean *not selected*, *not shown* (skip logic), or *survey not taken*.
- **No built-in governance** — sensitivity (PHI/PII) isn't in the schema; access is a manual, unenforced column allow-list.

## The idea

Stop encoding answers as columns; store them as **rows** in a long `responses` table, and let the
**dictionary we already maintain** (`primary_source`, `secondary_source`, `question`, `response`,
`variable_metadata`) be the joinable metadata. Same thesis both phases — Phase 1 proves it cheaply,
Phase 2 builds it out.

---

## Phase 1 — Dictionary-Direct (start here)

<picture><source media="(prefers-color-scheme: dark)" srcset="connect_model_a_overview_dark.svg"><img alt="Model A overview" src="connect_model_a_overview.svg"></picture>

<details><summary>Full Phase 1 model (all columns) — the dictionary as-is, arranged like the CIDTool ERD, plus <code>responses</code></summary>

<picture><source media="(prefers-color-scheme: dark)" srcset="connect_model_a_dark.svg"><img alt="Model A full ERD with all columns" src="connect_model_a.svg"></picture>

</details>

- **What it is:** the CIDTool dictionary tables loaded **as-is**, plus **one** new table — `responses`
  (`connect_id × question_concept_id × current_source_question_concept_id × loop_instance → response_concept_id / value`). Optional thin `question_type_norm` view for clean per-type SQL.
- **The lift — small:**
  1. Load CIDTool output into BigQuery (we already produce it).
  2. One **metadata-driven UNPIVOT** from CleanConnect → `responses`, generated per survey from the dictionary's column→concept map.
  3. *(optional)* `question_type_norm` view: messy `question_type` → clean `base_type` + flags.
  - No new modeling, reuses CleanConnect + the dictionary verbatim, low risk.
- **What it buys:** stable schema (dancing stops), **generic SQL by `concept_id`/type**, labels one join away, **v1/v2 pool automatically** (both unpivot to the same concept), one answers table across all surveys.
- **What it does *not* buy (→ Phase 2):** governance, sessions/missingness, clean reused-concept integrity, version/option-set unification, curated marts + lineage, researcher-facing naming. Multi-select/grids stay as the dictionary's binary 0/1 sub-question rows.
- **Important:** with no access control, Phase 1 is **not externally release-ready** — it's an internal/analyst layer (or coarse dataset-level IAM) until Phase 2.

## Phase 2 — Functional model (the PR2 warehouse)

<picture><source media="(prefers-color-scheme: dark)" srcset="connect_data_model_overview_dark.svg"><img alt="Model B overview" src="connect_data_model_overview.svg"></picture>

<details><summary>Full Phase 2 model (all columns)</summary>

<picture><source media="(prefers-color-scheme: dark)" srcset="connect_data_model_dark.svg"><img alt="Model B full ERD with all columns" src="connect_data_model.svg"></picture>

</details>

- **What it adds:** cleaned researcher-facing dimensions; a **placement bridge** (`survey_questions`) so reused concepts and grids/select-all resolve cleanly; **sessions** (`response_sessions`, derived from participant status/timing) for completion + missingness; **version-scoped `response_options`**; layered **Core → Analytic → Marts**; governance built in.
- **The lift — larger, but incremental on Phase 1's `responses` fact, and phaseable:**
  - dimension cleanup + type normalization + placement/session derivation;
  - **governance**: `sensitivity_tier` classification → BigQuery **row-access policies** → three **release tiers** (Sensitive / Core / Public) with date-shift, masking, and cell-size suppression;
  - **analytic layer**: `fact_response`, dimensions, aggregates, a question-type **view library**;
  - **curated marts** with full lineage (dbt proposed).
- **What it buys:** tidy multi-select, version/option validity, **true missingness**, **governed per-sensitivity access**, reproducible derived variables with lineage, and a shareable query/view library — the trustworthy contract PR2 needs to share with the research community.

---

## Value proposition — the same queries, three ways

| Standard query | Wide (today) | Phase 1 | Phase 2 |
|---|---|---|---|
| Multi-select distribution | unpivot + v1/v2 COALESCE + known columns | filtered group-by; versions pool | plain group-by / view |
| Labeled distribution, *any* question | bespoke `CASE`, no reuse | parameterized by `concept_id` (+ type view) | precomputed aggregate |
| Completion & **true** missingness | cross-table, ambiguous | still ambiguous (no sessions) | sessions + skip logic |
| Non-PHI extract (**governance**) | manual allow-list | manual allow-list | sensitivity tier + IAM |

Phase 1 flips the top two from *painful/impossible* to *routine*; Phase 2 makes the bottom two —
missingness and governance — possible at all. Worked SQL below (example concept IDs from the tooth-loss
select-all `899251483` and its follow-up `724589244`).

### Q1 — distribution of a multi-select ("reasons for tooth loss")
```sql
-- WIDE: unpivot one indicator column per option, doubled across v1/v2, COALESCE'd by hand
SELECT 'accident' AS reason, COUNTIF(COALESCE(d_899251483_d_812107266_v2, d_899251483_d_812107266)='353358909') n
FROM `CleanConnect.mouthwash`
UNION ALL SELECT 'tooth decay', COUNTIF(COALESCE(d_899251483_d_452438775_v2, d_899251483_d_452438775)='353358909')
FROM `CleanConnect.mouthwash`;   -- …and you must know every option column + the v2-only ones

-- PHASE 1: one table, labels via join, v1/v2 pool automatically
SELECT q.current_question_text AS reason, COUNT(*) n
FROM responses r JOIN question q USING (question_concept_id)
WHERE r.current_source_question_concept_id = 899251483 AND r.response_concept_id = 353358909
GROUP BY reason;

-- PHASE 2: one row per selected option — a plain group-by
SELECT o.label AS reason, COUNT(*) n
FROM responses r
JOIN survey_questions sq ON sq.survey_question_id = r.survey_question_id
JOIN response_options o ON o.question_concept_id = sq.question_concept_id AND o.response_concept_id = r.response_concept_id
WHERE sq.question_concept_id = 899251483 GROUP BY reason;
```

### Q2 — labeled distribution for *any* question
```sql
-- WIDE: bespoke CASE per question; nothing generalizes
SELECT CASE d_724589244 WHEN '349122068' THEN '1' WHEN '194129782' THEN '2 to 4' /* … */ END AS answer, COUNT(*) n
FROM `CleanConnect.mouthwash` GROUP BY answer;

-- PHASE 1: labels via join; swap the concept_id to run it for ANY question
SELECT resp.current_format_value AS answer, COUNT(*) n
FROM responses r JOIN response resp USING (response_concept_id)
WHERE r.question_concept_id = 724589244 GROUP BY answer;

-- PHASE 2: read a precomputed aggregate
SELECT answer_label AS answer, n FROM agg_question_distribution WHERE question_concept_id = 724589244;
```

### Q3 — completion & **true** missingness (Phase 2 only)
```sql
-- WIDE & PHASE 1: a blank/absent answer can't distinguish not-shown vs not-answered vs survey-not-taken.

-- PHASE 2: sessions give status; skip_logic gives reachability
SELECT s.status, COUNT(DISTINCT s.connect_id) participants,
       COUNT(DISTINCT IF(r.response_id IS NOT NULL, s.connect_id, NULL)) answered_x
FROM response_sessions s
JOIN survey_questions sq ON sq.question_concept_id = /* X */ 0
LEFT JOIN responses r ON r.session_id = s.session_id AND r.survey_question_id = sq.survey_question_id
WHERE s.survey_id = /* Module 1 */ 0 AND s.wave = 'baseline'
GROUP BY s.status;
```

### Q4 — non-PHI extract / **governance** (Phase 2 only)
```sql
-- WIDE & PHASE 1: no sensitivity in the schema — a manual, unenforced allow-list of "safe" fields.

-- PHASE 2: sensitivity is data + enforced by a BigQuery row-access policy; the researcher's query is unchanged
SELECT * FROM responses WHERE sensitivity_tier = 'non_sensitive';
```

## Transformation lift at a glance

| | **Phase 1** | **Phase 2** |
|---|---|---|
| New objects we build | 1 table (`responses`) [+ 1 view] | ~10 dims/facts + analytic + marts |
| Reuses | CleanConnect + CIDTool verbatim | Phase 1's `responses` fact |
| New modeling | none | dimensions, sessions, governance, marts |
| Risk | low | moderate, phased |
| Governance | none (bolt-on later) | built in (row-access + release tiers) |
| Externally release-ready | no | yes |

---

## Recommendation

1. **Approve Phase 1 now.** Low cost, low risk, immediately useful, and a genuine down payment — its
   `responses` fact carries into Phase 2 unchanged.
2. **Commit to Phase 2** as the funded path to the PR2 research warehouse — especially **governance** and
   **lineage**, which Phase 1 deliberately defers and which are non-negotiable for sharing data externally.

Net: Phase 1 = an internal quick win that proves the model; Phase 2 = the governed, shareable product.
