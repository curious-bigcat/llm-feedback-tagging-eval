# Decision report: NHS feedback tagging (v3)

**Question:** which model and prompt should tag patient comments with the right themes, sub-themes, sentiment and
impact, instead of today's setup (Mistral Large 3 with the current prompt)?

**Recommendation: Gemini 3.1 Pro with the structured v3 prompt (C09).**
- It ties for the best tag accuracy (precision 0.75, F1 0.79) and is closest to the right number of tags (1.89 per
  comment; the key has 1.69).
- It has the best groundedness and coherence (0.85), passes the checks on 205 of 207 comments, and is the most
  consistent setup: it gives the same tags in all 3 runs for 83% of comments (today's setup: 39%).
- It costs about 4 times today's setup per comment (19.5 vs 5.1 credits per 1,000 comments).

**Two cheaper options:**
- **Quick win at today's cost: keep Mistral Large 3, switch to the v3 prompt (C10).** Tags per comment fall from
  2.9 to 2.2, precision rises from 0.51 to 0.65 and consistency from 39% to 58%, at the same cost (4.9 credits per
  1,000 comments).
- **Mid-price: GPT-5.4 with the v3 prompt (C11):** the same judge correctness as C09 (2.60) at a third of its cost
  (6.6 credits per 1,000), but it over-tags more (2.13 tags per comment, precision 0.67).

Date: 9 Nov 2026. All work ran in Snowflake (`VOC_EVAL.HARNESS`); details in `README.md`. This is the third run (v3):
a fresh, step-by-step rerun that adds plain-SQL tag-accuracy checks (precision, recall, F1, over-tagging) after an
aggregation trial showed that wrong tags distort the reports built from them.

---

## 1. How the test was run

1. **Sample:** 207 patient comments, at least 10 for each of the 33 sub-themes (Parking: 3, all the data has) and
   at least 17 for each impact level (1-5). Comments that copy a rulebook example, and 20% of people kept for
   prompt work, were left out first.
2. **Panel check:** 4 models from different makers tagged the sample. Before voting, each was checked for
   over-tagging (1.8-2.3 tags per comment, all under the 2.5 warning level).
3. **Answer key:** a tag was accepted when 3 or more models agreed, sentiment when 3 or more agreed, impact when all
   ratings were within 1 point. New: comments with 4 or more agreed tags went to a person too. 67 rows were settled
   by the panel and 140 by a person (in a 10-per-page review app). The key has **1.69 tags per comment**.
4. **Grid:** 4 models x 3 prompts = 12 setups, each tagging all 207 comments 3 times: 7,452 answers.
   - `current_v2`: today's prompt
   - `structured_v2`: the structured prompt template
   - `structured_v3`: `structured_v2` plus one rule against over-tagging ("tag a sub-theme only when the comment makes
     a clear point about it; most comments make 1-2 points", with an example)
5. **Scores:**

| Score | Meaning | How |
|---|---|---|
| Valid | Passes the automatic checks: real quote, real taxonomy pair, consistent scores, impact 1-5 | SQL, out of 207 |
| Precision | Of the tags given, the share that are in the answer key (low = over-tagging) | SQL |
| Recall | Of the key's tags, the share that were found (low = missing tags) | SQL |
| F1 | Precision and recall combined | SQL |
| Tags per comment | Compared with the key's 1.69 | SQL |
| Same tags in 3 repeats | Share of comments with the identical set of sub-themes in all 3 runs | SQL |
| Correctness | Judge: does the answer match the key (tags, sentiment, impact)? | Claude Sonnet 4.6, 0-3 |
| Groundedness | Judge: share of tags supported by the comment | Claude Sonnet 4.6, 0-1 |
| Coherence | Judge: share of tags that fit together (sentiment fits the quote, no duplicates or contradictions) | Claude Sonnet 4.6, 0-1 |

The judge is not one of the tested models. The plain-SQL scores need no AI and give the same result every time.

---

## 2. Results

Averages over 3 repeats (207 comments each), best first by F1.

| Setup | Model | Prompt | Valid | Precision | Recall | F1 | Tags / comment | Same tags 3x | Correctness | Grounded | Coherent | Credits / 1,000 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| C04 | Gemini 3.1 Pro | current | 188 | **0.75** | 0.86 | **0.80** | 1.94 | 72% | **2.64** | 0.83 | 0.84 | 20.5 |
| **C09** | **Gemini 3.1 Pro** | **v3** | **205** | **0.75** | 0.84 | 0.79 | **1.89** | **83%** | 2.60 | **0.85** | **0.85** | 19.5 |
| C08 | Gemini 3.1 Pro | v2 | **206** | 0.72 | 0.85 | 0.78 | 1.98 | 69% | 2.63 | 0.83 | 0.84 | 19.2 |
| C12 | Claude Opus 5 | v3 | 203 | 0.66 | 0.87 | 0.75 | 2.23 | 77% | 2.55 | 0.78 | 0.78 | 25.3 |
| C11 | GPT-5.4 | v3 | 195 | 0.67 | 0.84 | 0.74 | 2.13 | 68% | 2.60 | 0.78 | 0.78 | 6.6 |
| C10 | Mistral Large 3 | v3 | 185 | 0.65 | 0.85 | 0.74 | 2.21 | 58% | 2.50 | 0.70 | 0.73 | 4.9 |
| C06 | Claude Opus 5 | v2 | 205 | 0.61 | 0.90 | 0.73 | 2.46 | 73% | 2.56 | 0.76 | 0.75 | 25.5 |
| C03 | GPT-5.4 | current | 183 | 0.61 | 0.90 | 0.72 | 2.48 | 61% | 2.57 | 0.72 | 0.72 | 6.8 |
| C02 | Claude Opus 5 | current | 173 | 0.60 | 0.90 | 0.72 | 2.52 | 69% | 2.51 | 0.75 | 0.73 | 30.0 |
| C07 | GPT-5.4 | v2 | 194 | 0.63 | 0.85 | 0.72 | 2.29 | 63% | 2.59 | 0.76 | 0.76 | 6.5 |
| C05 | Mistral Large 3 | v2 | 179 | 0.58 | 0.88 | 0.70 | 2.56 | 45% | 2.47 | 0.68 | 0.69 | 5.0 |
| C01 | Mistral Large 3 | current (today) | 170 | 0.51 | 0.89 | 0.65 | 2.92 | 39% | 2.35 | 0.63 | 0.60 | 5.1 |

**Stability:** every setup's F1 moves by at most 0.01 and correctness by at most 0.08 between repeats, so the gaps
between setups are real.

**Impact:** every setup gives exactly the key's impact on 71-81% of comments; today's setup is lowest (71%).

## 3. What the results say

1. **Today's setup over-tags.** It finds most of the right tags (recall 0.89) but adds many wrong ones: 2.9 tags per
   comment where the key has 1.7, so only about half of its tags are right (precision 0.51). It is last on every
   score and gives the same tags in all 3 runs for only 39% of comments - the "different answers for the same
   comment" problem.
2. **The two kinds of score agree.** The order by F1 (plain SQL) is close to the order by the judge's correctness,
   groundedness and coherence: Gemini first, today's setup last.
3. **Gemini 3.1 Pro is the best model** with every prompt, and the only one close to the key's number of tags.
4. **The v3 rule against over-tagging works on every model.** With v3, each model has its fewest tags, best
   precision and highest consistency, for a recall cost of 0.01-0.03. It helps weaker models most (Mistral: precision
   0.51 -> 0.65). Dropping low-confidence tags instead does not work: the models are confident even about wrong tags.
5. **C09 vs C04 and C08 (all Gemini):** C04 scores slightly higher on judge correctness (2.64 vs 2.60) but fails the
   checks on 19 comments; C08 is as valid as C09 but less precise and less consistent. C09 is the best balance:
   top precision, top groundedness and coherence, near-full validity and by far the most consistent.
6. **Claude Opus 5 is the most expensive and not the most accurate,** so it is not recommended.

**Pass criteria** (proposed before the run: precision 0.70 or more, at most 2.2 tags per comment, valid 95% or
more): only **C08 (precision 0.72)** and **C09** pass all three; C04 passes accuracy but is 91% valid.

## 4. Cost

Real Snowflake credits from usage history, split per setup by each run's token counts.

| Setup | Credits for this test (207 x 3) | Credits per 1,000 comments | Relative to today |
|---|---|---|---|
| C01 Mistral / current (today) | 3.2 | 5.1 | 1x |
| C10 Mistral / v3 | 3.0 | 4.9 | 1x |
| C11 GPT-5.4 / v3 | 4.1 | 6.6 | 1.3x |
| C09 Gemini / v3 | 12.1 | 19.5 | 3.8x |
| C12 Opus / v3 | 15.7 | 25.3 | 5.0x |

For scale: tagging all 6,211 comments once would cost about 121 credits with C09, 41 with C11 and 30 with C10.

**What this run cost:**

| Part | Credits |
|---|---|
| Pre-tag for sampling (Llama 3.3) | 3.2 |
| Panel (4 small models) | 6.5 |
| Grid (12 setups x 3 repeats) | 108.7 |
| Judge (Claude Sonnet 4.6 106.4 incl. the 20-comment test; Llama 3.1 2.1, the built-in correctness scorer) | 108.5 |
| **Total** | **about 227** |

Usage history fills in with a delay of up to a few hours, so the last hour's figures may rise slightly.

---

## 5. Limitations

- **The answer key leans towards finding every point.** The reviewer mostly added the 2-of-4 suggestions (26
  comments) and removed tags on 1. A stricter key would lower everyone's recall and raise their precision; the
  ranking is unlikely to change, since every setup is scored against the same key.
- **The key is checked only where the panel disagreed.** The 67 panel-settled rows were not audited. Option: a
  30-row blind audit.
- **Over-tagging is reduced, not solved.** Even the best setup adds an extra tag on about 1 in 4 comments.
- **Small sample for rare sub-themes.** Most have 10-20 comments; Parking has 3. Per-sub-theme results
  (`TAG_SCORES_BY_SUBTHEME`) are indicative only.
- **One judge model.** Claude Sonnet 4.6 is from the same maker as Claude Opus 5; Opus did not score unusually well,
  so no favouritism is visible.
- **Prompt v3 was written after seeing v2's over-tagging.** It was tested on the same sample; a check on fresh
  comments would confirm it generalises.

## 6. Next steps

1. **Decide:** C09 (best quality and consistency), C11 (lower cost) or C10 (prompt-only change at today's cost).
2. **Quick win either way:** move today's setup to the v3 prompt; it is a prompt change only.
3. Fresh-comment check: done (step 10a, the winner holds on 100 new comments). Answer-key audit: queued (step 10b).
4. Put the winner into production with the same answer format and checks, failed answers to the review queue, and a
   monthly check of about 30 new comments with the same precision/recall/F1 views.
