#!/usr/bin/env python3
"""SSH hosts for Pilot: the hosts named in ~/.ssh/config, and every file it Includes, each opened in a new terminal.

Only `Host` names without wildcards are listed (a `*`, `?` or `!` pattern is a rule, not a host), with the HostName,
User and Port the first block naming them sets, as ssh reads it. Nothing is ever connected from the list itself: the
hidden connect command opens a terminal window running `ssh <host>`, and only for a host the config still names, so a
crafted context can never run anything else. Keys, identities and known_hosts are never read.

Its page (Sven, 2026-10-31: a page does its job in place) has a box that narrows the hosts as Sven types (the hidden
`filter` command keeps the words in paths.data, which the page reads back) and the hosts as rows, Connect on a click and
as an inline button, the copy and the config file on the ⋯ menu.
"""
import glob
import json
import os
import re
import shlex
import subprocess
import sys

CONFIG = "~/.ssh/config"
GHOSTTY = ["/Applications/Ghostty.app", os.path.expanduser("~/Applications/Ghostty.app")]
NAME = re.compile(r"[A-Za-z0-9._@-]+\Z")
MOST_INCLUDES = 32


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


def words(line):
    """A config line as its keyword (lowercase) and values; `Key=Value` too. None for a blank or comment line."""
    line = line.strip()
    if not line or line.startswith("#"):
        return None
    try:
        parts = shlex.split(line.replace("=", " ", 1) if "=" in line.split(None, 1)[0] else line, comments=True)
    except ValueError:
        return None
    return (parts[0].lower(), parts[1:]) if parts else None


def read_config(path, hosts, seen, depth=0):
    """Adds the hosts `path` names to `hosts` (name → settings, the first value of each setting wins, as in ssh),
    following Include (relative paths from ~/.ssh, globs allowed)."""
    path = os.path.realpath(os.path.expanduser(path))
    if path in seen or len(seen) >= MOST_INCLUDES or depth > 8:
        return
    seen.add(path)
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return
    current = []
    for line in lines:
        parsed = words(line)
        if not parsed:
            continue
        key, values = parsed
        if key == "include":
            for pattern in values:
                pattern = os.path.expanduser(pattern)
                if not os.path.isabs(pattern):
                    pattern = os.path.join(os.path.expanduser("~/.ssh"), pattern)
                for included in sorted(glob.glob(pattern)):
                    read_config(included, hosts, seen, depth + 1)
        elif key == "host":
            current = [v for v in values if NAME.match(v) and not v.startswith("!")]
            for name in current:
                hosts.setdefault(name, {"source": path})
        elif key == "match":
            current = []
        elif key in ("hostname", "user", "port") and values:
            for name in current:
                hosts[name].setdefault(key, values[0])


def hosts():
    found = {}
    read_config(CONFIG, found, set())
    return found


def tilde(path):
    """`path` from home as ~/…; config paths are real paths, so home is compared as one too."""
    for home in (os.path.expanduser("~"), os.path.realpath(os.path.expanduser("~"))):
        if path.startswith(home + "/"):
            return "~" + path[len(home):]
    return path


def address(settings):
    """"me@192.0.2.10:2222", the parts the config sets; None when it sets none."""
    host = settings.get("hostname")
    if not host:
        return None
    user = settings.get("user")
    port = settings.get("port")
    return "%s%s%s" % (user + "@" if user else "", host, ":" + port if port and port != "22" else "")


def terminal_app(preferences):
    """The chosen app's path, else Ghostty when installed, else Terminal."""
    chosen = preferences.get("terminal")
    if isinstance(chosen, str) and chosen and os.path.isdir(chosen):
        return chosen
    return next((g for g in GHOSTTY if os.path.isdir(g)), "Terminal")


def app_name(app):
    return os.path.basename(app)[:-4] if app.endswith(".app") else app


def host_items(run, words=""):
    """A row per host, its name, address and user holding every word in `words`."""
    found = hosts()
    terminal = app_name(terminal_app(run.get("preferences") or {}))
    items = []
    for name in sorted(found, key=str.lower):
        settings = found[name]
        where = address(settings)
        text = " ".join(x for x in (name, where, settings.get("user")) if x).lower()
        if not all(w in text for w in words.lower().split()):
            continue
        items.append({
            "id": name, "title": name, "icon": "🖥️",
            "subtitle": " · ".join(x for x in (where, tilde(settings["source"])) if x),
            "keywords": " ".join(x for x in (settings.get("hostname"), settings.get("user")) if x),
            "actions": [
                {"type": "run", "command": "connect", "title": "Connect in %s" % terminal, "context": {"host": name}},
                {"type": "copy", "text": "ssh %s" % name, "title": "Copy ssh %s" % name},
                {"type": "open", "url": settings["source"], "title": "Open %s" % os.path.basename(settings["source"])},
            ]})
    return items


EMPTY = {"title": "No hosts in %s" % CONFIG, "icon": "🖥️",
         "subtitle": "Add a Host block, e.g. Host prod with HostName 203.0.113.7, and it shows here"}


def list_hosts(run):
    send({"type": "list", "items": host_items(run) or [EMPTY]})


def filter_path(run):
    folder = (run.get("paths") or {}).get("data") or os.environ.get("TMPDIR", "/tmp")
    os.makedirs(folder, exist_ok=True)
    return os.path.join(folder, "filter.txt")


def held_filter(run):
    try:
        with open(filter_path(run), encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def keep_filter(run):
    """The page's box: the words typed, kept for the page; blank (an emptied box, or Show all) clears them."""
    words = (run.get("input") or "").strip()[:200]
    with open(filter_path(run), "w", encoding="utf-8") as f:
        f.write(words)


def page(run):
    words = held_filter(run)
    rows = host_items(run, words)
    for row in rows:
        row["inline"] = [dict(row["actions"][0], icon="terminal")]
    box = {"type": "input", "placeholder": "Filter hosts by name, address or user", "live": True,
           "action": {"type": "run", "command": "filter", "title": "Filter"}}
    blocks = [box]
    if words:
        blocks.append({"type": "buttons", "actions": [{"type": "run", "command": "filter", "title": "Show all hosts"}]})
        title = "%d host%s matching “%s”" % (len(rows), "" if len(rows) == 1 else "s", words)
        rows = rows or [{"title": "No host matches “%s”" % words, "icon": "🔎"}]
    else:
        title = "Hosts"
        rows = rows or [EMPTY]
    blocks.append({"type": "list", "title": title, "items": rows})
    send({"type": "blocks", "blocks": blocks})


def open_with(arguments):
    done = subprocess.run(["open"] + arguments, capture_output=True, text=True, timeout=10)
    return None if done.returncode == 0 else (done.stderr.strip() or "open failed")[:160]


def connect(run):
    context = run.get("context") if isinstance(run.get("context"), dict) else {}
    name = context.get("host")
    if not (isinstance(name, str) and NAME.match(name) and name in hosts()):
        send({"type": "error", "text": "no host %s in %s" % (name, CONFIG)})
        return
    app = terminal_app(run.get("preferences") or {})
    if app_name(app).lower() == "ghostty":
        failed = open_with(["-na", app, "--args", "--command=ssh " + name, "--window-save-state=never"])
    else:
        cache = (run.get("paths") or {}).get("cache") or os.environ.get("TMPDIR", "/tmp")
        os.makedirs(cache, exist_ok=True)
        script = os.path.join(cache, "ssh-%s.command" % name)
        with open(script, "w", encoding="utf-8") as f:
            f.write("#!/bin/sh\nexec ssh %s\n" % shlex.quote(name))
        os.chmod(script, 0o755)
        app = "Terminal"
        failed = open_with(["-a", app, script])
    if failed:
        send({"type": "error", "text": failed})
        return
    send({"type": "hud", "text": "ssh %s in %s" % (name, app_name(app))})


def main():
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        send({"type": "error", "text": "got a run message it could not read"})
        return
    command = run.get("command")
    if command == "hosts":
        list_hosts(run)
    elif command == "connect":
        connect(run)
    elif command == "page":
        page(run)
    elif command == "filter":
        keep_filter(run)
    else:
        send({"type": "error", "text": "has no command %s" % command})


if __name__ == "__main__":
    main()
