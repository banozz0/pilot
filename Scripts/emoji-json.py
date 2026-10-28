#!/usr/bin/env python3
"""Packaging/emoji.json from github/gemoji's db/emoji.json (MIT, its notice in Packaging/gemoji-LICENSE.txt).

Each emoji keeps gemoji's order and is trimmed to its emoji (e), its name (n), its aliases and tags but the name itself
as sorted keywords (k) and its category (c), which the emoji grid heads its blocks with (EmojiSearch, EmojiGrid).

    curl -sSLo /tmp/gemoji.json https://raw.githubusercontent.com/github/gemoji/master/db/emoji.json
    python3 Scripts/emoji-json.py /tmp/gemoji.json > Packaging/emoji.json
"""
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    gemoji = json.load(f)
trimmed = [{"e": g["emoji"], "n": g["description"], "k": sorted(set(g["aliases"] + g["tags"]) - {g["description"]}), "c": g["category"]} for g in gemoji]
sys.stdout.write(json.dumps(trimmed, ensure_ascii=False, separators=(",", ":")))
