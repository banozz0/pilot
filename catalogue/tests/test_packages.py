import fcntl
import importlib.util
import json
import time
import unittest

from harness import EXTENSIONS, ExtensionTestCase

_spec = importlib.util.spec_from_file_location("packages_main", EXTENSIONS / "packages" / "main.py")
main = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(main)

# A stand-in for curl: reads the config Packages writes on its stdin (`curl -K -`), logs what it asked (the URL, the
# headers and its own arguments) one JSON line each, and answers from responses.json: {"<a part of the URL>": {"http":
# 200, "body": <JSON>}} (or "text" for a body that is not JSON), the first part found in the URL deciding.
FAKE_CURL = r"""
import json, os, sys
root = sys.argv[1]
config, headers = {}, []
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
with open(os.path.join(root, "calls.jsonl"), "a") as f:
    f.write(json.dumps({"url": url, "headers": headers, "agent": config.get("user-agent"), "argv": sys.argv[2:]}) + "\n")
with open(os.path.join(root, "responses.json")) as f:
    routes = json.load(f)
answer = next((a for part, a in routes.items() if part in url), None)
if answer is None:
    sys.stderr.write("curl: (6) Could not resolve host\n")
    sys.exit(6)
text = answer["text"] if "text" in answer else json.dumps(answer["body"])
sys.stdout.write(text + "\n" + str(answer.get("http", 200)))
"""

# MaltaPost's trackedItems answer, its fields as its tracking page's bundle and template read them (movements[]: date,
# description, location, code, actionDescription, reasonDescription; isForeign, foreignBarcode).
def maltapost(*movements):
    return {"isSendOnParcel": False, "isForeign": True, "foreignBarcode": "RR123456785DE", "localBarcode": None,
            "requiresPayment": False, "isUntrackable": False, "movements": list(movements)}


def movement(date, description, location="", code="EMD", action=None, reason=None):
    return {"date": date, "description": description, "location": location, "code": code,
            "actionDescription": action, "reasonDescription": reason}


# Cainiao's detail.json answer, its fields as its tracking page's bundle reads them (module[]: mailNo, status,
# statusDesc, latestTrace, detailList[]: timeStr, desc, standerdDesc).
def cainiao(number, *details):
    details = [{"timeStr": t, "desc": d, "standerdDesc": h, "group": {}} for t, h, d in details]
    return {"module": [{"mailNo": number, "mailNoSource": "EXTERNAL", "status": "TRANSPORT", "statusDesc": "In transit",
                        "originCountry": "China", "destCountry": "Malta", "latestTrace": details[0] if details else {},
                        "detailList": details}], "success": True}


UPS_NUMBER = "1Z999AA10123456784"
USPS_NUMBER = "9400111206209393241432"
FROM_CHINA = "LX123456789CN"
OTHER = "RR123456785FR"  # La Poste: no feed Packages reads


class PackagesTests(ExtensionTestCase):
    EXTENSION = "packages"

    def setUp(self):
        super().setUp()
        self.addCleanup(self.settle)
        (self.box.root / "fake_curl.py").write_text(FAKE_CURL)
        self.box.shim("curl", 'exec /usr/bin/python3 "%s" "%s" "$@"' % (self.box.root / "fake_curl.py", self.box.root))
        self.region("en_US")
        self.answer({})

    def region(self, locale):
        """The Mac's region as `defaults read -g AppleLocale` says it."""
        self.box.shim("defaults", 'echo "%s"' % locale)

    def answer(self, routes):
        (self.box.root / "responses.json").write_text(json.dumps(routes))

    def calls(self):
        path = self.box.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def settle(self):
        """Waits for a read to end, so a test never leaves one running."""
        lock = self.box.cache / "read.lock"
        if lock.exists():
            with open(str(lock), "a") as f:
                fcntl.flock(f, fcntl.LOCK_EX)

    def stored(self):
        return json.loads((self.box.data / "parcels.json").read_text())["parcels"]

    def reads(self):
        return json.loads((self.box.cache / "reads.json").read_text())["byId"]

    def hud(self, result):
        return result.of_type("hud")[0]["text"]

    def error(self, result):
        return result.of_type("error")[0]["text"]

    def add(self, text):
        return self.hud(self.run_ext("add", input=text))

    def seed(self, parcels, reads=None):
        (self.box.data / "parcels.json").write_text(json.dumps({"version": 3, "parcels": parcels}))
        (self.box.cache / "reads.json").write_text(json.dumps({"byId": reads or {}}))

    def parcel(self, pid, number, name="", added=None, **extra):
        return dict({"id": pid, "number": number, "name": name,
                     "added": time.time() - 3 * 86400 if added is None else added}, **extra)

    def details(self, pid):
        """The details pushed over the popover once its read has ended, as the popover's next ask (every 2 s) sees them."""
        message = self.blocks_message("details", "popover", context={"id": pid})
        if "refresh" in message:
            self.settle()
            message = self.blocks_message("details", "popover", context={"id": pid})
        self.assertNotIn("refresh", message)
        return message["blocks"]

    # ---- keeping parcels ----

    def test_a_parcel_is_added_with_its_carrier_from_the_number_and_its_name(self):
        typed = self.run_ext("packages", query="1z999aa10123456784 lamp").items
        self.assertItemShape(typed)
        self.assertEqual((typed[0]["title"], typed[0]["subtitle"]), ("Add " + UPS_NUMBER, "as lamp · UPS"))
        self.assertEqual(self.hud(self.run_ext("add", context=typed[0]["actions"][0]["context"])), "Packages: added lamp · UPS")
        self.assertEqual(self.add("%s shoes" % OTHER.lower()), "Packages: added shoes · La Poste")
        self.assertEqual(self.add("TBA123456789012"), "Packages: added TBA123456789012")
        self.assertEqual(self.add(OTHER), "Packages: already keeping shoes")
        self.assertEqual(self.error(self.run_ext("add", input="hello")), "type a tracking number first, then a name if you like")
        items = self.run_ext("packages").items
        self.assertItemShape(items)
        rows = {i["title"]: i for i in items}
        self.assertEqual(list(rows), ["TBA123456789012", "shoes", "lamp"])  # newest first
        self.assertEqual(rows["shoes"]["subtitle"], "La Poste · On the way")
        self.assertEqual(rows["shoes"]["actions"][0],
                         {"type": "open", "title": "Open on t.17track.net", "url": "https://t.17track.net/en#nums=" + OTHER})
        self.assertEqual(rows["lamp"]["actions"][0]["url"], "https://www.ups.com/track?loc=en_US&tracknum=" + UPS_NUMBER)
        self.assertEqual([a["title"] for a in rows["lamp"]["actions"]],
                         ["Open on ups.com", "Show details", "Copy tracking number", "Rename…", "Mark delivered", "Remove"])
        self.assertEqual([i["title"] for i in self.run_ext("packages", query="poste").items], ["shoes"])
        self.assertEqual(self.calls(), [])  # adding reads nothing

    def test_a_number_names_its_carrier_only_when_its_shape_does(self):
        self.assertEqual(main.carrier_of(UPS_NUMBER), ("ups", "UPS"))
        self.assertEqual(main.carrier_of(USPS_NUMBER), ("usps", "USPS"))
        self.assertEqual(main.carrier_of("RR123456785MT"), ("maltapost", "MaltaPost"))
        self.assertEqual(main.carrier_of("RR123456785DE"), ("deutschepost", "Deutsche Post"))
        self.assertEqual(main.carrier_of("LP00123456789012"), ("cainiao", "Cainiao"))
        self.assertEqual(main.carrier_of("RR123456785ZZ"), (None, "ZZ's post"))
        self.assertEqual(main.carrier_of("123456789012"), (None, ""))  # a bare 12 digits: FedEx, or many others
        self.assertEqual(main.page_url({"number": "123456789012"}), "https://t.17track.net/en#nums=123456789012")
        self.assertEqual(main.page_url({"number": "RR123456785GB"}), "https://t.17track.net/en#nums=RR123456785GB")
        self.assertEqual(main.page_url({"number": "RR123456785MT"}), "https://www.maltapost.com/tracking#/tracking?barcode=RR123456785MT")
        self.assertEqual(main.page_url({"number": "RR123456785DE"}),
                         "https://www.dhl.de/en/privatkunden/dhl-sendungsverfolgung.html?piececode=RR123456785DE")

    def test_packages_1_parcels_are_kept_and_trackingmore_is_gone(self):
        (self.box.data / "parcels.json").write_text(json.dumps({"version": 2, "parcels": [
            {"id": "local-0011223344556677", "number": FROM_CHINA, "courier": "", "courierName": "China Post",
             "name": "shoes", "added": time.time() - 86400, "local": True},
            {"id": "9a" * 16, "number": UPS_NUMBER, "courier": "ups", "courierName": "UPS", "name": "",
             "added": time.time() - 2 * 86400, "delivered": time.time() - 3600}]}))
        (self.box.cache / "status.json").write_text(json.dumps({"byId": {"9a" * 16: {"delivery_status": "transit"}}}))
        items = self.run_ext("packages").items
        self.assertEqual([(i["title"], i["section"]) for i in items], [("shoes", "On the way"), (UPS_NUMBER, "Delivered")])
        self.run_ext("rename", context={"id": "9a" * 16}, input="lamp")
        kept = self.stored()
        self.assertEqual(kept[1], {"id": "9a" * 16, "number": UPS_NUMBER, "name": "lamp", "added": kept[1]["added"],
                                   "delivered": kept[1]["delivered"]})
        self.assertEqual(kept[0]["name"], "shoes")
        self.assertFalse((self.box.cache / "status.json").exists())
        manifest = (EXTENSIONS / "packages" / "extension.json").read_text()
        source = (EXTENSIONS / "packages" / "main.py").read_text()
        said = json.dumps([self.blocks_message("page", "page"), self.bar()], ensure_ascii=False)
        for text in (manifest, said):
            self.assertNotIn("trackingmore", text.lower())
        self.assertNotIn("api.trackingmore", source.lower())
        self.assertNotIn("preferences", json.loads(manifest))

    def test_rename_sets_the_name_shown_and_the_number_stays_in_its_details(self):
        self.add(OTHER)
        pid = self.stored()[0]["id"]
        rename = next(a for a in self.run_ext("packages").items[0]["actions"] if a["title"] == "Rename…")
        self.assertEqual((rename["command"], rename["context"], rename["ask"], rename["stay"]),
                         ("rename", {"id": pid}, {"text": ""}, True))
        self.assertEqual(self.hud(self.run_ext("rename", context={"id": pid}, input="  winter   boots ")),
                         "Packages: renamed winter boots")
        row = self.run_ext("packages").items[0]
        self.assertEqual(row["title"], "winter boots")
        self.assertEqual(next(a for a in row["actions"] if a["title"] == "Rename…")["ask"], {"text": "winter boots"})
        detail = self.run_ext("parcel", context={"id": pid}).detail
        self.assertIn({"label": "Number", "text": OTHER}, detail["metadata"])
        self.assertIn("## winter boots", detail["markdown"])
        self.assertEqual(self.hud(self.run_ext("rename", context={"id": "gone"}, input="x")), "Packages: not kept any more")

    def test_delivered_is_marked_by_hand_and_taken_back_and_remove_asks_first(self):
        self.add("%s shoes" % OTHER)
        pid = self.stored()[0]["id"]
        mark = next(a for a in self.run_ext("packages").items[0]["actions"] if a["title"] == "Mark delivered")
        self.assertEqual((mark["command"], mark["context"]), ("mark", {"id": pid, "delivered": True}))
        self.assertEqual(self.hud(self.run_ext("mark", context=mark["context"])), "Packages: shoes marked delivered")
        row = self.run_ext("packages").items[0]
        self.assertEqual((row["section"], row["subtitle"], row["icon"]), ("Delivered", "La Poste · Delivered", "✅"))
        self.assertIn("Mark on the way", [a["title"] for a in row["actions"]])
        self.assertEqual(self.hud(self.run_ext("mark", context={"id": pid, "delivered": False})), "Packages: shoes back on the way")
        remove = next(a for a in self.run_ext("packages").items[0]["actions"] if a["title"] == "Remove")
        self.assertEqual(remove["ask"], {"confirm": "Remove shoes from Packages?"})
        self.assertEqual(self.hud(self.run_ext("remove", context={"id": pid})), "Packages: removed shoes")
        self.assertEqual(self.stored(), [])
        self.assertEqual(self.calls(), [])  # La Poste: nothing is read

    # ---- the menu bar, its popover, the page ----

    def test_the_menu_bar_item_is_the_box_and_the_count_and_its_popover_one_short_line_a_parcel(self):
        self.seed([self.parcel("a", FROM_CHINA, "Winter boots for the kids", added=time.time() - 100),
                   self.parcel("b", OTHER, "lamp", added=time.time() - 200),
                   self.parcel("c", UPS_NUMBER, "", added=time.time() - 300, delivered=time.time())],
                  {"a": {"readAt": time.time() - 7200, "triedAt": time.time() - 7200, "error": None,
                         "events": [{"at": "2026-11-22 07:19:00", "head": "Departed from sorting center",
                                     "text": "[Guangzhou] Departed from sorting center", "place": "", "source": "Cainiao"}]}})
        line = self.bar()
        self.assertEqual(line["text"], "📦 2")
        self.assertNotIn("tone", line)
        self.assertEqual(line["faces"], [{"label": "Parcels", "value": "2 on the way", "symbol": "shippingbox"},
                                         {"label": "Winter boots fo…", "value": "Departed from sorting c…",
                                          "symbol": "truck.box"}])
        blocks = self.popover()
        self.assertEqual([b["type"] for b in blocks], ["input", "list", "list"])
        self.assertEqual(blocks[0]["placeholder"], "Tracking number, then a name")
        rows = blocks[1]["items"]
        self.assertEqual([(r["title"], r["subtitle"]) for r in rows],
                         [("Winter boots for the kids", "China Post · Departed from sorting center"), ("lamp", "La Poste · On the way")])
        self.assertEqual([[a["command"] for a in r["inline"]] for r in rows], [["mark"], ["mark"]])  # stacks its line
        self.assertEqual(rows[0]["actions"][0], {"type": "push", "title": "Show details", "command": "details",
                                                 "context": {"id": "a"}})
        self.assertEqual(rows[1]["actions"][0]["type"], "open")  # La Poste: Return opens its page
        self.assertEqual(blocks[2]["items"][0]["subtitle"], "UPS · Delivered")
        for r in rows:
            self.assertLessEqual(len(r["subtitle"]), main.LINE)
        self.assertEqual(self.calls(), [])  # the bar and its popover never read a carrier
        self.seed([])
        self.assertEqual(self.bar()["text"], "📦")

    def test_the_page_has_inline_buttons_and_one_line_on_how_it_works(self):
        self.add("%s shoes" % OTHER)
        blocks = self.page()
        self.assertEqual([b["type"] for b in blocks], ["input", "list", "note"])
        self.assertEqual([a["command"] for a in blocks[1]["items"][0]["inline"]], ["mark", "rename", "remove"])
        self.assertEqual(blocks[-1]["text"], main.HOW)
        manifest = json.loads((EXTENSIONS / "packages" / "extension.json").read_text())
        self.assertIn("never in the background", manifest["description"])
        self.assertEqual(manifest["permissions"]["network"], ["www.maltapost.com", "global.cainiao.com"])

    # ---- details from the carrier ----

    def test_details_read_cainiao_when_opened_and_not_again_while_fresh(self):
        self.answer({"global.cainiao.com/global/detail.json": {"body": cainiao(
            FROM_CHINA, ("2026-11-20 22:10:05", "Departed from sorting center", "[Guangzhou] Departed from sorting center"),
            ("2026-11-21 09:30:00", "Arrived at destination country", "[Malta] Arrived at destination country"),
            ("2026-11-19 10:00:00", "Accepted", ""))}})
        self.add(FROM_CHINA + " shoes")
        pid = self.stored()[0]["id"]
        blocks = self.details(pid)
        self.assertEqual([b["type"] for b in blocks], ["note", "note", "markdown", "buttons"])
        self.assertEqual((blocks[0]["text"], blocks[0]["aside"]), ("Arrived at destination country", "read just now"))
        self.assertEqual(blocks[1], {"type": "note", "icon": "tag", "text": FROM_CHINA + " · China Post"})
        self.assertEqual(blocks[2]["text"].splitlines(), [  # newest first
            "- **Nov 21, 09:30** · Arrived at destination country · [Malta] Arrived at destination country",
            "- **Nov 20, 22:10** · Departed from sorting center · [Guangzhou] Departed from sorting center",
            "- **Nov 19, 10:00** · Accepted"])
        self.assertEqual([a["title"] for a in blocks[3]["actions"]], ["Tracking page", "Refresh"])
        self.assertEqual(blocks[3]["actions"][0]["url"], "https://global.cainiao.com/newDetail.htm?mailNoList=" + FROM_CHINA)
        calls = self.calls()
        self.assertEqual([c["url"] for c in calls], ["https://global.cainiao.com/global/detail.json?mailNos=" + FROM_CHINA])
        self.assertEqual(calls[0]["argv"], ["-K", "-"])  # the number never reaches curl's arguments
        self.assertIn("Pilot-Packages", calls[0]["agent"])
        self.details(pid)
        self.assertEqual(len(self.calls()), 1)  # read under 10 minutes ago: not again
        row = self.run_ext("packages").items[0]
        self.assertEqual(row["subtitle"], "China Post · Arrived at destination country")
        self.assertEqual(row["actions"][0]["command"], "parcel")  # Return shows its details
        self.assertEqual(next(a for a in row["actions"] if a["title"] == "Refresh")["context"], {"id": pid})
        self.assertEqual(self.reads()[pid]["events"][0]["source"], "Cainiao")

    def test_on_a_mac_set_to_malta_maltapost_reads_a_parcel_from_abroad(self):
        number = "RR123456785DE"
        self.answer({"maltapost.com/TrackAndTraceApi/v1/trackedItems": {"body": maltapost(
            movement("2026-11-21T09:12:00", "Item received at the Central Mail Room", "Marsa"),
            movement("2026-11-22T08:05:00", "Item out for delivery", "Qormi", "EMH", action="Delivery attempted",
                     reason="Addressee absent"))}})
        self.add(number + " book")
        pid = self.stored()[0]["id"]
        self.assertEqual(self.run_ext("packages").items[0]["actions"][0]["type"], "open")  # en_US: no feed for it
        self.assertIn("Deutsche Post has no tracking Packages may read: Return opens dhl.de.",
                      self.run_ext("parcel", context={"id": pid}).detail["markdown"])
        self.assertEqual(self.calls(), [])
        self.region("en_MT")
        detail = self.run_ext("parcel", context={"id": pid}).detail
        if "Reading" in detail["markdown"]:  # the read outlived the detail's wait: Refresh shows it
            self.settle()
            detail = self.run_ext("parcel", context={"id": pid}).detail
        self.assertIn("**Item out for delivery**", detail["markdown"])
        self.assertIn("· Item out for delivery · Delivery attempted · Addressee absent · Qormi", detail["markdown"])
        self.assertIn("· Item received at the Central Mail Room · Marsa", detail["markdown"])
        self.assertEqual([c["url"] for c in self.calls()],
                         ["https://www.maltapost.com/TrackAndTraceApi/v1/trackedItems?barcode=" + number])
        self.assertIn({"label": "Carrier", "text": "Deutsche Post"}, detail["metadata"])
        self.assertTrue(next(m for m in detail["metadata"] if m["label"] == "Read")["text"].endswith("from MaltaPost"))
        self.assertEqual([a["title"] for a in detail["actions"]][:2], ["Open on dhl.de", "Refresh"])

    def test_a_parcel_from_china_in_malta_shows_both_carriers_events_in_one_list(self):
        self.region("en_MT")
        self.answer({"global.cainiao.com": {"body": cainiao(FROM_CHINA, ("2026-11-18 10:00:00", "Departed", ""))},
                     "maltapost.com": {"body": maltapost(movement("2026-11-22T08:05:00", "Item delivered", "Qormi", "EMI"))}})
        self.add(FROM_CHINA)
        blocks = self.details(self.stored()[0]["id"])
        self.assertEqual([line.split(" · ")[1] for line in blocks[2]["text"].splitlines()], ["Item delivered", "Departed"])
        self.assertEqual(len(self.calls()), 2)
        row = self.run_ext("packages").items[0]
        self.assertEqual((row["section"], row["subtitle"]), ("On the way", "China Post · Item delivered"))  # marked by hand only

    def test_refresh_reads_now_and_a_failed_read_keeps_what_was_read(self):
        self.region("en_MT")
        self.answer({"maltapost.com": {"body": maltapost(movement("2026-11-21T09:12:00", "Item received", "Marsa"))}})
        self.add("RR123456785MT")
        pid = self.stored()[0]["id"]
        self.assertEqual(self.hud(self.run_ext("refresh", context={"id": pid})), "Packages: RR123456785MT · Item received")
        self.assertEqual(self.hud(self.run_ext("refresh", context={"id": pid})), "Packages: RR123456785MT · Item received")
        self.assertEqual(len(self.calls()), 1)  # within 30 s of the last read: not again
        reads = json.loads((self.box.cache / "reads.json").read_text())
        reads["byId"][pid]["triedAt"] -= 3600
        (self.box.cache / "reads.json").write_text(json.dumps(reads))
        self.answer({})
        self.assertEqual(self.hud(self.run_ext("refresh", context={"id": pid})), "Packages: RR123456785MT · Item received")
        self.assertEqual(self.reads()[pid]["error"], "MaltaPost: Could not resolve host")
        self.answer({"maltapost.com": {"http": 503, "text": "<html>busy</html>"}})
        self.seed([self.parcel("x", "RR000000000MT")])
        self.assertEqual(self.error(self.run_ext("refresh", context={"id": "x"})), "could not read it: MaltaPost: it answered 503")
        detail = self.run_ext("parcel", context={"id": "x"}).detail
        self.assertIn("Could not read it: MaltaPost: it answered 503.", detail["markdown"])

    def test_an_unreadable_answer_is_said_and_shown_as_such(self):
        self.answer({"global.cainiao.com": {"text": "<html>slide to verify</html>"}})
        self.add(FROM_CHINA)
        blocks = self.details(self.stored()[0]["id"])
        self.assertEqual(blocks[-2], {"type": "markdown", "text": "Could not read it: Cainiao: its answer was not readable."})


if __name__ == "__main__":
    unittest.main()
