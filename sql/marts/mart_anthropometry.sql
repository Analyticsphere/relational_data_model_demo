-- mart_anthropometry — participant-grain height / weight / BMI.
-- FIRST PASS: a plain BigQuery VIEW (no dbt / no Jinja yet — to be reworked into a dbt model later).
-- Built on the long `responses` fact. Logic transcribed faithfully from
--   Analyticsphere/PR2-analyses → PR2_FinalDerivationsCode.rmd  (validate row-for-row against it before use).
--
-- Numeric answers: cast from `response_value_as_string` (always populated). Height is two boxes
-- (feet + inches) nested under D_114314839; weight is standalone D_746012894. Zero values -> NULL,
-- then BMI = weight_lb / height_in^2 * 703 (imperial), binned into the .rmd's 6 categories.

CREATE OR REPLACE VIEW `nih-nci-dceg-connect-stg-5519.marts.mart_anthropometry`(
  connect_id               OPTIONS(description="Participant Connect ID"),
  height_ft                OPTIONS(description="Reported height, feet component (D_114314839_D_340854069)"),
  height_in                OPTIONS(description="Reported height, inches component (D_114314839_D_600462977)"),
  weight                   OPTIONS(description="Reported weight in pounds (D_746012894)"),
  height_combined_nozeroes OPTIONS(description="Total height in inches (feet*12 + inches); NULL if not > 0"),
  weight_nozeroes          OPTIONS(description="Weight in pounds; NULL if not > 0"),
  bmi_derived              OPTIONS(description="Derived BMI = weight_lb / height_in^2 * 703 (imperial)"),
  bmi_category             OPTIONS(description="BMI category bin (Underweight / Normal / Overweight / Obesity I-III / Missing)")
)
OPTIONS(description="Participant-grain anthropometry (height, weight, BMI, BMI category) derived from the responses fact. First-pass BigQuery view (pre-dbt); BMI is a derived formula/bin, not a dictionary label. Transcribed from Analyticsphere/PR2-analyses — validate row-for-row before reporting use.")
AS
WITH pivoted AS (
  SELECT
    connect_id,
    MAX(IF(question_concept_id = '340854069'
           AND current_source_question_concept_id = '114314839',
           SAFE_CAST(response_value_as_string AS FLOAT64), NULL)) AS height_ft,  -- D_114314839_D_340854069
    MAX(IF(question_concept_id = '600462977'
           AND current_source_question_concept_id = '114314839',
           SAFE_CAST(response_value_as_string AS FLOAT64), NULL)) AS height_in,  -- D_114314839_D_600462977
    MAX(IF(question_concept_id = '746012894',
           SAFE_CAST(response_value_as_string AS FLOAT64), NULL)) AS weight       -- D_746012894
  FROM `nih-nci-dceg-connect-stg-5519.relational.responses`
  GROUP BY connect_id
),
sized AS (
  SELECT
    connect_id, height_ft, height_in, weight,
    IF((height_ft * 12) + height_in > 0, (height_ft * 12) + height_in, NULL) AS height_combined_nozeroes,
    IF(weight > 0, weight, NULL)                                             AS weight_nozeroes
  FROM pivoted
),
bmi AS (
  SELECT
    connect_id, height_ft, height_in, weight, height_combined_nozeroes, weight_nozeroes,
    SAFE_DIVIDE(weight_nozeroes, POW(height_combined_nozeroes, 2)) * 703 AS bmi_derived
  FROM sized
)
SELECT
  connect_id, height_ft, height_in, weight,
  height_combined_nozeroes, weight_nozeroes, bmi_derived,
  CASE
    WHEN bmi_derived IS NULL   THEN 'Missing'
    WHEN bmi_derived < 18.5    THEN 'Underweight (<18.5)'
    WHEN bmi_derived < 25      THEN 'Normal weight (18.5 - <25)'
    WHEN bmi_derived < 30      THEN 'Overweight (25 - <30)'
    WHEN bmi_derived < 35      THEN 'Obesity class I (30 - <35)'
    WHEN bmi_derived < 40      THEN 'Obesity class II (35 - <40)'
    WHEN bmi_derived >= 40     THEN 'Obesity class III (>=40)'
    ELSE 'Missing'
  END AS bmi_category
FROM bmi;
