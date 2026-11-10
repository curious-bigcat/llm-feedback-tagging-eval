-- report.sql : aggregation step A1, builds REPORT_COMMENTS: 500 patient transport comments, standing in for one
-- monthly report. Picked by fixed hash from the whole service (both survey questions); no AI calls, re-running gives
-- the same 500. Then (A2): CALL RUN_MODEL('C09', 1, 'REPORT_COMMENTS') and CALL RUN_MODEL('C01', 1, 'REPORT_COMMENTS').
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

CREATE OR REPLACE TABLE REPORT_COMMENTS AS
SELECT COMMENT_ID, TRUST, SERVICE, QUESTION, COMMENT_TEXT, PATIENT_RATING
FROM COMMENTS
WHERE SERVICE = 'PTS - Patient Transport'
QUALIFY ROW_NUMBER() OVER (ORDER BY SHA2('nhs_eval_v3|report|' || COMMENT_ID)) <= 500;

-- Check: 500 rows, split by question.
SELECT QUESTION, COUNT(*) AS COMMENTS FROM REPORT_COMMENTS GROUP BY 1 ORDER BY 1;
