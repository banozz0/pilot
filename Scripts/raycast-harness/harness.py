#!/usr/bin/env python3
"""The top-20 rerun (spec raycast-extensions, T7): Raycast's 20 most-installed extensions through the `pilot` command
against a sandbox, the phase gates' proof. Written fresh: none of the spike's code.

    harness.py install --pilot P --socket S --work W [--only a,b]   GitHub install of each, its installed folder kept in W
    harness.py run     --pilot P --socket S --work W --host H [--only a,b]  every view command, empty search then "a"
    harness.py act     --pilot P --socket S --work W --host H --measure M --victim PID [--only a,b]  each gate one's press
    harness.py summary --work W --measure M                          coverage, first answers and host footprints

P is PilotCLI, S the sandbox's socket (Tests/PilotTests/SandboxHost.swift, PILOT_SANDBOX_ALLOW=1), W a work folder, H the
real pilot-ext-host the sandbox's wrapper starts (its path finds this sandbox's hosts with `pgrep -f`, never another
slot's), M the host's --measure log (Helpers/pilot-ext-host, Measure.swift) and PID a `sleep` the caller started under a
name of its own, the only process Kill Process may kill. A sandbox serves 10 minutes, so `run` and `act` install the
folders `install` kept as local folders when the sandbox lacks them: GitHub is asked once per extension (60 calls an
hour unauthenticated). Every command is printed with its whole stdout, then its exit and time; nothing is read from or
written to the Mac's own Pilot. Python 3 stdlib only.
"""
import argparse
import json
import os
import shutil
import statistics
import subprocess
import sys
import time

# Raycast's public store pages 1 and 2 in store order, frozen 2026-11-19 (spec raycast-extensions-spike, Results).
FROZEN = [
    ("kill-process", "Kill Process"), ("color-picker", "Color Picker"), ("google-chrome", "Google Chrome"),
    ("google-translate", "Google Translate"), ("spotify-player", "Spotify Player"),
    ("visual-studio-code-recent-projects", "Visual Studio Code"), ("linear", "Linear"), ("slack", "Slack"), ("brew", "Brew"),
    ("1password", "1Password"), ("notion", "Notion"), ("github", "GitHub"), ("chatgpt", "ChatGPT"), ("coffee", "Coffee"),
    ("arc", "Arc"), ("obsidian", "Obsidian"), ("speedtest", "Speedtest"), ("apple-notes", "Apple Notes"),
    ("video-downloader", "Video Downloader"), ("google-search", "Google Search"),
]

# Phase 1's gate (spec raycast-extensions, Decisions › Coverage): each one's view, the search that shows content, and its
# primary action's press as `pilot ext act` takes it. `row` names a row by its title ("{victim}" is the sleep's name),
# `expect` what the measure log must hold after the press: the kind of call and a piece of it; `prefs` preferences set
# first (Kill Process's confirmation is an alert Pilot lacks until T11; Obsidian's append command's required note);
# `storage` the extension's own LocalStorage in the sandbox, as an earlier run leaves it (Chrome remembers that it found
# Chrome and skips asking AppleScript again); "{first}" in `row` is the first row's title.
GATE = {
    "kill-process": {"command": "index", "query": "{victim}", "row": "{victim}", "expect": ("exec", "kill"),
                     "prefs": {"skipConfirmation": "true"}},
    "brew": {"command": "installed", "query": "", "row": "{first}/Pin Formula", "expect": ("exec", "brew pin")},
    "obsidian": {"command": "searchNoteCommand", "query": "", "row": None, "expect": ("open", "obsidian://"),
                 "prefs": {"notePath": "/nonexistent/t7-harness.md"}},
    "google-chrome": {"command": "search-history", "query": "", "row": None, "expect": ("applescript", "make new tab"),
                      "storage": {"is-installed": True}},
    # Its recent projects read VS Code's own database, which needs VS Code in /Applications; installed extensions do not.
    "visual-studio-code-recent-projects": {"command": "extensions", "query": "", "row": None, "expect": ("open", "vscode")},
    "google-search": {"command": "index", "query": "pilot", "row": None, "expect": ("open", "google.com/search")},
}


def say(text=""):
    print(text, flush=True)


def run(argv, env=None, timeout=120):
    """Runs one command, printing it and its whole stdout (stderr after it, marked), and answers (exit, stdout, seconds)."""
    say("$ " + " ".join(quote(a) for a in argv))
    started = time.monotonic()
    try:
        done = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=timeout)
        code, out, err = done.returncode, done.stdout, done.stderr
    except subprocess.TimeoutExpired as late:
        code, out, err = "timeout", (late.stdout or b"").decode() if isinstance(late.stdout, bytes) else (late.stdout or ""), ""
    took = time.monotonic() - started
    if out:
        say(out.rstrip("\n"))
    if err:
        say("# stderr:\n" + err.rstrip("\n"))
    say("# exit %s, %.2f s" % (code, took))
    return code, out, took


def quote(word):
    return word if word and all(c.isalnum() or c in "-_./:=,@+" for c in word) else "'" + word.replace("'", "'\"'\"'") + "'"


def pilot(args, ns, timeout=120):
    env = dict(os.environ, PILOT_SOCKET=ns.socket)
    code, out, took = run([ns.pilot] + args, env=env, timeout=timeout)
    try:
        answer = json.loads(out) if out.strip() else None
    except ValueError:
        answer = None
    return code, answer, took


def hosts_left(ns):
    """This sandbox's hosts still running (by the real host's path), and every pilot-ext-host on the Mac, with owners."""
    mine = subprocess.run(["/usr/bin/pgrep", "-f", ns.host], capture_output=True, text=True).stdout.split()
    every = subprocess.run(["/usr/bin/pgrep", "-lf", "pilot-ext-host"], capture_output=True, text=True).stdout.strip()
    say("# hosts of this sandbox left: %s" % (" ".join(mine) or "none"))
    if every:
        say("# every pilot-ext-host on this Mac (other slots run their own):\n" + every)
    return mine


def chosen(ns):
    only = set(filter(None, (ns.only or "").split(",")))
    return [(folder, title) for folder, title in FROZEN if not only or folder in only]


def installed(ns):
    """The ids the sandbox has installed."""
    _, answer, _ = pilot(["list", "extensions"], ns)
    rows = answer if isinstance(answer, list) else (answer or {}).get("items", []) if isinstance(answer, dict) else []
    return {row.get("id") for row in rows if isinstance(row, dict)}


def ensure(ns, folder):
    """Puts the folder `install` kept back into this sandbox when it lacks it; answers the extension's id. Kill Process
    goes through `pilot ext install <folder>`, whose answer names the sandbox's Extensions folder; every other one is
    copied into that folder, which Pilot reads on each call: a local install asks its whole question, and a big
    extension's passes the 1,200 characters Pilot shows (only the GitHub route counts them down), so it is denied."""
    kept = os.path.join(ns.work, "installed", folder)
    if not os.path.isdir(kept):
        say("# %s: no installed folder kept (its GitHub install failed or never ran)" % folder)
        return None
    ext = json.load(open(os.path.join(kept, "package.json")))["name"]
    if ext in ns.have:
        if not getattr(ns, "extensions", None):
            _, card, _ = pilot(["ext", "show", ext], ns)
            ns.extensions = os.path.dirname(card["folder"]) if isinstance(card, dict) and card.get("folder") else None
        return ext
    if not getattr(ns, "extensions", None):
        code, answer, _ = pilot(["ext", "install", os.path.join(ns.work, "installed", "kill-process")], ns)
        if code != 0 or not isinstance(answer, dict) or not answer.get("folder"):
            return None
        ns.extensions = os.path.dirname(answer["folder"])
        ns.have.add("kill-process")
        if ext in ns.have:
            return ext
    shutil.copytree(kept, os.path.join(ns.extensions, ext), symlinks=True)
    say("# copied %s into the sandbox's Extensions folder %s" % (kept, ns.extensions))
    code, _, _ = pilot(["ext", "show", ext], ns)
    if code != 0:
        return None
    ns.have.add(ext)
    return ext


def phase_install(ns):
    os.makedirs(os.path.join(ns.work, "installed"), exist_ok=True)
    results = {}
    for folder, title in chosen(ns):
        say("\n## install %s (%s)" % (title, folder))
        code, answer, took = pilot(["ext", "install", "github:raycast/extensions/extensions/" + folder], ns, timeout=300)
        where = (answer or {}).get("folder") if isinstance(answer, dict) else None
        results[folder] = {"exit": code, "seconds": round(took, 2), "commands": (answer or {}).get("commands") if isinstance(answer, dict) else None}
        if code == 0 and where:
            kept = os.path.join(ns.work, "installed", folder)
            shutil.rmtree(kept, ignore_errors=True)
            shutil.copytree(where, kept, symlinks=True)
            say("# kept %s as %s" % (where, kept))
    save(ns, "install", results)


def views(ns, ext):
    """The view commands of an installed extension, from its card."""
    _, card, _ = pilot(["ext", "show", ext], ns)
    commands = (card or {}).get("commands", []) if isinstance(card, dict) else []
    return [c for c in commands if isinstance(c, dict) and c.get("mode") not in ("no-view", "menu-bar", "bar")], commands


def content(answer):
    """Whether an `ext run` answer shows content: a row that is not a loading or empty placeholder, or a detail."""
    if not isinstance(answer, dict):
        return False
    items = [i for i in answer.get("items", []) if isinstance(i, dict)]
    if any(i.get("actions") or i.get("subtitle") or i.get("accessory") for i in items) or len(items) > 1:
        return True
    detail = answer.get("detail")
    return isinstance(detail, dict) and bool(detail.get("markdown") or detail.get("metadata"))


def phase_run(ns):
    ns.have = installed(ns)
    results = {}
    for folder, title in chosen(ns):
        say("\n## run %s (%s)" % (title, folder))
        ext = ensure(ns, folder)
        if not ext:
            results[folder] = {"installed": False}
            continue
        shown, commands = views(ns, ext)
        rows = {}
        for command in shown:
            action = command.get("action") or "ext.%s.%s" % (ext, command.get("name"))
            for query in ("", "a"):
                code, answer, took = pilot(["ext", "run", action, "--query", query], ns, timeout=60)
                left = hosts_left(ns)
                rows.setdefault(action, []).append({"query": query, "exit": code, "seconds": round(took, 2), "content": content(answer),
                                                    "error": error_of(answer), "hostsLeft": len(left)})
        results[folder] = {"installed": True, "id": ext, "commands": len(commands), "views": rows,
                           "skipped": [c.get("name") for c in commands if isinstance(c, dict) and c.get("mode") in ("no-view", "menu-bar", "bar")]}
    save(ns, "run", results)


def error_of(answer):
    if isinstance(answer, dict):
        if answer.get("error"):
            return str(answer["error"])[:200]
        items = answer.get("items") or []
        if len(items) == 1 and isinstance(items[0], dict) and items[0].get("error"):
            return str(items[0].get("title"))[:200]
    return None


def measured(ns, since):
    """The measure log's records from line `since` on."""
    with open(ns.measure) as log:
        lines = log.readlines()
    return [json.loads(l) for l in lines[since:] if l.strip()], len(lines)


def lines_in(ns):
    return sum(1 for _ in open(ns.measure)) if os.path.exists(ns.measure) else 0


def phase_act(ns):
    ns.have = installed(ns)
    victim = os.path.basename(subprocess.run(["/bin/ps", "-o", "comm=", "-p", str(ns.victim)], capture_output=True, text=True).stdout.strip())
    say("# the harness's sleep: pid %s, named %s" % (ns.victim, victim or "?"))
    results = {}
    for folder, title in chosen(ns):
        spec = GATE.get(folder)
        if not spec:
            continue
        say("\n## act %s (%s)" % (title, folder))
        ext = ensure(ns, folder)
        if not ext:
            results[folder] = {"installed": False}
            continue
        for name, value in spec.get("prefs", {}).items():
            pilot(["add", "ext-prefs", "--pref", "%s.%s" % (ext, name), "--value", value], ns)
        if spec.get("storage") and getattr(ns, "extensions", None):
            data = os.path.join(os.path.dirname(ns.extensions), "ExtensionData", ext, "data")
            os.makedirs(data, exist_ok=True)
            with open(os.path.join(data, ".raycast-local-storage.json"), "w") as out:
                json.dump(spec["storage"], out)
            say("# seeded %s's LocalStorage in the sandbox: %s" % (ext, json.dumps(spec["storage"])))
        query = spec["query"].replace("{victim}", victim)
        action = "ext.%s.%s" % (ext, spec["command"])
        _, answer, _ = pilot(["ext", "run", action, "--query", query], ns, timeout=60)
        hosts_left(ns)
        for again in (2, 3):
            if content(answer):
                break
            # A slow first load (Brew's `brew` calls) ends a one-shot run while loading; a later one reads the cache it kept.
            say("# no content yet; run %d, as another open would, reads the extension's own cache" % again)
            _, answer, _ = pilot(["ext", "run", action, "--query", query], ns, timeout=60)
            hosts_left(ns)
        items = (answer or {}).get("items", []) if isinstance(answer, dict) else []
        first = items[0].get("title", "") if items and isinstance(items[0], dict) else ""
        row = spec["row"].replace("{victim}", victim).replace("{first}", first) if spec["row"] else first_pressable(items)
        result = {"id": ext, "command": action, "query": query, "content": content(answer), "row": row}
        if not row:
            result["pressed"] = False
            results[folder] = result
            continue
        since = lines_in(ns)
        press = ["ext", "act", ext, row, "--command", spec["command"]] + (["--query", query] if query else [])
        code, pressed, _ = pilot(press, ns, timeout=60)
        if code != 0:
            # A slow synchronous call at load (Chrome's `brew --prefix`) can hold a view's first answer past 2 s: once more.
            say("# the press failed; once more")
            since = lines_in(ns)
            code, pressed, _ = pilot(press, ns, timeout=60)
        left = hosts_left(ns)
        time.sleep(0.5)
        records, _ = measured(ns, since)
        calls = [r for r in records if r.get("kind") in ("exec", "open", "applescript", "copy", "paste")]
        say("# the measure log's calls after the press:")
        for call in calls:
            say(json.dumps(call, sort_keys=True))
        kind, piece = spec["expect"]
        hit = [c for c in calls if c.get("kind") == kind and piece in json.dumps(c)]
        # A typed action (Action.Open and the rest) is Pilot's to perform: `ext act` answers it, and the host never sees it.
        if isinstance(pressed, dict) and pressed.get("note", "").startswith("answered") and piece in json.dumps(pressed.get("action")):
            hit.append({"kind": kind, "answeredByPilot": pressed.get("action")})
            say("# the press answered a typed action, Pilot's to perform: %s" % json.dumps(pressed.get("action"), sort_keys=True))
        result.update({"actExit": code, "calls": calls, "expected": "%s %s" % (kind, piece), "issued": bool(hit), "hostsLeft": len(left)})
        if folder == "kill-process":
            alive = subprocess.run(["/bin/kill", "-0", str(ns.victim)], capture_output=True).returncode == 0
            say("# kill -0 %s: %s" % (ns.victim, "still running" if alive else "gone"))
            result["victimGone"] = not alive
        results[folder] = result
    save(ns, "act", results)


def first_pressable(items):
    """The first row with an action, by its title, as `ext act` takes it: its first action is the primary one."""
    for item in items:
        if isinstance(item, dict) and item.get("actions"):
            return item.get("title")
    return None


def save(ns, phase, results):
    path = os.path.join(ns.work, "%s.json" % phase)
    old = json.load(open(path)) if os.path.exists(path) else {}
    old.update(results)
    with open(path, "w") as out:
        json.dump(old, out, indent=1, sort_keys=True)
    say("# %s results: %s" % (phase, path))


def percentile(values, p):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(p / 100 * (len(ordered) - 1))))] if ordered else None


def phase_summary(ns):
    run_results = json.load(open(os.path.join(ns.work, "run.json")))
    act_path = os.path.join(ns.work, "act.json")
    act_results = json.load(open(act_path)) if os.path.exists(act_path) else {}
    say("extension | views run | views with content | hosts left | gate press")
    for folder, title in FROZEN:
        r = run_results.get(folder)
        if not r or not r.get("installed"):
            say("%s | not installed" % title)
            continue
        shown = r["views"]
        good = sum(1 for runs in shown.values() if any(x["content"] for x in runs))
        left = sum(x["hostsLeft"] for runs in shown.values() for x in runs)
        a = act_results.get(folder)
        press = "" if not a else ("issued %s" % a.get("expected") if a.get("issued") else "NOT issued (%s)" % a.get("expected"))
        say("%s | %d | %d | %d | %s" % (title, len(shown), good, left, press))
    exits = []
    with open(ns.measure) as log:
        for line in log:
            record = json.loads(line)
            if record.get("kind") == "exit" and record.get("mode") == "run":
                exits.append(record)
    first = [r["firstLineMs"] for r in exits if r.get("firstLineMs") is not None]
    peak = [r["peakFootprintMB"] for r in exits if r.get("peakFootprintMB") is not None]
    for name, values, unit in (("first answer (host's first stdout line, from its start)", first, "ms"), ("host peak footprint", peak, "MB")):
        if values:
            say("%s: %d runs, median %.1f %s, p90 %.1f %s, highest %.1f %s" % (name, len(values), statistics.median(values), unit,
                                                                         percentile(values, 90), unit, max(values), unit))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("phase", choices=["install", "run", "act", "summary"])
    parser.add_argument("--pilot")
    parser.add_argument("--socket")
    parser.add_argument("--work", required=True)
    parser.add_argument("--host")
    parser.add_argument("--measure")
    parser.add_argument("--victim", type=int)
    parser.add_argument("--only")
    ns = parser.parse_args()
    {"install": phase_install, "run": phase_run, "act": phase_act, "summary": phase_summary}[ns.phase](ns)


if __name__ == "__main__":
    sys.exit(main())
