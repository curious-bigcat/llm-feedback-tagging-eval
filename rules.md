# Business rules: rules_v1

**Status:** agreed 6 Nov 2026. Every score in this evaluation depends on these rules. Change them only by creating `rules_v2`, never by editing v1.
**Equivalent to:** Step 1 of the evaluation method.

## Sources (pinned in `source/SOURCES.txt`)
- `source/v6framework_230831.csv`: 7,908 NHS Friends and Family Test comments with human labels (v6 framework, 50 label columns).
- `source/framework3.qmd`: published framework, final version Oct 2023: 10 themes, 33 sub-themes, with definitions and example quotes.
- `source/params.py`: the project's official theme to sub-theme mapping (`major_cat_dict`).

## Rule 1: Label conversion, v6 to v7 (`label_map.csv`, built by `make_label_map.py`)
| Map type | Count | Rule |
|---|---|---|
| `same_name` | 30 | The v6 label exists unchanged in v7 |
| `merge` | 10 | The v6 label is part of a broader v7 sub-theme, as stated in that sub-theme's published definition |
| `fallback` | 7 | No documented v7 home, so it becomes **General / Not assigned** |
| `no_data` | 3 | No comment carries the label, and it isn't in v7, so it isn't used |

**Merges:**
- **Staffing levels & responsiveness:** Number & deployment of staff, Staff responsiveness.
- **Continuity of care:** Diagnosis & triage, Referrals & continuity of care, Staff continuity, Care plans, Patient records.
- **Environment, facilities & equipment:** Environment & Facilities, Provision of medical equipment.
- **Timeliness of care:** Existence of services (0 comments).

**Fallbacks:** Impact of treatment/care, Negative experience & dissatisfaction, Equality Diversity & Inclusion, Admission, Patient appearance & grooming, Safeguarding concerns, Learning organisation.

**Effect on the 6,217 usable comments:**
- Every comment keeps at least one label. On average there are 1.38 per comment, and 27.3% of comments have more than one (up to 7).
- 30 duplicate labels were collapsed, where two v6 labels merged into the same v7 sub-theme.
- 398 comments touched a fallback label. For 197 of them, `Not assigned` is now their **only** label.
- **Known effect:** `Not assigned` grows to **758 comments**, the second-largest sub-theme after Positive experience (1,775). It becomes a large mixed category, as a generic "Other" fallback would. Results are reported with and without it.
- Thin sub-themes: `Parking` (1 comment) is reported separately; `Labelling not possible` has no comments.

## Rule 2: Sentiment
- **Scale:** −1 to +1, with 0 neutral.
- **Answer key (labeller sentiment 1–5):** 1–2 = Positive, 3 = Neutral (includes mixed), 4–5 = Negative. Comments without a sentiment are excluded from sentiment scoring only.
- **Model output:** a sentiment label and score per theme. A comment's sentiment is the sign of the mean of its theme scores: above 0.2 = Positive, below −0.2 = Negative, otherwise Neutral.
- **Consistency check:** Positive needs a score above 0, Negative below 0, and Neutral between −0.2 and 0.2. A mismatch is retried once, then sent to review; the rate is reported for each setup.
  - Motivation: in the Step 0 test, 3 of 4 models labelled a theme Negative with a positive score.

## Rule 3: Counting
A comment counts **once per sub-theme**. A comment with 4 sub-themes is 1 comment in volume counts and adds 1 to each of its 4 sub-themes.

## Rule 4: Quotes
Each theme needs a short, word-for-word extract (25 words or fewer) from the comment. The key has no quotes, so quotes are scored as **groundedness**: the share that appear exactly in the comment (case and whitespace ignored).

## Rule 5: Patient rating
`FFT categorical answer` (1–5, plus undocumented codes 6 and 7) is descriptive context only and is never scored. Labels and sentiment follow the comment text.

## Data handling (applies to every later step)
- **Usable comments:** the comment is not blank (including whitespace-only) and isn't "Did not answer" or "Not answered". That leaves **6,211**.
- **Splits are grouped by respondent:** 2,039 people answered 2–3 questions, and one person never appears in both DEV and EVAL.
- **Prompt leakage:** 64 comments containing a framework example quote (15 characters or more, straight or curly quote marks) word for word are kept out of EVAL.
- **Dates:** NEAS mixes formats. Zero-padded values are read as `dd/mm/yyyy` (5,973). An unpadded first part, or a second part above 12, means `m/dd/yyyy` (238). All 6,211 dates parse.
  - **Known limitation (accepted, option B):** in the **See and Convey** service (1,391 comments), formats are mixed comment by comment.
    - 624 of its dates have both parts at 12 or below, so they can't be read with certainty and are read as day-first.
    - Evidence: all 152 respondents whose answers carry different dates show mirrored day/month values (for example `04/12/2022` and `12/04/2022` on the same survey).
    - Every other service is consistently day-first.
    - Effect: EVAL scoring doesn't use dates, so it's unaffected. **121 of the 383 REPLAY comments have uncertain dates**, so part of REPLAY may come from earlier than September 2022. Treat REPLAY as "mostly recent", not strictly the last month.
- **Replay holdout:** respondents with any comment dated on or after 1 September 2022 → REPLAY (383 comments, 249 people, NEAS only, since NHFT data ends in May 2022). Oct–Dec 2022 add only 35 comments.

## Piles (built in Step 3; `prep.py`, seed `rules_v1`, deterministic)
Priority: leaked → DEV; then any comment on or after the replay date → REPLAY; then 20% DEV / 80% EVAL by comment count, stratified by each respondent's main theme.

| Pile | Comments | People | Purpose |
|---|---|---|---|
| EVAL | 4,563 | 3,052 | Scoring only. **Scoring sample: 402**, at least 5 per sub-theme where EVAL has them; Parking has 1 |
| DEV | 1,265 | 831 | Prompt work, examples, panel calibration; holds all 64 leaked comments |
| REPLAY | 383 | 249 | Step 6 replay |
