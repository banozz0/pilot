#!/usr/bin/env python3
"""A top-bar item for Pilot (story 161). The manifest's surfaces.bar names the hidden `bar` command; Pilot runs it with
"surface": "bar" and shows the bar message's text (24 characters at most), then on a click with "surface": "popover"
and shows the blocks message. `now` is the shown command every extension needs. Python 3.9 stdlib only, as macOS's
/usr/bin/python3; a bar answer must come within 2 s, a popover's within 5 s."""
import json
import sys
import time


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


def blocks():
    return [{"type": "stats", "items": [{"label": "Time", "value": time.strftime("%H:%M")},
                                        {"label": "Day", "value": time.strftime("%a")}]},
            {"type": "markdown", "text": "A popover's blocks: stats, meter, list, markdown, buttons."}]


def bar(run):
    if run.get("surface") == "popover":
        send({"type": "blocks", "blocks": blocks()})
    else:
        send({"type": "bar", "text": "🧩 %s" % time.strftime("%H:%M"), "blocks": blocks()})


def now(run):
    send({"type": "hud", "text": "It is %s" % time.strftime("%H:%M")})


def main():
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        send({"type": "error", "text": "got a run message it could not read"})
        return
    command = run.get("command")
    if command == "bar":
        bar(run)
    elif command == "now":
        now(run)
    else:
        send({"type": "error", "text": "has no command %s" % command})


if __name__ == "__main__":
    main()
