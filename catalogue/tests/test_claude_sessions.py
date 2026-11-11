import json
import os

from harness import ExtensionTestCase

SECRET_TAIL = "THE-REST-OF-THIS-PROMPT-MUST-NEVER-BE-PRINTED"


class ClaudeSessionsTests(ExtensionTestCase):
    EXTENSION = "claude-sessions"

    def setUp(self):
        super().setUp()
        self.projects = self.box.home / ".claude" / "projects"
        self.work = self.box.home / "code" / "my app"
        self.work.mkdir(parents=True)
        self.clock = 1_800_000_000

    def session(self, sid, lines, project="-Users-x-my-app", age=0):
        folder = self.projects / project
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / ("%s.jsonl" % sid)
        path.write_text("".join(json.dumps(line, separators=(",", ":")) + "\n" for line in lines))
        os.utime(path, (self.clock - age, self.clock - age))
        return path

    def user(self, content, **extra):
        line = {"type": "user", "cwd": str(self.work), "gitBranch": "main", "timestamp": "2026-10-09T08:00:00.000Z",
                "sessionId": "x", "message": {"role": "user", "content": content}}
        line.update(extra)
        return line

    def assistant(self, model="claude-opus-5-5"):
        return {"type": "assistant", "message": {"role": "assistant", "model": model, "content": [{"type": "text", "text": "ok"}]}}

    def items(self):
        r = self.run_ext("sessions", home=self.box.home)
        self.assertItemShape(r.items)
        self.assertLess(r.elapsed, 2)
        self.assertNotIn(SECRET_TAIL, r.stdout)
        return r.items

    def test_lists_sessions_newest_first_with_title_folder_and_age(self):
        self.session("aaa", [{"type": "permission-mode", "permissionMode": "default"},
                             self.user("Fix the login bug please"), self.assistant(),
                             {"type": "ai-title", "aiTitle": "Login bug fix", "sessionId": "aaa"}], age=7200)
        self.session("bbb", [self.user("x" * 30 + " and then much more " + "y" * 60 + SECRET_TAIL)], age=60)
        items = self.items()
        self.assertEqual([i["id"] for i in items], ["bbb", "aaa"])
        self.assertEqual(items[1]["title"], "Login bug fix")
        self.assertLessEqual(len(items[0]["title"]), 80)
        self.assertTrue(items[0]["title"].endswith("…"))
        self.assertTrue(items[1]["subtitle"].startswith("~/code/my app · "))

    def test_actions_copy_the_resume_command_inside_its_folder(self):
        path = self.session("abc-123", [self.user("hello")])
        item = self.items()[0]
        resume = "cd '%s' && claude --resume abc-123" % self.work
        self.assertEqual(item["actions"][0], {"type": "copy", "text": resume, "title": "Copy resume command"})
        self.assertEqual(item["actions"][1]["type"], "paste")
        self.assertEqual(item["actions"][2], {"type": "push", "command": "session", "title": "Show details",
                                              "context": {"file": str(path)}})
        self.assertEqual(item["actions"][3], {"type": "open", "url": str(self.work), "title": "Open folder"})

    def test_titles_skip_meta_tool_results_and_name_slash_commands(self):
        self.session("cmd", [self.user("<local-command-stdout>noise</local-command-stdout>"),
                             self.user("<command-name>/review</command-name><command-args>the branch</command-args>")])
        self.session("meta", [self.user("hidden", isMeta=True),
                              self.user([{"type": "tool_result", "content": "x"}]),
                              self.user([{"type": "text", "text": "<pasted_content id=1>\nRepo: thing</pasted_content>"}])],
                     age=10)
        self.session("none", [self.user([{"type": "tool_result", "content": "x"}])], age=20)
        titles = {i["id"]: i["title"] for i in self.items()}
        self.assertEqual(titles, {"cmd": "/review the branch", "meta": "Repo: thing", "none": "Session none"})

    def test_a_title_written_late_in_a_long_transcript_is_found(self):
        filler = [self.assistant() for _ in range(6000)]
        self.session("long", [self.user("start")] + filler + [{"type": "ai-title", "aiTitle": "Late title"}])
        self.assertGreater((self.projects / "-Users-x-my-app" / "long.jsonl").stat().st_size, 512 * 1024)
        self.assertEqual(self.items()[0]["title"], "Late title")

    def test_subagent_files_are_left_out_and_the_list_is_capped(self):
        self.session("agent-1", [self.user("sub")])
        for n in range(65):
            self.session("s%02d" % n, [self.user("p")], age=n)
        items = self.items()
        self.assertEqual(len(items), 60)
        self.assertNotIn("agent-1", [i["id"] for i in items])
        self.assertTrue((self.box.cache / "sessions.json").exists())
        self.assertEqual(len(self.items()), 60, "the cached second read lists the same")

    def test_no_sessions_is_one_plain_row(self):
        self.assertEqual(self.items()[0]["title"], "No Claude Code sessions yet")

    def test_detail_of_a_pushed_session_and_of_the_newest(self):
        old = self.session("old", [self.user("old one"), self.assistant("claude-haiku-4-5")], age=600)
        self.session("new", [self.user("new one"), self.assistant(), self.assistant()])
        d = self.run_ext("session", home=self.box.home, context={"file": str(old)}).detail
        facts = {f["label"]: f["text"] for f in d["metadata"]}
        self.assertEqual((facts["Folder"], facts["Branch"], facts["Model"], facts["Session"], facts["Messages"]),
                         ("~/code/my app", "main", "claude-haiku-4-5", "old", "2"))
        self.assertIn("claude --resume old", d["markdown"])
        for a in d["actions"]:
            self.assertActionShape(a)
        d = self.run_ext("session", home=self.box.home).detail
        self.assertEqual({f["label"]: f["text"] for f in d["metadata"]}["Session"], "new")

    def test_detail_refuses_a_file_outside_the_projects_folder(self):
        outside = self.box.home / "x.jsonl"
        outside.write_text("{}\n")
        r = self.run_ext("session", home=self.box.home, context={"file": str(outside)})
        self.assertEqual(r.of_type("error"), [{"type": "error", "text": "that session is gone"}])

    def test_the_page_searches_sessions_as_typed_and_a_click_copies_the_resume_command(self):
        self.session("aaa", [self.user("Fix the login bug please"), {"type": "ai-title", "aiTitle": "Login bug fix"}],
                     age=7200)
        self.session("bbb", [self.user("Draw the widget page " + "y" * 70 + SECRET_TAIL)], project="-Users-x-other", age=60)
        result = self.run_ext("page", surface="page")
        self.assertNotIn(SECRET_TAIL, result.stdout)
        blocks = self.page()
        self.assertEqual(blocks[0]["type"], "input")
        self.assertTrue(blocks[0]["live"])
        rows = blocks[1]["items"]
        self.assertEqual([r["id"] for r in rows], ["bbb", "aaa"])
        self.assertEqual(rows[1]["actions"], [{"type": "copy", "text": "cd '%s' && claude --resume aaa" % self.work,
                                               "title": "Copy resume command"}])
        self.assertEqual([(a["type"], a["icon"]) for a in rows[1]["inline"]], [("open", "📂"), ("copy", "🆔")])

        self.run_ext("find", input="login")
        blocks = self.page()
        self.assertEqual(blocks[1]["actions"][0], {"type": "run", "command": "find", "title": "Clear “login”",
                                                   "context": {"clear": True}})
        self.assertEqual([r["id"] for r in blocks[2]["items"]], ["aaa"])
        self.run_ext("find", input="nope")
        self.assertEqual(self.page()[-1], {"type": "markdown", "text": "No session matches “nope”."})
        self.run_ext("find", input="x", context={"clear": True})
        self.assertEqual(len(self.page()), 2)

    def test_the_page_with_no_sessions_says_so(self):
        self.assertIn("No Claude Code sessions yet", self.page()[-1]["text"])
