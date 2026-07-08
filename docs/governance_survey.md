# Connect Data Model — Governance & Sensitivity (feasibility)

*Survey date: 2026-07-08 · Source: `data_dictionary/masterFile.csv` + `schemas/stage/CleanConnect/*.json`*

---

## Purpose & framing

The governance enhancement (backlog §7) gates access to PR2 by sensitivity, in three release tiers
(**Sensitive / Core / Public**), enforced in BigQuery IAM. This is the **long pole** for external sharing —
and it is **nascent / in its infancy**. This document is a feasibility analysis, not a spec. It asks:

1. Can we classify sensitivity **objectively** (HIPAA-based), given that the dictionary's `PII` flag is not
   maintained? How many fields are we actually talking about?
2. What does each **release tier** need to transform, and where does that live in the model?
3. **How amenable is the long-format, dictionary-driven model to standard security techniques** —
   row-level, column-level, and table/dataset-level security?

Deliberately **not** relying on the `PII` flag alone (see §1). **Caveat:** the HIPAA classification below is a
**keyword heuristic** over question text — a defensible *lower-bound estimate* for scoping, **not** a
compliance-grade determination. Real classification is curation + legal review. **No BigQuery queries were
run.**

---

## 1. The `PII` flag is a hint, not a classification

The dictionary carries a `PII` column (index 26). Its current state:

| Value | Rows | Note |
|---|---:|---|
| *(blank)* | 8,271 | 62% of survey rows have no value |
| `No` / `NO` | 4,405 | casing drift already present |
| `Yes` | 447 | the only positive signal |

At the **question-concept** grain: **437 concepts flagged `PII=Yes`** out of 3,240. Cross-checked against an
objective HIPAA direct-identifier scan (§2):

- **297** concepts are both flagged *and* objectively direct identifiers (agreement)
- **547** concepts are objective direct identifiers the flag **does not** mark `Yes` (the flag **misses ~65%**)
- **140** concepts are flagged `Yes` but are not obvious direct identifiers (health-sensitive, indirect, or
  over-flagged)

**Question-level vs. response-level.** The CIDTool ERD allows the `PII` flag at **either the question or the
response level** (a response with no own flag inherits its parent question's). In the data, though,
response-level flagging is **almost unused**: PII varies across a question's response rows in only **2
questions**, and just **6 response concepts** carry their own `Yes`. So the one mechanism that would capture
"the coded answer is safe but *this option's* free text isn't" (§5) exists in the schema but is **not
populated** — meaning sensitivity must be **authored at both the question and the response/companion grain**,
and the model must resolve the **effective tier per response row** as `max(question_tier, response_tier)`,
never inheriting "safe" from a benign parent.

**Conclusion:** the flag is a useful *seed* but cannot be the control input. A maintained
`sensitivity_taxonomy` (concept → tier) must be authored; the flag is one input to it, not the answer.

---

## 2. Objective classification — HIPAA Safe Harbor (18 identifiers)

Keyword scan over 3,240 distinct question concepts (question text + variable label). Direct-identifier
categories with hits:

| HIPAA Safe Harbor identifier | Distinct concepts | Notes |
|---|---:|---|
| #2 Geographic < state (address) | **654** | the dominant category — **527** are street/address/apartment (the reused-address explosion) |
| #3 Dates (other than year) | 128 | Connect mostly uses ages/years, but DOB + `date/time` stamps qualify |
| #1 Names | 22 | participant/proxy/maiden names |
| #6 Email | 22 | |
| #4 Telephone | 16 | |
| #7 SSN | 13 | the **Social Security** survey is an entire instrument of #7 |
| #16 Biometric/genetic | 3 | **under-count** — genetic/GWAS data is a *separate biospecimen/genomic domain*, not survey rows |
| #8 MRN, #11 license, #12–15 vehicle/device/URL/IP, #17 photos | 0 | Connect surveys don't collect these |

**Union of direct-identifier concepts: ~844 (26% of all question concepts).** Additional axes not captured by
Safe Harbor keywords:

- **Free-text (`Char`) concepts: 655** — a **cross-cutting** risk (any free-text answer can contain a name,
  address, or other identifier regardless of the question's topic). See §5.
- **Age (>89 rule): 321** age-related concepts — HIPAA requires aggregating ages over 89.
- **Genetic / geospatial** — largely **outside the survey dictionary** (biospecimen/GWAS domain, geocoded
  coordinates from the address pipeline). These are the highest-sensitivity classes and need classification
  where they live, not here.

### Proposed sensitivity taxonomy (beyond boolean PII)

A single `sensitivity_tier` per concept, richer than PII/non-PII:

```
non_sensitive · quasi_identifier · direct_identifier · geolocation · free_text · genetic · health_sensitive
```

Seeded from (PII flag ∪ HIPAA scan ∪ variable type ∪ domain), then curated. This lookup — not the flag — is
what the model denormalizes onto `responses` for enforcement.

---

## 3. Release tiers → transforms → where they live in the model

| Tier | Researcher gets | Transforms needed | In the model |
|---|---|---|---|
| **Sensitive** | raw responses, minimal redaction | mask a few free-text fields; keep real dates/identifiers | full `responses`; free-text column masked where flagged; tightest IAM |
| **Core** | de-identified-ish | **date-shift** (per-participant offset), **generalize/drop** direct identifiers (address→tract, age>89→"90+"), drop free-text | `responses` with identifier rows filtered + `response_value_as_date` shifted; a versioned dbt transform |
| **Public** | aggregate-only | **aggregation + cell-size suppression** (min-n) | **not the `responses` table** — separate `agg_*` marts with suppression rules |

**Key point:** the tiers are **different products**, not just different grants. Sensitive/Core are row-level
filtered/transformed views of `responses`; Public is a distinct aggregate mart. Raw survey responses are
exposed at Sensitive/Core via **authorized views**; **derived variables** (marts, §8) are governed as their
own products (see §4).

---

## 4. Model amenability to standard security techniques (the core question)

The long/narrow, dictionary-driven shape changes *which* BigQuery mechanism is the natural fit — and mostly
in the model's favor.

| Mechanism | Fit to the model | Assessment |
|---|---|---|
| **Row-level security** (row-access policies) | **Excellent — the primary mechanism.** Sensitivity is a property of the **question** (`question_concept_id`), which is a **row** in `responses`. Denormalize the `sensitivity_tier` onto the fact; one policy per tier filters the single table. | **~844 sensitive concepts collapse to 1 column + ~3 policies.** Contrast the wide tables: **3,867 survey columns**, each a separate classification/policy-tag decision. This is the strongest governance argument for the model. |
| **Column-level security** (policy tags) | **Narrow but real role.** The fact has few columns; the sensitive dimension is the *row*, not the column — **except** `response_value_as_string` (free text), which can carry PII for *any* question. Policy-tag / mask that one column. | Complements RLS: RLS handles "which questions"; a policy tag on the free-text value column handles the cross-cutting free-text risk (§5). |
| **Table / dataset-level isolation** (`*_phi` dataset) | **Defensible but costs the single-table win.** Hard isolation (IRB-friendliest) requires **splitting `responses` by tier** — re-sharding the one fact into e.g. `responses` + `responses_phi`, partially re-introducing the wide-world fragmentation. | Use as defense-in-depth for the highest tier (genetic/direct-identifier), not as the primary control. Hybrid: RLS for most tiers + a physically isolated dataset for the top tier. |
| **Authorized views / datasets** | **The researcher-facing surface.** Expose per-tier subsets without granting base-table access. | Sensitive/Core = authorized views over `responses` (+ RLS); Public = authorized views over `agg_*`. |

### Where marts differ
Derived-variable **marts (§8) are wide and participant-grain** — so *there* sensitivity is **column-level**
again, and **policy tags fit naturally**. Net architecture: **RLS on the long fact + policy tags on the wide
marts** + authorized views as the surface. The model doesn't force one mechanism; it routes each surface to
the mechanism that fits its shape.

---

## 5. The free-text problem (cross-cutting)

`response_value_as_string` is the audit-of-truth column and holds **every free-text answer**. A free-text
value can contain an identifier regardless of how its *question* is classified — so it is not fully covered by
row-level (question-based) classification.

**The "Other — please describe" trap.** Much of the risk is *not* whole questions but the free-text companion
of an otherwise-benign coded question: a select-all / multiple-choice item (non-PII) with an *"Other: please
describe ___"* option whose text box can contain anything — a name, an address, a diagnosis. There are **142**
such companion concepts (**118** free-text `Char`; e.g. the race/ethnicity *"None of these … please describe"*
boxes). Two consequences: (1) **you cannot classify by the parent question** — the coded parent is
`non_sensitive` while its companion is `free_text` (this is exactly the response-level granularity §1 shows the
flag doesn't populate); and (2) **the long format helps here** — the companion is a *distinct
`question_concept_id`*, i.e. a **separate row** in `responses` (the coded selection is one row; the free-text
describe is another). So **row-level security drops the companion independently** while keeping the coded
answer — *provided* the 142 companions are classified `free_text`. A concrete, enumerable classification task.

Options for the free-text columns generally, in order of bluntness:

1. **Classify all 655 free-text concepts as `free_text` sensitive** → RLS drops them below Sensitive tier
   (blunt, safe, loses usable free text).
2. **Column-level mask `response_value_as_string`** in Core/Public via policy tag, keeping coded/numeric/date
   columns available (targeted; the coded answer is usually the analytic value anyway).
3. **NLP scrubbing** of free text into a cleaned column (highest effort; a Core-tier transform).

Recommended default: **(1)+(2)** — treat free-text questions as sensitive *and* policy-tag the string column,
so free text never leaks through either the row or the column path.

---

## 6. Feasibility verdict & what's missing

- **Schema/mechanism feasibility: high.** The long-format model is *more* amenable to enforcement than the
  wide tables: sensitivity collapses to **one denormalized `sensitivity_tier` + a few row-access policies**,
  with policy tags reserved for the free-text column and the wide marts. Nothing here needs a BigQuery
  capability Connect lacks.
- **Classification feasibility: real work.** ~844 direct-identifier + 655 free-text + 321 age concepts need a
  **maintained `sensitivity_taxonomy`** — the `PII` flag misses ~65% of identifiers, so this is authoring +
  legal review, not a lookup.
- **The rest is org/policy, not schema** (and is what keeps this in its infancy): date-shift design
  (per-participant offset, interval preservation), cell-suppression thresholds (min-n, complementary
  suppression), IAM group design, and **IRB sign-off**. These gate external release regardless of how good
  the schema is.

### Recommendation
1. Stand up a **`sensitivity_taxonomy` lookup** (concept → tier), seeded from PII flag ∪ HIPAA scan ∪
   variable type ∪ domain, then curated. Denormalize the effective tier onto `responses`.
2. Make **RLS the primary control** (row-access policies by tier), **policy-tag the free-text value column**,
   and reserve **physical dataset isolation** for the top tier only.
3. Treat **date-shift, cell-suppression, and IRB** as a **parallel org workstream started early** — the long
   pole — not a schema task.
4. Govern **marts (§8) separately** with policy tags (they're wide/participant-grain).

Governance is genuinely nascent — but the model's shape is a **help, not a hindrance**: it turns thousands of
column-classification decisions into one row attribute and a handful of policies.

---

## Scope summary

| Dimension | Count |
|---|---|
| Distinct question concepts | 3,240 |
| `PII=Yes` flagged (concept grain) | 437 |
| Objective HIPAA direct-identifier concepts (heuristic) | ~844 (26%) |
| — of which geographic/address | 654 (527 street/address/apartment) |
| Direct identifiers the `PII` flag **misses** | 547 |
| `PII=Yes` that aren't obvious direct identifiers | 140 |
| Free-text (`Char`) concepts (cross-cutting risk) | 655 |
| — of which "Other-specify" companions of benign coded questions | 142 (118 `Char`) |
| Questions using response-level PII granularity (mechanism exists, ~unused) | 2 |
| Age-related concepts (>89 HIPAA rule) | 321 |
| Wide survey columns to classify (the RLS-vs-policy-tag contrast) | 3,867 → **1 tier column + ~3 policies** in long format |

---

*Design-phase feasibility analysis for the governance enhancement (backlog §7). HIPAA classification is a
keyword heuristic (lower-bound estimate), not a compliance determination. Genetic/geospatial data live outside
the survey dictionary and need classification in their own domains. All counts from
`data_dictionary/masterFile.csv` and `schemas/stage/CleanConnect/*.json`. No BigQuery queries were run.*
