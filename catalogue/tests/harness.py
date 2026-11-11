"""Runs an extension command the way Pilot does (ADR 0010, Sources/PilotCore/ExtensionRun.swift).

The program runs in its own folder with a small fixed environment (HOME, USER, TMPDIR, PATH of its folder, Homebrew's
and the system's, LANG, PILOT_EXTENSION_ID), gets one JSON run message on stdin, which is then closed, and must answer in
JSON lines within Pilot's limits: 2 s for a list or detail, 30 s for a no-view command.

Two test-only additions, both prepended to PATH after the program's folder: a `shims` folder a test fills with fake
`open`, `pbcopy`, `pbpaste`, `gh`… so nothing reaches Sven's screen, clipboard or accounts; and, when PILOT_EXT_PYTHON
names an interpreter (e.g. /usr/bin/python3, macOS's 3.9), a `python3` that runs it, so every program is proven on
the oldest Python a Mac ships.
"""
import base64
import functools
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXTENSIONS = ROOT / "extensions"
SYSTEM_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
TIMEOUTS = {"list": 2.0, "detail": 2.0, "no-view": 30.0, "page": 5.0, "bar": 2.0, "popover": 5.0}  # stories 161, 165
# Each action type and the field it needs; an item carries the first seven, a no-view run may also print the last three
# (ai: ADR 0010 amended 2026-10-25, Pilot's AI on a text, its answer handed to a run).
ITEM_ACTIONS = {"open": "url", "copy": "text", "paste": "text", "push": "command", "run": "command", "hud": "text",
                "pilot": "action"}
ACTIONS = dict(ITEM_ACTIONS, timer="seconds", alert="text", ai="prompt")
# Pilot's Extension.Item.Action.icons: one list for an inline button, a note and a link (chart, plus, reset, info: Q138).
INLINE_ICONS = {"bubble", "moon", "sun", "pencil", "tag", "xmark", "arrow.up", "arrow.down", "terminal", "refresh", "chart",
                "plus", "reset", "info", "circle", "checkmark.circle"}  # circle, checkmark.circle: To-do B, 2026-10-17
# An action's key (To-do B, ADR 0010 amended 2026-10-17): modifiers then one key; Pilot's Extension.Item.Action.Key.
KEY = re.compile(r"^((cmd|ctrl|opt|shift)\+)+([a-z0-9]|return|delete|up|down)$")
OWNED_KEYS = {"cmd+" + k for k in "acvxkqwhm123456789"}

_spec = importlib.util.spec_from_file_location("check", ROOT / "scripts" / "check.py")
check = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check)


@functools.lru_cache(maxsize=None)
def _manifest(folder):
    return json.loads((Path(folder) / "extension.json").read_text(encoding="utf-8"))


def manifest(ext_id, folder=None):
    return _manifest(str(folder or EXTENSIONS / ext_id))


def resolved_preferences(m, saved):
    """Pilot's Preference.resolved: the saved value when it fits, else the default; a checkbox with neither is false,
    any other type left out."""
    values = {}
    for p in m.get("preferences", []):
        value = saved.get(p["name"])
        kind = p["type"]
        if value is not None and not check.fits(kind, p.get("data") or [], value):
            value = None
        if value is None:
            value = p.get("default")
        if value is None and kind == "checkbox":
            value = False
        if value is not None:
            values[p["name"]] = value
    return values


class Result:
    def __init__(self, stdout, stderr, code, elapsed):
        self.stdout, self.stderr, self.code, self.elapsed = stdout, stderr, code, elapsed
        self.messages = []
        self.plain = []
        for line in (line for line in stdout.splitlines() if line.strip()):
            try:
                message = json.loads(line)
            except ValueError:
                self.plain.append(line)
                continue
            if isinstance(message, dict):
                self.messages.append(message)
            else:
                self.plain.append(line)

    def of_type(self, kind):
        return [m for m in self.messages if m.get("type") == kind]

    @property
    def items(self):
        lists = self.of_type("list")
        return lists[-1]["items"] if lists else None

    @property
    def detail(self):
        details = self.of_type("detail")
        return details[-1] if details else None

    @property
    def actions(self):
        """The no-view actions, in printed order."""
        return [m["action"] for m in self.of_type("action")]


class Sandbox:
    """Temporary home, data, cache and shim folders for one test."""

    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix="pilot-ext-test-"))
        self.home = self.root / "home"
        self.data = self.root / "data"
        self.cache = self.root / "cache"
        self.tmp = self.root / "tmp"
        self.shims = self.root / "shims"
        self.log = self.root / "shim.log"
        for p in (self.home, self.data, self.cache, self.tmp, self.shims):
            p.mkdir()
        python = os.environ.get("PILOT_EXT_PYTHON")
        if python:
            self.shim("python3", 'exec "%s" "$@"' % python)

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def shim(self, name, body=None):
        """A fake command on PATH; by default it logs its name and arguments, one line each, and prints nothing."""
        if body is None:
            body = 'printf "%%s\\n" "%s $*" >> "%s"' % (name, self.log)
        path = self.shims / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)
        return path

    def shim_calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def run(self, ext_id, command, query=None, context=None, preferences=None, home=None, timeout=None, folder=None,
            surface=None, pilot=None, input=None):
        """Runs `command`, from `folder` when given (an installed copy), else from the repo; `surface` ("page" or "bar")
        runs it as that surface does (or "popover", a bar item's click), the surface named in the run message and its time
        limit applied; `pilot` is Pilot's defaults in the run message (story 165: repos, terminal); `input` the text typed
        in an input block or the answer to a run's ask (story 165)."""
        folder = Path(folder or EXTENSIONS / ext_id)
        m = manifest(ext_id, folder)
        spec = next(c for c in m["commands"] if c["name"] == command)
        program = (folder / spec["run"]).resolve()
        message = {"type": "run", "extension": ext_id, "command": command,
                   "preferences": resolved_preferences(m, preferences or {}),
                   "paths": {"data": str(self.data), "cache": str(self.cache)}}
        if query is not None or spec["mode"] in ("list", "detail"):
            message["query"] = query or ""
        if context is not None:
            message["context"] = context
        if surface is not None:
            message["surface"] = surface
        if pilot is not None:
            message["pilot"] = pilot
        if input is not None:
            message["input"] = input
        env = {"HOME": str(home or self.home), "USER": os.environ.get("USER", "sven"), "TMPDIR": str(self.tmp) + "/",
               "PATH": ":".join([str(program.parent), str(self.shims), SYSTEM_PATH]),
               "LANG": "en_US.UTF-8", "PILOT_EXTENSION_ID": ext_id}
        limit = TIMEOUTS[surface or spec["mode"]] if timeout is None else timeout
        started = time.monotonic()
        proc = subprocess.Popen([str(program)], cwd=str(program.parent), env=env, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        line = json.dumps(message, sort_keys=True, separators=(",", ":")) + "\n"
        try:
            out, err = proc.communicate(line.encode(), timeout=limit)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate()
            raise AssertionError("%s %s did not answer in %g s: Pilot would stop it" % (ext_id, command, limit))
        return Result(out.decode("utf-8", "replace"), err.decode("utf-8", "replace"), proc.returncode,
                      time.monotonic() - started)


class ExtensionTestCase(unittest.TestCase):
    """Gives each test a Sandbox and the protocol checks every answer must pass."""

    def setUp(self):
        self.box = Sandbox()
        self.addCleanup(self.box.close)

    def run_ext(self, command, **kwargs):
        result = self.box.run(self.EXTENSION, command, **kwargs)
        self.assertEqual(result.plain, [], "printed lines outside the protocol: %r" % result.plain)
        self.assertEqual(result.code, 0, "exit %d: %s" % (result.code, result.stderr[-500:]))
        return result

    def assertItemShape(self, items):
        """Every item as Pilot decodes it: a title string, optional strings, actions of known types with their field."""
        for item in items:
            self.assertIsInstance(item.get("title"), str)
            for key in ("id", "subtitle", "icon", "keywords", "section"):
                if key in item:
                    self.assertIsInstance(item[key], str, key)
            if "accessory" in item:  # To-do B: a word, or a badge's text and tone, at the row's right
                accessory = item["accessory"]
                self.assertIsInstance(accessory if isinstance(accessory, str) else accessory.get("text"), str)
                self.assertIn(None if isinstance(accessory, str) else accessory.get("tone"), self.TONES)
            for action in item.get("actions", []):
                self.assertActionShape(action, ITEM_ACTIONS)
            self.assertLessEqual(len(item.get("badges", [])), 3)  # story 165: badges and inline buttons, 3 each
            for badge in item.get("badges", []):
                self.assertIsInstance(badge.get("text"), str)
                self.assertIn(badge.get("tone"), self.TONES)
            self.assertLessEqual(len(item.get("inline", [])), 3)
            if "image" in item:  # Pilot 2026-10-16: a row's picture, base64, up to 64 KB
                self.assertLessEqual(len(base64.b64decode(item["image"], validate=True)), 64 * 1024)
            for action in item.get("inline", []):
                self.assertActionShape(action, ITEM_ACTIONS)
                self.assertTrue(action.get("icon") in INLINE_ICONS or check.is_emoji(action.get("icon")), action)

    def assertActionShape(self, action, fields=ACTIONS):
        self.assertIn(action.get("type"), fields, action)
        self.assertIn(fields[action["type"]], action, action)
        if "key" in action:  # To-do B: Command, Control or Option, never a key the search field or Pilot owns
            self.assertRegex(action["key"], KEY)
            self.assertTrue(any(m in action["key"] for m in ("cmd", "ctrl", "opt")), action)
            self.assertNotIn(action["key"], OWNED_KEYS)
        for flag in ("stay", "clear"):  # To-do B: Hyper+Space stays open as a run runs
            if flag in action:
                self.assertIs(action[flag], True)
                self.assertEqual(action["type"], "run", action)
        if "ask" in action:  # story 165: only a run asks; text, up to 8 choices, or a confirm
            self.assertEqual(action["type"], "run", action)
            ask = action["ask"]
            self.assertEqual(len(ask), 1, ask)
            if "choices" in ask:
                self.assertTrue(1 <= len(ask["choices"]) <= 8, ask)
                for choice in ask["choices"]:
                    self.assertIsInstance(choice.get("title"), str)
                    self.assertIsInstance(choice.get("value"), str)
            else:
                self.assertIsInstance(ask.get("text", ask.get("confirm")), str, ask)
        if action["type"] in ("run", "push"):
            names = {c["name"]: c for c in manifest(self.EXTENSION)["commands"]}
            self.assertIn(action["command"], names, "names a command the extension lacks")
            wanted = "no-view" if action["type"] == "run" else ("list", "detail", "no-view")  # a push in a popover: 165
            self.assertIn(names[action["command"]]["mode"], wanted, action)

    BLOCK_TYPES = {"stats", "meter", "list", "markdown", "buttons", "section", "chat", "input", "hero", "strip", "note", "links"}
    ICONS = INLINE_ICONS  # Pilot's Extension.Item.Action.icons
    ROLES = ("user", "assistant", "tool")
    TONES = (None, "fine", "warn", "alert")

    def assertBlocksShape(self, blocks, types=BLOCK_TYPES):
        """Every block as Pilot decodes it (stories 161 and 165): a known type with its fields; a list's items and the
        buttons' actions as an item's; a section's blocks one level deep, a meter's resetsAt seconds since 1970, its mark 0
        to 100 and value a string; a chat's messages (20 at most), an input's run actions (its extra ones titled, 5 at most) and file kinds; a hero's value and at most 3
        stats, a strip's 1 to 7 columns, each a label and a glyph, high or low (Omarchy ideas T4); Pilot Q138: a help on a
        meter or section, a section's icon claude or openai, a note's text, a links row's 1 to 6 links, each a title or one
        of Pilot's icons and its actions."""
        self.assertIsInstance(blocks, list)
        for block in blocks:
            self.assertIn(block.get("type"), types, block)
            kind = block["type"]
            if kind == "stats":
                self.assertTrue(block["items"])
                for stat in block["items"]:
                    self.assertIsInstance(stat.get("label"), str)
                    self.assertIsInstance(stat.get("value"), str)
                    self.assertIn(stat.get("tone"), self.TONES)
            elif kind == "meter":
                self.assertIsInstance(block.get("label"), str)
                self.assertIsInstance(block.get("percent"), (int, float))
                self.assertIn(block.get("tone"), self.TONES)
                if "resetsAt" in block:
                    self.assertIsInstance(block["resetsAt"], (int, float))
                if "mark" in block:
                    self.assertTrue(0 <= block["mark"] <= 100, block)
                self.assertIsInstance(block.get("value", ""), str)
                self.assertIsInstance(block.get("help", ""), str)
            elif kind == "section":
                self.assertIsInstance(block.get("title", ""), str)
                self.assertIsInstance(block.get("subtitle", ""), str)
                self.assertIsInstance(block.get("help", ""), str)
                self.assertIn(block.get("icon"), (None, "claude", "openai"))
                self.assertBlocksShape(block["blocks"], self.BLOCK_TYPES - {"section"})
            elif kind == "list":
                self.assertItemShape(block["items"])
            elif kind == "markdown":
                self.assertIsInstance(block.get("text"), str)
            elif kind == "note":
                self.assertTrue(isinstance(block.get("text"), str) and block["text"], block)
                for key in ("aside", "help"):
                    self.assertIsInstance(block.get(key, ""), str)
                self.assertIn(block.get("icon", "info"), self.ICONS)
            elif kind == "links":
                self.assertTrue(1 <= len(block["items"]) <= 6, block)
                for link in block["items"]:
                    self.assertTrue(isinstance(link.get("title"), str) or link.get("icon") in self.ICONS, link)
                    self.assertIn(link.get("tone"), self.TONES)
                    for key in ("word", "help"):
                        self.assertIsInstance(link.get(key, ""), str)
                    self.assertTrue(link["actions"])
                    for action in link["actions"]:
                        self.assertActionShape(action, ITEM_ACTIONS)
            elif kind == "hero":
                self.assertIsInstance(block.get("value"), (str, int, float))
                for key in ("glyph", "unit", "place"):
                    self.assertIsInstance(block.get(key, ""), str)
                self.assertIn(block.get("tone"), self.TONES)
                self.assertLessEqual(len(block.get("items", [])), 3)
                for stat in block.get("items", []):
                    self.assertIsInstance(stat.get("label"), str)
                    self.assertIsInstance(stat.get("value"), str)
            elif kind == "strip":
                self.assertTrue(1 <= len(block["items"]) <= 7, block)
                for column in block["items"]:
                    self.assertIsInstance(column.get("label"), str)
                    self.assertTrue(any(isinstance(column.get(k), str) for k in ("glyph", "high", "low")), column)
            elif kind == "chat":
                self.assertIsInstance(block.get("working", False), bool)
                self.assertLessEqual(len(block["messages"]), 20)
                for message in block["messages"]:
                    self.assertIn(message.get("role"), self.ROLES)
                    self.assertIsInstance(message.get("text"), str)
                    if "at" in message:
                        self.assertIsInstance(message["at"], (int, float))
            elif kind == "input":
                self.assertIsInstance(block.get("placeholder", ""), str)
                for key in ("action", "alt"):
                    if key in block or key == "action":
                        self.assertEqual(block[key]["type"], "run", block)  # only a run takes typed text
                        self.assertActionShape(block[key], ITEM_ACTIONS)
                # Pilot 2026-10-31: more runs that take the text, each a titled button; a Choose button's file kinds.
                self.assertLessEqual(len(block.get("actions", [])), 5)
                for action in block.get("actions", []):
                    self.assertEqual(action["type"], "run", block)
                    self.assertIsInstance(action.get("title"), str)
                    self.assertActionShape(action, ITEM_ACTIONS)
                self.assertTrue(all(isinstance(k, str) and k for k in block.get("files", [])), block)
            else:
                self.assertTrue(block["actions"])
                for action in block["actions"]:
                    self.assertActionShape(action, ITEM_ACTIONS)

    def assertGaugesShape(self, gauges):
        """A bar line's gauges (story 165): up to 3, a label of at most 5 characters (2 before Pilot's 2026-10-16), 1 or 2 meters 0 to 100, a tone; or
        (2026-10-11) one of Pilot's provider glyphs (`icon` claude or openai) and a `text` of at most 6 characters in
        place of the meters."""
        self.assertLessEqual(len(gauges), 3)
        for gauge in gauges:
            self.assertLessEqual(len(gauge.get("label", "")), 5)
            self.assertIn(gauge.get("icon"), (None, "claude", "openai"))
            self.assertLessEqual(len(gauge.get("text", "")), 6)
            if "meters" in gauge or not ("icon" in gauge or "text" in gauge):
                self.assertTrue(1 <= len(gauge["meters"]) <= 2, gauge)
                self.assertTrue(all(0 <= m <= 100 for m in gauge["meters"]), gauge)
            self.assertIn(gauge.get("tone"), self.TONES)

    def blocks_message(self, command, surface, **kwargs):
        """One blocks message, its shape checked: a page's, or a bar command's popover (story 165), with its refresh."""
        result = self.run_ext(command, surface=surface, **kwargs)
        found = result.of_type("blocks")
        self.assertEqual(len(found), 1, result.stdout)
        self.assertBlocksShape(found[0]["blocks"])
        if "refresh" in found[0]:
            self.assertTrue(2 <= found[0]["refresh"] <= 60, found[0])
        return found[0]

    def blocks(self, command, surface, **kwargs):
        return self.blocks_message(command, surface, **kwargs)["blocks"]

    def page(self, **kwargs):
        return self.blocks("page", "page", **kwargs)

    def popover(self, **kwargs):
        return self.blocks("bar", "popover", **kwargs)

    def bar(self, **kwargs):
        """The bar command's one bar message: a short text, a tone, gauges, blocks its popover shows until it answers."""
        result = self.run_ext("bar", surface="bar", **kwargs)
        found = result.of_type("bar")
        self.assertEqual(len(found), 1, result.stdout)
        self.assertIsInstance(found[0].get("text"), str)
        self.assertLessEqual(len(found[0]["text"]), 24)
        self.assertIn(found[0].get("tone"), self.TONES)
        self.assertGaugesShape(found[0].get("gauges", []))
        self.assertBlocksShape(found[0].get("blocks", []))
        return found[0]
