#!/usr/bin/env python3
"""Pomodoro for Pilot: focus blocks and breaks counted down on Pilot's one timer.

Every command is this one program; Pilot names the command in the run message on stdin. The state lives in
paths.data/state.json: the day, the focus blocks ended that day, and the block running or paused. Pilot counts the
timer down and at zero runs the hidden `ended` command, which counts the block, then shows the end alert, or with
"Start the next block by itself" starts the next block and says so in a HUD with the end sound. The hidden `page`
command is its page (and Home block): the countdown as a meter, today's blocks and Focus, Break, Pause, Stop.
"""
import json
import math
import os
import sys
import time

LENGTHS = range(1, 121)
COMMON = [5, 10, 15, 20, 25, 30, 45, 50, 60, 90, 120]
SOUNDS = {"Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi",
          "Submarine", "Tink"}


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


def act(action):
    send({"type": "action", "action": action})


def hud(text, sound=None):
    action = {"type": "hud", "text": text}
    if sound:
        action["sound"] = sound
    act(action)


def run_action(command, title, context=None):
    action = {"type": "run", "command": command, "title": title}
    if context is not None:
        action["context"] = context
    return action


class Settings:
    """The preferences as numbers, each falling back to its default when it does not read."""

    def __init__(self, preferences):
        def minutes(name, fallback, top=120):
            try:
                value = int(str(preferences.get(name, fallback)))
            except ValueError:
                return fallback
            return min(max(value, 1), top)

        self.focus = minutes("focus", 25)
        self.short = minutes("shortBreak", 5)
        self.long = minutes("longBreak", 15)
        self.every = minutes("longBreakEvery", 4, 12)
        sound = preferences.get("sound", "Glass")
        self.sound = sound if sound in SOUNDS else None
        self.auto = preferences.get("autoStart") is True


class State:
    """state.json: the day's count and the block, kept between runs."""

    def __init__(self, folder):
        self.path = os.path.join(folder, "state.json")
        try:
            with open(self.path, encoding="utf-8") as f:
                saved = json.load(f)
        except (OSError, ValueError):
            saved = {}
        self.day = saved.get("day")
        self.count = saved.get("count", 0) if isinstance(saved.get("count"), int) else 0
        self.block = saved.get("block") if isinstance(saved.get("block"), dict) else None

    def save(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        temp = self.path + ".tmp"
        with open(temp, "w", encoding="utf-8") as f:
            json.dump({"day": self.day, "count": self.count, "block": self.block}, f)
        os.replace(temp, self.path)

    @property
    def today(self):
        """Focus blocks ended today; another day's count is none."""
        return self.count if self.day == time.strftime("%Y-%m-%d") else 0

    def live(self, now):
        """The block running or paused; one whose end passed unseen (Pilot quit while it ran) is none."""
        b = self.block
        if not b:
            return None
        if paused(b) or b.get("ends", 0) > now:
            return b
        return None


def rest_length(state, s):
    """The break due now and whether it is the long one: the long break once every `every` focus blocks today."""
    due = state.today > 0 and state.today % s.every == 0
    return (s.long, True) if due else (s.short, False)


def title(block, state, s):
    if block["phase"] == "focus":
        return "Focus %d of %d" % (state.today % s.every + 1, s.every)
    return "Long break" if block.get("long") else "Break"


def clock(seconds):
    seconds = max(0, int(math.ceil(seconds)))
    return "%d:%02d" % (seconds // 60, seconds % 60)


def paused(block):
    """A paused block keeps the seconds it had left; a running one its end time."""
    return block.get("left") is not None


def left(block, now):
    return block["left"] if paused(block) else block["ends"] - now


def buttons(block):
    """The timer's and Today's buttons: Resume and Stop while paused, else Pause, Skip and Stop."""
    if paused(block):
        return [run_action("resume", "Resume"), run_action("stop", "Stop")]
    return [run_action("pause", "Pause"), run_action("skip", "Skip"), run_action("stop", "Stop")]


def timer(block, state, s, now):
    seconds = min(max(int(math.ceil(left(block, now))), 1), 86400)
    return {"type": "timer", "title": title(block, state, s), "seconds": seconds, "paused": paused(block),
            "end": run_action("ended", "End", {"block": block["id"]}), "actions": buttons(block)}


def start(state, s, phase, minutes, long=False, say=True):
    now = time.time()
    block = {"id": "%d-%s" % (int(now * 1000), phase), "phase": phase, "long": long, "length": minutes * 60,
             "ends": now + minutes * 60, "left": None}
    state.block = block
    state.save()
    act(timer(block, state, s, now))
    if say:
        what = "Focus" if phase == "focus" else ("Long break" if long else "Break")
        hud("%s %d min. Ends %s." % (what, minutes, time.strftime("%H:%M", time.localtime(block["ends"]))))


def start_next(state, s, phase, say=True):
    """The next block of the round, as the end alert, Skip and the auto start begin it: the long break when due."""
    if phase == "focus":
        start(state, s, "focus", s.focus, say=say)
    else:
        minutes, long = rest_length(state, s)
        start(state, s, "rest", minutes, long, say=say)


def ordinal(n):
    suffix = "th" if 11 <= n % 100 <= 13 else {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return "%d%s" % (n, suffix)


def ended(state, s, context):
    """The timer reached zero: count a focus block, then the end alert, or the next block and a HUD."""
    block = state.block
    if not block or block.get("id") != context.get("block"):
        hud("Timer done")
        return
    phase = block["phase"]
    state.block = None
    note = None
    if phase == "focus":
        state.count = state.today + 1
        state.day = time.strftime("%Y-%m-%d")
        note = "%s block today. Take %d." % (ordinal(state.today), rest_length(state, s)[0])
    state.save()
    done = "Focus done" if phase == "focus" else "Break done"
    following = "rest" if phase == "focus" else "focus"
    if s.auto:
        start_next(state, s, following, say=False)
        hud(". ".join(x for x in (done, note) if x), s.sound)
        return
    alert = {"type": "alert", "text": done,
             "actions": [run_action("next", "Start break" if following == "rest" else "Start focus", {"phase": following}),
                         run_action("stop", "Stop", {"after": block["id"]})]}
    if note:
        alert["note"] = note
    if s.sound:
        alert["sound"] = s.sound
    act(alert)


def custom_items(query):
    digits = "".join(c for c in query.strip().split(" ")[0] if c.isdigit()) if query.strip() else ""
    typed = int(digits) if digits else None
    lengths = [typed] if typed in LENGTHS else []
    lengths += [m for m in COMMON if m != typed]
    return [{"id": str(m), "title": "Focus %d min" % m, "subtitle": "Start a focus block of %d minutes" % m,
             "actions": [run_action("focus", "Start %d min" % m, {"minutes": m})]} for m in lengths]


def today_detail(state, s, now):
    block = state.live(now)
    count = state.today
    if block is None:
        running, actions = "Nothing", [run_action("focus", "Start focus"), run_action("break", "Start break")]
    else:
        actions = buttons(block)
        if paused(block):
            running = "%s, paused at %s" % (title(block, state, s), clock(block["left"]))
        else:
            running = "%s, %s left, ends %s" % (title(block, state, s), clock(block["ends"] - now),
                                                time.strftime("%H:%M", time.localtime(block["ends"])))
    if count > 0 and count % s.every == 0:
        long_line = "The next break is the long one."
    else:
        more = s.every - count % s.every
        long_line = "The long break comes after %d more focus block%s." % (more, "" if more == 1 else "s")
    markdown = "# Pomodoro today\n\n**%d focus block%s** today. %s\n\n**Now:** %s." % (
        count, "" if count == 1 else "s", long_line, running)
    metadata = [
        {"label": "Blocks today", "text": str(count)},
        {"label": "Now", "text": running},
        {"label": "Focus", "text": "%d min" % s.focus},
        {"label": "Short break", "text": "%d min" % s.short},
        {"label": "Long break", "text": "%d min, every %d blocks" % (s.long, s.every)},
        {"label": "End sound", "text": s.sound or "None"},
        {"label": "Next block by itself", "text": "On" if s.auto else "Off"},
    ]
    send({"type": "detail", "markdown": markdown, "metadata": metadata, "actions": actions})


def custom_button(s):
    """The page's Focus for…: a length picked in its button row (Sven, 2026-10-31: the page does what Custom focus does in
    Hyper+Space), lengths other than the Focus setting's, eight at most."""
    lengths = [m for m in (15, 20, 30, 45, 50, 60, 90, 120) if m != s.focus][:8]
    return dict(run_action("focus", "Focus for…"),
                ask={"choices": [{"title": "%d min" % m, "value": str(m)} for m in lengths]})


def page(state, s, now):
    """The page's blocks: the block as a meter of the time left, today's blocks, and its buttons (Focus, Break, Focus
    for…, then the block's own); asked every 5 s while a block counts down, so the meter moves."""
    block = state.live(now)
    actions = [run_action("focus", "Focus %d min" % s.focus), run_action("break", "Break %d min" % s.short), custom_button(s)]
    if block is None:
        meter = {"type": "meter", "label": "Next: " + title({"phase": "focus"}, state, s), "percent": 0,
                 "value": clock(s.focus * 60), "note": "Nothing running"}
    else:
        seconds = max(0, left(block, now))
        # A block started before 1.1.0 has no length: it reads full.
        length = block.get("length") or seconds or 1
        meter = {"type": "meter", "label": title(block, state, s), "percent": round(min(seconds / length, 1) * 100, 1),
                 "value": clock(seconds)}
        if paused(block):
            meter.update(note="Paused", tone="warn")
        else:
            meter["note"] = "Ends %s" % time.strftime("%H:%M", time.localtime(block["ends"]))
            if block["phase"] != "focus":
                meter["tone"] = "fine"
        actions += buttons(block)
    long_break = "next break" if rest_length(state, s)[1] else "%d more" % (s.every - state.today % s.every)
    stats = {"type": "stats", "items": [{"label": "Blocks today", "value": str(state.today)},
                                        {"label": "Long break after", "value": long_break}]}
    answer = {"type": "blocks", "blocks": [meter, stats, {"type": "buttons", "actions": actions}]}
    if block is not None and not paused(block):
        answer["refresh"] = 5
    send(answer)


def main():
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        send({"type": "error", "text": "got a run message it could not read"})
        return
    command = run.get("command")
    context = run.get("context") if isinstance(run.get("context"), dict) else {}
    s = Settings(run.get("preferences") or {})
    data = (run.get("paths") or {}).get("data") or os.path.join(os.environ.get("TMPDIR", "/tmp"), "pomodoro")
    state = State(data)
    now = time.time()
    block = state.live(now)

    if command == "focus":
        minutes = context.get("minutes")
        picked = str(run.get("input") or "")
        if picked.isdigit():  # the page's Focus for…
            minutes = int(picked)
        start(state, s, "focus", minutes if type(minutes) is int and minutes in LENGTHS else s.focus)
    elif command == "break":
        start(state, s, "rest", s.short)
    elif command == "next":
        start_next(state, s, "rest" if context.get("phase") == "rest" else "focus")
    elif command == "custom":
        send({"type": "list", "items": custom_items(run.get("query") or "")})
    elif command == "pause":
        if block is None:
            hud("No timer running.")
        elif paused(block):
            hud("Already paused at %s." % clock(block["left"]))
        else:
            block["left"] = max(1, int(math.ceil(block["ends"] - now)))
            state.save()
            act(timer(block, state, s, now))
            hud("Paused at %s." % clock(block["left"]))
    elif command == "resume":
        if block is None or not paused(block):
            hud("Nothing paused.")
        else:
            block["ends"] = now + block["left"]
            block["left"] = None
            state.save()
            act(timer(block, state, s, now))
            hud("Resumed, %s left." % clock(block["ends"] - now))
    elif command == "skip":
        if block is None:
            hud("No timer running.")
        else:
            start_next(state, s, "rest" if block["phase"] == "focus" else "focus")
    elif command == "stop":
        if "after" in context and block is not None:
            # The end alert's Stop, pressed after another block began: that block keeps running.
            hud("%s keeps running." % title(block, state, s))
            return
        state.block = None
        state.save()
        act({"type": "timer", "seconds": 0})
        if "after" not in context:
            hud("Timer stopped.")
    elif command == "ended":
        ended(state, s, context)
    elif command == "today":
        today_detail(state, s, now)
    elif command == "page":
        page(state, s, now)
    else:
        send({"type": "error", "text": "has no command %s" % command})


if __name__ == "__main__":
    main()
