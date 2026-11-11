import json
import time

from harness import ExtensionTestCase


class PomodoroTests(ExtensionTestCase):
    EXTENSION = "pomodoro"

    def state(self):
        return json.loads((self.box.data / "state.json").read_text())

    def write_state(self, **fields):
        state = {"day": time.strftime("%Y-%m-%d"), "count": 0, "block": None}
        state.update(fields)
        (self.box.data / "state.json").write_text(json.dumps(state))

    def block(self, phase="focus", left=None, ends_in=600, long=False):
        return {"id": "b1", "phase": phase, "long": long, "length": 1500, "ends": time.time() + ends_in, "left": left}

    def timer(self, result):
        timers = [a for a in result.actions if a["type"] == "timer"]
        self.assertEqual(len(timers), 1, result.actions)
        self.assertActionShape(timers[0])
        for a in timers[0].get("actions", []) + ([timers[0]["end"]] if "end" in timers[0] else []):
            self.assertActionShape(a)
        return timers[0]

    def test_focus_starts_a_timer_of_the_focus_length_with_its_buttons(self):
        r = self.run_ext("focus")
        t = self.timer(r)
        self.assertEqual(t["seconds"], 1500)
        self.assertEqual(t["title"], "Focus 1 of 4")
        self.assertFalse(t["paused"])
        self.assertEqual([a["title"] for a in t["actions"]], ["Pause", "Skip", "Stop"])
        self.assertEqual(t["end"]["command"], "ended")
        self.assertEqual(r.actions[0]["type"], "timer", "timer first, then the HUD")
        self.assertTrue(r.actions[1]["text"].startswith("Focus 25 min."))
        self.assertEqual(self.state()["block"]["phase"], "focus")

    def test_focus_length_follows_the_preference_and_a_custom_context(self):
        self.assertEqual(self.timer(self.run_ext("focus", preferences={"focus": "50"}))["seconds"], 3000)
        self.assertEqual(self.timer(self.run_ext("focus", context={"minutes": 7}))["seconds"], 420)
        self.assertEqual(self.timer(self.run_ext("focus", context={"minutes": 500}))["seconds"], 1500)

    def test_break_is_always_the_short_one(self):
        self.write_state(count=4)
        t = self.timer(self.run_ext("break"))
        self.assertEqual((t["seconds"], t["title"]), (300, "Break"))

    def test_custom_puts_a_typed_length_first_then_common_lengths(self):
        r = self.run_ext("custom", query="45")
        self.assertItemShape(r.items)
        self.assertEqual(r.items[0]["title"], "Focus 45 min")
        self.assertEqual(r.items[0]["actions"][0], {"type": "run", "command": "focus", "title": "Start 45 min",
                                                    "context": {"minutes": 45}})
        self.assertEqual([i["title"] for i in r.items].count("Focus 45 min"), 1)
        self.assertEqual(self.run_ext("custom", query="7 min").items[0]["title"], "Focus 7 min")
        self.assertEqual(self.run_ext("custom", query="").items[0]["title"], "Focus 5 min")
        self.assertEqual(self.run_ext("custom", query="300").items[0]["title"], "Focus 5 min")
        self.assertEqual(self.run_ext("custom", query="abc").items[0]["title"], "Focus 5 min")

    def test_pause_holds_the_time_left_and_resume_counts_on(self):
        self.write_state(block=self.block(ends_in=600))
        t = self.timer(self.run_ext("pause"))
        self.assertTrue(t["paused"])
        self.assertIn(t["seconds"], (599, 600, 601))
        self.assertEqual([a["title"] for a in t["actions"]], ["Resume", "Stop"])
        self.assertIsNotNone(self.state()["block"]["left"])
        again = self.run_ext("pause").actions
        self.assertEqual(len(again), 1)
        self.assertTrue(again[0]["text"].startswith("Already paused at "), again)
        t = self.timer(self.run_ext("resume"))
        self.assertFalse(t["paused"])
        self.assertIn(t["seconds"], (599, 600, 601))
        self.assertIsNone(self.state()["block"]["left"])

    def test_pause_resume_skip_without_a_timer_say_so(self):
        self.assertEqual(self.run_ext("pause").actions, [{"type": "hud", "text": "No timer running."}])
        self.assertEqual(self.run_ext("resume").actions, [{"type": "hud", "text": "Nothing paused."}])
        self.assertEqual(self.run_ext("skip").actions, [{"type": "hud", "text": "No timer running."}])

    def test_a_block_whose_end_passed_unseen_counts_as_none(self):
        self.write_state(block=self.block(ends_in=-5))
        self.assertEqual(self.run_ext("pause").actions, [{"type": "hud", "text": "No timer running."}])

    def test_skip_moves_to_the_next_block_without_counting(self):
        self.write_state(count=3, block=self.block("focus"))
        t = self.timer(self.run_ext("skip"))
        self.assertEqual((t["title"], t["seconds"]), ("Break", 300))
        self.assertEqual(self.state()["count"], 3)
        t = self.timer(self.run_ext("skip"))
        self.assertEqual(t["title"], "Focus 4 of 4")

    def test_stop_stops_the_timer_and_clears_the_block(self):
        self.write_state(block=self.block())
        r = self.run_ext("stop")
        self.assertEqual(r.actions, [{"type": "timer", "seconds": 0}, {"type": "hud", "text": "Timer stopped."}])
        self.assertIsNone(self.state()["block"])

    def test_ended_focus_counts_the_block_and_shows_the_alert(self):
        self.write_state(count=2, block=self.block("focus"))
        r = self.run_ext("ended", context={"block": "b1"})
        self.assertEqual(len(r.actions), 1)
        alert = r.actions[0]
        self.assertActionShape(alert)
        self.assertEqual(alert["type"], "alert")
        self.assertEqual((alert["text"], alert["note"], alert["sound"]), ("Focus done", "3rd block today. Take 5.", "Glass"))
        self.assertEqual([a["title"] for a in alert["actions"]], ["Start break", "Stop"])
        for a in alert["actions"]:
            self.assertActionShape(a)
        self.assertEqual(self.state()["count"], 3)
        self.assertIsNone(self.state()["block"])

    def test_the_long_break_comes_every_n_blocks_and_start_break_takes_it(self):
        self.write_state(count=3, block=self.block("focus"))
        alert = self.run_ext("ended", context={"block": "b1"}).actions[0]
        self.assertEqual(alert["note"], "4th block today. Take 15.")
        start_break = alert["actions"][0]
        t = self.timer(self.run_ext(start_break["command"], context=start_break["context"]))
        self.assertEqual((t["title"], t["seconds"]), ("Long break", 900))
        self.assertTrue(self.state()["block"]["long"])

    def test_long_break_every_follows_its_preference(self):
        self.write_state(count=1, block=self.block("focus"))
        alert = self.run_ext("ended", context={"block": "b1", "phase": "focus"},
                             preferences={"longBreakEvery": "2", "longBreak": "30"}).actions[0]
        self.assertEqual(alert["note"], "2nd block today. Take 30.")

    def test_the_day_count_starts_again_on_a_new_day(self):
        self.write_state(day="2001-01-01", count=7, block=self.block("focus"))
        alert = self.run_ext("ended", context={"block": "b1"}).actions[0]
        self.assertEqual(alert["note"], "1st block today. Take 5.")
        self.assertEqual(self.state()["day"], time.strftime("%Y-%m-%d"))

    def test_ended_break_offers_focus_and_has_no_note(self):
        self.write_state(count=1, block=self.block("rest"))
        alert = self.run_ext("ended", context={"block": "b1", "phase": "rest"}, preferences={"sound": "None"}).actions[0]
        self.assertEqual(alert["text"], "Break done")
        self.assertNotIn("note", alert)
        self.assertNotIn("sound", alert)
        self.assertEqual(alert["actions"][0]["title"], "Start focus")
        self.assertEqual(self.state()["count"], 1)

    def test_auto_start_runs_the_next_block_and_says_so_with_the_sound(self):
        self.write_state(count=0, block=self.block("focus"))
        r = self.run_ext("ended", context={"block": "b1", "phase": "focus"}, preferences={"autoStart": True, "sound": "Ping"})
        t = self.timer(r)
        self.assertEqual((t["title"], t["seconds"]), ("Break", 300))
        self.assertEqual(r.actions[-1], {"type": "hud", "text": "Focus done. 1st block today. Take 5.", "sound": "Ping"})
        self.assertEqual(len(r.actions), 2)
        self.assertEqual(self.state()["block"]["phase"], "rest")

    def test_a_stale_end_changes_nothing(self):
        self.write_state(count=2, block=self.block("focus"))
        r = self.run_ext("ended", context={"block": "older"})
        self.assertEqual(r.actions, [{"type": "hud", "text": "Timer done"}])
        self.assertEqual(self.state()["count"], 2)

    def test_the_alerts_stop_leaves_a_newer_block_running(self):
        self.write_state(block=self.block("focus"))
        r = self.run_ext("stop", context={"after": "b0"})
        self.assertEqual(r.actions, [{"type": "hud", "text": "Focus 1 of 4 keeps running."}])
        self.assertIsNotNone(self.state()["block"])
        self.write_state(block=None)
        self.assertEqual(self.run_ext("stop", context={"after": "b0"}).actions, [{"type": "timer", "seconds": 0}])

    def test_today_shows_blocks_what_runs_and_settings(self):
        r = self.run_ext("today")
        d = r.detail
        self.assertIn("**0 focus blocks** today", d["markdown"])
        facts = {f["label"]: f["text"] for f in d["metadata"]}
        self.assertEqual(facts["Now"], "Nothing")
        self.assertEqual(facts["Long break"], "15 min, every 4 blocks")
        self.assertEqual(facts["End sound"], "Glass")
        self.assertEqual([a["title"] for a in d["actions"]], ["Start focus", "Start break"])
        self.write_state(count=4, block=self.block("rest", left=125, long=True))
        d = self.run_ext("today").detail
        facts = {f["label"]: f["text"] for f in d["metadata"]}
        self.assertEqual(facts["Now"], "Long break, paused at 2:05")
        self.assertIn("The next break is the long one.", d["markdown"])
        self.assertEqual([a["title"] for a in d["actions"]], ["Resume", "Stop"])
        for a in d["actions"]:
            self.assertActionShape(a)

    # ---- page (Home block) ----

    def test_page_with_nothing_running_offers_focus_and_break(self):
        self.write_state(count=2)
        message = self.blocks_message("page", "page")
        self.assertNotIn("refresh", message, "nothing counts down, so no fast pace")
        meter, stats, buttons = message["blocks"]
        self.assertEqual((meter["type"], meter["label"], meter["percent"], meter["value"]),
                         ("meter", "Next: Focus 3 of 4", 0, "25:00"))
        self.assertEqual({i["label"]: i["value"] for i in stats["items"]}, {"Blocks today": "2", "Long break after": "2 more"})
        self.assertEqual([a["title"] for a in buttons["actions"]], ["Focus 25 min", "Break 5 min", "Focus for…"])

    def test_page_counts_a_running_focus_down_on_a_5_s_pace(self):
        self.write_state(count=1, block=self.block(ends_in=600))
        message = self.blocks_message("page", "page")
        self.assertEqual(message["refresh"], 5)
        meter, stats, buttons = message["blocks"]
        self.assertEqual(meter["label"], "Focus 2 of 4")
        self.assertIn(meter["value"], ("10:00", "9:59"))
        self.assertAlmostEqual(meter["percent"], 40, delta=0.2)
        self.assertTrue(meter["note"].startswith("Ends ") and "tone" not in meter)
        self.assertEqual(stats["items"][0]["value"], "1")
        self.assertEqual([(a["title"], a["command"]) for a in buttons["actions"]],
                         [("Focus 25 min", "focus"), ("Break 5 min", "break"), ("Focus for…", "focus"), ("Pause", "pause"),
                          ("Skip", "skip"), ("Stop", "stop")])

    def test_page_shows_a_paused_block_held_with_resume(self):
        self.write_state(block=self.block(left=300))
        message = self.blocks_message("page", "page")
        self.assertNotIn("refresh", message, "a paused block does not move")
        meter, _, buttons = message["blocks"]
        self.assertEqual((meter["value"], meter["percent"], meter["note"], meter["tone"]), ("5:00", 20, "Paused", "warn"))
        self.assertEqual([a["title"] for a in buttons["actions"]], ["Focus 25 min", "Break 5 min", "Focus for…", "Resume", "Stop"])

    def test_page_shows_a_break_in_the_fine_tone_and_focus_stores_its_length(self):
        self.run_ext("break")
        self.assertEqual(self.state()["block"]["length"], 300)
        meter = self.page()[0]
        self.assertEqual((meter["label"], meter["tone"]), ("Break", "fine"))
        self.assertGreater(meter["percent"], 99)

    def test_page_says_the_long_break_is_next_as_today_does(self):
        self.write_state(count=4)
        self.assertEqual(self.page()[1]["items"][1]["value"], "next break")

    def test_the_pages_focus_for_picks_a_length_in_its_row_and_starts_it(self):
        # Sven, 2026-10-31: the page does Custom focus's job in place.
        buttons = self.page(preferences={"focus": "30"})[2]["actions"]
        custom = next(a for a in buttons if a["title"] == "Focus for…")
        values = [c["value"] for c in custom["ask"]["choices"]]
        self.assertNotIn("30", values)  # the Focus button's own length
        self.assertEqual(values[:2], ["15", "20"])
        t = self.timer(self.run_ext("focus", input="45"))
        self.assertEqual((t["seconds"], t["title"]), (2700, "Focus 1 of 4"))
        self.assertEqual(self.state()["block"]["length"], 2700)
