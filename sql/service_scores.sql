-- service_scores.sql : aggregation step R5, scores the 9 service reports in SERVICE_REPORTS (3 writers x 3 runs)
-- against the customer's reporting challenges. Judge: Claude Sonnet 4.6 (J01, not a writer), temperature 0, JSON
-- answers, one batch statement per score.
--   SERVICE_JUDGE       : per section, FAITHFUL = share of its claims supported by the comments it was written from
--                         (a sub-theme section: that sub-theme's comments; a theme: the theme's; the overview: all)
--   SERVICE_CONSISTENCY : per writer and section across the 3 runs, CONSISTENT = share of main points made in all 3
--   SERVICE_SCORES      : one row per writer, with the free SQL checks: coverage of the expected sections
--                         (SERVICE_EXPECTED), sub-theme sections the same in all 3 runs, quotes word for word in that
--                         sub-theme's evidence / in any of its comments, numbers in the text, tokens, failures
-- Upload the two prompt files and re-run setup.sql (reloads PROMPTS) first. Re-running replaces all scores.
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

-- SOFT_QUOTE: NORM_QUOTE, plus curly quotes made straight and anything that is not a letter or digit trimmed from
-- both ends, so a quote counts as word for word when only the wrapping differs ("The service was quick." inside
-- "The service was quick and ...").
CREATE OR REPLACE FUNCTION SOFT_QUOTE(S STRING) RETURNS STRING AS
'REGEXP_REPLACE(TRANSLATE(NORM_QUOTE(S), CHR(8216) || CHR(8217) || CHR(8220) || CHR(8221), CHR(39) || CHR(39) || CHR(34) || CHR(34)), ''^[^a-z0-9]+|[^a-z0-9]+$'', '''')';

-- SERVICE_LINES: the comments each section is judged against, one row per comment x sub-theme.
CREATE OR REPLACE VIEW SERVICE_LINES AS
SELECT t.THEME, t.SUB_THEME, t.COMMENT_ID, t.SENTIMENT, t.EVIDENCE, a.COMMENT_TEXT
FROM SERVICE_TAGS t JOIN SERVICE_ANSWERS a USING (COMMENT_ID);

CREATE OR REPLACE TABLE SERVICE_JUDGE AS
WITH src AS (
  SELECT 'sub_theme' AS LEVEL, THEME, SUB_THEME,
         LISTAGG('- (' || SENTIMENT || ') ' || COMMENT_TEXT, '\n') WITHIN GROUP (ORDER BY COMMENT_ID) AS COMMENTS
  FROM SERVICE_LINES GROUP BY 2, 3
  UNION ALL
  SELECT 'theme', THEME, NULL,
         LISTAGG('- (' || SENTIMENTS || ') ' || COMMENT_TEXT, '\n') WITHIN GROUP (ORDER BY COMMENT_ID)
  FROM (SELECT THEME, COMMENT_ID, ANY_VALUE(COMMENT_TEXT) AS COMMENT_TEXT,
               LISTAGG(DISTINCT SENTIMENT, '/') WITHIN GROUP (ORDER BY SENTIMENT) AS SENTIMENTS
        FROM SERVICE_LINES GROUP BY 1, 2)
  GROUP BY 2
  UNION ALL
  SELECT 'overview', NULL, NULL, DOC FROM SERVICE_DOCUMENT),
j AS (
  SELECT r.WRITER, r.REPEAT_NO, r.LEVEL, r.THEME, r.SUB_THEME,
         AI_COMPLETE(model => 'claude-sonnet-4-6',
           prompt => REPLACE(REPLACE(REPLACE(REPLACE(p.PROMPT_TEXT, '{LEVEL}', r.LEVEL),
                       '{NAME}', COALESCE(r.SUB_THEME, r.THEME, 'whole service')), '{SECTION}', r.SUMMARY),
                       '{COMMENTS}', c.COMMENTS),
           model_parameters => {'temperature': 0, 'max_tokens': 4096},
           response_format => PARSE_JSON('{"type": "json", "schema": {"type": "object", "additionalProperties": false,
             "required": ["claims"], "properties": {"claims": {"type": "array", "items": {"type": "object",
               "additionalProperties": false, "required": ["claim", "supported", "reason"], "properties": {
               "claim": {"type": "string"}, "supported": {"type": "boolean"}, "reason": {"type": "string"}}}}}}}'),
           show_details => TRUE) AS R
  FROM SERVICE_REPORTS r
  JOIN src c ON c.LEVEL = r.LEVEL AND EQUAL_NULL(UPPER(TRIM(c.THEME)), UPPER(TRIM(r.THEME)))
            AND EQUAL_NULL(UPPER(TRIM(c.SUB_THEME)), UPPER(TRIM(r.SUB_THEME)))
  JOIN PROMPTS p ON p.PROMPT = 'service_judge_v1'
  WHERE r.SUMMARY IS NOT NULL)
SELECT WRITER, REPEAT_NO, LEVEL, THEME, SUB_THEME, R:structured_output[0]:raw_message AS VERDICT,
       ARRAY_SIZE(FILTER(VERDICT:claims, x -> x:supported::BOOLEAN)) / NULLIF(ARRAY_SIZE(VERDICT:claims), 0) AS FAITHFUL,
       R:usage:prompt_tokens AS INPUT_TOKENS, R:usage:completion_tokens AS OUTPUT_TOKENS
FROM j;

-- Consistency of the overview and the theme sections (the levels every run writes).
CREATE OR REPLACE TABLE SERVICE_CONSISTENCY AS
WITH v AS (
  SELECT WRITER, LEVEL, UPPER(TRIM(COALESCE(THEME, 'Overview'))) AS NAME,
         MAX(IFF(REPEAT_NO = 1, SUMMARY, NULL)) AS V1, MAX(IFF(REPEAT_NO = 2, SUMMARY, NULL)) AS V2,
         MAX(IFF(REPEAT_NO = 3, SUMMARY, NULL)) AS V3
  FROM SERVICE_REPORTS WHERE LEVEL IN ('overview', 'theme') GROUP BY 1, 2, 3),
j AS (
  SELECT v.WRITER, v.LEVEL, v.NAME,
         AI_COMPLETE(model => 'claude-sonnet-4-6',
           prompt => REPLACE(REPLACE(REPLACE(REPLACE(p.PROMPT_TEXT, '{NAME}', v.NAME), '{V1}', v.V1), '{V2}', v.V2),
                     '{V3}', v.V3),
           model_parameters => {'temperature': 0, 'max_tokens': 4096},
           response_format => PARSE_JSON('{"type": "json", "schema": {"type": "object", "additionalProperties": false,
             "required": ["points"], "properties": {"points": {"type": "array", "items": {"type": "object",
               "additionalProperties": false, "required": ["point", "v1", "v2", "v3"], "properties": {
               "point": {"type": "string"}, "v1": {"type": "boolean"}, "v2": {"type": "boolean"},
               "v3": {"type": "boolean"}}}}}}}'),
           show_details => TRUE) AS R
  FROM v JOIN PROMPTS p ON p.PROMPT = 'service_consistency_v1'
  WHERE v.V1 IS NOT NULL AND v.V2 IS NOT NULL AND v.V3 IS NOT NULL)
SELECT WRITER, LEVEL, NAME, R:structured_output[0]:raw_message AS VERDICT,
       ARRAY_SIZE(FILTER(VERDICT:points, x -> x:v1::BOOLEAN AND x:v2::BOOLEAN AND x:v3::BOOLEAN))
         / NULLIF(ARRAY_SIZE(VERDICT:points), 0) AS CONSISTENT,
       ARRAY_SIZE(VERDICT:points) AS POINTS
FROM j;

-- SERVICE_SCORES: one row per writer (averages over its 3 runs).
CREATE OR REPLACE VIEW SERVICE_SCORES AS
WITH ex AS (
  SELECT LEVEL, UPPER(COALESCE(SUB_THEME, THEME)) AS NAME FROM SERVICE_EXPECTED),
ex_n AS (
  SELECT COUNT_IF(LEVEL = 'theme') AS N_THEMES, COUNT_IF(LEVEL = 'sub_theme') AS N_SUBTHEMES FROM ex),
written AS (
  SELECT DISTINCT WRITER, REPEAT_NO, LEVEL, UPPER(TRIM(COALESCE(SUB_THEME, THEME))) AS NAME
  FROM SERVICE_REPORTS WHERE LEVEL IN ('theme', 'sub_theme')),
cov AS (
  SELECT r.WRITER, r.REPEAT_NO,
         COUNT_IF(r.LEVEL = 'theme' AND ex.NAME IS NOT NULL) AS THEMES_COVERED,
         COUNT_IF(r.LEVEL = 'sub_theme' AND ex.NAME IS NOT NULL) AS SUBTHEMES_COVERED,
         COUNT_IF(r.LEVEL = 'sub_theme' AND ex.NAME IS NULL) AS EXTRA_SUBTHEMES,
         COALESCE(LISTAGG(IFF(r.LEVEL = 'sub_theme', r.NAME, NULL), '|') WITHIN GROUP (ORDER BY r.NAME), '') AS SUB_SET
  FROM written r LEFT JOIN ex ON ex.LEVEL = r.LEVEL AND ex.NAME = r.NAME
  GROUP BY 1, 2),
cov_w AS (
  SELECT WRITER, AVG(THEMES_COVERED) AS THEMES_COVERED, AVG(SUBTHEMES_COVERED) AS SUBTHEMES_COVERED,
         AVG(EXTRA_SUBTHEMES) AS EXTRA_SUBTHEMES_PER_RUN, IFF(COUNT(DISTINCT SUB_SET) = 1, 'yes', 'no') AS SAME_SUBTHEMES_3_RUNS
  FROM cov GROUP BY 1),
q AS (
  SELECT s.WRITER, s.REPEAT_NO, s.SUB_THEME, f.index AS QI,
         MAX(IFF(CONTAINS(SOFT_QUOTE(l.EVIDENCE), SOFT_QUOTE(f.value::STRING))
                 OR CONTAINS(SOFT_QUOTE(f.value::STRING), SOFT_QUOTE(l.EVIDENCE)), 1, 0)) AS IN_EVIDENCE,
         MAX(IFF(CONTAINS(SOFT_QUOTE(l.COMMENT_TEXT), SOFT_QUOTE(f.value::STRING)), 1, 0)) AS IN_COMMENT
  FROM SERVICE_REPORTS s
  CROSS JOIN LATERAL FLATTEN(s.QUOTES) f
  LEFT JOIN SERVICE_LINES l ON UPPER(l.SUB_THEME) = UPPER(TRIM(s.SUB_THEME))
  WHERE s.LEVEL = 'sub_theme'
  GROUP BY 1, 2, 3, 4),
q_w AS (
  SELECT WRITER, ROUND(100 * AVG(IN_EVIDENCE)) AS PCT_QUOTES_IN_EVIDENCE, ROUND(100 * AVG(IN_COMMENT)) AS PCT_QUOTES_IN_COMMENT,
         COUNT(*) AS QUOTES
  FROM q GROUP BY 1),
w AS (
  SELECT WRITER, COUNT_IF(LEVEL = 'error') AS FAILED_RUNS,
         COUNT_IF(REGEXP_LIKE(SUMMARY, '.*[0-9].*', 's')) AS SECTIONS_WITH_DIGITS,
         ROUND(AVG(INPUT_TOKENS)) AS INPUT_TOKENS, ROUND(AVG(OUTPUT_TOKENS)) AS OUTPUT_TOKENS
  FROM SERVICE_REPORTS GROUP BY 1),
jd AS (
  SELECT WRITER, ROUND(AVG(IFF(LEVEL = 'overview', FAITHFUL, NULL)), 3) AS FAITHFUL_OVERVIEW,
         ROUND(AVG(IFF(LEVEL = 'theme', FAITHFUL, NULL)), 3) AS FAITHFUL_THEMES,
         ROUND(AVG(IFF(LEVEL = 'sub_theme', FAITHFUL, NULL)), 3) AS FAITHFUL_SUBTHEMES
  FROM SERVICE_JUDGE GROUP BY 1),
cs AS (
  SELECT WRITER, ROUND(AVG(IFF(LEVEL = 'overview', CONSISTENT, NULL)), 3) AS CONSISTENT_OVERVIEW,
         ROUND(AVG(IFF(LEVEL = 'theme', CONSISTENT, NULL)), 3) AS CONSISTENT_THEMES
  FROM SERVICE_CONSISTENCY GROUP BY 1)
SELECT w.WRITER, w.FAILED_RUNS,
       ROUND(c.THEMES_COVERED, 1) || ' / ' || n.N_THEMES AS THEMES_COVERED,
       ROUND(c.SUBTHEMES_COVERED, 1) || ' / ' || n.N_SUBTHEMES AS SUBTHEMES_COVERED,
       ROUND(c.EXTRA_SUBTHEMES_PER_RUN, 1) AS EXTRA_SUBTHEMES_PER_RUN, c.SAME_SUBTHEMES_3_RUNS,
       jd.FAITHFUL_OVERVIEW, jd.FAITHFUL_THEMES, jd.FAITHFUL_SUBTHEMES,
       cs.CONSISTENT_OVERVIEW, cs.CONSISTENT_THEMES,
       q.QUOTES, q.PCT_QUOTES_IN_EVIDENCE, q.PCT_QUOTES_IN_COMMENT,
       w.SECTIONS_WITH_DIGITS, w.INPUT_TOKENS, w.OUTPUT_TOKENS
FROM w CROSS JOIN ex_n n LEFT JOIN cov_w c ON c.WRITER = w.WRITER LEFT JOIN jd ON jd.WRITER = w.WRITER
LEFT JOIN cs ON cs.WRITER = w.WRITER LEFT JOIN q_w q ON q.WRITER = w.WRITER;
