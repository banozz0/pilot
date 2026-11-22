import fcntl
import importlib.util
import json
import time
import unittest
from unittest import mock
from urllib.parse import parse_qs, urlsplit

from harness import EXTENSIONS, ExtensionTestCase

_spec = importlib.util.spec_from_file_location("packages_main", EXTENSIONS / "packages" / "main.py")
main = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(main)

KEY = "FAKE_packages_test_key"  # a placeholder, never a real key
PREFS = {"apiKey": KEY}

# A stand-in for curl: reads the config Packages writes on its stdin (`curl -K -`), logs what it asked (method, path,
# query, body, the key header and its own arguments) one JSON line each, and answers from responses.json:
# {"METHOD path": {"http": 200, "body": {...}}}, or a list of such answers used in turn (the last one repeated).
FAKE_CURL = r'''
import json, os, sys
root = sys.argv[1]
config = {}
headers = []
for line in sys.stdin.read().splitlines():
    name, _, value = line.partition(" = ")
    value = value.strip()
    if value.startswith('"') and value.endswith('"'):
        value = value[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    if name.strip() == "header":
        headers.append(value)
    else:
        config[name.strip()] = value
url = config.get("url", "")
path = url.split("/v4/", 1)[-1].split("?", 1)[0]
method = config.get("request", "GET")
entry = {"method": method, "path": path, "url": url, "body": config.get("data-binary"), "headers": headers,
         "argv": sys.argv[2:]}
with open(os.path.join(root, "calls.jsonl"), "a") as f:
    f.write(json.dumps(entry) + "\n")
with open(os.path.join(root, "responses.json")) as f:
    routes = json.load(f)
route = method + " " + (path if not path.startswith("trackings/delete/") else "trackings/delete")
answers = routes.get(route)
if answers is None:
    sys.stderr.write("curl: (6) Could not resolve host: api.trackingmore.com\n")
    sys.exit(6)
if isinstance(answers, list):
    count_path = os.path.join(root, "count-" + route.replace(" ", "_").replace("/", "_"))
    n = int(open(count_path).read()) if os.path.exists(count_path) else 0
    open(count_path, "w").write(str(n + 1))
    answers = answers[min(n, len(answers) - 1)]
sys.stdout.write(json.dumps(answers["body"]) + "\n" + str(answers.get("http", 200)))
'''


def envelope(data, code=200, message="Request response is successful"):
    """TrackingMore's envelope, with the HTTP status it comes with (docs: Response Code)."""
    return {"http": {200: 200, 401: 401, 429: 429}.get(code, 400),
            "body": {"meta": {"code": code, "message": message}, "data": data}}


def event(date, detail, location="", status="transit"):
    return {"checkpoint_date": date, "checkpoint_delivery_status": status, "checkpoint_delivery_substatus": status + "001",
            "tracking_detail": detail, "location": location, "country_iso2": None, "state": None, "city": None,
            "zip": None, "raw_status": None}


def tracking(tid, number, courier="usps", status="transit", events=(), updating=True, link=None):
    """A tracking as trackings/get and trackings/create answer (the docs' quick start sample, trimmed)."""
    events = list(events)
    return {"id": tid, "tracking_number": number, "courier_code": courier, "order_number": number,
            "created_at": "2026-11-20T06:07:40+00:00", "update_at": "2026-11-22T06:18:46+00:00",
            "delivery_status": status, "archived": "tracking", "updating": updating, "substatus": status + "001",
            "latest_event": events[0]["tracking_detail"] if events else None,
            "latest_checkpoint_time": events[0]["checkpoint_date"] if events else None, "transit_time": 2,
            "scheduled_delivery_date": None,
            "origin_info": {"courier_code": courier, "weblink": "https://www.usps.com/", "tracking_link": link,
                            "trackinfo": events},
            "destination_info": {"courier_code": None, "weblink": None, "trackinfo": []}}


USPS = {"courier_name": "USPS", "courier_code": "usps", "courier_country_iso2": "US", "courier_type": "postal"}
DHL = {"courier_name": "DHL Express", "courier_code": "dhl", "courier_country_iso2": "DE", "courier_type": "express"}
NUMBER = "9400111206209393241432"  # the docs' sample number
OTHER = "LX123456789CN"
TRANSIT_EVENTS = [event("2026-11-21T21:19:00-04:00", "Accepted at USPS Origin Facility", "FORT LAUDERDALE,FL,33309"),
                  event("2026-11-22T07:19:00", "Arrived at USPS Regional Facility", "MIAMI,FL", "transit"),
                  event("2026-11-21", "Shipping Label Created, USPS Awaiting Item", "", "inforeceived")]
DELIVERED_EVENTS = [event("2026-11-04T14:31:00-04:00", "Delivered, In/At Mailbox", "HEMINGWAY,SC,29554", "delivered")]


class PackagesTests(ExtensionTestCase):
    EXTENSION = "packages"

    def setUp(self):
        super().setUp()
        self.addCleanup(self.settle)
        (self.box.root / "fake_curl.py").write_text(FAKE_CURL)
        self.box.shim("curl", 'exec /usr/bin/python3 "%s" "%s" "$@"' % (self.box.root / "fake_curl.py", self.box.root))
        self.answer({})

    def answer(self, routes):
        (self.box.root / "responses.json").write_text(json.dumps(routes))
        for f in self.box.root.glob("count-*"):
            f.unlink()

    def calls(self):
        path = self.box.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def settle(self):
        lock = self.box.cache / "refresh.lock"
        if lock.exists():
            with open(str(lock), "a") as f:
                fcntl.flock(f, fcntl.LOCK_EX)

    def stored(self):
        return json.loads((self.box.data / "parcels.json").read_text())["parcels"]

    def status(self):
        return json.loads((self.box.cache / "status.json").read_text())

    def seed(self, parcels, trackings, refreshed_at=None):
        """Parcels already tracked, with what TrackingMore said (`trackings` by id), read `refreshed_at`."""
        (self.box.data / "parcels.json").write_text(json.dumps({"version": 1, "parcels": parcels}))
        read = time.time() if refreshed_at is None else refreshed_at
        status = {"byId": {tid: dict(main.trimmed(t), fetchedAt=read) for tid, t in trackings.items()}, "refreshedAt": read}
        (self.box.cache / "status.json").write_text(json.dumps(status))

    def hud(self, result):
        return result.of_type("hud")[0]["text"]

    def error(self, result):
        return result.of_type("error")[0]["text"]

    def parcel(self, tid, number, courier="usps", name="", added=None, courier_name="USPS"):
        return {"id": tid, "number": number, "courier": courier, "courierName": courier_name, "name": name,
                "added": time.time() - 3 * 86400 if added is None else added}

    def two_parcels(self, refreshed_at=None):
        self.seed([self.parcel("t1", NUMBER, name="Shoes"), self.parcel("t2", OTHER, "china-post", added=time.time() - 5 * 86400, courier_name="China Post")],
                  {"t1": tracking("t1", NUMBER, events=TRANSIT_EVENTS, link="https://tools.usps.com/go/TrackConfirmAction?tLabels=" + NUMBER),
                   "t2": tracking("t2", OTHER, "china-post", "delivered", DELIVERED_EVENTS, updating=False)},
                  refreshed_at)

    # ---- no key ----

    def test_without_a_key_every_view_says_how_to_get_one_and_asks_nothing(self):
        items = self.run_ext("packages", query="9400111206209393241432").items
        self.assertItemShape(items)
        self.assertEqual([i["title"] for i in items], ["Add your TrackingMore API key"])
        self.assertEqual(items[0]["actions"][0]["url"], "https://www.trackingmore.com/signup.html")
        page = self.page()
        self.assertIn("Developer › API Key", page[0]["text"])
        self.assertIn("trackingmore.com/signup.html", page[0]["text"])
        detail = self.run_ext("parcel", context={"id": "t1"}).detail
        self.assertIn("Add your TrackingMore API key", detail["markdown"])
        for command in ("add", "remove", "refresh"):
            result = self.run_ext(command, input=NUMBER, context={"id": "t1"})
            self.assertIn("API key", self.error(result))
        self.assertEqual(self.calls(), [])

    # ---- add ----

    def test_add_detects_one_carrier_creates_it_and_keeps_the_key_off_the_command_line(self):
        self.answer({"POST couriers/detect": envelope([USPS]),
                     "POST trackings/create": envelope(tracking("t1", NUMBER, status="pending"))})
        result = self.run_ext("add", input="%s shoes for mum" % NUMBER.lower(), preferences=PREFS)
        self.assertEqual(self.hud(result), "Packages: tracking shoes for mum with USPS · Pending")
        calls = self.calls()
        self.assertEqual([(c["method"], c["path"]) for c in calls], [("POST", "couriers/detect"), ("POST", "trackings/create")])
        self.assertEqual(json.loads(calls[1]["body"]), {"tracking_number": NUMBER, "courier_code": "usps"})
        for c in calls:
            self.assertEqual(c["argv"], ["-K", "-"])  # the key and the number never reach the arguments `ps` shows
            self.assertIn("Tracking-Api-Key: " + KEY, c["headers"])
        self.assertEqual([(p["id"], p["number"], p["courier"], p["name"]) for p in self.stored()],
                         [("t1", NUMBER, "usps", "shoes for mum")])
        again = self.run_ext("add", input=NUMBER, preferences=PREFS)
        self.assertEqual(self.hud(again), "Packages: already tracking shoes for mum")
        self.run_ext("packages", preferences=PREFS)  # just read by its add: the list asks nothing
        self.settle()
        self.assertEqual(len(self.calls()), 2)

    def test_add_with_several_carriers_asks_which_then_tracks_with_the_one_picked(self):
        self.answer({"POST couriers/detect": envelope([DHL, USPS]),
                     "POST trackings/create": envelope(tracking("t9", OTHER, "dhl", "inforeceived"))})
        result = self.run_ext("add", input=OTHER, preferences=PREFS)
        push = result.actions[0]
        self.assertActionShape(push)
        self.assertEqual((push["type"], push["command"]), ("push", "pick-carrier"))
        self.assertEqual(self.calls()[-1]["path"], "couriers/detect")
        self.assertFalse((self.box.data / "parcels.json").exists())
        rows = self.run_ext("pick-carrier", context=push["context"], preferences=PREFS).items
        self.assertItemShape(rows)
        self.assertEqual([r["title"] for r in rows], ["DHL Express", "USPS"])
        pick = rows[0]["actions"][0]
        done = self.run_ext("add", context=pick["context"], preferences=PREFS)
        self.assertEqual(self.hud(done), "Packages: tracking %s with DHL Express · Label created" % OTHER)
        self.assertEqual([c["path"] for c in self.calls()], ["couriers/detect", "trackings/create"])
        self.assertEqual(self.stored()[0]["courier"], "dhl")

    def test_a_number_already_in_the_account_is_read_not_created_again(self):
        self.answer({"POST couriers/detect": envelope([USPS]),
                     "POST trackings/create": envelope(None, 4101, "Tracking No. already exists."),
                     "GET trackings/get": envelope([tracking("t1", NUMBER, events=TRANSIT_EVENTS)])})
        result = self.run_ext("add", input=NUMBER, preferences=PREFS)
        self.assertEqual(self.hud(result), "Packages: tracking %s with USPS · In transit" % NUMBER)
        get = self.calls()[-1]
        self.assertEqual(parse_qs(urlsplit(get["url"]).query), {"tracking_numbers": [NUMBER]})
        self.assertEqual(self.stored()[0]["id"], "t1")

    def test_add_says_why_trackingmore_refused(self):
        cases = [({"POST couriers/detect": envelope(None, 401, "Authorization verification failed")}, "refused the API key"),
                 ({"POST couriers/detect": envelope([])}, "could not tell the carrier"),
                 ({"POST couriers/detect": envelope(None, 4121, "Cannot detect courier.")}, "could not tell the carrier"),
                 ({"POST couriers/detect": envelope([USPS]), "POST trackings/create": envelope(None, 4190, "quota")}, "no credits left"),
                 ({"POST couriers/detect": envelope(None, 429, "Too many")}, "slow down"),
                 ({}, "could not reach TrackingMore")]
        for routes, said in cases:
            self.answer(routes)
            result = self.run_ext("add", input=NUMBER, preferences=PREFS)
            self.assertIn(said, self.error(result), routes)
        self.assertFalse((self.box.data / "parcels.json").exists())
        self.assertEqual(self.error(self.run_ext("add", input="hello", preferences=PREFS)),
                         "type a tracking number first, then a name if you like")

    def test_a_key_that_could_break_curls_config_is_never_sent(self):
        for command in ("packages", "add", "page"):
            result = self.run_ext(command, input=NUMBER, preferences={"apiKey": 'abc"\nurl = "https://example.com'})
            self.assertIn("does not look right", self.error(result))
        self.assertEqual(self.calls(), [])

    # ---- list and detail ----

    def test_the_list_shows_status_last_event_and_age_in_two_sections(self):
        self.two_parcels()
        items = self.run_ext("packages", preferences=PREFS).items
        self.assertItemShape(items)
        self.assertEqual([(i["title"], i.get("section")) for i in items], [("Shoes", "On the way"), (OTHER, "Delivered")])
        shoes = items[0]
        self.assertEqual(shoes["subtitle"], "In transit · Arrived at USPS Regional Facility · MIAMI,FL")
        self.assertRegex(shoes["accessory"], r"^\d+[mhdw]$|^now$")
        self.assertEqual(items[1]["accessory"]["tone"], "fine")
        self.assertEqual([a["title"] for a in shoes["actions"]],
                         ["Show events", "Open on the carrier's site", "Copy tracking number", "Stop tracking", "Refresh"])
        self.assertIn("new TrackingMore credit", shoes["actions"][3]["ask"]["confirm"])
        self.assertEqual(self.calls(), [])  # read just now: nothing asked
        self.assertEqual([i["title"] for i in self.run_ext("packages", query="china", preferences=PREFS).items], [OTHER])
        typed = self.run_ext("packages", query="1z999aa10123456784 lamp", preferences=PREFS).items
        self.assertEqual(typed[0]["title"], "Track 1Z999AA10123456784")
        self.assertEqual(typed[0]["actions"][0]["context"], {"number": "1Z999AA10123456784", "name": "lamp"})

    def test_a_parcel_shows_every_event_newest_first_whatever_its_date_form(self):
        self.two_parcels()
        detail = self.run_ext("parcel", context={"id": "t1"}, preferences=PREFS).detail
        lines = [l for l in detail["markdown"].splitlines() if l.startswith("- ")]
        self.assertEqual([l.split(" · ", 1)[1] for l in lines],
                         ["Arrived at USPS Regional Facility · MIAMI,FL", "Accepted at USPS Origin Facility · FORT LAUDERDALE,FL,33309",
                          "Shipping Label Created, USPS Awaiting Item"])
        self.assertIn("**Nov 21** · Shipping", lines[2])
        facts = {m["label"]: m["text"] for m in detail["metadata"]}
        self.assertEqual((facts["Number"], facts["Carrier"], facts["Status"]), (NUMBER, "USPS", "In transit"))
        delivered = {m["label"]: m["text"] for m in self.run_ext("parcel", context={"id": "t2"}, preferences=PREFS).detail["metadata"]}
        self.assertEqual(delivered["Refresh"], "no longer asked (delivered)")
        for action in detail["actions"]:
            self.assertActionShape(action)

    def test_the_page_adds_lists_and_removes(self):
        self.two_parcels()
        blocks = self.page(preferences=PREFS)
        self.assertEqual(blocks[0]["type"], "input")
        self.assertEqual(blocks[0]["action"]["command"], "add")
        lists = [b for b in blocks if b["type"] == "list"]
        self.assertEqual([(b["title"], [i["title"] for i in b["items"]]) for b in lists],
                         [("On the way", ["Shoes"]), ("Delivered", [OTHER])])
        self.assertEqual(lists[0]["items"][0]["inline"][0]["command"], "remove")

    # ---- remove ----

    def test_remove_stops_it_at_trackingmore_and_drops_it(self):
        self.two_parcels()
        self.answer({"DELETE trackings/delete": envelope({"id": "t1", "tracking_number": NUMBER, "courier_code": "usps"})})
        result = self.run_ext("remove", context={"id": "t1"}, preferences=PREFS)
        self.assertEqual(self.hud(result), "Packages: stopped tracking Shoes")
        self.assertEqual([(c["method"], c["path"]) for c in self.calls()], [("DELETE", "trackings/delete/t1")])
        self.assertEqual([p["id"] for p in self.stored()], ["t2"])
        self.assertNotIn("t1", self.status()["byId"])

    def test_remove_offline_keeps_it_and_gone_at_trackingmore_drops_it(self):
        self.two_parcels()
        self.assertIn("could not stop tracking", self.error(self.run_ext("remove", context={"id": "t1"}, preferences=PREFS)))
        self.assertEqual(len(self.stored()), 2)
        self.answer({"DELETE trackings/delete": envelope(None, 4102, "Tracking No. no exists.")})
        self.run_ext("remove", context={"id": "t1"}, preferences=PREFS)
        self.assertEqual([p["id"] for p in self.stored()], ["t2"])

    # ---- refresh and quota ----

    def test_a_stale_list_refreshes_once_in_the_background_and_never_asks_for_delivered_parcels(self):
        self.two_parcels(refreshed_at=time.time() - 16 * 60)
        delivered_now = tracking("t1", NUMBER, status="delivered", updating=True,
                                 events=[event("2026-11-22T10:00:00+01:00", "Delivered, Front Door", "MIAMI,FL", "delivered")] + TRANSIT_EVENTS)
        self.answer({"GET trackings/get": envelope([delivered_now])})
        first = self.run_ext("packages", preferences=PREFS).items
        self.assertEqual(first[0]["subtitle"].split(" · ")[0], "In transit")  # shown at once, from what was read
        self.settle()
        gets = [c for c in self.calls() if c["path"] == "trackings/get"]
        self.assertEqual(len(gets), 1)
        self.assertEqual(parse_qs(urlsplit(gets[0]["url"]).query)["tracking_numbers"], [NUMBER])  # not the delivered one
        items = self.run_ext("packages", preferences=PREFS).items
        self.assertEqual([(i["title"], i["section"]) for i in items], [("Shoes", "Delivered"), (OTHER, "Delivered")])
        self.run_ext("packages", preferences=PREFS)
        self.page(preferences=PREFS)
        self.settle()
        self.assertEqual(len(self.calls()), 1)  # all delivered: nothing is ever asked again
        self.assertIn("nothing on its way", self.hud(self.run_ext("refresh", preferences=PREFS)))

    def test_views_wait_fifteen_minutes_between_reads_and_two_while_a_new_parcel_has_no_event(self):
        self.assertEqual((main.FRESH, main.NEW_FRESH, main.FORCE_FLOOR), (900, 120, 60))
        self.two_parcels(refreshed_at=time.time() - 14 * 60)
        self.answer({"GET trackings/get": envelope([tracking("t1", NUMBER, events=TRANSIT_EVENTS)])})
        self.run_ext("packages", preferences=PREFS)
        self.run_ext("parcel", context={"id": "t1"}, preferences=PREFS)
        self.settle()
        self.assertEqual(self.calls(), [])
        self.seed([self.parcel("t3", OTHER, added=time.time() - 300)], {"t3": tracking("t3", OTHER, status="pending")},
                  refreshed_at=time.time() - 3 * 60)
        self.answer({"GET trackings/get": envelope([tracking("t3", OTHER, events=TRANSIT_EVENTS[:1])])})
        self.run_ext("packages", preferences=PREFS)
        self.settle()
        self.assertEqual([c["path"] for c in self.calls()], ["trackings/get"])

    def test_refresh_forces_a_read_but_not_twice_in_a_minute(self):
        self.two_parcels(refreshed_at=time.time() - 5 * 60)
        self.answer({"GET trackings/get": envelope([tracking("t1", NUMBER, status="pickup", events=TRANSIT_EVENTS)])})
        self.assertEqual(self.hud(self.run_ext("refresh", preferences=PREFS)), "Packages: 1 parcel refreshed")
        self.assertEqual(self.status()["byId"]["t1"]["delivery_status"], "pickup")
        self.assertEqual(self.hud(self.run_ext("refresh", preferences=PREFS)), "Packages: refreshed just now")
        self.assertEqual(len(self.calls()), 1)

    def test_a_failed_refresh_shows_its_reason_and_waits_before_trying_again(self):
        self.two_parcels(refreshed_at=time.time() - 20 * 60)
        self.answer({"GET trackings/get": envelope(None, 401, "Authorization verification failed")})
        self.run_ext("packages", preferences=PREFS)
        self.settle()
        items = self.run_ext("packages", preferences=PREFS).items
        self.assertEqual(items[0]["title"], "Could not refresh")
        self.assertIn("refused the API key", items[0]["subtitle"])
        self.settle()
        self.assertEqual(len(self.calls()), 1)

    def test_more_than_forty_parcels_are_read_forty_at_a_time(self):
        parcels = [self.parcel("id%d" % i, "LX%09dCN" % i) for i in range(45)]
        self.seed(parcels, {}, refreshed_at=0)
        self.answer({"GET trackings/get": envelope([])})
        self.assertEqual(self.hud(self.run_ext("refresh", preferences=PREFS)), "Packages: 45 parcels refreshed")
        sizes = [len(parse_qs(urlsplit(c["url"]).query)["tracking_numbers"][0].split(",")) for c in self.calls()]
        self.assertEqual(sizes, [40, 5])

    def test_a_parcel_trackingmore_leaves_out_waits_like_the_rest(self):
        self.two_parcels(refreshed_at=time.time() - 20 * 60)
        self.answer({"GET trackings/get": envelope([])})  # archived at TrackingMore, or gone after its 180 days
        self.run_ext("packages", preferences=PREFS)
        self.settle()
        self.run_ext("packages", query="s", preferences=PREFS)
        self.run_ext("packages", query="sh", preferences=PREFS)
        self.settle()
        self.assertEqual(len(self.calls()), 1)

    def test_a_tracking_answered_under_another_id_is_matched_by_number_and_carrier(self):
        self.two_parcels(refreshed_at=0)
        self.answer({"GET trackings/get": envelope([tracking("other-id", NUMBER, status="pickup", events=TRANSIT_EVENTS)])})
        self.run_ext("refresh", preferences=PREFS)
        self.assertEqual(self.status()["byId"]["t1"]["delivery_status"], "pickup")

    def test_a_forced_refresh_also_asks_a_parcel_trackingmore_stopped_updating(self):
        self.seed([self.parcel("t4", OTHER)], {"t4": tracking("t4", OTHER, status="expired", updating=False)}, refreshed_at=0)
        self.answer({"GET trackings/get": envelope([tracking("t4", OTHER, status="transit", events=TRANSIT_EVENTS)])})
        self.run_ext("packages", preferences=PREFS)
        self.settle()
        self.assertEqual(self.calls(), [])  # a view never asks it
        self.assertEqual(self.hud(self.run_ext("refresh", preferences=PREFS)), "Packages: 1 parcel refreshed")
        self.assertEqual(self.status()["byId"]["t4"]["delivery_status"], "transit")

    def test_a_refresh_landing_late_never_brings_back_a_removed_parcel_or_drops_a_new_one(self):
        self.two_parcels(refreshed_at=0)
        data, cache = str(self.box.data), str(self.box.cache)

        def slow_read(key, numbers):
            # While TrackingMore answers, the person removes Shoes and adds a new parcel.
            with main.Store(data, cache) as store:
                store.parcels = [p for p in store.parcels if p["id"] != "t1"] + [self.parcel("t5", "NEW123456")]
            return {"t1": tracking("t1", NUMBER, status="pickup")}, None

        with mock.patch.object(main, "read_trackings", slow_read):
            self.assertIsNone(main.fetch(KEY, main.Store(data, cache)))
        self.assertEqual([p["id"] for p in self.stored()], ["t2", "t5"])
        self.assertNotIn("t1", self.status()["byId"])


if __name__ == "__main__":
    unittest.main()
