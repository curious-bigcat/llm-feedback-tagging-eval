-- sample.sql : builds SAMPLE_COMMENTS, the comments we develop and test on: at least 10 per sub-theme and at least
-- 10 per impact level (1-5). Real data has no labels, so a cheap model (Llama 3.3) first says roughly what each
-- comment is about and how serious it is; that is used only to pick comments, never as an answer. Re-running gives
-- the same picks for the same Llama tags (every pick uses a fixed hash).
--   1. leave out people whose comments copy a rulebook example quote (the model would have seen the answer), and
--      keep 20% of people aside for writing prompt examples, picked by SHA2 of the person id
--   2. Llama tags each remaining comment with sub-themes + the words that show them (a tag counts only if those
--      words are really in the comment), and a rough impact 1-5 for the whole comment
--   3. every group - each sub-theme and each impact level - takes comments in its own fixed shuffled order until it
--      has 10; one comment counts for every group it is in. A group with fewer than 10 comments takes all it has.
-- Only SAMPLE_COMMENTS is kept; the working tables are temporary.
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

-- NORM_QUOTE: text compared without case, curly quotes or spacing differences, so only the words must match.
CREATE OR REPLACE FUNCTION NORM_QUOTE(S STRING)
RETURNS STRING
AS
$$
  TRIM(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(
    TRANSLATE(LOWER(COALESCE(S, '')), '‘’‚‛“”„‟`´', '''''''''""""'''''),
    '\\s+([.,;:!?)])', '\\1'), '\\s+', ' '), '^[\\s"'']+|[\\s"'']+$', ''))
$$;

EXECUTE IMMEDIATE $$
DECLARE
  v_added NUMBER DEFAULT 1;
BEGIN
  -- 1. Comments we may sample from.
  CREATE OR REPLACE TEMPORARY TABLE T_POOL AS
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
      FROM (SELECT DISTINCT RESPONDENT_ID FROM COMMENTS))
    SELECT c.* FROM COMMENTS c JOIN people p USING (RESPONDENT_ID)
    WHERE p.P >= 0.2 AND c.RESPONDENT_ID NOT IN (SELECT RESPONDENT_ID FROM copied);

  -- 2. Rough tags and impact from Llama: short prompt (sub-theme names + the first 180 characters of each
  --    definition, and the same 1-5 impact scale as the v2 prompts).
  CREATE OR REPLACE TEMPORARY TABLE T_PRE AS
    WITH rules AS (
      SELECT LISTAGG('- ' || SUB_THEME || ': ' || LEFT(DEFINITION, 180), '\n') WITHIN GROUP (ORDER BY ORDINAL) AS LIST,
             OBJECT_CONSTRUCT('type', 'json', 'schema', OBJECT_CONSTRUCT(
               'type', 'object', 'additionalProperties', FALSE, 'required', ARRAY_CONSTRUCT('tags', 'impact'),
               'properties', OBJECT_CONSTRUCT(
                 'tags', OBJECT_CONSTRUCT('type', 'array', 'items', OBJECT_CONSTRUCT(
                   'type', 'object', 'additionalProperties', FALSE, 'required', ARRAY_CONSTRUCT('sub_theme', 'quote'),
                   'properties', OBJECT_CONSTRUCT(
                     'sub_theme', OBJECT_CONSTRUCT('type', 'string', 'enum', ARRAY_AGG(SUB_THEME) WITHIN GROUP (ORDER BY ORDINAL)),
                     'quote',     OBJECT_CONSTRUCT('type', 'string')))),
                 'impact', OBJECT_CONSTRUCT('type', 'integer')))) AS FMT
      FROM TAXONOMY)
    SELECT c.COMMENT_ID, c.COMMENT_TEXT,
           AI_COMPLETE(model => 'llama3.3-70b',
             prompt => 'List every sub-theme from the list below that this patient feedback comment is about. '
                    || 'For each, copy the exact words from the comment that show it. Use only names from the list.\n'
                    || 'Also rate the impact of the whole comment from 1 to 5: 1 = no problem raised (praise, thanks or '
                    || 'nothing to improve); 2 = minor inconvenience (parking, signs, food choice); 3 = clearly affected '
                    || 'the experience, no harm (a long wait, poor communication); 4 = significant distress, a delay in '
                    || 'care or a failure of service; 5 = harm or a risk to safety (serious neglect, a fall, a '
                    || 'safeguarding concern).\n\n'
                    || 'SUB-THEMES\n' || r.LIST || '\n\nSURVEY QUESTION\n' || c.QUESTION || '\n\nCOMMENT\n' || c.COMMENT_TEXT,
             model_parameters => {'temperature': 0, 'max_tokens': 1024},
             response_format => r.FMT) AS R
    FROM T_POOL c CROSS JOIN rules r;

  CREATE OR REPLACE TEMPORARY TABLE T_TAGS AS
    SELECT DISTINCT a.COMMENT_ID, t.value:sub_theme::STRING AS SUB_THEME
    FROM T_PRE a, LATERAL FLATTEN(a.R:tags) t
    WHERE NORM_QUOTE(t.value:quote::STRING) <> ''
      AND CONTAINS(NORM_QUOTE(a.COMMENT_TEXT), NORM_QUOTE(t.value:quote::STRING));

  -- Groups to fill: each sub-theme, and each impact level as 'Impact N'.
  CREATE OR REPLACE TEMPORARY TABLE T_GROUPS AS
    SELECT COMMENT_ID, SUB_THEME AS GRP FROM T_TAGS
    UNION
    SELECT COMMENT_ID, 'Impact ' || TRY_TO_NUMBER(R:impact::STRING) FROM T_PRE
    WHERE TRY_TO_NUMBER(R:impact::STRING) BETWEEN 1 AND 5;

  -- 3. Pick at least 10 per group, one round at a time.
  CREATE OR REPLACE TEMPORARY TABLE T_PICKED (COMMENT_ID STRING, PICKED_FOR STRING);
  WHILE (v_added > 0) DO
    INSERT INTO T_PICKED
      WITH have AS (
        SELECT g.GRP, COUNT(DISTINCT p.COMMENT_ID) AS N
        FROM T_GROUPS g LEFT JOIN T_PICKED p USING (COMMENT_ID) GROUP BY 1),
      nxt AS (
        SELECT g.GRP, g.COMMENT_ID
        FROM T_GROUPS g JOIN have h ON h.GRP = g.GRP AND h.N < 10
        WHERE g.COMMENT_ID NOT IN (SELECT COMMENT_ID FROM T_PICKED)
        QUALIFY ROW_NUMBER() OVER (PARTITION BY g.GRP ORDER BY SHA2('nhs_eval_v2|quota|' || g.COMMENT_ID)) = 1)
      SELECT COMMENT_ID, MIN(GRP) FROM nxt GROUP BY COMMENT_ID;
    v_added := SQLROWCOUNT;
  END WHILE;

  -- SUB_THEMES and IMPACT are Llama's rough pre-tags (used for picking only; the answer key comes from the panel).
  CREATE OR REPLACE TABLE SAMPLE_COMMENTS AS
    SELECT c.COMMENT_ID, c.QUESTION, c.COMMENT_TEXT, p.PICKED_FOR,
           (SELECT ARRAY_AGG(DISTINCT t.SUB_THEME) FROM T_TAGS t WHERE t.COMMENT_ID = c.COMMENT_ID) AS SUB_THEMES,
           TRY_TO_NUMBER(x.R:impact::STRING) AS IMPACT
    FROM T_PICKED p JOIN COMMENTS c USING (COMMENT_ID) JOIN T_PRE x USING (COMMENT_ID);
  RETURN (SELECT COUNT(*) FROM SAMPLE_COMMENTS) || ' comments in SAMPLE_COMMENTS';
END;
$$;

-- Coverage: comments per sub-theme and per impact level in SAMPLE_COMMENTS (should be 10 or more; fewer means the
-- data has too few).
SELECT f.value::STRING AS GRP, COUNT(*) AS COMMENTS
FROM SAMPLE_COMMENTS, LATERAL FLATTEN(SUB_THEMES) f GROUP BY 1
UNION ALL
SELECT 'Impact ' || IMPACT, COUNT(*) FROM SAMPLE_COMMENTS WHERE IMPACT IS NOT NULL GROUP BY 1
ORDER BY 2, 1;
