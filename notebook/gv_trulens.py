"""GV_FIRST_PASS: our theme-tagging classifier, wrapped with TruLens so Snowflake AI Observability
records every call (trace, tokens, latency) and the judge can score it.

The app sends exactly the same request as the SQL procedure: it reads the filled prompt and the fixed answer
format from VOC_EVAL.HARNESS.GV_REQUESTS, and checks the reply with CHECK_ANSWER (retry once). Answers are
also saved to RESULTS with SOURCE = 'TRULENS', so SQL scoring is the same for grid and procedure runs.
"""
import json
import random
import re
import time

from snowflake.snowpark import Session
from trulens.core import Metric, Selector
from trulens.core.otel.instrument import instrument
from trulens.otel.semconv.trace import SpanAttributes

DB = "VOC_EVAL.HARNESS"


def run_sql(session: Session, sql: str, params: list):
    """Run one statement; when parallel runs hit a table lock (000625), wait a little and try again."""
    for attempt in range(8):
        try:
            return session.sql(sql, params=params).collect()
        except Exception as e:
            if "000625" not in str(e) or attempt == 7:
                raise
            time.sleep(1 + attempt + random.random() * 2)


def readable(answer: dict) -> str:
    """The answer as plain lines for the judge, e.g. '- Timeliness of care (Access ...), Negative: "I waited 3 hours"'.
    The JSON answer itself is saved to RESULTS; this is only what AI Observability shows and judges."""
    tags = (answer or {}).get("tags") or []
    if not tags:
        return "No tags returned."
    return "\n".join(f'- {t.get("sub_theme")} ({t.get("theme")}), {t.get("sentiment_label")}: "{t.get("evidence")}"'
                     for t in tags)


# Our own judge metrics (custom, client-side, judged by the J01 judge in GV_MODEL_CONFIG). The built-in
# groundedness and coherence were shown to be unfair to tag lists and short comments (they judge the comment, not
# the tagging). Each asks the judge for a yes/no verdict per tag; score = share of "yes" tags (0-1), with reasons.
# The judge gets the same rules the model had: the survey question and the definitions of the tagged sub-themes.
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


def _judge_prompt(prompt_template: str, definitions: dict, comment: str, question: str, output: str) -> str:
    tagged = re.findall(r"^- (.+?) \(", output, flags=re.M)
    defs = "\n".join(f"- {s}: {definitions.get(s, '(no definition)')}" for s in dict.fromkeys(tagged))
    return prompt_template.format(question=question, comment=comment, tags=output, definitions=defs)


def _verdicts(reply: str) -> list:
    reply = json.loads(reply) if reply else {}
    return ((reply.get("structured_output") or [{}])[0].get("raw_message") or {}).get("tags") or []


def prefetch_verdicts(session: Session, judge: str, rows: list) -> dict:
    """Asks the judge about every (comment, answer) of a run up front, in one AI_COMPLETE statement per round
    (Snowflake runs the calls in parallel), instead of TruLens's one-at-a-time loop. rows = [(comment, question,
    output)]. Returns {prompt: verdicts}; the metrics then just look their prompt up. Empty replies: 2 more rounds."""
    if not re.fullmatch(r"[A-Za-z0-9._-]+", judge):
        raise ValueError(f"unexpected judge name: {judge}")
    definitions = _definitions(session)
    prompts = list(dict.fromkeys(
        _judge_prompt(t, definitions, c, q, o)
        for c, q, o in rows if o and o != "No tags returned."
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
                         model_parameters => {{'temperature': 0, 'max_tokens': 16000}},
                         response_format => PARSE_JSON(?), show_details => TRUE)::STRING AS R
                FROM T_JUDGE_PROMPTS""", params=[json.dumps(VERDICT_FORMAT)]).collect():
            if v := _verdicts(r["R"]):
                found[r["PROMPT"]] = v
    return found


def _definitions(session: Session) -> dict:
    return {r["SUB_THEME"]: r["DEFINITION"][:800] for r in session.sql(
        f"SELECT SUB_THEME, DEFINITION FROM {DB}.TAXONOMY").collect()}


def _tag_metric(session: Session, judge: str, name: str, prompt_template: str, definitions: dict,
                cache: dict) -> Metric:
    if not re.fullmatch(r"[A-Za-z0-9._-]+", judge):
        raise ValueError(f"unexpected judge name: {judge}")

    def ask(prompt: str):
        """Returns (verdicts, error). Up to 3 attempts: the judge occasionally returns an empty reply."""
        error = None
        for attempt in range(3):
            try:
                # max_tokens 16000: the judge is a reasoning model, and with many tags its thinking used up the
                # default 4,096-token output limit, so the reply came back empty.
                row = session.sql(f"""SELECT AI_COMPLETE(model => '{judge}', prompt => ?,
                                        model_parameters => {{'temperature': 0, 'max_tokens': 16000}},
                                        response_format => PARSE_JSON(?), show_details => TRUE)::STRING AS R""",
                                  params=[prompt, json.dumps(VERDICT_FORMAT)]).collect()[0]["R"]
                verdicts = _verdicts(row)
                if verdicts:
                    return verdicts, None
                error = "empty reply"
            except Exception as e:  # keep the metric running; the reason is recorded with the score
                error = str(e)[:200]
            time.sleep(2 * (attempt + 1))
        return [], error

    def score(context: list, output: str):
        if not output or output == "No tags returned.":
            return 0.0, {"reason": "no tags"}
        # context = [comment, survey question] from GVFirstPass.get_context (flattened in case it is nested).
        flat = [c for item in (context or []) for c in (item if isinstance(item, list) else [item])]
        comment, question = (flat + ["", ""])[:2]
        prompt = _judge_prompt(prompt_template, definitions, comment, question, output)
        # With a pre-fetched batch, a prompt missing from it was empty 3 times: record "judge failed" (re-judge
        # later in a batch) rather than ask again one at a time, which took ~3 minutes per call.
        if cache is not None:
            verdicts, error = cache.get(prompt, []), "empty reply in 3 batch rounds"
        else:
            verdicts, error = ask(prompt)
        if not verdicts:
            return 0.0, {"reason": f"judge failed 3 times: {error}"}
        ok = sum(1 for v in verdicts if v.get("ok"))
        return ok / len(verdicts), {"reason": "; ".join(
            f'{v.get("sub_theme")}: {"yes" if v.get("ok") else "no"} - {v.get("reason")}' for v in verdicts)}

    return Metric(name=name, implementation=score,
                  selectors={"context": Selector.select_context(collect_list=True),
                             "output": Selector.select_record_output()})


def tag_metrics(session: Session, judge: str, cache: dict = None) -> list:
    """tag_groundedness: is each tag supported by the comment?  tag_coherence: do the tags fit together?
    cache = prefetch_verdicts(...) output, so scoring is a lookup instead of one judge call at a time."""
    definitions = _definitions(session)
    return [_tag_metric(session, judge, "tag_groundedness", TAG_GROUNDEDNESS_PROMPT, definitions, cache or {}),
            _tag_metric(session, judge, "tag_coherence", TAG_COHERENCE_PROMPT, definitions, cache or {})]


class GVFirstPass:
    """One setup (model + prompt) tagging one comment at a time."""

    def __init__(self, session: Session, config_id: str, comment_set: str, repeat: int, run_id: str):
        self.session = session
        self.config_id, self.comment_set, self.repeat, self.run_id = config_id, comment_set, repeat, run_id
        cfg = session.sql(
            f"SELECT MODEL, PROMPT_VERSION, TEMPERATURE FROM {DB}.GV_MODEL_CONFIG WHERE CONFIG_ID = ?",
            params=[config_id]).collect()[0]
        self.model, self.prompt_version, self.temperature = cfg[0], cfg[1], float(cfg[2])
        if not re.fullmatch(r"[A-Za-z0-9._-]+", self.model):  # the model must be written into SQL as a literal
            raise ValueError(f"unexpected model name: {self.model}")
        self.questions = {r["COMMENT_ID"]: r["QUESTION"] for r in session.sql(
            f"SELECT COMMENT_ID, QUESTION FROM {DB}.COMMENTS JOIN {DB}.GV_COMMENT_SETS USING (COMMENT_ID) WHERE COMMENT_SET = ?",
            params=[comment_set]).collect()}
        # Answers go to this run's own table first (no lock fights with parallel runs); flush() copies them to RESULTS.
        self.stage = f"{DB}.STG_{re.sub(r'[^A-Za-z0-9_]', '_', run_id).upper()}"
        session.sql(f"CREATE TABLE IF NOT EXISTS {self.stage} LIKE {DB}.RESULTS").collect()

    # The context the judge checks against: the comment and the survey question it answers (not the full rulebook).
    @instrument(span_type=SpanAttributes.SpanType.RETRIEVAL,
                attributes={SpanAttributes.RETRIEVAL.QUERY_TEXT: "comment_text",
                            SpanAttributes.RETRIEVAL.RETRIEVED_CONTEXTS: "return"})
    def get_context(self, comment_text: str, comment_id: str) -> list:
        return [comment_text, self.questions.get(comment_id, "")]

    # The AI call, with the shared prompt and the fixed answer format.
    @instrument(span_type=SpanAttributes.SpanType.GENERATION)
    def call_model(self, comment_id: str) -> dict:
        row = self.session.sql(f"""
            SELECT AI_COMPLETE(model => '{self.model}', prompt => q.PROMPT_FILLED,
                     model_parameters => {{'temperature': {self.temperature}, 'max_tokens': 4096}},
                     response_format => q.RESPONSE_FORMAT, show_details => TRUE)::STRING AS R
            FROM {DB}.GV_REQUESTS q
            WHERE q.COMMENT_ID = ? AND q.COMMENT_SET = ? AND q.PROMPT_VERSION = ?""",
            params=[comment_id, self.comment_set, self.prompt_version]).collect()[0]
        reply = json.loads(row["R"]) if row["R"] else {}
        return {"answer": (reply.get("structured_output") or [{}])[0].get("raw_message"),
                "usage": reply.get("usage") or {}}

    # Check with CHECK_ANSWER and save to this run's table; returns the list of problems.
    def _check_and_save(self, comment_id: str, out: dict, attempt: int) -> list:
        answer = json.dumps(out["answer"]) if out["answer"] is not None else None
        problems = self.session.sql(f"""
            SELECT {DB}.CHECK_ANSWER(PARSE_JSON(?), c.COMMENT_TEXT, r.ALLOWED_PAIRS)::STRING AS P
            FROM {DB}.COMMENTS c CROSS JOIN {DB}.GV_RULEBOOK r WHERE c.COMMENT_ID = ?""",
            params=[answer, comment_id]).collect()[0]["P"]
        run_sql(self.session, f"""
            MERGE INTO {self.stage} t
            USING (SELECT ? RUN_ID, ? CONFIG_ID, ? MODEL, ? PROMPT_VERSION, ? COMMENT_SET, ? REPEAT_NO, ? COMMENT_ID,
                          ? ATTEMPT, PARSE_JSON(?) ANSWER, PARSE_JSON(?)::ARRAY PROBLEMS, ? PROMPT_TOKENS,
                          ? COMPLETION_TOKENS) s
            ON t.RUN_ID = s.RUN_ID AND t.COMMENT_ID = s.COMMENT_ID
            WHEN MATCHED THEN UPDATE SET ATTEMPT = s.ATTEMPT, ANSWER = s.ANSWER, PROBLEMS = s.PROBLEMS,
                 PROMPT_TOKENS = s.PROMPT_TOKENS, COMPLETION_TOKENS = s.COMPLETION_TOKENS
            WHEN NOT MATCHED THEN INSERT (RUN_ID, CONFIG_ID, MODEL, PROMPT_VERSION, COMMENT_SET, REPEAT_NO, COMMENT_ID,
                 ATTEMPT, ANSWER, PROBLEMS, PROMPT_TOKENS, COMPLETION_TOKENS, SOURCE)
                 VALUES (s.RUN_ID, s.CONFIG_ID, s.MODEL, s.PROMPT_VERSION, s.COMMENT_SET, s.REPEAT_NO, s.COMMENT_ID,
                 s.ATTEMPT, s.ANSWER, s.PROBLEMS, s.PROMPT_TOKENS, s.COMPLETION_TOKENS, 'TRULENS')""",
            [self.run_id, self.config_id, self.model, self.prompt_version, self.comment_set, self.repeat,
             comment_id, attempt, answer, problems,
             out["usage"].get("prompt_tokens"), out["usage"].get("completion_tokens")])
        return json.loads(problems)

    # A finished answer already saved for this run (passed, or already retried): reused on resume, not paid again.
    def _saved(self, comment_id: str):
        rows = run_sql(self.session, f"""
            SELECT ANSWER::STRING A FROM (SELECT * FROM {self.stage} UNION ALL SELECT * FROM {DB}.RESULTS)
            WHERE RUN_ID = ? AND COMMENT_ID = ? AND (ARRAY_SIZE(PROBLEMS) = 0 OR ATTEMPT = 2) LIMIT 1""",
            [self.run_id, comment_id])
        return json.loads(rows[0]["A"]) if rows and rows[0]["A"] else ({} if rows else None)

    # After invocation: copy this run's answers into RESULTS in one statement, then drop the run's table.
    def flush(self):
        run_sql(self.session, f"""
            MERGE INTO {DB}.RESULTS t USING {self.stage} s
            ON t.RUN_ID = s.RUN_ID AND t.COMMENT_ID = s.COMMENT_ID
            WHEN MATCHED THEN UPDATE SET ATTEMPT = s.ATTEMPT, ANSWER = s.ANSWER, PROBLEMS = s.PROBLEMS,
                 PROMPT_TOKENS = s.PROMPT_TOKENS, COMPLETION_TOKENS = s.COMPLETION_TOKENS
            WHEN NOT MATCHED THEN INSERT (RUN_ID, CONFIG_ID, MODEL, PROMPT_VERSION, COMMENT_SET, REPEAT_NO, COMMENT_ID,
                 ATTEMPT, ANSWER, PROBLEMS, PROMPT_TOKENS, COMPLETION_TOKENS, SOURCE)
                 VALUES (s.RUN_ID, s.CONFIG_ID, s.MODEL, s.PROMPT_VERSION, s.COMMENT_SET, s.REPEAT_NO, s.COMMENT_ID,
                 s.ATTEMPT, s.ANSWER, s.PROBLEMS, s.PROMPT_TOKENS, s.COMPLETION_TOKENS, 'TRULENS')""", [])
        self.session.sql(f"DROP TABLE IF EXISTS {self.stage}").collect()

    # The app's entry point. INPUT = the comment, OUTPUT = the answer as readable lines: this is what the judge sees.
    @instrument(span_type=SpanAttributes.SpanType.RECORD_ROOT,
                attributes={SpanAttributes.RECORD_ROOT.INPUT: "comment_text",
                            SpanAttributes.RECORD_ROOT.OUTPUT: "return"})
    def tag_comment(self, comment_text: str, comment_id: str) -> str:
        self.get_context(comment_text, comment_id)
        saved = self._saved(comment_id)
        if saved is not None:
            return readable(saved)
        out = self.call_model(comment_id)
        if self._check_and_save(comment_id, out, 1):  # failed a check: one retry, same as the SQL procedure
            out = self.call_model(comment_id)
            self._check_and_save(comment_id, out, 2)
        return readable(out["answer"])
