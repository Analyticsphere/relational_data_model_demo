# Connect Survey Version Handling

*Survey date: 2026-07-07 · Source: `data_dictionary/masterFile.csv` + `schemas/stage/CleanConnect/*.json`*

---

## Purpose

This document surveys how versioning actually works in the Connect data dictionary and BQ schema, and scopes the engineering needed for the `version handling` enhancement (backlog §3). It covers:

- The two-axis version scheme (`_vN` major version, `rN` revision)
- How each axis manifests in the dictionary, in BQ column names, and in the `responses` fact
- The four distinct versioning patterns and what each means for analysis
- Quantitative scope of the problem across survey variables
- Concrete case studies for each pattern
- What the relational model needs to handle per pattern

---

## The Two-Axis Version Scheme

Every Connect variable name ends with a version suffix: `_vNrN`. There are two independent axes:

| Axis | Meaning | Example |
|---|---|---|
| **`v` (version)** | Major change: the measurement concept changed — different question text, different answer options, or different source question | `_v1r0` → `_v2r0` |
| **`r` (revision)** | Minor change: the collection *mechanism* changed but the concept is identical — range check widened, UI updated, double-entry added | `_v1r0` → `_v1r1` |

These axes are independent. `_v2r1` means the second major version, revised once. The distinction matters for analysis: revision increments are **transparent** (same question, just collected more carefully); version increments may require explicit harmonization.

---

## Variable Version Distribution (Survey rows)

| Version × Revision | Count | % of survey vars |
|---|---:|---:|
| `v1r0` — baseline | 3,147 | 81% |
| `v1r1` — minor revision of v1 | 258 | 7% |
| `v2r0` — major version 2 | 315 | 8% |
| `v2r1` — minor revision of v2 | 72 | 2% |
| `v2r2` — second minor revision of v2 | 18 | <1% |
| `v3r0` — major version 3 | 25 | <1% |
| `v3r1` — minor revision of v3 | 3 | <1% |
| No suffix | 10 | <1% |
| **Total** | **3,848** | |

**81% of survey variables are still at v1r0** — the baseline, untouched. The remaining 19% (691 variables) have been versioned at least once. All versioned variables require deliberate handling in the relational model.

---

## How the Dictionary Represents Versions

**The dictionary is forward-looking.** When a variable is revised:
- The *current* version's row is updated in place (the variable name changes from `_v1r0` to `_v2r0`)
- The old row is either removed entirely, or kept with status `Deprecated`
- Only **2** variable bases have both a `_v1` and `_v2` row coexisting in the current dictionary

**Consequence**: the dictionary alone is not sufficient to compare v1 and v2. The BQ schemas (which retain all historical columns) are the ground truth for what was actually collected.

### Deprecated / New / Revised status

The `Deprecated, New, or Revised` column documents lifecycle, but is not comprehensively filled:

| Status | Survey rows | Notes |
|---|---:|---|
| *(blank)* | 2,124 | Most baseline variables; no change since initial load |
| Revised | 1,115 | Currently active, but something changed — covers both `r` and `v` bumps |
| Deprecated | 407 | No longer collected; replaced or removed |
| New | 202 | Explicitly added after initial launch |

The `Revised` label applies to **both** major-version and minor-revision changes — it does not distinguish them. The variable name suffix (`_v` vs `_r` increment) is the only reliable discriminator.

---

## Four Versioning Patterns

### Pattern 1: Repeat Administration (`_v2` BQ column suffix)

**What it is**: The *same question* (same concept ID, same options) asked again at a later biospecimen visit. BQ appends `_v2` to the column name for the second administration. Not the same as a `_v2r0` variable name change.

**Scope**: **17 dancing pairs** (v1 column + v2 column coexisting) found across `bioSurvey`, `clinicalBioSurvey`, and `covid19Survey`.

**Examples:**

| v1 column | v2 column | Concept ID | Question |
|---|---|---|---|
| `d_191057574` | `d_191057574_v2` | 191057574 | At about what time did you last eat or drink anything other than water before donating your samples? *(SRVBIO_EATDRINKTIME)* |
| `d_299417266` | `d_299417266_v2` | 299417266 | What time did you go to sleep on the night before donating your samples? *(SRVBIO_SLEEPTIME)* |
| `d_890156588` | `d_890156588_v2` | 890156588 | Did you get vaccinated against COVID-19? *(SrvCov_COV25)* |
| `d_899251483_d_812107266` | `d_899251483_d_812107266_v2` | 812107266 | Yes, from accident or injury *(tooth-loss SATA option, Mouthwash)* |

Also **47 `_v2`-only columns** exist in stage where the v1 column was dropped (the question existed only in later administrations, e.g., follow-up COVID survey questions).

**What the relational model needs**: A **wave / administration index** on each `responses` row. The concept ID is the same — the two rows are semantically the same question asked twice. Without an administration index, `GROUP BY question_concept_id` conflates answers from different visits and double-counts participants who answered both. The `response_sessions` enhancement (backlog §5) directly provides this key.

---

### Pattern 2: Minor Revision (`r` increments, concept ID unchanged)

**What it is**: A technical change to how the question is collected — the validation range is widened, the UI mechanism changes, or a branch-logic constraint is updated. The concept ID stays the same. The measurement is considered continuous across revisions.

**Scope**: **258** `v1r1` survey variables + **72** `v2r1` + **18** `v2r2` + **3** `v3r1` = **351** revision-incremented variables.

**Examples:**

| Old variable | New variable | What changed |
|---|---|---|
| `SrvBOH_Age_v1r0` | `SrvBOH_Age_v1r1` | Age range check widened: `min=40 max=70` → `min=30 max=75` (pushed 2024-02-01) |
| `SrvBOH_SkinCancAge_v1r0` | `SrvBOH_SkinCancAge_v1r1` | Range check max updated: previously `max=age`, now `max=sum(isDefined(D_150344905,age),1)` |
| `SrvBOH_AnemiaAge_v1r0` | `SrvBOH_AnemiaAge_v1r1` | Same range-check pattern update across ~200 age-at-diagnosis questions |
| `SrvSS_SSN_v3r0` | `SrvSS_SSN_v3r1` | Double-entry UI mechanism added in V0.02 PWA Prod Push (2024-01) |

The ~200 age-at-diagnosis revision increments are all the same underlying fix: the upper-bound range check was changed from `max=age` to `max=sum(isDefined(AGE,age), 1)` to allow participants to report a diagnosis in the same year they enrolled.

**What the relational model needs**: Essentially nothing — revision increments are transparent. The same concept ID is used before and after, so `responses` rows join correctly. It is worth flagging the revision in the `question` dimension as a `max_revision` attribute so analysts know multiple collection mechanisms existed. For the age-at-diagnosis mass update specifically, a note in the question dimension that "range validation changed on 2024-02-01" would prevent confusion if outlier values appear.

---

### Pattern 3: Major Version with Same Concept ID (concept reused, behaviour changed)

**What it is**: The question is substantially revised — different answer options, restructured question, changed skip logic — but the same concept ID is retained. Statistically, v1 and v2 answers are *not* directly comparable (different options were offered), yet `GROUP BY question_concept_id` will silently combine them.

**Scope**: Observed in the COVID vaccine questions and the biospecimen time questions. The dictionary marks the old version as `Deprecated` and the new as the current entry.

**Examples:**

| v1 variable | v2 variable | Concept ID | Change |
|---|---|---|---|
| `SrvBlU_COV25_v1r0` *(Deprecated)* | `SrvBlU_COV25_v2r0` *(Deprecated)* | 890156588 | COVID vaccination question — same text, different option set between Blood/Urine v1 and v2 administrations |
| `SrvBlU_COV26_v1r0` *(Deprecated)* | `SrvBlU_COV26_v2r0` *(Deprecated)* | 877074400 | COVID vaccine shot count — same concept, revised in mouthwash re-administration |

**What the relational model needs**: A `question_version` attribute on `responses` (already planned; already on the `responses` DDL as `question_version`). When two rows share the same `question_concept_id` but differ in `question_version`, the analyst must inspect the option sets before pooling. A `response_options` version-scoped lookup table (mapping concept ID × version → valid response codes) is the clean solution. Queries that want pooled v1+v2 answers would join to this table to confirm the options are compatible before aggregating.

---

### Pattern 4: Major Version with New Concept ID (concept replaced)

**What it is**: The question changed enough that a new concept ID was assigned. The old variable is `Deprecated`; the new variable gets a new `_v2` name and new concept ID. The two measurements are *different concepts* — they cannot be joined on concept ID. They can only be linked via a **concept equivalence / deprecated→successor mapping** (backlog §6 + §3).

**Scope**: The most common form of revision for survey variables. Examples include the sex/anatomy questions, which were restructured in early 2023.

**Examples:**

| Old variable (Deprecated) | New variable | Old CID | New CID | Change |
|---|---|---|---|---|
| `SrvBOH_SexAtBirth_v1r0` *(not in current dict)* | `SrvBOH_SexAtBirth_v2r1` | *(dropped)* | 407056417 | Question text and option set changed; new concept assigned |
| `SrvBOH_Penis_v1r0` *(not in current dict)* | `SrvBOH_Penis_v2r0` | *(dropped)* | 582784267 | Display condition changed (was intersex-only; now shown to all). New concept. |
| `SrvBOH_Testes_v1r0` *(not in current dict)* | `SrvBOH_Testes_v2r0` | *(dropped)* | 751402477 | Same — display condition broadened |
| `SrvBOH_Gender_v2r1` *(Deprecated)* | — | 289664241 | — | Deprecated without replacement (unharmonization change that was never pushed to prod) |

**Note on `SrvBOH_Gender_v2r1`**: This is `Deprecated` with no successor — a planned revision that was never released to production. It is in the dictionary but its data in BQ (if any exists) should be treated as a staging artifact.

**What the relational model needs**: 
1. A `concept_relationship` row of type `replaces` / `replaced_by` linking old CID → new CID (backlog §6). This is the machine-readable way to say "these two concepts measure the same construct across time."
2. A `deprecated_at` date and `successor_concept_id` attribute on the `question` dimension so queries can automatically route to the current version.
3. Analysts who need to pool v1-era and v2-era data must explicitly join through the equivalence plane — it should never be automatic (the option sets may genuinely differ).

---

## Version Handling by Secondary Source

The volume and type of versioning varies heavily by survey module:

| Secondary Source | Total rows | Deprecated | Revised | Version spike |
|---|---:|---:|---:|---|
| Where You Live and Work | 908 | 2 | 527 | Heavy revision — 58% of rows revised |
| Background and Overall Health | 895 | 33 | 322 | Moderate; sex/anatomy pattern 4 revisions |
| Smoking, Alcohol, and Sun | 420 | 22 | 201 | Moderate |
| Medications / Reproductive | 490 | 3 | 32 | Light |
| Cancer Screening History | 236 | 0 | 10 | Mostly new (226 New) — recent addition |
| Blood/Urine/Mouthwash | 199 | 119 | 13 | Heavy deprecation — repeat-admin pattern |
| Blood/Urine *(older)* | 145 | 117 | 6 | Very high deprecation — superseded by Mouthwash |
| COVID-19 | 115 | 109 | 1 | 95% deprecated — entire module superseded |

**Key observation**: The COVID-19 module has 95% deprecated rows — it was effectively replaced by the COVID-19 (Post-Pandemic) module. The Blood/Urine secondary source is similarly heavily deprecated, superseded by Blood/Urine/Mouthwash. These are entire-module replacements, not individual question edits. In the relational model they represent Pattern 4 (new concept IDs) at scale.

---

## What the Relational Model Needs per Pattern

| Pattern | `responses` impact | Required enhancement |
|---|---|---|
| **1. Repeat administration** | Same CID, two rows per participant | `wave`/`administration_index` on `responses` (backlog §5) |
| **2. Minor revision (r increment)** | Same CID, continuous — no action needed | Document `max_revision` in `question` dimension |
| **3. Same CID, changed options** | Same CID, incompatible option sets | `question_version` on `responses` (already planned) + `response_options` version-scoped lookup |
| **4. New CID (replaced concept)** | Different CID, no join path | `deprecated_at` + `successor_concept_id` on `question`; `concept_relationship` table (backlog §6) |

### Proposed `question` dimension additions

```sql
ALTER TABLE question ADD COLUMN max_version        INT64;   -- highest _vN seen (1, 2, 3)
ALTER TABLE question ADD COLUMN max_revision       INT64;   -- highest _rN seen
ALTER TABLE question ADD COLUMN status             STRING;  -- Deprecated | Revised | New | (blank)
ALTER TABLE question ADD COLUMN deprecated_at      DATE;
ALTER TABLE question ADD COLUMN successor_cid      INT64;   -- FK -> question for pattern-4 pairs
ALTER TABLE question ADD COLUMN is_repeat_admin    BOOL;    -- true if _v2 BQ column exists
```

### The `COALESCE` helper view (minimum viable version unification)

Before a full `response_options` version-scoped lookup is built, a simple view handles the most common analytical case — pooling v1 and v2 responses for questions where the options are compatible:

```sql
CREATE OR REPLACE VIEW relational.v_responses_current AS
SELECT
  r.*,
  COALESCE(q_new.question_concept_id, r.question_concept_id) AS current_question_cid
FROM relational.responses r
LEFT JOIN relational.question q_old
  ON r.question_concept_id = q_old.question_concept_id
  AND q_old.status = 'Deprecated'
LEFT JOIN relational.question q_new
  ON q_old.successor_cid = q_new.question_concept_id;
```

This routes deprecated-concept responses to their successors automatically, while leaving non-deprecated rows untouched. Analysts who need to distinguish v1-era from v2-era data can join directly on `responses` without the view.

---

## Recommended Design: SCD Type 4 (clean current table + version overlay)

The four patterns above are all instances of one classic data-warehouse problem: a **Slowly Changing
Dimension (SCD)** — a descriptive table (`question`, `response`, `source_question`) whose attributes change
slowly over time. The only real design question is *"when a description changes, what happens to the old
value?"* The standard answers are the "SCD types":

| Type | What it does | On our `question` dim | Verdict for Connect |
|---|---|---|---|
| **Type 1** | Overwrite — keep only the current value | One row per question, current text only; history lost | What the clean current tables do today |
| **Type 2** | Add a new **row** per version (`version` / `valid_from` / `is_current`) | `question` gets many rows per concept | History kept, but every join must filter to current or fan out |
| **Type 3** | Add a **column** for each prior value (`v1_text`, `v2_text`, …) | Every row carries mostly-null version columns | This *is* the dictionary's `Current/V1/V2` layout we normalized away |
| **Type 4** | **Split into two tables**: a clean *current* table + a separate *history* table | `question` stays 1 row/concept; a `question_version` overlay holds versions | **Recommended** |

**Recommendation: Type 4.** Keep the current-state dimensions (`question`, `response`, `source_question`)
exactly as they are now — one clean row per concept, holding the live value — and add a **separate version
overlay** per entity that actually versions. Rationale:

- **The common path stays foolproof.** ~99% of analysis wants the current label with a simple 1:1 join.
  Type 4 keeps `responses → question` matching exactly one row, so no query needs to remember
  `AND is_current`. (Type 2 would break this — a missed filter silently double-counts.)
- **We already removed Type 3.** The `current_`/`v1_` prefixes were Type 3 in disguise: mostly-null version
  columns bloating every row and capping history at a fixed number of priors. Normalizing those into rows
  is the Type-4 move.
- **History becomes opt-in, not mandatory.** Version-aware analysis joins the overlay; everyone else never
  sees it.

### Which mechanism per pattern (the "version attribute vs. concept relationship" rule)

The overlay is not one-size-fits-all — the discriminator is **whether the source minted a new concept ID**:

| | Same concept ID kept (Pattern 3) | New concept ID minted (Pattern 4) |
|---|---|---|
| Example | `899251483` → `899251483_V2` (same ID, options changed) | sex-at-birth restructured → new CID `407056417` |
| Mechanism | **version attribute**: `question_version` on the fact (already present) + version-scoped `response_options` + a `question_version` history row | **concept relationship**: `concept_relationship` (`replaces`/`replaced_by`) + `successor_concept_id` on `question` |
| Why | The dictionary keeps the ID; fabricating per-version IDs would violate the concept-ID spine (principle #1) | Two *real* distinct IDs already exist; the link between them is the data |

Do **not** mint synthetic per-version IDs to force everything through `concept_relationship` — that fights the
source. And do **not** express a genuine new-ID replacement as an attribute history — that link is *between
two IDs*, not an attribute of one.

### Structure

```
responses ──question_concept_id──────────────▶ question           (current: 1 row/concept — default join)
     │
     └──(question_concept_id, question_version)─▶ question_version  (history: 1 row/version — opt-in)

question ──successor_concept_id──▶ question   (Pattern 4: deprecated CID → replacement CID)
```

The `question` dimension carries the *current* value plus lightweight, **typed** version descriptors (not a
boolean — see below). The `question_version` overlay carries the full per-version detail.

```sql
-- current dimension: unchanged, plus typed version descriptors
question(
  question_concept_id,      -- PK, one row per concept
  question_text,            -- CURRENT wording
  question_type,
  status,                   -- Deprecated | Revised | New | (blank)
  max_version,              -- highest _vN seen (1, 2, 3…)
  deprecated_at,            -- DATE, Pattern 4
  successor_concept_id      -- FK -> question, Pattern 4 replacement
)

-- version overlay (SCD Type 4 history side): one row per (concept, version)
question_version(
  question_concept_id,          -- FK -> question
  version,                      -- 1, 2, …
  question_text,                -- wording AS OF this version
  source_question_concept_id,   -- placement AS OF this version
  status,                       -- Deprecated | Revised | New | Current
  status_date,
  replaced_by_concept_id        -- optional, for option/question supersession
)
```

Option-set membership changes (an option added/dropped) ride in the **version-scoped option set** —
`response_options` keyed by `(question_concept_id, version, response_concept_id)` — because "an option was
added" is a change to a *set*, not a scalar field, so it doesn't belong in `question_version`.

### Worked example — tooth-loss `899251483`

**`question` (current — the clean default):**

| question_concept_id | question_text | status | max_version |
|---|---|---|---|
| 899251483 | *(current wording)* | Revised | 2 |

**`question_version` (history overlay):**

| question_concept_id | version | question_text | status | status_date |
|---|---|---|---|---|
| 899251483 | 1 | *(v1 wording)* | Deprecated | 2022-… |
| 899251483 | 2 | *(v2 wording)* | Current | 2023-… |

**version-scoped `response_options` (the option *set* per version):**

| question_concept_id | version | response_concept_id | label |
|---|---|---|---|
| 899251483 | 1 | 812107266 | accident |
| 899251483 | 1 | 452438775 | decay |
| 899251483 | 1 | 104430631 | No *(old)* |
| 899251483 | 2 | 812107266 | accident |
| 899251483 | 2 | 452438775 | decay |
| 899251483 | 2 | 886864375 | other reason *(new)* |
| 899251483 | 2 | 551489317 | No *(new)* |

A participant answering under v1 has `responses` rows with `question_version = 1`; joining `question` gives
the current label ("what is this question"), while joining `question_version` + the version-scoped options
tells you they were only *offered* the v1 set — so the absence of "other reason" is *not offered*, not
*declined*.

### Query patterns

```sql
-- Everyday (unchanged; doesn't know versioning exists): current label, 1:1 join
SELECT q.question_text, r.*
FROM responses r
JOIN question q USING (question_concept_id);

-- Version-aware (opt-in): text/options AS THE PARTICIPANT SAW THEM
SELECT qv.question_text, r.*
FROM responses r
JOIN question_version qv
  ON qv.question_concept_id = r.question_concept_id
 AND qv.version            = r.question_version;
```

### Common operation: safe cross-version pooling

The single most common versioned-table operation is *"give me the distribution of answers to question X
across all participants"* — and it's exactly where a naive `GROUP BY question_concept_id` goes wrong, because
v1 and v2 may have offered different options (Pattern 3) or the concept may have been replaced outright
(Pattern 4). The Type-4 tables make the safe version straightforward.

**(a) Pattern 4 — normalize deprecated CIDs to their successor *before* grouping**, so answers to a
replaced-concept question pool with its replacement:

```sql
WITH normalized AS (
  SELECT COALESCE(q.successor_concept_id, r.question_concept_id) AS q_cid,
         r.response_value_as_concept_id
  FROM responses r
  JOIN question q USING (question_concept_id)
)
SELECT n.q_cid, resp.format_value AS answer, COUNT(*) AS n
FROM normalized n
LEFT JOIN response resp ON resp.response_concept_id = n.response_value_as_concept_id
GROUP BY n.q_cid, answer
ORDER BY n DESC;
```

**(b) Pattern 3 — pool a same-CID question but keep comparability visible.** Tag each answer with the
version it was collected under and with *how many versions offered that option*, so an option that existed in
only one version (the new "other reason") surfaces instead of silently merging into a rate whose denominator
differs by version:

```sql
-- comparability lookup: how many versions offered each option
WITH opt_versions AS (
  SELECT response_concept_id, COUNT(DISTINCT version) AS versions_offered
  FROM response_options
  WHERE question_concept_id = '899251483'
  GROUP BY response_concept_id
)
SELECT resp.format_value  AS answer,
       r.question_version,
       COUNT(*)           AS n,
       ov.versions_offered            -- 1 = version-specific (pool with care); 2 = offered in both
FROM responses r
LEFT JOIN response     resp ON resp.response_concept_id = r.response_value_as_concept_id
LEFT JOIN opt_versions ov   ON ov.response_concept_id   = r.response_value_as_concept_id
WHERE r.question_concept_id = '899251483'
GROUP BY answer, r.question_version, ov.versions_offered
ORDER BY r.question_version, n DESC;
```

`versions_offered` is the guardrail: options seen in *every* version are safe to pool; options seen in only
one are reported on their own. (This is the structured version of the hand-`COALESCE` reconciliation the
pain-exhibit repos do by column name.)

### On an `is_versioned` flag — derive it, don't store it

Tempting, but a stored boolean is (1) **lossy** — "versioned" conflates repeat-administration (Pattern 1),
minor `_rN` revision (Pattern 2), same-ID option change (Pattern 3), and new-ID replacement (Pattern 4) —
and (2) **derived**, so storing it invites drift when a new version lands (against principle #4, "metadata is
generated, not authored"). In Type 4 the question answers itself:

```sql
-- convenience flag as a VIEW column, never an authored/stored column
CREATE OR REPLACE VIEW v_question AS
SELECT q.*,
       (q.max_version > 1 OR q.status IN ('Deprecated','Revised')) AS is_versioned
FROM question q;
```

Keep the *typed* descriptors (`status`, `max_version`, `successor_concept_id`) on the dimension; let the
boolean fall out of them in the view. On the fact, don't add a flag either — a pooling hazard is already
detectable via `COUNT(DISTINCT question_version) OVER (PARTITION BY question_concept_id) > 1`.

### Populating the overlay from the data dictionary

The neat part: the dictionary *already* stores versions — but as **wide Type-3 columns**
(`Current / V1 / V2 Question Text`, `Current / V1 / V2 Source Question`), which is the very shape we're
normalizing away. So building the Type-4 overlay is the **same wide→long unpivot** we run for the `responses`
fact, applied to the dictionary's version columns.

| Overlay target | Data-dictionary source (`masterFile.csv`) | Transform |
|---|---|---|
| `question.status` | `Deprecated, New, or Revised` (col 12) | forward-fill to the question row |
| `question.added_at` / `deprecated_at` / `status_date` | `Date … Pushed to Prod` (col 13); `Date added or modified` (col 33) | forward-fill |
| `question.max_version` | the `_vN` in the SAS mnemonic (`Variable Label`, col 18) | parse `_v(\d+)`, take MAX per concept |
| `question_version` rows | `Current / V1 / V2 Question Text` + `Current / V1 / V2 Source Question` columns | **unpivot**: one row per non-null version column → `(question_concept_id, version, question_text, source_question_concept_id)` |
| version-scoped `response_options` | response concepts under the concept's v1 vs `_v2` physical columns + per-response `Deprecated/New` flags | reconcile **Quest > dictionary flags > columns** (the offered-set decision) |
| `question.successor_concept_id` | **not stored explicitly** — old is `Deprecated`, new is a separate row/CID | infer by matching the mnemonic **base** (`SrvBOH_SexAtBirth_*`) across a version bump; ambiguous pairs **hand-authored** |

Two honesty notes:

- **The same-CID vs new-CID split falls straight out of the source.** If the `_V2` variable keeps the concept
  ID → a `question_version` row (Pattern 3, version attribute). If it carries a *new* concept ID → a
  `successor_concept_id` / `concept_relationship` link (Pattern 4). The transform branches on exactly that test.
- **`successor_concept_id` is the only non-mechanical part.** Everything else is forward-fill + unpivot +
  regex-parse; the deprecated→replacement links are curation (mnemonic-base matching gets most; the tail is
  hand-authored) — the "curation work, not schema work" called out in Summary of Scope. (If CIDTool later
  emits these version relationships directly, the overlay loads from CIDTool instead of being parsed from
  masterFile, like the other dimensions.)

### Added questions (`status = New`) — a birth, not a version conflict

Questions are genuinely **added over time**, not just revised. In `masterFile.csv`, **994 rows** are flagged
`New`, and **488 carry a `Date … Pushed to Prod`** spanning **June 2022 → May 2026** (per year: 2022 · 20,
2023 · 80, 2024 · 65, **2025 · 269**, 2026 · 54). Whole sections arrive at once — the **Cancer Screening
History** module alone contributes **226**.

This is distinct from the four version *patterns*: there is no v1 to pool with — the concept simply **did not
exist before its add date**. It maps to the overlay cleanly, and matters most for denominators:

- `question.status = 'New'` + `question.added_at` (the push-to-prod date); no `successor` link, no prior
  `question_version` row.
- **Absence of a response is not "missing" for a participant who finished the survey before the add date** —
  they were never offered the question. So the correct denominator for a `New` question excludes pre-add-date
  sessions: `session.completed_at < question.added_at` ⇒ *not offered* (distinct from asked-and-skipped).
  This is the same *offered-vs-not-offered* logic as option-set versioning, one level up (whole question,
  keyed on date). Worth stating for the view library, since a naive "N answered / total participants" rate
  silently understates a recently-added question.

This is enhancement §3's resolved shape, and it is where `v1_source_question` (removed from the core
`source_question` dim in the column-rename PR) lands: as a `source_question_version` overlay row under the
same Type-4 pattern, if/when the need is pulled in.

---

## Summary of Scope

| Dimension | Count |
|---|---|
| Survey variables with any versioning | 691 (19% of survey rows) |
| Variables in BQ with true dancing pairs (v1 + v2 column) | 17 |
| Variables in BQ with v2-only column (replacement) | 47 |
| Survey variables marked Deprecated | 407 |
| Variable bases with multiple versions in the current dictionary | 2 |
| Distinct secondary sources with >10% deprecated rows | 3 (COVID-19, Blood/Urine, Blood/Urine/Mouthwash) |

The version-handling problem is **real but bounded**: 81% of variables are untouched `v1r0`, 7% are transparent minor revisions, and the remaining 12% split between repeat administrations (Pattern 1) and concept replacements (Patterns 3 & 4). The biggest lift is authoring the `successor_cid` links for deprecated→replaced pairs — that is curation work, not schema work.

---

*This document was generated as a design-phase reference for the version handling enhancement (backlog §3). All counts are from `data_dictionary/masterFile.csv` and `schemas/stage/CleanConnect/*.json`. No BigQuery queries were run.*
