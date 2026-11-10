"""Answer-key review.

Ten comments per page, then save the page. Two kinds of work:
- Panel disagreements: check the panel's suggested answer for each (tags, sentiment, impact). Saving sets
  ANSWER_KEY.DECIDED_BY = human (with who and when) and closes each REVIEW_QUEUE item.
- Blind audit (step 10b): the comment only, no suggestion; tag it fresh. Saved in REVIEW_QUEUE only, ANSWER_KEY is
  not changed, so the person's answer can be compared with the panel's.
Cards that are not complete, or are marked "Skip for now", stay open and come back on a later page.
"""
import json

import streamlit as st

DB = "VOC_EVAL.HARNESS"
PAGE_SIZE = 10
SENTIMENTS = ["Positive", "Neutral", "Negative"]
IMPACTS = [1, 2, 3, 4, 5]
IMPACT_HELP = ("1 no problem raised · 2 minor inconvenience · 3 affected the experience, no harm · "
               "4 significant distress, delay or service failure · 5 harm or risk to safety")
MODES = {"Panel disagreements": "panel_split", "Blind audit": "audit"}

st.set_page_config(page_title="Answer key review", page_icon=":material/fact_check:", layout="wide")

session = st.connection("snowflake").session()


@st.cache_data(ttl=3600)
def all_pairs() -> list[str]:
    rows = session.sql(f"SELECT THEME || ' > ' || SUB_THEME AS P FROM {DB}.TAXONOMY ORDER BY ORDINAL").collect()
    return [r["P"] for r in rows]


def next_page(reason: str, skipped: list[int]):
    """The next open items of this kind (up to PAGE_SIZE), plus progress counts. Not cached: it changes after every save."""
    counts = session.sql(f"""SELECT COUNT(*) AS TOTAL, COUNT_IF(STATUS = 'done') AS DONE
                             FROM {DB}.REVIEW_QUEUE WHERE REASON = ?""", params=[reason]).collect()[0]
    rows = session.sql(f"""
        SELECT q.ITEM_ID, q.COMMENT_ID, q.DETAILS::STRING AS DETAILS, c.QUESTION, c.COMMENT_TEXT
        FROM {DB}.REVIEW_QUEUE q JOIN {DB}.SAMPLE_COMMENTS c USING (COMMENT_ID)
        WHERE q.REASON = ? AND q.STATUS = 'open'
        ORDER BY q.ITEM_ID""", params=[reason]).collect()
    todo = [r for r in rows if r["ITEM_ID"] not in skipped] or rows
    return todo[:PAGE_SIZE], counts["TOTAL"], counts["DONE"]


def label(p: str) -> str:
    return p.split(" > ", 1)[1]


def reviewer() -> str:
    try:
        name = st.user.get("user_name") or st.user.get("email")
    except Exception:
        name = None
    return name or session.sql("SELECT CURRENT_USER()").collect()[0][0]


def save(item, tags: list[str], sentiment: str, impact: int, who: str, audit: bool):
    tag_list = [{"theme": t.split(" > ")[0], "sub_theme": label(t)} for t in tags]
    if not audit:
        session.sql(f"""UPDATE {DB}.ANSWER_KEY SET TAGS = PARSE_JSON(?)::ARRAY, SENTIMENT = ?, IMPACT = ?,
                        DECIDED_BY = 'human', REVIEWED_BY = ?, REVIEWED_AT = CURRENT_TIMESTAMP() WHERE COMMENT_ID = ?""",
                    params=[json.dumps(tag_list), sentiment, int(impact), who, item["COMMENT_ID"]]).collect()
    session.sql(f"""UPDATE {DB}.REVIEW_QUEUE SET STATUS = 'done', DECISION = PARSE_JSON(?), REVIEWED_BY = ?,
                    REVIEWED_AT = CURRENT_TIMESTAMP() WHERE ITEM_ID = ?""",
                params=[json.dumps({"tags": tag_list, "sentiment": sentiment, "impact": int(impact)}), who,
                        int(item["ITEM_ID"])]).collect()


def card(n: int, item, audit: bool) -> dict:
    """One comment: shows the panel's suggestion (none in audit mode) and returns the reviewer's choice."""
    iid = int(item["ITEM_ID"])
    d = json.loads(item["DETAILS"])
    agreed = [f"{t['theme']} > {t['sub_theme']}" for t in d.get("accepted") or []]
    maybe = [f"{v['theme']} > {v['sub_theme']}" for v in d.get("all_votes") or [] if v["status"] == "split"]
    panel_sentiment = d.get("sentiment") if d.get("sentiment") in SENTIMENTS else None
    panel_impact = int(d["impact"]) if d.get("impact") in IMPACTS else None

    with st.container(border=True):
        st.caption(f"{n}. {item['QUESTION']}")
        st.markdown(f"**{item['COMMENT_TEXT']}**")

        left, right = st.columns([3, 2])
        if audit:
            with left:
                tags = st.multiselect("Tags: the points this comment clearly makes", all_pairs(),
                                      format_func=label, key=f"t_{iid}")
            with right:
                sentiment = st.segmented_control("Sentiment", SENTIMENTS, key=f"s_{iid}")
                impact = st.segmented_control("Impact", IMPACTS, key=f"i_{iid}", help=IMPACT_HELP)
            if len(tags) > 3:
                st.warning(f"{len(tags)} tags selected. Most comments make 1-2 points.", icon=":material/warning:")
            skip = st.checkbox("Skip for now", key=f"k_{iid}")
            return {"item": item, "tags": tags, "sentiment": sentiment, "impact": impact, "skip": skip}

        with left:
            tags = st.multiselect("Tags (agreed by 3+ models are pre-selected)", all_pairs(), default=agreed,
                                  format_func=label, key=f"t_{iid}")
            if maybe:
                st.caption("Also suggested by 2 of 4 models: add any that the comment clearly makes a point about")
                with st.container(horizontal=True):
                    for p in maybe:
                        if st.checkbox(label(p), key=f"m_{iid}_{p}"):
                            tags = list(dict.fromkeys(tags + [p]))
            if not agreed:
                st.caption("No tag was agreed by 3 or more models.")
        with right:
            sentiment = st.segmented_control("Sentiment", SENTIMENTS, default=panel_sentiment, key=f"s_{iid}")
            if panel_sentiment is None:
                st.caption("Panel did not agree: choose one.")
            impact = st.segmented_control("Impact", IMPACTS, default=panel_impact, key=f"i_{iid}", help=IMPACT_HELP)
            if panel_impact is None:
                said = ", ".join(str(v) for v in (d.get("impact_votes") or {}).values()) or "no answer"
                st.caption(f"Panel said {said}: choose one.")

        if d.get("too_many_tags"):
            st.info("The panel agreed on 4 or more tags. Keep only the points the comment clearly makes.",
                    icon=":material/info:")
        if len(tags) > 3:
            st.warning(f"{len(tags)} tags selected. Most comments make 1-2 points.", icon=":material/warning:")
        skip = st.checkbox("Skip for now", key=f"k_{iid}")
    return {"item": item, "tags": tags, "sentiment": sentiment, "impact": impact, "skip": skip}


st.session_state.setdefault("skipped", [])

st.title("Answer key review")
open_audit = session.sql(f"SELECT COUNT(*) FROM {DB}.REVIEW_QUEUE WHERE REASON = 'audit'").collect()[0][0]
mode = (st.segmented_control("Work", list(MODES), default="Blind audit", key="mode") or "Blind audit"
        if open_audit else "Panel disagreements")
audit = MODES[mode] == "audit"
if audit:
    st.info("Blind audit: tag each comment from scratch. The panel's answer is hidden and the answer key is not "
            "changed; your answers are compared with the panel's afterwards.", icon=":material/visibility_off:")
page, total, done = next_page(MODES[mode], st.session_state.skipped)
st.progress(done / total if total else 1.0, text=f"{done} of {total} reviewed")
if st.session_state.pop("saved_msg", None):
    st.toast(st.session_state.pop("saved_text", "Saved"), icon=":material/check:")

if not page:
    st.success("All done. The audit is complete." if audit else "All done. The answer key is complete.",
               icon=":material/task_alt:")
    st.stop()

st.caption(f"{len(page)} comments on this page. Impact: {IMPACT_HELP}")
choices = [card(n, item, audit) for n, item in enumerate(page, start=1)]

allowed = set(all_pairs())
ready = [c for c in choices if not c["skip"] and c["tags"] and all(t in allowed for t in c["tags"])
         and c["sentiment"] in SENTIMENTS and c["impact"] in IMPACTS]
skipping = [c for c in choices if c["skip"]]
missing = [n for n, c in enumerate(choices, start=1) if not c["skip"] and c not in ready]

st.caption(f"Ready to save: {len(ready)}  ·  skipped: {len(skipping)}"
           + (f"  ·  incomplete (need tags, sentiment and impact): {', '.join(map(str, missing))}" if missing else ""))
if st.button(f"Save this page ({len(ready)})", type="primary", icon=":material/check:",
             disabled=not ready and not skipping):
    who = reviewer()
    for c in ready:
        save(c["item"], c["tags"], c["sentiment"], c["impact"], who, audit)
    st.session_state.skipped += [int(c["item"]["ITEM_ID"]) for c in skipping]
    st.session_state.saved_msg = True
    st.session_state.saved_text = f"Saved {len(ready)}" + (f", skipped {len(skipping)}" if skipping else "")
    st.rerun()
