import hashlib
import json
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from harness import ExtensionTestCase


class SummarisePageTests(ExtensionTestCase):
    """The page does its job (Sven, 2026-10-31): a box to paste a link or choose a file, Summarise, the summary with Copy.
    No network and no AI: a text document is the source, and the AI's answer is handed to `summarised` as Pilot would."""
    EXTENSION = "summarise"

    def setUp(self):
        super().setUp()
        self.box.shim("open")
        self.box.shim("pbpaste", "exit 0")

    def box_of(self, blocks):
        self.assertEqual(blocks[0]["type"], "section")
        self.assertEqual(blocks[0]["title"], "Summarise")
        box = blocks[0]["blocks"][0]
        self.assertEqual(box["type"], "input")
        return box

    def test_an_empty_page_leads_with_the_box(self):
        blocks = self.page()
        box = self.box_of(blocks)
        self.assertEqual(box["action"], {"type": "run", "command": "fetch", "title": "Summarise"})
        self.assertIn("pdf", box["files"])
        self.assertIn("path", box["placeholder"])  # an older Pilot has no Choose button: a pasted path still reads
        self.assertEqual([b["type"] for b in blocks], ["section", "markdown"])
        self.assertNotIn("Hyper+Space", blocks[1]["text"])  # the page does the job itself (Sven, 2026-10-31)
        self.assertNotIn("refresh", self.blocks_message("page", "page"))

    def test_a_chosen_file_is_summarised_and_its_summary_shows_with_copy(self):
        doc = self.box.home / "Notes.txt"
        doc.write_text("Pilot makes a Mac feel like Omarchy. " * 40)
        fetched = self.run_ext("fetch", input=str(doc))
        ai = fetched.actions[-1]
        self.assertEqual(ai["type"], "ai")
        self.assertIn("Pilot makes a Mac", ai["text"])
        self.assertEqual(ai["then"]["command"], "summarised")

        waiting = self.blocks_message("page", "page")
        self.assertEqual(waiting["refresh"], 2)  # asked again until the answer is in
        self.assertNotIn("copy", [a["type"] for b in waiting["blocks"] if b["type"] == "buttons" for a in b["actions"]])

        self.run_ext("summarised", context=ai["then"]["context"], input="- Pilot feels like Omarchy")
        blocks = self.page()
        self.box_of(blocks)  # the box stays, for the next one
        self.assertEqual(blocks[1]["title"], "Notes.txt")
        buttons = next(b["actions"] for b in blocks if b["type"] == "buttons")
        self.assertEqual(buttons[0], {"type": "copy", "text": "- Pilot feels like Omarchy", "title": "Copy summary"})
        summary = next(b for b in blocks if b.get("title") == "Summary · Pilot AI")
        self.assertEqual(summary["blocks"][0]["text"], "- Pilot feels like Omarchy")

    def test_a_failed_summary_offers_try_again_and_no_copy(self):
        doc = self.box.home / "Plan.md"
        doc.write_text("# Plan\n\nShip Pilot next week. " * 20)
        ai = self.run_ext("fetch", input=str(doc)).actions[-1]
        self.run_ext("summarised", context=dict(ai["then"]["context"], error="signed out"))
        blocks = self.page()
        actions = [a for b in blocks if b["type"] == "buttons" for a in b["actions"]]
        self.assertNotIn("copy", [a["type"] for a in actions])
        self.assertIn("Try again", [a["title"] for a in actions])


class SummariseDeleteTests(ExtensionTestCase):
    """Delete and Clear failed (P94): both files go, the page moves on, and nothing a late answer does brings one back."""
    EXTENSION = "summarise"

    def setUp(self):
        super().setUp()
        self.box.shim("open")
        self.box.shim("pbpaste", "exit 0")
        self.items = self.box.data / "items"
        self.items.mkdir()

    def store(self, item_id, status="done", age=0, shown=False):
        facts = {"id": item_id, "source": "https://example.com/" + item_id, "kind": "page", "title": item_id, "status": status,
                 "at": time.time() - age, "chat": []}
        (self.items / (item_id + ".json")).write_text(json.dumps(facts))
        (self.items / (item_id + ".txt")).write_text("text of " + item_id)
        if shown:
            (self.box.data / "current").write_text(item_id)

    def files(self):
        return sorted(p.name for p in self.items.iterdir())

    def buttons(self, blocks):
        return [a for b in blocks if b["type"] == "buttons" for a in b["actions"]]

    def earlier(self, blocks):
        return next((b["items"] for b in blocks if b.get("title") == "Earlier"), [])

    def test_deleting_the_shown_one_leaves_the_page_on_the_next_newest(self):
        self.store("aaa", age=30)
        self.store("bbb", age=20)
        self.store("ccc", age=10, shown=True)
        delete = next(a for a in self.buttons(self.page()) if a["title"] == "Delete")
        self.assertEqual(delete["context"], {"id": "ccc"})
        self.run_ext("delete", context=delete["context"])
        self.assertEqual(self.files(), ["aaa.json", "aaa.txt", "bbb.json", "bbb.txt"])
        blocks = self.page()
        self.assertEqual(blocks[1]["title"], "bbb")
        self.assertEqual([i["title"] for i in self.earlier(blocks)], ["aaa"])
        moved = json.loads((self.items / "bbb.json").read_text())
        self.assertLess(moved["at"], time.time() - 15)  # moving the page does not date it now

    def test_deleting_the_last_one_leaves_the_empty_page(self):
        self.store("aaa", shown=True)
        self.run_ext("delete", context={"id": "aaa"})
        self.assertEqual(self.files(), [])
        self.assertEqual([b["type"] for b in self.page()], ["section", "markdown"])

    def test_a_row_of_earlier_deletes_that_row_and_the_page_stays(self):
        self.store("aaa", age=20)
        self.store("bbb", age=10, shown=True)
        row = self.earlier(self.page())[0]
        self.assertEqual(row["inline"][0]["command"], "delete")
        self.assertEqual(row["actions"][1]["title"], "Delete")
        self.run_ext("delete", context=row["inline"][0]["context"])
        self.assertEqual(self.files(), ["bbb.json", "bbb.txt"])
        blocks = self.page()
        self.assertEqual(blocks[1]["title"], "bbb")
        self.assertEqual(self.earlier(blocks), [])

    def test_a_row_gone_already_says_so(self):
        result = self.run_ext("delete", context={"id": "nothere"})
        self.assertEqual(result.of_type("hud")[0]["text"], "That summary is gone")

    def test_clear_failed_shows_only_with_failed_ones_and_removes_only_those(self):
        self.store("good", age=30, shown=True)
        self.store("fresh", status="reading", age=10)
        self.assertNotIn("Clear failed", [a["title"] for a in self.buttons(self.page())])
        self.store("failed", status="failed", age=40)
        self.store("stale", status="summarising", age=400)  # status_of's stale one is failed too
        clear = next(a for a in self.buttons(self.page()) if a["title"] == "Clear failed")
        self.run_ext(clear["command"])
        self.assertEqual(self.files(), ["fresh.json", "fresh.txt", "good.json", "good.txt"])
        self.assertNotIn("Clear failed", [a["title"] for a in self.buttons(self.page())])

    def test_clear_failed_moves_the_page_off_a_failed_one(self):
        self.store("good", age=30)
        self.store("bad", status="failed", shown=True)
        self.run_ext("clear-failed")
        self.assertEqual(self.page()[1]["title"], "good")

    def test_a_late_answer_does_not_bring_a_deleted_one_back(self):
        self.store("aaa", status="summarising", shown=True)
        self.run_ext("delete", context={"id": "aaa"})
        late = self.run_ext("summarised", context={"id": "aaa"}, input="- too late")
        self.assertEqual(late.of_type("hud")[0]["text"], "That source is gone")
        self.assertEqual(self.files(), [])

    def test_a_source_deleted_while_it_is_read_stays_gone_and_is_not_summarised(self):
        test = self

        class Slow(BaseHTTPRequestHandler):
            def do_GET(self):  # the read is under way: the item exists and Sven deletes it now
                url = "http://127.0.0.1:%d/page" % self.server.server_port
                test.box.run("summarise", "delete", context={"id": hashlib.sha1(url.encode()).hexdigest()[:16]})
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(b"Read after it was deleted.")

            def log_message(self, *_):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Slow)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        fetched = self.run_ext("fetch", input="http://127.0.0.1:%d/page" % server.server_port, timeout=15)
        self.assertEqual(fetched.of_type("hud")[0]["text"], "That source is gone")
        self.assertEqual(fetched.actions, [])  # no AI asked
        self.assertEqual(self.files(), [])

    def test_hyper_space_rows_delete_with_a_key_and_stay_open(self):
        self.store("aaa", shown=True)
        row = next(r for r in self.run_ext("summarise", query="").items if r.get("id") == "item:aaa")
        delete = row["actions"][1]
        self.assertEqual((delete["command"], delete["key"], delete["stay"]), ("delete", "cmd+delete", True))
        self.run_ext("delete", context=delete["context"])
        self.assertEqual(self.files(), [])


if __name__ == "__main__":
    unittest.main()
