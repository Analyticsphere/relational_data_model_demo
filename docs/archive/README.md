# docs/archive/ — kick-off pitch materials (superseded)

These are the **internal kick-off pitch** artifacts from the phase where the team was deciding *whether* to
build an improved data model. **That decision is made** — the Dictionary-Direct model is accepted — so these
are archived for reference. Active work now lives in the **operational documentation** (the enhancement
backlog + the investigation surveys under `docs/`).

| File | What |
|---|---|
| `internal_pitch.md` | the kick-off pitch (OMOP framing, pain exhibits, value props, recommendation) |
| `Connect_Data_Model_Pitch.pptx` | the slide deck presented at kick-off |
| `build_deck.py` | generates the deck (regenerable: `python docs/archive/build_deck.py`) |
| `slide_assets/` | PNG diagrams embedded in the deck |

The model **ERD SVGs** (`docs/connect_model_a*.svg`, `docs/connect_event_plane*.svg`) stayed in `docs/` — they
document the model itself and are referenced by `README.md`, not just the pitch.

**For current work, start with:** `docs/enhancement_backlog.md` (the accepted model + the enhancement roadmap)
and the investigation surveys (`docs/*_survey.md`, `docs/value_typing.md`).
