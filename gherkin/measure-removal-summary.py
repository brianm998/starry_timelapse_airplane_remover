#!/usr/bin/env python3
"""Collects the reports gherkin/measure-removal.sh wrote into one markdown table: python3 summary.py <out-dir> > summary.md"""
import json, os, statistics, sys

def q(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(p * len(xs)))] if xs else float("nan")

root = sys.argv[1]
print("# Removal measurements\n")
print("| run | seconds | GPU path | objects | label errors | worst-stretch ratio p25 / p50 / p75 / p90 / max | <0.5 | >=0.5 | star median ratio (range over frames) | max lost-star fraction | unchanged-outside px |")
print("|---|---|---|---|---|---|---|---|---|---|---|")
detail = []
for name in sorted(os.listdir(root)):
    d = os.path.join(root, name)
    rp = os.path.join(d, "report.json")
    if not os.path.isfile(rp):
        print(f"| {name} | no report (see star.log / verify.txt) |||||||||||")
        continue
    r = json.load(open(rp))
    secs = open(os.path.join(d, "star.status")).read().split("after")[-1].split()[0]
    gpu = " / ".join(open(os.path.join(d, "gpu.txt")).read().split("\n")[:2]).strip() if os.path.exists(os.path.join(d, "gpu.txt")) else ""
    objs = [o for o in r["objects"] if o["status"] != "labelError"]
    w = [o["measurement"]["worstRatio"] for o in objs if o["measurement"]["worstRatio"] is not None]
    st = list(r.get("stars", {}).values())
    sm = [s["medianRatio"] for s in st]
    lost = [s["fractionBelowHalf"] for s in st]
    print(f"| {name} | {secs} | {gpu or 'not logged'} | {r['summary']['objects']} | {r['summary']['labelErrors']} "
          f"| {q(w,.25):.2f} / {q(w,.5):.2f} / {q(w,.75):.2f} / {q(w,.9):.2f} / {max(w) if w else float('nan'):.2f} "
          f"| {sum(x < .5 for x in w)} | {sum(x >= .5 for x in w)} "
          f"| {statistics.median(sm) if sm else float('nan'):.3f} ({min(sm) if sm else 0:.3f}–{max(sm) if sm else 0:.3f}) "
          f"| {max(lost) if lost else float('nan'):.3f} | {r.get('collateralArea', 0) if r.get('collateral') else '-'} |")
    # input contrast of removed vs not-removed objects: is a faint-object cutoff possible?
    rem, kept = [], []
    for o in objs:
        m = o["measurement"]
        c = [s["inputContrast"] for s in m["stretches"] if s["measurable"]]
        if not c or m["worstRatio"] is None: continue
        (rem if m["worstRatio"] < .5 else kept).append(statistics.median(c))
    detail.append((name, rem, kept))
print("\n## Input contrast (median over measurable stretches) of removed vs not-removed objects\n")
print("| run | removed n | removed p5 / p25 / p50 | not removed n | not removed p50 / p75 / p95 |")
print("|---|---|---|---|---|")
for name, rem, kept in detail:
    print(f"| {name} | {len(rem)} | {q(rem,.05):.4f} / {q(rem,.25):.4f} / {q(rem,.5):.4f} | {len(kept)} | {q(kept,.5):.4f} / {q(kept,.75):.4f} / {q(kept,.95):.4f} |")
