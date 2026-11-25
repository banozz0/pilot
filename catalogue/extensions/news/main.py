#!/usr/bin/env python3
"""News for Pilot (Sven, 2026-11-22): headlines from the sources he picks, world and tech first, newest first in Hyper+Space and
on the extension's page, and a 24-hour summary made only when he presses for one, laid out as a newspaper's front
page in one HTML file.

`news` is the Hyper+Space list: a row that makes the summary, then every headline (its source and age; Return opens
it in the browser). `page` is the extension's page: the summary's button and the last one, the headlines and the
sources not answering. `bar` is the menu-bar item and Pilot's dock face (ADR 0010, amended 2026-11-13): 📰 and the
count of headlines new since its popover last opened; the popover has a count per ticked group (each opening that
group's headlines, the hidden `group` command), the three newest headlines and the summary's links beside Pilot's Open
page (Sven on build 3160).
Sources are ticked in the extension's Settings (Sven, build 3142): a checkbox per built-in source, `source-<id>`, by
place and kind, and Your feeds, a text of RSS or Atom links or words to follow through a Google News search. Those
preferences alone pick what is read and summarised; 1.1.0's ticks on the page (paths.data/sources.json) are not read.
Headlines are read from the cache alone; a view finding them older than FRESH starts one refresh, a detached child
(`main.py --refresh`) holding a lock, so no view waits on the network and two never fetch at once. The bar item is
asked every 2 minutes while the screen is in use (its count catching up after an open), the picked feeds still read at
most every FRESH then. No AI reads
them.
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

PAGE = "pilot://open?tab=page&extension=news"
SETTINGS = "pilot://open?page=extensions&extension=news"  # its Settings form, on the Extensions page
PICK_SOURCES = {"type": "open", "url": SETTINGS, "title": "Pick sources"}
NO_SOURCES = "No sources ticked"
TICK_FIRST = "Tick a source in News' Settings first"
DAY = 86400
FRESH = 600  # seconds headlines count as fresh
RETRY = 120  # seconds after a refresh before a view starts another
KEPT_FOR = 3 * DAY  # seconds an item is kept
KEPT = 1500  # items kept at most
SUMMARY_FRESH = 300  # seconds of headlines a summary uses as they are; older ones are fetched first
SUMMARY_WAIT = 20  # seconds a summary waits for that fetch
REFRESH_TIME = 22  # seconds one refresh may take in all
STALE = 600  # seconds a summary may take before it counts as lost
FETCH_STALE = 60  # seconds a press may spend fetching before it counts as lost
ASK_AGAIN_AFTER = 75  # seconds a summary waits before a press, or its page's Ask again, asks again
MOST_READ = 200  # items one summary sends at most
PER_SOURCE = 40  # of them, from one source at most
ROWS = 150  # headlines in Hyper+Space
PAGE_ROWS = 50  # on the page (a list block's most)
BAR_ROWS = 3  # in the bar item's popover, under the counts
GROUPS_PER_ROW = 3  # group counts on one popover row
TITLE_ROOM = 40  # characters of a headline on a popover row
SOURCE_ROOM = 16  # of its source
LONGEST = 24  # Pilot's bar text and a dock face's value
MINE = 20  # feeds of his own read at most
ICONS = {"Malta": "🇲🇹", "World": "🌍", "Tech": "💻", "Business": "💼", "Reddit": "👽", "Yours": "📡"}
CACHE, LOCK, OLD_PICKS, SUMMARY, SEEN = "headlines.json", "refresh.lock", "sources.json", "summary.json", "seen.json"


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


def hud(text, *actions):
    """The HUD line, then `actions`. Pilot shows a no-view's hud message only when it prints no action, so with actions
    the line goes first as a hud action."""
    if not actions:
        return send({"type": "hud", "text": text})
    for action in ({"type": "hud", "text": text},) + actions:
        send({"type": "action", "action": action})


def run_action(command, title, context=None, **fields):
    action = {"type": "run", "command": command, "title": title}
    if context is not None:
        action["context"] = context
    action.update(fields)
    return action


def load(folder, name):
    try:
        with open(os.path.join(folder, name), encoding="utf-8") as f:
            value = json.load(f)
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def save(folder, name, value):
    path = os.path.join(folder, name)
    with open(path + ".part", "w", encoding="utf-8") as f:
        json.dump(value, f, ensure_ascii=False)
    os.replace(path + ".part", path)


def language(run):
    return (run.get("preferences") or {}).get("language") or "english"


def last_day(items, now):
    return [i for i in items if now - i.get("at", 0) < DAY]


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
    """What his Settings tick, and nothing else: each built-in source's checkbox (`source-<id>`; Pilot sends it resolved,
    its manifest default while he never touched it, which the form shows too) and Your feeds. A missing or non-boolean
    value is off."""

    def __init__(self, run):
        prefs = run.get("preferences") or {}
        self.all = [dict(s, on=prefs.get("source-" + s["id"]) is True) for s in feeds.built_in()] + mine(prefs.get("feeds"))

    def on(self):
        return [s for s in self.all if s["on"]]

    def titles(self):
        return {s["id"]: s["title"] for s in self.all}

    def groups(self):
        return {s["id"]: s["group"] for s in self.all}


def mine(text):
    """Your feeds: the text split at commas, each an RSS or Atom link (named by its host) or words followed through a
    Google News search; MINE at most, a repeat once."""
    found, seen = [], set()
    for piece in (text if isinstance(text, str) else "").split(","):
        piece = piece.strip()
        if not piece:
            continue
        if feeds.is_feed_url(piece):
            url, title = piece, (urlparse(piece).hostname or piece).replace("www.", "", 1)
        else:
            url, title = feeds.google(piece), "Google News: %s" % piece[:60]
        sid = feeds.custom_id(url)
        if sid not in seen:
            seen.add(sid)
            found.append({"id": sid, "group": "Yours", "title": title[:60], "url": url, "on": True})
    return found[:MINE]


def old_feeds(data, sources):
    """1.1.0's own feeds (sources.json's `mine`) not in Your feeds yet, so the page can say what to paste."""
    have = {s["url"] for s in sources.all}
    return [m["url"] for m in load(data, OLD_PICKS).get("mine") or []
            if isinstance(m, dict) and feeds.is_feed_url(m.get("url", "")) and m["url"] not in have]


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
                tidied = (feeds.tidy(source, r, seen, now) for r in raw)
                fresh[source["id"]] = [i for i in tidied if now - i["at"] < KEPT_FOR]
        if error:  # its last items stay, with why the fetch failed
            last = status.get(source["id"]) if isinstance(status.get(source["id"]), dict) else {}
            count, fetched = last.get("count", 0), last.get("fetchedAt")
        else:
            count, fetched = len(fresh[source["id"]]), now
        status[source["id"]] = {"error": error, "triedAt": now, "count": count, "fetchedAt": fetched}
    items = [i for i in old if i["source"] not in fresh] + [i for group in fresh.values() for i in group]
    items.sort(key=lambda i: -i["at"])
    save(cache, CACHE, {"fetchedAt": now, "sources": status, "items": items[:KEPT]})


def refresh_main():
    job = json.loads(sys.stdin.read())
    refresh(job["cache"], job["sources"])


def start_refresh(cache, sources):
    """Takes the lock and hands it to a detached child that fetches; nothing when a refresh runs already."""
    if not sources:
        return False
    try:
        lock = open(os.path.join(cache, LOCK), "a")
    except OSError:
        return False
    with lock:
        if not locked(lock):
            return False
        try:
            child = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--refresh"], stdin=subprocess.PIPE,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, pass_fds=(lock.fileno(),),
                                     start_new_session=True, cwd=os.path.dirname(os.path.abspath(__file__)))
            child.stdin.write(json.dumps({"cache": cache, "sources": sources}).encode())
            child.stdin.close()
        except OSError:
            return False
    return True


def headlines(cache, sources, budget=0.0, force=False, fresh_for=FRESH, empty_budget=0.0):
    """(the kept record, True while a refresh runs). A record older than `fresh_for`, missing a picked source, or
    `force`, starts a refresh (not within RETRY of the last, unless forced); the view waits for it `budget` s at most
    (`empty_budget` when nothing is kept yet), and reads the record again only when a refresh ran meanwhile."""
    started = time.monotonic()
    record = load(cache, CACHE)
    budget = budget or (empty_budget if not record else 0.0)
    since = time.time() - (record.get("fetchedAt") or 0)
    tried = record.get("sources") or {}
    missing = [s for s in sources if s["id"] not in tried]
    began = (force or missing or (since >= fresh_for and since >= RETRY)) and start_refresh(cache, sources)
    running = refreshing(cache)
    waited = began or running
    while running and budget and time.monotonic() - started < budget:
        time.sleep(0.1)
        running = refreshing(cache)
    if budget and waited:
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
    """The last summary: `status` fetching (a press reading its headlines), working (asked), done or failed, with its
    time, file, seconds and who answered. A fetch past FETCH_STALE or an ask past STALE counts as lost, so a new press
    may start."""
    state = load(data, SUMMARY)
    waited = time.time() - state.get("started", 0)
    if (state.get("status") == "fetching" and waited > FETCH_STALE) or (state.get("status") == "working" and waited > STALE):
        state.update(status="failed", error="no answer came back")
    return state


def lost(state):
    """The job of a summary asked ASK_AGAIN_AFTER ago and not answered, which may be asked again; else None."""
    asked = state.get("asked")
    if state.get("status") == "working" and state.get("job") and isinstance(asked, (int, float)) \
            and time.time() - asked >= ASK_AGAIN_AFTER:
        return state["job"]
    return None


def askable(data, job, on):
    """The items of a lost job (see `lost`) to ask again, when every one is from a source still ticked; else none, and a
    press starts a new summary."""
    if not job:
        return []
    items = load(os.path.join(data, "jobs"), job + ".json").get("items") or []
    ids = {s["id"] for s in on}
    return items if items and all(isinstance(i, dict) and i.get("source") in ids for i in items) else []


def summary_buttons(run, data, state, sources, on):
    """Summarise (or Ask again for a lost answer, its job's own ai, only after ASK_AGAIN_AFTER so a double click never asks
    twice) and Open the last summary; Pick sources alone while none is ticked. With whether Ask again shows."""
    if not on:
        return [PICK_SOURCES], False
    kept = askable(data, lost(state), on)
    buttons = [ask_ai(state["job"], kept, sources.titles(), language(run), title="Ask again") if kept else
               run_action("summarise", "Summarise the last 24 hours", icon="📰")]
    if state.get("path") and os.path.exists(state["path"]):
        buttons.append({"type": "open", "url": state["path"], "title": "Open the last summary"})
    return buttons, bool(kept)


def save_in(run):
    chosen = ((run.get("preferences") or {}).get("folder") or "").strip()
    return os.path.expanduser(chosen) if chosen else os.path.expanduser("~/Downloads/Pilot News")


def summary_line(state):
    if state.get("status") == "fetching":
        return "Fetching headlines for a summary…"
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
    sources = Sources(run)
    on = sources.on()
    record, running = headlines(cache, on, empty_budget=1.0)
    items = picked_items(record, on)
    titles, groups = sources.titles(), sources.groups()
    state = summary_state(data)
    row = {"id": "summarise", "title": "Summarise the last 24 hours", "icon": "📰",
           "subtitle": summary_line(state) or "%d headlines from your sources, laid out as a front page" % len(
               last_day(items, time.time())),
           "keywords": "summary summarize digest newspaper front page today",
           "actions": [run_action("summarise", "Summarise the last 24 hours")]}
    if state.get("path") and os.path.exists(state["path"]):
        row["actions"].append({"type": "open", "url": state["path"], "title": "Open the last summary", "key": "cmd+o"})
    rows = [row]
    if not on:
        rows.append({"id": "empty", "title": NO_SOURCES, "subtitle": "Tick your sources in News' Settings",
                     "icon": "📡", "actions": [PICK_SOURCES]})
    elif not items:
        rows.append({"id": "empty", "title": "Fetching headlines…" if running else "No headlines yet",
                     "subtitle": "From the sources ticked in News' Settings", "icon": "📡",
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
    sources = Sources(run)
    on = sources.on()
    job = lost(state)
    items = askable(data, job, on)
    if items:  # an answer lost on the way: the same job asked again; whichever answer comes first is the paper
        save(data, SUMMARY, dict(state, asked=time.time()))
        return hud("Asking again for the news summary", ask_ai(job, items, sources.titles(), language(run)))
    if state.get("status") in ("fetching", "working") and not job:  # lost and no longer askable: a new summary
        return hud("A news summary is already on its way (%s)" % age(state.get("started", 0)))
    if not on:
        return hud(TICK_FIRST)
    started = time.time()
    # Fetching from now, so a second press while the headlines are read is refused too; a fetch that dies with its
    # process counts as lost after FETCH_STALE.
    save(data, SUMMARY, dict(state, status="fetching", started=started, error=None))
    try:
        record, _ = headlines(cache, on, budget=SUMMARY_WAIT, fresh_for=SUMMARY_FRESH)
        items = gather(record, on, time.time())
    except BaseException:
        save(data, SUMMARY, state)
        raise
    if not items:
        save(data, SUMMARY, state)
        return hud("No headlines from the last 24 hours in your sources")
    job = hashlib.sha1(("%f" % started).encode()).hexdigest()[:12]
    jobs = os.path.join(data, "jobs")
    os.makedirs(jobs, exist_ok=True)
    for name in os.listdir(jobs):  # one summary at a time, so only this job's file is kept
        feeds.discard(os.path.join(jobs, name))
    save(jobs, job + ".json", {"items": items})
    save(data, SUMMARY, dict(state, status="working", job=job, started=started, asked=time.time(), count=len(items),
                             error=None))
    named = len({i["source"] for i in items})
    hud("Summarising %d headlines from %d sources…" % (len(items), named),
        ask_ai(job, items, sources.titles(), language(run)))


def ask_ai(job, items, titles, language, title="News summary"):
    """The `ai` action for one job: its items' headlines and descriptions, the answer to `summarised` with the job and when
    it was asked, so the time shown is the AI's."""
    import paper  # only a summary needs it: the list and the page start faster without
    return {"type": "ai", "title": title, "prompt": paper.task(language), "text": paper.numbered(items, titles)[:150000],
            "then": run_action("summarised", "News summary", {"job": job, "asked": time.time()})}


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
    asked = context.get("asked") if isinstance(context.get("asked"), (int, float)) else time.time()
    seconds = max(0.0, time.time() - asked)
    state = load(data, SUMMARY)
    if state.get("job") == job and state.get("status") == "done":  # Ask again's twin answer: one paper a press
        return hud("That news summary is made already")
    saved = load(os.path.join(data, "jobs"), job + ".json") if job.isalnum() else {}
    items = [i for i in saved.get("items") or [] if isinstance(i, dict)]
    if not items:
        return hud("That news summary's headlines are gone; press Summarise again")
    if context.get("error"):
        if state.get("job") == job:
            save(data, SUMMARY, dict(state, status="failed", error=str(context["error"])[:200], at=time.time()))
        return hud("News summary failed: %s" % str(context["error"])[:160])
    import paper
    answer = (run.get("input") or "").strip()
    sources = Sources(run)
    titles, groups = sources.titles(), sources.groups()
    # Who wrote it: the fallback's notice when it took over, else the AI Pilot names (`answeredBy`, Pilot from 2026-11-22),
    # else, from an older Pilot, its AI unnamed.
    by = str(context.get("notice") or context.get("answeredBy") or "Pilot's AI")
    layout = paper.layout(answer, len(items)) or paper.fallback(answer, items, titles, groups)
    html = paper.page(layout, items, titles, {"day": time.time(), "seconds": seconds, "by": by})
    folder = save_in(run)
    try:
        os.makedirs(folder, exist_ok=True)
        path = unique(folder, time.strftime("%Y-%m-%d"))
        with open(path, "w", encoding="utf-8") as f:
            f.write(html)
    except OSError as e:
        save(data, SUMMARY, dict(state, status="failed", error="could not save it (%s)" % e.strerror, at=time.time()))
        return hud("News summary could not be saved: %s" % e.strerror)
    save(data, SUMMARY, {"status": "done", "job": job, "at": time.time(), "seconds": seconds,
                         "by": by, "count": len(items), "path": path})
    hud("News summary ready in %d s · %s" % (round(seconds), by), {"type": "open", "url": path})


def refresh_now(run):
    data, cache = folders(run)
    on = Sources(run).on()
    if not on:
        return hud(TICK_FIRST)
    record, _ = headlines(cache, on, budget=REFRESH_TIME + 2, force=True)
    failed = [s for s in on if (record.get("sources") or {}).get(s["id"], {}).get("error")]
    hud("Headlines refreshed" + (" · %d not answering" % len(failed) if failed else ""))


def moved(run):
    """Hides the page's note on 1.1.0's picks: their file kept aside, never read again."""
    data, _ = folders(run)
    try:
        os.replace(os.path.join(data, OLD_PICKS), os.path.join(data, "sources-1.1.json"))
    except OSError:
        pass
    hud("Your sources are in News' Settings")


def moved_note(data, sources):
    """While 1.1.0's picks file is there: where picking went, and his old feeds to paste."""
    if not os.path.exists(os.path.join(data, OLD_PICKS)):
        return []
    text = ("Sources are ticked in News' Settings now. Ticks made on this page before 1.2 did not carry over: "
            "Settings starts from its defaults.")
    old = old_feeds(data, sources)
    if old:
        text += " Your feeds from before, to paste into Your feeds: " + ", ".join(old)
    return [{"type": "note", "text": text, "icon": "info"},
            {"type": "buttons", "actions": [PICK_SOURCES, run_action("moved", "Hide this note")]}]


def headline_rows(items, titles, now, most):
    return [{"id": i["id"], "title": i["title"], "subtitle": titles.get(i["source"], i["source"]),
             "accessory": age(i["at"], now), "actions": [{"type": "open", "url": i["link"], "title": "Open"}]}
            for i in items[:most]]


def none_yet(on, running):
    if not on:
        return "_%s: tick them in News' Settings._" % NO_SOURCES
    return "_Fetching headlines…_" if running else "_No headlines from the ticked sources yet._"


class View:
    """What the page and the bar item show: the ticked sources, their kept headlines (a stale cache starts a refresh,
    never waited for) and the summary's state and buttons."""

    def __init__(self, run):
        self.data, cache = folders(run)
        self.sources = Sources(run)
        self.on = self.sources.on()
        self.record, self.running = headlines(cache, self.on)
        self.items = picked_items(self.record, self.on)
        self.state = summary_state(self.data)
        self.waiting = self.state.get("status") in ("fetching", "working")
        self.now = time.time()
        self.buttons, self.again = summary_buttons(run, self.data, self.state, self.sources, self.on)

    def rows(self, most):
        return headline_rows(self.items, self.sources.titles(), self.now, most)

    def note(self):
        line = summary_line(self.state)
        return [{"type": "note", "text": line, "icon": "info"}] if line else []

    def answer(self, blocks):
        """A blocks answer, asked again at a calmer pace while Ask again (which carries the job's text) shows, else soon
        while a summary or a refresh is on its way."""
        answer = {"type": "blocks", "blocks": blocks}
        if self.again:
            answer["refresh"] = 10
        elif self.waiting or self.running:
            answer["refresh"] = 2
        return answer


def page(run):
    """The page: the summary's buttons and its last one, the headlines, and the ticked sources not answering."""
    view = View(run)
    status = view.record.get("sources") or {}
    buttons = view.buttons + ([run_action("refresh", "Refresh", icon="refresh"), PICK_SOURCES] if view.on else [])
    blocks = [{"type": "section", "title": "News", "subtitle": "%d headlines in the last 24 hours from %d sources" % (
        len(last_day(view.items, view.now)), len(view.on)),
        "aside": "Refreshing…" if view.running else "Read %s" % clock(view.record.get("fetchedAt")),
        "blocks": [{"type": "buttons", "actions": buttons}] + view.note() + moved_note(view.data, view.sources)}]
    failing = [s for s in view.on if (status.get(s["id"]) or {}).get("error")]
    if failing:
        blocks.append({"type": "list", "title": "Not answering", "items": [
            {"id": "x-" + s["id"], "title": s["title"], "subtitle": status[s["id"]]["error"],
             "badges": [{"text": "Kept %d" % status[s["id"]].get("count", 0), "tone": "warn"}],
             "actions": [{"type": "open", "url": s["url"], "title": "Open the feed"}]} for s in failing]})
    rows = view.rows(PAGE_ROWS)
    blocks.append({"type": "list", "title": "Headlines", "items": rows} if rows else
                  {"type": "markdown", "text": none_yet(view.on, view.running)})
    send(view.answer(blocks))


def clipped(text, most=LONGEST):
    return text if len(text) <= most else text[:most - 1].rstrip() + "…"


def short_source(title):
    """A source's name as a popover row shows it: before any bracket ("TVM News (English)" is TVM News), held short."""
    return clipped(title.split(" (")[0], SOURCE_ROOM)


def bar_rows(items, titles, now, most):
    """Popover rows on one line each (Sven on build 3160, "the menu bar can look better"): the headline held to
    TITLE_ROOM, so its source (dimmed) and its age keep their room in the 340-point popover; the whole title on hover."""
    return [{"id": i["id"], "title": clipped(i["title"], TITLE_ROOM), "subtitle": short_source(titles.get(i["source"], i["source"])),
             "accessory": age(i["at"], now), "actions": [{"type": "open", "url": i["link"], "title": i["title"][:200]}]}
            for i in items[:most]]


def group_counts(view):
    """Each group he ticks a source in, in Settings' order, with its headlines of the last 24 hours."""
    groups, recent = view.sources.groups(), last_day(view.items, view.now)
    order = []
    for s in view.on:
        if s["group"] not in order:
            order.append(s["group"])
    return [(g, sum(1 for i in recent if groups.get(i["source"]) == g)) for g in order]


def count_links(view):
    """The popover's first rows: World 8 · Tech 12 · Malta 20, each opening that group's headlines in the popover (a push
    to the hidden group command), at most GROUPS_PER_ROW to a row, so a row never passes the popover's edge."""
    links = [{"title": g, "word": str(n), "help": "%s: %d headline%s in the last 24 hours" % (g, n, "" if n == 1 else "s"),
              "actions": [{"type": "push", "command": "group", "title": g, "context": {"group": g}}]}
             for g, n in group_counts(view)]
    return [{"type": "links", "items": links[i:i + GROUPS_PER_ROW]} for i in range(0, len(links), GROUPS_PER_ROW)]


def summary_links(view):
    """The summary's buttons as the popover's last links row, which Pilot draws beside Open page: short words, the whole
    one on hover."""
    words = {"Summarise the last 24 hours": "Summarise", "Open the last summary": "Last summary"}
    return {"type": "links", "items": [{"title": words.get(a["title"], a["title"]), "help": a["title"], "actions": [a]}
                                       for a in view.buttons]}


def new_since_opened(view, opened):
    """How many of the last 24 hours' headlines came since the popover last opened (SEEN keeps the ids it showed); an
    open counts them seen. With no record yet (the first run, or an empty cache) every one counts seen, so the item
    never starts at 60; a record is kept only once there are headlines, so a first refresh never counts as new (1.3.1)."""
    ids = [i["id"] for i in view.items]
    seen = load(view.data, SEEN)
    if opened or not isinstance(seen.get("ids"), list) or not seen["ids"]:
        if ids:
            save(view.data, SEEN, {"ids": ids, "at": view.now})
        return 0
    known = set(seen["ids"])
    return sum(1 for i in last_day(view.items, view.now) if i["id"] not in known)


def bar(run):
    """The menu-bar item and its popover (ADR 0010, surfaces v2), and Pilot's dock face (amended 2026-11-13). The item
    is 📰 and the count of headlines new since the popover last opened; the popover leads with a count per ticked group,
    then the BAR_ROWS newest headlines and the summary's links beside Pilot's Open page. Read from the cache alone: a
    stale one starts a refresh and the popover asks again in 2 s."""
    view = View(run)
    popover = run.get("surface") == "popover"
    if not view.on:
        blocks = [{"type": "markdown", "text": none_yet(view.on, view.running)}, summary_links(view)]
    else:
        rows = bar_rows(view.items, view.sources.titles(), view.now, BAR_ROWS)
        blocks = count_links(view) + [{"type": "list", "title": "Newest", "items": rows} if rows else
                                      {"type": "markdown", "text": none_yet(view.on, view.running)}] + view.note() + [summary_links(view)]
    new = new_since_opened(view, popover) if view.on else 0
    if popover:
        return send(view.answer(blocks))
    value = "Summarising…" if view.waiting else clipped(view.items[0]["title"]) if view.items else (
        NO_SOURCES if not view.on else "No headlines yet")
    send({"type": "bar", "text": "📰 %s" % ("99+" if new > 99 else new) if new else "📰", "blocks": blocks,
          "faces": [{"label": "News", "value": value, "symbol": "newspaper"}]})


def group(run):
    """A group's headlines of the last 24 hours, pushed over the popover from its count (World 8), newest first."""
    view = View(run)
    name = str((run.get("context") or {}).get("group") or "")
    groups = view.sources.groups()
    items = [i for i in last_day(view.items, view.now) if groups.get(i["source"]) == name]
    rows = bar_rows(items, view.sources.titles(), view.now, PAGE_ROWS)
    blocks = [{"type": "list", "items": rows} if rows else
              {"type": "markdown", "text": "_Nothing from %s in the last 24 hours._" % (name or "this group")}]
    if len(items) > len(rows):  # a list's most is 50: the rest are named, so the count it opened from still adds up
        blocks.append({"type": "note", "text": "%d older ones in Hyper+Space: type news" % (len(items) - len(rows)), "icon": "info"})
    send(view.answer(blocks))


COMMANDS = {"news": news, "summarise": summarise, "summarised": summarised, "refresh": refresh_now, "moved": moved,
            "page": page, "bar": bar, "group": group}


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
