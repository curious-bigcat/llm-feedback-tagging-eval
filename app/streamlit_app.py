"""Answer-key review.

One comment at a time: check the panel's suggested answer (tags, sentiment, impact) and approve it.
Approving sets ANSWER_KEY.DECIDED_BY = human (with who and when) and closes the
REVIEW_QUEUE item.
"""
import json

import streamlit as st

DB = "VOC_EVAL.HARNESS"
SENTIMENTS = ["Positive", "Neutral", "Negative"]
IMPACTS = [1, 2, 3, 4, 5]
IMPACT_HELP = ("1 no problem raised · 2 minor inconvenience · 3 affected the experience, no harm · "
               "4 significant distress, delay or service failure · 5 harm or risk to safety")

st.set_page_config(page_title="Answer key review", page_icon=":material/fact_check:")

session = st.connection("snowflake").session()


@st.cache_data(ttl=3600)
def all_pairs() -> list[str]:
    rows = session.sql(f"SELECT THEME || ' > ' || SUB_THEME AS P FROM {DB}.TAXONOMY ORDER BY ORDINAL").collect()
    return [r["P"] for r in rows]


def next_item(skipped: list[int]):
    """The next open panel split, plus progress counts. Not cached: it changes after every save."""
    counts = session.sql(f"""SELECT COUNT(*) AS TOTAL, COUNT_IF(STATUS = 'done') AS DONE
                             FROM {DB}.REVIEW_QUEUE WHERE REASON = 'panel_split'""").collect()[0]
    rows = session.sql(f"""
        SELECT q.ITEM_ID, q.COMMENT_ID, q.DETAILS::STRING AS DETAILS, c.QUESTION, c.COMMENT_TEXT
        FROM {DB}.REVIEW_QUEUE q JOIN {DB}.SAMPLE_COMMENTS c USING (COMMENT_ID)
        WHERE q.REASON = 'panel_split' AND q.STATUS = 'open'
        ORDER BY q.ITEM_ID""").collect()
    todo = [r for r in rows if r["ITEM_ID"] not in skipped] or rows
    return (todo[0] if todo else None), counts["TOTAL"], counts["DONE"]


def label(p: str) -> str:
    return p.split(" > ", 1)[1]


def reviewer() -> str:
    try:
        name = st.user.get("user_name") or st.user.get("email")
    except Exception:
        name = None
    return name or session.sql("SELECT CURRENT_USER()").collect()[0][0]


def approve(item, tags: list[str], sentiment: str, impact: int):
    allowed = set(all_pairs())
    if (not tags or any(t not in allowed for t in tags) or sentiment not in SENTIMENTS
            or impact not in IMPACTS):  # server-side check
        st.error("Choose at least one valid tag, a sentiment and an impact.")
        return False
    tag_list = [{"theme": t.split(" > ")[0], "sub_theme": label(t)} for t in tags]
    who = reviewer()
    session.sql(f"""UPDATE {DB}.ANSWER_KEY SET TAGS = PARSE_JSON(?)::ARRAY, SENTIMENT = ?, IMPACT = ?, DECIDED_BY = 'human',
                    REVIEWED_BY = ?, REVIEWED_AT = CURRENT_TIMESTAMP() WHERE COMMENT_ID = ?""",
                params=[json.dumps(tag_list), sentiment, int(impact), who, item["COMMENT_ID"]]).collect()
    session.sql(f"""UPDATE {DB}.REVIEW_QUEUE SET STATUS = 'done', DECISION = PARSE_JSON(?), REVIEWED_BY = ?,
                    REVIEWED_AT = CURRENT_TIMESTAMP() WHERE ITEM_ID = ?""",
                params=[json.dumps({"tags": tag_list, "sentiment": sentiment, "impact": int(impact)}), who,
                        int(item["ITEM_ID"])]).collect()
    return True


st.session_state.setdefault("skipped", [])

st.title("Answer key review")
item, total, done = next_item(st.session_state.skipped)
st.progress(done / total if total else 1.0, text=f"{done} of {total} reviewed")

if item is None:
    st.success("All done. The answer key is complete.", icon=":material/task_alt:")
    st.stop()

d = json.loads(item["DETAILS"])
agreed = [f"{t['theme']} > {t['sub_theme']}" for t in d.get("accepted") or []]
maybe = [v for v in d.get("all_votes") or [] if v["status"] == "split"]
panel_sentiment = d.get("sentiment") if d.get("sentiment") in SENTIMENTS else None
panel_impact = int(d["impact"]) if d.get("impact") in IMPACTS else None
impact_votes = d.get("impact_votes") or {}

with st.container(border=True):
    st.caption(item["QUESTION"])
    st.markdown(f"#### {item['COMMENT_TEXT']}")

st.markdown("**Agreed by the panel**")
if agreed:
    for p in agreed:
        st.markdown(f":material/check_circle: {label(p)}")
else:
    st.caption("No tag was agreed by 3 or more models.")

keep = []
if maybe:
    st.markdown("**Only 2 of 4 models chose these. Keep them?**")
    for v in maybe:
        p = f"{v['theme']} > {v['sub_theme']}"
        if st.checkbox(label(p), key=f"m_{item['ITEM_ID']}_{p}"):
            keep.append(p)

st.markdown("**Sentiment**")
sentiment = st.segmented_control("Sentiment", SENTIMENTS, default=panel_sentiment,
                                 key=f"s_{item['ITEM_ID']}", label_visibility="collapsed")
if panel_sentiment is None:
    st.caption("The panel did not agree on sentiment. Please choose one.")

st.markdown("**Impact**")
impact = st.segmented_control("Impact", IMPACTS, default=panel_impact, key=f"i_{item['ITEM_ID']}",
                              label_visibility="collapsed", help=IMPACT_HELP)
if panel_impact is None:
    said = ", ".join(f"{v}" for v in impact_votes.values()) or "no answer"
    st.caption(f"The panel did not agree on impact (they said {said}). Please choose one.  ·  {IMPACT_HELP}")

with st.expander("Edit tags"):
    extra = st.multiselect("Add a tag", [p for p in all_pairs() if p not in agreed + keep],
                           format_func=label, key=f"a_{item['ITEM_ID']}")
    drop = st.multiselect("Remove an agreed tag", agreed, format_func=label, key=f"d_{item['ITEM_ID']}")

final = [p for p in dict.fromkeys(agreed + keep + extra) if p not in drop]
st.caption("Will be saved as: " + (", ".join(label(p) for p in final) or "nothing yet")
           + f"  ·  {sentiment or 'no sentiment'}  ·  impact {impact or '?'}")

with st.container(horizontal=True):
    if st.button("Approve", type="primary", icon=":material/check:",
                 disabled=not final or sentiment is None or impact is None):
        if approve(item, final, sentiment, impact):
            st.rerun()
    if st.button("Skip", icon=":material/skip_next:"):
        st.session_state.skipped.append(int(item["ITEM_ID"]))
        st.rerun()
