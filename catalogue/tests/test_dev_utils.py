import base64
import hashlib
import json
import re
import time

from harness import ExtensionTestCase


def jwt(header, payload):
    enc = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).decode().rstrip("=")
    return "%s.%s.sig" % (enc(header), enc(payload))


class DevUtilsTests(ExtensionTestCase):
    EXTENSION = "dev-utils"

    def clip(self, text):
        path = self.box.root / "clip.txt"
        path.write_bytes(text.encode("utf-8"))
        self.box.shim("pbpaste", 'cat "%s"' % path)

    def rows(self, text):
        self.clip(text)
        r = self.run_ext("transform")
        self.assertItemShape(r.items)
        self.assertLess(r.elapsed, 2)
        return {i["title"]: i for i in r.items}

    def result(self, rows, title):
        actions = rows[title]["actions"]
        self.assertEqual([a["type"] for a in actions], ["copy", "paste"])
        self.assertEqual(actions[0]["text"], actions[1]["text"])
        return actions[0]["text"]

    def test_plain_text_offers_encodings_hashes_and_case(self):
        rows = self.rows("Hello World ünïcode")
        self.assertEqual(self.result(rows, "Base64 encode"), base64.b64encode("Hello World ünïcode".encode()).decode())
        self.assertEqual(self.result(rows, "URL encode"), "Hello%20World%20%C3%BCn%C3%AFcode")
        self.assertEqual(self.result(rows, "SHA-256"), hashlib.sha256("Hello World ünïcode".encode()).hexdigest())
        self.assertEqual(self.result(rows, "MD5"), hashlib.md5("Hello World ünïcode".encode()).hexdigest())
        self.assertEqual(self.result(rows, "lowercase"), "hello world ünïcode")
        self.assertEqual(self.result(rows, "UPPERCASE"), "HELLO WORLD ÜNÏCODE")
        self.assertEqual(self.result(rows, "slug"), "hello-world-unicode")
        self.assertTrue(re.match(r"[0-9a-f-]{36}\Z", self.result(rows, "New UUID")))
        for absent in ("JSON pretty", "Base64 decode", "URL decode", "Decode JWT", "Epoch to date", "Date to epoch"):
            self.assertNotIn(absent, rows)

    def test_decodes_base64_and_url_text(self):
        rows = self.rows(base64.b64encode(b"secret: hi there").decode())
        self.assertEqual(self.result(rows, "Base64 decode"), "secret: hi there")
        rows = self.rows("a%20b%2Fc+d")
        self.assertEqual(self.result(rows, "URL decode"), "a b/c d")

    def test_binary_base64_is_not_offered_as_text(self):
        self.assertNotIn("Base64 decode", self.rows(base64.b64encode(bytes(range(0, 32))).decode()))

    def test_json_pretty_and_minify(self):
        rows = self.rows('{"b": [1, 2], "a": "é"}')
        self.assertEqual(self.result(rows, "JSON minify"), '{"b":[1,2],"a":"é"}')
        self.assertEqual(json.loads(self.result(rows, "JSON pretty")), {"b": [1, 2], "a": "é"})
        self.assertIn("\n  ", self.result(rows, "JSON pretty"))

    def test_epoch_and_iso_dates_both_ways(self):
        rows = self.rows("1791583200")
        self.assertEqual(self.result(rows, "Epoch to date"), "2026-10-09T22:00:00Z")
        self.assertEqual(self.result(self.rows("1791583200000"), "Epoch to date"), "2026-10-09T22:00:00Z")
        self.assertEqual(self.result(self.rows("2026-10-09T22:00:00Z"), "Date to epoch"), "1791583200")
        self.assertEqual(self.result(self.rows("2026-10-09T23:00:00+01:00"), "Date to epoch"), "1791583200")

    def test_a_jwt_row_pushes_its_detail(self):
        token = jwt({"alg": "HS256", "typ": "JWT"}, {"sub": "sven", "exp": int(time.time()) - 3600, "iat": 1791583200})
        rows = self.rows(token)
        self.assertNotIn("Base64 decode", rows)
        jwt_row = rows["Decode JWT"]
        self.assertTrue(jwt_row["subtitle"].startswith("HS256 · "))
        push = jwt_row["actions"][0]
        self.assertEqual(push, {"type": "push", "command": "jwt", "title": "Show JWT", "context": {"token": token}})
        self.clip("the clipboard changed since")
        d = self.run_ext("jwt", context=push["context"]).detail
        facts = {f["label"]: f["text"] for f in d["metadata"]}
        self.assertEqual((facts["Algorithm"], facts["Subject"], facts["State"]), ("HS256", "sven", "expired"))
        self.assertTrue(facts["Issued"].startswith("2026-10-09T22:00:00Z ("))
        self.assertIn("1 hour ago", facts["Expires"])
        self.assertIn('"sub": "sven"', d["markdown"])
        self.assertIn("not verified", d["markdown"])

    def test_jwt_detail_on_its_own_reads_the_clipboard(self):
        self.clip(jwt({"alg": "none"}, {"sub": "x"}))
        self.assertEqual(self.run_ext("jwt").detail["metadata"][0], {"label": "Algorithm", "text": "none"})

    def test_jwt_detail_without_a_token_is_an_error(self):
        self.clip("not a token")
        self.assertEqual(self.run_ext("jwt").of_type("error"), [{"type": "error", "text": "found no JWT on the clipboard"}])

    def test_an_empty_clipboard_still_offers_uuid_and_epoch(self):
        rows = self.rows("")
        self.assertEqual(sorted(rows), ["Epoch now", "New UUID", "The clipboard holds no text"])
        self.assertNotIn("actions", rows["The clipboard holds no text"])

    def test_new_uuid_copies_then_says_so(self):
        r = self.run_ext("new-uuid")
        copy, hud = r.actions
        self.assertEqual(copy["type"], "copy")
        self.assertTrue(re.match(r"[0-9a-f-]{36}\Z", copy["text"]))
        self.assertEqual(hud, {"type": "hud", "text": "Copied " + copy["text"]})

    def test_the_page_transforms_typed_text_and_a_click_copies_the_result(self):
        blocks = self.page()
        self.assertEqual(blocks[0]["type"], "input")
        self.assertEqual(blocks[0]["action"]["command"], "use")
        self.assertEqual([a["title"] for a in blocks[1]["actions"]], ["Use clipboard", "Copy new UUID"])
        self.assertEqual(blocks[2]["type"], "markdown")

        self.run_ext("use", input='{"b": 1, "a": [2]}')
        blocks = self.page()
        self.assertEqual([a["title"] for a in blocks[1]["actions"]], ["Use clipboard", "Copy new UUID", "Clear"])
        rows = {r["title"]: r for r in blocks[-1]["items"]}
        self.assertEqual(rows["JSON minify"]["actions"], [{"type": "copy", "text": '{"b":1,"a":[2]}', "title": "Copy result"}])
        self.assertNotIn("paste", [a["type"] for r in rows.values() for a in r["actions"]])

        self.run_ext("use", context={"clear": True})
        self.assertEqual(len(self.page()), 3)

    def test_the_page_decodes_a_jwt_from_the_clipboard_and_forgets_old_text(self):
        token = jwt({"alg": "HS256"}, {"sub": "sven", "exp": 4102444800})
        self.clip(token)
        self.run_ext("use", context={"clipboard": True})
        blocks = self.page()
        section = next(b for b in blocks if b["type"] == "section")
        self.assertEqual(section["title"], "JWT")
        self.assertIn("**Subject:** sven", section["blocks"][0]["text"])
        self.assertIn('"sub": "sven"', section["blocks"][0]["text"])
        self.assertEqual([a["title"] for a in section["blocks"][1]["actions"]], ["Copy payload", "Copy header"])
        self.assertNotIn("JWT", [r["id"] for r in blocks[-1]["items"]])

        held = self.box.cache / "text.json"
        old = json.loads(held.read_text())
        held.write_text(json.dumps(dict(old, at=old["at"] - 700)))
        self.assertEqual(len(self.page()), 3)

    def test_use_clipboard_with_nothing_copied_says_so(self):
        self.clip("")
        r = self.run_ext("use", context={"clipboard": True})
        self.assertEqual(r.of_type("hud"), [{"type": "hud", "text": "The clipboard holds no text"}])
