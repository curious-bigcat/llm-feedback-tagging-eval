-- fresh.sql : step 10a, builds FRESH_COMMENTS: 100 comments the prompt work never saw, to check that the winner's
-- results hold outside the 207-comment sample. Taken from the 20% of people kept aside in sample.sql (same hash, so the
-- same people), leaving out people whose comments copy a rulebook example quote. One comment per person (so no one
-- person's style dominates), picked in a fixed shuffled order. No AI calls; re-running gives the same 100.
-- Then: CALL RUN_MODEL('C09', 1, 'FRESH_COMMENTS') .. and JUDGE_RUN('C09', 1, 0, 'FRESH_COMMENTS') ..
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

CREATE OR REPLACE TABLE FRESH_COMMENTS AS
WITH quotes AS (
  SELECT DISTINCT NORM_QUOTE(f.value::STRING) AS QUOTE
  FROM TAXONOMY t,
       LATERAL FLATTEN(REGEXP_SUBSTR_ALL(TRANSLATE(t.EXAMPLES, '‘’“”', '''''""'), '[''"]([^''"]{15,})[''"]', 1, 1, 'e', 1)) f),
copied AS (
  SELECT DISTINCT c.RESPONDENT_ID FROM COMMENTS c JOIN quotes q
    ON CONTAINS(NORM_QUOTE(c.COMMENT_TEXT), q.QUOTE)
    OR (LENGTH(NORM_QUOTE(c.COMMENT_TEXT)) >= 15 AND CONTAINS(q.QUOTE, NORM_QUOTE(c.COMMENT_TEXT)))),
people AS (
  SELECT RESPONDENT_ID, PERCENT_RANK() OVER (ORDER BY SHA2('nhs_eval_v2|split|' || RESPONDENT_ID)) AS P
  FROM (SELECT DISTINCT RESPONDENT_ID FROM COMMENTS)),
one_each AS (
  SELECT c.COMMENT_ID, c.RESPONDENT_ID, c.QUESTION, c.COMMENT_TEXT
  FROM COMMENTS c JOIN people p USING (RESPONDENT_ID)
  WHERE p.P < 0.2 AND c.RESPONDENT_ID NOT IN (SELECT RESPONDENT_ID FROM copied)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY c.RESPONDENT_ID ORDER BY SHA2('nhs_eval_v3|fresh|' || c.COMMENT_ID)) = 1)
SELECT COMMENT_ID, QUESTION, COMMENT_TEXT
FROM one_each
QUALIFY ROW_NUMBER() OVER (ORDER BY SHA2('nhs_eval_v3|fresh|' || RESPONDENT_ID)) <= 100;

-- Safety check: none of these comments is in the sample (expect 0).
SELECT COUNT(*) AS IN_SAMPLE FROM FRESH_COMMENTS JOIN SAMPLE_COMMENTS USING (COMMENT_ID);
