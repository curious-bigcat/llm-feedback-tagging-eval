-- 03_shared.sql : building blocks shared by every AI call. Both the SQL procedure (panel, trial) and the
-- TruLens app (grid) read these, so all callers send the same prompt and answer format and are checked by
-- the same rules. Safe to re-run.
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

-- GV_RULEBOOK (1 row), built from TAXONOMY:
--   TAXONOMY_TEXT   all 33 sub-themes with definitions and examples, pasted into every prompt
--   ALLOWED_PAIRS   the 33 valid "Theme > Sub-theme" strings, used to reject a sub-theme under the wrong theme
--   RESPONSE_FORMAT the fixed answer format (JSON schema) for AI_COMPLETE: the model must return {"tags": [...]}
--                   with all 6 fields, and can only use the real theme / sub-theme names and
--                   Positive / Neutral / Negative. What it can't enforce is checked by CHECK_ANSWER.
CREATE OR REPLACE VIEW GV_RULEBOOK AS
SELECT
  'nhs_v7' AS TAXONOMY_VERSION,
  LISTAGG('- ' || THEME || ' > ' || SUB_THEME || ': ' || DEFINITION
          || IFF(EXAMPLES <> '', ' Examples: ' || EXAMPLES, ''), '\n') WITHIN GROUP (ORDER BY ORDINAL) AS TAXONOMY_TEXT,
  ARRAY_AGG(THEME || ' > ' || SUB_THEME) WITHIN GROUP (ORDER BY ORDINAL) AS ALLOWED_PAIRS,
  OBJECT_CONSTRUCT(
    'type', 'json',
    'schema', OBJECT_CONSTRUCT(
      'type', 'object', 'additionalProperties', FALSE, 'required', ARRAY_CONSTRUCT('tags'),
      'properties', OBJECT_CONSTRUCT('tags', OBJECT_CONSTRUCT(
        'type', 'array',
        'items', OBJECT_CONSTRUCT(
          'type', 'object', 'additionalProperties', FALSE,
          'required', ARRAY_CONSTRUCT('theme', 'sub_theme', 'sentiment_label', 'sentiment_score', 'confidence_score', 'evidence'),
          'properties', OBJECT_CONSTRUCT(
            'theme',            OBJECT_CONSTRUCT('type', 'string', 'enum', ARRAY_AGG(DISTINCT THEME)),
            'sub_theme',        OBJECT_CONSTRUCT('type', 'string', 'enum', ARRAY_AGG(SUB_THEME) WITHIN GROUP (ORDER BY ORDINAL)),
            'sentiment_label',  OBJECT_CONSTRUCT('type', 'string', 'enum', ARRAY_CONSTRUCT('Positive', 'Neutral', 'Negative')),
            'sentiment_score',  OBJECT_CONSTRUCT('type', 'number'),
            'confidence_score', OBJECT_CONSTRUCT('type', 'number'),
            'evidence',         OBJECT_CONSTRUCT('type', 'string'))))))
  ) AS RESPONSE_FORMAT
FROM TAXONOMY;

-- GV_COMMENT_SETS: which comment ids each job uses. SAMPLE = the scored TEST comments in GV_SAMPLE; TEST = every
-- TEST comment (only the sorter uses it, to pick the sample); TRIAL = 20 PRACTICE comments picked by a fixed
-- SHA2 shuffle, so the same 20 every time.
CREATE OR REPLACE VIEW GV_COMMENT_SETS AS
SELECT 'SAMPLE' AS COMMENT_SET, COMMENT_ID FROM GV_SAMPLE
UNION ALL
SELECT 'TEST', COMMENT_ID FROM COMMENTS WHERE PILE = 'TEST'
UNION ALL
SELECT 'TRIAL', COMMENT_ID FROM COMMENTS WHERE PILE = 'PRACTICE'
QUALIFY ROW_NUMBER() OVER (ORDER BY SHA2('nhs_eval_v1|trial|' || COMMENT_ID)) <= 20;

-- GV_REQUESTS: the exact request sent to a model, one row per comment x prompt version.
-- Fills the prompt's {TAXONOMY}, {QUESTION} and {COMMENT} slots and carries the answer format and the
-- prompt fingerprint. The model never sees an answer key.
CREATE OR REPLACE VIEW GV_REQUESTS AS
SELECT s.COMMENT_SET, c.COMMENT_ID, p.PROMPT_VERSION, p.SHA256 AS PROMPT_SHA256, r.TAXONOMY_VERSION,
       REPLACE(REPLACE(REPLACE(p.PROMPT_TEXT, '{TAXONOMY}', r.TAXONOMY_TEXT),
               '{QUESTION}', c.QUESTION), '{COMMENT}', c.COMMENT_TEXT) AS PROMPT_FILLED,
       r.RESPONSE_FORMAT
FROM GV_COMMENT_SETS s
JOIN COMMENTS c USING (COMMENT_ID)
CROSS JOIN PROMPTS p
CROSS JOIN GV_RULEBOOK r;

-- NORM_QUOTE: prepares text for the quote check so punctuation style doesn't count, but words must match.
-- Lower case, curly quotes to straight, no space before punctuation, single spaces, and no quote marks
-- wrapped around the whole text. A corrected spelling or paraphrase still fails.
CREATE OR REPLACE FUNCTION NORM_QUOTE(S STRING)
RETURNS STRING
AS
$$
  TRIM(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(
    TRANSLATE(LOWER(COALESCE(S, '')), '‘’‚‛“”„‟`´', '''''''''""""'''''),
    '\\s+([.,;:!?)])', '\\1'), '\\s+', ' '), '^[\\s"'']+|[\\s"'']+$', ''))
$$;

-- CHECK_ANSWER: the automatic check on one answer (doc Step 4). Plain SQL, no AI. It checks the answer is
-- valid, not correct. Returns a list of problems; an empty list means pass. The 6 checks:
--   no tags returned | pair not in taxonomy | quote not in comment | score does not match label
--   (Positive > 0, Negative < 0, Neutral = 0, within -1..1) | confidence outside 0-1 | sub-theme repeated
CREATE OR REPLACE FUNCTION CHECK_ANSWER(ANSWER VARIANT, COMMENT_TEXT STRING, ALLOWED_PAIRS ARRAY)
RETURNS ARRAY
AS
$$
  ARRAY_CAT(ARRAY_CAT(ARRAY_CAT(ARRAY_CAT(ARRAY_CAT(
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
        ARRAY_CONSTRUCT('sub-theme repeated'), ARRAY_CONSTRUCT()))
$$;
