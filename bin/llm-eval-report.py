#!/usr/bin/env python3
"""Turn bench/eval-*.json into the Markdown table used in docs/capability-evaluation.md.

Kept as a script rather than hand-copied numbers: the table is then a function of the raw files, and
re-running the battery regenerates it instead of requiring someone to retype 63 cells correctly.

    python bin/llm-eval-report.py --out results.md
"""
import argparse
import glob
import json
import os

CATS = ["math", "logic", "code", "instr", "json", "needle", "tools", "knowledge"]


def load(pattern):
    out = []
    for path in sorted(glob.glob(pattern)):
        with open(path, encoding="utf-8") as f:
            out.append(json.load(f))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bench", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bench"))
    ap.add_argument("--out", default="")
    args = ap.parse_args()

    runs = load(os.path.join(args.bench, "eval-*.json"))
    if not runs:
        raise SystemExit("no eval-*.json in " + args.bench)

    runs.sort(key=lambda r: -r["macro"])
    lines = []
    lines.append("### The table")
    lines.append("")
    lines.append("Sorted by the unweighted mean of the eight category pass-rates. That mean is a")
    lines.append("convenience for ordering the rows, **not** a capability score — read the profile, and read")
    lines.append("the interval below before believing a gap.")
    lines.append("")
    header = "| model | macro | " + " | ".join(CATS) + " | budget hit |"
    lines.append(header)
    lines.append("|---|--:|" + "|".join(["--:"] * len(CATS)) + "|--:|")
    for r in runs:
        cells = []
        for c in CATS:
            v = r["categories"].get(c)
            cells.append(f"{v['pass']}/{v['n']}" if v else "-")
        hit = sum(1 for i in r["items"] if i.get("budget_exhausted"))
        lines.append(f"| **{r['model']}** | **{r['macro']:.1f}** | " + " | ".join(cells) + f" | {hit} |")
    lines.append("")

    # profile sentences: what each model is actually good at, from its own numbers
    lines.append("### The profile, in words")
    lines.append("")
    for r in runs:
        perfect = [c for c, v in r["categories"].items() if v["pass"] == v["n"]]
        weak = sorted([(v["pass"] / v["n"], c) for c, v in r["categories"].items()])[:2]
        weak = [c for p, c in weak if p < 1.0]
        parts = []
        if perfect:
            parts.append("clean sweep in " + ", ".join(f"`{c}`" for c in sorted(perfect)))
        if weak:
            parts.append("loses points in " + ", ".join(f"`{c}`" for c in weak))
        hit = sum(1 for i in r["items"] if i.get("budget_exhausted"))
        if hit:
            parts.append(f"ran out of its token budget on {hit} item(s), so its row is a lower bound")
        na = sum(1 for i in r["items"] if i.get("no_answer"))
        if na:
            parts.append(f"{na} answer(s) could not be parsed out of the reply")
        lines.append(f"- **{r['model']}** — " + ("; ".join(parts) if parts else "no clear pattern") + ".")
    lines.append("")

    # per-category leader, which is the thing a single aggregate destroys
    lines.append("### Who wins each category")
    lines.append("")
    lines.append("| category | best | score | field median |")
    lines.append("|---|---|---|--:|")
    for c in CATS:
        vals = [(r["categories"][c]["pass"] / r["categories"][c]["n"], r["model"]) for r in runs if c in r["categories"]]
        if not vals:
            continue
        vals.sort(reverse=True)
        best = vals[0]
        med = sorted(v for v, _ in vals)[len(vals) // 2]
        lines.append(f"| `{c}` | {best[1]} | {best[0] * 100:.0f} % | {med * 100:.0f} % |")
    lines.append("")
    text = "\n".join(lines)

    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")
        print("wrote " + args.out)
    else:
        print(text)


if __name__ == "__main__":
    main()
