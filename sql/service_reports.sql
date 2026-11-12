-- service_reports.sql : aggregation step R4, the service report written by 3 writers from the same SQL-built
-- document (SERVICE_DOCUMENT, service_tags.sql) and the same instruction (prompts/service_report_v1.txt, in PROMPTS).
-- One AI_COMPLETE call per report, temperature 0, the same answer limit (8,192 tokens) for every writer, JSON answer:
--   {overview, themes: [{theme, summary, sub_themes: [{sub_theme, summary, quotes[]}]}]}
-- The numbers are not written by the AI: they come from SERVICE_SV when the report is laid out.
-- E.g. CALL RUN_SERVICE_REPORT('gemini-3.1-pro', 1). Writers: mistral-large3 (today), gemini-3.1-pro, openai-gpt-5.4.
-- A failure (e.g. input or answer too long) is recorded as an 'ERROR' row: it is a result, not a crash.
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

-- SERVICE_REPORTS: one row per report section. LEVEL = overview | theme | sub_theme | error.
CREATE TABLE IF NOT EXISTS SERVICE_REPORTS (
  WRITER        STRING,
  REPEAT_NO     NUMBER,
  LEVEL         STRING,
  THEME         STRING,
  SUB_THEME     STRING,
  SUMMARY       STRING,
  QUOTES        ARRAY,
  INPUT_TOKENS  NUMBER,
  OUTPUT_TOKENS NUMBER,
  ERROR         STRING,
  RAW           VARIANT,
  CREATED_AT    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE PROCEDURE RUN_SERVICE_REPORT(P_WRITER STRING, P_REPEAT NUMBER)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  v_tmp STRING DEFAULT 'T_SVC_' || REGEXP_REPLACE(P_WRITER || '_' || P_REPEAT, '[^A-Za-z0-9_]', '_');
  v_fmt STRING DEFAULT '{"type": "json", "schema": {"type": "object", "additionalProperties": false,
    "required": ["overview", "themes"], "properties": {"overview": {"type": "string"},
    "themes": {"type": "array", "items": {"type": "object", "additionalProperties": false,
      "required": ["theme", "summary", "sub_themes"], "properties": {"theme": {"type": "string"},
      "summary": {"type": "string"}, "sub_themes": {"type": "array", "items": {"type": "object",
        "additionalProperties": false, "required": ["sub_theme", "summary", "quotes"], "properties": {
        "sub_theme": {"type": "string"}, "summary": {"type": "string"},
        "quotes": {"type": "array", "items": {"type": "string"}}}}}}}}}}}';
  bad_input EXCEPTION (-20001, 'Writer must be mistral-large3, gemini-3.1-pro or openai-gpt-5.4');
BEGIN
  IF (P_WRITER NOT IN ('mistral-large3', 'gemini-3.1-pro', 'openai-gpt-5.4')) THEN
    RAISE bad_input;
  END IF;
  DELETE FROM SERVICE_REPORTS WHERE WRITER = :P_WRITER AND REPEAT_NO = :P_REPEAT;

  -- The model name must be a literal in AI_COMPLETE, so the call is built as text; it only ever comes from the
  -- allowed list above.
  EXECUTE IMMEDIATE '
    CREATE OR REPLACE TEMPORARY TABLE ' || v_tmp || ' AS
    SELECT AI_COMPLETE(model => ''' || P_WRITER || ''',
             prompt => REPLACE(p.PROMPT_TEXT, ''{DOCUMENT}'', d.DOC),
             model_parameters => {''temperature'': 0, ''max_tokens'': 8192},
             response_format => PARSE_JSON(?), show_details => TRUE) AS R
    FROM SERVICE_DOCUMENT d JOIN PROMPTS p ON p.PROMPT = ''service_report_v1'''
    USING (v_fmt);

  EXECUTE IMMEDIATE '
    INSERT INTO SERVICE_REPORTS (WRITER, REPEAT_NO, LEVEL, THEME, SUB_THEME, SUMMARY, QUOTES, INPUT_TOKENS, OUTPUT_TOKENS, RAW)
    SELECT ?, ?, ''overview'', NULL, NULL, R:structured_output[0]:raw_message:overview::STRING, NULL,
           R:usage:prompt_tokens, R:usage:completion_tokens, R
    FROM ' || v_tmp || '
    UNION ALL
    SELECT ?, ?, ''theme'', t.value:theme::STRING, NULL, t.value:summary::STRING, NULL, NULL, NULL, NULL
    FROM ' || v_tmp || ', LATERAL FLATTEN(R:structured_output[0]:raw_message:themes) t
    UNION ALL
    SELECT ?, ?, ''sub_theme'', t.value:theme::STRING, s.value:sub_theme::STRING, s.value:summary::STRING,
           s.value:quotes::ARRAY, NULL, NULL, NULL
    FROM ' || v_tmp || ', LATERAL FLATTEN(R:structured_output[0]:raw_message:themes) t, LATERAL FLATTEN(t.value:sub_themes) s'
    USING (P_WRITER, P_REPEAT, P_WRITER, P_REPEAT, P_WRITER, P_REPEAT);
  EXECUTE IMMEDIATE 'DROP TABLE IF EXISTS ' || v_tmp;

  RETURN (SELECT :P_WRITER || ' r' || :P_REPEAT || ': overview ' || IFF(COUNT_IF(LEVEL = 'overview' AND SUMMARY IS NOT NULL) = 1, 'ok', 'missing')
                 || ', ' || COUNT_IF(LEVEL = 'theme') || ' themes, ' || COUNT_IF(LEVEL = 'sub_theme') || ' sub-themes, '
                 || MAX(OUTPUT_TOKENS) || ' output tokens'
          FROM SERVICE_REPORTS WHERE WRITER = :P_WRITER AND REPEAT_NO = :P_REPEAT);
EXCEPTION
  WHEN OTHER THEN
    INSERT INTO SERVICE_REPORTS (WRITER, REPEAT_NO, LEVEL, ERROR) SELECT :P_WRITER, :P_REPEAT, 'error', :SQLERRM;
    RETURN P_WRITER || ' r' || P_REPEAT || ': failed: ' || SQLERRM;
END;
$$;
