import importlib.util
import json
import os
import queue
import random
import signal
import subprocess
import threading
import time
from urllib.parse import quote

from harness import EXTENSIONS, SYSTEM_PATH, ExtensionTestCase, manifest, resolved_preferences

SECRET_SAMPLE = "PRIVATE-BODY-LINE-THAT-MUST-ONLY-APPEAR-IN-PROTOCOL"
WORDS = ("alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec "
         "romeo sierra tango uniform victor whiskey xray yankee zulu").split()


class Session:
    """A session list as Pilot keeps it (ExtensionSession.swift): the run message, then a query message per change of
    the search, one answer line each, then close."""

    def __init__(self, test, query, preferences=None):
        box = test.box
        program = EXTENSIONS / "obsidian-search" / "main.py"
        message = {"type": "run", "extension": "obsidian-search", "command": "search", "query": query,
                   "preferences": resolved_preferences(manifest("obsidian-search"), preferences or {}),
                   "paths": {"data": str(box.data), "cache": str(box.cache)}}
        env = {"HOME": str(box.home), "USER": os.environ.get("USER", "sven"), "TMPDIR": str(box.tmp) + "/",
               "PATH": ":".join([str(program.parent), str(box.shims), SYSTEM_PATH]), "LANG": "en_US.UTF-8",
               "PILOT_EXTENSION_ID": "obsidian-search"}
        self.lines = queue.Queue()
        self.started = time.monotonic()
        self.proc = subprocess.Popen([str(program)], cwd=str(program.parent), env=env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        test.addCleanup(self._kill)
        threading.Thread(target=self._read, daemon=True).start()
        self._send(message)

    def _kill(self):
        if self.proc.poll() is None:
            os.killpg(self.proc.pid, signal.SIGKILL)
            self.proc.wait()

    def _read(self):
        for line in self.proc.stdout:
            self.lines.put(line.decode("utf-8"))

    def _send(self, message):
        self.proc.stdin.write((json.dumps(message) + "\n").encode())
        self.proc.stdin.flush()

    def answer(self, since):
        line = self.lines.get(timeout=2)
        return json.loads(line), time.monotonic() - since

    def first(self):
        return self.answer(self.started)

    def ask(self, text):
        asked = time.monotonic()
        self._send({"type": "query", "text": text})
        return self.answer(asked)

    def close(self):
        self._send({"type": "close"})
        self.proc.stdin.close()
        code = self.proc.wait(timeout=0.5)
        self.stderr = self.proc.stderr.read().decode("utf-8")
        self.proc.stdout.close()
        self.proc.stderr.close()
        return code


class ObsidianSearchTests(ExtensionTestCase):
    EXTENSION = "obsidian-search"

    def setUp(self):
        super().setUp()
        self.vault = self.box.home / "Notes Vault"
        self.clock = time.time()
        self.note("Pilot spec.md", "# Pilot spec\n\nThe build contract lives here.\n", age=86400 * 30)
        self.note("Projects/Pilot/Journal.md", "---\ntags: [pilot, journal]\n---\nShipped the pilot tiler today.\n"
                  "- [ ] write the spec section\n" + SECRET_SAMPLE + "\n", age=60)
        self.note("Projects/Old/Pilot notes.md", "Old pilot notes.\n", age=86400 * 400)
        self.note("Knowledge/Tiling.md", "---\naliases:\n  - Window tiling\ntitle: Tiling basics\n---\nA tiler.\n",
                  age=3600)
        self.note("Knowledge/Tiling copy/Tiling.md", "Second note with the same title.\n", age=7200)
        self.note(".obsidian/workspace.md", "pilot hidden\n")
        self.note(".trash/Pilot trashed.md", "pilot trashed\n")
        self.note("Archive/.hidden/Pilot hidden.md", "pilot hidden\n")
        (self.vault / "Projects" / "image.png").write_bytes(b"\x89PNG pilot")
        self.write_obsidian({"a": {"path": str(self.box.home / "Old vault"), "ts": 1},
                             "b": {"path": str(self.vault), "ts": 2, "open": True}})

    def note(self, rel, text, age=0, vault=None):
        path = (vault or self.vault) / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        os.utime(path, (self.clock - age, self.clock - age))
        return path

    def write_obsidian(self, vaults):
        folder = self.box.home / "Library" / "Application Support" / "obsidian"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "obsidian.json").write_text(json.dumps({"vaults": vaults}))

    def search(self, query, **kwargs):
        r = self.run_ext("search", query=query, **kwargs)  # the harness fails it past Pilot's 2 s
        self.assertEqual(r.stderr, "")
        if r.items is not None:
            self.assertItemShape(r.items)
        return r

    def test_empty_search_lists_recent_notes_and_skips_hidden_folders(self):
        items = self.search("").items
        self.assertEqual([i["id"] for i in items],
                         ["Projects/Pilot/Journal.md", "Knowledge/Tiling.md", "Knowledge/Tiling copy/Tiling.md",
                          "Pilot spec.md", "Projects/Old/Pilot notes.md"])
        self.assertEqual(items[0]["subtitle"], "Projects/Pilot · 1 min ago")
        self.assertEqual(items[3]["subtitle"].split(" · ")[0], "Notes Vault", "a note at the root shows the vault")

    def test_title_hits_rank_above_body_hits_and_recent_above_old(self):
        r = self.search("pilot")
        ids = [i["id"] for i in r.items]
        self.assertEqual(ids, ["Pilot spec.md", "Projects/Old/Pilot notes.md", "Projects/Pilot/Journal.md"])
        self.assertEqual(r.items[2]["icon"], "🔎", "a body hit")
        self.assertEqual(r.items[2]["subtitle"], "Projects/Pilot · Shipped the pilot tiler today.")
        self.assertNotIn(SECRET_SAMPLE, r.stdout, "only the matching line leaves the program")
        ids = [i["id"] for i in self.search("tiling").items]
        self.assertEqual(ids, ["Knowledge/Tiling.md", "Knowledge/Tiling copy/Tiling.md"])

    def test_every_word_must_match_and_aliases_count_as_titles(self):
        self.assertEqual([i["id"] for i in self.search("spec section").items], ["Projects/Pilot/Journal.md"])
        self.assertEqual(self.search("spec section").items[0]["subtitle"], "Projects/Pilot · write the spec section")
        self.assertEqual([i["id"] for i in self.search("window til").items], ["Knowledge/Tiling.md"])
        self.assertEqual(self.search("window til").items[0]["icon"], "📝")

    def test_no_match_is_one_plain_row(self):
        items = self.search("zebra crossing").items
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["title"], "No note matches “zebra crossing”")
        self.assertNotIn("actions", items[0])

    def test_actions_open_in_obsidian_preview_copy_and_reveal(self):
        item = self.search("journal").items[0]
        for a in item["actions"]:
            self.assertActionShape(a)
        path = str(self.vault / "Projects/Pilot/Journal.md")
        context = {"vault": str(self.vault), "file": "Projects/Pilot/Journal.md", "link": "[[Journal]]"}
        self.assertEqual(item["actions"], [
            {"type": "open", "url": "obsidian://open?vault=Notes%20Vault&file=Projects%2FPilot%2FJournal",
             "title": "Open in Obsidian"},
            {"type": "push", "command": "note", "title": "Show preview", "context": context},
            {"type": "copy", "text": path, "title": "Copy path"},
            {"type": "copy", "text": "[[Journal]]", "title": "Copy wikilink"},
            {"type": "run", "command": "reveal", "title": "Reveal in Finder", "context": context}])
        links = [i["actions"][3]["text"] for i in self.search("tiling").items]
        self.assertEqual(links, ["[[Knowledge/Tiling]]", "[[Knowledge/Tiling copy/Tiling]]"],
                         "a title two notes share links by path")

    def test_unicode_titles_match_whatever_their_normalisation(self):
        self.note("Cafe\u0301 notes.md", "decomposed name\n")
        items = self.search("café").items
        self.assertEqual(items[0]["title"], "Café notes")
        on_disk = os.listdir(str(self.vault))
        name = next(n for n in on_disk if n.endswith(" notes.md"))
        self.assertTrue(items[0]["actions"][0]["url"].endswith(quote(name[:-3], safe="")), "the link names the file as stored")

    def test_the_vault_preference_wins_over_obsidians_list(self):
        other = self.box.home / "Other"
        self.note("Only here.md", "x\n", vault=other)
        self.assertEqual([i["title"] for i in self.search("", preferences={"vault": str(other)}).items], ["Only here"])

    def test_no_vault_anywhere_is_one_honest_error(self):
        (self.box.home / "Library" / "Application Support" / "obsidian" / "obsidian.json").unlink()
        r = self.search("pilot")
        self.assertIn("found no Obsidian vault", r.of_type("error")[0]["text"])
        r = self.search("pilot", preferences={"vault": str(self.box.home / "nope")})
        self.assertEqual(r.of_type("error"), [{"type": "error", "text": "has no vault folder ~/nope: set Vault folder "
                                                                         "on the Extensions page"}])

    def test_obsidians_last_vault_gone_and_an_empty_vault(self):
        self.write_obsidian({"b": {"path": str(self.box.home / "Gone"), "ts": 5}})
        self.assertIn("last vault gone", self.search("").of_type("error")[0]["text"])
        empty = self.box.home / "Empty"
        empty.mkdir()
        self.assertEqual(self.search("", preferences={"vault": str(empty)}).items[0]["title"], "No notes in ~/Empty")

    def test_preview_shows_the_note_trimmed_with_its_facts(self):
        body = "\n".join("line %d" % n for n in range(400)) + "\n```\ncode that never closes\n"
        self.note("Long.md", "---\ntags:\n  - big\naliases: [Huge]\n---\n" + body)
        context = {"vault": str(self.vault), "file": "Long.md", "link": "[[Long]]"}
        d = self.run_ext("note", context=context).detail
        self.assertTrue(d["markdown"].startswith("# Long\n\nline 0\n"))
        self.assertIn("line 149", d["markdown"])
        self.assertNotIn("line 150", d["markdown"])
        self.assertTrue(d["markdown"].endswith("*Trimmed: open it in Obsidian for the rest.*"))
        self.assertNotIn("tags:", d["markdown"], "the frontmatter shows as facts, not text")
        facts = {f["label"]: f["text"] for f in d["metadata"]}
        self.assertEqual((facts["Folder"], facts["Tags"], facts["Also called"]), ("Notes Vault", "big", "Huge"))
        for a in d["actions"]:
            self.assertActionShape(a)
        self.assertEqual([a["title"] for a in d["actions"]], ["Open in Obsidian", "Copy path", "Copy wikilink",
                                                              "Reveal in Finder"])

    def test_preview_closes_an_open_code_fence(self):
        self.note("Fence.md", "```\n" + "x\n" * 300)
        d = self.run_ext("note", context={"vault": str(self.vault), "file": "Fence.md"}).detail
        self.assertEqual(d["markdown"].count("```") % 2, 0)

    def test_preview_and_reveal_refuse_a_file_outside_the_vault(self):
        outside = self.box.home / "secret.md"
        outside.write_text("x")
        for command in ("note", "reveal"):
            r = self.run_ext(command, context={"vault": str(self.vault), "file": "../secret.md"})
            self.assertEqual(r.of_type("error"), [{"type": "error", "text": "that note is gone"}])

    def test_reveal_opens_finder_on_the_note(self):
        self.box.shim("open")
        r = self.run_ext("reveal", context={"vault": str(self.vault), "file": "Pilot spec.md"})
        self.assertEqual(self.box.shim_calls(), ["open -R %s" % (self.vault / "Pilot spec.md")])
        self.assertEqual(r.of_type("hud"), [{"type": "hud", "text": "Shown in Finder"}])

    def test_reveal_when_open_fails_is_an_error(self):
        self.box.shim("open", "exit 1")
        r = self.run_ext("reveal", context={"vault": str(self.vault), "file": "Pilot spec.md"})
        self.assertEqual(r.of_type("error"), [{"type": "error", "text": "Finder did not open: open exited 1"}])

    def test_a_session_answers_each_query_in_order_and_stops_on_close(self):
        s = Session(self, "")
        first, _ = s.first()
        self.assertEqual(len(first["items"]), 5)
        for query, wanted in (("pil", "Pilot spec"), ("pilot spec", "Pilot spec"), ("tiler", "Journal"),
                              ("", "Journal")):
            answer, elapsed = s.ask(query)
            self.assertEqual(answer["type"], "list")
            self.assertEqual(answer["items"][0]["title"], wanted, query)
            self.assertLess(elapsed, 0.5)
        self.assertEqual(s.close(), 0)
        self.assertEqual(s.stderr, "")
        cache = json.loads((self.box.cache / "index.json").read_text())
        self.assertEqual(cache["vault"], str(self.vault))
        self.assertEqual(cache["notes"]["Knowledge/Tiling.md"][2], ["Tiling basics", "Window tiling"])
        self.assertNotIn(SECRET_SAMPLE, json.dumps(cache), "the cache never holds a note's body")

    def held_index(self, vault, cache=None):
        """The extension's Index loaded in this process with its background read held until the test ends, as on a
        disk too slow to read anything in time."""
        spec = importlib.util.spec_from_file_location("obsidian_search", EXTENSIONS / "obsidian-search" / "main.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        held = threading.Event()
        read = module.read_note
        module.read_note = lambda path, limit=module.NOTE_BYTES: held.wait() and read(path, limit)
        index = module.Index(str(vault), cache and str(cache))
        self.addCleanup(lambda: (held.set(), index.thread.join(5)))  # done before the sandbox goes
        return module, index

    def test_a_cached_alias_matches_before_the_vault_is_read(self):
        s = Session(self, "pilot")  # a search waits for the read, so the cache is written by close
        s.first()
        s.close()
        cache = json.loads((self.box.cache / "index.json").read_text())
        self.assertIn("Knowledge/Tiling.md", cache["notes"])
        cache["notes"]["Knowledge/Tiling.md"][2] = ["Cached alias"]
        (self.box.cache / "index.json").write_text(json.dumps(cache))
        module, index = self.held_index(self.vault, self.box.cache)
        started = time.monotonic()
        items = module.search(index, "cached alias", started + module.ANSWER_BUDGET)
        self.assertLess(time.monotonic() - started, 1.5)
        self.assertEqual(items[0]["id"], "Knowledge/Tiling.md")
        self.assertEqual(items[-1]["title"], "Still reading the vault: 0 of 5 notes searched")

    def test_thousands_of_notes_answer_well_inside_two_seconds(self):
        big = self.box.home / "Big"
        rnd = random.Random(7)
        for n in range(4000):
            words = " ".join(rnd.choices(WORDS, k=300))
            lines = "\n".join(words[i:i + 80] for i in range(0, len(words), 80))
            self.note("folder %d/note %d.md" % (n % 40, n), "# note %d\n%s\n" % (n, lines), age=n * 60, vault=big)
        self.note("folder 3/Needle.md", "the haystack holds a needle\n", vault=big)
        self.note("folder 9/other.md", "somewhere a needle hides\n", age=86400, vault=big)
        s = Session(self, "needle", preferences={"vault": str(big)})
        first, elapsed = s.first()
        self.assertLess(elapsed, 2, "a cold session reads the vault and answers inside Pilot's limit")
        self.assertEqual([i["title"] for i in first["items"]], ["Needle", "other"])
        times = []
        for query in ("alpha bravo", "zulu", "note 3999", "xray yankee zulu", "nothing like this"):
            answer, elapsed = s.ask(query)
            self.assertEqual(answer["type"], "list")
            times.append(elapsed)
        self.assertLess(max(times), 0.8, times)
        self.assertEqual(s.close(), 0)

    def test_a_query_before_the_read_finishes_answers_from_titles_and_says_so(self):
        module, index = self.held_index(self.vault)
        items = module.search(index, "pilot", time.monotonic() + 0.1)
        self.assertEqual([i.get("id") for i in items[:2]], ["Pilot spec.md", "Projects/Old/Pilot notes.md"])
        self.assertTrue(items[-1]["title"].startswith("Still reading the vault: "), items[-1])
        self.assertEqual(len(items), 3, "body hits wait for the read")

    # The page (Sven, 2026-10-31): a search box over the vault, the notes it finds opening in Obsidian from the page.

    def test_the_empty_page_lists_recent_notes(self):
        blocks = self.page()
        self.assertEqual(blocks[0]["type"], "input")
        self.assertTrue(blocks[0]["live"])
        self.assertEqual(blocks[0]["action"]["command"], "find")
        self.assertEqual(blocks[1]["title"], "Recent in Notes Vault")
        self.assertEqual([i["id"] for i in blocks[1]["items"]][:2], ["Projects/Pilot/Journal.md", "Knowledge/Tiling.md"])

    def test_the_page_searches_as_typed_and_a_click_opens_the_note(self):
        self.run_ext("find", input=" pilot ")
        result = self.run_ext("page", surface="page")
        self.assertNotIn(SECRET_SAMPLE, result.stdout)
        blocks = self.page()
        self.assertEqual(blocks[1]["actions"][0]["title"], "Clear “pilot”")
        self.assertEqual(blocks[2]["title"], "Matches in Notes Vault")
        journal = blocks[2]["items"][2]
        self.assertEqual(journal["id"], "Projects/Pilot/Journal.md")
        self.assertEqual(journal["actions"], [{"type": "open", "title": "Open in Obsidian",
                                               "url": "obsidian://open?vault=Notes%20Vault&file=Projects%2FPilot%2FJournal"}])
        self.assertEqual([(a["title"], a["icon"]) for a in journal["inline"]],
                         [("Copy wikilink", "🔗"), ("Copy path", "📋"), ("Reveal in Finder", "📂")])

        self.run_ext("find", input="zebra crossing")
        rows = self.page()[2]["items"]
        self.assertEqual(rows[0]["title"], "No note matches “zebra crossing”")
        self.assertNotIn("inline", rows[0])
        self.run_ext("find", input="")
        self.assertEqual(self.page()[1]["title"], "Recent in Notes Vault")

    def test_the_page_without_a_vault_says_how_to_set_one(self):
        (self.box.home / "Library" / "Application Support" / "obsidian" / "obsidian.json").unlink()
        blocks = self.page()
        self.assertEqual(blocks[0]["type"], "input")
        self.assertIn("found no Obsidian vault", blocks[1]["text"])
