#!/usr/bin/env python3
"""Snapshots GitHub release download counts and repo traffic into CSV files, and summarises them.

GitHub only keeps a running total per release asset and a 14-day window of traffic. Taking a snapshot every day turns
the running totals into a history (new downloads per day/week/month) and keeps the traffic past its 14 days.

  stats.py collect --data DIR     add today's snapshot to the CSVs in DIR (created if missing)
  stats.py report [--data DIR]    markdown summary; with no --data it reads the `stats` branch on origin

See README.md. Needs the `gh` cli, logged in (locally) or with GH_TOKEN set (in Actions). Standard library only."""
import argparse, csv, datetime as dt, json, os, subprocess, sys
from collections import defaultdict
from pathlib import Path

BRANCH = "stats"

DOWNLOADS = ("downloads.csv", ["date", "tag", "published", "asset", "downloads"])
REPO      = ("repo.csv",      ["date", "stars", "forks", "watchers"])
VIEWS     = ("views.csv",     ["date", "count", "uniques"])
CLONES    = ("clones.csv",    ["date", "count", "uniques"])
REFERRERS = ("referrers.csv", ["date", "referrer", "count", "uniques"])
PATHS     = ("paths.csv",     ["date", "path", "title", "count", "uniques"])

WINDOWS = (7, 30)


# ── gh ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

class GhError(Exception):
    pass

def gh_api(endpoint, token=None, paginate=False):
    cmd = ["gh", "api", endpoint] + (["--paginate", "--slurp"] if paginate else [])
    env = dict(os.environ, **({"GH_TOKEN": token} if token else {}))
    p = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if p.returncode != 0:
        raise GhError((p.stderr or p.stdout).strip())
    data = json.loads(p.stdout)
    return [x for page in data for x in page] if paginate else data

def warn(title, message):
    # an annotation on the run page in Actions, plain text anywhere else
    if os.environ.get("GITHUB_ACTIONS"):
        print(f"::warning title={title}::{message}")
    else:
        print(f"warning: {title}: {message}", file=sys.stderr)


# ── csv ────────────────────────────────────────────────────────────────────────────────────────────────────────────

def read_csv(path):
    if not path.exists():
        return []
    with open(path, newline="") as f:
        return list(csv.DictReader(f))

def write_csv(path, fields, rows):
    with open(path, "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(fields)
        w.writerows(rows)

def replace_snapshot(data, spec, date, rows):
    """Files that hold one set of rows per snapshot date: running it twice on a day leaves that day's rows, not two."""
    name, fields = spec
    kept = [[r[k] for k in fields] for r in read_csv(data / name) if r["date"] != date]
    write_csv(data / name, fields, sorted(kept + [[str(v) for v in r] for r in rows]))

def merge_daily(data, spec, rows):
    """Files keyed by calendar day, as GitHub reports it. The newest fetch wins: the last day it reports is partial."""
    name, fields = spec
    by_day = {r["date"]: [r[k] for k in fields] for r in read_csv(data / name)}
    by_day.update({r[0]: [str(v) for v in r] for r in rows})
    write_csv(data / name, fields, [by_day[d] for d in sorted(by_day)])


# ── collect ────────────────────────────────────────────────────────────────────────────────────────────────────────

def collect(repo, data, date):
    data.mkdir(parents=True, exist_ok=True)

    releases = [r for r in gh_api(f"repos/{repo}/releases", paginate=True) if not r["draft"]]
    rows = [[date, r["tag_name"], (r["published_at"] or "")[:10], a["name"], a["download_count"]]
            for r in releases for a in r["assets"]]
    replace_snapshot(data, DOWNLOADS, date, rows)
    print(f"downloads: {len(rows)} assets in {len(releases)} releases, {sum(r[4] for r in rows)} downloads in all")

    info = gh_api(f"repos/{repo}")
    replace_snapshot(data, REPO, date, [[date, info["stargazers_count"], info["forks_count"], info["subscribers_count"]]])
    print(f"repo: {info['stargazers_count']} stars, {info['forks_count']} forks, {info['subscribers_count']} watchers")

    # The traffic endpoints want push access; the Actions GITHUB_TOKEN does not have it, so STATS_TOKEN stands in.
    token = os.environ.get("STATS_TOKEN")
    try:
        views = gh_api(f"repos/{repo}/traffic/views", token)["views"]
        clones = gh_api(f"repos/{repo}/traffic/clones", token)["clones"]
        referrers = gh_api(f"repos/{repo}/traffic/popular/referrers", token)
        paths = gh_api(f"repos/{repo}/traffic/popular/paths", token)
    except GhError as e:
        warn("Traffic not collected", f"{e} (the traffic API needs push access: set the STATS_TOKEN secret, see "
                                      f"tools/release-stats/README.md)")
        return
    merge_daily(data, VIEWS, [[v["timestamp"][:10], v["count"], v["uniques"]] for v in views])
    merge_daily(data, CLONES, [[c["timestamp"][:10], c["count"], c["uniques"]] for c in clones])
    replace_snapshot(data, REFERRERS, date, [[date, r["referrer"], r["count"], r["uniques"]] for r in referrers])
    replace_snapshot(data, PATHS, date, [[date, p["path"], p["title"], p["count"], p["uniques"]] for p in paths])
    print(f"traffic: {len(views)} days of views, {len(clones)} days of clones, "
          f"{len(referrers)} referrers, {len(paths)} paths")


# ── report ─────────────────────────────────────────────────────────────────────────────────────────────────────────

class Directory:
    def __init__(self, path):
        self.path = Path(path)
    def rows(self, spec):
        return read_csv(self.path / spec[0])

class GitBranch:
    """The same files, read from origin/stats without checking it out."""
    def __init__(self, branch):
        self.ref = f"origin/{branch}"
        here = Path(__file__).resolve().parent
        self.run = lambda *a: subprocess.run(["git", *a], cwd=here, capture_output=True, text=True)
        fetched = self.run("fetch", "--quiet", "origin", branch)
        if fetched.returncode != 0 and self.run("rev-parse", "--verify", "--quiet", self.ref).returncode != 0:
            sys.exit(f"no `{branch}` branch on origin yet. The Release stats workflow creates it on its first run, or "
                     f"collect locally and report from there:\n"
                     f"  {sys.argv[0]} collect --data DIR && {sys.argv[0]} report --data DIR")
    def rows(self, spec):
        p = self.run("show", f"{self.ref}:{spec[0]}")
        return list(csv.DictReader(p.stdout.splitlines())) if p.returncode == 0 else []

def is_release(tag):
    # test-data and ci-assets hold fixtures that CI downloads on every run; they are not the product
    return tag.startswith("release/")

def platform(name):
    n = name.lower()
    if n.endswith((".pkg", ".dmg")): return "macOS"
    if n.endswith((".deb", ".rpm", ".appimage")): return "Linux"
    if n.endswith(".exe") or "windows" in n: return "Windows"
    return "other"

def flavor(name):
    n = name.lower()
    if n.startswith("star-desktop"): return "desktop (Kotlin)"
    if "_app_" in n: return "app (SwiftUI)"
    if "_cli_" in n or n.startswith("star_"): return "cli"
    return "other"

def baseline(dates, latest, days):
    """The snapshot to diff `latest` against for a window of `days` days, and whether the history is too short for it."""
    cutoff = (dt.date.fromisoformat(latest) - dt.timedelta(days=days)).isoformat()
    older = [d for d in dates if d <= cutoff]
    if older:
        return older[-1], False
    return (dates[0], True) if dates[0] != latest else (None, True)

def new_downloads(snaps, dates, latest, days, keep):
    base, partial = baseline(dates, latest, days)
    if base is None:
        return "—"
    # an asset missing from the baseline is new since then; one that went down was deleted and re-uploaded
    n = sum(max(0, c - snaps[base].get(k, 0)) for k, c in snaps[latest].items() if keep(*k))
    return f"+{n}" + ("*" if partial else "")

def table(head, rows):
    out = ["| " + " | ".join(head) + " |", "|---|" + "---:|" * (len(head) - 1)]
    return "\n".join(out + ["| " + " | ".join(str(c) for c in r) + " |" for r in rows])

def downloads_section(src):
    snaps, published = defaultdict(dict), {}
    for r in src.rows(DOWNLOADS):
        snaps[r["date"]][(r["tag"], r["asset"])] = int(r["downloads"])
        published[r["tag"]] = r["published"]
    if not snaps:
        return None, "_No download snapshots yet._"
    dates = sorted(snaps)
    latest, assets = dates[-1], snaps[dates[-1]]

    def growth(keep):
        return [new_downloads(snaps, dates, latest, w, keep) for w in WINDOWS]
    def total(keep):
        return sum(c for k, c in assets.items() if keep(*k))

    product = lambda tag, asset: is_release(tag)
    head = [f"{w}d" for w in WINDOWS]
    out = [f"## Downloads\n\n**{total(product)}** all time across {len({t for t, _ in assets if is_release(t)})} "
           f"releases · new: " + " · ".join(f"{h} **{g}**" for h, g in zip(head, growth(product)))]

    for title, of in (("Platform", lambda a: platform(a)), ("Product", lambda a: flavor(a))):
        groups = sorted({of(a) for t, a in assets if is_release(t)})
        rows = [[g, total(lambda t, a: is_release(t) and of(a) == g),
                 *growth(lambda t, a: is_release(t) and of(a) == g)] for g in groups]
        out.append(table([title, "all time"] + [f"+{h}" for h in head], sorted(rows, key=lambda r: -r[1])))

    tags = sorted({t for t, _ in assets if is_release(t)}, key=lambda t: published.get(t, ""), reverse=True)
    rows = [[t.removeprefix("release/"), published.get(t, ""), total(lambda tag, a: tag == t),
             *growth(lambda tag, a: tag == t)] for t in tags[:10]]
    out.append(f"### Latest releases\n\n" + table(["release", "published", "all time"] + [f"+{h}" for h in head], rows))
    if tags[10:]:
        out.append(f"{len(tags) - 10} older releases: {total(lambda tag, a: tag in tags[10:])} downloads.")

    ci = total(lambda t, a: not is_release(t))
    notes = [f"Fixture releases (`test-data`, `ci-assets`): {ci} downloads, nearly all CI. Not counted above."]
    if any(g.endswith("*") for g in growth(product)):
        notes.append(f"`*` history starts {dates[0]}; the figure is the growth since then.")
    if len(dates) == 1:
        notes.append("Growth appears from the second snapshot on.")
    return (dates[0], latest), "\n\n".join(out + notes)

def traffic_section(src):
    views = {r["date"]: r for r in src.rows(VIEWS)}
    clones = {r["date"]: r for r in src.rows(CLONES)}
    if not views and not clones:
        return "## Traffic\n\n_No traffic recorded. The traffic API needs push access: see README.md, “Traffic”._"
    weeks = defaultdict(lambda: [0, 0, 0, 0])
    for d in sorted(set(views) | set(clones)):
        day = dt.date.fromisoformat(d)
        w = weeks[(day - dt.timedelta(days=day.weekday())).isoformat()]
        for i, series in ((0, views), (2, clones)):
            if d in series:
                w[i] += int(series[d]["count"])
                w[i + 1] += int(series[d]["uniques"])
    rows = [[wk, *weeks[wk]] for wk in sorted(weeks)[-8:]]
    out = ["## Traffic",
           table(["week of", "views", "unique viewer-days", "clones", "unique cloner-days"], rows),
           "A viewer-day is one unique visitor on one day, so these add up daily uniques, not weekly ones. Clones are "
           "mostly CI and the developer's own machines. The latest week is usually partial."]

    for spec, head, cols in ((REFERRERS, "Referrers", ["referrer"]), (PATHS, "Popular pages", ["path"])):
        snap = src.rows(spec)
        if not snap:
            continue
        latest = max(r["date"] for r in snap)
        top = sorted((r for r in snap if r["date"] == latest), key=lambda r: -int(r["count"]))[:10]
        out.append(f"### {head} (the 14 days to {latest})\n\n" + table(
            [cols[0], "views", "unique"], [[r[cols[0]].replace("/brianm998/starry_timelapse_airplane_remover", "") or "/",
                                            r["count"], r["uniques"]] for r in top]))
    return "\n\n".join(out)

def repo_section(src):
    rows = src.rows(REPO)
    if not rows:
        return ""
    last = rows[-1]
    line = f"## Repository\n\n★ **{last['stars']}** stars · {last['forks']} forks · {last['watchers']} watching"
    dates = [r["date"] for r in rows]
    base, partial = baseline(dates, last["date"], 30)
    if base:
        before = next(r for r in rows if r["date"] == base)
        line += f" · stars {int(last['stars']) - int(before['stars']):+d} since {base}"
    return line

def report(src):
    span, downloads = downloads_section(src)
    head = "# star: downloads and traffic"
    if span:
        n = len({r["date"] for r in src.rows(DOWNLOADS)})
        head += f"\n\nLatest snapshot {span[1]}." + (f" {n} snapshots since {span[0]}." if n > 1 else " It is the first.")
    return "\n\n".join(s for s in (head, downloads, repo_section(src), traffic_section(src)) if s) + "\n"


# ── main ───────────────────────────────────────────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect", help="add a snapshot to the CSVs in --data")
    c.add_argument("--data", required=True, help="directory holding the CSVs")
    c.add_argument("--repo", help="owner/name; default the current directory's repo")
    c.add_argument("--date", help="snapshot date YYYY-MM-DD; default today, UTC")
    r = sub.add_parser("report", help="print the markdown summary")
    r.add_argument("--data", help=f"directory holding the CSVs; default the `{BRANCH}` branch on origin")
    a = ap.parse_args()

    if a.cmd == "collect":
        repo = a.repo or os.environ.get("GITHUB_REPOSITORY") or gh_api_repo()
        date = a.date or dt.datetime.now(dt.timezone.utc).date().isoformat()
        try:
            collect(repo, Path(a.data), date)
        except GhError as e:
            sys.exit(f"gh failed: {e}")
    else:
        print(report(Directory(a.data) if a.data else GitBranch(BRANCH)), end="")

def gh_api_repo():
    p = subprocess.run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"cannot tell which repo this is, pass --repo owner/name: {p.stderr.strip()}")
    return p.stdout.strip()

if __name__ == "__main__":
    main()
