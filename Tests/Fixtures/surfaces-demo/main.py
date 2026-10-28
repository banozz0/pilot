#!/usr/bin/env python3
"""Pilot's Surfaces v2 fixture: every new field once. Reads Pilot's run message on stdin, prints JSON lines.

Fixed clock: set SURFACES_DEMO_NOW is not possible (Pilot passes no environment), so tests pass "now" in the context.
"""
import json, os, sys, time

msg = json.loads(sys.stdin.readline() or "{}")
command, surface = msg.get("command"), msg.get("surface")
context = msg.get("context") or {}
now = int(context.get("now", time.time()))
data = (msg.get("paths") or {}).get("data")
log = os.path.join(data, "chat.json") if data else None


def say(obj):
    print(json.dumps(obj))


def chat_log():
    try:
        with open(log) as f:
            return json.load(f)
    except Exception:
        return [{"role": "user", "text": "Is the build green?", "at": now - 600},
                {"role": "tool", "text": "ran 3 tools"},
                {"role": "assistant", "text": "Yes: **2167 tests**, 3 known failures.", "at": now - 540}]


def session(ref, title, state, tone=None):
    ctx = {"ref": ref}
    return {"title": title, "subtitle": "Claude · %s" % state, "icon": "💬",
            "badges": [{"text": state}] + ([{"text": "review", "tone": tone}] if tone else []),
            "inline": [{"type": "push", "command": "chat", "icon": "bubble", "title": "Reply", "context": ctx},
                       {"type": "run", "command": "tag", "icon": "moon", "title": "Sleep", "context": ctx}],
            "actions": [{"type": "push", "command": "chat", "title": "Open chat", "context": ctx},
                        {"type": "run", "command": "rename", "title": "Rename…", "context": ctx, "ask": {"text": title}},
                        {"type": "run", "command": "tag", "title": "Tag", "context": ctx,
                         "ask": {"choices": [{"title": "review", "value": "review"}, {"title": "No tag", "value": "none"}]}},
                        {"type": "run", "command": "close", "title": "Close…", "destructive": True, "context": ctx,
                         "ask": {"confirm": "Close %s? Its terminal ends." % title}}]}


usage = [
    {"type": "section", "title": "Claude", "subtitle": "Max · read 11:15", "blocks": [
        {"type": "meter", "label": "Session", "percent": 34, "resetsAt": now + 82 * 60},
        {"type": "meter", "label": "Week", "percent": 25, "note": "resets Thu 20:00"}]},
    {"type": "section", "title": "Codex", "subtitle": "ChatGPT", "blocks": [
        {"type": "meter", "label": "5 hours", "percent": 0, "note": "reset since your last run"},
        {"type": "meter", "label": "Week", "percent": 67, "tone": "warn", "resetsAt": now + 406 * 60}]},
]
rows = {"type": "list", "title": "Sessions", "items": [session("s1", "Pilot coordinator 2", "idle", "fine"),
                                                     session("s2", "Layout rework", "working")]}

if command == "bar" and surface == "popover":
    say({"type": "blocks", "blocks": usage + [rows, {"type": "buttons", "actions": [
        {"type": "push", "command": "chat", "title": "Open chat", "context": {"ref": "s1"}}]}]})
elif command == "bar":
    say({"type": "bar", "text": "2", "tone": "warn", "gauges": [
        {"label": "C", "meters": [34, 25]}, {"label": "X", "meters": [0, 67], "tone": "warn"}],
        "blocks": usage[:1]})
elif command == "page":
    say({"type": "blocks", "refresh": 30, "blocks": [
        {"type": "stats", "items": [{"label": "Need you", "value": 0}, {"label": "Working", "value": 1, "tone": "fine"},
                                    {"label": "Idle", "value": 1}]}] + usage + [rows]})
elif command == "chat":
    ref = context.get("ref", "s1")
    say({"type": "blocks", "refresh": 2, "blocks": [
        {"type": "chat", "working": False, "messages": chat_log()},
        {"type": "input", "placeholder": "Reply to %s…" % ref,
         "action": {"type": "run", "command": "send", "title": "Send", "context": {"ref": ref}},
         "alt": {"type": "run", "command": "send", "title": "Interrupt", "context": {"ref": ref, "interrupt": True}}}]})
elif command == "send":
    text, pilot = msg.get("input", ""), msg.get("pilot") or {}
    if log:
        os.makedirs(data, exist_ok=True)
        messages = chat_log() + [{"role": "user", "text": text, "at": now},
                                 {"role": "assistant", "text": "Got it%s. Repos: %s" % (" (interrupting)" if context.get("interrupt") else "", pilot.get("repos", "?")), "at": now}]
        with open(log, "w") as f:
            json.dump(messages[-20:], f)
    say({"type": "hud", "text": "Sent to %s" % context.get("ref")})
elif command in ("rename", "tag", "close"):
    say({"type": "hud", "text": "%s %s: %s" % (command, context.get("ref"), msg.get("input", "confirmed"))})
else:
    say({"type": "error", "text": "unknown command %s" % command})
