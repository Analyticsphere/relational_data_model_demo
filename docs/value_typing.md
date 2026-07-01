# Response Value Typing — approach and limitations

The `responses` table carries four value columns following the OMOP `observation` pattern:

| Column | BQ type | Contents |
|---|---|---|
| `response_value_as_string` | STRING | Verbatim cell — **always populated, lossless source of truth** |
| `response_value_as_concept_id` | STRING | Coded (single/multi-select) answer concept ID |
| `response_value_as_number` | FLOAT64 | Numeric answer (age, year, count, weight, …) |
| `response_value_as_date` | DATE | ISO date answer (Special Functions date questions) |

Values are routed from `response_value_as_string` by `sql/unpivot_stage/type_response_values.sql`
after every unpivot load. The typed columns are derived; `response_value_as_string` is always the
ground truth.

---

## Routing logic

Rules are applied in priority order; the first match wins.

1. **9-digit integer** → `response_value_as_concept_id`
   Pattern: `^\d{9}$`
2. **ISO date** → `response_value_as_date`
   Pattern: `^\d{4}-\d{2}-\d{2}$` + `SAFE_CAST AS DATE IS NOT NULL`
3. **Numeric (non-9-digit, non-date)** → `response_value_as_number`
   Condition: `SAFE_CAST AS FLOAT64 IS NOT NULL` after excluding rules 1–2
4. **Anything else** → remains only in `response_value_as_string` (free text / unrecognized)

Note: the dictionary's `question_type` field is **not used** for routing — it is ~62% blank or
inconsistently categorized, making value-pattern routing more robust.

---

## Limitations by column

### `response_value_as_concept_id`

**False positives (misrouted non-concept-IDs)**
: Theoretically, any free-text answer that is exactly 9 digits would be misrouted. In practice,
no natural Connect survey answer (age, year, count, zip code, census tract, phone) is exactly
9 digits — the 9-digit integer is the Connect concept ID namespace convention. The observed
false-positive rate is effectively zero.

**False negatives (missed concept IDs)**
: If Connect's concept ID scheme ever expands beyond 9 digits (e.g., 10-digit IDs for a new
domain), those IDs would fall through to `response_value_as_string`. The pattern must be updated
if the concept ID length convention changes.

**No ontology validation**
: Routing is by pattern, not by membership in the `response` dimension table. Approximately 0.3%
of routed concept IDs have no matching entry in `response` (dictionary gaps). In
`v_responses_enriched` these rows have `NULL` for `response_label` — this is correct behavior
(known gap, not a misroute). Query the `question_response` bridge to distinguish confirmed coded
questions from gap cases.

**Re-typing after a partial unpivot re-run**
: If the unpivot is re-run for one survey table, the typing step must also be re-run for those
rows. A partial re-type risks leaving stale or missing values. The safe pattern is: re-run the
unpivot for the affected table, then re-run `type_response_values.sql` over the whole table
(it is idempotent — existing non-NULL values are overwritten, not doubled).

---

### `response_value_as_number`

**FLOAT64 precision**
: Numeric answers are stored as `FLOAT64`. FLOAT64 represents integers exactly up to 2^53
(~9 quadrillion), which covers all expected Connect values (ages, years, counts, weights). No
precision loss is expected for current data.

**Year answers**
: 4-digit years (e.g., `"2024"`) are correctly routed to `response_value_as_number` as
`2024.0`. Downstream callers should `CAST(response_value_as_number AS INT64)` before date
arithmetic (e.g., computing age from birth year).

**Locale sensitivity**
: Decimal values using a comma separator (e.g., European-locale `"1,5"`) return NULL from
`SAFE_CAST AS FLOAT64` and remain in `response_value_as_string`. Connect is a US cohort and
CIDTool emits period-decimal format; this is very unlikely to occur.

**Numeric sentinels**
: Values like `"-1"` (a common refused/unknown sentinel in other instruments) are valid FLOAT64
and would route to `response_value_as_number`. Connect uses concept IDs for refusal/unknown, not
numeric sentinels, so this is not expected in production. Verify if importing data from external
instruments.

**ISO date strings excluded**
: Step 3 explicitly excludes strings matching `^\d{4}-\d{2}-\d{2}$` so date-shaped values are
not double-routed. A string like `"2024-07-01"` goes to `response_value_as_date`, not to
`response_value_as_number` (even though `SAFE_CAST AS FLOAT64` of `"2024-07-01"` returns NULL,
the exclusion makes the intent explicit).

---

### `response_value_as_date`

**Format coverage**
: Only `YYYY-MM-DD` (ISO 8601) is recognized. Other date formats — `MM/DD/YYYY`, `M/D/YYYY`,
textual months — are not captured and remain in `response_value_as_string`. CIDTool should
consistently emit ISO format; any deviation silently misses.

**Sparsity in current data**
: Stage (~300 participants) has approximately 25 date-valued rows across 2 questions of type
"Special Functions". The full cohort (200k) could have proportionally more, but date-valued
answers appear to be exceptional rather than common in current survey instruments.

**Naive dates (no timezone)**
: BigQuery's `DATE` type has no timezone. All dates are stored exactly as emitted by CIDTool.
Cross-date comparisons are safe; comparing to `TIMESTAMP` columns requires explicit `DATE()`
casting.

**Padded partial dates**
: A value like `"2024-01-01"` that represents "January 2024" (a year-month answer padded to the
first of the month) would be stored as `DATE '2024-01-01'` with no indication of the padding.
Callers must consult the question definition (`question_type = 'Special Functions'` + question
text) to determine whether day precision is meaningful.

**SAFE_CAST validation**
: The REGEXP pre-filter (`^\d{4}-\d{2}-\d{2}$`) is applied before the SAFE_CAST; only strings
passing the pattern are attempted. SAFE_CAST returns NULL for logically invalid dates
(e.g., `"2024-02-30"`), which remain in `response_value_as_string`.

---

### Cross-cutting / general limitations

**Mutual exclusivity**
: The three typed columns are mutually exclusive per routing logic — a given value routes to
exactly one typed column. If a question legitimately receives both numeric and coded answers
across different participants (e.g., "enter age OR prefer not to say" coded as a concept ID),
different rows correctly route to different columns. No single value lands in two typed columns.

**Typing is post-load**
: The unpivot step writes only `response_value_as_string`. The typing step must be run after
every full or partial unpivot load. The full `type_response_values.sql` is the safe default —
it is idempotent and fast relative to the unpivot.

**`response_value_as_string` is always the audit trail**
: All typed columns are derived from `response_value_as_string`. To audit un-typed (free-text)
rows:
```sql
SELECT response_value_as_string, COUNT(*) AS n
FROM `nih-nci-dceg-connect-stg-5519.relational.responses`
WHERE response_value_as_string IS NOT NULL
  AND response_value_as_number     IS NULL
  AND response_value_as_concept_id IS NULL
  AND response_value_as_date       IS NULL
GROUP BY 1 ORDER BY 2 DESC LIMIT 50;
```

**SAFE_CAST failure mode is silent**
: `SAFE_CAST` returns NULL (not an error) on unparseable input. Routing failures leave NULL in
the typed column and the original value in `response_value_as_string`. This is intentional —
it prevents one bad value from failing the entire update — but it means type errors are
invisible without the audit query above.

**Dictionary `question_type` not used for routing**
: The dictionary's `question_type` field is ~62% blank or inconsistently categorized. Routing
by value pattern makes the typing step robust to dictionary updates and avoids dependency on
a noisy field. The trade-off: routing is purely data-driven, so a future question type that
legitimately produces 9-digit non-concept-ID integers would need an explicit exclusion added.
