-- report_scores.sql : aggregation step A5, scores the 18 reports in REPORT_SUMMARIES (step A4).
-- Judge: Claude Sonnet 4.6 (J01 in MODELS; not a writer), temperature 0, JSON answers, one batch statement per score.
--   REPORT_TOPICS      : what each section should cover: the top 3 sub-themes of each theme by comment count from the
--                        semantic view REPORT_SV (3+ comments), and for the overview the top 3 themes other than General
--   REPORT_JUDGE       : per section (incl. the overview): FAITHFUL = share of its claims the comments support;
--                        COVERAGE = share of its key topics it mentions (prompts/report_judge_v2.txt)
--   REPORT_CONSISTENCY : per section across the 3 runs: CONSISTENT = share of main points made in all 3 runs
--                        (prompts/report_consistency_v2.txt)
--   REPORT_SCORES      : one row per tag set x method, with the free SQL checks (numbers in text, quotes real)
-- Each section is judged against the comments it was written from: that theme's comments (the overview: all comments).
-- Upload the two prompt files and re-run setup.sql (reloads PROMPTS) first. Re-running replaces all scores.
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

CREATE OR REPLACE TABLE REPORT_TOPICS AS
WITH st AS (SELECT * FROM SEMANTIC_VIEW(REPORT_SV DIMENSIONS ANSWERS_T.SETUP, TAGS_T.THEME, TAGS_T.SUB_THEME
                                         METRICS TAGS_T.COMMENTS)),
th AS (SELECT * FROM SEMANTIC_VIEW(REPORT_SV DIMENSIONS ANSWERS_T.SETUP, TAGS_T.THEME METRICS TAGS_T.COMMENTS))
SELECT SETUP, THEME, ARRAY_AGG(SUB_THEME) WITHIN GROUP (ORDER BY COMMENTS DESC, SUB_THEME) AS TOPICS
FROM (SELECT * FROM st WHERE COMMENTS >= 3
      QUALIFY ROW_NUMBER() OVER (PARTITION BY SETUP, THEME ORDER BY COMMENTS DESC, SUB_THEME) <= 3)
GROUP BY 1, 2
UNION ALL
SELECT SETUP, 'Overview', ARRAY_AGG(THEME) WITHIN GROUP (ORDER BY COMMENTS DESC, THEME)
FROM (SELECT * FROM th WHERE THEME <> 'General'
      QUALIFY ROW_NUMBER() OVER (PARTITION BY SETUP ORDER BY COMMENTS DESC, THEME) <= 3)
GROUP BY 1;

CREATE OR REPLACE TABLE REPORT_JUDGE AS
WITH src AS (
  SELECT SETUP, THEME, LISTAGG('- (' || SENTIMENTS || ') ' || COMMENT_TEXT, '\n') WITHIN GROUP (ORDER BY COMMENT_ID) AS COMMENTS
  FROM REPORT_THEME_LINES GROUP BY 1, 2
  UNION ALL
  SELECT SETUP, 'Overview', LISTAGG('- Themes: ' || THEMES || '\n  Comment: ' || COMMENT_TEXT, '\n')
                              WITHIN GROUP (ORDER BY COMMENT_ID)
  FROM REPORT_COMMENT_LINES GROUP BY 1),
j AS (
  SELECT s.SETUP, s.METHOD, s.REPEAT_NO, s.THEME,
         AI_COMPLETE(model => 'claude-sonnet-4-6',
           prompt => REPLACE(REPLACE(REPLACE(REPLACE(p.PROMPT_TEXT, '{THEME}', s.THEME), '{SECTION}', s.SUMMARY),
                       '{TOPICS}', COALESCE('- ' || ARRAY_TO_STRING(t.TOPICS, '\n- '),
                                            '(none: no sub-theme has 3 or more comments; return an empty topics list)')),
                     '{COMMENTS}', c.COMMENTS),
           model_parameters => {'temperature': 0, 'max_tokens': 4096},
           response_format => PARSE_JSON('{"type": "json", "schema": {"type": "object", "additionalProperties": false,
             "required": ["claims"], "properties": {
               "claims": {"type": "array", "items": {"type": "object", "additionalProperties": false,
                 "required": ["claim", "supported", "reason"], "properties": {"claim": {"type": "string"},
                 "supported": {"type": "boolean"}, "reason": {"type": "string"}}}},
               "topics": {"type": "array", "items": {"type": "object", "additionalProperties": false,
                 "required": ["topic", "mentioned"], "properties": {"topic": {"type": "string"},
                 "mentioned": {"type": "boolean"}}}}}}}'),
           show_details => TRUE) AS R,
         t.TOPICS
  FROM REPORT_SUMMARIES s
  JOIN src c ON c.SETUP = s.SETUP AND c.THEME = s.THEME
  LEFT JOIN REPORT_TOPICS t ON t.SETUP = s.SETUP AND t.THEME = s.THEME
  JOIN PROMPTS p ON p.PROMPT = 'report_judge_v2'
  WHERE s.SUMMARY IS NOT NULL)
SELECT SETUP, METHOD, REPEAT_NO, THEME, R:structured_output[0]:raw_message AS VERDICT,
       ARRAY_SIZE(FILTER(VERDICT:claims, x -> x:supported::BOOLEAN)) / NULLIF(ARRAY_SIZE(VERDICT:claims), 0) AS FAITHFUL,
       IFF(TOPICS IS NULL, NULL,
           ARRAY_SIZE(FILTER(VERDICT:topics, x -> x:mentioned::BOOLEAN)) / NULLIF(ARRAY_SIZE(VERDICT:topics), 0)) AS COVERAGE,
       R:usage:prompt_tokens AS INPUT_TOKENS, R:usage:completion_tokens AS OUTPUT_TOKENS
FROM j;

CREATE OR REPLACE TABLE REPORT_CONSISTENCY AS
WITH v AS (
  SELECT SETUP, METHOD, THEME,
         MAX(IFF(REPEAT_NO = 1, SUMMARY, NULL)) AS V1, MAX(IFF(REPEAT_NO = 2, SUMMARY, NULL)) AS V2,
         MAX(IFF(REPEAT_NO = 3, SUMMARY, NULL)) AS V3
  FROM REPORT_SUMMARIES WHERE THEME <> 'ERROR' GROUP BY 1, 2, 3),
j AS (
  SELECT v.SETUP, v.METHOD, v.THEME,
         AI_COMPLETE(model => 'claude-sonnet-4-6',
           prompt => REPLACE(REPLACE(REPLACE(REPLACE(p.PROMPT_TEXT, '{THEME}', v.THEME), '{V1}', v.V1), '{V2}', v.V2),
                     '{V3}', v.V3),
           model_parameters => {'temperature': 0, 'max_tokens': 4096},
           response_format => PARSE_JSON('{"type": "json", "schema": {"type": "object", "additionalProperties": false,
             "required": ["points"], "properties": {"points": {"type": "array", "items": {"type": "object",
               "additionalProperties": false, "required": ["point", "v1", "v2", "v3"], "properties": {
               "point": {"type": "string"}, "v1": {"type": "boolean"}, "v2": {"type": "boolean"},
               "v3": {"type": "boolean"}}}}}}}'),
           show_details => TRUE) AS R
  FROM v JOIN PROMPTS p ON p.PROMPT = 'report_consistency_v2'
  WHERE v.V1 IS NOT NULL AND v.V2 IS NOT NULL AND v.V3 IS NOT NULL)
SELECT SETUP, METHOD, THEME, R:structured_output[0]:raw_message AS VERDICT,
       ARRAY_SIZE(FILTER(VERDICT:points, x -> x:v1::BOOLEAN AND x:v2::BOOLEAN AND x:v3::BOOLEAN))
         / NULLIF(ARRAY_SIZE(VERDICT:points), 0) AS CONSISTENT,
       ARRAY_SIZE(VERDICT:points) AS POINTS,
       R:usage:prompt_tokens AS INPUT_TOKENS, R:usage:completion_tokens AS OUTPUT_TOKENS
FROM j;

-- REPORT_SCORES: one row per tag set x method; section scores are averages over the theme sections of the 3 runs,
-- overview scores over the 3 overviews.
CREATE OR REPLACE VIEW REPORT_SCORES AS
WITH quotes AS (
  SELECT s.SETUP, s.METHOD, s.REPEAT_NO, s.THEME, f.index AS QI,
         MAX(IFF(CONTAINS(NORM_QUOTE(l.COMMENT_TEXT), NORM_QUOTE(f.value::STRING)), 1, 0)) AS REAL
  FROM REPORT_SUMMARIES s
  CROSS JOIN LATERAL FLATTEN(s.QUOTES) f
  LEFT JOIN REPORT_THEME_LINES l ON l.SETUP = s.SETUP AND l.THEME = s.THEME
  GROUP BY 1, 2, 3, 4, 5),
q AS (SELECT SETUP, METHOD, COUNT(*) AS QUOTES, ROUND(100 * AVG(REAL), 1) AS PCT_QUOTES_REAL FROM quotes GROUP BY 1, 2),
w AS (
  SELECT SETUP, METHOD, COUNT_IF(THEME NOT IN ('Overview', 'ERROR')) / 3 AS SECTIONS_PER_REPORT,
         COUNT_IF(THEME = 'ERROR') AS FAILED_RUNS,
         COUNT_IF(REGEXP_LIKE(SUMMARY, '.*[0-9].*', 's')) AS SECTIONS_WITH_DIGITS,
         ROUND(SUM(INPUT_TOKENS) / 3) AS WRITER_IN_TOKENS_PER_REPORT, ROUND(SUM(OUTPUT_TOKENS) / 3) AS WRITER_OUT_TOKENS_PER_REPORT
  FROM REPORT_SUMMARIES GROUP BY 1, 2),
j AS (
  SELECT SETUP, METHOD,
         ROUND(AVG(IFF(THEME <> 'Overview', FAITHFUL, NULL)), 3) AS FAITHFUL,
         ROUND(AVG(IFF(THEME =  'Overview', FAITHFUL, NULL)), 3) AS OVERVIEW_FAITHFUL,
         ROUND(AVG(IFF(THEME <> 'Overview', COVERAGE, NULL)), 3) AS COVERAGE,
         ROUND(AVG(IFF(THEME =  'Overview', COVERAGE, NULL)), 3) AS OVERVIEW_COVERAGE,
         COUNT_IF(FAITHFUL IS NULL) AS NOT_JUDGED
  FROM REPORT_JUDGE GROUP BY 1, 2),
c AS (
  SELECT SETUP, METHOD,
         ROUND(AVG(IFF(THEME <> 'Overview', CONSISTENT, NULL)), 3) AS CONSISTENT,
         ROUND(AVG(IFF(THEME =  'Overview', CONSISTENT, NULL)), 3) AS OVERVIEW_CONSISTENT
  FROM REPORT_CONSISTENCY GROUP BY 1, 2)
SELECT w.SETUP, w.METHOD, w.SECTIONS_PER_REPORT, w.FAILED_RUNS, j.FAITHFUL, j.OVERVIEW_FAITHFUL, j.COVERAGE,
       j.OVERVIEW_COVERAGE, c.CONSISTENT, c.OVERVIEW_CONSISTENT, q.QUOTES, q.PCT_QUOTES_REAL, w.SECTIONS_WITH_DIGITS,
       w.WRITER_IN_TOKENS_PER_REPORT, w.WRITER_OUT_TOKENS_PER_REPORT, j.NOT_JUDGED
FROM w LEFT JOIN j USING (SETUP, METHOD) LEFT JOIN c USING (SETUP, METHOD) LEFT JOIN q USING (SETUP, METHOD);
