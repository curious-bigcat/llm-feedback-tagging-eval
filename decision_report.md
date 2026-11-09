# Decision report: NHS feedback tagging

**Question:** which model and prompt should tag patient comments with the right themes, sub-themes, sentiment and
impact, instead of today's setup (Mistral Large 3 with the current prompt)?

**Recommendation: switch to Gemini 3.1 Pro with the structured prompt (C08).** It is joint top on correctness, top on tag
quality, gives a valid answer for every comment (209 of 209) and is the most stable across repeats. It costs about
4 times as much as today's setup per comment. If cost matters most, **GPT-5.4 with the structured prompt (C07)** is close
behind on correctness (2.60 vs 2.65) at about 40% of C08's cost, with weaker tag quality.

Date: 8 Nov 2026. All work ran in Snowflake (`VOC_EVAL.HARNESS`); details in `README.md`. This is the second run
(v2): it adds an **impact rating (1-5)** for every comment. The first run (v1, no impact) gave the same
recommendation.

---

## 1. How the test was run

1. **Sample:** 209 patient comments with at least 10 for each of the 33 sub-themes (Parking: 3, all the data has)
   and at least 10 for each impact level. Comments that copy a rulebook example, and 20% of people kept for prompt
   work, were left out first.
2. **Answer key:** 4 models from different makers tagged the sample. A tag was accepted when 3 or more agreed;
   sentiment when 3 or more agreed; impact when all ratings were within 1 point (value = the middle rating).
   The 137 comments where they disagreed were decided by a person. Result: 72 panel-settled + 137 human-decided.
3. **Grid:** 8 setups (4 models x 2 prompts), each tagging all 209 comments 3 times: 5,016 answers.
4. **Judge:** Claude Sonnet 4.6 scored every answer in Snowflake Evaluations (app `GV_TAGGER`):

| Score | Meaning | Scale |
|---|---|---|
| Valid | Passes the automatic checks: real quote, real theme/sub-theme pair, consistent scores, impact 1-5 | out of 209 |
| Correctness | Matches the answer key (tags, sentiment and impact) | 0-3 |
| Groundedness | Share of tags supported by the comment | 0-1 |
| Coherence | Share of tags that fit together (sentiment fits the quote, no contradictions or duplicates) | 0-1 |
| Impact exact / within 1 | The setup's impact equals / is within 1 point of the answer key (plain count, no AI) | % |
| Same tags in 3 repeats | Share of comments with the identical set of sub-themes in all 3 repeats (plain count) | % |

The judge is not one of the 8 tested models.

---

## 2. Results

Averages over the 3 repeats (209 comments each).

| Setup | Model | Prompt | Valid (of 209) | Correctness | Groundedness | Coherence | Credits / 1,000 comments |
|---|---|---|---|---|---|---|---|
| C01 (today) | Mistral Large 3 | current | 173 | 2.32 | 0.63 | 0.62 | 5.2 |
| C02 | Claude Opus 5 | current | 174 | 2.52 | 0.75 | 0.75 | 31.4 |
| C03 | GPT-5.4 | current | 181 | 2.52 | 0.73 | 0.73 | 8.4 |
| C04 | Gemini 3.1 Pro | current | 189 | **2.67** | **0.84** | 0.84 | 20.8 |
| C05 | Mistral Large 3 | structured | 179 | 2.44 | 0.69 | 0.70 | 5.0 |
| C06 | Claude Opus 5 | structured | 207 | 2.58 | 0.76 | 0.76 | 25.9 |
| C07 | GPT-5.4 | structured | 196 | 2.60 | 0.76 | 0.79 | 7.9 |
| **C08** | **Gemini 3.1 Pro** | **structured** | **209** | **2.65** | **0.84** | **0.85** | 20.1 |

**Impact and consistency** (plain counts against the answer key and across repeats, no AI):

| Setup | Impact exact | Impact within 1 | Same impact in 3 repeats | Same tags in 3 repeats |
|---|---|---|---|---|
| C01 (today) | 73% | 94% | 86% | 40% |
| C02 | 80% | 95% | 94% | 68% |
| C03 | 81% | 95% | 85% | 54% |
| C04 | 80% | 95% | 89% | 70% |
| C05 | 75% | 94% | 86% | 47% |
| C06 | 80% | 95% | 94% | 73% |
| C07 | 79% | 96% | 88% | 65% |
| C08 | 80% | 95% | 87% | 73% |

**Stability of correctness across the 3 repeats:** every setup stays within 0.09 (C01 2.32-2.33, C04 2.65-2.67,
C07 2.55-2.64, C08 2.65-2.66), so the gaps between setups are real, not chance.

## 3. What the results say

1. **Today's setup is the weakest.** C01 is last on correctness, groundedness, coherence and impact, and gives the
   same tags in all 3 repeats for only 40% of comments: the "different output for the same comment" problem
   seen in production.
2. **Gemini 3.1 Pro is the best model.** With either prompt it leads on correctness, groundedness and coherence.
3. **The structured prompt helps.** It makes answers more valid (Opus 174 -> 207, Gemini 189 -> 209, GPT-5.4 181 -> 196)
   and lifts correctness for every model except Gemini, where C04 and C08 tie (2.67 vs 2.65, within repeat spread).
   C08 is chosen over C04 because it never fails the checks (C04 still fails 61 answers after the retry).
4. **Impact is the easy part.** Every setup is within 1 point of the answer key on 94-96% of comments; the
   strongest models agree exactly about 80% of the time. Today's setup is lowest at 73%.
5. **Claude Opus 5 is the most expensive and not the most accurate,** so it is not recommended.

## 4. Cost

Real Snowflake credits from usage history, split per setup by each run's token counts.

| Setup | Credits for this test (209 x 3) | Credits per 1,000 comments | Relative to today |
|---|---|---|---|
| C01 Mistral / current (today) | 3.3 | 5.2 | 1x |
| C07 GPT-5.4 / structured | 4.9 | 7.9 | 1.5x |
| C08 Gemini / structured | 12.6 | 20.1 | 3.9x |
| C06 Opus / structured | 16.2 | 25.9 | 5.0x |

For scale: tagging all 6,211 comments once would cost about 125 credits with C08, 49 with C07 and 32 with C01.

**What this run cost** (since the fresh start):

| Part | Credits |
|---|---|
| Pre-tag for sampling (Llama 3.3; run twice, the sample was rebuilt once to balance impact) | 6.2 |
| Panel / answer key (4 small models; includes two earlier rounds that were discarded) | 6.9 |
| Grid (8 setups x 3 repeats) | 78.1 |
| Judge (Sonnet 4.6 69.8, including the 20-comment test and one re-run; Llama 3.1 1.5, the built-in correctness scorer) | 71.2 |
| **Total** | **about 162** |

Usage history fills in with a delay of up to a few hours, so the last hour's figures may rise slightly.

---

## 5. Limitations

- **The answer key is checked only where the panel disagreed.** The 72 rows the panel settled were not audited.
  Correctness is relative to that key, so all setups share any error in it. Option: a 30-row blind audit.
- **Impact is a judgement call.** The panel models often disagreed on impact (a third of comments were 2 or more
  points apart), so 70 of the 137 reviewed comments needed a person to set impact. The 1-5 definitions could be
  tightened with the business's own examples.
- **Few serious cases.** Only about 10 comments in the key are impact 5 (harm or safety); results on that level
  rest on few examples.
- **No sub-theme F1 yet.** Correctness comes from the judge model; impact and consistency are plain counts.
  Precision, recall and F1 of sub-themes against the key would add a plain count for tags too.
- **Small sample for rare sub-themes.** Most sub-themes have 10-20 comments; Parking has 3.
- **One judge model.** Claude Sonnet 4.6 is from the same maker as Claude Opus 5 (C02, C06); Opus did not score
  unusually well, so no favouritism is visible.
- **One taxonomy order.** The taxonomy was always given in its own order. A shuffled-order trial on the panel
  models changed their sub-themes on a third or more of comments but rarely their impact; this was not tested
  on the 8 setups.
- **Prompt not tuned.** Both prompts were used as given (plus the impact rule); no prompt was improved during the test.

## 6. Next steps

1. **Decide:** C08 (best quality, most reliable) or C07 (close on correctness, lower cost).
2. Optionally tighten the impact definitions with the business and run the 30-row answer-key audit and the F1 score.
3. Put the winner into production: batch tagging with the same answer format and automatic checks, with answers that
   still fail after one retry sent to the review queue, and a monthly check of about 30 random new comments.
