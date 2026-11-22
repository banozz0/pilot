#!/usr/bin/env python3
"""Packages for Pilot: parcels tracked through TrackingMore (trackingmore.com) with the person's own API key, the
`apiKey` password preference (Pilot keeps it in the Keychain and hands it over in each run message). Without a key every
view says how to get one and nothing else runs: one gate in main() answers for every command but the carrier pick.

TrackingMore's v4 API (https://api.trackingmore.com/v4, header Tracking-Api-Key): POST couriers/detect names the carrier
of a number, POST trackings/create starts tracking it (one credit for each new number and carrier; reading it again
costs none), GET trackings/get?tracking_numbers=… (40 at most) reads the latest, DELETE trackings/delete/{id} stops it.
Errors come back as HTTP 4xx with the envelope's meta.code in the body (4101 already exists, 4190 out of credits, 401 the
key refused, 429 too fast), so curl runs without --fail and the body decides.

The key, the URL (its query holds tracking numbers) and the body reach curl as a config on its stdin (`curl -K -`),
never as arguments, which `ps` shows. Nothing is logged: no number, name, event or key leaves stdout's protocol lines.

Refresh: a view (the list, a parcel, the page) shows what was read last at once and, when that is older than FRESH s
(NEW_FRESH s while a parcel added in the last hour has no event yet), starts one detached child (`main.py --refresh`,
single under refresh.lock) that reads every parcel still on its way in one call per 40 numbers. Delivered parcels and
ones TrackingMore stopped updating are never asked again. Nothing polls in the background: no bar item, no timer; the
page asks only while it shows, and still within FRESH. Refresh (⌘R) forces one, not within FORCE_FLOOR s of the last.

Stores: paths.data/parcels.json (the list: id, number, carrier, name, added) and paths.cache/status.json (what
TrackingMore said for each id, and when), each written under store.lock, so a refresh landing late never brings back a
removed parcel or drops a new one.
"""
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime
from urllib.parse import urlencode

API = "https://api.trackingmore.com/v4"
SIGNUP = "https://www.trackingmore.com/signup.html"
KEY_HELP = "https://www.trackingmore.com/docs/trackingmore/zte58cee4mz0v-api-authentication"
FRESH = 15 * 60
NEW_FRESH = 2 * 60
NEW_FOR = 60 * 60
FORCE_FLOOR = 60
RETRY = 60
CURL_TIMEOUT = 10
REFRESH_BUDGET = 25  # Refresh is a no-view run, stopped at 30 s
BATCH = 40  # trackings/get takes 40 numbers at most
MOST_CARRIERS = 8  # a run's ask lists 8 choices at most; the pick list keeps to the same
EVENTS_SHOWN = 40
PARCELS = "parcels.json"
STATUS = "status.json"
STORE_LOCK = "store.lock"
REFRESH_LOCK = "refresh.lock"
KEY = re.compile(r"^[A-Za-z0-9_-]{8,128}$")
NUMBER = re.compile(r"^[A-Za-z0-9-]{5,50}$")
GONE = {404, 4102, 4112}  # TrackingMore has no such tracking: removing it is done
# TrackingMore's delivery statuses (docs: Courier Delivery Status): words, emoji, tone.
STATUSES = {"pending": ("Pending", "⏳", None), "notfound": ("Not found yet", "⏳", None),
            "inforeceived": ("Label created", "🏷\ufe0f", None), "transit": ("In transit", "🚚", None),
            "pickup": ("Out for delivery", "🛵", "fine"), "undelivered": ("Delivery failed", "⚠\ufe0f", "warn"),
            "delivered": ("Delivered", "✅", "fine"), "exception": ("Problem", "❗", "alert"),
            "expired": ("No news for 30 days", "💤", "warn")}
MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]  # whatever the Mac's language
NO_KEY_TITLE = "Add your TrackingMore API key"
NO_KEY = ("Packages needs your own TrackingMore API key. Make a TrackingMore account (%s), open Developer › API Key, "
          "click Generate API key, copy it, and paste it in Packages' settings (Extensions › Packages). Each new parcel "
          "uses one TrackingMore credit; refreshing it uses none." % SIGNUP)
NO_KEY_MARKDOWN = "## %s\n\n%s" % (NO_KEY_TITLE, NO_KEY)
NO_KEY_ACTIONS = [{"type": "open", "title": "Open TrackingMore's sign-up page", "url": SIGNUP},
                  {"type": "open", "title": "How to make an API key", "url": KEY_HELP}]
NO_KEY_ERROR = "Packages needs your TrackingMore API key: add it in Packages' settings (sign up at trackingmore.com)"
BAD_KEY = "that TrackingMore API key does not look right: check it in Packages' settings"


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


def fail(text):
    send({"type": "error", "text": text})


def context_of(run):
    return run.get("context") if isinstance(run.get("context"), dict) else {}


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


class Store:
    """The parcel list and what TrackingMore last said, read together; `with store:` holds store.lock, reads both again
    and writes them back at its end."""

    def __init__(self, data, cache):
        self.data, self.cache = data, cache
        self.lock = None
        self.read()

    @classmethod
    def of(cls, run):
        return cls(folder(run, "data"), folder(run, "cache"))

    def read(self):
        raw = load(os.path.join(self.data, PARCELS)).get("parcels")
        self.parcels = [p for p in raw if parcel_of(p)] if isinstance(raw, list) else []
        self.status = load(os.path.join(self.cache, STATUS))
        if not isinstance(self.status.get("byId"), dict):
            self.status["byId"] = {}

    def __enter__(self):
        self.lock = open(os.path.join(self.cache, STORE_LOCK), "a")
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        self.read()
        return self

    def __exit__(self, kind, value, trace):
        try:
            if kind is None:
                ids = {p["id"] for p in self.parcels}
                self.status["byId"] = {k: v for k, v in self.status["byId"].items() if k in ids}
                save(os.path.join(self.data, PARCELS), {"version": 1, "parcels": self.parcels})
                save(os.path.join(self.cache, STATUS), self.status)
        finally:
            self.lock.close()
        return False

    def tracking(self, parcel):
        entry = self.status["byId"].get(parcel["id"])
        return entry if isinstance(entry, dict) else {}

    def find(self, parcel_id):
        return next((p for p in self.parcels if p["id"] == parcel_id), None)

    def active(self):
        """The parcels still worth asking about: not delivered, and still updated by TrackingMore."""
        return [p for p in self.parcels if state(self.tracking(p)) == "active"]

    def read_at(self):
        """When the stalest parcel on its way was last read (an add reads its own), 0 for one never read; with none on
        its way, the last refresh."""
        active = self.active()
        if not active:
            return self.status.get("refreshedAt") or 0
        return min(self.tracking(p).get("fetchedAt") or 0 for p in active)


def parcel_of(value):
    return (isinstance(value, dict) and all(isinstance(value.get(k), str) and value[k] for k in ("id", "number", "courier"))
            and isinstance(value.get("added", 0), (int, float)))


def state(tracking):
    """"delivered", "stopped" (TrackingMore no longer updates it) or "active"; only an active parcel is asked again."""
    if tracking.get("delivery_status") == "delivered":
        return "delivered"
    return "stopped" if tracking.get("updating") is False else "active"


# ---- TrackingMore ----

def api_key(run):
    """(key, None), (None, None) when none is set, or (None, why) for one that cannot be sent."""
    key = str((run.get("preferences") or {}).get("apiKey") or "").strip()
    if not key:
        return None, None
    return (key, None) if KEY.match(key) else (None, BAD_KEY)


def quoted(text):
    """A value for curl's config file: double quotes, with backslash and quote escaped."""
    return '"%s"' % text.replace("\\", "\\\\").replace('"', '\\"')


def call(key, method, path, query=None, body=None):
    """(meta code, data, why): TrackingMore's answer; code 200 with its data, or another code (or 0: no answer) with
    words for the person."""
    url = "%s/%s" % (API, path) + ("?" + urlencode(query) if query else "")
    lines = ["url = " + quoted(url), "request = " + quoted(method), "silent", "show-error",
             "max-time = %d" % CURL_TIMEOUT, "header = " + quoted("Tracking-Api-Key: " + key),
             "header = " + quoted("Accept: application/json"), "header = " + quoted("Content-Type: application/json"),
             "write-out = " + quoted("\\n%{http_code}")]
    if body is not None:
        lines.append("data-binary = " + quoted(json.dumps(body)))
    binary = shutil.which("curl") or "/usr/bin/curl"
    try:
        done = subprocess.run([binary, "-K", "-"], input=("\n".join(lines) + "\n").encode(), stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=CURL_TIMEOUT + 2)
    except (OSError, subprocess.TimeoutExpired):
        return 0, None, "could not reach TrackingMore"
    if done.returncode != 0:
        said = done.stderr.decode("utf-8", "replace").strip().splitlines()
        return 0, None, "could not reach TrackingMore (%s)" % (said[-1] if said else "no answer").replace("curl: ", "")[:120]
    text, _, http = done.stdout.decode("utf-8", "replace").rpartition("\n")
    try:
        answer = json.loads(text)
    except ValueError:
        answer = None
    meta = answer.get("meta") if isinstance(answer, dict) else None
    code = meta.get("code") if isinstance(meta, dict) else None
    if not isinstance(code, int) or isinstance(code, bool):
        code = int(http) if http.strip().isdigit() else 0
    if code == 200:
        return 200, answer.get("data") if isinstance(answer, dict) else None, None
    message = meta.get("message") if isinstance(meta, dict) and isinstance(meta.get("message"), str) else ""
    return code, None, words(code, message)


def words(code, message):
    if code in (401, 403):
        return "TrackingMore refused the API key: check it in Packages' settings"
    if code == 429:
        return "TrackingMore asked to slow down: try again in a minute"
    if code == 4190:
        return "your TrackingMore plan has no credits left this month: a new parcel waits for next month or a bigger plan"
    if code in (4110, 4111):
        return "TrackingMore says this is not a tracking number"
    if code == 4120:
        return "TrackingMore does not know that carrier"
    if code == 4121:
        return "TrackingMore could not tell the carrier from this number: check it and try again"
    if code == 4122:
        return "this carrier needs more than the number (a postcode or a date), which Packages does not ask for"
    if 500 <= code < 600:  # 500, and TrackingMore's 511 to 513
        return "TrackingMore had a problem: try again later"
    return "TrackingMore: %s" % (message or "answered %d" % code)[:140]


def trimmed(t):
    """What Packages keeps of a tracking: its status, its latest event and every checkpoint, and the carrier's page."""
    if not isinstance(t, dict):
        return {}
    keep = {k: t.get(k) for k in ("id", "tracking_number", "courier_code", "delivery_status", "substatus", "updating",
                                  "latest_event", "latest_checkpoint_time", "scheduled_delivery_date", "transit_time",
                                  "created_at")}
    events, link = [], None
    for side in ("destination_info", "origin_info"):
        info = t.get(side)
        if not isinstance(info, dict):
            continue
        link = link or next((info.get(k) for k in ("tracking_link", "weblink") if isinstance(info.get(k), str) and info.get(k)), None)
        for e in info.get("trackinfo") or []:
            if isinstance(e, dict) and isinstance(e.get("tracking_detail"), str) and e["tracking_detail"].strip():
                events.append({k: e.get(k) for k in ("checkpoint_date", "tracking_detail", "location",
                                                      "checkpoint_delivery_status")})
    seen, unique = set(), []
    for e in sorted(events, key=lambda e: moment(e.get("checkpoint_date")) or 0, reverse=True):
        mark = (e.get("checkpoint_date"), e["tracking_detail"])
        if mark not in seen:
            seen.add(mark)
            unique.append(e)
    keep["events"] = unique
    keep["link"] = link
    keep["fetchedAt"] = time.time()
    return keep


def detect(key, number):
    """(candidates [{"code", "name"}], None), at least one, or (None, why)."""
    code, data, why = call(key, "POST", "couriers/detect", body={"tracking_number": number})
    if code != 200:
        return None, why
    found = []
    for c in data if isinstance(data, list) else []:
        if isinstance(c, dict) and isinstance(c.get("courier_code"), str) and c["courier_code"]:
            found.append({"code": c["courier_code"], "name": str(c.get("courier_name") or c["courier_code"])})
    return (found, None) if found else (None, words(4121, ""))


def read_trackings(key, numbers):
    """({id: tracking}, why): the latest for `numbers`, 40 to a call."""
    found = {}
    for start in range(0, len(numbers), BATCH):
        code, data, why = call(key, "GET", "trackings/get", query={"tracking_numbers": ",".join(numbers[start:start + BATCH])})
        if code != 200:
            return found, why
        for t in data if isinstance(data, list) else [data] if isinstance(data, dict) else []:
            if isinstance(t, dict) and isinstance(t.get("id"), str):
                found[t["id"]] = t
    return found, None


# ---- the refresh ----

def locked(f):
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False


def refreshing(cache):
    try:
        with open(os.path.join(cache, REFRESH_LOCK), "a") as f:
            return not locked(f)
    except OSError:
        return False


def fetch(key, store):
    """One read of every parcel on its way; its answer, or why it failed, saved in status.json. Holds no lock while it
    waits on TrackingMore."""
    numbers = sorted({p["number"] for p in store.active()})
    if not numbers:
        return None
    found, why = read_trackings(key, numbers)
    with store:
        now = time.time()
        for parcel in store.parcels:
            if parcel["id"] in found:
                store.status["byId"][parcel["id"]] = trimmed(found[parcel["id"]])
        store.status["triedAt"] = now
        store.status["error"] = why
        if why is None:
            store.status["refreshedAt"] = now
    return why


def due(store, now, force=False):
    """Whether to read TrackingMore now: something on its way whose last read is older than the pace (FORCE_FLOOR when
    forced), and for a view not within RETRY s of a failure."""
    active = store.active()
    if not active:
        return False
    gone = now - store.read_at()
    if force:
        return gone >= FORCE_FLOOR
    status = store.status
    if status.get("error") and now - (status.get("triedAt") or 0) < RETRY:
        return False
    waiting = any(not store.tracking(p).get("events") and now - p.get("added", 0) < NEW_FOR for p in active)
    return gone >= (NEW_FRESH if waiting else FRESH)


def start_refresh(key, store):
    """A detached `main.py --refresh` holding the refresh lock from before it starts; None when one runs already."""
    try:
        lock = open(os.path.join(store.cache, REFRESH_LOCK), "a")
    except OSError:
        return None
    with lock:
        if not locked(lock):
            return None
        try:
            child = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--refresh"], stdin=subprocess.PIPE,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, pass_fds=(lock.fileno(),),
                                     start_new_session=True, cwd=os.path.dirname(os.path.abspath(__file__)))
            child.stdin.write(json.dumps({"key": key, "data": store.data, "cache": store.cache}).encode())
            child.stdin.close()
        except OSError:
            return None
    return child


def refresh_main():
    job = json.loads(sys.stdin.read())
    fetch(job["key"], Store(job["data"], job["cache"]))


def look(run, key):
    """The store as a view shows it, a refresh started when one is due; (store, running)."""
    store = Store.of(run)
    started = due(store, time.time()) and start_refresh(key, store)
    return store, bool(started) or refreshing(store.cache)


# ---- words ----

def moment(stamp):
    """Seconds since 1970 for TrackingMore's YYYY-MM-DD, YYYY-MM-DDTHH:MM:SS and …+HH:MM (a time without a zone read
    as this Mac's); None when it does not read."""
    if not isinstance(stamp, str) or not stamp.strip():
        return None
    text = stamp.strip().replace(" ", "T", 1)
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    for candidate in (text, text[:19]):
        try:
            return datetime.fromisoformat(candidate).timestamp()
        except ValueError:
            pass
    return None


def age(seconds, now):
    if seconds is None:
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


def clock(stamp):
    seconds = moment(stamp)
    if seconds is None:
        return ""
    t = time.localtime(seconds)
    day = "%s %d" % (MONTHS[t.tm_mon - 1], t.tm_mday)
    return day if len(stamp.strip()) <= 10 else "%s, %02d:%02d" % (day, t.tm_hour, t.tm_min)


def title(parcel):
    return parcel.get("name") or parcel["number"]


def status_of(tracking):
    if not tracking:
        return ("Waiting for TrackingMore", "⏳", None)
    return STATUSES.get(tracking.get("delivery_status"), ("Pending", "⏳", None))


def last_event(tracking):
    events = tracking.get("events") or []
    return events[0] if events else None


def event_line(event):
    parts = [" ".join(str(event.get("tracking_detail") or "").split())[:100]]
    place = " ".join(str(event.get("location") or "").split())
    if place:
        parts.append(place[:40])
    return " · ".join(parts)


def summary(tracking):
    event = last_event(tracking)
    return status_of(tracking)[0] + (" · " + event_line(event) if event else "")


def when_last(tracking):
    event = last_event(tracking)
    return moment(event.get("checkpoint_date")) if event else moment(tracking.get("latest_checkpoint_time"))


def staying(action, stay):
    return dict(action, stay=True) if stay else action


def remove_action(parcel, stay=False):
    return staying({"type": "run", "title": "Stop tracking", "command": "remove", "context": {"id": parcel["id"]},
                    "destructive": True, "key": "cmd+delete",
                    "ask": {"confirm": "Stop tracking %s? Adding it again later uses a new TrackingMore credit." % title(parcel)}},
                   stay)


def refresh_action(stay=False):
    return staying({"type": "run", "title": "Refresh", "command": "refresh", "key": "cmd+r"}, stay)


def parcel_actions(parcel, tracking, menu=False):
    actions = [{"type": "push", "title": "Show events", "command": "parcel", "context": {"id": parcel["id"]}}]
    if tracking.get("link"):
        actions.append({"type": "open", "title": "Open on the carrier's site", "url": tracking["link"], "key": "cmd+o"})
    actions.append({"type": "copy", "title": "Copy tracking number", "text": parcel["number"], "key": "cmd+shift+c"})
    actions.append(remove_action(parcel, stay=menu))
    actions.append(refresh_action(stay=menu))
    return actions


def keywords(parcel, tracking):
    return " ".join([parcel["number"], parcel.get("courierName", ""), status_of(tracking)[0]])


def row(parcel, tracking, now, menu=False):
    _, icon, tone = status_of(tracking)
    item = {"id": parcel["id"], "title": title(parcel), "subtitle": summary(tracking), "icon": icon,
            "keywords": keywords(parcel, tracking), "actions": parcel_actions(parcel, tracking, menu)}
    when = age(when_last(tracking) or parcel.get("added"), now)
    if when:
        item["accessory"] = {"text": when, "tone": tone} if tone else when
    return item


def split_input(text):
    """(number, name) from "<number> [a name]"; number None when the first word is no tracking number."""
    words_ = str(text or "").split(None, 1)
    number = words_[0].upper() if words_ and NUMBER.match(words_[0]) and re.search(r"\d", words_[0]) else None
    name = " ".join(words_[1].split())[:60] if len(words_) > 1 else ""
    return number, name


def grouped(store):
    on_way, done = [], []
    for p in sorted(store.parcels, key=lambda p: -(p.get("added") or 0)):
        (done if state(store.tracking(p)) == "delivered" else on_way).append(p)
    return on_way, done


# ---- commands ----

def no_key_row():
    return {"title": NO_KEY_TITLE, "icon": "🔑",
            "subtitle": "Make an account at trackingmore.com, then Developer › API Key; paste it in Packages' settings",
            "actions": NO_KEY_ACTIONS}


def list_command(run, key):
    store, running = look(run, key)
    now = time.time()
    query = " ".join(str(run.get("query") or "").split())
    items = []
    number, name = split_input(query)
    if number and not any(p["number"] == number for p in store.parcels):
        items.append({"title": "Track %s" % number, "subtitle": ("as %s · " % name if name else "") + "TrackingMore finds the carrier",
                      "icon": "➕", "actions": [{"type": "run", "title": "Track", "command": "add", "clear": True,
                                                "context": {"number": number, "name": name}}]})
    if store.status.get("error"):
        items.append({"title": "Could not refresh", "subtitle": store.status["error"], "icon": "⚠\ufe0f",
                      "actions": [refresh_action(stay=True)]})
    on_way, done = grouped(store)
    needle = "" if number else query.lower()
    for section, parcels in (("On the way", on_way), ("Delivered", done)):
        for p in parcels:
            tracking = store.tracking(p)
            if needle and needle not in " ".join([title(p), keywords(p, tracking), summary(tracking)]).lower():
                continue
            items.append(dict(row(p, tracking, now, menu=True), section=section))
    if not store.parcels and not number:
        items.append({"title": "No parcels yet", "icon": "📦",
                      "subtitle": "Type a tracking number, then a name if you like, and press Return"})
    elif running:
        items.append({"title": "Refreshing…", "subtitle": "Open Packages again in a moment for the latest", "icon": "🔄"})
    send({"type": "list", "items": items})


def add(run, key):
    context = context_of(run)
    if context.get("number"):
        number, name = split_input(context.get("number"))
        name = " ".join(str(context.get("name") or "").split())[:60] or name
    else:
        number, name = split_input(run.get("input"))
    if not number:
        fail("type a tracking number first, then a name if you like")
        return
    store = Store.of(run)
    courier = context.get("courier") if isinstance(context.get("courier"), str) else None
    have = next((p for p in store.parcels if p["number"] == number and (courier is None or p["courier"] == courier)), None)
    if have:
        send({"type": "hud", "text": "Packages: already tracking %s" % title(have)})
        return
    courier_name = str(context.get("courierName") or courier or "")
    if not courier:
        found, why = detect(key, number)
        if not found:
            fail(why)
            return
        if len(found) > 1:
            send({"type": "action", "action": {"type": "push", "title": "Pick the carrier", "command": "pick-carrier",
                                                "context": {"number": number, "name": name,
                                                            "carriers": found[:MOST_CARRIERS]}}})
            return
        courier, courier_name = found[0]["code"], found[0]["name"]
    code, tracking, why = call(key, "POST", "trackings/create", body={"tracking_number": number, "courier_code": courier})
    if code == 4101:  # tracked already in this TrackingMore account: read it, no new credit
        found, why = read_trackings(key, [number])
        tracking = next((t for t in found.values() if t.get("courier_code") == courier), None)
        code = 200 if tracking else code
        why = why or "TrackingMore lists it already but did not send it"
    if code != 200 or not isinstance(tracking, dict) or not isinstance(tracking.get("id"), str):
        fail(why or "TrackingMore did not start tracking it")
        return
    parcel = {"id": tracking["id"], "number": number, "courier": courier, "courierName": courier_name,
              "name": name, "added": time.time()}
    kept = trimmed(tracking)
    with store:
        store.parcels = [p for p in store.parcels if p["id"] != parcel["id"]] + [parcel]
        store.status["byId"][parcel["id"]] = kept
    send({"type": "hud", "text": "Packages: tracking %s with %s · %s" % (title(parcel), courier_name, status_of(kept)[0])})


def pick_carrier(run, key=None):
    context = context_of(run)
    number, name = context.get("number"), context.get("name") or ""
    items = []
    for c in (context.get("carriers") or [])[:MOST_CARRIERS]:
        if isinstance(c, dict) and isinstance(c.get("code"), str):
            items.append({"title": str(c.get("name") or c["code"]), "subtitle": c["code"], "icon": "🚚",
                          "actions": [{"type": "run", "title": "Track with it", "command": "add",
                                       "context": {"number": number, "name": name, "courier": c["code"],
                                                   "courierName": str(c.get("name") or c["code"])}}]})
    if not items or not isinstance(number, str):
        items = [{"title": "No carriers to pick from", "subtitle": "Track the number again from Packages", "icon": "⚠\ufe0f"}]
    send({"type": "list", "items": items})


def parcel_detail(run, key):
    store, running = look(run, key)
    parcel = store.find(context_of(run).get("id"))
    if not parcel:
        send({"type": "detail", "markdown": "## Not tracked any more\n\nThis parcel was removed from Packages.",
              "metadata": [], "actions": []})
        return
    tracking = store.tracking(parcel)
    now = time.time()
    words_, icon, _ = status_of(tracking)
    lines = ["## %s %s" % (icon, title(parcel)), "", "**%s**" % words_, ""]
    events = tracking.get("events") or []
    for e in events[:EVENTS_SHOWN]:
        lines.append("- **%s** · %s" % (clock(e.get("checkpoint_date")) or "–", event_line(e)))
    if len(events) > EVENTS_SHOWN:
        lines.append("- … %d older events" % (len(events) - EVENTS_SHOWN))
    if not events:
        lines.append("No events yet: the carrier has not scanned it, or TrackingMore has not read it yet.")
    metadata = [{"label": "Number", "text": parcel["number"]},
                {"label": "Carrier", "text": parcel.get("courierName") or parcel["courier"]},
                {"label": "Status", "text": words_}]
    if tracking.get("scheduled_delivery_date"):
        expected = tracking["scheduled_delivery_date"]
        metadata.append({"label": "Expected", "text": clock(expected) or str(expected)})
    metadata.append({"label": "Added", "text": ago(parcel.get("added"), now)})
    metadata.append({"label": "Read", "text": "refreshing…" if running else ago(tracking.get("fetchedAt"), now)})
    why_not = {"delivered": "delivered", "stopped": "TrackingMore stopped updating it"}.get(state(tracking))
    if why_not:
        metadata.append({"label": "Refresh", "text": "no longer asked (%s)" % why_not})
    send({"type": "detail", "markdown": "\n".join(lines), "metadata": metadata,
          "actions": [a for a in parcel_actions(parcel, tracking) if a["type"] != "push"]})


def remove(run, key):
    store = Store.of(run)
    parcel = store.find(context_of(run).get("id"))
    if not parcel:
        send({"type": "hud", "text": "Packages: not tracked any more"})
        return
    code, _, why = call(key, "DELETE", "trackings/delete/%s" % parcel["id"])
    if code != 200 and code not in GONE:
        fail("could not stop tracking it: %s" % why)
        return
    with store:
        store.parcels = [p for p in store.parcels if p["id"] != parcel["id"]]
    send({"type": "hud", "text": "Packages: stopped tracking %s" % title(parcel)})


def refresh(run, key):
    store = Store.of(run)
    count = len(store.active())
    if not count:
        send({"type": "hud", "text": "Packages: nothing on its way to refresh"})
        return
    if not due(store, time.time(), force=True):
        send({"type": "hud", "text": "Packages: refreshed %s" % ago(store.read_at(), time.time())})
        return
    with open(os.path.join(store.cache, REFRESH_LOCK), "a") as lock:
        started, waited = time.monotonic(), False
        while not locked(lock):  # another refresh runs: its answer is this one's
            if time.monotonic() - started > REFRESH_BUDGET:
                fail("could not refresh: TrackingMore did not answer in time")
                return
            waited = True
            time.sleep(0.2)
        if waited:
            store.read()
            why = store.status.get("error")
        else:
            why = fetch(key, store)
    if why:
        fail("could not refresh: %s" % why)
        return
    send({"type": "hud", "text": "Packages: %d parcel%s refreshed" % (count, "" if count == 1 else "s")})


def page(run, key):
    store, running = look(run, key)
    now = time.time()
    blocks = [{"type": "input", "placeholder": "Tracking number, then a name if you like",
               "action": {"type": "run", "title": "Track", "command": "add"}}]
    if store.status.get("error"):
        blocks.append({"type": "note", "text": "Could not refresh: %s" % store.status["error"], "icon": "info"})
    on_way, done = grouped(store)
    for heading, parcels in (("On the way", on_way), ("Delivered", done)):
        if parcels:
            items = [dict(row(p, store.tracking(p), now), inline=[dict(remove_action(p), icon="xmark")]) for p in parcels]
            blocks.append({"type": "list", "title": heading, "items": items})
    if not store.parcels:
        blocks.append({"type": "markdown", "text": "No parcels yet. Type a tracking number above and press Return: "
                                                   "TrackingMore finds the carrier."})
    read = "refreshing…" if running else "read %s" % ago(store.read_at() or None, now)
    blocks.append({"type": "note", "text": "TrackingMore · %s · delivered parcels are not asked again" % read,
                   "icon": "info"})
    blocks.append({"type": "buttons", "actions": [refresh_action()]})
    answer = {"type": "blocks", "blocks": blocks}
    if running:
        answer["refresh"] = 3
    send(answer)


# Each command, and what it answers without a key: a list row, a detail or a page saying how to get one; a no-view
# command's error. The carrier pick needs none (it only lists what `add` found).
COMMANDS = {
    "packages": (list_command, lambda: send({"type": "list", "items": [no_key_row()]})),
    "parcel": (parcel_detail, lambda: send({"type": "detail", "markdown": NO_KEY_MARKDOWN, "metadata": [],
                                            "actions": NO_KEY_ACTIONS})),
    "page": (page, lambda: send({"type": "blocks", "blocks": [{"type": "markdown", "text": NO_KEY_MARKDOWN},
                                                              {"type": "buttons", "actions": NO_KEY_ACTIONS}]})),
    "add": (add, lambda: fail(NO_KEY_ERROR)),
    "remove": (remove, lambda: fail(NO_KEY_ERROR)),
    "refresh": (refresh, lambda: fail(NO_KEY_ERROR)),
    "pick-carrier": (pick_carrier, None),
}


def main():
    if sys.argv[1:] == ["--refresh"]:
        refresh_main()
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
    handler, without_key = COMMANDS[command]
    if without_key is None:
        handler(run)
        return
    key, why = api_key(run)
    if why:
        fail(why)
    elif not key:
        without_key()
    else:
        handler(run, key)


if __name__ == "__main__":
    main()
