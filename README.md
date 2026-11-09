# NHS feedback tagging evaluation

**Goal:** find which AI model and prompt tags patient comments with the right sub-themes, sentiment and impact
most accurately, treating the data like real customer feedback (text only, no labels).

Everything runs in Snowflake: database `VOC_EVAL`, schema `HARNESS`, role `VOC_EVAL_ROLE`.

**Result in one line:** switch from today's setup (Mistral Large 3, current prompt) to **Gemini 3.1 Pro with the structured
prompt (C08)**: joint best on correctness, best on tag quality, valid for all 209 comments, at about 3.9x today's
cost per comment. Cheaper option: GPT-5.4 with the structured prompt (C07). Full details in `decision_report.md`. This run
(v2, with impact) cost about 162 credits.

## The approach at a glance

![Evaluation approach](evaluation_approach.png)

---

## Where we are

| Step | Status |
|---|---|
| 1. Load the raw data | Done |
| 2. Pick a test sample | Done (209 comments) |
| 3. Build the answer key | Done: 72 settled by the panel, 137 by a person |
| 4. Human review of undecided answers | Done: all 137 reviewed |
| 5. Test grid (8 setups x 3 repeats) | Done: 5,016 answers |
| 6. Judge scores every answer | Done: 15,044 scores |
| 7. Results report | Done: `decision_report.md` |

**Impact rating (new in v2):** every answer also rates the whole comment's impact from 1 to 5:

| Impact | Meaning |
|---|---|
| 1 | No problem raised (praise, thanks or nothing to improve) |
| 2 | Minor inconvenience (parking, signs, food choice) |
| 3 | Clearly affected the experience, no harm (a long wait, poor communication) |
| 4 | Significant distress, a delay in care or a failure of service |
| 5 | Harm or a risk to safety (serious neglect, a fall, a safeguarding concern) |

The same definition is in both prompts (`prompts/current_v2.txt`, `prompts/structured_v2.txt`). The v1 prompts and the v1
results (no impact) are kept only as files; Snowflake holds the v2 run.

---

## Step 1: Load the raw data

Two tables, loaded from `data/`:

| Table | Rows | What it holds |
|---|---|---|
| `COMMENTS` | 6,211 | `COMMENT_ID, RESPONDENT_ID, TRUST, SERVICE, DATE_RAW, QUESTION, COMMENT_TEXT, PATIENT_RATING` |
| `TAXONOMY` | 33 | The rulebook: 10 themes, 33 sub-themes, each with a definition and example quotes |

No labels, groups or flags: just the text, as real customer data would arrive.

## Step 2: Pick a test sample (`sql/sample.sql`)

Result: **`SAMPLE_COMMENTS`, 209 comments, at least 10 for every sub-theme and at least 10 for every impact level**
(except Parking, which has only 3: the data barely has any).

How:
1. **Set some comments aside** (never tested):
   - comments that copy a rulebook example quote, because a model would already know the answer
   - 20% of people, kept for writing prompt examples later
   - one person's comments always stay together
2. **Rough-tag the rest with a cheap model** (Llama 3.3): "which sub-themes is this about, which words show it,
   and how serious is it (impact 1-5)?" A tag only counts if those words are really in the comment. These rough
   tags are used only to pick the sample, never as the answer. Cost: about 3 credits, 2 minutes.
3. **Pick comments until every group has 10.** A group is a sub-theme or an impact level. Each group takes
   comments in a fixed shuffled order (a hash of the comment id, so nobody chooses). One comment counts for every
   group it is in, which is why it is 209 comments, not 380.

   Rough impact in the sample: 84 at level 1, 25 at 2, 55 at 3, 28 at 4, 17 at 5. Without the impact groups,
   the sample had only about 8 serious (level 5) comments.

Columns: `COMMENT_ID, QUESTION, COMMENT_TEXT, PICKED_FOR` (the group it was picked for),
`SUB_THEMES` (every sub-theme it seems to be about), `IMPACT` (Llama's rough impact; for picking only).

Note: Llama's rough tags can vary slightly between runs even at temperature 0, so re-running `sample.sql` can pick
a few different comments.

## Step 3: Build the answer key (`sql/setup.sql`, `sql/answer_key.sql`)

The answer key says what the correct tags, sentiment and impact are for each sample comment.

1. **4 different AI models (the panel)** each tag all 209 comments with the same prompt and answer format:

   | Panel | Model | Passed the checks |
   |---|---|---|
   | P01 | Claude Haiku 4.5 | 129 / 209 |
   | P02 | GPT-5.4 mini | 183 / 209 |
   | P03 | Gemini 3.8 Flash | 200 / 209 |
   | P04 | Mistral Large 2 | 183 / 209 |

   Each answer is checked automatically: the quote must be in the comment, the theme and sub-theme must be a real
   pair, the sentiment score must match its label, and impact must be a whole number 1-5. A failed answer is asked
   once more. (Haiku fails mostly on sentiment scores that don't match the label; the key uses only its tags,
   labels and impact.)
2. **Votes are counted per tag:**
   - 3 or 4 models gave it (with average confidence 0.7 or more): **accepted**
   - 2 models gave it: **split**, a person decides
   - 1 model gave it: dropped
   - sentiment is accepted when 3 or more models agree
   - impact is accepted when 3 or more models gave one and all are within 1 point (e.g. 3, 3, 4, 4); the value is
     the middle rating. A wider spread (e.g. 2 and 5) goes to a person
3. **Result (`ANSWER_KEY`) straight after the panel:**
   - 72 comments `DECIDED_BY = panel`: every tag, the sentiment and the impact agreed
   - 137 comments `DECIDED_BY = needs_review`: sent to the review queue (all since decided by a person, step 4);
     70 of them because the panel's impact ratings were too far apart

## Step 4: Human review of undecided answers (GV_REVIEW app)

The panel can't settle every comment. A person decides the rest, so the answer key never rests on a 2-2 vote.

**Which comments come to you** (137 of 209, one `panel_split` row each in `REVIEW_QUEUE`), any of:
- a tag only 2 of the 4 models gave (a split)
- no tag that 3 or more models agreed on
- fewer than 3 models agreeing on the sentiment
- impact ratings more than 1 point apart

**What you see** (open in Snowsight: **Projects > Streamlit > GV_REVIEW**), one comment at a time:
1. the survey question and the comment
2. **Agreed by the panel:** tags 3 or more models gave (kept unless you remove them)
3. **Only 2 of 4 models chose these. Keep them?** one tick-box per split tag
4. **Sentiment:** pre-filled if 3 or more models agreed, otherwise you must choose
5. **Impact (1-5):** pre-filled if the panel agreed, otherwise you must choose (it shows what each model said)
6. **Edit tags:** add any other sub-theme, or remove an agreed one
7. a preview line of exactly what will be saved

Example (illustrative):
> Comment: *"Waited 4 hours for the ambulance but the crew were lovely."*
> Agreed: Timeliness of care. Split: Staff manner (2 of 4). Sentiment: no majority.
> You tick Staff manner, choose Negative, and approve.

**What Approve does:**
- `ANSWER_KEY`: tags, sentiment and impact replaced by your choice, `DECIDED_BY = human`, with `REVIEWED_BY` and
  `REVIEWED_AT` recorded
- `REVIEW_QUEUE`: the item becomes `done`, with your decision saved in `DECISION`
- the app checks the tags are real taxonomy pairs and a sentiment and impact are chosen before saving

**Skip** moves to the next comment without saving; skipped comments come back at the end.

**Safety:** `answer_key.sql` refuses to rebuild once any row is `human`, so your decisions are never overwritten.

**Comments not reviewed** would stay `needs_review` and be left out of the correctness score (which compares against
the answer key); groundedness and coherence don't use the key. Here all 137 were reviewed, so every score covers all
209 comments.

**Result:** all 137 reviewed. `ANSWER_KEY` is complete: 209 rows (72 `panel`, 137 `human`), every row with tags,
a sentiment and an impact.

**Later in the grid:** a tested model's answer that still fails the automatic checks after one retry is also
queued (`REASON = failed_check`), so a person can see why.

---

## Step 5: Test grid

Each setup tags the 209 sample comments 3 times (to check consistency), with `RUN_MODEL(setup, repeat)`. Each setup
runs on its own warehouse (`VOC_GV_C01`..`C08`) with its 3 repeats at the same time, so all 24 runs go in
parallel. Run ids look like `C04_r2`. Took about 15 minutes (Gemini 3.1 Pro was slowest).

| | Current prompt | Structured prompt |
|---|---|---|
| Mistral Large 3 | C01 (today's setup) | C05 |
| Claude Opus 5 | C02 | C06 |
| GPT-5.4 | C03 | C07 |
| Gemini 3.1 Pro | C04 | C08 |

**Valid answers** (passed the automatic checks, out of 209 per repeat):

| Setup | Repeat 1 | Repeat 2 | Repeat 3 | Still failing after retry (all repeats) |
|---|---|---|---|---|
| C01 Mistral / current | 176 | 173 | 170 | 108 |
| C02 Opus / current | 178 | 175 | 170 | 104 |
| C03 GPT-5.4 / current | 178 | 183 | 183 | 83 |
| C04 Gemini / current | 191 | 188 | 187 | 61 |
| C05 Mistral / structured | 180 | 177 | 181 | 89 |
| C06 Opus / structured | 206 | 208 | 206 | 7 |
| C07 GPT-5.4 / structured | 197 | 197 | 195 | 38 |
| C08 Gemini / structured | 209 | 208 | 209 | 1 |

"Valid" only means well-formed (real quote, real pair, consistent scores, impact 1-5), not correct; correctness is
the judge's job. The structured prompt makes every model's answers more valid; the champion C01 fails about 1 in 6.
The 491 answers still failing were queued as `failed_check` for optional review; the judge scores them anyway.

**Impact and consistency** (plain counts, no AI): every setup's impact is within 1 point of the answer key on
94-96% of comments (exact: 73% for C01, about 80% for the others). Same tags in all 3 repeats: 40% for C01 up to
73% for C06 and C08. Full table in `decision_report.md`.

---

## Step 6: Judge (`sql/judge.sql`, `notebook/judge_app.py`)

The judge, **Claude Sonnet 4.6** (`J01` in `MODELS`), scores every grid answer in **Snowflake Evaluations**
(Snowsight > AI & ML > Evaluations > `GV_TAGGER`), using Snowflake's TruLens build.

How: `JUDGE_RUN(setup, repeat, limit)` creates one TruLens run per grid run (e.g. `C04_r2`). It replays that run's
saved answers from `ANSWERS` (no model calls), then the judge scores each answer on:

| Score | Question | Scale | Uses the answer key? |
|---|---|---|---|
| correctness (built-in) | Does the answer match `ANSWER_KEY` (tags, sentiment, impact)? | 0-3 | Yes |
| tag_groundedness (ours) | Is each tag supported by the comment? (share of tags judged yes) | 0-1 | No |
| tag_coherence (ours) | Do the tags fit together: sentiment fits the quote, no contradictions, no duplicates? | 0-1 | No |

Efficiency: all judge prompts of a run go to the model in one parallel batch; the 24 runs run at the same time,
each on its setup's warehouse. Tested on 20 comments first (`*_test20` runs), then the full run took about 10
minutes. One run (C06_r2) stalled in the judge batch; it was cancelled, its run and events deleted, and re-judged.
Coverage: 627 scores per metric per setup (209 x 3); 4 correctness scores missing for C04, left out of the averages.

**Results** (average of the 3 repeats; correctness range across repeats in brackets):

| Setup | Correctness (0-3) | Groundedness | Coherence |
|---|---|---|---|
| C01 Mistral / current (champion) | 2.32 (2.32-2.33) | 0.63 | 0.62 |
| C02 Opus / current | 2.52 (2.50-2.54) | 0.75 | 0.75 |
| C03 GPT-5.4 / current | 2.52 (2.51-2.55) | 0.73 | 0.73 |
| C04 Gemini / current | **2.67** (2.65-2.67) | **0.84** | 0.84 |
| C05 Mistral / structured | 2.44 (2.42-2.47) | 0.69 | 0.70 |
| C06 Opus / structured | 2.58 (2.56-2.60) | 0.76 | 0.76 |
| C07 GPT-5.4 / structured | 2.60 (2.55-2.64) | 0.76 | 0.79 |
| C08 Gemini / structured | **2.65** (2.65-2.66) | **0.84** | **0.85** |

---

## Step 7: Decision report (`decision_report.md`)

**Recommendation: Gemini 3.1 Pro with the structured prompt (C08).** Joint top on correctness with C04, top on tag quality,
valid for all 209 comments (C04 still fails 61 answers), stable across repeats, about 3.9x today's cost per comment.
Cheaper alternative: GPT-5.4 with the structured prompt (C07), correctness 2.60 at about 1.5x today's cost, weaker tag quality.
Today's setup (C01) is last on every score.

The report also covers impact accuracy, consistency across repeats, real costs from usage history (this run cost
about 162 credits), limitations and next steps.

## Checks not done yet (options)

- **Answer-key audit:** the 72 rows the panel settled on its own were not checked by a person. A 30-row blind
  audit would measure how often the key is right.
- **Sub-theme F1:** correctness comes from the judge model (impact and consistency are already plain counts).
  Precision, recall and F1 of each answer's sub-themes against the answer key would add a plain, free, repeatable
  count for tags too.
- **Taxonomy order:** a trial with 2 shuffled taxonomy orders on the panel models changed their sub-themes on a
  third or more of comments, but rarely their impact. It was rolled back to keep this run simple and was not run on
  the 8 setups.

---

## Snowflake objects

| Kind | Name | Purpose |
|---|---|---|
| Table | `COMMENTS`, `TAXONOMY` | Raw data |
| Table | `SAMPLE_COMMENTS` | The 209 test comments |
| Table | `PROMPTS` | The 2 prompt texts (v2, with impact), with a SHA-256 fingerprint |
| Table | `MODELS` | Every model setup: id, role, model, prompt |
| View | `RULEBOOK` | Taxonomy text for prompts, the 33 valid pairs, the fixed answer format (tags + impact) |
| Table | `ANSWERS` | Every model answer, with its check result |
| Table | `ANSWER_KEY` | The correct tags, sentiment and impact per sample comment |
| Table | `REVIEW_QUEUE` | Items for a person: 137 `panel_split` (all done), 491 `failed_check` from the grid (optional, open) |
| Procedure | `RUN_MODEL(model_id, repeat)` | Runs one model over the sample, e.g. `CALL RUN_MODEL('P01', 1)` |
| Procedure | `JUDGE_RUN(model_id, repeat, limit)` | Judges one grid run in Snowflake Evaluations, e.g. `CALL JUDGE_RUN('C04', 2, 0)` |
| Function | `CHECK_ANSWER`, `NORM_QUOTE` | The automatic answer checks and quote matching |
| Streamlit | `GV_REVIEW` | Review app (answer-key splits) |
| Evaluations app | `GV_TAGGER` | The judge's runs and scores (created by TruLens); 24 full runs + 24 `*_test20` test runs |
| Stage | `DATA_STAGE` | Uploaded data, prompts, scripts and app files |

Warehouses: `VOC_GV_PANEL` (panel runs), `VOC_GV_C01`..`VOC_GV_C08` (one per grid setup), `DEMO_WH` (app).

## Files

| File | What it does |
|---|---|
| `decision_report.md` | Step 7: the results, recommendation and costs |
| `evaluation_approach.png` | One-page diagram for slides and calls: the data, the 5 steps (logic, how it ran in Snowflake, AI models used) and today vs. winner |
| `evaluation_approach.svg` | Editable source of the diagram (open in a browser, Figma or Illustrator) |
| `data/comments.csv`, `data/taxonomy.csv` | Raw data |
| `prompts/current_v2.txt`, `prompts/structured_v2.txt` | The two prompts being compared (with the impact rule) |
| `prompts/current_v1.txt`, `prompts/structured_v1.txt` | The first-run prompts (no impact), kept for the record |
| `sql/sample.sql` | Step 2: builds `SAMPLE_COMMENTS` |
| `sql/setup.sql` | Prompts, models, rulebook, checks, answers table, review queue, `RUN_MODEL` |
| `sql/answer_key.sql` | Step 3: builds `ANSWER_KEY` from the panel and queues disagreements |
| `sql/judge.sql` | Step 6: the `JUDGE_RUN` procedure |
| `notebook/judge_app.py` | Step 6: the TruLens app (replays answers) and the two custom judge metrics |
| `app/streamlit_app.py`, `app/environment.yml` | The GV_REVIEW app |
| `prep.py`, `make_label_map.py` | Earlier data-prep scripts (built `data/*.csv` from the NHS source files); kept for the record, not used by the current pipeline |
| `notebook/run_eval.py`, `notebook/gv_trulens.py` | Earlier laptop-based TruLens runner and app (before `judge.sql` / `judge_app.py`); kept for the record, not used now |
| `split.py`, `PLAN.md`, `rules.md` | Earlier sample split script, plan and labelling rules; kept for the record, not used now |
| `sql/00_admin.sql` .. `sql/07_sample.sql` | Earlier numbered SQL pipeline (before `setup.sql`, `sample.sql`, `answer_key.sql`, `judge.sql`); kept for the record, not used now |
| `judge_bundle/judge.ipynb`, `judge_bundle/requirements.txt` | Earlier notebook version of the judge; kept for the record, not used now |

## Rebuild from scratch

1. Upload `data/*.csv` to `@DATA_STAGE`, `prompts/*_v2.txt` to `@DATA_STAGE/prompts/`, `sql/*.sql` to `@DATA_STAGE/sql/`.
2. Create and load `COMMENTS` and `TAXONOMY` from the CSVs.
3. Run `sample.sql` (about 3 credits), then `setup.sql`.
4. Run the panel: `CALL RUN_MODEL('P01', 1)` .. `('P04', 1)` (in parallel, about 2 minutes).
5. Run `answer_key.sql`, then a person reviews the undecided comments in GV_REVIEW (step 4).
6. Grid: `CALL RUN_MODEL('C01', 1)` .. `('C08', 3)`, one task per setup on its own warehouse.
7. Upload `notebook/judge_app.py` to `@DATA_STAGE/notebook/`, run `judge.sql`, then `CALL JUDGE_RUN('C01', 1, 0)` ..
   `('C08', 3, 0)` (one task per run; try `limit = 20` first).
