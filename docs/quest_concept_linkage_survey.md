# Quest ↔ concept-ID linkage — the `skip_logic` blocker

*Survey date: 2026-07-08 · Source: `surveys/module1.txt` (episphere/quest) + `data_dictionary/masterFile.csv` + episphere tooling (`quest`, `conceptGithubActions`)*

---

## Purpose

`skip_logic` (backlog §4) parses branching from Quest markup, but the markup references questions by **short
Quest names** (`SEX`, `MOM1`, `SIB4`) while the `responses` fact keys on **9-digit concept IDs**. The
skip-logic survey named this the **critical blocker** and the shared-dependency critical path names a
"Quest variable-name → concept-ID map." This document establishes **whether that map exists, where, and how
reliable each resolution path is** — quantitative, no BigQuery queries.

---

## The problem, quantified

**The authoring markup carries no concept IDs.** `surveys/module1.txt`:

| Metric | Value |
|---|---|
| Distinct Quest question-ID tokens | 302 (286 question blocks) |
| Question IDs in **concept-ID form** (`D_<cid>`) | **0** — all short-name form (`MARITAL`, `SKINCANC`) |
| 9-digit concept IDs anywhere in the file | **0** |
| Skip-logic trigger names in `displayif`/`loopmax` | 21 (`SEX`, `SEX2`, `MOM1`, `SIB4`, `NUMSIB`, …) |

**The dictionary carries no Quest-short-name column.** Across all **37** `masterFile.csv` columns, the row for
`[MARITAL?]` (concept `783167257`) contains the question text, `Variable Label = "Marital Status"`, and
`Variable Name = "SrvBOH_Marital_v1r0"` — but the token **`MARITAL` appears nowhere**. The Quest name is only
*echoed* in the SAS mnemonic (`SrvBOH_`**`Marital`**`_v1r0`), not stored as a join key.

**So heuristic resolution from the authoring `.txt` is weak:**

| Heuristic | Coverage (of module1) | Note |
|---|---|---|
| Quest name ↔ Variable-Name mnemonic | **13%** of questions, **10%** of triggers | `Marital`≈`MARITAL`, but `SIB4`/`MOM1`/`NUMSIB` don't align |
| Quest prompt text ↔ dictionary `Current Question Text` | **~41%** (crude normalization) | breaks on piping `{$u:age}`, inline `displayif` text, wording drift |

Neither is good enough to operationalize skip logic against concept IDs. The trigger names — the ones that
actually matter for §4 — are the *worst* case (10% mnemonic): `SIB4`, `MOM1`, `DAD`, `CHILD4`, `NUMSIB`,
`SEX2` resolve to nothing by name.

---

## Where the linkage actually lives (the tooling)

The mapping is **not** a stored short-name crosswalk — it is produced by the concept-ID **generation
pipeline**, and the *deployed* markup is concept-ID-based:

- **`episphere/conceptGithubActions`** (a GitHub Actions repo, `.github/workflows/main.yml`) runs
  **`concept.js`**, which **assigns a concept ID to each survey element** and persists artifacts:
  - `jsons/<conceptId>.json` — **5,749 per-concept files**, keyed on **concept ID**, carrying `Variable Name`,
    `Current Question Text`, `Current Format/Value`, etc. (the dictionary in JSON form).
  - `jsons/varToConcept.json` — a `nameToConcept` map, but keyed on **response option values** (`"1"→349122068`),
    **not** question short-names.
  - `jsons/conceptIds.txt` — the pool of allocated concept IDs.
- **Concept IDs are assigned by `Variable Name` + question text, not the Quest short-name** — so the short-name
  (`MARITAL`) is consumed at authoring time and never persisted as a key.
- **`episphere/quest/replace2.js`** is the render-time transform; the **compiled/deployed markup is
  concept-ID-based** — e.g. the mouthwash tooth-loss question is authored/deployed as `[D_899251483_V2?]`, and
  the compiled `sub_modules_module1/main_json` carries concept IDs (`726699695` …). The short-name form is the
  **authoring source**; the concept-ID form is what actually runs.

**Net:** there is no `MARITAL → 783167257` lookup file to fetch. The linkage exists as a *process*
(conceptGithubActions) and as the *compiled concept-ID-form markup*, not as a short-name crosswalk.

---

## Resolution paths (ranked)

1. **Parse the compiled / deployed concept-ID-form markup — recommended.** In that form the skip-logic
   triggers are **already concept IDs** (`displayif=equals(D_<cid>, …)`), so §4 needs **no name resolution at
   all**. Action: obtain the compiled markup (the concept-ID form Quest deploys) rather than the short-name
   authoring `.txt`. This dissolves the blocker.
2. **Extract the crosswalk from the generation pipeline.** `conceptGithubActions` knows the
   element→concept-ID assignment at generation time; a small addition there (or reading its intermediate
   state) could emit an explicit `quest_name → concept_id` table. Authoring change in a repo we don't own, but
   authoritative.
3. **Heuristic reconstruction (fallback, not sufficient alone).** Combine question-text match (~41%, improvable
   with careful normalization that strips piping/inline `displayif`), Variable-Name mnemonic (13%), and
   **question-order/`Index` alignment** (both the markup and the dictionary are ordered; the concept JSON even
   carries an `Index`). Even combined, expect a residual tail needing manual mapping — brittle, and exactly the
   hand-work the model is trying to remove.

---

## Impact on `skip_logic` (§4)

- The §4 parser is **feasible**, but **only against the concept-ID-form markup** (path 1). Parsing the
  short-name authoring `.txt` and re-deriving concept IDs (path 3) is the trap — it re-creates a brittle
  label-as-join-key crosswalk, the anti-pattern the model exists to remove.
- This reframes the "critical blocker": it is **not** an unbounded authoring task. The mapping already exists
  in the deployed markup / generation tooling; the work is **sourcing the concept-ID-form markup**, not
  reconstructing names.
- **Verify next:** confirm the compiled concept-ID-form markup is obtainable for all modules (module1 authoring
  `.txt` is short-name; the mouthwash-style `[D_<cid>]` form and `main_json` show the compiled form exists —
  confirm coverage and access).

---

## Scope summary

| Dimension | Count |
|---|---|
| module1 Quest question tokens (all short-name form) | 302 (286 blocks) |
| Concept IDs in the authoring markup | 0 |
| Skip-logic trigger names to resolve | 21 |
| `masterFile` columns containing the Quest short-name | 0 / 37 |
| Resolution — Variable-Name mnemonic | 13% questions / 10% triggers |
| Resolution — question-text match (crude) | ~41% |
| conceptGithubActions per-concept JSONs (keyed on concept ID) | 5,749 |
| Authoritative short-name → concept-ID lookup file | **none exists** (assigned by Variable Name/text; deployed markup is concept-ID-based) |

---

*Design-phase investigation for the `skip_logic` enhancement (backlog §4) and the shared Quest-name→concept-ID
dependency. Markup from `episphere/quest/questionnaires/module1.txt`; tooling from `episphere/quest`
(`replace2.js`) and `episphere/conceptGithubActions` (`concept.js`, `jsons/`). No BigQuery queries were run.*
