"""News's 24-hour summary as one self-contained HTML file laid out as a newspaper's front page: a masthead with the
date, the lead story, sections in ruled columns, In brief, and every article the summary read, each linked.

The AI's answer is read as a small JSON layout naming items by number, so every link and every source's name comes
from the feeds, never from the AI; an answer that does not read as one still makes a paper, its text as the lead and
the sections by source. Every text is escaped and only http(s) links are drawn. No web font, no script from
elsewhere: serif faces every Mac has. Light paper by default, dark with the system's dark mode, a #dark or #light at
the end of its address picks one, and the masthead's button switches.
"""
import html
import json
import re
import time
from urllib.parse import urlparse

TASK = (
    "These are the news headlines from the last 24 hours, numbered [n], each with its source, time and a short "
    "description. Edit them into a newspaper front page and answer with JSON only, no fence and no words around it, "
    "in this shape: "
    '{"lead": {"headline": "...", "summary": "two or three sentences", "items": [n, ...]}, '
    '"sections": [{"title": "...", "stories": [{"headline": "...", "summary": "one or two sentences", "items": [n, ...]}]}], '
    '"brief": [{"text": "one line", "items": [n]}]}. '
    "The lead is the day's most important story. Make 3 to 6 sections by place or topic (Malta first when there is "
    "Maltese news), 2 to 6 stories each; merge items about the same story into one story listing all their numbers. "
    "Put 4 to 10 smaller items in brief. Use only what the items say: no facts from elsewhere. Headlines at most 12 "
    "words. Write everything in %s, translating headlines in other languages. Every number must be one of the items'.")
LANGUAGES = {"english": "English", "maltese": "Maltese (Malti)"}


def task(language):
    return TASK % LANGUAGES.get(language, "English")


def numbered(items, titles):
    """The text the AI reads: each item as `[n] Source · HH:MM` over its headline and description."""
    lines = []
    for n, item in enumerate(items, 1):
        source = titles.get(item["source"], item["source"]) + (" via " + item["via"] if item.get("via") else "")
        lines.append("[%d] %s · %s\n%s" % (n, source, time.strftime("%a %H:%M", time.localtime(item["at"])), item["title"]))
        if item.get("text"):
            lines.append(item["text"])
        lines.append("")
    return "\n".join(lines)


# MARK: Reading the AI's answer

def _numbers(value, count):
    if not isinstance(value, list):
        return []
    seen = []
    for n in value:
        if isinstance(n, str) and n.strip().lstrip("[").rstrip("]").isdigit():
            n = int(n.strip().lstrip("[").rstrip("]"))
        if isinstance(n, int) and not isinstance(n, bool) and 1 <= n <= count and n not in seen:
            seen.append(n)
    return seen


def _words(value, limit):
    return re.sub(r"\s+", " ", value).strip()[:limit] if isinstance(value, str) else ""


def _story(raw, count):
    if not isinstance(raw, dict):
        return None
    story = {"headline": _words(raw.get("headline"), 200), "summary": _words(raw.get("summary"), 1200),
             "items": _numbers(raw.get("items"), count)}
    return story if story["headline"] else None


def layout(answer, count):
    """The AI's answer as {"lead", "sections", "brief"}, each story with its item numbers checked against `count`; None
    when it holds no JSON object with a lead or a section."""
    text = (answer or "").strip()
    text = re.sub(r"^```(?:json)?\s*|\s*```$", "", text)
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        raw = json.loads(text[start:end + 1])
    except ValueError:
        return None
    if not isinstance(raw, dict):
        return None
    sections = []
    for section in raw.get("sections") if isinstance(raw.get("sections"), list) else []:
        if not isinstance(section, dict):
            continue
        stories = [s for s in (_story(r, count) for r in (section.get("stories") or [])
                               if isinstance(section.get("stories"), list)) if s]
        if stories:
            sections.append({"title": _words(section.get("title"), 60) or "News", "stories": stories[:8]})
    brief = []
    for line in raw.get("brief") if isinstance(raw.get("brief"), list) else []:
        if isinstance(line, dict) and _words(line.get("text"), 300):
            brief.append({"text": _words(line["text"], 300), "items": _numbers(line.get("items"), count)})
        elif isinstance(line, str) and line.strip():
            brief.append({"text": _words(line, 300), "items": []})
    lead = _story(raw.get("lead"), count)
    if not lead and not sections:
        return None
    if not lead:
        lead = sections[0]["stories"].pop(0)
        sections = [s for s in sections if s["stories"]]
    return {"lead": lead, "sections": sections[:8], "brief": brief[:12]}


def fallback(answer, items, titles, groups):
    """A paper with no layout from the AI: its words (when any) as the lead's text, the newest item as the lead, the rest
    by group and source."""
    words = re.sub(r"^```\w*\s*|\s*```$", "", (answer or "").strip())
    lead = {"headline": items[0]["title"], "summary": "", "items": [1], "notes": words}
    by_group = {}
    for n, item in enumerate(items[1:], 2):
        by_group.setdefault(groups.get(item["source"], "News"), []).append(
            {"headline": item["title"], "summary": item.get("text", ""), "items": [n]})
    sections = [{"title": g, "stories": stories[:6]} for g, stories in by_group.items()]
    return {"lead": lead, "sections": sections, "brief": []}


# MARK: Drawing

def _e(text):
    return html.escape(text or "", quote=True)


def _href(link):
    url = urlparse(link or "")
    return _e(link) if url.scheme in ("http", "https") and url.netloc else None


def _source_links(numbers, items, titles):
    links = []
    for n in numbers:
        item = items[n - 1]
        href = _href(item["link"])
        name = _e(titles.get(item["source"], item["source"]))
        if href:
            links.append('<a href="%s" title="%s">%s</a>' % (href, _e(item["title"]), name))
    return '<p class="read">%s</p>' % " · ".join(links) if links else ""


def _headline(story, items, tag):
    first = story["items"][0] if story["items"] else None
    href = _href(items[first - 1]["link"]) if first else None
    words = _e(story["headline"])
    return "<%s>%s</%s>" % (tag, '<a href="%s">%s</a>' % (href, words) if href else words, tag)


def _paragraphs(text):
    """The AI's own words for a fallback lead: lines as paragraphs, Markdown bullets as a list, ** dropped."""
    out, bullets = [], []
    for line in text.splitlines():
        line = re.sub(r"\*\*|__|^#+\s*", "", line.strip())
        if re.match(r"^[-*•]\s+", line):
            bullets.append("<li>%s</li>" % _e(re.sub(r"^[-*•]\s+", "", line)))
            continue
        if bullets:
            out.append("<ul>%s</ul>" % "".join(bullets))
            bullets = []
        if line:
            out.append("<p>%s</p>" % _e(line))
    if bullets:
        out.append("<ul>%s</ul>" % "".join(bullets))
    return "".join(out)


STYLE = """
:root{--paper:#f4efe4;--ink:#1d1a16;--muted:#6b6357;--rule:#2a251f;--hair:#c9bfae;--link:#1d1a16;--accent:#8a1c1c;
--shade:rgba(60,40,10,.06)}
html.dark{--paper:#16140f;--ink:#ece5d6;--muted:#a59b89;--rule:#d8cfbd;--hair:#4a4236;--link:#ece5d6;--accent:#e0796b;
--shade:rgba(255,240,210,.04)}
@media (prefers-color-scheme:dark){html:not(.light){--paper:#16140f;--ink:#ece5d6;--muted:#a59b89;--rule:#d8cfbd;
--hair:#4a4236;--link:#ece5d6;--accent:#e0796b;--shade:rgba(255,240,210,.04)}}
*{box-sizing:border-box}
html{background:var(--paper)}
body{margin:0 auto;max-width:1240px;padding:28px 40px 60px;color:var(--ink);background:var(--paper);
font:17px/1.5 "Iowan Old Style","Charter","Georgia","Times New Roman",serif;
background-image:radial-gradient(var(--shade) 1px,transparent 1px);background-size:3px 3px}
a{color:var(--link);text-decoration:none}
a:hover{text-decoration:underline;text-decoration-thickness:1px;text-underline-offset:3px}
.ears{display:flex;justify-content:space-between;align-items:center;font:600 12px/1.2 "Georgia",serif;
letter-spacing:.14em;text-transform:uppercase;color:var(--muted)}
.ears button{font:inherit;letter-spacing:inherit;text-transform:inherit;color:var(--muted);background:none;
border:1px solid var(--hair);border-radius:2px;padding:4px 8px;cursor:pointer}
.mast{text-align:center;margin:6px 0 0;font:400 92px/1 "Didot","Bodoni 72","Bodoni 72 Oldstyle","Playfair Display",
"Times New Roman",serif;letter-spacing:-.01em}
.mast small{display:block;font:italic 17px/1.6 "Iowan Old Style","Georgia",serif;letter-spacing:.02em;color:var(--muted);
margin-top:6px}
.dateline{display:flex;justify-content:space-between;gap:16px;margin:14px 0 22px;padding:7px 0;
border-top:3px double var(--rule);border-bottom:1px solid var(--rule);font:600 13px/1.3 "Georgia",serif;
letter-spacing:.08em;text-transform:uppercase}
.front{display:grid;grid-template-columns:minmax(0,2.1fr) minmax(0,1fr);gap:0 34px}
.lead{padding-right:34px;border-right:1px solid var(--hair)}
.kicker{font:700 12px/1 "Georgia",serif;letter-spacing:.18em;text-transform:uppercase;color:var(--accent);margin:0 0 10px}
.lead h1{font:700 48px/1.06 "Bodoni 72","Didot","Times New Roman",serif;margin:0 0 14px;letter-spacing:-.01em}
.lead .standfirst{font:italic 21px/1.45 "Iowan Old Style","Georgia",serif;margin:0 0 12px}
.lead .body{columns:2;column-gap:28px;column-rule:1px solid var(--hair)}
.lead .body p:first-child::first-letter{float:left;font:700 58px/.8 "Bodoni 72","Didot",serif;padding:6px 8px 0 0}
.read{font:13px/1.4 "Georgia",serif;color:var(--muted);margin:6px 0 0}
.read a{color:var(--muted);border-bottom:1px dotted var(--hair)}
aside.brief h2,section h2{font:700 13px/1 "Georgia",serif;letter-spacing:.2em;text-transform:uppercase;margin:0 0 12px;
padding:0 0 7px;border-bottom:2px solid var(--rule)}
aside.brief ol{list-style:none;margin:0;padding:0}
aside.brief li{padding:9px 0;border-bottom:1px solid var(--hair);font-size:15.5px;line-height:1.4}
aside.brief li:last-child{border-bottom:0}
section{margin:34px 0 0}
section .cols{columns:3 250px;column-gap:30px;column-rule:1px solid var(--hair)}
article{break-inside:avoid;margin:0 0 18px;padding-bottom:16px;border-bottom:1px solid var(--hair)}
article h3{font:700 22px/1.18 "Bodoni 72","Didot","Times New Roman",serif;margin:0 0 6px}
article p{margin:0;font-size:16px}
.index{margin-top:44px;border-top:3px double var(--rule);padding-top:14px}
.index .cols{columns:4 220px;column-gap:26px;column-rule:1px solid var(--hair);font-size:13.5px;line-height:1.35}
.index h4{font:700 12px/1.2 "Georgia",serif;letter-spacing:.14em;text-transform:uppercase;margin:0 0 6px;break-after:avoid}
.index ul{list-style:none;margin:0 0 16px;padding:0;break-inside:avoid-column}
.index li{margin:0 0 6px}
.index time{color:var(--muted);font-variant-numeric:tabular-nums;margin-right:6px}
footer{margin-top:30px;padding-top:10px;border-top:1px solid var(--rule);font:12px/1.5 "Georgia",serif;color:var(--muted);
text-align:center;letter-spacing:.04em}
@media (max-width:860px){.front{grid-template-columns:1fr}.lead{border-right:0;padding-right:0}.lead .body{columns:1}
.mast{font-size:58px}body{padding:18px}}
@media print{.ears button{display:none}body{background:none}}
"""

SCRIPT = """(function(){var r=document.documentElement,h=location.hash;
if(h==='#dark'){r.classList.add('dark')}else if(h==='#light'){r.classList.add('light')}
var b=document.getElementById('look');if(!b)return;b.onclick=function(){
var dark=r.classList.contains('dark')||(!r.classList.contains('light')&&matchMedia('(prefers-color-scheme: dark)').matches);
r.classList.toggle('dark',!dark);r.classList.toggle('light',dark)}})();"""


def page(paper, items, titles, meta):
    """The whole file. `paper` is a layout; `meta` has `day` (a time), `seconds`, `by`, `sources` (titles) and `count`."""
    day = time.localtime(meta["day"])
    date = time.strftime("%A %-d %B %Y", day)
    lead = paper["lead"]
    body = _paragraphs(lead["notes"]) if lead.get("notes") else ""
    lead_html = ('<div class="lead"><p class="kicker">The lead</p>%s%s%s%s</div>' % (
        _headline(lead, items, "h1"),
        '<p class="standfirst">%s</p>' % _e(lead["summary"]) if lead.get("summary") else "",
        '<div class="body">%s</div>' % body if body else "",
        _source_links(lead["items"], items, titles)))
    brief = ""
    if paper["brief"]:
        lines = []
        for line in paper["brief"]:
            first = line["items"][0] if line["items"] else None
            href = _href(items[first - 1]["link"]) if first else None
            words = _e(line["text"])
            lines.append("<li>%s</li>" % ('<a href="%s">%s</a>' % (href, words) if href else words))
        brief = '<aside class="brief"><h2>In brief</h2><ol>%s</ol></aside>' % "".join(lines)
    else:
        brief = '<aside class="brief"><h2>In brief</h2><ol>%s</ol></aside>' % "".join(
            '<li><a href="%s">%s</a></li>' % (_href(i["link"]) or "#", _e(i["title"])) for i in items[1:9])
    sections = []
    for section in paper["sections"]:
        stories = "".join('<article>%s%s%s</article>' % (
            _headline(s, items, "h3"), "<p>%s</p>" % _e(s["summary"]) if s.get("summary") else "",
            _source_links(s["items"], items, titles)) for s in section["stories"])
        sections.append('<section><h2>%s</h2><div class="cols">%s</div></section>' % (_e(section["title"]), stories))
    by_source = {}
    for item in items:
        by_source.setdefault(item["source"], []).append(item)
    index = "".join('<h4>%s</h4><ul>%s</ul>' % (_e(titles.get(sid, sid)), "".join(
        '<li><time>%s</time><a href="%s">%s</a></li>' % (time.strftime("%H:%M", time.localtime(i["at"])),
                                                         _href(i["link"]) or "#", _e(i["title"])) for i in group))
        for sid, group in by_source.items())
    who = meta.get("by") or "Pilot's AI"
    took = "%d s" % round(meta["seconds"]) if meta.get("seconds") is not None else "—"
    return """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark"><title>Pilot News · %(date)s</title><style>%(style)s</style></head>
<body>
<div class="ears"><span>The last 24 hours</span><span>%(count)d stories · %(nsources)d sources</span>
<button id="look" type="button">Light / dark</button></div>
<h1 class="mast">Pilot News<small>%(sources)s</small></h1>
<div class="dateline"><span>%(date)s</span><span>Edited by %(who)s in %(took)s</span></div>
<div class="front">%(lead)s%(brief)s</div>
%(sections)s
<div class="index"><section><h2>Every article read</h2><div class="cols">%(index)s</div></section></div>
<footer>Made by Pilot News at %(made)s from the headlines and short descriptions of %(count)d articles. Summaries are an
AI's reading: check the article before you rely on one.</footer>
<script>%(script)s</script>
</body></html>
""" % {"date": _e(date), "style": STYLE, "count": len(items), "nsources": len(by_source), "who": _e(who), "took": took,
       "sources": _e(" · ".join(meta.get("sources") or [])), "lead": lead_html, "brief": brief,
       "sections": "\n".join(sections), "index": index, "made": time.strftime("%H:%M", day), "script": SCRIPT}
