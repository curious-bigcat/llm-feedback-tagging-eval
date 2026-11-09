"""Build label_map.csv: the rules_v1 conversion of the 50 v6 label columns to the published v7 framework.

Every target is validated against both sources:
  - source/framework3.qmd  (published sub-themes and their theme headings)
  - source/params.py       (major_cat_dict: official theme -> sub-theme hierarchy)
The script stops if any v6 column is unmapped or any target is not in the framework.
Run: python3 make_label_map.py
"""
import ast
import csv
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "source"
FALLBACK = "Not assigned"

# v6 label -> (v7 sub-theme, map_type, basis). Same-name labels are filled in automatically below.
MERGES = {
    "Number & deployment of staff": ("Staffing levels & responsiveness", "Definition covers the number of staff and how they are deployed"),
    "Staff responsiveness": ("Staffing levels & responsiveness", "Definition covers how accommodating and timely staff are in responding to needs"),
    "Diagnosis & triage": ("Continuity of care", "Definition covers diagnosis and triage"),
    "Referals & continuity of care": ("Continuity of care", "Definition covers referrals and continuity of care"),
    "Staff continuity": ("Continuity of care", "Definition covers how people move between services and staff"),
    "Care plans": ("Continuity of care", "Definition covers care plans"),
    "Patient records": ("Continuity of care", "Definition covers the sharing of records"),
    "Environment & Facilities": ("Environment, facilities & equipment", "Renamed; definition covers environment and facilities"),
    "Provision of medical equipment": ("Environment, facilities & equipment", "Definition covers provision of medical equipment"),
    "Existence of services": ("Timeliness of care", "Definition covers the availability and existence of services"),
}
FALLBACKS = [
    "Impact of treatment/ care", "Negative experience & dissatisfaction", "Equality, Diversity & Inclusion",
    "Admission", "Patient appearance & grooming", "Safeguarding concerns?", "Learning organisation",
]
NO_DATA = ["Psychological therapy arrangements", "Choice of services", "Out of hours support (community services)"]


def framework_subthemes():
    """Sub-theme -> theme heading, as published in framework3.qmd."""
    out, theme = {}, None
    for line in (SRC / "framework3.qmd").read_text().splitlines():
        if line.startswith("## "):
            theme = line[3:].strip()
        elif line.startswith("### "):
            out[line[4:].strip()] = theme
    return out


def params_hierarchy():
    src = (SRC / "params.py").read_text()
    major = ast.literal_eval(re.search(r"major_cat_dict = (\{.*?\n\})", src, re.S).group(1))
    return {sub: theme for theme, subs in major.items() for sub in subs}


def main():
    fw = framework_subthemes()
    pm = params_hierarchy()
    with open(SRC / "v6framework_230831.csv", newline="") as fh:
        v6 = next(csv.reader(fh))[11:]
    assert len(v6) == 50, len(v6)

    rows = []
    for label in v6:
        if label in MERGES:
            target, kind, basis = MERGES[label][0], "merge", MERGES[label][1]
        elif label in FALLBACKS:
            target, kind, basis = FALLBACK, "fallback", "No documented v7 home; rules_v1 fallback (Not assigned covers rare topics)"
        elif label in NO_DATA:
            target, kind, basis = None, "no_data", "No comments carry this label; not in v7"
        elif label in fw:
            target, kind, basis = label, "same_name", "Same sub-theme name in v7"
        else:
            raise SystemExit(f"Unmapped v6 label: {label!r}")
        theme = fw.get(target) if target else None
        if target:
            assert target in fw, f"{target!r} not in framework3.qmd"
            # params.py omits 'Not assigned'; everything else must agree with the published headings.
            if target in pm:
                assert pm[target].lower() == theme.lower(), (target, pm[target], theme)
        rows.append([label, theme or "", target or "", kind, basis])

    targets = {r[2] for r in rows if r[2]}
    missing = sorted(set(fw) - targets)
    with open(ROOT / "label_map.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["V6_LABEL", "THEME", "SUB_THEME", "MAP_TYPE", "BASIS"])
        w.writerows(rows)

    counts = {}
    for r in rows:
        counts[r[3]] = counts.get(r[3], 0) + 1
    print(f"label_map.csv: {len(rows)} v6 labels -> {len(targets)} v7 sub-themes; by type {counts}")
    print(f"v7 sub-themes with no v6 source: {missing or 'none'}")


if __name__ == "__main__":
    main()
