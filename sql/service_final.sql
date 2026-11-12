-- service_final.sql : the finished service report (markdown, one row), laid out by SQL. Every number comes from
-- SERVICE_SV; every sentence and quote is copied unchanged from one written report in SERVICE_REPORTS.
-- Default: Gemini 3.1 Pro run 1 (change PICK to lay out another). No AI calls.
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

CREATE OR REPLACE VIEW SERVICE_FINAL_REPORT AS
WITH pick AS (SELECT 'gemini-3.1-pro' AS WRITER, 1 AS REPEAT_NO),
sv AS (SELECT * FROM SEMANTIC_VIEW(SERVICE_SV DIMENSIONS ANSWERS_T.SERVICE
                                   METRICS ANSWERS_T.ALL_COMMENTS, ANSWERS_T.HIGH_IMPACT_COMMENTS)),
qs AS (SELECT LISTAGG('"' || QUESTION || '" ' || ALL_COMMENTS, ', ') WITHIN GROUP (ORDER BY QUESTION DESC) AS Q
       FROM SEMANTIC_VIEW(SERVICE_SV DIMENSIONS ANSWERS_T.QUESTION METRICS ANSWERS_T.ALL_COMMENTS)),
th AS (SELECT * FROM SEMANTIC_VIEW(SERVICE_SV DIMENSIONS TAGS_T.THEME
                                   METRICS TAGS_T.COMMENTS, TAGS_T.NEGATIVE_COMMENTS, TAGS_T.POSITIVE_COMMENTS)),
st AS (SELECT * FROM SEMANTIC_VIEW(SERVICE_SV DIMENSIONS TAGS_T.THEME, TAGS_T.SUB_THEME
                                   METRICS TAGS_T.COMMENTS, TAGS_T.NEGATIVE_COMMENTS, TAGS_T.POSITIVE_COMMENTS)),
r AS (SELECT s.* FROM SERVICE_REPORTS s JOIN pick p ON p.WRITER = s.WRITER AND p.REPEAT_NO = s.REPEAT_NO),
quotes AS (
  SELECT r.SUB_THEME, LISTAGG('> "' || f.value::STRING || '"', '\n>\n') WITHIN GROUP (ORDER BY f.index) AS Q
  FROM r, LATERAL FLATTEN(r.QUOTES) f WHERE r.LEVEL = 'sub_theme' GROUP BY 1),
sub AS (
  SELECT st.THEME, st.COMMENTS,
         '#### ' || st.SUB_THEME || '\n*' || st.COMMENTS || ' comments - ' || ROUND(100 * st.NEGATIVE_COMMENTS / st.COMMENTS)
         || '% negative, ' || ROUND(100 * st.POSITIVE_COMMENTS / st.COMMENTS) || '% positive*\n\n' || r.SUMMARY
         || COALESCE('\n\n' || q.Q, '') AS BLOCK
  FROM st JOIN r ON r.LEVEL = 'sub_theme' AND UPPER(TRIM(r.SUB_THEME)) = UPPER(st.SUB_THEME)
  LEFT JOIN quotes q ON q.SUB_THEME = r.SUB_THEME),
subs AS (
  SELECT THEME, LISTAGG(BLOCK, '\n\n') WITHIN GROUP (ORDER BY COMMENTS DESC) AS B FROM sub GROUP BY 1),
thb AS (
  SELECT th.THEME, th.COMMENTS,
         '### ' || th.THEME || '\n*' || th.COMMENTS || ' comments - ' || ROUND(100 * th.NEGATIVE_COMMENTS / th.COMMENTS)
         || '% negative, ' || ROUND(100 * th.POSITIVE_COMMENTS / th.COMMENTS) || '% positive*\n\n' || r.SUMMARY
         || COALESCE('\n\n' || s.B, '') AS BLOCK
  FROM th JOIN r ON r.LEVEL = 'theme' AND UPPER(TRIM(r.THEME)) = UPPER(th.THEME)
  LEFT JOIN subs s ON s.THEME = th.THEME),
body AS (SELECT LISTAGG(BLOCK, '\n\n') WITHIN GROUP (ORDER BY COMMENTS DESC) AS B FROM thb),
tbl AS (
  SELECT LISTAGG('| ' || THEME || ' | ' || COMMENTS || ' | ' || ROUND(100 * NEGATIVE_COMMENTS / COMMENTS) || '% | '
                 || ROUND(100 * POSITIVE_COMMENTS / COMMENTS) || '% |', '\n') WITHIN GROUP (ORDER BY COMMENTS DESC) AS T
  FROM th),
ov AS (SELECT SUMMARY FROM r WHERE LEVEL = 'overview')
SELECT '# Patient feedback report: ' || sv.SERVICE || '\n\n'
       || '*' || sv.ALL_COMMENTS || ' comments (' || qs.Q || '); ' || sv.HIGH_IMPACT_COMMENTS
       || ' with high impact (4-5). Numbers from the semantic view SERVICE_SV; text written by '
       || pick.WRITER || ' (run ' || pick.REPEAT_NO || ').*\n\n'
       || '## Overview\n\n' || ov.SUMMARY || '\n\n'
       || '## Themes at a glance\n\n| Theme | Comments | Negative | Positive |\n|---|---|---|---|\n' || tbl.T || '\n\n'
       || 'A comment can raise more than one theme, so the theme counts add up to more than ' || sv.ALL_COMMENTS
       || '; within a theme each comment counts once.\n\n## Themes\n\n' || body.B AS REPORT
FROM sv, qs, tbl, body, ov, pick;

SELECT LENGTH(REPORT) AS CHARS FROM SERVICE_FINAL_REPORT;
