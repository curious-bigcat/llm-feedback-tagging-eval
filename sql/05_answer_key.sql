-- 05_answer_key.sql : builds the answer key for the 404 scored comments from the 4 panel models' votes
-- (PLAN.md Step 3, doc Step 3). Plain SQL, no AI calls: the panel answers are already in RESULTS.
-- Rules, per comment:
--   tag chosen by 3-4 models with average confidence >= 0.7 -> accepted; by 2 models -> split; by 1 -> dropped
--   sentiment: each model's overall label; accepted when 3+ models agree
--   no splits + an accepted tag + an accepted sentiment -> 'panel_consensus' (final);
--   otherwise 'needs_review' plus a 'panel_split' item for the review app (-> 'human_reviewed')
-- Re-runnable until the first review decision; after that it refuses, so reviews are never overwritten.
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

-- ANSWER_KEY: one row per scored comment, the ground truth for correctness scoring. TAGS and SENTIMENT
-- are final (or the panel's proposal while needs_review); SOURCE says where they came from; PANEL_VOTES
-- keeps what each panel model said.
CREATE TABLE IF NOT EXISTS ANSWER_KEY (
  COMMENT_ID       STRING PRIMARY KEY,
  TAGS             ARRAY,
  SENTIMENT        STRING,
  SOURCE           STRING,
  PANEL_VOTES      VARIANT,
  TAXONOMY_VERSION STRING,
  CREATED_AT       TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
  REVIEWED_BY      STRING,
  REVIEWED_AT      TIMESTAMP_LTZ
);

-- Build: count the votes into a temp table, save the answer key, queue the splits for review.
-- In order: the panel's answers -> one vote per model per valid sub-theme -> vote counts and decision per
-- tag -> each model's overall sentiment -> sentiment majority -> everything gathered per comment -> final
-- source. Starts from all 404 sample comments, so a comment with no usable panel answer still goes to review.
EXECUTE IMMEDIATE $$
DECLARE
  already_reviewed EXCEPTION (-20002, 'ANSWER_KEY already has human_reviewed rows; not rebuilding.');
BEGIN
  IF ((SELECT COUNT(*) FROM ANSWER_KEY WHERE SOURCE = 'human_reviewed') > 0) THEN
    RAISE already_reviewed;
  END IF;

  DELETE FROM ANSWER_KEY;
  DELETE FROM REVIEW_QUEUE WHERE REASON = 'panel_split' AND STATUS = 'open';

  CREATE OR REPLACE TEMPORARY TABLE T_PANEL AS
  WITH panel AS (
    SELECT f.COMMENT_ID, f.MODEL, f.ANSWER
    FROM RESULTS f
    JOIN RUN_LOG l USING (RUN_ID)
    JOIN GV_MODEL_CONFIG g ON g.CONFIG_ID = l.CONFIG_ID
    WHERE g.ROLE = 'panel' AND l.COMMENT_SET = 'SAMPLE' AND l.REPEAT_NO = 1
  ),
  tags AS (
    SELECT p.COMMENT_ID, p.MODEL, t.value:theme::STRING AS THEME, t.value:sub_theme::STRING AS SUB_THEME,
           MAX(t.value:confidence_score::FLOAT) AS CONF
    FROM panel p, LATERAL FLATTEN(p.ANSWER:tags) t, GV_RULEBOOK r
    WHERE ARRAY_CONTAINS((t.value:theme::STRING || ' > ' || t.value:sub_theme::STRING)::VARIANT, r.ALLOWED_PAIRS)
    GROUP BY 1, 2, 3, 4
  ),
  votes AS (
    SELECT COMMENT_ID, THEME, SUB_THEME, COUNT(*) AS N_MODELS, AVG(CONF) AS AVG_CONF,
           ARRAY_AGG(MODEL) WITHIN GROUP (ORDER BY MODEL) AS MODELS,
           CASE WHEN COUNT(*) >= 3 AND AVG(CONF) >= 0.7 THEN 'accepted'
                WHEN COUNT(*) >= 2 THEN 'split'
                ELSE 'dropped' END AS STATUS
    FROM tags GROUP BY 1, 2, 3
  ),
  model_sentiment AS (
    SELECT p.COMMENT_ID, p.MODEL,
           CASE WHEN COUNT_IF(t.value:sentiment_label::STRING = 'Positive') > COUNT_IF(t.value:sentiment_label::STRING = 'Negative') THEN 'Positive'
                WHEN COUNT_IF(t.value:sentiment_label::STRING = 'Negative') > COUNT_IF(t.value:sentiment_label::STRING = 'Positive') THEN 'Negative'
                ELSE 'Neutral' END AS LABEL
    FROM panel p, LATERAL FLATTEN(p.ANSWER:tags) t
    GROUP BY 1, 2
  ),
  sentiment AS (
    SELECT COMMENT_ID,
           OBJECT_AGG(MODEL, LABEL::VARIANT) AS VOTES,
           MODE(LABEL) AS TOP_LABEL,
           MAX(n) AS TOP_N
    FROM (SELECT *, COUNT(*) OVER (PARTITION BY COMMENT_ID, LABEL) AS n FROM model_sentiment)
    GROUP BY 1
  ),
  per_comment AS (
    SELECT s.COMMENT_ID,
           ARRAY_AGG(IFF(v.STATUS = 'accepted', OBJECT_CONSTRUCT('theme', v.THEME, 'sub_theme', v.SUB_THEME), NULL)) AS ACCEPTED,
           ARRAY_AGG(IFF(v.STATUS = 'split', OBJECT_CONSTRUCT('theme', v.THEME, 'sub_theme', v.SUB_THEME,
                                                             'models', v.MODELS, 'avg_conf', ROUND(v.AVG_CONF, 2)), NULL)) AS SPLITS,
           ARRAY_AGG(OBJECT_CONSTRUCT('theme', v.THEME, 'sub_theme', v.SUB_THEME, 'n_models', v.N_MODELS,
                                      'models', v.MODELS, 'avg_conf', ROUND(v.AVG_CONF, 2), 'status', v.STATUS)) AS ALL_VOTES,
           ANY_VALUE(s.VOTES) AS SENT_VOTES,
           ANY_VALUE(IFF(s.TOP_N >= 3, s.TOP_LABEL, NULL)) AS SENTIMENT
    FROM sentiment s LEFT JOIN votes v USING (COMMENT_ID)
    GROUP BY 1
  )
  SELECT c.COMMENT_ID, COALESCE(p.ACCEPTED, ARRAY_CONSTRUCT()) AS ACCEPTED, COALESCE(p.SPLITS, ARRAY_CONSTRUCT()) AS SPLITS,
         p.ALL_VOTES, p.SENT_VOTES, p.SENTIMENT,
         IFF(ARRAY_SIZE(COALESCE(p.SPLITS, ARRAY_CONSTRUCT())) = 0
             AND ARRAY_SIZE(COALESCE(p.ACCEPTED, ARRAY_CONSTRUCT())) > 0
             AND p.SENTIMENT IS NOT NULL, 'panel_consensus', 'needs_review') AS SOURCE
  FROM COMMENTS c LEFT JOIN per_comment p USING (COMMENT_ID)
  WHERE c.IN_SAMPLE;

  INSERT INTO ANSWER_KEY (COMMENT_ID, TAGS, SENTIMENT, SOURCE, PANEL_VOTES, TAXONOMY_VERSION)
    SELECT COMMENT_ID, ACCEPTED, SENTIMENT, SOURCE,
           OBJECT_CONSTRUCT('tag_votes', ALL_VOTES, 'sentiment_votes', SENT_VOTES), 'nhs_v7'
    FROM T_PANEL;

  INSERT INTO REVIEW_QUEUE (REASON, COMMENT_ID, RUN_ID, DETAILS)
    SELECT 'panel_split', COMMENT_ID, 'PANEL_SAMPLE_r1',
           OBJECT_CONSTRUCT('accepted', ACCEPTED, 'splits', SPLITS, 'sentiment', SENTIMENT,
                            'sentiment_votes', SENT_VOTES, 'all_votes', ALL_VOTES)
    FROM T_PANEL WHERE SOURCE = 'needs_review';

  RETURN (SELECT OBJECT_AGG(SOURCE, n::VARIANT) FROM (SELECT SOURCE, COUNT(*) n FROM ANSWER_KEY GROUP BY 1));
END;
$$;
