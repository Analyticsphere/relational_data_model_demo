# Connect Data Model — status update

The **Dictionary-Direct** model (accepted) is standing up in the stage BigQuery project
(`nih-nci-dceg-connect-stg-5519`): the CIDTool data dictionary adopted as the source of truth, plus **one
long-format `responses` fact** that everything joins to. Below are the objects currently defined, followed by
example queries showing what they enable. Roadmap and open decisions live in
[`enhancement_backlog.md`](enhancement_backlog.md).

> All example queries below are copy-paste runnable against the stage project.

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
| `v_data_dictionary` | Convenience view | The dimensions denormalized back into a flat, data-dictionary-like row per question × allowed response (deterministically ordered). |
| `mart_demographics` | Mart (curated) | Participant-grain education / marital status / income (labels from the dictionary). |
| `mart_anthropometry` | Mart (curated) | Participant-grain height / weight / BMI / BMI category. |
| `mart_smoking` | Mart (curated) | Participant-grain smoking status, cigarette history, and derived Never/Current/Former category. |

> Layering: **dictionary dimensions → `responses` fact → convenience views → curated marts.** Marts read the
> model, never the reverse. Marts are a first pass as plain views (dbt — for lineage/tests — comes next).

---

## Example queries

Each query is shown two ways — **SQL** and **R** (`DBI` + `dbplyr`). The dbplyr pipelines are **lazy**: nothing
is sent to BigQuery until you pipe to `collect()`, and `show_query()` prints the SQL dbplyr generated (a handy
bridge for SQL and R users alike). Set up the connection and lazy table handles once:

```r
library(DBI); library(dplyr); library(dbplyr)
con <- dbConnect(bigrquery::bigquery(), project = "nih-nci-dceg-connect-stg-5519")

# Lazy handles - no data is pulled until collect().
responses         <- tbl(con, I("relational.responses"))
response          <- tbl(con, I("relational.response"))
concept_rel       <- tbl(con, I("relational.concept_relationship"))
mart_smoking      <- tbl(con, I("relational.mart_smoking"))
v_resp_enriched   <- tbl(con, I("relational.v_responses_enriched"))
v_data_dictionary <- tbl(con, I("relational.v_data_dictionary"))
```

### 1. One generic query works for *any* question
No bespoke `CASE` per question, no knowing column names — swap one concept ID and it works across every survey.

```sql
SELECT o.current_format_value AS answer, COUNT(*) AS n
FROM relational.responses r
JOIN relational.response  o ON o.response_concept_id = r.response_value_as_concept_id
WHERE r.question_concept_id = '108417657'   -- e.g. "How many times have you had a proctoscopy?"
GROUP BY answer ORDER BY n DESC;
```
```r
responses |>
  filter(question_concept_id == "108417657") |>
  inner_join(response, by = c("response_value_as_concept_id" = "response_concept_id")) |>
  count(answer = current_format_value, sort = TRUE)     # add |> collect() to run
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
```r
street_of_residence <- concept_rel |>
  filter(relationship == "synonym", concept_id_2 == "105043152")

responses |>
  inner_join(street_of_residence, by = c("question_concept_id" = "concept_id_1")) |>
  transmute(connect_id, loop_instance, street_name = response_value_as_string)
```

### 3. A curated derived variable is one line
A researcher reuses a vetted variable instead of re-deriving it.

```sql
SELECT cigarette_cats, COUNT(*) AS n
FROM relational.mart_smoking
GROUP BY cigarette_cats ORDER BY n DESC;
```

```r
mart_smoking |> count(cigarette_cats, sort = TRUE)
```

### 4. What a mart definition looks like (`mart_demographics`)
Derived variables are just SQL over `responses`, with **labels pulled from the dictionary** (not hand-typed),
so they can't drift. Columns pair each coded answer with its label. This is the recipe dbt will later wrap
with lineage + tests.

```sql
WITH pivoted AS (
  SELECT
    connect_id,
    MAX(IF(question_concept_id = '367803647'
           AND current_source_question_concept_id = '367803647', response_value_as_string, NULL)) AS education_concept_id,
    MAX(IF(question_concept_id = '783167257', response_value_as_string, NULL)) AS marital_status_concept_id,
    MAX(IF(question_concept_id = '759004335', response_value_as_string, NULL)) AS income_concept_id
  FROM relational.responses
  GROUP BY connect_id
)
SELECT
  p.connect_id,
  p.education_concept_id,
  COALESCE(e.current_format_value, 'Missing') AS education_cat,
  p.marital_status_concept_id,
  COALESCE(m.current_format_value, 'Missing') AS marital_status_cat,
  p.income_concept_id,
  COALESCE(i.current_format_value, 'Missing') AS income_cat
FROM pivoted p
LEFT JOIN relational.response e ON e.response_concept_id = p.education_concept_id
LEFT JOIN relational.response m ON m.response_concept_id = p.marital_status_concept_id
LEFT JOIN relational.response i ON i.response_concept_id = p.income_concept_id;
```

R users usually *consume* the finished mart (like #3) rather than re-author it. And an ad-hoc labeled recode is
itself a short dplyr pipeline — a labeled distribution for any question is just a join to the dictionary:

```r
responses |>
  filter(question_concept_id == "367803647") |> # education
  inner_join(response, by = c("response_value_as_string" = "response_concept_id")) |>
  count(education = current_format_value, sort = TRUE)
```

### 5. Zero joins for analysts (`v_responses_enriched`)
For hand-SQL users, the convenience view ships every answer already labeled with its survey, question text,
and response — self-describing, no joins to remember.

```sql
SELECT connect_id, survey, question_text, response_label, response_value
FROM relational.v_responses_enriched
WHERE question_concept_id = '108417657';
```
```r
v_resp_enriched |>
  filter(question_concept_id == "108417657") |>
  select(connect_id, survey, question_text, response_label, response_value)
```

### 6. Browse the data dictionary (`v_data_dictionary`)
The dictionary itself is a queryable, deterministically-ordered view — one row per question x allowed option.

```sql
SELECT question_concept_id, current_question_text, response_concept_id, current_format_value
FROM relational.v_data_dictionary
WHERE secondary_source = 'Background and Overall Health'
LIMIT 20;
```
```r
v_data_dictionary |>
  filter(secondary_source == "Background and Overall Health") |>
  select(question_concept_id, current_question_text, response_concept_id, current_format_value) |>
  head(20)
```

---

*Notes for the team: the model is populated in **stage** (`nih-nci-dceg-connect-stg-5519`), not production.
The `responses` fact, dimensions, `v_data_dictionary`/`v_responses_enriched` views, and the three marts are
all queryable now. Marts are a first pass pending validation (checked row-for-row against the finalized
PR2-analyses derivations). Next steps are the enhancement backlog — typed values, version handling, skip
logic, sessions, governance — and reworking the marts into dbt for full lineage.*
