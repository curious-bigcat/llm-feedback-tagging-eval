# Plan: Testing AI theme-tagging on NHS patient feedback (raw-data path)

## What we are doing
The goal is to choose the best AI model and prompt for a feedback-tagging tool that reads customer feedback and tags each comment with **themes**, **sub-themes**, a **sentiment** and a **supporting quote**.

The evaluation method prescribes:
1. A **trusted answer key**. Where none exists, it's built by a **4-model labelling panel**, and a **human review screen** handles cases the panel can't settle.
2. A **fixed answer format**, with every answer checked automatically.
3. Every **model × prompt** combination, **3 times each**, tracked in **Snowflake AI Observability (TruLens)**.
4. An **AI judge** from a different model family that scores correctness, groundedness and coherence, and compares the winner with the current setup.
5. **Pass/fail rules agreed before** looking at the results.

We use **public NHS data** instead of any customer's real data, run in our own Snowflake account.

**We treat the data as raw:**
- The NHS expert tags were **deleted permanently**: from the CSV, from the table (Time Travel off), and from the stage.
- That mirrors a customer who only has raw comments.
- **The answer key is built by the panel plus human review.**

---

## The data we start with (`nhs_eval/data/`)
NHS England **"Friends and Family Test"** feedback: short comments patients wrote after using an NHS service.

### `comments.csv`: 6,211 comments
| Column | What it holds |
|---|---|
| `COMMENT_ID` | Unique id of the comment |
| `RESPONDENT_ID` | The person who wrote it (one person can answer 2–3 questions) |
| `TRUST`, `SERVICE`, `SUB_SERVICE` | Which NHS organisation and service |
| `DATE_RAW` | Date as given (formats vary; not used for scoring) |
| `QUESTION` | The survey question answered (e.g. "what was good", "what could be improved") |
| `COMMENT_TEXT` | What the patient wrote: **the only text the AI sees** |
| `PATIENT_RATING` | The patient's own rating: context only, never scored |
| `LEAKED_QUOTE` | Filled in if the comment contains a rulebook example quote (64 comments) |
| `PILE` | `TEST` (4,873 comments) or `PRACTICE` (1,338). Each person is in one pile only. These are the doc's `EVAL` and `DEV` |
| `IN_SAMPLE` | `True` for the **404 TEST comments we score** |

### `taxonomy.csv`: the rulebook
**10 themes, 33 sub-themes**, each with a definition and example quotes. It is sent to the AI with every comment. The AI may only choose names from this list.

### Built-in safeguards
- **PRACTICE** is for prompt examples and trial runs. **TEST** is only for scoring.
- A person never appears in both piles.
- All 64 "leaked" comments are in PRACTICE.
- `PILE` and `IN_SAMPLE` were chosen **before** the expert tags were deleted, so the sample is balanced by theme. With truly raw data you'd pick the sample at random; this doesn't reveal any answers to the models.

---

## Scoring rules (agreed)
- **Sentiment:** one scale from −1 to +1. Positive must be above 0, Negative below 0, Neutral exactly 0.
- **Counting:** a comment counts once per sub-theme.
- **Quotes:** must be short, word-for-word extracts from the comment.
- **Correctness:** against the **answer key**. Full marks for the exact theme + sub-theme; half marks for the right theme with the wrong sub-theme; zero for a wrong theme.
- **Patient's own rating:** never scored.

---

## The 8 steps
Each step is explained and approved before it runs.

### Step 1: Workspace, access, data and settings (doc Step 2), DONE
- **Workspace and access:**
  - `VOC_EVAL.HARNESS`, role `VOC_EVAL_ROLE`
  - the role has `SNOWFLAKE.CORTEX_USER`, `USE AI FUNCTIONS` and `EXECUTE TASK`, and owns the schema, so it can create External Agents and tasks there
- **Data:** `COMMENTS` and `TAXONOMY`, plus **one checks query** (`sql/02_checks.sql`, 10 checks, all 0 problems). One check confirms no expert-answer columns remain.
- **Settings table `V1_MODEL_CONFIG`:** one row per setup.

| Config | Model | Prompt | Role |
|---|---|---|---|
| C01 | Mistral Large 3 (Mistral's newest available here) | current | champion (baseline) |
| C02–C04 | Claude Opus 5 / GPT-5.4 / Gemini 3.1 Pro (each company's top generally available model) | current | challenger |
| C05–C08 | the same 4 models | structured | challenger |
| P01–P04 | Claude Haiku 4.5 / GPT-5.4 mini / Gemini 3.1 Flash-Lite / Mistral Large 2 (different versions from the grid) | current | panel |
| J01 | Grok 4.7 (xAI) | — | judge |

Why these models:
- Each company's top generally available model that works with the fixed answer format.
- Preview models were skipped, because they can change between repeats.
- OpenAI's GPT-6 and 5.6 models were skipped: they return empty answers with the fixed format.

### Step 2: Prompts, answer format and checks (doc Step 4), DONE
- **Two locked prompts** in the `PROMPTS` table:
  - `current_v1`: simple, like a typical first version
  - `structured_v1`: the six-part structure (task, input, rules, output, safety line, final check)
- **Shared building blocks**, used by both the SQL procedure and TruLens (`sql/03_shared.sql`):
  - `V1_RULEBOOK`: rulebook text, allowed pairs and the fixed answer format, all from `TAXONOMY`
  - `V1_COMMENT_SETS`: which comments each job uses (SAMPLE 404, TRIAL 20)
  - `V1_REQUESTS`: the exact text sent to the model
  - `CHECK_ANSWER`: the SQL check. It flags a bad theme/sub-theme pair, a quote not in the comment, a score that doesn't match its label, confidence outside 0–1, or a repeated sub-theme
- **Procedure `RUN_CLASSIFY(setup, set, repeat)`** (`sql/04_classify.sql`):
  - sends all calls together and checks every answer
  - retries failures once; second failures go to `REVIEW_QUEUE`
  - saves to `RESULTS` and logs to `RUN_LOG`
- **Smoke test passed:** P04 on 20 TRIAL comments. 20 of 20 answered; 19 passed; 1 repeated sub-theme was caught, retried and queued for review.

### Step 3: Build the answer key with the panel (doc Step 3)
- **The 4 panel models** each label the **404 SAMPLE comments**, using `current_v1` with temperature 0: about 1,600 calls on small models.
- **Combining their answers, per comment** (in SQL, no extra AI calls):
  - **Accepted (`panel_consensus`):** a sub-theme tagged by **3 or 4 of the 4** models, with average confidence of at least 0.7.
  - **Split:** a sub-theme tagged by **exactly 2** models, or a consensus tag with low confidence. The whole comment goes to the review screen.
  - **Dropped:** a sub-theme tagged by only 1 model.
  - **Sentiment:** the majority overall label across the 4 models. A 2–2 tie goes to review.
- **Result:** table `ANSWER_KEY`, one row per comment:
  - the tags and sentiment
  - `SOURCE`: `panel_consensus` or `human_reviewed`
  - the taxonomy version
  - once final, it's never changed, as the doc requires

### Step 4: Human review screen (doc Steps 3–5)
A small **Streamlit in Snowflake** app with one queue and **accept, fix or reject** for each case:
- **Panel splits** (Step 3): **you decide the tags.** These become `human_reviewed` in `ANSWER_KEY`.
- **Answers that failed the check twice** (Steps 2 and 6).
- **Cases the judge marks "answer key may be wrong"** (Step 7).

Every decision is saved with who made it and when. **The answer key is final only once all panel splits are reviewed.**

### Step 5: Register the classifier in AI Observability and run the trial (doc Steps 2 and 5)
- **Python environment:** TruLens 2.16 is installed in `nhs_eval/.venv` (`trulens-core`, `trulens-connectors-snowflake`, `trulens-providers-cortex`).
- **The app `V1_FIRST_PASS`:** our classifier wrapped with TruLens, with three traced steps:
  1. **get context:** the comment text, marked as the "retrieval" step so groundedness is checked against it
  2. **call model:** reads from `V1_REQUESTS`, so it sends the same prompt and answer format as `RUN_CLASSIFY`
  3. **check:** runs `CHECK_ANSWER`, retries once, and saves to `RESULTS` with `SOURCE = 'TRULENS'`
- **Registration:** this creates the External Agent `V1_FIRST_PASS`. Each setup is a version, e.g. `mistral-large3__current_v1`.
- **Trial:** each setup on the 20 TRIAL comments (PRACTICE pile), to check answers come back complete. There's no answer key for TRIAL, so the trial is judged on groundedness, coherence and the SQL checks only.

### Step 6: Run the test (doc Step 5)
- **Cost first:** measure the real size of each request and estimate the total, including the judge's calls. **You choose the grid size** before anything runs. For example:
  - full: 4 models × 2 prompts × 3 repeats × 404 comments = about 9,700 classifier calls, plus the judge's calls
  - smaller: fewer models or comments
- **The run:**
  - every setup runs as an AI Observability run on SAMPLE
  - temperature 0; every setting is logged
  - Mistral + current prompt is the baseline
  - ground truth = `ANSWER_KEY`
- **Scores, saved side by side:**

| Score | From | Plain meaning |
|---|---|---|
| **Correctness** | Judge (built-in) **and** exact SQL vs `ANSWER_KEY` | How well the tags match the answer key |
| **Tag groundedness** | Judge (our own metric) **and** SQL quote check | Is each tag's quote in the comment, and does the comment support that sub-theme? |
| **Tag coherence** | Judge (our own metric) | Does each sentiment fit its quote; no contradicting or duplicate tags? |
| **Sentiment accuracy** | SQL | Does the sentiment match the answer key? |
| **Stability** | SQL | How much results change across the 3 repeats |
| **Valid-answer rate** | SQL | How often answers pass the automatic checks |
| **Cost and speed** | AI Observability | Tokens and time per request |

- **Scored rows:** the 305 final `ANSWER_KEY` rows (275 `panel_consensus` + 30 `human_reviewed`). The 99 still `needs_review` are left out of scoring (kept open for the demo).
- **Why our own metrics:** the built-in groundedness and coherence were tested in the trial and marked correct short answers as 0 (they are built for chatbot answers, and judged the comment rather than the tagging). Our two metrics ask the judge for a yes/no per tag, with reasons. The judge sees the survey question, the comment, the tags and the definitions of the tagged sub-themes, so it marks by the same rulebook the model had.
- **Checking the judge:** the doc's 70% judge-vs-SQL check was **dropped** at your request (no SQL-based scoring). The report says the judge was not cross-checked; the answer-key check in Step 7 partly covers this.
- **The judge: GLM-5.3 (Zhipu)**, `GLM-5.3`, switched from Grok 4.7 on 7 Nov 2026.
  - It comes from a company that isn't in the grid.
  - The same judge is used for every setup in the test (all 8 runs re-judged with GLM).
  - **Why the switch:** Grok 4.7 (preview) slowed to ~200–300 s per call, which would have taken days. GLM took ~15 s.
  - **Check before switching:** on 35 grid answers both judges scored, GLM gave the **same groundedness score on 31 (89%)**, averages 0.841 vs Grok's 0.831, correlation 0.88. Judge failures (empty replies, retried 3 times) were under 1%.
  - GLM's known weakness is occasional empty replies. Those show up as "judge failed" and are re-judged at the end, not counted as 0.
- **Cost note:** Opus 5 and Gemini 3.1 Pro are among the most expensive models.

### Step 7: Disagreements and decision report (doc Step 5)

**Answer-key check (rules fixed on 7 Nov 2026, before the grid results were read).** The answer key was built by small models, and only its panel splits were checked by a person. These rules measure how good it is, without letting the tested models decide the truth:
1. **Freeze key v1.** Before any change, the current `ANSWER_KEY` is copied as-is to `ANSWER_KEY_V1`. Every setup is scored against v1 first.
2. **Flag rule**, applied the same way to every one of the 305 final rows:
   - **Missed tag:** a sub-theme that is **not** in the key, but that **at least 6 of the 8 setups** (C01–C08, valid answers only) tagged, **and** that the judge's `tag_groundedness` verdict marked "yes" in most of those answers.
   - **Doubtful key tag:** a sub-theme that **is** in the key, but that **none of the 8 setups** tagged.
3. **Random audit:** 30 further `panel_consensus` rows that were not flagged, picked with a fixed seed (lowest `SHA2('nhs_eval_v1|audit|' \|\| COMMENT_ID)`), so the key's error rate is measured on rows nobody chose.
4. **Blind review:** flagged and audit rows go to `REVIEW_QUEUE` (reason `answer_key_check`). The review screen shows the question, the comment, the key's tags and the candidate tags, **without** saying which model suggested what or how many did.
5. **Key v2 = v1 + your decisions only.** A model never changes the key by itself. Changed rows become `human_reviewed`.
6. **Report both:** correctness against v1 **and** v2, plus the **key error rate** = share of the 30 audit rows you changed (a small sample, so stated with that caveat). A winner must win under **both** versions.

Only correctness depends on the key, so moving to v2 re-scores correctness only; tag groundedness and coherence don't change.

**Disagreements:** where the best setup and the baseline disagree, the judge marks each case:
  - *new better*
  - *current better*
  - *both wrong*
  - *answer key may be wrong* (these go to the review screen)

  The judge sees the two answers in random order, and in both orders.
- **Decision report (`decision_report.md`):**
  - the score table for every setup, with PASS or FAIL and reasons
  - results by service and by survey question
  - whether the gain came from the model or the prompt
  - answer-key make-up: how much is `panel_consensus` vs `human_reviewed`
  - the judge-vs-SQL agreement rate
  - example comments where the winner and the baseline disagree

**Pass/fail rules**, set before the test (from the doc). A new setup beats the baseline only if:
- correctness is higher on average, and not lower in any single repeat
- tag groundedness is at least 0.90
- tag coherence is no worse
- results vary no more than the baseline's
- **it also wins on the `human_reviewed` comments alone**
- no service or survey question scores worse
- cost is within a limit you agree before the run

### Step 8: Known limits of the raw-data path (written into the report)
- **The panel can be confidently wrong together.** We can't check that without expert labels, because those were deleted on purpose. Only the `human_reviewed` comments are checked by a person.
- **Shared habits:** the panel and the grid models come from the same 4 companies, though at different versions and sizes. That's why the winner must also win on `human_reviewed` comments.

---

## Skipped
- Doc Step 6: replay on last month's data, approval, go-live and one-week monitoring.
- After-go-live improvements: shorter rulebook, yearly reports, prompt trimming.

The decision report is the end point.

---

## What gets created
**Local (`nhs_eval/`):**
- `sql/`:
  - `01_setup.sql`
  - `02_checks.sql`
  - `03_shared.sql`
  - `04_classify.sql`
  - `05_answer_key.sql`
  - scoring and report scripts to come
- `prompts/`: `current_v1.txt`, `structured_v1.txt`
- `notebook/`: `v1_trulens.py` (the TruLens app and our two judge metrics) and `run_eval.py` (registers the app, runs one setup, computes metrics)
- `app/`: the Streamlit review screen
- `decision_report.md`: the final result

**Snowflake (`VOC_EVAL.HARNESS`):**
- **tables:**
  - `COMMENTS`, `TAXONOMY`, `V1_MODEL_CONFIG`, `PROMPTS`
  - `RESULTS`: every AI answer (panel, trial and grid)
  - `RUN_LOG`
  - `REVIEW_QUEUE`
  - `ANSWER_KEY`
- **views:** `V1_RULEBOOK`, `V1_COMMENT_SETS`, `V1_REQUESTS`
- **function:** `CHECK_ANSWER`
- **procedure:** `RUN_CLASSIFY`
- **AI Observability:** app `V1_FIRST_PASS` and its runs
- **Streamlit:** the review screen

## Current status
- **Steps 1–2 done:**
  - the workspace, data, settings, locked prompts, shared views, check function and procedure are built
  - the smoke test passed
- **Expert tags deleted permanently**; checks confirm none remain.
- **Review queue:** 1 open item (from the smoke test), kept for testing the review screen.
- **Next:** Step 3, the panel builds the answer key on the 404 SAMPLE comments (about 1,600 small-model calls), waiting for your approval.
