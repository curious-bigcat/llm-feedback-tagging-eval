-- report_tags.sql : aggregation step A3, the tagged report slice in two tables for the semantic view REPORT_SV.
--   REPORT_ANSWERS : one row per setup x comment (500 per setup): question, rating, the model's impact, valid or not
--   REPORT_TAGS    : one row per setup x comment x valid sub-theme, with the theme and sentiment of that tag
-- SETUP is 'C09' (winner) or 'C01' (today), from runs C09_report_r1 / C01_report_r1. Only valid taxonomy pairs are
-- kept, and a sub-theme given twice in one answer counts once (its first sentiment).
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

CREATE OR REPLACE TABLE REPORT_ANSWERS AS
SELECT a.MODEL_ID AS SETUP, a.COMMENT_ID, c.QUESTION, c.COMMENT_TEXT, c.PATIENT_RATING,
       TRY_TO_NUMBER(a.ANSWER:impact::STRING) AS IMPACT, ARRAY_SIZE(a.PROBLEMS) = 0 AS VALID
FROM ANSWERS a JOIN REPORT_COMMENTS c USING (COMMENT_ID)
WHERE a.RUN_ID IN ('C09_report_r1', 'C01_report_r1');

CREATE OR REPLACE TABLE REPORT_TAGS AS
SELECT a.MODEL_ID AS SETUP, a.COMMENT_ID, t.value:theme::STRING AS THEME, t.value:sub_theme::STRING AS SUB_THEME,
       t.value:sentiment_label::STRING AS SENTIMENT, t.value:evidence::STRING AS EVIDENCE
FROM ANSWERS a, LATERAL FLATTEN(a.ANSWER:tags) t, RULEBOOK r
WHERE a.RUN_ID IN ('C09_report_r1', 'C01_report_r1')
  AND ARRAY_CONTAINS((t.value:theme::STRING || ' > ' || t.value:sub_theme::STRING)::VARIANT, r.ALLOWED_PAIRS)
QUALIFY ROW_NUMBER() OVER (PARTITION BY a.MODEL_ID, a.COMMENT_ID, t.value:sub_theme::STRING ORDER BY t.index) = 1;

-- Check: rows per setup.
SELECT SETUP, COUNT(*) AS TAGS, COUNT(DISTINCT COMMENT_ID) AS COMMENTS_WITH_TAGS FROM REPORT_TAGS GROUP BY 1 ORDER BY 1;
