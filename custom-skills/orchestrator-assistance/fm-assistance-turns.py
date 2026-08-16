#!/usr/bin/env python3
"""Emit observable parent turns from one Claude session history file.

Invoked by fm-assistance.sh, which owns the cursor and the calling contract.
Reads its inputs from the environment so no parent path or record uuid has to
survive a shell quoting round trip:

    FM_A_HISTORY  path to the parent's .jsonl session history
    FM_A_CURSOR   line index already consumed (live mode)
    FM_A_LIMIT    maximum turns to emit
    FM_A_UNTIL    record uuid to stop BEFORE (replay mode)

Live mode emits turns after the cursor and reports the new cursor as the final
"#next=<n>" line. Replay mode ignores the cursor, never reports one, and emits
the last FM_A_LIMIT turns that precede FM_A_UNTIL, so replaying history cannot
carry a later correction back into the input that is supposed to precede it.

An observable turn is a non-sidechain user or assistant record: a subagent's
own transcript is not something the parent said.
"""
from __future__ import annotations

import json
import os
import sys

EXCERPT = 300


def text_of(message):
    if not isinstance(message, dict):
        return ""
    content = message.get("content")
    if isinstance(content, str):
        return content
    parts = []
    if isinstance(content, list):
        for block in content:
            if not isinstance(block, dict):
                continue
            kind = block.get("type")
            if kind == "text":
                parts.append(block.get("text", ""))
            elif kind == "tool_use":
                parts.append("[tool:%s]" % block.get("name", ""))
            elif kind == "tool_result":
                parts.append("[tool-result]")
            elif kind == "thinking":
                parts.append("[thinking]")
    return " ".join(part for part in parts if part)


def excerpt(raw):
    flat = " ".join(raw.split())
    if len(flat) > EXCERPT:
        return flat[:EXCERPT] + "..."
    return flat


def main():
    path = os.environ.get("FM_A_HISTORY", "")
    until = os.environ.get("FM_A_UNTIL", "").strip()
    try:
        cursor = int(os.environ.get("FM_A_CURSOR", "0") or 0)
        limit = int(os.environ.get("FM_A_LIMIT", "20") or 20)
    except ValueError:
        print("fm-assistance-turns: cursor and limit must be integers", file=sys.stderr)
        return 1
    if limit < 1:
        print("fm-assistance-turns: limit must be at least 1", file=sys.stderr)
        return 1

    try:
        handle = open(path, "r", encoding="utf-8", errors="replace")
    except OSError as err:
        print("fm-assistance-turns: %s" % err, file=sys.stderr)
        return 1

    turns = []
    until_index = None
    total = 0
    with handle:
        for index, line in enumerate(handle, start=1):
            total = index
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if not isinstance(record, dict):
                continue
            if until and until_index is None and record.get("uuid") == until:
                until_index = index
            if record.get("type") not in ("user", "assistant"):
                continue
            if record.get("isSidechain"):
                continue
            turns.append(
                (
                    index,
                    record.get("type", ""),
                    record.get("uuid", ""),
                    record.get("timestamp", ""),
                    excerpt(text_of(record.get("message"))),
                )
            )

    if until:
        if until_index is None:
            print(
                "fm-assistance-turns: record %s is not in this history; refusing to "
                "replay the whole file" % until,
                file=sys.stderr,
            )
            return 1
        selected = [turn for turn in turns if turn[0] < until_index][-limit:]
        for turn in selected:
            print("\t".join(str(field) for field in turn))
        return 0

    scanned = cursor
    emitted = 0
    for turn in turns:
        if turn[0] <= cursor:
            continue
        scanned = turn[0]
        print("\t".join(str(field) for field in turn))
        emitted += 1
        if emitted >= limit:
            break
    else:
        scanned = max(scanned, total)

    print("#next=%d" % scanned)
    return 0


if __name__ == "__main__":
    sys.exit(main())
