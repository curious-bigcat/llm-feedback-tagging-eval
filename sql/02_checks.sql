-- 02_checks.sql : data checks for Step 1. Read-only; every row must show PROBLEMS = 0 before any AI call.
-- Each line counts the rows breaking one rule (or the gap from an expected count): row counts, unique ids,
-- one pile per person, no leaked comment in TEST, no empty comments, no expert-answer columns left, 14 setups.
-- (The scored sample is checked in 07_sample.sql once it is picked.)
USE SCHEMA VOC_EVAL.HARNESS;

SELECT 'comments row count is 6,211' AS CHECK_NAME, ABS(COUNT(*) - 6211) AS PROBLEMS FROM COMMENTS
UNION ALL SELECT 'taxonomy row count is 33', ABS(COUNT(*) - 33) FROM TAXONOMY
UNION ALL SELECT 'comment ids are unique', COUNT(*) - COUNT(DISTINCT COMMENT_ID) FROM COMMENTS
UNION ALL SELECT 'no person in both piles', COUNT(*) FROM (
  SELECT RESPONDENT_ID FROM COMMENTS GROUP BY 1 HAVING COUNT(DISTINCT PILE) > 1)
UNION ALL SELECT 'no leaked comment in TEST', COUNT(*) FROM COMMENTS WHERE LEAKED_QUOTE IS NOT NULL AND PILE = 'TEST'
UNION ALL SELECT 'every comment has text', COUNT(*) FROM COMMENTS WHERE COMMENT_TEXT IS NULL OR TRIM(COMMENT_TEXT) = ''
UNION ALL SELECT 'no expert-answer columns present', COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
  WHERE TABLE_SCHEMA = 'HARNESS' AND TABLE_NAME = 'COMMENTS' AND (COLUMN_NAME ILIKE 'HUMAN%' OR COLUMN_NAME = 'IN_SAMPLE')
UNION ALL SELECT 'settings table has 14 setups', ABS(COUNT(*) - 14) FROM V1_MODEL_CONFIG
ORDER BY 1;
