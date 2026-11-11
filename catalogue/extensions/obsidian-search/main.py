#!/usr/bin/env python3
"""Obsidian search for Pilot: find a note in an Obsidian vault by title, then by what it says, without opening Obsidian.

The search list is a session (ADR 0010): one process stays up while the view is open. It walks the vault once
(.obsidian, .trash and every hidden folder skipped), so titles answer at once, and reads every note's text in a
background thread, newest first, holding it in memory as written (for snippets) and lowercased (for the search), so
no query touches the disk. Each note's aliases and frontmatter title are kept in paths.cache/index.json, keyed by
modification time and size, so a later session matches them before its read is done. A query that comes before the
read is finished waits for it up to ANSWER_BUDGET, then answers from what is read and says so; a query already
superseded by a newer one is answered with the last list, unsearched. Note text leaves the program only inside list and detail messages; the cache
holds paths, times and aliases, never a note's body.

The page (Sven, 2026-10-31: a page does its job in place) is a search box over the same index, one process an ask: the
recent notes while it is empty, else the matches, a click opening the note in Obsidian, its inline buttons copying the
wikilink or the path and showing it in Finder. The box searches as Sven types: the hidden find command keeps its words
in paths.data for SEARCH_FOR seconds (the words, never a note's text), and the page reads them back.
"""
import collections
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
import unicodedata
from urllib.parse import quote

LIMIT = 50
ANSWER_BUDGET = 1.2
NOTE_BYTES, PREVIEW_BYTES = 1024 * 1024, 256 * 1024
SNIPPET = 100
PREVIEW_LINES, PREVIEW_CHARS = 150, 6000
PAGE_BUDGET = 3.0  # of a page's 5 s, how long a search waits for the vault's read
SEARCH = "search.json"  # in paths.data: the page's search words
SEARCH_FOR = 600  # seconds the page's words count, so a page opened later starts unfiltered
MARKUP = re.compile(r"^(?:#{1,6}\s+|[-*+]\s+\[[ xX]\]\s+|[-*+>]\s+|\d+[.)]\s+)+")


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def fold(text):
    return unicodedata.normalize("NFC", text).lower()


def tilde(path):
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path == home or path.startswith(home + "/") else path


def ago(mtime, now):
    s = max(0, now - mtime)
    if s < 60:
        return "just now"
    if s < 3600:
        return "%d min ago" % (s // 60)
    if s < 86400:
        return "%d h ago" % (s // 3600)
    if s < 2 * 86400:
        return "yesterday"
    if s < 7 * 86400:
        return "%d days ago" % (s // 86400)
    return time.strftime("%-d %b %Y", time.localtime(mtime))


# The vault

def default_vault():
    """The vault Obsidian opened last, from its own vault list; None when Obsidian has none."""
    path = os.path.expanduser("~/Library/Application Support/obsidian/obsidian.json")
    try:
        with open(path, encoding="utf-8") as f:
            vaults = json.load(f).get("vaults")
    except (OSError, ValueError, AttributeError):
        return None
    if not isinstance(vaults, dict):
        return None
    known = [v for v in vaults.values() if isinstance(v, dict) and isinstance(v.get("path"), str)]
    known.sort(key=lambda v: v.get("ts") if isinstance(v.get("ts"), (int, float)) else 0, reverse=True)
    return known[0]["path"] if known else None


def find_vault(run):
    """(vault folder, None) or (None, the reason there is none)."""
    chosen = (run.get("preferences") or {}).get("vault")
    if isinstance(chosen, str) and chosen.strip():
        vault = os.path.abspath(os.path.expanduser(chosen.strip()))
        if not os.path.isdir(vault):
            return None, "has no vault folder %s: set Vault folder on the Extensions page" % tilde(vault)
        return vault, None
    found = default_vault()
    if not found:
        return None, "found no Obsidian vault: open one in Obsidian once, or set Vault folder on the Extensions page"
    vault = os.path.abspath(os.path.expanduser(found))
    if not os.path.isdir(vault):
        return None, "found Obsidian's last vault gone (%s): set Vault folder on the Extensions page" % tilde(vault)
    return vault, None


def frontmatter(text):
    """(aliases and title from the YAML frontmatter, tags, the body after it). A small reader for the common shapes:
    `key: value`, `key: [a, b]` and a `- item` list under the key."""
    if not text.startswith("---"):
        return [], [], text
    end = text.find("\n---", 3)
    if end < 0:
        return [], [], text
    block = text[3:end]
    body = text[end + 4:]
    body = body[body.find("\n") + 1:] if "\n" in body else ""
    fields, key = {}, None
    for line in block.splitlines():
        if not line.strip():
            continue
        if line[:1] not in (" ", "\t", "-") and ":" in line:
            key, value = line.split(":", 1)
            key, value = key.strip().lower(), value.strip()
            fields[key] = []
            if value.startswith("[") and value.endswith("]"):
                fields[key] = [v.strip().strip("'\"") for v in value[1:-1].split(",")]
            elif value:
                fields[key] = [value.strip("'\"")]
        elif key and line.strip().startswith("- "):
            fields[key].append(line.strip()[2:].strip().strip("'\""))
    names = [v for k in ("title", "aliases", "alias") for v in fields.get(k, []) if v]
    tags = [v.lstrip("#") for k in ("tags", "tag") for v in fields.get(k, []) if v]
    return names, tags, body


def read_note(path, limit=NOTE_BYTES):
    with open(path, "rb") as f:
        return f.read(limit).decode("utf-8", "replace")


class Note:
    __slots__ = ("rel", "path", "title", "folder", "mtime", "size", "key", "relkey", "aliases", "aliaskey", "text", "body")

    def __init__(self, vault, rel, mtime, size):
        self.rel = rel
        self.path = os.path.join(vault, rel)
        self.title = unicodedata.normalize("NFC", os.path.basename(rel)[:-3])
        self.folder = unicodedata.normalize("NFC", os.path.dirname(rel))
        self.mtime, self.size = mtime, size
        self.key = fold(self.title)
        self.relkey = fold(rel[:-3])
        self.set_aliases([])
        self.text = self.body = None  # the body as written, and lowercased for the search, both UTF-8

    def set_aliases(self, aliases):
        self.aliases = aliases
        self.aliaskey = [fold(a) for a in aliases]


def walk(vault):
    """Every .md note under `vault` as (path relative to it, mtime, size); hidden folders and symlinked folders are
    left out."""
    found = []
    stack = [""]
    while stack:
        rel = stack.pop()
        try:
            entries = list(os.scandir(os.path.join(vault, rel)))
        except OSError:
            continue
        for e in entries:
            if e.name.startswith("."):
                continue
            sub = os.path.join(rel, e.name) if rel else e.name
            try:
                if e.is_dir(follow_symlinks=False):
                    stack.append(sub)
                elif e.name.lower().endswith(".md") and e.is_file():
                    st = e.stat()
                    found.append((sub, st.st_mtime, st.st_size))
            except OSError:
                continue
    return found


class Index:
    """The vault's notes; titles from the walk, aliases from the cache, bodies filled in by a background read."""

    def __init__(self, vault, cache_dir):
        self.vault = vault
        self.cache_path = os.path.join(cache_dir, "index.json") if cache_dir else None
        self.cached = self.load_cache()
        self.notes = []
        for rel, mtime, size in walk(vault):
            note = Note(vault, rel, mtime, size)
            hit = self.cached.get(rel)
            if isinstance(hit, list) and len(hit) == 3 and hit[0] == mtime and hit[1] == size:
                note.set_aliases(hit[2])
            self.notes.append(note)
        self.notes.sort(key=lambda n: -n.mtime)
        self.stems = collections.Counter(n.key for n in self.notes)
        self.read = 0
        self.loaded = threading.Event()
        self.thread = threading.Thread(target=self.load, daemon=True)
        self.thread.start()

    def load_cache(self):
        if not self.cache_path:
            return {}
        try:
            with open(self.cache_path, encoding="utf-8") as f:
                cache = json.load(f)
        except (OSError, ValueError):
            return {}
        if not isinstance(cache, dict) or cache.get("vault") != self.vault or not isinstance(cache.get("notes"), dict):
            return {}
        return cache["notes"]

    def load(self):
        for note in self.notes:
            try:
                aliases, _, body = frontmatter(read_note(note.path))
            except OSError:
                body, aliases = "", []
            note.set_aliases(aliases)
            body = unicodedata.normalize("NFC", body)
            note.text = body.encode()  # bytes: a str with one emoji costs 4 bytes a character
            note.body = body.lower().encode()
            self.read += 1
        self.loaded.set()
        self.save_cache()

    def save_cache(self):
        if not self.cache_path:
            return
        notes = {n.rel: [n.mtime, n.size, n.aliases] for n in self.notes}
        if notes == self.cached:
            return
        tmp = "%s.%d.tmp" % (self.cache_path, os.getpid())
        try:
            os.makedirs(os.path.dirname(self.cache_path), exist_ok=True)
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump({"vault": self.vault, "notes": notes}, f)
            os.replace(tmp, self.cache_path)
        except OSError:
            try:
                os.remove(tmp)
            except OSError:
                pass

    def link(self, note):
        """An [[wikilink]]: the bare title when no other note shares it, else its path in the vault."""
        return "[[%s]]" % (note.title if self.stems[note.key] <= 1 else note.rel[:-3])


# Searching

def recency(mtime, now):
    """1 for a note changed now, falling towards 0 over weeks: orders notes within a match tier, never across one."""
    return 1.0 / (1.0 + max(0.0, now - mtime) / (14 * 86400.0))


def word_start(hay, q):
    return any(hay.startswith(q, i + 1) for i, c in enumerate(hay) if not c.isalnum())


def title_rank(note, q, tokens):
    """How well the title (or, weaker, an alias) matches: 5 exact, 4 starts with it, 3 a word starts with it, 2 holds
    it, 1 holds every word; None when it does not match."""
    hay = note.key
    if all(t in hay for t in tokens):
        if hay == q:
            return 5
        if hay.startswith(q):
            return 4
        if word_start(hay, q):
            return 3
        return 2 if q in hay else 1
    for alias in note.aliaskey:
        if all(t in alias for t in tokens):
            return 4 if alias == q else 1
    return None


def body_rank(note, q, tokens, needles):
    """1 when the body holds the whole query, 0 when it holds every word (a word may also be in its path), else None.
    `needles` are the query and its words as UTF-8, as the body is held."""
    body = note.body
    if body is None:
        return None
    if needles[0] in body:
        return 1
    if len(tokens) == 1:  # the body was just searched for it
        return 0 if q in note.relkey else None
    return 0 if all(t in note.relkey or n in body for t, n in zip(tokens, needles[1:])) else None


def clean_line(line):
    return " ".join(MARKUP.sub("", line.strip()).split())


def snippet(note, q, tokens, needles):
    """The first line of the note's body holding the query (else its first word), cut to SNIPPET around the match;
    None when the body is not read yet or holds none of it."""
    if note.body is None:
        return None
    at = next((at for at in (note.body.find(n) for n in needles) if at >= 0), -1)
    if at < 0:
        return None
    line = note.text.split(b"\n")[note.body.count(b"\n", 0, at)]  # lower() keeps every line break
    text = clean_line(line.decode("utf-8", "replace"))
    if len(text) <= SNIPPET:
        return text
    found = fold(text)
    at = max(0, next((found.find(n) for n in [q] + tokens if n in found), 0))
    start = max(0, min(at - 30, len(text) - SNIPPET))
    cut = text[start:start + SNIPPET].strip()
    return ("…" if start else "") + cut + ("…" if start + SNIPPET < len(text) else "")


def obsidian_url(vault, rel):
    return "obsidian://open?vault=%s&file=%s" % (quote(os.path.basename(vault), safe=""), quote(rel[:-3], safe=""))


def note_actions(vault, rel, link, preview=True):
    """Open in Obsidian (Return), then Show preview (left out in the preview itself), copy path, copy wikilink and
    reveal in Finder."""
    context = {"vault": vault, "file": rel, "link": link}
    acts = [{"type": "open", "url": obsidian_url(vault, rel), "title": "Open in Obsidian"},
            {"type": "copy", "text": os.path.join(vault, rel), "title": "Copy path"},
            {"type": "copy", "text": link, "title": "Copy wikilink"},
            {"type": "run", "command": "reveal", "title": "Reveal in Finder", "context": context}]
    if preview:
        acts.insert(1, {"type": "push", "command": "note", "title": "Show preview", "context": context})
    return acts


def where(vault, note):
    return note.folder or os.path.basename(vault)


def row(index, note, detail, icon):
    return {"id": note.rel, "title": note.title, "subtitle": "%s · %s" % (where(index.vault, note), detail),
            "icon": icon, "actions": note_actions(index.vault, note.rel, index.link(note))}


def search(index, query, deadline):
    now = time.time()
    q = " ".join(fold(query).split())
    tokens = q.split()
    if not index.notes:
        return [{"title": "No notes in %s" % tilde(index.vault), "subtitle": "Set Vault folder on the Extensions page"}]
    if not tokens:
        return [row(index, n, ago(n.mtime, now), "📝") for n in index.notes[:LIMIT]]
    index.loaded.wait(max(0.0, deadline - time.monotonic()))
    needles = [q.encode()] + [t.encode() for t in tokens]
    ranked = []
    for n in index.notes:
        rank = title_rank(n, q, tokens)
        if rank is not None:
            ranked.append((2, rank + recency(n.mtime, now), n))
            continue
        rank = body_rank(n, q, tokens, needles)
        if rank is not None:
            ranked.append((1, rank + recency(n.mtime, now), n))
    ranked.sort(key=lambda r: (-r[0], -r[1], r[2].key))
    items = []
    for tier, _, n in ranked[:LIMIT]:
        items.append(row(index, n, snippet(n, q, tokens, needles) or ago(n.mtime, now), "📝" if tier == 2 else "🔎"))
    if not index.loaded.is_set():
        items.append({"title": "Still reading the vault: %d of %d notes searched" % (index.read, len(index.notes)),
                      "subtitle": "Type on, or search again in a moment for the rest", "icon": "⏳"})
    elif not items:
        items = [{"title": "No note matches “%s”" % query.strip(), "subtitle": "Searched %d notes in %s"
                  % (len(index.notes), tilde(index.vault)), "icon": "🔍"}]
    return items


def serve(run, started):
    """The session: answers the run message's query, then each query message in order, until close or stdin ends."""
    queries = queue.Queue()  # (time it came, its text), then None once the view closed

    def read_input():
        for line in sys.stdin:
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if not isinstance(message, dict) or message.get("type") == "close":
                break
            if message.get("type") == "query":
                queries.put((time.monotonic(), message.get("text")))
        queries.put(None)

    threading.Thread(target=read_input, daemon=True).start()
    vault, problem = find_vault(run)
    index = Index(vault, (run.get("paths") or {}).get("cache")) if vault else None

    last = []

    def answer(text, received):
        if not index:
            send({"type": "error", "text": problem})
            return
        if last and any(q is not None for q in list(queries.queue)):
            send(last[0])  # a newer query waits: this answer is replaced at once, so the last one does
            return
        try:
            message = {"type": "list", "items": search(index, text if isinstance(text, str) else "",
                                                       received + ANSWER_BUDGET)}
        except Exception as e:  # one honest row, never a traceback that could quote a note
            message = {"type": "error", "text": "could not search: %s" % type(e).__name__}
        last[:] = [message]
        send(message)

    answer(run.get("query"), started)
    for got in iter(queries.get, None):
        answer(got[1], got[0])
    if index and index.loaded.is_set():
        index.thread.join(0.3)  # let the cache write finish


# The page

def held_words(run):
    """The page's search words while they are younger than SEARCH_FOR, else ""."""
    try:
        with open(os.path.join((run.get("paths") or {}).get("data") or "", SEARCH), encoding="utf-8") as f:
            held = json.load(f)
    except (OSError, ValueError):
        return ""
    if not isinstance(held, dict) or time.time() - (held.get("at") or 0) > SEARCH_FOR:
        return ""
    return held.get("query") if isinstance(held.get("query"), str) else ""


def find(run):
    """The page's box: its words kept for the page, an emptied box (or Clear) forgetting them. Quiet: the page shows."""
    folder = (run.get("paths") or {}).get("data")
    if not folder:
        return
    path = os.path.join(folder, SEARCH)
    words = " ".join((run.get("input") or "").split())
    if not words or (run.get("context") or {}).get("clear"):
        try:
            os.remove(path)
        except OSError:
            pass
        return
    os.makedirs(folder, exist_ok=True)
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        json.dump({"query": words, "at": time.time()}, f)
    os.replace(path + ".tmp", path)


def page_row(item):
    """A list row on the page: a click opens the note in Obsidian; Copy wikilink, Copy path and Reveal in Finder as
    inline buttons. Show preview stays in Hyper+Space. A status row has no actions and stays as it is."""
    by = {a["title"]: a for a in item.get("actions", [])}
    if "Open in Obsidian" not in by:
        return item
    inline = [dict(by[t], icon=icon) for t, icon in (("Copy wikilink", "🔗"), ("Copy path", "📋"), ("Reveal in Finder", "📂"))]
    return dict(item, actions=[by["Open in Obsidian"]], inline=inline)


def page(run, started):
    """The page: the search box, then the recent notes, or the notes matching its words."""
    words = held_words(run)
    blocks = [{"type": "input", "placeholder": "Search notes by title or by what they say", "live": True,
               "action": {"type": "run", "command": "find", "title": "Search"}}]
    vault, problem = find_vault(run)
    if not vault:
        blocks.append({"type": "markdown", "text": "Obsidian search %s." % problem})
        send({"type": "blocks", "blocks": blocks})
        return
    if words:
        blocks.append({"type": "buttons", "actions": [{"type": "run", "command": "find", "title": "Clear “%s”" % words,
                                                       "context": {"clear": True}}]})
    index = Index(vault, (run.get("paths") or {}).get("cache"))
    items = search(index, words, started + PAGE_BUDGET)
    title = "Matches in %s" % os.path.basename(vault) if words else "Recent in %s" % os.path.basename(vault)
    blocks.append({"type": "list", "title": title, "items": [page_row(i) for i in items]})
    send({"type": "blocks", "blocks": blocks})


# Preview and reveal

def note_from(run):
    """(vault, absolute path, path in the vault) of the note the context names, or None when it is not a note in it."""
    context = run.get("context") if isinstance(run.get("context"), dict) else {}
    vault, rel = context.get("vault"), context.get("file")
    if not (isinstance(vault, str) and isinstance(rel, str) and rel.lower().endswith(".md")):
        return None
    real_vault = os.path.realpath(vault)
    path = os.path.realpath(os.path.join(vault, rel))
    if not (path.startswith(real_vault + os.sep) and os.path.isfile(path)):
        return None
    return vault, os.path.join(vault, rel), rel


def trim(body):
    lines = body.strip("\n").splitlines()
    text = "\n".join(lines[:PREVIEW_LINES])
    cut = len(lines) > PREVIEW_LINES or len(text) > PREVIEW_CHARS
    text = text[:PREVIEW_CHARS]
    if text.count("```") % 2:
        text += "\n```"
    return text, cut


def show_note(run):
    found = note_from(run)
    if not found:
        send({"type": "error", "text": "that note is gone"})
        return
    vault, path, rel = found
    context = run["context"]
    names, tags, body = frontmatter(read_note(path, PREVIEW_BYTES))
    st = os.stat(path)
    note = Note(vault, rel, st.st_mtime, st.st_size)
    text, cut = trim(body)
    markdown = "# %s\n\n%s" % (note.title, text or "*This note is empty.*")
    if cut:
        markdown += "\n\n*Trimmed: open it in Obsidian for the rest.*"
    metadata = [{"label": "Folder", "text": where(vault, note)},
                {"label": "Modified", "text": "%s (%s)" % (time.strftime("%-d %b %Y %H:%M", time.localtime(st.st_mtime)),
                                                           ago(st.st_mtime, time.time()))},
                {"label": "Words", "text": str(len(body.split())) if st.st_size <= PREVIEW_BYTES else "over 256 KB"}]
    if tags:
        metadata.append({"label": "Tags", "text": ", ".join(tags)})
    if names:
        metadata.append({"label": "Also called", "text": ", ".join(names)})
    link = context.get("link") if isinstance(context.get("link"), str) else "[[%s]]" % note.title
    send({"type": "detail", "markdown": markdown, "metadata": metadata,
          "actions": note_actions(vault, rel, link, preview=False)})


def reveal(run):
    found = note_from(run)
    if not found:
        send({"type": "error", "text": "that note is gone"})
        return
    done = subprocess.run(["open", "-R", found[1]], capture_output=True, text=True, timeout=10)
    if done.returncode != 0:
        send({"type": "error", "text": "Finder did not open: open exited %d" % done.returncode})
        return
    send({"type": "hud", "text": "Shown in Finder"})


def main():
    started = time.monotonic()
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        send({"type": "error", "text": "got a run message it could not read"})
        return
    command = run.get("command")
    if command == "search":
        serve(run, started)
    elif command == "note":
        show_note(run)
    elif command == "reveal":
        reveal(run)
    elif command == "page":
        page(run, started)
    elif command == "find":
        find(run)
    else:
        send({"type": "error", "text": "has no command %s" % command})


if __name__ == "__main__":
    main()
