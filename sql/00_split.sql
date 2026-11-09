-- 00_split.sql : splits the raw comments into DEV and EVAL groups, the way real customer data has to be prepared
-- (it arrives with no groups or labels). Safe to re-run: the same people always land in the same group.
--   DEV  = prompt examples and trial runs only; never scored
--   EVAL = the only comments a sample can be drawn from
-- Rules, applied per person so one person's comments are never in both groups:
--   1. leaked: any of their comments contains, or is contained in, a rulebook example quote (15+ characters) from
--      TAXONOMY.EXAMPLES; a model would get those right just by having seen the example in the prompt
--   2. otherwise the lowest 20% of people by SHA2('nhs_eval_v2|split|' || RESPONDENT_ID) go to DEV
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

-- NORM_QUOTE: prepares text for quote matching so punctuation style doesn't count, but words must match.
-- Lower case, curly quotes to straight, no space before punctuation, single spaces, no wrapping quote marks.
CREATE OR REPLACE FUNCTION NORM_QUOTE(S STRING)
RETURNS STRING
AS
$$
  TRIM(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(
    TRANSLATE(LOWER(COALESCE(S, '')), '‘’‚‛“”„‟`´', '''''''''""""'''''),
    '\\s+([.,;:!?)])', '\\1'), '\\s+', ' '), '^[\\s"'']+|[\\s"'']+$', ''))
$$;

-- GV_SPLIT: one row per comment with its group and why.
CREATE OR REPLACE TABLE GV_SPLIT AS
WITH quotes AS (
  SELECT DISTINCT NORM_QUOTE(f.value::STRING) AS QUOTE
  FROM TAXONOMY t,
       LATERAL FLATTEN(REGEXP_SUBSTR_ALL(TRANSLATE(t.EXAMPLES, '‘’“”', '''''""'), '[''"]([^''"]{15,})[''"]', 1, 1, 'e', 1)) f),
leaked AS (
  SELECT DISTINCT c.RESPONDENT_ID
  FROM COMMENTS c JOIN quotes q
    ON CONTAINS(NORM_QUOTE(c.COMMENT_TEXT), q.QUOTE)
    OR (LENGTH(NORM_QUOTE(c.COMMENT_TEXT)) >= 15 AND CONTAINS(q.QUOTE, NORM_QUOTE(c.COMMENT_TEXT)))),
people AS (
  SELECT RESPONDENT_ID,
         PERCENT_RANK() OVER (ORDER BY SHA2('nhs_eval_v2|split|' || RESPONDENT_ID)) AS P
  FROM (SELECT DISTINCT RESPONDENT_ID FROM COMMENTS))
SELECT c.COMMENT_ID, c.RESPONDENT_ID,
       IFF(l.RESPONDENT_ID IS NOT NULL OR p.P < 0.2, 'DEV', 'EVAL') AS GRP,
       CASE WHEN l.RESPONDENT_ID IS NOT NULL THEN 'leaked example' WHEN p.P < 0.2 THEN 'random 20%' ELSE 'eval' END AS REASON
FROM COMMENTS c
JOIN people p USING (RESPONDENT_ID)
LEFT JOIN leaked l USING (RESPONDENT_ID);

-- Checks: every comment has a group, no person in both groups, no leaked comment in EVAL.
SELECT 'every comment has a group' AS CHECK_NAME, (SELECT COUNT(*) FROM COMMENTS) - COUNT(*) AS PROBLEMS FROM GV_SPLIT
UNION ALL SELECT 'no person in both groups', COUNT(*) FROM (
  SELECT RESPONDENT_ID FROM GV_SPLIT GROUP BY 1 HAVING COUNT(DISTINCT GRP) > 1)
UNION ALL SELECT 'no leaked comment in EVAL', COUNT(*) FROM GV_SPLIT WHERE GRP = 'EVAL' AND REASON = 'leaked example';
