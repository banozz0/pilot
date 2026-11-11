import fcntl
import json
import os
import time
import unittest
from urllib.parse import parse_qs, urlsplit

from harness import ExtensionTestCase

ZONE = os.path.realpath("/etc/localtime").split("/zoneinfo/", 1)[-1]
PLACES = {"results": [
    {"name": "Valletta", "latitude": 35.899, "longitude": 14.514, "country": "Malta", "country_code": "MT",
     "admin1": "Valletta", "timezone": "Europe/Malta"},
    {"name": "Paris", "latitude": 33.66, "longitude": -95.55, "country": "United States", "country_code": "US",
     "admin1": "Texas", "timezone": "America/Chicago"},
    {"name": "Paris", "latitude": 48.853, "longitude": 2.349, "country": "France", "country_code": "FR",
     "admin1": "Île-de-France", "timezone": "Europe/Paris"},
    {"name": "Home town", "latitude": 1.5, "longitude": 2.5, "country": "Here", "country_code": "HH", "timezone": ZONE}]}


def forecast(is_day=1):
    """Open-Meteo's answer as its API gives it: 14:15 on Saturday 10 October 2026, 72 hours and 7 days."""
    hours = ["2026-10-%02dT%02d:00" % (10 + i // 24, i % 24) for i in range(72)]
    return {"latitude": 35.9, "longitude": 14.5, "utc_offset_seconds": 7200, "timezone": "Europe/Malta",
            "current": {"time": "2026-10-10T14:15", "interval": 900, "temperature_2m": 23.6, "apparent_temperature": 25.8,
                        "relative_humidity_2m": 61, "weather_code": 0, "wind_speed_10m": 15.2, "wind_direction_10m": 45, "is_day": is_day},
            "hourly": {"time": hours, "temperature_2m": [20 + i % 5 for i in range(72)],
                       "weather_code": [61 if i == 16 else 1 for i in range(72)],
                       "precipitation_probability": [10 if i == 14 else 40 for i in range(72)],
                       "is_day": [1 if 7 <= i % 24 <= 18 else 0 for i in range(72)]},
            "daily": {"time": ["2026-10-%02d" % d for d in range(10, 17)], "weather_code": [0, 63, 3, 3, 95, 1, 2],
                      "temperature_2m_max": [27.4, 22, 21, 23, 24, 25, 26], "temperature_2m_min": [19.1, 17, 16, 16, 18, 18, 19],
                      "precipitation_probability_max": [10, 80, 20, 5, 90, 0, 0]}}


class WeatherTests(ExtensionTestCase):
    EXTENSION = "weather"

    def setUp(self):
        super().setUp()
        self.addCleanup(self.settle)
        self.fake_curl()

    def fake_curl(self, fail=None, delay=0, is_day=1, places=PLACES):
        """A curl that logs its URL and answers from the fixtures, or fails as curl does, or answers the forecast `delay` s
        late."""
        (self.box.root / "places.json").write_text(json.dumps(places))
        (self.box.root / "forecast.json").write_text(json.dumps(forecast(is_day)))
        url = '"$url"'
        body = 'for url; do :; done\nprintf "%%s\\n" %s >> "%s"\n' % (url, self.box.log)  # the URL is the last argument
        if delay:
            body += 'case %s in *geocoding*) ;; *) sleep %s;; esac\n' % (url, delay)
        if fail:
            body += 'echo "curl: %s" >&2; exit 6' % fail
        else:
            body += 'case %s in *geocoding*) cat "%s";; *) cat "%s";; esac' % (
                url, self.box.root / "places.json", self.box.root / "forecast.json")
        self.box.shim("curl", body)

    def calls(self):
        return [(urlsplit(u).netloc, {k: v[0] for k, v in parse_qs(urlsplit(u).query).items()}) for u in self.box.shim_calls()]

    def settle(self):
        """Waits out a refresh a view left running, so it lands before the next look and never in a removed sandbox."""
        lock = self.box.cache / "refresh.lock"
        if lock.exists():
            with open(str(lock), "a") as f:
                fcntl.flock(f, fcntl.LOCK_EX)

    def kept(self):
        return json.loads((self.box.cache / "forecast.json").read_text())

    def stats(self, block):
        return {s["label"]: s["value"] for s in block["items"]}

    def sections(self, blocks):
        return {b["title"]: b for b in blocks if b["type"] == "section"}

    VALLETTA = {"city": "Valletta"}
    # Pilot's defaults as a Pilot that draws hero and strip sends them (Pilot fd3da77a, Omarchy ideas Q100), and an older one's.
    PILOT = {"repos": "/tmp/code", "terminal": "com.mitchellh.ghostty",
             "blocks": "stats,meter,list,markdown,buttons,section,chat,input,hero,strip"}
    OLDER = {"repos": "/tmp/code", "terminal": "com.mitchellh.ghostty"}
    # A Pilot that draws line icons by name (ADR 0010, amended 2026-10-25, Q475).
    LINED = dict(PILOT, icons="bubble,cloud,cloud.bolt,cloud.drizzle,cloud.fog,cloud.moon,cloud.rain,cloud.snow,cloud.sun,moon,sun,wind")

    # ---- the bar and the cache ----

    def test_bar_shows_the_temperature_and_asks_open_meteo_once_in_15_minutes(self):
        line = self.bar(preferences=self.VALLETTA)
        self.assertEqual(line["text"], "☀️ 24°")
        self.assertNotIn("tone", line)
        [(geo_host, geo), (host, query)] = self.calls()
        self.assertEqual((geo_host, geo["name"]), ("geocoding-api.open-meteo.com", "Valletta"))
        self.assertEqual(host, "api.open-meteo.com")
        self.assertEqual((query["latitude"], query["longitude"], query["temperature_unit"], query["wind_speed_unit"]),
                         ("35.899", "14.514", "celsius", "kmh"))
        self.assertEqual(self.bar(preferences=self.VALLETTA)["text"], "☀️ 24°")
        self.assertEqual(len(self.calls()), 2, "a fresh answer is not asked again")

    def test_a_stale_answer_is_asked_again_without_looking_the_city_up_again(self):
        self.bar(preferences=self.VALLETTA)
        kept = self.kept()
        kept["fetchedAt"] -= 16 * 60
        (self.box.cache / "forecast.json").write_text(json.dumps(kept))
        self.assertEqual(self.blocks_message("bar", "popover", preferences=self.VALLETTA)["refresh"], 3,
                         "the kept answer shows at once and the popover asks again while the fetch runs")
        self.settle()
        self.assertEqual([host for host, _ in self.calls()],
                         ["geocoding-api.open-meteo.com", "api.open-meteo.com", "api.open-meteo.com"])

    def test_offline_shows_the_last_answer_with_its_time_and_waits_a_minute_to_retry(self):
        self.bar(preferences=self.VALLETTA)
        kept = self.kept()
        kept["fetchedAt"] -= 3600
        (self.box.cache / "forecast.json").write_text(json.dumps(kept))
        self.fake_curl(fail="(6) Could not resolve host: api.open-meteo.com")
        self.assertNotIn("tone", self.bar(preferences=self.VALLETTA), "not known to be offline until the fetch ends")
        self.settle()
        line = self.bar(preferences=self.VALLETTA)
        self.assertEqual((line["text"], line["tone"]), ("☀️ 24°", "warn"))
        now = self.sections(self.popover(preferences=self.VALLETTA))["Now in Valletta"]
        self.assertIn("Offline · from ", now["subtitle"])
        self.assertEqual(len(self.calls()), 3, "one failed try, then none for a minute")

    def test_offline_with_nothing_kept_says_why(self):
        self.fake_curl(fail="(6) Could not resolve host: geocoding-api.open-meteo.com")
        line = self.bar(preferences=self.VALLETTA)
        self.assertEqual((line["text"], line["tone"]), ("🌡️ –", "warn"))
        self.assertEqual(line["blocks"][0]["text"], "No weather yet: (6) Could not resolve host: geocoding-api.open-meteo.com.")

    def test_a_slow_network_never_holds_the_bar_past_its_limit_and_the_answer_lands_later(self):
        self.fake_curl(delay=1.8)
        line = self.bar(preferences=self.VALLETTA)
        self.assertEqual(line["text"], "🌡️ –")
        self.assertEqual(line["blocks"][0]["text"], "Asking Open-Meteo…")
        message = self.blocks_message("bar", "popover", preferences=self.VALLETTA)
        self.assertIn("Now in Valletta", self.sections(message["blocks"]), "the popover waits longer and gets it")
        self.assertNotIn("refresh", message)
        self.assertEqual(self.bar(preferences=self.VALLETTA)["text"], "☀️ 24°")
        self.assertEqual(len(self.calls()), 2, "one fetch served both")

    # ---- views ----

    def test_popover_has_now_six_hours_and_seven_days(self):
        blocks = self.popover(preferences=self.VALLETTA)
        found = self.sections(blocks)
        self.assertEqual(list(found), ["Now in Valletta", "Next hours", "Next 7 days"])
        self.assertTrue(found["Now in Valletta"]["subtitle"].startswith("Clear · Updated "))
        self.assertEqual(self.stats(found["Now in Valletta"]["blocks"][0]),
                         {"Now": "☀️ 24°", "Feels like": "26°", "High / low": "27° / 19°", "Rain": "10%",
                          "Wind": "15 km/h NE"})
        hours = found["Next hours"]["blocks"][0]["items"]
        self.assertEqual([h["label"] for h in hours], ["15:00", "16:00", "17:00", "18:00", "19:00", "20:00"])
        self.assertEqual(hours[1]["value"], "🌦️ 21°", "light rain")
        self.assertEqual(hours[4]["value"], "🌙 24°", "after dark a clear hour shows the moon")
        days = found["Next 7 days"]["blocks"][0]["items"]
        self.assertEqual(len(days), 7)
        self.assertEqual((days[0]["title"], days[0]["subtitle"], days[0]["icon"]), ("Today · 27° / 19°", "Clear · rain 10%", "☀️"))
        self.assertEqual(days[1]["title"], "Sun · 22° / 17°")

    def test_page_lists_24_hours_with_refresh_and_the_credit(self):
        blocks = self.page(preferences=self.VALLETTA)
        hours = self.sections(blocks)["Next hours"]["blocks"][0]["items"]
        self.assertEqual(len(hours), 24)
        self.assertEqual((hours[0]["title"], hours[0]["subtitle"]), ("15:00 · 20°", "Mainly clear · rain 40%"))
        self.assertEqual(blocks[-2]["actions"][0]["command"], "refresh")
        self.assertIn("Open-Meteo.com", blocks[-1]["text"])

    # ---- the glance: hero and strip where Pilot draws them ----

    def test_popover_leads_with_a_big_now_over_five_days_when_pilot_draws_them(self):
        hero, strip = self.popover(preferences=self.VALLETTA, pilot=self.PILOT)
        self.assertEqual(hero, {"type": "hero", "glyph": "☀️", "value": "24", "unit": "°C", "place": "Valletta · Clear",
                                "items": [{"label": "Feels like", "value": "26°"}, {"label": "Wind", "value": "15 km/h NE"},
                                          {"label": "Humidity", "value": "61%"}]})
        self.assertEqual(strip["type"], "strip")
        self.assertEqual([(c["label"], c["glyph"], c["high"], c["low"]) for c in strip["items"]],
                         [("Today", "☀️", "27°", "19°"), ("Sun", "🌧️", "22°", "17°"), ("Mon", "☁️", "21°", "16°"),
                          ("Tue", "☁️", "23°", "16°"), ("Wed", "⛈️", "24°", "18°")])
        self.assertIn("relative_humidity_2m", self.calls()[-1][1]["current"])

    def test_a_pilot_that_draws_line_icons_gets_their_names_in_the_hero_and_strip_only(self):
        hero, strip = self.popover(preferences=self.VALLETTA, pilot=self.LINED)
        self.assertEqual(hero["glyph"], "sun")
        self.assertEqual([c["glyph"] for c in strip["items"]], ["sun", "cloud.rain", "cloud", "cloud", "cloud.bolt"])
        line = self.bar(preferences=self.VALLETTA, pilot=self.LINED)
        self.assertEqual(line["text"], "☀️ 24°", "the bar's text keeps its emoji")
        page = self.page(preferences=self.VALLETTA, pilot=self.LINED)
        names = set(self.LINED["icons"].split(","))
        self.assertFalse({row["icon"] for row in page[2]["blocks"][0]["items"]} & names, "list rows keep emoji")
        # A Pilot listing only some names gets the emoji for the rest.
        hero, strip = self.popover(preferences=self.VALLETTA, pilot=dict(self.PILOT, icons="sun,moon"))
        self.assertEqual([c["glyph"] for c in strip["items"]], ["sun", "🌧️", "☁️", "☁️", "⛈️"])

    def test_the_bar_keeps_its_text_and_carries_the_glance(self):
        line = self.bar(preferences=self.VALLETTA, pilot=dict(self.PILOT, blocks="stats, hero, strip"))
        self.assertEqual(line["text"], "☀️ 24°")
        self.assertBlocksShape(line["blocks"])
        self.assertEqual([b["type"] for b in line["blocks"]], ["hero", "strip"])

    def test_page_shows_the_glance_over_seven_days_then_24_hours_refresh_and_the_credit(self):
        blocks = self.page(preferences=self.VALLETTA, pilot=self.PILOT)
        self.assertEqual([b["type"] for b in blocks], ["hero", "strip", "section", "section", "buttons", "markdown"])
        self.assertEqual(len(blocks[1]["items"]), 7)
        self.assertEqual(len(blocks[2]["blocks"][0]["items"]), 24)
        self.assertEqual(blocks[3]["title"], "Place")
        self.assertEqual(blocks[4]["actions"][0]["command"], "refresh")
        self.assertIn("Open-Meteo.com", blocks[5]["text"])

    def test_an_older_pilot_gets_todays_sections(self):
        for pilot in (None, self.OLDER, dict(self.OLDER, blocks="stats,meter,hero"), "hero,strip"):
            with self.subTest(pilot=pilot):
                found = self.sections(self.popover(preferences=self.VALLETTA, pilot=pilot))
                self.assertEqual(list(found), ["Now in Valletta", "Next hours", "Next 7 days"])
        line = self.bar(preferences=self.VALLETTA, pilot=self.OLDER)
        self.assertEqual([b["type"] for b in line["blocks"]], ["section", "section", "section"])

    def test_offline_the_glance_warns_and_says_when_it_was_read(self):
        self.bar(preferences=self.VALLETTA)
        kept = self.kept()
        kept["fetchedAt"] -= 3600
        (self.box.cache / "forecast.json").write_text(json.dumps(kept))
        self.fake_curl(fail="(6) Could not resolve host: api.open-meteo.com")
        self.bar(preferences=self.VALLETTA)
        self.settle()
        hero, _, note = self.popover(preferences=self.VALLETTA, pilot=self.PILOT)
        self.assertEqual(hero["tone"], "warn")
        self.assertTrue(note["text"].startswith("Offline · from "), note)

    def test_fahrenheit_glance_says_f_and_mph(self):
        hero = self.popover(preferences=dict(self.VALLETTA, units="fahrenheit"), pilot=self.PILOT)[0]
        self.assertEqual((hero["unit"], hero["items"][1]["value"]), ("°F", "15 mph NE"))

    def test_night_shows_the_moon_now(self):
        self.fake_curl(is_day=0)
        self.assertEqual(self.bar(preferences=self.VALLETTA)["text"], "🌙 24°")

    def test_weather_view_in_hyper_space(self):
        r = self.run_ext("weather", preferences=self.VALLETTA)
        d = r.detail
        self.assertTrue(d["markdown"].startswith("# ☀️ 24° Clear\n"))
        self.assertIn("- Sun 🌧️ 22° / 17°, rain, rain 80%", d["markdown"])
        meta = {m["label"]: m["text"] for m in d["metadata"]}
        self.assertEqual((meta["Place"], meta["Wind"]), ("Valletta, Malta", "15 km/h NE"))
        for action in d["actions"]:
            self.assertActionShape(action)
        self.assertEqual(d["actions"][1], {"type": "copy", "text": "Valletta: 24°, clear", "title": "Copy the weather"})

    def test_refresh_asks_again_even_when_fresh(self):
        self.bar(preferences=self.VALLETTA)
        r = self.run_ext("refresh", preferences=self.VALLETTA)
        self.assertEqual(r.of_type("hud")[0]["text"], "Weather: Valletta: 24°, clear")
        self.assertEqual(len(self.calls()), 3)

    def test_refresh_offline_is_an_error(self):
        self.fake_curl(fail="(6) Could not resolve host: geocoding-api.open-meteo.com")
        r = self.run_ext("refresh", preferences=self.VALLETTA)
        self.assertEqual(r.of_type("error")[0]["text"], "could not refresh: (6) Could not resolve host: geocoding-api.open-meteo.com")

    # ---- where and units ----

    def test_fahrenheit_asks_in_fahrenheit_and_mph_and_does_not_reuse_the_celsius_answer(self):
        self.bar(preferences=self.VALLETTA)
        self.popover(preferences=dict(self.VALLETTA, units="fahrenheit"))
        _, query = self.calls()[-1]
        self.assertEqual((query["temperature_unit"], query["wind_speed_unit"]), ("fahrenheit", "mph"))
        self.assertEqual(len(self.calls()), 3, "the place is looked up once")
        wind = self.stats(self.sections(self.popover(preferences=dict(self.VALLETTA, units="fahrenheit")))
                          ["Now in Valletta"]["blocks"][0])["Wind"]
        self.assertEqual(wind, "15 mph NE")

    def test_a_country_after_a_comma_picks_that_country(self):
        self.bar(preferences={"city": "Paris, France"})
        self.assertEqual(self.calls()[0][1]["name"], "Paris")
        self.assertEqual(self.calls()[1][1]["latitude"], "48.853")
        self.bar(preferences={"city": "paris,  us"})
        self.assertEqual(self.calls()[-1][1]["latitude"], "33.66")

    def test_an_unknown_city_says_so(self):
        line = self.bar(preferences={"city": "Valletta, Narnia"})
        self.assertEqual(line["blocks"][0]["text"], "No weather yet: Open-Meteo knows no place called Valletta, Narnia.")

    # ---- the page's place (Sven, 2026-10-31: pick a city on the page) ----

    def place(self, **kwargs):
        return self.sections(self.page(**kwargs))["Place"]

    def test_the_page_searches_a_city_as_typed_and_a_row_picks_it_for_every_view(self):
        place = self.place(preferences=self.VALLETTA, pilot=self.PILOT)
        self.assertEqual(place["subtitle"], "Valletta, Malta · from Settings")
        box = place["blocks"][0]
        self.assertEqual((box["type"], box["live"], box["action"]["command"]), ("input", True, "find-place"))
        self.run_ext("find-place", input="paris", preferences=self.VALLETTA)
        self.assertEqual(self.calls()[-1][1]["name"], "paris")
        rows = self.place(preferences=self.VALLETTA, pilot=self.PILOT)["blocks"][1]["items"]
        self.assertEqual([(r["title"], r["subtitle"]) for r in rows][:3],
                         [("Valletta", "Valletta · Malta"), ("Paris", "Texas · United States"), ("Paris", "Île-de-France · France")])
        france = rows[2]["actions"][0]
        self.assertEqual(france["command"], "pick-place")
        said = self.run_ext("pick-place", context=france["context"], preferences=self.VALLETTA)
        self.assertEqual(said.of_type("hud")[0]["text"], "Weather: Paris, France")
        asked = len(self.calls())
        place = self.place(preferences=self.VALLETTA, pilot=self.PILOT)
        self.assertEqual(place["subtitle"], "Paris, France · picked here")
        self.assertEqual(self.calls()[asked][1]["latitude"], "48.853", "the forecast asked for the place picked, no lookup")
        self.assertEqual(len(place["blocks"]), 2, "the search closed; Use the City setting offered")
        self.assertEqual(place["blocks"][1]["actions"][0]["context"], {"clear": True})

    def test_an_edited_city_setting_wins_over_a_pick_and_use_the_city_setting_forgets_it(self):
        self.run_ext("pick-place", context={"place": {"name": "Paris", "country": "France", "latitude": 48.853,
                                                      "longitude": 2.349}}, preferences=self.VALLETTA)
        self.assertEqual(self.place(preferences=self.VALLETTA)["subtitle"].split(" · ")[1], "picked here")
        self.assertEqual(self.place(preferences={"city": "Paris, France"})["subtitle"].split(" · ")[1], "from Settings")
        self.run_ext("pick-place", context={"clear": True}, preferences=self.VALLETTA)
        self.assertEqual(self.place(preferences=self.VALLETTA)["subtitle"], "Valletta, Malta · from Settings")

    def test_an_emptied_place_box_closes_the_search_and_offline_says_why(self):
        self.fake_curl(fail="(6) Could not resolve host: geocoding-api.open-meteo.com")
        result = self.box.run(self.EXTENSION, "find-place", input="rome", preferences=self.VALLETTA)
        self.assertEqual(result.of_type("error")[0]["text"], "(6) Could not resolve host: geocoding-api.open-meteo.com")
        rows = self.place(preferences=self.VALLETTA)["blocks"][1]["items"]
        self.assertEqual(rows[0]["title"], "(6) Could not resolve host: geocoding-api.open-meteo.com")
        self.run_ext("find-place", input="", preferences=self.VALLETTA)
        self.assertEqual(len(self.place(preferences=self.VALLETTA)["blocks"]), 1)

    @unittest.skipIf(ZONE.startswith("Etc/") or "/" not in ZONE, "this Mac's time zone names no city")
    def test_no_city_uses_the_mac_time_zone_city(self):
        elsewhere = dict(PLACES["results"][0], timezone="America/Nowhere")
        self.fake_curl(places={"results": [elsewhere, PLACES["results"][-1]]})
        self.bar()
        geo = self.calls()[0][1]
        self.assertEqual(geo["name"], ZONE.rsplit("/", 1)[1].replace("_", " "))
        self.assertEqual(self.calls()[1][1]["latitude"], "1.5", "the result in the Mac's own time zone")
