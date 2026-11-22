#!/usr/bin/env python3
"""Compares star's removal on the same pixels as 8-bit JPEG (a7sii_10) and 16-bit TIFF (a7sii_10_16bit).

Reads the report.json files gherkin/measure-removal.sh wrote (runs named <os>-<dataset>-<method>[-<tag>]),
matches objects by (frame stem, label id) and prints a markdown table; --json writes the same numbers.
Exit status is non-zero only with --gate and a metric past its threshold (gherkin/removal-thresholds.json).

  python3 gherkin/compare-formats.py <out-dir> --os linux [--tag cpu] [--gate] [--json out.json]
  python3 gherkin/compare-formats.py --jpeg a/report.json --tiff b/report.json [--gate]
"""
import argparse, json, os, statistics, sys

JPEG, TIFF = "a7sii_10", "a7sii_10_16bit"
METHODS = ["selective", "automatic_false", "automatic_true"]
HERE = os.path.dirname(os.path.abspath(__file__))


def stem(frame):
    return os.path.splitext(os.path.basename(frame))[0]


def _objects(report):
    out = {}
    for o in report.get("objects", []):
        m = o.get("measurement") or {}
        if o.get("status") in ("labelError", "unmeasurable") or m.get("medianRatio") is None:
            continue
        out[(stem(o["frame"]), o["id"])] = m["medianRatio"]
    return out


def _stars(report):
    return {stem(k): v["medianRatio"] for k, v in (report.get("stars") or {}).items()}


def compare(jpeg, tiff, removed_max=0.6):
    """Compare two parsed reports. A verdict is 'removed' when the object's median ratio is <= removed_max."""
    a, b = _objects(jpeg), _objects(tiff)
    common = sorted(set(a) & set(b))
    disagree = []
    for k in common:
        ra, rb = a[k] <= removed_max, b[k] <= removed_max
        if ra != rb:
            disagree.append({"frame": k[0], "id": k[1], "jpeg_ratio": a[k], "tiff_ratio": b[k],
                             "jpeg": "removed" if ra else "kept", "tiff": "removed" if rb else "kept"})
    n = len(common)
    diffs = [abs(a[k] - b[k]) for k in common]
    rem_a = sum(a[k] <= removed_max for k in common) / n if n else float("nan")
    rem_b = sum(b[k] <= removed_max for k in common) / n if n else float("nan")
    sa, sb = _stars(jpeg), _stars(tiff)
    sc = sorted(set(sa) & set(sb))
    sd = [sa[f] - sb[f] for f in sc]
    return {
        "objects_compared": n,
        "objects_only_jpeg": len(set(a) - set(b)),
        "objects_only_tiff": len(set(b) - set(a)),
        "verdict_agreement": (n - len(disagree)) / n if n else float("nan"),
        "disagreeing": disagree,
        "removed_fraction_jpeg": rem_a,
        "removed_fraction_tiff": rem_b,
        "removed_fraction_delta": abs(rem_a - rem_b) if n else float("nan"),
        "stretch_ratio_diff_median": statistics.median(diffs) if diffs else float("nan"),
        "stretch_ratio_diff_max": max(diffs) if diffs else float("nan"),
        "frames_compared": len(sc),
        "star_flux_diff_median": statistics.median(sd) if sd else float("nan"),
        "star_flux_diff_abs_max": max(abs(x) for x in sd) if sd else float("nan"),
    }


def gate(result, thresholds):
    """Returns the list of failed checks (empty means pass)."""
    fails = []
    amin = (thresholds.get("format_parity_verdict_agreement_min") or {}).get("value")
    dmax = (thresholds.get("format_parity_removed_fraction_delta_max") or {}).get("value")
    if result["objects_compared"] == 0:
        return ["no objects in common between the two reports"]
    if amin is not None and result["verdict_agreement"] < amin:
        fails.append(f"verdict agreement {result['verdict_agreement']:.3f} < {amin}")
    if dmax is not None and result["removed_fraction_delta"] > dmax:
        fails.append(f"removed-fraction delta {result['removed_fraction_delta']:.3f} > {dmax}")
    return fails


def markdown(results):
    lines = ["# JPEG vs 16-bit TIFF (same pixels)\n",
             "| method | objects | verdict agreement | disagreeing | removed fraction jpeg / tiff (delta) | "
             "stretch-ratio diff median / max | star flux diff median (max abs) |",
             "|---|---|---|---|---|---|---|"]
    for name, r in results.items():
        lines.append(f"| {name} | {r['objects_compared']} | {r['verdict_agreement']:.3f} | {len(r['disagreeing'])} "
                     f"| {r['removed_fraction_jpeg']:.3f} / {r['removed_fraction_tiff']:.3f} ({r['removed_fraction_delta']:.3f}) "
                     f"| {r['stretch_ratio_diff_median']:.3f} / {r['stretch_ratio_diff_max']:.3f} "
                     f"| {r['star_flux_diff_median']:+.4f} ({r['star_flux_diff_abs_max']:.4f}) |")
    for name, r in results.items():
        if r["disagreeing"]:
            lines.append(f"\n**{name}: objects that disagree** (frame:id jpeg→tiff ratio)\n")
            for d in r["disagreeing"]:
                lines.append(f"* `{d['frame']}:{d['id']}` {d['jpeg']} {d['jpeg_ratio']:.3f} → {d['tiff']} {d['tiff_ratio']:.3f}")
    return "\n".join(lines) + "\n"


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("out_dir", nargs="?")
    p.add_argument("--os", dest="os_label")
    p.add_argument("--tag", default="")
    p.add_argument("--jpeg", help="report.json of the JPEG run (single-pair mode)")
    p.add_argument("--tiff", help="report.json of the TIFF run (single-pair mode)")
    p.add_argument("--thresholds", default=os.path.join(HERE, "removal-thresholds.json"))
    p.add_argument("--json", dest="json_out")
    p.add_argument("--gate", action="store_true")
    args = p.parse_args(argv)

    th = json.load(open(args.thresholds))
    removed_max = th["removed_max"]["value"]
    pairs = {}
    if args.jpeg and args.tiff:
        pairs["pair"] = (args.jpeg, args.tiff)
    elif args.out_dir and args.os_label:
        suffix = f"-{args.tag}" if args.tag else ""
        for m in METHODS:
            pairs[m] = tuple(os.path.join(args.out_dir, f"{args.os_label}-{ds}-{m}{suffix}", "report.json") for ds in (JPEG, TIFF))
    else:
        p.error("give <out-dir> --os <label>, or --jpeg and --tiff")

    results, fails = {}, []
    for name, (jp, tp) in pairs.items():
        if not (os.path.isfile(jp) and os.path.isfile(tp)):
            print(f"{name}: missing {jp if not os.path.isfile(jp) else tp}", file=sys.stderr)
            fails.append(f"{name}: report missing")
            continue
        results[name] = compare(json.load(open(jp)), json.load(open(tp)), removed_max)
        fails += [f"{name}: {f}" for f in gate(results[name], th)]
    print(markdown(results))
    if fails:
        print("\n" + ("Gate failed:" if args.gate else "Would fail the gate:") + "\n" + "\n".join(f"* {f}" for f in fails))
    if args.json_out:
        json.dump({"results": results, "failures": fails}, open(args.json_out, "w"), indent=2)
    return 1 if (args.gate and fails) else 0


if __name__ == "__main__":
    sys.exit(main())
