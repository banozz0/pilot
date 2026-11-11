#!/usr/bin/env python3
"""Weather for Pilot: the temperature now as a menu-bar item, a popover and a page with now, the next hours and the next
7 days (Surfaces v2, Pilot story 165), and a Weather view in Hyper+Space. A Pilot that draws hero and strip blocks (its
run message's `pilot.blocks` names them, Omarchy ideas T4) gets a big now over a strip of days instead of today's sections. Data from Open-Meteo (open-meteo.com, free,
no key, CC BY 4.0): its geocoding API turns the City preference into a place, its forecast API answers for that place.

Where: a place picked on the page, else the City preference, else the city of the Mac's time zone (/etc/localtime, e.g.
Europe/Malta → Malta), so no location permission is ever asked. A city is looked up once and kept (places.json). The
page's place box (Sven, 2026-10-31) searches Open-Meteo's geocoding as he types (`find-place`, its answer kept for the page
in found.json) and a row picks one (`pick-place`, kept in paths.data/picked.json with the City setting it was picked
under, so a later edit of that setting wins).

Every network call runs in a detached child (`main.py --refresh`, one at a time under refresh.lock) through curl
(macOS's own), so a slow network never holds a view past Pilot's limit: a view with an answer kept (forecast.json)
shows it at once, its time said, and asks again shortly; one with none waits for the child as long as its limit allows.
The answer is fresh for FRESH s; a failed fetch is not tried again for RETRY s, and offline the last answer shows with
when it was read.
"""
import fcntl
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import date
from urllib.parse import urlencode

FRESH = 15 * 60
RETRY = 60
CURL_TIMEOUT = 10
BUDGET = {"bar": 1.5, "popover": 3.5, "page": 3.5, "detail": 1.5}  # seconds a view waits for a fetch; Pilot's limits 2, 5, 5, 2
REFRESH_BUDGET = 25  # Refresh is a no-view run, stopped at 30 s
REFRESH_SOON = 3  # a view whose fetch still runs asks again this many seconds later
HOURS = {"popover": 6, "page": 24}
DAYS_SHOWN = {"popover": 5, "page": 7}  # the strip's days, today first
FORECAST = "forecast.json"
PLACES = "places.json"
LOCK = "refresh.lock"
PICKED = "picked.json"
FOUND = "found.json"
FOUND_FOR = 10 * 60  # seconds the page shows a place search
FOUND_ROWS = 8
GEOCODING = "https://geocoding-api.open-meteo.com/v1/search"
FORECAST_API = "https://api.open-meteo.com/v1/forecast"
CREDIT = "Weather data by [Open-Meteo.com](https://open-meteo.com/) (CC BY 4.0)"
# WMO weather codes as Open-Meteo gives them: words, the day's emoji, the night's.
CODES = {0: ("Clear", "☀️", "🌙"), 1: ("Mainly clear", "🌤️", "🌙"), 2: ("Partly cloudy", "⛅", "☁️"),
         3: ("Overcast", "☁️", "☁️"), 45: ("Fog", "🌫️", "🌫️"), 48: ("Freezing fog", "🌫️", "🌫️"),
         51: ("Light drizzle", "🌦️", "🌧️"), 53: ("Drizzle", "🌦️", "🌧️"), 55: ("Heavy drizzle", "🌧️", "🌧️"),
         56: ("Freezing drizzle", "🌧️", "🌧️"), 57: ("Freezing drizzle", "🌧️", "🌧️"),
         61: ("Light rain", "🌦️", "🌧️"), 63: ("Rain", "🌧️", "🌧️"), 65: ("Heavy rain", "🌧️", "🌧️"),
         66: ("Freezing rain", "🌧️", "🌧️"), 67: ("Freezing rain", "🌧️", "🌧️"),
         71: ("Light snow", "🌨️", "🌨️"), 73: ("Snow", "🌨️", "🌨️"), 75: ("Heavy snow", "❄️", "❄️"),
         77: ("Snow grains", "🌨️", "🌨️"), 80: ("Light showers", "🌦️", "🌧️"), 81: ("Showers", "🌧️", "🌧️"),
         82: ("Heavy showers", "🌧️", "🌧️"), 85: ("Snow showers", "🌨️", "🌨️"), 86: ("Snow showers", "🌨️", "🌨️"),
         95: ("Thunderstorm", "⛈️", "⛈️"), 96: ("Thunderstorm, hail", "⛈️", "⛈️"), 99: ("Thunderstorm, hail", "⛈️", "⛈️")}
# The same codes as Pilot's line icons (ADR 0010, amended 2026-10-25, Q475): the day's name, the night's. A hero's and a
# strip's glyph only, and only for a Pilot whose `pilot.icons` lists the name; any other gets the emoji.
LINES = {0: ("sun", "moon"), 1: ("cloud.sun", "cloud.moon"), 2: ("cloud.sun", "cloud.moon"), 3: ("cloud", "cloud"),
         45: ("cloud.fog", "cloud.fog"), 48: ("cloud.fog", "cloud.fog"),
         51: ("cloud.drizzle", "cloud.drizzle"), 53: ("cloud.drizzle", "cloud.drizzle"), 55: ("cloud.drizzle", "cloud.drizzle"),
         56: ("cloud.drizzle", "cloud.drizzle"), 57: ("cloud.drizzle", "cloud.drizzle"),
         61: ("cloud.rain", "cloud.rain"), 63: ("cloud.rain", "cloud.rain"), 65: ("cloud.rain", "cloud.rain"),
         66: ("cloud.rain", "cloud.rain"), 67: ("cloud.rain", "cloud.rain"), 80: ("cloud.rain", "cloud.rain"),
         81: ("cloud.rain", "cloud.rain"), 82: ("cloud.rain", "cloud.rain"),
         71: ("cloud.snow", "cloud.snow"), 73: ("cloud.snow", "cloud.snow"), 75: ("cloud.snow", "cloud.snow"),
         77: ("cloud.snow", "cloud.snow"), 85: ("cloud.snow", "cloud.snow"), 86: ("cloud.snow", "cloud.snow"),
         95: ("cloud.bolt", "cloud.bolt"), 96: ("cloud.bolt", "cloud.bolt"), 99: ("cloud.bolt", "cloud.bolt")}
WINDS = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


def load(folder, name):
    try:
        with open(os.path.join(folder, name), encoding="utf-8") as f:
            value = json.load(f)
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def save(folder, name, value):
    path = os.path.join(folder, name)
    temp = "%s.%d.tmp" % (path, os.getpid())
    with open(temp, "w", encoding="utf-8") as f:
        json.dump(value, f, ensure_ascii=False)
    os.replace(temp, path)


# ---- where and what ----

def mac_time_zone():
    """The Mac's time zone name (Europe/Malta), or None."""
    target = os.path.realpath("/etc/localtime")
    return target.split("/zoneinfo/", 1)[1] if "/zoneinfo/" in target else None


def settings(run):
    """{"city", "zone", "units", "place", "key"}: the place asked for (a city, else the Mac's time zone) and units; `place`
    names the place among those looked up, `key` the answer they need, so a changed preference never shows the old
    place's weather."""
    prefs = run.get("preferences") or {}
    city = " ".join(str(prefs.get("city") or "").split())
    units = "fahrenheit" if prefs.get("units") == "fahrenheit" else "celsius"
    chosen = picked(run, city)
    if chosen:
        place = "pick:%s,%s" % (chosen["latitude"], chosen["longitude"])
        return {"city": chosen["name"], "zone": None, "units": units, "place": place, "key": "%s|%s" % (place, units),
                "picked": chosen}
    zone = None if city else mac_time_zone()
    place = city.lower() or "zone:%s" % zone
    return {"city": city, "zone": zone, "units": units, "place": place, "key": "%s|%s" % (place, units)}


def data_dir(run):
    """Pilot's data folder for this extension (the cache's when it sends none), made on the first run."""
    paths = run.get("paths") or {}
    folder = paths.get("data") or paths.get("cache")
    if not isinstance(folder, str) or not folder:
        return None
    os.makedirs(folder, exist_ok=True)
    return folder


def place_of(value):
    """A place as picked: {"name", "country", "latitude", "longitude"}; None when it does not read."""
    if not isinstance(value, dict) or not isinstance(value.get("name"), str) or not value["name"].strip():
        return None
    lat, lon = value.get("latitude"), value.get("longitude")
    if not all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in (lat, lon)):
        return None
    return {"name": value["name"].strip(), "country": str(value.get("country") or ""), "latitude": lat, "longitude": lon}


def picked(run, city):
    """The place picked on the page while the City setting is still the one it was picked under; else None."""
    folder = data_dir(run)
    kept = load(folder, PICKED) if folder else {}
    return place_of(kept.get("place")) if kept.get("under") == city else None


def zone_city(zone):
    """The city a time zone is named after (Europe/Malta → Malta, America/New_York → New York); None for Etc/UTC."""
    if not zone or "/" not in zone or zone.startswith("Etc/"):
        return None
    return zone.rsplit("/", 1)[1].replace("_", " ")


def curl(url):
    """(parsed JSON, None) or (None, why)."""
    binary = shutil.which("curl") or "/usr/bin/curl"
    try:
        done = subprocess.run([binary, "-sS", "--fail", "--max-time", str(CURL_TIMEOUT), url], stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=CURL_TIMEOUT + 2)
    except (OSError, subprocess.TimeoutExpired):
        return None, "could not reach Open-Meteo"
    if done.returncode != 0:
        said = done.stderr.decode("utf-8", "replace").strip().splitlines()
        return None, (said[-1] if said else "Open-Meteo did not answer").replace("curl: ", "")[:160]
    try:
        return json.loads(done.stdout.decode("utf-8")), None
    except ValueError:
        return None, "Open-Meteo's answer did not read"


def find_place(want, folder):
    """The place `want` names, looked up once: {"name", "country", "latitude", "longitude"}, or (None, why). A city may
    carry its country or region after a comma; a time zone's city is the one in that time zone."""
    if want.get("picked"):
        return want["picked"], None
    places = load(folder, PLACES)
    if want["place"] in places:
        return places[want["place"]], None
    if want["city"]:
        name, _, rest = want["city"].partition(",")
        rest = rest.strip().lower()
    else:
        name, rest = zone_city(want["zone"]), ""
        if not name:
            return None, "no city: set one in Weather's settings"
    answer, error = curl(GEOCODING + "?" + urlencode({"name": name.strip(), "count": 10, "language": "en",
                                                      "format": "json"}))
    if error:
        return None, error
    found = [r for r in (answer or {}).get("results") or [] if isinstance(r, dict)
             and isinstance(r.get("latitude"), (int, float)) and isinstance(r.get("longitude"), (int, float))]
    if rest:
        found = [r for r in found if rest in (str(r.get("country", "")).lower(), str(r.get("country_code", "")).lower(),
                                              str(r.get("admin1", "")).lower())]
    elif want["zone"]:
        found = [r for r in found if r.get("timezone") == want["zone"]] or found
    if not found:
        return None, "Open-Meteo knows no place called %s" % (want["city"] or name)
    r = found[0]
    place = {"name": r.get("name") or name, "country": r.get("country") or "", "latitude": r["latitude"],
             "longitude": r["longitude"]}
    places[want["place"]] = place
    save(folder, PLACES, places)
    return place, None


def fetch(want, folder):
    """Asks Open-Meteo for `want`'s forecast and keeps it with when it was tried (forecast.json); a failure keeps the last
    answer and says why."""
    place, error = find_place(want, folder)
    if not error:
        fahrenheit = want["units"] == "fahrenheit"
        query = {"latitude": place["latitude"], "longitude": place["longitude"], "timezone": "auto", "forecast_days": 7,
                 "current": "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,"
                            "wind_direction_10m,is_day",
                 "hourly": "temperature_2m,weather_code,precipitation_probability,is_day",
                 "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max",
                 "temperature_unit": "fahrenheit" if fahrenheit else "celsius",
                 "wind_speed_unit": "mph" if fahrenheit else "kmh"}
        data, error = curl(FORECAST_API + "?" + urlencode(query))
        if not error and not isinstance((data or {}).get("current"), dict):
            error = "Open-Meteo sent no current weather"
    now = time.time()
    if error:
        record = dict(kept_for(folder, want), key=want["key"], triedAt=now, error=error)
    else:
        record = {"key": want["key"], "triedAt": now, "error": None, "fetchedAt": now, "place": place,
                  "units": want["units"], "data": data}
    save(folder, FORECAST, record)


def kept_for(folder, want):
    """The kept record for `want`'s place and units; empty when it is another's."""
    record = load(folder, FORECAST)
    return record if record.get("key") == want["key"] else {}


# ---- the refresh child ----

def locked(f):
    """Takes the refresh lock on the open file `f`; False when a refresh holds it."""
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False


def refreshing(folder):
    """True while a refresh holds the lock."""
    try:
        with open(os.path.join(folder, LOCK), "a") as f:
            return not locked(f)
    except OSError:
        return False


def refresh_main():
    """`main.py --refresh`: one fetch for the place on stdin, the refresh lock held through the file it was handed."""
    job = json.loads(sys.stdin.read())
    fetch(job["want"], job["cache"])


def start_refresh(folder, want):
    """Takes the refresh lock and hands it to a detached child that fetches, so the lock is held from before it starts
    until it ends; None when a refresh runs already or the child could not start."""
    try:
        lock = open(os.path.join(folder, LOCK), "a")
    except OSError:
        return None
    with lock:
        if not locked(lock):
            return None
        try:
            child = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--refresh"], stdin=subprocess.PIPE,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, pass_fds=(lock.fileno(),),
                                     start_new_session=True, cwd=os.path.dirname(os.path.abspath(__file__)))
            child.stdin.write(json.dumps({"cache": folder, "want": want}).encode())
            child.stdin.close()
        except OSError:
            return None
    return child


def cache_dir(run):
    """Pilot's cache folder for this extension, which it makes on the first run."""
    folder = (run.get("paths") or {}).get("cache")
    if not isinstance(folder, str) or not folder:
        send({"type": "error", "text": "Pilot sent no cache folder"})
        sys.exit(0)
    os.makedirs(folder, exist_ok=True)
    return folder


def forecast(run, budget, force=False):
    """(the kept answer for the place asked, or None; the last try's error, or None; True while a fetch still runs).
    A stale or missing answer, or `force`, starts a fetch (not within RETRY s of a failed one, unless `force`). A view
    with an answer to show shows it at once; one with none, or `force`, waits for the fetch `budget` s at most."""
    started = time.monotonic()
    folder = cache_dir(run)
    want = settings(run)
    record = kept_for(folder, want)
    now = time.time()
    stale = "data" not in record or now - (record.get("fetchedAt") or 0) >= FRESH
    recently_failed = record.get("error") and now - (record.get("triedAt") or 0) < RETRY
    waits = force or "data" not in record
    child = start_refresh(folder, want) if force or (stale and not recently_failed) else None
    if child and waits:
        try:
            child.wait(max(0.1, budget - (time.monotonic() - started)))
        except subprocess.TimeoutExpired:
            pass
    running = refreshing(folder)  # this child, or another view's
    if waits:
        while running and time.monotonic() - started < budget:
            time.sleep(0.1)
            running = refreshing(folder)
        record = kept_for(folder, want)
    return (record if "data" in record else None), record.get("error"), running


# ---- words ----

def degrees(value):
    return "%d°" % round(value) if isinstance(value, (int, float)) else "–"


def percent(value):
    return "%d%%" % value if isinstance(value, (int, float)) else "–"


def condition(code, day=True):
    words, sun, moon = CODES.get(code, ("Unknown", "🌡️", "🌡️"))
    return words, sun if day else moon


def glyph(code, day, icons):
    """A hero's or a strip's glyph: the line icon's name where Pilot draws it (`icons`, from `pilot.icons`), else the emoji."""
    name = LINES.get(code, (None, None))[0 if day else 1]
    return name if name in icons else condition(code, day)[1]


def wind(speed, direction, units):
    if not isinstance(speed, (int, float)):
        return "–"
    words = "%d %s" % (round(speed), "mph" if units == "fahrenheit" else "km/h")
    if isinstance(direction, (int, float)):
        words += " " + WINDS[int((direction % 360 + 22.5) // 45) % 8]
    return words


def clock(stamp):
    """14:05 when today, else Mon 14:05."""
    moment = time.localtime(stamp)
    if time.strftime("%Y-%m-%d", moment) == time.strftime("%Y-%m-%d"):
        return time.strftime("%H:%M", moment)
    return "%s %s" % (DAYS[moment.tm_wday], time.strftime("%H:%M", moment))


def at(series, key, i):
    values = series.get(key) or []
    return values[i] if 0 <= i < len(values) else None


class Weather:
    """One kept answer, read for a view."""

    def __init__(self, kept):
        data = kept["data"]
        self.place, self.units, self.fetched = kept["place"], kept["units"], kept["fetchedAt"]
        self.now = data.get("current") or {}
        self.hourly = data.get("hourly") or {}
        self.daily = data.get("daily") or {}
        stamp = str(self.now.get("time") or "")
        times = self.hourly.get("time") or []
        hour = stamp[:13] + ":00"
        self.this_hour = times.index(hour) if hour in times else -1
        self.next_hour = next((i for i, t in enumerate(times) if t > stamp), len(times))
        self.today = stamp[:10]

    @property
    def where(self):
        return ", ".join(p for p in (self.place.get("name"), self.place.get("country")) if p)

    def condition(self):
        return condition(self.now.get("weather_code"), self.now.get("is_day", 1) == 1)

    def bar_text(self):
        return "%s %s" % (self.condition()[1], degrees(self.now.get("temperature_2m")))

    def rain_now(self):
        return percent(at(self.hourly, "precipitation_probability", self.this_hour))

    def high_low(self, i=0):
        return "%s / %s" % (degrees(at(self.daily, "temperature_2m_max", i)), degrees(at(self.daily, "temperature_2m_min", i)))

    def now_stats(self):
        emoji = self.condition()[1]
        return [{"label": "Now", "value": "%s %s" % (emoji, degrees(self.now.get("temperature_2m")))},
                {"label": "Feels like", "value": degrees(self.now.get("apparent_temperature"))},
                {"label": "High / low", "value": self.high_low()},
                {"label": "Rain", "value": self.rain_now()},
                {"label": "Wind", "value": wind(self.now.get("wind_speed_10m"), self.now.get("wind_direction_10m"), self.units)}]

    def hours(self, count):
        """[(time, emoji, temperature, words, rain chance)] for the next `count` hours."""
        found = []
        for i in range(self.next_hour, min(self.next_hour + count, len(self.hourly.get("time") or []))):
            words, emoji = condition(at(self.hourly, "weather_code", i), at(self.hourly, "is_day", i) != 0)
            found.append((self.hourly["time"][i][11:16], emoji, degrees(at(self.hourly, "temperature_2m", i)), words,
                          percent(at(self.hourly, "precipitation_probability", i))))
        return found

    def days(self):
        """[(name, emoji, high / low, words, rain chance)] for each day given, today first."""
        found = []
        for i, day in enumerate(self.daily.get("time") or []):
            words, emoji = condition(at(self.daily, "weather_code", i))
            try:
                name = "Today" if day == self.today else DAYS[date(*map(int, day.split("-"))).weekday()]
            except (TypeError, ValueError):
                name = day
            found.append((name, emoji, self.high_low(i), words, percent(at(self.daily, "precipitation_probability_max", i))))
        return found

    def hero(self, error, icons=()):
        """The big now: the sky's line icon or emoji, the temperature, where and what, then feels like, wind and humidity."""
        words = self.condition()[0]
        hero = {"type": "hero", "glyph": glyph(self.now.get("weather_code"), self.now.get("is_day", 1) == 1, icons), "value": degrees(self.now.get("temperature_2m")).rstrip("°"),
                "unit": "°F" if self.units == "fahrenheit" else "°C", "place": "%s · %s" % (self.place.get("name"), words),
                "items": [{"label": "Feels like", "value": degrees(self.now.get("apparent_temperature"))},
                          {"label": "Wind", "value": wind(self.now.get("wind_speed_10m"), self.now.get("wind_direction_10m"),
                                                          self.units)},
                          {"label": "Humidity", "value": percent(self.now.get("relative_humidity_2m"))}]}
        if error:
            hero["tone"] = "warn"
        return hero

    def strip(self, count, icons=()):
        """The next `count` days side by side, today first: each its line icon or emoji, high and low."""
        return [{"label": name, "glyph": glyph(at(self.daily, "weather_code", i), True, icons),
                 "high": degrees(at(self.daily, "temperature_2m_max", i)), "low": degrees(at(self.daily, "temperature_2m_min", i))}
                for i, (name, _, _, _, _) in enumerate(self.days()[:count])]

    def summary(self):
        return "%s: %s, %s" % (self.place.get("name"), degrees(self.now.get("temperature_2m")), self.condition()[0].lower())


def read_line(weather, error):
    """When the answer was read, and that it is old when the last fetch failed."""
    if error:
        return "Offline · from %s" % clock(weather.fetched)
    return "Updated %s · Open-Meteo" % clock(weather.fetched)


def problem(error, running):
    if running:
        return "Asking Open-Meteo…"
    return "No weather yet: %s." % (error or "Open-Meteo did not answer")


# ---- views ----

def draws_hero(run):
    """Whether this Pilot draws hero and strip blocks: its run message's `pilot.blocks` names them; an older Pilot names
    none, and gets today's sections."""
    pilot = run.get("pilot")
    listed = [k.strip() for k in str(pilot.get("blocks") or "").split(",")] if isinstance(pilot, dict) else []
    return "hero" in listed and "strip" in listed


def drawn_icons(run):
    """The icon names this Pilot draws: its run message's `pilot.icons`; an older Pilot names none, and gets emoji."""
    pilot = run.get("pilot")
    return {k.strip() for k in str(pilot.get("icons") or "").split(",")} if isinstance(pilot, dict) else set()


def hour_list(upcoming):
    """The next hours as list rows: time and temperature, the sky and the rain chance."""
    return {"type": "list", "items": [{"title": "%s · %s" % (t, d), "subtitle": "%s · rain %s" % (w, r), "icon": e}
                                      for t, e, d, w, r in upcoming]}


def blocks(weather, error, hours):
    """Now, the next `hours` hours, the next 7 days."""
    words = weather.condition()[0]
    found = [{"type": "section", "title": "Now in %s" % weather.place.get("name"),
              "subtitle": "%s · %s" % (words, read_line(weather, error)),
              "blocks": [{"type": "stats", "items": weather.now_stats()}]}]
    upcoming = weather.hours(hours)
    if hours <= 6:
        hour_blocks = [{"type": "stats", "items": [{"label": t, "value": "%s %s" % (e, d)} for t, e, d, _, _ in upcoming]}]
    else:
        hour_blocks = [hour_list(upcoming)]
    if upcoming:
        found.append({"type": "section", "title": "Next hours", "blocks": hour_blocks})
    days = weather.days()
    if days:
        found.append({"type": "section", "title": "Next 7 days", "blocks": [{"type": "list", "items": [
            {"title": "%s · %s" % (n, hl), "subtitle": "%s · rain %s" % (w, r), "icon": e} for n, e, hl, w, r in days]}]})
    return found


def refresh_button():
    return {"type": "run", "command": "refresh", "title": "Refresh", "icon": "refresh"}


def view_blocks(run, weather, error, view):
    """A view's blocks where Pilot draws a hero and a strip: the big now over the next days, offline when it was read, and
    on a page the next hours; else today's sections."""
    if not draws_hero(run):
        return blocks(weather, error, HOURS[view])
    icons = drawn_icons(run)
    found = [weather.hero(error, icons)]
    strip = weather.strip(DAYS_SHOWN[view], icons)
    if strip:
        found.append({"type": "strip", "items": strip})
    if error:
        found.append({"type": "markdown", "text": read_line(weather, error)})
    upcoming = weather.hours(HOURS[view]) if view == "page" else []
    if upcoming:
        found.append({"type": "section", "title": "Next hours", "blocks": [hour_list(upcoming)]})
    return found


def place_block(run, kept):
    """The page's place (Sven, 2026-10-31): where it shows and from what, a box that searches a city as Sven types, its
    answers a row each that picks it, and Back to the City setting while a pick holds."""
    want = settings(run)
    where = Weather(kept).where if kept else want["city"] or zone_city(want["zone"]) or "–"
    source = "picked here" if want.get("picked") else "from Settings" if want["city"] else "your Mac's time zone"
    inner = [{"type": "input", "placeholder": "Search a city: Valletta, Paris, Tokyo…", "live": True, "debounce": 400,
              "action": {"type": "run", "command": "find-place", "title": "Search"}}]
    folder = data_dir(run)
    held = load(folder, FOUND) if folder else {}
    if held.get("query") and time.time() - (held.get("at") or 0) < FOUND_FOR:
        rows = [{"id": "place:%d" % i, "title": r["name"],
                 "subtitle": " · ".join(p for p in (r.get("admin1"), r.get("country")) if p), "icon": "📍",
                 "actions": [{"type": "run", "command": "pick-place", "title": "Use %s" % r["name"],
                              "context": {"place": place_of(r)}}]}
                for i, r in enumerate(held.get("results") or []) if place_of(r)][:FOUND_ROWS]
        if not rows:
            rows = [{"id": "place:none", "title": held.get("error") or "Open-Meteo knows no place called %s" % held["query"],
                     "icon": "⚠️" if held.get("error") else "🔎"}]
        inner.append({"type": "list", "items": rows})
    if want.get("picked"):
        inner.append({"type": "buttons", "actions": [{"type": "run", "command": "pick-place", "title": "Use the City setting",
                                                      "context": {"clear": True}}]})
    return {"type": "section", "title": "Place", "subtitle": "%s · %s" % (where, source), "blocks": inner}


def answer_blocks(run, kept, error, running, view):
    page = view == "page"
    if not kept:
        found = [{"type": "markdown", "text": problem(error, running)}]
    else:
        found = view_blocks(run, Weather(kept), error, view)
    if page:
        found += [place_block(run, kept), {"type": "buttons", "actions": [refresh_button()]},
                  {"type": "markdown", "text": CREDIT}]
    message = {"type": "blocks", "blocks": found}
    if running:
        message["refresh"] = REFRESH_SOON
    send(message)


def bar(run):
    popover = run.get("surface") == "popover"
    kept, error, running = forecast(run, BUDGET["popover" if popover else "bar"])
    if popover:
        answer_blocks(run, kept, error, running, "popover")
    elif not kept:
        send({"type": "bar", "text": "🌡️ –", "tone": "warn", "blocks": [{"type": "markdown", "text": problem(error, running)}]})
    else:
        weather = Weather(kept)
        message = {"type": "bar", "text": weather.bar_text(), "blocks": view_blocks(run, weather, error, "popover")}
        if error:
            message["tone"] = "warn"
        send(message)


def page(run):
    kept, error, running = forecast(run, BUDGET["page"])
    answer_blocks(run, kept, error, running, "page")


def detail(run):
    """Hyper+Space's Weather: now, the next hours, the week, as one markdown view."""
    kept, error, running = forecast(run, BUDGET["detail"])
    refresh = dict(refresh_button(), title="Refresh the weather")
    if not kept:
        send({"type": "detail", "markdown": problem(error, running), "actions": [refresh]})
        return
    weather = Weather(kept)
    words, emoji = weather.condition()
    lines = ["# %s %s %s" % (emoji, degrees(weather.now.get("temperature_2m")), words), "",
             "**Next hours** " + " · ".join("%s %s %s" % (t, e, d) for t, e, d, _, _ in weather.hours(6)), "",
             "**Next 7 days**", ""]
    lines += ["- %s %s %s, %s, rain %s" % (n, e, hl, w.lower(), r) for n, e, hl, w, r in weather.days()]
    lines += ["", CREDIT]
    metadata = [{"label": "Place", "text": weather.where}, {"label": "Updated", "text": read_line(weather, error)}]
    metadata += [{"label": s["label"], "text": s["value"]} for s in weather.now_stats()[1:]]
    send({"type": "detail", "markdown": "\n".join(lines), "metadata": metadata,
          "actions": [refresh, {"type": "copy", "text": weather.summary(), "title": "Copy the weather"}]})


def refresh(run):
    kept, error, running = forecast(run, REFRESH_BUDGET, force=True)
    if running or error or not kept:
        send({"type": "error", "text": "could not refresh: %s" % (error or "Open-Meteo did not answer in time")})
        return
    send({"type": "hud", "text": "Weather: %s" % Weather(kept).summary()})


def find_place_command(run):
    """The page's place box: Open-Meteo's places for the words typed, kept for the page to draw; an emptied box closes the
    search."""
    folder = data_dir(run)
    text = " ".join(str(run.get("input") or "").split())[:100]
    if not text:
        try:
            os.remove(os.path.join(folder, FOUND))
        except OSError:
            pass
        return
    answer, error = curl(GEOCODING + "?" + urlencode({"name": text, "count": FOUND_ROWS, "language": "en", "format": "json"}))
    results = [{k: r.get(k) for k in ("name", "admin1", "country", "latitude", "longitude")}
               for r in (answer or {}).get("results") or [] if isinstance(r, dict) and place_of(r)]
    save(folder, FOUND, {"query": text, "at": time.time(), "results": results, "error": error})
    if error:
        send({"type": "error", "text": error})


def pick_place(run):
    """A place row's pick, kept with the City setting it was picked under; Use the City setting forgets it."""
    folder = data_dir(run)
    context = run.get("context") if isinstance(run.get("context"), dict) else {}
    city = " ".join(str((run.get("preferences") or {}).get("city") or "").split())
    for name in (FOUND,) + ((PICKED,) if context.get("clear") else ()):
        try:
            os.remove(os.path.join(folder, name))
        except OSError:
            pass
    if context.get("clear"):
        send({"type": "hud", "text": "Weather: back to %s" % (city or "your Mac's time zone")})
        return
    place = place_of(context.get("place"))
    if not place:
        send({"type": "error", "text": "got no place to use"})
        return
    save(folder, PICKED, {"under": city, "place": place})
    send({"type": "hud", "text": "Weather: %s" % ", ".join(p for p in (place["name"], place["country"]) if p)})


def main():
    if sys.argv[1:] == ["--refresh"]:
        refresh_main()
        return
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        send({"type": "error", "text": "got a run message it could not read"})
        return
    command = run.get("command")
    if command == "weather":
        detail(run)
    elif command == "bar":
        bar(run)
    elif command == "page":
        page(run)
    elif command == "refresh":
        refresh(run)
    elif command == "find-place":
        find_place_command(run)
    elif command == "pick-place":
        pick_place(run)
    else:
        send({"type": "error", "text": "has no command %s" % command})


if __name__ == "__main__":
    main()
