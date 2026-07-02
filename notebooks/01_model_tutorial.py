import marimo

__generated_with = "0.9.14"
app = marimo.App(width="medium")


@app.cell
def _():
    import marimo as mo
    return (mo,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(
        """
        # The Connect Data Model — a hands-on tour

        This tutorial shows *why* the long‑format `responses` fact (answers as **rows**, keyed to the
        dictionary's concept IDs) makes analysis easier than the wide "dancing‑schema" tables.

        Everything below is **plain SQL** against a local DuckDB (≈ BigQuery SQL). The only Python is the
        setup cell that loads the committed demo **dimension** tables and seeds a tiny **synthetic**
        `responses` fact. There is **no production data** here — and you can swap the seed for a real/dummy
        `responses` dataset without changing any query below (see the last cell).

        > Run it: `pip install marimo duckdb` then `marimo edit notebooks/01_model_tutorial.py`.
        """
    )
    return


@app.cell
def _():
    # --- the only Python: build a DuckDB with the demo dimensions + a SYNTHETIC responses seed ---
    from pathlib import Path
    import duckdb

    _here = Path.cwd()
    _root = next((p for p in [_here, *_here.parents] if (p / "output" / "dim" / "question.csv").exists()), _here)
    DIM = (_root / "output" / "dim").as_posix()

    con = duckdb.connect()  # in-memory; nothing is written to disk
    for _t in ["primary_source", "secondary_source", "source_question", "question",
               "response", "question_response", "concept_relationship"]:
        con.execute(f"CREATE VIEW {_t} AS SELECT * FROM read_csv('{DIM}/{_t}.csv', header=true, all_varchar=true)")

    # SYNTHETIC responses — grain/columns match sql/unpivot/00_responses_ddl.sql. Anchored to REAL concept IDs
    # so the dictionary joins resolve. Replace this block with a real dummy fact later (see the final cell).
    con.execute(
        """
        CREATE TABLE responses (
          connect_id VARCHAR, secondary_source_concept_id VARCHAR,
          current_source_question_concept_id VARCHAR, question_concept_id VARCHAR, loop_instance INT,
          question_version VARCHAR, response_value_as_string VARCHAR, response_value_as_number DOUBLE,
          response_value_as_concept_id VARCHAR, source_table VARCHAR, source_column VARCHAR);

        -- single-select: 108417657 "How many times have you had a proctoscopy?"
        INSERT INTO responses (connect_id, secondary_source_concept_id, question_concept_id, loop_instance, response_value_as_concept_id) VALUES
         ('P01','726699695','108417657',1,'236949684'),('P02','726699695','108417657',1,'506053626'),
         ('P03','726699695','108417657',1,'236949684'),('P04','726699695','108417657',1,'462661976'),
         ('P05','726699695','108417657',1,'236949684'),('P06','726699695','108417657',1,'178420302'),
        -- reused concept 784119588 "Survey Language" — appears under MANY surveys (here: Mouthwash + Where You Live and Work)
         ('P01','390351864','784119588',1,'163149180'),('P02','390351864','784119588',1,'163149180'),
         ('P03','390351864','784119588',1,'773342525'),('P01','716117817','784119588',1,'163149180'),
         ('P04','716117817','784119588',1,'773342525'),('P05','716117817','784119588',1,'163149180');
        -- free-text address answers across DIFFERENT street-name concepts (residence: current/seasonal/previous)
        INSERT INTO responses (connect_id, secondary_source_concept_id, question_concept_id, loop_instance, response_value_as_string) VALUES
         ('P01','716117817','105043152',1,'10 Oak St'),('P02','716117817','105043152',1,'5 Elm Ave'),
         ('P01','716117817','110516520',1,'22 Beach Rd'),('P01','716117817','110516520',2,'30 Lake Way'),
         ('P03','716117817','111275683',1,'9 Maple Dr');
        """
    )
    return (con,)


@app.cell(hide_code=True)
def _(mo):
    mo.md(
        """
        ## 1 · Answers are rows — and self‑describing with one join

        In the wide tables an answer is a cell in an opaque `d_<concept>` column. Here it's a **row** in
        `responses`, and the dictionary supplies every label. One shape holds coded answers *and* free text;
        loops are rows (`loop_instance`), not `_N` columns.
        """
    )
    return


@app.cell
def _(con, mo):
    _ = mo.sql(
        """
        SELECT r.connect_id,
               ss.secondary_source                                        AS survey,
               q.current_question_text                                    AS question,
               COALESCE(o.current_format_value, r.response_value_as_string) AS answer,
               r.loop_instance
        FROM responses r
        JOIN question q               ON q.question_concept_id          = r.question_concept_id
        LEFT JOIN secondary_source ss ON ss.secondary_source_concept_id = r.secondary_source_concept_id
        LEFT JOIN response o          ON o.response_concept_id          = r.response_value_as_concept_id
        ORDER BY r.connect_id, survey, question
        LIMIT 12
        """,
        engine=con,
    )
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(
        """
        ## 2 · One generic query works for *any* question

        The wide tables need a bespoke `CASE` per question and you must know its columns. Here the *same*
        distribution query answers **any** single‑select — just change the `question_concept_id`. Try
        swapping `108417657` for another concept ID.
        """
    )
    return


@app.cell
def _(con, mo):
    _ = mo.sql(
        """
        SELECT o.current_format_value AS answer, COUNT(*) AS n
        FROM responses r
        JOIN response o ON o.response_concept_id = r.response_value_as_concept_id
        WHERE r.question_concept_id = '108417657'   -- "How many times have you had a proctoscopy?"
        GROUP BY o.current_format_value
        ORDER BY n DESC
        """,
        engine=con,
    )
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(
        """
        ## 3 · A concept reused across surveys — pool it, or slice it

        Connect deliberately reuses a question concept across instruments (e.g. `784119588` "Survey
        Language" appears in ~15 surveys). The model **stamps the survey on every answer row**, so you can
        **pool** the concept across all surveys with one `GROUP BY`, or **slice** it to a single survey —
        neither is possible in the wide world without hand‑UNIONing per‑survey tables.
        """
    )
    return


@app.cell
def _(con, mo):
    _pooled = mo.sql(
        """
        -- pooled across every survey the concept appears in
        SELECT o.current_format_value AS language, COUNT(*) AS n
        FROM responses r
        JOIN response o ON o.response_concept_id = r.response_value_as_concept_id
        WHERE r.question_concept_id = '784119588'
        GROUP BY language ORDER BY n DESC
        """,
        engine=con,
    )
    return


@app.cell
def _(con, mo):
    _by_survey = mo.sql(
        """
        -- the same concept, sliced by the stamped survey
        SELECT ss.secondary_source AS survey, o.current_format_value AS language, COUNT(*) AS n
        FROM responses r
        JOIN response o          ON o.response_concept_id          = r.response_value_as_concept_id
        JOIN secondary_source ss ON ss.secondary_source_concept_id = r.secondary_source_concept_id
        WHERE r.question_concept_id = '784119588'
        GROUP BY survey, language ORDER BY survey, n DESC
        """,
        engine=con,
    )
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(
        """
        ## 4 · Harmonize reused fields once — via `concept_relationship`

        The same real‑world field is spread across many distinct concept IDs — a residence "street name"
        is ~66 different concepts (current / seasonal / previous / …). Instead of a hand‑written 26‑branch
        `CASE` (which three geocoding repos each rebuilt), the equivalence plane records the "these mean the
        same field" link **once, as data**. One join to `concept_relationship` gathers every
        "street‑name‑of‑residence" answer — across concepts *and* loop instances.
        """
    )
    return


@app.cell
def _(con, mo):
    _harmonized = mo.sql(
        """
        WITH residence_street_name AS (
          SELECT concept_id_1 AS question_concept_id
          FROM concept_relationship
          WHERE relationship = 'synonym' AND concept_id_2 = '105043152'   -- the group's canonical concept
        )
        SELECT q.current_question_text        AS field,
               r.response_value_as_string      AS street_name,
               r.connect_id, r.loop_instance
        FROM responses r
        JOIN residence_street_name g USING (question_concept_id)
        JOIN question q              USING (question_concept_id)
        ORDER BY r.connect_id, r.loop_instance
        """,
        engine=con,
    )
    return


@app.cell(hide_code=True)
def _(mo):
    mo.md(
        """
        ## Swap in your own `responses` data

        Every query above is unchanged by *where* `responses` comes from. To use a real or dummy fact,
        replace the synthetic `INSERT` block in the setup cell with either of:

        ```python
        con.execute("CREATE TABLE responses AS SELECT * FROM read_parquet('path/to/responses.parquet')")
        # or attach a DuckDB file you built for tutorials:
        con.execute("ATTACH 'tutorials/responses_dummy.duckdb' AS d (READ_ONLY)")
        con.execute("CREATE VIEW responses AS SELECT * FROM d.responses")
        ```

        Keep the columns aligned with `sql/unpivot/00_responses_ddl.sql` and the dictionary joins keep working.
        """
    )
    return


if __name__ == "__main__":
    app.run()
