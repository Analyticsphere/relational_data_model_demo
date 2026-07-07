# Connect Survey Question Types

*Survey date: 2026-07-07 · Source: `data_dictionary/masterFile.csv` + `episphere/quest` module1.txt*

---

## Purpose

This document surveys every `Question Type` value found in the Connect data dictionary across all survey rows. For each type it provides:
- A description of what it means structurally
- Quest markup syntax (where available from `module1.txt`)
- Representative dictionary examples (variable name, concept ID, secondary source)
- Data/storage implications relevant to the relational model

It also summarises the distribution and flags consolidation opportunities — a prerequisite for deciding whether `question_type` can become a well-typed enum in the `question` dimension.

---

## Methodology

- **Source**: `data_dictionary/masterFile.csv` column index 35 (`Question Type`), filtered to `Primary Source = Survey` (3,848 rows total; 1,724 with a non-blank `Question Type` value).
- **Quest cross-reference**: `episphere/quest/questionnaires/module1.txt` (the only published baseline module as of 2026-06).
- **Stage data**: Column-to-dictionary mapping cross-checked against `output/survey_columns_stage_mapped.csv`. No direct BigQuery queries were run — per project policy, all analysis uses schemas and dictionary only.

---

## Distribution of Question Types (Survey rows only)

The raw dictionary contains 44 distinct non-blank values in the `Question Type` column for survey rows. Many are typo or modifier variants of a smaller set of logical types.

| Raw Question Type | Count | Canonical Group |
|---|---:|---|
| Optional Select All that Apply | 387 | Select-All-That-Apply |
| Or (xor=) Question (either/or text boxes without radio button), Loops | 190 | XOR / Age-or-Year |
| Grid with Multiple Choice Sub-Questions | 180 | Grid |
| Optional Multiple Choice | 155 | Multiple Choice |
| Or (xor=) Question (either/or text boxes without radio button) | 160 | XOR / Age-or-Year |
| Optional Select All that Apply, Loops | 110 | Select-All-That-Apply |
| Multiple Choice | 96 | Multiple Choice |
| Nested | 71 | Nested / DisplayIf |
| Select All That Apply | 44 | Select-All-That-Apply |
| Optional Multiple Choice, Loops | 42 | Multiple Choice |
| Optional Select All that Apply, Displayif in One or More Responses | 38 | Select-All-That-Apply |
| Select all that apply *(case variant)* | 35 | Select-All-That-Apply |
| Text Box Plus Check Box | 30 | Text Box + Check Box |
| Optional Multiple Choice with Text Box (text in text box) | 24 | MC + Free Text |
| Text only Response *(case variant)* | 15 | Free Text |
| Text Only Response | 13 | Free Text |
| Multiple Text Boxes | 12 | Multiple Text Boxes |
| Text Only Response, loops | 11 | Free Text |
| Text Box Plus Check Box, Loops | 10 | Text Box + Check Box |
| Special Functions | 9 | Special / Time Picker |
| Optional Select All That Apply, DisplayIf in One or More Responses *(case variant)* | 9 | Select-All-That-Apply |
| Required Select All that Apply | 8 | Select-All-That-Apply |
| Multiple Text Boxes, Loops | 8 | Multiple Text Boxes |
| Required Multiple Choice | 7 | Multiple Choice |
| Mulitple Text Boxes *(typo)* | 7 | Multiple Text Boxes |
| Optional Multiple Choice, Displayif and Piped text | 7 | Multiple Choice |
| Multiple choice *(case variant)* | 7 | Multiple Choice |
| Optional Multiple Choice with Text Box, Loops | 6 | MC + Free Text |
| Multiple Text Boxes, Display if in One or More Responses | 5 | Multiple Text Boxes |
| Text Only Response, Loops | 4 | Free Text |
| Special Function *(singular typo)* | 4 | Special / Time Picker |
| Optional multiple Choice *(case variant)* | 3 | Multiple Choice |
| Text only response *(case variant)* | 3 | Free Text |
| Optional Multiple Choice, Figures (with radio button to select one) | 2 | Multiple Choice |
| Text only Response, Loops *(case variant)* | 2 | Free Text |
| Self Populates Outside of Quest | 2 | Self-Populating / Derived |
| Multiple Choice with Text box (text in text box) | 2 | MC + Free Text |
| Multiple Choice with displayif and/or Piped Text | 1 | Multiple Choice |
| Optional Select All That Apply *(case variant)* | 1 | Select-All-That-Apply |
| Optional Multiple Choice, DisplayIf in One or More Responses | 1 | Multiple Choice |
| Mulitple Choice *(typo)* | 1 | Multiple Choice |
| Text box *(generic)* | 1 | Free Text |
| Dropdown Menu (single choice) | 1 | Multiple Choice |

**Blank / no value: 2,124 survey rows** — the largest single "category". See §9 below.

---

## Canonical Question Types

The 44 raw values collapse into **8 meaningful structural types** (plus the blank/unknown category).

---

### 1. Multiple Choice (`(n) option` in Quest)

**Description**: Participant selects exactly one option from a numbered list. In Quest, options are rendered with a radio button using `(n)` syntax. Subcategories in the dictionary (`Optional`, `Required`, `Figures`, `Displayif`, `Piped text`) reflect presentation modifiers, not a different interaction type.

**Quest syntax:**
```
[MARITAL?] Are you now married, widowed, divorced, separated, never married, or living with a partner?
(1) Never Married
(2) Not married but living with partner
(3) Married
(4) Divorced
(5) Widowed
(6) Separated
(99) Prefer not to answer

[AGECOR!] Based on the information you provided when you enrolled ...you are {$u:age} years old today. Is that correct?
(1) Yes -> MARITAL
(2) No
```
- `?` suffix = optional (can skip), `!` suffix = required.
- `-> TARGET` = skip to a target question (branch logic).
- `{$u:age}` = piped value from participant profile.

**Dictionary examples:**

| Variable | Concept ID | Secondary Source | Question Text |
|---|---|---|---|
| `SrvBOH_Marital_v1r0` | 783167257 | Background and Overall Health | Are you now married, widowed, divorced, separated, never married, or living with a partner? |
| `SrvScr_ORSCREEN_v1r0` | 802157786 | Cancer Screening History | Have you ever had an oral cancer screening? |
| `SrvBOH_SexAtBirth_v2r1` | 407056417 | Background and Overall Health | What is your sex? |
| `SrvBOH_HairFemale_v1r0` | 365851428 | Background and Overall Health | Which one of these female figures most closely resembles your hair pattern at age 40? *(Figures variant)* |
| `SrvCDx_DxMonth_v1r0` | 299768751 | Self-Reported Cancer Dx | What is the date of your diagnosis? - Month *(Dropdown variant)* |

**Modifiers seen in dictionary** (all map to the same storage pattern):
- `Optional` vs. `Required` — completion enforcement only
- `Displayif` / `Piped text` — conditional visibility or injected text
- `Figures` — image-based response (radio button still selects one value)
- `Dropdown Menu` — UI variant; still single-select

**Storage implication**: One `responses` row per answered question; `response_value` is the selected concept-ID code (a Num). No structural difference between sub-variants.

---

### 2. Select-All-That-Apply (`[n]` options in Quest)

**Description**: Participant may check any combination of checkboxes. Each option becomes an independent boolean (0/1) variable in BQ. In Quest, options use `[n]` syntax.

**Quest syntax:**
```
[RACEETH?] Which categories describe you? Select all that apply.
[1] American Indian or Alaska Native  -> RACEETH2
[2] Asian  -> RACEETH3
[3] Black, African American, or African -> RACEETH4
...
[8] None of these fully describe me: Please describe [text box:RACEETH_TB]
[99] Prefer not to answer
< -> LANG >
```
- `[n]` = checkbox option; multiple may be selected simultaneously.
- `[text box:ID]` = inline free-text field associated with a specific option (see §5).
- `< -> TARGET >` = unconditional jump to target after the question.

**Dictionary examples:**

| Variable | Concept ID | Secondary Source | Question Text |
|---|---|---|---|
| `SrvBOH_AlaskaNative_v1r0` | 583826374 | Background and Overall Health | American Indian or Alaska Native *(option within race/ethnicity SATA)* |
| `SrvMtW_PERMTTHLOST1_v1r0` | 812107266 | Blood/Urine/Mouthwash | Yes, from accident or injury *(option within tooth-loss SATA)* |
| `SrvROI_IntCommSpaces_v1r0` | 362882148 | 2026 ROI Preference Survey | Community spaces |
| `SrvBOH_Penis_v2r0` | 582784267 | Background and Overall Health | Penis (Phallus) *(Required SATA — sex anatomy question)* |

**Modifiers seen in dictionary:**
- `Optional` vs. `Required` — completion enforcement
- `DisplayIf in One or More Responses` — one or more options become visible only based on prior answers
- `Loops` — the question repeats per loop iteration (sibling/child family history)

**Storage implication**: One `responses` row *per option* that is checked (value = 1) or unchecked (value = 0). The "select all" parent question is represented by a `source_question_concept_id`; each option is a distinct `question_concept_id`. This is the type that most aggressively inflates column count in the wide schema.

---

### 3. XOR / Age-or-Year (`xor=` text boxes in Quest)

**Description**: Participant fills in **either** field A **or** field B — not both. The canonical Connect use-case is "age at diagnosis *or* year at diagnosis" — if the participant provides age, the year box is suppressed, and vice versa. This is rendered as two numeric text boxes with mutual exclusion enforced by Quest's `xor=` attribute.

**Quest syntax:**
```
[SKINCANC3?] How old were you when you first learned you had skin cancer?

|__|__|xor=SKINCANC3 id=SKINCANC3_AGE min=0 max=isDefined(AGE,age)| Age at diagnosis
|__|__|__|__|xor=SKINCANC3 id=SKINCANC3_YEAR minval=... max=#currentYear| Year at diagnosis
```
- `|__|__|` = text input box of that width.
- `xor=GROUP_ID` = mutual exclusion group — entering a value in one clears the other.
- `min=` / `max=` / `minval=` = validation constraints.

**Dictionary examples:**

| Variable | Concept ID | Secondary Source | Question Text |
|---|---|---|---|
| `SrvBOH_SkinCancAge_v1r1` | 206625031 | Background and Overall Health | Age at diagnosis |
| `SrvBOH_SkinCancYear_v1r0` | 261863326 | Background and Overall Health | Year at diagnosis |
| `SrvBOH_AnemiaAge_v1r1` | 206625031 | Background and Overall Health | Age at diagnosis |

> Note: The same concept ID (e.g. 206625031 for "Age at diagnosis") is reused across many conditions. The `source_question_concept_id` distinguishes which condition the age belongs to.

**Storage implication**: Two `responses` rows per XOR pair — one for age, one for year — but at most one will have a non-null value. Conceptually a single "when" fact expressed in whichever unit the participant chose. Typed value columns in the relational model would separate `value_num` (age) from `value_year` (year).

---

### 4. Grid with Multiple Choice Sub-Questions

**Description**: A tabular layout where one axis lists items (rows) and the other axis provides a fixed set of radio-button responses (columns). Each cell is an independent multiple-choice variable. In BQ each cell becomes its own column; in the relational model each becomes a `responses` row. The grid header question is tracked via `GridID/Source Question Name` in the dictionary.

**Quest syntax** (grid presented as repeated sub-questions sharing the same response scale):
```
[MEDS2C?] In the past 4 weeks, how often did you take each of the following medications?
                        Never  Less than once/wk  1-3x/wk  4-6x/wk  Daily
Tylenol® (Acetaminophen)   (0)         (1)           (2)      (3)     (4)
NSAIDs [aspirin, Advil...]  (0)         (1)           (2)      (3)     (4)
Medications to lower acid   (0)         (1)           (2)      (3)     (4)
...
```

**Dictionary examples:**

| Variable | Concept ID | Secondary Source | Question Text (sub-item) |
|---|---|---|---|
| `SrvBlU_Tylenol_v2r0` | 619765650 | Blood/Urine/Mouthwash | Tylenol® (Acetaminophen) |
| `SrvBlU_NSAIDs_v2r0` | 520755310 | Blood/Urine/Mouthwash | NSAIDs [such as aspirin, Advil®, Aleve®] |
| `SrvBlU_Acid_v1r0` | 839329467 | Blood/Urine/Mouthwash | Medications to lower stomach acid |
| `SrvQoL_PhysFnct1_v1r0` | 559540891 | Quality of Life | Are you able to do chores such as vacuuming or yard work? |

**Storage implication**: Structurally identical to Multiple Choice at the row level — each sub-question gets one `responses` row. The `source_question_concept_id` (the grid's parent question) groups all sub-questions. The `Nested` type (see §6) is similar; the dictionary does not always distinguish grids from nested MC blocks consistently.

---

### 5. MC + Free Text (`MC with Text Box` / SATA with inline `[text box]`)

**Description**: A multiple-choice or select-all question that includes one option wired to a free-text field. The most common form is `Other: Please describe [text box]`. The text box is a separate variable in BQ (`_Desc` or `_TB` suffix convention), linked to the parent question through the `source_question_concept_id`.

**Quest syntax:**
```
[GEN?] Do you think of yourself as:
(1) Male
(2) Female
...
(6) Additional gender category: Please describe [text box:GEN_TB]
(99) Prefer not to answer
```
or in SATA:
```
[RACEETH?] Which categories describe you? Select all that apply.
[8] None of these fully describe me: Please describe [text box:RACEETH_TB]
```

**Dictionary examples:**

| Variable | Concept ID | Secondary Source | Question Text |
|---|---|---|---|
| `SrvBOH_Gender_v2r1` | 289664241 | Background and Overall Health | Gender - Do you think of yourself as: *(MC parent)* |
| `SrvBOH_GenderDesc_v1r0` | 918409306 | Background and Overall Health | Gender - Do you think of yourself as: [text box] *(Char companion)* |
| `SrvCDx_PrimarySite_v1r0` | 181737942 | Self-Reported Cancer Dx | What is the primary site of your cancer diagnosis? |
| `SrvCDx_PrimarySiteOth_v1r0` | 546976551 | Self-Reported Cancer Dx | What is the primary site of your cancer diagnosis - Other: please describe |
| `SrvBlU_COV28_v1r0` | 220055064 | Blood/Urine/Mouthwash | Which COVID-19 vaccine shot did you get? *(in loop)* |
| `SrvBlU_COV28Desc_v1r0` | 395747093 | Blood/Urine/Mouthwash | Which COVID-19 vaccine shot did you get? Please describe [text box] |

**Storage implication**: The MC parent and text-box companion are stored as separate `responses` rows linked by `source_question_concept_id`. The text-box row has `var_type = Char` and `value_text` in typed value columns; the MC parent row uses `value_num`.

---

### 6. Nested / DisplayIf

**Description**: A question whose *visibility* is conditioned on a prior response (`displayif=` in Quest) but which is itself a standard MC or SATA question. The dictionary uses "Nested" primarily for Quality of Life sub-questions that are always shown within a larger block (e.g. functional ability items under a parent prompt), and also for questions with response-level conditional branches.

**Quest syntax:**
```
[SEX2,displayif=equals(SEX,3)!] Later questions in this survey will ask about surgeries...
Please select the body parts that you were born with.
[1] Penis
[2] Testes
...
```
or at response level:
```
[MHGROUP1?] Have you ever been told...
[1,displayif=or(equals(SEX,2),...)] Uterine Fibroids -> UF
[2,displayif=or(equals(SEX,2),...)] Endometriosis -> ENDO
```

**Dictionary examples (Quality of Life block):**

| Variable | Concept ID | Secondary Source | Question Text |
|---|---|---|---|
| `SrvQoL_PhysFnct1_v1r0` | 559540891 | Quality of Life | Are you able to do chores such as vacuuming or yard work? |
| `SrvQoL_PhysFnct2_v1r0` | 917425212 | Quality of Life | Are you able to go up and down stairs at a normal pace? |
| `SrvQoL_PhysFnct3_v1r0` | 783201540 | Quality of Life | Are you able to go for a walk of at least 15 minutes? |

**Storage implication**: No structural difference from Multiple Choice at the `responses` row level. The skip logic is metadata (a future `skip_logic` dimension in the enhancement backlog). The dictionary's "Nested" label is inconsistently applied — some grids and conditional questions are also labelled Nested.

---

### 7. Text Box / Free Text / Multiple Text Boxes

**Description**: Participant types a free-form numeric or character response into one or more text input fields. Includes:
- **Single text box** — `Text only Response` / `Text Only Response` (age, count, weight, open-ended text)
- **Multiple text boxes** — height (feet + inches), address fields, multi-part dates
- **Text Box Plus Check Box** — a numeric text field paired with an "unavailable/unknown" checkbox as the alternative

**Quest syntax:**
```
[AGE!] How old are you today?
Age: |__|__|min=40 max=70|

[HEIGHTFEET?] How tall are you with your shoes off?
|__|__|id=HEIGHTFT min=0 max=10| Feet
|__|__|id=HEIGHTIN min=0 max=11| Inches

[SIBAGE?] How old is your sibling today?
|__|__|__|id=SIBAGE_AGE min=0 max=125| Sibling's age
[99] Don't know
```
- `|__|__|` = text input; width implied by number of `|__` pairs.
- `min=` / `max=` = validation; `id=` = variable binding.

**Dictionary examples:**

| Variable | Concept ID | Secondary Source | Type | Question Text |
|---|---|---|---|---|
| `SrvBOH_Age_v1r1` | 150344905 | Background and Overall Health | Num | How old are you today? |
| `SrvBOH_CurrentWeight_v1r0` | 746012894 | Background and Overall Health | Num | How much do you weigh without clothes or shoes on? |
| `SrvBOH_HeightFt_v1r0` | 340854069 | Background and Overall Health | Num | Height feet *(Multiple Text Boxes)* |
| `SrvBOH_HeightIn_v1r0` | 600462977 | Background and Overall Health | Num | Height inches *(Multiple Text Boxes)* |
| `SrvBOH_AddressL1_v1r0` | 284580415 | Background and Overall Health | Char | Alternative address line 1 |
| `SrvBOH_MotherAgeNum_v1r0` | 378988419 | Background and Overall Health | Num | How old is your mother today?, Number *(Text Box Plus Check Box)* |
| `SrvBOH_MotherAge_v2r0` | 178420302 | Background and Overall Health | Num | Unavailable/Unknown *(checkbox companion — value 0/1)* |
| `SrvROI_OthPref_v1r0` | 395168461 | 2026 ROI Preference Survey | Char | Is there anything else you want to tell us... *(open text)* |

**Storage implication**: `value_num` for numeric text boxes, `value_text` for character boxes. "Text Box Plus Check Box" pairs always appear as two `responses` rows for the same parent question — one Num (the value), one binary (the "unknown" checkbox). The Multiple Text Boxes subtype groups conceptually-linked inputs (e.g. feet + inches) under the same `source_question_concept_id`.

---

### 8. Special Functions / Time Picker

**Description**: Quest UI widgets that are neither radio buttons nor plain text boxes — primarily dropdown time selectors (HH:MM AM/PM) and month/year pickers. Limited to ~13 variables in the Blood/Urine/Mouthwash biospecimen collection module.

**Dictionary examples:**

| Variable | Concept ID | Secondary Source | Type | Format | Question Text |
|---|---|---|---|---|---|
| `SRVBIO_EATDRINKTIME_V1R0` | 191057574 | Blood/Urine/Mouthwash | Time | HH:MM AM/PM | At about what time did you last eat or drink anything other than water before donating your samples? |
| `SRVBIO_SLEEPTIME_V1R0` | 299417266 | Blood/Urine/Mouthwash | Time | HH:MM AM/PM | What time did you go to sleep on the night before donating your samples? |
| `SRVBIO_WAKETIME_V1R0` | 689861450 | Blood/Urine/Mouthwash | Time | HH:MM AM/PM | What time did you wake up on the day that you donated your samples? |
| `SrvBlU_COV27_MY_v1r0` | 141616126 | Blood/Urine/Mouthwash | Month | YYYY-MM | When were you vaccinated? MY |

**Storage implication**: Stored as `value_text` in the current schema (ISO string). A typed value column `value_datetime` or `value_time` would be appropriate for the time-picker questions.

---

### 9. Self-Populating / Derived

**Description**: Value is populated outside the Quest instrument — either derived from a prior system record, a calculation, or an API integration. Examples include occupation category (populated from an O*NET lookup based on job title) and the age confirmation question (populated from enrollment data).

**Dictionary examples:**

| Variable | Concept ID | Secondary Source | Question Text |
|---|---|---|---|
| `SrvBOH_OccupationCat_v1r1` | 761310265 | Background and Overall Health | Please identify the occupation category that best describes this job. - current |
| `SrvBOH_PastOccupCat_v1r1` | 279637054 | Background and Overall Health | Please identify the occupation category that best describes this job. - longest held |

**Storage implication**: Same `responses` row structure. Conceptually these are "system-filled" rather than "participant-answered" — a future `response_source` attribute on the `responses` fact could distinguish them.

---

## Consolidation Analysis

### What can be merged

The 44 raw values compress to ~8 structural types because most variation is one of:

| Variation | Examples | Recommendation |
|---|---|---|
| **Capitalisation** | `Text only Response`, `Text Only Response`, `Text only response` | Normalise to a single canonical casing |
| **Typos** | `Mulitple Choice`, `Mulitple Text Boxes` | Fix at source in dictionary |
| **Optional vs. Required modifier** | `Optional Multiple Choice`, `Required Multiple Choice`, `Multiple Choice` | Collapse to base type; express required/optional as a separate boolean attribute |
| **Loop modifier** | `…, Loops` suffix | Collapse to base type; loops are a structural property of the source question block, not the question type itself |
| **DisplayIf modifier** | `…, Displayif in One or More Responses` | Collapse to base type; `displayif` is skip logic metadata |
| **Piped text modifier** | `…, Displayif and Piped text` | Collapse to base type; piped text is a rendering property |
| **Dropdown vs. Radio** | `Dropdown Menu (single choice)` vs. `Multiple Choice` | Merge: same data structure, different UI widget |
| **Figures** | `Optional Multiple Choice, Figures (with radio button to select one)` | Merge into Multiple Choice; note as image-based in question metadata if needed |
| **Case + singular/plural** | `Special Functions` vs. `Special Function` | Fix at source |
| **Mixed-case SATA** | `Select All That Apply`, `Select all that apply`, `Optional Select All that Apply`, `Optional Select All That Apply` | Normalise to a single term |

### Proposed canonical enum (8 values)

```
MULTIPLE_CHOICE
SELECT_ALL_THAT_APPLY
XOR_AGE_OR_YEAR
GRID
TEXT_FREE
MULTIPLE_TEXT_BOXES
MC_WITH_TEXT_BOX
SPECIAL_FUNCTION
```

These 8 values cover all structurally distinct cases. Modifiers (`required`, `optional`, `has_loop`, `has_displayif`, `has_piped_text`, `has_inline_text_box`) should be separate boolean columns on the `question` dimension rather than encoded in the type string. This gives cleaner filter queries and avoids combinatorial explosion in the type taxonomy.

### What should stay distinct

- **XOR / Age-or-Year** should remain separate from plain `Multiple Text Boxes` — the mutual exclusion constraint is semantically significant (it means "age *or* year, not both") and affects how null values are interpreted in the relational model.
- **Grid** should remain separate from `Nested` — while both render as sub-questions under a parent, grids have a fixed shared response scale across all rows, which the relational model may want to leverage for efficient column labelling.
- **Text Box Plus Check Box** (e.g. "age, or Unknown") is structurally a `TEXT_FREE` + `MULTIPLE_CHOICE` pair and could be modelled as `MC_WITH_TEXT_BOX` in reverse — but it is common enough to warrant explicit documentation in the `question` dimension.

---

## Data Quality Issues in the Dictionary

| Issue | Examples | Count (approx.) |
|---|---|---|
| **Blank `Question Type`** for survey rows | Non-survey rows and many older/non-module entries | 2,124 survey rows |
| **Notes accidentally entered as question type** | "Question text also for HdRef_Privacy_v1r0", "Updated Secondary Source to…" | ~10 rows |
| **Typos** | `Mulitple Choice`, `Mulitple Text Boxes` | ~8 rows |
| **Capitalisation inconsistency** | `Text only Response` vs `Text Only Response` vs `Text only response` | ~30 rows |
| **Loop / Modifier suffixes bloating the taxonomy** | `…, Loops`, `…, Displayif in One or More Responses` | ~450 rows |

The 2,124 blank rows are the largest issue. Spot-checking shows they are predominantly:
- Non-baseline-module surveys (Quality of Life, COVID, ROI Preference Survey) that were added after the `Question Type` column convention was established
- Recruitment and biospecimen variables where the column was never filled in

**Recommendation**: Before any ETL populates a `question_type` dimension column, the dictionary should be cleaned: fix typos, normalise casing, fill blanks for survey rows, and strip modifiers into separate fields. The 8-value enum above provides a target schema.

---

## Summary Table by Canonical Type

| Canonical Type | Quest Syntax | BQ `var_type` | Est. Survey Rows | Key Distinction |
|---|---|---|---:|---|
| **Multiple Choice** | `(n) option` | Num | ~350 | Single select; one `responses` row |
| **Select-All-That-Apply** | `[n] option` | Num (0/1) | ~640 | One row per option; boolean per option |
| **XOR / Age-or-Year** | `\|__\| xor=GROUP` | Num / Year | ~350 | Paired; at most one has a value |
| **Grid** | Repeated MC sub-questions | Num | ~180 | Sub-questions share a response scale |
| **Free Text** | `\|__\|` text input | Num or Char | ~80 | Open-ended numeric or character |
| **Multiple Text Boxes** | Multiple `\|__\|` fields | Num / Char | ~50 | Conceptually one question; multiple boxes |
| **MC + Free Text** | `(n) option + [text box]` | Num + Char | ~50 | Two rows: MC parent + Char companion |
| **Special Function** | Dropdown time/date pickers | Time / Month | ~13 | Non-standard widget; ISO string storage |
| **Self-Populating / Derived** | n/a (system-filled) | Char | ~2 | Not participant-answered |
| **Unknown (blank)** | — | — | ~2,124 | Needs backfill |

---

*This document was generated as a design-phase reference. Quest markup examples are from `episphere/quest/questionnaires/module1.txt` (Background and Overall Health). The remaining modules (Blood/Urine/Mouthwash, COVID, QoL, etc.) follow the same Quest conventions but are not published as standalone `.txt` files in the questionnaires directory as of 2026-06.*
