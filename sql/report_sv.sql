-- report_sv.sql : aggregation step A3, the semantic view REPORT_SV: the report's numbers, defined once.
-- Tables: ANSWERS_T (REPORT_ANSWERS, one row per setup x comment) and TAGS_T (REPORT_TAGS, one row per setup x comment
-- x sub-theme). Every query must filter on SETUP ('C09' winner or 'C01' today): the two tag sets are separate reports.
-- Counting rule: COMMENTS counts distinct comments, so a comment with 2 sub-themes in one theme counts once for that
-- theme. % of comments = COMMENTS / ALL_COMMENTS (500 per setup), worked out in the report query.
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

CREATE OR REPLACE SEMANTIC VIEW REPORT_SV
  TABLES (
    ANSWERS_T AS REPORT_ANSWERS PRIMARY KEY (SETUP, COMMENT_ID)
      COMMENT = 'One row per tagging setup and comment in the patient transport report slice',
    TAGS_T AS REPORT_TAGS PRIMARY KEY (SETUP, COMMENT_ID, SUB_THEME)
      COMMENT = 'One row per tagging setup, comment and sub-theme the model gave'
  )
  RELATIONSHIPS (
    TAG_TO_ANSWER AS TAGS_T (SETUP, COMMENT_ID) REFERENCES ANSWERS_T
  )
  DIMENSIONS (
    ANSWERS_T.SETUP AS ANSWERS_T.SETUP COMMENT = 'Tagging setup: C09 = Gemini 3.1 Pro + structured v3 (winner), C01 = Mistral Large 3 + current prompt (today)',
    ANSWERS_T.QUESTION AS ANSWERS_T.QUESTION COMMENT = 'Survey question the comment answers',
    ANSWERS_T.IMPACT AS ANSWERS_T.IMPACT COMMENT = 'Impact of the whole comment, 1 (no problem) to 5 (harm or risk to safety)',
    ANSWERS_T.PATIENT_RATING AS ANSWERS_T.PATIENT_RATING COMMENT = 'Rating the patient gave in the survey',
    TAGS_T.THEME AS TAGS_T.THEME COMMENT = 'Taxonomy theme',
    TAGS_T.SUB_THEME AS TAGS_T.SUB_THEME COMMENT = 'Taxonomy sub-theme',
    TAGS_T.SENTIMENT AS TAGS_T.SENTIMENT COMMENT = 'Sentiment of this tag: Positive, Neutral or Negative'
  )
  METRICS (
    ANSWERS_T.ALL_COMMENTS AS COUNT(DISTINCT ANSWERS_T.COMMENT_ID) COMMENT = 'Comments in the report',
    ANSWERS_T.AVG_IMPACT AS ROUND(AVG(ANSWERS_T.IMPACT), 2) COMMENT = 'Average impact of the comments',
    TAGS_T.COMMENTS AS COUNT(DISTINCT TAGS_T.COMMENT_ID) COMMENT = 'Comments raising this theme or sub-theme (each comment once)',
    TAGS_T.NEGATIVE_COMMENTS AS COUNT(DISTINCT IFF(TAGS_T.SENTIMENT = 'Negative', TAGS_T.COMMENT_ID, NULL)) COMMENT = 'Comments with a negative tag',
    TAGS_T.POSITIVE_COMMENTS AS COUNT(DISTINCT IFF(TAGS_T.SENTIMENT = 'Positive', TAGS_T.COMMENT_ID, NULL)) COMMENT = 'Comments with a positive tag',
    TAGS_T.TAGS AS COUNT(*) COMMENT = 'Tags given (a comment can have several)'
  )
  COMMENT = 'Patient transport report slice (500 comments) tagged by the winner and by today''s setup: comments, sentiment and impact per theme and sub-theme';

-- Check against plain SQL (expect DIFF = 0 on every row).
WITH sv AS (
  SELECT * FROM SEMANTIC_VIEW(REPORT_SV DIMENSIONS ANSWERS_T.SETUP, TAGS_T.THEME METRICS TAGS_T.COMMENTS, TAGS_T.NEGATIVE_COMMENTS)),
plain AS (
  SELECT SETUP, THEME, COUNT(DISTINCT COMMENT_ID) AS C, COUNT(DISTINCT IFF(SENTIMENT = 'Negative', COMMENT_ID, NULL)) AS N
  FROM REPORT_TAGS GROUP BY 1, 2)
SELECT COUNT(*) AS ROWS_COMPARED, SUM(ABS(sv.COMMENTS - p.C) + ABS(sv.NEGATIVE_COMMENTS - p.N)) AS DIFF
FROM sv JOIN plain p ON p.SETUP = sv.SETUP AND p.THEME = sv.THEME;
