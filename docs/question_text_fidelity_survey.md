# Does `question_text` represent what participants actually see?

*Survey date: 2026-07-16 · Source: `surveys/module1.txt` (Quest authoring markup) + `data_dictionary/masterFile.csv` (`Current Question Text`). No BigQuery queries; module1 only.*

## Purpose

`question.question_text` (from the dictionary's `Current Question Text`) is the label we surface to
researchers and lean on downstream — e.g. the OMOP/Usagi `source_code_description`. This asks how faithfully
that flat string represents the **rendered question a participant saw** in the Quest instrument. Scoped to
**Module 1** (the stress-test module; ~282 question blocks).

## Headline

**`question_text` is a plain-text *stem*, not a faithful rendering.** It captures the core wording reasonably,
but by construction it drops almost everything that shapes what the participant actually saw: formatting,
numeric-input framing, branch-conditional wording, and personalization. Verbatim word-for-word identity is
the exception (~13%), not the rule. And — per the linkage gap below — we can't even measure per-question
fidelity cleanly from the available source.

## Method & honest limits

Parsed each Quest question block (prompt text + markup) from `module1.txt`, and compared the normalized
prompt to the dictionary `Current Question Text`. Two hard limits, both pointing the same way:

- **Authoring form.** `surveys/module1.txt` is the **short-name authoring** markup — it carries **zero
  concept IDs** (see [`quest_concept_linkage_survey.md`](quest_concept_linkage_survey.md)). So there is **no
  key** to join a Quest question to its dictionary row; pairing must be done by matching the very text whose
  fidelity we're measuring.
- **Proxy matching is lossy.** That linkage survey already quantified it: Quest-name↔mnemonic resolves
  **~13%**, Quest-prompt↔dictionary-text **~41%** (crude), "breaks on piping, inline `displayif`, wording
  drift." So the **structural census below is reliable** (computed from Quest alone), the **verbatim-match
  rate is a reliable lower bound**, but a precise "drift %" is **not** measurable until the compiled markup
  is sourced.

## Finding 1 — what a flat string structurally cannot hold (reliable)

Computed from the Quest markup directly (no matching needed). Each is something the participant saw that a
single plain string cannot carry:

| Feature in the rendered question | Module 1 questions | What the flat `question_text` loses |
|---|---:|---|
| **HTML formatting** (`<b>`, `<br>`, `<u>`) | **236 (84%)** | emphasis and structure — e.g. "when you **first**…", "when you **last**…"; the bolded word often *is* the distinction between two otherwise-identical questions |
| **Numeric-input framing** (`\|__\|`, `min=`/`max=`) | **193 (68%)** | that the question is a bounded numeric entry (e.g. age `min=40 max=70`), not an open prompt |
| **Inline `displayif` conditional text** | 130 (46%); **110 wrap branch-dependent display text** | that the *same* concept renders **different wording per branch** — e.g. "…told **her/him/your sibling/your child**…"; the flat text stores one variant |
| **Piping / personalization** (`{$u:age}`, `{$WORK3_JOBTITLE}`) | 8 (3%) | the participant saw a **filled-in value** ("you are **57** years old"); the flat text has a token or a generic phrasing |

So even a *word-perfect* transcription would misrepresent what most Module 1 participants saw.

## Finding 2 — the words themselves are only sometimes verbatim (lower bound)

After Unicode-folding and punctuation-insensitive comparison, only **~13% (36/282)** of Quest prompts are
**verbatim word-identical** to a dictionary `Current Question Text` (and 24 of those still drop HTML the
participant saw). This is consistent with the linkage survey's looser **~41%** "resolvable" figure — the gap
between 13% and 41% is exactly the systematic, non-verbatim divergence. Categories (illustrative; not
precisely quantifiable given proxy matching):

- **Instructions the dictionary omits** — Quest shows "Select all that apply. Note, you may select more than
  one group."; the dictionary keeps only the stem.
- **Emphasis stripped** — `Which type of <b>diabetes</b>…` → `Which type of diabetes…`.
- **Conditional framing flattened** — the she/him/sibling/child variants collapse to one.
- **Genuine wording drift** — real, smaller: `WORK5` "**Is** this your longest-held job?" vs dict "**Was**…";
  `WORK7` "longest-held **job**" vs "longest-held **job title**"; `BREASTDIS2` "you **have**" vs "you **have or
  had**". These are transcription differences, not formatting.

## Finding 3 — we can't measure it cleanly yet (and the fix)

The reason the precise numbers are soft is the **Quest↔concept linkage gap**, already documented in
[`quest_concept_linkage_survey.md`](quest_concept_linkage_survey.md): the authoring `.txt` has no concept
IDs, and the dictionary has no Quest short-name. That survey's conclusion applies directly here — the
**compiled/deployed Quest markup is concept-ID-based**, so sourcing it would let this exact comparison be run
**per concept** (deterministic join) instead of by lossy text matching, turning Findings 1–2 into precise,
per-question numbers.

## Implications for the model

- **`question_text` is fine as a human label / search field, but should not be presented as "the question as
  presented to the participant."** In particular, do not export it to researchers or into the OMOP/Usagi
  `source_code_description` framed as verbatim question wording — it is a stem.
- **Fidelity-sensitive uses need a Quest-derived `display_text`**, distinct from `question_text`: it would
  carry formatting, piping **placeholders** (not filled values), numeric-input bounds, and the per-branch
  wording variants. This attaches as an overlay sourced from the **compiled** markup — it does not touch the
  dictionary or `responses`.
- **This is gated on the same dependency as `skip_logic` (§4): sourcing the compiled concept-ID markup.** One
  parse of that artifact unblocks display-text fidelity, skip logic, question order, and loop/grid structure
  together. See the shared-dependencies critical path in [`enhancement_backlog.md`](enhancement_backlog.md).
- **A cheap interim flag:** mark questions whose Quest block contains HTML / `displayif` display-text / piping
  as `display_text_lossy = true` (derivable once the markup is parsed), so consumers know the stem is an
  approximation for those.

## Caveats

Module 1 only — the stress-test module, likely richer in conditional/grid/loop structure than average, so the
84%/68%/46% figures are an **upper-ish bound** on complexity, not a cohort-wide rate. All figures are from the
**authoring** markup; the verbatim-match rate is a lower bound. Precise per-question fidelity awaits the
compiled markup.
