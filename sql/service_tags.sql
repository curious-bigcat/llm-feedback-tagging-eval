-- service_tags.sql : aggregation steps R2 and R3, for the service in SERVICE_COMMENTS (Forensic), tagged by the
-- winner (run C09_svc_r1).
--   R2: SERVICE_ANSWERS (one row per comment), SERVICE_TAGS (one row per comment x valid sub-theme, with the tag's
--       sentiment and evidence quote) and the semantic view SERVICE_SV: every count and % in the report, defined once.
--       A comment counts once per theme even when it has two sub-themes in it.
--   R3: SERVICE_DOCUMENT (1 row): the SQL concatenation, nested service -> theme -> sub-theme -> comment -> the tag's
--       sentiment and evidence quote, with the counts from SERVICE_SV beside each group. This is what the writers get.
--       SERVICE_EXPECTED lists the sections a complete report must have.
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

CREATE OR REPLACE TABLE SERVICE_ANSWERS AS
SELECT c.COMMENT_ID, c.TRUST, c.SERVICE, c.QUESTION, REGEXP_REPLACE(c.COMMENT_TEXT, '\\s+', ' ') AS COMMENT_TEXT,
       c.PATIENT_RATING, TRY_TO_NUMBER(a.ANSWER:impact::STRING) AS IMPACT, ARRAY_SIZE(a.PROBLEMS) = 0 AS VALID
FROM ANSWERS a JOIN SERVICE_COMMENTS c USING (COMMENT_ID)
WHERE a.RUN_ID = 'C09_svc_r1';

-- Only valid taxonomy pairs; a sub-theme given twice in one answer is kept once (its first tag).
CREATE OR REPLACE TABLE SERVICE_TAGS AS
SELECT a.COMMENT_ID, t.value:theme::STRING AS THEME, t.value:sub_theme::STRING AS SUB_THEME,
       t.value:sentiment_label::STRING AS SENTIMENT, REGEXP_REPLACE(t.value:evidence::STRING, '\\s+', ' ') AS EVIDENCE
FROM ANSWERS a, LATERAL FLATTEN(a.ANSWER:tags) t, RULEBOOK r
WHERE a.RUN_ID = 'C09_svc_r1'
  AND ARRAY_CONTAINS((t.value:theme::STRING || ' > ' || t.value:sub_theme::STRING)::VARIANT, r.ALLOWED_PAIRS)
QUALIFY ROW_NUMBER() OVER (PARTITION BY a.COMMENT_ID, t.value:sub_theme::STRING ORDER BY t.index) = 1;

CREATE OR REPLACE SEMANTIC VIEW SERVICE_SV
  TABLES (
    ANSWERS_T AS SERVICE_ANSWERS PRIMARY KEY (COMMENT_ID)
      COMMENT = 'One row per patient comment of the service, tagged by the winner (Gemini 3.1 Pro + structured v3)',
    TAGS_T AS SERVICE_TAGS PRIMARY KEY (COMMENT_ID, SUB_THEME)
      COMMENT = 'One row per comment and sub-theme the model gave, with the tag sentiment and evidence quote'
  )
  RELATIONSHIPS (
    TAG_TO_ANSWER AS TAGS_T (COMMENT_ID) REFERENCES ANSWERS_T
  )
  DIMENSIONS (
    ANSWERS_T.SERVICE AS ANSWERS_T.SERVICE COMMENT = 'Service',
    ANSWERS_T.QUESTION AS ANSWERS_T.QUESTION COMMENT = 'Survey question the comment answers',
    ANSWERS_T.IMPACT AS ANSWERS_T.IMPACT COMMENT = 'Impact of the whole comment, 1 (no problem) to 5 (harm or risk to safety)',
    TAGS_T.THEME AS TAGS_T.THEME COMMENT = 'Taxonomy theme',
    TAGS_T.SUB_THEME AS TAGS_T.SUB_THEME COMMENT = 'Taxonomy sub-theme',
    TAGS_T.SENTIMENT AS TAGS_T.SENTIMENT COMMENT = 'Sentiment of this tag: Positive, Neutral or Negative'
  )
  METRICS (
    ANSWERS_T.ALL_COMMENTS AS COUNT(DISTINCT ANSWERS_T.COMMENT_ID) COMMENT = 'Comments',
    ANSWERS_T.HIGH_IMPACT_COMMENTS AS COUNT(DISTINCT IFF(ANSWERS_T.IMPACT >= 4, ANSWERS_T.COMMENT_ID, NULL)) COMMENT = 'Comments with impact 4 or 5',
    TAGS_T.COMMENTS AS COUNT(DISTINCT TAGS_T.COMMENT_ID) COMMENT = 'Comments raising this theme or sub-theme (each comment once)',
    TAGS_T.NEGATIVE_COMMENTS AS COUNT(DISTINCT IFF(TAGS_T.SENTIMENT = 'Negative', TAGS_T.COMMENT_ID, NULL)) COMMENT = 'Comments with a negative tag',
    TAGS_T.POSITIVE_COMMENTS AS COUNT(DISTINCT IFF(TAGS_T.SENTIMENT = 'Positive', TAGS_T.COMMENT_ID, NULL)) COMMENT = 'Comments with a positive tag',
    TAGS_T.TAGS AS COUNT(*) COMMENT = 'Tags given (a comment can have several)'
  )
  COMMENT = 'One service report: comments, sentiment and impact per theme and sub-theme, each comment counted once';

-- SERVICE_EXPECTED: the sections a complete report must have - every theme, and every sub-theme with 5+ comments.
CREATE OR REPLACE VIEW SERVICE_EXPECTED AS
SELECT 'theme' AS LEVEL, THEME, NULL AS SUB_THEME, COMMENTS
FROM SEMANTIC_VIEW(SERVICE_SV DIMENSIONS TAGS_T.THEME METRICS TAGS_T.COMMENTS)
UNION ALL
SELECT 'sub_theme', THEME, SUB_THEME, COMMENTS
FROM SEMANTIC_VIEW(SERVICE_SV DIMENSIONS TAGS_T.THEME, TAGS_T.SUB_THEME METRICS TAGS_T.COMMENTS)
WHERE COMMENTS >= 5;

-- SERVICE_DOCUMENT (R3): sub-theme blocks (each comment with this tag's sentiment and evidence) are joined into theme
-- blocks, theme blocks into the service block. Biggest groups first; counts from SERVICE_SV.
CREATE OR REPLACE VIEW SERVICE_DOCUMENT AS
WITH st AS (SELECT * FROM SEMANTIC_VIEW(SERVICE_SV DIMENSIONS TAGS_T.THEME, TAGS_T.SUB_THEME
                                        METRICS TAGS_T.COMMENTS, TAGS_T.NEGATIVE_COMMENTS)),
th AS (SELECT * FROM SEMANTIC_VIEW(SERVICE_SV DIMENSIONS TAGS_T.THEME
                                   METRICS TAGS_T.COMMENTS, TAGS_T.NEGATIVE_COMMENTS, TAGS_T.POSITIVE_COMMENTS)),
sv AS (SELECT * FROM SEMANTIC_VIEW(SERVICE_SV DIMENSIONS ANSWERS_T.SERVICE METRICS ANSWERS_T.ALL_COMMENTS)),
sub AS (
  SELECT t.THEME, t.SUB_THEME, st.COMMENTS,
         '    SUB-THEME: ' || t.SUB_THEME || ' (' || st.COMMENTS || ' comments, '
         || ROUND(100 * st.NEGATIVE_COMMENTS / st.COMMENTS) || '% negative)\n'
         || LISTAGG('      COMMENT: "' || a.COMMENT_TEXT || '"\n        - ' || t.SENTIMENT || ' | evidence: "' || t.EVIDENCE || '"',
                    '\n') WITHIN GROUP (ORDER BY t.COMMENT_ID) AS BLOCK
  FROM SERVICE_TAGS t JOIN SERVICE_ANSWERS a USING (COMMENT_ID)
  JOIN st ON st.THEME = t.THEME AND st.SUB_THEME = t.SUB_THEME
  GROUP BY t.THEME, t.SUB_THEME, st.COMMENTS, st.NEGATIVE_COMMENTS),
thb AS (
  SELECT s.THEME, th.COMMENTS,
         '  THEME: ' || s.THEME || ' (' || th.COMMENTS || ' comments, ' || ROUND(100 * th.NEGATIVE_COMMENTS / th.COMMENTS)
         || '% negative, ' || ROUND(100 * th.POSITIVE_COMMENTS / th.COMMENTS) || '% positive)\n'
         || LISTAGG(s.BLOCK, '\n') WITHIN GROUP (ORDER BY s.COMMENTS DESC, s.SUB_THEME) AS BLOCK
  FROM sub s JOIN th ON th.THEME = s.THEME
  GROUP BY s.THEME, th.COMMENTS, th.NEGATIVE_COMMENTS, th.POSITIVE_COMMENTS)
SELECT 'SERVICE: ' || (SELECT ANY_VALUE(SERVICE) FROM sv) || ' (' || (SELECT ANY_VALUE(ALL_COMMENTS) FROM sv)
       || ' comments)\n' || LISTAGG(BLOCK, '\n') WITHIN GROUP (ORDER BY COMMENTS DESC, THEME) AS DOC
FROM thb;

-- Check R2: the semantic view against plain SQL (expect DIFF = 0).
WITH sv AS (SELECT * FROM SEMANTIC_VIEW(SERVICE_SV DIMENSIONS TAGS_T.THEME, TAGS_T.SUB_THEME
                                        METRICS TAGS_T.COMMENTS, TAGS_T.NEGATIVE_COMMENTS)),
plain AS (SELECT THEME, SUB_THEME, COUNT(DISTINCT COMMENT_ID) AS C,
                 COUNT(DISTINCT IFF(SENTIMENT = 'Negative', COMMENT_ID, NULL)) AS N
          FROM SERVICE_TAGS GROUP BY 1, 2)
SELECT COUNT(*) AS ROWS_COMPARED, SUM(ABS(sv.COMMENTS - p.C) + ABS(sv.NEGATIVE_COMMENTS - p.N)) AS DIFF
FROM sv JOIN plain p ON p.THEME = sv.THEME AND p.SUB_THEME = sv.SUB_THEME;
