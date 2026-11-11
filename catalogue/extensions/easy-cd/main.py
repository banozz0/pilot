#!/usr/bin/env python3
"""Easy-CD folders for Pilot: easy-cd's (`ecd`) pinned folders, then its recent ones, read only.

easy-cd keeps both in its state folder, $XDG_STATE_HOME/ecd or ~/.local/state/ecd: `pins` is one folder per line in
pin order, `visits` one `<unix time>\t<folder>` line per landing. Recents are ranked as ecd ranks them (zoxide-style
frecency: a visit weighs 4 within the hour, 2 within the day, 1/2 within the week, 1/4 after), pins and folders that
no longer exist left out. Nothing is ever written to easy-cd's files. The hidden open-terminal command opens a window
through `open`, so the program never holds it.

The page (Sven, 2026-10-31: a page does its job in place) is a search box over the same folders, pinned then recent; a
click opens a terminal there, its inline buttons Finder and Copy path. The box searches as Sven types: the hidden find
command keeps its words in paths.data for SEARCH_FOR seconds, and the page reads them back.
"""
import itertools
import json
import os
import subprocess
import sys
import time

RECENTS = 30
SEARCH = "search.json"  # in paths.data: the page's search words
SEARCH_FOR = 600  # seconds the page's words count, so a page opened later starts unfiltered
GHOSTTY = ["/Applications/Ghostty.app", os.path.expanduser("~/Applications/Ghostty.app")]


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


def state_dir():
    xdg = os.environ.get("XDG_STATE_HOME", "")
    return os.path.join(xdg if os.path.isabs(xdg) else os.path.expanduser("~/.local/state"), "ecd")


def read_lines(path):
    """The file's lines, or None when it does not exist."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().split("\n")
    except FileNotFoundError:
        return None
    except OSError:
        return []


def pins(lines):
    seen, out = set(), []
    for d in lines or []:
        if d and d not in seen and os.path.isdir(d):
            seen.add(d)
            out.append(d)
    return out


def recents(lines, now):
    """[(folder, last visit)] best frecency first, as ecd ranks them (frecency() and visited() in easy-cd's
    internal/picker/state.go: keep the weights and tie-break in step with it); gone folders are left to the caller."""
    score, last = {}, {}
    for line in lines or []:
        stamp, sep, d = line.partition("\t")
        if not sep or not d:
            continue
        try:
            t = int(stamp)
        except ValueError:
            continue
        age = now - t
        score[d] = score.get(d, 0) + (4 if age < 3600 else 2 if age < 86400 else 0.5 if age < 7 * 86400 else 0.25)
        last[d] = max(last.get(d, t), t)
    return [(d, last[d]) for d in sorted(score, key=lambda d: (-score[d], d))]


def tilde(path):
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path == home or path.startswith(home + "/") else path


def ago(stamp, now):
    s = max(0, now - stamp)
    if s < 60:
        return "just now"
    if s < 3600:
        return "%d min ago" % (s // 60)
    if s < 86400:
        return "%d h ago" % (s // 3600)
    if s < 2 * 86400:
        return "yesterday"
    if s < 7 * 86400:
        return "%d days ago" % (s // 86400)
    return time.strftime("%-d %b %Y", time.localtime(stamp))


def terminal_app(preferences):
    """The chosen app's path, else Ghostty when installed, else Terminal."""
    chosen = preferences.get("terminal")
    if isinstance(chosen, str) and chosen and os.path.isdir(chosen):
        return chosen
    return next((g for g in GHOSTTY if os.path.isdir(g)), "Terminal")


def app_name(app):
    return os.path.basename(app)[:-4] if app.endswith(".app") else app


def row(folder, icon, note, terminal):
    return {"id": folder, "title": os.path.basename(folder) or folder, "subtitle": "%s · %s" % (tilde(folder), note),
            "icon": icon, "keywords": tilde(folder),
            "actions": [{"type": "run", "command": "open-terminal", "title": "Open in %s" % terminal,
                         "context": {"path": folder}},
                        {"type": "open", "url": folder, "title": "Open in Finder"},
                        {"type": "copy", "text": folder, "title": "Copy path"}]}


def folders(run):
    """(pinned rows, recent rows, the row saying why there are none)."""
    state = state_dir()
    pin_lines, visit_lines = read_lines(os.path.join(state, "pins")), read_lines(os.path.join(state, "visits"))
    now = int(time.time())
    pinned = pins(pin_lines)
    terminal = app_name(terminal_app(run.get("preferences") or {}))
    recent = (r for r in recents(visit_lines, now) if r[0] not in pinned and os.path.isdir(r[0]))
    none = pin_lines is None and visit_lines is None
    empty = {"title": "easy-cd has no pins or recent folders yet" if none else "easy-cd's folders are all gone",
             "subtitle": "Run ecd in a terminal: Enter lands in a folder, Ctrl+P pins it" if none
             else "The folders it pinned or visited no longer exist", "icon": "📂"}
    return ([row(d, "📌", "pinned", terminal) for d in pinned],
            [row(d, "🕘", ago(last, now), terminal) for d, last in itertools.islice(recent, RECENTS)], empty)


def list_folders(run):
    pinned, recent, empty = folders(run)
    send({"type": "list", "items": pinned + recent or [empty]})


def held_words(run):
    """The page's search words while they are younger than SEARCH_FOR, else ""."""
    try:
        with open(os.path.join((run.get("paths") or {}).get("data") or "", SEARCH), encoding="utf-8") as f:
            held = json.load(f)
    except (OSError, ValueError):
        return ""
    if not isinstance(held, dict) or time.time() - (held.get("at") or 0) > SEARCH_FOR:
        return ""
    return held.get("query") if isinstance(held.get("query"), str) else ""


def find(run):
    """The page's box: its words kept for the page, an emptied box (or Clear) forgetting them. Quiet: the page shows."""
    folder = (run.get("paths") or {}).get("data")
    if not folder:
        return
    path = os.path.join(folder, SEARCH)
    words = " ".join((run.get("input") or "").split())
    if not words or (run.get("context") or {}).get("clear"):
        try:
            os.remove(path)
        except OSError:
            pass
        return
    os.makedirs(folder, exist_ok=True)
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        json.dump({"query": words, "at": time.time()}, f)
    os.replace(path + ".tmp", path)


def matches(item, words):
    hay = " ".join((item["title"], item.get("keywords", ""))).lower()
    return all(w in hay for w in words.lower().split())


def page_row(item):
    """A list row on the page: a click opens the terminal; Finder and Copy path as inline buttons."""
    run, finder, copy = item["actions"]
    return dict(item, actions=[run], inline=[dict(finder, icon="📂"), dict(copy, icon="📋")])


def page(run):
    """The page: the search box, then the pinned folders and the recent ones that match its words."""
    words = held_words(run)
    blocks = [{"type": "input", "placeholder": "Search your pinned and recent folders", "live": True,
               "action": {"type": "run", "command": "find", "title": "Search"}}]
    pinned, recent, empty = folders(run)
    if words:
        pinned, recent = [i for i in pinned if matches(i, words)], [i for i in recent if matches(i, words)]
        blocks.append({"type": "buttons", "actions": [{"type": "run", "command": "find", "title": "Clear “%s”" % words,
                                                       "context": {"clear": True}}]})
    if pinned:
        blocks.append({"type": "list", "title": "Pinned", "items": [page_row(i) for i in pinned]})
    if recent:
        blocks.append({"type": "list", "title": "Recent", "items": [page_row(i) for i in recent]})
    if not pinned and not recent:
        blocks.append({"type": "markdown", "text": "No folder matches “%s”." % words if words else
                       "**%s.** %s" % (empty["title"], empty["subtitle"])})
    send({"type": "blocks", "blocks": blocks})


def open_terminal(run):
    """Opens a terminal window in the folder the context names: Ghostty as a new window there, another terminal by
    opening the folder with it. The window belongs to the terminal, never to this program."""
    context = run.get("context") if isinstance(run.get("context"), dict) else {}
    folder = context.get("path")
    if not (isinstance(folder, str) and os.path.isdir(folder)):
        send({"type": "error", "text": "got no folder that exists"})
        return
    app = terminal_app(run.get("preferences") or {})
    if app_name(app).lower() == "ghostty":
        arguments = ["-na", app, "--args", "--working-directory=" + folder, "--window-save-state=never"]
    else:
        arguments = ["-a", app, folder]
    done = subprocess.run(["open"] + arguments, capture_output=True, text=True, timeout=10)
    if done.returncode != 0:
        send({"type": "error", "text": (done.stderr.strip() or "open failed")[:160]})
        return
    send({"type": "hud", "text": "%s in %s" % (os.path.basename(folder) or folder, app_name(app))})


def main():
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        send({"type": "error", "text": "got a run message it could not read"})
        return
    command = run.get("command")
    if command == "folders":
        list_folders(run)
    elif command == "open-terminal":
        open_terminal(run)
    elif command == "page":
        page(run)
    elif command == "find":
        find(run)
    else:
        send({"type": "error", "text": "has no command %s" % command})


if __name__ == "__main__":
    main()
