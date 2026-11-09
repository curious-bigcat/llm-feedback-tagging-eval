"""Run one setup through Snowflake AI Observability (TruLens), then compute the judge's metrics.

  python run_eval.py C01 TRIAL 1            # the TruLens trial: C01 on the 20 TRIAL comments
  python run_eval.py C06 SAMPLE 2           # a grid run: C06 on the 404 SAMPLE comments, repeat 2

Registers the classifier once as the External Agent GV_FIRST_PASS (one version per setup), creates a run,
invokes it over the comment set, waits for invocation to finish, logs it in RUN_LOG, then asks the judge for its
metrics. TRIAL has no answer key, so correctness is only requested for SAMPLE. All 404 SAMPLE comments are tagged;
the 99 still 'needs_review' carry the panel's proposal as ground truth and are left out of scoring later in SQL.
Results: Snowsight > AI & ML > Evaluations > GV_FIRST_PASS, and VOC_EVAL.HARNESS.RESULTS (SOURCE = 'TRULENS').
"""
import json
import os
import sys
import time

os.environ.setdefault("TRULENS_OTEL_TRACING", "1")

from snowflake.snowpark import Session
from trulens.apps.app import TruApp
from trulens.connectors.snowflake import SnowflakeConnector
from trulens.core.run import RunConfig

from gv_trulens import DB, GVFirstPass, tag_metrics

CONNECTION = os.environ["SNOWFLAKE_CONNECTION_NAME"]  # set to your connection name; no default
APP_NAME = "GV_FIRST_PASS"
WORKERS = int(os.getenv("GV_WORKERS", "4"))  # calls in flight at once within one run
TERMINAL = {"INVOCATION_COMPLETED", "INVOCATION_PARTIALLY_COMPLETED", "FAILED", "CANCELLED"}


def main(config_id: str, comment_set: str, repeat: int, suffix: str = ""):
    session = Session.builder.config("connection_name", CONNECTION).create()
    for stmt in ("USE ROLE VOC_EVAL_ROLE", "USE WAREHOUSE DEMO_WH", f"USE SCHEMA {DB}"):
        session.sql(stmt).collect()

    judge = session.sql(f"SELECT MODEL FROM {DB}.GV_MODEL_CONFIG WHERE ROLE = 'judge'").collect()[0][0]
    version = session.sql(f"SELECT APP_VERSION FROM {DB}.GV_MODEL_CONFIG WHERE CONFIG_ID = ?",
                          params=[config_id]).collect()[0][0]
    # RESULTS_ID names the answers in RESULTS and RUN_LOG; a suffix only names a new TruLens run (e.g. a resume),
    # which reuses the answers already saved under RESULTS_ID instead of paying for them again.
    results_id = f"{config_id}_{comment_set}_r{repeat}_trulens"
    run_name = results_id + suffix

    # The dataset: the comments of this set; for SAMPLE also the answer key as ground truth.
    with_key = comment_set == "SAMPLE"
    df = session.sql(f"""
        SELECT c.COMMENT_ID, c.COMMENT_TEXT,
               {"OBJECT_CONSTRUCT('tags', k.TAGS, 'sentiment', k.SENTIMENT)::STRING" if with_key else "NULL"} AS GROUND_TRUTH
        FROM {DB}.GV_COMMENT_SETS s JOIN {DB}.COMMENTS c USING (COMMENT_ID)
        {"JOIN " + DB + ".ANSWER_KEY k USING (COMMENT_ID)" if with_key else ""}
        WHERE s.COMMENT_SET = ?
        ORDER BY c.COMMENT_ID""", params=[comment_set]).to_pandas()
    print(f"{run_name}: {len(df)} comments, judge {judge}")

    connector = SnowflakeConnector(snowpark_session=session)
    app = GVFirstPass(session, config_id, comment_set, repeat, results_id)
    tru_app = TruApp(app, app_name=APP_NAME, app_version=version, connector=connector,
                     main_method=app.tag_comment)

    # The app receives the INPUT column first, then each extra mapped column in order (here: comment_id).
    spec = {"RECORD_ROOT.INPUT": "COMMENT_TEXT", "comment_id": "COMMENT_ID"}
    if with_key:
        spec["RECORD_ROOT.GROUND_TRUTH_OUTPUT"] = "GROUND_TRUTH"
    run = tru_app.add_run(RunConfig(
        run_name=run_name, dataset_name=f"{comment_set}_{len(df)}", source_type="DATAFRAME",
        dataset_spec=spec, label=comment_set, llm_judge_name=judge,
        description=f"{config_id} {version} on {comment_set}, repeat {repeat}", invocation_max_workers=WORKERS))

    started = session.sql("SELECT CURRENT_TIMESTAMP()").collect()[0][0]
    t0 = time.time()
    run.start(input_df=df)
    while (status := str(run.get_status()).split(".")[-1]) not in TERMINAL:
        time.sleep(15)
    print(f"invocation: {status} after {time.time() - t0:.0f}s")
    app.flush()

    # Log the run like RUN_CLASSIFY does: every fixed setting plus the totals from RESULTS.
    session.sql(f"DELETE FROM {DB}.RUN_LOG WHERE RUN_ID = ?", params=[results_id]).collect()
    session.sql(f"""
        INSERT INTO {DB}.RUN_LOG
        SELECT ?, g.CONFIG_ID, g.MODEL, g.PROMPT_VERSION, p.SHA256, r.TAXONOMY_VERSION, g.TEMPERATURE, ?, ?,
               'TRULENS', ?, CURRENT_TIMESTAMP(), COUNT(f.COMMENT_ID), COUNT_IF(ARRAY_SIZE(f.PROBLEMS) = 0),
               COUNT_IF(f.ATTEMPT = 2), 0, SUM(f.PROMPT_TOKENS), SUM(f.COMPLETION_TOKENS)
        FROM {DB}.GV_MODEL_CONFIG g
        JOIN {DB}.PROMPTS p ON p.PROMPT_VERSION = g.PROMPT_VERSION
        CROSS JOIN {DB}.GV_RULEBOOK r
        LEFT JOIN {DB}.RESULTS f ON f.RUN_ID = ?
        WHERE g.CONFIG_ID = ?
        GROUP BY g.CONFIG_ID, g.MODEL, g.PROMPT_VERSION, p.SHA256, r.TAXONOMY_VERSION, g.TEMPERATURE""",
        params=[results_id, comment_set, repeat, started, results_id, config_id]).collect()

    # Judge metrics: our own tag_groundedness and tag_coherence (gv_trulens.py), plus built-in correctness against
    # the answer key when there is one. Built-in groundedness/coherence are not used (unfair to tag lists).
    custom = tag_metrics(session, judge)
    builtin = ["correctness"] if with_key else []
    print("compute_metrics:", run.compute_metrics(metrics=builtin + custom))
    print(json.dumps({"run": run_name, "app": APP_NAME, "version": version,
                      "metrics": builtin + [m.name for m in custom]}))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4] if len(sys.argv) > 4 else "")
