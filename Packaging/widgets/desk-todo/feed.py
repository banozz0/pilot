#!/usr/bin/env python3
"""To-do widget's feed (ADR 0016): reads the To-do extension's list, ExtensionData/todo/data/todos.json under Pilot's
folder, as that extension writes it (version 2: items with text, done, doneAt, due as 2026-10-23, order), changes nothing
and prints one {"type": "data", ...} line: the open ones grouped as To-do groups them, and the ones done today."""
import datetime
import json
import os
import sys

PILOT = os.path.join(os.path.expanduser("~"), "Library", "Application Support", "Pilot")
STORE = os.path.join(PILOT, "ExtensionData", "todo", "data", "todos.json")
INSTALLED = os.path.join(PILOT, "Extensions", "todo")
DAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
MOST = 30


def day(value):
    try:
        return datetime.date.fromisoformat(value) if isinstance(value, str) else None
    except ValueError:
        return None


def label(due, today):
    n = (due - today).days
    if n == 0:
        return "Today"
    if n == 1:
        return "Tomorrow"
    if n < 0 or n >= 7:
        return "%d %s" % (due.day, MONTHS[due.month - 1])
    return DAYS[due.weekday()]


def main():
    try:
        message = json.loads(sys.stdin.readline() or "{}")
    except ValueError:
        message = {}
    show_done = (message.get("settings") or {}).get("showDone", True) is not False
    try:
        with open(STORE, encoding="utf-8") as f:
            stored = json.load(f)
    except (OSError, ValueError):
        stored = None
    if stored is None and not os.path.isdir(INSTALLED):
        print(json.dumps({"type": "data", "data": {"installed": False}}))
        return
    items = stored.get("items") if isinstance(stored, dict) else []
    items = [t for t in items if isinstance(t, dict) and isinstance(t.get("text"), str)] if isinstance(items, list) else []
    today = datetime.date.today()
    midnight = datetime.datetime.combine(today, datetime.time()).timestamp()
    groups = {"Overdue": [], "Today": [], "Upcoming": [], "No date": []}
    for t in items:
        if t.get("done"):
            continue
        due = day(t.get("due"))
        name = "No date" if due is None else "Overdue" if due < today else "Today" if due == today else "Upcoming"
        groups[name].append((due, t.get("order") or 0, {"text": t["text"][:200], "due": label(due, today) if due else None}))
    for name, rows in groups.items():
        rows.sort(key=lambda r: (r[0] or today, r[1]) if name in ("Overdue", "Upcoming") else (r[1],))
    done = [t for t in items if t.get("done") and isinstance(t.get("doneAt"), (int, float)) and t["doneAt"] >= midnight]
    done.sort(key=lambda t: -t["doneAt"])
    out, left = [], MOST
    for name in ("Overdue", "Today", "Upcoming", "No date"):
        rows = [r[2] for r in groups[name]][:left]
        left -= len(rows)
        if rows:
            out.append({"name": name, "items": rows})
    data = {"installed": True, "groups": out, "open": sum(len(g) for g in groups.values()), "doneToday": len(done),
            "done": [{"text": t["text"][:200]} for t in done[:5]] if show_done else []}
    print(json.dumps({"type": "data", "data": data}, ensure_ascii=False))


if __name__ == "__main__":
    main()
