import datetime
import importlib.util
import json
import time

from harness import EXTENSIONS, ExtensionTestCase, manifest

_spec = importlib.util.spec_from_file_location("todo_main", EXTENSIONS / "todo" / "main.py")
todo_main = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(todo_main)

SATURDAY = datetime.date(2026, 10, 17)


def iso(days):
    return (datetime.date.today() + datetime.timedelta(days=days)).isoformat()


class DueDayTests(ExtensionTestCase):
    """The day read off the end of a new to-do, on Saturday 17 October 2026."""
    EXTENSION = "todo"

    def parsed(self, text):
        rest, due = todo_main.parse_due(text, SATURDAY)
        return rest, due and due.isoformat()

    def test_a_trailing_day_is_read_and_cut(self):
        for text, want in [("call mum fri", "2026-10-23"), ("call mum friday", "2026-10-23"), ("x today", "2026-10-17"),
                           ("x tomorrow", "2026-10-18"), ("x tmrw", "2026-10-18"), ("x in 3 days", "2026-10-20"),
                           ("x in 2 weeks", "2026-10-31"), ("x next week", "2026-10-19"), ("x 23 oct", "2026-10-23"),
                           ("x oct 23", "2026-10-23"), ("x 1 jan", "2027-01-01"), ("x sat", "2026-10-24"),
                           ("x Mon", "2026-10-19")]:
            self.assertEqual(self.parsed(text), ("x" if text.startswith("x") else "call mum", want), text)

    def test_no_day_or_only_a_day_leaves_the_text_as_it_is(self):
        for text in ("buy milk", "fri", "friday plans", "x 31 feb", "x in days"):
            self.assertEqual(self.parsed(text), (text, None), text)

    def test_labels(self):
        label = lambda days: todo_main.due_label(SATURDAY + datetime.timedelta(days=days), SATURDAY)
        self.assertEqual([label(n) for n in (0, 1, 6, 7, -1, 80)], ["Today", "Tomorrow", "Fri", "24 Oct", "Fri 16", "5 Jan 2027"])


class TodoTests(ExtensionTestCase):
    EXTENSION = "todo"

    def stored(self):
        return json.loads((self.box.data / "todos.json").read_text())

    def items(self):
        return self.stored()["items"]

    def store(self, *items):
        (self.box.data / "todos.json").write_text(json.dumps({"version": 2, "items": list(items)}))

    def todo(self, id_, text, done=False, age=60, order=0, due=None):
        t = {"id": id_, "text": text, "done": done, "created": time.time() - age, "order": order}
        if done:
            t["doneAt"] = time.time() - age / 2
        if due is not None:
            t["due"] = iso(due)
        return t

    def rows(self, blocks):
        return [i for b in blocks if b["type"] == "list" for i in b["items"]]

    def listed(self, query=""):
        r = self.run_ext("todo", query=query)
        self.assertItemShape(r.items)
        return r.items

    # ---- the old store ----

    def test_a_version_1_file_keeps_every_todo_and_its_order_and_is_written_back_as_version_2(self):
        # Verbatim To-do 1.1.1 store: no order, no due day; open ones showed newest first.
        old = {"version": 1, "items": [
            {"id": "a1b2c3d4", "text": "Renew Malta ID card", "done": False, "created": 1760500000.5},
            {"id": "e5f6a7b8", "text": "Buy milk", "done": False, "created": 1760600000.25},
            {"id": "c9d0e1f2", "text": "Reply to Harry about the launch", "done": False, "created": 1760650000.0},
            {"id": "0a1b2c3d", "text": "Book dentist", "done": True, "created": 1760400000.0, "doneAt": 1760660000.0}]}
        (self.box.data / "todos.json").write_text(json.dumps(old, ensure_ascii=False, indent=1))
        titles = [i["title"] for i in self.listed()]
        self.assertEqual(titles, ["Reply to Harry about the launch", "Buy milk", "Renew Malta ID card", "Book dentist"])
        self.assertEqual(self.stored()["version"], 1, "reading writes nothing")
        self.assertEqual(self.bar()["text"], "☑️ 3")
        self.run_ext("add", input="new one", context={"quiet": True})
        stored = self.stored()
        self.assertEqual(stored["version"], 2)
        kept = {t["id"]: t for t in stored["items"]}
        for t in old["items"]:
            self.assertEqual({k: kept[t["id"]][k] for k in t}, t, "every field of %s kept" % t["id"])
        self.assertEqual([i["title"] for i in self.listed()][:4],
                         ["new one", "Reply to Harry about the launch", "Buy milk", "Renew Malta ID card"])

    def test_an_unreadable_file_reads_as_empty_and_the_next_add_rewrites_it(self):
        (self.box.data / "todos.json").write_text("{not json")
        self.assertEqual(self.bar()["text"], "☑️ 0")
        self.run_ext("add", input="fresh")
        self.assertEqual([t["text"] for t in self.items()], ["fresh"])

    # ---- adding ----

    def test_todo_buy_milk_in_hyper_space_adds_it_in_one_step_with_its_day(self):
        add = next(c for c in manifest(self.EXTENSION)["commands"] if c["name"] == "add")
        self.assertEqual((add["keyword"], add["mode"]), ("todo", "no-view"))
        r = self.run_ext("add", input="buy milk")
        self.assertEqual(r.of_type("hud")[0]["text"], "Added: buy milk")
        r = self.run_ext("add", input="call mum tomorrow")
        self.assertEqual(r.of_type("hud")[0]["text"], "Added: call mum · Tomorrow")
        self.assertEqual([(t["text"], t.get("due")) for t in self.items()], [("buy milk", None), ("call mum", iso(1))])

    def test_the_input_box_and_the_add_row_add_quietly_at_the_top(self):
        self.store(self.todo("a", "old"))
        r = self.run_ext("add", input="  from   the box ", context={"quiet": True})
        self.assertEqual(r.messages, [])
        self.run_ext("add", context={"text": "from the row", "due": iso(2), "quiet": True})
        self.assertEqual([i["title"] for i in self.listed()], ["from the row", "from the box", "old"])
        r = self.run_ext("add", input="   ")
        self.assertEqual(r.of_type("error")[0]["text"], "type a to-do first")

    def test_typing_offers_add_first_with_the_day_read_then_the_matches(self):
        self.store(self.todo("a", "buy milk"), self.todo("b", "walk dog"), self.todo("c", "milk the cat", done=True))
        items = self.listed("milk")
        self.assertEqual(items[0]["title"], "Add “milk”")
        self.assertEqual(items[0]["subtitle"], "New to-do")
        add = items[0]["actions"][0]
        self.assertEqual((add["command"], add["context"], add.get("clear")), ("add", {"text": "milk", "quiet": True}, True))
        self.assertEqual([i["title"] for i in items[1:]], ["buy milk", "milk the cat"])
        dated = self.listed("call mum tomorrow")[0]
        self.assertEqual((dated["title"], dated["accessory"]), ("Add “call mum”", {"text": "Tomorrow"}))
        self.assertEqual(dated["actions"][0]["context"]["due"], iso(1))

    def test_empty_list_says_how_to_add(self):
        self.assertEqual(self.listed()[0]["title"], "Nothing to do")

    # ---- tidy or sectioned ----

    def test_with_no_day_set_the_list_is_tidy_no_section_and_no_date_on_any_open_row(self):
        self.store(self.todo("a", "one", order=1), self.todo("b", "two", order=0), self.todo("c", "gone", done=True, due=-3))
        items = self.listed()
        self.assertEqual([(i["title"], i.get("section"), "accessory" in i) for i in items],
                         [("two", None, False), ("one", None, False), ("gone", "Done", False)])

    def test_with_a_day_set_the_list_is_sectioned_by_when_it_is_due(self):
        self.store(self.todo("u2", "later", due=9, order=0), self.todo("n", "someday", order=1), self.todo("t", "now", due=0),
                   self.todo("o", "late", due=-2), self.todo("u1", "soon", due=3, order=5), self.todo("d", "did", done=True))
        items = self.listed()
        self.assertEqual([(i["title"], i["section"]) for i in items],
                         [("late", "Overdue"), ("now", "Today"), ("soon", "Upcoming"), ("later", "Upcoming"),
                          ("someday", "No date"), ("did", "Done")])
        tags = {i["title"]: i.get("accessory") for i in items}
        self.assertEqual(tags["now"], {"text": "Today", "tone": "warn"})
        self.assertEqual(tags["late"]["tone"], "alert")
        self.assertNotIn("tone", tags["soon"])
        self.assertIsNone(tags["someday"])

    # ---- keys ----

    def test_every_menu_action_has_its_key_and_keeps_hyper_space_open(self):
        self.store(self.todo("a", "one"), self.todo("b", "two", done=True))
        open_, done = self.listed()
        self.assertEqual([(a["title"], a.get("key")) for a in open_["actions"]],
                         [("Mark done", None), ("Edit", "cmd+e"), ("Set due date", "cmd+d"), ("Move up", "opt+up"),
                          ("Move down", "opt+down"), ("Copy text", "cmd+shift+c"), ("Delete", "cmd+delete")])
        self.assertTrue(all(a.get("stay") for a in open_["actions"] if a["type"] == "run"))
        self.assertEqual(open_["actions"][1]["ask"], {"text": "one"})
        choices = open_["actions"][2]["ask"]["choices"]
        self.assertEqual([c["title"] for c in choices[:2]], ["Today", "Tomorrow"])
        self.assertEqual(choices[0]["value"], iso(0))
        self.assertEqual(done["actions"][0]["command"], "undone")

    def test_upcoming_and_overdue_rows_keep_date_order_so_offer_no_move(self):
        self.store(self.todo("a", "soon", due=3), self.todo("b", "now", due=0))
        titles = {i["title"]: [a["title"] for a in i["actions"]] for i in self.listed()}
        self.assertNotIn("Move up", titles["soon"])
        self.assertIn("Move up", titles["now"])

    # ---- changes ----

    def test_done_undone_and_delete_change_only_the_named_todo_quietly(self):
        self.store(self.todo("a", "one"), self.todo("b", "two"))
        self.assertEqual(self.run_ext("done", context={"id": "a"}).messages, [])
        self.assertEqual([(t["id"], t["done"]) for t in self.items()], [("a", True), ("b", False)])
        self.run_ext("undone", context={"id": "a"})
        self.assertNotIn("doneAt", self.items()[0])
        self.run_ext("delete", context={"id": "b"})
        self.assertEqual([t["id"] for t in self.items()], ["a"])
        r = self.run_ext("done", context={"id": "zz"})
        self.assertEqual(r.of_type("error")[0]["text"], "that to-do is gone")

    def test_undo_is_offered_second_for_a_few_seconds_and_puts_a_deleted_one_back(self):
        self.store(self.todo("a", "one", order=0), self.todo("b", "two", order=1))
        self.run_ext("delete", context={"id": "a"})
        [row] = self.listed()
        undo = row["actions"][1]
        self.assertEqual((undo["title"], undo["key"], undo["command"]), ("Undo delete", "cmd+z", "undo"))
        self.run_ext("undo")
        self.assertEqual([i["title"] for i in self.listed()], ["one", "two"])
        self.assertEqual(self.run_ext("undo").of_type("error")[0]["text"], "has nothing to undo")
        self.run_ext("done", context={"id": "b"})
        stored = self.stored()
        stored["undo"]["at"] -= 10
        (self.box.data / "todos.json").write_text(json.dumps(stored))
        self.assertEqual([a["title"] for a in self.listed()[0]["actions"]][1], "Edit")

    def test_edit_and_due_change_the_text_and_the_day(self):
        self.store(self.todo("a", "one"))
        self.run_ext("edit", context={"id": "a"}, input="  one,  better ")
        self.run_ext("due", context={"id": "a"}, input=iso(0))
        self.assertEqual((self.items()[0]["text"], self.items()[0]["due"]), ("one, better", iso(0)))
        self.run_ext("due", context={"id": "a"}, input="")
        self.assertNotIn("due", self.items()[0])
        self.assertEqual(self.run_ext("edit", context={"id": "a"}, input=" ").of_type("error")[0]["text"], "type the to-do's text")

    def test_move_goes_one_place_within_its_section(self):
        self.store(self.todo("a", "a", order=0), self.todo("b", "b", order=1), self.todo("c", "c", order=2),
                   self.todo("u", "up", order=3, due=4))
        self.run_ext("move", context={"id": "c", "by": -1})
        self.assertEqual([i["title"] for i in self.listed() if i["section"] == "No date"], ["a", "c", "b"])
        self.run_ext("move", context={"id": "a", "by": -1})  # already first
        self.run_ext("move", context={"id": "u", "by": -1})  # Upcoming keeps date order
        self.assertEqual([i["title"] for i in self.listed()], ["up", "a", "c", "b"])

    def test_a_page_drag_puts_the_row_in_its_place_in_its_section(self):
        self.store(self.todo("a", "a", order=0), self.todo("b", "b", order=0), self.todo("c", "c", order=0))
        self.run_ext("reorder", context={"key": "a", "to": 2})
        order = [i["title"] for i in self.listed()]
        self.assertEqual(order[-1], "a")
        self.assertEqual(len(set(t["order"] for t in self.items())), 3)

    def test_clear_done_keeps_the_open_ones(self):
        self.store(self.todo("a", "one", done=True), self.todo("b", "two"), self.todo("c", "three", done=True))
        r = self.run_ext("clear-done")
        self.assertEqual(r.of_type("hud")[0]["text"], "Deleted 2 done to-dos")
        self.assertEqual([t["id"] for t in self.items()], ["b"])

    # ---- surfaces ----

    def test_bar_counts_the_open_ones_and_those_due_today(self):
        self.store(self.todo("a", "one"), self.todo("b", "two", done=True))
        self.assertEqual(self.bar()["text"], "☑️ 1")
        self.store(self.todo("a", "one"), self.todo("b", "two", due=0), self.todo("c", "three", due=-1), self.todo("d", "four", due=2))
        self.assertEqual(self.bar()["text"], "☑️ 4 · 2")

    def test_popover_is_the_same_sections_compact_with_done_folded(self):
        self.store(self.todo("a", "one", due=0), self.todo("b", "two"), self.todo("c", "three", done=True))
        blocks = self.popover()
        self.assertEqual(blocks[0]["type"], "input")
        self.assertEqual(blocks[0]["action"]["context"], {"quiet": True})
        lists = [b for b in blocks if b["type"] == "list"]
        self.assertEqual([(b.get("title"), [i["title"] for i in b["items"]]) for b in lists],
                         [("Today", ["one"]), ("No date", ["two"]), (None, ["1 done ›"])])

    def test_a_click_on_a_surface_row_edits_it_and_only_the_circle_ticks_it(self):
        # Sven, 2026-10-12: a click on a row in the menu-bar dropdown marked it done. Pilot runs a row's first action on a
        # click, so on a surface the first is Edit (asked in the row), never Mark done.
        self.store(self.todo("a", "one"), self.todo("b", "two", done=True))
        rows = [r for blocks in (self.popover(), self.page(), self.blocks("done-list", "popover")) for r in self.rows(blocks)
                if "inline" in r]
        self.assertEqual(len(rows), 4)
        for r in rows:
            self.assertEqual((r["actions"][0]["command"], r["actions"][0]["ask"]), ("edit", {"text": r["title"]}))
            self.assertIn((r["inline"][0]["command"], r["inline"][0]["icon"]), (("done", "circle"), ("undone", "checkmark.circle")))
            self.assertEqual(r["inline"][-1]["command"], "delete")
            self.assertFalse(any("key" in a or "stay" in a for a in r["actions"]))

    def test_page_lists_counts_sections_with_reorder_where_the_order_is_yours(self):
        self.store(self.todo("a", "one"), self.todo("b", "two", done=True), self.todo("c", "three", done=True, age=4e5))
        blocks = self.page()
        stats = {s["label"]: s["value"] for s in blocks[0]["items"]}
        self.assertEqual((stats["Open"], stats["Done"]), ("1", "2"))
        lists = [b for b in blocks if b["type"] == "list"]
        self.assertEqual([(b["title"], [i["title"] for i in b["items"]]) for b in lists],
                         [("To do", ["one"]), ("Done", ["two", "three"])])
        self.assertEqual(lists[0]["reorder"], {"command": "reorder"})
        self.store(self.todo("a", "one", due=5), self.todo("b", "two"))
        lists = [b for b in self.page() if b["type"] == "list"]
        self.assertEqual([(b["title"], "reorder" in b) for b in lists], [("Upcoming", False), ("No date", True)])

    def test_the_page_sets_a_due_day_in_the_row_and_the_choice_lands(self):
        # Sven, 2026-10-31: the page does its job in place; the due day was only under ⋯.
        self.store(self.todo("a", "one"), self.todo("b", "two", done=True))
        rows = {r["title"]: r for r in self.rows(self.page()) if "inline" in r}
        due = rows["one"]["inline"][1]
        self.assertEqual((due["command"], due["icon"], due["context"]), ("due", "📅", {"id": "a"}))
        self.assertEqual(due["ask"]["choices"][0]["title"], "Today")
        self.assertNotIn("due", [a.get("command") for a in rows["two"]["inline"]])  # a done one has no day
        self.run_ext("due", context=due["context"], input=due["ask"]["choices"][1]["value"])
        lists = [b for b in self.page() if b["type"] == "list"]
        self.assertEqual([(b["title"], [i["title"] for i in b["items"]]) for b in lists],
                         [("Upcoming", ["one"]), ("Done", ["two"])])

    def test_empty_popover_and_page_still_offer_the_input(self):
        self.assertEqual([b["type"] for b in self.popover()], ["input", "markdown"])
        self.assertEqual([b["type"] for b in self.page()], ["stats", "input", "markdown"])
