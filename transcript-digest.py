#!/usr/bin/env python3
"""transcript-digest.py <session.jsonl> [max_chars]
Turn a Claude Code JSONL transcript into a compact, readable dialogue for
summarization: user prompts, assistant prose, and one-line tool markers.
Tool results and raw blobs are dropped. Emits the LAST max_chars of it."""
import json, sys, os

path = sys.argv[1]
max_chars = int(sys.argv[2]) if len(sys.argv) > 2 else 60000
out = []

def tool_marker(block):
    name = block.get("name", "tool")
    inp = block.get("input") or {}
    hint = ""
    for k in ("file_path", "path", "command", "pattern", "url", "prompt", "description", "query"):
        v = inp.get(k)
        if isinstance(v, str) and v.strip():
            hint = v.strip().splitlines()[0][:90]
            break
    return f"  [{name}: {hint}]" if hint else f"  [{name}]"

with open(path, errors="replace") as fh:
    for line in fh:
        try:
            o = json.loads(line)
        except Exception:
            continue
        t = o.get("type")
        m = o.get("message") or {}
        c = m.get("content")
        if t == "user":
            if isinstance(c, str):
                s = c.strip()
                if s and not s.startswith("<"):
                    out.append("USER: " + s[:1500])
            elif isinstance(c, list):
                for b in c:
                    if isinstance(b, dict) and b.get("type") == "text":
                        s = b.get("text", "").strip()
                        if s and not s.startswith("<") and "Request interrupted" not in s:
                            out.append("USER: " + s[:1500])
        elif t == "assistant" and isinstance(c, list):
            for b in c:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "text":
                    s = b.get("text", "").strip()
                    if s:
                        out.append("ASSISTANT: " + s[:2500])
                elif b.get("type") == "tool_use":
                    out.append(tool_marker(b))

# Collapse runs of tool markers so the digest stays about the conversation.
compact, run = [], []
for item in out:
    if item.startswith("  ["):
        run.append(item)
    else:
        if run:
            compact.extend(run if len(run) <= 4 else run[:2] + [f"  [... {len(run)-3} more tool calls ...]"] + run[-1:])
            run = []
        compact.append(item)
if run:
    compact.extend(run[:3])

text = "\n".join(compact)
sys.stdout.write(text[-max_chars:])
