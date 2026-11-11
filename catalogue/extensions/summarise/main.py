#!/usr/bin/env python3
"""Summarise for Pilot (Sven, 2026-10-25: Q478, Q480 to Q482): a YouTube video's transcript, a web page's readable text or
a document's text, summarised by Pilot's own AI, shown on the extension's page with the full text, Save as .md (to
~/Downloads) and Ask about it.

`summarise` is the Hyper+Space list: a link or a path typed, the link or the Finder file on the clipboard, documents by
name (Spotlight), and the earlier ones. `fetch` (also the keyword "summarise …" and the selection pill's Summarise) reads
the source, opens the page and asks Pilot's AI through an `ai` action (ADR 0010, amended 2026-10-25), whose answer comes
back as `summarised`'s input; `ask` and `answered` do the same for a question. The AI runs only as Sven runs one of
those (Q478): the list and the page read the disk and never ask it, and the page asks again every 2 s only while an
answer is on its way. Each source is one JSON file in paths.data/items; paths.data/current names the one the page shows.
The page leads with a box (Sven, 2026-10-31): a link or a file's path pasted, or a document picked with its Choose button,
and Summarise runs `fetch` on it, as the list's row would.
`delete` removes one source and `clear-failed` every failed one (P94); a source removed while it is read or summarised
stays gone, its late answer only saying so.
`bar` is the menu-bar item (Q485): 📝, with … while a summary is on its way, from the disk alone; its popover, asked on a
click, offers what is copied (a link, a Finder file or text) as one row whose click summarises it, a box to paste a link
or text into, and the last summary. Only the popover reads the clipboard, and the AI still runs only on a click.
Python 3.9 stdlib only, as macOS's /usr/bin/python3; a PDF's text comes from PDFKit through osascript's JavaScript and a
rich document's through textutil, both on every Mac, neither a target that asks for permission.
"""
import hashlib
import html
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from html.parser import HTMLParser
from urllib.parse import parse_qs, quote, urlparse

DOWNLOADS = os.path.expanduser("~/Downloads")
PAGE = "pilot://open?tab=page&extension=summarise"
AGENT = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 "
         "Safari/605.1.15")
# YouTube's consent wall in the EU is skipped by the cookie its own "Reject all" sets.
YOUTUBE_HEADERS = {"User-Agent": AGENT, "Accept-Language": "en-US,en;q=0.9", "Cookie": "SOCS=CAI; CONSENT=YES+"}
# The web player's caption links need a proof token now; the Android player's do not (probed 2026-10-25).
ANDROID = {"clientName": "ANDROID", "clientVersion": "20.10.38"}
VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")
LARGEST_PAGE = 5 * 1024 * 1024
SHOWN = 40000  # of the full text, how much the page draws; the .md file holds it all
KEPT = 30  # earlier sources kept; the oldest go
CUE_SPAN = 30  # seconds of transcript per line
STALE = 300  # seconds a read or an answer may take before the page stops waiting for it
DOCUMENTS = ("com.adobe.pdf", "public.plain-text", "public.rtf", "net.daringfireball.markdown", "public.html",
             "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "org.oasis-open.opendocument.text")
RICH = {".rtf", ".rtfd", ".doc", ".docx", ".odt", ".html", ".htm", ".webarchive", ".wordml"}
NOUN = {"video": "video", "page": "page", "doc": "document", "text": "text"}
# What the page's Choose button offers: the documents `document` reads.
PICKED = ["pdf", "txt", "md", "markdown", "rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive"]
SENT = 150000  # of a source, how much goes to Pilot's AI: Pilot's own cut (ExtensionAI.longest)
SUMMARY_TASK = ("Summarise this %s in 3 to 6 short Markdown bullets of its main points, in the source's own language. "
                "Bullets only: no heading and no closing line.")
ASK_TASK = ("Answer the question after the source from the source alone, in a few sentences. When the source has "
            "timestamps such as [12:30], cite the one the answer comes from. If the source does not say, say so.")


class Problem(Exception):
    """Why a source could not be read, in words for the page."""


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


def run_action(command, title, context=None, **fields):
    action = {"type": "run", "command": command, "title": title}
    if context is not None:
        action["context"] = context
    action.update(fields)
    return action


class Store:
    """The extension's data folder: a source's facts in <id>.json and its full text in <id>.txt, so the list and the page
    read the facts of every earlier one without their text; and which one the page shows."""

    def __init__(self, run):
        self.root = (run.get("paths") or {}).get("data") or os.path.join(os.environ.get("TMPDIR", "/tmp"), "summarise")
        self.items = os.path.join(self.root, "items")
        self.pointer = os.path.join(self.root, "current")
        os.makedirs(self.items, exist_ok=True)

    def path(self, item_id, ext=".json"):
        return os.path.join(self.items, re.sub(r"[^a-z0-9]", "", item_id) + ext)

    def load(self, item_id, text=False):
        """Its facts, with its full text as "text" when asked and read; None when it is gone."""
        try:
            with open(self.path(item_id), encoding="utf-8") as f:
                item = json.load(f)
        except (OSError, ValueError):
            return None
        if not isinstance(item, dict):
            return None
        if text:
            try:
                with open(self.path(item_id, ".txt"), encoding="utf-8") as f:
                    item["text"] = f.read()
            except OSError:  # still being read
                pass
        return item

    def save(self, item):
        """Its facts, and its full text when it carries one."""
        item["at"] = time.time()
        facts = dict(item)
        if "text" in facts:
            write_file(self.path(item["id"], ".txt"), facts.pop("text"))
        write_file(self.path(item["id"]), json.dumps(facts, ensure_ascii=False))

    def current(self, text=False):
        try:
            with open(self.pointer, encoding="utf-8") as f:
                return self.load(f.read().strip(), text)
        except OSError:
            return None

    def show(self, item):
        """The page shows `item` from now, and it is the newest of the earlier ones."""
        write_file(self.pointer, item["id"])
        self.save(item)

    def remove(self, item_id):
        for ext in (".txt", ".json"):
            discard(self.path(item_id, ext))

    def forget(self, ids):
        """Removes these sources; if the page shows one of them, it moves to the newest left, or to its empty state. The
        pointer alone moves: `show` would date that source now, and a stale one would count as working again."""
        shown = self.current()
        for item_id in ids:
            self.remove(item_id)
        if not shown or shown["id"] not in ids:
            return
        left = self.earlier()
        if left:
            write_file(self.pointer, left[0]["id"])
        else:
            discard(self.pointer)

    def earlier(self):
        """Every source, newest first; past KEPT the oldest are deleted."""
        found = []
        for name in os.listdir(self.items):
            item = self.load(name[:-5]) if name.endswith(".json") else None
            if item:
                found.append(item)
        found.sort(key=lambda i: i.get("at", 0), reverse=True)
        for old in found[KEPT:]:
            try:
                self.remove(old["id"])
            except OSError:
                pass
        return found[:KEPT]


def discard(path):
    try:
        os.remove(path)
    except FileNotFoundError:
        pass


def write_file(path, text):
    part = path + ".part"
    with open(part, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(part, path)


# MARK: Sources

def youtube_id(text):
    """The video id of a YouTube link (watch, youtu.be, shorts, live, embed); None for anything else."""
    url = urlparse(text if "://" in text else "https://" + text)
    host = (url.hostname or "").lower()
    if host.endswith("youtu.be"):
        vid = url.path.strip("/").split("/")[0]
    elif host == "youtube.com" or host.endswith(".youtube.com"):
        vid = (parse_qs(url.query).get("v") or [""])[0]
        parts = url.path.strip("/").split("/")
        if not vid and len(parts) >= 2 and parts[0] in ("shorts", "live", "embed", "v"):
            vid = parts[1]
    else:
        return None
    return vid if VIDEO_ID.match(vid or "") else None


def is_link(text):
    url = urlparse(text)
    return url.scheme in ("http", "https") and bool(url.netloc) and not re.search(r"\s", text)


def as_path(text):
    """A file a text names (a path, ~ or a file:// link) when it exists; else None."""
    if text.startswith("file://"):
        text = urllib.request.url2pathname(urlparse(text).path)
    path = os.path.expanduser(text)
    return path if text[:1] in ("/", "~") and os.path.isfile(path) else None


def kind_of(source):
    if youtube_id(source):
        return "video"
    if is_link(source):
        return "page"
    if as_path(source):
        return "doc"
    return "text"


def get(url, headers, data=None, timeout=10, limit=LARGEST_PAGE):
    """The body and content type of `url`; a Problem when it does not answer."""
    request = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read(limit + 1)
            return body[:limit], response.headers.get_content_type(), response.headers.get_content_charset() or "utf-8"
    except urllib.error.HTTPError as e:
        raise Problem("%s answered %d" % (urlparse(url).hostname, e.code))
    except (urllib.error.URLError, OSError) as e:
        raise Problem("%s did not answer (%s)" % (urlparse(url).hostname, getattr(e, "reason", e)))


def clock(seconds):
    seconds = int(seconds or 0)
    h, m, s = seconds // 3600, seconds // 60 % 60, seconds % 60
    return "%d:%02d:%02d" % (h, m, s) if h else "%d:%02d" % (m, s)


def video(vid):
    """Its title, channel, length and transcript, one line per CUE_SPAN seconds stamped [m:ss]."""
    page, _, charset = get("https://www.youtube.com/watch?v=" + vid, YOUTUBE_HEADERS)
    page = page.decode(charset, "replace")
    key = re.search(r'"INNERTUBE_API_KEY":"([^"]+)"', page)
    if not key:
        raise Problem("YouTube's page did not read")
    body = json.dumps({"context": {"client": ANDROID}, "videoId": vid}).encode()
    answer, _, _ = get("https://www.youtube.com/youtubei/v1/player?key=" + key.group(1),
                       dict(YOUTUBE_HEADERS, **{"Content-Type": "application/json"}), data=body)
    try:
        player = json.loads(answer)
    except ValueError:
        raise Problem("YouTube's player did not read")
    details = player.get("videoDetails") or {}
    tracks = ((player.get("captions") or {}).get("playerCaptionsTracklistRenderer") or {}).get("captionTracks") or []
    if not tracks:
        why = (player.get("playabilityStatus") or {}).get("reason")
        raise Problem(why or "This video has no transcript")

    def rank(track):
        english = (track.get("languageCode") or "").startswith("en")
        spoken = track.get("kind") != "asr"
        return (not english, not spoken)

    track = sorted(tracks, key=rank)[0]
    xml, _, _ = get(track["baseUrl"].replace("&fmt=srv3", ""), YOUTUBE_HEADERS)
    lines, start, words = [], None, []
    for begin, said in re.findall(r'<text start="([\d.]+)"[^>]*>(.*?)</text>', xml.decode("utf-8", "replace"), re.S) + [("", "")]:
        # Captions arrive escaped twice (&amp;#39;); the empty last cue writes the last line.
        said = re.sub(r"\s+", " ", html.unescape(html.unescape(said))).strip()
        if said and start is not None and float(begin) - start < CUE_SPAN:
            words.append(said)
            continue
        if words:
            lines.append("[%s] %s" % (clock(start), " ".join(words)))
        if said:
            start, words = float(begin), [said]
    if not lines:
        raise Problem("This video's transcript is empty")
    return {"title": details.get("title") or "YouTube video", "channel": details.get("author"),
            "length": clock(details.get("lengthSeconds")) if details.get("lengthSeconds") else None,
            "language": track.get("languageCode"), "text": "\n".join(lines)}


class Readable(HTMLParser):
    """A page's title and readable text: an <article>'s, else <main>'s, else the body's, without scripts, menus and forms."""
    SKIP = {"script", "style", "noscript", "svg", "nav", "header", "footer", "aside", "form", "button", "iframe",
            "template", "select", "figure"}
    BLOCK = {"p", "div", "li", "h1", "h2", "h3", "h4", "h5", "h6", "br", "tr", "section", "blockquote", "pre", "dd", "dt"}
    VOID = {"br", "img", "hr", "meta", "link", "input", "source", "wbr", "area", "base", "col", "embed", "param", "track"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.title, self.meta_title, self.skipping, self.in_title = "", None, 0, False
        self.open = []
        self.parts = {"article": [], "main": [], "body": []}

    def handle_starttag(self, tag, attrs):
        if tag == "meta":
            a = dict(attrs)
            if a.get("property") == "og:title" and a.get("content"):
                self.meta_title = a["content"]
        if tag in self.VOID:
            if tag == "br":
                self.text("\n")
            return
        self.open.append(tag)
        if tag in self.SKIP:
            self.skipping += 1
        elif tag == "title":
            self.in_title = True
        elif tag in self.BLOCK:
            self.text("\n")

    def handle_endtag(self, tag):
        if tag not in self.open:
            return
        while self.open:
            last = self.open.pop()
            if last in self.SKIP:
                self.skipping -= 1
            if last == tag:
                break
        if tag == "title":
            self.in_title = False
        elif tag in self.BLOCK:
            self.text("\n")

    def handle_data(self, data):
        if self.in_title:
            self.title += data
        elif not self.skipping:
            self.text(data)

    def text(self, data):
        self.parts["body"].append(data)
        for part in ("article", "main"):
            if part in self.open:
                self.parts[part].append(data)

    def readable(self):
        for part in ("article", "main", "body"):
            lines = [re.sub(r"[ \t ]+", " ", line).strip() for line in "".join(self.parts[part]).split("\n")]
            text = "\n\n".join(line for line in lines if len(line) > 1)
            if len(text) >= 200 or part == "body":
                return text


def web(url):
    body, kind, charset = get(url, {"User-Agent": AGENT, "Accept-Language": "en-US,en;q=0.9"})
    name = urlparse(url).hostname or url
    if kind == "application/pdf" or body[:5] == b"%PDF-":
        return {"title": os.path.basename(urlparse(url).path) or name, "text": pdf_text(None, body)}
    if kind.startswith("text/plain"):
        return {"title": name, "text": body.decode(charset, "replace")}
    reader = Readable()
    try:
        reader.feed(body.decode(charset, "replace"))
    except Exception:  # html.parser raises on a few broken pages; what it read so far still counts
        pass
    text = reader.readable()
    if not text.strip():
        raise Problem("This page has no text Summarise can read (it may need JavaScript)")
    title = (reader.meta_title or reader.title or name).strip()
    return {"title": re.sub(r"\s+", " ", html.unescape(title)), "text": text}


PDF_SCRIPT = """ObjC.import('PDFKit');
function run(argv) {
  var doc = $.PDFDocument.alloc.initWithURL($.NSURL.fileURLWithPath(argv[0]));
  return doc.isNil() ? '' : (ObjC.unwrap(doc.string) || '');
}"""


def pdf_text(path, data=None):
    """A PDF's text through PDFKit (osascript's JavaScript, no app target); `data` is written to a temp file first."""
    temp = None
    if data is not None:
        temp = os.path.join(os.environ.get("TMPDIR", "/tmp"), "summarise-%d.pdf" % os.getpid())
        with open(temp, "wb") as f:
            f.write(data)
        path = temp
    try:
        done = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", PDF_SCRIPT, path], capture_output=True,
                              timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        raise Problem("The PDF's text did not read in time")
    finally:
        if temp:
            os.remove(temp)
    text = done.stdout.decode("utf-8", "replace").strip()
    if not text:
        raise Problem("This PDF has no text to read (a scan has only pictures)")
    return text


def document(path):
    ext = os.path.splitext(path)[1].lower()
    if ext == ".pdf":
        text = pdf_text(path)
    elif ext in RICH or os.path.isdir(path):
        try:
            done = subprocess.run(["/usr/bin/textutil", "-convert", "txt", "-stdout", path], capture_output=True, timeout=20)
        except (OSError, subprocess.TimeoutExpired):
            raise Problem("textutil did not read %s" % os.path.basename(path))
        text = done.stdout.decode("utf-8", "replace")
    else:
        with open(path, "rb") as f:
            raw = f.read(LARGEST_PAGE)
        if b"\0" in raw[:4096]:
            raise Problem("%s is not a text document" % os.path.basename(path))
        text = raw.decode("utf-8", "replace")
    if not text.strip():
        raise Problem("%s has no text" % os.path.basename(path))
    return {"title": os.path.basename(path), "text": text.strip()}


def read_source(source, kind):
    if kind == "video":
        try:
            return video(youtube_id(source))
        except Problem:  # YouTube now and then turns one ask away; a second one a moment later reads
            time.sleep(1)
            return video(youtube_id(source))
    if kind == "page":
        return web(source)
    if kind == "doc":
        return document(as_path(source))
    first = source.strip().split("\n")[0]
    return {"title": first[:60] + ("…" if len(first) > 60 else ""), "text": source.strip()}


# MARK: The clipboard and Spotlight

def started(args):
    try:
        return subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    except OSError:
        return None


def said(process, timeout):
    """What a started process printed, or None when it failed or took longer than `timeout`."""
    if not process:
        return None
    try:
        out, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        return None
    return out.strip() if process.returncode == 0 else None


def clipboard_link():
    text = said(started(["pbpaste"]), 0.5)
    return text if text and is_link(text) else None


def clipboard_file(process):
    """A file copied in Finder (⌘C), from the clipboard's file URL: no Finder automation, so no permission asked."""
    path = said(process, 0.8)
    return path if path and os.path.isfile(path) else None


def copied_now():
    """The clipboard's text and its Finder file, both asked at once: each is a process start, and a list has 2 s."""
    reading = started(["pbpaste"]), started(["osascript", "-e", "POSIX path of (the clipboard as «class furl»)"])
    return said(reading[0], 0.5), clipboard_file(reading[1])


def documents(words, limit=8):
    """Documents in the home folder whose name holds `words`, through Spotlight; none when it is slow."""
    name = words.replace("\\", "").replace('"', "")
    kinds = " || ".join('kMDItemContentTypeTree == "%s"' % k for k in DOCUMENTS)
    try:
        done = subprocess.run(["/usr/bin/mdfind", "-onlyin", os.path.expanduser("~"),
                               'kMDItemFSName == "*%s*"cd && (%s)' % (name, kinds)], capture_output=True, text=True, timeout=1.0)
    except (OSError, subprocess.TimeoutExpired):
        return []
    return [p for p in done.stdout.splitlines() if p and "/Library/" not in p][:limit]


# MARK: Commands

def noun(kind):
    return NOUN.get(kind, "text")


def short(source):
    return re.sub(r"^https?://(www\.)?", "", source)[:80]


def delete_action(item_id, **fields):
    return run_action("delete", "Delete", {"id": item_id}, destructive=True, **fields)


def start_row(source, title, subtitle, icon, row_id):
    return {"id": row_id, "title": title, "subtitle": subtitle, "icon": icon,
            "actions": [run_action("fetch", "Summarise", {"source": source})]}


def summarise(run, store):
    """The Hyper+Space list: what can be summarised now, then the earlier ones."""
    query = (run.get("query") or "").strip()
    kind = kind_of(query) if query else None
    rows = []
    if kind in ("video", "page", "doc"):
        rows.append(start_row(query, "Summarise %s" % short(query), noun(kind).capitalize(), "📝", "typed"))
    elif not query:
        text, copied = copied_now()
        link = text if text and is_link(text) else None
        if link:
            rows.append(start_row(link, "Summarise the copied link", short(link), "🔗", "clipboard"))
        if copied:
            rows.append(start_row(copied, "Summarise %s" % os.path.basename(copied), "Copied in Finder", "📄", "finder"))
    elif len(query) >= 2:
        for path in documents(query):
            rows.append(start_row(path, os.path.basename(path), os.path.dirname(path).replace(os.path.expanduser("~"), "~"),
                                  "📄", "doc:" + path))
    words = query.lower()
    for item in store.earlier():
        if words and words not in item.get("title", "").lower() and words not in item.get("source", "").lower():
            continue
        rows.append({"id": "item:" + item["id"], "title": item.get("title") or short(item["source"]), "section": "Earlier",
                     "subtitle": noun(item.get("kind")).capitalize() + " · " + short(item.get("source", "")),
                     "icon": "🗂️", "actions": [run_action("show", "Open", {"id": item["id"]}),
                                               delete_action(item["id"], key="cmd+delete", stay=True)]})
    if not rows:
        rows.append({"id": "hint", "title": "Copy a link or a file, or type a link or a document's name",
                     "subtitle": "YouTube videos, web pages, PDFs and text documents", "icon": "📝",
                     "actions": [{"type": "hud", "text": "Copy a link or a file first, then open Summarise again"}]})
    send({"type": "list", "items": rows})


def ask_ai(task, text, then, context):
    send({"type": "action", "action": {"type": "ai", "prompt": task, "text": text[:SENT],
                                       "then": run_action(then, "Answer", context)}})


def open_item(store, item):
    store.show(item)
    send({"type": "action", "action": {"type": "open", "url": PAGE}})


def source_text(item):
    head = [item.get("title") or ""]
    if item.get("channel"):
        head.append("Channel: %s" % item["channel"])
    return "\n".join(head) + "\n\n" + item.get("text", "")


def fetch(run, store):
    """Reads the source (the input, else the row's, else the copied link), opens the page on it, then asks for its summary;
    a source already summarised only opens."""
    context = run.get("context") or {}
    source = (run.get("input") or context.get("source") or "").strip()
    if not source and context.get("clipboard"):  # the popover's copied text, read as it is pressed
        source = said(started(["pbpaste"]), 0.5) or ""
    source = source or clipboard_link()
    if not source:
        return send({"type": "hud", "text": "Copy a link first, or type summarise and a link"})
    kind = kind_of(source)
    # One item a video, whichever link to it; a document by its path.
    key = "youtube:" + youtube_id(source) if kind == "video" else as_path(source) or source
    item_id = hashlib.sha1(key.encode("utf-8")).hexdigest()[:16]
    item = store.load(item_id)
    if item and item.get("summary") and item.get("words"):
        return open_item(store, item)
    item = {"id": item_id, "source": as_path(source) or source, "kind": kind, "title": short(source) if kind != "text" else "Text",
            "status": "reading", "chat": []}
    store.show(item)
    # The page opens now, so the read shows; its own open action would wait for the read.
    subprocess.run(["open", PAGE], capture_output=True, timeout=5)
    problem = None
    try:
        item.update(read_source(source, kind))
    except Problem as e:
        problem = e
    if not store.load(item_id):  # deleted while it was read: saving now would bring it back
        return send({"type": "hud", "text": "That source is gone"})
    if problem:
        item.update(status="failed", error=str(problem))
        store.save(item)
        return send({"type": "hud", "text": "Summarise: %s" % problem})
    item.update(status="summarising", words=len(item["text"].split()))
    store.save(item)
    ask_ai(SUMMARY_TASK % noun(kind), source_text(item), "summarised", {"id": item_id})


def reply(run, store):
    """An `ai` action's answer: the source it was about, and the AI's text or why there is none."""
    context = run.get("context") or {}
    item = store.load(context.get("id", ""))
    if not item:
        send({"type": "hud", "text": "That source is gone"})
    return item, context.get("error"), (run.get("input") or "").strip()


def summarised(run, store):
    item, error, text = reply(run, store)
    if not item:
        return
    if error:
        item.update(status="failed", error="Pilot's AI: %s" % error)
    else:
        item.update(status="done", summary=text, error=None)
    store.save(item)
    send({"type": "hud", "text": "Summary failed" if error else "Summary ready"})


def ask(run, store):
    question = (run.get("input") or "").strip()
    item = store.current(text=True)
    if not question or not item or not item.get("text"):
        return send({"type": "hud", "text": "Summarise something first, then ask about it"})
    item["chat"] = (item.get("chat") or []) + [{"role": "user", "text": question, "at": time.time()}]
    item["asking"] = True
    store.save(dict((k, v) for k, v in item.items() if k != "text"))
    ask_ai(ASK_TASK, source_text(item) + "\n\nQuestion: " + question, "answered", {"id": item["id"]})


def answered(run, store):
    item, error, text = reply(run, store)
    if not item:
        return
    text = "Pilot's AI could not answer: %s" % error if error else text
    item["chat"] = (item.get("chat") or []) + [{"role": "assistant", "text": text, "at": time.time()}]
    item["asking"] = False
    store.save(item)
    send({"type": "hud", "text": "Answered"})


def markdown(item):
    lines = ["# %s" % item.get("title", "Summary"), ""]
    if item.get("kind") == "doc":
        lines.append("**File:** %s" % item["source"])
    elif item.get("kind") != "text":
        lines.append("**Link:** %s" % item["source"])
    facts = [item[k] for k in ("channel", "length") if item.get(k)]
    if facts:
        lines.append("**%s:** %s" % ("Channel" if item.get("channel") else "Length", " · ".join(facts)))
    lines += ["", "## Summary", "", item.get("summary") or "_No summary yet._", "",
              "## %s" % ("Transcript" if item.get("kind") == "video" else "Text"), "", item.get("text", ""), ""]
    return "\n".join(lines)


def save(run, store):
    item = store.load((run.get("context") or {}).get("id", ""), text=True) or store.current(text=True)
    if not item:
        return send({"type": "hud", "text": "Nothing to save yet"})
    base = re.sub(r'[/:\\\0]', "-", item.get("title") or "Summary").strip(". ")[:120] or "Summary"
    path, n = os.path.join(DOWNLOADS, base + ".md"), 2
    while os.path.exists(path):
        path, n = os.path.join(DOWNLOADS, "%s %d.md" % (base, n)), n + 1
    with open(path, "w", encoding="utf-8") as f:
        f.write(markdown(item))
    send({"type": "hud", "text": "Saved %s to Downloads" % os.path.basename(path)})


def show(run, store):
    item = store.load((run.get("context") or {}).get("id", ""))
    if not item:
        return send({"type": "hud", "text": "That summary is gone"})
    open_item(store, item)


def delete(run, store):
    item = store.load((run.get("context") or {}).get("id", ""))
    if not item:
        return send({"type": "hud", "text": "That summary is gone"})
    store.forget([item["id"]])
    send({"type": "hud", "text": "Summary deleted"})


def clear_failed(run, store):
    failed = [i["id"] for i in store.earlier() if status_of(i) == "failed"]
    store.forget(failed)
    send({"type": "hud", "text": "Cleared %d failed" % len(failed)})


def status_of(item):
    """Its status; a read stopped with its run, or an answer that never came back, counts as failed after STALE, so the
    2 s asks stop."""
    status = item.get("status")
    stale = time.time() - item.get("at", 0) > STALE
    if status in ("reading", "summarising") and stale:
        status, item["error"] = "failed", "it took too long"
    if item.get("asking") and stale:
        item["asking"] = False
    return status


def summary_words(item, status):
    name = noun(item.get("kind"))
    if status == "reading":
        return "_Reading the %s…_" % ("transcript" if name == "video" else name)
    if status == "summarising":
        return "_Pilot's AI is summarising it…_"
    if status == "failed":
        return "Not summarised: %s" % item.get("error", "")
    return item.get("summary") or ""


def bar(run, store):
    """The bar line, 📝 (… while a summary is on its way), from the disk; on a click, its popover: what is copied as a row
    that summarises it, a box to paste a link or text into, and the last summary (Pilot draws Open page under it)."""
    item = store.current()
    status = status_of(item) if item else None
    working = status in ("reading", "summarising")
    if run.get("surface") != "popover":
        return send({"type": "bar", "text": "📝 …" if working else "📝", "blocks": [{"type": "markdown", "text":
                     "Click to summarise what you copied: a link, a file or text."}]})
    copied, path = copied_now()
    rows = []
    if path:
        rows.append(start_row(path, "Summarise %s" % os.path.basename(path), "Copied in Finder", "📄", "finder"))
    elif copied and is_link(copied):
        rows.append(start_row(copied, "Summarise the copied %s" % noun(kind_of(copied)), short(copied), "🔗", "clipboard"))
    elif copied:
        first = copied.split("\n")[0].strip()
        rows.append({"id": "text", "title": "Summarise the copied text", "subtitle": first[:60] + ("…" if len(first) > 60 else ""),
                     "icon": "📋", "actions": [run_action("fetch", "Summarise", {"clipboard": True})]})
    blocks = [{"type": "list", "title": "Copied", "items": rows}] if rows else [
        {"type": "markdown", "text": "Copy a link, a file in Finder or some text, or paste one below."}]
    blocks.append({"type": "input", "placeholder": "Paste a link or text to summarise", "action": run_action("fetch", "Summarise")})
    if item:
        blocks.append({"type": "section", "title": item.get("title") or "Summary", "subtitle": short(item.get("source", "")),
                       "blocks": [{"type": "markdown", "text": summary_words(item, status)}]})
    answer = {"type": "blocks", "blocks": blocks}
    if working:
        answer["refresh"] = 2
    send(answer)


def new_box():
    """The page's box: a link or a file's path pasted, or (a Pilot from 2026-10-31) a document chosen, then Summarise. An
    older Pilot ignores `files` and draws the box with its arrow, and a pasted path still reads."""
    return {"type": "section", "title": "Summarise", "blocks": [
        {"type": "input", "placeholder": "Paste a YouTube link, a web page's link or a file's path",
         "action": run_action("fetch", "Summarise"), "files": PICKED}]}


def page(run, store):
    """The page: a box to summarise something new; the source shown, its summary with Copy, Ask about it, the full text,
    and the earlier ones; disk only, asked again every 2 s while an answer is on its way."""
    item = store.current(text=True)
    if not item:
        blocks = [new_box(), {"type": "markdown", "text":
                  "YouTube videos (from their transcript), web pages, PDFs and text documents. The summary shows here, "
                  "with its full text, Copy, Save as .md and Ask about it."}]
        return send({"type": "blocks", "blocks": blocks + earlier_blocks(store.earlier())})
    name, status = noun(item.get("kind")), status_of(item)
    facts = [{"label": label, "value": str(item[key])} for label, key in (("Channel", "channel"), ("Length", "length"))
             if item.get(key)]
    if item.get("words"):
        facts.append({"label": "Words", "value": "{:,}".format(item["words"])})
    head = [{"type": "stats", "items": facts}] if facts else []
    blocks = [new_box(), {"type": "section", "title": item.get("title") or "Summary", "subtitle": short(item.get("source", "")),
                          "aside": name.capitalize(), "blocks": head}]
    buttons = []
    if status == "done" and item.get("summary"):
        buttons.append({"type": "copy", "text": item["summary"], "title": "Copy summary"})
    if item.get("text"):
        buttons.append(run_action("save", "Save as .md", {"id": item["id"]}, icon="📄"))
    if item.get("kind") != "text":
        buttons.append({"type": "open", "url": item["source"], "title": "Open document" if item.get("kind") == "doc" else "Open link"})
    if status == "failed":
        buttons.append(run_action("fetch", "Try again", {"source": item["source"]}))
    buttons.append(delete_action(item["id"]))
    blocks.append({"type": "buttons", "actions": buttons})
    blocks.append({"type": "section", "title": "Summary · Pilot AI",
                   "blocks": [{"type": "markdown", "text": summary_words(item, status)}]})
    if item.get("text"):
        chat = item.get("chat") or []
        asked = [{"type": "chat", "messages": chat, "working": bool(item.get("asking"))}] if chat else []
        blocks.append({"type": "section", "title": "Ask about it", "blocks": asked + [
            {"type": "input", "placeholder": "Ask about this %s" % name, "action": run_action("ask", "Ask")}]})
        text = item["text"]
        if len(text) > SHOWN:
            text = text[:SHOWN] + "\n\n_The rest is in the .md file: Save as .md._"
        blocks.append({"type": "section", "title": "Transcript" if name == "video" else "Full text",
                       "blocks": [{"type": "markdown", "text": text}]})
    blocks += earlier_blocks(store.earlier(), item["id"])
    answer = {"type": "blocks", "blocks": blocks}
    if status in ("reading", "summarising") or item.get("asking"):
        answer["refresh"] = 2
    send(answer)


def earlier_row(item):
    """A row of Earlier: a click shows it; Delete as an inline button, and in `actions` so ⋯ and an older Pilot reach it."""
    gone = delete_action(item["id"])
    return {"id": item["id"], "title": item.get("title") or short(item.get("source", "")),
            "subtitle": noun(item.get("kind")).capitalize(),
            "actions": [run_action("show", "Show", {"id": item["id"]}), gone], "inline": [dict(gone, icon="xmark")]}


def earlier_blocks(items, shown=None):
    """Clear failed while any source has failed (every kept one, the shown one too), then Earlier without the shown one."""
    blocks = []
    if any(status_of(i) == "failed" for i in items):
        blocks.append({"type": "buttons", "actions": [run_action("clear-failed", "Clear failed", destructive=True)]})
    others = [i for i in items if i["id"] != shown][:10]
    if others:
        blocks.append({"type": "list", "title": "Earlier", "items": [earlier_row(i) for i in others]})
    return blocks


COMMANDS = {"summarise": summarise, "fetch": fetch, "summarised": summarised, "ask": ask, "answered": answered,
            "save": save, "show": show, "delete": delete, "clear-failed": clear_failed, "page": page, "bar": bar}


def main():
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        send({"type": "error", "text": "got a run message it could not read"})
        return
    command = COMMANDS.get(run.get("command"))
    if not command:
        return send({"type": "error", "text": "has no command %s" % run.get("command")})
    try:
        command(run, Store(run))
    except OSError as e:
        send({"type": "error", "text": "could not use its files (%s)" % e.strerror})


if __name__ == "__main__":
    main()
