#!/usr/bin/env python3
"""Compares Juxta's line diff with `git diff --no-index` (myers, patience, histogram).

    scripts/compare-git.py Fixtures/pairs/*/                 # fixture folders (left.*, right.*)
    scripts/compare-git.py a.cfg b.cfg c.cfg d.cfg            # file pairs
    scripts/compare-git.py --repo ~/src/configs --commits 300 --paths '*.cfg' '*.conf'
    ... --csv results.csv --keep /tmp/pairs                   # save rows / the extracted pairs

With --repo, walks the last N non-merge commits (touching --paths, if given) and diffs each
modified text file's before/after blobs. Juxta's changed lines are deleted + inserted +
2 x modified (a modified row is one line on each side), comparable to git's added + removed.
A missing final newline is added before running git, which would otherwise count the last
line as changed; pairs whose line endings, encoding or BOM differ are skipped.
Pairs where Juxta exceeds histogram by more than 20% and more than 5 lines are flagged.
Needs a release build: swift build -c release (binary at .build/release/juxta-diff).
"""

import argparse
import csv
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALGORITHMS = ("myers", "patience", "histogram")
REGULAR = ("100644", "100755")  # file modes; not symlinks or submodules


def git_diff(left, right, algorithm):
    """(added + removed, change runs) from git, or None for binary files. Each run is
    ((left start, count), (right start, count)), 1-based like Juxta's hunks. Runs are read
    from a normal 3-line-context diff: git places changes differently with -U0."""
    out = subprocess.run(
        ["git", "-c", "core.quotepath=off", "diff", "--no-index", "--no-color", "--no-ext-diff",
         "--no-textconv", "--numstat", "-p", f"--diff-algorithm={algorithm}", "--", left, right],
        capture_output=True).stdout
    total, runs, run, a, b = None, [], None, 0, 0
    for line in out.split(b"\n"):
        if total is None:
            if b"\t" in line:
                added, removed = line.split(b"\t")[:2]
                if added == b"-":
                    return None
                total = int(added) + int(removed)
            continue
        header = re.match(rb"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", line)
        if header:
            # An empty side's start is the line before it.
            a = int(header[1]) + (header[2] == b"0")
            b = int(header[3]) + (header[4] == b"0")
            run = None
        elif a and line[:1] in (b"-", b"+"):
            if run is None:
                run = [a, 0, b, 0]
                runs.append(run)
            if line[:1] == b"-":
                run[1] += 1
                a += 1
            else:
                run[3] += 1
                b += 1
        elif a and line[:1] == b" ":
            run = None
            a += 1
            b += 1
    return (total or 0, [((r[0], r[1]), (r[2], r[3])) for r in runs])


def juxta(binary, left, right):
    proc = subprocess.run([binary, "--json", left, right], capture_output=True)
    if proc.returncode == 2:
        return None
    return json.loads(proc.stdout)


def with_final_newline(path, copy):
    """`path`, or `copy` with a final line ending added: git counts a missing
    final newline as a changed last line, which Juxta reports as a format difference."""
    data = Path(path).read_bytes()
    if not data or data.endswith((b"\n", b"\r")):
        return path
    ending = b"\r\n" if b"\r\n" in data else b"\r" if b"\r" in data else b"\n"
    Path(copy).write_bytes(data + ending)
    return str(copy)


def compare(binary, label, left, right):
    """A result row, "binary", or "format" when the files' line endings, encoding or byte
    order mark differ (git then counts every line affected; Juxta counts none)."""
    j = juxta(binary, left, right)
    if j is None:
        return "binary"
    if set(j["hiddenDifferences"]) - {"final newline"}:
        return "format"
    row = {"pair": label, "left": left, "right": right,
           "juxta": j["deleted"] + j["inserted"] + 2 * j["modified"], "juxta_hunks": len(j["hunks"]),
           "modified": j["modified"], "deleted": j["deleted"], "inserted": j["inserted"],
           "approximate": j["approximate"], "lines": max(j["leftLines"], j["rightLines"]), "ms": j["ms"]}
    with tempfile.TemporaryDirectory(prefix="juxta-compare-") as folder:
        if j["hiddenDifferences"]:
            left = with_final_newline(left, Path(folder) / "left")
            right = with_final_newline(right, Path(folder) / "right")
        for algorithm in ALGORITHMS:
            g = git_diff(left, right, algorithm)
            if g is None:
                return "binary"
            row[algorithm], runs = g
            row[algorithm + "_hunks"] = len(runs)
            if algorithm == "histogram":
                hunks = [((h["left"]["start"], h["left"]["count"]), (h["right"]["start"], h["right"]["count"]))
                         for h in j["hunks"]]
                # Same lines changed, placed differently: usually a slider choice.
                row["boundaries_differ"] = row["juxta"] == g[0] and hunks != runs
    return row


def fixture_pairs(paths):
    """(label, left, right) from fixture folders and/or consecutive file pairs."""
    pairs, files = [], []
    for p in map(Path, paths):
        if p.is_dir():
            left, right = sorted(p.glob("left.*")), sorted(p.glob("right.*"))
            if left and right:
                pairs.append((p.name, str(left[0]), str(right[0])))
        else:
            files.append(p)
    if len(files) % 2:
        sys.exit("compare-git: file arguments must come in pairs")
    for a, b in zip(files[::2], files[1::2]):
        pairs.append((f"{a} {b}", str(a), str(b)))
    return pairs


def git(repo, *args, input=None):
    return subprocess.run(["git", "-C", repo, *args], input=input, capture_output=True, check=True).stdout


def repo_pairs(repo, commits, paths, per_commit, max_bytes, out):
    """Writes before/after blobs of modified files in the last `commits` commits to `out`."""
    pathspec = ["--", *paths] if paths else []
    shas = git(repo, "log", "--no-merges", f"-n{commits}", "--format=%H", *pathspec).decode().split()
    changes = []
    for sha in shas:
        raw = git(repo, "diff-tree", "-r", "--no-commit-id", "--no-renames", "--diff-filter=M",
                  "--raw", "-z", sha, *pathspec).split(b"\0")
        found = []
        for meta, name in zip(raw[::2], raw[1::2]):
            fields = meta.decode().split()
            if len(fields) >= 4 and fields[0][1:] in REGULAR and fields[1] in REGULAR:
                found.append((sha, name.decode(errors="replace"), fields[2], fields[3]))
        changes += found[:per_commit]
    blobs = sorted({b for c in changes for b in c[2:]})
    # Partial clones fetch missing blobs one at a time; ask for them all at once instead.
    if _has_promisor(repo):
        for k in range(0, len(blobs), 1000):
            subprocess.run(["git", "-C", repo, "-c", "fetch.negotiationAlgorithm=noop", "fetch", "origin",
                            "--no-tags", "--no-write-fetch-head", "--recurse-submodules=no",
                            "--filter=blob:none", "--stdin"],
                           input="\n".join(blobs[k:k + 1000]).encode(), capture_output=True)
    sizes = {}
    for line in git(repo, "cat-file", "--batch-check", input="\n".join(blobs).encode()).decode().splitlines():
        fields = line.split()
        if len(fields) == 3:
            sizes[fields[0]] = int(fields[2])
    pairs = []
    for n, (sha, name, old, new) in enumerate(changes):
        if max(sizes.get(old, 1 << 62), sizes.get(new, 1 << 62)) > max_bytes:
            continue
        d = out / f"{n:04d}-{sha[:8]}-{Path(name).name}"
        d.mkdir(parents=True, exist_ok=True)
        ext = Path(name).suffix or ".txt"
        for side, blob in (("left", old), ("right", new)):
            (d / f"{side}{ext}").write_bytes(git(repo, "cat-file", "blob", blob))
        (d / "about.txt").write_text(f"{sha} {name}\n")
        pairs.append((f"{sha[:8]} {name}", str(d / f"left{ext}"), str(d / f"right{ext}")))
    return pairs


def _has_promisor(repo):
    return subprocess.run(["git", "-C", repo, "config", "--get-regexp", r"remote\..*\.promisor"],
                          capture_output=True).returncode == 0


def percentile(values, p):
    if not values:
        return float("nan")
    values = sorted(values)
    return values[min(len(values) - 1, int(round(p / 100 * (len(values) - 1))))]


def report(rows, ratio_limit, min_lines):
    for r in rows:
        h = r["histogram"]
        r["ratio"] = r["juxta"] / h if h else (1.0 if r["juxta"] == 0 else float("inf"))
        r["flagged"] = r["juxta"] > h * ratio_limit and r["juxta"] - h > min_lines
    changed = [r for r in rows if r["juxta"] or r["histogram"]]
    print(f"{len(rows)} pairs compared, {len(changed)} with changes")
    print(f"{'':12}{'lines':>10}{'hunks':>10}{'< juxta':>10}{'> juxta':>10}")
    for key in ("juxta",) + ALGORITHMS:
        lines = sum(r[key] for r in rows)
        hunks = sum(r[key + "_hunks"] for r in rows)
        if key == "juxta":
            print(f"{key:12}{lines:>10}{hunks:>10}")
        else:
            fewer = sum(r[key] < r["juxta"] for r in rows)
            more = sum(r[key] > r["juxta"] for r in rows)
            print(f"{key:12}{lines:>10}{hunks:>10}{fewer:>10}{more:>10}")
    print("(< juxta: pairs where git changed fewer lines than Juxta; > juxta: more)")
    ratios = [r["ratio"] for r in changed if r["histogram"]]
    if ratios:
        print(f"juxta / histogram: median {statistics.median(ratios):.3f}, p95 {percentile(ratios, 95):.3f}, "
              f"max {max(ratios):.2f}")
    print(f"same total as histogram: {sum(r['juxta'] == r['histogram'] for r in rows)}; "
          f"hunk count differs: {sum(r['juxta_hunks'] != r['histogram_hunks'] for r in rows)}; "
          f"approximate: {sum(r['approximate'] for r in rows)}")
    ms = [r["ms"] for r in rows]
    if ms:
        print(f"juxta compare time (ms): p50 {percentile(ms, 50):.2f}, p95 {percentile(ms, 95):.2f}, "
              f"max {max(ms):.2f} (largest file {max(r['lines'] for r in rows)} lines)")
    moved = [r for r in rows if r["boundaries_differ"]]
    print(f"same lines changed as histogram, different hunk boundaries: {len(moved)}")
    for r in moved[:10]:
        print(f"  {r['pair']}\n      {r['left']}  {r['right']}")
    flagged = sorted((r for r in rows if r["flagged"]), key=lambda r: r["histogram"] - r["juxta"])
    print(f"flagged (juxta > histogram by >{(ratio_limit - 1) * 100:.0f}% and >{min_lines} lines): {len(flagged)}")
    for r in flagged[:10]:
        print(f"  juxta {r['juxta']:>5} (~{r['modified']} -{r['deleted']} +{r['inserted']})"
              f"  histogram {r['histogram']:>5}  myers {r['myers']:>5}  patience {r['patience']:>5}  {r['pair']}")
        print(f"      {r['left']}  {r['right']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("pairs", nargs="*", help="fixture folders, or files in left/right pairs")
    parser.add_argument("--repo", help="walk this git repository's history instead")
    parser.add_argument("--commits", type=int, default=300)
    parser.add_argument("--paths", nargs="+", default=[], help="pathspecs to restrict --repo to")
    parser.add_argument("--per-commit", type=int, default=20, help="at most this many files per commit")
    parser.add_argument("--max-bytes", type=int, default=4 << 20, help="skip larger files")
    parser.add_argument("--keep", help="write the --repo pairs here instead of a temporary folder")
    parser.add_argument("--csv", help="write one row per pair to this file")
    parser.add_argument("--juxta", default=str(ROOT / ".build/release/juxta-diff"))
    parser.add_argument("--ratio", type=float, default=1.2)
    parser.add_argument("--min-lines", type=int, default=5)
    args = parser.parse_args()
    if not os.access(args.juxta, os.X_OK):
        sys.exit(f"compare-git: no {args.juxta}; run swift build -c release")

    temp = None
    try:
        if args.repo:
            out = Path(args.keep) if args.keep else Path(temp := tempfile.mkdtemp(prefix="juxta-compare-"))
            pairs = repo_pairs(args.repo, args.commits, args.paths, args.per_commit, args.max_bytes, out)
        else:
            pairs = fixture_pairs(args.pairs)
        with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
            results = list(pool.map(lambda p: compare(args.juxta, *p), pairs))
        rows = [r for r in results if isinstance(r, dict)]
        for reason, why in (("binary", "binary or unreadable"),
                            ("format", "with line-ending, encoding or BOM differences (not comparable)")):
            if skipped := results.count(reason):
                print(f"skipped {skipped} pairs {why}")
        report(rows, args.ratio, args.min_lines)
        if args.csv and rows:
            with open(args.csv, "w", newline="") as f:
                writer = csv.DictWriter(f, fieldnames=list(rows[0]))
                writer.writeheader()
                writer.writerows(rows)
    finally:
        if temp:
            shutil.rmtree(temp, ignore_errors=True)

if __name__ == "__main__":
    main()
