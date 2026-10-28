#!/usr/bin/env python3
"""Rust-crates-LICENSES.txt: every crates.io crate linked into pilot-files, the file index, with its copyright lines and
licence texts.

The crates are cargo tree's normal edges for Apple silicon, build-time macros left out; each crate's texts are the licence
files it ships in the cargo registry (offline), texts identical but for whitespace printed once. A -sys crate's bundled C library adds its own
LICENSE from the folder its `links` names (zstd-sys: zstd's BSD licence, not its GPL alternative). A crate that ships no
licence file gets the standard text of the licence its Cargo.toml declares, with its authors as the copyright line; a crate
neither covers fails the build, so a new crate never ships without its text (General › About, Acknowledgements).

    python3 -I Scripts/rust-licenses.py Helpers/pilot-files/Cargo.toml > Rust-crates-LICENSES.txt
"""
import json
import re
import subprocess
import sys
from pathlib import Path

MIT = """Copyright (c) {holder}

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE."""
WTFPL = """            DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
                    Version 2, December 2004

 Copyright (C) 2004 Sam Hocevar <sam@hocevar.net>

 Everyone is permitted to copy and distribute verbatim or modified
 copies of this license document, and changing it is allowed as long
 as the name is changed.

            DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
   TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION

  0. You just DO WHAT THE FUCK YOU WANT TO."""
STANDARD = {"MIT": MIT, "WTFPL": WTFPL}  # a choice of licences takes the first of these it offers
LICENCE_FILE = re.compile(r"^(licen[cs]e|copying|copyright|unlicense|notice)", re.I)
COPYRIGHT_LINE = re.compile(r"copyright\s*(\(c\)|©|\d{4})|©", re.I)

manifest = sys.argv[1]
tree = subprocess.run(["cargo", "tree", "--offline", "--manifest-path", manifest, "--edges", "normal,no-proc-macro",
                       "--prefix", "none", "--target", "aarch64-apple-darwin", "--format", "{p}"],
                      check=True, capture_output=True, text=True).stdout
linked = {tuple(line.split()[:2]) for line in tree.splitlines() if line and " (/" not in line}  # path crates are Pilot's own or Cardinal's
meta = json.loads(subprocess.run(["cargo", "metadata", "--offline", "--format-version", "1", "--manifest-path", manifest,
                                  "--filter-platform", "aarch64-apple-darwin"], check=True, capture_output=True, text=True).stdout)
packages = {(p["name"], "v" + p["version"]): p for p in meta["packages"]}

texts = {}  # text with its whitespace collapsed -> (number, file name, text, [crate ids])
crates = []
unresolved = []
for key in sorted(linked):
    p = packages[key]
    crate = " ".join(key)
    root = Path(p["manifest_path"]).parent
    files = sorted(f for f in root.iterdir() if f.is_file() and LICENCE_FILE.match(f.name))
    if p.get("links") and (root / p["links"] / "LICENSE").is_file():
        files.append(root / p["links"] / "LICENSE")
    elif p["name"].endswith("-sys"):
        unresolved.append(f"{p['name']} bundles native code but {p.get('links')}/LICENSE is missing")
    found = [(str(f.relative_to(root)), f.read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n").strip()) for f in files]
    holders = ", ".join(re.sub(r"\s*<[^>]*>", "", a) for a in p["authors"]) or f"the {p['name']} authors"
    note = ""
    if not found:
        spdx = next((s for s in re.findall(r"[\w.+-]+", p["license"] or "") if s in STANDARD), None)
        if not spdx:
            unresolved.append(f"{crate} ships no licence file and declares {p['license']!r}")
            continue
        found = [(spdx, STANDARD[spdx].format(holder=holders))]
        note = f"no licence file in the crate; {spdx} as its Cargo.toml declares"
    lines = sorted({line.strip() for _, t in found for line in t.splitlines()
                    if COPYRIGHT_LINE.search(line) and "[yyyy]" not in line and "<year>" not in line})
    ids = []
    for name, text in found:
        same = " ".join(text.split())
        number, _, _, users = texts.setdefault(same, (len(texts) + 1, name, text, []))
        users.append(crate)
        ids.append(number)
    crates.append((crate, p["license"], lines or [f"Authors: {holders}"], sorted(set(ids)), note))

if unresolved:
    sys.exit("rust-licenses: unresolved:\n  " + "\n  ".join(unresolved))
out = [f"The {len(crates)} Rust crates linked into pilot-files, the file index, each with its copyright",
       f"lines and the licence texts it ships ({len(texts)} distinct texts below, each printed once).", ""]
for name, spdx, lines, ids, note in crates:
    out.append(f"{name} · {spdx} · texts {', '.join(map(str, ids))}" + (f" ({note})" if note else ""))
    out += [f"    {line}" for line in lines]
for n, name, text, users in texts.values():
    out += ["", "=" * 78, f"Text {n}: {name}, from {', '.join(users)}", "=" * 78, "", text]
sys.stdout.write("\n".join(out) + "\n")
print(f"rust-licenses: {len(crates)} crates, {len(texts)} texts, 0 unresolved", file=sys.stderr)
