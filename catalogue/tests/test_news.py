import fcntl
import json
import sys
import time
import unittest
from email.utils import formatdate

from harness import EXTENSIONS, ExtensionTestCase

sys.path.insert(0, str(EXTENSIONS / "news"))
import feeds  # noqa: E402
import paper  # noqa: E402

NOW = time.time()


def rfc(hours_ago):
    return formatdate(NOW - hours_ago * 3600)


def iso(hours_ago):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW - hours_ago * 3600))


# A Times of Malta-like RSS 2.0 feed: one item 30 hours old (outside a summary's day), one with a hostile title.

def rss_feed():
    return """<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>Times of Malta</title>
<item><title>Parliament approves the budget</title><link>https://timesofmalta.com/a/budget</link>
<pubDate>%s</pubDate><description><![CDATA[<p>The House voted <b>36 to 29</b> late on Saturday &amp; adjourned.</p>]]></description></item>
<item><title>Ferry service to Gozo resumes</title><link>https://timesofmalta.com/a/ferry</link><pubDate>%s</pubDate>
<description>Fast ferries ran again after the storm.</description></item>
<item><title>Old story from yesterday</title><link>https://timesofmalta.com/a/old</link><pubDate>%s</pubDate></item>
<item><title>&lt;script&gt;alert(1)&lt;/script&gt; Valletta</title><link>https://timesofmalta.com/a/x</link><pubDate>%s</pubDate></item>
<item><title>No link here</title><link>javascript:alert(1)</link><pubDate>%s</pubDate></item>
</channel></rss>""" % (rfc(1), rfc(3), rfc(30), rfc(5), rfc(2))

# A Verge-like Atom feed: ISO times with Z and an offset, the alternate link among others.

def atom_feed():
    return """<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"><title>The Verge</title>
<entry><title type="html">A new Mac mini</title><link rel="replies" href="https://www.theverge.com/x/comments"/>
<link rel="alternate" href="https://www.theverge.com/x"/><published>%s</published>
<summary type="html">&lt;p&gt;Apple's smallest desktop gets faster.&lt;/p&gt;</summary></entry>
<entry><title>Chips everywhere</title><link href="https://www.theverge.com/y"/><updated>%s</updated></entry>
</feed>""" % (iso(2), time.strftime("%Y-%m-%dT%H:%M:%S+01:00", time.gmtime(NOW - 4 * 3600 + 3600)))

# TVM's Maltese feed: non-ASCII titles and descriptions, as it sends them.

def malti_feed():
    return """<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel><title>TVMnews.mt</title><description>L-Aħbarijiet ta&#039; TVM</description>
<item><title>Is-settur marittimu ġġenera kważi €1,000 miljun</title><link>https://tvmnews.mt/news/marittimu/</link>
<pubDate>%s</pubDate><description>Il-Ministru qal li ż-żieda fl-għadd ta’ vapuri hija sinjal tajjeb.</description></item>
<item><title>Direttur ta&#8217; kumpanija mmultat €1,800</title><link>https://tvmnews.mt/news/multa/</link>
<pubDate>%s</pubDate></item>
</channel></rss>""" % (rfc(0.5), rfc(6))

BROKEN = "<html><body>Our feed has moved</body></html>"
CUT = "<?xml version='1.0'?><rss><channel><item><title>Half"

PICKS = {"picked": {"times-of-malta": True, "maltatoday": False, "newsbook-en": False, "lovin-malta": True,
                    "tvm-en": False, "tvm": True, "bbc-world": False, "hacker-news": False, "the-verge": True}}
ROUTES = {"timesofmalta.com": ("rss.xml", 0), "theverge.com": ("atom.xml", 0), "tvmnews.mt": ("malti.xml", 0),
          "lovinmalta.com": ("broken.html", 0), "example.org/feed": ("rss.xml", 0)}

FAKE_CURL = r'''
import json, sys
args = sys.argv[1:]
out = args[args.index("-o") + 1]
url = args[-1]
with open(LOG, "a") as f:
    f.write("curl " + url + "\n")
routes = json.load(open(ROUTES))
for key, (name, delay) in routes.items():
    if key in url:
        if delay:
            import time; time.sleep(delay)
        open(out, "wb").write(open(FIXTURES + "/" + name, "rb").read())
        sys.stdout.write("200")
        sys.exit(0)
sys.stderr.write("curl: (6) Could not resolve host\n")
sys.exit(6)
'''


class NewsTests(ExtensionTestCase):
    EXTENSION = "news"

    def setUp(self):
        global NOW
        NOW = time.time()  # the fixtures' times are from now, however long the suite ran before
        super().setUp()
        self.addCleanup(self.settle)
        fixtures = self.box.root / "fixtures"
        fixtures.mkdir()
        for name, body in (("rss.xml", rss_feed()), ("atom.xml", atom_feed()), ("malti.xml", malti_feed()), ("broken.html", BROKEN),
                           ("cut.xml", CUT)):
            (fixtures / name).write_text(body, encoding="utf-8")
        self.routes(ROUTES)
        script = self.box.root / "fakecurl.py"
        script.write_text("LOG = %r\nROUTES = %r\nFIXTURES = %r\n" % (str(self.box.log), str(self.box.root / "routes.json"),
                                                                     str(fixtures)) + FAKE_CURL)
        self.box.shim("curl", 'exec /usr/bin/python3 "%s" "$@"' % script)
        self.pick(PICKS)

    def routes(self, routes):
        (self.box.root / "routes.json").write_text(json.dumps(routes))

    def pick(self, picks):
        (self.box.data / "sources.json").write_text(json.dumps(picks))

    def settle(self):
        lock = self.box.cache / "refresh.lock"
        if lock.exists():
            with open(str(lock), "a") as f:
                fcntl.flock(f, fcntl.LOCK_EX)

    def fetched(self):
        """Fills the cache as a view's refresh does, and waits for it."""
        self.run_ext("refresh")
        self.settle()

    def read(self, path):
        with open(path, encoding="utf-8") as f:
            return f.read()

    def summary(self):
        return json.loads((self.box.data / "summary.json").read_text())

    def press(self, **kwargs):
        result = self.run_ext("summarise", **kwargs)
        ai = [a for a in result.actions if a["type"] == "ai"]
        return result, ai[0] if ai else None

    def answer(self, ai, input=None, **context):
        then = ai["then"]
        self.assertEqual(then["command"], "summarised")
        return self.run_ext("summarised", context=dict(then["context"], **context), input=input,
                            preferences={"folder": str(self.box.root / "out")})

    # ---- reading feeds ----

    def test_rss_atom_and_maltese_feeds_read_with_their_times_and_text(self):
        rss = feeds.parse(rss_feed().encode())
        self.assertEqual([i["title"] for i in rss][:2], ["Parliament approves the budget", "Ferry service to Gozo resumes"])
        self.assertEqual(rss[0]["text"], "The House voted 36 to 29 late on Saturday & adjourned.")
        self.assertAlmostEqual(rss[0]["at"], NOW - 3600, delta=2)
        self.assertNotIn("No link here", [i["title"] for i in rss], "a javascript: link is no article")
        atom = feeds.parse(atom_feed().encode())
        self.assertEqual([(i["title"], i["link"]) for i in atom],
                         [("A new Mac mini", "https://www.theverge.com/x"), ("Chips everywhere", "https://www.theverge.com/y")])
        self.assertAlmostEqual(atom[0]["at"], NOW - 2 * 3600, delta=2)
        self.assertAlmostEqual(atom[1]["at"], NOW - 4 * 3600, delta=2, msg="an offset is read, not dropped")
        self.assertEqual(atom[0]["text"], "Apple's smallest desktop gets faster.")
        malti = feeds.parse(malti_feed().encode())
        self.assertEqual(malti[0]["title"], "Is-settur marittimu ġġenera kważi €1,000 miljun")
        self.assertEqual(malti[1]["title"], "Direttur ta’ kumpanija mmultat €1,800")
        self.assertEqual(feeds.feed_title(malti_feed().encode()), "TVMnews.mt")

    def test_a_broken_feed_says_why_and_an_entity_bomb_is_refused(self):
        for body, words in ((BROKEN, "is not an RSS or Atom feed"), (CUT, "did not read as RSS or Atom"), ("", "empty")):
            with self.assertRaises(feeds.FeedProblem) as raised:
                feeds.parse(body.encode())
            self.assertIn(words, str(raised.exception))
        bomb = '<?xml version="1.0"?><!DOCTYPE r [<!ENTITY a "aaaa"><!ENTITY b "&a;&a;">]><rss><channel/></rss>'
        with self.assertRaises(feeds.FeedProblem):
            feeds.parse(bomb.encode())

    def test_dates_read_on_python_3_9(self):
        self.assertEqual(feeds.when("2026-11-22T10:00:00Z"), feeds.when("Sun, 22 Nov 2026 10:00:00 +0000"))
        self.assertEqual(feeds.when("2026-11-22T11:00:00+01:00"), feeds.when("2026-11-22T10:00:00.123Z"))
        self.assertIsNone(feeds.when("yesterday"))

    def test_a_google_news_title_loses_its_publisher_and_a_copy_of_a_story_shows_once(self):
        google = {"id": "google-malta", "url": feeds.google("Malta")}
        own = {"id": "times-of-malta", "url": "https://timesofmalta.com/rss"}
        copy = feeds.tidy(google, {"title": "Parliament approves the budget - Times of Malta", "link": "https://news.google.com/a",
                                   "at": NOW - 60, "text": ""}, {}, NOW)
        self.assertEqual((copy["title"], copy["via"]), ("Parliament approves the budget", "Times of Malta"))
        first = feeds.tidy(own, {"title": "Parliament approves the budget", "link": "https://timesofmalta.com/a/budget",
                                 "at": NOW - 120, "text": ""}, {}, NOW)
        self.assertEqual([i["source"] for i in feeds.merged([copy, first])], ["times-of-malta"])

    # ---- Hyper+Space ----

    def test_hyper_space_lists_the_summary_row_then_headlines_newest_first_and_return_opens_them(self):
        items = self.run_ext("news").items
        self.assertItemShape(items)
        self.assertEqual(items[0]["title"], "Summarise the last 24 hours")
        self.assertEqual(items[0]["actions"][0], {"type": "run", "command": "summarise", "title": "Summarise the last 24 hours"})
        rows = items[1:]
        self.assertEqual([r["title"] for r in rows[:3]],
                         ["Is-settur marittimu ġġenera kważi €1,000 miljun", "Parliament approves the budget", "A new Mac mini"])
        self.assertEqual((rows[0]["subtitle"], rows[0]["accessory"], rows[0]["icon"]), ("TVM Aħbarijiet (Malti)", "30 min", "🇲🇹"))
        self.assertEqual((rows[1]["accessory"], rows[2]["subtitle"]), ("1 h", "The Verge"))
        self.assertEqual(rows[1]["actions"][0], {"type": "open", "url": "https://timesofmalta.com/a/budget",
                                                 "title": "Open in the browser"})
        ages = [r for r in rows if r["title"] == "Old story from yesterday"]
        self.assertEqual(ages[0]["accessory"], "1 d")
        self.assertFalse([m for m in self.box.run("news", "news").messages if m.get("type") == "action"])

    def test_a_fresh_cache_is_not_fetched_again_and_a_stale_one_refreshes_behind_the_list(self):
        self.run_ext("news")
        self.settle()
        asked = len(self.box.shim_calls())
        self.assertEqual(asked, 4, "one curl per picked source")
        self.run_ext("news")
        self.settle()
        self.assertEqual(len(self.box.shim_calls()), asked, "fresh headlines are not asked again")
        kept = json.loads((self.box.cache / "headlines.json").read_text())
        kept["fetchedAt"] -= 3600
        (self.box.cache / "headlines.json").write_text(json.dumps(kept))
        self.routes(dict(ROUTES, **{"timesofmalta.com": ("rss.xml", 1.5)}))
        result = self.run_ext("news")
        self.assertLess(result.elapsed, 1.0, "the list shows what is kept at once")
        self.assertEqual(len(result.items), 9, "the summary row and 8 headlines")
        self.settle()
        self.assertEqual(len(self.box.shim_calls()), asked * 2)

    # ---- the page ----

    def test_the_page_shows_the_buttons_headlines_a_broken_feed_and_the_sources_malta_first(self):
        self.fetched()
        blocks = self.page()
        news = blocks[0]
        self.assertEqual((news["title"], news["subtitle"]), ("News", "7 headlines in the last 24 hours from 4 sources"))
        self.assertEqual([a["title"] for a in news["blocks"][0]["actions"]], ["Summarise the last 24 hours", "Refresh"])
        failing = [b for b in blocks if b.get("title") == "Not answering"][0]
        self.assertEqual([(r["title"], r["subtitle"]) for r in failing["items"]], [("Lovin Malta", "is not an RSS or Atom feed")])
        headlines = [b for b in blocks if b.get("title") == "Headlines"][0]
        self.assertEqual(headlines["items"][0]["title"], "Is-settur marittimu ġġenera kważi €1,000 miljun")
        sources = blocks[-1]
        self.assertEqual(sources["title"], "Sources")
        self.assertEqual(sources["blocks"][0]["type"], "input")
        groups = [b["title"].split(" · ")[0] for b in sources["blocks"][1:]]
        self.assertEqual(groups, ["Malta", "World", "Tech", "Business", "Reddit"])
        malta = {r["id"]: r for r in sources["blocks"][1]["items"]}
        self.assertEqual(malta["times-of-malta"]["accessory"], {"text": "On", "tone": "fine"})
        self.assertEqual(malta["lovin-malta"]["accessory"], {"text": "On", "tone": "warn"})
        self.assertNotIn("accessory", malta["maltatoday"])
        self.assertEqual(malta["maltatoday"]["inline"][0]["icon"], "circle")
        self.assertTrue(malta["times-of-malta"]["subtitle"].startswith("4 items · 3 in 24 h · read "), malta["times-of-malta"])

    def test_a_broken_feed_keeps_its_last_headlines(self):
        self.fetched()
        self.routes(dict(ROUTES, **{"timesofmalta.com": ("cut.xml", 0)}))
        self.fetched()
        titles = [r["title"] for r in self.run_ext("news").items]
        self.assertIn("Parliament approves the budget", titles)
        failing = [b for b in self.page() if b.get("title") == "Not answering"][0]
        self.assertEqual(failing["items"][0]["badges"], [{"text": "Kept 4", "tone": "warn"}])

    def test_a_source_switched_on_is_fetched_and_one_switched_off_leaves_the_list(self):
        self.fetched()
        self.assertEqual(self.run_ext("toggle", context={"id": "the-verge"}).of_type("hud")[0]["text"], "The Verge off")
        self.assertNotIn("A new Mac mini", [r["title"] for r in self.run_ext("news").items])
        self.routes(dict(ROUTES, **{"maltatoday.com.mt": ("rss.xml", 0)}))
        self.run_ext("toggle", context={"id": "maltatoday"})
        self.settle()
        self.assertIn("curl https://www.maltatoday.com.mt/rss/news/", self.box.shim_calls())

    def test_his_own_feed_is_checked_named_and_removable_and_words_follow_google_news(self):
        self.assertEqual(self.run_ext("add-feed", input="https://example.org/feed").of_type("hud")[0]["text"], "Added Times of Malta")
        self.assertIn("That feed", self.run_ext("add-feed", input="https://nowhere.invalid/rss").of_type("hud")[0]["text"])
        self.assertEqual(self.run_ext("add-feed", input="Valletta port").of_type("hud")[0]["text"],
                         "Added Google News: Valletta port")
        self.settle()
        yours = [b for b in self.page()[-1]["blocks"] if b.get("title") == "Yours"][0]["items"]
        self.assertEqual([r["title"] for r in yours], ["Times of Malta", "Google News: Valletta port"])
        self.assertEqual(json.loads((self.box.data / "sources.json").read_text())["mine"][1]["url"],
                         "https://news.google.com/rss/search?q=Valletta+port&hl=en-GB&gl=GB&ceid=GB:en")
        self.run_ext("remove-feed", context={"id": yours[0]["id"]})
        self.assertEqual([r["title"] for r in [b for b in self.page()[-1]["blocks"] if b.get("title") == "Yours"][0]["items"]],
                         ["Google News: Valletta port"])

    # ---- the summary ----

    def test_a_press_sends_the_last_24_hours_headlines_and_short_descriptions_once(self):
        self.fetched()
        result, ai = self.press()
        self.assertEqual(result.of_type("hud")[0]["text"], "Summarising 7 headlines from 3 sources…")
        self.assertActionShape(ai)
        text = ai["text"]
        self.assertIn("[1] TVM Aħbarijiet (Malti) · ", text)
        self.assertIn("Is-settur marittimu ġġenera kważi €1,000 miljun", text)
        self.assertNotIn("Old story from yesterday", text, "only the last 24 hours")
        self.assertNotIn("Our feed has moved", text)
        self.assertIn("answer with JSON only", ai["prompt"])
        self.assertIn("in English", ai["prompt"])
        self.assertEqual(self.summary()["status"], "working")
        again, second = self.press()
        self.assertIsNone(second, "one summary per press: no second ask while one is on its way")
        self.assertIn("already on its way", again.of_type("hud")[0]["text"])

    def test_the_answer_becomes_a_newspaper_page_with_every_article_linked_and_opened(self):
        self.fetched()
        _, ai = self.press(preferences={"language": "maltese"})
        self.assertIn("in Maltese (Malti)", ai["prompt"])
        layout = {"lead": {"headline": "Budget passes after a long night", "summary": "The House approved it 36 to 29.",
                           "items": [2, 99]},
                  "sections": [{"title": "Malta", "stories": [{"headline": "Shipping brings in €1bn", "summary": "Il-Ministru.",
                                                               "items": [1]}]},
                               {"title": "Tech", "stories": [{"headline": "A faster Mac mini", "summary": "", "items": ["3"]}]}],
                  "brief": [{"text": "Ferries run again", "items": [4]}]}
        done = self.answer(ai, input="```json\n%s\n```" % json.dumps(layout), notice="Answered by Codex. Claude Code is out of usage.")
        hud = done.of_type("hud")[0]["text"]
        self.assertRegex(hud, r"^News summary ready in \d+ s · Answered by Codex\. Claude Code is out of usage\.$")
        [opened] = done.actions
        self.assertEqual(opened["type"], "open")
        self.assertTrue(opened["url"].endswith(time.strftime("%Y-%m-%d") + ".html"))
        html = self.read(opened["url"])
        self.assertIn('<h1 class="mast">Pilot News', html)
        self.assertIn(time.strftime("%A %-d %B %Y"), html)
        self.assertIn('<a href="https://timesofmalta.com/a/budget">Budget passes after a long night</a>', html)
        self.assertIn("Shipping brings in €1bn", html)
        self.assertIn("<h2>Tech</h2>", html)
        for link in ("https://timesofmalta.com/a/budget", "https://timesofmalta.com/a/ferry", "https://tvmnews.mt/news/multa/",
                     "https://www.theverge.com/y", "https://timesofmalta.com/a/x"):
            self.assertIn('href="%s"' % link, html, "every article is linked")
        self.assertNotIn("<script>alert", html)
        self.assertIn('href="https://timesofmalta.com/a/x">Valletta</a>', html, "a title's tags are dropped as a description's")
        self.assertNotIn("Old story from yesterday", html)
        self.assertIn("Edited by Answered by Codex.", html)
        self.assertEqual(html.count("<script>"), 1, "its one script is its own light and dark switch")
        state = self.summary()
        self.assertEqual((state["status"], state["count"], state["path"]), ("done", 7, opened["url"]))
        page = self.page()
        self.assertIn("Open the last summary", [a["title"] for a in page[0]["blocks"][0]["actions"]])
        self.assertRegex(page[0]["blocks"][1]["text"], r"^Last summary \d\d:\d\d · 7 headlines · \d+ s · Answered by Codex")
        _, again = self.press()
        self.assertIsNotNone(again, "a new press makes a new summary")
        self.answer(again, input=json.dumps(layout))
        self.assertTrue(self.summary()["path"].endswith(time.strftime("%Y-%m-%d") + " 2.html"), "the first one is kept")

    def test_while_one_is_on_its_way_the_page_offers_ask_again_and_a_twin_answer_is_dropped(self):
        self.fetched()
        _, ai = self.press()
        page = self.page()
        again = page[0]["blocks"][0]["actions"][0]
        self.assertEqual((again["type"], again["title"]), ("ai", "Ask again"))
        self.assertEqual((again["text"], again["then"]["context"]["job"]), (ai["text"], ai["then"]["context"]["job"]))
        self.assertEqual(page[0]["blocks"][1]["text"], "Summarising 7 headlines…")
        self.assertEqual(self.box.run("news", "page", surface="page").of_type("blocks")[0]["refresh"], 2)
        first = self.answer(again, input="{}")
        self.assertEqual(len(first.actions), 1)
        twin = self.answer(ai, input="{}")
        self.assertEqual((twin.of_type("hud")[0]["text"], twin.actions), ("That news summary is made already", []))
        self.assertEqual(len(list((self.box.root / "out").iterdir())), 1, "one paper a press")
        self.assertEqual(self.page()[0]["blocks"][0]["actions"][0]["type"], "run", "done: the button presses anew")

    def test_an_answer_that_is_not_json_still_makes_a_paper_and_a_failure_makes_none(self):
        self.fetched()
        _, ai = self.press()
        done = self.answer(ai, input="- **Budget** passed\n- Ferries are back")
        self.assertEqual(done.of_type("hud")[0]["text"].split(" · ")[1], "Pilot's AI")
        html = self.read(done.actions[0]["url"])
        self.assertIn("<li>Budget passed</li>", html)
        self.assertIn('href="https://www.theverge.com/x"', html)
        _, ai = self.press()
        failed = self.answer(ai, error="Claude Code is signed out. Sign in on the AI page.")
        self.assertEqual(failed.of_type("hud")[0]["text"], "News summary failed: Claude Code is signed out. Sign in on the AI page.")
        self.assertEqual(failed.actions, [])
        self.assertEqual(self.summary()["status"], "failed")
        self.assertIsNotNone(self.press()[1], "after a failure a press asks again")

    def test_nothing_from_the_last_day_asks_no_ai(self):
        self.pick({"picked": {k: False for k in PICKS["picked"]}})
        self.assertEqual(self.press()[0].of_type("hud")[0]["text"], "Pick a source on the News page first")
        self.pick({"picked": dict({k: False for k in PICKS["picked"]}, **{"lovin-malta": True})})
        result, ai = self.press()
        self.assertIsNone(ai)
        self.assertEqual(result.of_type("hud")[0]["text"], "No headlines from the last 24 hours in your sources")

    def test_no_surface_asks_the_ai_and_there_is_no_timer(self):
        manifest = json.loads((EXTENSIONS / "news" / "extension.json").read_text())
        self.assertEqual(list(manifest["surfaces"]), ["page"])
        self.fetched()
        for command in ("news", "page"):
            result = self.box.run("news", command, surface="page" if command == "page" else None)
            self.assertFalse([m for m in result.messages if m.get("type") == "action"], command)

    def test_the_paper_layout_keeps_only_real_item_numbers(self):
        read = paper.layout('Here: {"lead": {"headline": "H", "items": [0, 2, 2, 7, "1", true]}, "sections": []}', 3)
        self.assertEqual(read["lead"]["items"], [2, 1])
        self.assertIsNone(paper.layout("no json at all", 3))
        self.assertIsNone(paper.layout('{"lead": {"summary": "no headline"}}', 3))


if __name__ == "__main__":
    unittest.main()
