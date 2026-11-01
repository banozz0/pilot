#!/usr/bin/env python3
"""AI usage widget's feed (ADR 0016): asks the AI usage extension, as Pilot's menu bar asks it, and reshapes its answer
for the page. Pilot has no AI usage reading, so this runs that extension's own `bar` command (it reads its caches and
answers in well under a second) with the run message Pilot would send: its saved preferences and its data and cache
folders. Accounts' email addresses stay out of the page; plans and windows go in. Changes nothing of its own."""
import json
import os
import re
import subprocess
import sys

HOME = os.path.expanduser("~")
PILOT = os.path.join(HOME, "Library", "Application Support", "Pilot")
EXTENSION = os.path.join(PILOT, "Extensions", "ai-usage")
DATA = os.path.join(PILOT, "ExtensionData", "ai-usage")
CACHE = os.path.join(HOME, "Library", "Caches", "dev.banozz.pilot", "Extensions", "ai-usage")


def send(data):
    sys.stdout.write(json.dumps({"type": "data", "data": data}, ensure_ascii=False) + "\n")


def ask():
    try:
        with open(os.path.join(DATA, "preferences.json"), encoding="utf-8") as f:
            preferences = json.load(f)
    except (OSError, ValueError):
        preferences = {}
    message = {"type": "run", "extension": "ai-usage", "command": "bar", "surface": "bar",
               "preferences": preferences if isinstance(preferences, dict) else {},
               "paths": {"data": os.path.join(DATA, "data"), "cache": CACHE}}
    os.makedirs(os.path.join(DATA, "data"), exist_ok=True)
    os.makedirs(CACHE, exist_ok=True)
    out = subprocess.run([sys.executable, os.path.join(EXTENSION, "main.py")], input=json.dumps(message) + "\n",
                         capture_output=True, text=True, timeout=3.5, cwd=EXTENSION).stdout
    for line in reversed(out.splitlines()):
        try:
            answer = json.loads(line)
        except ValueError:
            continue
        if isinstance(answer, dict) and answer.get("type") in ("bar", "blocks"):
            return answer
    return None


def providers(blocks):
    found, seen = [], {}
    for section in blocks or []:
        if not isinstance(section, dict) or section.get("type") != "section":
            continue
        name = section.get("title") or "?"
        seen[name] = seen.get(name, 0) + 1
        windows, notes = [], []
        for block in section.get("blocks") or []:
            if block.get("type") == "meter":
                windows.append({k: block.get(k) for k in ("label", "percent", "tone", "mark", "markTone", "resetsAt", "note")})
            elif block.get("type") == "markdown" and isinstance(block.get("text"), str):
                notes.append(re.sub(r"[*`]", "", block["text"])[:120])
        subtitle = section.get("subtitle") or ""
        found.append({"name": name if seen[name] == 1 else "%s %d" % (name, seen[name]), "plan": section.get("asideNote"),
                      "updated": subtitle.replace("Updated ", "") if subtitle.startswith("Updated") else None,
                      "state": None if windows else (subtitle or "No limits read"), "windows": windows, "notes": notes[:1]})
    return found


def main():
    sys.stdin.read()
    if not os.path.isfile(os.path.join(EXTENSION, "main.py")):
        send({"installed": False})
        return
    try:
        answer = ask()
    except (OSError, subprocess.SubprocessError):
        answer = None
    if answer is None:
        send({"installed": True, "problem": "AI usage did not answer"})
        return
    send({"installed": True, "providers": providers(answer.get("blocks"))})


if __name__ == "__main__":
    main()
