import fcntl
import importlib.util
import json
import os
import time
import unittest
from unittest import mock
from datetime import datetime
from urllib.parse import parse_qs, urlsplit
from zoneinfo import ZoneInfo

from harness import EXTENSIONS, ExtensionTestCase

_spec = importlib.util.spec_from_file_location("markets", EXTENSIONS / "markets" / "main.py")
markets = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(markets)

NY = ZoneInfo("America/New_York")


def ny(y, mo, d, h, mi=0):
    """Seconds since 1970 at a New York wall-clock time."""
    return datetime(y, mo, d, h, mi, tzinfo=NY).timestamp()


def chart(symbol, company, last, change, percent, previous, line):
    """Nasdaq's chart answer as its API gives it (trimmed): Thursday 15 October 2026, a pre-market minute, the session
    every 30 minutes from 09:30 to 16:00, an after-hours minute."""
    stamps = [ny(2026, 10, 15, 4)] + [ny(2026, 10, 15, 9, 30) + i * 1800 for i in range(14)] + [ny(2026, 10, 15, 20)]
    values = [line[0] - 5] + line + [last]
    return {"data": {"symbol": symbol, "company": company, "timeAsOf": "Oct 15, 2026", "lastSalePrice": "$%s" % last,
                     "netChange": change, "percentageChange": percent, "deltaIndicator": "up", "previousClose": "$%s" % previous,
                     "volume": "39,767,602", "exchange": "NASDAQ-GS",
                     "chart": [{"z": {"dateTime": "", "value": str(v)}, "x": int(t * 1000), "y": v} for t, v in zip(stamps, values)]},
            "message": None, "status": {"rCode": 200, "bCodeMessage": None, "developerMessage": None}}


NOT_FOUND = {"data": None, "message": None,
             "status": {"rCode": 400, "bCodeMessage": [{"code": 1001, "errorMessage": "Symbol not exists."}]}}
SESSION = [340 + (i % 5) for i in range(14)]
FIXTURES = {
    "nasdaq-AAPL-stocks": chart("AAPL", "Apple Inc. Common Stock", "342.00", "-0.96", "-0.28%", "342.96", SESSION),
    "nasdaq-SPY-stocks": NOT_FOUND,
    "nasdaq-SPY-etf": chart("SPY", "State Street SPDR S&P 500 ETF Trust", "771.79", "+2.19", "+0.28%", "769.60",
                            [765 + i for i in range(14)]),
    "nasdaq-ZZZZQ-stocks": NOT_FOUND, "nasdaq-ZZZZQ-etf": NOT_FOUND,
    "markets": [{"id": "bitcoin", "symbol": "btc", "name": "Bitcoin", "current_price": 73093, "high_24h": 73420,
                 "low_24h": 71016, "price_change_24h": 1196.72, "price_change_percentage_24h": 1.43819,
                 "last_updated": "2026-10-16T07:05:56.000Z", "sparkline_in_7d": {"price": [80000 + i * 10 for i in range(168)]}},
                {"id": "ethereum", "symbol": "eth", "name": "Ethereum", "current_price": 2650.5, "high_24h": 2700,
                 "low_24h": 2600, "price_change_24h": -15.2, "price_change_percentage_24h": -0.57,
                 "last_updated": "2026-10-16T07:05:56.000Z", "sparkline_in_7d": {"price": [3000 - i for i in range(168)]}},
                {"id": "kaspa", "symbol": "kas", "name": "Kaspa", "current_price": 0.0612345, "high_24h": 0.063,
                 "low_24h": 0.06, "price_change_24h": 0, "price_change_percentage_24h": 0,
                 "last_updated": "2026-10-16T07:05:56.000Z", "sparkline_in_7d": {"price": [0.06] * 168}}],
    "search": {"coins": [{"id": "kaspa-fake", "symbol": "KAS", "market_cap_rank": 900},
                         {"id": "kaspa", "symbol": "KAS", "market_cap_rank": 40},
                         {"id": "kasta", "symbol": "KASTA", "market_cap_rank": 10}]},
    "fx": {"amount": 1.0, "base": "USD", "date": "2026-10-15", "rates": {"EUR": 0.89222}},
}


def tv(ticker, name, close, change, change_abs, high, low, description, currency, kind):
    return {"s": ticker, "d": [name, close, change, change_abs, high, low, description, currency, kind, ticker.split(":")[0]]}


STOCK_ROWS = [tv("NASDAQ:AAPL", "AAPL", 344.28, 0.6667, 2.28, 347.82, 342.03, "Apple Inc.", "USD", "stock"),
              tv("AMEX:SPY", "SPY", 770.545, -0.1613, -1.245, 773.25, 770.48, "State Street SPDR S&P 500 ETF", "USD", "fund"),
              tv("XETR:VWCE", "VWCE", 170.62, -0.1872, -0.32, 171.2, 170.1, "Vanguard FTSE All-World UCITS ETF", "EUR", "fund"),
              tv("BMV:SPY", "SPY", 13900.0, 0.1, 13.9, 13950.0, 13800.0, "SPDR S&P 500 ETF", "MXN", "fund"),
              tv("VIE:AAPL", "AAPL", 300.1, 0.5, 1.5, 301.0, 298.0, "Apple Inc.", "EUR", "stock")]
COIN_ROWS = [tv("MEXC:BTCEUR", "BTCEUR", 73000.0, 1.0, 730.0, 73500.0, 72000.0, "Bitcoin / Euro", "EVC", "spot"),
             tv("BITSTAMP:BTCEUR", "BTCEUR", 73116.65, -0.1739, -127.35, 73573.92, 72540.0, "Bitcoin / Euro", "EUR", "spot"),
             tv("KRAKEN:BTCEUR", "BTCEUR", 73120.4, -0.17, -124.0, 73580.0, 72550.0, "Bitcoin / Euro", "EUR", "spot"),
             tv("KRAKEN:ETHEUR", "ETHEUR", 2197.15, 0.9669, 21.04, 2213.09, 2159.76, "Ethereum / Euro", "EUR", "spot")]
PAIR_ROWS = [tv("FX:EURUSD", "EURUSD", 1.12385, 0.12, 0.00135, 1.1251, 1.1219, "Euro / U.S. Dollar", "USD", "forex"),
             tv("SP:SPX", "SPX", 7659.44, 0.31, 23.6, 7670.1, 7620.0, "S&P 500 Index", None, "index"),
             tv("BITSTAMP:BTCUSD", "BTCUSD", 81609.58, 1.2, 967.5, 82100.0, 80200.0, "Bitcoin / U.S. dollar", "USD", "spot")]


def found(symbol, description, kind, prefix, place, specs=None, contracts=None):
    """A row of TradingView's symbol search as it answers (recorded for "BTC" on 2026-10-16, trimmed), its match
    highlighted."""
    row = {"symbol": symbol, "description": description, "type": kind, "exchange": place, "currency_code": "USD",
           "source2": {"id": prefix, "name": place, "description": place}, "source_id": prefix, "typespecs": specs or []}
    if contracts:
        row["contracts"] = contracts
    return row


SEARCH = {"symbols_remaining": 7453, "symbols": [
    dict(found("<em>BTCUSD</em>", "<em>Bitcoin</em> / U.S. dollar", "spot", "BITSTAMP", "Bitstamp", ["crypto"]), prefix="BITSTAMP"),
    dict(found("<em>BTCUSD</em>", "<em>Bitcoin</em> / US Dollar", "spot", "COINBASE", "Coinbase", ["crypto"]), prefix="COINBASE"),
    found("<em>BTCUSD</em>", "<em>Bitcoin</em> all time history index", "index", "INDEX", "INDEX", ["crypto", "synthetic"]),
    found("<em>BTC</em>", "<em>Bitcoin</em> Futures", "futures", "CME", "CME", None,
          [{"symbol": "<em>BTC</em>1!", "typespecs": ["continuous", "synthetic"]}, {"symbol": "<em>BTC</em>V2026", "description": "Oct 2026"}]),
    found("<em>BTC</em>", "Grayscale Bitcoin Mini Trust (<em>BTC</em>)", "fund", "AMEX", "NYSE American", ["etf"]),
    found("<em>BTC</em>", "London <em>BTC</em> Company Limited", "stock", "LSE", "London Stock Exchange", ["common"])]}
FIXTURES.update({"tv-global": {"totalCount": 8, "data": STOCK_ROWS + PAIR_ROWS}, "tv-crypto": {"totalCount": 4, "data": COIN_ROWS},
                 "tv-search": SEARCH})


class MarketsCase(ExtensionTestCase):
    """The sandbox, the fake curl and the helpers every Markets test shares; PREFS are each run's preferences unless the
    test names its own."""
    EXTENSION = "markets"
    PREFS = {}
    PILOT = {"repos": "/tmp/code", "terminal": "com.mitchellh.ghostty",
             "blocks": "stats,meter,list,markdown,buttons,section,chat,input,hero,strip,note,links"}
    OLDER = {"repos": "/tmp/code", "terminal": "com.mitchellh.ghostty"}

    def setUp(self):
        super().setUp()
        self.addCleanup(self.settle)
        self.fixtures = self.box.root / "fixtures"
        self.fixtures.mkdir()
        for name, body in FIXTURES.items():
            (self.fixtures / (name + ".json")).write_text(json.dumps(body))
        self.fake_curl()

    def run_ext(self, command, **kwargs):
        kwargs["preferences"] = dict(self.PREFS, **(kwargs.get("preferences") or {}))
        return super().run_ext(command, **kwargs)

    def fake_curl(self, fail=None, delay=0):
        """A curl that logs its arguments and answers from the fixtures by host and path, `delay` s late, or fails as
        curl does; a URL with no fixture is a 404."""
        body = 'for url; do :; done\nprintf "%%s\\n" "$*" >> "%s"\n' % self.box.log
        if delay:
            body += "sleep %s\n" % delay
        if fail:
            body += 'echo "curl: %s" >&2; exit 6' % fail
        else:
            body += ('case "$url" in\n'
                     '  *symbol-search.tradingview.com/*) f=tv-search;;\n'
                     '  *scanner.tradingview.com/global/scan) f=tv-global;; *scanner.tradingview.com/crypto/scan) f=tv-crypto;;\n'
                     '  */market_chart*) f=coin-chart;; */historical\\?*) f=nasdaq-history;; *frankfurter.dev/v1/*..*) f=fx-series;;\n'
                     '  *api.nasdaq.com/api/quote/*) s=${url#*/api/quote/}; s=${s%%%%/*}; f="nasdaq-$s-${url##*assetclass=}";;\n'
                     '  *coins/markets*) f=markets;; *api/v3/search*) f=search;; *frankfurter*) f=fx;; *) f=none;;\n'
                     'esac\n'
                     'if [ -f "%s/$f.json" ]; then cat "%s/$f.json"; else echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; fi'
                     % (self.fixtures, self.fixtures))
        self.box.shim("curl", body)

    def calls(self):
        """(host, path, query, the arguments before the URL) per curl call."""
        found = []
        for line in self.box.shim_calls():
            args, _, url = line.rpartition(" ")
            parts = urlsplit(url)
            found.append((parts.netloc, parts.path, {k: v[0] for k, v in parse_qs(parts.query).items()}, args))
        return found

    def asked(self, since=0):
        """What was asked from the `since`th call on, in short and sorted: AAPL/stocks, markets, search, fx."""
        short = []
        for host, path, query, args in self.calls()[since:]:
            if host == "api.nasdaq.com":
                short.append("%s/%s" % (path.split("/")[3], query["assetclass"]))
            elif host == "symbol-search.tradingview.com":
                short.append("tv-search")
            elif host == "scanner.tradingview.com":
                short.append("tv-%s-%s" % (path.split("/")[1], "find" if "in_range" in args else "tickers"))
            else:
                short.append({"api.frankfurter.dev": "fx"}.get(host, path.rsplit("/", 1)[-1]))
        return sorted(short)

    def settle(self):
        lock = self.box.cache / "refresh.lock"
        if lock.exists():
            with open(str(lock), "a") as f:
                fcntl.flock(f, fcntl.LOCK_EX)

    def kept(self):
        return json.loads((self.box.cache / "quotes.json").read_text())

    def age_all(self, seconds):
        kept = self.kept()
        for record in kept.values():
            record["fetchedAt"] -= seconds
            record["triedAt"] -= seconds
        (self.box.cache / "quotes.json").write_text(json.dumps(kept))

    def coins_query(self):
        """The query of the CoinGecko markets call."""
        return next(q for _, p, q, _ in self.calls() if p.endswith("/markets"))

    def rows(self, blocks):
        return {i["id"]: i for b in blocks if b["type"] == "list" for i in b["items"]}


class NasdaqTests(MarketsCase):
    """Nasdaq for stocks and ETFs, CoinGecko for coins: Markets 1.0.0's sources."""
    PREFS = {"source": "nasdaq"}

    # ---- the bar and the cache ----

    def test_bar_shows_the_first_symbol_and_its_change_and_asks_each_source_once(self):
        line = self.bar()
        self.assertEqual((line["text"], line["tone"]), ("SPY ▲0.28%", "fine"))
        self.assertEqual(self.asked(), ["AAPL/stocks", "SPY/etf", "SPY/stocks", "fx", "markets"])
        coins = self.coins_query()
        self.assertEqual((coins["vs_currency"], coins["ids"], coins["sparkline"]), ("eur", "bitcoin,ethereum", "true"))
        for host, _, _, args in self.calls():
            self.assertIn(host, {"api.nasdaq.com", "api.coingecko.com", "api.frankfurter.dev"})
            self.assertEqual("Mozilla/" in args, host == "api.nasdaq.com", "Nasdaq answers a browser's User-Agent alone")
        self.assertEqual(self.bar()["text"], "SPY ▲0.28%")
        self.assertEqual(len(self.calls()), 5, "fresh answers are not asked again")

    def test_a_stock_found_as_an_etf_is_asked_as_one_from_then_on(self):
        self.bar()
        self.age_all(8 * 86400)
        self.blocks_message("bar", "popover")
        self.settle()
        self.assertEqual(self.asked(since=5), ["AAPL/stocks", "SPY/etf", "markets"], "neither the class nor the rate asked again")

    def test_a_falling_pin_is_alert_with_its_arrow_and_the_price_shows_when_asked(self):
        line = self.bar(preferences={"pinned": "aapl"})
        self.assertEqual((line["text"], line["tone"]), ("AAPL ▼0.28%", "alert"))
        self.assertEqual(self.bar(preferences={"pinned": "BTC", "showPrice": True})["text"], "BTC €73.1k ▲1.44%")
        self.assertEqual(self.bar(preferences={"pinned": "SPY", "showPrice": True})["text"], "SPY €689 ▲0.28%")
        self.assertEqual(self.bar(preferences={"pinned": "NOPE"})["text"], "SPY ▲0.28%", "an unlisted pin is the first")

    def test_offline_keeps_the_last_prices_marked_old_and_waits_a_minute_to_retry(self):
        self.bar()
        self.age_all(8 * 86400)
        self.fake_curl(fail="(6) Could not resolve host: api.nasdaq.com")
        self.bar()
        self.settle()
        line = self.bar()
        self.assertEqual((line["text"], line["tone"]), ("SPY ▲0.28%", "warn"))
        rows = self.rows(self.popover(pilot=self.PILOT))
        self.assertIn({"text": "⚠ 8d old", "tone": "warn"}, rows["stock:SPY"]["badges"])
        self.assertIn("Nasdaq: (6) Could not resolve host", rows["stock:SPY"]["subtitle"])
        self.assertEqual(len(self.calls()), 5 + 3, "one failed try each (SPY, AAPL, coins), then none for a minute")

    def test_offline_with_nothing_kept_says_why(self):
        self.fake_curl(fail="(6) Could not resolve host: api.nasdaq.com")
        line = self.bar()
        self.assertEqual((line["text"], line["tone"]), ("SPY –", "warn"))
        spy = self.rows(line["blocks"])["stock:SPY"]
        self.assertEqual((spy["title"], spy["subtitle"]), ("SPY", "Nasdaq: (6) Could not resolve host: api.nasdaq.com"))
        self.assertEqual(spy["badges"], [{"text": "no price", "tone": "warn"}])

    def test_a_slow_network_shows_the_rows_asking_then_the_prices(self):
        self.fake_curl(delay=1.8)
        line = self.bar()
        self.assertEqual(line["text"], "SPY –")
        self.assertNotIn("tone", line, "asking is no failure")
        spy = self.rows(line["blocks"])["stock:SPY"]
        self.assertEqual((spy["subtitle"], spy["badges"]), ("Asking…", []))
        self.settle()
        self.assertEqual(self.bar()["text"], "SPY ▲0.28%")

    def test_an_unknown_symbol_says_so_and_the_rest_still_show(self):
        rows = self.rows(self.popover(preferences={"symbols": "ZZZZQ, BTC"}))
        self.assertEqual(rows["stock:ZZZZQ"]["subtitle"], "Nasdaq knows no ZZZZQ")
        self.assertEqual(rows["coin:BTC"]["title"], "BTC · €73,093")
        self.popover(preferences={"symbols": "ZZZZQ, BTC"})
        self.assertEqual(self.asked().count("ZZZZQ/stocks"), 1, "not asked again within a minute")

    def test_a_coin_not_known_is_found_once_by_its_symbol(self):
        rows = self.rows(self.popover(preferences={"symbols": "coin:KAS"}))
        self.assertEqual((rows["coin:KAS"]["title"], rows["coin:KAS"]["badges"]), ("KAS · €0.06123", [{"text": "0.00% 24h"}]))
        self.assertEqual(self.coins_query()["ids"], "kaspa", "the highest-ranked KAS")
        self.age_all(3600)
        self.popover(preferences={"symbols": "coin:KAS"})
        self.settle()
        self.assertEqual(self.asked(), ["markets", "markets", "search"], "searched once, kept")

    def test_dollars_need_no_rate(self):
        rows = self.rows(self.popover(preferences={"currency": "usd"}))
        self.assertEqual(rows["stock:SPY"]["title"], "SPY · $771.79")
        self.assertNotIn("fx", self.asked())
        self.assertEqual(self.coins_query()["vs_currency"], "usd")

    # ---- views ----

    maxDiff = None

    def test_popover_leads_with_the_pin_big_then_a_row_a_symbol_with_its_line_and_the_market_hours(self):
        hero, listed, note, links = self.popover(pilot=self.PILOT)
        self.assertEqual(hero, {"type": "hero", "glyph": "📈", "value": "688.61", "unit": "EUR", "tone": "fine",
                                "place": "State Street SPDR S&P 500 ETF Trust · SPY · ≈ from $771.79",
                                "items": [{"label": "Today", "value": "▲ 0.28% · +€1.95", "tone": "fine"},
                                          {"label": "Day range", "value": "682.55 – 694.15"},
                                          {"label": "Prev close", "value": "686.65"}]})
        rows = listed["items"]
        self.assertEqual([r["title"] for r in rows], ["SPY · ≈ €688.61", "AAPL · ≈ €305.14", "BTC · €73,093", "ETH · €2,650.50"])
        self.assertEqual([r["badges"] for r in rows],
                         [[{"text": "▲ 0.28%", "tone": "fine"}], [{"text": "▼ 0.28%", "tone": "alert"}],
                          [{"text": "▲ 1.44% 24h", "tone": "fine"}], [{"text": "▼ 0.57% 24h", "tone": "alert"}]])
        self.assertEqual([r["icon"] for r in rows], ["🧺", "🏢", "🪙", "🪙"])
        self.assertEqual(rows[0]["subtitle"], "▁▂▂▃▃▄▄▅▅▆▆▇▇█  State Street SPDR S&P 500 ETF Trust",
                         "the session alone, 09:30 to 16:00")
        self.assertEqual(rows[1]["subtitle"].split("  ")[1], "Apple Inc.")
        self.assertEqual(len(rows[2]["subtitle"].split("  ")[0]), 16, "a coin's last 24 hours in 16 bars")
        self.assertEqual(rows[0]["actions"][0], {"type": "open", "url": "https://www.nasdaq.com/market-activity/etfs/spy",
                                                 "title": "Open SPY on Nasdaq"})
        self.assertEqual(rows[1]["inline"][0]["url"], "https://www.nasdaq.com/market-activity/stocks/aapl")
        self.assertEqual(rows[2]["inline"][0], {"type": "open", "url": "https://www.coingecko.com/en/coins/bitcoin",
                                                "title": "Open on CoinGecko", "icon": "🌐"})
        self.assertEqual(rows[1]["actions"][1], {"type": "copy", "text": "AAPL ≈ €305.14", "title": "Copy the price"})
        self.assertRegex(note["text"], r"^Updated \d\d:\d\d · US market (open until|closed · opens) ")
        self.assertEqual((note["aside"], links["items"][0]["actions"][0]["command"]), ("Nasdaq · CoinGecko", "refresh"))

    def test_an_older_pilot_gets_the_rows_and_the_hours_in_words(self):
        for pilot in (None, self.OLDER):
            with self.subTest(pilot=pilot):
                blocks = self.popover(pilot=pilot)
                self.assertEqual([b["type"] for b in blocks], ["list", "markdown"])
                self.assertIn("· Nasdaq · CoinGecko", blocks[1]["text"])

    def test_page_adds_refresh_and_the_credit(self):
        blocks = self.page(pilot=self.PILOT)
        self.assertEqual([b["type"] for b in blocks], ["input", "hero", "list", "note", "buttons", "markdown"])
        self.assertEqual(blocks[4]["actions"][0]["command"], "refresh")
        self.assertIn("ECB", blocks[5]["text"])

    def test_no_symbols_says_where_to_add_them(self):
        line = self.bar(preferences={"symbols": " , ; "})
        self.assertEqual((line["text"], line["tone"]), ("📈 –", "warn"))
        self.assertIn("settings", line["blocks"][0]["text"])
        self.assertEqual(self.calls(), [])

    def test_hyper_space_lists_the_rows_then_refresh(self):
        items = self.run_ext("markets").items
        self.assertItemShape(items)
        self.assertEqual([i["id"] for i in items], ["stock:SPY", "stock:AAPL", "coin:BTC", "coin:ETH", "search", "refresh"])
        self.assertEqual(items[-2]["actions"][0], {"type": "push", "command": "search", "title": "Search TradingView"})
        self.assertEqual(items[-1]["actions"][0]["command"], "refresh")

    def test_refresh_asks_everything_again_and_says_the_moves(self):
        self.bar()
        result = self.run_ext("refresh")
        self.assertEqual(result.of_type("hud")[0]["text"],
                         "Markets: SPY ▲ 0.28%, AAPL ▼ 0.28%, BTC ▲ 1.44%, ETH ▼ 0.57%")
        self.assertEqual(len(self.calls()), 5 + 4, "SPY as an ETF, AAPL, the coins and the rate again")


class TradingViewTests(MarketsCase):
    """TradingView's screener, the default source: one call for the stocks, one for the coins, a row opening there."""

    def test_default_source_finds_each_listing_once_and_asks_by_ticker_from_then_on(self):
        line = self.bar()
        self.assertEqual((line["text"], line["tone"]), ("SPY ▼0.16%", "alert"))
        self.assertEqual(self.asked(), ["fx", "tv-crypto-find", "tv-global-find"])
        self.assertEqual(self.bar()["text"], "SPY ▼0.16%")
        self.assertEqual(len(self.calls()), 3, "fresh answers are not asked again")
        self.age_all(8 * 86400)
        self.blocks_message("bar", "popover")
        self.settle()
        self.assertEqual(self.asked(since=3), ["tv-crypto-tickers", "tv-global-tickers"], "the listings found are kept")
        bodies = " ".join(a for h, _, _, a in self.calls()[3:] if h == "scanner.tradingview.com")  # the two scans run side by side
        self.assertIn('"tickers":["KRAKEN:BTCEUR","KRAKEN:ETHEUR"]', bodies)
        self.assertIn('"tickers":["AMEX:SPY","NASDAQ:AAPL"]', bodies)

    def test_rows_open_on_tradingview_in_euros(self):
        rows = self.rows(self.popover(pilot=self.PILOT))
        self.assertEqual(rows["stock:SPY"]["actions"][0], {"type": "open", "url": "https://www.tradingview.com/symbols/AMEX-SPY/",
                                                           "title": "Open SPY on TradingView"})
        self.assertEqual(rows["coin:BTC"]["inline"][0]["url"], "https://www.tradingview.com/symbols/KRAKEN-BTCEUR/",
                         "a pair in euros on the first exchange preferred, never MEXC's EVC")
        self.assertEqual(rows["stock:AAPL"]["title"], "AAPL · ≈ €%.2f" % (344.28 * 0.89222))
        self.assertEqual(rows["coin:BTC"]["title"], "BTC · €73,120")
        self.assertEqual((rows["coin:BTC"]["badges"], rows["stock:AAPL"]["subtitle"]),
                         ([{"text": "▼ 0.17%", "tone": "alert"}], "Apple Inc."), "no line from one reading")

    def test_the_line_grows_from_the_prices_read(self):
        self.popover(preferences={"symbols": "BTC"})
        rows = json.loads((self.fixtures / "tv-crypto.json").read_text())
        rows["data"][2]["d"][1] = 74000.0
        (self.fixtures / "tv-crypto.json").write_text(json.dumps(rows))
        self.age_all(400)
        self.popover(preferences={"symbols": "BTC"})
        self.settle()
        btc = self.rows(self.popover(preferences={"symbols": "BTC"}))["coin:BTC"]
        self.assertEqual(btc["subtitle"], "▁█  Bitcoin / Euro")

    def test_an_exchange_written_is_asked_for_that_listing_in_its_money(self):
        rows = self.rows(self.popover(preferences={"symbols": "XETR:VWCE, BTC", "pinned": "VWCE"}, pilot=self.PILOT))
        self.assertEqual(self.asked(), ["tv-crypto-find", "tv-global-tickers"], "no lookup, no rate: both in euros")
        vwce = rows["stock:XETR:VWCE"]
        self.assertEqual((vwce["title"], vwce["actions"][0]["url"]), ("VWCE · €170.62", "https://www.tradingview.com/symbols/XETR-VWCE/"))

    def test_a_coins_move_is_said_since_midnight_utc(self):
        hero = self.popover(preferences={"pinned": "BTC"}, pilot=self.PILOT)[0]
        self.assertEqual([i["label"] for i in hero["items"]], ["Since 00:00 UTC", "Day range", "As of"])
        spy = self.popover(preferences={"pinned": "SPY"}, pilot=self.PILOT)[0]
        self.assertEqual([i["label"] for i in spy["items"]], ["Today", "Day range", "Prev close"])

    def test_an_unknown_ticker_says_so(self):
        rows = self.rows(self.popover(preferences={"symbols": "ZZZZQ, SPY"}))
        self.assertEqual((rows["stock:ZZZZQ"]["subtitle"], rows["stock:ZZZZQ"]["badges"]),
                         ("TradingView knows no ZZZZQ", [{"text": "no price", "tone": "warn"}]))
        self.assertTrue(rows["stock:SPY"]["title"].startswith("SPY · ≈ €"))


class BarTests(MarketsCase):
    """The menu bar's styles and parts, on Nasdaq and CoinGecko's answers."""
    PREFS = {"source": "nasdaq"}

    def test_several_side_by_side_fit_pilots_24_characters(self):
        line = self.bar(preferences={"pinned": "SPY, BTC"})
        self.assertEqual((line["text"], line["tone"]), ("SPY ▲0.28% · BTC ▲1.44%", "fine"))
        line = self.bar(preferences={"pinned": "SPY, AAPL"})
        self.assertEqual(line["text"], "SPY ▲0.28% · AAPL ▼0.28%")
        self.assertNotIn("tone", line, "mixed moves: the arrows say it")
        self.assertEqual(self.bar(preferences={"pinned": "SPY, AAPL, BTC", "showPrice": True})["text"], "SPY ▲0.28% · AAPL ▼0.28%",
                         "prices dropped first, then the symbols that do not fit")

    def test_several_in_turn_move_on_each_bar_run_never_on_a_click(self):
        prefs = {"pinned": "SPY, AAPL", "several": "rotate"}
        self.assertEqual(self.bar(preferences=prefs)["text"], "SPY ▲0.28%")
        self.assertEqual(self.bar(preferences=prefs)["text"], "AAPL ▼0.28%")
        self.popover(preferences=prefs)
        self.assertEqual(self.bar(preferences=prefs)["text"], "SPY ▲0.28%")

    def test_the_parts_shown_are_the_users(self):
        prefs = {"pinned": "SPY", "showSymbol": False, "showPrice": True, "showChange": True}
        self.assertEqual(self.bar(preferences=prefs)["text"], "€689 ▲0.28% +€1.95")
        self.assertEqual(self.bar(preferences=dict(prefs, showPrice=False, showPercent=False, showChange=False))["text"],
                         "SPY ▲0.28%", "nothing ticked: the symbol and its change")

    def test_text_with_the_days_line(self):
        self.assertRegex(self.bar(preferences={"style": "line"})["text"], r"^SPY [▁▂▃▄▅▆▇█]{6} ▲0\.28%$")

    def test_mini_bars_one_gauge_a_symbol_each_in_its_tone(self):
        line = self.bar(preferences={"style": "bars", "pinned": "SPY, AAPL, BTC, ETH"})
        self.assertEqual(line["text"], "")
        self.assertNotIn("tone", line)
        spy, aapl, btc = line["gauges"]
        self.assertEqual((spy["label"], spy["text"], spy["tone"]), ("SPY", "▲0.28%", "fine"))
        self.assertAlmostEqual(spy["meters"][0], (771.79 - 765) / (778 - 765) * 100)
        self.assertEqual((aapl["label"], aapl["meters"], aapl["tone"]), ("AAPL", [50.0], "alert"))
        self.assertEqual((btc["label"], btc["text"]), ("BTC", "▲1.44%"))
        line = self.bar(preferences={"style": "bars", "showSymbol": False})
        self.assertNotIn("label", line["gauges"][0])


EURUSD = {"kind": "pair", "symbol": "EURUSD", "listing": "FX:EURUSD", "type": "forex", "name": "Euro / U.S. Dollar"}
SPX = {"kind": "pair", "symbol": "SPX", "listing": "SP:SPX", "type": "index"}


class SearchTests(MarketsCase):
    """TradingView's symbol search adds to the list followed, which the page orders and trims (Sven Q192)."""

    def watched(self):
        return [s["key"] for s in json.loads((self.box.data / "watchlist.json").read_text())["symbols"]]

    def add(self, symbol, **kwargs):
        return self.run_ext("add", context={"symbol": symbol}, **kwargs)

    def hud(self, result):
        self.assertEqual(result.of_type("error"), [], result.stdout)
        return result.of_type("hud")[0]["text"]

    def test_the_old_symbols_setting_seeds_the_list_and_an_edit_there_replaces_it(self):
        self.bar()
        self.assertEqual(self.watched(), ["stock:SPY", "stock:AAPL", "coin:BTC", "coin:ETH"])
        self.assertEqual(self.hud(self.add(EURUSD)), "Markets: added FX:EURUSD")
        self.assertEqual(list(self.rows(self.popover())), ["stock:SPY", "stock:AAPL", "coin:BTC", "coin:ETH", "pair:FX:EURUSD"])
        self.assertEqual(list(self.rows(self.popover(preferences={"symbols": "BTC, SPY"}))), ["coin:BTC", "stock:SPY"],
                         "Sven edited the setting: it wins")
        self.assertEqual(self.watched(), ["coin:BTC", "stock:SPY"])

    def test_hyper_space_search_lists_tradingviews_answers_and_return_adds_one(self):
        items = self.run_ext("search", query="btc").items
        self.assertItemShape(items)
        self.assertEqual([i["id"] for i in items], ["find:pair:BITSTAMP:BTCUSD", "find:pair:COINBASE:BTCUSD", "find:pair:INDEX:BTCUSD",
                                                    "find:pair:CME:BTC1!", "find:stock:AMEX:BTC", "find:stock:LSE:BTC"])
        first = items[0]
        self.assertEqual((first["title"], first["subtitle"], first["icon"]), ("BTCUSD", "Bitcoin / U.S. dollar", "🪙"))
        self.assertEqual([b["text"] for b in first["badges"]], ["Bitstamp", "Crypto"])
        self.assertEqual(first["actions"][1]["url"], "https://www.tradingview.com/symbols/BITSTAMP-BTCUSD/")
        host, _, query, args = self.calls()[0]
        self.assertEqual((host, query["text"], query.get("search_type")), ("symbol-search.tradingview.com", "btc", None))
        self.assertIn("Origin: https://www.tradingview.com", args)
        self.assertEqual(self.hud(self.run_ext("add", context=first["actions"][0]["context"])), "Markets: added BITSTAMP:BTCUSD")
        self.assertEqual(self.watched()[-1], "pair:BITSTAMP:BTCUSD")
        again = self.run_ext("search", query="btc").items[0]
        self.assertIn({"text": "✓ followed", "tone": "fine"}, again["badges"])
        self.assertEqual(self.hud(self.run_ext("add", context=again["actions"][0]["context"])),
                         "Markets follows BITSTAMP:BTCUSD already")

    def test_a_leading_type_word_narrows_the_search(self):
        items = self.run_ext("search", query="crypto btc").items
        self.assertEqual(self.calls()[0][2]["search_type"], "crypto")
        self.assertEqual(self.calls()[0][2]["text"], "btc")
        self.assertEqual([i["title"] for i in items], ["BTCUSD", "BTCUSD", "BTCUSD"], "the coin pairs and the coin index")
        self.assertEqual([i["title"] for i in self.run_ext("search", query="futures btc").items], ["BTC1!"])

    def test_an_empty_search_shows_how_and_asks_nothing(self):
        items = self.run_ext("search", query="  ").items
        self.assertItemShape(items)
        self.assertIn("crypto", items[1]["title"])
        self.assertEqual(self.calls(), [])

    def test_search_offline_says_why_in_one_row(self):
        self.fake_curl(fail="(6) Could not resolve host: symbol-search.tradingview.com")
        items = self.run_ext("search", query="btc").items
        self.assertEqual([i["title"] for i in items], ["TradingView did not answer"])
        self.assertIn("Could not resolve host", items[0]["subtitle"])

    def test_the_page_searches_filters_adds_and_closes(self):
        page = self.page(pilot=self.PILOT)
        self.assertEqual(page[0]["action"]["command"], "find")
        self.assertEqual(self.hud(self.run_ext("find", input="btc")), "Markets: 6 found for btc")
        section = self.page(pilot=self.PILOT)[1]
        self.assertEqual((section["type"], section["title"], section["subtitle"]), ("section", "TradingView: “btc”", "6 found · every type"))
        filters, results = section["blocks"]
        self.assertEqual([a["title"] for a in filters["actions"]], ["Stocks", "Funds", "Crypto", "Forex", "Indices", "Futures"])
        self.assertEqual([i["title"] for i in results["items"]][-1], "Close the search")
        self.assertEqual([a["icon"] for a in results["items"][0]["inline"]], ["plus", "🌐"])
        self.run_ext("find", context={"type": "crypto"})
        self.assertEqual(self.calls()[-1][2]["search_type"], "crypto")
        section = self.page(pilot=self.PILOT)[1]
        self.assertEqual(section["subtitle"], "3 found · Crypto")
        self.assertEqual(section["blocks"][0]["actions"][2]["title"], "✓ Crypto")
        self.run_ext("find", context={"type": "crypto"})
        self.assertNotIn("search_type", self.calls()[-1][2], "the filter pressed again: every type")
        self.assertEqual(self.hud(self.run_ext("clear-search")), "Markets: search closed")
        self.assertNotIn("section", [b["type"] for b in self.page(pilot=self.PILOT)])

    def test_the_search_box_searches_as_sven_types_and_emptied_closes_the_search(self):
        box = self.page(pilot=self.PILOT)[0]
        self.assertEqual((box["type"], box["live"], box["action"]["command"]), ("input", True, "find"))
        self.assertNotIn("debounce", box, "Pilot's own pause")
        self.run_ext("find", input="btc")
        self.assertEqual(self.page(pilot=self.PILOT)[1]["type"], "section")
        self.assertEqual(self.hud(self.run_ext("find", input="  ")), "Markets: search closed")
        self.assertNotIn("section", [b["type"] for b in self.page(pilot=self.PILOT)])
        self.assertEqual(self.run_ext("find").of_type("error")[0]["text"], "type a symbol or a name to search, e.g. BTC or Apple",
                         "no input at all is no live run: said as before")

    def test_an_older_pilot_gets_no_search_box(self):
        self.assertNotIn("input", [b["type"] for b in self.page(pilot=self.OLDER)])

    def test_the_pages_rows_move_up_and_down_and_are_removed_in_place(self):
        rows = list(self.rows(self.page(pilot=self.PILOT)).values())
        self.assertEqual([a["icon"] for a in rows[0]["inline"]], ["arrow.down", "xmark"])
        self.assertEqual([a["icon"] for a in rows[1]["inline"]], ["arrow.up", "arrow.down", "xmark"])
        self.assertEqual([a["icon"] for a in rows[-1]["inline"]], ["arrow.up", "xmark"])
        self.assertTrue(rows[0]["inline"][-1]["destructive"])
        self.assertEqual(self.hud(self.run_ext("move", context=rows[0]["inline"][0]["context"])), "Markets: SPY moved down")
        self.assertEqual(self.watched(), ["stock:AAPL", "stock:SPY", "coin:BTC", "coin:ETH"])
        self.assertEqual(self.hud(self.run_ext("remove", context={"key": "coin:BTC"})), "Markets: removed BTC")
        self.assertEqual(self.watched(), ["stock:AAPL", "stock:SPY", "coin:ETH"])
        self.assertEqual(self.run_ext("move", context={"key": "stock:AAPL", "by": -1}).of_type("error")[0]["text"],
                         "can't move that symbol there")
        items = self.run_ext("markets").items
        self.assertEqual([a["title"] for a in items[0]["actions"]][-2:], ["Move AAPL down", "Remove AAPL from Markets"])

    def test_the_pages_rows_drag_into_order_by_their_key_and_new_place(self):
        page = self.page(pilot=self.PILOT)
        listed = next(b for b in page if b["type"] == "list")
        self.assertEqual(listed["reorder"], {"command": "move"})
        self.assertEqual([i["id"] for i in listed["items"]], ["stock:SPY", "stock:AAPL", "coin:BTC", "coin:ETH"])
        self.assertEqual(self.hud(self.run_ext("move", context={"key": "stock:SPY", "to": 2})), "Markets: SPY moved to 3")
        self.assertEqual(self.watched(), ["stock:AAPL", "coin:BTC", "stock:SPY", "coin:ETH"], "row 0 dropped on row 2")
        self.assertEqual(self.hud(self.run_ext("move", context={"key": "coin:ETH", "to": 0.0})), "Markets: ETH moved to 1")
        self.assertEqual(self.watched(), ["coin:ETH", "stock:AAPL", "coin:BTC", "stock:SPY"])
        self.assertEqual(self.hud(self.run_ext("move", context={"key": "coin:BTC", "to": 1})), "Markets: BTC moved up", "⌥↑ is one place")
        for odd in ({"key": "coin:ETH", "to": 4}, {"key": "coin:ETH", "to": -1}, {"key": "coin:ETH", "to": 0}, {"key": "coin:ETH", "to": 1.5},
                    {"key": "coin:ETH", "to": "2"}, {"key": "coin:ETH", "to": True}, {"key": "coin:SOL", "to": 1}):
            self.assertEqual(self.run_ext("move", context=odd).of_type("error")[0]["text"], "can't move that symbol there", odd)
        self.assertEqual(self.watched(), ["coin:ETH", "coin:BTC", "stock:AAPL", "stock:SPY"])
        popover = self.run_ext("bar", surface="popover", pilot=self.PILOT).of_type("blocks")[0]["blocks"]
        self.assertNotIn("reorder", next(b for b in popover if b["type"] == "list"), "rows drag on the page alone")

    def test_pairs_keep_their_own_figures_and_need_no_rate(self):
        none = {"symbols": " "}
        for symbol in (EURUSD, SPX, markets.picked(SEARCH["symbols"][0])):
            self.add(symbol, preferences=none)
        rows = self.rows(self.popover(preferences=none))
        self.assertEqual([r["title"] for r in rows.values()], ["EURUSD · 1.1239", "SPX · 7,659.44", "BTCUSD · $81,610"])
        self.assertEqual([r["icon"] for r in rows.values()], ["💱", "📊", "🪙"])
        self.assertEqual(self.asked(), ["tv-global-tickers"], "one call for every pair, no exchange rate")
        hero = self.page(preferences=dict(none, pinned="EURUSD"), pilot=self.PILOT)[1]
        self.assertEqual((hero["value"], hero.get("unit")), ("1.1239", "USD"))

    def test_nasdaq_says_a_pair_is_priced_on_tradingview_alone(self):
        self.add(EURUSD, preferences={"source": "nasdaq"})
        self.popover(preferences={"source": "nasdaq"})
        self.settle()
        row = self.rows(self.popover(preferences={"source": "nasdaq"}))["pair:FX:EURUSD"]
        self.assertIn("TradingView alone", row["subtitle"])
        self.assertEqual(row["actions"][0]["url"], "https://www.tradingview.com/symbols/FX-EURUSD/")

    def test_a_full_list_takes_no_more(self):
        self.bar(preferences={"symbols": " ".join("S%d" % i for i in range(12))})
        result = self.add(EURUSD, preferences={"symbols": " ".join("S%d" % i for i in range(12))})
        self.assertEqual(result.of_type("error")[0]["text"], "follows 12 symbols at most: remove one first")


def widget_row(ticker, close, change, change_abs, high, low, description, currency, kind, ranges):
    """A screener row with the widget's columns: the day's, then Perf.W, Perf.1M, Perf.Y and each span's high and low."""
    row = tv(ticker, ticker.split(":")[1], close, change, change_abs, high, low, description, currency, kind)
    (w, m, y), (wh, wl, mh, ml, yh, yl) = ranges
    return dict(row, d=row["d"] + [w, m, y, wh, wl, mh, ml, yh, yl])


WIDGET_ROWS = [widget_row("BITSTAMP:BTCUSD", 77907.05, 0.62, 480.0, 78500.0, 77000.0, "Bitcoin / U.S. dollar", "USD", "spot",
                          ((-3.6, -8.2, -28.8), (81971.0, 76325.98, 86968.58, 76172.75, 110750.0, 57800.19))),
               widget_row("NASDAQ:AAPL", 344.63, -1.23, -4.29, 349.19, 334.35, "Apple Inc.", "USD", "stock",
                          ((-1.28, 4.18, 26.7), (351.43, 334.35, 351.73, 325.81, 351.73, 243.42))),
               widget_row("FX:EURUSD", 1.11574, -0.2, -0.0022, 1.1189, 1.1150, "Euro / U.S. Dollar", "USD", "forex",
                          ((-0.51, -1.52, -3.52), (1.12266, 1.11043, 1.12853, 1.11043, 1.20828, 1.11043))),
               widget_row("SP:SPX", 7580.07, -1.82, -140.4, 7700.0, 7560.0, "S&P 500 Index", None, "index",
                          ((-0.75, -1.42, 10.49), (7758.43, 7527.56, 7844.52, 7527.56, 7844.52, 6316.91)))]
# Recorded on 2026-11-01 for the same asks, trimmed: CoinGecko's month of BTC, Nasdaq's month of AAPL closes, the ECB's
# month of EURUSD.
COIN_CHART = {"prices": [[1790974800000 + i * 3600000, 84428.5 - i * 20] for i in range(300)], "market_caps": [], "total_volumes": []}
NASDAQ_HISTORY = {"data": {"symbol": "AAPL", "totalRecords": 3, "tradesTable": {"asOf": None, "headers": {}, "rows": [
    {"date": "10/30/2026", "close": "$344.63", "volume": "67,841,560", "open": "$346.715", "high": "$349.19", "low": "$334.35"},
    {"date": "10/29/2026", "close": "$348.92", "volume": "51,002,100", "open": "$347.10", "high": "$350.00", "low": "$345.20"},
    {"date": "10/01/2026", "close": "$333.69", "volume": "48,113,900", "open": "$332.00", "high": "$335.10", "low": "$330.80"}]}},
    "message": None, "status": {"rCode": 200}}
FX_SERIES = {"amount": 1.0, "base": "EUR", "start_date": "2026-10-01", "end_date": "2026-10-30",
             "rates": {"2026-10-01": {"USD": 1.1225}, "2026-10-15": {"USD": 1.1208}, "2026-10-30": {"USD": 1.1172}}}
WIDGET_SYMBOLS = [{"kind": "pair", "symbol": "BTCUSD", "listing": "BITSTAMP:BTCUSD"},
                  {"kind": "stock", "symbol": "AAPL", "listing": "NASDAQ:AAPL"},
                  {"kind": "pair", "symbol": "EURUSD", "listing": "FX:EURUSD"},
                  {"kind": "pair", "symbol": "SPX", "listing": "SP:SPX"}]
KEYS = ["pair:BITSTAMP:BTCUSD", "stock:NASDAQ:AAPL", "pair:FX:EURUSD", "pair:SP:SPX"]


class WidgetTests(MarketsCase):
    """Pilot's Markets widget (Pilot P83): its symbols in the run's context, one screener call for every quote and its
    ranges, a line from the free source that keeps one, and TradingView's search."""

    def setUp(self):
        super().setUp()
        for name, body in {"tv-global": {"totalCount": 4, "data": WIDGET_ROWS}, "coin-chart": COIN_CHART,
                           "nasdaq-history": NASDAQ_HISTORY, "fx-series": FX_SERIES}.items():
            (self.fixtures / (name + ".json")).write_text(json.dumps(body))

    def answer(self, **context):
        result = self.run_ext("widget", context=context)
        self.assertEqual(result.of_type("error"), [], result.stdout)
        return result.of_type("data")[0]["data"]

    def test_one_call_prices_every_symbol_with_its_ranges_and_lines_come_where_history_is_free(self):
        data = self.answer(symbols=WIDGET_SYMBOLS, range="1M", lines=KEYS)
        self.assertEqual(sorted(data["quotes"]), sorted(KEYS))
        btc, aapl = data["quotes"]["pair:BITSTAMP:BTCUSD"], data["quotes"]["stock:NASDAQ:AAPL"]
        self.assertEqual((btc["price"], btc["asset"], btc["currency"], btc["type"]), (77907.05, "coin", "USD", "spot"))
        self.assertEqual(aapl["ranges"]["1M"], {"percent": 4.18, "high": 351.73, "low": 325.81})
        self.assertEqual(data["quotes"]["pair:SP:SPX"]["ranges"]["1Y"], {"percent": 10.49, "high": 7844.52, "low": 6316.91})
        self.assertEqual(self.asked(), ["AAPL/stocks", "fx", "market_chart", "tv-global-tickers"], "Nasdaq's history of AAPL")
        self.assertIn('"Perf.1M"', next(a for h, _, _, a in self.calls() if h == "scanner.tradingview.com"))
        lines = data["lines"]
        self.assertEqual(len(lines["pair:BITSTAMP:BTCUSD"]), 120, "cut to the chart's points, the latest kept")
        self.assertEqual(lines["pair:BITSTAMP:BTCUSD"][-1][1], 84428.5 - 299 * 20)
        self.assertEqual([p[1] for p in lines["stock:NASDAQ:AAPL"]], [333.69, 348.92, 344.63], "oldest first")
        self.assertEqual([p[1] for p in lines["pair:FX:EURUSD"]], [1.1225, 1.1208, 1.1172])
        self.assertEqual(data["errors"], {"pair:SP:SPX": "no free history for SP:SPX"})
        chart = next(q for h, p, q, _ in self.calls() if p.endswith("/market_chart"))
        self.assertEqual(chart, {"vs_currency": "usd", "days": "30"})

    def test_a_currency_pairs_day_has_no_line_and_a_quote_alone_asks_no_history(self):
        data = self.answer(symbols=WIDGET_SYMBOLS, range="1D", lines=["pair:FX:EURUSD"])
        self.assertEqual((data["lines"], data["errors"]), ({}, {"pair:FX:EURUSD": "no history for EURUSD over 1D"}))
        self.assertEqual(self.asked(), ["tv-global-tickers"])
        self.assertEqual(self.answer(symbols=WIDGET_SYMBOLS[:1])["lines"], {})

    def test_offline_every_symbol_says_why(self):
        self.fake_curl(fail="(6) Could not resolve host: scanner.tradingview.com")
        data = self.answer(symbols=WIDGET_SYMBOLS[:2], range="1W", lines=KEYS[:1])
        self.assertEqual(data["quotes"], {})
        self.assertEqual(sorted(data["errors"]), KEYS[:2])
        self.assertTrue(data["errors"]["stock:NASDAQ:AAPL"].startswith("TradingView: (6) Could not resolve host"))

    def test_search_answers_listings_and_an_empty_one_asks_nothing(self):
        found = self.answer(search="btc")["found"]
        self.assertEqual([f["key"] for f in found], ["pair:BITSTAMP:BTCUSD", "pair:COINBASE:BTCUSD", "pair:INDEX:BTCUSD",
                                                    "pair:CME:BTC1!", "stock:AMEX:BTC", "stock:LSE:BTC"])
        self.assertEqual((found[0]["name"], found[0]["where"], found[0]["type"]), ("Bitcoin / U.S. dollar", "Bitstamp", "spot"))
        self.assertEqual(self.answer(search=" ")["found"], [])
        self.assertEqual(len(self.calls()), 1)


class MarketWords(unittest.TestCase):
    """The parts that need no network or clock: symbols, New York's session, the figures and the line."""

    def test_symbols(self):
        found = markets.symbols("spy, AAPL btc;ETH, coin:kas stock:ETH, BTC, bad$sym, ")
        self.assertEqual([s["key"] for s in found], ["stock:SPY", "stock:AAPL", "coin:BTC", "coin:ETH", "coin:KAS", "stock:ETH"])
        self.assertEqual(len(markets.symbols(" ".join("S%d" % i for i in range(20)))), 12)

    def test_search_words_and_picks(self):
        self.assertEqual(markets.search_words(" Crypto  sol "), ("sol", "crypto"))
        self.assertEqual(markets.search_words("etf"), ("etf", ""), "a type word alone is searched for")
        self.assertEqual(markets.search_words("fx eur usd"), ("eur usd", "forex"))
        future = markets.picked(SEARCH["symbols"][3])
        self.assertEqual((future["key"], future["symbol"], future["where"]), ("pair:CME:BTC1!", "BTC1!", "CME"))
        self.assertEqual(markets.picked(SEARCH["symbols"][4])["key"], "stock:AMEX:BTC")
        self.assertIsNone(markets.entry({"kind": "pair", "symbol": "EURUSD"}), "a pair names its listing")
        self.assertIsNone(markets.entry({"kind": "stock", "symbol": "AAPL", "listing": "NASDAQ:MSFT"}))
        self.assertEqual(markets.rate_figure(1.12385), "1.1239")
        self.assertEqual(markets.rate_figure(150.1234), "150.123")

    def test_a_stock_is_asked_every_five_minutes_in_session_and_once_after_each_close(self):
        def due(now, fetched, key="stock:SPY", **extra):
            return markets.due(key.split(":")[0], dict({"quote": {}, "fetchedAt": fetched, "triedAt": fetched}, **extra), now)
        thursday_noon = ny(2026, 10, 15, 12)
        self.assertFalse(due(thursday_noon, thursday_noon - 200))
        self.assertTrue(due(thursday_noon, thursday_noon - 400))
        self.assertTrue(due(ny(2026, 10, 15, 16, 10), ny(2026, 10, 15, 16, 1)), "the closing prints still settle")
        self.assertTrue(due(ny(2026, 10, 15, 18), ny(2026, 10, 15, 16, 10)), "asked once after they settled")
        self.assertFalse(due(ny(2026, 10, 15, 23), ny(2026, 10, 15, 18)))
        self.assertFalse(due(ny(2026, 10, 18, 12), ny(2026, 10, 16, 17)), "a Sunday asks nothing after Friday's close")
        self.assertTrue(due(ny(2026, 10, 19, 9, 40), ny(2026, 10, 16, 17)), "Monday's session")
        self.assertTrue(due(ny(2026, 10, 18, 12), ny(2026, 10, 18, 11), key="coin:BTC:eur"), "a coin never closes")
        self.assertFalse(due(thursday_noon, 0, error="x", triedAt=thursday_noon - 30), "a minute after a failure")
        self.assertTrue(markets.due("stock", {}, thursday_noon))

    def test_a_holiday_is_asked_once_into_the_session_then_not_till_the_close(self):
        thanksgiving_noon = ny(2026, 11, 26, 12)
        record = {"quote": {"asOf": ny(2026, 11, 25, 20)}, "fetchedAt": ny(2026, 11, 26, 9, 35)}
        self.assertTrue(markets.due("stock", record, thanksgiving_noon), "five minutes in: not yet known")
        record["fetchedAt"] = ny(2026, 11, 26, 9, 45)
        self.assertFalse(markets.due("stock", record, thanksgiving_noon), "no minute today at 09:45: shut")
        record["quote"]["asOf"] = ny(2026, 11, 26, 9, 44)
        self.assertTrue(markets.due("stock", record, thanksgiving_noon), "a trading day")

    def test_market_line_in_the_macs_time(self):
        with mock.patch.dict(os.environ, {"TZ": "Europe/Malta"}):
            time.tzset()
            self.addCleanup(time.tzset)
            self.assertEqual(markets.market_line(ny(2026, 10, 15, 12))[:21], "US market open until ")
            self.assertRegex(markets.market_line(ny(2026, 10, 17, 12)), r"^US market closed · opens (Mon )?15:30$")
            self.assertRegex(markets.market_line(ny(2026, 10, 15, 8)), r"^US market closed · opens (Thu )?15:30$")
            self.assertRegex(markets.market_line(ny(2026, 10, 16, 17)), r"^US market closed · opens (Mon )?15:30$")

    def test_figures(self):
        self.assertEqual([markets.figure(v) for v in (73093, 342.0, 0.0612345)], ["73,093", "342.00", "0.06123"])
        self.assertEqual([markets.short(v) for v in (73093, 688.6, 4.2)], ["73.1k", "689", "4.20"])
        self.assertEqual([markets.amount(v) for v in (0.5376, 1196.7, 0.004321)], ["0.54", "1,196.70", "0.004321"])
        self.assertEqual([markets.change(v) for v in (1.4381, -0.28, 0.001, None)], ["▲ 1.44%", "▼ 0.28%", "0.00%", "–"])
        self.assertEqual([markets.tone(v) for v in (1, -1, 0.004)], ["fine", "alert", None])
        self.assertEqual([markets.number(v) for v in ("$1,342.00", "+2.19", "-0.28%", "UNCH", "N/A")], [1342, 2.19, -0.28, 0, None])

    def test_spark_and_thin(self):
        self.assertEqual(markets.spark([1, 2, 3, 4, 5, 6, 7, 8]), "▁▂▃▄▅▆▇█")
        self.assertEqual(markets.spark([5, 5, 5]), "▄▄▄")
        self.assertEqual(markets.spark([5]), "")
        self.assertEqual(markets.thin(list(range(100)), 4), [24, 49, 74, 99])


if __name__ == "__main__":
    unittest.main()
