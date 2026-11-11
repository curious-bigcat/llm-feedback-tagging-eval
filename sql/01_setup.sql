-- 01_setup.sql : workspace, access, data tables, settings table and locked prompts (PLAN.md Step 1).
-- Upload comments.csv, taxonomy.csv and prompts/*.txt to @VOC_EVAL.HARNESS.DATA_STAGE with PUT first.
-- Safe to re-run: tables are recreated from the uploaded files. Then run 02_checks.sql.

-- Role and access: VOC_EVAL_ROLE gets only what the doc and AI Observability need (Cortex AI functions,
-- running tasks, its own database, a warehouse). It owns the schema it creates, so it also holds
-- CREATE EXTERNAL AGENT and CREATE TASK there.
USE ROLE ACCOUNTADMIN;
CREATE ROLE IF NOT EXISTS VOC_EVAL_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE VOC_EVAL_ROLE;
GRANT USE AI FUNCTIONS ON ACCOUNT TO ROLE VOC_EVAL_ROLE;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE VOC_EVAL_ROLE;
GRANT CREATE DATABASE ON ACCOUNT TO ROLE VOC_EVAL_ROLE;
GRANT USAGE ON WAREHOUSE DEMO_WH TO ROLE VOC_EVAL_ROLE;
GRANT ROLE VOC_EVAL_ROLE TO ROLE ACCOUNTADMIN;
GRANT ROLE VOC_EVAL_ROLE TO USER IDENTIFIER($EVAL_USER);  -- SET EVAL_USER = '<your user>'; first

-- Workspace: database, schema, a CSV file format (header row, quoted values) and a stage for uploads.
USE ROLE VOC_EVAL_ROLE;
USE WAREHOUSE DEMO_WH;
CREATE DATABASE IF NOT EXISTS VOC_EVAL;
CREATE SCHEMA IF NOT EXISTS VOC_EVAL.HARNESS;
USE SCHEMA VOC_EVAL.HARNESS;

CREATE FILE FORMAT IF NOT EXISTS CSV_FMT
  TYPE = CSV SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"' ENCODING = 'UTF8';
CREATE STAGE IF NOT EXISTS DATA_STAGE FILE_FORMAT = CSV_FMT;

-- COMMENTS: the 6,211 raw patient comments, with no expert answers (they were deleted).
-- PILE = TEST (scoring only) or PRACTICE (trying things out), one pile per person; LEAKED_QUOTE = contains a
-- rulebook example, so kept in PRACTICE. Which TEST comments are scored is decided by us, in V1_SAMPLE.
-- Time Travel is off so the deleted expert columns can't be restored. The load aborts on any bad row.
CREATE OR REPLACE TABLE COMMENTS (
  COMMENT_ID          STRING PRIMARY KEY,
  RESPONDENT_ID       STRING,
  TRUST               STRING,
  SERVICE             STRING,
  SUB_SERVICE         STRING,
  DATE_RAW            STRING,
  QUESTION            STRING,
  COMMENT_TEXT        STRING,
  PATIENT_RATING      NUMBER,
  LEAKED_QUOTE        STRING,
  PILE                STRING
) DATA_RETENTION_TIME_IN_DAYS = 0;

COPY INTO COMMENTS FROM (
  SELECT $1, $2, $3, $4, NULLIF($5, ''), $6, $7, $8, TRY_TO_NUMBER($9), NULLIF($10, ''), $11
  FROM @DATA_STAGE/comments.csv
) ON_ERROR = ABORT_STATEMENT;

-- V1_SAMPLE: the TEST comments we score, picked by 07_sample.sql (at least 10 per sub-theme + 100 random),
-- with why each was picked. Empty until 07_sample.sql runs.
CREATE TABLE IF NOT EXISTS V1_SAMPLE (
  COMMENT_ID  STRING PRIMARY KEY,
  PICKED_FOR  STRING,
  PICKED_AT   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- TAXONOMY: the rulebook, 10 themes and 33 sub-themes with definitions and examples. Its text goes into
-- every prompt, its names are the only allowed answers, and it is used to validate and score answers.
CREATE OR REPLACE TABLE TAXONOMY (
  ORDINAL      NUMBER,
  THEME        STRING,
  SUB_THEME    STRING,
  DEFINITION   STRING,
  EXAMPLES     STRING,
  IN_PARAMS_PY BOOLEAN,
  PRIMARY KEY (THEME, SUB_THEME)
);

COPY INTO TAXONOMY FROM (
  SELECT $1::NUMBER, $2, $3, $4, $5, $6::BOOLEAN FROM @DATA_STAGE/taxonomy.csv
) ON_ERROR = ABORT_STATEMENT;

-- V1_MODEL_CONFIG: one row per setup (model + prompt + role). Switching models means updating a row.
-- Roles: champion = today's baseline; challenger = setups being tested; panel = models that build the
-- answer key; judge = the AI Observability judge; sorter = the cheap model that pre-tags all TEST comments
-- only to pick the sample (its tags are never an answer). Temperature 0 everywhere; APP_VERSION names the
-- setup in AI Observability.
CREATE OR REPLACE TABLE V1_MODEL_CONFIG (
  CONFIG_ID        STRING PRIMARY KEY,
  ROLE             STRING,
  MODEL            STRING,
  PROMPT_VERSION   STRING,
  TAXONOMY_VERSION STRING,
  TEMPERATURE      FLOAT,
  APP_VERSION      STRING
);

INSERT INTO V1_MODEL_CONFIG
SELECT id, role, model, prompt, 'nhs_v7', 0, IFF(prompt IS NULL, NULL, model || '__' || prompt)
FROM VALUES
  ('C01', 'champion',   'mistral-large3',        'current_v1'),
  ('C02', 'challenger', 'claude-opus-5',         'current_v1'),
  ('C03', 'challenger', 'openai-gpt-5.4',        'current_v1'),
  ('C04', 'challenger', 'gemini-3.1-pro',        'current_v1'),
  ('C05', 'challenger', 'mistral-large3',        'structured_v1'),
  ('C06', 'challenger', 'claude-opus-5',         'structured_v1'),
  ('C07', 'challenger', 'openai-gpt-5.4',        'structured_v1'),
  ('C08', 'challenger', 'gemini-3.1-pro',        'structured_v1'),
  ('P01', 'panel',      'claude-haiku-4-5',      'current_v1'),
  ('P02', 'panel',      'openai-gpt-5.4-mini',   'current_v1'),
  ('P03', 'panel',      'gemini-3.8-flash',      'current_v1'),
  ('P04', 'panel',      'mistral-large2',        'current_v1'),
  ('J01', 'judge',      'glm-5.3',               NULL)
  AS v(id, role, model, prompt);

-- PROMPTS: the two approved prompt files, each read whole as one value, named by file (current_v1, structured_v1)
-- and fingerprinted with SHA-256 so we can prove which text was used. Edits become a new version.
CREATE FILE FORMAT IF NOT EXISTS WHOLE_FILE_FMT TYPE = CSV FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE ESCAPE_UNENCLOSED_FIELD = NONE;
CREATE OR REPLACE TABLE PROMPTS AS
SELECT REPLACE(SPLIT_PART(METADATA$FILENAME, '/', -1), '.txt', '') AS PROMPT_VERSION,
       $1::STRING AS PROMPT_TEXT, SHA2($1, 256) AS SHA256, CURRENT_TIMESTAMP() AS LOCKED_AT
FROM @DATA_STAGE/prompts (FILE_FORMAT => 'WHOLE_FILE_FMT');
