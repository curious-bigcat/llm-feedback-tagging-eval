-- tag_scores.sql : plain-SQL checks on tagging (no AI, free, repeatable). Run any time after RUN_MODEL runs.
--   TAG_PROFILE : per run, how many tags each comment gets and which sub-themes are used most. Needs no answer key,
--                 so it is used on the panel before voting, to spot a model that over-tags.
--   TAG_SCORES  : per run, precision, recall and F1 of its sub-themes against ANSWER_KEY, plus over-tagging measures.
--   TAG_SCORES_BY_SUBTHEME : the same per sub-theme, to see which sub-themes are over-used or missed.
--   TAG_CONSISTENCY : per setup and comment set, the share of comments given the same sub-themes in every repeat.
-- Only valid taxonomy pairs count; a sub-theme given twice in one answer counts once. Fresh-comment runs (step 10a,
-- e.g. 'C09_fresh_r1') have no answer key, so TAG_SCORES and TAG_SCORES_BY_SUBTHEME keep only sample runs
-- (run ids like 'C09_r1').
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

-- RUN_TAGS: one row per run x comment x valid sub-theme (answers with no valid tag have no rows).
CREATE OR REPLACE VIEW RUN_TAGS AS
SELECT DISTINCT a.RUN_ID, a.MODEL_ID, a.COMMENT_ID, t.value:sub_theme::STRING AS SUB_THEME
FROM ANSWERS a, LATERAL FLATTEN(a.ANSWER:tags) t, RULEBOOK r
WHERE ARRAY_CONTAINS((t.value:theme::STRING || ' > ' || t.value:sub_theme::STRING)::VARIANT, r.ALLOWED_PAIRS);

-- TAG_PROFILE: tags per comment (average and spread) and the 3 most-used sub-themes, per run.
CREATE OR REPLACE VIEW TAG_PROFILE AS
WITH per_comment AS (
  SELECT a.RUN_ID, a.MODEL_ID, a.COMMENT_ID, COUNT(t.SUB_THEME) AS N_TAGS
  FROM ANSWERS a LEFT JOIN RUN_TAGS t USING (RUN_ID, COMMENT_ID)
  GROUP BY 1, 2, 3),
top_sub AS (
  SELECT RUN_ID, LISTAGG(SUB_THEME || ' ' || N, ', ') WITHIN GROUP (ORDER BY N DESC, SUB_THEME) AS TOP_3
  FROM (SELECT RUN_ID, SUB_THEME, COUNT(*) AS N FROM RUN_TAGS GROUP BY 1, 2
        QUALIFY ROW_NUMBER() OVER (PARTITION BY RUN_ID ORDER BY COUNT(*) DESC, SUB_THEME) <= 3)
  GROUP BY 1)
SELECT p.RUN_ID, ANY_VALUE(p.MODEL_ID) AS MODEL_ID, COUNT(*) AS COMMENTS,
       ROUND(AVG(p.N_TAGS), 2) AS TAGS_PER_COMMENT,
       ROUND(100 * COUNT_IF(p.N_TAGS = 1) / COUNT(*), 1) AS PCT_1_TAG,
       ROUND(100 * COUNT_IF(p.N_TAGS >= 4) / COUNT(*), 1) AS PCT_4PLUS_TAGS,
       MAX(p.N_TAGS) AS MAX_TAGS,
       ANY_VALUE(t.TOP_3) AS TOP_3_SUB_THEMES
FROM per_comment p LEFT JOIN top_sub t USING (RUN_ID)
GROUP BY p.RUN_ID;

-- TAG_SCORES: precision, recall, F1 per run against the answer key (comments still needs_review are left out).
--   precision = correct tags / tags given   (low = over-tagging: wrong extra tags)
--   recall    = correct tags / key tags     (low = under-tagging: missed tags)
--   F1        = 2PR / (P + R)               (one number for both)
--   over-tagged comments = share of comments where the run gave more sub-themes than the key has
CREATE OR REPLACE VIEW TAG_SCORES AS
WITH key AS (
  SELECT k.COMMENT_ID, t.value:sub_theme::STRING AS SUB_THEME
  FROM ANSWER_KEY k, LATERAL FLATTEN(k.TAGS) t WHERE k.DECIDED_BY <> 'needs_review'),
key_n AS (SELECT COMMENT_ID, COUNT(*) AS KEY_TAGS FROM key GROUP BY 1),
runs AS (SELECT DISTINCT RUN_ID, MODEL_ID FROM ANSWERS WHERE RLIKE(RUN_ID, '[A-Z][0-9]+_r[0-9]+')),
per_comment AS (
  SELECT r.RUN_ID, r.MODEL_ID, n.COMMENT_ID, n.KEY_TAGS,
         COUNT(t.SUB_THEME) AS RUN_TAGS_N, COUNT(k.SUB_THEME) AS CORRECT
  FROM runs r CROSS JOIN key_n n
  LEFT JOIN RUN_TAGS t ON t.RUN_ID = r.RUN_ID AND t.COMMENT_ID = n.COMMENT_ID
  LEFT JOIN key k ON k.COMMENT_ID = t.COMMENT_ID AND k.SUB_THEME = t.SUB_THEME
  GROUP BY 1, 2, 3, 4)
SELECT RUN_ID, ANY_VALUE(MODEL_ID) AS MODEL_ID, COUNT(*) AS COMMENTS,
       SUM(RUN_TAGS_N) AS TAGS_GIVEN, SUM(KEY_TAGS) AS KEY_TAGS, SUM(CORRECT) AS CORRECT_TAGS,
       ROUND(SUM(CORRECT) / NULLIF(SUM(RUN_TAGS_N), 0), 3) AS PRECISION,
       ROUND(SUM(CORRECT) / NULLIF(SUM(KEY_TAGS), 0), 3) AS RECALL,
       ROUND(2 * SUM(CORRECT) / NULLIF(SUM(RUN_TAGS_N) + SUM(KEY_TAGS), 0), 3) AS F1,
       ROUND(AVG(RUN_TAGS_N), 2) AS TAGS_PER_COMMENT,
       ROUND(AVG(KEY_TAGS), 2) AS KEY_TAGS_PER_COMMENT,
       ROUND(100 * COUNT_IF(RUN_TAGS_N > KEY_TAGS) / COUNT(*), 1) AS PCT_OVER_TAGGED,
       ROUND(100 * COUNT_IF(RUN_TAGS_N < KEY_TAGS) / COUNT(*), 1) AS PCT_UNDER_TAGGED,
       ROUND(100 * COUNT_IF(CORRECT = KEY_TAGS AND RUN_TAGS_N = KEY_TAGS) / COUNT(*), 1) AS PCT_EXACT_MATCH
FROM per_comment
GROUP BY RUN_ID;

-- TAG_SCORES_BY_SUBTHEME: per run and sub-theme, how often it was given, how often correctly, and F1.
-- High GIVEN with low PRECISION = an over-used sub-theme; low RECALL = one that is missed.
CREATE OR REPLACE VIEW TAG_SCORES_BY_SUBTHEME AS
WITH key AS (
  SELECT k.COMMENT_ID, t.value:sub_theme::STRING AS SUB_THEME
  FROM ANSWER_KEY k, LATERAL FLATTEN(k.TAGS) t WHERE k.DECIDED_BY <> 'needs_review'),
scored AS (SELECT COMMENT_ID FROM ANSWER_KEY WHERE DECIDED_BY <> 'needs_review'),
given AS (
  SELECT t.RUN_ID, t.SUB_THEME, COUNT(*) AS GIVEN, COUNT(k.COMMENT_ID) AS CORRECT
  FROM RUN_TAGS t JOIN scored USING (COMMENT_ID)
  LEFT JOIN key k ON k.COMMENT_ID = t.COMMENT_ID AND k.SUB_THEME = t.SUB_THEME
  GROUP BY 1, 2),
in_key AS (SELECT SUB_THEME, COUNT(*) AS IN_KEY FROM key GROUP BY 1),
runs AS (SELECT DISTINCT RUN_ID FROM ANSWERS WHERE RLIKE(RUN_ID, '[A-Z][0-9]+_r[0-9]+'))
SELECT r.RUN_ID, s.SUB_THEME,
       COALESCE(g.GIVEN, 0) AS GIVEN, COALESCE(i.IN_KEY, 0) AS IN_KEY, COALESCE(g.CORRECT, 0) AS CORRECT,
       ROUND(COALESCE(g.CORRECT, 0) / NULLIF(g.GIVEN, 0), 3) AS PRECISION,
       ROUND(COALESCE(g.CORRECT, 0) / NULLIF(i.IN_KEY, 0), 3) AS RECALL,
       ROUND(2 * COALESCE(g.CORRECT, 0) / NULLIF(COALESCE(g.GIVEN, 0) + COALESCE(i.IN_KEY, 0), 0), 3) AS F1
FROM runs r CROSS JOIN TAXONOMY s
LEFT JOIN given g ON g.RUN_ID = r.RUN_ID AND g.SUB_THEME = s.SUB_THEME
LEFT JOIN in_key i ON i.SUB_THEME = s.SUB_THEME;

-- TAG_CONSISTENCY: per setup and comment set (SAMPLE or FRESH), how many repeats it has and the share of comments
-- with the identical set of sub-themes in every repeat (an answer with no valid tag counts as the empty set).
CREATE OR REPLACE VIEW TAG_CONSISTENCY AS
WITH per_answer AS (
  SELECT a.MODEL_ID, IFF(CONTAINS(a.RUN_ID, '_fresh_'), 'FRESH', 'SAMPLE') AS COMMENT_SET, a.RUN_ID, a.COMMENT_ID,
         COALESCE(LISTAGG(t.SUB_THEME, '|') WITHIN GROUP (ORDER BY t.SUB_THEME), '') AS TAG_SET
  FROM ANSWERS a LEFT JOIN RUN_TAGS t USING (RUN_ID, COMMENT_ID)
  GROUP BY 1, 2, 3, 4),
per_comment AS (
  SELECT MODEL_ID, COMMENT_SET, COMMENT_ID, COUNT(*) AS REPEATS, COUNT(DISTINCT TAG_SET) AS VERSIONS
  FROM per_answer GROUP BY 1, 2, 3)
SELECT MODEL_ID, COMMENT_SET, COUNT(*) AS COMMENTS, MAX(REPEATS) AS REPEATS,
       ROUND(100 * COUNT_IF(VERSIONS = 1) / COUNT(*), 1) AS PCT_SAME_TAGS
FROM per_comment GROUP BY 1, 2;
