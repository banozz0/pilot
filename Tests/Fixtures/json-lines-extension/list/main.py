#!/usr/bin/env python3
"""A list command for Pilot (ADR 0010). Pilot writes one JSON run message on stdin and closes it; the program prints
JSON lines on stdout: here one list message, whose rows Pilot filters as you type. Python 3.9 stdlib only, as macOS's
/usr/bin/python3; a list must answer within 2 s."""
import json
import sys


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


def items(run):
    rows = [("Alpha", "the first row"), ("Beta", "the second row"), ("Gamma", "the third row")]
    send({"type": "list", "items": [
        {"id": title.lower(), "title": title, "subtitle": words,
         "actions": [{"type": "copy", "text": title, "title": "Copy"},
                     {"type": "hud", "text": "%s: %s" % (title, words), "title": "Say it"}]}
        for title, words in rows]})


def main():
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        send({"type": "error", "text": "got a run message it could not read"})
        return
    command = run.get("command")
    if command == "items":
        items(run)
    else:
        send({"type": "error", "text": "has no command %s" % command})


if __name__ == "__main__":
    main()
