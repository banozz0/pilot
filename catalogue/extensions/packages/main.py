#!/usr/bin/env python3
"""Packages for Pilot: parcels kept by their number, and, with the person's own TrackingMore API key (the `apiKey`
password preference, kept in the Keychain and handed over in each run message), tracked live through trackingmore.com.

Without a key (TrackingMore's free accounts have no API key) nothing reaches the network: a parcel is its number, a name
and a carrier guessed from the number's shape, kept on this Mac. Return on it opens its tracking page: the carrier's own
when the shape names one carrier for certain (UPS's 1Z numbers, USPS's 22-digit ones), else 17track's page for the
number, which finds the carrier itself. Opening it sends the number to that site. Delivered is marked by hand.

With a key TrackingMore's v4 API (https://api.trackingmore.com/v4, header Tracking-Api-Key) does the rest: POST
couriers/detect names the carrier of a number, POST trackings/create starts tracking it (one credit for each new number
and carrier; reading it again costs none), GET trackings/get?tracking_numbers=… (40 at most) reads the latest, DELETE
trackings/delete/{id} stops it. Errors come back as HTTP 4xx with the envelope's meta.code in the body (4101 already
exists, 4190 out of credits, 401 the key refused, 429 too fast), so curl runs without --fail and the body decides. A
parcel kept before the key came stays local until "Track with TrackingMore" spends its credit: none is spent unasked.

The key, the URL (its query holds tracking numbers) and the body reach curl as a config on its stdin (`curl -K -`),
never as arguments, which `ps` shows. Nothing is logged: no number, name, event or key leaves stdout's protocol lines.

Refresh (with a key only): a view (the list, a parcel, the page, the menu bar item) shows what was read last at once
and, when that is older than FRESH s (NEW_FRESH s while a parcel added in the last hour has no event yet), starts one
detached child (`main.py --refresh`, single under refresh.lock) that reads every tracked parcel still on its way in one
call per 40 numbers. The menu bar item is asked every 300 s, so with a key and a parcel on its way TrackingMore is read
at most once every 15 minutes in the background (2 for a new parcel with no event yet), each read free of credits; with
nothing on its way, or no key, never. Delivered parcels (TrackingMore's word or the person's mark) and ones TrackingMore
stopped updating are never asked again. Refresh (⌘R) forces one, not within FORCE_FLOOR s of the last.

Stores: paths.data/parcels.json (the list: id, number, carrier or its guess, name, added, a Delivered mark, `local` for
one TrackingMore does not track) and paths.cache/status.json (what TrackingMore said for each id, and when), each written
under store.lock, so a refresh landing late never brings back a removed parcel or drops a new one. A tracked parcel's id
is TrackingMore's; a local one's is "local-" and 16 hex characters.
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
from urllib.parse import quote, urlencode

API = "https://api.trackingmore.com/v4"
SIGNUP = "https://www.trackingmore.com/signup.html"
PRICING = "https://www.trackingmore.com/pricing"
KEY_HELP = "https://www.trackingmore.com/docs/trackingmore/zte58cee4mz0v-api-authentication"
TRACK_ANY = "https://t.17track.net/en#nums=%s"  # 17track's page for a number; it finds the carrier
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
FACE_LABEL, FACE_VALUE = 16, 24  # a dock face's label and value, at most
PARCELS = "parcels.json"
STATUS = "status.json"
STORE_LOCK = "store.lock"
REFRESH_LOCK = "refresh.lock"
KEY = re.compile(r"^[A-Za-z0-9_-]{8,128}$")
NUMBER = re.compile(r"^[A-Za-z0-9-]{5,50}$")
ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")  # TrackingMore's tracking ids are 32 hex characters
GONE = {404, 4102, 4112}  # TrackingMore has no such tracking: removing it is done
# Numbers whose shape names one carrier, and its own tracking page: UPS's 1Z and 16 more (UPS's tracking support), USPS's
# Intelligent Mail package barcode, 92 to 95 and 20 more digits (USPS Publication 199).
CERTAIN = [(re.compile(r"^1Z[0-9A-Z]{16}$"), "UPS", "https://www.ups.com/track?loc=en_US&tracknum=%s"),
           (re.compile(r"^9[2-5]\d{20}$"), "USPS", "https://tools.usps.com/go/TrackConfirmAction?tLabels=%s")]
# The UPU's S10 shape (two letters, nine digits, the sending country's ISO code) names the post it left from, not the one
# that brings it, so its page is 17track's.
S10 = re.compile(r"^[A-Z]{2}\d{9}([A-Z]{2})$")
POSTS = {"AU": "Australia Post", "CA": "Canada Post", "CN": "China Post", "DE": "Deutsche Post", "ES": "Correos",
         "FR": "La Poste", "GB": "Royal Mail", "HK": "Hongkong Post", "IT": "Poste Italiane", "JP": "Japan Post",
         "KR": "Korea Post", "MT": "MaltaPost", "NL": "PostNL", "SG": "Singapore Post", "US": "USPS"}
GUESSES = [(re.compile(r"^TBA\d{12}$"), "Amazon Logistics")]
# TrackingMore's delivery statuses (docs: Courier Delivery Status): words, emoji, tone.
STATUSES = {"pending": ("Pending", "⏳", None), "notfound": ("Not found yet", "⏳", None),
            "inforeceived": ("Label created", "🏷\ufe0f", None), "transit": ("In transit", "🚚", None),
            "pickup": ("Out for delivery", "🛵", "fine"), "undelivered": ("Delivery failed", "⚠\ufe0f", "warn"),
            "delivered": ("Delivered", "✅", "fine"), "exception": ("Problem", "❗", "alert"),
            "expired": ("No news for 30 days", "💤", "warn")}
TONE_RANK = {None: 0, "fine": 1, "warn": 2, "alert": 3}
MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]  # whatever the Mac's language
NO_KEY_TITLE = "Live status needs a TrackingMore API key"
NO_KEY = ("Packages keeps your parcels without one: Return opens a parcel's tracking page and you mark it delivered. "
          "For live status, last events and Delivered on its own, add a TrackingMore API key in Packages' settings "
          "(Extensions › Packages). TrackingMore's paid plans include one (Developer › API Key › Generate API key); "
          "each new parcel then uses one credit, refreshing it none.")
NO_KEY_ACTIONS = [{"type": "open", "title": "See TrackingMore's plans", "url": PRICING},
                  {"type": "open", "title": "How to make an API key", "url": KEY_HELP}]
BAD_KEY = "that TrackingMore API key does not look right: check it in Packages' settings"


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


def fail(text):
    send({"type": "error", "text": text})


def hud(text):
    send({"type": "hud", "text": "Packages: " + text})


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
                save(os.path.join(self.data, PARCELS), {"version": 2, "parcels": self.parcels})
                save(os.path.join(self.cache, STATUS), self.status)
        finally:
            self.lock.close()
        return False

    def tracking(self, parcel):
        entry = self.status["byId"].get(parcel["id"])
        return entry if isinstance(entry, dict) else {}

    def find(self, parcel_id):
        return next((p for p in self.parcels if p["id"] == parcel_id), None)

    def active(self, force=False):
        """The tracked parcels still worth asking about: not delivered, and still updated by TrackingMore; forced, any
        not delivered."""
        return [p for p in self.parcels if state(p, self.tracking(p)) in (("active", "stopped") if force else ("active",))]

    def read_at(self):
        """When the stalest parcel on its way was last read (an add reads its own), 0 for one never read; with none on
        its way, the last refresh."""
        active = self.active()
        if not active:
            return self.status.get("refreshedAt") or 0
        return min(self.tracking(p).get("fetchedAt") or 0 for p in active)


def parcel_of(value):
    """A parcel as stored: an id and a number, a carrier (empty for a local one, which may have only a guess)."""
    return (isinstance(value, dict) and all(isinstance(value.get(k), str) and value[k] for k in ("id", "number"))
            and isinstance(value.get("courier", ""), str) and (value.get("local") or value.get("courier"))
            and isinstance(value.get("added", 0), (int, float)))


def state(parcel, tracking):
    """"delivered" (TrackingMore's word or the person's mark), "local" (TrackingMore does not track it), "stopped"
    (TrackingMore no longer updates it) or "active"; only an active parcel is asked again."""
    if parcel.get("delivered") or tracking.get("delivery_status") == "delivered":
        return "delivered"
    if parcel.get("local"):
        return "local"
    return "stopped" if tracking.get("updating") is False else "active"


def guess(number):
    """(the carrier's name or "", its own tracking page when the number's shape names it for certain, else None)."""
    for pattern, name, url in CERTAIN:
        if pattern.match(number):
            return name, url % quote(number, safe="")
    post = S10.match(number)
    if post:
        return POSTS.get(post.group(1), "%s's post" % post.group(1)), None
    return next((name for pattern, name in GUESSES if pattern.match(number)), ""), None


def page_url(parcel, tracking):
    """Where a parcel's tracking page is: TrackingMore's link to the carrier's page, the carrier's own for a number
    whose shape names it, else 17track's for the number."""
    if isinstance(tracking.get("link"), str) and tracking["link"].startswith("https://"):
        return tracking["link"]
    return guess(parcel["number"])[1] or TRACK_ANY % quote(parcel["number"], safe="")


def site_of(url):
    host = url.split("/")[2] if url.count("/") >= 2 else url
    return host[4:] if host.startswith("www.") else host


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


def fetch(key, store, force=False):
    """One read of every tracked parcel on its way (forced, every one not delivered); its answer, or why it failed,
    saved in status.json. A tracking is matched by id, else by number and carrier. Holds no lock while it waits on
    TrackingMore."""
    numbers = sorted({p["number"] for p in store.active(force)})
    if not numbers:
        return None
    found, why = read_trackings(key, numbers)
    by_number = {(t.get("tracking_number"), t.get("courier_code")): t for t in found.values()}
    with store:
        now = time.time()
        for parcel in store.parcels:
            if parcel.get("local"):
                continue
            t = found.get(parcel["id"]) or by_number.get((parcel["number"], parcel["courier"]))
            if t is not None:
                store.status["byId"][parcel["id"]] = trimmed(t)
        store.status["triedAt"] = now
        store.status["error"] = why
        if why is None:
            store.status["refreshedAt"] = now
    return why


def due(store, now, force=False):
    """Whether to read TrackingMore now: something on its way whose last read is older than the pace (FORCE_FLOOR when
    forced), and for a view not within RETRY s of a failure. The last whole refresh bounds it, so a parcel TrackingMore
    leaves out of its answer (archived, or gone after its 180 days) waits like the rest."""
    active = store.active(force)
    if not active:
        return False
    gone = now - max(store.read_at(), store.status.get("refreshedAt") or 0)
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
    """The store as a view shows it, a refresh started when one is due (never without a key); (store, running)."""
    store = Store.of(run)
    if not key:
        return store, False
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


def fit(text, most):
    text = " ".join(str(text).split())
    return text if len(text) <= most else text[:most - 1] + "…"


def title(parcel):
    return parcel.get("name") or parcel["number"]


def carrier(parcel):
    """The carrier's name: TrackingMore's, the certain one, "maybe" before a guess, or ""."""
    if not parcel.get("local"):
        return parcel.get("courierName") or parcel.get("courier") or ""
    name, certain = guess(parcel["number"])
    return name if certain else ("maybe " + name if name else "")


def tracked(parcel, key):
    """Whether TrackingMore tracks it and this run can ask it."""
    return bool(key) and not parcel.get("local")


def status_of(parcel, tracking):
    if parcel.get("delivered"):
        return ("Delivered (marked)", "✅", "fine")
    if parcel.get("local"):
        return ("On the way", "📦", None)
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


def summary(parcel, tracking):
    """A row's subtitle: the status and last event, or for a parcel with none the carrier and where Return goes."""
    event = last_event(tracking)
    if event:
        return status_of(parcel, tracking)[0] + " · " + event_line(event)
    if parcel.get("local") or not tracking:
        where = "Return opens " + site_of(page_url(parcel, tracking))
        said = carrier(parcel)
        head = status_of(parcel, tracking)[0] if parcel.get("delivered") else said[:1].upper() + said[1:]
        return " · ".join(part for part in (head, where) if part)
    return status_of(parcel, tracking)[0]


def when_last(tracking):
    event = last_event(tracking)
    return moment(event.get("checkpoint_date")) if event else moment(tracking.get("latest_checkpoint_time"))


def staying(action, stay):
    return dict(action, stay=True) if stay else action


def remove_action(parcel, key, stay=False):
    if tracked(parcel, key):
        title_, ask = "Stop tracking", "Stop tracking %s? Adding it again later uses a new TrackingMore credit." % title(parcel)
    else:
        title_, ask = "Remove", "Remove %s from Packages?" % title(parcel)
    return staying({"type": "run", "title": title_, "command": "remove", "context": {"id": parcel["id"]},
                    "destructive": True, "key": "cmd+delete", "ask": {"confirm": ask}}, stay)


def mark_action(parcel, tracking, stay=False):
    """Mark delivered, or take a mark back; None when TrackingMore itself says delivered."""
    if parcel.get("delivered"):
        return staying({"type": "run", "title": "Mark on the way", "command": "mark",
                        "context": {"id": parcel["id"], "delivered": False}}, stay)
    if state(parcel, tracking) == "delivered":
        return None
    return staying({"type": "run", "title": "Mark delivered", "command": "mark",
                    "context": {"id": parcel["id"], "delivered": True}}, stay)


def refresh_action(stay=False):
    return staying({"type": "run", "title": "Refresh", "command": "refresh", "key": "cmd+r"}, stay)


def parcel_actions(parcel, tracking, key, menu=False):
    url = page_url(parcel, tracking)
    opened = {"type": "open", "title": "Open on %s" % site_of(url), "url": url}
    shown = {"type": "push", "title": "Show events" if tracked(parcel, key) else "Show details", "command": "parcel",
             "context": {"id": parcel["id"]}}
    actions = [shown, dict(opened, key="cmd+o")] if tracked(parcel, key) else [opened, shown]
    actions.append({"type": "copy", "title": "Copy tracking number", "text": parcel["number"], "key": "cmd+shift+c"})
    mark = mark_action(parcel, tracking, stay=menu)
    if mark:
        actions.append(mark)
    if key and parcel.get("local") and not parcel.get("delivered"):
        actions.append(staying({"type": "run", "title": "Track with TrackingMore (uses one credit)", "command": "add",
                                "context": {"from": parcel["id"]}}, menu))
    actions.append(remove_action(parcel, key, stay=menu))
    if tracked(parcel, key):
        actions.append(refresh_action(stay=menu))
    return actions


def keywords(parcel, tracking):
    return " ".join([parcel["number"], carrier(parcel), status_of(parcel, tracking)[0]])


def row(parcel, tracking, now, key, menu=False):
    _, icon, tone = status_of(parcel, tracking)
    item = {"id": parcel["id"], "title": title(parcel), "subtitle": summary(parcel, tracking), "icon": icon,
            "keywords": keywords(parcel, tracking), "actions": parcel_actions(parcel, tracking, key, menu)}
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
        (done if state(p, store.tracking(p)) == "delivered" else on_way).append(p)
    return on_way, done


def key_row(why):
    if why:
        return {"title": "That TrackingMore API key does not look right", "icon": "🔑", "subtitle": BAD_KEY[0].upper() + BAD_KEY[1:],
                "actions": NO_KEY_ACTIONS}
    return {"title": NO_KEY_TITLE, "icon": "🔑", "actions": NO_KEY_ACTIONS,
            "subtitle": "Parcels are kept and opened without one; TrackingMore's paid plans include a key"}


# ---- commands ----

def list_command(run, key):
    store, running = look(run, key)
    now = time.time()
    query = " ".join(str(run.get("query") or "").split())
    items = []
    number, name = split_input(query)
    if number and not any(p["number"] == number for p in store.parcels):
        if key:
            subtitle, verb = "TrackingMore finds the carrier", "Track"
        else:
            said = carrier({"number": number, "local": True})
            subtitle, verb = " · ".join(p for p in (said[:1].upper() + said[1:], "Return will open its tracking page") if p), "Keep"
        items.append({"title": "%s %s" % (verb, number), "subtitle": ("as %s · " % name if name else "") + subtitle,
                      "icon": "➕", "actions": [{"type": "run", "title": verb, "command": "add", "clear": True,
                                                "context": {"number": number, "name": name}}]})
    if key and store.status.get("error"):
        items.append({"title": "Could not refresh", "subtitle": store.status["error"], "icon": "⚠\ufe0f",
                      "actions": [refresh_action(stay=True)]})
    on_way, done = grouped(store)
    needle = "" if number else query.lower()
    for section, parcels in (("On the way", on_way), ("Delivered", done)):
        for p in parcels:
            tracking = store.tracking(p)
            if needle and needle not in " ".join([title(p), keywords(p, tracking), summary(p, tracking)]).lower():
                continue
            items.append(dict(row(p, tracking, now, key, menu=True), section=section))
    if not store.parcels and not number:
        items.append({"title": "No parcels yet", "icon": "📦",
                      "subtitle": "Type a tracking number, then a name if you like, and press Return"})
    elif running:
        items.append({"title": "Refreshing…", "subtitle": "Open Packages again in a moment for the latest", "icon": "🔄"})
    if not key and not needle:
        items.append(dict(key_row(run.get("keyProblem")), section="TrackingMore"))
    send({"type": "list", "items": items})


def keep_local(store, number, name):
    said, _ = guess(number)
    parcel = {"id": "local-" + os.urandom(8).hex(), "number": number, "courier": "", "courierName": said, "name": name,
              "added": time.time(), "local": True}
    with store:
        store.parcels.append(parcel)
    hud("keeping %s · Return opens it on %s" % (title(parcel), site_of(page_url(parcel, {}))))


def add(run, key):
    context = context_of(run)
    store = Store.of(run)
    source = store.find(context.get("from")) if isinstance(context.get("from"), str) else None
    if context.get("from") and not (source and source.get("local")):
        hud("that parcel is not kept here any more")
        return
    if source:
        number, name = source["number"], source.get("name") or ""
    elif context.get("number"):
        number, name = split_input(context.get("number"))
        name = " ".join(str(context.get("name") or "").split())[:60] or name
    else:
        number, name = split_input(run.get("input"))
    if not number:
        fail("type a tracking number first, then a name if you like")
        return
    if run.get("keyProblem") and (source or not key):
        fail(run["keyProblem"])
        return
    courier = context.get("courier") if isinstance(context.get("courier"), str) else None
    have = next((p for p in store.parcels if p is not source and p["number"] == number
                 and (courier is None or p.get("local") or p["courier"] == courier)), None)
    if have:
        hint = ": Track with TrackingMore on it tracks it live" if key and have.get("local") else ""
        hud("already %s %s%s" % ("keeping" if have.get("local") else "tracking", title(have), hint))
        return
    if not key:
        keep_local(store, number, name)
        return
    courier_name = str(context.get("courierName") or courier or "")
    if not courier:
        found, why = detect(key, number)
        if not found:
            fail(why)
            return
        if len(found) > 1:
            ask = {"number": number, "name": name, "carriers": found[:MOST_CARRIERS]}
            if source:
                ask["from"] = source["id"]
            send({"type": "action", "action": {"type": "push", "title": "Pick the carrier", "command": "pick-carrier",
                                                "context": ask}})
            return
        courier, courier_name = found[0]["code"], found[0]["name"]
    code, tracking, why = call(key, "POST", "trackings/create", body={"tracking_number": number, "courier_code": courier})
    if code == 4101:  # tracked already in this TrackingMore account: read it, no new credit
        found, why = read_trackings(key, [number])
        tracking = next((t for t in found.values() if t.get("courier_code") == courier), None)
        code = 200 if tracking else code
        why = why or "TrackingMore lists it already but did not send it"
    if code != 200 or not isinstance(tracking, dict) or not ID.match(str(tracking.get("id"))):
        fail(why or "TrackingMore did not start tracking it")
        return
    parcel = {"id": tracking["id"], "number": number, "courier": courier, "courierName": courier_name,
              "name": name, "added": source.get("added", time.time()) if source else time.time()}
    kept = trimmed(tracking)
    with store:
        gone = {parcel["id"], source["id"] if source else None}
        store.parcels = [p for p in store.parcels if p["id"] not in gone] + [parcel]
        store.status["byId"][parcel["id"]] = kept
    hud("tracking %s with %s · %s" % (title(parcel), courier_name, status_of(parcel, kept)[0]))


def pick_carrier(run, key):
    context = context_of(run)
    number, name = context.get("number"), context.get("name") or ""
    items = []
    for c in (context.get("carriers") or [])[:MOST_CARRIERS]:
        if isinstance(c, dict) and isinstance(c.get("code"), str):
            picked = {"number": number, "name": name, "courier": c["code"], "courierName": str(c.get("name") or c["code"])}
            if isinstance(context.get("from"), str):
                picked["from"] = context["from"]
            items.append({"title": str(c.get("name") or c["code"]), "subtitle": c["code"], "icon": "🚚",
                          "actions": [{"type": "run", "title": "Track with it", "command": "add", "context": picked}]})
    if not items or not isinstance(number, str):
        items = [{"title": "No carriers to pick from", "subtitle": "Track the number again from Packages", "icon": "⚠\ufe0f"}]
    send({"type": "list", "items": items})


def parcel_detail(run, key):
    store, running = look(run, key)
    parcel = store.find(context_of(run).get("id"))
    if not parcel:
        send({"type": "detail", "markdown": "## Not kept any more\n\nThis parcel was removed from Packages.",
              "metadata": [], "actions": []})
        return
    tracking = store.tracking(parcel)
    now = time.time()
    words_, icon, _ = status_of(parcel, tracking)
    lines = ["## %s %s" % (icon, title(parcel)), "", "**%s**" % words_, ""]
    events = tracking.get("events") or []
    for e in events[:EVENTS_SHOWN]:
        lines.append("- **%s** · %s" % (clock(e.get("checkpoint_date")) or "–", event_line(e)))
    if len(events) > EVENTS_SHOWN:
        lines.append("- … %d older events" % (len(events) - EVENTS_SHOWN))
    if not events:
        url = page_url(parcel, tracking)
        if tracked(parcel, key):
            lines.append("No events yet: the carrier has not scanned it, or TrackingMore has not read it yet.")
        else:
            lines.append("Packages keeps this parcel without TrackingMore: its events are on its tracking page, "
                         "[%s](%s)." % (site_of(url), url))
    metadata = [{"label": "Number", "text": parcel["number"]}]
    if carrier(parcel):
        metadata.append({"label": "Carrier", "text": carrier(parcel)})
    metadata.append({"label": "Status", "text": words_})
    if tracking.get("scheduled_delivery_date"):
        expected = tracking["scheduled_delivery_date"]
        metadata.append({"label": "Expected", "text": clock(expected) or str(expected)})
    metadata.append({"label": "Added", "text": ago(parcel.get("added"), now)})
    if tracked(parcel, key):
        metadata.append({"label": "Read", "text": "refreshing…" if running else ago(tracking.get("fetchedAt"), now)})
        why_not = {"delivered": "delivered", "stopped": "TrackingMore stopped updating it"}.get(state(parcel, tracking))
        if why_not:
            metadata.append({"label": "Refresh", "text": "no longer asked (%s)" % why_not})
    send({"type": "detail", "markdown": "\n".join(lines), "metadata": metadata,
          "actions": [a for a in parcel_actions(parcel, tracking, key) if a["type"] != "push"]})


def remove(run, key):
    store = Store.of(run)
    parcel = store.find(context_of(run).get("id"))
    if not parcel:
        hud("not kept any more")
        return
    if tracked(parcel, key):
        code, _, why = call(key, "DELETE", "trackings/delete/" + quote(parcel["id"], safe=""))
        if code != 200 and code not in GONE:
            fail("could not stop tracking it: %s" % why)
            return
    with store:
        store.parcels = [p for p in store.parcels if p["id"] != parcel["id"]]
    if tracked(parcel, key):
        hud("stopped tracking %s" % title(parcel))
    else:
        hud("removed %s%s" % (title(parcel), "" if parcel.get("local") else " (TrackingMore still lists it, at no cost)"))


def mark(run, key):
    context = context_of(run)
    delivered = context.get("delivered") is not False
    with Store.of(run) as store:
        parcel = store.find(context.get("id"))
        if parcel:
            if delivered:
                parcel["delivered"] = time.time()
            else:
                parcel.pop("delivered", None)
    if not parcel:
        hud("not kept any more")
    else:
        hud("%s %s" % (title(parcel), "marked delivered" if delivered else "back on the way"))


def refresh(run, key):
    if not key:
        fail(run.get("keyProblem") or "refreshing needs a TrackingMore API key: without one, open a parcel's tracking page")
        return
    store = Store.of(run)
    count = len(store.active(force=True))
    if not count:
        hud("nothing on its way to refresh")
        return
    if not due(store, time.time(), force=True):
        hud("refreshed %s" % ago(store.read_at(), time.time()))
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
            why = fetch(key, store, force=True)
    if why:
        fail("could not refresh: %s" % why)
        return
    hud("%d parcel%s refreshed" % (count, "" if count == 1 else "s"))


def view_blocks(run, key, store, running):
    """The page's blocks, and the menu bar item's popover's."""
    now = time.time()
    blocks = [{"type": "input", "placeholder": "Tracking number, then a name if you like",
               "action": {"type": "run", "title": "Track" if key else "Keep", "command": "add"}}]
    if key and store.status.get("error"):
        blocks.append({"type": "note", "text": "Could not refresh: %s" % store.status["error"], "icon": "info"})
    on_way, done = grouped(store)
    for heading, parcels in (("On the way", on_way), ("Delivered", done)):
        if parcels:
            items = []
            for p in parcels:
                tracking = store.tracking(p)
                inline = [dict(remove_action(p, key), icon="xmark")]
                marked = mark_action(p, tracking)
                if marked:
                    inline.insert(0, dict(marked, icon="reset" if p.get("delivered") else "checkmark.circle"))
                items.append(dict(row(p, tracking, now, key), inline=inline))
            blocks.append({"type": "list", "title": heading, "items": items})
    if not store.parcels:
        blocks.append({"type": "markdown", "text": "No parcels yet. Type a tracking number above and press Return: "
                                                   + ("TrackingMore finds the carrier." if key else
                                                      "Packages keeps it, and Return on it opens its tracking page.")})
    if key:
        read = "refreshing…" if running else "read %s" % ago(store.read_at() or None, now)
        blocks.append({"type": "note", "text": "TrackingMore · %s · delivered parcels are not asked again" % read,
                       "icon": "info"})
        blocks.append({"type": "buttons", "actions": [refresh_action()]})
    else:
        problem = run.get("keyProblem")
        blocks.append({"type": "note", "icon": "info", "text": (problem[0].upper() + problem[1:]) if problem else
                       "No TrackingMore key: Return opens a parcel's tracking page (the carrier's, or 17track's), "
                       "and you mark it delivered. A key, on TrackingMore's paid plans, adds live status."})
        blocks.append({"type": "buttons", "actions": NO_KEY_ACTIONS})
    return blocks


def send_blocks(run, key, store, running):
    answer = {"type": "blocks", "blocks": view_blocks(run, key, store, running)}
    if running:
        answer["refresh"] = 3
    send(answer)


def page(run, key):
    send_blocks(run, key, *look(run, key))


def newest(store, parcels):
    """The tracked parcel on its way whose last event is newest, and that event's time; (None, None) without one."""
    best, at = None, None
    for p in parcels:
        when = when_last(store.tracking(p)) if not p.get("local") else None
        if when is not None and (at is None or when > at):
            best, at = p, when
    return best, at


def bar(run, key):
    """The menu bar item: 📦 and how many are on their way, with the newest event's status when TrackingMore tracks
    one; its dock faces say the same. Clicked, the page's blocks."""
    store, running = look(run, key)
    if run.get("surface") == "popover":
        send_blocks(run, key, store, running)
        return
    on_way, _ = grouped(store)
    count = len(on_way)
    faces = [{"label": "Parcels", "value": "%d on the way" % count if count else "None on the way", "symbol": "shippingbox"}]
    text = "📦 %d" % count if count else "📦"
    lead, _ = newest(store, on_way) if key else (None, None)
    if lead:
        tracking = store.tracking(lead)
        words_, _, tone = status_of(lead, tracking)
        event = last_event(tracking)
        text += " · " + words_
        faces.append({"label": fit(title(lead), FACE_LABEL), "symbol": "truck.box",
                      "value": fit(event.get("tracking_detail") if event else words_, FACE_VALUE)})
        if tone:
            faces[-1]["tone"] = tone
    loudest = max((status_of(p, store.tracking(p))[2] for p in on_way if tracked(p, key)), key=TONE_RANK.get, default=None)
    message = {"type": "bar", "text": text, "faces": faces, "blocks": view_blocks(run, key, store, running)}
    if loudest in ("warn", "alert"):
        message["tone"] = loudest
    send(message)


COMMANDS = {"packages": list_command, "page": page, "bar": bar, "add": add, "pick-carrier": pick_carrier,
            "parcel": parcel_detail, "remove": remove, "mark": mark, "refresh": refresh}


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
    key, why = api_key(run)
    run["keyProblem"] = why  # a key that cannot be sent: shown, and no TrackingMore call
    COMMANDS[command](run, key)


if __name__ == "__main__":
    main()
