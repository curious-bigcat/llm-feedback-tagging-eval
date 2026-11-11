-- Step 5 scoring inside Snowflake, with Snowflake's own TruLens build (Anaconda channel, 2.7).
-- TruLens 2.7 can only save client-side scores for a run it created in the same session, so V1_JUDGE_RUN creates a
-- new TruLens run (e.g. 'C01_SAMPLE_r1_t'), replays it over the 404 SAMPLE comments and then computes the judge's
-- metrics. Replay makes no model calls: V1FirstPass.tag_comment reuses each answer RUN_CLASSIFY saved in RESULTS.
-- Results appear in Snowsight > AI & ML > Evaluations > V1_FIRST_PASS.
USE ROLE VOC_EVAL_ROLE;
USE SCHEMA VOC_EVAL.HARNESS;

-- Each judge run uses its setup's own warehouse (VOC_EVAL_C01..C08, see 04_classify.sql), so runs don't compete.

-- V1_JUDGE_RUN: e.g. CALL V1_JUDGE_RUN('C01', 'SAMPLE', 1, '_t'). Uses the J01 judge from V1_MODEL_CONFIG.
CREATE OR REPLACE PROCEDURE V1_JUDGE_RUN(P_CONFIG_ID STRING, P_COMMENT_SET STRING, P_REPEAT INT, P_SUFFIX STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'trulens-core', 'trulens-connectors-snowflake', 'trulens-providers-cortex')
IMPORTS = ('@VOC_EVAL.HARNESS.DATA_STAGE/notebook/v1_trulens.py')
HANDLER = 'run'
EXECUTE AS CALLER
AS
$$
import json
import os
import time

os.environ.setdefault("TRULENS_OTEL_TRACING", "1")
# The span uploader holds 2,048 spans by default; the fast metric loop (404 comments x 2 metrics x 2-3 spans)
# overflowed it and silently dropped scores. A bigger queue and batch keep every score and mean fewer uploads.
os.environ["OTEL_BSP_MAX_QUEUE_SIZE"] = "100000"
os.environ["OTEL_BSP_MAX_EXPORT_BATCH_SIZE"] = "5000"

from trulens.apps.app import TruApp
from trulens.connectors.snowflake import SnowflakeConnector
from trulens.connectors.snowflake import otel_exporter
from trulens.core.run import RunConfig

from v1_trulens import DB, V1FirstPass, tag_metrics

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


def run(session, config_id, comment_set, repeat, suffix, limit):
    session.use_database("VOC_EVAL")
    session.use_schema("HARNESS")
    judge = session.sql(f"SELECT MODEL FROM {DB}.V1_MODEL_CONFIG WHERE ROLE = 'judge'").collect()[0][0]
    version = session.sql(f"SELECT APP_VERSION FROM {DB}.V1_MODEL_CONFIG WHERE CONFIG_ID = ?",
                          params=[config_id]).collect()[0][0]
    results_id = f"{config_id}_{comment_set}_r{repeat}"  # the RUN_CLASSIFY run whose saved answers are replayed
    run_name = results_id + suffix
    with_key = comment_set == "SAMPLE"

    # Same dataset and mapping as run_eval.py: the comment, its id, and the answer key as ground truth.
    df = session.sql(f"""
        SELECT c.COMMENT_ID, c.COMMENT_TEXT,
               {"OBJECT_CONSTRUCT('tags', k.TAGS, 'sentiment', k.SENTIMENT)::STRING" if with_key else "NULL"} AS GROUND_TRUTH
        FROM {DB}.V1_COMMENT_SETS s JOIN {DB}.COMMENTS c USING (COMMENT_ID)
        {"JOIN " + DB + ".ANSWER_KEY k USING (COMMENT_ID)" if with_key else ""}
        WHERE s.COMMENT_SET = ? {"AND k.SOURCE <> 'needs_review'" if limit and with_key else ""}
        {"QUALIFY ROW_NUMBER() OVER (ORDER BY SHA2('nhs_eval_v1|judge_test|' || c.COMMENT_ID)) <= " + str(int(limit))
         if limit else ""}
        ORDER BY c.COMMENT_ID""", params=[comment_set]).to_pandas()
    spec = {"RECORD_ROOT.INPUT": "COMMENT_TEXT", "comment_id": "COMMENT_ID"}
    if with_key:
        spec["RECORD_ROOT.GROUND_TRUTH_OUTPUT"] = "GROUND_TRUTH"

    app = V1FirstPass(session, config_id, comment_set, repeat, results_id)
    # The 3 repeats of a setup start together and race to register the same app version ("already exists");
    # on a retry the version is found and reused. One connector only: TruLens refuses a second one in a session.
    connector = SnowflakeConnector(snowpark_session=session)
    for attempt in range(5):
        try:
            tru_app = TruApp(app, app_name="V1_FIRST_PASS", app_version=version,
                             connector=connector, main_method=app.tag_comment)
            break
        except Exception as e:
            if "already exists" not in str(e) or attempt == 4:
                raise
            time.sleep(5 + 5 * attempt)
    tr_run = tru_app.add_run(RunConfig(
        run_name=run_name, dataset_name=f"{comment_set}_{len(df)}", source_type="DATAFRAME",
        dataset_spec=spec, label=comment_set, llm_judge_name=judge,
        description=f"{config_id} {version} on {comment_set}, repeat {repeat} (judged in Snowflake)"))

    # Invocation: reuses saved answers, so no model calls; then the judge step in the same session.
    t0 = time.time()
    tr_run.start(input_df=df)
    while (status := str(tr_run.get_status()).split(".")[-1]) not in TERMINAL:
        time.sleep(15)
    t1 = time.time()
    session.sql(f"DROP TABLE IF EXISTS {app.stage}").collect()
    patch_record_count(len(df))
    # The judge's verdicts for all answers in one parallel batch (same comment, question and readable answer
    # that TruLens hands each metric), so the metric loop below is a lookup, not one GLM call at a time.
    ids = set(df["COMMENT_ID"])
    saved = [r for r in session.sql(f"""
        SELECT r.COMMENT_ID, c.COMMENT_TEXT, c.QUESTION, r.ANSWER::STRING AS A
        FROM {DB}.RESULTS r JOIN {DB}.COMMENTS c USING (COMMENT_ID)
        WHERE r.RUN_ID = ? AND (ARRAY_SIZE(r.PROBLEMS) = 0 OR r.ATTEMPT = 2)""", params=[results_id]).collect()
             if r["COMMENT_ID"] in ids]
    cache = prefetch_verdicts(session, judge, [
        (r["COMMENT_TEXT"], r["QUESTION"] or "", readable(json.loads(r["A"]) if r["A"] else {})) for r in saved])
    t2 = time.time()
    # Tag metrics first: compute_metrics ends with a blocking upload of every score. Only then start the server-side
    # correctness, because once it starts Snowflake rejects further uploads for the run ("Computation Started").
    result = tr_run.compute_metrics(metrics=tag_metrics(session, judge, cache))
    if with_key:
        result += " / " + tr_run.compute_metrics(metrics=["correctness"])
    return json.dumps({"run": run_name, "invocation": status, "invoke_s": round(t1 - t0),
                       "prefetch_s": round(t2 - t1), "verdicts": len(cache),
                       "judge_s": round(time.time() - t2), "compute_metrics": str(result)})
$$;

-- One task per grid run (8 setups x 3 repeats), each on its setup's warehouse, so all 24 score in parallel.
EXECUTE IMMEDIATE $$
DECLARE
  c CURSOR FOR SELECT CONFIG_ID FROM V1_MODEL_CONFIG WHERE ROLE IN ('champion', 'challenger') ORDER BY 1;
BEGIN
  FOR r IN c DO
    FOR rep IN 1 TO 3 DO
      EXECUTE IMMEDIATE 'CREATE OR REPLACE TASK V1_JUDGE_' || r.CONFIG_ID || '_R' || rep ||
        ' WAREHOUSE = VOC_EVAL_' || r.CONFIG_ID || ' USER_TASK_TIMEOUT_MS = 86400000 AS CALL V1_JUDGE_RUN(''' ||
        r.CONFIG_ID || ''', ''SAMPLE'', ' || rep || ', ''_t'')';
    END FOR;
  END FOR;
  RETURN 'judge tasks created';
END;
$$;

-- Start one (test) or all: EXECUTE TASK V1_JUDGE_C01_R1;
