-- setup.sql : everything the models need to classify SAMPLE_COMMENTS (built by sample.sql). Safe to re-run.
-- Upload prompts/*.txt to @DATA_STAGE/prompts/ first.
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

-- PROMPTS: the prompt files, each read whole (current_v1, structured_v1, current_v2, structured_v2), with a SHA-256 fingerprint so
-- we can prove which text was used. Each has {TAXONOMY}, {QUESTION} and {COMMENT} slots. The v2 prompts add the
-- impact rating (1-5) and are the ones used now; v1 is kept as the record of the first evaluation.
CREATE FILE FORMAT IF NOT EXISTS WHOLE_FILE_FMT TYPE = CSV FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE ESCAPE_UNENCLOSED_FIELD = NONE;
CREATE OR REPLACE TABLE PROMPTS AS
SELECT REPLACE(SPLIT_PART(METADATA$FILENAME, '/', -1), '.txt', '') AS PROMPT,
       $1::STRING AS PROMPT_TEXT, SHA2($1, 256) AS SHA256
FROM @DATA_STAGE/prompts (FILE_FORMAT => 'WHOLE_FILE_FMT');

-- MODELS: one row per model setup. ROLE: champion = today's setup; challenger = being tested; panel = builds the
-- answer key; judge = scores the answers. Temperature 0 everywhere.
CREATE OR REPLACE TABLE MODELS (MODEL_ID STRING PRIMARY KEY, ROLE STRING, MODEL STRING, PROMPT STRING);
INSERT INTO MODELS VALUES
  ('C01', 'champion',   'mistral-large3',      'current_v2'),
  ('C02', 'challenger', 'claude-opus-5',       'current_v2'),
  ('C03', 'challenger', 'openai-gpt-5.4',      'current_v2'),
  ('C04', 'challenger', 'gemini-3.1-pro',      'current_v2'),
  ('C05', 'challenger', 'mistral-large3',      'structured_v2'),
  ('C06', 'challenger', 'claude-opus-5',       'structured_v2'),
  ('C07', 'challenger', 'openai-gpt-5.4',      'structured_v2'),
  ('C08', 'challenger', 'gemini-3.1-pro',      'structured_v2'),
  ('C09', 'challenger', 'gemini-3.1-pro',      'structured_v3'),  -- v3 = v2 + rule against over-tagging
  ('C10', 'challenger', 'mistral-large3',      'structured_v3'),
  ('C11', 'challenger', 'openai-gpt-5.4',      'structured_v3'),
  ('C12', 'challenger', 'claude-opus-5',       'structured_v3'),
  ('P01', 'panel',      'claude-haiku-4-5',    'current_v2'),
  ('P02', 'panel',      'openai-gpt-5.4-mini', 'current_v2'),
  ('P03', 'panel',      'gemini-3.8-flash',    'current_v2'),
  ('P04', 'panel',      'mistral-large2',      'current_v2'),
  ('J01', 'judge',      'claude-sonnet-4-6',   NULL);

-- RULEBOOK (1 row): the taxonomy text pasted into every prompt, the 33 valid "Theme > Sub-theme" pairs, and the
-- fixed answer format:
--   {"tags": [{theme, sub_theme, sentiment_label, sentiment_score, confidence_score, evidence}], "impact": 1-5}
CREATE OR REPLACE VIEW RULEBOOK AS
SELECT
  LISTAGG('- ' || THEME || ' > ' || SUB_THEME || ': ' || DEFINITION
          || IFF(EXAMPLES <> '', ' Examples: ' || EXAMPLES, ''), '\n') WITHIN GROUP (ORDER BY ORDINAL) AS TAXONOMY_TEXT,
  ARRAY_AGG(THEME || ' > ' || SUB_THEME) WITHIN GROUP (ORDER BY ORDINAL) AS ALLOWED_PAIRS,
  OBJECT_CONSTRUCT('type', 'json', 'schema', OBJECT_CONSTRUCT(
    'type', 'object', 'additionalProperties', FALSE, 'required', ARRAY_CONSTRUCT('tags', 'impact'),
    'properties', OBJECT_CONSTRUCT(
      'tags', OBJECT_CONSTRUCT('type', 'array', 'items', OBJECT_CONSTRUCT(
        'type', 'object', 'additionalProperties', FALSE,
        'required', ARRAY_CONSTRUCT('theme', 'sub_theme', 'sentiment_label', 'sentiment_score', 'confidence_score', 'evidence'),
        'properties', OBJECT_CONSTRUCT(
          'theme',            OBJECT_CONSTRUCT('type', 'string', 'enum', ARRAY_AGG(DISTINCT THEME)),
          'sub_theme',        OBJECT_CONSTRUCT('type', 'string', 'enum', ARRAY_AGG(SUB_THEME) WITHIN GROUP (ORDER BY ORDINAL)),
          'sentiment_label',  OBJECT_CONSTRUCT('type', 'string', 'enum', ARRAY_CONSTRUCT('Positive', 'Neutral', 'Negative')),
          'sentiment_score',  OBJECT_CONSTRUCT('type', 'number'),
          'confidence_score', OBJECT_CONSTRUCT('type', 'number'),
          'evidence',         OBJECT_CONSTRUCT('type', 'string')))),
      -- plain integer: Gemini rejects enum/minimum/maximum on numbers; CHECK_ANSWER enforces 1-5 instead
      'impact', OBJECT_CONSTRUCT('type', 'integer')))) AS RESPONSE_FORMAT
FROM TAXONOMY;

-- CHECK_ANSWER: the automatic check on one answer (valid, not necessarily correct). Returns a list of problems;
-- empty = pass. Checks: no tags | pair not in taxonomy | quote not in comment | score does not match label
-- (Positive > 0, Negative < 0, Neutral = 0, within -1..1) | confidence outside 0-1 | sub-theme repeated |
-- impact missing or not a whole number 1-5.
CREATE OR REPLACE FUNCTION CHECK_ANSWER(ANSWER VARIANT, COMMENT_TEXT STRING, ALLOWED_PAIRS ARRAY)
RETURNS ARRAY
AS
$$
  ARRAY_CAT(ARRAY_CAT(ARRAY_CAT(ARRAY_CAT(ARRAY_CAT(ARRAY_CAT(
    IFF(ANSWER IS NULL OR NOT IS_ARRAY(ANSWER:tags) OR ARRAY_SIZE(ANSWER:tags) = 0,
        ARRAY_CONSTRUCT('no tags returned'), ARRAY_CONSTRUCT()),
    TRANSFORM(FILTER(COALESCE(ANSWER:tags::ARRAY, ARRAY_CONSTRUCT()),
                     t -> NOT ARRAY_CONTAINS((t:theme::STRING || ' > ' || t:sub_theme::STRING)::VARIANT, ALLOWED_PAIRS)),
              t -> 'pair not in taxonomy: ' || t:theme::STRING || ' > ' || t:sub_theme::STRING)),
    TRANSFORM(FILTER(COALESCE(ANSWER:tags::ARRAY, ARRAY_CONSTRUCT()),
                     t -> NORM_QUOTE(t:evidence::STRING) = ''
                          OR NOT CONTAINS(NORM_QUOTE(COMMENT_TEXT), NORM_QUOTE(t:evidence::STRING))),
              t -> 'quote not in comment: ' || t:sub_theme::STRING)),
    TRANSFORM(FILTER(COALESCE(ANSWER:tags::ARRAY, ARRAY_CONSTRUCT()),
                     t -> NOT ((t:sentiment_label::STRING = 'Positive' AND t:sentiment_score::FLOAT > 0)
                            OR (t:sentiment_label::STRING = 'Negative' AND t:sentiment_score::FLOAT < 0)
                            OR (t:sentiment_label::STRING = 'Neutral'  AND t:sentiment_score::FLOAT = 0))
                          OR NOT (t:sentiment_score::FLOAT BETWEEN -1 AND 1)),
              t -> 'score does not match label: ' || t:sub_theme::STRING)),
    TRANSFORM(FILTER(COALESCE(ANSWER:tags::ARRAY, ARRAY_CONSTRUCT()),
                     t -> NOT (t:confidence_score::FLOAT BETWEEN 0 AND 1)),
              t -> 'confidence outside 0-1: ' || t:sub_theme::STRING)),
    IFF(ARRAY_SIZE(ARRAY_DISTINCT(TRANSFORM(COALESCE(ANSWER:tags::ARRAY, ARRAY_CONSTRUCT()), t -> t:sub_theme)))
          < ARRAY_SIZE(COALESCE(ANSWER:tags::ARRAY, ARRAY_CONSTRUCT())),
        ARRAY_CONSTRUCT('sub-theme repeated'), ARRAY_CONSTRUCT())),
    IFF(TRY_TO_NUMBER(ANSWER:impact::STRING) IN (1, 2, 3, 4, 5), ARRAY_CONSTRUCT(),
        ARRAY_CONSTRUCT('impact missing or not 1-5')))
$$;

-- ANSWERS: one row per model answer. RUN_ID = model id + repeat, e.g. 'C04_r2'. PROBLEMS empty = passed the checks;
-- ATTEMPT 2 = the answer after one retry.
CREATE TABLE IF NOT EXISTS ANSWERS (
  RUN_ID        STRING,
  MODEL_ID      STRING,
  MODEL         STRING,
  PROMPT        STRING,
  REPEAT_NO     NUMBER,
  COMMENT_ID    STRING,
  ATTEMPT       NUMBER,
  ANSWER        VARIANT,
  PROBLEMS      ARRAY,
  INPUT_TOKENS  NUMBER,
  OUTPUT_TOKENS NUMBER,
  CREATED_AT    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- REVIEW_QUEUE: comments for a person to decide in the ANSWER_REVIEW app. REASON = panel_split (the panel disagreed)
-- or failed_check (a tested model's answer failed the checks twice). STATUS open -> done.
CREATE TABLE IF NOT EXISTS REVIEW_QUEUE (
  ITEM_ID     NUMBER AUTOINCREMENT,
  REASON      STRING,
  COMMENT_ID  STRING,
  RUN_ID      STRING,
  DETAILS     VARIANT,
  STATUS      STRING DEFAULT 'open',
  DECISION    VARIANT,
  REVIEWED_BY STRING,
  REVIEWED_AT TIMESTAMP_LTZ,
  CREATED_AT  TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- RUN_MODEL(model id, repeat [, source]): runs one model over every comment in the source table, e.g.
-- CALL RUN_MODEL('P01', 1). Source is SAMPLE_COMMENTS (default; run id 'P01_r1'), FRESH_COMMENTS (step 10a, built
-- by fresh.sql; run id 'C09_fresh_r1') or REPORT_COMMENTS (aggregation step A1, built by report.sql; 'C09_report_r1').
--   1. one AI_COMPLETE call per comment in a single statement (Snowflake runs them in parallel), with the model's
--      prompt filled in and the fixed answer format; each answer is saved with its CHECK_ANSWER result
--   2. failed answers are asked once more; the retry replaces the first answer
--   3. tested models' answers that still fail go to REVIEW_QUEUE (panel disagreements are reviewed instead)
-- Re-running a run replaces its rows. The model name must be a literal in AI_COMPLETE, so the call is built as
-- text; the name only ever comes from MODELS, and the source must be one of the three tables above.
DROP PROCEDURE IF EXISTS RUN_MODEL(STRING, NUMBER);
CREATE OR REPLACE PROCEDURE RUN_MODEL(P_MODEL_ID STRING, P_REPEAT NUMBER, P_SOURCE STRING DEFAULT 'SAMPLE_COMMENTS')
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  v_run_id STRING DEFAULT P_MODEL_ID || DECODE(P_SOURCE, 'FRESH_COMMENTS', '_fresh', 'REPORT_COMMENTS', '_report', '')
                          || '_r' || P_REPEAT;
  v_tmp    STRING DEFAULT 'T_RETRY_' || REGEXP_REPLACE(P_MODEL_ID
                          || DECODE(P_SOURCE, 'FRESH_COMMENTS', '_fresh', 'REPORT_COMMENTS', '_report', '')
                          || '_' || P_REPEAT, '[^A-Za-z0-9_]', '');
  v_model  STRING;
  v_prompt STRING;
  v_role   STRING;
  v_call   STRING;
  bad_input  EXCEPTION (-20001, 'Unknown model id, or a model with no prompt');
  bad_source EXCEPTION (-20002, 'Source must be SAMPLE_COMMENTS, FRESH_COMMENTS or REPORT_COMMENTS');
BEGIN
  IF (P_SOURCE NOT IN ('SAMPLE_COMMENTS', 'FRESH_COMMENTS', 'REPORT_COMMENTS')) THEN
    RAISE bad_source;
  END IF;
  SELECT MODEL, PROMPT, ROLE INTO :v_model, :v_prompt, :v_role FROM MODELS WHERE MODEL_ID = :P_MODEL_ID;
  IF (v_model IS NULL OR v_prompt IS NULL) THEN
    RAISE bad_input;
  END IF;

  DELETE FROM ANSWERS      WHERE RUN_ID = :v_run_id;
  DELETE FROM REVIEW_QUEUE WHERE RUN_ID = :v_run_id AND STATUS = 'open';

  v_call := 'AI_COMPLETE(model => ''' || REPLACE(v_model, '''', '') || ''',
               prompt => REPLACE(REPLACE(REPLACE(p.PROMPT_TEXT, ''{TAXONOMY}'', r.TAXONOMY_TEXT),
                                 ''{QUESTION}'', c.QUESTION), ''{COMMENT}'', c.COMMENT_TEXT),
               model_parameters => {''temperature'': 0, ''max_tokens'': 4096},
               response_format => r.RESPONSE_FORMAT, show_details => TRUE)';

  -- Attempt 1: every comment in the source.
  EXECUTE IMMEDIATE '
    INSERT INTO ANSWERS (RUN_ID, MODEL_ID, MODEL, PROMPT, REPEAT_NO, COMMENT_ID, ATTEMPT, ANSWER, PROBLEMS,
                         INPUT_TOKENS, OUTPUT_TOKENS)
    WITH a AS (
      SELECT c.COMMENT_ID, c.COMMENT_TEXT, r.ALLOWED_PAIRS, ' || v_call || ' AS R
      FROM ' || P_SOURCE || ' c CROSS JOIN RULEBOOK r JOIN PROMPTS p ON p.PROMPT = ?)
    SELECT ?, ?, ?, ?, ?, COMMENT_ID, 1, R:structured_output[0]:raw_message,
           CHECK_ANSWER(R:structured_output[0]:raw_message, COMMENT_TEXT, ALLOWED_PAIRS),
           R:usage:prompt_tokens, R:usage:completion_tokens
    FROM a'
    USING (v_prompt, v_run_id, P_MODEL_ID, v_model, v_prompt, P_REPEAT);

  -- Attempt 2: only the failed answers, via a temp table named per run so parallel runs don't collide.
  EXECUTE IMMEDIATE '
    CREATE OR REPLACE TEMPORARY TABLE ' || v_tmp || ' AS
    WITH a AS (
      SELECT c.COMMENT_ID, c.COMMENT_TEXT, r.ALLOWED_PAIRS, ' || v_call || ' AS R
      FROM ' || P_SOURCE || ' c CROSS JOIN RULEBOOK r JOIN PROMPTS p ON p.PROMPT = ?
      JOIN ANSWERS f ON f.COMMENT_ID = c.COMMENT_ID AND f.RUN_ID = ? AND ARRAY_SIZE(f.PROBLEMS) > 0)
    SELECT COMMENT_ID, R:structured_output[0]:raw_message AS ANSWER,
           CHECK_ANSWER(R:structured_output[0]:raw_message, COMMENT_TEXT, ALLOWED_PAIRS) AS PROBLEMS,
           R:usage:prompt_tokens AS IT, R:usage:completion_tokens AS OT
    FROM a'
    USING (v_prompt, v_run_id);

  UPDATE ANSWERS f SET ATTEMPT = 2, ANSWER = t.ANSWER, PROBLEMS = t.PROBLEMS,
         INPUT_TOKENS = f.INPUT_TOKENS + COALESCE(t.IT, 0), OUTPUT_TOKENS = f.OUTPUT_TOKENS + COALESCE(t.OT, 0)
    FROM IDENTIFIER(:v_tmp) t WHERE f.RUN_ID = :v_run_id AND f.COMMENT_ID = t.COMMENT_ID;
  EXECUTE IMMEDIATE 'DROP TABLE IF EXISTS ' || v_tmp;

  -- Still failing after the retry: to the review screen (not for panel models).
  INSERT INTO REVIEW_QUEUE (REASON, COMMENT_ID, RUN_ID, DETAILS)
    SELECT 'failed_check', COMMENT_ID, RUN_ID, OBJECT_CONSTRUCT('answer', ANSWER, 'problems', PROBLEMS)
    FROM ANSWERS WHERE RUN_ID = :v_run_id AND ARRAY_SIZE(PROBLEMS) > 0 AND :v_role <> 'panel';

  RETURN (SELECT :v_run_id || ': ' || COUNT(*) || ' answers, ' || COUNT_IF(ARRAY_SIZE(PROBLEMS) = 0) || ' passed, '
                 || COUNT_IF(ATTEMPT = 2) || ' retried'
          FROM ANSWERS WHERE RUN_ID = :v_run_id);
END;
$$;
