-- aggregate.sql : the aggregation test. Turns tagged comments into an organisation-level report (one section per
-- theme) and scores it. Run after setup.sql (which loads prompts/summary_v1, report_judge_v1, report_consistency_v1
-- into PROMPTS) and after the tagging runs.
--
-- A report section has two parts:
--   counts (plain SQL, REPORT_COUNTS): unique comments, % negative, average impact, high-impact (4-5) comments
--   summary (AI, REPORT_SUMMARIES): 3-5 sentences + 2-3 word-for-word quotes, with no numbers in the text
--
-- Report sources (whose tags decide which comments go into which theme):
--   KEY      = ANSWER_KEY on the 209 sample comments (the reference)
--   C01_r1, C08_r1     = today's setup and the winner on the same 209 comments
--   C01_full, C08_full = the same two setups on all 4,846 pool comments (annual-sized; no reference exists)
--
-- Summary methods, run by RUN_SUMMARY(source, method, writer, repeat):
--   single    = one AI_COMPLETE call with every comment of every theme, returns all sections at once
--   mapreduce = AI_COMPLETE per chunk of 150 comments of a theme (map), then one call per theme to combine (reduce)
--   ai_agg    = AI_AGG per theme (Snowflake picks the model and handles any size), writer must be 'ai_agg'
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

-- REPORT_TAGS: one row per source x comment x valid sub-theme. SENTIMENT is the comment's overall label (more
-- Positive or Negative tags; the answer key's own label for KEY), so all sources are counted the same way.
CREATE OR REPLACE VIEW REPORT_TAGS AS
WITH runs AS (
  SELECT REGEXP_REPLACE(RUN_ID, '_p[1-8]_r1$', '') AS SOURCE, COMMENT_ID, ANSWER
  FROM ANSWERS
  WHERE RUN_ID IN ('C01_r1', 'C08_r1') OR RUN_ID RLIKE 'C0[18]_full_p[1-8]_r1'),
run_tags AS (
  SELECT r.SOURCE, r.COMMENT_ID, t.value:theme::STRING AS THEME, t.value:sub_theme::STRING AS SUB_THEME,
         t.value:sentiment_label::STRING AS TAG_SENTIMENT, TRY_TO_NUMBER(r.ANSWER:impact::STRING) AS IMPACT
  FROM runs r, LATERAL FLATTEN(r.ANSWER:tags) t),
run_sentiment AS (
  SELECT SOURCE, COMMENT_ID,
         CASE WHEN COUNT_IF(TAG_SENTIMENT = 'Positive') > COUNT_IF(TAG_SENTIMENT = 'Negative') THEN 'Positive'
              WHEN COUNT_IF(TAG_SENTIMENT = 'Negative') > COUNT_IF(TAG_SENTIMENT = 'Positive') THEN 'Negative'
              ELSE 'Neutral' END AS SENTIMENT
  FROM run_tags GROUP BY 1, 2),
all_tags AS (
  SELECT DISTINCT t.SOURCE, t.COMMENT_ID, t.THEME, t.SUB_THEME, s.SENTIMENT, t.IMPACT
  FROM run_tags t JOIN run_sentiment s USING (SOURCE, COMMENT_ID)
  UNION ALL
  SELECT DISTINCT 'KEY', k.COMMENT_ID, t.value:theme::STRING, t.value:sub_theme::STRING, k.SENTIMENT, k.IMPACT
  FROM ANSWER_KEY k, LATERAL FLATTEN(k.TAGS) t)
SELECT a.* FROM all_tags a, RULEBOOK r
WHERE ARRAY_CONTAINS((a.THEME || ' > ' || a.SUB_THEME)::VARIANT, r.ALLOWED_PAIRS);

-- REPORT_COUNTS: the report's numbers. One row per source x theme x sub-theme, plus one theme total row
-- (SUB_THEME = '(all)') that counts each comment once. N_TAG_ROWS on the total row = what a naive sum of the
-- sub-theme counts would give, so N_TAG_ROWS / N_COMMENTS shows the double counting.
CREATE OR REPLACE VIEW REPORT_COUNTS AS
SELECT SOURCE, THEME, COALESCE(SUB_THEME, '(all)') AS SUB_THEME,
       COUNT(DISTINCT COMMENT_ID) AS N_COMMENTS,
       COUNT(*) AS N_TAG_ROWS,
       ROUND(100 * COUNT(DISTINCT IFF(SENTIMENT = 'Negative', COMMENT_ID, NULL)) / COUNT(DISTINCT COMMENT_ID), 1) AS PCT_NEGATIVE,
       ROUND(AVG(IMPACT), 2) AS AVG_IMPACT,
       COUNT(DISTINCT IFF(IMPACT >= 4, COMMENT_ID, NULL)) AS N_HIGH_IMPACT
FROM REPORT_TAGS
GROUP BY GROUPING SETS ((SOURCE, THEME, SUB_THEME), (SOURCE, THEME));

-- REPORT_LINES: the summary input, one line per source x theme x comment:
-- "[sub-theme(s) | sentiment] comment text". CHUNK_NO groups 150 comments for map-reduce.
CREATE OR REPLACE VIEW REPORT_LINES AS
SELECT t.SOURCE, t.THEME, t.COMMENT_ID, c.COMMENT_TEXT,
       '[' || LISTAGG(DISTINCT t.SUB_THEME, ', ') WITHIN GROUP (ORDER BY t.SUB_THEME) || ' | ' || ANY_VALUE(t.SENTIMENT)
         || '] ' || REPLACE(c.COMMENT_TEXT, '\n', ' ') AS LINE,
       CEIL(ROW_NUMBER() OVER (PARTITION BY t.SOURCE, t.THEME ORDER BY SHA2('nhs_eval_v2|chunk|' || t.COMMENT_ID)) / 150) AS CHUNK_NO
FROM REPORT_TAGS t JOIN COMMENTS c USING (COMMENT_ID)
GROUP BY t.SOURCE, t.THEME, t.COMMENT_ID, c.COMMENT_TEXT;

-- REPORT_COUNT_ACCURACY (sample only): each setup's counts per sub-theme against the answer key's.
CREATE OR REPLACE VIEW REPORT_COUNT_ACCURACY AS
WITH k AS (SELECT THEME, SUB_THEME, N_COMMENTS, RANK() OVER (ORDER BY N_COMMENTS DESC) AS RK
           FROM REPORT_COUNTS WHERE SOURCE = 'KEY' AND SUB_THEME <> '(all)'),
s AS (SELECT SOURCE, THEME, SUB_THEME, N_COMMENTS, RANK() OVER (PARTITION BY SOURCE ORDER BY N_COMMENTS DESC) AS RK
      FROM REPORT_COUNTS WHERE SOURCE IN ('C01_r1', 'C08_r1') AND SUB_THEME <> '(all)'),
j AS (SELECT src.SOURCE, k.THEME, k.SUB_THEME, k.N_COMMENTS AS KEY_N, COALESCE(s.N_COMMENTS, 0) AS SETUP_N, k.RK AS KEY_RK, s.RK AS SETUP_RK
      FROM k CROSS JOIN (SELECT COLUMN1 AS SOURCE FROM VALUES ('C01_r1'), ('C08_r1')) src
      LEFT JOIN s ON s.SOURCE = src.SOURCE AND s.THEME = k.THEME AND s.SUB_THEME = k.SUB_THEME)
SELECT SOURCE,
       ROUND(AVG(ABS(SETUP_N - KEY_N)), 2) AS MEAN_ABS_COUNT_ERROR,
       ROUND(100 * AVG(ABS(SETUP_N - KEY_N) / NULLIF(KEY_N, 0)), 1) AS MEAN_PCT_COUNT_ERROR,
       COUNT_IF(KEY_RK <= 10 AND SETUP_RK <= 10) AS TOP10_OVERLAP,
       ROUND(CORR(KEY_RK, COALESCE(SETUP_RK, 99)), 3) AS RANK_AGREEMENT
FROM j GROUP BY 1;

-- REPORT_SUMMARIES: one row per source x method x writer x repeat x theme. ERROR is set when the method failed
-- (e.g. the prompt is too long for the model's context), and SUMMARY is then empty.
CREATE TABLE IF NOT EXISTS REPORT_SUMMARIES (
  SOURCE        STRING,
  METHOD        STRING,
  WRITER        STRING,
  REPEAT_NO     NUMBER,
  THEME         STRING,
  SUMMARY       STRING,
  INPUT_CHARS   NUMBER,
  INPUT_TOKENS  NUMBER,
  OUTPUT_TOKENS NUMBER,
  CALLS         NUMBER,
  ERROR         STRING,
  CREATED_AT    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- RUN_SUMMARY(source, method, writer, repeat): writes one report's sections with one method, e.g.
-- CALL RUN_SUMMARY('C08_full', 'mapreduce', 'gemini-3.1-pro', 1). Re-running replaces that report's rows.
-- The writer must be a literal model name in AI_COMPLETE, so the call is built as text; only fixed values pass.
CREATE OR REPLACE PROCEDURE RUN_SUMMARY(P_SOURCE STRING, P_METHOD STRING, P_WRITER STRING, P_REPEAT NUMBER)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  v_tmp STRING DEFAULT 'T_MAP_' || REGEXP_REPLACE(P_SOURCE || '_' || P_WRITER || '_' || P_REPEAT, '[^A-Za-z0-9_]', '_');
  v_params STRING DEFAULT '{''temperature'': 0, ''max_tokens'': 8192}';
  v_err STRING;
  v_instr STRING;
  bad_input EXCEPTION (-20003, 'Unknown source, method or writer');
BEGIN
  IF (NOT (P_SOURCE IN ('KEY', 'C01_r1', 'C08_r1', 'C01_full', 'C08_full')
           AND ((P_METHOD IN ('single', 'mapreduce') AND P_WRITER IN ('mistral-large3', 'gemini-3.1-pro'))
                OR (P_METHOD = 'ai_agg' AND P_WRITER = 'ai_agg')))) THEN
    RAISE bad_input;
  END IF;
  DELETE FROM REPORT_SUMMARIES
    WHERE SOURCE = :P_SOURCE AND METHOD = :P_METHOD AND WRITER = :P_WRITER AND REPEAT_NO = :P_REPEAT;

  BEGIN
    IF (P_METHOD = 'single') THEN
      -- All themes in one call; the answer is {"sections": [{"theme", "text"}]}.
      EXECUTE IMMEDIATE '
        INSERT INTO REPORT_SUMMARIES (SOURCE, METHOD, WRITER, REPEAT_NO, THEME, SUMMARY, INPUT_CHARS, INPUT_TOKENS, OUTPUT_TOKENS, CALLS, ERROR)
        WITH body AS (
          SELECT LISTAGG(''## '' || THEME || ''\n'' || LINES, ''\n\n'') WITHIN GROUP (ORDER BY THEME) AS TXT,
                 ARRAY_AGG(THEME) WITHIN GROUP (ORDER BY THEME) AS THEMES
          FROM (SELECT THEME, LISTAGG(LINE, ''\n'') WITHIN GROUP (ORDER BY COMMENT_ID) AS LINES
                FROM REPORT_LINES WHERE SOURCE = ? GROUP BY THEME)),
        call AS (
          SELECT LENGTH(b.TXT) AS N_CHARS,
                 AI_COMPLETE(model => ''' || P_WRITER || ''',
                   prompt => p.PROMPT_TEXT || ''\nThe comments below are grouped by theme (lines starting with ##). ''
                             || ''Write one section for every theme, following the rules above for each.\n\n'' || b.TXT,
                   model_parameters => ' || v_params || ',
                   response_format => OBJECT_CONSTRUCT(''type'', ''json'', ''schema'', OBJECT_CONSTRUCT(
                     ''type'', ''object'', ''required'', ARRAY_CONSTRUCT(''sections''),
                     ''properties'', OBJECT_CONSTRUCT(''sections'', OBJECT_CONSTRUCT(''type'', ''array'', ''items'', OBJECT_CONSTRUCT(
                       ''type'', ''object'', ''required'', ARRAY_CONSTRUCT(''theme'', ''text''),
                       ''properties'', OBJECT_CONSTRUCT(''theme'', OBJECT_CONSTRUCT(''type'', ''string'', ''enum'', b.THEMES),
                                                         ''text'', OBJECT_CONSTRUCT(''type'', ''string''))))))),
                   show_details => TRUE) AS R
          FROM body b, PROMPTS p WHERE p.PROMPT = ''summary_v1'')
        -- OUTER flatten keeps one row when the model returns no sections, so the failure is recorded with its reply.
        SELECT ?, ?, ?, ?, COALESCE(s.value:theme::STRING, ''(all)''), s.value:text::STRING,
               IFF(COALESCE(s.index, 0) = 0, c.N_CHARS, 0), IFF(COALESCE(s.index, 0) = 0, c.R:usage:prompt_tokens, 0),
               IFF(COALESCE(s.index, 0) = 0, c.R:usage:completion_tokens, 0), IFF(COALESCE(s.index, 0) = 0, 1, 0),
               IFF(s.value IS NULL, ''no sections returned: '' || LEFT(COALESCE(c.R::STRING, ''(null reply)''), 500), NULL)
        FROM call c, LATERAL FLATTEN(c.R:structured_output[0]:raw_message:sections, OUTER => TRUE) s'
        USING (P_SOURCE, P_SOURCE, P_METHOD, P_WRITER, P_REPEAT);

    ELSEIF (P_METHOD = 'mapreduce') THEN
      -- Map: one call per chunk of up to 150 comments of a theme.
      EXECUTE IMMEDIATE '
        CREATE OR REPLACE TEMPORARY TABLE ' || v_tmp || ' AS
        WITH chunks AS (
          SELECT THEME, CHUNK_NO, LISTAGG(LINE, ''\n'') WITHIN GROUP (ORDER BY COMMENT_ID) AS TXT
          FROM REPORT_LINES WHERE SOURCE = ? GROUP BY THEME, CHUNK_NO)
        SELECT k.THEME, k.CHUNK_NO, LENGTH(k.TXT) AS N_CHARS,
               AI_COMPLETE(model => ''' || P_WRITER || ''',
                 prompt => p.PROMPT_TEXT || ''\n\nTHEME: '' || k.THEME || ''\n\nCOMMENTS\n'' || k.TXT,
                 model_parameters => ' || v_params || ', show_details => TRUE) AS R
        FROM chunks k, PROMPTS p WHERE p.PROMPT = ''summary_v1'''
        USING (P_SOURCE);
      -- Reduce: one call per theme combining its chunk sections (a theme with one chunk keeps it as is).
      EXECUTE IMMEDIATE '
        INSERT INTO REPORT_SUMMARIES (SOURCE, METHOD, WRITER, REPEAT_NO, THEME, SUMMARY, INPUT_CHARS, INPUT_TOKENS, OUTPUT_TOKENS, CALLS)
        WITH m AS (
          SELECT THEME, COUNT(*) AS N_CHUNKS, SUM(N_CHARS) AS N_CHARS,
                 SUM(R:usage:prompt_tokens) AS IT, SUM(R:usage:completion_tokens) AS OT,
                 LISTAGG(''--- part '' || CHUNK_NO || ''\n'' || R:choices[0]:messages::STRING, ''\n\n'') WITHIN GROUP (ORDER BY CHUNK_NO) AS PARTS,
                 ANY_VALUE(R:choices[0]:messages::STRING) AS ONLY_PART
          FROM ' || v_tmp || ' GROUP BY THEME),
        r AS (
          SELECT m.THEME, AI_COMPLETE(model => ''' || P_WRITER || ''',
                   prompt => p.PROMPT_TEXT || ''\n\nBelow are sections written for different parts of the comments of one theme. ''
                             || ''Combine them into one section for the whole theme, following the same rules. ''
                             || ''Keep quotes exactly as they appear in the parts.\n\nTHEME: '' || m.THEME || ''\n\n'' || m.PARTS,
                   model_parameters => ' || v_params || ', show_details => TRUE) AS R
          FROM m, PROMPTS p WHERE p.PROMPT = ''summary_v1'' AND m.N_CHUNKS > 1)
        SELECT ?, ?, ?, ?, m.THEME, IFF(m.N_CHUNKS = 1, m.ONLY_PART, r.R:choices[0]:messages::STRING), m.N_CHARS,
               m.IT + COALESCE(r.R:usage:prompt_tokens, 0), m.OT + COALESCE(r.R:usage:completion_tokens, 0),
               m.N_CHUNKS + IFF(m.N_CHUNKS = 1, 0, 1)
        FROM m LEFT JOIN r ON r.THEME = m.THEME'
        USING (P_SOURCE, P_METHOD, P_WRITER, P_REPEAT);
      EXECUTE IMMEDIATE 'DROP TABLE IF EXISTS ' || v_tmp;

    ELSE
      -- AI_AGG: one aggregate per theme; Snowflake picks the model and splits large inputs itself.
      SELECT PROMPT_TEXT INTO :v_instr FROM PROMPTS WHERE PROMPT = 'summary_v1';
      INSERT INTO REPORT_SUMMARIES (SOURCE, METHOD, WRITER, REPEAT_NO, THEME, SUMMARY, INPUT_CHARS, CALLS)
        SELECT :P_SOURCE, :P_METHOD, :P_WRITER, :P_REPEAT, l.THEME, AI_AGG(l.LINE, :v_instr), SUM(LENGTH(l.LINE)), 1
        FROM REPORT_LINES l WHERE l.SOURCE = :P_SOURCE GROUP BY l.THEME;
    END IF;
  EXCEPTION
    WHEN OTHER THEN
      v_err := SQLERRM;
      INSERT INTO REPORT_SUMMARIES (SOURCE, METHOD, WRITER, REPEAT_NO, THEME, INPUT_CHARS, CALLS, ERROR)
        SELECT :P_SOURCE, :P_METHOD, :P_WRITER, :P_REPEAT, '(all)', SUM(LENGTH(LINE)), 1, :v_err
        FROM REPORT_LINES WHERE SOURCE = :P_SOURCE;
      EXECUTE IMMEDIATE 'DROP TABLE IF EXISTS ' || v_tmp;
  END;

  RETURN (SELECT :P_SOURCE || ' ' || :P_METHOD || ' ' || :P_WRITER || ' r' || :P_REPEAT || ': '
                 || COUNT_IF(SUMMARY IS NOT NULL) || ' sections' || COALESCE(', ERROR: ' || LEFT(MAX(ERROR), 200), '')
          FROM REPORT_SUMMARIES
          WHERE SOURCE = :P_SOURCE AND METHOD = :P_METHOD AND WRITER = :P_WRITER AND REPEAT_NO = :P_REPEAT);
END;
$$;

-- REPORT_SECTIONS: the sections actually delivered, one per report and theme (if a model wrote a theme twice, the
-- longer one is kept). Scoring uses this view; REPORT_SUMMARIES keeps everything the model returned.
CREATE OR REPLACE VIEW REPORT_SECTIONS AS
SELECT * FROM REPORT_SUMMARIES
WHERE SUMMARY IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY SOURCE, METHOD, WRITER, REPEAT_NO, THEME ORDER BY LENGTH(SUMMARY) DESC) = 1;

-- REPORT_SCORES: one row per summary section. Plain checks (numbers, quotes) plus the judge's faithfulness and
-- coverage (Claude Sonnet 4.6, J01 in MODELS) and the agreement between repeat 1 and repeat 2.
CREATE TABLE IF NOT EXISTS REPORT_SCORES (
  SOURCE         STRING,
  METHOD         STRING,
  WRITER         STRING,
  REPEAT_NO      NUMBER,
  THEME          STRING,
  HAS_NUMBERS    BOOLEAN,
  N_QUOTES       NUMBER,
  N_QUOTES_REAL  NUMBER,
  FAITHFULNESS   FLOAT,
  COVERAGE       FLOAT,
  UNSUPPORTED    ARRAY,
  CONSISTENCY    FLOAT,
  CREATED_AT     TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- SCORE_REPORTS(): rebuilds REPORT_SCORES for every summary section. The judge sees the theme's top 3 sub-themes
-- (from the answer key for sample sources, from the source's own counts at full scale) and up to 200 of the
-- theme's comments (a fixed hash pick).
CREATE OR REPLACE PROCEDURE SCORE_REPORTS()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  v_judge STRING;
BEGIN
  SELECT MODEL INTO :v_judge FROM MODELS WHERE ROLE = 'judge';
  IF (NOT REGEXP_LIKE(v_judge, '[A-Za-z0-9._-]+')) THEN
    RETURN 'unexpected judge name';
  END IF;
  DELETE FROM REPORT_SCORES;

  EXECUTE IMMEDIATE '
    INSERT INTO REPORT_SCORES (SOURCE, METHOD, WRITER, REPEAT_NO, THEME, HAS_NUMBERS, N_QUOTES, N_QUOTES_REAL,
                               FAITHFULNESS, COVERAGE, UNSUPPORTED)
    WITH s AS (SELECT * FROM REPORT_SECTIONS),
    quotes AS (
      SELECT s.SOURCE, s.METHOD, s.WRITER, s.REPEAT_NO, s.THEME, q.index AS QI, q.value::STRING AS QUOTE
      FROM s, LATERAL FLATTEN(REGEXP_SUBSTR_ALL(TRANSLATE(s.SUMMARY, ''“”'', ''""''), ''"([^"]{8,})"'', 1, 1, ''e'', 1)) q),
    quote_found AS (
      SELECT q.SOURCE, q.METHOD, q.WRITER, q.REPEAT_NO, q.THEME, q.QI, MAX(IFF(l.COMMENT_ID IS NULL, 0, 1)) AS FOUND
      FROM quotes q LEFT JOIN REPORT_LINES l
        ON l.SOURCE = q.SOURCE AND l.THEME = q.THEME AND CONTAINS(NORM_QUOTE(l.COMMENT_TEXT), NORM_QUOTE(q.QUOTE))
      GROUP BY 1, 2, 3, 4, 5, 6),
    quote_check AS (
      SELECT SOURCE, METHOD, WRITER, REPEAT_NO, THEME, COUNT(*) AS N_Q, SUM(FOUND) AS N_REAL
      FROM quote_found GROUP BY 1, 2, 3, 4, 5),
    top3 AS (
      SELECT SOURCE, THEME, LISTAGG(''- '' || SUB_THEME, ''\n'') WITHIN GROUP (ORDER BY N_COMMENTS DESC, SUB_THEME) AS TOP
      FROM (SELECT src.SOURCE, c.THEME, c.SUB_THEME, c.N_COMMENTS
            FROM (SELECT DISTINCT SOURCE FROM REPORT_SUMMARIES) src
            JOIN REPORT_COUNTS c ON c.SOURCE = IFF(src.SOURCE IN (''C01_r1'', ''C08_r1''), ''KEY'', src.SOURCE)
            WHERE c.SUB_THEME <> ''(all)''
            QUALIFY ROW_NUMBER() OVER (PARTITION BY src.SOURCE, c.THEME ORDER BY c.N_COMMENTS DESC, c.SUB_THEME) <= 3)
      GROUP BY 1, 2),
    sample_lines AS (
      SELECT SOURCE, THEME, LISTAGG(LINE, ''\n'') WITHIN GROUP (ORDER BY COMMENT_ID) AS TXT
      FROM (SELECT * FROM REPORT_LINES
            QUALIFY ROW_NUMBER() OVER (PARTITION BY SOURCE, THEME ORDER BY SHA2(''nhs_eval_v2|judge|'' || COMMENT_ID)) <= 200)
      GROUP BY 1, 2),
    judged AS (
      SELECT s.*, AI_COMPLETE(model => ''' || v_judge || ''',
               prompt => REPLACE(REPLACE(REPLACE(REPLACE(p.PROMPT_TEXT, ''{THEME}'', s.THEME), ''{TOP}'', COALESCE(t.TOP, ''(none)'')),
                                 ''{COMMENTS}'', COALESCE(l.TXT, '''')), ''{SUMMARY}'', s.SUMMARY),
               model_parameters => {''temperature'': 0, ''max_tokens'': 1024},
               response_format => {''type'': ''json'', ''schema'': {''type'': ''object'',
                 ''required'': [''faithfulness'', ''coverage'', ''unsupported''],
                 ''properties'': {''faithfulness'': {''type'': ''number''}, ''coverage'': {''type'': ''number''},
                                  ''unsupported'': {''type'': ''array'', ''items'': {''type'': ''string''}}}}}) AS J
      FROM s JOIN PROMPTS p ON p.PROMPT = ''report_judge_v1''
      LEFT JOIN top3 t ON t.SOURCE = s.SOURCE AND t.THEME = s.THEME
      LEFT JOIN sample_lines l ON l.SOURCE = s.SOURCE AND l.THEME = s.THEME)
    SELECT j.SOURCE, j.METHOD, j.WRITER, j.REPEAT_NO, j.THEME,
           REGEXP_LIKE(REGEXP_REPLACE(TRANSLATE(j.SUMMARY, ''\u201c\u201d'', ''""''), ''"[^"]*"'', ''''), ''.*[0-9].*'', ''s''),  -- digits outside quotes
           COALESCE(q.N_Q, 0), COALESCE(q.N_REAL, 0),
           j.J:faithfulness::FLOAT, j.J:coverage::FLOAT, j.J:unsupported::ARRAY
    FROM judged j LEFT JOIN quote_check q
      ON q.SOURCE = j.SOURCE AND q.METHOD = j.METHOD AND q.WRITER = j.WRITER AND q.REPEAT_NO = j.REPEAT_NO AND q.THEME = j.THEME';

  -- Consistency: repeat 1 vs repeat 2 of the same report section (stored on both rows).
  EXECUTE IMMEDIATE '
    UPDATE REPORT_SCORES x SET CONSISTENCY = c.SCORE
    FROM (
      SELECT a.SOURCE, a.METHOD, a.WRITER, a.THEME,
             AI_COMPLETE(model => ''' || v_judge || ''',
               prompt => REPLACE(REPLACE(p.PROMPT_TEXT, ''{A}'', a.SUMMARY), ''{B}'', b.SUMMARY),
               model_parameters => {''temperature'': 0, ''max_tokens'': 256},
               response_format => {''type'': ''json'', ''schema'': {''type'': ''object'', ''required'': [''agreement''],
                 ''properties'': {''agreement'': {''type'': ''number''}}}}):agreement::FLOAT AS SCORE
      FROM REPORT_SECTIONS a
      JOIN REPORT_SECTIONS b ON b.SOURCE = a.SOURCE AND b.METHOD = a.METHOD AND b.WRITER = a.WRITER
                             AND b.THEME = a.THEME AND b.REPEAT_NO = 2
      JOIN PROMPTS p ON p.PROMPT = ''report_consistency_v1''
      WHERE a.REPEAT_NO = 1) c
    WHERE x.SOURCE = c.SOURCE AND x.METHOD = c.METHOD AND x.WRITER = c.WRITER AND x.THEME = c.THEME';

  RETURN (SELECT COUNT(*) || ' sections scored' FROM REPORT_SCORES);
END;
$$;
