import json
import time
from datetime import datetime, timezone
from unittest import mock

import harness
from harness import ExtensionTestCase


def stamp(seconds_ago):
    return datetime.fromtimestamp(time.time() - seconds_ago, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def session(ref, title, project, status, activity="idle", agent="claude", kind="agent", **extra):
    s = {"globalRef": ref, "sessionId": ref.rsplit(":", 1)[-1], "title": title, "displayTitle": title,
         "projectName": project, "kind": kind, "status": status, "activity": activity,
         "isSleeping": status == "sleep", "lastInteractionAt": stamp(extra.pop("age", 60)),
         "actions": None if status == "unknown" else {"focus": status == "running", "sleep": status == "running",
                                                       "wake": status == "sleep", "kill": True}}
    if kind == "agent":
        s["agentId"] = s["agentName"] = agent
    s.update(extra)
    return s


def sessions():
    """Ghostex's sessions answer, each age counted from now: built per test, never at import, so the suite's
    length never ages it."""
    return {"ok": True, "projects": [{"customAgents": [{"agentId": "custom-designer-x1", "name": "designer"}]}],
            "sessions": [
                session("S1:P1:G1", "Asleep long ago", "pilot", "sleep", age=86400 * 3),
                session("S1:P1:G2", "Idle one", "pilot", "running", age=600, sessionTag="testing"),
                session("S1:P2:G3", "Busy build", "agents", "running", "working", age=5, queuedPromptCount=2,
                        coordinatorRole="thread", coordinatorSessionId="G5"),
                session("S1:P1:G4", "Design pass", "pilot", "running", "working", agent="custom-designer-x1", age=30,
                        sessionTag="custom-abcd1", coordinatorRole="thread", coordinatorSessionId="G5"),
                session("S1:P2:G5", "Needs an answer", "agents", "running", pendingQuestionCount=1, age=120,
                        sessionTag="testing", coordinatorRole="coordinator"),
                session("S1:P3:G6", "old-terminal", "dotfiles", "unknown", kind="terminal", age=86400 * 30),
                session("S1:P1:G7", "Parked", "pilot", "sleep", isParked=True, age=86400 * 9, sessionTag="done"),
                {"title": "no ref, skipped"},
                session("all", "bad ref, skipped", "pilot", "running"),
            ]}

TAGS = {"ok": True, "customSessionTags": {"order": ["custom-abcd1"], "tags": {
    "custom-abcd1": {"name": "Client", "icon": "star", "color": "#ff8800", "tagId": "custom-abcd1"}}}}

SENDER = ("\n\nMessage from another agent\nAgent: Claude\nSession: Pilot coordinator 3\nSession ID: G2j79\n"
          "Agent ID: claude\nAgent Session ID: x\nReply to: S60:P73tc:G2j79")


def row(role, *blocks, at=1791628500):
    return {"id": "m%s" % at, "role": role, "blocks": list(blocks), "timestamp": at * 1000, "source": "transcript"}


def text(t):
    return {"type": "text", "text": t}


def call(name):
    return {"type": "tool-call", "name": name, "input": {}, "callId": "c"}


RESULT = {"type": "tool-result", "output": "exit 0"}
CHAT = {"ok": True, "fingerprint": "fp1", "working": True, "queue": [], "messages": [
    row("user", text("first question"), at=100),
    row("assistant", text("first answer"), at=101),
    row("user", text("build 16 is in. **AI usage** is ass" + SENDER), at=102),
    row("assistant", call("Bash"), at=103), row("tool", RESULT, at=104),
    row("assistant", call("Read"), at=105), row("tool", RESULT, at=106),
    row("assistant", text("Reading the code."), call("Grep"), at=107), row("tool", RESULT, at=108),
    row("user", text("<task-notification>\n<task-id>x</task-id></task-notification>"), at=109),
    row("assistant", text("Started thread *Surfaces v2 design*."), at=110),
    row("user", text("<bash-input>ls</bash-input>"), at=110.5),
    row("user", text("go on"), at=111),
    row("assistant", text("x" * 2000), at=112),
    row("system", text("compacted"), at=113),
    row("assistant", call("Edit"), at=114), row("tool", RESULT, at=115),
]}

FAKE = r'''"""A ghostex that logs each call's arguments as one JSON line and never reaches the real app: each verb answers
from the config's entry for it (stdout, stderr, exit, sleep), else {"ok": true}."""
import json, sys, time
CONFIG, LOG = %r, %r
with open(LOG, "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\n")
with open(CONFIG) as f:
    answer = json.load(f).get(sys.argv[1] if len(sys.argv) > 1 else "", {"stdout": '{"ok": true}'})
time.sleep(answer.get("sleep", 0))
sys.stdout.write(answer.get("stdout", ""))
sys.stderr.write(answer.get("stderr", ""))
sys.exit(answer.get("exit", 0))
'''

REFS = {"S1:P1:G1", "S1:P1:G2", "S1:P2:G3", "S1:P1:G4", "S1:P2:G5", "S1:P3:G6", "S1:P1:G7"}
READS = ("sessions", "read-session-chat", "read-custom-session-tags")


class GhostexTests(ExtensionTestCase):
    EXTENSION = "ghostex"

    def setUp(self):
        super().setUp()
        self.config = {}
        self.sessions = sessions()
        self.fake("sessions", self.sessions)
        self.fake("read-custom-session-tags", TAGS)
        self.fake("read-session-chat", CHAT)
        fake = self.box.root / "fake_ghostex.py"
        fake.write_text(FAKE % (str(self.box.root / "fake.json"), str(self.box.root / "ghostex.log")))
        self.box.shim("ghostex", 'exec python3 "%s" "$@"' % fake)
        self.box.shim("open")

    def fake(self, verb, body=None, **raw):
        self.config[verb] = dict({"stdout": json.dumps(body)} if body is not None else {}, **raw)
        (self.box.root / "fake.json").write_text(json.dumps(self.config))

    def calls(self):
        log = self.box.root / "ghostex.log"
        return [json.loads(l) for l in log.read_text().splitlines()] if log.exists() else []

    def writes(self):
        return [c for c in self.calls() if c[0] not in READS]

    def assertOneSession(self, ref):
        """Every write names exactly the one session, by its ref, and never all."""
        for c in self.writes():
            named = [a for a in c if any(r in a for r in REFS | {"all"})]
            self.assertEqual(len(named), 1, c)
            self.assertIn(ref, named[0], c)
            self.assertNotIn("all", c)

    def items(self, **kwargs):
        r = self.run_ext("sessions", **kwargs)
        self.assertItemShape(r.items)
        self.assertLess(r.elapsed, 2)
        return r.items

    def rows(self, blocks):
        return {i["title"]: i for b in blocks if b["type"] == "list" for i in b["items"]}

    def chat(self, ref="S1:P2:G3", **kwargs):
        return self.blocks("chat", "popover", context={"ref": ref, "title": "Busy build"}, **kwargs)

    def run_write(self, command, context, input=None):
        r = self.run_ext(command, context=context, input=input)
        for m in r.messages:
            self.assertIn(m["type"], ("hud", "error"), m)
        return r

    # ---- Hyper+Space, as 1.1.0 ----

    def test_lists_sessions_by_what_needs_you_and_return_focuses(self):
        items = self.items()
        self.assertEqual([i["title"] for i in items],
                         ["Needs an answer", "Busy build", "Design pass", "Idle one", "Asleep long ago", "Parked",
                          "old-terminal"])
        rows = {i["title"]: i for i in items}
        self.assertEqual(rows["Design pass"]["subtitle"], "pilot · designer · working · just now")
        self.assertEqual(rows["Parked"]["subtitle"], "pilot · Claude · asleep, parked · 9 d ago")
        self.assertEqual(rows["Idle one"]["actions"][0], {"type": "run", "command": "focus", "title": "Focus in Ghostex",
                                                          "context": {"ref": "S1:P1:G2", "wake": False}})
        self.assertEqual(rows["Asleep long ago"]["actions"][0]["title"], "Wake and focus in Ghostex")
        self.assertEqual(self.calls(), [["sessions", "--json", "--full"]])

    def test_focus_on_a_sleeping_session_wakes_it_first_then_brings_ghostex_forward(self):
        r = self.run_write("focus", {"ref": "S1:P1:G1", "wake": True})
        self.assertEqual(self.calls(), [["wake", "--session-id", "S1:P1:G1", "--json"],
                                        ["focus", "--session-id", "S1:P1:G1", "--json"]])
        self.assertEqual(self.box.shim_calls(), ["open -a Ghostex"])
        self.assertEqual(r.of_type("hud")[0]["text"], "Woken and focused in Ghostex")

    def test_ghostex_failing_hung_or_missing_shows_one_honest_row(self):
        self.fake("sessions", stderr="Error: gxserver is not running\n", exit=1)
        self.assertEqual(self.items()[0]["subtitle"], "Error: gxserver is not running")
        self.fake("sessions", sleep=5)
        self.assertEqual(self.items()[0]["subtitle"], "Ghostex did not answer in time: is it running?")
        (self.box.shims / "ghostex").unlink()
        hide = mock.patch.object(harness, "SYSTEM_PATH", "/usr/bin:/bin:/usr/sbin:/sbin")  # the real CLI is in Homebrew's
        hide.start()
        self.addCleanup(hide.stop)
        self.assertIn("ghostex is not installed", self.items()[0]["subtitle"])

    def test_show_keeps_orchestrators_or_one_agent_in_the_list(self):
        def titles(show):
            return [i["title"] for i in self.items(preferences={"show": show})]
        self.assertEqual(titles("coordinator"), ["Needs an answer"])
        self.assertEqual(titles("designer"), ["Design pass"])
        self.assertEqual(titles("claude"), ["Needs an answer", "Busy build", "Idle one", "Asleep long ago", "Parked"])
        self.assertEqual(titles("all"), [i["title"] for i in self.items()])
        none = self.items(preferences={"show": "codex"})
        self.assertEqual([(i["title"], i["icon"]) for i in none], [("No Codex sessions in Ghostex", "👻")])

    def test_show_narrows_the_bar_popover_and_page_alike(self):
        orchestrators = {"show": "coordinator"}
        self.assertEqual((self.bar(preferences=orchestrators)["text"]), "👻 1")
        self.assertEqual([(b.get("title"), [i["title"] for i in b["items"]]) for b in self.popover(preferences=orchestrators)],
                         [("Need you", ["Needs an answer"])])
        blocks = self.page(preferences=orchestrators)
        self.assertEqual([s["value"] for s in blocks[0]["items"]], ["1", "0", "0", "0"])
        self.assertEqual([(b["title"], [i["title"] for i in b["items"]]) for b in blocks[1:]],
                         [("agents", ["Needs an answer"])])
        codex = {"show": "codex"}
        self.assertEqual(self.bar(preferences=codex)["text"], "👻")
        self.assertEqual(self.popover(preferences=codex), [{"type": "markdown", "text": "No Codex session is awake."}])
        self.assertEqual(self.page(preferences=codex)[-1],
                         {"type": "markdown", "text": "No Codex sessions. Show, in the extension's settings, picks which."})

    def test_a_reply_reaches_a_session_show_leaves_out(self):
        r = self.run_ext("send", context={"ref": "S1:P1:G2"}, input="hi", preferences={"show": "codex"})
        self.assertEqual(self.writes(), [["send-session-chat-message", "--session-id=S1:P1:G2", "--text=hi", "--json"]])
        self.assertEqual(r.of_type("hud")[0]["text"], "Sent")

    # ---- bar and popover ----

    def test_bar_is_amber_with_how_many_need_you(self):
        line = self.bar()
        self.assertEqual((line["text"], line["tone"]), ("👻 1", "warn"))

    def test_bar_counts_working_sessions_and_is_the_ghost_alone_when_none_work(self):
        quiet = dict(self.sessions, sessions=[s for s in self.sessions["sessions"] if s.get("pendingQuestionCount") is None])
        self.fake("sessions", quiet)
        line = self.bar()
        self.assertEqual((line["text"], line.get("tone")), ("👻 2", None))
        self.assertEqual([b.get("title") for b in line["blocks"]], ["Working", "Idle", None])
        self.fake("sessions", {"ok": True, "sessions": [s for s in quiet["sessions"] if s.get("activity") != "working"]})
        self.assertEqual(self.bar()["text"], "👻")

    def test_bar_says_why_when_ghostex_is_not_there(self):
        self.fake("sessions", stderr="Error: gxserver is not running\n", exit=1)
        line = self.bar()
        self.assertEqual(line["text"], "👻")
        self.assertEqual(line["blocks"], [{"type": "markdown",
                                           "text": "Ghostex sessions are not available: Error: gxserver is not running"}])

    def test_popover_groups_need_you_working_idle_then_the_sleeping_ones(self):
        blocks = self.popover()
        lists = [(b.get("title"), [i["title"] for i in b["items"]]) for b in blocks]
        self.assertEqual(lists, [("Need you", ["Needs an answer"]), ("Working", ["Busy build", "Design pass"]),
                                 ("Idle", ["Idle one"]), (None, ["2 asleep ›"])])
        self.assertEqual(blocks[-1]["items"][0]["actions"], [{"type": "push", "command": "asleep",
                                                              "title": "Show sleeping sessions"}])
        busy = blocks[1]["items"][0]
        self.assertEqual(busy["subtitle"], "agents · Claude · just now")
        self.assertEqual(busy["actions"][0], {"type": "push", "command": "chat", "title": "Open chat", "icon": "bubble",
                                              "context": {"ref": "S1:P2:G3", "title": "Busy build"}})
        self.assertNotIn("inline", busy)
        asleep = self.blocks("asleep", "popover")
        self.assertEqual([i["title"] for i in asleep[0]["items"]], ["Asleep long ago", "Parked"])

    # ---- page ----

    def test_page_counts_states_then_lists_each_project(self):
        blocks = self.page()
        self.assertEqual(blocks[0]["items"], [
            {"label": "Need you", "value": "1", "tone": "warn"}, {"label": "Working", "value": "2", "tone": "fine"},
            {"label": "Idle", "value": "1"}, {"label": "Asleep", "value": "2"}])
        lists = [(b["title"], [i["title"] for i in b["items"]]) for b in blocks[1:]]
        self.assertEqual(lists, [("agents", ["Needs an answer", "Busy build"]),
                                 ("pilot", ["Design pass", "Idle one", "Asleep long ago", "Parked"]),
                                 ("dotfiles", ["old-terminal"])])
        self.assertEqual(self.calls(), [["sessions", "--json", "--full"], ["read-custom-session-tags", "--json"]])

    def test_page_rows_carry_badges_inline_reply_and_sleep_or_wake_and_a_full_menu(self):
        rows = self.rows(self.page())
        self.assertEqual(rows["Busy build"]["badges"], [{"text": "working", "tone": "fine"}, {"text": "2 queued"}])
        self.assertEqual(rows["Design pass"]["badges"], [{"text": "working", "tone": "fine"}, {"text": "client"}])
        self.assertEqual(rows["Needs an answer"]["badges"], [{"text": "needs you", "tone": "warn"}, {"text": "testing"}])
        self.assertEqual(rows["Parked"]["badges"], [{"text": "asleep"}, {"text": "done"}])
        self.assertEqual(rows["Busy build"]["subtitle"], "Claude · just now")
        self.assertEqual([(a["title"], a["icon"]) for a in rows["Idle one"]["inline"]],
                         [("Reply", "bubble"), ("Sleep", "moon"), ("Close…", "xmark")])
        self.assertEqual([(a["title"], a["icon"]) for a in rows["Parked"]["inline"]],
                         [("Reply", "bubble"), ("Wake", "sun"), ("Close…", "xmark")])
        self.assertEqual(rows["Idle one"]["inline"][2]["ask"], {"confirm": "Close Idle one? Its terminal ends."})
        self.assertEqual([a["title"] for a in rows["Idle one"]["actions"]],
                         ["Reply", "Rename…", "Tag", "Sleep", "Open in Ghostex", "Close…"])
        self.assertEqual([a["title"] for a in rows["old-terminal"]["actions"]],
                         ["Reply", "Rename…", "Tag", "Open in Ghostex", "Close…"])
        # No sleep or wake for a terminal Ghostex can't act on: Rename takes its place.
        self.assertEqual([a["title"] for a in rows["old-terminal"]["inline"]], ["Reply", "Rename…", "Close…"])
        for item in rows.values():
            for button in item["inline"]:
                self.assertIn(button, item["actions"])  # an older Pilot reaches every inline through ⋯

    def test_rename_tag_and_close_ask_first(self):
        actions = {a["title"]: a for a in self.rows(self.page())["Idle one"]["actions"]}
        self.assertEqual(actions["Rename…"]["ask"], {"text": "Idle one"})
        self.assertEqual(actions["Close…"]["ask"], {"confirm": "Close Idle one? Its terminal ends."})
        self.assertIs(actions["Close…"]["destructive"], True)
        self.assertEqual(actions["Close…"]["context"], {"ref": "S1:P1:G2", "title": "Idle one"})
        # Sven's own tags first, then the built-ins in use most, then Ghostex's order; its own tag left out, No tag last.
        self.assertEqual(actions["Tag"]["ask"]["choices"], [
            {"title": "Client", "value": "custom-abcd1"}, {"title": "Done", "value": "done"},
            {"title": "Favorite", "value": "favorite"}, {"title": "High priority", "value": "high-priority"},
            {"title": "Low priority", "value": "low-priority"}, {"title": "Todo", "value": "todo"},
            {"title": "Research", "value": "research"}, {"title": "No tag", "value": "none"}])
        untagged = {a["title"]: a for a in self.rows(self.page())["Busy build"]["actions"]}
        choices = untagged["Tag"]["ask"]["choices"]
        self.assertEqual(len(choices), 8)
        self.assertEqual([c["value"] for c in choices[:3]], ["custom-abcd1", "testing", "done"])
        self.assertNotIn("none", [c["value"] for c in choices])

    def test_page_says_why_ghostex_is_not_there(self):
        self.fake("sessions", stderr="Error: gxserver is not running\n", exit=1)
        self.assertEqual(self.page(), [{"type": "markdown", "text": "Ghostex sessions are not available: Error: gxserver is not running"}])

    # ---- chat ----

    def test_chat_folds_tool_work_and_shows_the_last_six_messages(self):
        answer = self.blocks_message("chat", "popover", context={"ref": "S1:P2:G3", "title": "Busy build"})
        self.assertEqual(answer["refresh"], 2)
        blocks = answer["blocks"]
        chat = blocks[0]
        self.assertEqual(chat["type"], "chat")
        self.assertIs(chat["working"], True)
        self.assertEqual([(m["role"], m["text"][:40]) for m in chat["messages"]], [
            ("assistant", "first answer"),
            ("user", "build 16 is in. **AI usage** is ass\n\n*fr"),
            ("tool", "ran 2 tools"),
            ("assistant", "Reading the code."),
            ("tool", "ran 2 tools"),
            ("assistant", "Started thread *Surfaces v2 design*."),
            ("tool", "ran Bash"),
            ("user", "go on"),
            ("assistant", "x" * 40),
            ("tool", "ran Edit")])
        messages = chat["messages"]
        self.assertTrue(messages[1]["text"].endswith("*from Pilot coordinator 3*"))
        self.assertEqual(len(messages[8]["text"]), 1500)
        self.assertEqual(messages[0]["at"], 101)
        self.assertEqual(self.calls()[-1], ["read-session-chat", "S1:P2:G3", "--limit", "200", "--json"])

    def test_chat_keeps_the_users_last_message_past_a_long_run_of_answers(self):
        answers = []
        for n in range(8):
            answers += [row("assistant", text("step %d" % n), call("Bash"), at=120 + 2 * n), row("tool", RESULT, at=121 + 2 * n)]
        self.fake("read-session-chat", dict(CHAT, messages=CHAT["messages"] + answers))
        messages = self.chat()[0]["messages"]
        self.assertEqual([(m["role"], m["text"]) for m in messages[:4]], [
            ("user", "go on"), ("tool", "4 more messages"), ("assistant", "step 3"), ("tool", "ran Bash")])
        self.assertEqual([m["text"] for m in messages if m["role"] == "assistant"], ["step %d" % n for n in range(3, 8)])

    def test_chat_has_a_reply_box_return_queues_option_return_interrupts(self):
        blocks = self.chat()
        box = blocks[1]
        self.assertEqual(box["placeholder"], "Reply to Busy build…")
        self.assertEqual(box["action"], {"type": "run", "command": "send", "title": "Queue",
                                         "context": {"ref": "S1:P2:G3", "title": "Busy build"}})
        self.assertEqual(box["alt"]["context"], {"ref": "S1:P2:G3", "title": "Busy build", "interrupt": True})
        self.assertEqual(blocks[2], {"type": "markdown", "text": "2 waiting in its queue"})
        self.assertEqual([a["title"] for a in blocks[3]["actions"]], ["Open in Ghostex", "Sleep"])
        asleep = self.chat("S1:P1:G1")
        self.assertEqual(asleep[1]["placeholder"], "Reply wakes Asleep long ago…")
        self.assertEqual(asleep[1]["action"]["title"], "Send")
        # No queue, no line: Pilot draws the one hint under the box.
        self.assertEqual([a["title"] for a in asleep[2]["actions"]], ["Open in Ghostex", "Wake"])
        self.assertEqual(self.writes(), [])

    def test_chat_asked_again_long_polls_with_the_last_fingerprint(self):
        self.chat()
        self.chat()
        reads = [c for c in self.calls() if c[0] == "read-session-chat"]
        self.assertEqual(reads[1], ["read-session-chat", "S1:P2:G3", "--limit", "200", "--json", "--wait-ms", "2000",
                                    "--fingerprint", "fp1"])
        cache = self.box.cache / "chat.json"
        reads_file = json.loads(cache.read_text())
        reads_file["S1:P2:G3"]["at"] -= 30  # a first open, long after the last read
        cache.write_text(json.dumps(reads_file))
        self.chat()
        self.assertEqual([c for c in self.calls() if c[0] == "read-session-chat"][2][-1], "--json")

    def test_a_chat_that_does_not_read_says_why_and_keeps_its_buttons(self):
        self.fake("read-session-chat", {"ok": False, "error": "No session matched."}, exit=1)
        blocks = self.chat()
        self.assertEqual(blocks[0], {"type": "markdown", "text": "Can't read this chat: No session matched."})
        self.assertEqual(blocks[-1]["type"], "buttons")

    # ---- writes: each names one session ----

    def test_return_to_a_working_agent_queues_until_it_stops(self):
        r = self.run_write("send", {"ref": "S1:P2:G3"}, input="looks good, commit it")
        self.assertEqual(self.writes(), [["queue-session-chat-prompt", "--session-id=S1:P2:G3",
                                          "--text=looks good, commit it", "--json"]])
        self.assertEqual(r.of_type("hud")[0]["text"], "Queued until it stops")
        self.assertOneSession("S1:P2:G3")

    def test_return_to_an_idle_agent_sends_at_once(self):
        r = self.run_write("send", {"ref": "S1:P1:G2"}, input="next one")
        self.assertEqual(self.writes(), [["send-session-chat-message", "--session-id=S1:P1:G2", "--text=next one", "--json"]])
        self.assertEqual(r.of_type("hud")[0]["text"], "Sent")

    def test_option_return_interrupts_a_working_agent_then_sends(self):
        r = self.run_write("send", {"ref": "S1:P2:G3", "interrupt": True}, input="stop, wrong file")
        self.assertEqual(self.writes(), [["interrupt-session-chat", "--session-id=S1:P2:G3"],
                                         ["send-session-chat-message", "--session-id=S1:P2:G3", "--text=stop, wrong file",
                                          "--json"]])
        self.assertEqual(r.of_type("hud")[0]["text"], "Interrupted and sent")
        self.assertOneSession("S1:P2:G3")

    def test_option_return_to_an_idle_agent_has_nothing_to_interrupt(self):
        self.run_write("send", {"ref": "S1:P1:G2", "interrupt": True}, input="hi")
        self.assertEqual([c[0] for c in self.writes()], ["send-session-chat-message"])

    def test_a_sleeping_session_is_woken_then_sent_to(self):
        for interrupt in (False, True):
            r = self.run_write("send", {"ref": "S1:P1:G1", "interrupt": interrupt}, input="wake up")
            self.assertEqual(r.of_type("hud")[0]["text"], "Woken and sent")
        self.assertEqual(self.writes(), [["wake", "--session-id", "S1:P1:G1", "--json"],
                                         ["send-session-chat-message", "--session-id=S1:P1:G1", "--text=wake up", "--json"]] * 2)
        self.assertOneSession("S1:P1:G1")

    def test_a_reply_that_looks_like_a_flag_stays_text(self):
        self.run_write("send", {"ref": "S1:P1:G2"}, input="--help")
        self.assertEqual(self.writes(), [["send-session-chat-message", "--session-id=S1:P1:G2", "--text=--help", "--json"]])

    def test_a_reply_to_nothing_or_a_session_that_is_gone_sends_nothing(self):
        r = self.run_write("send", {"ref": "S1:P1:G2"}, input="   ")
        self.assertEqual(r.of_type("error")[0]["text"], "got no reply to send")
        r = self.run_write("send", {"ref": "S9:P9:G9"}, input="hi")
        self.assertEqual(r.of_type("error")[0]["text"], "could not send: that session is gone from Ghostex")
        r = self.run_write("send", {"ref": "S1:P3:G6"}, input="hi")
        self.assertEqual(r.of_type("error")[0]["text"], "could not send: it is not running, open it in Ghostex")
        self.assertEqual(self.writes(), [])

    def test_a_refused_send_says_why(self):
        self.fake("queue-session-chat-prompt", {"ok": False, "error": "Queue is full."}, exit=1)
        r = self.run_write("send", {"ref": "S1:P2:G3"}, input="hi")
        self.assertEqual(r.of_type("error")[0]["text"], "could not send: Queue is full.")

    def test_rename_takes_the_typed_title(self):
        r = self.run_write("rename", {"ref": "S1:P1:G2", "title": "Idle one"}, input="  Layout rework build ")
        self.assertEqual(self.writes(), [["rename-session", "--session-id=S1:P1:G2", "--title=Layout rework build", "--json"]])
        self.assertEqual(r.of_type("hud")[0]["text"], "Renamed")
        r = self.run_write("rename", {"ref": "S1:P1:G2"}, input="")
        self.assertEqual(r.of_type("error")[0]["text"], "got no new title")
        self.assertEqual(len(self.writes()), 1)

    def test_tag_takes_a_built_in_a_custom_tag_or_none_and_nothing_else(self):
        for value in ("high-priority", "custom-abcd1", "none"):
            self.run_write("tag", {"ref": "S1:P1:G2"}, input=value)
        self.assertEqual(self.writes(), [["tag-session", "--session-id=S1:P1:G2", "--tag=%s" % v, "--json"]
                                         for v in ("high-priority", "custom-abcd1", "none")])
        for value in ("all", "--help", "urgent", ""):
            r = self.run_write("tag", {"ref": "S1:P1:G2"}, input=value)
            self.assertEqual(r.of_type("error")[0]["text"], "got no tag to set")
        self.assertEqual(len(self.writes()), 3)
        self.assertOneSession("S1:P1:G2")

    def test_close_sleep_and_wake_name_the_one_session(self):
        r = self.run_write("close", {"ref": "S1:P1:G2", "title": "Idle one"})
        self.assertEqual(r.of_type("hud")[0]["text"], "Session closed")
        self.run_write("sleep", {"ref": "S1:P1:G2"})
        self.run_write("wake", {"ref": "S1:P1:G2"})
        self.assertEqual(self.writes(), [[verb, "--session-id", "S1:P1:G2", "--json"] for verb in ("kill", "sleep", "wake")])
        self.assertOneSession("S1:P1:G2")

    def test_no_command_acts_without_exactly_one_session_ref(self):
        tries = [(command, {"ref": "all"}) for command in ("send", "rename", "tag", "close", "sleep", "wake", "focus")]
        tries += [("close", c) for c in ({"ref": "S1:P1:G2 all"}, {"ref": "--help"}, {"ref": ["S1:P1:G2"]}, {}, None)]
        for command, context in tries:
            r = self.run_write(command, context, input="done")
            self.assertEqual(r.of_type("error")[0]["text"], "got no Ghostex session to act on")
        self.assertEqual(self.calls(), [])

    def test_every_action_the_surfaces_offer_names_one_session(self):
        blocks = self.page() + self.popover() + self.chat()
        actions = [a for b in blocks if b["type"] == "list" for i in b["items"] for a in i["actions"]]
        actions += [b[k] for b in blocks if b["type"] == "input" for k in ("action", "alt")]
        actions += [a for b in blocks if b["type"] == "buttons" for a in b["actions"]]
        for action in actions:
            if action["command"] != "asleep":
                self.assertIn(action["context"]["ref"], REFS, action)
