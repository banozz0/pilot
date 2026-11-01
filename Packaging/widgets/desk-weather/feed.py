#!/usr/bin/env python3
"""Weather widget's feed (ADR 0016): reads Pilot's message on stdin, asks Open-Meteo (free, no key, CC BY 4.0) and prints
one {"type": "data", ...} line for the page. The city comes from the City setting, else the Mac's time zone
(/etc/localtime, Europe/Malta → Malta). The place is kept in TMPDIR, so a run is one request; the last forecast is kept
too and shown, marked stale, when the network fails. Pilot stops a run after 5 s, so each request waits 2 s at most."""
import hashlib
import json
import os
import sys
import time
import urllib.parse
import urllib.request

GEOCODING = "https://geocoding-api.open-meteo.com/v1/search"
FORECAST = "https://api.open-meteo.com/v1/forecast"
WAIT = 2.0
CACHE = os.path.join(os.environ.get("TMPDIR") or "/tmp", "pilot-desk-weather")


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


def get(url, query):
    request = urllib.request.Request(url + "?" + urllib.parse.urlencode(query), headers={"User-Agent": "Pilot desk widget"})
    with urllib.request.urlopen(request, timeout=WAIT) as response:
        return json.load(response)


def cached(name):
    try:
        with open(os.path.join(CACHE, name), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def keep(name, value):
    try:
        os.makedirs(CACHE, exist_ok=True)
        temp = os.path.join(CACHE, "%s.%d" % (name, os.getpid()))
        with open(temp, "w", encoding="utf-8") as f:
            json.dump(value, f)
        os.replace(temp, os.path.join(CACHE, name))
    except OSError:
        pass


def zone():
    target = os.path.realpath("/etc/localtime")
    return target.split("/zoneinfo/", 1)[1] if "/zoneinfo/" in target else None


def place(city):
    """The city's name and coordinates: the setting's, else the time zone's; None when neither finds one."""
    tz = zone()
    want = city.strip() or (tz.split("/")[-1].replace("_", " ") if tz else "")
    if not want:
        return None
    key = "place-" + hashlib.sha1(want.lower().encode()).hexdigest()[:12] + ".json"
    found = cached(key)
    if found:
        return found
    name, _, country = want.partition(",")
    results = get(GEOCODING, {"name": name.strip(), "count": 10, "language": "en", "format": "json"}).get("results") or []
    if country.strip():
        results = [r for r in results if country.strip().lower() in (r.get("country") or "").lower()] or results
    elif not city.strip() and tz:
        results = [r for r in results if r.get("timezone") == tz] or results
    if not results:
        return None
    r = results[0]
    found = {"name": r.get("name") or want, "latitude": r["latitude"], "longitude": r["longitude"]}
    keep(key, found)
    return found


def forecast(where, fahrenheit):
    query = {
        "latitude": where["latitude"], "longitude": where["longitude"], "timezone": "auto", "forecast_days": 6,
        "current": "temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m,is_day",
        "hourly": "temperature_2m,precipitation_probability,weather_code,is_day",
        "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max",
    }
    if fahrenheit:
        query.update({"temperature_unit": "fahrenheit", "wind_speed_unit": "mph"})
    return get(FORECAST, query)


def shaped(where, raw, fahrenheit):
    cur, hourly, daily = raw.get("current") or {}, raw.get("hourly") or {}, raw.get("daily") or {}
    now = (cur.get("time") or "")[:13]  # "2026-10-31T10"
    times = hourly.get("time") or []
    start = next((i for i, t in enumerate(times) if t[:13] >= now), 0)
    hours = []
    for i in range(start, min(start + 13, len(times))):
        hours.append({"hour": times[i][11:13], "temp": hourly["temperature_2m"][i],
                      "rain": (hourly.get("precipitation_probability") or [None] * len(times))[i],
                      "code": hourly["weather_code"][i], "day": bool(hourly["is_day"][i])})
    days = []
    for i, day in enumerate((daily.get("time") or [])[:6]):
        days.append({"date": day, "code": daily["weather_code"][i], "high": daily["temperature_2m_max"][i],
                     "low": daily["temperature_2m_min"][i], "rain": (daily.get("precipitation_probability_max") or [None] * 6)[i]})
    rain_now = hours[0]["rain"] if hours else None
    return {"place": where["name"], "unit": "°F" if fahrenheit else "°C", "wind": "mph" if fahrenheit else "km/h",
            "now": {"temp": cur.get("temperature_2m"), "feels": cur.get("apparent_temperature"), "code": cur.get("weather_code"),
                    "day": bool(cur.get("is_day", 1)), "humidity": cur.get("relative_humidity_2m"), "wind": cur.get("wind_speed_10m"),
                    "rain": rain_now},
            "hours": hours, "days": days, "updated": time.strftime("%H:%M"), "stale": False}


def main():
    try:
        message = json.loads(sys.stdin.readline() or "{}")
    except ValueError:
        message = {}
    settings = message.get("settings") or {}
    city = settings.get("city") if isinstance(settings.get("city"), str) else ""
    fahrenheit = settings.get("units") == "fahrenheit"
    last = "last-%s.json" % hashlib.sha1(("%s|%s" % (city.strip().lower(), fahrenheit)).encode()).hexdigest()[:12]
    try:
        where = place(city)
        if where is None:
            send({"type": "data", "data": {"problem": "No place called %s" % (city.strip() or "your time zone's city")}})
            return
        data = shaped(where, forecast(where, fahrenheit), fahrenheit)
        keep(last, data)
        send({"type": "data", "data": data})
    except Exception:  # the network or Open-Meteo: the last forecast, marked stale
        data = cached(last)
        if data:
            data["stale"] = True
            send({"type": "data", "data": data})
        else:
            send({"type": "data", "data": {"problem": "Open-Meteo did not answer"}})


if __name__ == "__main__":
    main()
