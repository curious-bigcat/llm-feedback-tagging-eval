-- 07_sample.sql : picks the scored sample (GV_SAMPLE) from the EVAL group made by 00_split.sql.
-- Real data has no labels, so a cheap model (Llama 3.3) first pre-tags every EVAL comment, only to know roughly
-- which sub-themes each comment is about; its tags are never used as an answer. Re-running gives the same sample.
--   1. GV_PRETAG: one AI_COMPLETE call per EVAL comment in a single statement (Snowflake runs them in parallel),
--      with a short prompt (sub-theme names + the first 180 characters of each definition, ~1,300 tokens instead of
--      the full rulebook's ~14,000) and a fixed answer format: a list of {sub_theme, quote}. A tag is kept only if
--      its quote is really in the comment. Skipped if GV_PRETAG is already filled (delete its rows to redo).
--   2. quota: every sub-theme gets 10 comments, taken in rounds from its own fixed shuffle
--      (SHA2('nhs_eval_v2|quota|' || COMMENT_ID)); a comment counts for every sub-theme it carries
--   3. random: 100 more EVAL comments in another fixed shuffle (SHA2('nhs_eval_v2|random|' || COMMENT_ID)), so
--      overall scores reflect ordinary feedback and not only the quota
-- A sub-theme with fewer than 10 tagged EVAL comments takes all it has; the coverage check lists it as thin.
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

CREATE TABLE IF NOT EXISTS GV_PRETAG (
  COMMENT_ID STRING,
  SUB_THEME  STRING,
  QUOTE      STRING
);

CREATE TABLE IF NOT EXISTS GV_SAMPLE (
  COMMENT_ID STRING PRIMARY KEY,
  PICKED_FOR STRING,
  PICKED_AT  TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

EXECUTE IMMEDIATE $$
DECLARE
  v_quota  NUMBER DEFAULT 10;
  v_random NUMBER DEFAULT 100;
  v_added  NUMBER DEFAULT 1;
BEGIN
  -- 1. Pre-tag (only once).
  IF ((SELECT COUNT(*) FROM GV_PRETAG) = 0) THEN
    INSERT INTO GV_PRETAG (COMMENT_ID, SUB_THEME, QUOTE)
      WITH rules AS (
        SELECT LISTAGG('- ' || SUB_THEME || ': ' || LEFT(DEFINITION, 180), '\n') WITHIN GROUP (ORDER BY ORDINAL) AS LIST,
               OBJECT_CONSTRUCT('type', 'json', 'schema', OBJECT_CONSTRUCT(
                 'type', 'object', 'additionalProperties', FALSE, 'required', ARRAY_CONSTRUCT('tags'),
                 'properties', OBJECT_CONSTRUCT('tags', OBJECT_CONSTRUCT('type', 'array', 'items', OBJECT_CONSTRUCT(
                   'type', 'object', 'additionalProperties', FALSE, 'required', ARRAY_CONSTRUCT('sub_theme', 'quote'),
                   'properties', OBJECT_CONSTRUCT(
                     'sub_theme', OBJECT_CONSTRUCT('type', 'string', 'enum', ARRAY_AGG(SUB_THEME) WITHIN GROUP (ORDER BY ORDINAL)),
                     'quote',     OBJECT_CONSTRUCT('type', 'string'))))))) AS FMT
        FROM TAXONOMY),
      a AS (
        SELECT c.COMMENT_ID, c.COMMENT_TEXT,
               AI_COMPLETE(model => 'llama3.3-70b',
                 prompt => 'List every sub-theme from the list below that this patient feedback comment is about. '
                        || 'For each, copy the exact words from the comment that show it. Use only names from the list.\n\n'
                        || 'SUB-THEMES\n' || r.LIST || '\n\nSURVEY QUESTION\n' || c.QUESTION || '\n\nCOMMENT\n' || c.COMMENT_TEXT,
                 model_parameters => {'temperature': 0, 'max_tokens': 1024},
                 response_format => r.FMT) AS R
        FROM COMMENTS c JOIN GV_SPLIT s USING (COMMENT_ID) CROSS JOIN rules r
        WHERE s.GRP = 'EVAL')
      SELECT DISTINCT a.COMMENT_ID, t.value:sub_theme::STRING, t.value:quote::STRING
      FROM a, LATERAL FLATTEN(a.R:tags) t
      WHERE NORM_QUOTE(t.value:quote::STRING) <> ''
        AND CONTAINS(NORM_QUOTE(a.COMMENT_TEXT), NORM_QUOTE(t.value:quote::STRING));
  END IF;

  -- 2. Quota, filled one round at a time: each round adds, for every sub-theme still short, its next comment in the
  -- fixed shuffle, until every sub-theme has 10 or has run out.
  DELETE FROM GV_SAMPLE;
  WHILE (v_added > 0) DO
    INSERT INTO GV_SAMPLE (COMMENT_ID, PICKED_FOR)
      WITH have AS (
        SELECT p.SUB_THEME, COUNT(DISTINCT g.COMMENT_ID) AS N
        FROM GV_PRETAG p LEFT JOIN GV_SAMPLE g USING (COMMENT_ID)
        GROUP BY 1),
      nxt AS (
        SELECT p.SUB_THEME, p.COMMENT_ID
        FROM GV_PRETAG p JOIN have h ON h.SUB_THEME = p.SUB_THEME AND h.N < :v_quota
        WHERE p.COMMENT_ID NOT IN (SELECT COMMENT_ID FROM GV_SAMPLE)
        QUALIFY ROW_NUMBER() OVER (PARTITION BY p.SUB_THEME ORDER BY SHA2('nhs_eval_v2|quota|' || p.COMMENT_ID)) = 1)
      SELECT COMMENT_ID, 'quota: ' || MIN(SUB_THEME) FROM nxt GROUP BY COMMENT_ID;
    v_added := SQLROWCOUNT;
  END WHILE;

  -- 3. Random part: 100 more EVAL comments not already picked.
  INSERT INTO GV_SAMPLE (COMMENT_ID, PICKED_FOR)
    SELECT COMMENT_ID, 'random' FROM GV_SPLIT
    WHERE GRP = 'EVAL' AND COMMENT_ID NOT IN (SELECT COMMENT_ID FROM GV_SAMPLE)
    QUALIFY ROW_NUMBER() OVER (ORDER BY SHA2('nhs_eval_v2|random|' || COMMENT_ID)) <= :v_random;

  RETURN (SELECT OBJECT_AGG(PART, N::VARIANT) FROM (
            SELECT IFF(PICKED_FOR = 'random', 'random', 'quota') PART, COUNT(*) N FROM GV_SAMPLE GROUP BY 1));
END;
$$;

-- Coverage check: per sub-theme, comments in the sample and in the whole EVAL group (by the pre-tags).
SELECT t.SUB_THEME,
       COUNT(DISTINCT IFF(g.COMMENT_ID IS NOT NULL, p.COMMENT_ID, NULL)) AS IN_SAMPLE,
       COUNT(DISTINCT p.COMMENT_ID) AS IN_EVAL
FROM TAXONOMY t
LEFT JOIN GV_PRETAG p ON p.SUB_THEME = t.SUB_THEME
LEFT JOIN GV_SAMPLE g ON g.COMMENT_ID = p.COMMENT_ID
GROUP BY t.SUB_THEME, t.ORDINAL
ORDER BY IN_SAMPLE, t.ORDINAL;
