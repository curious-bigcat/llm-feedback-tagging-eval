"""Clean the NHS FFT source files into two files (rules agreed in PLAN.md).

Inputs (pinned in source/SOURCES.txt, never modified):
  source/v6framework_230831.csv  7,908 comments with 50 old (v6) tag columns
  source/framework3.qmd          published framework: themes, sub-themes, definitions, examples
  source/params.py               the NHS project's code copy of the theme -> sub-theme list (cross-check only)
Outputs:
  data/taxonomy.csv  33 rows: one combined taxonomy
  data/comments.csv  6,211 rows: usable comments with tags converted to the published framework, plus
                     PILE (TEST | PRACTICE, one pile per person) and IN_SAMPLE (the ~400 TEST comments we score)
The split uses a fixed seed, so re-running gives identical files.
Run: python3 prep.py
"""
import ast
import csv
import hashlib
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "source"
OUT = ROOT / "data"

NON_ANSWERS = {"", "did not answer", "not answered"}
FALLBACK = "Not assigned"
SENTIMENT = {"1": "Positive", "2": "Positive", "3": "Neutral", "4": "Negative", "5": "Negative"}
MIN_QUOTE_CHARS = 15  # shorter rulebook examples ('Good', 'Nothing') are too generic to count as leakage
SEED = "nhs_eval_v1"
PRACTICE_SHARE = 0.20
SAMPLE_SIZE = 400
MIN_PER_SUB_THEME = 5

# Old (v6) tag -> published sub-theme, where the name differs. Each merge is stated in the target's definition.
MERGES = {
    "Number & deployment of staff": "Staffing levels & responsiveness",
    "Staff responsiveness": "Staffing levels & responsiveness",
    "Diagnosis & triage": "Continuity of care",
    "Referals & continuity of care": "Continuity of care",
    "Staff continuity": "Continuity of care",
    "Care plans": "Continuity of care",
    "Patient records": "Continuity of care",
    "Environment & Facilities": "Environment, facilities & equipment",
    "Provision of medical equipment": "Environment, facilities & equipment",
    "Existence of services": "Timeliness of care",
}
# No home in the published framework -> fallback (agreed).
FALLBACKS = {
    "Impact of treatment/ care", "Negative experience & dissatisfaction", "Equality, Diversity & Inclusion",
    "Admission", "Patient appearance & grooming", "Safeguarding concerns?", "Learning organisation",
}
# Not in the published framework and no comment carries them.
NO_DATA = {"Psychological therapy arrangements", "Choice of services", "Out of hours support (community services)"}


def build_taxonomy():
    """Themes, sub-themes, definitions and examples from framework3.qmd, checked against params.py."""
    rows, theme = [], None
    for chunk in re.split(r"\n(?=## |### )", (SRC / "framework3.qmd").read_text()):
        head, _, body = chunk.partition("\n")
        if head.startswith("## "):
            theme = head[3:].strip()
        elif head.startswith("### "):
            definition, _, examples = body.split(":::", 1)[0].partition("Examples:")
            rows.append({"ORDINAL": len(rows) + 1, "THEME": theme, "SUB_THEME": head[4:].strip(),
                         "DEFINITION": " ".join(definition.split()), "EXAMPLES": " ".join(examples.split())})
    assert len(rows) == 33 and len({r["THEME"] for r in rows}) == 10, "framework3.qmd structure changed"

    code = (SRC / "params.py").read_text()
    params = ast.literal_eval(re.search(r"major_cat_dict = (\{.*?\n\})", code, re.S).group(1))
    in_params = {sub: t for t, subs in params.items() for sub in subs}
    for r in rows:
        # params.py omits 'Not assigned' and capitalises one theme differently; otherwise the two must agree.
        if r["SUB_THEME"] in in_params:
            assert in_params[r["SUB_THEME"]].lower() == r["THEME"].lower(), r
        r["IN_PARAMS_PY"] = r["SUB_THEME"] in in_params
    assert set(in_params) <= {r["SUB_THEME"] for r in rows}, "params.py has sub-themes missing from the framework"
    return rows


def map_tag(v6, sub_to_theme):
    """Return (theme, sub_theme) for an old tag, or None if it is unused."""
    if v6 in NO_DATA:
        return None
    sub = FALLBACK if v6 in FALLBACKS else MERGES.get(v6, v6)
    assert sub in sub_to_theme, f"unmapped old tag: {v6!r}"
    return sub_to_theme[sub], sub


def norm(text):
    return " ".join(text.lower().split())


def rank(key):
    """Fixed pseudo-random order: the same key and seed always give the same position."""
    return hashlib.sha256(f"{SEED}|{key}".encode()).hexdigest()


def main_theme(tags):
    """The theme with the most tags (ties broken by name)."""
    counts = Counter(t for t, _ in tags)
    return min(counts, key=lambda t: (-counts[t], t))


def split_piles(comments, tags_by_id):
    """One pile per person. Anyone with a leaked comment goes to PRACTICE; the rest are split
    20% PRACTICE / 80% TEST by comment count, separately within each person's main theme."""
    people = defaultdict(list)
    for c in comments:
        people[c["RESPONDENT_ID"]].append(c["COMMENT_ID"])
    pile = {p: "PRACTICE" for p, ids in people.items() if any(c["LEAKED_QUOTE"] for c in comments if c["COMMENT_ID"] in ids)}
    groups = defaultdict(list)
    for p, ids in people.items():
        if p not in pile:
            groups[main_theme([t for i in ids for t in tags_by_id[i]])].append(p)
    for persons in groups.values():
        total, practice = sum(len(people[p]) for p in persons), 0
        for p in sorted(persons, key=rank):
            pile[p] = "PRACTICE" if practice < PRACTICE_SHARE * total else "TEST"
            practice += len(people[p]) if pile[p] == "PRACTICE" else 0
    return pile


def pick_sample(test_ids, tags_by_id):
    """~SAMPLE_SIZE TEST comments: at least MIN_PER_SUB_THEME per sub-theme first (rarest first; all of them if
    TEST has fewer), then topped up in proportion to each comment's main theme."""
    ordered = sorted(test_ids, key=rank)
    subs = {i: {s for _, s in tags_by_id[i]} for i in test_ids}
    available = Counter(s for i in test_ids for s in subs[i])
    chosen = []
    for sub in sorted(available, key=lambda s: (available[s], s)):
        need = min(MIN_PER_SUB_THEME, available[sub]) - sum(sub in subs[i] for i in chosen)
        for i in ordered:
            if need <= 0:
                break
            if i not in chosen and sub in subs[i]:
                chosen.append(i)
                need -= 1
    theme_of = {i: main_theme(tags_by_id[i]) for i in test_ids}
    for theme, n in sorted(Counter(theme_of.values()).items()):
        need = round(SAMPLE_SIZE * n / len(test_ids)) - sum(theme_of[i] == theme for i in chosen)
        for i in ordered:
            if need <= 0:
                break
            if i not in chosen and theme_of[i] == theme:
                chosen.append(i)
                need -= 1
    return set(chosen)


def write_csv(name, rows):
    with open(OUT / name, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    print(f"{name}: {len(rows)} rows")


def main():
    OUT.mkdir(exist_ok=True)
    taxonomy = build_taxonomy()
    sub_to_theme = {r["SUB_THEME"]: r["THEME"] for r in taxonomy}

    with open(SRC / "v6framework_230831.csv", newline="") as fh:
        reader = csv.reader(fh)
        header = next(reader)
        raw = [dict(zip(header, r)) for r in reader]
    old_tags = header[11:]
    assert len(old_tags) == 50

    quotes = sorted({norm(a or b) for r in taxonomy for a, b in re.findall(r"'([^']+)'|\u2018([^\u2019]+)\u2019", r["EXAMPLES"])
                     if len((a or b).strip()) >= MIN_QUOTE_CHARS})

    comments, tags_by_id = [], {}
    for r in raw:
        text = r["FFT answer"].strip()
        if text.lower() in NON_ANSWERS:
            continue
        tags = sorted({t for v6 in old_tags if r[v6].strip() not in ("", "0", "0.0") if (t := map_tag(v6, sub_to_theme))})
        assert tags, f"comment without tags: {r['Comment ID']}"
        tags_by_id[r["Comment ID"]] = tags
        score = r["Comment sentiment"].strip()
        score = str(int(float(score))) if score else ""
        comments.append({
            "COMMENT_ID": r["Comment ID"],
            "RESPONDENT_ID": r["Respondent ID"],
            "TRUST": r["Trust"],
            "SERVICE": " ".join(r["Service type 1"].split()),
            "SUB_SERVICE": " ".join(r["Service type 2"].split()),
            "DATE_RAW": r["Date"],
            "QUESTION": r["FFT question"].strip(),
            "COMMENT_TEXT": text,
            "PATIENT_RATING": r["FFT categorical answer"].strip(),
            "HUMAN_SENTIMENT_1_5": score,
            "HUMAN_SENTIMENT": SENTIMENT.get(score, ""),
            "HUMAN_TAGS": json.dumps([{"theme": t, "sub_theme": s} for t, s in tags]),
            "N_TAGS": len(tags),
            "LEAKED_QUOTE": next((q for q in quotes if q in norm(text)), ""),
        })

    assert len(comments) == len({c["COMMENT_ID"] for c in comments}), "duplicate comment ids"

    pile = split_piles(comments, tags_by_id)
    test_ids = [c["COMMENT_ID"] for c in comments if pile[c["RESPONDENT_ID"]] == "TEST"]
    sample = pick_sample(test_ids, tags_by_id)
    for c in comments:
        c["PILE"] = pile[c["RESPONDENT_ID"]]
        c["IN_SAMPLE"] = c["COMMENT_ID"] in sample

    # Split checks: one pile per person, no leaked comment in TEST, sample only from TEST.
    assert all(len({pile[p]}) == 1 for p in pile)
    assert not any(c["LEAKED_QUOTE"] and c["PILE"] == "TEST" for c in comments), "leaked comment in TEST"
    assert all(c["PILE"] == "TEST" for c in comments if c["IN_SAMPLE"]), "sample outside TEST"

    write_csv("taxonomy.csv", taxonomy)
    write_csv("comments.csv", comments)
    piles = Counter(c["PILE"] for c in comments)
    people = Counter(pile.values())
    print(f"piles (comments): {dict(piles)}; piles (people): {dict(people)}; sample: {len(sample)}")
    print(f"tags per comment: {sum(c['N_TAGS'] for c in comments) / len(comments):.2f}; "
          f"multi-tag share: {sum(c['N_TAGS'] > 1 for c in comments) / len(comments):.1%}; "
          f"leaked: {sum(bool(c['LEAKED_QUOTE']) for c in comments)}; "
          f"no human sentiment: {sum(not c['HUMAN_SENTIMENT'] for c in comments)}")


if __name__ == "__main__":
    main()
