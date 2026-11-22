"""News's sources and feeds: the built-in list, reading RSS 2.0, RSS 1.0 (RDF) and Atom, and fetching every picked
feed at once through curl, each with its own time and size limit, so one dead feed never holds the rest.

Each built-in URL was asked on 2026-11-22 and answered with a feed; Malta comes first. The Malta
Independent has no feed today; TVM's news is its `ahbarijiet` posts, and its plain feed is a
cached copy days old, so its links ask for them by date. Reddit answers readers without a sign-in with 429 or 404, so Reddit's are listed
but off. Reuters and AP publish no public feed; theirs are Google News searches of their sites.
Python 3.9 stdlib only; nothing here logs a title, a description or a feed's text.
"""
import email.utils
import hashlib
import os
import re
import shutil
import subprocess
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser
from urllib.parse import quote_plus, urlparse

AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Pilot-News/1.0 (RSS reader)"
LARGEST = 5 * 1024 * 1024  # bytes of one feed
FEED_TIME = 12  # seconds one feed may take
DESCRIBED = 300  # characters of an item's description kept

GOOGLE = "https://news.google.com/rss/search?q=%s&hl=en-GB&gl=GB&ceid=GB:en"


def google(words):
    return GOOGLE % quote_plus(words)


# (group, id, title, url), in Settings' order. Each is a checkbox in Settings, source-<id>, whose default in
# extension.json says whether it starts ticked (one list of defaults: test_news checks the two match).
BUILT_IN = [
    ("Malta", "times-of-malta", "Times of Malta", "https://timesofmalta.com/rss"),
    ("Malta", "maltatoday", "MaltaToday", "https://www.maltatoday.com.mt/rss/news/"),
    ("Malta", "newsbook-en", "Newsbook (English)", "https://newsbook.com.mt/en/feed/"),
    ("Malta", "newsbook", "Newsbook (Malti)", "https://newsbook.com.mt/feed/"),
    ("Malta", "lovin-malta", "Lovin Malta", "https://lovinmalta.com/feed/"),
    ("Malta", "tvm-en", "TVM News (English)", "https://tvmnews.mt/en/feed/?post_type=ahbarijiet&orderby=date&order=DESC"),
    ("Malta", "tvm", "TVM Aħbarijiet (Malti)", "https://tvmnews.mt/feed/?post_type=ahbarijiet&orderby=date&order=DESC"),
    ("Malta", "the-shift", "The Shift", "https://theshiftnews.com/feed/"),
    ("Malta", "one-news", "ONE News (Malti)", "https://one.com.mt/feed/"),
    ("Malta", "gozo-news", "Gozo News", "https://gozo.news/feed/"),
    ("Malta", "maltatoday-business", "MaltaToday Business", "https://www.maltatoday.com.mt/rss/business/"),
    ("Malta", "google-malta", "Google News: Malta", google("Malta when:1d")),
    ("World", "bbc-world", "BBC World", "https://feeds.bbci.co.uk/news/world/rss.xml"),
    ("World", "bbc-top", "BBC Top stories", "https://feeds.bbci.co.uk/news/rss.xml"),
    ("World", "guardian-world", "The Guardian World", "https://www.theguardian.com/world/rss"),
    ("World", "al-jazeera", "Al Jazeera", "https://www.aljazeera.com/xml/rss/all.xml"),
    ("World", "npr", "NPR News", "https://feeds.npr.org/1001/rss.xml"),
    ("World", "reuters", "Reuters (through Google News)", google("site:reuters.com when:1d")),
    ("World", "ap", "AP (through Google News)", google("site:apnews.com when:1d")),
    ("World", "google-world", "Google News: World",
     "https://news.google.com/rss/headlines/section/topic/WORLD?hl=en-GB&gl=GB&ceid=GB:en"),
    ("Tech", "hacker-news", "Hacker News", "https://news.ycombinator.com/rss"),
    ("Tech", "ars-technica", "Ars Technica", "https://feeds.arstechnica.com/arstechnica/index"),
    ("Tech", "the-verge", "The Verge", "https://www.theverge.com/rss/index.xml"),
    ("Tech", "techcrunch", "TechCrunch", "https://techcrunch.com/feed/"),
    ("Tech", "bbc-tech", "BBC Technology", "https://feeds.bbci.co.uk/news/technology/rss.xml"),
    ("Tech", "google-tech", "Google News: Technology",
     "https://news.google.com/rss/headlines/section/topic/TECHNOLOGY?hl=en-GB&gl=GB&ceid=GB:en"),
    ("Business", "google-business", "Google News: Business",
     "https://news.google.com/rss/headlines/section/topic/BUSINESS?hl=en-GB&gl=GB&ceid=GB:en"),
    ("Reddit", "r-malta", "r/malta", "https://www.reddit.com/r/malta/.rss"),
    ("Reddit", "r-worldnews", "r/worldnews", "https://www.reddit.com/r/worldnews/.rss"),
    ("Reddit", "r-technology", "r/technology", "https://www.reddit.com/r/technology/.rss"),
]


def built_in():
    return [{"id": i, "group": g, "title": t, "url": u} for g, i, t, u in BUILT_IN]


def is_feed_url(text):
    url = urlparse(text)
    return url.scheme in ("http", "https") and bool(url.hostname) and not re.search(r"\s", text)


def custom_id(url):
    return "my-" + hashlib.sha1(url.encode("utf-8")).hexdigest()[:10]


# MARK: Reading a feed

class _Text(HTMLParser):
    """An HTML fragment's words, its tags dropped; script and style left out."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts, self.skip = [], 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self.skip += 1
        elif tag in ("p", "br", "div", "li"):
            self.parts.append(" ")

    def handle_endtag(self, tag):
        if tag in ("script", "style") and self.skip:
            self.skip -= 1

    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)


def plain(fragment, limit=None):
    """A description's words: HTML tags and entities resolved, whitespace collapsed, cut at `limit` with an ellipsis."""
    if not fragment:
        return ""
    reader = _Text()
    try:
        reader.feed(fragment)
        reader.close()
        text = "".join(reader.parts)
    except Exception:  # HTMLParser raises little, but a feed is outside input
        text = re.sub(r"<[^>]+>", " ", fragment)
    text = re.sub(r"\s+", " ", text).strip()
    if limit and len(text) > limit:
        text = text[:limit].rsplit(" ", 1)[0].rstrip(",;:.") + "…"
    return text


ISO = re.compile(r"(\d{4})-(\d\d)-(\d\d)(?:[T ](\d\d):(\d\d)(?::(\d\d)(?:\.\d+)?)?)?\s*(Z|[+-]\d\d:?\d\d)?$", re.I)


def when(text):
    """Seconds since 1970 of an RFC 822 date (RSS) or an ISO 8601 one (Atom, dc:date), or None. 3.9's fromisoformat
    takes no `Z`, so ISO is read by hand; a time with no zone counts as UTC."""
    text = (text or "").strip()
    if not text:
        return None
    m = ISO.match(text)
    if m:
        y, mo, d, h, mi, s, zone = m.groups()
        try:
            at = datetime(int(y), int(mo), int(d), int(h or 0), int(mi or 0), int(s or 0), tzinfo=timezone.utc)
        except ValueError:
            return None
        if zone and zone.upper() != "Z":
            sign = 1 if zone[0] == "+" else -1
            digits = zone[1:].replace(":", "")
            at -= sign * timedelta(hours=int(digits[:2]), minutes=int(digits[2:]))
        return at.timestamp()
    try:
        at = email.utils.parsedate_to_datetime(text)
    except (TypeError, ValueError, IndexError):
        return None
    if at is None:
        return None
    if at.tzinfo is None:
        at = at.replace(tzinfo=timezone.utc)
    return at.timestamp()


def _local(tag):
    return tag.rsplit("}", 1)[-1] if isinstance(tag, str) else ""


def _child(node, name):
    """`name` in any namespace or none (ElementTree's {*}, Python 3.8 and later)."""
    return node.find("{*}" + name)


def _text(node, *names):
    for name in names:
        child = _child(node, name)
        if child is not None and (child.text or "").strip():
            return child.text.strip()
    return ""


def _atom_link(entry):
    best = ""
    for child in entry.findall("{*}link"):
        rel, href = child.get("rel", "alternate"), (child.get("href") or "").strip()
        if href and rel == "alternate":
            return href
        best = best or href
    return best


class FeedProblem(Exception):
    """Why a feed's answer could not be read, in words for the page."""


def parse(body):
    """A feed's items as [{"title", "link", "at" (or None), "text", "via"}]; see `read`."""
    return read(body)[1]


def read(body):
    """(the feed's own title, its items), from RSS 2.0, RSS 1.0 or Atom; raises FeedProblem when it is none of them. A
    feed declaring entities is refused (no entity expansion from outside input)."""
    if not body or not body.strip():
        raise FeedProblem("sent an empty answer")
    if b"<!ENTITY" in body:
        raise FeedProblem("declares XML entities, so it is not read")
    try:
        root = ET.fromstring(body)
    except ET.ParseError:
        raise FeedProblem("did not read as RSS or Atom")
    kind = _local(root.tag)
    channel = _child(root, "channel")  # RSS 2.0's (items inside it) and RSS 1.0's (items beside it)
    if kind == "feed":
        nodes, atom = root.findall("{*}entry"), True
    elif kind == "rss":
        nodes, atom = (channel.findall("{*}item") if channel is not None else []), False
    elif kind == "RDF":
        nodes, atom = root.findall("{*}item"), False
    else:
        raise FeedProblem("is not an RSS or Atom feed")
    items = []
    for node in nodes:
        title = plain(_text(node, "title"))
        link = _atom_link(node) if atom else (_text(node, "link") or _guid_link(node))
        if not title or not is_feed_url(link):
            continue
        at = when(_text(node, "published", "updated", "issued") if atom else _text(node, "pubDate", "date", "updated"))
        text = _text(node, "summary", "content") if atom else _text(node, "description", "encoded", "summary")
        source = _child(node, "source")
        via = (source.text or "").strip() if source is not None and not atom else ""
        items.append({"title": title, "link": link, "at": at, "text": plain(text, DESCRIBED), "via": via})
    return plain(_text(channel if channel is not None else root, "title")), items


def _guid_link(node):
    guid = _child(node, "guid")
    if guid is not None and guid.get("isPermaLink", "true") != "false":
        return (guid.text or "").strip()
    return ""


# MARK: Fetching

def fetch_all(sources, folder, deadline):
    """Fetches every source's feed into `folder` at once; {id: (body bytes or None, why or None)}. Each curl has its own
    FEED_TIME and LARGEST; past `deadline` (time.monotonic) the ones still running are stopped."""
    os.makedirs(folder, exist_ok=True)
    curl = shutil.which("curl") or "/usr/bin/curl"
    running, answers = {}, {}
    for source in sources:
        out = os.path.join(folder, source["id"] + ".part")
        try:
            running[source["id"]] = (subprocess.Popen(
                [curl, "-sS", "-L", "--compressed", "--max-time", str(FEED_TIME), "--max-filesize", str(LARGEST),
                 "-A", AGENT, "-o", out, "-w", "%{http_code}", source["url"]],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE), out)
        except OSError:
            answers[source["id"]] = (None, "could not start curl")
    for source_id, (process, out) in running.items():
        try:
            code, err = process.communicate(timeout=max(0.1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
            answers[source_id] = (None, "took too long")
            discard(out)
            continue
        status = code.decode("ascii", "replace").strip()
        if process.returncode != 0:
            said = err.decode("utf-8", "replace").strip().splitlines()
            answers[source_id] = (None, (said[-1] if said else "did not answer").replace("curl: ", "")[:120])
        elif status and not status.startswith("2"):
            answers[source_id] = (None, "answered %s" % status)
        else:
            try:
                with open(out, "rb") as f:
                    answers[source_id] = (f.read(LARGEST), None)
            except OSError:
                answers[source_id] = (None, "sent nothing")
        discard(out)
    return answers


def discard(path):
    try:
        os.remove(path)
    except OSError:
        pass


# MARK: Items

def item_id(link):
    return hashlib.sha1(link.encode("utf-8")).hexdigest()[:12]


GOOGLE_TAIL = re.compile(r"\s+[-–—]\s+[^-–—]{2,60}$")


def tidy(source, raw, seen, now):
    """A feed item as kept: its id, source, title (a Google News title's " - Publisher" taken off, the publisher kept as
    `via`), link, time (an undated one keeps the time it was first seen) and description."""
    title = raw["title"]
    via = raw.get("via") or ""
    through_google = "news.google.com" in source["url"]
    named = re.search(r"\s+[-–—]\s+%s$" % re.escape(via), title) if via else None
    if named:  # the publisher its <source> names, repeated at the headline's end
        title = title[:named.start()]
    elif through_google:  # no <source>: Google's " - Publisher" read from the headline
        tail = GOOGLE_TAIL.search(title)
        if tail:
            via, title = tail.group(0).strip(" -–—"), title[:tail.start()]
    iid = item_id(raw["link"])
    at = raw.get("at") or seen.get(iid) or now
    text = raw.get("text") or ""
    if text.lower().startswith(title.lower()[:40]) and len(text) <= len(title) + 40:
        text = ""  # a description that only repeats the headline
    return {"id": iid, "source": source["id"], "title": title, "link": raw["link"], "at": min(at, now), "text": text,
            "via": via, "google": through_google}


def same_story(title):
    return re.sub(r"[\W_]+", " ", title.lower()).strip()


def merged(items):
    """Newest first, one item per link and per headline: a story two sources carry keeps its first, a source of its own
    before a Google News copy."""
    ordered = sorted(items, key=lambda i: (bool(i.get("google")), -i["at"]))
    kept, links, titles = [], set(), set()
    for item in ordered:
        key = same_story(item["title"])
        if item["link"] in links or key in titles:
            continue
        links.add(item["link"])
        titles.add(key)
        kept.append(item)
    kept.sort(key=lambda i: -i["at"])
    return kept
