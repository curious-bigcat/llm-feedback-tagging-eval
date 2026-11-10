"""GV_TAGGER: the TruLens app the judge scores, for Snowflake Evaluations (AI & ML > Evaluations).

It makes no model calls: every grid answer is already saved in ANSWERS by RUN_MODEL, so tag_comment just replays
the saved answer for one comment. TruLens records each replay as a record, then the judge (J01 in MODELS) scores it:
  correctness       built-in, server-side: the answer against ANSWER_KEY
  tag_groundedness  ours: is each tag supported by the comment?
  tag_coherence     ours: do the tags fit together (sentiment fits the quote, no contradictions, no duplicates)?
"""
import json
import re

from snowflake.snowpark import Session
from trulens.core import Metric, Selector
from trulens.core.otel.instrument import instrument
from trulens.otel.semconv.trace import SpanAttributes

DB = "VOC_EVAL.HARNESS"
# Judge output limit: verdicts need a few hundred tokens; 8,192 leaves room for long tag lists.
JUDGE_MAX_TOKENS = 8192


def readable(answer: dict) -> str:
    """The answer as plain lines for the judge, e.g. '- Timeliness of care (Access ...), Negative: "I waited 3 hours"',
    then 'Impact: 3'. The tag metrics read only the '- ' lines; correctness sees the impact too."""
    tags = (answer or {}).get("tags") or []
    lines = [f'- {t.get("sub_theme")} ({t.get("theme")}), {t.get("sentiment_label")}: "{t.get("evidence")}"'
             for t in tags] or ["No tags returned."]
    return "\n".join(lines + [f'Impact: {(answer or {}).get("impact", "not given")}'])


# The two custom metrics. The built-in groundedness and coherence judge the comment, not the tagging, so they are
# unfair to tag lists and short comments. Each asks the judge for a yes/no verdict per tag; score = share of "yes"
# tags (0-1), with the reasons. The judge gets the survey question and the definitions of the tagged sub-themes.
TAG_GROUNDEDNESS_PROMPT = """You check whether the tags given to one patient feedback comment are supported by that comment.
For each tag answer ok = true only if BOTH hold:
1. its quote appears in the comment (ignore capital letters, punctuation and spacing), and
2. the comment's meaning, read as an answer to the survey question, supports that sub-theme (as defined below) and sentiment.
Short comments count too: "Nothing" or "All good" can support a general tag such as "Positive experience & gratitude".
Judge only against the comment and the definitions, not against outside knowledge.

SURVEY QUESTION
{question}

COMMENT
{comment}

TAGS
{tags}

DEFINITIONS OF THE TAGGED SUB-THEMES
{definitions}"""

TAG_COHERENCE_PROMPT = """You check whether a set of tags given to one patient feedback comment is coherent as a whole.
Judge the tagging, not the quality or length of the comment: a short comment like "Nothing" can be tagged coherently.
Read the comment as an answer to the survey question, and use the sub-theme definitions below.
For each tag answer ok = true only if ALL hold:
1. its sentiment (Positive / Neutral / Negative) fits what its quote says,
2. it does not contradict another tag (for example the same quote tagged Positive in one tag and Negative in another),
3. it is not a near-duplicate of another tag (two sub-themes saying the same thing about the same quote).

SURVEY QUESTION
{question}

COMMENT
{comment}

TAGS
{tags}

DEFINITIONS OF THE TAGGED SUB-THEMES
{definitions}"""

VERDICT_FORMAT = {"type": "json", "schema": {
    "type": "object", "additionalProperties": False, "required": ["tags"],
    "properties": {"tags": {"type": "array", "items": {
        "type": "object", "additionalProperties": False, "required": ["sub_theme", "ok", "reason"],
        "properties": {"sub_theme": {"type": "string"}, "ok": {"type": "boolean"},
                       "reason": {"type": "string"}}}}}}}


def definitions(session: Session) -> dict:
    return {r["SUB_THEME"]: r["DEFINITION"][:800] for r in session.sql(
        f"SELECT SUB_THEME, DEFINITION FROM {DB}.TAXONOMY").collect()}


def judge_prompt(template: str, defs: dict, comment: str, question: str, output: str) -> str:
    tagged = re.findall(r"^- (.+?) \(", output, flags=re.M)
    tag_defs = "\n".join(f"- {s}: {defs.get(s, '(no definition)')}" for s in dict.fromkeys(tagged))
    return template.format(question=question, comment=comment, tags=output, definitions=tag_defs)


def _verdicts(reply: str) -> list:
    reply = json.loads(reply) if reply else {}
    return ((reply.get("structured_output") or [{}])[0].get("raw_message") or {}).get("tags") or []


def prefetch_verdicts(session: Session, judge: str, rows: list) -> dict:
    """Asks the judge about every (comment, question, answer) of a run up front, in one AI_COMPLETE statement per
    round (Snowflake runs the calls in parallel), instead of TruLens's one-at-a-time loop. Returns {prompt: verdicts};
    the metrics then just look their prompt up. Empty replies get up to 2 more rounds."""
    if not re.fullmatch(r"[A-Za-z0-9._-]+", judge):  # the judge name is written into SQL as a literal
        raise ValueError(f"unexpected judge name: {judge}")
    defs = definitions(session)
    prompts = list(dict.fromkeys(
        judge_prompt(t, defs, c, q, o)
        for c, q, o in rows if o and not o.startswith("No tags returned.")
        for t in (TAG_GROUNDEDNESS_PROMPT, TAG_COHERENCE_PROMPT)))
    found = {}
    for _ in range(3):
        todo = [p for p in prompts if p not in found]
        if not todo:
            break
        session.create_dataframe([[p] for p in todo], schema=["PROMPT"]).write.save_as_table(
            "T_JUDGE_PROMPTS", mode="overwrite", table_type="temporary")
        for r in session.sql(f"""
                SELECT PROMPT, AI_COMPLETE(model => '{judge}', prompt => PROMPT,
                         model_parameters => {{'temperature': 0, 'max_tokens': {JUDGE_MAX_TOKENS}}},
                         response_format => PARSE_JSON(?), show_details => TRUE)::STRING AS R
                FROM T_JUDGE_PROMPTS""", params=[json.dumps(VERDICT_FORMAT)]).collect():
            if v := _verdicts(r["R"]):
                found[r["PROMPT"]] = v
    return found


def _tag_metric(name: str, template: str, defs: dict, cache: dict) -> Metric:
    def score(context: list, output: str):
        if not output or output.startswith("No tags returned."):
            return 0.0, {"reason": "no tags"}
        # context = [comment, survey question] from GVTagger.get_context (flattened in case it is nested).
        flat = [c for item in (context or []) for c in (item if isinstance(item, list) else [item])]
        comment, question = (flat + ["", ""])[:2]
        verdicts = cache.get(judge_prompt(template, defs, comment, question, output), [])
        if not verdicts:
            return 0.0, {"reason": "judge failed: empty reply in 3 batch rounds"}
        ok = sum(1 for v in verdicts if v.get("ok"))
        return ok / len(verdicts), {"reason": "; ".join(
            f'{v.get("sub_theme")}: {"yes" if v.get("ok") else "no"} - {v.get("reason")}' for v in verdicts)}

    return Metric(name=name, implementation=score,
                  selectors={"context": Selector.select_context(collect_list=True),
                             "output": Selector.select_record_output()})


def tag_metrics(session: Session, cache: dict) -> list:
    defs = definitions(session)
    return [_tag_metric("tag_groundedness", TAG_GROUNDEDNESS_PROMPT, defs, cache),
            _tag_metric("tag_coherence", TAG_COHERENCE_PROMPT, defs, cache)]


class GVTagger:
    """One run (setup + repeat), replaying its saved answers one comment at a time. SOURCE is the comment table the
    run used: SAMPLE_COMMENTS or FRESH_COMMENTS."""

    def __init__(self, session: Session, run_id: str, source: str = "SAMPLE_COMMENTS"):
        if source not in ("SAMPLE_COMMENTS", "FRESH_COMMENTS"):
            raise ValueError(f"unexpected source: {source}")
        rows = session.sql(f"""
            SELECT a.COMMENT_ID, a.ANSWER::STRING AS A, c.COMMENT_TEXT, c.QUESTION
            FROM {DB}.ANSWERS a JOIN {DB}.{source} c USING (COMMENT_ID)
            WHERE a.RUN_ID = ?""", params=[run_id]).collect()
        self.answers = {r["COMMENT_ID"]: json.loads(r["A"]) if r["A"] else {} for r in rows}
        self.questions = {r["COMMENT_ID"]: r["QUESTION"] or "" for r in rows}
        self.texts = {r["COMMENT_ID"]: r["COMMENT_TEXT"] for r in rows}

    def judge_rows(self, comment_ids) -> list:
        """(comment, question, readable answer) for the batch judge: exactly what TruLens hands each metric."""
        return [(self.texts[i], self.questions[i], readable(self.answers[i])) for i in comment_ids if i in self.answers]

    # The context the judge checks against: the comment and the survey question it answers.
    @instrument(span_type=SpanAttributes.SpanType.RETRIEVAL,
                attributes={SpanAttributes.RETRIEVAL.QUERY_TEXT: "comment_text",
                            SpanAttributes.RETRIEVAL.RETRIEVED_CONTEXTS: "return"})
    def get_context(self, comment_text: str, comment_id: str) -> list:
        return [comment_text, self.questions.get(comment_id, "")]

    # Entry point. INPUT = the comment, OUTPUT = the saved answer as readable lines: this is what the judge sees.
    @instrument(span_type=SpanAttributes.SpanType.RECORD_ROOT,
                attributes={SpanAttributes.RECORD_ROOT.INPUT: "comment_text",
                            SpanAttributes.RECORD_ROOT.OUTPUT: "return"})
    def tag_comment(self, comment_text: str, comment_id: str) -> str:
        self.get_context(comment_text, comment_id)
        return readable(self.answers.get(comment_id))
