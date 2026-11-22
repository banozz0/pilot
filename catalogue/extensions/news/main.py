#!/usr/bin/env python3
"""News for Pilot (Sven, 2026-11-22): headlines from the sources he picks, Malta first, newest first in Hyper+Space and
on the extension's page, and a 24-hour summary made only when he presses for one, laid out as a newspaper's front
page in one HTML file.

`news` is the Hyper+Space list: a row that makes the summary, then every headline (its source and age; Return opens
it in the browser). `page` is the extension's page: the summary's button and the last one, the headlines, and the
sources by place and kind, each switched on or off there (no list type exists among preferences, so picking lives on
the page), with a box that adds any RSS or Atom link, or words to follow through a Google News search.
Headlines are read from the cache alone; a view finding them older than FRESH starts one refresh, a detached child
(`main.py --refresh`) holding a lock, so no view waits on the network and two never fetch at once. No AI reads them.
`summarise` gathers the picked sources' items of the last 24 hours and sends their headlines and short descriptions
(never whole articles) through Pilot's AI with an `ai` action (ADR 0010, amended 2026-10-25); `summarised` gets the
answer, writes the paper to the Save in folder (~/Downloads/Pilot News unless picked) and opens it. One press, one
summary: a press while one is on its way says so. Nothing runs on a timer.
Python 3.9 stdlib only, as macOS's /usr/bin/python3; feeds come through curl. Nothing logs a headline or feed text.
"""
import sys

sys.dont_write_bytecode = True  # no __pycache__ in the extension's folder

import fcntl  # noqa: E402
import hashlib  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import subprocess  # noqa: E402
import time  # noqa: E402
from urllib.parse import urlparse  # noqa: E402

import feeds  # noqa: E402
import paper  # noqa: E402

PAGE = "pilot://open?tab=page&extension=news"
FRESH = 600  # seconds headlines count as fresh
RETRY = 120  # seconds after a refresh before a view starts another
KEPT_FOR = 3 * 86400  # seconds an item is kept
KEPT = 1500  # items kept at most
DAY = 86400
SUMMARY_FRESH = 300  # seconds of headlines a summary uses as they are; older ones are fetched first
SUMMARY_WAIT = 20  # seconds a summary waits for that fetch
REFRESH_TIME = 22  # seconds one refresh may take in all
STALE = 600  # seconds a summary may take before it counts as lost
MOST_READ = 200  # items one summary sends at most
PER_SOURCE = 40  # of them, from one source at most
ROWS = 150  # headlines in Hyper+Space
PAGE_ROWS = 50  # on the page (a list block's most)
ICONS = {"Malta": "🇲🇹", "World": "🌍", "Tech": "💻", "Business": "💼", "Reddit": "👽", "Yours": "📡"}
CACHE, LOCK, PICKS, SUMMARY = "headlines.json", "refresh.lock", "sources.json", "summary.json"


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


def hud(text):
    send({"type": "hud", "text": text})


def run_action(command, title, context=None, **fields):
    action = {"type": "run", "command": command, "title": title}
    if context is not None:
        action["context"] = context
    action.update(fields)
    return action


def load(folder, name, default=None):
    try:
        with open(os.path.join(folder, name), encoding="utf-8") as f:
            value = json.load(f)
    except (OSError, ValueError):
        return {} if default is None else default
    return value if isinstance(value, dict) else ({} if default is None else default)


def save(folder, name, value):
    path = os.path.join(folder, name)
    with open(path + ".part", "w", encoding="utf-8") as f:
        json.dump(value, f, ensure_ascii=False)
    os.replace(path + ".part", path)


def folders(run):
    paths = run.get("paths") or {}
    data = paths.get("data") or paths.get("cache")
    cache = paths.get("cache") or data
    if not isinstance(data, str) or not data:
        send({"type": "error", "text": "Pilot sent no data folder"})
        sys.exit(0)
    for folder in (data, cache):
        os.makedirs(folder, exist_ok=True)
    return data, cache


# MARK: Sources

class Sources:
    """The built-in sources and his own, with what he switched on or off (paths.data/sources.json: `picked`, id to
    true or false over each built-in's default, and `mine`, the feeds he added, each on unless picked off)."""

    def __init__(self, data):
        self.data = data
        saved = load(data, PICKS)
        self.picked = saved.get("picked") if isinstance(saved.get("picked"), dict) else {}
        self.mine = [m for m in saved.get("mine") or [] if isinstance(m, dict) and feeds.is_feed_url(m.get("url", ""))]
        self.all = feeds.built_in() + [dict(m, group="Yours", on=True) for m in self.mine]
        self.by_id = {s["id"]: s for s in self.all}

    def is_on(self, source):
        value = self.picked.get(source["id"])
        return value if isinstance(value, bool) else source["on"]

    def on(self):
        return [s for s in self.all if self.is_on(s)]

    def titles(self):
        return {s["id"]: s["title"] for s in self.all}

    def groups(self):
        return {s["id"]: s["group"] for s in self.all}

    def store(self):
        save(self.data, PICKS, {"picked": self.picked, "mine": self.mine})


# MARK: Headlines and their refresh

def locked(f):
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False


def refreshing(cache):
    try:
        with open(os.path.join(cache, LOCK), "a") as f:
            return not locked(f)
    except OSError:
        return False


def refresh(cache, sources):
    """Fetches `sources` and keeps their items with the ones kept already: a source that fails keeps its last items and
    says why; items past KEPT_FOR go."""
    now = time.time()
    kept = load(cache, CACHE)
    old = [i for i in kept.get("items") or [] if isinstance(i, dict) and now - i.get("at", 0) < KEPT_FOR]
    seen = {i["id"]: i["at"] for i in old}
    status = kept.get("sources") if isinstance(kept.get("sources"), dict) else {}
    answers = feeds.fetch_all(sources, os.path.join(cache, "feeds"), time.monotonic() + REFRESH_TIME)
    fresh = {}
    for source in sources:
        body, error = answers.get(source["id"], (None, "was not asked"))
        if body is not None:
            try:
                raw = feeds.parse(body)
            except feeds.FeedProblem as e:
                error = str(e)
            else:
                fresh[source["id"]] = [feeds.tidy(source, r, seen, now) for r in raw]
                fresh[source["id"]] = [i for i in fresh[source["id"]] if now - i["at"] < KEPT_FOR]
        last = status.get(source["id"]) if isinstance(status.get(source["id"]), dict) else {}
        status[source["id"]] = {"error": error, "triedAt": now, "count": len(fresh.get(source["id"], [])) if not error
                                else last.get("count", 0), "fetchedAt": now if not error else last.get("fetchedAt")}
    items = [i for i in old if i["source"] not in fresh] + [i for group in fresh.values() for i in group]
    items.sort(key=lambda i: -i["at"])
    save(cache, CACHE, {"fetchedAt": now, "sources": status, "items": items[:KEPT]})


def refresh_main():
    job = json.loads(sys.stdin.read())
    refresh(job["cache"], job["sources"])


def start_refresh(cache, sources):
    """Takes the lock and hands it to a detached child that fetches; None when a refresh runs already."""
    if not sources:
        return None
    try:
        lock = open(os.path.join(cache, LOCK), "a")
    except OSError:
        return None
    with lock:
        if not locked(lock):
            return None
        try:
            child = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--refresh"], stdin=subprocess.PIPE,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, pass_fds=(lock.fileno(),),
                                     start_new_session=True, cwd=os.path.dirname(os.path.abspath(__file__)))
            child.stdin.write(json.dumps({"cache": cache, "sources": sources}).encode())
            child.stdin.close()
        except OSError:
            return None
    return child


def headlines(cache, sources, budget=0.0, force=False, fresh_for=FRESH):
    """(the kept record, True while a refresh runs). A record older than `fresh_for`, missing a picked source, or
    `force`, starts a refresh (not within RETRY of the last, unless forced); the view waits for it `budget` s at most."""
    started = time.monotonic()
    record = load(cache, CACHE)
    now = time.time()
    tried = record.get("sources") or {}
    missing = [s for s in sources if s["id"] not in tried]
    stale = now - (record.get("fetchedAt") or 0) >= fresh_for
    recent = now - (record.get("fetchedAt") or 0) < RETRY
    if force or missing or (stale and not recent):
        start_refresh(cache, sources)
    running = refreshing(cache)
    while running and budget and time.monotonic() - started < budget:
        time.sleep(0.1)
        running = refreshing(cache)
    if budget:
        record = load(cache, CACHE)
    return record, running


def picked_items(record, sources):
    ids = {s["id"] for s in sources}
    return feeds.merged([i for i in record.get("items") or [] if isinstance(i, dict) and i.get("source") in ids])


def age(at, now=None):
    seconds = max(0, (now or time.time()) - at)
    if seconds < 60:
        return "now"
    if seconds < 3600:
        return "%d min" % (seconds // 60)
    if seconds < DAY:
        return "%d h" % (seconds // 3600)
    return "%d d" % (seconds // DAY)


def clock(at):
    if not at:
        return "never"
    today = time.localtime()[:3] == time.localtime(at)[:3]
    return time.strftime("%H:%M" if today else "%a %H:%M", time.localtime(at))


# MARK: The summary's state

def summary_state(data):
    """The last summary: `status` working, done or failed, with its time, file, seconds and who answered. One on its way
    for longer than STALE counts as lost, so a new press may start."""
    state = load(data, SUMMARY)
    if state.get("status") == "working" and time.time() - state.get("started", 0) > STALE:
        state.update(status="failed", error="no answer came back")
    return state


def save_in(run):
    chosen = ((run.get("preferences") or {}).get("folder") or "").strip()
    return os.path.expanduser(chosen) if chosen else os.path.expanduser("~/Downloads/Pilot News")


def summary_line(state):
    if state.get("status") == "working":
        return "Summarising %d headlines…" % state.get("count", 0)
    if state.get("status") == "failed":
        return "The last summary failed: %s" % state.get("error", "")
    if state.get("status") == "done":
        return "Last summary %s · %d headlines · %d s · %s" % (clock(state.get("at")), state.get("count", 0),
                                                              round(state.get("seconds", 0)), state.get("by") or "Pilot's AI")
    return ""


# MARK: Commands

def news(run):
    """Hyper+Space: the summary's row, then every picked source's headline, newest first."""
    data, cache = folders(run)
    sources = Sources(data)
    on = sources.on()
    record, running = headlines(cache, on, budget=1.0 if not load(cache, CACHE) else 0.0)
    items = picked_items(record, on)
    titles, groups = sources.titles(), sources.groups()
    state = summary_state(data)
    last_day = [i for i in items if time.time() - i["at"] < DAY]
    row = {"id": "summarise", "title": "Summarise the last 24 hours", "icon": "📰",
           "subtitle": summary_line(state) or "%d headlines from your sources, laid out as a front page" % len(last_day),
           "keywords": "summary summarize digest newspaper front page today",
           "actions": [run_action("summarise", "Summarise the last 24 hours")]}
    if state.get("path") and os.path.exists(state["path"]):
        row["actions"].append({"type": "open", "url": state["path"], "title": "Open the last summary", "key": "cmd+o"})
    rows = [row]
    if not items:
        rows.append({"id": "empty", "title": "Fetching headlines…" if running else "No headlines yet",
                     "subtitle": "Pick your sources on the News page", "icon": "📡",
                     "actions": [{"type": "open", "url": PAGE, "title": "Open the News page"}]})
    now = time.time()
    for item in items[:ROWS]:
        source = titles.get(item["source"], item["source"])
        rows.append({"id": item["id"], "title": item["title"],
                     "subtitle": source + (" · " + item["via"] if item.get("via") else ""),
                     "accessory": age(item["at"], now), "icon": ICONS.get(groups.get(item["source"]), "📰"),
                     "keywords": " ".join([source, item.get("via", "")]).strip(),
                     "actions": [{"type": "open", "url": item["link"], "title": "Open in the browser"},
                                 {"type": "copy", "text": item["link"], "title": "Copy link", "key": "cmd+shift+c"}]})
    send({"type": "list", "items": rows})


def gather(record, on, now):
    """The last 24 hours' items for a summary, newest first: at most PER_SOURCE a source and MOST_READ in all."""
    counts, chosen = {}, []
    for item in picked_items(record, on):
        if now - item["at"] >= DAY:
            continue
        if counts.get(item["source"], 0) >= PER_SOURCE:
            continue
        counts[item["source"]] = counts.get(item["source"], 0) + 1
        chosen.append(item)
        if len(chosen) >= MOST_READ:
            break
    return chosen


def summarise(run):
    """The press: fresh headlines (fetched first when older than SUMMARY_FRESH), the last 24 hours' gathered, and one
    `ai` action with their headlines and short descriptions; the answer comes back to `summarised`."""
    data, cache = folders(run)
    state = summary_state(data)
    if state.get("status") == "working":
        return hud("A news summary is already on its way (%s)" % age(state.get("started", 0)))
    sources = Sources(data)
    on = sources.on()
    if not on:
        return hud("Pick a source on the News page first")
    started = time.time()
    record, _ = headlines(cache, on, budget=SUMMARY_WAIT, fresh_for=SUMMARY_FRESH)
    items = gather(record, on, time.time())
    if not items:
        return hud("No headlines from the last 24 hours in your sources")
    job = hashlib.sha1(("%f" % started).encode()).hexdigest()[:12]
    jobs = os.path.join(data, "jobs")
    os.makedirs(jobs, exist_ok=True)
    for name in os.listdir(jobs):  # one summary at a time, so only this job's file is kept
        try:
            os.remove(os.path.join(jobs, name))
        except OSError:
            pass
    save(jobs, job + ".json", {"items": items})
    titles = sources.titles()
    save(data, SUMMARY, dict(state, status="working", job=job, started=started, count=len(items),
                             sources=len({i["source"] for i in items}), error=None))
    language = (run.get("preferences") or {}).get("language") or "english"
    hud("Summarising %d headlines from %d sources…" % (len(items), len({i["source"] for i in items})))
    send({"type": "action", "action": {"type": "ai", "prompt": paper.task(language),
                                       "text": paper.numbered(items, titles)[:150000],
                                       "then": run_action("summarised", "News summary", {"job": job, "started": started})}})


def unique(folder, name):
    path, n = os.path.join(folder, name + ".html"), 2
    while os.path.exists(path):
        path, n = os.path.join(folder, "%s %d.html" % (name, n)), n + 1
    return path


def summarised(run):
    """The AI's answer (or why there is none): the paper written and opened, the time it took and who answered kept."""
    data, _ = folders(run)
    context = run.get("context") if isinstance(run.get("context"), dict) else {}
    job = str(context.get("job") or "")
    started = context.get("started") if isinstance(context.get("started"), (int, float)) else time.time()
    seconds = max(0.0, time.time() - started)
    state = load(data, SUMMARY)
    saved = load(os.path.join(data, "jobs"), job + ".json") if job.isalnum() else {}
    items = [i for i in saved.get("items") or [] if isinstance(i, dict)]
    if not items:
        return hud("That news summary's headlines are gone; press Summarise again")
    if context.get("error"):
        if state.get("job") == job:
            save(data, SUMMARY, dict(state, status="failed", error=str(context["error"])[:200], at=time.time()))
        return hud("News summary failed: %s" % str(context["error"])[:160])
    answer = (run.get("input") or "").strip()
    sources = Sources(data)
    titles, groups = sources.titles(), sources.groups()
    by = str(context.get("notice") or "Pilot's AI")
    layout = paper.layout(answer, len(items)) or paper.fallback(answer, items, titles, groups)
    shown = []
    for item in items:
        name = titles.get(item["source"], item["source"])
        if name not in shown:
            shown.append(name)
    html = paper.page(layout, items, titles, {"day": time.time(), "seconds": seconds, "by": by, "sources": shown})
    folder = save_in(run)
    try:
        os.makedirs(folder, exist_ok=True)
        path = unique(folder, time.strftime("%Y-%m-%d"))
        with open(path, "w", encoding="utf-8") as f:
            f.write(html)
    except OSError as e:
        save(data, SUMMARY, dict(state, status="failed", error="could not save it (%s)" % e.strerror, at=time.time()))
        return hud("News summary could not be saved: %s" % e.strerror)
    save(data, SUMMARY, {"status": "done", "job": job, "at": time.time(), "started": started, "seconds": seconds,
                         "by": by, "count": len(items), "path": path})
    hud("News summary ready in %d s · %s" % (round(seconds), by))
    send({"type": "action", "action": {"type": "open", "url": path}})


def refresh_now(run):
    data, cache = folders(run)
    on = Sources(data).on()
    record, running = headlines(cache, on, budget=REFRESH_TIME + 2, force=True)
    failed = [s for s in on if (record.get("sources") or {}).get(s["id"], {}).get("error")]
    hud("Headlines refreshed" + (" · %d not answering" % len(failed) if failed else ""))


def toggle(run):
    data, cache = folders(run)
    sources = Sources(data)
    source = sources.by_id.get(str((run.get("context") or {}).get("id") or ""))
    if not source:
        return hud("That source is gone")
    now_on = not sources.is_on(source)
    sources.picked[source["id"]] = now_on
    sources.store()
    if now_on and source["id"] not in (load(cache, CACHE).get("sources") or {}):
        start_refresh(cache, sources.on())
    hud("%s %s" % (source["title"], "on" if now_on else "off"))


def add_feed(run):
    """Adds his own feed: an RSS or Atom link, read once to check it is one and to name it, or words, followed as a
    Google News search."""
    data, cache = folders(run)
    text = (run.get("input") or "").strip()
    if not text:
        return hud("Paste a feed's link, or type words to follow")
    sources = Sources(data)
    if feeds.is_feed_url(text):
        url, title = text, ""
    else:
        url, title = feeds.google(text), "Google News: %s" % text[:60]
    sid = feeds.custom_id(url)
    if sid in sources.by_id:
        return hud("That feed is in your sources already")
    if not title:
        answer = feeds.fetch_all([{"id": sid, "url": url}], os.path.join(cache, "feeds"), time.monotonic() + 15)
        body, error = answer.get(sid, (None, "was not asked"))
        if error:
            return hud("That feed %s" % error)
        try:
            found = feeds.parse(body)
        except feeds.FeedProblem as e:
            return hud("That link %s" % e)
        title = (feeds.feed_title(body) or urlparse(url).hostname or url)[:60]
        if not found:
            return hud("%s has no items right now; not added" % title)
    sources.mine.append({"id": sid, "title": title, "url": url})
    sources.store()
    start_refresh(cache, Sources(data).on())
    hud("Added %s" % title)


def remove_feed(run):
    data, _ = folders(run)
    sources = Sources(data)
    sid = str((run.get("context") or {}).get("id") or "")
    mine = [m for m in sources.mine if m["id"] != sid]
    if len(mine) == len(sources.mine):
        return hud("That feed is gone")
    sources.mine = mine
    sources.picked.pop(sid, None)
    sources.store()
    hud("Feed removed")


def source_row(sources, source, status):
    on = sources.is_on(source)
    flip = run_action("toggle", "Turn off" if on else "Turn on", {"id": source["id"]})
    tried = status.get(source["id"]) if isinstance(status.get(source["id"]), dict) else {}
    if tried.get("error"):
        words = "Not answering: %s" % tried["error"]
    elif tried:
        words = "%d items · read %s" % (tried.get("count", 0), clock(tried.get("triedAt")))
    else:
        words = urlparse(source["url"]).hostname or ""
    row = {"id": source["id"], "title": source["title"], "subtitle": words, "actions": [flip],
           "inline": [dict(flip, icon="checkmark.circle" if on else "circle")]}
    if on:
        row["accessory"] = {"text": "On", "tone": "warn" if tried.get("error") else "fine"}
    if source["group"] == "Yours":
        gone = run_action("remove-feed", "Remove", {"id": source["id"]}, destructive=True)
        row["actions"].append(gone)
        row["inline"].append(dict(gone, icon="xmark"))
    return row


def page(run):
    """The page: the summary's buttons and its last one, the headlines, then the sources to pick from by group."""
    data, cache = folders(run)
    sources = Sources(data)
    on = sources.on()
    record, running = headlines(cache, on)
    items = picked_items(record, on)
    titles, status = sources.titles(), record.get("sources") or {}
    state = summary_state(data)
    working = state.get("status") == "working"
    now = time.time()
    last_day = sum(1 for i in items if now - i["at"] < DAY)
    buttons = [run_action("summarise", "Summarise the last 24 hours", icon="📰")]
    if state.get("path") and os.path.exists(state["path"]):
        buttons.append({"type": "open", "url": state["path"], "title": "Open the last summary"})
    buttons.append(run_action("refresh", "Refresh", icon="refresh"))
    head = [{"type": "buttons", "actions": buttons}]
    if summary_line(state):
        head.append({"type": "note", "text": summary_line(state), "icon": "info"})
    blocks = [{"type": "section", "title": "News", "subtitle": "%d headlines in the last 24 hours from %d sources" % (
        last_day, len(on)), "aside": "Refreshing…" if running else "Read %s" % clock(record.get("fetchedAt")),
        "blocks": head}]
    failing = [s for s in on if (status.get(s["id"]) or {}).get("error")]
    if failing:
        blocks.append({"type": "list", "title": "Not answering", "items": [
            {"id": "x-" + s["id"], "title": s["title"], "subtitle": status[s["id"]]["error"],
             "badges": [{"text": "Kept %d" % status[s["id"]].get("count", 0), "tone": "warn"}],
             "actions": [{"type": "open", "url": s["url"], "title": "Open the feed"}]} for s in failing]})
    rows = [{"id": i["id"], "title": i["title"], "subtitle": titles.get(i["source"], i["source"]),
             "accessory": age(i["at"], now), "actions": [{"type": "open", "url": i["link"], "title": "Open"}]}
            for i in items[:PAGE_ROWS]]
    blocks.append({"type": "list", "title": "Headlines", "items": rows} if rows else
                  {"type": "markdown", "text": "_Fetching headlines…_" if running else "_No headlines yet: switch a source on below._"})
    picks = [{"type": "input", "placeholder": "Add a feed: paste an RSS or Atom link, or words to follow on Google News",
              "action": run_action("add-feed", "Add")}]
    for group in feeds.GROUPS:
        members = [s for s in sources.all if s["group"] == group]
        if members:
            picks.append({"type": "list", "title": group + (" · " + feeds.GROUP_NOTES[group] if group in feeds.GROUP_NOTES else ""),
                          "items": [source_row(sources, s, status) for s in members]})
    blocks.append({"type": "section", "title": "Sources", "subtitle": "%d on · Malta first; tick the ones you read" % len(on),
                   "blocks": picks})
    answer = {"type": "blocks", "blocks": blocks}
    if working or running:
        answer["refresh"] = 2
    send(answer)


COMMANDS = {"news": news, "summarise": summarise, "summarised": summarised,
            "refresh": refresh_now, "toggle": toggle, "add-feed": add_feed, "remove-feed": remove_feed, "page": page}


def main():
    if sys.argv[1:] == ["--refresh"]:
        return refresh_main()
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        return send({"type": "error", "text": "got a run message it could not read"})
    command = COMMANDS.get(run.get("command"))
    if not command:
        return send({"type": "error", "text": "has no command %s" % run.get("command")})
    try:
        command(run)
    except OSError as e:
        send({"type": "error", "text": "could not use its files (%s)" % e.strerror})


if __name__ == "__main__":
    main()
