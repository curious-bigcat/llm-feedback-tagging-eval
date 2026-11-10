-- answer_key.sql : builds ANSWER_KEY, the "correct" answer for every SAMPLE_COMMENTS row, from the 4 panel models'
-- answers (RUN_MODEL('P01'..'P04', 1)). Plain SQL, no AI calls. Rules, per comment:
--   tag given by 3-4 models with average confidence >= 0.7 -> accepted; by 2 models -> split; by 1 -> dropped
--   sentiment: each model's overall label (more Positive or Negative tags); accepted when 3+ models agree
--   impact (1-5): accepted when 3+ models gave one and all are within 1 point of each other; value = rounded median
--   no split + at least one accepted tag + accepted sentiment + accepted impact + fewer than 4 accepted tags -> 'panel'
--   (final); otherwise 'needs_review', and the comment goes to REVIEW_QUEUE for a person to decide (-> 'human').
--   The 4-tag guard catches over-tagging: most comments make 1-2 points, so 4+ agreed tags get a person's check.
-- Re-runnable until the first review decision; after that it refuses, so a person's decisions are never lost.
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

-- ANSWER_KEY: one row per sample comment. TAGS, SENTIMENT and IMPACT are final (or the panel's proposal while
-- needs_review); DECIDED_BY = panel | needs_review | human; PANEL_VOTES keeps what each panel model said.
CREATE TABLE IF NOT EXISTS ANSWER_KEY (
  COMMENT_ID  STRING PRIMARY KEY,
  TAGS        ARRAY,
  SENTIMENT   STRING,
  IMPACT      NUMBER,
  DECIDED_BY  STRING,
  PANEL_VOTES VARIANT,
  REVIEWED_BY STRING,
  REVIEWED_AT TIMESTAMP_LTZ
);

EXECUTE IMMEDIATE $$
DECLARE
  already_reviewed EXCEPTION (-20002, 'ANSWER_KEY already has reviewed rows; not rebuilding.');
BEGIN
  IF ((SELECT COUNT(*) FROM ANSWER_KEY WHERE DECIDED_BY = 'human') > 0) THEN
    RAISE already_reviewed;
  END IF;
  DELETE FROM ANSWER_KEY;
  DELETE FROM REVIEW_QUEUE WHERE REASON = 'panel_split' AND STATUS = 'open';

  -- In order: panel answers -> one vote per model per valid sub-theme -> vote counts per tag -> each model's
  -- overall sentiment -> sentiment majority -> impact agreement -> everything per comment.
  CREATE OR REPLACE TEMPORARY TABLE T_VOTES AS
  WITH panel AS (
    SELECT a.COMMENT_ID, a.MODEL, a.ANSWER
    FROM ANSWERS a JOIN MODELS m USING (MODEL_ID)
    WHERE m.ROLE = 'panel' AND a.REPEAT_NO = 1),
  tags AS (
    SELECT p.COMMENT_ID, p.MODEL, t.value:theme::STRING AS THEME, t.value:sub_theme::STRING AS SUB_THEME,
           MAX(t.value:confidence_score::FLOAT) AS CONF
    FROM panel p, LATERAL FLATTEN(p.ANSWER:tags) t, RULEBOOK r
    WHERE ARRAY_CONTAINS((t.value:theme::STRING || ' > ' || t.value:sub_theme::STRING)::VARIANT, r.ALLOWED_PAIRS)
    GROUP BY 1, 2, 3, 4),
  votes AS (
    SELECT COMMENT_ID, THEME, SUB_THEME, COUNT(*) AS N_MODELS, AVG(CONF) AS AVG_CONF,
           ARRAY_AGG(MODEL) WITHIN GROUP (ORDER BY MODEL) AS MODELS,
           CASE WHEN COUNT(*) >= 3 AND AVG(CONF) >= 0.7 THEN 'accepted'
                WHEN COUNT(*) >= 2 THEN 'split'
                ELSE 'dropped' END AS STATUS
    FROM tags GROUP BY 1, 2, 3),
  model_sentiment AS (
    SELECT p.COMMENT_ID, p.MODEL,
           CASE WHEN COUNT_IF(t.value:sentiment_label::STRING = 'Positive') > COUNT_IF(t.value:sentiment_label::STRING = 'Negative') THEN 'Positive'
                WHEN COUNT_IF(t.value:sentiment_label::STRING = 'Negative') > COUNT_IF(t.value:sentiment_label::STRING = 'Positive') THEN 'Negative'
                ELSE 'Neutral' END AS LABEL
    FROM panel p, LATERAL FLATTEN(p.ANSWER:tags) t
    GROUP BY 1, 2),
  sentiment AS (
    SELECT COMMENT_ID, OBJECT_AGG(MODEL, LABEL::VARIANT) AS VOTES, MODE(LABEL) AS TOP_LABEL, MAX(n) AS TOP_N
    FROM (SELECT *, COUNT(*) OVER (PARTITION BY COMMENT_ID, LABEL) AS n FROM model_sentiment)
    GROUP BY 1),
  impact AS (
    SELECT COMMENT_ID,
           OBJECT_AGG(MODEL, IMP::VARIANT) AS VOTES,
           IFF(COUNT(IMP) >= 3 AND MAX(IMP) - MIN(IMP) <= 1, ROUND(MEDIAN(IMP)), NULL) AS IMPACT,
           ROUND(MEDIAN(IMP)) AS PROPOSED
    FROM (SELECT COMMENT_ID, MODEL, TRY_TO_NUMBER(ANSWER:impact::STRING) AS IMP FROM panel)
    WHERE IMP BETWEEN 1 AND 5
    GROUP BY 1),
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
    GROUP BY 1)
  SELECT c.COMMENT_ID,
         COALESCE(p.ACCEPTED, ARRAY_CONSTRUCT()) AS ACCEPTED, COALESCE(p.SPLITS, ARRAY_CONSTRUCT()) AS SPLITS,
         p.ALL_VOTES, p.SENT_VOTES, p.SENTIMENT, i.VOTES AS IMPACT_VOTES, i.IMPACT, i.PROPOSED AS IMPACT_PROPOSED,
         IFF(ARRAY_SIZE(COALESCE(p.SPLITS, ARRAY_CONSTRUCT())) = 0
             AND ARRAY_SIZE(COALESCE(p.ACCEPTED, ARRAY_CONSTRUCT())) BETWEEN 1 AND 3
             AND p.SENTIMENT IS NOT NULL AND i.IMPACT IS NOT NULL, 'panel', 'needs_review') AS DECIDED_BY,
         ARRAY_SIZE(COALESCE(p.ACCEPTED, ARRAY_CONSTRUCT())) >= 4 AS TOO_MANY_TAGS
  FROM SAMPLE_COMMENTS c
  LEFT JOIN per_comment p USING (COMMENT_ID)
  LEFT JOIN impact i USING (COMMENT_ID);

  INSERT INTO ANSWER_KEY (COMMENT_ID, TAGS, SENTIMENT, IMPACT, DECIDED_BY, PANEL_VOTES)
    SELECT COMMENT_ID, ACCEPTED, SENTIMENT, IMPACT, DECIDED_BY,
           OBJECT_CONSTRUCT('tag_votes', ALL_VOTES, 'sentiment_votes', SENT_VOTES, 'impact_votes', IMPACT_VOTES)
    FROM T_VOTES;

  INSERT INTO REVIEW_QUEUE (REASON, COMMENT_ID, RUN_ID, DETAILS)
    SELECT 'panel_split', COMMENT_ID, 'PANEL_r1',
           OBJECT_CONSTRUCT('accepted', ACCEPTED, 'splits', SPLITS, 'sentiment', SENTIMENT,
                            'sentiment_votes', SENT_VOTES, 'all_votes', ALL_VOTES,
                            'impact', IMPACT, 'impact_proposed', IMPACT_PROPOSED, 'impact_votes', IMPACT_VOTES,
                            'too_many_tags', TOO_MANY_TAGS)
    FROM T_VOTES WHERE DECIDED_BY = 'needs_review';

  RETURN (SELECT OBJECT_AGG(DECIDED_BY, n::VARIANT) FROM (SELECT DECIDED_BY, COUNT(*) n FROM ANSWER_KEY GROUP BY 1));
END;
$$;
