#!/usr/bin/env python3
"""A no-view command for Pilot (ADR 0010). Pilot writes one JSON run message on stdin and closes it; the program prints
JSON lines on stdout: here one hud message, the line Pilot shows. It may also print action messages (copy, open, …)
or an error message. Python 3.9 stdlib only, as macOS's /usr/bin/python3; a no-view run may take up to 30 s."""
import json
import sys


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


def hello(run):
    send({"type": "hud", "text": "Hello from %s" % run.get("extension", "an extension")})


def main():
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        send({"type": "error", "text": "got a run message it could not read"})
        return
    command = run.get("command")
    if command == "hello":
        hello(run)
    else:
        send({"type": "error", "text": "has no command %s" % command})


if __name__ == "__main__":
    main()
