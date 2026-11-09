-- 04_classify.sql : result tables, the SQL classify procedure RUN_CLASSIFY, and the warehouses and tasks that run
-- the panel and the grid in parallel. Every job (panel, trial, grid) classifies here; TruLens only replays the
-- saved answers for the judge (06_judge.sql). Safe to re-run.
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

-- RESULTS: one row per AI answer for every job. RUN_ID like 'P04_TRIAL_r1' (setup, comment set, repeat).
-- Holds the JSON answer, the CHECK_ANSWER problems (empty = passed), the attempt (2 = after the retry),
-- tokens for cost, and SOURCE = SQL or TRULENS.
CREATE TABLE IF NOT EXISTS RESULTS (
  RUN_ID            STRING,
  CONFIG_ID         STRING,
  MODEL             STRING,
  PROMPT_VERSION    STRING,
  COMMENT_SET       STRING,
  REPEAT_NO         NUMBER,
  COMMENT_ID        STRING,
  ATTEMPT           NUMBER,
  ANSWER            VARIANT,
  PROBLEMS          ARRAY,
  PROMPT_TOKENS     NUMBER,
  COMPLETION_TOKENS NUMBER,
  SOURCE            STRING,
  CREATED_AT        TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- RUN_LOG: one row per run with every fixed setting (model, prompt and its fingerprint, taxonomy version,
-- temperature) and the totals (answers, passed, retried, sent to review, tokens, start and end time).
CREATE TABLE IF NOT EXISTS RUN_LOG (
  RUN_ID            STRING,
  CONFIG_ID         STRING,
  MODEL             STRING,
  PROMPT_VERSION    STRING,
  PROMPT_SHA256     STRING,
  TAXONOMY_VERSION  STRING,
  TEMPERATURE       FLOAT,
  COMMENT_SET       STRING,
  REPEAT_NO         NUMBER,
  SOURCE            STRING,
  STARTED_AT        TIMESTAMP_LTZ,
  ENDED_AT          TIMESTAMP_LTZ,
  N_COMMENTS        NUMBER,
  N_PASSED          NUMBER,
  N_RETRIED         NUMBER,
  N_TO_REVIEW       NUMBER,
  PROMPT_TOKENS     NUMBER,
  COMPLETION_TOKENS NUMBER
);

-- REVIEW_QUEUE: the to-do list for a person, read and updated by the GV_REVIEW app.
-- REASON = failed_check_twice | panel_split | answer_key_may_be_wrong; STATUS open -> done, with the
-- decision, who made it and when.
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

-- RUN_CLASSIFY(setup, comment set, repeat): runs one setup over one comment set once, e.g.
-- CALL RUN_CLASSIFY('P04', 'TRIAL', 1). Several runs can go in parallel with ASYNC / AWAIT ALL.
--   1. reads the model, prompt and temperature from GV_MODEL_CONFIG; re-running a run replaces its rows
--   2. sends one AI_COMPLETE call per comment in a single statement (Snowflake runs them in parallel),
--      with the fixed answer format, and saves each answer with its CHECK_ANSWER result
--   3. retries the failed answers once (the retry replaces the first answer)
--   4. sends answers that still fail to REVIEW_QUEUE (not for panel models, whose disagreements are
--      reviewed as panel splits instead, nor for the sorter, whose tags only pick the sample)
--   5. logs the run in RUN_LOG
-- The model name must be a literal in AI_COMPLETE, so the call is built as text and run with EXECUTE
-- IMMEDIATE; the name only ever comes from GV_MODEL_CONFIG.
CREATE OR REPLACE PROCEDURE RUN_CLASSIFY(P_CONFIG_ID STRING, P_COMMENT_SET STRING, P_REPEAT NUMBER)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  v_run_id  STRING DEFAULT P_CONFIG_ID || '_' || P_COMMENT_SET || '_r' || P_REPEAT;
  v_tmp     STRING DEFAULT 'T_RETRY_' || REGEXP_REPLACE(P_CONFIG_ID || '_' || P_COMMENT_SET || '_' || P_REPEAT, '[^A-Za-z0-9_]', '');
  v_model   STRING;
  v_prompt  STRING;
  v_temp    FLOAT;
  v_role    STRING;
  v_started TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
  v_call    STRING;
  v_retried NUMBER;
  v_review  NUMBER;
  bad_input EXCEPTION (-20001, 'Unknown setup or comment set');
BEGIN
  SELECT MODEL, PROMPT_VERSION, TEMPERATURE, ROLE INTO :v_model, :v_prompt, :v_temp, :v_role
    FROM GV_MODEL_CONFIG WHERE CONFIG_ID = :P_CONFIG_ID AND PROMPT_VERSION IS NOT NULL;
  IF (v_model IS NULL OR P_COMMENT_SET NOT IN ('SAMPLE', 'TEST', 'TRIAL')) THEN
    RAISE bad_input;
  END IF;

  DELETE FROM RESULTS      WHERE RUN_ID = :v_run_id;
  DELETE FROM RUN_LOG      WHERE RUN_ID = :v_run_id;
  DELETE FROM REVIEW_QUEUE WHERE RUN_ID = :v_run_id AND STATUS = 'open';

  v_call := 'AI_COMPLETE(model => ''' || REPLACE(v_model, '''', '') || ''', prompt => q.PROMPT_FILLED,
               model_parameters => {''temperature'': ' || v_temp || ', ''max_tokens'': 4096},
               response_format => q.RESPONSE_FORMAT, show_details => TRUE)';

  -- Attempt 1: every comment in the set.
  EXECUTE IMMEDIATE '
    INSERT INTO RESULTS (RUN_ID, CONFIG_ID, MODEL, PROMPT_VERSION, COMMENT_SET, REPEAT_NO, COMMENT_ID, ATTEMPT,
                         ANSWER, PROBLEMS, PROMPT_TOKENS, COMPLETION_TOKENS, SOURCE)
    WITH a AS (
      SELECT q.COMMENT_ID, ' || v_call || ' AS R
      FROM GV_REQUESTS q WHERE q.COMMENT_SET = ? AND q.PROMPT_VERSION = ?)
    SELECT ?, ?, ?, ?, ?, ?, a.COMMENT_ID, 1, a.R:structured_output[0]:raw_message,
           CHECK_ANSWER(a.R:structured_output[0]:raw_message, c.COMMENT_TEXT, r.ALLOWED_PAIRS),
           a.R:usage:prompt_tokens, a.R:usage:completion_tokens, ''SQL''
    FROM a JOIN COMMENTS c USING (COMMENT_ID) CROSS JOIN GV_RULEBOOK r'
    USING (P_COMMENT_SET, v_prompt, v_run_id, P_CONFIG_ID, v_model, v_prompt, P_COMMENT_SET, P_REPEAT);

  -- Attempt 2: only the failed answers, via a temp table named per run so parallel runs don't collide.
  EXECUTE IMMEDIATE '
    CREATE OR REPLACE TEMPORARY TABLE ' || v_tmp || ' AS
    WITH a AS (
      SELECT q.COMMENT_ID, ' || v_call || ' AS R
      FROM GV_REQUESTS q
      JOIN RESULTS f ON f.COMMENT_ID = q.COMMENT_ID AND f.RUN_ID = ? AND ARRAY_SIZE(f.PROBLEMS) > 0
      WHERE q.COMMENT_SET = ? AND q.PROMPT_VERSION = ?)
    SELECT a.COMMENT_ID, a.R:structured_output[0]:raw_message AS ANSWER,
           CHECK_ANSWER(a.R:structured_output[0]:raw_message, c.COMMENT_TEXT, r.ALLOWED_PAIRS) AS PROBLEMS,
           a.R:usage:prompt_tokens AS PT, a.R:usage:completion_tokens AS CT
    FROM a JOIN COMMENTS c USING (COMMENT_ID) CROSS JOIN GV_RULEBOOK r'
    USING (v_run_id, P_COMMENT_SET, v_prompt);

  UPDATE RESULTS f SET ATTEMPT = 2, ANSWER = t.ANSWER, PROBLEMS = t.PROBLEMS,
         PROMPT_TOKENS = f.PROMPT_TOKENS + COALESCE(t.PT, 0), COMPLETION_TOKENS = f.COMPLETION_TOKENS + COALESCE(t.CT, 0)
    FROM IDENTIFIER(:v_tmp) t WHERE f.RUN_ID = :v_run_id AND f.COMMENT_ID = t.COMMENT_ID;
  v_retried := (SELECT COUNT(*) FROM IDENTIFIER(:v_tmp));
  EXECUTE IMMEDIATE 'DROP TABLE IF EXISTS ' || v_tmp;

  -- Still failing after the retry: send to the review screen (not for panel or sorter models).
  INSERT INTO REVIEW_QUEUE (REASON, COMMENT_ID, RUN_ID, DETAILS)
    SELECT 'failed_check_twice', COMMENT_ID, RUN_ID, OBJECT_CONSTRUCT('answer', ANSWER, 'problems', PROBLEMS)
    FROM RESULTS WHERE RUN_ID = :v_run_id AND ARRAY_SIZE(PROBLEMS) > 0 AND :v_role NOT IN ('panel', 'sorter');
  v_review := SQLROWCOUNT;

  INSERT INTO RUN_LOG
    SELECT :v_run_id, :P_CONFIG_ID, :v_model, :v_prompt, p.SHA256, r.TAXONOMY_VERSION, :v_temp, :P_COMMENT_SET, :P_REPEAT,
           'SQL', :v_started, CURRENT_TIMESTAMP(), COUNT(*), COUNT_IF(ARRAY_SIZE(f.PROBLEMS) = 0), :v_retried, :v_review,
           SUM(f.PROMPT_TOKENS), SUM(f.COMPLETION_TOKENS)
    FROM RESULTS f CROSS JOIN PROMPTS p CROSS JOIN GV_RULEBOOK r
    WHERE f.RUN_ID = :v_run_id AND p.PROMPT_VERSION = :v_prompt
    GROUP BY p.SHA256, r.TAXONOMY_VERSION;

  RETURN (SELECT OBJECT_CONSTRUCT(*) FROM RUN_LOG WHERE RUN_ID = :v_run_id);
END;
$$;

-- One warehouse per setup (created by ACCOUNTADMIN; usage granted to VOC_EVAL_ROLE), so no run waits for another.
-- X-Small is enough because the calls mostly wait on the model; up to 3 clusters so the 3 repeats each get one.
-- VOC_GV_PANEL runs the 4 panel models.
-- CREATE WAREHOUSE VOC_GV_C01 WAREHOUSE_SIZE = 'XSMALL' MIN_CLUSTER_COUNT = 1 MAX_CLUSTER_COUNT = 3
--   AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE;   (likewise C02..C08 and PANEL)
-- GRANT USAGE, OPERATE, MONITOR ON WAREHOUSE VOC_GV_C01 TO ROLE VOC_EVAL_ROLE;

-- Grid tasks: one per setup, on its own warehouse, running its 3 repeats at the same time (ASYNC / AWAIT ALL).
EXECUTE IMMEDIATE $$
DECLARE
  c CURSOR FOR SELECT CONFIG_ID FROM GV_MODEL_CONFIG WHERE ROLE IN ('champion', 'challenger') ORDER BY 1;
BEGIN
  FOR r IN c DO
    EXECUTE IMMEDIATE 'CREATE OR REPLACE TASK GV_CLASSIFY_' || r.CONFIG_ID || ' WAREHOUSE = VOC_GV_' || r.CONFIG_ID ||
      ' USER_TASK_TIMEOUT_MS = 14400000 AS BEGIN ' ||
      'ASYNC (CALL RUN_CLASSIFY(''' || r.CONFIG_ID || ''', ''SAMPLE'', 1)); ' ||
      'ASYNC (CALL RUN_CLASSIFY(''' || r.CONFIG_ID || ''', ''SAMPLE'', 2)); ' ||
      'ASYNC (CALL RUN_CLASSIFY(''' || r.CONFIG_ID || ''', ''SAMPLE'', 3)); ' ||
      'AWAIT ALL; END';
  END FOR;
  RETURN 'grid tasks created';
END;
$$;

-- Start the grid: EXECUTE TASK GV_CLASSIFY_C01; ... EXECUTE TASK GV_CLASSIFY_C08;
