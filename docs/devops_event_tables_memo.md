# Memo — Event tables: keeping the long-format redesign dictionary-compatible

**To:** DevOps / data-engineering
**Re:** The proposed long-format event tables (`activities`, `collections`, `kits`, `surveys`, `incentives`, `refusals`, `collectionDetails`)
**From:** Data-model working group

## First: this is the right direction

Moving follow-up/operational events from nested wide columns to **long-format, one-table-per-event-type** is exactly the shape we want, and it matches where the survey data model is headed. Concretely, your `collectionDetails` before/after — ~120 nested fields (`participants[173836415][266600170][592099155]` × ~30 fields × 4 rounds) collapsing to ~14 columns where **adding a round or specimen needs zero schema change** — is the single best argument for the redesign. Computing aggregates (`anyBloodOrUrine…`) at query time instead of storing them, and giving refused collections a row, are both the right calls. We're aligned and supportive.

## One thing to preserve: the link back to the data dictionary

The examples use **human-readable column names and values** (`Type = "Blood"`, `Status = "Refused"`, `Location = "HP Research Medical"`, `Payment Type = "$25 Gift Card"`). The previous nested form carried **concept IDs**; the long form drops them. That's the one change that breaks compatibility, because the dictionary — and everything researchers will build on it — is keyed on **concept IDs and the Primary/Secondary-Source hierarchy**, not on strings.

Two consequences if the strings are the only identifier:
1. **Events can't be linked to Primary/Secondary Source** (domain/instrument) — the exact linkage leadership wants.
2. **Labels drift.** Already in these examples, the mouthwash specimen appears as **"Mouthwash," "MW Collection," "Mouthwash Collection," and "Home Mouthwash"** across tables. A single concept ID for "mouthwash specimen" unifies all four; strings won't join reliably.

This is the same lesson the survey side learned the hard way (analyses that string-match labels as join keys become fragile and diverge). Easy to avoid now, expensive to retrofit later.

## Five asks (all additive — keep the long format exactly as designed)

1. **Carry a concept_id for every column and every coded value**, alongside the human-readable string (keep the string as a display label). The dictionary already defines these under the non-Survey domains (Biospecimen, Collection Details, Recruitment).
2. **Standardize the specimen/type vocabulary to one concept set** so the same thing has one ID across tables (fix Mouthwash / MW Collection / Mouthwash Collection / Home Mouthwash).
3. **Make `Round` a keyed entity** (`round_id` + activity type), shared across all event tables **and** the survey administrations — it's the natural "encounter" that ties a participant's collections, kits, surveys, incentives, and refusals together.
4. **Reuse existing global concepts** rather than minting new ones — e.g., the `Status` set almost certainly reuses the survey `not_started / started / submitted` concepts; `Location`/`Site` are existing site concepts. Worth a quick check against the dictionary before defining new values.
5. **Keep the "refused / no-row" semantics explicit** (you already give refusals a row — please keep that; it makes non-collection auditable rather than ambiguous).

## On structure: separate tables or one?

Keep **separate per-type tables** (as proposed) — different event types have genuinely different attributes (kits have shipped/received; incentives have payment type/eligibility; collections have location/accession IDs), and a single combined table would be mostly empty cells and harder to govern (a collection location is PHI; a kit status isn't).

For the "everything that happened to a participant" use case, the right answer is a **unified view** over those base tables — which you've **already built** as the *SMDB Participant Summary* (`Round, Type, Category, Item, Status, Date, Setting, Refused`). Keep that as a **view**, not as the stored shape. (This is exactly how OMOP works: separate domain tables — condition / drug / measurement / specimen — unified by `person` and `visit`.)

## What we'll do on our side

- Treat these event tables as the concrete design of the model's event plane (currently a single `other_event_tables` placeholder).
- Reconcile your `surveys` event table with our `response_sessions` (they're the same grain), using `Round` as the shared administration/wave key so survey responses and collection events link through one spine.
- Phase 1: consume your tables as-is plus the concept_id companion columns. Phase 2: model the `rounds` hub + per-type event facts + the unified view, with sensitivity tiers for the PHI fields (locations, dates, names).

Happy to pair on the column→concept and value→concept crosswalk, and on making `Round` the shared key — those two items unblock everything else.
