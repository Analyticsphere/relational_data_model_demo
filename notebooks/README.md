# notebooks/ — tutorials for the Connect Data Model

Notebook-style tutorials that demonstrate the utility of the model. **[marimo](https://marimo.io)** notebooks
(pure `.py` — clean diffs, reproducible, no hidden state), **SQL‑forward** (Python confined to one setup cell),
and **production‑data‑free** (they run on the committed demo dimensions + a small synthetic `responses` seed).

| File | What |
|---|---|
| `01_model_tutorial.py` | Four before/after demos: answers‑as‑rows + one‑join labels · one generic query for any question · a reused concept pooled/sliced across surveys · harmonizing reused fields via `concept_relationship`. |

## Run

```bash
pip install marimo duckdb
marimo edit notebooks/01_model_tutorial.py     # interactive editor
marimo run  notebooks/01_model_tutorial.py     # read-only app view
marimo export html notebooks/01_model_tutorial.py -o tutorial.html   # static share
# marimo export html-wasm notebooks/01_model_tutorial.py --mode run  # serverless, runs in-browser
```

The setup cell builds an **in‑memory** DuckDB from `output/dim/*.csv` (committed) and seeds a tiny synthetic
`responses` fact anchored to real concept IDs. Nothing is written to disk; no production data is read.

## Swapping in data

The queries don't care where `responses` comes from. When a real/dummy `responses` dataset exists, replace
the synthetic `INSERT` block in the setup cell with a `read_parquet(...)` load or an `ATTACH` of a DuckDB
file, keeping columns aligned with `sql/unpivot/00_responses_ddl.sql`.
