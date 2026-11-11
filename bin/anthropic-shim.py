#!/usr/bin/env python3
"""
anthropic-shim.py - let Claude Code (and anything else that speaks the Anthropic Messages API)
talk to a local llama.cpp server, which only speaks the OpenAI API.

    python anthropic-shim.py --upstream http://127.0.0.1:8081/v1 --port 8097

Then point Claude Code at it:

    ANTHROPIC_BASE_URL=http://127.0.0.1:8097
    ANTHROPIC_AUTH_TOKEN=local
    ANTHROPIC_MODEL=<whatever>        # llama.cpp ignores the id and uses the loaded model

Why this exists: llama-server has no /v1/messages endpoint (checked against the binary), so
Claude Code cannot talk to it directly. Translation covered here:

  system (string|blocks)        -> system message
  user/assistant text blocks    -> OpenAI messages
  tool_result blocks            -> role=tool messages
  assistant tool_use blocks     -> assistant.tool_calls
  tools / tool_choice           -> OpenAI function definitions
  streaming SSE                 -> Anthropic events, including input_json_delta for tools

Standard library only - no pip install, which matters on a 4 Mbit/s link.
"""

import argparse
import json
import sys
import time
import uuid
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = "http://127.0.0.1:8081/v1"


# ---------------------------------------------------------------- request mapping

def _text_of(content):
    """Anthropic content can be a string or a list of blocks; return plain text."""
    if isinstance(content, str):
        return content
    out = []
    for block in content or []:
        if isinstance(block, str):
            out.append(block)
        elif block.get("type") == "text":
            out.append(block.get("text", ""))
    return "".join(out)


def _tool_result_to_text(block):
    c = block.get("content")
    if isinstance(c, str):
        return c
    parts = []
    for item in c or []:
        if isinstance(item, str):
            parts.append(item)
        elif item.get("type") == "text":
            parts.append(item.get("text", ""))
    return "".join(parts)


def convert_messages(system, messages):
    """Anthropic messages -> OpenAI messages."""
    out = []
    if system:
        out.append({"role": "system", "content": _text_of(system)})

    for msg in messages or []:
        role = msg.get("role")
        content = msg.get("content")

        if isinstance(content, str):
            out.append({"role": role, "content": content})
            continue

        blocks = content or []
        if role == "assistant":
            text_parts, tool_calls = [], []
            for b in blocks:
                t = b.get("type")
                if t == "text":
                    text_parts.append(b.get("text", ""))
                elif t == "tool_use":
                    tool_calls.append({
                        "id": b.get("id") or ("call_" + uuid.uuid4().hex[:12]),
                        "type": "function",
                        "function": {
                            "name": b.get("name", ""),
                            "arguments": json.dumps(b.get("input") or {}, ensure_ascii=False),
                        },
                    })
            m = {"role": "assistant", "content": "".join(text_parts) or None}
            if tool_calls:
                m["tool_calls"] = tool_calls
            out.append(m)
        else:
            # a user turn may carry plain text and/or tool results; OpenAI needs tool
            # results as their own role=tool messages, in order.
            for b in blocks:
                t = b.get("type")
                if t == "tool_result":
                    out.append({
                        "role": "tool",
                        "tool_call_id": b.get("tool_use_id", ""),
                        "content": _tool_result_to_text(b),
                    })
                elif t == "text":
                    txt = b.get("text", "")
                    if txt:
                        out.append({"role": "user", "content": txt})
    return out


def convert_tools(tools):
    if not tools:
        return None
    converted = []
    for t in tools:
        converted.append({
            "type": "function",
            "function": {
                "name": t.get("name", ""),
                "description": t.get("description", ""),
                "parameters": t.get("input_schema") or {"type": "object", "properties": {}},
            },
        })
    return converted


def convert_request(body):
    payload = {
        "messages": convert_messages(body.get("system"), body.get("messages")),
        "stream": bool(body.get("stream")),
    }
    if body.get("model"):
        payload["model"] = body["model"]
    if body.get("max_tokens"):
        payload["max_tokens"] = body["max_tokens"]
    if body.get("temperature") is not None:
        payload["temperature"] = body["temperature"]
    if body.get("top_p") is not None:
        payload["top_p"] = body["top_p"]
    if body.get("stop_sequences"):
        payload["stop"] = body["stop_sequences"]

    tools = convert_tools(body.get("tools"))
    if tools:
        payload["tools"] = tools
        tc = body.get("tool_choice") or {}
        kind = tc.get("type")
        if kind == "any":
            payload["tool_choice"] = "required"
        elif kind == "tool" and tc.get("name"):
            payload["tool_choice"] = {"type": "function", "function": {"name": tc["name"]}}
        elif kind == "auto":
            payload["tool_choice"] = "auto"
    return payload


STOP_MAP = {
    "stop": "end_turn",
    "length": "max_tokens",
    "tool_calls": "tool_use",
    "function_call": "tool_use",
    "content_filter": "end_turn",
}


# ---------------------------------------------------------------- upstream calls

def post_upstream(payload, timeout=600):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        UPSTREAM + "/chat/completions",
        data=data,
        headers={"Content-Type": "application/json", "Accept": "text/event-stream"},
        method="POST",
    )
    return urllib.request.urlopen(req, timeout=timeout)


def sse_iter(resp):
    """Yield (event, data-dict) from an SSE stream."""
    for raw in resp:
        line = raw.decode("utf-8", "replace").strip()
        if not line or line.startswith(":"):
            continue
        if line.startswith("data:"):
            chunk = line[5:].strip()
            if chunk == "[DONE]":
                return
            try:
                yield json.loads(chunk)
            except json.JSONDecodeError:
                continue


# ---------------------------------------------------------------- response renderers

def render_stream(body, handler):
    payload = convert_request(body)
    payload["stream"] = True
    model_name = body.get("model") or "local"
    msg_id = "msg_" + uuid.uuid4().hex[:20]

    def send(event, data):
        handler.wfile.write(
            ("event: %s\ndata: %s\n\n" % (event, json.dumps(data, ensure_ascii=False))).encode("utf-8")
        )
        handler.wfile.flush()

    send("message_start", {
        "type": "message_start",
        "message": {
            "id": msg_id, "type": "message", "role": "assistant", "model": model_name,
            "content": [], "stop_reason": None, "stop_sequence": None,
            "usage": {"input_tokens": 0, "output_tokens": 0},
        },
    })

    text_open = False
    index = 0
    tools = {}          # upstream tool_call index -> {"id","name","args","block_index"}
    stop_reason = "end_turn"
    out_tokens = 0

    resp = post_upstream(payload)
    try:
        for chunk in sse_iter(resp):
            choice = (chunk.get("choices") or [{}])[0]
            delta = choice.get("delta") or {}

            piece = delta.get("content")
            if piece:
                if not text_open:
                    send("content_block_start", {
                        "type": "content_block_start", "index": index,
                        "content_block": {"type": "text", "text": ""},
                    })
                    text_open = True
                send("content_block_delta", {
                    "type": "content_block_delta", "index": index,
                    "delta": {"type": "text_delta", "text": piece},
                })

            for tc in delta.get("tool_calls") or []:
                i = tc.get("index", 0)
                fn = tc.get("function") or {}
                if i not in tools:
                    if text_open:
                        send("content_block_stop", {"type": "content_block_stop", "index": index})
                        text_open = False
                        index += 1
                    tools[i] = {"id": tc.get("id") or ("toolu_" + uuid.uuid4().hex[:20]),
                                "name": fn.get("name", ""), "args": "", "block": index}
                    send("content_block_start", {
                        "type": "content_block_start", "index": index,
                        "content_block": {"type": "tool_use", "id": tools[i]["id"],
                                          "name": tools[i]["name"], "input": {}},
                    })
                    index += 1
                elif fn.get("name") and not tools[i]["name"]:
                    tools[i]["name"] = fn["name"]
                if fn.get("arguments"):
                    tools[i]["args"] += fn["arguments"]
                    send("content_block_delta", {
                        "type": "content_block_delta", "index": tools[i]["block"],
                        "delta": {"type": "input_json_delta", "partial_json": fn["arguments"]},
                    })

            fr = choice.get("finish_reason")
            if fr:
                stop_reason = STOP_MAP.get(fr, "end_turn")

            usage = chunk.get("usage") or {}
            if usage.get("completion_tokens"):
                out_tokens = usage["completion_tokens"]

        if text_open:
            send("content_block_stop", {"type": "content_block_stop", "index": index})
        for t in tools.values():
            send("content_block_stop", {"type": "content_block_stop", "index": t["block"]})
        if tools:
            stop_reason = "tool_use"

        send("message_delta", {
            "type": "message_delta",
            "delta": {"stop_reason": stop_reason, "stop_sequence": None},
            "usage": {"output_tokens": out_tokens},
        })
        send("message_stop", {"type": "message_stop"})
    finally:
        resp.close()


def render_blocking(body, handler):
    payload = convert_request(body)
    payload["stream"] = False
    resp = post_upstream(payload)
    raw = resp.read()
    resp.close()
    data = json.loads(raw.decode("utf-8"))
    choice = (data.get("choices") or [{}])[0]
    msg = choice.get("message") or {}

    content = []
    if msg.get("content"):
        content.append({"type": "text", "text": msg["content"]})
    for tc in msg.get("tool_calls") or []:
        fn = tc.get("function") or {}
        try:
            args = json.loads(fn.get("arguments") or "{}")
        except json.JSONDecodeError:
            args = {}
        content.append({"type": "tool_use", "id": tc.get("id") or "toolu_x",
                        "name": fn.get("name", ""), "input": args})

    stop_reason = "tool_use" if msg.get("tool_calls") else STOP_MAP.get(choice.get("finish_reason"), "end_turn")
    usage = data.get("usage") or {}
    out = {
        "id": "msg_" + uuid.uuid4().hex[:20], "type": "message", "role": "assistant",
        "model": body.get("model") or "local", "content": content,
        "stop_reason": stop_reason, "stop_sequence": None,
        "usage": {"input_tokens": usage.get("prompt_tokens", 0),
                  "output_tokens": usage.get("completion_tokens", 0)},
    }
    data_out = json.dumps(out, ensure_ascii=False).encode("utf-8")
    handler.send_response(200)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(data_out)))
    handler.end_headers()
    handler.wfile.write(data_out)


# ---------------------------------------------------------------- HTTP server

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[shim] %s\n" % (fmt % args))

    def _read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n).decode("utf-8")) if n else {}

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            out = json.dumps({"data": [{"id": "local", "type": "model"}], "has_more": False}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
            return
        self.send_error(404)

    def do_POST(self):
        path = self.path.split("?")[0]
        try:
            body = self._read_body()
        except Exception as exc:                       # noqa: BLE001
            self.send_error(400, str(exc))
            return

        if path.endswith("/count_tokens"):
            text = json.dumps(body.get("messages") or []) + str(body.get("system") or "")
            out = json.dumps({"input_tokens": max(1, len(text) // 4)}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
            return

        if not path.endswith("/messages"):
            self.send_error(404)
            return

        if body.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            try:
                render_stream(body, self)
            except BrokenPipeError:
                pass
            except Exception as exc:                   # noqa: BLE001
                sys.stderr.write("[shim] stream error: %r\n" % (exc,))
                try:
                    err = {"type": "error", "error": {"type": "api_error", "message": str(exc)}}
                    self.wfile.write(("event: error\ndata: %s\n\n" % json.dumps(err)).encode())
                    self.wfile.flush()
                except Exception:                      # noqa: BLE001
                    pass
        else:
            try:
                render_blocking(body, self)
            except urllib.error.HTTPError as exc:
                detail = exc.read().decode("utf-8", "replace")[:500]
                self.send_error(502, "upstream %s: %s" % (exc.code, detail))
            except Exception as exc:                   # noqa: BLE001
                self.send_error(500, str(exc))


def main():
    global UPSTREAM
    ap = argparse.ArgumentParser()
    ap.add_argument("--upstream", default=UPSTREAM, help="llama-server .../v1 base url")
    ap.add_argument("--port", type=int, default=8097)
    ap.add_argument("--host", default="127.0.0.1")
    args = ap.parse_args()
    UPSTREAM = args.upstream.rstrip("/")
    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    print("anthropic-shim: http://%s:%d  ->  %s" % (args.host, args.port, UPSTREAM), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
