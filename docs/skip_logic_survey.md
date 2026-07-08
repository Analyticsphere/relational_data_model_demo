# Connect Survey Skip Logic

*Survey date: 2026-07-07 · Source: `episphere/quest/questionnaires/module1.txt` + `data_dictionary/masterFile.csv`*

---

## Purpose

This document surveys every skip-logic mechanism used in the Connect Quest surveys, focusing on `module1.txt` (Background and Overall Health — the only published baseline module as of 2026-06). It documents:

- The distinct skip-logic mechanisms and their Quest syntax
- Quantitative distribution of each pattern
- Expression complexity and what fraction is machine-parseable
- The key "trigger" variables that drive the majority of branching
- Implications for the relational model's `skip_logic` enhancement (backlog §4)

The goal is to scope the engineering effort required to turn Quest skip logic into first-class queryable data, and to identify the hard tail that requires a raw-expression fallback.

---

## Methodology

- **Source**: `episphere/quest/questionnaires/module1.txt` (2,381 lines, 286 questions). Module1 is the most complex baseline module and is the recommended parser prototype target per the enhancement backlog.
- **Analysis**: regex-based extraction of all skip-logic patterns. No BigQuery queries were run.
- **Scope caveat**: module1 covers *Background and Overall Health* only. Other modules (Blood/Urine/Mouthwash, COVID, QoL, etc.) are not yet published as `.txt` files in the questionnaires directory — patterns are expected to be similar but the distribution will differ.

---

## Overall Coverage

| Metric | Count |
|---|---:|
| Total questions in module1 | 286 |
| Questions with **any** skip logic | 184 (64%) |
| Questions with **no** skip logic | 102 (36%) |
| Questions inside loop blocks | 64 (22%) |

Nearly two-thirds of questions have conditional behaviour. Skip logic is not a special case — it is the norm.

---

## The Eight Skip-Logic Mechanisms

### 1. `displayif=` on a question (whole-question gating)

**What it does**: The entire question is hidden or shown based on a prior response. The most common mechanism.

**Quest syntax:**
```
[SEX2,displayif=equals(SEX,3)!] Later questions in this survey...
Please select the body parts that you were born with.
[1] Penis
[2] Testes
...

[BLDTRANS3?,displayif=greaterThanOrEqual(NUMBLDTRANS2,1)] How old were you when you had your first blood transfusion?

[WTLOSS1_1825?,displayif=greaterThanOrEqual(percentDiff(WEIGHTHIS1,WEIGHTHIS2),.05)] Did you lose weight on purpose between ages 18 and 25?
```

The `displayif=` attribute is placed after the question name and before the `?`/`!` suffix. A question without `displayif` is always shown.

**Occurrences in module1**: **127 questions** have a question-level `displayif`.

---

### 2. `displayif=` on a response option (individual option gating)

**What it does**: A specific answer option is hidden or shown based on prior responses. Used heavily in sex/anatomy-gated questions where the *menu* of options changes per participant.

**Quest syntax:**
```
[MHGROUP1?] Have you ever been told you have any of the following conditions?
[1,displayif=or(equals(SEX,2),and(equals(SEX,3),equals(SEX2,6)))] Uterine Fibroids -> UF
[2,displayif=or(equals(SEX,2),and(equals(SEX,3),equals(SEX2,6)))] Endometriosis -> ENDO
[3,displayif=or(equals(SEX,2),and(equals(SEX,3),equals(SEX2,7)))] Polycystic Ovary Syndrome (PCOS) -> PCOS
[4,displayif=or(equals(SEX,1),and(equals(SEX,3),equals(SEX2,3)))] Enlarged Prostate -> ENLGPROS
```

**Occurrences in module1**: **23 individual response options** gated by `displayif`.

---

### 3. `-> TARGET` response-level branch (answer-triggered jump)

**What it does**: Selecting a specific answer jumps the participant to a named question, skipping everything in between. Used to route participants through condition-specific follow-up blocks or to skip inapplicable sections.

**Quest syntax — simple (no condition):**
```
[SKINCANC?] Has a doctor ever told you that you have non-melanoma skin cancer?
(1) Yes -> SKINCANC2
(0) No
< -> MHGROUP1 >

[AGECOR!] Based on your enrollment data, you are {$u:age} years old today. Is that correct?
(1) Yes -> MARITAL
(2) No
```

**Quest syntax — combined with displayif:**
```
[1,displayif=or(equals(SEX,2),...)] Uterine Fibroids -> UF
```
*Here the option is only shown to eligible participants and, if selected, routes to the follow-up block.*

**Occurrences in module1**:

| Branch type | Count |
|---|---:|
| Always-skip (no `displayif` on the option) | 192 |
| Conditional option + branch | 22 |
| **Total response-level branches** | **214** |

Top branch targets: `BREASTSUR2` (10), `_CONTINUE` (4), `GEN` (2), `INCOME` (2), `WORK7` (2). The special target `_CONTINUE` means "resume sequential flow from where you would have been" — it is Quest's explicit no-op jump.

---

### 4. Unconditional end-of-question jump `< -> TARGET >`

**What it does**: After the last response option is rendered (whether or not the participant answered), flow jumps unconditionally to the named question. Used to delimit skip blocks — a "Yes" branch routes into a follow-up section, and the unconditional jump at the end of that section routes back to the main flow.

**Quest syntax:**
```
[SKINCANC?] Has a doctor ever told you... non-melanoma skin cancer?
(1) Yes -> SKINCANC2
(0) No
< -> MHGROUP1 >           ← jump to next major section if No

[SKINCANC2?] When were you first told...
...
< -> MHGROUP1 >           ← also jump after follow-up block completes
```

**No-response default variant** `< #NR -> TARGET >`:  
If the participant does not answer the question at all (explicit non-response), route to `TARGET`. Used on required questions where Quest needs an explicit fallback routing rule.

```
[HYSTER?] Have you had a hysterectomy?
(1) Yes -> HYSTER2
(0) No
< #NR -> HYSTER >         ← loop back to the question if not answered (enforcement)
```

**Occurrences in module1**:

| Jump type | Count |
|---|---:|
| Unconditional `< -> TARGET >` | 57 |
| No-response default `< #NR -> TARGET >` | 8 |

---

### 5. `<loop>` block (repeated question set)

**What it does**: A block of questions that repeats up to `max` times, once per iteration of a family-history element (sibling, child). The loop count is driven by a prior numeric answer (`NUMSIB`, `NUMKIDS`). Within the loop, `#loop` is the current iteration index.

**Quest syntax:**
```
<loop max=25>
[SIB2?|firstquestion=#loop loopmax=NUMSIB|] Thinking of your
  |displayif=equals(#loop,1)|oldest|
  |displayif=greaterThan(#loop,1)|next oldest| sibling,
  what physical sex was this sibling assigned at birth?
(2) Female
(1) Male
(3) Intersex or other
(77) Don't know

[SIB3?] Is he/she a full or half sibling?
...
</loop>
```

- `firstquestion=#loop loopmax=NUMSIB` — entry condition: loop iterates as long as `#loop ≤ NUMSIB`.
- `#loop` — the current iteration counter, usable in `displayif` and inline text.
- `max=25` — hard cap preventing runaway loops.
- Within loop blocks, `displayif` still works normally and references earlier responses within the same loop iteration.

**Occurrences in module1**: **2 loop blocks** (siblings, children), each with `max=25`. Combined they contain 64 questions (32 unique question templates × 2 blocks).

---

### 6. XOR mutual exclusion (`xor=GROUP` on text inputs)

**What it does**: Two or more text input fields share an exclusion group — entering a value in one automatically clears the others. The canonical use case is "age at diagnosis *or* year of diagnosis — not both."

**Quest syntax:**
```
|__|__|xor=SKINCANC3 id=SKINCANC3_AGE min=0 max=isDefined(AGE,age)| Age at diagnosis
|__|__|__|__|xor=SKINCANC3 id=SKINCANC3_YEAR minval=... max=#currentYear| Year at diagnosis
```

Both fields share `xor=SKINCANC3`. Entering age clears year and vice versa.

**Occurrences in module1**: **161 XOR groups** — every condition's "age at diagnosis / year at diagnosis" pair gets its own group. There are ~80 medical conditions with this pattern in module1.

---

### 7. Soft-edit / modal validation (`softedit=true modalif=`)

**What it does**: A non-blocking range check. If the entered value meets the `modalif` condition (e.g. weight < 70 lbs), Quest shows a modal dialog asking the participant to confirm. The value is not rejected — it is a soft prompt, not a hard constraint.

**Quest syntax:**
```
[WEIGHT?] How much do you weigh without clothes or shoes on?
|__|__|__|min=0 max=999 softedit=true modalif=value<70 modalvalue='Is this weight correct?'| #Pounds
```

**Occurrences in module1**: **7** (all weight-history questions).

---

### 8. Inline conditional text `||condition|text|`

**What it does**: Within a question prompt, substitutes alternative text depending on a prior response. Used pervasively for pronoun substitution (he/she/they), loop-iteration labels (oldest/next oldest), and sex-specific question wording.

**Quest syntax:**
```
[SIBDEATH?] How old was
  |displayif=equals(SIB2,1)|he|
  |displayif=equals(SIB2,2)|she|
  |displayif=or(equals(SIB2,3),or(equals(SIB2,77),equals(SIB2,undefined)))|your sibling|
  when they died?

[WEIGHTHIS?] How much did you weigh when you were...
a. 18 years old
...
|displayif=greaterThanOrEqual(isDefined(AGE,age),45)|d. 45 years old |
```

**Occurrences in module1**: **97** inline conditional text blocks.

---

## Summary Counts

| Mechanism | Occurrences | Scope |
|---|---:|---|
| `displayif=` on question | 127 | Whole question show/hide |
| `displayif=` on response option | 23 | Individual option show/hide |
| Inline conditional text `\|\|condition\|text\|` | 97 | Wording substitution |
| Response-level branch `-> TARGET` | 214 | Route on answer |
| Unconditional jump `< -> TARGET >` | 57 | End-of-block routing |
| No-response default `< #NR -> TARGET >` | 8 | Non-answer fallback |
| XOR mutual exclusion | 161 groups | Age-or-year pairs |
| Loop blocks `<loop>` | 2 blocks / 64 Qs | Repeated family-history Qs |
| Soft-edit `softedit=true modalif=` | 7 | Soft range validation |

---

## Expression Complexity Analysis

All `displayif=` expressions use a prefix-notation functional syntax:

```
equals(VAR, VALUE)
or(expr, expr)
and(expr, expr)
greaterThan(VAR, VALUE)
greaterThanOrEqual(VAR, VALUE)
isDefined(VAR, default)
isNotDefined(VAR, default)
percentDiff(VAR1, VAR2)
difference(VALUE1, VALUE2)
```

### Function frequency in `displayif` expressions

| Function | Occurrences |
|---|---:|
| `equals` | 497 |
| `or` | 232 |
| `greaterThanOrEqual` | 15 |
| `and` | 11 |
| `percentDiff` | 8 |
| `isDefined` | 4 |
| `isNotDefined` | 4 |
| `greaterThan` | 3 |

### Expression categories

| Category | Count | % | Parseable? |
|---|---:|---:|---|
| **Simple equals** — `equals(VAR, VALUE)` | 132 | 48% | ✅ trivial |
| **OR of equals** — `or(equals(...), equals(...))` | 115 | 42% | ✅ straightforward |
| **Numeric comparison** — `greaterThan`, `percentDiff` | 16 | 6% | ✅ with typed rule |
| **AND** — `and(equals(...), equals(...))` | 2 | <1% | ✅ straightforward |
| **Defined check** — `isDefined` / `isNotDefined` | 2 | <1% | ✅ with null-handling rule |
| **Complex nested** — `or(...and(...))` depth ≥ 3 | 9 | 3% | ⚠️ parseable with recursion |

**Key finding: 97% of expressions are structurally simple** — they collapse into 1–2 levels of `equals` / `or` / `and`. The 9 "complex nested" expressions are not exotic logic; they are all variants of the same sex/anatomy pattern repeated across many questions:

```
or(equals(SEX,2), and(equals(SEX,3), equals(SEX2,6)))   ← "female or intersex-with-uterus"
or(equals(SEX,1), and(equals(SEX,3), equals(SEX2,1)))   ← "male or intersex-with-penis"
```

A recursive descent parser handles all of these. No raw-expression fallback is needed for the `displayif=` sub-language itself. However, the expressions reference **Quest variable names** (e.g. `SEX`, `SEX2`, `NUMSIB`) not dictionary concept IDs — a Quest-name → concept-ID mapping table is required before these rules are usable with the `responses` fact.

### Special value references in expressions

| Reference | Occurrences | Meaning |
|---|---:|---|
| `#currentYear` | 161 | Current calendar year (evaluated at survey-time) |
| `isDefined(VAR, default)` | 240 | Returns `VAR`'s value or `default` if blank |
| `percentDiff(V1, V2)` | 8 | Proportional change between two answers (weight loss trigger) |
| `difference(V1, V2)` | 161 | Arithmetic difference (year bounds for diagnosis ranges) |
| `#loop` | 2 | Current loop iteration index |
| `#NR` | 8 | Explicit non-response sentinel |

`isDefined(AGE, age)` is the idiom used throughout module1 for "participant's age — use their enrolled age as the fallback if the age question was not answered." It appears in `min=` / `max=` validation bounds on text inputs and in `displayif` conditions that gate age-stratified questions.

---

## Key Trigger Variables

The following Quest variables are referenced most frequently in `displayif` expressions — they are the spine of the skip-logic graph. Questions downstream of these variables will have the most `responses` rows affected by missingness-vs-skipped ambiguity.

| Quest variable | References in `displayif` | Role |
|---|---:|---|
| `SIB4` | 101 | Is sibling still living? (gates age-of-death vs age-today) |
| `CHILD4` | 101 | Is child still living? (same pattern) |
| `MOM1` | 96 | Is mother still living? |
| `DAD` | 89 | Is father still living? |
| `SEX` | 31 | Sex assigned at birth (gates all anatomy/reproductive questions) |
| `SIB2` | 30 | Sibling sex (pronoun substitution in loop) |
| `CHILD2` | 30 | Child sex (pronoun substitution in loop) |
| `SEX2` | 13 | Anatomy details for intersex respondents (gates specific conditions) |
| `GEN` | 2 | Gender identity |
| `NUMSIB` / `NUMKIDS` | 1 each | Loop bounds |

**Observation**: The top 4 triggers (`SIB4`, `CHILD4`, `MOM1`, `DAD`) drive nearly 40% of all `displayif` references — all gating the same pattern: "if parent/sibling/child is deceased, ask age-at-death; if living, ask current age." This pattern repeats 64 times (once per sibling × 2 loops + parents).

`SEX` and `SEX2` together gate all reproductive/anatomy questions and drive the most *structurally complex* expressions. These 31+13 = 44 references produce the `or(equals(SEX,2), and(equals(SEX,3), equals(SEX2,N)))` family that accounts for most of the depth-≥3 expressions.

---

## Implications for the Relational Model

### What the `skip_logic` dimension needs to capture

Each skip-logic rule in the `responses` model needs to answer: *"For participant P answering question Q, should this response row exist, and if not, why not?"*

The proposed schema from backlog §4:

```
skip_logic (
  question_concept_id    INT64,   -- the gated question (or option)
  trigger_concept_id     INT64,   -- the prior question driving the condition
  operator               STRING,  -- equals | greaterThan | greaterThanOrEqual | isDefined | or | and
  trigger_value          STRING,  -- the value compared against (NULL for isDefined checks)
  action                 STRING,  -- hide_question | hide_option | jump_to
  target_concept_id      INT64,   -- for jump_to actions: the target question
  enable_behavior        STRING,  -- show_if | hide_if
  raw_expression         STRING   -- fallback: full unparsed expression for complex cases
)
```

Based on the module1 analysis, the fields break down as follows:

| Schema field | Driven by | Coverage |
|---|---|---|
| `question_concept_id` | Question name → concept ID mapping | All rules |
| `trigger_concept_id` | Quest variable name → concept ID mapping | All rules |
| `operator` + `trigger_value` | Parsed from `displayif=` expression | ~97% parseable |
| `action = hide_question` | Question-level `displayif` | 127 rules |
| `action = hide_option` | Response-level `displayif` | 23 rules |
| `action = jump_to` | `-> TARGET` branches | 214 rules |
| `action = unconditional_jump` | `< -> TARGET >` | 57 rules |
| `action = loop` | `<loop>` blocks | 2 block headers |
| `raw_expression` | Complex / unparseable fallback | ~9 edge cases |

### The Quest-name → concept-ID gap

**This is the critical blocker.** Quest uses short variable names (`SEX`, `MARITAL`, `SKINCANC`); the dictionary uses 9-digit concept IDs. The `skip_logic` dimension is only useful in the relational model if every `trigger_concept_id` resolves to the same concept ID spine used in `responses`. The mapping exists implicitly (the `Variable Name` column in the dictionary is derived from the Quest name), but it must be made explicit as a lookup table before rules can be operationalized.

### XOR pairs in the model

The 161 XOR age/year pairs represent a special class of skip logic: mutual exclusion on inputs. In the `responses` fact this appears as two rows for the same `source_question_concept_id`, at most one of which has a non-null value. The `skip_logic` dimension does not need to represent this — it is enforced at collection time and manifests as nullability in the data. However, documenting it as metadata (a `mutual_exclusion_group` attribute on `question`) would help analysts understand why one of the pair is always null.

### Loop depth and the `responses` fact

The two loop blocks (siblings, children) each iterate up to 25 times, creating up to 50 full copies of their 32-question template. This means up to 1,600 potential `responses` rows per participant for family history alone. The `source_question_concept_id` alone does not distinguish iteration 1 from iteration 25 — a future `loop_index` column on `responses`, or a derived `response_sessions` dimension (backlog §5), is needed to reconstruct the per-sibling/per-child structure.

---

## Consolidation / Normalization Observations

| Pattern | Count | Consolidation note |
|---|---:|---|
| Simple equals gate (`equals(VAR, VALUE)`) | 132 | Fully normalizable into structured rule row |
| OR of equals (`or(equals(...), equals(...))`) | 115 | Expand into multiple rule rows (one per equality arm) |
| `or(VAR, and(VAR, VAR2))` sex/anatomy pattern | ~44 | Template-able: one named rule type per anatomy gate |
| Response branch always routes to a follow-up block | 192 | Maps 1:1 to `jump_to` action |
| Unconditional jumps close skip blocks | 57 | Maps to `block_end` marker |
| XOR age/year pairs | 161 | Not skip logic per se; attribute on `question` |
| Loop blocks | 2 | Special `loop` action; `firstquestion`/`loopmax` as attributes |

The sex/anatomy `displayif` pattern (`or(equals(SEX,2), and(equals(SEX,3), equals(SEX2,N)))`) appears 44+ times with slightly varying `SEX2` values. This is the best candidate for a **named rule template** — define it once and reference it by name, reducing 44 raw expressions to a handful of parameterised entries.

---

## Data Quality / Dictionary Gap

The data dictionary (`masterFile.csv`) does not carry structured skip-logic information. The `Notes` and `Derivation Notes` columns contain free-text hints for ~1,353 rows (mostly non-survey), but these are not machine-readable. All structured skip logic lives in Quest markup only.

**Consequence**: there is no dictionary-side source of truth for skip logic — Quest is the sole authoritative source. Any `skip_logic` dimension must be generated by parsing Quest, not by reading the dictionary. This is the core engineering dependency for backlog §4.

---

*This document was generated as a design-phase reference for the `skip_logic` enhancement (backlog §4). All counts are from `episphere/quest/questionnaires/module1.txt`. Other survey modules follow the same Quest conventions and are expected to have similar patterns.*
