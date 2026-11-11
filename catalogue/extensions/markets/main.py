#!/usr/bin/env python3
"""Markets for Pilot: stocks, ETFs and coins and their day's change in the menu bar; its popover and page list every
symbol with its price, its change and a spark line of the day (Surfaces v2, Pilot story 165), and Hyper+Space's Markets
lists the same rows. Each row opens the symbol's page on the source the prices come from.

Sources, free and keyless, picked in the settings:
- TradingView (the default): its screener API (scanner.tradingview.com, the one tradingview.com's screener reads), one
  call for every stock and ETF on any exchange and one for every coin pair in the currency asked. A bare ticker is the
  listing traded most (AAPL is NASDAQ:AAPL), XETR:VWCE names one. It keeps no history, so a row's line is drawn from the
  prices this extension read through the day, and grows as it reads them. A coin's change is since 00:00 UTC.
- Nasdaq and CoinGecko: stocks and ETFs listed in the US from Nasdaq's quote API (it answers only a browser's
  User-Agent), one call a symbol with the day's minutes; coins from CoinGecko, one call for all, their change over 24 h.
Other currencies come from the ECB's daily rates through Frankfurter, so a converted price is near (≈) and its change in
percent the exchange's own. Yahoo Finance is left out: it refuses this machine (429) and has broken often for others.

Every network call runs in a detached child (`main.py --refresh`, one at a time under refresh.lock) through curl, so a
slow network never holds a view past Pilot's limit (Weather's way). A coin is due after FRESH s; a stock after FRESH s
while its session may run (Nasdaq: New York's 09:30 to 16:00; TradingView, whose listings span Europe and the US: 03:00
to 16:00 New York), closing prints SETTLE s later, and otherwise once after each close, so a closed market costs
nothing. On Nasdaq a holiday shows itself when an answer 10 minutes into the session holds no minute of that day. A
failed symbol keeps its last answer, marked old, and is not asked again for RETRY s.

The menu bar shows one or several symbols (side by side, or one a minute in turn) as text, as text with the day's line,
or as mini bars: one of Pilot's gauges a symbol, its meter where the price stands in the day's range, in its own tone.

The symbols followed are a list kept in the data folder (watchlist.json), seeded from the Symbols setting; an edit of
that setting replaces it. TradingView's symbol search (the one tradingview.com's search box reads) adds to it, from
Hyper+Space's Add to Markets, which asks as Sven types, or the page's search box, which searches as he types too (Pilot's
live input) and whose answer the page then draws; the page's rows are dragged into order (Pilot's reorder) or moved up and
down, and removed in place. A listing picked there that is not a stock or a fund (a coin pair,
a currency pair, an index, a future) is a pair: priced in its own figures, never converted, and on TradingView only.
"""
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from urllib.parse import quote, urlencode
from zoneinfo import ZoneInfo

FRESH = 5 * 60
RETRY = 60
FX_FRESH = 12 * 3600  # the ECB sets its rates once a working day
SETTLE = 20 * 60
DAY = 24 * 3600
CURL_TIMEOUT = 8
BUDGET = {"bar": 1.5, "popover": 3.5, "page": 3.5, "list": 1.5}  # seconds a view waits for a fetch; Pilot's limits 2, 5, 5, 2
REFRESH_BUDGET = 25  # Refresh is a no-view run, stopped at 30 s
REFRESH_SOON = 3  # a view whose fetch still runs asks again this many seconds later
MOST = 12  # symbols asked
SPARK = 16  # a row's line, in bars
BAR_SPARK = 6  # the menu bar's line
LONGEST = 24  # Pilot's bar text
GAUGES = 3  # Pilot's gauges a bar item
GAUGE_TEXT = 6
GAUGE_LABEL = 5  # Pilot's gauge label since 2026-10-16; an older Pilot cuts it to two
BARS = "▁▂▃▄▅▆▇█"
QUOTES = "quotes.json"
NAMES = "names.json"
FX = "fx.json"
TURN = "turn.json"
LOCK = "refresh.lock"
WATCHLIST = "watchlist.json"  # in the data folder: the symbols followed
FOUND = "search.json"  # in the cache: the page's last search
FOUND_FOR = 30 * 60  # the page shows its last search this long
FOUND_ROWS = 20
SEARCH_BUDGET = 1.3  # Hyper+Space's search asks within Pilot's 2 s
SEARCH_API = "https://symbol-search.tradingview.com/symbol_search/v3/"
SEARCH_HEADERS = ["Origin: https://www.tradingview.com", "Referer: https://www.tradingview.com/"]
# TradingView's search filters (search_type), in the page's order, and the words that pick one in Hyper+Space's search.
FILTERS = {"stocks": "Stocks", "funds": "Funds", "crypto": "Crypto", "forex": "Forex", "index": "Indices",
           "futures": "Futures"}
FILTER_WORDS = {"stock": "stocks", "stocks": "stocks", "fund": "funds", "funds": "funds", "etf": "funds", "etfs": "funds",
                "crypto": "crypto", "coin": "crypto", "coins": "crypto", "fx": "forex", "forex": "forex", "index": "index",
                "indices": "index", "future": "futures", "futures": "futures"}
ASSET_WORDS = {"stocks": "Stock", "etf": "Fund", "coin": "Crypto", "forex": "Forex", "index": "Index", "futures": "Futures"}
ASSETS = {"stock": "stocks", "dr": "stocks", "fund": "etf", "spot": "coin", "crypto": "coin", "forex": "forex",
          "index": "index", "futures": "futures"}
STOCK_TYPES = [t for t, a in ASSETS.items() if a in ("stocks", "etf")]  # picked, a stock in the currency asked; the rest pairs
FILTER_ASSETS = {"stocks": "stocks", "funds": "etf", "crypto": "coin", "forex": "forex", "index": "index", "futures": "futures"}
AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
NASDAQ = "https://api.nasdaq.com/api/quote/%s/chart?assetclass=%s"
COINS_API = "https://api.coingecko.com/api/v3/coins/markets"
COIN_SEARCH = "https://api.coingecko.com/api/v3/search"
SCANNER = "https://scanner.tradingview.com/%s/scan"
FX_API = "https://api.frankfurter.dev/v1/latest"
NEW_YORK = ZoneInfo("America/New_York")
SYMBOL = re.compile(r"[A-Z0-9][A-Z0-9.\-]{0,11}\Z")
TICKER = re.compile(r"[A-Z0-9][A-Z0-9.\-_!]{0,19}\Z")  # a search pick's symbol: a future's continuous ES1! too
EXCHANGE = re.compile(r"[A-Z][A-Z0-9_]{0,19}\Z")
# The coins a bare symbol means, by CoinGecko id; any other is a stock unless written coin:XYZ (stock:XYZ forces a
# stock: ETH is also Ethan Allen's ticker).
COINS = {"BTC": "bitcoin", "ETH": "ethereum", "SOL": "solana", "XRP": "ripple", "BNB": "binancecoin", "DOGE": "dogecoin",
         "ADA": "cardano", "TRX": "tron", "AVAX": "avalanche-2", "DOT": "polkadot", "LINK": "chainlink", "LTC": "litecoin",
         "BCH": "bitcoin-cash", "XLM": "stellar", "TON": "the-open-network", "SHIB": "shiba-inu", "SUI": "sui",
         "HBAR": "hedera-hashgraph", "UNI": "uniswap", "ATOM": "cosmos", "XMR": "monero", "NEAR": "near", "APT": "aptos",
         "PEPE": "pepe", "HYPE": "hyperliquid", "USDT": "tether", "USDC": "usd-coin"}
# Where a coin pair is read on TradingView, the first that lists it in the currency asked.
COIN_EXCHANGES = ["COINBASE", "KRAKEN", "BITSTAMP", "BINANCE", "BITVAVO", "GEMINI", "BITFINEX", "OKX", "BYBIT"]
TV_COLUMNS = ["name", "close", "change", "change_abs", "high", "low", "description", "currency", "type", "exchange"]
MONEY = {"eur": "€", "usd": "$", "gbp": "£", "chf": "CHF "}
KINDS = {"stocks": "🏢", "etf": "🧺", "coin": "🪙", "forex": "💱", "index": "📊", "futures": "📜", "other": "📈"}
# Each source: its short name in a kept record's key, when its stocks' session may open (New York time), whether it
# knows a holiday, and per kind the site a row opens and what a move is measured over.
STOCK_WORDS = {"badge": "", "window": "Today", "range": "Day range"}
SOURCES = {
    "tradingview": {"tag": "tv", "name": "TradingView", "session": (3, 0), "holidays": False,
                    "words": {"stock": dict(STOCK_WORDS, site="TradingView"),
                              "coin": {"badge": "", "window": "Since 00:00 UTC", "range": "Day range", "site": "TradingView"}},
                    "credit": "Prices from [TradingView](https://www.tradingview.com/), some exchanges delayed"},
    "nasdaq": {"tag": "nq", "name": "Nasdaq · CoinGecko", "session": (9, 30), "holidays": True,
               "words": {"stock": dict(STOCK_WORDS, site="Nasdaq"),
                         "coin": {"badge": " 24h", "window": "24h", "range": "24h range", "site": "CoinGecko"}},
               "credit": "Stocks and ETFs from [Nasdaq](https://www.nasdaq.com/), may be delayed; coins from "
                         "[CoinGecko](https://www.coingecko.com/)"},
}
FX_CREDIT = "; currencies from the ECB through [Frankfurter](https://frankfurter.dev/)."


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


def load(folder, name):
    try:
        with open(os.path.join(folder, name), encoding="utf-8") as f:
            value = json.load(f)
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def save(folder, name, value):
    path = os.path.join(folder, name)
    temp = "%s.%d.tmp" % (path, os.getpid())
    with open(temp, "w", encoding="utf-8") as f:
        json.dump(value, f, ensure_ascii=False)
    os.replace(temp, path)


# ---- what is asked ----

def words(text):
    return [w for w in re.split(r"[\s,;]+", str(text or "").upper()) if w]


def symbols(text):
    """[{"key", "kind", "symbol", "listing"}] in the order typed, at most MOST: a known coin's symbol (or coin:XYZ) a coin,
    any other (or stock:XYZ) a stock or an ETF, EXCHANGE:XYZ that listing on TradingView; one that cannot be is skipped."""
    found, seen = [], set()
    for word in words(text):
        prefix, _, name = word.rpartition(":")
        listing = None
        if prefix in ("COIN", "STOCK"):
            kind = prefix.lower()
        elif prefix:
            kind, listing = ("stock", word) if EXCHANGE.match(prefix) else (None, None)
        else:
            kind = "coin" if name in COINS else "stock"
        key = "%s:%s" % (kind, listing or name)
        if not kind or not SYMBOL.match(name) or key in seen:
            continue
        seen.add(key)
        found.append({"key": key, "kind": kind, "symbol": name, "listing": listing})
    return found[:MOST]


def entry(value):
    """A symbol followed as kept or handed on in a context, checked: {"key", "kind", "symbol", "listing"} and, from a
    search, its "type" and "name"; None when it does not read. A pair always names its listing."""
    if not isinstance(value, dict):
        return None
    kind, symbol, listing = value.get("kind"), value.get("symbol"), value.get("listing")
    if kind not in ("stock", "coin", "pair") or not isinstance(symbol, str) or not TICKER.match(symbol):
        return None
    if listing is not None:
        prefix, _, name = str(listing).rpartition(":")
        if not EXCHANGE.match(prefix) or name != symbol:
            return None
    elif kind == "pair":
        return None
    found = {"key": "%s:%s" % (kind, listing or symbol), "kind": kind, "symbol": symbol, "listing": listing}
    for extra in ("type", "name", "where"):
        if isinstance(value.get(extra), str) and value[extra]:
            found[extra] = value[extra][:80]
    return found


def asset_of(symbol):
    """What a followed symbol is before a price says: a coin, else its search type's (a stock, a fund, a pair's)."""
    if symbol["kind"] == "coin":
        return "coin"
    return ASSETS.get(symbol.get("type"), "stocks" if symbol["kind"] == "stock" else "other")


def data_dir(run):
    """Pilot's data folder for this extension; None when Pilot sent none."""
    folder = (run.get("paths") or {}).get("data")
    return folder if isinstance(folder, str) and folder else None


def watchlist(run):
    """The symbols followed, in order: the list kept, or the Symbols setting's when none is kept or that setting was
    edited since (an edit there replaces the list; Markets 1.1's setting is read this way the first time)."""
    text = str((run.get("preferences") or {}).get("symbols") or "")
    folder = data_dir(run)
    kept = load(folder, WATCHLIST) if folder else {}
    if kept.get("from") == text and isinstance(kept.get("symbols"), list):
        return [e for e in map(entry, kept["symbols"]) if e][:MOST]
    listed = symbols(text)
    keep(run, listed)
    return listed


def keep(run, listed):
    """Keeps `listed` as the symbols followed, with the setting's text it stands for."""
    try:
        folder = data_dir(run)
        if folder:
            os.makedirs(folder, exist_ok=True)
            save(folder, WATCHLIST, {"from": str((run.get("preferences") or {}).get("symbols") or ""), "symbols": listed})
            return True
    except OSError:
        pass
    return False


def settings(run):
    """What to ask, from where, in which money, and how the bar shows it: its symbols (the first when none named is
    listed), side by side or in turn, its style and its parts."""
    prefs = run.get("preferences") or {}
    listed = watchlist(run)
    named = words(prefs.get("pinned"))
    pinned = []
    for word in named:
        pinned += [s["key"] for s in listed if word in (s["symbol"], s["key"].upper(), s["listing"]) and s["key"] not in pinned]
    pinned = pinned or [s["key"] for s in listed[:1]]
    show = {part: prefs.get(name, default) is not False for part, name, default in
            (("symbol", "showSymbol", True), ("price", "showPrice", False), ("percent", "showPercent", True),
             ("change", "showChange", False))}
    choice = lambda name, allowed, default: prefs.get(name) if prefs.get(name) in allowed else default
    return {"symbols": listed, "source": choice("source", SOURCES, "tradingview"), "currency": choice("currency", MONEY, "eur"),
            "pinned": pinned, "style": choice("style", ("text", "line", "bars"), "text"), "rotate": prefs.get("several") == "rotate",
            "show": show}


def record_key(symbol, want):
    """Where a symbol's answer is kept, per source: a stock's or a pair's in its listing's money, a coin's in the
    currency asked."""
    key = "%s:%s" % (SOURCES[want["source"]]["tag"], symbol["key"])
    return key if symbol["kind"] != "coin" else "%s:%s" % (key, want["currency"])


# ---- sessions ----

def session(day, opens=(9, 30)):
    """(opens, closes at 16:00) in New York on `day`, a date, or None on a weekend (holidays not known)."""
    if day.weekday() >= 5:
        return None
    at = lambda h, m: datetime(day.year, day.month, day.day, h, m, tzinfo=NEW_YORK).timestamp()
    return at(*opens), at(16, 0)


def ny_day(now):
    return datetime.fromtimestamp(now, NEW_YORK).date()


def in_session(now, settle=SETTLE, opens=(9, 30)):
    """Whether a session opening at `opens` New York time runs at `now` (seconds since 1970), `settle` s after its close
    included."""
    hours = session(ny_day(now), opens)
    return bool(hours) and hours[0] <= now < hours[1] + settle


def last_settled(now):
    """When the last close's prints settled, at or before `now`: a session's close plus SETTLE."""
    for back in range(8):
        hours = session(ny_day(now) - timedelta(days=back))
        if hours and hours[1] + SETTLE <= now:
            return hours[1] + SETTLE
    return 0


def market_line(now):
    """The US market open until its close, or closed until its next open, in the Mac's own time."""
    day = ny_day(now)
    hours = session(day)
    if in_session(now, settle=0):
        return "US market open until %s" % clock(hours[1])
    while not hours or hours[0] <= now:
        day += timedelta(days=1)
        hours = session(day)
    return "US market closed · opens %s" % clock(hours[0])


def resting(record, now):
    """A failed try is not repeated for RETRY s."""
    return bool(record.get("error")) and now - (record.get("triedAt") or 0) < RETRY


def due(kind, record, now, source="nasdaq"):
    """Whether a kept answer is asked again: none kept, a coin's or a pair's after FRESH s, a stock's after FRESH s while
    its session may run or once after each close; never while resting."""
    if resting(record, now):
        return False
    if "quote" not in record:
        return True
    fetched = record.get("fetchedAt") or 0
    if kind != "stock":
        return now - fetched >= FRESH
    running = in_session(now, opens=SOURCES[source]["session"]) and now - fetched >= FRESH
    return (running and not (SOURCES[source]["holidays"] and holiday(record, now))) or fetched < last_settled(now)


def holiday(record, now):
    """A session day the market keeps shut: asked 10 minutes into it, Nasdaq still had no minute from that day."""
    opens = session(ny_day(now))[0]
    as_of = (record.get("quote") or {}).get("asOf")
    return bool(as_of) and (record.get("fetchedAt") or 0) >= opens + 600 and ny_day(as_of) != ny_day(now)


def fx_pairs(want, quotes):
    """The rates the kept quotes need: each money a quote is in that is not the currency asked, as "USD:EUR"."""
    asked = want["currency"].upper()
    found = {(quotes.get(record_key(s, want)) or {}).get("quote", {}).get("currency") for s in want["symbols"]
             if s["kind"] == "stock"}
    return sorted("%s:%s" % (c, asked) for c in found if isinstance(c, str) and c and c != asked)


def fx_due(pair, fx, now, force=False):
    record = fx.get(pair) or {}
    return force or (not resting(record, now) and now - (record.get("fetchedAt") or 0) >= FX_FRESH)


# ---- asking ----

def curl(url, browser=False, body=None, headers=(), timeout=CURL_TIMEOUT):
    """(parsed JSON, None) or (None, why); `browser` sends a browser's User-Agent, which Nasdaq answers alone; `body`
    is POSTed as JSON; `headers` are sent as they are; it gives up after `timeout` s. The URL is curl's last argument."""
    binary = shutil.which("curl") or "/usr/bin/curl"
    extra = ["-A", AGENT, "-H", "Accept: application/json"] if browser else []
    for header in headers:
        extra += ["-H", header]
    if body is not None:
        extra += ["-H", "Content-Type: application/json", "--data-binary", json.dumps(body, separators=(",", ":"))]
    try:
        done = subprocess.run([binary, "-sS", "--fail", "--compressed", "--max-time", str(timeout)] + extra + [url],
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout + 0.5)
    except (OSError, subprocess.TimeoutExpired):
        return None, "could not reach it"
    if done.returncode != 0:
        said = done.stderr.decode("utf-8", "replace").strip().splitlines()
        return None, (said[-1] if said else "no answer").replace("curl: ", "")[:160]
    try:
        return json.loads(done.stdout.decode("utf-8")), None
    except ValueError:
        return None, "its answer did not read"


def number(value):
    """A figure as Nasdaq writes it ("$1,342.00", "+2.19", "-0.28%", "UNCH"), or as a number; None when there is none."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value or "").replace("$", "").replace(",", "").replace("%", "").strip()
    if text.upper() == "UNCH":
        return 0.0
    try:
        return float(text)
    except ValueError:
        return None


def thin(values, count=SPARK):
    """`values` cut to `count`, each the last of its stretch, so the line ends on the latest."""
    if len(values) <= count:
        return list(values)
    return [values[int((i + 1) * len(values) / count) - 1] for i in range(count)]


# Nasdaq and CoinGecko

def stock_quote(data, asset):
    """Nasdaq's chart answer as kept: name, price, change, percent, previous close, the session's low, high and line, and
    when its last minute was."""
    price = number(data.get("lastSalePrice"))
    if price is None:
        return None
    points = [(p["x"] / 1000.0, number(p.get("y"))) for p in data.get("chart") or []
              if isinstance(p, dict) and isinstance(p.get("x"), (int, float))]
    points = [(t, y) for t, y in points if y is not None]
    hours = session(ny_day(points[-1][0])) if points else None
    regular = [y for t, y in points if hours and hours[0] <= t <= hours[1]]  # 09:30 to the 16:00 minute
    line = regular or [y for _, y in points]
    previous = number(data.get("previousClose"))
    change = number(data.get("netChange"))
    percent = number(data.get("percentageChange"))
    if percent is None and change is not None and previous:
        percent = change / previous * 100
    name = str(data.get("company") or "")
    for tail in (" Common Stock", " Ordinary Shares", " American Depositary Shares", " Class A", " Class B"):
        name = name.split(tail)[0]
    return {"name": name.strip(), "price": price, "change": change, "percent": percent, "previous": previous,
            "low": min(line) if line else None, "high": max(line) if line else None, "line": thin(line),
            "asOf": points[-1][0] if points else None, "asset": asset, "currency": "USD"}


def fetch_stock(symbol, asset):
    """(quote, None) or (None, why): the asset class Nasdaq files it under when known, else stocks and then ETFs."""
    for each in [asset] if asset else ["stocks", "etf"]:
        answer, error = curl(NASDAQ % (quote(symbol, safe=""), each), browser=True)
        if error:
            return None, "Nasdaq: %s" % error
        data = answer.get("data") if isinstance(answer, dict) else None
        if isinstance(data, dict):
            found = stock_quote(data, each)
            return (found, None) if found else (None, "Nasdaq sent no price for %s" % symbol)
    return None, "Nasdaq knows no %s" % symbol


def coin_id(symbol, names):
    """(CoinGecko's id for a coin's symbol, None) or (None, why): a known coin's, one found before, else the coin with
    that symbol CoinGecko ranks highest."""
    if symbol in COINS:
        return COINS[symbol], None
    if "cg:" + symbol in names:
        return names["cg:" + symbol], None
    answer, error = curl(COIN_SEARCH + "?" + urlencode({"query": symbol}))
    if error:
        return None, "CoinGecko: %s" % error
    found = [c for c in (answer or {}).get("coins") or [] if isinstance(c, dict) and str(c.get("symbol", "")).upper() == symbol
             and isinstance(c.get("id"), str)]
    if not found:
        return None, "CoinGecko knows no %s" % symbol
    best = min(found, key=lambda c: c.get("market_cap_rank") if isinstance(c.get("market_cap_rank"), int) else 1 << 30)
    names["cg:" + symbol] = best["id"]
    return best["id"], None


def coin_quote(row, currency):
    """A CoinGecko markets row as kept; its line is the last 24 of the week's hours (CoinGecko draws it in dollars:
    the line's shape, never its figures)."""
    price = number(row.get("current_price"))
    if price is None:
        return None
    week = [number(v) for v in ((row.get("sparkline_in_7d") or {}).get("price") or [])]
    try:
        stamp = datetime.strptime(str(row.get("last_updated"))[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        stamp = None
    return {"name": str(row.get("name") or ""), "price": price, "change": number(row.get("price_change_24h")),
            "percent": number(row.get("price_change_percentage_24h")), "low": number(row.get("low_24h")),
            "high": number(row.get("high_24h")), "line": thin([v for v in week if v is not None][-24:]), "asOf": stamp,
            "id": row.get("id"), "asset": "coin", "currency": currency.upper()}


def fetch_coins(coins, currency, names):
    """{symbol: (quote, None) or (None, why)} for `coins`, one markets call for all."""
    found, ids = {}, {}
    for symbol in coins:
        cid, error = coin_id(symbol, names)
        if error:
            found[symbol] = (None, error)
        else:
            ids[cid] = symbol
    if not ids:
        return found
    answer, error = curl(COINS_API + "?" + urlencode({"vs_currency": currency, "ids": ",".join(sorted(ids)), "sparkline": "true"}))
    rows = {r.get("id"): r for r in answer if isinstance(r, dict)} if isinstance(answer, list) else {}
    if not error and not isinstance(answer, list):
        error = "its answer did not read"
    for cid, symbol in ids.items():
        made = coin_quote(rows[cid], currency) if cid in rows else None
        found[symbol] = (made, None) if made else (None, "CoinGecko: %s" % error if error else "CoinGecko sent no %s" % symbol)
    return found


def nasdaq_fetch(asked, want, names):
    """{record key: (quote, None) or (None, why)}: each stock its own call, side by side, the coins one call; a pair
    neither knows."""
    from concurrent.futures import ThreadPoolExecutor  # the child's alone: a view never pays for it

    stocks = [s for s in asked if s["kind"] == "stock"]
    coins = [s for s in asked if s["kind"] == "coin"]
    with ThreadPoolExecutor(max_workers=len(stocks) + 1) as pool:
        coin_job = pool.submit(fetch_coins, [s["symbol"] for s in coins], want["currency"], names) if coins else None
        jobs = {record_key(s, want): pool.submit(fetch_stock, s["symbol"], names.get(record_key(s, want))) for s in stocks}
        answers = {key: job.result() for key, job in jobs.items()}
        answers.update((record_key(s, want), (None, "TradingView alone prices it: pick it under Prices from"))
                       for s in asked if s["kind"] == "pair")
        if coin_job:
            found = coin_job.result()
            answers.update((record_key(s, want), found[s["symbol"]]) for s in coins)
    for s in stocks:
        made = answers[record_key(s, want)][0]
        if made:
            names[record_key(s, want)] = made["asset"]
    return answers


# TradingView

def tv_quote(ticker, row, coin):
    """A screener row as kept; its previous close is its price less the day's change."""
    d = dict(zip(TV_COLUMNS, row))
    price = number(d.get("close"))
    if price is None:
        return None
    change = number(d.get("change_abs"))
    asset = "coin" if coin else ASSETS.get(d.get("type"), "stocks")
    return {"name": str(d.get("description") or d.get("name") or ""), "price": price, "change": change,
            "percent": number(d.get("change")), "previous": None if asset == "coin" or change is None else price - change,
            "low": number(d.get("low")), "high": number(d.get("high")), "ticker": ticker, "asset": asset,
            "currency": str(d.get("currency") or "").upper() or None}


def scan(market, body, columns=TV_COLUMNS):
    """The screener's rows for `body` on `market` (global, crypto) as [(ticker, row)], in its order; or (None, why)."""
    answer, error = curl(SCANNER % market, body=dict(body, columns=columns))
    if error:
        return None, "TradingView: %s" % error
    rows = answer.get("data") if isinstance(answer, dict) else None
    if not isinstance(rows, list):
        return None, "TradingView: its answer did not read"
    return [(r["s"], r["d"]) for r in rows if isinstance(r, dict) and isinstance(r.get("s"), str)
            and isinstance(r.get("d"), list) and len(r["d"]) == len(columns)], None


def tv_market(market, asks, pick, coin):
    """{key: (quote, None) or (None, why)} for `asks` ({key: (name, ticker or None)}) on one market: the tickers known
    in one call, the names not yet placed in another, each placed on the listing `pick` chooses from the screener's
    rows for its name (the most traded first)."""
    found = {}
    known = {k: t for k, (_, t) in asks.items() if t}
    if known:
        rows, error = scan(market, {"symbols": {"tickers": sorted(set(known.values()))}})
        by_ticker = dict(rows or [])
        for key, ticker in known.items():
            made = tv_quote(ticker, by_ticker[ticker], coin) if ticker in by_ticker else None
            found[key] = (made, None) if made else (None, error or "TradingView knows no %s" % ticker)
    unknown = {k: n for k, (n, t) in asks.items() if not t}
    if unknown:
        rows, error = scan(market, {"filter": [{"left": "name", "operation": "in_range", "right": sorted(set(unknown.values()))}],
                                    "sort": {"sortBy": "Value.Traded", "sortOrder": "desc"}, "range": [0, 200]})
        for key, name in unknown.items():
            chosen = pick([(t, d) for t, d in rows or [] if d[0] == name])
            made = tv_quote(chosen[0], chosen[1], coin) if chosen else None
            found[key] = (made, None) if made else (None, error or "TradingView knows no %s" % name)
    return found


def tv_fetch(asked, want, names):
    """{record key: (quote, None) or (None, why)}: every stock and pair in one call on the global market (it answers
    any listing by its ticker), every coin as its pair in the currency asked in one on the crypto market; each listing
    found is kept for the next time."""
    from concurrent.futures import ThreadPoolExecutor  # the child's alone: a view never pays for it

    currency = want["currency"].upper()
    rank = {e: i for i, e in enumerate(COIN_EXCHANGES)}

    def coin_pick(rows):
        pairs = [r for r in rows if str(dict(zip(TV_COLUMNS, r[1])).get("currency")).upper() == currency]
        return min(pairs, key=lambda r: rank.get(r[0].split(":")[0], len(rank)), default=None)

    stocks = {record_key(s, want): (s["symbol"], s["listing"] or names.get(record_key(s, want))) for s in asked if s["kind"] != "coin"}
    coins = {record_key(s, want): (s["symbol"] + currency, names.get(record_key(s, want))) for s in asked if s["kind"] == "coin"}
    with ThreadPoolExecutor(max_workers=2) as pool:
        jobs = [pool.submit(tv_market, "global", stocks, lambda rows: rows[0] if rows else None, False) if stocks else None,
                pool.submit(tv_market, "crypto", coins, coin_pick, True) if coins else None]
        answers = {}
        for job in jobs:
            answers.update(job.result() if job else {})
    for key, (made, _) in answers.items():
        if made:
            names[key] = made["ticker"]
    return answers


def fetch_fx(pair):
    """(the rate `pair` names, "USD:EUR", None) or (None, why)."""
    base, to = pair.split(":")
    answer, error = curl(FX_API + "?" + urlencode({"base": base, "symbols": to}))
    if error:
        return None, "Frankfurter: %s" % error
    rate = number((answer.get("rates") or {}).get(to)) if isinstance(answer, dict) else None
    return (rate, None) if rate else (None, "Frankfurter sent no %s rate" % pair.replace(":", " to "))


def sampled(record, made, now):
    """The prices read before, as [[seconds, price]], with this one: a coin's of the last 24 h, a stock's of the day
    (New York's) it was last read on, so a source with no history still draws the day's line."""
    samples = [s for s in record.get("samples") or [] if isinstance(s, list) and len(s) == 2] + [[now, made["price"]]]
    if made["asset"] == "coin":
        return [s for s in samples if now - s[0] < DAY]
    today = ny_day(now)
    return [s for s in samples if ny_day(s[0]) == today]


def fetch(want, folder, force):
    """Asks the source for every symbol due (all when `force`), then each rate a price needs, and keeps each answer with
    when it was tried; a failure keeps the last answer and says why."""
    now = time.time()
    quotes, names, fx = load(folder, QUOTES), load(folder, NAMES), load(folder, FX)
    known = dict(names)
    asked = [s for s in want["symbols"] if force or due(s["kind"], quotes.get(record_key(s, want)) or {}, now, want["source"])]
    answers = FETCH[want["source"]](asked, want, names) if asked else {}
    for key, (made, error) in answers.items():
        kept = quotes.get(key) or {}
        if not made:
            quotes[key] = dict(kept, triedAt=now, error=error)
            continue
        quotes[key] = {"triedAt": now, "error": None, "fetchedAt": now, "quote": made}
        if not made.get("line"):  # a source with no history: the line from the prices read
            quotes[key]["samples"] = sampled(kept, made, now)
            made["line"] = thin([p for _, p in quotes[key]["samples"]])
    asked_now = {record_key(s, want) for s in want["symbols"]}
    quotes = {k: v for k, v in quotes.items() if k in asked_now}  # a symbol, source or currency no longer asked
    rates = [p for p in fx_pairs(want, quotes) if fx_due(p, fx, now, force)]
    for pair in rates:
        rate, error = fetch_fx(pair)
        fx[pair] = dict(fx.get(pair) or {}, triedAt=now, error=error, **({"rate": rate, "fetchedAt": now} if rate else {}))
    if rates:
        save(folder, FX, fx)
    if names != known:
        save(folder, NAMES, names)
    save(folder, QUOTES, quotes)


# ---- the refresh child ----

FETCH = {"tradingview": tv_fetch, "nasdaq": nasdaq_fetch}


def locked(f):
    """Takes the refresh lock on the open file `f`; False when a refresh holds it."""
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False


def refreshing(folder):
    """True while a refresh holds the lock."""
    try:
        with open(os.path.join(folder, LOCK), "a") as f:
            return not locked(f)
    except OSError:
        return False


def refresh_main():
    """`main.py --refresh`: one fetch for the symbols on stdin, the refresh lock held through the file it was handed."""
    job = json.loads(sys.stdin.read())
    fetch(job["want"], job["cache"], job.get("force", False))


def start_refresh(folder, want, force):
    """Takes the refresh lock and hands it to a detached child that fetches, so the lock is held from before it starts
    until it ends; None when a refresh runs already or the child could not start."""
    try:
        lock = open(os.path.join(folder, LOCK), "a")
    except OSError:
        return None
    with lock:
        if not locked(lock):
            return None
        try:
            child = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--refresh"], stdin=subprocess.PIPE,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, pass_fds=(lock.fileno(),),
                                     start_new_session=True, cwd=os.path.dirname(os.path.abspath(__file__)))
            child.stdin.write(json.dumps({"cache": folder, "want": want, "force": force}).encode())
            child.stdin.close()
        except OSError:
            return None
    return child


def cache_dir(run):
    """Pilot's cache folder for this extension, which it makes on the first run."""
    folder = (run.get("paths") or {}).get("cache")
    if not isinstance(folder, str) or not folder:
        send({"type": "error", "text": "Pilot sent no cache folder"})
        sys.exit(0)
    os.makedirs(folder, exist_ok=True)
    return folder


def markets(run, budget, force=False):
    """(settings, Board of the kept answers, True while a fetch still runs). Any symbol or rate due, or `force`, starts
    a fetch; a view with every symbol's answer shows them at once, one missing an answer (or `force`) waits `budget` s
    at most."""
    started = time.monotonic()
    folder = cache_dir(run)
    want = settings(run)
    now = time.time()
    quotes, fx = load(folder, QUOTES), load(folder, FX)
    records = [(s["kind"], quotes.get(record_key(s, want)) or {}) for s in want["symbols"]]
    late = [record for kind, record in records if due(kind, record, now, want["source"])]
    waits = force or any("quote" not in record for record in late)
    rates = any(fx_due(p, fx, now) for p in fx_pairs(want, quotes))
    child = start_refresh(folder, want, force) if force or late or rates else None
    if child and waits:
        try:
            child.wait(max(0.1, budget - (time.monotonic() - started)))
        except subprocess.TimeoutExpired:
            pass
    running = refreshing(folder)  # this child, or another view's
    if waits:
        while running and time.monotonic() - started < budget:
            time.sleep(0.1)
            running = refreshing(folder)
        quotes, fx = load(folder, QUOTES), load(folder, FX)
    return want, Board(want, quotes, fx), running


# ---- words ----

def clock(stamp):
    """14:05 when today, else Mon 14:05, in the Mac's time."""
    moment = time.localtime(stamp)
    if time.strftime("%Y-%m-%d", moment) == time.strftime("%Y-%m-%d"):
        return time.strftime("%H:%M", moment)
    return time.strftime("%a %H:%M", moment)


def figure(value):
    """A price as people read one: whole from 10,000, cents from 1, four figures below."""
    if value is None:
        return "–"
    size = abs(value)
    if size >= 10000:
        return "{:,.0f}".format(value)
    if size >= 1:
        return "{:,.2f}".format(value)
    return "{:.4g}".format(value)


def rate_figure(value):
    """A currency pair's rate as traders read one: four decimals, three from 10 (USDJPY)."""
    if value is None:
        return "–"
    return "{:,.4f}".format(value) if abs(value) < 10 else "{:,.3f}".format(value)


def amount(value):
    """A change in money: in cents from one cent, as a price below it (a small coin's)."""
    return "{:,.2f}".format(value) if 0.01 <= abs(value) < 1 else figure(value)


def short(value):
    """A price in at most six characters for the bar: 73.1k, 342, 4.21."""
    size = abs(value)
    if size >= 10000:
        return "%.1fk" % (value / 1000) if size < 1e6 else "%.1fM" % (value / 1e6)
    return "%.0f" % value if size >= 100 else figure(value)


def tone(percent):
    """Up fine, down alert, flat plain: always with its arrow, never the colour alone."""
    if percent is None or round(percent, 2) == 0:
        return None
    return "fine" if percent > 0 else "alert"


def change(percent, tight=False):
    """▲ 1.29%, ▼ 0.28%, or 0.00% when flat; `tight` with no space, one decimal from 10%."""
    if percent is None:
        return "–"
    arrow = {"fine": "▲", "alert": "▼"}.get(tone(percent), "")
    figures = "%.1f" % abs(percent) if tight and abs(percent) >= 10 else "%.2f" % abs(percent)
    return "%s%s%s%%" % (arrow, "" if tight or not arrow else " ", figures)


def sign(unit):
    """A money's sign: €, $, £, CHF, else its code."""
    return MONEY.get(unit.lower(), unit + " ")


def signed(value):
    return "+" if value > 0 else "−" if value < 0 else ""


def spark(values):
    """The day as a line of bars, lowest to highest; flat as a level line."""
    if len(values) < 2:
        return ""
    low, high = min(values), max(values)
    if high - low <= abs(high) * 1e-6:
        return BARS[3] * len(values)
    return "".join(BARS[int(round((v - low) / (high - low) * (len(BARS) - 1)))] for v in values)


def age(seconds):
    minutes = int(seconds // 60)
    return "%dm" % minutes if minutes < 60 else "%dh" % (minutes // 60) if minutes < 2880 else "%dd" % (minutes // 1440)


class Row:
    """One symbol's kept answer, read for a view, its money settled once: in the currency asked when the price is, or
    converted at the ECB's rate (≈), or in its own money while no rate is known. A pair keeps its own figures: a coin
    pair's in its money, a currency pair's, an index's or a future's bare."""

    def __init__(self, symbol, record, board):
        self.symbol, self.kind, self.key, self.listing = symbol["symbol"], symbol["kind"], symbol["key"], symbol["listing"]
        self.quote, self.error, self.fetched = record.get("quote") or {}, record.get("error"), record.get("fetchedAt")
        self.coin, self.pair = self.kind == "coin", self.kind == "pair"
        self.source = "tradingview" if self.pair else board.source  # the one source that prices a pair
        self.asset = self.quote.get("asset") or asset_of(symbol)
        self.words = SOURCES[self.source]["words"]["coin" if self.asset == "coin" else "stock"]
        self.figure, self.short = (rate_figure, rate_figure) if self.asset == "forex" else (figure, short)
        if self.pair:
            self.approx, self.rate, self.unit = False, 1, self.quote.get("currency") or ""
            self.sign = sign(self.unit) if self.unit and self.asset == "coin" else ""
            return
        own = self.quote.get("currency") or (board.currency.upper() if self.coin else "USD")
        rate = 1 if own == board.currency.upper() else board.rates.get("%s:%s" % (own, board.currency.upper()))
        self.approx = bool(rate) and rate != 1
        self.rate = rate or 1
        self.unit = board.currency.upper() if rate else own
        self.sign = sign(self.unit)

    @property
    def stale(self):
        """Its answer is old: the last try failed."""
        return bool(self.quote and self.error)

    @property
    def tone(self):
        """Warn while its answer is old or missing for a failure, else its move's tone."""
        if self.error:
            return "warn"
        return tone(self.quote.get("percent")) if self.quote else None

    @property
    def line(self):
        """The day's prices: the source's own minutes, or those this extension read."""
        return self.quote.get("line") or []

    def scaled(self, value):
        return None if value is None else value * self.rate

    def money(self, value, near=True, shown=None):
        """A figure with its money sign, ≈ before a converted one."""
        if value is None:
            return "–"
        return ("≈ " if near and self.approx else "") + self.sign + (shown or self.figure)(self.scaled(value))

    def url(self):
        """Its page on the source the prices come from; a pair's on TradingView, the one source that has it."""
        if self.source == "tradingview":
            ticker = self.quote.get("ticker") or self.listing
            return (tv_page(ticker) if ticker else
                    "https://www.tradingview.com/chart/?symbol=%s" % (self.symbol + (self.unit if self.coin else "")))
        if self.coin:
            return "https://www.coingecko.com/en/coins/%s" % (self.quote.get("id") or COINS.get(self.symbol, self.symbol.lower()))
        section = "etfs" if self.quote.get("asset") == "etf" else "stocks"
        return "https://www.nasdaq.com/market-activity/%s/%s" % (section, self.symbol.lower())

    def badges(self):
        if not self.quote:
            return [{"text": "no price", "tone": "warn"}] if self.error else []
        moved = self.quote.get("percent")
        found = [{"text": change(moved) + self.words["badge"], "tone": tone(moved)}]
        if self.stale:
            found.append({"text": "⚠ %s old" % age(time.time() - (self.fetched or 0)), "tone": "warn"})
        return [{k: v for k, v in b.items() if v is not None} for b in found]

    def item(self, edits=(), buttons=False):
        """Its row: Return opens it, Cmd+K copies its price; `edits` (moving it, removing it) are its inline buttons when
        `buttons` (the page), else more of Cmd+K's (Hyper+Space)."""
        where = self.words["site"]
        item = {"id": self.key, "title": self.symbol, "icon": KINDS.get(self.asset, KINDS["other"]),
                "keywords": " ".join(filter(None, [self.symbol, self.quote.get("name"), self.kind])), "badges": self.badges(),
                "actions": [{"type": "open", "url": self.url(), "title": "Open %s on %s" % (self.symbol, where)}],
                "inline": [{"type": "open", "url": self.url(), "title": "Open on %s" % where, "icon": "🌐"}]}
        if not self.quote:
            item["subtitle"] = self.error or "Asking…"
        else:
            price = self.money(self.quote["price"])
            item["title"] = "%s · %s" % (self.symbol, price)
            item["subtitle"] = "  ".join(w for w in [spark(self.line), self.quote.get("name"), self.error] if w)
            item["actions"].append({"type": "copy", "text": "%s %s" % (self.symbol, price), "title": "Copy the price"})
        if buttons:
            item["inline"] = list(edits)
        else:
            item["actions"] += edits
        return item

    def edits(self, at, count):
        """Move up (not the first), move down (not the last), remove: runs that change the list followed."""
        found = []
        if at > 0:
            found.append({"type": "run", "command": "move", "title": "Move %s up" % self.symbol, "icon": "arrow.up",
                          "context": {"key": self.key, "by": -1}})
        if at < count - 1:
            found.append({"type": "run", "command": "move", "title": "Move %s down" % self.symbol, "icon": "arrow.down",
                          "context": {"key": self.key, "by": 1}})
        found.append({"type": "run", "command": "remove", "title": "Remove %s from Markets" % self.symbol, "icon": "xmark",
                      "destructive": True, "context": {"key": self.key}})
        return found

    def parts(self, show, style):
        """The bar's words for it, each (part, text) in order: symbol, line, price, change in percent, change in money."""
        q = self.quote
        plain = [("symbol", self.symbol), ("percent", change(q.get("percent"), tight=True) if q else "–")]
        if not q:
            return plain
        found = [("symbol", self.symbol)] if show["symbol"] else []
        if style == "line" and len(self.line) > 1:
            found.append(("line", spark(thin(self.line, BAR_SPARK))))
        if show["price"]:
            price = self.scaled(q["price"])
            found.append(("price", self.sign.strip() + self.short(price)))
        if show["percent"]:
            found.append(("percent", change(q.get("percent"), tight=True)))
        if show["change"] and q.get("change") is not None:
            moved = abs(self.scaled(q["change"]))
            found.append(("change", signed(q["change"]) + self.sign.strip() + (amount(moved) if moved < 100 else short(moved))))
        return found or plain

    def gauge(self, show):
        """A mini bar: its symbol (five characters at most), a meter where the price stands between the day's low and high, and the
        first of its change, its change in money or its price that fits six characters, in its own tone."""
        q = self.quote
        gauge = {"label": self.symbol[:GAUGE_LABEL] if show["symbol"] else ""}
        low, high, price = q.get("low"), q.get("high"), q.get("price")
        if None not in (low, high, price):
            gauge["meters"] = [50 if high <= low else min(max((price - low) / (high - low) * 100, 0), 100)]
        texts = [p for _, p in self.parts(dict(show, symbol=False), "text")]
        gauge["text"] = next((t for t in texts if len(t) <= GAUGE_TEXT), "")
        if self.tone:
            gauge["tone"] = self.tone
        return {k: v for k, v in gauge.items() if v != ""}

    def hero(self):
        """The bar's symbol big: its price and unit, its name, then its move, its range and its last close or time."""
        q = self.quote
        moved, moved_by = q.get("percent"), q.get("change")
        where = [q.get("name") or self.symbol, self.symbol]
        if self.approx:
            where.append("≈ from %s%s" % (sign(q.get("currency") or ""), figure(q["price"])))
        delta = change(moved)
        if moved_by is not None:
            delta += " · %s%s" % (signed(moved_by), self.money(abs(moved_by), near=False, shown=amount))
        items = [{"label": self.words["window"], "value": delta, "tone": tone(moved)},
                 {"label": self.words["range"], "value": "%s – %s" % (self.figure(self.scaled(q.get("low"))), self.figure(self.scaled(q.get("high"))))}]
        if q.get("previous") is None:
            items.append({"label": "As of", "value": clock(q.get("asOf") or self.fetched or time.time())})
        else:
            items.append({"label": "Prev close", "value": self.figure(self.scaled(q["previous"]))})
        hero = {"type": "hero", "glyph": {"fine": "📈", "alert": "📉"}.get(tone(moved), "➖"), "value": self.figure(self.scaled(q["price"])),
                "unit": self.unit or None, "place": " · ".join(where), "tone": self.tone,
                "items": [{k: v for k, v in stat.items() if v is not None} for stat in items]}
        return {k: v for k, v in hero.items() if v is not None}


class Board:
    """Every symbol asked, with its kept answer, and the rates its prices are shown at."""

    def __init__(self, want, quotes, fx):
        self.currency, self.source = want["currency"], want["source"]
        self.rates = {pair: r["rate"] for pair, r in fx.items() if isinstance(r, dict) and r.get("rate")}
        self.rows = [Row(s, quotes.get(record_key(s, want)) or {}, self) for s in want["symbols"]]
        self.pinned = [r for key in want["pinned"] for r in self.rows if r.key == key]
        self.us = any(r.kind == "stock" and r.quote.get("currency", "USD") == "USD" for r in self.rows)

    def status(self):
        """Updated 14:05 · US market closed · opens Mon 15:30."""
        times = [r.fetched for r in self.rows if r.fetched]
        found = ["Updated %s" % clock(max(times))] if times else ["Not asked yet"]
        if self.us:
            found.append(market_line(time.time()))
        return " · ".join(found)

    def credit(self):
        return SOURCES[self.source]["credit"] + FX_CREDIT

    def items(self, buttons):
        """Every row with its edits (story 165's inline buttons when `buttons`)."""
        return [r.item(r.edits(at, len(self.rows)), buttons) for at, r in enumerate(self.rows)]

    def summary(self):
        return ", ".join("%s %s" % (r.symbol, change(r.quote.get("percent"))) for r in self.rows if r.quote) or "no prices yet"


# ---- the menu bar ----

def fitted(rows, show, style):
    """The bar's text for `rows` side by side, within Pilot's 24 characters: each row's parts, the lines dropped first,
    then the prices, then the rows that still do not fit (the first always kept, cut by Pilot)."""
    parts = [r.parts(show, style) for r in rows]
    for dropped in ((), ("line",), ("line", "price")):
        segments = [" ".join(t for p, t in each if p not in dropped) for each in parts]
        text = " · ".join(segments)
        if len(text) <= LONGEST:
            return text
    kept = segments[:1]
    for segment in segments[1:]:
        if len(" · ".join(kept + [segment])) > LONGEST:
            break
        kept.append(segment)
    return " · ".join(kept)


def shared_tone(rows):
    """One tone for text showing `rows`: warn when one is old or failed, else theirs when they agree, else none (the
    arrows say it)."""
    tones = {r.tone for r in rows}
    if "warn" in tones:
        return "warn"
    return tones.pop() if len(tones) == 1 else None


def turn(folder, count, advance):
    """Which of `count` bar symbols shows now when they take turns; a bar run (not a popover) moves to the next."""
    kept = load(folder, TURN).get("turn")
    now = kept if isinstance(kept, int) else -1
    if advance:
        now += 1
        save(folder, TURN, {"turn": now % count})
    return max(now, 0) % count


def bar_face(want, board, folder):
    """The bar line: its text, or gauges with no text, and its tone."""
    rows = board.pinned
    if not rows:
        return {"text": "📈 –", "tone": "warn"}
    if want["rotate"] and len(rows) > 1:
        rows = [rows[turn(folder, len(rows), advance=True)]]
    shown = [r for r in rows if r.quote]
    if want["style"] == "bars" and shown:
        return {"text": "", "gauges": [r.gauge(want["show"]) for r in shown[:GAUGES]]}
    face = {"text": fitted(rows, want["show"], want["style"])}
    found = shared_tone(rows)
    if found:
        face["tone"] = found
    return face


# ---- views ----

def drawn(run):
    """The block kinds this Pilot draws (its run message's `pilot.blocks`); an older Pilot names none."""
    pilot = run.get("pilot")
    return {k.strip() for k in str(pilot.get("blocks") or "").split(",")} if isinstance(pilot, dict) else set()


def refresh_button():
    return {"type": "run", "command": "refresh", "title": "Refresh", "icon": "refresh"}


def view_blocks(run, board, view):
    """The bar's first symbol big (where Pilot draws a hero), every symbol a row, then when it was read and the market's
    hours, and Refresh; a page leads with its search and adds its sources, its rows moved and removed in place."""
    kinds = drawn(run)
    page_ = view == "page"
    found = search_blocks(run, kinds, {r.key for r in board.rows}) if page_ else []
    if not board.rows:
        where = "search above" if found else "add some in Markets' settings, e.g. SPY, AAPL, BTC, ETH"
        return found + [{"type": "markdown", "text": "No symbols: %s." % where}]
    first = board.pinned[0] if board.pinned else None
    if "hero" in kinds and first and first.quote:
        found.append(first.hero())
    if page_:
        found.append({"type": "list", "items": board.items(True), "reorder": {"command": "move"}})
    else:
        found.append({"type": "list", "items": [r.item() for r in board.rows]})
    name = SOURCES[board.source]["name"]
    if "note" in kinds:
        found.append({"type": "note", "text": board.status(), "aside": name, "icon": "chart"})
    else:
        found.append({"type": "markdown", "text": "%s · %s" % (board.status(), name)})
    if view == "page":
        found += [{"type": "buttons", "actions": [refresh_button()]}, {"type": "markdown", "text": board.credit()}]
    elif "links" in kinds:
        found.append({"type": "links", "items": [{"icon": "refresh", "help": "Ask for the prices now",
                                                  "actions": [refresh_button()]}]})
    return found


def answer_blocks(run, board, running, view):
    message = {"type": "blocks", "blocks": view_blocks(run, board, view)}
    if running:
        message["refresh"] = REFRESH_SOON
    send(message)


def bar(run):
    popover = run.get("surface") == "popover"
    want, board, running = markets(run, BUDGET["popover" if popover else "bar"])
    if popover:
        answer_blocks(run, board, running, "popover")
        return
    send(dict(bar_face(want, board, run["paths"]["cache"]), type="bar", blocks=view_blocks(run, board, "popover")))


def page(run):
    _, board, running = markets(run, BUDGET["page"])
    answer_blocks(run, board, running, "page")


def listing(run):
    """Hyper+Space's Markets: every symbol a row (Cmd+K moves or removes it), then Add to Markets and Refresh."""
    _, board, running = markets(run, BUDGET["list"])
    items = board.items(False)
    items.append({"id": "search", "title": "Add to Markets…", "subtitle": "Search TradingView: BTC, AAPL, EURUSD, SPX",
                  "icon": "🔎", "actions": [{"type": "push", "command": "search", "title": "Search TradingView"}]})
    items.append({"id": "refresh", "title": "Refresh the prices", "subtitle": board.status(), "icon": "🔄",
                  "actions": [dict(refresh_button(), title="Refresh the prices")]})
    send({"type": "list", "items": items})


# ---- search and the list followed ----

def search_words(text):
    """(the words to search, the filter a leading word names or ""): "crypto sol" is sol among coins; a filter word
    alone is searched for."""
    parts = str(text or "").split()
    if len(parts) > 1 and parts[0].lower() in FILTER_WORDS:
        return " ".join(parts[1:]), FILTER_WORDS[parts[0].lower()]
    return " ".join(parts), ""


def plain(text):
    """A search answer's text without its highlights."""
    import html  # the search's alone: a view never pays for it

    return html.unescape(re.sub(r"</?em>", "", str(text or ""))).strip()


def picked(result):
    """A search answer's row as a symbol to follow, with "where" it trades (its exchange's name); None when it does not
    read. A stock or a fund is a stock (EXCHANGE:XYZ); the rest pairs. A future is followed by its continuous contract."""
    if not isinstance(result, dict):
        return None
    kind = str(result.get("type") or "")
    symbol = plain(result.get("symbol")).upper()
    contracts = [c for c in result.get("contracts") or [] if isinstance(c, dict)] if isinstance(result.get("contracts"), list) else []
    if contracts:
        contract = next((c for c in contracts if "continuous" in (c.get("typespecs") or [])), contracts[0])
        symbol = plain(contract.get("symbol")).upper()
    exchange = str(result.get("prefix") or result.get("source_id") or result.get("exchange") or "").upper()
    source = result.get("source2") if isinstance(result.get("source2"), dict) else {}
    return entry({"kind": "stock" if kind in STOCK_TYPES else "pair", "symbol": symbol, "listing": "%s:%s" % (exchange, symbol),
                  "type": kind, "name": plain(result.get("description")), "where": plain(source.get("name") or result.get("exchange"))})


def fits(result, kind):
    """Whether an answer is of the filter asked: TradingView narrows by it, and an unknown filter narrows nothing there."""
    if kind not in FILTER_ASSETS:
        return True
    specs = result.get("typespecs") if isinstance(result.get("typespecs"), list) else []
    return ASSETS.get(result.get("type")) == FILTER_ASSETS[kind] or (kind == "crypto" and "crypto" in specs)


def search(text, kind, timeout):
    """(symbols found for `text`, each once, in TradingView's order, None) or (None, why)."""
    query = {"text": text, "hl": "0", "exchange": "", "lang": "en", "search_type": kind, "domain": "production",
             "sort_by_country": "US"}
    answer, error = curl(SEARCH_API + "?" + urlencode(query), headers=SEARCH_HEADERS, timeout=timeout)
    if error:
        return None, "TradingView: %s" % error
    results = answer.get("symbols") if isinstance(answer, dict) else answer
    if not isinstance(results, list):
        return None, "TradingView: its answer did not read"
    found, seen = [], set()
    for result in results:
        made = picked(result) if isinstance(result, dict) and fits(result, kind) else None
        if made and made["key"] not in seen:
            seen.add(made["key"])
            found.append(made)
    return found, None


def tv_page(ticker):
    return "https://www.tradingview.com/symbols/%s/" % ticker.replace(":", "-")


def context(run):
    """The run's context, a dict, else {}."""
    found = run.get("context")
    return found if isinstance(found, dict) else {}


def label(symbol):
    return symbol["listing"] or symbol["symbol"]


def found_item(symbol, followed, buttons):
    """A search answer as a row: Return adds it (said when it is followed already), Cmd+K opens it on TradingView or
    copies its ticker; `buttons` draws add and open as its inline buttons (the page)."""
    adds = {"type": "run", "command": "add", "title": "Add %s to Markets" % symbol["symbol"],
            "context": {"symbol": symbol}}
    opens = {"type": "open", "url": tv_page(label(symbol)),
             "title": "Open %s on TradingView" % symbol["symbol"]}
    asset = asset_of(symbol)
    badges = [{"text": b} for b in (symbol.get("where"), ASSET_WORDS.get(asset, symbol.get("type", "").capitalize())) if b]
    if symbol["key"] in followed:
        badges.append({"text": "✓ followed", "tone": "fine"})
    item = {"id": "find:" + symbol["key"], "title": symbol["symbol"], "subtitle": symbol.get("name", ""),
            "icon": KINDS.get(asset, KINDS["other"]), "badges": badges[:3],
            "keywords": " ".join(filter(None, [symbol["symbol"], symbol.get("name"), symbol.get("where")])),
            "actions": [adds, opens, {"type": "copy", "text": label(symbol), "title": "Copy %s" % label(symbol)}]}
    if buttons:
        item["inline"] = [dict(adds, title="Add", icon="plus"), dict(opens, title="Open on TradingView", icon="🌐")]
    return item


def search_list(run):
    """Hyper+Space's Add to Markets: TradingView's answers for the words typed, asked on each change (filter self) within
    Pilot's 2 s; a leading crypto, stock, fund, forex, index or futures narrows them."""
    text, kind = search_words(run.get("query"))
    if not text:
        send({"type": "list", "items": [
            {"id": "hint", "title": "Type a symbol or a name", "subtitle": "BTC, AAPL, EURUSD, SPX, gold", "icon": "🔎"},
            {"id": "hint-filter", "title": "Start with crypto, stock, fund, forex, index or futures to narrow",
             "subtitle": "crypto sol · forex eur · futures es", "icon": "🏷️"}]})
        return
    found, error = search(text, kind, SEARCH_BUDGET)
    followed = {s["key"] for s in watchlist(run)}
    if error:
        items = [{"id": "error", "title": "TradingView did not answer", "subtitle": error, "icon": "⚠️"}]
    else:
        items = [found_item(s, followed, False) for s in found] or [
            {"id": "none", "title": "Nothing on TradingView for %s" % text, "icon": "🔎"}]
    send({"type": "list", "items": items})


def held_search(folder):
    """The page's last search while it is younger than FOUND_FOR s, else {}."""
    held = load(folder, FOUND)
    return held if held.get("query") and time.time() - (held.get("at") or 0) < FOUND_FOR else {}


def search_blocks(run, kinds, followed):
    """The page's search box (where Pilot draws one), then its last search: a button a filter (pressed again, every
    type), its answers as rows that add with Return, and Close."""
    blocks = []
    if "input" in kinds:
        blocks.append({"type": "input", "placeholder": "Search TradingView: BTC, AAPL, EURUSD, SPX…", "live": True,
                       "action": {"type": "run", "command": "find", "title": "Search"}})
    held = held_search(cache_dir(run))
    if not held:
        return blocks
    kind = held.get("type") or ""
    symbols_found = [s for s in map(entry, held.get("found") or []) if s]
    filters = {"type": "buttons", "actions": [{"type": "run", "command": "find", "title": ("✓ " if value == kind else "") + title,
                                               "context": {"type": value}} for value, title in FILTERS.items()]}
    rows = [found_item(s, followed, True) for s in symbols_found[:FOUND_ROWS]] or [
        {"id": "find:none", "title": held.get("error") or "Nothing found", "icon": "⚠️" if held.get("error") else "🔎"}]
    rows.append({"id": "find:close", "title": "Close the search", "icon": "✖️",
                 "actions": [{"type": "run", "command": "clear-search", "title": "Close the search"}]})
    title = "TradingView: “%s”" % held["query"]
    subtitle = "%d found · %s" % (len(symbols_found), FILTERS.get(kind, "every type"))
    inner = [filters, {"type": "list", "items": rows}]
    if "section" in kinds:
        return blocks + [{"type": "section", "title": title, "subtitle": subtitle, "blocks": inner}]
    return blocks + [{"type": "markdown", "text": "**%s** · %s" % (title, subtitle)}] + inner


def find(run):
    """The page's search: the words typed in its box, or a filter button's filter over the words held (pressed again,
    every type); its answers are kept for the page to draw. The box searches as Sven types, so a box emptied closes the
    search."""
    folder = cache_dir(run)
    pressed = context(run).get("type")
    if pressed is not None:
        held = held_search(folder)
        text = held.get("query") or ""
        kind = pressed if pressed in FILTERS and pressed != held.get("type") else ""
    else:
        text, kind = search_words(run.get("input"))
        if not text and run.get("input") is not None:
            clear_search(run)
            return
    if not text:
        send({"type": "error", "text": "type a symbol or a name to search, e.g. BTC or Apple"})
        return
    found, error = search(text, kind, CURL_TIMEOUT)
    save(folder, FOUND, {"query": text, "type": kind, "at": time.time(), "found": found or [], "error": error})
    if error:
        send({"type": "error", "text": error})
    else:
        send({"type": "hud", "text": "Markets: %d found for %s" % (len(found), text)})


def clear_search(run):
    try:
        os.remove(os.path.join(cache_dir(run), FOUND))
    except OSError:
        pass
    send({"type": "hud", "text": "Markets: search closed"})


def changed(run, listed, words):
    """Keeps `listed` as the symbols followed and says `words`, or why it could not."""
    if keep(run, listed):
        send({"type": "hud", "text": "Markets: %s" % words})
    else:
        send({"type": "error", "text": "could not keep the list in its data folder"})


def place(listed, key):
    """Where the symbol `key` names stands in `listed`, or None."""
    return next((i for i, s in enumerate(listed) if s["key"] == key), None)


def follow(run):
    """Adds the symbol its context hands on (a search row's) to the end of the list followed."""
    symbol = entry(context(run).get("symbol"))
    if not symbol:
        send({"type": "error", "text": "got no symbol to add"})
        return
    listed = watchlist(run)
    if any(s["key"] == symbol["key"] for s in listed):
        send({"type": "hud", "text": "Markets follows %s already" % label(symbol)})
    elif len(listed) >= MOST:
        send({"type": "error", "text": "follows %d symbols at most: remove one first" % MOST})
    else:
        changed(run, listed + [symbol], "added %s" % label(symbol))


def unfollow(run):
    """Removes the symbol its context names."""
    listed = watchlist(run)
    at = place(listed, context(run).get("key"))
    if at is None:
        send({"type": "error", "text": "follows no such symbol"})
        return
    gone = listed.pop(at)
    changed(run, listed, "removed %s" % label(gone))


def move(run):
    """Moves the symbol its context names to its place `to` (from 0: a row dragged on the page, Pilot's reorder), or one
    place up (by -1) or down (by 1)."""
    listed = watchlist(run)
    found = context(run)
    at, by, to = place(listed, found.get("key")), found.get("by"), found.get("to")
    if at is not None and to is None and by in (-1, 1):
        to = at + by
    if at is None or isinstance(to, bool) or not isinstance(to, (int, float)) or to != int(to) or not 0 <= to < len(listed) or to == at:
        send({"type": "error", "text": "can't move that symbol there"})
        return
    to = int(to)
    symbol = listed.pop(at)
    listed.insert(to, symbol)
    words = "up" if to == at - 1 else "down" if to == at + 1 else "to %d" % (to + 1)
    changed(run, listed, "%s moved %s" % (label(symbol), words))


def refresh(run):
    _, board, running = markets(run, REFRESH_BUDGET, force=True)
    failed = [r for r in board.rows if r.error]
    if running or (failed and len(failed) == len(board.rows)):
        send({"type": "error", "text": "could not refresh: %s" % (failed[0].error if failed else "no answer in time")})
        return
    send({"type": "hud", "text": "Markets: %s" % board.summary()})


# ---- Pilot's Markets widget ----
# Pilot's own desktop widget (Pilot P83) asks through `widget`, a hidden no-view command, and draws the answer itself:
# its symbols are TradingView listings picked by this extension's search, handed in the run's context, never the
# watchlist. One screener call prices them all, with each range's change, high and low; a range's line comes from a
# free source where one keeps history (coins: CoinGecko; US stocks and ETFs: Nasdaq; ECB currencies: Frankfurter, by
# day). It answers one `{"type": "data"}` line, which Pilot alone reads (an older Pilot skips the type), and keeps
# nothing but the coin ids found, so the menu bar's answers and the widget's never touch.

WIDGET_COLUMNS = TV_COLUMNS + ["Perf.W", "Perf.1M", "Perf.Y", "High.5D", "Low.5D", "High.1M", "Low.1M",
                               "price_52_week_high", "price_52_week_low"]
RANGES = {"1D": 1, "1W": 7, "1M": 30, "1Y": 365}  # a range key and the days its line spans
RANGE_COLUMNS = {"1W": ("Perf.W", "High.5D", "Low.5D"), "1M": ("Perf.1M", "High.1M", "Low.1M"),
                 "1Y": ("Perf.Y", "price_52_week_high", "price_52_week_low")}
LINE_POINTS = 120  # a chart's line, at most
WIDGET_TIMEOUT = 8  # each call's; the lines are asked side by side, so a run ends well inside Pilot's 30 s
US_EXCHANGES = {"NASDAQ", "NYSE", "AMEX", "ARCA", "NYSEARCA", "BATS", "CBOE"}  # listings Nasdaq keeps a history of
# The money a coin pair is quoted in, longest first (USDT before USD), and CoinGecko's name for it.
COIN_MONEY = [("USDT", "usd"), ("USDC", "usd"), ("FDUSD", "usd"), ("USD", "usd"), ("EUR", "eur"), ("GBP", "gbp"),
              ("CHF", "chf"), ("JPY", "jpy"), ("BTC", "btc"), ("ETH", "eth")]
COIN_CHART = "https://api.coingecko.com/api/v3/coins/%s/market_chart?%s"
NASDAQ_HISTORY = "https://api.nasdaq.com/api/quote/%s/historical?%s"
FX_SERIES = "https://api.frankfurter.dev/v1/%s..?%s"


def widget_quote(ticker, row):
    """A screener row with the widget's columns as Pilot reads it: the day's quote, its listing's type and exchange, and
    for 1W, 1M and 1Y the change in percent with that span's high and low."""
    made = tv_quote(ticker, row[:len(TV_COLUMNS)], False)
    if not made:
        return None
    d = dict(zip(WIDGET_COLUMNS, row))
    made["type"] = str(d.get("type") or "")
    made["exchange"] = ticker.split(":")[0]
    if made["type"] in ("spot", "crypto"):
        made["asset"] = "coin"
    made["ranges"] = {span: {"percent": number(d.get(p)), "high": number(d.get(h)), "low": number(d.get(lo))}
                      for span, (p, h, lo) in RANGE_COLUMNS.items()}
    return made


def coin_line(name, span, names):
    """(a coin pair's line over `span`, [[seconds, price]], None) or (None, why), from CoinGecko in the pair's money."""
    for money, gecko in COIN_MONEY:
        if name.endswith(money) and len(name) > len(money):
            break
    else:
        return None, "no history for %s" % name
    cid, error = coin_id(name[:-len(money)], names)
    if error:
        return None, error
    answer, error = curl(COIN_CHART % (quote(cid, safe=""), urlencode({"vs_currency": gecko, "days": RANGES[span]})),
                         timeout=WIDGET_TIMEOUT)
    if error:
        return None, "CoinGecko: %s" % error
    prices = answer.get("prices") if isinstance(answer, dict) else None
    points = [[p[0] / 1000.0, number(p[1])] for p in prices or [] if isinstance(p, list) and len(p) == 2
              and isinstance(p[0], (int, float))]
    return [p for p in points if p[1] is not None], None


def nasdaq_line(name, asset, span, now):
    """(a US stock's or fund's line over `span`, None) or (None, why): the day's minutes of its last session for 1D, else
    a close a day."""
    kind = "etf" if asset == "etf" else "stocks"
    if span == "1D":
        answer, error = curl(NASDAQ % (quote(name, safe=""), kind), browser=True, timeout=WIDGET_TIMEOUT)
        data = answer.get("data") if isinstance(answer, dict) else None
        if error or not isinstance(data, dict):
            return None, "Nasdaq: %s" % (error or "no chart for %s" % name)
        points = [[p["x"] / 1000.0, number(p.get("y"))] for p in data.get("chart") or []
                  if isinstance(p, dict) and isinstance(p.get("x"), (int, float))]
        points = [p for p in points if p[1] is not None]
        hours = session(ny_day(points[-1][0])) if points else None
        regular = [p for p in points if hours and hours[0] <= p[0] <= hours[1]]
        return regular or points, None
    since = datetime.fromtimestamp(now, NEW_YORK).date() - timedelta(days=RANGES[span])
    answer, error = curl(NASDAQ_HISTORY % (quote(name, safe=""), urlencode({"assetclass": kind, "fromdate": since.isoformat(),
                                                                             "limit": 400})),
                         browser=True, timeout=WIDGET_TIMEOUT)
    rows = (((answer or {}).get("data") or {}).get("tradesTable") or {}).get("rows") if isinstance(answer, dict) else None
    if error or not isinstance(rows, list):
        return None, "Nasdaq: %s" % (error or "no history for %s" % name)
    points = []
    for row in rows:
        try:
            day = datetime.strptime(str(row.get("date")), "%m/%d/%Y").replace(hour=16, tzinfo=NEW_YORK)
        except (AttributeError, ValueError):
            continue
        close = number(row.get("close"))
        if close is not None:
            points.append([day.timestamp(), close])
    return sorted(points), None


def fx_line(name, span, now):
    """(a currency pair's line over `span`, a rate a working day, None) or (None, why): the ECB's rates keep no day."""
    if span == "1D" or len(name) != 6:
        return None, "no history for %s over %s" % (name, span)
    since = datetime.fromtimestamp(now, timezone.utc).date() - timedelta(days=RANGES[span])
    answer, error = curl(FX_SERIES % (since.isoformat(), urlencode({"base": name[:3], "symbols": name[3:]})), timeout=WIDGET_TIMEOUT)
    rates = answer.get("rates") if isinstance(answer, dict) else None
    if error or not isinstance(rates, dict):
        return None, "Frankfurter: %s" % (error or "no %s rates" % name)
    points = []
    for day, values in sorted(rates.items()):
        try:
            stamp = datetime.strptime(day, "%Y-%m-%d").replace(hour=16, tzinfo=timezone.utc).timestamp()
        except ValueError:
            continue
        rate = number((values or {}).get(name[3:])) if isinstance(values, dict) else None
        if rate is not None:
            points.append([stamp, rate])
    return points, None


def widget_line(symbol, made, span, names, now):
    """(`symbol`'s line over `span`, cut to LINE_POINTS, None) or (None, why) when no free source keeps its history."""
    exchange, _, name = symbol["listing"].rpartition(":")
    asset = (made or {}).get("asset") or asset_of(symbol)
    if asset == "coin":
        points, error = coin_line(name, span, names)
    elif asset in ("stocks", "etf") and exchange in US_EXCHANGES:
        points, error = nasdaq_line(name, asset, span, now)
    elif asset == "forex":
        points, error = fx_line(name, span, now)
    else:
        return None, "no free history for %s" % symbol["listing"]
    if error or not points:
        return None, error or "no history for %s" % symbol["listing"]
    return thin(points, LINE_POINTS), None


def widget(run):
    """The widget's ask, in its context: `{"search": text}` answers the listings found; else `{"symbols": [listed
    symbols], "range": "1D", "lines": [keys]}` answers every symbol's quote and, for the keys in `lines`, its line over
    the range; a symbol that failed says why under `errors`."""
    asked = context(run)
    if isinstance(asked.get("search"), str):
        text, kind = search_words(asked["search"])
        found, error = search(text, kind, WIDGET_TIMEOUT) if text.strip() else ([], None)
        if error:
            send({"type": "error", "text": error})
        else:
            send({"type": "data", "data": {"found": found[:FOUND_ROWS]}})
        return
    symbols = [e for e in map(entry, asked.get("symbols") or []) if e and e["listing"]][:MOST]
    span = asked.get("range") if asked.get("range") in RANGES else "1D"
    wanted = {k for k in asked.get("lines") or [] if isinstance(k, str)}
    folder = cache_dir(run)
    names = load(folder, NAMES)
    known = dict(names)
    quotes, lines, errors = {}, {}, {}
    if symbols:
        rows, error = scan("global", {"symbols": {"tickers": sorted({s["listing"] for s in symbols})}}, WIDGET_COLUMNS)
        by_ticker = dict(rows or [])
        for s in symbols:
            made = widget_quote(s["listing"], by_ticker[s["listing"]]) if s["listing"] in by_ticker else None
            if made:
                quotes[s["key"]] = made
            else:
                errors[s["key"]] = error or "TradingView knows no %s" % s["listing"]
    drawn = [s for s in symbols if s["key"] in wanted]
    if drawn:
        from concurrent.futures import ThreadPoolExecutor  # the widget's alone: a view never pays for it

        now = time.time()
        with ThreadPoolExecutor(max_workers=min(len(drawn), 6)) as pool:
            jobs = {s["key"]: pool.submit(widget_line, s, quotes.get(s["key"]), span, names, now) for s in drawn}
            for key, job in jobs.items():
                points, error = job.result()
                if points:
                    lines[key] = points
                else:
                    errors.setdefault(key, error)
    if names != known:
        save(folder, NAMES, names)
    send({"type": "data", "data": {"range": span, "quotes": quotes, "lines": lines, "errors": errors}})


def main():
    if sys.argv[1:] == ["--refresh"]:
        refresh_main()
        return
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        send({"type": "error", "text": "got a run message it could not read"})
        return
    command = run.get("command")
    view = {"markets": listing, "bar": bar, "page": page, "refresh": refresh, "search": search_list, "find": find,
            "clear-search": clear_search, "add": follow, "remove": unfollow, "move": move, "widget": widget}.get(command)
    if view:
        view(run)
    else:
        send({"type": "error", "text": "has no command %s" % command})


if __name__ == "__main__":
    main()
