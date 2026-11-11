-- judge.sql : step 6, the judge scores every grid answer in Snowflake Evaluations (AI & ML > Evaluations > FEEDBACK_TAGGER).
-- JUDGE_RUN(setup, repeat, limit) creates a TruLens run (e.g. 'C04_r2'), replays that grid run's saved answers from
-- ANSWERS (no model calls), and has the judge (J01 in MODELS) score them: tag_groundedness and tag_coherence (ours,
-- client-side) and correctness against ANSWER_KEY - tags, sentiment and impact (built-in, server-side).
-- Uses Snowflake's TruLens build (2.7).
-- LIMIT > 0 judges only that many comments (fixed hash pick), for a quick test; 0 = all.
-- SOURCE: SAMPLE_COMMENTS (default) or FRESH_COMMENTS (step 10a: replays run 'C09_fresh_r1' etc.; fresh comments have
-- no answer key, so only tag_groundedness and tag_coherence are scored, not correctness).
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

DROP PROCEDURE IF EXISTS JUDGE_RUN(STRING, STRING, INT, INT);
DROP PROCEDURE IF EXISTS JUDGE_RUN(STRING, INT, INT);
CREATE OR REPLACE PROCEDURE JUDGE_RUN(P_MODEL_ID STRING, P_REPEAT INT, P_LIMIT INT, P_SOURCE STRING DEFAULT 'SAMPLE_COMMENTS')
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'trulens-core', 'trulens-connectors-snowflake', 'trulens-providers-cortex')
IMPORTS = ('@VOC_EVAL.HARNESS.DATA_STAGE/notebook/judge_app.py')
HANDLER = 'run'
EXECUTE AS CALLER
AS
$$
import json
import os
import time

os.environ.setdefault("TRULENS_OTEL_TRACING", "1")
# The span uploader holds 2,048 spans by default; the fast metric loop overflows it and silently drops scores.
# A bigger queue and batch keep every score and mean fewer uploads.
os.environ["OTEL_BSP_MAX_QUEUE_SIZE"] = "100000"
os.environ["OTEL_BSP_MAX_EXPORT_BATCH_SIZE"] = "5000"

from trulens.apps.app import TruApp
from trulens.connectors.snowflake import SnowflakeConnector
from trulens.connectors.snowflake import otel_exporter
from trulens.core.run import RunConfig

from judge_app import DB, FeedbackTagger, prefetch_verdicts, tag_metrics

TERMINAL = {"INVOCATION_COMPLETED", "INVOCATION_PARTIALLY_COMPLETED", "FAILED", "CANCELLED"}


# Workaround for TruLens 2.7: spans of client-side metric scores carry no input record count, so every score upload
# is rejected ("None" is not an Integer). Fill in the run's real record count when it is missing.
def patch_record_count(count):
    for cls in vars(otel_exporter).values():
        if isinstance(cls, type) and hasattr(cls, "_ingest_spans_from_stage"):
            original = cls._ingest_spans_from_stage

            def ingest(*args, _original=original, **kwargs):
                if "input_records_count" in kwargs:
                    if kwargs["input_records_count"] in (None, "None"):
                        kwargs["input_records_count"] = count
                elif len(args) > 5 and args[5] in (None, "None"):
                    args = args[:5] + (count,) + args[6:]
                return _original(*args, **kwargs)

            cls._ingest_spans_from_stage = staticmethod(ingest)


def run(session, model_id, repeat, limit, source="SAMPLE_COMMENTS"):
    if source not in ("SAMPLE_COMMENTS", "FRESH_COMMENTS"):
        raise ValueError(f"unexpected source: {source}")
    fresh = source == "FRESH_COMMENTS"
    session.use_database("VOC_EVAL")
    session.use_schema("HARNESS")
    judge = session.sql(f"SELECT MODEL FROM {DB}.MODELS WHERE ROLE = 'judge'").collect()[0][0]
    m = session.sql(f"SELECT MODEL, PROMPT FROM {DB}.MODELS WHERE MODEL_ID = ?", params=[model_id]).collect()[0]
    version = f"{m['MODEL']}__{m['PROMPT']}"
    run_id = f"{model_id}{'_fresh' if fresh else ''}_r{repeat}"   # the run whose saved answers are replayed
    run_name = run_id + (f"_test{limit}" if limit else "")

    # Dataset: the comment, its id, and (sample only) the answer key as ground truth.
    pick = ("QUALIFY ROW_NUMBER() OVER (ORDER BY SHA2('nhs_eval_v2|judge_test|' || c.COMMENT_ID)) <= " + str(int(limit))
            if limit else "")
    if fresh:
        df = session.sql(f"SELECT c.COMMENT_ID, c.COMMENT_TEXT FROM {DB}.FRESH_COMMENTS c {pick} "
                         "ORDER BY c.COMMENT_ID").to_pandas()
        spec = {"RECORD_ROOT.INPUT": "COMMENT_TEXT", "comment_id": "COMMENT_ID"}
    else:
        df = session.sql(f"""
            SELECT c.COMMENT_ID, c.COMMENT_TEXT,
                   OBJECT_CONSTRUCT('tags', k.TAGS, 'sentiment', k.SENTIMENT, 'impact', k.IMPACT)::STRING AS GROUND_TRUTH
            FROM {DB}.SAMPLE_COMMENTS c JOIN {DB}.ANSWER_KEY k USING (COMMENT_ID)
            {pick}
            ORDER BY c.COMMENT_ID""").to_pandas()
        spec = {"RECORD_ROOT.INPUT": "COMMENT_TEXT", "comment_id": "COMMENT_ID",
                "RECORD_ROOT.GROUND_TRUTH_OUTPUT": "GROUND_TRUTH"}
    label = "FRESH" if fresh else "SAMPLE"

    app = FeedbackTagger(session, run_id, source)
    # The 3 repeats of a setup start together and race to register the same app version ("already exists");
    # on a retry the version is found and reused. One connector only: TruLens refuses a second one in a session.
    connector = SnowflakeConnector(snowpark_session=session)
    for attempt in range(5):
        try:
            tru_app = TruApp(app, app_name="FEEDBACK_TAGGER", app_version=version,
                             connector=connector, main_method=app.tag_comment)
            break
        except Exception as e:
            if "already exists" not in str(e) or attempt == 4:
                raise
            time.sleep(5 + 5 * attempt)
    tr_run = tru_app.add_run(RunConfig(
        run_name=run_name, dataset_name=f"{label}_{len(df)}", source_type="DATAFRAME",
        dataset_spec=spec, label=label, llm_judge_name=judge,
        description=f"{model_id} {version}, repeat {repeat}" + (", fresh comments" if fresh else "")))

    # Replay: no model calls.
    t0 = time.time()
    tr_run.start(input_df=df)
    while (status := str(tr_run.get_status()).split(".")[-1]) not in TERMINAL:
        time.sleep(15)
    t1 = time.time()

    # The judge's verdicts for all answers in one parallel batch, so the metric loop below is a lookup.
    patch_record_count(len(df))
    cache = prefetch_verdicts(session, judge, app.judge_rows(df["COMMENT_ID"]))
    t2 = time.time()
    # Tag metrics first: compute_metrics ends with a blocking upload of every score. Only then start correctness,
    # because once it starts Snowflake rejects further uploads for the run ("Computation Started"). Fresh comments
    # have no answer key, so no correctness.
    result = tr_run.compute_metrics(metrics=tag_metrics(session, cache))
    if not fresh:
        result += " / " + tr_run.compute_metrics(metrics=["correctness"])
    return json.dumps({"run": run_name, "records": len(df), "invocation": status, "replay_s": round(t1 - t0),
                       "judge_batch_s": round(t2 - t1), "verdicts": len(cache),
                       "metrics_s": round(time.time() - t2), "compute_metrics": result})
$$;
