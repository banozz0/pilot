#!/usr/bin/env python3
"""Ports for Pilot: the listening TCP ports (lsof) and quitting the program that holds one.

Kill port lists one row per program and port; its Quit and Force quit run the hidden `kill` command with the pid and
port as context, which checks again that the pid still holds the port before signalling it. Never pid 1 or below,
never this program, never Pilot (this program's parent, or a process named Pilot).
"""
import json
import os
import signal
import subprocess
import sys

LSOF_TIMEOUT = 1.5


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


def lsof(arguments):
    """lsof's field output; lsof exits 1 when nothing matches, which is no rows, not a failure."""
    try:
        done = subprocess.run(["lsof"] + arguments, capture_output=True, text=True, timeout=LSOF_TIMEOUT)
    except FileNotFoundError:
        raise RuntimeError("lsof is not on this Mac")
    except subprocess.TimeoutExpired:
        raise RuntimeError("lsof took too long")
    if done.returncode not in (0, 1):
        raise RuntimeError("lsof failed: %s" % done.stderr.strip()[:120])
    return done.stdout


def listening():
    """{(pid, port): {"pid", "port", "name", "addresses"}} from lsof -F pcn, by port then pid."""
    rows, pid, name = {}, None, ""
    for line in lsof(["-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]).splitlines():
        if not line:
            continue
        tag, value = line[0], line[1:]
        if tag == "p":
            pid, name = int(value), ""
        elif tag == "c":
            name = value
        elif tag == "n" and pid is not None:
            host, _, port = value.rpartition(":")
            if not port.isdigit():
                continue
            row = rows.setdefault((pid, int(port)), {"pid": pid, "port": int(port), "name": name, "addresses": []})
            if host not in row["addresses"]:
                row["addresses"].append(host)
    return [rows[k] for k in sorted(rows, key=lambda k: (k[1], k[0]))]


def item(row):
    pid, port, name = row["pid"], row["port"], row["name"] or "unknown"
    context = {"pid": pid, "port": port, "name": name}
    url = "http://localhost:%d" % port
    return {
        "id": "%d-%d" % (pid, port),
        "title": "Port %d" % port,
        "subtitle": "%s · pid %d · %s" % (name, pid, ", ".join(row["addresses"])),
        "icon": "🔌",
        "keywords": "%s %d %d" % (name, pid, port),
        "actions": [
            {"type": "run", "command": "kill", "title": "Quit %s" % name, "context": dict(context, signal="TERM")},
            {"type": "run", "command": "kill", "title": "Force quit %s" % name, "context": dict(context, signal="KILL")},
            {"type": "open", "url": url, "title": "Open %s" % url},
            {"type": "copy", "text": str(pid), "title": "Copy PID"},
            {"type": "copy", "text": url, "title": "Copy URL"},
        ],
    }


def kill_port():
    try:
        rows = listening()
    except RuntimeError as e:
        send({"type": "error", "text": str(e)})
        return
    if not rows:
        send({"type": "list", "items": [{"title": "No TCP port is listening", "subtitle": "Nothing of yours holds one",
                                         "icon": "🔌"}]})
        return
    send({"type": "list", "items": [item(r) for r in rows]})


def process_name(pid):
    done = subprocess.run(["ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True, timeout=1)
    return done.stdout.strip()


def refusal(pid):
    """Why `pid` must not be signalled; None when it may."""
    if type(pid) is not int or pid <= 1:
        return "will not quit pid %s" % pid
    if pid in (os.getpid(), os.getppid()):
        return "will not quit Pilot"
    path = process_name(pid)
    if os.path.basename(path) == "Pilot" or "/Pilot.app/" in path:
        return "will not quit Pilot"
    return None


def kill(context):
    pid, port, name = context.get("pid"), context.get("port"), context.get("name") or "the program"
    why = refusal(pid)
    if why:
        send({"type": "error", "text": why})
        return
    if type(port) is not int:
        send({"type": "error", "text": "got no port"})
        return
    try:
        holders = lsof(["-nP", "-t", "-a", "-p", str(pid), "-iTCP:%d" % port, "-sTCP:LISTEN"]).split()
    except RuntimeError as e:
        send({"type": "error", "text": str(e)})
        return
    if str(pid) not in holders:
        send({"type": "error", "text": "port %d is no longer held by pid %d" % (port, pid)})
        return
    force = context.get("signal") == "KILL"
    try:
        os.kill(pid, signal.SIGKILL if force else signal.SIGTERM)
    except ProcessLookupError:
        send({"type": "error", "text": "pid %d has already quit" % pid})
        return
    except PermissionError:
        send({"type": "error", "text": "may not quit pid %d: it is not yours" % pid})
        return
    verb = "Force quit" if force else "Asked to quit:"
    send({"type": "hud", "text": "%s %s (pid %d) on port %d" % (verb, name, pid, port)})


def main():
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        send({"type": "error", "text": "got a run message it could not read"})
        return
    command = run.get("command")
    if command == "kill-port":
        kill_port()
    elif command == "kill":
        kill(run.get("context") if isinstance(run.get("context"), dict) else {})
    else:
        send({"type": "error", "text": "has no command %s" % command})


if __name__ == "__main__":
    main()
