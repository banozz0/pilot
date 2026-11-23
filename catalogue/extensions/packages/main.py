#!/usr/bin/env python3
"""Packages for Pilot: parcels kept on this Mac by their tracking number, a name if given, and the carrier the number's
shape names. No account and no key.

Details come from a carrier's own public tracking, the JSON its tracking web page itself asks for, where that works
without a key (checked 2026-11-23; DHL, UPS, USPS, Royal Mail and 17track answer scripts with a bot wall, a captcha or
terms that forbid it, so their details say so in one line and Return opens their page):
  MaltaPost  GET https://www.maltapost.com/TrackAndTraceApi/v1/trackedItems?barcode=<n>  (its page's Angular bundle,
             STT.constants.TrackingAPIURL + "/trackedItems?barcode="; terms silent on automated access, robots.txt
             disallows /TrackAndTraceApi/*): movements[] {date, description, location, actionDescription, reasonDescription}.
             MaltaPost tracks an item from abroad by its own number, so on a Mac set to Malta every UPU S10 number is
             asked there too.
  Cainiao    GET https://global.cainiao.com/global/detail.json?mailNos=<n>  (its page's bundle, global-track
             js/index.js; no terms of use published for global.cainiao.com): module[] {detailList[] {timeStr, desc,
             standerdDesc}}. For China Post's S10 numbers and AliExpress's LP numbers.
Both are read only when the person asks: opening a parcel's details (when what was read is older than FRESH s) or
Refresh (not within FORCE_FLOOR s of the last). Nothing runs in the background. Neither feed's delivered field is
documented, so Delivered stays the person's mark; a row shows the carrier's newest event as its status.

A read is a detached child (`main.py --read`, single under read.lock) so a view answers in its 2 s; the view that
started it waits up to WAIT s for it. The URL (it holds the number) reaches curl as a config on its stdin (`curl -K -`),
never as an argument, which `ps` shows. Nothing is logged: no number, name or event leaves stdout's protocol lines.

Stores: paths.data/parcels.json (id, number, name, added, a Delivered mark) and paths.cache/reads.json (what each
parcel's carriers said, and when), each written under store.lock, so a read landing late never brings back a removed
parcel or drops a new one. Packages 1.x's parcels (version 2, TrackingMore's ids among them) are read as they are.
"""
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from functools import lru_cache
from urllib.parse import quote, urlsplit

TRACK_ANY = "https://t.17track.net/en#nums=%s"  # 17track's page for a number; it finds the carrier
MALTAPOST = "https://www.maltapost.com/TrackAndTraceApi/v1/trackedItems?barcode=%s"
CAINIAO = "https://global.cainiao.com/global/detail.json?mailNos=%s"
FRESH = 10 * 60
FORCE_FLOOR = 30
CURL_TIMEOUT = 10
WAIT = 1.2  # a list or detail answers within 2 s
READ_BUDGET = 25  # Refresh is a no-view run, stopped at 30 s
EVENTS_SHOWN = 30
POPOVER_EVENTS = 12
FACE_LABEL, FACE_VALUE = 16, 24  # a dock face's label and value, at most
LINE = 44  # a row's carrier and status, at most: one line under its name in the popover
NAME_MOST = 40
PARCELS = "parcels.json"
READS = "reads.json"
STORE_LOCK = "store.lock"
READ_LOCK = "read.lock"
NUMBER = re.compile(r"^[A-Za-z0-9-]{5,50}$")
MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]  # whatever the Mac's language
HOW = ("Opening a parcel reads it from its carrier's own tracking (MaltaPost, Cainiao), never in the background; for "
       "other carriers Return opens their page.")


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


def fail(text):
    send({"type": "error", "text": text})


def hud(text):
    send({"type": "hud", "text": "Packages: " + text})


def context_of(run):
    return run.get("context") if isinstance(run.get("context"), dict) else {}


# ---- carriers ----

DHL_PAGE = "https://www.dhl.de/en/privatkunden/dhl-sendungsverfolgung.html?piececode=%s"
CAINIAO_PAGE = "https://global.cainiao.com/newDetail.htm?mailNoList=%s"
# Each carrier: its name, its tracking page for a number (None: 17track's) and the feeds (FEEDS) that know its numbers.
# On a Mac set to Malta, MaltaPost is asked for every S10 number too (feeds_of).
CARRIERS = {
    "ups": ("UPS", "https://www.ups.com/track?loc=en_US&tracknum=%s", ()),
    "usps": ("USPS", "https://tools.usps.com/go/TrackConfirmAction?tLabels=%s", ()),
    "dhl": ("DHL", DHL_PAGE, ()),
    "deutschepost": ("Deutsche Post", DHL_PAGE, ()),
    "maltapost": ("MaltaPost", "https://www.maltapost.com/tracking#/tracking?barcode=%s", ("maltapost",)),
    "chinapost": ("China Post", CAINIAO_PAGE, ("cainiao",)),
    "cainiao": ("Cainiao", CAINIAO_PAGE, ("cainiao",)),
    "royalmail": ("Royal Mail", None, ()),
}
# Numbers whose shape names one carrier: UPS's 1Z and 16 more (UPS's tracking support); USPS's Intelligent Mail package
# barcode, 92 to 95 and 20 more digits (USPS Publication 199); DHL Paket's 20 digits from 00340 and JJD numbers;
# AliExpress's LP numbers (Cainiao). The UPU's S10 shape (two letters, nine digits, the sending country's code) names the
# post it left from.
SHAPES = [(re.compile(r"^1Z[0-9A-Z]{16}$"), "ups"), (re.compile(r"^9[2-5]\d{20}$"), "usps"),
          (re.compile(r"^(00340\d{15}|JJD\d{10,})$"), "dhl"), (re.compile(r"^LP\d{12,16}$"), "cainiao")]
S10 = re.compile(r"^[A-Z]{2}\d{9}([A-Z]{2})$")
S10_CARRIERS = {"CN": "chinapost", "DE": "deutschepost", "GB": "royalmail", "MT": "maltapost", "US": "usps"}
POSTS = {"AU": "Australia Post", "CA": "Canada Post", "ES": "Correos", "FR": "La Poste", "HK": "Hongkong Post",
         "IT": "Poste Italiane", "JP": "Japan Post", "KR": "Korea Post", "NL": "PostNL", "SG": "Singapore Post"}


def carrier_of(number):
    """(carrier id or None, its name or "")."""
    for pattern, cid in SHAPES:
        if pattern.match(number):
            return cid, CARRIERS[cid][0]
    post = S10.match(number)
    if post:
        cid = S10_CARRIERS.get(post.group(1))
        return (cid, CARRIERS[cid][0]) if cid else (None, POSTS.get(post.group(1), "%s's post" % post.group(1)))
    return None, ""


def page_url(parcel):
    cid, _ = carrier_of(parcel["number"])
    page = CARRIERS[cid][1] if cid else None
    return (page or TRACK_ANY) % quote(parcel["number"], safe="")


def site_of(url):
    host = urlsplit(url).hostname or url
    return host[4:] if host.startswith("www.") else host


@lru_cache(maxsize=None)
def in_malta():
    """Whether this Mac's region is Malta (its AppleLocale ends _MT): then MaltaPost brings an S10 item from abroad."""
    binary = shutil.which("defaults") or "/usr/bin/defaults"
    try:
        said = subprocess.run([binary, "read", "-g", "AppleLocale"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              timeout=2).stdout.decode("utf-8", "replace").strip()
    except (OSError, subprocess.TimeoutExpired):
        said = ""
    return said.split("@")[0].endswith("_MT")


def feeds_of(number):
    """The feeds that may know `number`."""
    cid, _ = carrier_of(number)
    feeds = list(CARRIERS[cid][2]) if cid else []
    if "maltapost" not in feeds and S10.match(number) and in_malta():
        feeds.append("maltapost")
    return feeds


def readable(parcel):
    return bool(feeds_of(parcel["number"]))


def feed_names(parcel):
    return " and ".join(FEEDS[f][0] for f in feeds_of(parcel["number"]))


# ---- reading a carrier ----

def quoted(text):
    """A value for curl's config file: double quotes, with backslash and quote escaped."""
    return '"%s"' % text.replace("\\", "\\\\").replace('"', '\\"')


def get_json(url):
    """(value, why): the JSON at `url`, or None and words for the person."""
    lines = ["url = " + quoted(url), "silent", "show-error", "compressed", "max-time = %d" % CURL_TIMEOUT,
             "user-agent = " + quoted("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Pilot-Packages"),
             "header = " + quoted("Accept: application/json"), "write-out = " + quoted("\\n%{http_code}")]
    binary = shutil.which("curl") or "/usr/bin/curl"
    try:
        done = subprocess.run([binary, "-K", "-"], input=("\n".join(lines) + "\n").encode(), stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=CURL_TIMEOUT + 2)
    except (OSError, subprocess.TimeoutExpired):
        return None, "no answer"
    if done.returncode != 0:
        said = done.stderr.decode("utf-8", "replace").strip().splitlines()
        return None, re.sub(r"^curl: (\(\d+\) )?", "", said[-1] if said else "no answer")[:100]
    text, _, http = done.stdout.decode("utf-8", "replace").rpartition("\n")
    if http.strip() != "200":
        return None, "it answered %s" % (http.strip() or "nothing")
    try:
        return json.loads(text), None
    except ValueError:
        return None, "its answer was not readable"


def words(*parts):
    return " · ".join(p for p in (" ".join(str(p or "").split()) for p in parts) if p)


def an_event(at, head, text="", place=""):
    """An event as kept: its time as the carrier wrote it, its headline, the detail and where."""
    event = {"at": at.strip() if isinstance(at, str) else "", "head": words(head)[:80], "text": words(text)[:200],
             "place": words(place)[:60]}
    return event if event["head"] or event["text"] else None


def read_maltapost(number):
    value, why = get_json(MALTAPOST % quote(number, safe=""))
    if why:
        return None, why
    movements = value.get("movements") if isinstance(value, dict) else None
    if not isinstance(movements, list):
        return None, "its answer had no movements"
    return [e for e in (an_event(m.get("date"), m.get("description"), words(m.get("actionDescription"),
                                                                            m.get("reasonDescription")), m.get("location"))
                        for m in movements if isinstance(m, dict)) if e], None


def read_cainiao(number):
    value, why = get_json(CAINIAO % quote(number, safe=""))
    if why:
        return None, why
    found = value.get("module") if isinstance(value, dict) and value.get("success") else None
    if not isinstance(found, list):
        return None, "its answer had no module"
    entry = next((m for m in found if isinstance(m, dict) and m.get("mailNo") == number), found[0] if found else {})
    details = entry.get("detailList") if isinstance(entry, dict) else None
    return [e for e in (an_event(d.get("timeStr"), d.get("standerdDesc") or d.get("desc"),
                                 d.get("desc") if d.get("standerdDesc") else "")
                        for d in details or [] if isinstance(d, dict)) if e], None


FEEDS = {"maltapost": ("MaltaPost", read_maltapost), "cainiao": ("Cainiao", read_cainiao)}


def read_feed(feed, number):
    """(name, events or None, why)."""
    name, reader = FEEDS[feed]
    try:
        found, why = reader(number)
    except (AttributeError, KeyError, TypeError, ValueError):
        found, why = None, "its answer was in a shape Packages does not know"
    return name, found, why


def read_number(number):
    """Every feed's events for `number`, newest first (the feeds asked at once), why each feed that failed did, and
    whether any answered."""
    feeds = feeds_of(number)
    with ThreadPoolExecutor(max_workers=max(1, len(feeds))) as pool:
        said = list(pool.map(lambda feed: read_feed(feed, number), feeds))
    events = [dict(e, source=name) for name, found, _ in said if found is not None for e in found]
    events.sort(key=lambda e: moment(e.get("at")) or 0, reverse=True)
    return events, ["%s: %s" % (name, why) for name, _, why in said if why], any(why is None for _, _, why in said)


# ---- stores ----

def folder(run, kind):
    path = (run.get("paths") or {}).get(kind)
    if not isinstance(path, str) or not path:
        fail("Pilot sent no %s folder" % kind)
        sys.exit(0)
    os.makedirs(path, exist_ok=True)
    return path


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            value = json.load(f)
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def save(path, value):
    temp = "%s.%d.tmp" % (path, os.getpid())
    with open(temp, "w", encoding="utf-8") as f:
        json.dump(value, f, ensure_ascii=False)
    os.replace(temp, path)


def parcel_of(value):
    """A parcel as stored, Packages 1.x's too: an id and a number; the rest it had (a carrier code, `local`) dropped."""
    if not (isinstance(value, dict) and all(isinstance(value.get(k), str) and value[k] for k in ("id", "number"))):
        return None
    parcel = {"id": value["id"], "number": value["number"],
              "name": value["name"] if isinstance(value.get("name"), str) else "",
              "added": value["added"] if isinstance(value.get("added"), (int, float)) else 0}
    if isinstance(value.get("delivered"), (int, float)) and value["delivered"]:
        parcel["delivered"] = value["delivered"]
    return parcel


class Store:
    """The parcel list and what each carrier last said, read together; `with store:` holds store.lock, reads both
    again and writes them back at its end."""

    def __init__(self, data, cache):
        self.data, self.cache = data, cache
        self.lock = None
        self.read()

    @classmethod
    def of(cls, run):
        return cls(folder(run, "data"), folder(run, "cache"))

    def read(self):
        raw = load(os.path.join(self.data, PARCELS)).get("parcels")
        self.parcels = [p for p in map(parcel_of, raw if isinstance(raw, list) else []) if p]
        self.reads = load(os.path.join(self.cache, READS))
        if not isinstance(self.reads.get("byId"), dict):
            self.reads["byId"] = {}

    def __enter__(self):
        self.lock = open(os.path.join(self.cache, STORE_LOCK), "a")
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        self.read()
        return self

    def __exit__(self, kind, value, trace):
        try:
            if kind is None:
                ids = {p["id"] for p in self.parcels}
                self.reads["byId"] = {k: v for k, v in self.reads["byId"].items() if k in ids}
                save(os.path.join(self.data, PARCELS), {"version": 3, "parcels": self.parcels})
                save(os.path.join(self.cache, READS), self.reads)
                old = os.path.join(self.cache, "status.json")  # Packages 1.x's TrackingMore answers
                if os.path.exists(old):
                    os.remove(old)
        finally:
            self.lock.close()
        return False

    def got(self, parcel):
        entry = self.reads["byId"].get(parcel["id"])
        return entry if isinstance(entry, dict) else {}

    def find(self, parcel_id):
        return next((p for p in self.parcels if p["id"] == parcel_id), None)


# ---- the reads ----

def locked(f):
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False


def reading(cache):
    try:
        with open(os.path.join(cache, READ_LOCK), "a") as f:
            return not locked(f)
    except OSError:
        return False


def read_parcel(store, parcel_id):
    """Reads a parcel from its feeds and keeps what they said, or why they failed; a failed read keeps what was read
    before. Holds no lock while it waits on a carrier."""
    parcel = store.find(parcel_id)
    if not parcel:
        return
    events, problems, answered = read_number(parcel["number"])
    with store:
        if store.find(parcel_id):
            now = time.time()
            entry = dict(store.got(parcel), triedAt=now, error="; ".join(problems) or None)
            if answered:
                entry.update(events=events, readAt=now)
            store.reads["byId"][parcel_id] = entry


def start_read(store, parcel_id):
    """A detached `main.py --read` holding the read lock from before it starts; None when one runs already."""
    try:
        lock = open(os.path.join(store.cache, READ_LOCK), "a")
    except OSError:
        return None
    with lock:
        if not locked(lock):
            return None
        try:
            child = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--read"], stdin=subprocess.PIPE,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, pass_fds=(lock.fileno(),),
                                     start_new_session=True, cwd=os.path.dirname(os.path.abspath(__file__)))
            child.stdin.write(json.dumps({"data": store.data, "cache": store.cache, "id": parcel_id}).encode())
            child.stdin.close()
        except OSError:
            return None
    return child


def read_main():
    job = json.loads(sys.stdin.read())
    read_parcel(Store(job["data"], job["cache"]), job["id"])


def stale(store, parcel, older, now):
    return readable(parcel) and now - (store.got(parcel).get("triedAt") or 0) >= older


def look_at(run):
    """The store and the context's parcel, read first when what was read is older than FRESH s, waiting up to WAIT s;
    (store, parcel, still reading)."""
    store = Store.of(run)
    parcel = store.find(context_of(run).get("id"))
    if parcel and stale(store, parcel, FRESH, time.time()):
        child = start_read(store, parcel["id"])
        if child:
            try:
                child.wait(timeout=WAIT)
            except subprocess.TimeoutExpired:
                pass
        else:  # another run's read: wait for its lock
            started = time.monotonic()
            while time.monotonic() - started < WAIT and reading(store.cache):
                time.sleep(0.05)
        store.read()
        parcel = store.find(parcel["id"])
    return store, parcel, reading(store.cache)


# ---- words ----

def moment(text):
    """Seconds since 1970 for an ISO 8601 time or "YYYY-MM-DD HH:MM:SS" (a time without a zone read as this Mac's);
    None when it does not read."""
    if not isinstance(text, str) or not text.strip():
        return None
    text = text.strip().replace(" ", "T", 1)
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    for candidate in (text, text[:19], text[:10]):
        try:
            return datetime.fromisoformat(candidate).timestamp()
        except ValueError:
            pass
    return None


def age(seconds, now):
    if not seconds:
        return ""
    gone = max(0, now - seconds)
    if gone < 60:
        return "now"
    if gone < 3600:
        return "%dm" % (gone // 60)
    if gone < 86400:
        return "%dh" % (gone // 3600)
    if gone < 14 * 86400:
        return "%dd" % (gone // 86400)
    return "%dw" % (gone // (7 * 86400))


def ago(seconds, now):
    said = age(seconds, now)
    return "just now" if said == "now" else (said + " ago" if said else "never")


def clock(text):
    """Nov 22, 07:19, or the carrier's own words when they do not read as a time."""
    seconds = moment(text)
    if seconds is None:
        return fit(text or "", 18)
    t = time.localtime(seconds)
    day = "%s %d" % (MONTHS[t.tm_mon - 1], t.tm_mday)
    return day if len(text.strip()) <= 10 else "%s, %02d:%02d" % (day, t.tm_hour, t.tm_min)


def fit(text, most):
    text = " ".join(str(text).split())
    return text if len(text) <= most else text[:most - 1].rstrip() + "…"


def title(parcel):
    return parcel.get("name") or parcel["number"]


def latest(got):
    events = got.get("events") or []
    return events[0] if events else None


def status_of(parcel, got):
    """Its status in words: Delivered (the person's mark), the carrier's newest event, or On the way."""
    if parcel.get("delivered"):
        return "Delivered"
    event = latest(got)
    return (event.get("head") or event.get("text")) if event else "On the way"


def short(parcel, status):
    """A row's one line: its carrier and its status, short."""
    return fit(words(carrier_of(parcel["number"])[1], status), LINE)


def bullet(event):
    """An event as a Markdown list line: when, what, the detail and where."""
    return "- **%s** · %s" % (clock(event.get("at")) or "–", words(
        event.get("head"), event.get("text") if event.get("text") != event.get("head") else "", event.get("place")))


def no_feed(parcel):
    return "%s has no tracking Packages may read" % (carrier_of(parcel["number"])[1] or "its carrier")


# ---- actions ----

def staying(action, stay):
    return dict(action, stay=True) if stay else action


def details_action(parcel, view):
    """Its details: the detail view in Hyper+Space, blocks pushed over the popover or the page."""
    return {"type": "push", "title": "Show details", "command": "parcel" if view == "list" else "details",
            "context": {"id": parcel["id"]}}


def open_action(parcel):
    url = page_url(parcel)
    return {"type": "open", "title": "Open on %s" % site_of(url), "url": url}


def rename_action(parcel, stay):
    return staying({"type": "run", "title": "Rename…", "command": "rename", "context": {"id": parcel["id"]},
                    "key": "cmd+e", "ask": {"text": parcel.get("name") or ""}}, stay)


def remove_action(parcel, stay):
    return staying({"type": "run", "title": "Remove", "command": "remove", "context": {"id": parcel["id"]},
                    "destructive": True, "key": "cmd+delete",
                    "ask": {"confirm": "Remove %s from Packages?" % title(parcel)}}, stay)


def mark_action(parcel, stay):
    marked = bool(parcel.get("delivered"))
    return staying({"type": "run", "title": "Mark on the way" if marked else "Mark delivered", "command": "mark",
                    "context": {"id": parcel["id"], "delivered": not marked}}, stay)


def refresh_action(parcel, stay):
    return staying({"type": "run", "title": "Refresh", "command": "refresh", "key": "cmd+r",
                    "context": {"id": parcel["id"]}}, stay)


def parcel_actions(parcel, view):
    """Every action of a parcel; `view` is "list" (Hyper+Space), "blocks" (popover and page) or "detail". Return shows
    the details of a parcel Packages can read, else opens its tracking page."""
    stay = view != "blocks"
    if view == "detail":
        actions = [open_action(parcel)]
    elif readable(parcel):
        actions = [details_action(parcel, view), dict(open_action(parcel), key="cmd+o")]
    else:
        actions = [open_action(parcel), details_action(parcel, view)]
    if readable(parcel):
        actions.append(refresh_action(parcel, stay))
    return actions + [{"type": "copy", "title": "Copy tracking number", "text": parcel["number"], "key": "cmd+shift+c"},
                      rename_action(parcel, stay), mark_action(parcel, stay), remove_action(parcel, stay)]


def keywords(parcel, status):
    return " ".join([parcel["number"], carrier_of(parcel["number"])[1], status])


def row(parcel, got, now, view, aged=True):
    """A parcel's row; `aged` adds how long ago its newest event (else its adding) was."""
    status = status_of(parcel, got)
    item = {"id": parcel["id"], "title": title(parcel), "subtitle": short(parcel, status),
            "icon": "✅" if parcel.get("delivered") else "📦", "keywords": keywords(parcel, status),
            "actions": parcel_actions(parcel, view)}
    event = latest(got)
    when = age((moment(event.get("at")) if event else None) or parcel.get("added"), now) if aged else ""
    if when:
        item["accessory"] = when
    return item


def split_input(text):
    """(number, name) from "<number> [a name]"; number None when the first word is no tracking number."""
    parts = str(text or "").split(None, 1)
    number = parts[0].upper() if parts and NUMBER.match(parts[0]) and re.search(r"\d", parts[0]) else None
    name = words(parts[1])[:NAME_MOST] if len(parts) > 1 else ""
    return number, name


def grouped(store):
    """(on the way, delivered), newest first."""
    on_way, done = [], []
    for p in sorted(store.parcels, key=lambda p: -(p.get("added") or 0)):
        (done if p.get("delivered") else on_way).append(p)
    return on_way, done


def edited(run, change):
    """Changes the context's parcel under the store's lock; the parcel, or None (said) when it is gone."""
    with Store.of(run) as store:
        parcel = store.find(context_of(run).get("id"))
        if parcel:
            change(store, parcel)
    if not parcel:
        hud("not kept any more")
    return parcel


# ---- commands ----

def list_command(run):
    store = Store.of(run)
    now = time.time()
    query = words(run.get("query"))
    items = []
    number, name = split_input(query)
    if number and not any(p["number"] == number for p in store.parcels):
        items.append({"title": "Add %s" % number, "subtitle": words("as " + name if name else "", carrier_of(number)[1]),
                      "icon": "➕", "actions": [{"type": "run", "title": "Add", "command": "add", "clear": True,
                                                "context": {"number": number, "name": name}}]})
    on_way, done = grouped(store)
    needle = "" if number else query.lower()
    for section, parcels in (("On the way", on_way), ("Delivered", done)):
        for p in parcels:
            if needle and needle not in (title(p) + " " + keywords(p, status_of(p, store.got(p)))).lower():
                continue
            items.append(dict(row(p, store.got(p), now, "list"), section=section))
    if not store.parcels and not number:
        items.append({"title": "No parcels yet", "icon": "📦",
                      "subtitle": "Type a tracking number, then a name if you like, and press Return"})
    send({"type": "list", "items": items})


def add(run):
    context = context_of(run)
    store = Store.of(run)
    if context.get("number"):
        number, name = split_input(context.get("number"))
        name = words(context.get("name"))[:NAME_MOST] or name
    else:
        number, name = split_input(run.get("input"))
    if not number:
        fail("type a tracking number first, then a name if you like")
        return
    have = next((p for p in store.parcels if p["number"] == number), None)
    if have:
        hud("already keeping %s" % title(have))
        return
    parcel = {"id": "p-" + os.urandom(8).hex(), "number": number, "name": name, "added": time.time()}
    with store:
        store.parcels.append(parcel)
    hud(words("added " + title(parcel), carrier_of(number)[1]))


def rename(run):
    name = words(run.get("input"))[:NAME_MOST]
    if edited(run, lambda store, parcel: parcel.update(name=name)):
        hud("renamed %s" % name if name else "it shows its number")


def remove(run):
    def drop(store, parcel):
        store.parcels.remove(parcel)
    parcel = edited(run, drop)
    if parcel:
        hud("removed %s" % title(parcel))


def mark(run):
    marked = context_of(run).get("delivered") is not False

    def change(store, parcel):
        if marked:
            parcel["delivered"] = time.time()
        else:
            parcel.pop("delivered", None)
    parcel = edited(run, change)
    if parcel:
        hud("%s %s" % (title(parcel), "marked delivered" if marked else "back on the way"))


def refresh(run):
    """Reads the context's parcel from its feeds now, not within FORCE_FLOOR s of its last read."""
    store = Store.of(run)
    parcel = store.find(context_of(run).get("id"))
    if not parcel:
        hud("not kept any more")
        return
    if not readable(parcel):
        hud(no_feed(parcel) + ": open its page")
        return
    with open(os.path.join(store.cache, READ_LOCK), "a") as lock:
        started = time.monotonic()
        while not locked(lock):  # a read runs: wait for it, then read again only if it is still due
            if time.monotonic() - started > READ_BUDGET:
                fail("could not refresh: a read did not end in time")
                return
            time.sleep(0.1)
        store.read()
        if stale(store, parcel, FORCE_FLOOR, time.time()):
            read_parcel(store, parcel["id"])
    got = store.got(parcel)
    if got.get("error") and not got.get("events"):
        fail("could not read it: %s" % got["error"])
        return
    hud(words(title(parcel), status_of(parcel, got)))


def explained(parcel, got, still):
    """Why there are no events to show, in one line; None when there are."""
    if not readable(parcel):
        said = no_feed(parcel)
        return "%s%s: Return opens %s." % (said[0].upper(), said[1:], site_of(page_url(parcel)))
    if got.get("events"):
        return None
    if still or not got.get("triedAt"):
        return "Reading %s…" % feed_names(parcel)
    if got.get("error"):
        return "Could not read it: %s." % got["error"]
    return "%s has no events for it yet." % feed_names(parcel)


def read_words(parcel, got, still, now, source=True):
    if still:
        return "reading…"
    if not got.get("readAt"):
        return ""
    return "read " + ago(got.get("readAt"), now) + (" from " + feed_names(parcel) if source else "")


def parcel_detail(run):
    """Hyper+Space's detail view of a parcel, read first when what was read is older than FRESH s."""
    store, parcel, still = look_at(run)
    if not parcel:
        send({"type": "detail", "markdown": "## Not kept any more\n\nThis parcel was removed from Packages.",
              "metadata": [], "actions": []})
        return
    got, now = store.got(parcel), time.time()
    lines = ["## %s" % title(parcel), "", "**%s**" % status_of(parcel, got), ""]
    lines += [bullet(e) for e in (got.get("events") or [])[:EVENTS_SHOWN]]
    why = explained(parcel, got, still)
    if why:
        lines.append(why + (" Refresh (⌘R) shows it in a moment." if still else ""))
    _, name = carrier_of(parcel["number"])
    metadata = [{"label": "Number", "text": parcel["number"]}]
    if name:
        metadata.append({"label": "Carrier", "text": name})
    metadata.append({"label": "Added", "text": ago(parcel.get("added"), now)})
    read = read_words(parcel, got, still, now)
    if read:
        metadata.append({"label": "Read", "text": read})
    send({"type": "detail", "markdown": "\n".join(lines), "metadata": metadata,
          "actions": parcel_actions(parcel, "detail")})


def details(run):
    """A parcel's details as blocks, pushed over the popover or the page; asked again every 2 s while a read runs."""
    store, parcel, still = look_at(run)
    if not parcel:
        send({"type": "blocks", "blocks": [{"type": "markdown", "text": "This parcel was removed from Packages."}]})
        return
    got, now = store.got(parcel), time.time()
    _, name = carrier_of(parcel["number"])
    blocks = [{"type": "note", "icon": "info", "text": fit(status_of(parcel, got), LINE)},
              {"type": "note", "icon": "tag", "text": words(parcel["number"], name)}]
    read = read_words(parcel, got, still, now, source=False)
    if read:
        blocks[0]["aside"] = read
    events = (got.get("events") or [])[:POPOVER_EVENTS]
    if events:  # Markdown, which wraps: a list row at 340 pt cuts an event's words
        blocks.append({"type": "markdown", "text": "\n".join(map(bullet, events))})
    why = explained(parcel, got, still)
    if why:
        blocks.append({"type": "markdown", "text": why})
    buttons = [dict(open_action(parcel), title="Tracking page")]
    if readable(parcel):
        buttons.append(refresh_action(parcel, True))
    blocks.append({"type": "buttons", "actions": buttons})
    answer = {"type": "blocks", "blocks": blocks}
    if still:
        answer["refresh"] = 2
    send(answer)


def view_blocks(store, popover):
    """The page's blocks, and the menu bar item's popover's: an add field, the parcels one short line each."""
    now = time.time()
    blocks = [{"type": "input", "placeholder": "Tracking number, then a name",
               "action": {"type": "run", "title": "Add", "command": "add"}}]
    on_way, done = grouped(store)
    for heading, parcels in (("On the way", on_way), ("Delivered", done)):
        if not parcels:
            continue
        items = []
        for p in parcels:
            item = row(p, store.got(p), now, "blocks", aged=not popover)  # in the popover its age takes its line's room
            # Its mark as a button: a popover row with one draws its carrier and status under its name, so neither is
            # cut at the popover's 340 pt; the page has room for rename and remove too.
            item["inline"] = [dict(mark_action(p, False), icon="reset" if p.get("delivered") else "checkmark.circle")]
            if not popover:
                item["inline"] += [dict(rename_action(p, False), icon="pencil"), dict(remove_action(p, False), icon="xmark")]
            items.append(item)
        blocks.append({"type": "list", "title": heading, "items": items})
    if not store.parcels:
        blocks.append({"type": "markdown", "text": "No parcels yet."})
    if not popover:
        blocks.append({"type": "note", "icon": "info", "text": HOW})
    return blocks


def page(run):
    send({"type": "blocks", "blocks": view_blocks(Store.of(run), popover=False)})


def bar(run):
    """The menu bar item: 📦 and how many are on their way; its Dock faces say the same, with the newest event read.
    Clicked, the add field and the parcels. It reads nothing."""
    store = Store.of(run)
    if run.get("surface") == "popover":
        send({"type": "blocks", "blocks": view_blocks(store, popover=True)})
        return
    on_way, _ = grouped(store)
    count = len(on_way)
    faces = [{"label": "Parcels", "value": "%d on the way" % count if count else "None on the way", "symbol": "shippingbox"}]
    newest = [(moment(latest(store.got(p)).get("at")) or 0, p) for p in on_way if latest(store.got(p))]
    if newest:
        lead = max(newest, key=lambda pair: pair[0])[1]
        faces.append({"label": fit(title(lead), FACE_LABEL), "value": fit(status_of(lead, store.got(lead)), FACE_VALUE),
                      "symbol": "truck.box"})
    send({"type": "bar", "text": "📦 %d" % count if count else "📦", "faces": faces,
          "blocks": view_blocks(store, popover=True)})


COMMANDS = {"packages": list_command, "page": page, "bar": bar, "add": add, "parcel": parcel_detail, "details": details,
            "rename": rename, "remove": remove, "mark": mark, "refresh": refresh}


def main():
    if sys.argv[1:] == ["--read"]:
        read_main()
        return
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        fail("got a run message it could not read")
        return
    command = run.get("command")
    if command not in COMMANDS:
        fail("has no command %s" % command)
        return
    COMMANDS[command](run)


if __name__ == "__main__":
    main()
