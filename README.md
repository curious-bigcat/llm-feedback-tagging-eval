# NHS feedback tagging evaluation

**Goal:** find which AI model and prompt tags patient comments with the right sub-themes, sentiment and impact
most accurately, treating the data like real customer feedback (text only, no labels).

Everything runs in Snowflake: database `VOC_EVAL`, schema `HARNESS`, role `VOC_EVAL_ROLE`.

**Result:** switch from today's setup (Mistral Large 3, current prompt) to **Gemini 3.1 Pro with the structured v3
prompt (C09)**:
- **Precision 0.75** (today 0.51): far fewer wrong extra tags
- **1.89 tags per comment**, close to the answer key's 1.69 (today 2.92)
- **Same tags in all 3 runs for 83% of comments** (today 39%)
- **Valid for 205 of 207 comments** (today 170)
- **Judge groundedness and coherence 0.85** (today 0.63 / 0.60)
- About 3.8x today's cost (19.5 vs 5.1 credits per 1,000 comments)

**Quick win at today's cost:** keep Mistral and switch only the prompt to v3 (C10: precision 0.51 -> 0.65,
consistency 39% -> 58%). Cheaper option: GPT-5.4 with v3 (C11). Full details in `decision_report.md`. The whole
evaluation cost about 227 credits.

**How accuracy is measured:** plain SQL compares each setup's tags with an answer key (`sql/tag_scores.sql`):
**precision** = correct tags / tags given (low = over-tagging), **recall** = correct tags / key tags (low = missed tags),
**F1** = both combined. No AI is used for these scores; an AI judge adds a second, independent check.

## The approach at a glance

![Evaluation approach](evaluation_approach.png)

---

## Steps

| Step | What | Result |
|---|---|---|
| 1. Load the data | `COMMENTS`, `TAXONOMY` from `data/` | 6,211 comments, 33 sub-themes |
| 2. Pick a test sample | `sql/sample.sql` | **207 comments** (every sub-theme 10+ except Parking 3; every impact level 17+) |
| 3. Panel + over-tagging check | 4 models tag the sample | 1.8-2.3 tags per comment, none over-tagging |
| 4. Answer key + human review | `sql/answer_key.sql`, review app `ANSWER_REVIEW` | 67 panel + 140 human = 207 rows, 1.69 tags per comment |
| 5. Tag-accuracy scores | `sql/tag_scores.sql` | Precision, recall, F1, tags per comment, over-tagging, consistency |
| 6. Test grid | 4 models x 2 prompts x 3 repeats | 24 runs |
| 7. Over-tagging fix | v3 prompt on all 4 models | 12 setups, 36 runs, 7,452 answers |
| 8. AI judge | `sql/judge.sql`, `notebook/judge_app.py` | 36 runs, scores in `JUDGE_SCORES` |
| 9. Decision report | `decision_report.md` | Winner **C09 Gemini 3.1 Pro + structured_v3** |
| 10a. Fresh-comment check | `sql/fresh.sql` | The result holds on 100 new comments |
| 10b. Answer-key audit (blind) | `sql/audit.sql`, review app audit mode | 30 items ready, waiting for a person's review |

---

## Step 1: Load the data

| Table | Rows | What it holds |
|---|---|---|
| `COMMENTS` | 6,211 | `COMMENT_ID, RESPONDENT_ID, TRUST, SERVICE, DATE_RAW, QUESTION, COMMENT_TEXT, PATIENT_RATING` |
| `TAXONOMY` | 33 | The rulebook: 10 themes, 33 sub-themes, each with a definition and example quotes |

No labels, groups or flags: just the text, as real customer data would arrive.

Every answer gives, per tag, a theme, sub-theme, sentiment label and score, confidence and a quote from the comment,
plus one **impact** rating for the whole comment:

| Impact | Meaning |
|---|---|
| 1 | No problem raised (praise, thanks or nothing to improve) |
| 2 | Minor inconvenience (parking, signs, food choice) |
| 3 | Clearly affected the experience, no harm (a long wait, poor communication) |
| 4 | Significant distress, a delay in care or a failure of service |
| 5 | Harm or a risk to safety (serious neglect, a fall, a safeguarding concern) |

## Step 2: Pick a test sample (`sql/sample.sql`)

Result: **`SAMPLE_COMMENTS`, 207 comments, at least 10 for every sub-theme (Parking: 3, all the data has) and at
least 17 for every impact level.**

1. **Set some comments aside** (never tested):
   - comments that copy a rulebook example quote, because a model would already know the answer
   - 20% of people, kept aside (used later for the fresh-comment check, step 10a)
   - one person's comments always stay together
2. **Rough-tag the rest with a cheap model** (Llama 3.3): which sub-themes, which words show it, and a rough impact.
   A tag only counts if those words are really in the comment. Used only to pick the sample, never as the answer.
   About 3 credits.
3. **Pick comments until every group has 10.** A group is a sub-theme or an impact level. Each group takes comments
   in a fixed shuffled order (`SHA2` of the comment id, so nobody chooses and a re-run picks the same). One comment
   counts for every group it is in.

## Step 3: Panel + over-tagging check (`sql/setup.sql`)

4 cheaper models from different makers (the **panel**) tag all 207 comments with the same prompt and answer format,
via `RUN_MODEL('P01', 1)` .. `('P04', 1)`. Before voting, `TAG_PROFILE` (no answer key needed) checks none of them
over-tags:

| Panel | Model | Passed the checks | Tags per comment | 1 tag | 4+ tags |
|---|---|---|---|---|---|
| P01 | Claude Haiku 4.5 | 124 / 207 | 1.94 | 45% | 10% |
| P02 | GPT-5.4 mini | 179 / 207 | 2.26 | 32% | 16% |
| P03 | Gemini 3.8 Flash | 198 / 207 | 2.08 | 38% | 12% |
| P04 | Mistral Large 2 | 185 / 207 | 1.81 | 47% | 5% |

All under the 2.5 warning level, so all 4 vote. Because a tag needs 3 of 4 models, one model's extra tags cannot
enter the key on their own. Haiku fails mostly on sentiment scores not matching the label; the key uses only its
tags, labels and impact.

**How every answer is run and checked** (`RUN_MODEL` in `sql/setup.sql`):
- one `AI_COMPLETE` call per comment in a single SQL statement (Snowflake runs them in parallel), temperature 0, with
  a fixed JSON answer format (`RULEBOOK`) that allows only the 33 real sub-themes
- `CHECK_ANSWER`, 7 rules: at least one tag; real theme + sub-theme pair; **quote really in the comment**; sentiment
  score matches its label; confidence 0-1; no repeated sub-theme; impact 1-5
- a failed answer is asked once more; a tested model's answer that still fails goes to `REVIEW_QUEUE`

## Step 4: Answer key + human review (`sql/answer_key.sql`, `ANSWER_REVIEW` app)

**Votes per tag:**
- 3 or 4 models gave it: **accepted**
- 2 models gave it: **split**, a person decides
- 1 model gave it: dropped
- sentiment accepted when 3 or more models agree; impact when 3 or more gave one and all are within 1 point (value =
  the middle rating)
- **4+ agreed tags** also go to a person, as a guard against over-tagging in the key itself

**The review app** (Snowsight > Projects > Streamlit > `ANSWER_REVIEW`) shows **10 comments per page**: the comment,
the agreed tags pre-selected, the 2-of-4 suggestions as tick-boxes, sentiment and impact pre-filled when the panel
agreed, a warning above 3 tags, "Skip for now", and one **Save this page** button. Saving sets
`ANSWER_KEY.DECIDED_BY = human` (with who and when) and closes the `REVIEW_QUEUE` item. `answer_key.sql` refuses to
rebuild once any row is `human`, so decisions are never overwritten.

**Result:** 67 rows settled by the panel (1.43 tags per comment) + 140 by a person (1.81) = 207 rows,
**1.69 tags per comment**. The reviewer added tags on 26 comments (mostly 2-of-4 suggestions) and removed tags on 1,
so the key leans towards finding every point rather than being strict.

## Step 5: Tag-accuracy scores (`sql/tag_scores.sql`)

Plain SQL, no AI: free, exact and the same every time.

| View | What it shows |
|---|---|
| `RUN_TAGS` | One row per run x comment x valid sub-theme (JSON answers flattened; invalid pairs and duplicates removed) |
| `TAG_PROFILE` | Tags per comment, % with 1 tag, % with 4+ tags, top 3 sub-themes (no answer key needed) |
| `TAG_SCORES` | Per run: **precision, recall, F1**, tags per comment, % over-tagged, % under-tagged, % exact match |
| `TAG_SCORES_BY_SUBTHEME` | The same per sub-theme: which ones a model over-uses or misses |
| `TAG_CONSISTENCY` | Share of comments with the identical set of sub-themes in every repeat |

**How `TAG_SCORES` works:** for each run and each comment, SQL counts the tags given, the tags in the key and the
**correct tags** (given and in the key). It adds these up over all 207 comments, then divides once (micro-average,
so every tag counts the same):

- precision = correct / given
- recall = correct / key
- F1 = 2 x correct / (given + key)

Example, one run of today's setup: 606 tags given, 349 in the key, 307 correct -> precision 0.507, recall 0.880,
F1 0.643. The winner (C09): 393 given, 293 correct -> precision 0.746, recall 0.840, F1 0.790.

**Panel vs the key** (a sanity check only: the panel's votes helped build the key):

| Panel | Model | Precision | Recall | F1 | Tags per comment | Exact match |
|---|---|---|---|---|---|---|
| P01 | Claude Haiku 4.5 | 0.76 | 0.87 | 0.81 | 1.94 | 54% |
| P02 | GPT-5.4 mini | 0.69 | 0.92 | 0.79 | 2.26 | 47% |
| P03 | Gemini 3.8 Flash | 0.73 | 0.90 | 0.80 | 2.08 | 52% |
| P04 | Mistral Large 2 | 0.72 | 0.77 | 0.75 | 1.81 | 47% |

## Step 6: Test grid

4 models x 2 prompts, each tagging all 207 comments 3 times (to check consistency), with `RUN_MODEL(setup, repeat)`.
Each setup runs on its own warehouse (`VOC_EVAL_C01`..`C08`) as a task with its 3 repeats in parallel. Run ids look
like `C04_r2`.

| | Current prompt (`current_v2`) | Structured prompt (`structured_v2`) | Structured v3 (step 7) |
|---|---|---|---|
| Mistral Large 3 | C01 (today's setup) | C05 | C10 |
| Claude Opus 5 | C02 | C06 | C12 |
| GPT-5.4 | C03 | C07 | C11 |
| Gemini 3.1 Pro | C04 | C08 | C09 |

**Results, average of 3 repeats** (`TAG_SCORES` vs the key; key = 1.69 tags per comment):

| Setup | Valid (of 207) | Precision | Recall | F1 (range) | Tags per comment | Over-tagged | Same tags in 3 repeats | Same impact in 3 repeats |
|---|---|---|---|---|---|---|---|---|
| C04 Gemini / current | 188 | 0.75 | 0.86 | **0.80** (0.80-0.80) | 1.94 | 29% | 72% | 93% |
| C08 Gemini / structured | **206** | 0.72 | 0.85 | 0.78 (0.78-0.79) | 1.98 | 30% | 69% | 88% |
| C06 Opus / structured | 205 | 0.61 | 0.90 | 0.73 (0.72-0.73) | 2.46 | 51% | **73%** | **94%** |
| C03 GPT-5.4 / current | 183 | 0.61 | 0.90 | 0.72 (0.72-0.73) | 2.48 | 52% | 61% | 86% |
| C02 Opus / current | 173 | 0.60 | 0.90 | 0.72 (0.72-0.72) | 2.52 | 54% | 69% | 93% |
| C07 GPT-5.4 / structured | 194 | 0.63 | 0.85 | 0.72 (0.72-0.72) | 2.29 | 43% | 63% | 88% |
| C05 Mistral / structured | 179 | 0.58 | 0.88 | 0.70 (0.70-0.71) | 2.56 | 57% | 45% | 85% |
| C01 Mistral / current (today) | 170 | 0.51 | 0.89 | 0.65 (0.64-0.65) | **2.92** | **73%** | **39%** | 83% |

- Every setup finds most of the right tags (recall 0.84-0.91); they differ in how many **wrong extra tags** they add.
- Today's setup over-tags 73% of comments; its most over-used sub-themes are Continuity of care, Staff listening and
  Competence & training (precision 0.24-0.40).
- F1 moves by at most 0.01 between repeats, so the gaps between setups are real.
- Gemini 3.1 Pro is the only model close to the key's tag count.

## Step 7: Over-tagging fix

1. **Drop low-confidence tags** (free, SQL only): does not work. The models are confident even about wrong tags;
   today's setup rates almost every tag 0.8 or higher, so a 0.7 cut removes nothing. A 0.9 cut removes correct tags
   too (C08: precision 0.72 -> 0.80 but recall 0.85 -> 0.72, F1 0.78 -> 0.76).
2. **Tell the model not to over-tag:** `prompts/structured_v3.txt` = `structured_v2` plus one rule ("tag a sub-theme
   only when the comment makes a clear point about it; most comments make 1-2 points", with an example) and a
   matching final check. Tested on all 4 models (C09-C12), so the fix is shown to come from the prompt:

| Model | Prompt | Setup | Valid (of 207) | Precision | Recall | F1 | Tags per comment | Over-tagged | Same tags in 3 repeats |
|---|---|---|---|---|---|---|---|---|---|
| Mistral Large 3 | current | C01 (today) | 170 | 0.51 | 0.89 | 0.65 | 2.92 | 73% | 39% |
| Mistral Large 3 | structured_v2 | C05 | 179 | 0.58 | 0.88 | 0.70 | 2.56 | 57% | 45% |
| Mistral Large 3 | structured_v3 | **C10** | 185 | **0.65** | 0.85 | **0.74** | **2.21** | **43%** | **58%** |
| GPT-5.4 | current | C03 | 183 | 0.61 | 0.90 | 0.72 | 2.48 | 52% | 61% |
| GPT-5.4 | structured_v2 | C07 | 194 | 0.63 | 0.85 | 0.72 | 2.29 | 43% | 63% |
| GPT-5.4 | structured_v3 | **C11** | 195 | **0.67** | 0.84 | **0.74** | **2.13** | **37%** | **68%** |
| Claude Opus 5 | current | C02 | 173 | 0.60 | 0.90 | 0.72 | 2.52 | 54% | 69% |
| Claude Opus 5 | structured_v2 | C06 | 205 | 0.61 | 0.90 | 0.73 | 2.46 | 51% | 73% |
| Claude Opus 5 | structured_v3 | **C12** | 203 | **0.66** | 0.87 | **0.75** | **2.23** | **42%** | **77%** |
| Gemini 3.1 Pro | current | C04 | 188 | 0.75 | 0.86 | 0.80 | 1.94 | 29% | 72% |
| Gemini 3.1 Pro | structured_v2 | C08 | 206 | 0.72 | 0.85 | 0.78 | 1.98 | 30% | 69% |
| Gemini 3.1 Pro | structured_v3 | **C09** | 205 | 0.75 | 0.84 | 0.79 | **1.89** | **25%** | **83%** |

The rule works on every model: v3 gives each model its best precision, fewest tags, least over-tagging and highest
consistency, for a recall cost of 0.01-0.03. It helps weaker models most: today's model goes from 2.92 to 2.21 tags
per comment, precision 0.51 -> 0.65, F1 0.65 -> 0.74 and consistency 39% -> 58% with no model change.

## Step 8: AI judge (`sql/judge.sql`, `notebook/judge_app.py`)

A second, independent check. The judge, **Claude Sonnet 4.6** (`J01` in `MODELS`, not one of the tested models),
scores every answer in **Snowflake Evaluations** with Snowflake's TruLens build. `JUDGE_RUN(setup, repeat, limit)`
replays a run's saved answers from `ANSWERS` (no new model calls) and scores each one:

| Score | Question | Scale | Uses the answer key? |
|---|---|---|---|
| correctness (built-in) | Does the answer match `ANSWER_KEY` (tags, sentiment, impact)? | 0-3 | Yes |
| tag_groundedness (ours) | Is each tag supported by the comment? (share of tags judged yes) | 0-1 | No |
| tag_coherence (ours) | Do the tags fit together: sentiment fits the quote, no contradictions, no duplicates? | 0-1 | No |

All judge prompts of a run go to the model in one parallel batch; runs ran 3 per warehouse. Every score, with the
judge's reason, is saved in table `JUDGE_SCORES` (12 of 7,452 correctness scores missing, left out of averages).

**Results** (average of 3 repeats; correctness range in brackets):

| Setup | Correctness (0-3) | Groundedness | Coherence | F1 (SQL) |
|---|---|---|---|---|
| C04 Gemini / current | **2.64** (2.63-2.64) | 0.83 | 0.84 | **0.80** |
| C08 Gemini / v2 | 2.63 (2.62-2.66) | 0.83 | 0.84 | 0.78 |
| **C09 Gemini / v3** | 2.60 (2.59-2.61) | **0.85** | **0.85** | 0.79 |
| C11 GPT-5.4 / v3 | 2.60 (2.58-2.62) | 0.78 | 0.78 | 0.74 |
| C07 GPT-5.4 / v2 | 2.59 (2.57-2.59) | 0.76 | 0.76 | 0.72 |
| C03 GPT-5.4 / current | 2.57 (2.56-2.58) | 0.72 | 0.72 | 0.72 |
| C06 Opus / v2 | 2.56 (2.52-2.59) | 0.76 | 0.75 | 0.73 |
| C12 Opus / v3 | 2.55 (2.53-2.57) | 0.78 | 0.78 | 0.75 |
| C02 Opus / current | 2.51 (2.47-2.55) | 0.75 | 0.73 | 0.72 |
| C10 Mistral / v3 | 2.50 (2.48-2.53) | 0.70 | 0.73 | 0.74 |
| C05 Mistral / v2 | 2.47 (2.46-2.49) | 0.68 | 0.69 | 0.70 |
| C01 Mistral / current (today) | 2.35 (2.33-2.38) | 0.63 | 0.60 | 0.65 |

The judge and the plain-SQL F1 agree: Gemini first, today's setup last, and v3 raises groundedness and coherence
for every model.

## Step 9: Decision report (`decision_report.md`)

**Recommendation: Gemini 3.1 Pro with the structured v3 prompt (C09)** - top precision, groundedness and coherence,
near-full validity and by far the most consistent. Cheaper options: Mistral + v3 (C10, today's cost) and GPT-5.4 +
v3 (C11). The report also covers pass criteria, impact accuracy, real costs from usage history, limitations and next
steps.

## Step 10: Checks that the winner holds

**10a. Fresh comments (`sql/fresh.sql`).** The v3 prompt was written after seeing over-tagging on the 207 sample
comments, so it could be tuned to them. This check runs C09 (winner) and C01 (today) 3 times each on 100 comments the
prompt work never saw (one per person, from the 20% of people kept aside in step 2). There is no answer key for them,
so it compares only what needs none.

| Setup | Valid | Tags / comment | 1 tag | 4+ tags | Same tags 3x | Groundedness | Coherence |
|---|---|---|---|---|---|---|---|
| C09 Gemini / v3 | 100% (99%) | **1.60** (1.89) | 57% (44%) | **4%** (7%) | 71% (83%) | **0.90** (0.85) | **0.85** (0.85) |
| C01 today | 90% (82%) | 2.49 (2.92) | 23% (12%) | 21% (26%) | 55% (39%) | 0.68 (0.63) | 0.66 (0.60) |

(Sample figures in brackets.)
- **The winner holds:** far fewer tags than today's setup, and more of them supported (0.90 vs 0.68).
- Both give fewer tags here because fresh comments are a random pick and shorter (85 vs 148 characters on average).
- C09's consistency is lower here (71%): in the comments that differ, usually one run adds or swaps one borderline
  tag; 2 of 3 runs agree on almost all.
- **Not measured on fresh comments:** precision, recall, F1 and judge correctness, which need an answer key. That
  would need the panel plus about 65 comments of human review.

**10b. Answer-key audit (`sql/audit.sql`).** 30 of the 67 key rows the panel settled alone (fixed hash pick) are in
the review app's **Blind audit** mode: only the comment is shown, no suggestion, and a person tags it fresh. Answers
are saved in `REVIEW_QUEUE` only (`ANSWER_KEY` is not changed). `AUDIT_SCORES` then compares the person with the
panel (precision, recall, F1, exact match, sentiment and impact agreement). **Status: waiting for the review.**

---

## Aggregation: building the report for one service

**Goal:** test how a service report should be built from the tagged comments, and check the customer's reporting
challenges: large inputs hitting the context limit, the answer being too long to cover every theme with its
evidence, different results between runs, fragmented or inconsistent evidence quotes, and double counting.

**Service:** Forensic, all 669 comments (one real report: realistic size and mix).
**Writers:** Mistral Large 3 (today's model), Gemini 3.1 Pro (the tagging winner), GPT-5.4 (cheaper strong option);
3 runs each. **Judge:** Claude Sonnet 4.6 (not a writer).

**Finished report:** [`reports/service_report.md`](reports/service_report.md), with the Gemini vs Mistral comparison
at the end.

### Approach: SQL does the counting and grouping, the AI only writes

1. **Map (SQL):** every comment of the service is tagged once by the winner; each tag gives theme, sub-theme,
   sentiment and an evidence quote. Two tables: one row per comment (`SERVICE_ANSWERS`), one row per comment x
   sub-theme (`SERVICE_TAGS`, invalid pairs dropped, a sub-theme given twice kept once).
2. **Count (semantic view):** `SERVICE_SV` defines every number once: comments, % negative, % positive, high impact,
   by theme and sub-theme, with `COUNT(DISTINCT COMMENT_ID)` so no comment is double counted. Checked against plain SQL.
3. **Reduce and concatenate (SQL):** nested `LISTAGG` builds one document: service -> theme -> sub-theme -> comment ->
   the tag's sentiment and evidence, with the semantic-view counts on each heading, biggest groups first.
4. **Write (AI, one call):** the writer reads the document and returns JSON (overview, a summary per theme, a summary
   and 1-2 quotes per sub-theme with 5+ comments). It must not write numbers and must copy quotes word for word.
5. **Lay out (SQL):** `SERVICE_FINAL_REPORT` puts the semantic-view numbers and the writer's text together into
   markdown. The AI never touches a number.
6. **Check:** SQL checks coverage against `SERVICE_EXPECTED`, quotes against the comments, and digits in the text; the
   judge checks each section's claims against that section's comments, and compares the 3 runs.

| Step | What | How | Cost (about) |
|---|---|---|---|
| R1. Tag the service | All 669 comments tagged once by the winner (C09) | `sql/service.sql` builds `SERVICE_COMMENTS`; `RUN_MODEL('C09', 1, 'SERVICE_COMMENTS')` -> run `C09_svc_r1` | 13 |
| R2. Counts | One row per comment and per tag; semantic view `SERVICE_SV` gives every count and % (each comment once per theme) | SQL, no AI | 0 |
| R3. Concatenate | One document nested **service -> theme -> sub-theme -> comment -> the tag's sentiment and evidence quote**, with the counts from `SERVICE_SV` beside each group | SQL only (`LISTAGG`) | 0 |
| R4. Write the report | The same instruction on that document, one call per writer, 3 runs each (9 reports); numbers are not written by the AI | `AI_COMPLETE` | 5-15 |
| R5. Score | Coverage of the expected sections, faithfulness and consistency (judge), quotes word for word and no numbers in the text (SQL), input size vs context | `sql/service_scores.sql` -> `SERVICE_JUDGE`, `SERVICE_CONSISTENCY`, view `SERVICE_SCORES` | 5-10 |

**Run it:** `service.sql`, `RUN_MODEL('C09', 1, 'SERVICE_COMMENTS')`, `service_tags.sql`, `service_reports.sql`, then
`CALL RUN_SERVICE_REPORT('<writer>', 1..3)` for each writer (one task per writer), then `service_scores.sql`; read
`SELECT * FROM SERVICE_SCORES`. Then `service_final.sql` and `SELECT REPORT FROM SERVICE_FINAL_REPORT`.

### Results (Forensic, 669 comments, 9 reports)

R1: 669 comments tagged, 667 passed the checks (12 after a retry). R2: the semantic view and plain SQL agree on all
28 sub-theme counts. R3: the document is about 37k tokens; a complete report needs 9 theme sections and the 24
sub-themes with 5+ comments.

| Score (average of 3 runs) | Mistral Large 3 | Gemini 3.1 Pro | GPT-5.4 |
|---|---|---|---|
| Theme sections written (of 9) | 9 | 9 | 9 |
| Sub-theme sections written (of 24) | 20 (17-22) | **24 every run** | 21.3 (20-22) |
| Other sub-theme sections per run (fewer than 5 comments, or a name not in that list) | 2 | 0 | 0 |
| Same sub-theme sections in all 3 runs | no | **yes** | no |
| Faithful: overview / themes / sub-themes (share of claims the comments support) | 1.00 / 0.91 / 0.86 | 0.94 / 0.83 / 0.86 | 0.97 / **0.98 / 0.91** |
| Consistent: overview / themes (share of main points made in all 3 runs) | 0.78 / 0.41 | 0.46 / 0.50 | 0.44 / 0.62 |
| Quotes word for word in a comment of that sub-theme | 90% (some words changed) | **100%** | **100%** |
| Numbers written by the AI | 0 (1 "COVID-19") | 0 (2 "COVID-19") | 0 |
| Input / output tokens per report | 39k / 3.5k | 40k / 4.6k | 37k / 2.9k |

**The customer's challenges, one by one:**
- **Context limit:** not a problem for one service: about 40k input tokens fit all 3 writers. All 6,211 comments in
  one document would be about 9 times bigger (roughly 350k tokens), so a report stays one service (or one theme) per call.
- **Answer too long to cover the hierarchy and evidence:** this is the real problem. No report hit the 8,192-token
  answer limit (largest 5.1k), yet Mistral and GPT still skipped sub-themes (up to 7 of 24): the model chooses to
  stop, so "it has room" does not mean "it covers everything". Only Gemini wrote every section in every run.
- **Different results between runs:** even at temperature 0, only about half of the main points of a theme appear
  in all 3 runs, and only Gemini wrote the same sections each time. The text varies; the structure and numbers must
  not, which is why both come from SQL.
- **Fragmented or inconsistent quotes:** Gemini and GPT copied every quote exactly; Mistral changed words in 1 in 10
  (e.g. "uncertainty" to "uncertainties") and quoted a hospital name. Checked by SQL (`SOFT_QUOTE`), no AI.
- **Double counting:** solved before the AI: every count comes from `SERVICE_SV` (`COUNT(DISTINCT COMMENT_ID)`), and
  no writer wrote a count.
- **Main faithfulness error:** frequency words. Most unsupported claims say "many" for a point only a few comments make.

**Recommendation:** counts from the semantic view, text from Gemini 3.1 Pro (complete and stable structure, exact
quotes), and a check after writing that every expected section is there (`SERVICE_EXPECTED`); GPT-5.4 is the most
faithful but needs that check, as it skips sections. Credits for this phase are not yet in the usage history.

## Snowflake objects

| Kind | Name | Purpose |
|---|---|---|
| Table | `COMMENTS`, `TAXONOMY` | Raw data |
| Table | `SAMPLE_COMMENTS` | The 207 test comments |
| Table | `PROMPTS` | The prompt files (`current_v2`, `structured_v2`, `structured_v3`), with a SHA-256 fingerprint |
| Table | `MODELS` | Every model setup: id, role, model, prompt |
| View | `RULEBOOK` | Taxonomy text for prompts, the 33 valid pairs, the fixed answer format (tags + impact) |
| Function | `CHECK_ANSWER`, `NORM_QUOTE` | The automatic answer checks and quote matching |
| Procedure | `RUN_MODEL(model_id, repeat [, source])` | Runs one model over the sample, e.g. `CALL RUN_MODEL('C09', 1)`; source `'FRESH_COMMENTS'` for step 10a |
| Table | `ANSWERS` | Every model answer, with its check result |
| Table | `ANSWER_KEY` | The correct tags, sentiment and impact per sample comment |
| Table | `REVIEW_QUEUE` | Items for a person: `panel_split` (all done), `audit` (step 10b), `failed_check` (optional) |
| Streamlit | `ANSWER_REVIEW` | Review app: panel disagreements, and the blind audit |
| View | `RUN_TAGS`, `TAG_PROFILE`, `TAG_SCORES`, `TAG_SCORES_BY_SUBTHEME`, `TAG_CONSISTENCY` | Plain-SQL tag accuracy: precision, recall, F1, tags per comment, over-tagging, consistency |
| Procedure | `JUDGE_RUN(model_id, repeat, limit [, source])` | Judges one run in Snowflake Evaluations, e.g. `CALL JUDGE_RUN('C09', 1, 0)` |
| Table | `JUDGE_SCORES` | Every judge score with its reason: 36 full runs, 6 fresh-comment runs, test runs |
| Evaluations app | `FEEDBACK_TAGGER` | Where new judge runs are recorded (created by TruLens on the next `JUDGE_RUN`) |
| Table | `FRESH_COMMENTS` | Step 10a: 100 comments from the 20% of people kept aside |
| View | `AUDIT_ROWS`, `AUDIT_SCORES` | Step 10b: the person's blind answers vs the panel's key |
| Stage | `DATA_STAGE` | Uploaded data, prompts, scripts and app files |
| Table | `SERVICE_COMMENTS`, `SERVICE_ANSWERS`, `SERVICE_TAGS` | Aggregation: the Forensic comments, one row per comment, one row per comment x sub-theme |
| Semantic view | `SERVICE_SV` | Every count and % in the service report (each comment once per theme) |
| View | `SERVICE_DOCUMENT`, `SERVICE_EXPECTED`, `SERVICE_LINES` | The SQL-built document, the sections a complete report needs, the comments per section |
| Procedure | `RUN_SERVICE_REPORT(writer, repeat)` | One report by one writer into `SERVICE_REPORTS` |
| Table / view | `SERVICE_REPORTS`, `SERVICE_JUDGE`, `SERVICE_CONSISTENCY`, `SERVICE_SCORES` | The 9 reports and their scores |
| Function | `SOFT_QUOTE` | Quote matching that ignores quote marks and end punctuation |
| View | `SERVICE_FINAL_REPORT` | The finished report as markdown (numbers from `SERVICE_SV`, text from one writer) |

Warehouses: `VOC_EVAL_PANEL` (panel runs), `VOC_EVAL_C01`..`VOC_EVAL_C08` (grid runs), `DEMO_WH` (app).

## Files

| File | What it does |
|---|---|
| `decision_report.md` | Results, recommendation, costs, limitations |
| `evaluation_approach.png`, `.svg` | One-page diagram of the approach (the `.svg` is editable) |
| `data/comments.csv`, `data/taxonomy.csv` | Raw data |
| `prompts/current_v2.txt` | Today's prompt |
| `prompts/structured_v2.txt` | The structured prompt template |
| `prompts/structured_v3.txt` | `structured_v2` + the rule against over-tagging (the winner's prompt) |
| `sql/sample.sql` | Step 2: builds `SAMPLE_COMMENTS` |
| `sql/setup.sql` | Prompts, models, rulebook, checks, answers table, review queue, `RUN_MODEL` |
| `sql/answer_key.sql` | Step 4: builds `ANSWER_KEY` from the panel and queues disagreements |
| `sql/tag_scores.sql` | Step 5: precision, recall, F1 and the other tag-accuracy views |
| `sql/judge.sql`, `notebook/judge_app.py` | Step 8: the `JUDGE_RUN` procedure and the TruLens app with the two custom judge metrics |
| `sql/fresh.sql` | Step 10a: builds `FRESH_COMMENTS` |
| `sql/audit.sql` | Step 10b: queues the blind-audit items and creates `AUDIT_ROWS`, `AUDIT_SCORES` |
| `app/streamlit_app.py`, `app/environment.yml` | The `ANSWER_REVIEW` app |
| `sql/service.sql`, `sql/service_tags.sql` | Aggregation R1-R3: the service's comments, the tables, `SERVICE_SV` and the document |
| `sql/service_reports.sql`, `prompts/service_report_v1.txt` | R4: `RUN_SERVICE_REPORT` and the report instruction |
| `sql/service_scores.sql`, `prompts/service_judge_v1.txt`, `prompts/service_consistency_v1.txt` | R5: scores and the two judge instructions |
| `sql/service_final.sql`, `reports/service_report.md` | The finished report: semantic-view numbers + Gemini text, and the Gemini vs Mistral comparison |

## Rebuild from scratch

1. Upload `data/*.csv` to `@DATA_STAGE`, `prompts/*.txt` to `@DATA_STAGE/prompts/`, `sql/*.sql` to `@DATA_STAGE/sql/`,
   `app/*` to `@DATA_STAGE/app/`, `notebook/judge_app.py` to `@DATA_STAGE/notebook/`.
2. Create and load `COMMENTS` and `TAXONOMY` from the CSVs.
3. Run `sample.sql` (about 3 credits), then `setup.sql`, then `tag_scores.sql`.
4. Panel: `CALL RUN_MODEL('P01', 1)` .. `('P04', 1)`, in parallel.
5. Run `answer_key.sql`, then a person reviews the undecided comments in `ANSWER_REVIEW`.
6. Grid: `CALL RUN_MODEL('C01', 1)` .. `('C12', 3)`, one task per setup on its own warehouse. Read `TAG_SCORES`.
7. Judge (optional second check): run `judge.sql`, then `CALL JUDGE_RUN('C01', 1, 0)` .. `('C12', 3, 0)`, at most
   3 runs per warehouse (try `limit = 20` first).
8. Checks: `fresh.sql` then `RUN_MODEL(..., 'FRESH_COMMENTS')`; `audit.sql`, then the blind audit in the app.
