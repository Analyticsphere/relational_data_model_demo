# Phase 2 ETL — design sketch

> **Status:** design-level *sketch*, not a build spec — illustrations are pseudo-SQL/pseudocode, not
> production code. Realizes the Phase 2 (Model B) data model. See `CLAUDE.md` → *Phase 2 feasibility* for the
> dependencies/risks this assumes (CIDTool maturity, a Quest parser, governance as an org effort).

## 1. Shape: two planes, one layering boundary

Phase 2 ETL splits into two planes with very different cadences, under the model's `Core → Analytic → Marts`
rule:

- **Metadata / dimension plane** — built from the **data dictionary + Quest markup**. Changes only when the
  instruments change (slow). Produces the dimensions + placement bridge + skip_logic.
- **Fact plane** — built from **CleanConnect**. Refreshes on the data cadence (fast). Produces
  `response_sessions` + `responses`.

Tooling boundary:
- **Core** (everything in this doc) = the Connect→relational transform. **Not dbt** — it needs column-name
  parsing + Quest parsing, so it's **Python/R + BigQuery SQL**, orchestrated by Airflow/Cloud Composer
  (matches the existing Analyticsphere Cloud Run/Airflow infra).
- **Analytic + Marts** = **dbt**, reading Core as a `source`. Governance (RLS, release tiers) + marts live here.

## 2. Pipeline

```
SOURCES                       CORE build (Airflow + BQ SQL + parsers)            DOWNSTREAM (dbt)
─────────                     ───────────────────────────────────────           ────────────────
masterFile / CIDTool ─┐
Quest .txt markup ────┤─ METADATA PLANE ─► surveys, survey_versions,
                      │                     question_types, questions,
                      │                     response_options, survey_questions,
                      │                     skip_logic
                      │                                 │
CleanConnect tables ──┤─ FACT PLANE ─► participants ────┤
  + participants ─────┘       │         response_sessions  (pivot the metadata triad)
                              │         responses          (UNPIVOT → keyed to placement)
                              ▼                            │
                       column→concept→placement map ◄──────┘
                                                           ▼
                                       fact_response · dim_* · agg_* · marts
                                       + governance (row-access policies, release tiers)
```

## 3. Sources (recap)

| Source | Role | Notes |
|---|---|---|
| **CleanConnect** | structural source for facts (unpivot → `responses`; `participants` → sessions) | already version-merged, binary→concept, name-standardized |
| **masterFile.csv / CIDTool** | dimension driver (questions, options, types, surveys, versions, pii/sensitivity seed) | messy, forward-fill required; CIDTool maturity is risk #1 |
| **Quest `.txt` markup** | structure & behavior (order, loops, grids, skip logic) | needs a parser (risk #2) |
| **concept IDs** | join keys throughout + provenance back to raw Connect | never dropped |

## 4. Build order

**Stage 0 — Ingest references**
- Load `masterFile.csv`/CIDTool JSON → dictionary staging; **forward-fill** the 5-level hierarchy; canonicalize.
- **Parse Quest** → structured staging (see §6).
- Inventory **CleanConnect physical columns** per survey table → drives the unpivot (see §5).

**Stage 1 — Dimensions (metadata plane), FK-depth order**

| # | Table | From | Key logic |
|---|---|---|---|
| 1 | `surveys` | Secondary Source (+ Primary Source → `domain`) | dedupe instrument names |
| 2 | `survey_versions` | dictionary V1/V2 | one row per instrument×version |
| 3 | `question_types` | dictionary Question Type **+ Quest** | decompose dirty string → `base_type` + flags; Quest is structural truth |
| 4 | `questions` | dictionary QUESTION | reusable bank, **one row per concept**; label, variable_type, min/max, pii, seed `sensitivity_tier` |
| 5 | `response_options` | RESPONSE + Quest per `(question, concept_version)` | reconcile **Quest > dictionary flags > columns**; `is_other`/`is_exclusive`; status/deprecation; sensitivity |
| 6 | `survey_questions` (placement) | **Quest order + Source-Question grouping + column inventory** | the crux — §5 |
| 7 | `skip_logic` | Quest `displayif`/`->` | structured rows (`enable_behavior`, `trigger_default_value`) + `raw_expression` fallback — §6 |

**Stage 2 — Facts (data plane)**

| # | Table | From | Key logic |
|---|---|---|---|
| 8 | `participants` | CleanConnect `participants` | minimal enrollment attrs |
| 9 | `response_sessions` | participants **metadata triad** | pivot `(status concept, TmStart, TmComplete)` wide→long → one row per `(connect_id, survey, wave)` |
| 10 | `responses` | CleanConnect survey tables | **UNPIVOT** keyed to placement; SATA collapse; type the value; stamp `secondary_source_concept_id`; denormalize `sensitivity_tier` |

**Stage 3 — Governance + Analytic/Marts (dbt)** — `fact_response`, `dim_*`, `agg_*`, view library, marts;
sensitivity classification → row-access policies → release-tier transforms (date-shift / mask / suppress).

---

## 5. Deep dive A — the column→concept→placement map

**The backbone of the unpivot.** A lookup keyed on `(source_table, source_column)` resolving each physical
CleanConnect column to its model coordinates and ultimately a `survey_question_id`:

```
(source_table, source_column)
   → question_concept_id, parent_question_concept_id, concept_version, loop_instance
   → survey_question_id        (by joining the resolved coords to survey_questions)
```

### Column grammar (CleanConnect, lowercase `d_x_d_y`)

| Pattern | Example | Resolves to |
|---|---|---|
| `d_<C>` | `d_107060069` | question `C`, parent NULL, v1 |
| `d_<C>_v2` | `d_899251483_v2` | question `C`, `concept_version=v2` |
| `d_<P>_d_<C>` | `d_103397024_d_206625031` | parent (Source Question) `P`, question `C` |
| `d_<P>_d_<C>_v2` | `d_899251483_d_812107266_v2` | same, v2 |
| `d_<G>_d_<G>_d_<R>` | `d_115616118_d_115616118_d_746038746` | **grid**: grid `G` → sub-question → cell `R` (needs Quest to disambiguate) |
| trailing `_<N>` | `d_142912472_d_206625031_3` | `loop_instance = 3` (strip before parsing the rest) |

### Algorithm (illustrative)

```python
def parse_column(col):                      # col e.g. "d_899251483_d_812107266_v2"
    loop_instance = None
    m = re.search(r'_(\d+)$', col)          # 1. strip trailing _N loop suffix
    if m and not col.endswith('_v2'):       #    (do NOT mistake the version tag for a loop index)
        loop_instance = int(m.group(1)); col = col[:m.start()]
    concept_version = 'v2' if col.endswith('_v2') else 'v1'   # 2. version tag
    col = re.sub(r'_v2$', '', col)
    segs = col.removeprefix('d_').split('_d_')                # 3. split into concept-id segments
    if len(segs) == 1:   parent, question = None, segs[0]     # 4. interpret by arity
    elif len(segs) == 2: parent, question = segs[0], segs[1]
    elif len(segs) == 3 and segs[0] == segs[1]:               #    grid: G/G/R — Quest says which is subq vs cell
        parent, question = segs[0], None      # resolve `question`/response role from the Quest grid def
    return parent, question, concept_version, loop_instance
```

### Resolve to a placement

```sql
-- join parsed coords to the Quest+dictionary-built bridge to get survey_question_id
SELECT m.source_table, m.source_column, sq.survey_question_id
FROM parsed_columns m
JOIN survey_questions sq
  ON  sq.question_concept_id        = m.question_concept_id
  AND sq.parent_question_concept_id IS NOT DISTINCT FROM m.parent_question_concept_id
  AND sq.concept_version            = m.concept_version
  AND sq.survey_version_id          = version_of(m.source_table)   -- table → instrument×version
```
(CleanConnect merges V1/V2 into one table, so `concept_version` — the `_v2` tag — is what splits the two
placements of the same `question_concept_id`.)

### Edge cases (each → a QC flag, not a silent drop)

- **Reused leaf concept** under many parents → the `parent` segment disambiguates (this is *why* placement,
  not the leaf, is the key).
- **Grid `d_X_d_X_d_Y`** → the repeated grid ID + cell is ambiguous from the name alone; the **Quest grid
  definition** (sub-questions + shared option set) tells you which segment is sub-question vs. response.
- **Select-all option columns** `d_<sataParent>_d_<option>` → these map to **(SATA-question placement,
  response_option)**, *not* a sub-question placement. The map must know `base_type = multi_select` to route
  the option segment to `response_concept_id` (the SATA collapse, §7).
- **Non-data columns** (`uid`, `sha`, `treeJSON`, `state`, `__key__`, `__error__`) → excluded.
- **Unresolvable columns** (no matching concept/placement) → flagged as drift for review.

---

## 6. Deep dive B — the Quest parser

**The novel piece with no prior art in the existing repos.** Input: `episphere/quest/questionnaires/*.txt`.
Output: structured staging that populates `survey_questions` (order, loops, grids, required) + `response_options`
(codes, order, reusable sets) + `skip_logic`.

### Construct → output

| Quest construct | Example | Emits |
|---|---|---|
| Question | `[MARITAL?] …` / `[AGE!] …` | `survey_questions` row (markup ID ↔ concept ID via dictionary) |
| Single-select | `(1) Married` | `question_types=single_select`; codes → `response_options` |
| Multi-select | `[1] Asian` `[7] White` | `question_types=multi_select`; codes → `response_options` |
| Numeric/text | `Age: \|__\|__\|min=40 max=70\|` | `numeric` + bounds (length/min/max) |
| Inline branch | `(1) Yes -> MARITAL` | `skip_logic` `show` rule on the target |
| Conditional display | `[Q2,displayif=greaterThanOrEqual(numnames,3)]` | `skip_logic` predicate |
| Loop | `<loop max=10> … </loop>`, `#loop` | `is_looped`/`loop_max` on enclosed placements |
| Grid | `\|grid\|id="…"\|prompt\|[ [Q1] …; [Q2] … ]\|(0:None)(1:…)\|` | grid parent → sub-questions sharing a response set |
| Reusable set | `#YNP`, `#YN` | shared `response_options` set, expanded per placement |
| Piping / vars | `{$u:firstName}`, `numnames` | display only; bound var names reappear in `displayif` |

### Parse pipeline

1. **Tokenize into question blocks** (by `[…]` headers), tracking **loop scope** (`<loop>`/`</loop>`) and
   **grid scope** (`|grid|…|`) as a stack.
2. **Per block**, extract: markup ID, prompt, type signature (`()` vs `[]` vs `|__|` vs `|grid|`), options,
   validation bounds, `?`/`!` marker, `displayif`, `-> target`.
3. **Order index** = file sequence → `display_order`.
4. **Resolve markup ID ↔ concept ID** via the dictionary crosswalk (`SOURCE_QUESTION` / `v1_source_question`
   / `grid_source_question_name`). *Open risk: this linkage may be lossy — flag unresolved IDs.*
5. **Emit** `survey_questions` + `response_options` + `skip_logic` staging rows.

### `displayif` → `skip_logic` (the meaty translation)

Measured on `module1` (276 expressions): **~92% reduce to structured rows, ~8% need the raw fallback.**

```python
def translate_displayif(target_qid, expr):
    ast = parse(expr)                          # equals/and/or/greaterThanOrEqual/percentDiff/isDefined...
    ast = flatten_same_connective(ast)         # or(x, or(y,z)) -> flat OR(x,y,z)
    if is_single_predicate(ast) or is_flat_group(ast):     # ~92%
        behavior = 'any' if root_is_or(ast) else 'all'
        rows = []
        for leaf in leaves(ast):               # each equals()/comparison -> one skip_logic row
            rows.append(dict(target=target_qid, enable_behavior=behavior,
                             trigger=leaf.var, operator=leaf.op, trigger_value=leaf.val,
                             trigger_default_value=('undefined' if leaf.val=='undefined' else None),
                             action='show', raw_expression=expr))
        return rows
    else:                                      # ~8%: nested OR-of-AND, percentDiff, isDefined fallback
        return [dict(target=target_qid, action='show', raw_expression=expr)]   # lossless fallback

# inline "(1) Yes -> TARGET" becomes a show rule:
#   target=TARGET, trigger=this_question, operator='=', trigger_value='1', action='show'
```

- `trigger_default_value` absorbs Quest `undefined` (the unanswered-trigger case — 38% of module1 exprs touch it).
- Everything keeps `raw_expression` = the verbatim `displayif` (source of truth + the ~8% fallback).

### Parser risks / validation
- **Markup-ID ↔ concept-ID linkage** — if lossy, `skip_logic`/`survey_questions` degrade; emit an unresolved-ID report.
- **`?`/`!` question markers** — confirm semantics against the Quest engine before relying on them.
- **Grid disambiguation** — the grid def is the authority for which flattened segment is sub-question vs. cell.
- Emit a **parse log**: % of `displayif` structured vs. raw, unresolved IDs, unrecognized constructs.
- Prototype on `module1` first (the stress-test instrument) before the other surveys.

---

## 7. Other transforms (brief)

**SATA collapse (in the unpivot):** a `multi_select` question emits **one `responses` row per selected option**
(`response_concept_id` = the option), instead of the dictionary's binary sub-question rows — the
"Source Question overloaded" logical fix. (Open decision: sparse [drop `0`s] vs. dense [keep `0=No` rows].)

**Session derivation:** pivot the participants metadata triad `(status concept, TmStart, TmComplete)` per
survey → one `response_sessions` row per `(connect_id, survey, wave)`; `is_complete = status==submitted`.

**Illustrative unpivot:**
```sql
INSERT INTO responses
SELECT s.session_id, m.survey_question_id, m.loop_instance,
       CASE WHEN q.base_type IN ('single_select','multi_select') THEN cell.concept_value END AS response_concept_id,
       CASE WHEN q.base_type='text' THEN cell.raw END            AS value_string,
       CASE WHEN q.variable_type='Num' THEN SAFE_CAST(cell.raw AS NUMERIC) END AS value_number,
       q.sensitivity_tier, cell.source_table, cell.source_column
FROM unpivoted_cells cell
JOIN colmap m            USING (source_table, source_column)
JOIN survey_questions sq ON sq.survey_question_id = m.survey_question_id
JOIN questions q         ON q.question_concept_id = sq.question_concept_id
JOIN response_sessions s ON s.connect_id = cell.connect_id AND s.survey_id = sq.survey_id
WHERE NOT (q.base_type='multi_select' AND cell.raw = '0');   -- SATA sparse (open decision)
```

## 8. Cross-cutting concerns

- **Idempotency:** dimensions = full rebuild each run (deterministic from dictionary+Quest). Facts =
  partition `responses` by survey, cluster by `connect_id`/`question_concept_id`; refresh per-survey or in
  `connect_id` batches (the metrics/QC repos already chunk this way).
- **Provenance:** every fact row keeps `source_table`/`source_column` + concept IDs → raw lineage intact (#7).
- **Validation = the QC engine, generated:** the 7,025 hand-rules become generated checks — value-set/type/
  length from `response_options`/`variable_metadata`; skip-gated from `skip_logic`. Run as a post-Core gate
  (dbt tests downstream). ~85% generatable; the ~15% custom + ~8% raw-skip stay hand-authored.
- **Governance:** seed `sensitivity_tier` from the dictionary PII flag (question+response level, with
  inheritance), resolve the effective tier once, denormalize onto `responses`; row-access policies +
  release-tier marts live downstream (dbt + IAM).

## 9. Dependencies & sequencing

1. **De-risk first (gates the metadata plane):** audit CIDTool output (clean dims, or build Stage 1 from
   `masterFile` ourselves?); **prototype the Quest parser on module1**.
2. **Mechanical core:** column→placement map + unpivot + session pivot (straightforward once the map exists).
3. **Governance + marts in parallel** (org-gated, dbt) — the long pole.

**First milestone that proves the spine:** one survey end-to-end — **mouthwash** is ideal (small; has the
tooth-loss SATA + sessions) — through all stages, validated against the wide table.
