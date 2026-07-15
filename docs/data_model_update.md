# Connect Data Model — status update

The **Dictionary-Direct** model (accepted) is standing up in the stage BigQuery project: the CIDTool data
dictionary adopted as the source of truth, plus **one long-format `responses` fact** that everything joins to.
Below are the objects currently defined, followed by example queries showing what they enable. Roadmap and
open decisions live in [`enhancement_backlog.md`](enhancement_backlog.md).

---

## Objects (tables & views)

| Object | Type | Description |
|---|---|---|
| **`responses`** | **Fact** | Long/narrow — one row per answered survey cell (participant × question × loop instance × value), unpivoted from CleanConnect. The core of the model; every row traces back to its source concept IDs and CleanConnect column. |
| `primary_source` | Dimension | Domain — one row per domain concept (Survey, Recruitment, Biospecimen, …). From the dictionary / CIDTool. |
| `secondary_source` | Dimension | Survey instrument/section — one row per survey concept; FK to `primary_source` (domain). |
| `source_question` | Dimension | The grid / select-all group parent (GridID) that sub-questions attach to. |
| `question` | Dimension | Reusable question concept bank — one row per question concept, with current text and type. |
| `response` | Dimension | Response options — response concept ID → format/value label (the dictionary's coded-answer labels). |
| `question_response` | Bridge | The allowed response options per question concept (the offered option set). |
| `concept_relationship` | Equivalence overlay | OMOP-style `concept_id_1 → concept_id_2` with a relationship (e.g. `synonym`). Harmonizes reused fields; demo-populated for address components. |
| `survey_columns_clean_mapped` | Staging / mapping | Column → dictionary placement mapping: each CleanConnect column parsed to its concept path (survey, source-question, question, loop, version). |
| `colmap` | View (over the mapping) | Clean-named view of the column → placement mapping the `responses` unpivot joins on. |
| `v_responses_enriched` | Convenience view | Pre-joins the dictionary onto `responses` so every answer row is self-describing — **zero joins for analysts**. |
| `v_data_dictionary` | Convenience view | The dimensions denormalized back into a flat, data-dictionary-like row per question × allowed response. |
| `mart_demographics` | Mart (curated) | Participant-grain education / marital status / income (labels from the dictionary). |
| `mart_anthropometry` | Mart (curated) | Participant-grain height / weight / BMI / BMI category. |
| `mart_smoking` | Mart (curated) | Participant-grain smoking status, cigarette history, and derived Never/Current/Former category. |

> Layering: **dictionary dimensions → `responses` fact → convenience views → curated marts.** Marts read the
> model, never the reverse. Marts are a first pass as plain views (dbt — for lineage/tests — comes next).

---

## Example queries

### 1. One generic query works for *any* question
No bespoke `CASE` per question, no knowing column names — swap one concept ID and it works across every survey.

```sql
SELECT o.current_format_value AS answer, COUNT(*) AS n
FROM relational.responses r
JOIN relational.response  o ON o.response_concept_id = r.response_value_as_concept_id
WHERE r.question_concept_id = '108417657'   -- e.g. "How many times have you had a proctoscopy?"
GROUP BY answer ORDER BY n DESC;
```

### 2. Harmonize a reused field — one join instead of a 26-branch `CASE`
The same real-world field ("street name of residence") is ~66 different concept IDs; `concept_relationship`
records that they mean the same thing **once, as data**, so one join gathers them all.

```sql
SELECT r.connect_id, r.loop_instance, r.response_value_as_string AS street_name
FROM relational.responses r
JOIN relational.concept_relationship cr
  ON cr.concept_id_1 = r.question_concept_id AND cr.relationship = 'synonym'
WHERE cr.concept_id_2 = '105043152';   -- the group's canonical "street name of residence" concept
```

### 3. A curated derived variable is one line
A researcher reuses a vetted variable instead of re-deriving it; the mart's *definition* is its recipe.

```sql
SELECT cigarette_cats, COUNT(*) AS n
FROM marts.mart_smoking
GROUP BY cigarette_cats ORDER BY n DESC;
```

### 4. What a mart definition looks like (`mart_demographics`)
Derived variables are just SQL over `responses`, with **labels pulled from the dictionary** (not hand-typed),
so they can't drift. This is the recipe that dbt will later wrap with lineage + tests.

```sql
WITH pivoted AS (
  SELECT
    connect_id,
    MAX(IF(question_concept_id = '367803647'
           AND current_source_question_concept_id = '367803647',
           response_value_as_string, NULL)) AS education_cid,   -- D_367803647_D_367803647
    MAX(IF(question_concept_id = '783167257', response_value_as_string, NULL)) AS marital_cid,   -- D_783167257
    MAX(IF(question_concept_id = '759004335', response_value_as_string, NULL)) AS income_cid      -- D_759004335
  FROM relational.responses
  GROUP BY connect_id
)
SELECT
  p.connect_id,
  COALESCE(REGEXP_REPLACE(e.current_format_value, r'^\s*\d+\s*=\s*', ''), 'Missing') AS education_cat,
  COALESCE(REGEXP_REPLACE(m.current_format_value, r'^\s*\d+\s*=\s*', ''), 'Missing') AS marital_status_cat,
  COALESCE(REGEXP_REPLACE(i.current_format_value, r'^\s*\d+\s*=\s*', ''), 'Missing') AS income_cat
FROM pivoted p
LEFT JOIN relational.response e ON e.response_concept_id = p.education_cid
LEFT JOIN relational.response m ON m.response_concept_id = p.marital_cid
LEFT JOIN relational.response i ON i.response_concept_id = p.income_cid;
```

### 5. Zero joins for analysts (`v_responses_enriched`)
For hand-SQL users, the convenience view ships every answer already labeled with its survey, question text,
and response — self-describing, no joins to remember.

```sql
SELECT connect_id, survey, question_text, response_label, response_value
FROM relational.v_responses_enriched
WHERE question_concept_id = '108417657';
```

---

*Notes for the boss: the model is populated in **stage** (not production); marts and convenience views are a
first pass pending validation (marts are checked row-for-row against the finalized PR2-analyses derivations).
The next steps are the enhancement backlog — typed values, version handling, skip logic, sessions, governance,
and reworking the marts into dbt for full lineage.*
