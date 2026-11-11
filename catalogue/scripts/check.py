#!/usr/bin/env python3
"""Check every extension and theme pack against the rules Pilot applies, plus the catalogue's, and that index.json
is fresh. Prints one line per problem and exits 1 when there is any (2 when there are only flags; see --author).

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

Theme packs (themes/<id>/) follow Pilot's ThemePack.decode and ThemePackStore.validate (Sources/PilotCore): only the
known manifest keys, each once; schema 1; an id of 1 to 80 lowercase letters, digits and hyphens, the folder's name; a
title with no control characters; styles instrument or toybox; every palette role as #RRGGBB, variants likewise; a
material of glass, transparency 0 to 100 and blur full, light or off; a barPreset floatingStrip or threeIslands; adapters
ghostty, zed and obsidian, each {}; wallpapers and preview relative paths inside the folder, and no file they don't
name but manifest.json and PROVENANCE.md. The catalogue's own: no customMappings (their template is the one theme path
to code); no executable file; images PNG, JPEG or HEIC by their bytes, at most 16384 pixels a side and 50 million in
all; no `url(`, `@import` or `://` in the manifest; at most 300 files, 8 MB a file, 40 MB in all.

Both kinds (outside input is hostile, public-repo spec's threat model): no symlinks, no hidden files or folders, no
bidirectional or invisible Unicode controls in any text file, and no title that looks like another's of its kind.

`--author <login> [--base <ref>]` (for CI on a pull request): a pack this branch changes since <ref> (default
origin/main) whose folder was first added by someone else is flagged for Sven's read. Exit 0 fine, 1 problems,
2 flags only.
"""
import argparse
import importlib.util
import json
import os
import re
import struct
import subprocess
import sys
import unicodedata
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


def check_files(folder, problems, limits=(MAX_FILES, MAX_FILE, MAX_TOTAL)):
    """The limits on what ships from `folder`, and no bidi or invisible control in any of its text files; its listing."""
    most_files, most_file, most_total = limits
    found = build_index.files(folder)
    if len(found) > most_files:
        problems.append("%d files, more than %d" % (len(found), most_files))
    for f in found:
        if f["size"] > most_file:
            problems.append("%s is over %d MB" % (f["path"], most_file // 2 ** 20))
        for number, line in enumerate((text_of(folder / f["path"]) or "").splitlines(), 1):
            if any(ord(c) in INVISIBLE for c in line):
                problems.append("%s:%d holds a bidirectional or invisible control character" % (f["path"], number))
    if sum(f["size"] for f in found) > most_total:
        problems.append("over %d MB in all" % (most_total // 2 ** 20))
    return found


# Theme packs: ThemePack.decode (Sources/PilotCore/ThemePack.swift), OmarchyTheme.roles (Ghostty.swift).
THEME_KEYS = {"schema", "id", "title", "dark", "palette", "styles", "wallpapers", "adapters", "variants", "material",
              "barPreset", "customMappings", "preview"}
THEME_REQUIRED = ("schema", "id", "title", "dark", "palette", "styles", "wallpapers", "adapters")
ROLES = ("background", "dark_background", "darker_background", "lighter_background", "foreground", "dark_foreground",
         "light_foreground", "bright_foreground", "accent", "selection", "muted", "red", "yellow", "green", "cyan", "blue",
         "magenta", "bright_red", "bright_yellow", "bright_green", "bright_cyan", "bright_blue", "bright_magenta")
COLOUR = re.compile(r"#[0-9A-Fa-f]{6}\Z")
THEME_ID = re.compile(r"[a-z0-9][a-z0-9-]{0,79}\Z")
STYLES = {"instrument", "toybox"}
ADAPTERS = {"ghostty", "zed", "obsidian"}
BAR_PRESETS = {"floatingStrip", "threeIslands"}
BLURS = {"full", "light", "off"}
THEME_LIMITS = (300, 8 * 1024 * 1024, 40 * 1024 * 1024)  # files, a file, in all
MAX_SIDE, MAX_PIXELS = 16384, 50 * 1000 * 1000
HEIC_BRANDS = {b"heic", b"heix", b"heim", b"heis", b"hevc", b"hevx", b"mif1", b"msf1"}
BEACONS = ("url(", "@import", "://")
# Bidirectional controls ("Trojan Source") and invisible characters. U+200D and U+FE0F stay: emoji icons join with them.
INVISIBLE = set(range(0x202A, 0x202F)) | set(range(0x2066, 0x206A)) | {0x061C, 0x200B, 0x200C, 0x200E, 0x200F, 0x00AD,
                                                                        0x2060, 0x2061, 0x2062, 0x2063, 0x2064, 0xFEFF}
# Latin look-alikes from Cyrillic and Greek, for comparing titles (NFKC alone keeps them apart).
LOOKALIKES = str.maketrans("аеорсухіјѕԁɡοανρτκιВЕКМНОРСТХ", "aeopcyxijsdgoavptkiBEKMHOPCTX")


def no_duplicate_keys(pairs):
    keys = [k for k, _ in pairs]
    duplicate = next((k for k in keys if keys.count(k) > 1), None)
    if duplicate is not None:
        raise ValueError("the key \"%s\" appears twice" % duplicate)
    return dict(pairs)


def relative(path):
    """ThemeFiles.relative: not empty, not absolute, no NUL, and no empty, `.` or `..` part."""
    return isinstance(path, str) and path != "" and not path.startswith("/") and "\0" not in path \
        and all(part not in ("", ".", "..") for part in path.split("/"))


def image_size(data):
    """(kind, width, height) from a PNG, JPEG or HEIC's own bytes; None when it is none of them or its size doesn't read."""
    if data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] == b"IHDR":
        return ("PNG",) + struct.unpack(">II", data[16:24])
    if data[:3] == b"\xff\xd8\xff":
        i = 2
        while i + 9 < len(data):
            if data[i] != 0xFF:
                return None
            marker = data[i + 1]
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                i += 2
                continue
            length = struct.unpack(">H", data[i + 2:i + 4])[0]
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                height, width = struct.unpack(">HH", data[i + 5:i + 9])
                return ("JPEG", width, height)
            i += 2 + length
        return None
    if data[4:8] == b"ftyp" and data[8:12] in HEIC_BRANDS:
        sizes = []

        def boxes(start, end):
            while start + 8 <= end:
                size, kind = struct.unpack(">I4s", data[start:start + 8])
                header = 8
                if size == 1:
                    size, header = struct.unpack(">Q", data[start + 8:start + 16])[0], 16
                elif size == 0:
                    size = end - start
                if size < header or start + size > end:
                    return
                body = start + header
                if kind == b"meta":
                    boxes(body + 4, start + size)
                elif kind in (b"iprp", b"ipco"):
                    boxes(body, start + size)
                elif kind == b"ispe" and body + 12 <= start + size:
                    sizes.append(struct.unpack(">II", data[body + 4:body + 12]))
                start += size
        boxes(0, len(data))
        if sizes:
            width, height = max(sizes, key=lambda s: s[0] * s[1])
            return ("HEIC", width, height)
    return None


def text_of(path):
    """A file's text when it is UTF-8, else None (an image, say)."""
    try:
        return path.read_bytes().decode("utf-8")
    except (OSError, UnicodeDecodeError):
        return None


def check_tree(folder, problems):
    """Both kinds: nothing build_index.files leaves out, so a pack holds only what the index lists. No symlink, no hidden
    file or folder, no Python cache; Finder's .DS_Store is the one exception, as git ignores it."""
    for dirpath, dirnames, filenames in os.walk(folder):
        for name in sorted(dirnames + filenames):
            path = Path(dirpath) / name
            where = path.relative_to(folder).as_posix()
            if name == ".DS_Store":
                continue
            if path.is_symlink():
                problems.append("%s is a symlink" % where)
            elif name.startswith("."):
                problems.append("%s is hidden" % where)
            elif name == "__pycache__" or name.endswith(".pyc"):
                problems.append("%s is a Python cache: delete it" % where)
        dirnames[:] = [d for d in dirnames if not d.startswith(".") and d != "__pycache__"
                       and not (Path(dirpath) / d).is_symlink()]


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for k, v in value.items():
            yield k
            yield from strings(v)
    elif isinstance(value, list):
        for v in value:
            yield from strings(v)


def check_palette(name, palette, problems):
    if not isinstance(palette, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in palette.items()):
        problems.append("%s must map role names to colours" % name)
        return False
    missing = [r for r in ROLES if r not in palette]
    if missing:
        problems.append("%s misses %s" % (name, ", ".join(missing)))
    bad = sorted(k for k, v in palette.items() if not COLOUR.match(v))
    if bad:
        problems.append("%s: %s must be #RRGGBB" % (name, ", ".join(bad)))
    return not missing and not bad


def check_manifest(folder, manifest, problems):
    """ThemePack.decode's rules on a parsed manifest, plus the catalogue's. Returns the wallpapers and preview whose
    paths are safe to look at, ([], None) when they aren't."""
    unknown = sorted(set(manifest) - THEME_KEYS)
    if unknown:
        problems.append("manifest.json has fields a pack can't carry: %s" % ", ".join(unknown))
    missing = [k for k in THEME_REQUIRED if k not in manifest]
    if missing:
        problems.append("manifest.json misses %s" % ", ".join(missing))
        return [], None
    if "customMappings" in manifest:
        problems.append("customMappings: a catalogue theme carries none (its template writes text into a local config)")
    if manifest["schema"] != 1 or isinstance(manifest["schema"], bool):
        problems.append("schema must be 1")
    theme_id = manifest["id"]
    if not isinstance(theme_id, str) or not THEME_ID.match(theme_id):
        problems.append("id \"%s\" must be 1 to 80 lowercase letters, digits and hyphens" % theme_id)
    elif folder.name != theme_id:
        problems.append("folder name %s is not its id %s" % (folder.name, theme_id))
    title = manifest["title"]
    if not isinstance(title, str) or not title or any(unicodedata.category(c) in ("Cc", "Cf") for c in title):
        problems.append("title must be text with no control characters")
    if not isinstance(manifest["dark"], bool):
        problems.append("dark must be true or false")
    styles = manifest["styles"]
    if not isinstance(styles, list) or not all(isinstance(s, str) for s in styles) or not set(styles) <= STYLES:
        problems.append("styles must list instrument or toybox")
    ok_palette = check_palette("palette", manifest["palette"], problems)
    variants = manifest.get("variants")
    if variants is not None:
        if not isinstance(variants, dict):
            problems.append("variants must map dark or light to a palette")
        else:
            for mode, palette in variants.items():
                if mode not in ("dark", "light"):
                    problems.append("variants: \"%s\" is not dark or light" % mode)
                    continue
                ok_variant = check_palette("variants.%s" % mode, palette, problems)
                own_mode = "dark" if manifest["dark"] is True else "light"
                if ok_variant and ok_palette and mode == own_mode and palette != manifest["palette"]:
                    problems.append("variants.%s differs from the pack's own palette" % mode)
    material = manifest.get("material")
    if material is not None:
        if not isinstance(material, dict) or set(material) != {"glass", "transparency", "blur"} \
                or not isinstance(material["glass"], bool) or isinstance(material["transparency"], bool) \
                or not isinstance(material["transparency"], int) or not 0 <= material["transparency"] <= 100 \
                or material["blur"] not in BLURS:
            problems.append("material must be glass (true or false), transparency 0 to 100 and blur full, light or off")
    if manifest.get("barPreset") is not None and manifest["barPreset"] not in BAR_PRESETS:
        problems.append("barPreset must be floatingStrip or threeIslands")
    adapters = manifest["adapters"]
    if not isinstance(adapters, dict) or not set(adapters) <= ADAPTERS or any(v != {} for v in adapters.values()):
        problems.append("adapters must be ghostty, zed or obsidian, each {}")
    wallpapers, preview = manifest["wallpapers"], manifest.get("preview")
    if not isinstance(wallpapers, list) or not all(relative(w) for w in wallpapers):
        problems.append("wallpapers must be paths inside the folder")
        wallpapers = []
    if preview is not None and not relative(preview):
        problems.append("preview must be a path inside the folder")
        preview = None
    for text in strings(manifest):
        for beacon in BEACONS:
            if beacon in text.lower():
                problems.append("manifest.json holds \"%s\": a theme never points anywhere" % beacon)
    return wallpapers, preview


def check_theme(folder):
    """The problems with one theme pack folder; none when it is fine."""
    problems = []
    check_tree(folder, problems)
    try:
        manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"), object_pairs_hook=no_duplicate_keys)
    except FileNotFoundError:
        return problems + ["no manifest.json"]
    except ValueError as e:
        return problems + ["manifest.json does not read: %s" % e]
    if not isinstance(manifest, dict):
        return problems + ["manifest.json is not an object"]
    wallpapers, preview = check_manifest(folder, manifest, problems)
    found = check_files(folder, problems, THEME_LIMITS)
    for asset in wallpapers + ([preview] if preview else []):
        if not any(f["path"] == asset or f["path"].startswith(asset + "/") for f in found):
            problems.append("%s is missing or empty" % asset)
    for f in found:
        where = f["path"]
        if f["executable"]:
            problems.append("%s is executable: a theme is data" % where)
        if where == "PROVENANCE.md" and not (text_of(folder / where) or "").strip():
            problems.append("PROVENANCE.md must be UTF-8 text")
        if where in ("manifest.json", "PROVENANCE.md"):
            continue
        if where != preview and not any(where == w or where.startswith(w + "/") for w in wallpapers):
            problems.append("%s is not a wallpaper or the preview the manifest names" % where)
            continue
        size = image_size((folder / where).read_bytes())
        if size is None:
            problems.append("%s is not a PNG, JPEG or HEIC image whose size reads" % where)
        elif max(size[1:]) > MAX_SIDE or size[1] * size[2] > MAX_PIXELS or min(size[1:]) == 0:
            problems.append("%s is %dx%d: images are 1 to %d pixels a side, %d million in all"
                            % (where, size[1], size[2], MAX_SIDE, MAX_PIXELS // 10 ** 6))
    return problems


def skeleton(title):
    """What a title looks like: NFKC, Cyrillic and Greek look-alikes as Latin, case and everything but letters and
    digits dropped."""
    folded = unicodedata.normalize("NFKC", title).translate(LOOKALIKES).casefold()
    return "".join(c for c in unicodedata.normalize("NFKD", folded) if c.isalnum())


def lookalikes(titles):
    """Problems for titles of one kind that look like another's: {folder name: title} in, one line per pair out."""
    seen, problems = {}, []
    for name, title in sorted(titles.items()):
        if not isinstance(title, str):
            continue
        key = skeleton(title)
        if key in seen:
            problems.append("%s and %s: their titles look alike" % (seen[key], name))
        else:
            seen[key] = name
    return problems


def first_sender(path):
    """Who first added `path` (a pack folder) to git: the author's name and email, or None when git doesn't know it."""
    out = subprocess.run(["git", "log", "--diff-filter=A", "--reverse", "--format=%an%x09%ae", "--", str(path)],
                         cwd=ROOT, capture_output=True, text=True)
    lines = out.stdout.splitlines() if out.returncode == 0 else []
    return tuple(lines[0].split("\t", 1)) if lines else None


def flags(author, base):
    """Packs this branch changes since `base` that someone other than `author` (a GitHub login) first sent."""
    out = subprocess.run(["git", "diff", "--name-only", "%s...HEAD" % base, "--", "."], cwd=ROOT,
                         capture_output=True, text=True)
    if out.returncode != 0:
        return ["cannot compare with %s: %s" % (base, out.stderr.strip())]
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    packs = set()
    for changed in out.stdout.splitlines():
        parts = Path(top, changed).relative_to(ROOT).parts
        if len(parts) > 2 and parts[0] in ("extensions", "themes"):
            packs.add(Path(parts[0], parts[1]))
    found = []
    for pack in sorted(packs):
        sender = first_sender(ROOT / pack)
        if sender is None:
            continue  # a new pack: its sender is this author
        name, email = sender
        if name != author and not email.endswith("+%s@users.noreply.github.com" % author):
            found.append("flag: %s was first sent by %s, not %s: Sven reads it" % (pack.as_posix(), name, author))
    return found


def check(folder):
    """The problems with one extension folder; none when it is fine."""
    problems = []
    check_tree(folder, problems)
    try:
        manifest = json.loads((folder / "extension.json").read_text(encoding="utf-8"), object_pairs_hook=no_duplicate_keys)
    except FileNotFoundError:
        return problems + ["no extension.json"]
    except ValueError as e:
        return problems + ["extension.json does not read: %s" % e]
    if not isinstance(manifest, dict):
        return problems + ["extension.json is not an object"]
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


def title_of(folder, manifest_name):
    try:
        return json.loads((folder / manifest_name).read_text(encoding="utf-8")).get("title")
    except (OSError, ValueError, AttributeError):
        return None


def main(argv=None):
    parser = argparse.ArgumentParser(description="Check the catalogue's extensions and themes and its index.")
    parser.add_argument("--author", help="a pull request's GitHub login: flag packs someone else first sent")
    parser.add_argument("--base", default="origin/main", help="what the branch is compared with (default origin/main)")
    args = parser.parse_args(argv)
    failed = False
    kinds = ((build_index.EXTENSIONS, check, "extension.json"), (build_index.THEMES, check_theme, "manifest.json"))
    counts = []
    for root, checker, manifest_name in kinds:
        kind, folders = root.name, build_index.folders(root)
        counts.append(build_index.plural(len(folders), kind[:-1]))
        for folder in folders:
            for problem in checker(folder):
                failed = True
                print("%s/%s: %s" % (kind, folder.name, problem))
        for problem in lookalikes({f.name: title_of(f, manifest_name) for f in folders}):
            failed = True
            print("%s/%s" % (kind, problem))
    if not failed:
        fresh = build_index.render(build_index.build())
        current = build_index.INDEX.read_text(encoding="utf-8") if build_index.INDEX.exists() else ""
        if fresh != current:
            failed = True
            print("index.json is stale: run python3 scripts/build-index.py")
    flagged = flags(args.author, args.base) if args.author else []
    for line in flagged:
        print(line)
    if failed:
        return 1
    print("check: %s fine, index.json fresh" % " and ".join(counts))
    return 2 if flagged else 0


if __name__ == "__main__":
    sys.exit(main())
