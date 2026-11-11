#!/usr/bin/env python3
"""Write index.json, the catalogue Pilot reads, from every extensions/<id>/ and themes/<id>/ folder.

Run after every change to an extension or a theme. scripts/check.py fails when index.json is stale.

Schema 2: {"schema": 2, "extensions": [...], "themes": [...]}. Each entry lists every file with its path (inside its
folder, catalogue/<kind>/<id>/), sha256, size and executable bit. An extension entry is schema 1's unchanged. A theme
pack's manifest has no version (ThemePack.decode refuses unknown keys), so a theme entry carries `digest`, the sha256
of its file list, which changes whenever any file does: that is what an update compares.
"""
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXTENSIONS = ROOT / "extensions"
THEMES = ROOT / "themes"
INDEX = ROOT / "index.json"
SCHEMA = 2


def files(folder):
    """Every file Pilot installs from `folder`: regular files, hidden ones and Python caches left out, by path."""
    found = []
    for dirpath, dirnames, filenames in os.walk(folder):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d != "__pycache__")
        for name in filenames:
            if name.startswith(".") or name.endswith(".pyc"):
                continue
            path = Path(dirpath) / name
            if not path.is_file() or path.is_symlink():
                continue
            data = path.read_bytes()
            found.append({
                "path": path.relative_to(folder).as_posix(),
                "sha256": hashlib.sha256(data).hexdigest(),
                "size": len(data),
                "executable": bool(path.stat().st_mode & stat.S_IXUSR),
            })
    return sorted(found, key=lambda f: f["path"])


def entry(folder):
    """One extension's index entry, read from its manifest."""
    manifest = json.loads((folder / "extension.json").read_text(encoding="utf-8"))
    permissions = manifest.get("permissions") or {}
    return {
        "id": manifest["id"],
        "title": manifest["title"],
        "icon": manifest.get("icon"),
        "version": manifest["version"],
        "description": manifest["description"],
        "examples": list(manifest.get("examples") or []),
        "requires": list(manifest.get("requires") or []),
        "commands": [{"name": c["name"], "title": c["title"], "mode": c["mode"]}
                     for c in manifest["commands"] if not c.get("hidden")],
        "permissions": {
            "network": list(permissions.get("network") or []),
            "clipboard": bool(permissions.get("clipboard", False)),
            "files": list(permissions.get("files") or []),
            "actions": list(permissions.get("actions") or []),
        },
        "files": files(folder),
    }


def theme_entry(folder):
    """One theme pack's index entry, read from its manifest: what a catalogue card shows before anything is downloaded."""
    manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
    listing = files(folder)
    return {
        "id": manifest["id"],
        "title": manifest["title"],
        "dark": manifest["dark"],
        "styles": list(manifest.get("styles") or []),
        "palette": manifest["palette"],
        "preview": manifest.get("preview"),
        "digest": hashlib.sha256("".join("%s %s\n" % (f["path"], f["sha256"]) for f in listing).encode("utf-8")).hexdigest(),
        "files": listing,
    }


def folders(kind=EXTENSIONS):
    """The pack folders of one kind (EXTENSIONS or THEMES), by name; hidden ones left out."""
    if not kind.is_dir():
        return []
    return sorted(p for p in kind.iterdir() if p.is_dir() and not p.name.startswith("."))


def listed(folder):
    """Whether the catalogue offers `folder`: one whose manifest says `"unlisted": true` stays on Sven's Mac only, never in
    index.json (Video downloader, Q470). Pilot ignores the key; it is installed from its folder."""
    try:
        return json.loads((folder / "extension.json").read_text(encoding="utf-8")).get("unlisted") is not True
    except (OSError, ValueError, AttributeError):
        return True


def build():
    return {"schema": SCHEMA, "extensions": [entry(f) for f in folders() if listed(f)],
            "themes": [theme_entry(f) for f in folders(THEMES)]}


def render(index):
    return json.dumps(index, indent=2, ensure_ascii=False) + "\n"


def main():
    index = build()
    INDEX.write_text(render(index), encoding="utf-8")
    count, themes = len(index["extensions"]), len(index["themes"])
    print("index.json: %d extension%s, %d theme%s" % (count, "" if count == 1 else "s", themes, "" if themes == 1 else "s"))


if __name__ == "__main__":
    sys.exit(main())
