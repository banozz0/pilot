#!/usr/bin/env python3
"""Check every extension against the rules Pilot's Extension.swift applies, plus the catalogue's, and that index.json
is fresh. Prints one line per problem and exits 1 when there is any.

Pilot's rules (Sources/PilotCore/Extension.swift): id and command names `[a-z0-9][a-z0-9-]*`; runtime absent or
`process`; at least one command; command names unique; mode no-view, list or detail; run an executable regular file
inside the folder; filter pilot or self; a session is a list that filters itself; preference types text, password,
checkbox, dropdown (with data), app, file, folder; preference names `[A-Za-z0-9_-]+`, unique; a default that fits.
The catalogue's own (Pilot's PLAN section 3): folder name is the id; `version` x.y.z; a description, what it is for in
plain words; `examples`, one or two concrete uses (Pilot's story 158); `requires` a list
of names; `hidden` a boolean; at least one shown command; at most 200 files, 2 MB a file, 10 MB in all; Python
programs start `#!/usr/bin/env python3`. `surfaces` (Pilot's story 161): an object whose `page` and `bar` each name one
of its commands and may give `every`, a number of seconds (Pilot holds a page to 10 s and a bar item to 60 s at least).
`keyword` (2026-10-10): one lowercase word on a no-view command, unique in the extension; "todo buy milk" in Hyper+Space
runs it with "buy milk" as its input (Pilot ignores one it can't read; this check refuses it).
"""
import importlib.util
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("build_index", ROOT / "scripts" / "build-index.py")
build_index = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build_index)

NAME = re.compile(r"[a-z0-9][a-z0-9-]*\Z")
PREFERENCE_NAME = re.compile(r"[A-Za-z0-9_-]+\Z")
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
MODES = {"no-view", "list", "detail"}
FILTERS = {"pilot", "self"}
PREFERENCE_TYPES = {"text", "password", "checkbox", "dropdown", "app", "file", "folder"}
SHEBANG = "#!/usr/bin/env python3"
MAX_FILES, MAX_FILE, MAX_TOTAL = 200, 2 * 1024 * 1024, 10 * 1024 * 1024
MAX_EXAMPLES = 2  # Pilot shows two (Extension.mostExamples)


def is_emoji(s):
    """Close to Pilot's ScriptCommand.isEmoji (one character showing as an emoji): a short run of emoji code points."""
    if not isinstance(s, str) or not s or len(s) > 8:
        return False
    joiners = {0x200D, 0xFE0F, 0x20E3}
    if not all(ord(c) >= 0x2190 or ord(c) in joiners for c in s):
        return False
    return ord(s[0]) >= 0x1F000 or "\ufe0f" in s or (len(s) == 1 and 0x2300 <= ord(s) <= 0x2BFF)


def fits(kind, options, value):
    if kind == "checkbox":
        return isinstance(value, bool)
    if kind == "dropdown":
        return isinstance(value, str) and value in [o.get("value") for o in options]
    return isinstance(value, str)


def check_preferences(manifest, problems):
    names = set()
    for p in manifest.get("preferences") or []:
        name = p.get("name")
        if not isinstance(name, str) or not isinstance(p.get("title"), str) or not isinstance(p.get("type"), str):
            problems.append("a preference needs name, type and title as strings")
            continue
        kind = p["type"]
        options = p.get("data") or []
        if kind not in PREFERENCE_TYPES:
            problems.append("preference %s: type \"%s\" is not text, password, checkbox, dropdown, app, file or folder" % (name, kind))
            continue
        if kind == "dropdown":
            if not options:
                problems.append("preference %s: a dropdown needs data, its options" % name)
                continue
            if not all(isinstance(o, dict) and isinstance(o.get("title"), str) and isinstance(o.get("value"), str) for o in options):
                problems.append("preference %s: each option needs title and value as strings" % name)
                continue
        if not PREFERENCE_NAME.match(name):
            problems.append("preference name \"%s\" must be letters, digits, hyphens and underscores" % name)
        if name in names:
            problems.append("two preferences named \"%s\"" % name)
        names.add(name)
        if "default" in p and p["default"] is not None and not fits(kind, options, p["default"]):
            problems.append("preference %s: its default does not fit its type" % name)
        if "required" in p and not isinstance(p["required"], bool):
            problems.append("preference %s: required must be true or false" % name)


def check_program(folder, run, command, problems):
    root = os.path.realpath(folder)
    path = os.path.realpath(os.path.join(folder, run))
    if run.startswith("/") or not path.startswith(root + os.sep) or not os.path.isfile(path) or not os.access(path, os.X_OK):
        problems.append("command %s: %s is not an executable file in the folder" % (command, run))
        return
    with open(path, "rb") as f:
        first = f.readline().decode("utf-8", "replace").rstrip("\n")
    if path.endswith(".py") and first != SHEBANG:
        problems.append("command %s: %s must start %s" % (command, run, SHEBANG))


def check_commands(folder, manifest, problems):
    commands = manifest.get("commands")
    if not isinstance(commands, list) or not commands:
        problems.append("no commands")
        return
    names, keywords = set(), set()
    for c in commands:
        name = c.get("name")
        if not all(isinstance(c.get(k), str) for k in ("name", "title", "mode", "run")):
            problems.append("a command needs name, title, mode and run as strings")
            continue
        if not NAME.match(name):
            problems.append("command name \"%s\" must be lowercase letters, digits and hyphens" % name)
        if name in names:
            problems.append("two commands named \"%s\"" % name)
        names.add(name)
        if c["mode"] not in MODES:
            problems.append("command %s: mode \"%s\" is not no-view, list or detail" % (name, c["mode"]))
        check_program(folder, c["run"], name, problems)
        session = c.get("session", False)
        filter_ = c.get("filter", "self" if session else "pilot")
        if filter_ not in FILTERS:
            problems.append("command %s: filter \"%s\" is not pilot or self" % (name, filter_))
        if session and not (c["mode"] == "list" and filter_ == "self"):
            problems.append("command %s: a session must be a list that filters itself" % name)
        if "hidden" in c and not isinstance(c["hidden"], bool):
            problems.append("command %s: hidden must be true or false" % name)
        if "icon" in c and not is_emoji(c["icon"]):
            problems.append("command %s: icon must be one emoji" % name)
        if "keyword" in c:
            keyword = c["keyword"]
            if not isinstance(keyword, str) or not NAME.match(keyword):
                problems.append("command %s: keyword must be one word of lowercase letters, digits and hyphens" % name)
            elif c["mode"] != "no-view":
                problems.append("command %s: only a no-view command takes a keyword" % name)
            elif keyword in keywords:
                problems.append("two commands with keyword \"%s\"" % keyword)
            keywords.add(keyword if isinstance(keyword, str) else "")
    if all(c.get("hidden") for c in commands):
        problems.append("every command is hidden: nothing shows in Hyper+Space")


def check_surfaces(manifest, problems):
    surfaces = manifest.get("surfaces")
    if surfaces is None:
        return
    if not isinstance(surfaces, dict) or not set(surfaces) <= {"page", "bar"}:
        problems.append("surfaces must be an object with page and bar")
        return
    names = {c.get("name") for c in manifest.get("commands") or [] if isinstance(c, dict)}
    for kind, surface in surfaces.items():
        if not isinstance(surface, dict) or surface.get("command") not in names:
            problems.append("surfaces.%s must name one of its commands" % kind)
        elif "every" in surface and (isinstance(surface["every"], bool) or not isinstance(surface["every"], (int, float))
                                     or surface["every"] < (10 if kind == "page" else 60)):
            problems.append("surfaces.%s: every must be at least %d seconds" % (kind, 10 if kind == "page" else 60))


def check_files(folder, problems):
    found = build_index.files(folder)
    if len(found) > MAX_FILES:
        problems.append("%d files, more than %d" % (len(found), MAX_FILES))
    for f in found:
        if f["size"] > MAX_FILE:
            problems.append("%s is over %d MB" % (f["path"], MAX_FILE // 2 ** 20))
    if sum(f["size"] for f in found) > MAX_TOTAL:
        problems.append("over %d MB in all" % (MAX_TOTAL // 2 ** 20))


def check(folder):
    """The problems with one extension folder; none when it is fine."""
    problems = []
    try:
        manifest = json.loads((folder / "extension.json").read_text(encoding="utf-8"))
    except FileNotFoundError:
        return ["no extension.json"]
    except ValueError as e:
        return ["extension.json does not read: %s" % e]
    if not isinstance(manifest, dict):
        return ["extension.json is not an object"]
    ext_id = manifest.get("id")
    if not isinstance(ext_id, str) or not NAME.match(ext_id):
        problems.append("id \"%s\" must be lowercase letters, digits and hyphens" % ext_id)
    elif folder.name != ext_id:
        problems.append("folder name %s is not its id %s" % (folder.name, ext_id))
    if not isinstance(manifest.get("title"), str) or not manifest["title"].strip():
        problems.append("title is missing")
    if manifest.get("runtime", "process") != "process":
        problems.append("runtime \"%s\" is not one Pilot runs (process)" % manifest.get("runtime"))
    if not is_emoji(manifest.get("icon")):
        problems.append("icon must be one emoji")
    if not isinstance(manifest.get("version"), str) or not VERSION.match(manifest["version"]):
        problems.append("version must be x.y.z")
    if not isinstance(manifest.get("description"), str) or not manifest["description"].strip():
        problems.append("description is missing")
    examples = manifest.get("examples")
    if not isinstance(examples, list) or not 1 <= len(examples) <= MAX_EXAMPLES \
            or not all(isinstance(e, str) and e.strip() for e in examples):
        problems.append("examples must be a list of 1 to %d concrete uses" % MAX_EXAMPLES)
    requires = manifest.get("requires", [])
    if not isinstance(requires, list) or not all(isinstance(r, str) and r for r in requires):
        problems.append("requires must be a list of names")
    permissions = manifest.get("permissions", {})
    if not isinstance(permissions, dict) or not all(
            isinstance(permissions.get(k, []), list) for k in ("network", "files", "actions")) \
            or not isinstance(permissions.get("clipboard", False), bool):
        problems.append("permissions must hold lists network, files, actions and a boolean clipboard")
    if not isinstance(manifest.get("unlisted", False), bool):
        problems.append("unlisted must be a boolean")
    check_commands(folder, manifest, problems)
    check_preferences(manifest, problems)
    check_surfaces(manifest, problems)
    check_files(folder, problems)
    return problems


def main():
    failed = False
    folders = build_index.folders()
    for folder in folders:
        for problem in check(folder):
            failed = True
            print("%s: %s" % (folder.name, problem))
    if not failed:
        fresh = build_index.render(build_index.build())
        current = build_index.INDEX.read_text(encoding="utf-8") if build_index.INDEX.exists() else ""
        if fresh != current:
            failed = True
            print("index.json is stale: run python3 scripts/build-index.py")
    if failed:
        return 1
    print("check: %d extension%s fine, index.json fresh" % (len(folders), "" if len(folders) == 1 else "s"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
