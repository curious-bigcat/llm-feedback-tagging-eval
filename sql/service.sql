-- service.sql : aggregation step R1, the comments of one service, the size of one real report: all 669 Forensic
-- comments (both survey questions). No AI calls here; then tag them once with the winner:
--   CALL RUN_MODEL('C09', 1, 'SERVICE_COMMENTS')   -> run C09_svc_r1
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

CREATE OR REPLACE TABLE SERVICE_COMMENTS AS
SELECT COMMENT_ID, RESPONDENT_ID, TRUST, SERVICE, QUESTION, COMMENT_TEXT, PATIENT_RATING
FROM COMMENTS
WHERE SERVICE = 'Forensic';

-- Check: comments per survey question.
SELECT QUESTION, COUNT(*) AS COMMENTS FROM SERVICE_COMMENTS GROUP BY 1 ORDER BY 1;
