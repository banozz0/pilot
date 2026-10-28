#!/usr/bin/env python3
"""A detail command for Pilot (ADR 0010). Pilot writes one JSON run message on stdin and closes it; the program prints
JSON lines on stdout: here one detail message, markdown Pilot renders with facts beside it and actions under Cmd+K.
Python 3.9 stdlib only, as macOS's /usr/bin/python3; a detail must answer within 2 s."""
import json
import sys
import time


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


def show(run):
    now = time.strftime("%H:%M")
    send({"type": "detail", "markdown": "# %s\n\nA detail command's page. It is %s." % (run.get("extension", ""), now),
          "metadata": [{"label": "Time", "text": now}, {"label": "Command", "text": run.get("command", "")}],
          "actions": [{"type": "copy", "text": now, "title": "Copy the time"}]})


def main():
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        send({"type": "error", "text": "got a run message it could not read"})
        return
    command = run.get("command")
    if command == "show":
        show(run)
    else:
        send({"type": "error", "text": "has no command %s" % command})


if __name__ == "__main__":
    main()
