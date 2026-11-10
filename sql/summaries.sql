-- summaries.sql : aggregation step A4, writes the report text 3 ways from the tagged report slice (REPORT_TAGS).
-- The numbers are not written by the AI: they come from the semantic view REPORT_SV (step A3). The AI writes, per
-- theme, 3-5 sentences and 2-3 word-for-word quotes, plus a short overview of the whole service. Every method uses
-- the same instruction (prompts/summary_v2.txt, in PROMPTS) and, where a model can be chosen, the same writer
-- (Gemini 3.1 Pro), so only the method and the tags change.
--   big_prompt : all comments, each with its themes, in one AI_COMPLETE call -> overview + every section (JSON)
--   map_reduce : one AI_COMPLETE call per theme with only that theme's comments (map), then one call that writes the
--                overview from the sections (reduce)
--   ai_agg     : AI_AGG(comment, instruction) GROUP BY theme, then AI_AGG over the sections for the overview
-- E.g. CALL RUN_SUMMARY('C09', 'map_reduce', 1). Setup = whose tags: C09 (winner) or C01 (today).
-- Upload prompts/summary_v2.txt and re-run setup.sql (reloads PROMPTS) first.
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

-- REPORT_THEME_LINES: one row per setup x theme x comment (a comment with 2 sub-themes in one theme is listed once),
-- with the sentiment(s) of its tags in that theme. Input for map_reduce and ai_agg.
CREATE OR REPLACE VIEW REPORT_THEME_LINES AS
SELECT t.SETUP, t.THEME, t.COMMENT_ID,
       LISTAGG(DISTINCT t.SENTIMENT, '/') WITHIN GROUP (ORDER BY t.SENTIMENT) AS SENTIMENTS,
       ANY_VALUE(REGEXP_REPLACE(a.COMMENT_TEXT, '\\s+', ' ')) AS COMMENT_TEXT
FROM REPORT_TAGS t JOIN REPORT_ANSWERS a USING (SETUP, COMMENT_ID)
GROUP BY 1, 2, 3;

-- REPORT_COMMENT_LINES: one row per setup x comment, with all its themes, e.g. 'Staff (Positive); General (Positive)'.
-- Input for big_prompt.
CREATE OR REPLACE VIEW REPORT_COMMENT_LINES AS
SELECT SETUP, COMMENT_ID, ANY_VALUE(COMMENT_TEXT) AS COMMENT_TEXT,
       LISTAGG(THEME || ' (' || SENTIMENTS || ')', '; ') WITHIN GROUP (ORDER BY THEME) AS THEMES
FROM REPORT_THEME_LINES
GROUP BY 1, 2;

-- REPORT_SUMMARIES: one row per report section. THEME = a taxonomy theme, or 'Overview' for the whole service, or
-- 'ERROR' when the method failed (ERROR has the message). Tokens are per call where AI_COMPLETE reports them
-- (big_prompt: on the Overview row, for the single call); AI_AGG does not report them.
CREATE TABLE IF NOT EXISTS REPORT_SUMMARIES (
  SETUP         STRING,
  METHOD        STRING,
  REPEAT_NO     NUMBER,
  THEME         STRING,
  SUMMARY       STRING,
  QUOTES        ARRAY,
  INPUT_TOKENS  NUMBER,
  OUTPUT_TOKENS NUMBER,
  ERROR         STRING,
  RAW           VARIANT,
  CREATED_AT    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- RUN_SUMMARY(setup, method, repeat): writes one full report. Re-running replaces that report's rows.
CREATE OR REPLACE PROCEDURE RUN_SUMMARY(P_SETUP STRING, P_METHOD STRING, P_REPEAT NUMBER)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  v_prompt   STRING;
  v_overview STRING DEFAULT 'You write the overview at the top of a patient feedback report for an NHS service, for its '
    || 'managers. Below are the theme sections of the report. Write 2 to 3 sentences in plain British English on what '
    || 'patients say about the service as a whole: the biggest problems and the main praise. Do not write any numbers, '
    || 'counts or percentages, in digits or in words. Use only what the sections say.';
  v_tmp      STRING DEFAULT 'T_SUM_' || REGEXP_REPLACE(P_SETUP || '_' || P_METHOD || '_' || P_REPEAT, '[^A-Za-z0-9_]', '');
  v_sections STRING DEFAULT '{"type": "json", "schema": {"type": "object", "additionalProperties": false,
    "required": ["overview", "sections"], "properties": {"overview": {"type": "string"},
    "sections": {"type": "array", "items": {"type": "object", "additionalProperties": false,
      "required": ["theme", "summary", "quotes"], "properties": {"theme": {"type": "string"},
      "summary": {"type": "string"}, "quotes": {"type": "array", "items": {"type": "string"}}}}}}}}';
  v_section  STRING DEFAULT '{"type": "json", "schema": {"type": "object", "additionalProperties": false,
    "required": ["summary", "quotes"], "properties": {"summary": {"type": "string"},
    "quotes": {"type": "array", "items": {"type": "string"}}}}}';
  v_over_fmt STRING DEFAULT '{"type": "json", "schema": {"type": "object", "additionalProperties": false,
    "required": ["overview"], "properties": {"overview": {"type": "string"}}}}';
  bad_input EXCEPTION (-20001, 'Setup must be C09 or C01; method big_prompt, map_reduce or ai_agg');
BEGIN
  IF (P_SETUP NOT IN ('C09', 'C01') OR P_METHOD NOT IN ('big_prompt', 'map_reduce', 'ai_agg')) THEN
    RAISE bad_input;
  END IF;
  SELECT PROMPT_TEXT INTO :v_prompt FROM PROMPTS WHERE PROMPT = 'summary_v2';
  DELETE FROM REPORT_SUMMARIES WHERE SETUP = :P_SETUP AND METHOD = :P_METHOD AND REPEAT_NO = :P_REPEAT;

  IF (P_METHOD = 'big_prompt') THEN
    -- One call: every comment once, with its themes; the model must find and write every theme section itself.
    CREATE OR REPLACE TEMPORARY TABLE IDENTIFIER(:v_tmp) AS
      SELECT AI_COMPLETE(model => 'gemini-3.1-pro',
               prompt => :v_prompt || '\nTASK\nWrite a 2 to 3 sentence overview of the whole service, then one section '
                         || 'for every theme that appears in the comments below. Each comment is listed once, with the '
                         || 'themes it was tagged with and the sentiment of its tags in brackets.\n\nCOMMENTS\n'
                         || LISTAGG('- Themes: ' || THEMES || '\n  Comment: ' || COMMENT_TEXT, '\n')
                              WITHIN GROUP (ORDER BY COMMENT_ID),
               model_parameters => {'temperature': 0, 'max_tokens': 8192},
               response_format => PARSE_JSON(:v_sections), show_details => TRUE) AS R
      FROM REPORT_COMMENT_LINES WHERE SETUP = :P_SETUP;
    INSERT INTO REPORT_SUMMARIES (SETUP, METHOD, REPEAT_NO, THEME, SUMMARY, QUOTES, INPUT_TOKENS, OUTPUT_TOKENS, RAW)
      SELECT :P_SETUP, :P_METHOD, :P_REPEAT, 'Overview', R:structured_output[0]:raw_message:overview::STRING, NULL,
             R:usage:prompt_tokens, R:usage:completion_tokens, R
      FROM IDENTIFIER(:v_tmp)
      UNION ALL
      SELECT :P_SETUP, :P_METHOD, :P_REPEAT, s.value:theme::STRING, s.value:summary::STRING, s.value:quotes::ARRAY,
             NULL, NULL, NULL
      FROM IDENTIFIER(:v_tmp), LATERAL FLATTEN(R:structured_output[0]:raw_message:sections) s;

  ELSEIF (P_METHOD = 'map_reduce') THEN
    -- Map: one call per theme, with only that theme's comments (Snowflake runs the calls in parallel).
    CREATE OR REPLACE TEMPORARY TABLE IDENTIFIER(:v_tmp) AS
      SELECT THEME,
             AI_COMPLETE(model => 'gemini-3.1-pro',
               prompt => :v_prompt || '\nTASK\nWrite the section for the theme "' || THEME || '". Every comment below '
                         || 'was tagged with this theme; the sentiment of its tags is in brackets.\n\nCOMMENTS\n'
                         || LISTAGG('- (' || SENTIMENTS || ') ' || COMMENT_TEXT, '\n') WITHIN GROUP (ORDER BY COMMENT_ID),
               model_parameters => {'temperature': 0, 'max_tokens': 4096},
               response_format => PARSE_JSON(:v_section), show_details => TRUE) AS R
      FROM REPORT_THEME_LINES WHERE SETUP = :P_SETUP
      GROUP BY THEME;
    INSERT INTO REPORT_SUMMARIES (SETUP, METHOD, REPEAT_NO, THEME, SUMMARY, QUOTES, INPUT_TOKENS, OUTPUT_TOKENS, RAW)
      SELECT :P_SETUP, :P_METHOD, :P_REPEAT, THEME, R:structured_output[0]:raw_message:summary::STRING,
             R:structured_output[0]:raw_message:quotes::ARRAY, R:usage:prompt_tokens, R:usage:completion_tokens, R
      FROM IDENTIFIER(:v_tmp);
    -- Reduce: the overview, from the theme sections only.
    INSERT INTO REPORT_SUMMARIES (SETUP, METHOD, REPEAT_NO, THEME, SUMMARY, QUOTES, INPUT_TOKENS, OUTPUT_TOKENS, RAW)
      SELECT :P_SETUP, :P_METHOD, :P_REPEAT, 'Overview', R:structured_output[0]:raw_message:overview::STRING, NULL,
             R:usage:prompt_tokens, R:usage:completion_tokens, R
      FROM (SELECT AI_COMPLETE(model => 'gemini-3.1-pro',
                     prompt => :v_overview || '\n\nSECTIONS\n'
                               || LISTAGG('## ' || THEME || '\n' || SUMMARY, '\n\n') WITHIN GROUP (ORDER BY THEME),
                     model_parameters => {'temperature': 0, 'max_tokens': 2048},
                     response_format => PARSE_JSON(:v_over_fmt), show_details => TRUE) AS R
            FROM REPORT_SUMMARIES
            WHERE SETUP = :P_SETUP AND METHOD = :P_METHOD AND REPEAT_NO = :P_REPEAT AND SUMMARY IS NOT NULL);

  ELSE
    -- AI_AGG per theme: it splits long inputs itself. No JSON option, so the reply uses a fixed text layout that is
    -- parsed here: SUMMARY: <sentences> QUOTES: "<quote>" ...
    INSERT INTO REPORT_SUMMARIES (SETUP, METHOD, REPEAT_NO, THEME, SUMMARY, QUOTES, RAW)
      WITH a AS (
        SELECT THEME,
               AI_AGG('Theme: ' || THEME || ' | (' || SENTIMENTS || ') ' || COMMENT_TEXT,
                      :v_prompt || '\nTASK\nWrite the section for the theme that every comment was tagged with (shown '
                      || 'at the start of each comment, with the sentiment of its tags in brackets). Answer in exactly '
                      || 'this layout and nothing else:\nSUMMARY: <the sentences>\nQUOTES:\n"<quote 1>"\n"<quote 2>"') AS TXT
        FROM REPORT_THEME_LINES WHERE SETUP = :P_SETUP
        GROUP BY THEME)
      SELECT :P_SETUP, :P_METHOD, :P_REPEAT, THEME,
             COALESCE(TRIM(REGEXP_SUBSTR(TXT, 'SUMMARY:\\s*(.*?)\\s*QUOTES:', 1, 1, 'es', 1)), TXT),
             REGEXP_SUBSTR_ALL(COALESCE(REGEXP_SUBSTR(TXT, 'QUOTES:(.*)', 1, 1, 'es', 1), ''), '"([^"\\n]+)"', 1, 1, 'e', 1),
             TO_VARIANT(TXT)
      FROM a;
    INSERT INTO REPORT_SUMMARIES (SETUP, METHOD, REPEAT_NO, THEME, SUMMARY, RAW)
      SELECT :P_SETUP, :P_METHOD, :P_REPEAT, 'Overview', AGG, TO_VARIANT(AGG)
      FROM (SELECT AI_AGG('## ' || THEME || '\n' || SUMMARY, :v_overview) AS AGG
            FROM REPORT_SUMMARIES
            WHERE SETUP = :P_SETUP AND METHOD = :P_METHOD AND REPEAT_NO = :P_REPEAT AND SUMMARY IS NOT NULL);
  END IF;

  DROP TABLE IF EXISTS IDENTIFIER(:v_tmp);
  RETURN (SELECT :P_SETUP || ' ' || :P_METHOD || ' r' || :P_REPEAT || ': ' || COUNT_IF(THEME <> 'Overview')
                 || ' theme sections, overview ' || IFF(COUNT_IF(THEME = 'Overview' AND SUMMARY IS NOT NULL) = 1, 'ok', 'missing')
          FROM REPORT_SUMMARIES WHERE SETUP = :P_SETUP AND METHOD = :P_METHOD AND REPEAT_NO = :P_REPEAT);
EXCEPTION
  WHEN OTHER THEN
    -- e.g. the input is too long for one call: record the failure as the result.
    INSERT INTO REPORT_SUMMARIES (SETUP, METHOD, REPEAT_NO, THEME, ERROR)
      SELECT :P_SETUP, :P_METHOD, :P_REPEAT, 'ERROR', :SQLERRM;
    RETURN P_SETUP || ' ' || P_METHOD || ' r' || P_REPEAT || ': failed: ' || SQLERRM;
END;
$$;
