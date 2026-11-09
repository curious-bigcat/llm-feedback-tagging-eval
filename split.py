"""Add the TEST / PRACTICE split and the scoring sample to data/comments.csv (rules in PLAN.md).

  PILE       TEST | PRACTICE. One pile per person; anyone with a leaked comment goes to PRACTICE;
             the rest are split 20% PRACTICE / 80% TEST by comment count, within each person's main theme.
  IN_SAMPLE  ~400 TEST comments to score: at least 5 per sub-theme (all of them if TEST has fewer),
             then topped up in proportion to each comment's main theme.
Uses a fixed seed, so re-running gives an identical file. Safe to re-run (existing PILE/IN_SAMPLE are replaced).
Run: python3 split.py
"""
import csv
import hashlib
import json
from collections import Counter, defaultdict
from pathlib import Path

FILE = Path(__file__).resolve().parent / "data" / "comments.csv"
SEED = "nhs_eval_v1"
PRACTICE_SHARE = 0.20
SAMPLE_SIZE = 400
MIN_PER_SUB_THEME = 5


def rank(key):
    """Fixed pseudo-random order: the same key and seed always give the same position."""
    return hashlib.sha256(f"{SEED}|{key}".encode()).hexdigest()


def main_theme(tags):
    """The theme with the most tags (ties broken by name)."""
    counts = Counter(t["theme"] for t in tags)
    return min(counts, key=lambda t: (-counts[t], t))


def split_piles(comments):
    people = defaultdict(list)
    for c in comments:
        people[c["RESPONDENT_ID"]].append(c)
    pile = {p: "PRACTICE" for p, cs in people.items() if any(c["LEAKED_QUOTE"] for c in cs)}
    groups = defaultdict(list)
    for p, cs in people.items():
        if p not in pile:
            groups[main_theme([t for c in cs for t in c["TAGS"]])].append(p)
    for persons in groups.values():
        total, practice = sum(len(people[p]) for p in persons), 0
        for p in sorted(persons, key=rank):
            if practice < PRACTICE_SHARE * total:
                pile[p], practice = "PRACTICE", practice + len(people[p])
            else:
                pile[p] = "TEST"
    return pile


def pick_sample(test):
    ordered = sorted(test, key=lambda c: rank(c["COMMENT_ID"]))
    subs = {c["COMMENT_ID"]: {t["sub_theme"] for t in c["TAGS"]} for c in test}
    available = Counter(s for v in subs.values() for s in v)
    chosen = []
    for sub in sorted(available, key=lambda s: (available[s], s)):
        need = min(MIN_PER_SUB_THEME, available[sub]) - sum(sub in subs[i] for i in chosen)
        for c in ordered:
            if need <= 0:
                break
            if c["COMMENT_ID"] not in chosen and sub in subs[c["COMMENT_ID"]]:
                chosen.append(c["COMMENT_ID"])
                need -= 1
    theme_of = {c["COMMENT_ID"]: main_theme(c["TAGS"]) for c in test}
    for theme, n in sorted(Counter(theme_of.values()).items()):
        need = round(SAMPLE_SIZE * n / len(test)) - sum(theme_of[i] == theme for i in chosen)
        for c in ordered:
            if need <= 0:
                break
            if c["COMMENT_ID"] not in chosen and theme_of[c["COMMENT_ID"]] == theme:
                chosen.append(c["COMMENT_ID"])
                need -= 1
    return set(chosen)


def main():
    with open(FILE, newline="") as fh:
        rows = list(csv.DictReader(fh))
    for r in rows:
        r.pop("PILE", None)
        r.pop("IN_SAMPLE", None)
        r["TAGS"] = json.loads(r["HUMAN_TAGS"])

    pile = split_piles(rows)
    test = [r for r in rows if pile[r["RESPONDENT_ID"]] == "TEST"]
    sample = pick_sample(test)
    for r in rows:
        r["PILE"] = pile[r["RESPONDENT_ID"]]
        r["IN_SAMPLE"] = r["COMMENT_ID"] in sample

    assert not any(r["LEAKED_QUOTE"] and r["PILE"] == "TEST" for r in rows), "leaked comment in TEST"
    assert all(r["PILE"] == "TEST" for r in rows if r["IN_SAMPLE"]), "sample outside TEST"

    fields = [k for k in rows[0] if k != "TAGS"]
    with open(FILE, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    print(f"comments by pile: {dict(Counter(r['PILE'] for r in rows))}; "
          f"people by pile: {dict(Counter(pile.values()))}; sample: {len(sample)}")


if __name__ == "__main__":
    main()
