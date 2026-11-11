import json
import time

from harness import ExtensionTestCase


class EasyCdTests(ExtensionTestCase):
    EXTENSION = "easy-cd"

    def setUp(self):
        super().setUp()
        self.state = self.box.home / ".local" / "state" / "ecd"
        self.now = int(time.time())
        self.code = self.folder("code")
        self.pilot = self.folder("code/pilot")
        self.notes = self.folder("notes")
        self.music = self.folder("music")
        self.old = self.folder("old")

    def folder(self, rel):
        path = self.box.home / rel
        path.mkdir(parents=True, exist_ok=True)
        return str(path)

    def store(self, pins=None, visits=None):
        self.state.mkdir(parents=True, exist_ok=True)
        if pins is not None:
            (self.state / "pins").write_text("".join(p + "\n" for p in pins))
        if visits is not None:
            (self.state / "visits").write_text("".join("%d\t%s\n" % (self.now - age, d) for age, d in visits))

    def folders(self, **kwargs):
        items = self.run_ext("folders", **kwargs).items  # the harness fails it past Pilot's 2 s
        self.assertItemShape(items)
        return items

    def test_pins_first_in_pin_order_then_recents_by_frecency(self):
        self.store(pins=[self.pilot, self.code, str(self.box.home / "gone")],
                   visits=[(30, self.notes), (100, self.notes), (7200, self.music), (7200, self.music),
                           (7300, self.music), (86400 * 30, self.old), (60, self.pilot),
                           (60, str(self.box.home / "deleted"))])
        items = self.folders()
        self.assertEqual([i["id"] for i in items], [self.pilot, self.code, self.notes, self.music, self.old])
        self.assertEqual([i["icon"] for i in items], ["📌", "📌", "🕘", "🕘", "🕘"])
        self.assertEqual(items[0]["title"], "pilot")
        self.assertEqual(items[0]["subtitle"], "~/code/pilot · pinned")
        self.assertEqual(items[2]["subtitle"], "~/notes · just now")
        self.assertEqual(items[3]["subtitle"], "~/music · 2 h ago")

    def test_recents_alone_and_malformed_lines_skipped(self):
        self.state.mkdir(parents=True)
        (self.state / "visits").write_text("garbage\n\nnot-a-time\t%s\n%d\t%s\n" % (self.old, self.now - 10, self.notes))
        self.assertEqual([i["id"] for i in self.folders()], [self.notes])

    def test_actions_open_a_terminal_finder_and_copy(self):
        self.store(pins=[self.pilot])
        item = self.folders()[0]
        for a in item["actions"]:
            self.assertActionShape(a)
        self.assertTrue(item["actions"][0]["title"].startswith("Open in "))
        self.assertEqual(item["actions"][0]["context"], {"path": self.pilot})
        self.assertEqual(item["actions"][1:], [{"type": "open", "url": self.pilot, "title": "Open in Finder"},
                                               {"type": "copy", "text": self.pilot, "title": "Copy path"}])

    def test_the_chosen_terminal_names_the_action(self):
        app = self.box.root / "Kitty.app"
        app.mkdir()
        self.store(pins=[self.pilot])
        self.assertEqual(self.folders(preferences={"terminal": str(app)})[0]["actions"][0]["title"], "Open in Kitty")

    def test_no_store_is_one_honest_row(self):
        items = self.folders()
        self.assertEqual(items, [{"title": "easy-cd has no pins or recent folders yet",
                                  "subtitle": "Run ecd in a terminal: Enter lands in a folder, Ctrl+P pins it",
                                  "icon": "📂"}])

    def test_a_store_of_folders_all_gone_says_so(self):
        self.store(pins=[str(self.box.home / "gone")], visits=[(10, str(self.box.home / "gone too"))])
        self.assertEqual(self.folders()[0]["title"], "easy-cd's folders are all gone")

    def test_recents_are_capped_and_the_store_is_left_untouched(self):
        visits = [(n, self.folder("many/%02d" % n)) for n in range(40)]
        self.store(pins=[self.pilot], visits=visits)
        before = {p.name: p.read_bytes() for p in self.state.iterdir()}
        items = self.folders()
        self.assertEqual(len(items), 31)
        self.assertEqual({p.name: p.read_bytes() for p in self.state.iterdir()}, before)

    def test_a_thousand_visits_answer_fast(self):
        self.store(visits=[(n * 37, self.folder("deep/%d" % (n % 200))) for n in range(5000)])
        self.assertEqual(len(self.folders()), 30)

    def test_open_terminal_with_the_chosen_app(self):
        self.box.shim("open")
        app = self.box.root / "Kitty.app"
        app.mkdir()
        r = self.run_ext("open-terminal", context={"path": self.pilot}, preferences={"terminal": str(app)})
        self.assertEqual(self.box.shim_calls(), ["open -a %s %s" % (app, self.pilot)])
        self.assertEqual(r.of_type("hud"), [{"type": "hud", "text": "pilot in Kitty"}])

    def test_open_terminal_in_ghostty_opens_a_new_window_there(self):
        self.box.shim("open")
        app = self.box.root / "Ghostty.app"
        app.mkdir()
        self.run_ext("open-terminal", context={"path": self.pilot}, preferences={"terminal": str(app)})
        self.assertEqual(self.box.shim_calls(),
                         ["open -na %s --args --working-directory=%s --window-save-state=never" % (app, self.pilot)])

    def test_open_terminal_failing_or_a_missing_folder_is_an_error(self):
        self.box.shim("open", 'echo "no such app" >&2; exit 1')
        r = self.run_ext("open-terminal", context={"path": self.pilot}, preferences={"terminal": self.code})
        self.assertEqual(r.of_type("error"), [{"type": "error", "text": "no such app"}])
        r = self.run_ext("open-terminal", context={"path": str(self.box.home / "gone")})
        self.assertEqual(r.of_type("error"), [{"type": "error", "text": "got no folder that exists"}])

    def test_the_page_searches_its_folders_as_typed_and_a_click_opens_a_terminal(self):
        self.store(pins=[self.pilot, self.code], visits=[(30, self.notes), (60, self.music)])
        blocks = self.page()
        self.assertEqual(blocks[0]["type"], "input")
        self.assertTrue(blocks[0]["live"])
        self.assertEqual(blocks[0]["action"]["command"], "find")
        self.assertEqual([b.get("title") for b in blocks[1:]], ["Pinned", "Recent"])
        first = blocks[1]["items"][0]
        self.assertEqual([(a["command"], a["context"]) for a in first["actions"]], [("open-terminal", {"path": self.pilot})])
        self.assertEqual([a["icon"] for a in first["inline"]], ["📂", "📋"])

        self.run_ext("find", input="  mus ")
        blocks = self.page()
        self.assertEqual(blocks[1]["actions"][0]["title"], "Clear “mus”")
        self.assertEqual([b.get("title") for b in blocks[2:]], ["Recent"])
        self.assertEqual([i["id"] for i in blocks[2]["items"]], [self.music])

        self.run_ext("find", input="nothing-like-it")
        self.assertEqual(self.page()[-1], {"type": "markdown", "text": "No folder matches “nothing-like-it”."})
        self.run_ext("find", input="")  # the box emptied: every folder again
        self.assertEqual(len(self.page()), 3)

    def test_the_page_forgets_old_words_and_says_when_easy_cd_has_nothing(self):
        self.run_ext("find", input="pil")
        search = self.box.data / "search.json"
        held = json.loads(search.read_text())
        search.write_text(json.dumps(dict(held, at=held["at"] - 700)))
        blocks = self.page()
        self.assertEqual(len(blocks), 2)
        self.assertIn("easy-cd has no pins or recent folders yet", blocks[1]["text"])
