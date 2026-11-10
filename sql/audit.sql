-- audit.sql : step 10b, a blind check of the answer key. 30 of the rows the panel settled alone (DECIDED_BY = panel,
-- never seen by a person) go to the review app as REASON = 'audit'. The app shows only the comment - no tags, no
-- sentiment, no impact - and the person answers fresh. Answers are saved in REVIEW_QUEUE.DECISION only; ANSWER_KEY
-- is not changed. AUDIT_SCORES then compares the person with the panel. Safe to re-run: queues the 30 only once.
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

INSERT INTO REVIEW_QUEUE (REASON, COMMENT_ID, RUN_ID, DETAILS)
SELECT 'audit', COMMENT_ID, 'AUDIT', OBJECT_CONSTRUCT()
FROM ANSWER_KEY
WHERE DECIDED_BY = 'panel'
  AND NOT EXISTS (SELECT 1 FROM REVIEW_QUEUE WHERE REASON = 'audit')
QUALIFY ROW_NUMBER() OVER (ORDER BY SHA2('nhs_eval_v3|audit|' || COMMENT_ID)) <= 30;

-- AUDIT_ROWS: per audited comment, the panel's key and the person's answer side by side.
CREATE OR REPLACE VIEW AUDIT_ROWS AS
WITH person AS (
  SELECT q.COMMENT_ID, ARRAY_AGG(DISTINCT t.value:sub_theme::STRING) AS PERSON_TAGS,
         ANY_VALUE(q.DECISION:sentiment::STRING) AS PERSON_SENTIMENT, ANY_VALUE(q.DECISION:impact::INT) AS PERSON_IMPACT
  FROM REVIEW_QUEUE q, LATERAL FLATTEN(q.DECISION:tags) t
  WHERE q.REASON = 'audit' AND q.STATUS = 'done'
  GROUP BY 1),
panel AS (
  SELECT k.COMMENT_ID, ARRAY_AGG(DISTINCT t.value:sub_theme::STRING) AS PANEL_TAGS,
         ANY_VALUE(k.SENTIMENT) AS PANEL_SENTIMENT, ANY_VALUE(k.IMPACT) AS PANEL_IMPACT
  FROM ANSWER_KEY k, LATERAL FLATTEN(k.TAGS) t
  WHERE k.COMMENT_ID IN (SELECT COMMENT_ID FROM REVIEW_QUEUE WHERE REASON = 'audit')
  GROUP BY 1)
SELECT p.COMMENT_ID, c.COMMENT_TEXT, k.PANEL_TAGS, p.PERSON_TAGS,
       ARRAY_SIZE(ARRAY_INTERSECTION(k.PANEL_TAGS, p.PERSON_TAGS)) AS BOTH_N,
       ARRAY_SIZE(k.PANEL_TAGS) AS PANEL_N, ARRAY_SIZE(p.PERSON_TAGS) AS PERSON_N,
       k.PANEL_SENTIMENT, p.PERSON_SENTIMENT, k.PANEL_IMPACT, p.PERSON_IMPACT
FROM person p JOIN panel k USING (COMMENT_ID) JOIN SAMPLE_COMMENTS c USING (COMMENT_ID);

-- AUDIT_SCORES: the panel's key scored against the person (the person = truth here).
--   precision = panel tags the person also gave / panel tags (low = the key has extra tags)
--   recall    = person tags the panel also gave / person tags (low = the key misses tags)
CREATE OR REPLACE VIEW AUDIT_SCORES AS
SELECT COUNT(*) AS AUDITED,
       ROUND(SUM(BOTH_N) / NULLIF(SUM(PANEL_N), 0), 3) AS PRECISION,
       ROUND(SUM(BOTH_N) / NULLIF(SUM(PERSON_N), 0), 3) AS RECALL,
       ROUND(2 * SUM(BOTH_N) / NULLIF(SUM(PANEL_N) + SUM(PERSON_N), 0), 3) AS F1,
       ROUND(100 * COUNT_IF(BOTH_N = PANEL_N AND BOTH_N = PERSON_N) / COUNT(*), 1) AS PCT_SAME_TAGS,
       ROUND(100 * COUNT_IF(PANEL_SENTIMENT = PERSON_SENTIMENT) / COUNT(*), 1) AS PCT_SAME_SENTIMENT,
       ROUND(100 * COUNT_IF(PANEL_IMPACT = PERSON_IMPACT) / COUNT(*), 1) AS PCT_SAME_IMPACT,
       ROUND(100 * COUNT_IF(ABS(PANEL_IMPACT - PERSON_IMPACT) <= 1) / COUNT(*), 1) AS PCT_IMPACT_WITHIN_1
FROM AUDIT_ROWS;
