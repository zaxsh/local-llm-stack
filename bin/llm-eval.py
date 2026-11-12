#!/usr/bin/env python3
"""Run the capability suite against one local llama.cpp server and grade it.

Every score here is decided by a program: exact comparison, a regex, a JSON schema, or - for the code
items - by executing the model's function against unit tests it never sees. There is no judge model
and no human reading answers, which is the only way a score of "6/6" means anything at this scale.

    python bin/llm-eval.py --url http://127.0.0.1:8083/v1 --alias gemma-4-e4b --ctx 131072 \
        --out bench/eval-gemma4.json

Exit code 0 even when the model scores zero - a zero is data.
"""
import argparse
import json
import os
import random
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

# ---------------------------------------------------------------- transport

def chat(url, alias, messages, max_tokens, temperature=0.0, tools=None, timeout=600):
    payload = {
        "model": alias,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "top_p": 1.0,
        "stream": False,
    }
    if tools:
        payload["tools"] = tools
        payload["tool_choice"] = "auto"
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url.rstrip("/") + "/chat/completions", data=data,
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = json.loads(r.read().decode("utf-8", "replace"))
    return body, time.time() - t0

# ---------------------------------------------------------------- extraction

NUM = re.compile(r"-?\d+(?:[.,]\d+)?")


def tidy(s):
    """Normalise a comma decimal separator without touching thousands separators."""
    return re.sub(r"(?<=\d),(?=\d{1,2}\D|$)", ".", s)


def answer_part(text):
    """Everything after the last ANSWER: marker, else the whole reply."""
    if not text:
        return ""
    idx = text.rfind("ANSWER:")
    if idx >= 0:
        return text[idx + len("ANSWER:"):].strip()
    return text.strip()


def first_number(s):
    s = tidy(s)
    for m in NUM.finditer(s):
        raw = m.group(0)
        try:
            return float(raw.replace(",", "."))
        except ValueError:
            continue
    return None


def last_number(s):
    s = tidy(s)
    nums = [m.group(0) for m in NUM.finditer(s)]
    for raw in reversed(nums):
        try:
            return float(raw.replace(",", "."))
        except ValueError:
            continue
    return None


def parse_json_loose(s):
    """Pull the first complete JSON object out of prose or a code fence.

    Walking brace positions with raw_decode rather than slicing first-{ to last-} matters: models that
    keep talking after the object produce a trailing fragment, and the slice then fails to parse even
    though a perfectly good object is sitting at the front.
    """
    if not s:
        return None
    for blob in (s, re.sub(r"```(?:json)?\s*|\s*```", "", s)):
        decoder = json.JSONDecoder()
        for start in (i for i, ch in enumerate(blob) if ch == "{"):
            try:
                obj, _ = decoder.raw_decode(blob[start:])
                if isinstance(obj, dict):
                    return obj
            except json.JSONDecodeError:
                continue
    return None


def python_block(s):
    """The model's code, without the prose around it.

    A model that writes the function once, then repeats it after the `ANSWER:` marker (the marker is
    part of the contract, so a code answer ends up restating itself) would otherwise have both copies
    concatenated, and the second copy starts on a line that reads "ANSWER: def ..." - a SyntaxError
    caused by the harness, not by the model. Cutting at the marker fixes that, and an unterminated
    fence - the model ran out of tokens before writing ``` - falls through to the same cut.
    """
    if not s:
        return ""
    m = re.search(r"```(?:python|py)?\s*\n(.*?)```", s, re.S)
    body = m.group(1) if m else (s if "def " in s else "")
    return body.split("ANSWER:")[0].rstrip()

# ---------------------------------------------------------------- graders

def grade_numeric(item, reply):
    seg = answer_part(reply) or reply
    got = last_number(seg)
    if got is None:
        got = last_number(reply)
    if got is None:
        return False, None
    want = float(item["answer"])
    return abs(got - want) < 1e-6, got


def grade_choice(item, reply):
    """Accept the option letter, or the option's own text.

    Both are correct answers. A model that writes "ANSWER: 1945" for option (C) "1945" has answered the
    question; refusing it would test whether it guessed the expected format, not whether it knows the
    fact. Text matching only counts when exactly one option matches, so an answer that mentions two
    options is not credited by accident.
    """
    seg = answer_part(reply).strip()
    m = re.search(r"\b([A-D])\b", seg)
    if not m:
        m = re.search(r"\b([A-D])\b", reply or "")
    got = m.group(1) if m else None
    if got == item.get("answer"):
        return True, got
    options = {mm.group(1): mm.group(2).strip()
               for mm in re.finditer(r"^\(([A-D])\)\s*(.+?)\s*$", item.get("prompt", ""), re.M)}
    low = seg.lower()
    hits = [k for k, v in options.items() if len(v) >= 2 and v.lower() in low]
    if len(hits) == 1:
        return hits[0] == item.get("answer"), hits[0] + " (" + options[hits[0]] + ")"
    return got == item.get("answer"), got


def norm_scalar(s):
    """Compare identifiers the way a human would: "Order #A-1187", "#A-1187" and "A-1187" are one id.

    The first version of this item demanded exactly "A-1187" and five of seven models wrote
    "#A-1187". When a majority of models answer the same way and the key disagrees, the key is usually
    the thing that is wrong - it was measuring a formatting convention the prompt never stated.
    """
    t = str(s).strip().lower()
    t = re.sub(r"^order\s*", "", t)
    t = re.sub(r"^[#\s]+", "", t)
    return re.sub(r"[^a-z0-9\-_.]", "", t)


def grade_json(item, reply):
    got = parse_json_loose(answer_part(reply) or reply)
    if not isinstance(got, dict):
        return False, None
    ok = True
    for key, want in item["answer"].items():
        if key not in got:
            ok = False
            continue
        have = got[key]
        if isinstance(want, (int, float)) and not isinstance(want, bool):
            try:
                ok = ok and abs(float(have) - float(want)) < 1e-6
            except (TypeError, ValueError):
                ok = False
        elif isinstance(want, list):
            h = {norm_scalar(x) for x in have} if isinstance(have, list) else {norm_scalar(have)}
            ok = ok and {norm_scalar(x) for x in want} <= h
        else:
            ok = ok and norm_scalar(have) == norm_scalar(want)
    return ok, got


def grade_code(item, reply):
    code = python_block(reply)
    if not code.strip():
        return False, "no code block"
    script = code + "\n\n" + "\n".join(item["tests"]) + "\n"
    fd, path = tempfile.mkstemp(suffix=".py")
    os.close(fd)
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(script)
        p = subprocess.run([sys.executable, path], capture_output=True, text=True, timeout=20,
                           cwd=os.path.dirname(path))
        if p.returncode == 0:
            return True, "tests pass"
        err = (p.stderr or "").strip().splitlines()
        return False, (err[-1][:160] if err else f"exit {p.returncode}")
    except subprocess.TimeoutExpired:
        return False, "timeout"
    except Exception as exc:                      # noqa: BLE001 - any failure is a failed item
        return False, str(exc)[:160]
    finally:
        try:
            os.remove(path)
        except OSError:
            pass


def grade_constraints(item, reply):
    text = (reply or "").strip()
    # the model may still have wrapped the answer in a fence; for format items that is a miss, but
    # stripping one surrounding fence keeps the test about the constraint and not about markdown
    m = re.fullmatch(r"```[a-zA-Z]*\s*\n(.*?)\n```", text, re.S)
    if m:
        text = m.group(1).strip()
    lines = [ln for ln in text.splitlines() if ln.strip()]
    fails = []
    for c in item["constraints"]:
        rule, val = c["rule"], c.get("value")
        if rule == "lines":
            ok = len(lines) == val
        elif rule == "every_line_matches":
            ok = bool(lines) and all(re.match(val, ln) for ln in lines)
        elif rule == "no_answer_tag":
            ok = "ANSWER:" not in text
        elif rule == "regex_full":
            ok = re.fullmatch(val, text) is not None
        elif rule == "word_count":
            ok = len(re.findall(r"[A-Za-z0-9']+", re.sub(r"[.,!?;:]", " ", text))) == val
        elif rule == "max_words":
            ok = len(re.findall(r"[A-Za-z0-9']+", text)) <= val
        elif rule == "ends_with":
            ok = text.endswith(val)
        elif rule == "uppercase":
            ok = text == text.upper() and any(ch.isalpha() for ch in text)
        elif rule == "contains":
            ok = val.lower() in text.lower()
        elif rule == "json_equals":
            got = parse_json_loose(text)
            ok = got == val
        else:
            ok = False
        if not ok:
            fails.append(rule)
    return not fails, ("ok" if not fails else "failed: " + ",".join(fails))


def grade_tool(item, body):
    msg = body["choices"][0]["message"]
    calls = msg.get("tool_calls") or []
    name, args = None, None
    if calls:
        fn = calls[0].get("function", {})
        name = fn.get("name")
        raw = fn.get("arguments")
        try:
            args = json.loads(raw) if isinstance(raw, str) else raw
        except json.JSONDecodeError:
            args = raw
    else:
        blob = parse_json_loose(msg.get("content") or "")
        if isinstance(blob, dict) and "name" in blob:
            name = blob.get("name")
            a = blob.get("arguments", blob.get("args"))
            args = json.loads(a) if isinstance(a, str) else a
    if name != item["expect"]["name"]:
        return False, {"name": name, "args": args}
    want = item["expect"]["args"]
    if not isinstance(args, dict):
        return False, {"name": name, "args": args}
    for key, val in want.items():
        if key == "query_contains":
            q = str(args.get("query", "")).lower()
            if not all(tok in q for tok in val):
                return False, {"name": name, "args": args}
        elif str(args.get(key, "")).strip().lower() != str(val).strip().lower():
            return False, {"name": name, "args": args}
    return True, {"name": name, "args": args}


def grade_needle(item, reply):
    got = (answer_part(reply) or reply or "").lower()
    got = re.sub(r"[^a-z0-9 ]", "", got)
    want = re.sub(r"[^a-z0-9 ]", "", item["target"].lower())
    return want in got, (answer_part(reply) or "")[:80]

# ---------------------------------------------------------------- needle filler

WORDS = ("alpha bravo cedar delta ember falcon garnet harbor indigo juniper kettle lantern meadow "
         "nickel orchid pepper quartz river sierra timber umber velvet willow xenon yarrow zephyr "
         "amber basalt cobalt dune flint gravel hollow iris jade kelp lumen marble nimbus onyx "
         "prism quill reed slate topaz vault willow").split()


def filler_words(n_words, rng):
    out = []
    while len(out) < n_words:
        out.extend(rng.choice(WORDS) for _ in range(40))
    return " ".join(out[:n_words])


def build_needle(item, ctx):
    # Half of the model's own window, capped so a 131k model does not take ten minutes per item.
    budget_tokens = min(int(ctx * 0.45), 18000)
    total = int(budget_tokens * 0.75)
    depth = float(item.get("depth", 0.5))
    head = int(total * depth)
    rng = random.Random(hash(item["id"]) & 0xFFFF)
    before = filler_words(head, rng)
    after = filler_words(total - head, rng)
    doc = (before + "\n\n" + "Vault passphrase: " + item["secret"] + ".\n\n" + after)
    prompt = ("Read the document below, then answer the question about it.\n\n"
              "<document>\n" + doc + "\n</document>\n\nQuestion: " + item["question"])
    return prompt, total

# ---------------------------------------------------------------- main

TOOLS = [
    {"type": "function", "function": {
        "name": "get_weather",
        "description": "Current or forecast weather for a city.",
        "parameters": {"type": "object", "properties": {
            "city": {"type": "string", "description": "city name"},
            "when": {"type": "string", "description": "now, today, tomorrow"}},
            "required": ["city"]}}},
    {"type": "function", "function": {
        "name": "search_notes",
        "description": "Search the user's personal notes.",
        "parameters": {"type": "object", "properties": {
            "query": {"type": "string", "description": "what to look for"}},
            "required": ["query"]}}},
]


def self_test(suite):
    """Feed each item its own gold answer and require the grader to accept it.

    A benchmark with a broken extractor is worse than no benchmark: every model scores zero and the
    zero looks like a finding. This runs before any model is started.
    """
    bad = []
    for it in suite["items"]:
        kind = it["kind"]
        if kind in ("numeric", "choice"):
            ok, got = (grade_numeric if kind == "numeric" else grade_choice)(it, "ANSWER: " + str(it["answer"]))
        elif kind == "json":
            ok, got = grade_json(it, "ANSWER: " + json.dumps(it["answer"]))
        elif kind == "needle":
            ok, got = grade_needle(it, "ANSWER: " + it["target"])
        elif kind == "constraints":
            ok, got = grade_constraints(it, it["gold"])
        elif kind == "code":
            ok, got = grade_code(it, "```python\n" + it["gold"] + "\n```")
        elif kind == "tool":
            e = it["expect"]
            args = {}
            for k, v in e["args"].items():
                args["query" if k == "query_contains" else k] = " ".join(v) if k == "query_contains" else v
            fake = {"choices": [{"message": {"tool_calls": [{"function": {"name": e["name"], "arguments": json.dumps(args)}}]}}]}
            ok, got = grade_tool(it, fake)
        else:
            ok, got = False, "unknown kind"
        if not ok:
            bad.append((it["id"], got))
    if bad:
        print("  GRADER SELF-TEST FAILED - fix the grader before measuring models:", flush=True)
        for b in bad:
            print("   ", b, flush=True)
        return False
    print(f"  grader self-test: all {len(suite['items'])} gold answers grade as correct", flush=True)
    return True


def wilson(k, n):
    if n == 0:
        return 0.0, 0.0
    z = 1.96
    p = k / n
    d = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / d
    half = z * ((p * (1 - p) / n) + z * z / (4 * n * n)) ** 0.5 / d
    return max(0.0, centre - half), min(1.0, centre + half)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--alias", required=True)
    ap.add_argument("--ctx", type=int, default=8192)
    ap.add_argument("--suite", default=os.path.join(os.path.dirname(__file__), "..", "bench", "capability-suite-v1.json"))
    ap.add_argument("--out", required=True)
    ap.add_argument("--only", default="", help="comma list of categories")
    ap.add_argument("--skip-needle", action="store_true")
    ap.add_argument("--self-test", action="store_true", help="grade the gold answers and exit")
    ap.add_argument("--merge", action="store_true", help="replace only the items re-run, keep the rest")
    ap.add_argument("--budget-scale", type=float, default=1.0, help="multiply every max_tokens (same factor for every model)")
    args = ap.parse_args()

    with open(args.suite, encoding="utf-8") as f:
        suite = json.load(f)
    keep = {c.strip() for c in args.only.split(",") if c.strip()}
    if args.self_test:
        sys.exit(0 if self_test(suite) else 1)
    items = [i for i in suite["items"] if not keep or i["category"] in keep]
    if args.skip_needle:
        items = [i for i in items if i["kind"] != "needle"]

    results = []
    for it in items:
        suffix = "" if it.get("no_suffix") else suite.get("suffix", "")
        if it["kind"] == "needle":
            prompt, est = build_needle(it, args.ctx)
            suffix, extra = "", {"needle_tokens": est}
        else:
            prompt, extra = it["prompt"] + suffix, {}
        messages = [{"role": "user", "content": prompt}]
        tools = TOOLS if it["kind"] == "tool" else None
        t0 = time.time()
        try:
            budget = max(64, int(it.get("max_tokens", 600) * args.budget_scale))
            body, elapsed = chat(args.url, args.alias, messages, budget, tools=tools)
            msg = body["choices"][0]["message"]
            reply = msg.get("content") or ""
            reasoning = msg.get("reasoning_content") or ""
            finish = body["choices"][0].get("finish_reason")
            usage = body.get("usage", {})
            if it["kind"] == "numeric":
                ok, got = grade_numeric(it, reply)
            elif it["kind"] == "choice":
                ok, got = grade_choice(it, reply)
            elif it["kind"] == "json":
                ok, got = grade_json(it, reply)
            elif it["kind"] == "code":
                ok, got = grade_code(it, reply)
            elif it["kind"] == "constraints":
                ok, got = grade_constraints(it, reply)
            elif it["kind"] == "tool":
                ok, got = grade_tool(it, body)
            elif it["kind"] == "needle":
                ok, got = grade_needle(it, reply)
            else:
                ok, got = False, "unknown kind"
            results.append({"id": it["id"], "category": it["category"], "ok": bool(ok), "no_answer": bool(ok is False and (got is None or (isinstance(got, str) and not got.strip()))),
                            "reply": (reply or "").replace("\n", "\u23ce"),
                            "budget_exhausted": finish == "length",
                            "got": got if not isinstance(got, (dict, list)) else json.dumps(got)[:200],
                            "seconds": round(time.time() - t0, 2), "finish": finish,
                            "prompt_tokens": usage.get("prompt_tokens"),
                            "completion_tokens": usage.get("completion_tokens"),
                            "reasoning_chars": len(reasoning), **extra})
        except urllib.error.URLError as exc:
            results.append({"id": it["id"], "category": it["category"], "ok": False,
                            "got": "transport error: " + str(exc)[:120], "seconds": round(time.time() - t0, 2),
                            "finish": "error", **extra})
        except Exception as exc:                  # noqa: BLE001
            results.append({"id": it["id"], "category": it["category"], "ok": False,
                            "got": "error: " + str(exc)[:120], "seconds": round(time.time() - t0, 2),
                            "finish": "error", **extra})
        r = results[-1]
        print(f"  {r['id']:<12} {'PASS' if r['ok'] else 'fail'}  {r['seconds']:>6.1f}s  {str(r['got'])[:60]}",
              flush=True)

    # per-category tally with a Wilson interval, because 5/6 and 4/5 are not 83 % and 80 % of anything
    cats = {}
    for r in results:
        c = cats.setdefault(r["category"], {"n": 0, "pass": 0})
        c["n"] += 1
        c["pass"] += 1 if r["ok"] else 0


    for c in cats.values():
        c["pct"] = round(100.0 * c["pass"] / c["n"], 1)
        c["lo"], c["hi"] = [round(100 * x, 1) for x in wilson(c["pass"], c["n"])]
    macro = round(sum(c["pct"] for c in cats.values()) / len(cats), 1) if cats else 0.0

    if args.merge and os.path.exists(args.out):
        with open(args.out, encoding="utf-8") as f:
            previous = json.load(f)
        by_id = {i["id"]: i for i in previous.get("items", [])}
        for r in results:
            by_id[r["id"]] = r
        results = list(by_id.values())
        cats = {}
        for r in results:
            c = cats.setdefault(r["category"], {"n": 0, "pass": 0})
            c["n"] += 1
            c["pass"] += 1 if r["ok"] else 0
        for c in cats.values():
            c["pct"] = round(100.0 * c["pass"] / c["n"], 1)
            c["lo"], c["hi"] = [round(100 * x, 1) for x in wilson(c["pass"], c["n"])]
        macro = round(sum(c["pct"] for c in cats.values()) / len(cats), 1) if cats else 0.0

    out = {"model": os.path.basename(args.out).replace("eval-", "").replace(".json", ""),
           "alias": args.alias, "ctx": args.ctx, "suite": suite["name"],
           "when": time.strftime("%Y-%m-%d %H:%M:%S"), "categories": cats,
           "macro": macro, "items": results}
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)
    print(f"\n  macro {macro:.1f}   " + "  ".join(f"{k} {v['pass']}/{v['n']}" for k, v in sorted(cats.items())),
          flush=True)


if __name__ == "__main__":
    main()
