-- mart_smoking — participant-grain smoking variables.
-- FIRST PASS: a plain BigQuery VIEW (no dbt / no Jinja yet — to be reworked into a dbt model later).
-- Built on the long `responses` fact. Transcribed from
--   Analyticsphere/PR2-analyses → PR2_FinalDerivationsCode.rmd  (validate row-for-row against it before use).
--
-- Pattern: the four base recodes (smoker_status, cigs_lifetime, smoke_cigs_now, cigs_lasttime) are pure
-- code->label, so their labels JOIN the dictionary (`response` dim). The two DERIVED variables
-- (ever_smoker_override, cigarette_cats) are genuine analytic logic — kept as CASE, but evaluated on the
-- coded concept IDs (not label strings) so they can't drift with dictionary wording.
--
-- Answer concept IDs (from the .rmd's value maps):
--   smoker_status (binary)  Yes 353358909 / No 104430631                         [D_947205597_D_712653855]
--   cigs_lifetime  10-or-less 151488193 · 11-49 805449318 · 50-99 486319890 · 100+ 132232896   [D_763164658]
--   smoke_cigs_now No 419415087 · rarely 299561721 · some-days 716761013 · everyday 804785430   [D_639684251]
--   cigs_lasttime  past-month 317567178 · <1yr 484055234 · >1yr 802197176        [D_798549704]

CREATE OR REPLACE VIEW `${PROJECT}.marts.mart_smoking`(
  connect_id           OPTIONS(description="Participant Connect ID"),
  smoker_status_cid    OPTIONS(description="Ever-smoked binary answer concept ID (D_947205597_D_712653855)"),
  cigs_lifetime_cid    OPTIONS(description="Lifetime cigarettes answer concept ID (D_763164658)"),
  smoke_cigs_now_cid   OPTIONS(description="Smokes cigarettes now answer concept ID (D_639684251)"),
  cigs_lasttime_cid    OPTIONS(description="Last time smoked answer concept ID (D_798549704)"),
  smoker_status        OPTIONS(description="Ever-smoked label from the dictionary response dim"),
  cigs_lifetime        OPTIONS(description="Lifetime cigarettes label from the dictionary response dim"),
  smoke_cigs_now       OPTIONS(description="Smokes now label from the dictionary response dim"),
  cigs_lasttime        OPTIONS(description="Last time smoked label from the dictionary response dim"),
  ever_smoker_override OPTIONS(description="Derived: 1 if lifetime >=100 cigs, 0 if <100, NULL otherwise"),
  cigarette_cats       OPTIONS(description="Derived smoking status collapse: Never / Current / Former Smoker (evaluated on concept IDs)")
)
OPTIONS(description="Participant-grain smoking variables derived from the responses fact: base recodes (labels from the dictionary) plus derived ever_smoker_override and the Never/Current/Former cigarette_cats collapse. First-pass BigQuery view (pre-dbt). Transcribed from Analyticsphere/PR2-analyses — validate row-for-row before reporting use.")
AS
WITH pivoted AS (
  SELECT
    connect_id,
    MAX(IF(question_concept_id='712653855' AND current_source_question_concept_id='947205597',
           response_value_as_string, NULL)) AS smoker_status_cid,   -- D_947205597_D_712653855
    MAX(IF(question_concept_id='763164658', response_value_as_string, NULL)) AS cigs_lifetime_cid,   -- D_763164658
    MAX(IF(question_concept_id='639684251', response_value_as_string, NULL)) AS smoke_cigs_now_cid,  -- D_639684251
    MAX(IF(question_concept_id='798549704', response_value_as_string, NULL)) AS cigs_lasttime_cid    -- D_798549704
  FROM `${PROJECT}.relational.responses`
  GROUP BY connect_id
)
SELECT
  p.connect_id,
  p.smoker_status_cid, p.cigs_lifetime_cid, p.smoke_cigs_now_cid, p.cigs_lasttime_cid,

  -- base recodes: labels from the dictionary ("N = " stripped)
  COALESCE(REGEXP_REPLACE(ss.current_format_value, r'^\s*\d+\s*=\s*', ''), 'Missing / Skipped') AS smoker_status,
  COALESCE(REGEXP_REPLACE(cl.current_format_value, r'^\s*\d+\s*=\s*', ''), 'Missing / Skipped') AS cigs_lifetime,
  COALESCE(REGEXP_REPLACE(cn.current_format_value, r'^\s*\d+\s*=\s*', ''), 'Missing / Skipped') AS smoke_cigs_now,
  COALESCE(REGEXP_REPLACE(lt.current_format_value, r'^\s*\d+\s*=\s*', ''), 'Missing / Skipped') AS cigs_lasttime,

  -- ever_smoker_override (derived): 100+ -> 1 ; <100 -> 0 ; else NULL
  CASE
    WHEN p.cigs_lifetime_cid = '132232896' THEN 1
    WHEN p.cigs_lifetime_cid IN ('151488193','805449318','486319890') THEN 0
    ELSE NULL
  END AS ever_smoker_override,

  -- cigarette_cats (derived Never/Current/Former collapse), evaluated on concept IDs
  CASE
    WHEN p.smoker_status_cid = '104430631' THEN 'Never Smoker'                                    -- No
    WHEN p.smoker_status_cid = '353358909'
         AND p.cigs_lifetime_cid IN ('151488193','805449318') THEN 'Never Smoker'                 -- Yes but <50 lifetime
    WHEN p.smoker_status_cid = '353358909' AND p.cigs_lifetime_cid IN ('486319890','132232896')
         AND p.cigs_lasttime_cid IN ('317567178','484055234') THEN 'Current Smoker'               -- smoked within past year
    WHEN p.smoker_status_cid = '353358909' AND p.cigs_lifetime_cid IN ('486319890','132232896')
         AND p.cigs_lasttime_cid = '802197176' THEN 'Former Smoker'                               -- last >1yr ago
    WHEN p.smoker_status_cid = '353358909' AND p.cigs_lifetime_cid IN ('486319890','132232896')
         AND p.cigs_lasttime_cid IS NULL
         AND p.smoke_cigs_now_cid IN ('299561721','716761013','804785430') THEN 'Current Smoker'  -- no lasttime, smokes now
    WHEN p.smoker_status_cid = '353358909' AND p.cigs_lifetime_cid IN ('486319890','132232896')
         AND p.cigs_lasttime_cid IS NULL
         AND p.smoke_cigs_now_cid = '419415087' THEN 'Former Smoker'                              -- no lasttime, not now
    WHEN p.smoker_status_cid = '353358909' AND p.cigs_lifetime_cid IS NULL
         AND p.smoke_cigs_now_cid = '419415087' AND p.cigs_lasttime_cid = '802197176' THEN 'Former Smoker'
    ELSE 'Missing / Skipped'
  END AS cigarette_cats

FROM pivoted p
LEFT JOIN `${PROJECT}.relational.response` ss ON ss.response_concept_id = p.smoker_status_cid
LEFT JOIN `${PROJECT}.relational.response` cl ON cl.response_concept_id = p.cigs_lifetime_cid
LEFT JOIN `${PROJECT}.relational.response` cn ON cn.response_concept_id = p.smoke_cigs_now_cid
LEFT JOIN `${PROJECT}.relational.response` lt ON lt.response_concept_id = p.cigs_lasttime_cid;
