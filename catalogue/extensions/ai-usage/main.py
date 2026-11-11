#!/usr/bin/env python3
"""AI usage for Pilot: how much of each AI plan's limits is left, CodexBar's way, from this Mac and the providers' own CLIs.

Claude, two sources for the session and the week, Claude Code's cached read winning unless the status line is over
10 minutes newer (the cache holds the usage API's own answer, which CodexBar reads too; the status line read the week a
point lower on 2026-10-11):
- Claude Code hands its status-line command `rate_limits` after every reply (`five_hour` and `seven_day`, each
  `used_percentage` and `resets_at` in epoch seconds), and Ghostex keeps that per session in
  ~/.local/state/ghostex/agent-hooks/claude-statusline/<session>.json as `{"version", "updatedAt", "payload": {…}}`.
- Claude Code caches its own usage read in ~/.claude.json: `cachedUsageUtilization` (`fetchedAtMs`, `accountUuid` and
  `utilization.limits`, each `kind` session, weekly_all or weekly_scoped with a model's `display_name`, `percent`,
  `resets_at` ISO), the only place a per-model week such as "Fable weekly" shows; `oauthAccount` there gives the email
  and plan (`organizationType`, `organizationRateLimitTier`). Only those two keys are used; the file holds no token.

Codex, per account (a CODEX_HOME folder): the folders in the `codexHomes` preference, then Pilot's own accounts (each a
folder under paths.data/codex-accounts, made by Add Codex account, which runs Codex's own `codex login` in it), then
any other folder signed in to Codex (a ~/.codex-* or Pilot › AI's own Codex home, holding an auth.json, never opened)
while the `otherCodex` setting is on, one row each, an account seen twice once, are asked
through Codex's own `codex app-server` (`account/read`: email and plan; `account/rateLimits/read`: the 5-hour and weekly
windows, credits and limit reset credits; `account/rateLimitResetCredit/consume`: Redeem reset, asked first, the call
Codex's own Redeem reset makes). Codex signs in with its own login; Pilot never reads or copies it, and only
one Pilot process at a time runs Codex in a folder (a lock per folder: an ask or a sign-in that finds it held skips),
so two never refresh one login at once. The bar never waits for Codex: it shows the last answer
(paths.cache/codex-<hash>.json) and hands a stale one to one detached refresh; a popover or page asks again inline when
the answer is over 30 s old. Without an answer, and for a ~/.codex-* folder with logs but no login (listed, never
asked), the numbers come from the tail of the newest session logs
(sessions/YYYY/MM/DD/*.jsonl, archived_sessions): `token_count` events whose `payload.rate_limits` holds `primary` and
`secondary`, each `used_percent`, `window_minutes` and `resets_at` (older Codex: `resets_in_seconds`), plus `credits`.

Either way, a window whose reset time has passed since the numbers were read has reset: it shows 100% left, with what
it was. Each window's pace is CodexBar's (UsagePace and UsagePaceText, 0.74): in reserve or in deficit, whether it lasts
until the reset or when it runs out, and a mark where its share left should be by now, green in reserve and red in
deficit. No pace until 3% of the window has gone or once it is used up, "On pace" and no mark within 2 points, a session
"Projected empty", a week "Runs out", and only Codex's "1.5× headroom", past 15 points in reserve.

Status: each provider's status page (status.claude.com, status.openai.com, Statuspage's api/v2/status.json) is read by a
detached run at most every 5 minutes into paths.cache/status.json; a degraded service shows as a row under the cards.

Gemini keeps no local limit, and its quota is only asked with its sign-in token, which Pilot never reads: "limit
unknown" once the gemini CLI is on PATH; without it Gemini is left out.

Claude Code tokens (a footnote on the page and in the detail, not a limit): every assistant line in
~/.claude/projects/**/*.jsonl carries `message.usage`. Logs changed in the last 8 days are read from where the last run
stopped and summed per minute into paths.cache, keyed by path, size and modification time. A run that cannot finish in
its time hands the rest to one detached refresh (a lock keeps two from overlapping). The page, every 60 s while Home
shows, gives a full count under 5 minutes old again rather than stat every log.

Settings (the manifest's preferences): which providers the bar shows and whether its figure is the session or the most
used window; pace on or off; other Codex folders and Gemini shown or hidden. Every bar shows the share left, CodexBar's
way, draining as it is used.

Nothing else is read: no auth.json, credentials, keychain items or cookies of any provider.
"""
import calendar
import fcntl
import hashlib
import json
import math
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid

START = time.monotonic()
DAY = 86400
SCAN_DAYS = 8
BLOCK = 5 * 3600
CACHE_FILE = "claude-usage.json"
LOCK_FILE = "refresh.lock"
CODEX_LOCK = "codex.lock"
CACHE_VERSION = 1
SEEN_KEEP = 512  # message ids remembered per log to fold repeated lines into one; repeats sit close together
DETAIL_SCAN = 1.0  # seconds from start a detail may spend reading Claude logs; the rest goes to the background
PAGE_SCAN = 3.0  # a page's command may take 5 s; the bar and popover read no Claude logs at all
REFRESH_SCAN = 120.0
LIVE_FRESH = 30  # a popover or the summary asks Codex again when its answer is older
LIVE_STALE = 120  # the bar and detail hand an older answer to a background refresh; a page, every 60 s, asks past it
TOKENS_FRESH = 300  # a page counts Claude Code tokens again only when its last full count is older: each count stats every log
TOKENS_FILE = "claude-tokens.json"
LIVE_WAIT = 3.0  # seconds a popover waits for Codex; a page waits 2 s, leaving time to count Claude Code tokens
PAGE_WAIT = 2.0
REFRESH_WAIT = 10.0  # seconds Refresh now waits for Codex; a no-view command has 30
REDEEM_WAIT = 20.0  # seconds Redeem reset waits for Codex's answer, leaving time to ask the account again
CODEX_TAILS = (256 * 1024, 4 * 1024 * 1024, 32 * 1024 * 1024)
ACCOUNTS = "codex-accounts"  # Pilot's own Codex accounts, one CODEX_HOME each, under paths.data
LOGIN_WAIT = 900  # seconds a `codex login` may wait for the browser
LINK_WAIT = 8.0  # seconds Add Codex account waits for Codex to print its sign-in link
SIGNING_IN_REFRESH = 3  # a popover showing a sign-in asks again this often, so the new card shows
PAGE_SIGNING_IN_REFRESH = 15  # a page too, less often: it counts Claude Code's tokens each time
LINE_AHEAD = 600  # the status line wins over Claude Code's cached read only when this much newer
STATUS_FILE, STATUS_LOCK, STATUS_EVERY = "status.json", "status.lock", 300
CODEX_HOME_NAME = re.compile(r"\.codex(-[A-Za-z0-9._-]+)?\Z")
PILOT_AI_CODEX = os.path.join("Library", "Application Support", "Pilot", "codex")  # Pilot › AI's CODEX_HOME (Q203)
STATUSLINE = os.path.join(".local", "state", "ghostex", "agent-hooks", "claude-statusline")
STATUSLINE_TRIES = 40  # newest status-line files read for one with rate_limits
USAGE_KEYS = ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
SESSION, WEEK = 300, 10080  # window lengths in minutes
WARN, ALERT = 60, 85  # percent used
BAR = 20
# The settings (the manifest's preferences), read once per run by configure().
VIEW = {"barProviders": "both", "barWindow": "session", "pace": True, "otherCodex": True, "gemini": True}
# Each provider's status page (Statuspage's api/v2/status.json) and usage dashboard, as CodexBar links them.
STATUS_PAGES = {"claude": "https://status.claude.com", "codex": "https://status.openai.com"}
PROVIDERS = (("claude", "Claude"), ("codex", "Codex"))
DASHBOARDS = {"claude": "https://claude.ai/settings/usage", "codex": "https://chatgpt.com/codex/cloud/settings/analytics#usage"}
CLAUDE_PLANS = {"claude_max": "Max", "claude_pro": "Pro", "claude_team": "Team", "claude_enterprise": "Enterprise"}


def configure(run):
    """The run's settings over the defaults; a value of the wrong type keeps the default."""
    prefs = run.get("preferences") or {}
    for key, default in VIEW.items():
        if isinstance(prefs.get(key), type(default)):
            VIEW[key] = prefs[key]


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


def parse_time(stamp):
    """An ISO timestamp (UTC `Z`, or with an offset) as epoch seconds, or None."""
    if not isinstance(stamp, str) or len(stamp) < 19:
        return None
    try:
        if stamp.endswith("Z") or len(stamp) == 19:
            return calendar.timegm((int(stamp[0:4]), int(stamp[5:7]), int(stamp[8:10]), int(stamp[11:13]),
                                    int(stamp[14:16]), int(stamp[17:19]), 0, 0, 0))
        from datetime import datetime
        return datetime.fromisoformat(stamp).timestamp()
    except ValueError:
        return None


def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def window(name, percent, resets_at, now, minutes=None):
    """One limit window; reset_since when its reset time has passed since it was read."""
    return {"name": name, "percent": float(percent), "resets_at": resets_at,
            "minutes": minutes if isinstance(minutes, int) and minutes > 0 else None,
            "reset_since": resets_at is not None and resets_at <= now}


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_json(path, data):
    tmp = "%s.%d.tmp" % (path, os.getpid())
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, separators=(",", ":"))
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


# Claude


def claude_statusline(home, now):
    """(read time, session and week) from the newest Ghostex status-line file that carries rate_limits, or None."""
    folder = os.path.join(home, STATUSLINE)
    try:
        names = [n for n in os.listdir(folder) if n.endswith(".json")]
    except OSError:
        return None
    found = []
    for name in names:
        try:
            found.append((os.stat(os.path.join(folder, name)).st_mtime, name))
        except OSError:
            continue
    found.sort(reverse=True)
    for mtime, name in found[:STATUSLINE_TRIES]:
        data = read_json(os.path.join(folder, name))
        payload = data.get("payload") if isinstance(data, dict) else None
        limits = payload.get("rate_limits") if isinstance(payload, dict) else None
        if not isinstance(limits, dict):
            continue
        windows = []
        for key, label, minutes in (("five_hour", "Session", SESSION), ("seven_day", "Weekly", WEEK)):
            raw = limits.get(key)
            percent = number(raw.get("used_percentage")) if isinstance(raw, dict) else None
            if percent is not None:
                windows.append(window(label, percent, number(raw.get("resets_at")), now, minutes))
        if windows:
            return parse_time(data.get("updatedAt")) or mtime, windows
    return None


def claude_plan(account):
    plan = CLAUDE_PLANS.get(account.get("organizationType"))
    tier = re.search(r"_(\d+)x\Z", account.get("organizationRateLimitTier") or "")
    return "%s %sx" % (plan, tier.group(1)) if plan and tier else plan


def claude_account(home, now):
    """(email, plan, cached read) from ~/.claude.json: the account Claude Code signed in with and its own last usage read
    as (read time, windows), the per-model weeks among them; None for what is missing or another account's."""
    data = read_json(os.path.join(home, ".claude.json"))
    if not isinstance(data, dict):
        return None, None, None
    account = data.get("oauthAccount") if isinstance(data.get("oauthAccount"), dict) else {}
    email = account.get("emailAddress") if isinstance(account.get("emailAddress"), str) else None
    cached = data.get("cachedUsageUtilization")
    fetched = number(cached.get("fetchedAtMs")) if isinstance(cached, dict) else None
    if fetched is None or cached.get("accountUuid") != account.get("accountUuid"):
        return email, claude_plan(account), None
    usage = cached.get("utilization") if isinstance(cached.get("utilization"), dict) else {}
    windows = []
    for raw in usage.get("limits") or []:
        if not isinstance(raw, dict) or number(raw.get("percent")) is None:
            continue
        kind, scope = raw.get("kind"), raw.get("scope")
        model = scope.get("model") if isinstance(scope, dict) else None
        if kind == "session":
            name, minutes = "Session", SESSION
        elif kind == "weekly_all":
            name, minutes = "Weekly", WEEK
        elif kind == "weekly_scoped" and isinstance(model, dict) and isinstance(model.get("display_name"), str):
            name, minutes = "%s weekly" % model["display_name"], WEEK
        else:
            continue
        windows.append(window(name, raw["percent"], parse_time(raw.get("resets_at")), now, minutes))
    return email, claude_plan(account), (fetched / 1000.0, windows) if windows else None


def claude_limits(home, now):
    """Claude's windows: the session and the week from Claude Code's cached read (the usage API's answer, as CodexBar
    reads it) unless the status line is over 10 minutes newer, then the cached per-model weeks."""
    email, plan, cached = claude_account(home, now)
    line = claude_statusline(home, now)
    if line is None and cached is None:
        return {"state": "unknown", "who": email, "plan": plan}
    if cached is None or (line is not None and line[0] > cached[0] + LINE_AHEAD):
        read_at, windows = line
        exact = {w["name"]: w["resets_at"] for w in (cached[1] if cached else []) if w["resets_at"]}
        for w in windows:  # the status line rounds a reset to the minute; the cached read of the same window has it exact
            if w["resets_at"] and abs(exact.get(w["name"], 0) - w["resets_at"]) < 120:
                w["resets_at"] = exact[w["name"]]
        windows = windows + [w for w in (cached[1] if cached else []) if w["name"] not in ("Session", "Weekly")]
    else:
        read_at, windows = cached
    return {"state": "ok", "who": email, "plan": plan, "read_at": read_at, "windows": windows}


# Codex


def tilde(path, home):
    return "~" + path[len(home):] if path == home or path.startswith(home + os.sep) else path


def own_accounts(data_dir):
    """Pilot's own Codex accounts: each numbered folder under paths.data/codex-accounts, oldest first."""
    root = os.path.join(data_dir, ACCOUNTS) if data_dir else None
    try:
        names = [n for n in os.listdir(root) if n.isdigit()] if root else []
    except OSError:
        names = []
    return [os.path.join(root, n) for n in sorted(names, key=int) if os.path.isdir(os.path.join(root, n))]


def signed_in(path):
    """Whether Codex keeps a login in this folder; the file is never opened."""
    return os.path.exists(os.path.join(path, "auth.json"))


def codex_homes(home, run):
    """(the preference's folders, Pilot's own accounts, other logins, other folders): the first three asked live (other
    logins: any ~/.codex-* or Pilot › AI's Codex home signed in), the last (a ~/.codex-* with logs only) from its logs."""
    raw = (run.get("preferences") or {}).get("codexHomes")
    asked = []
    for part in (raw if isinstance(raw, str) and raw.strip() else "~/.codex").split(","):
        path = os.path.normpath(os.path.expanduser(part.strip())) if part.strip() else ""
        if os.path.isabs(path) and path not in asked:
            asked.append(path)
    own = [p for p in own_accounts((run.get("paths") or {}).get("data")) if p not in asked]
    try:
        names = sorted(os.listdir(home))
    except OSError:
        names = []
    logins, others = [], []
    pilot_ai = os.path.join(home, PILOT_AI_CODEX)
    for path in [os.path.join(home, n) for n in names if CODEX_HOME_NAME.match(n)] + [pilot_ai]:
        if path in asked:
            continue
        if signed_in(path):
            logins.append(path)
        elif os.path.isdir(os.path.join(path, "sessions")) and path != pilot_ai:
            others.append(path)
    return asked, own, logins, others


def codex_files(codex_home, now):
    """Codex logs changed in the last 8 days, newest first."""
    found = []
    for sub in ("sessions", "archived_sessions"):
        for folder, _, names in os.walk(os.path.join(codex_home, sub)):
            for name in names:
                if not name.endswith(".jsonl"):
                    continue
                path = os.path.join(folder, name)
                try:
                    mtime = os.stat(path).st_mtime
                except OSError:
                    continue
                if now - mtime < SCAN_DAYS * DAY:
                    found.append((mtime, path))
    found.sort(reverse=True)
    return [path for _, path in found]


def last_rate_limits(path):
    """(event time, rate_limits) of the last token_count event with a window in a Codex log, or None."""
    size = os.path.getsize(path)
    for tail in CODEX_TAILS:
        start = max(0, size - tail)
        with open(path, "rb") as f:
            f.seek(start)
            lines = f.read(size - start).split(b"\n")
        for raw in reversed(lines[1:] if start else lines):
            if b'"token_count"' not in raw or b'"rate_limits"' not in raw:
                continue
            try:
                event = json.loads(raw)
            except ValueError:
                continue
            payload = event.get("payload") if isinstance(event, dict) else None
            if not isinstance(payload, dict) or payload.get("type") != "token_count":
                continue
            limits = payload.get("rate_limits")
            if not isinstance(limits, dict) or limits.get("limit_id") not in (None, "codex"):
                continue
            if any(isinstance(limits.get(k), dict) for k in ("primary", "secondary")):
                return parse_time(event.get("timestamp")), limits
        if not start:
            break
    return None


def window_name(minutes, fallback):
    if not isinstance(minutes, int) or minutes <= 0:
        return fallback
    if minutes == SESSION:
        return "Session"
    if minutes == WEEK:
        return "Weekly"
    if minutes % 1440 == 0:
        return "%d days" % (minutes // 1440)
    if minutes % 60 == 0:
        return "%d hours" % (minutes // 60)
    return "%d min" % minutes


def credits_text(raw):
    """Codex credits worth showing: unlimited, or a balance above 0; None for none."""
    if not isinstance(raw, dict):
        return None
    if raw.get("unlimited") is True:
        return "unlimited"
    balance = raw.get("balance")
    try:
        return str(balance) if not isinstance(balance, bool) and float(balance) > 0 else None
    except (TypeError, ValueError):
        return None


def plan_words(plan):
    return {"prolite": "Pro Lite", "promax": "Pro Max", "edu_plus": "Edu Plus", "edu_pro": "Edu Pro"}.get(
        plan, plan.replace("_", " ").title()) if isinstance(plan, str) and plan and plan != "unknown" else None


def codex_windows(raw, keys, now, stamp=None):
    """The 5-hour and weekly windows of a Codex rate-limit snapshot, its keys (used, minutes, resets) as a log or the
    app-server spells them; an older log's `resets_in_seconds` counts from the event's `stamp`."""
    used, length, resets_key = keys
    out = []
    for key, fallback in (("primary", "Session"), ("secondary", "Weekly")):
        w = raw.get(key)
        percent = number(w.get(used)) if isinstance(w, dict) else None
        if percent is None:
            continue
        resets = number(w.get(resets_key))
        seconds = number(w.get("resets_in_seconds"))
        if resets is None and seconds is not None and stamp:
            resets = stamp + seconds
        out.append(window(window_name(w.get(length), fallback), percent, resets, now, w.get(length)))
    return out


def codex_logs(codex_home, now):
    """One account's windows from the last rate_limits in its session logs."""
    if not any(os.path.isdir(os.path.join(codex_home, sub)) for sub in ("sessions", "archived_sessions")):
        return {"state": "missing"}
    best = None
    for path in codex_files(codex_home, now)[:3]:
        try:
            found = last_rate_limits(path)
        except OSError:
            continue
        if found and (best is None or (found[0] or 0) > (best[0] or 0)):
            best = found
    if best is None:
        return {"state": "none"}
    stamp, raw = best
    windows = codex_windows(raw, ("used_percent", "window_minutes", "resets_at"), now, stamp)
    if not windows:
        return {"state": "none"}
    return {"state": "ok", "source": "logs", "read_at": stamp, "windows": windows,
            "credits": credits_text(raw.get("credits")), "plan": plan_words(raw.get("plan_type"))}


def codex_rpc(codex_home, requests, deadline):
    """Codex's answers to `requests` (after initialize) through `codex app-server` (JSON-RPC lines on stdio) in one
    account's folder, which signs in with its own login: {id: message} once every request with an id has answered;
    None when codex is missing, fails or is still quiet at `deadline`."""
    program = shutil.which("codex")
    if not program:
        return None
    env = dict(os.environ, CODEX_HOME=codex_home)
    try:
        proc = subprocess.Popen([program, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, env=env, start_new_session=True)
    except OSError:
        return None
    answers, buffer = {}, b""
    wanted = {r["id"] for r in requests if "id" in r}
    try:
        requests = [{"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "pilot-ai-usage", "version": "3"}}},
                    {"method": "initialized"}] + requests
        proc.stdin.write("".join(json.dumps(r) + "\n" for r in requests).encode())
        proc.stdin.flush()
        out = proc.stdout.fileno()
        while len(answers) < len(wanted):
            left = deadline - time.monotonic()
            if left <= 0 or not select.select([out], [], [], left)[0]:
                return None
            chunk = os.read(out, 65536)
            if not chunk:
                break
            buffer += chunk
            *lines, buffer = buffer.split(b"\n")
            for line in lines:
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if isinstance(message, dict) and message.get("id") in wanted:
                    answers[message["id"]] = message
    except OSError:
        return None
    finally:
        proc.kill()
        proc.wait()
    return answers


def ask_codex(codex_home, deadline):
    """Codex's own answer for one account: {at, account: {email, plan} or None when signed out, limits, reset_credits};
    None when codex is missing, fails or is still quiet at `deadline`."""
    answers = codex_rpc(codex_home, [{"id": 2, "method": "account/read", "params": {}},
                                     {"id": 3, "method": "account/rateLimits/read", "params": None}], deadline) or {}
    account = (answers.get(2) or {}).get("result")
    limits = (answers.get(3) or {}).get("result")
    if not isinstance(account, dict):
        return None
    who, at = account.get("account"), time.time()
    if not isinstance(who, dict):
        return {"at": at, "account": None}
    found = {"at": at, "account": {"email": who.get("email") if isinstance(who.get("email"), str) else None,
                                            "plan": plan_words(who.get("planType"))}}
    if isinstance(limits, dict) and isinstance(limits.get("rateLimits"), dict):
        found["limits"] = limits["rateLimits"]
        summary = limits.get("rateLimitResetCredits")
        if isinstance(summary, dict) and number(summary.get("availableCount")) is not None:
            found["reset_credits"] = {"count": int(summary["availableCount"]), "expires": sorted(
                c["expiresAt"] for c in summary.get("credits") or []
                if isinstance(c, dict) and c.get("status") == "available" and number(c.get("expiresAt")))}
    return found


def live_path(cache_dir, codex_home):
    return os.path.join(cache_dir, "codex-%s.json" % home_key(codex_home))


def home_key(codex_home):
    return hashlib.sha1(codex_home.encode()).hexdigest()[:12]


def lock_name(codex_home):
    """The lock one Pilot process holds while it runs Codex in a folder, asking or signing in."""
    return "codex-%s.lock" % home_key(codex_home)


def login_path(cache_dir, codex_home):
    """A sign-in running in a folder: {at, pid}."""
    return os.path.join(cache_dir, "login-%s.json" % home_key(codex_home))


def login_log(cache_dir, codex_home):
    """The sign-in's output: Codex's sign-in link, no token."""
    return os.path.join(cache_dir, "login-%s.log" % home_key(codex_home))


def login_failed(cache_dir, codex_home):
    """Why the last sign-in in this folder ended without a login: Codex's last line, kept until the next try."""
    return os.path.join(cache_dir, "login-%s-failed.json" % home_key(codex_home))


def redeem_path(data_dir, codex_home):
    """A Redeem reset in a folder Codex has not said the outcome of: {key, at}. The next press retries it with the same
    key, so Codex counts it as that attempt and never spends a second credit for it. Under paths.data, never the cache,
    which may be purged and would lose the key."""
    return os.path.join(data_dir, "redeem-%s.json" % home_key(codex_home))


def unlink_quietly(*paths):
    for path in paths:
        try:
            os.unlink(path)
        except OSError:
            pass


def signing_in(cache_dir, codex_home):
    """The sign-in link while `codex login` waits in this folder: "" before Codex printed it, None when none runs."""
    marker = read_json(login_path(cache_dir, codex_home)) if cache_dir else None
    if not isinstance(marker, dict) or not isinstance(marker.get("pid"), int):
        return None
    try:
        os.kill(marker["pid"], 0)
    except OSError:
        return None
    return login_link(cache_dir, codex_home) or ""


def read_log(path):
    """A sign-in log's first 64 KB, "" when it can't be read."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read(65536)
    except OSError:
        return ""


def login_link(cache_dir, codex_home):
    """The sign-in link Codex printed in this folder's sign-in log, or None."""
    found = re.search(r"https://\S+", read_log(login_log(cache_dir, codex_home)))
    return found.group(0) if found else None


def failed_line(cache_dir, codex_home):
    """Codex's last line from a sign-in that ended without a login, or None."""
    found = read_json(login_failed(cache_dir, codex_home)) if cache_dir else None
    return found.get("line") if isinstance(found, dict) and isinstance(found.get("line"), str) else None


def load_live(cache_dir, codex_home):
    data = read_json(live_path(cache_dir, codex_home)) if cache_dir else None
    return data if isinstance(data, dict) and number(data.get("at")) is not None else None


def ask_all(cache_dir, homes, deadline):
    """Asks each account at once, saves each answer; {home: answer} for those that answered."""
    found = {}

    def one(path):
        lock = take_lock(cache_dir, lock_name(path)) if cache_dir else None
        if cache_dir and lock is None:
            return  # another run asks Codex or signs in with this folder now: never two on one login
        try:
            answer = ask_codex(path, deadline)
        finally:
            if lock:
                lock.close()
        if answer:
            found[path] = answer
        if cache_dir:  # a failure is saved too, so the next ask waits as long as after an answer
            write_json(live_path(cache_dir, path), answer or {"at": time.time(), "failed": True})

    threads = [threading.Thread(target=one, args=(p,), daemon=True) for p in homes]
    for t in threads:
        t.start()
    for t in threads:
        t.join(max(0.0, deadline - time.monotonic()) + 0.2)
    return dict(found)


def spawn(*args):
    """One detached run of this program with `args` (its process, or None); it quits at once when another holds its
    lock. Its own session keeps it out of the run's process tree, so it outlives the run."""
    try:
        return subprocess.Popen([sys.executable, os.path.abspath(__file__)] + list(args),
                                cwd=os.path.dirname(os.path.abspath(__file__)), stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        return None


def from_live(answer, now):
    """A provider from Codex's own answer."""
    account = answer.get("account")
    if account is None:
        return {"state": "signed_out", "source": "live", "read_at": answer["at"]}
    raw = answer.get("limits") if isinstance(answer.get("limits"), dict) else {}
    windows = codex_windows(raw, ("usedPercent", "windowDurationMins", "resetsAt"), now)
    return {"state": "ok" if windows else "none", "source": "live", "read_at": answer["at"], "windows": windows,
            "who": account.get("email"), "plan": account.get("plan") or plan_words(raw.get("planType")),
            "credits": credits_text(raw.get("credits")), "reset_credits": answer.get("reset_credits")}


def answer_email(answer):
    """The email Codex answered with, lower case; None without one."""
    who = answer.get("account") if isinstance(answer, dict) and not answer.get("failed") else None
    email = who.get("email") if isinstance(who, dict) else None
    return email.lower() if isinstance(email, str) and email else None


def listed_homes(home, run, cache_dir):
    """codex_homes' four lists with other logins and other folders only while the `otherCodex` setting is on, then
    Pilot's own accounts signing in now or signed out ({path: sign-in link or None}), shown as such and never asked,
    then the folders Codex is asked in."""
    setting, own, logins, others = codex_homes(home, run)
    logins, others = (logins, others) if VIEW["otherCodex"] else ([], [])
    pending = {}
    for path in own:
        link = signing_in(cache_dir, path)
        if link is not None or not signed_in(path):
            pending[path] = link
    return setting, own, logins, others, pending, setting + [p for p in own if p not in pending] + logins


def codex_accounts(home, now, run, ask_until=None, fresh=LIVE_FRESH):
    """Every Codex account, asked ones first. `ask_until` (a monotonic deadline) asks Codex again for an answer over
    `fresh` s old (30, a page's 120); without it an answer over 120 s old goes to one background refresh. Pilot's own
    account signing in now or signed out is shown as such and never asked."""
    cache_dir = (run.get("paths") or {}).get("cache")
    setting, own, logins, others, pending, asked = listed_homes(home, run, cache_dir)
    answers = {p: load_live(cache_dir, p) for p in asked}
    stale = [p for p in asked if not answers[p] or now - answers[p]["at"] > (fresh if ask_until else LIVE_STALE)]
    if stale and ask_until:
        answers.update(ask_all(cache_dir, stale, ask_until))
    elif stale and cache_dir and shutil.which("codex"):
        spawn("--codex", cache_dir, *stale)
    out, known = [], set()
    for path in setting + own + logins + others:
        if path in pending:
            failed = failed_line(cache_dir, path) if pending[path] is None else None
            out.append({"state": "signing_in" if pending[path] is not None else "failed" if failed else "signed_out",
                        "link": pending[path], "failed": failed, "home": "Pilot account", "name": "Pilot account",
                        "own": path, "read_at": None, "source": None, "since": "update"})
            continue
        live, answer, email = path in answers, answers.get(path), answer_email(answers.get(path))
        logs = codex_logs(path, now)
        answer = None if answer and answer.get("failed") else answer
        provider = logs
        if answer and (logs["state"] != "ok" or answer["at"] >= (logs["read_at"] or 0)):
            provider = from_live(answer, now)
        if path in logins and email and email in known:
            continue  # the same account as a row above, found again in another folder
        label = "Pilot account" if path in own else "Pilot AI" if path == os.path.join(home, PILOT_AI_CODEX) else tilde(path, home)
        provider.update(home=label, own=path if path in own else None, path=path, same=bool(email and email in known))
        provider["name"] = provider.get("who") or provider["home"]
        provider["since"] = "update" if provider.get("source") == "live" else "run"
        if live or provider["state"] == "ok" or signed_in(path):
            out.append(provider)
            if email:
                known.add(email)
    return out


# Gemini


def gemini_state():
    return "installed" if shutil.which("gemini") else "missing"


def limits(run, now=None, ask_until=None, fresh=LIVE_FRESH):
    """Every provider's limits as a dict."""
    home = os.path.expanduser("~")
    now = time.time() if now is None else now
    return {"now": now, "claude": claude_limits(home, now), "codex": codex_accounts(home, now, run, ask_until, fresh),
            "gemini": gemini_state(), "status": status_read((run.get("paths") or {}).get("cache"), now)}


# Claude Code tokens (footnote)


def claude_root(home):
    return os.path.join(home, ".claude", "projects")


def claude_files(home, now):
    """(mtime, size, path) of Claude Code logs changed in the last 8 days, subagents' included, newest first."""
    found = []
    for folder, _, names in os.walk(claude_root(home)):
        for name in names:
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(folder, name)
            try:
                st = os.stat(path)
            except OSError:
                continue
            if now - st.st_mtime < SCAN_DAYS * DAY:
                found.append((st.st_mtime, st.st_size, path))
    found.sort(reverse=True)
    return found


def load_cache(cache_dir):
    data = read_json(os.path.join(cache_dir, CACHE_FILE)) if cache_dir else None
    files = data.get("files") if isinstance(data, dict) and data.get("version") == CACHE_VERSION else None
    return files if isinstance(files, dict) else {}


def save_cache(cache_dir, files, now):
    if not cache_dir:
        return
    oldest = (now - SCAN_DAYS * DAY) // 60
    for entry in files.values():
        entry["minutes"] = {k: v for k, v in entry["minutes"].items() if int(k) >= oldest}
        if len(entry["seen"]) > SEEN_KEEP:
            entry["seen"] = dict(list(entry["seen"].items())[-SEEN_KEEP:])
    write_json(os.path.join(cache_dir, CACHE_FILE), {"version": CACHE_VERSION, "files": files})


def add_line(entry, raw):
    """Folds one assistant line's usage into the entry's per-minute sums. Claude Code writes a line per content block,
    each repeating the message's usage while its output count grows, so a message id is counted once and only the
    growth of its output is added later."""
    try:
        event = json.loads(raw)
    except ValueError:
        return
    if not isinstance(event, dict) or event.get("type") != "assistant":
        return
    message = event.get("message")
    usage = message.get("usage") if isinstance(message, dict) else None
    stamp = parse_time(event.get("timestamp"))
    if not isinstance(usage, dict) or stamp is None:
        return
    counts = [usage.get(k) if isinstance(usage.get(k), int) else 0 for k in USAGE_KEYS]
    key = message.get("id") or event.get("requestId") or event.get("uuid")
    seen = entry["seen"]
    if key and key in seen:
        minute, counted = seen[key]
        if counts[1] > counted:
            entry["minutes"].setdefault(str(minute), [0, 0, 0, 0])[1] += counts[1] - counted
            seen[key] = [minute, counts[1]]
        return
    minute = int(stamp // 60)
    if key:
        seen[key] = [minute, counts[1]]
    sums = entry["minutes"].setdefault(str(minute), [0, 0, 0, 0])
    for i, n in enumerate(counts):
        sums[i] += n


def scan_file(path, size, mtime, old, deadline):
    """Reads a log from where its cached entry stopped to its last whole line; returns (entry, finished)."""
    if isinstance(old, dict) and isinstance(old.get("offset"), int) and old["offset"] <= size:
        entry = {"offset": old["offset"], "minutes": old.get("minutes") or {}, "seen": old.get("seen") or {}}
    else:
        entry = {"offset": 0, "minutes": {}, "seen": {}}
    finished = True
    with open(path, "rb") as f:
        f.seek(entry["offset"])
        pos = entry["offset"]
        for n, raw in enumerate(f):
            if pos >= size or not raw.endswith(b"\n"):
                break
            pos += len(raw)
            if b'"assistant"' in raw and b'"usage"' in raw:
                add_line(entry, raw)
            if n % 2000 == 1999 and time.monotonic() >= deadline:
                finished = pos >= size
                break
    entry["offset"] = pos
    entry["size"], entry["mtime"] = (size, mtime) if finished else (None, None)
    return entry, finished


def fresh(entry, size, mtime):
    return isinstance(entry, dict) and entry.get("size") == size and entry.get("mtime") == mtime


def refresh_claude(home, cache_dir, now, deadline):
    """Brings the cache up to date until the deadline: (entries by path, every log read)."""
    files = claude_files(home, now)
    cache = load_cache(cache_dir)
    kept, changed, done = {}, False, 0
    for mtime, size, path in files:
        old = cache.get(path)
        if fresh(old, size, mtime):
            kept[path] = old
            done += 1
            continue
        if time.monotonic() >= deadline:
            if isinstance(old, dict):
                kept[path] = old
            continue
        try:
            entry, finished = scan_file(path, size, mtime, old, deadline)
        except OSError:
            continue
        kept[path], changed = entry, True
        done += finished
    if changed or len(kept) != len(cache):
        save_cache(cache_dir, kept, now)
    return kept, done == len(files)


def take_lock(cache_dir, name=LOCK_FILE):
    """A refresh lock, held until its file is closed; None while another refresh holds it."""
    os.makedirs(cache_dir, exist_ok=True)
    handle = open(os.path.join(cache_dir, name), "a")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return handle
    except OSError:
        handle.close()
        return None


def token_blocks(minutes):
    """Five-hour blocks the way ccusage counts them: a block starts at the hour of the first message after a gap of
    5 h or more (or after the previous block's 5 h ran out) and ends 5 h after that hour. Only 8 days of logs are
    read, so a block chain with no 5 h gap in 8 days starts at the oldest message read."""
    out = []
    last = None
    for minute in sorted(minutes):
        t = minute * 60
        if not out or t >= out[-1]["start"] + BLOCK or t - last >= BLOCK:
            out.append({"start": t - t % 3600, "tokens": 0})
        out[-1]["tokens"] += minutes[minute]
        last = t
    return out


def claude_tokens(run, now, deadline, reuse=0):
    """Claude Code tokens in the last 7 days and in the running 5-hour block, read from its logs until `deadline`; a
    full count under `reuse` s old is given again without reading a log."""
    home, cache_dir = os.path.expanduser("~"), (run.get("paths") or {}).get("cache")
    if not os.path.isdir(claude_root(home)):
        return {"state": "missing"}
    last = read_json(os.path.join(cache_dir, TOKENS_FILE)) if cache_dir and reuse else None
    at = number(last.get("at")) if isinstance(last, dict) else None
    if at is not None and 0 <= now - at < reuse and last.get("state") == "ok" and last.get("complete"):
        return last
    lock = take_lock(cache_dir) if cache_dir else None
    if cache_dir and lock is None:
        entries, complete = load_cache(cache_dir), False
    else:
        try:
            entries, complete = refresh_claude(home, cache_dir, now, deadline)
        finally:
            if lock:
                lock.close()
        if not complete and cache_dir:
            spawn("--refresh", cache_dir)
    minutes = {}
    since = now - SCAN_DAYS * DAY
    for entry in entries.values():
        for key, sums in (entry.get("minutes") or {}).items():
            minute = int(key)
            if since <= minute * 60 <= now + 60:
                minutes[minute] = minutes.get(minute, 0) + sum(sums)
    week = sum(n for minute, n in minutes.items() if minute * 60 >= now - 7 * DAY)
    found = token_blocks(minutes)
    block = found[-1]["tokens"] if found and now < found[-1]["start"] + BLOCK else None
    tokens = {"state": "ok", "complete": complete, "week": week, "block": block}
    if cache_dir and complete:
        write_json(os.path.join(cache_dir, TOKENS_FILE), dict(tokens, at=now))
    return tokens


# Words


def short_tokens(n):
    for size, unit in ((1e9, "B"), (1e6, "M"), (1e3, "k")):
        if n >= size:
            value = n / size
            text = ("%.1f" % value) if value < 100 else str(int(round(value)))
            return (text[:-2] if text.endswith(".0") else text) + unit
    return str(n)


def span(seconds):
    seconds = int(abs(seconds))
    if seconds < 60:
        return "under a minute"
    minutes = seconds // 60
    if minutes < 60:
        return "%d min" % minutes
    hours, minutes = divmod(minutes, 60)
    if hours < 24:
        return "%d h %d min" % (hours, minutes) if minutes else "%d h" % hours
    days, hours = divmod(hours, 24)
    return "%d d %d h" % (days, hours) if hours else "%d d" % days


def days_after(moment, now):
    """Calendar days from now's day to moment's: 0 today, 1 tomorrow, -1 yesterday (noon to noon, so DST shifts round)."""
    noon = lambda t: time.mktime(time.localtime(t)[:3] + (12, 0, 0, 0, 0, -1))
    return int(round((noon(moment) - noon(now)) / DAY))


def stamp(moment, now):
    """When numbers were read, short: 11:15 today, yesterday 17:27, Tue 17:27 this week, else 3 Oct 17:27."""
    day = time.localtime(moment)
    days = -days_after(moment, now)
    clock = time.strftime("%H:%M", day)
    if days <= 0:
        return clock
    if days == 1:
        return "yesterday " + clock
    return time.strftime("%a " if days < 7 else "%-d %b ", day) + clock


def until(moment, now):
    """A reset time with its day and how long until it: today 18:04 (in 6 h 2 min)."""
    day = time.localtime(moment)
    name = {0: "today", 1: "tomorrow"}.get(days_after(moment, now)) or time.strftime("%a %-d %b", day)
    return "%s %s (in %s)" % (name, time.strftime("%H:%M", day), span(moment - now))


def tone(percent):
    """A share used in its tone: amber from 60%, red from 85%."""
    return "alert" if percent >= ALERT else "warn" if percent >= WARN else None


def shown(w):
    """The share used a window shows now: 0 once it reset since it was read."""
    return 0.0 if w["reset_since"] else w["percent"]


def left(w):
    return max(0.0, min(100.0, 100.0 - shown(w)))


def whole(x):
    """A non-negative number rounded as Swift rounds it, halves up."""
    return int(x + 0.5)


def percent_text(share):
    """A share as CodexBar writes it: <1% for a sliver, else whole."""
    return "<1%" if 0 < share < 1 else "%.0f%%" % share


def figure_text(w):
    return percent_text(left(w)) + " left"


def eta(seconds):
    """A time ahead as CodexBar's pace writes it, whole minutes rounded up: 2d 12h, 2d 5m, 4h 3m, 58m."""
    minutes = max(1, int(math.ceil(seconds / 60.0)))
    days, hours, rest = minutes // 1440, minutes // 60 % 24, minutes % 60
    if days:
        return "%dd %dh" % (days, hours) if hours else "%dd %dm" % (days, rest) if rest else "%dd" % days
    if hours:
        return "%dh %dm" % (hours, rest) if rest else "%dh" % hours
    return "%dm" % minutes


def reset_note(w, since):
    return "reset since your last %s (was %d%% used)" % (since, round(w["percent"]))


def pace(w, now, headroom=False):
    """(mark, its tone, words) for a window, CodexBar's pace: the mark where its share left should be by now if used
    evenly, green in reserve and red in deficit; how far ahead or behind that it is; whether it lasts until the reset at
    this rate or when it runs out; with `headroom` (Codex), "1.5× headroom" past 15 points in reserve when the rest would
    last 1.5 times as long. Nothing without a reset time and length, once it reset or is used up, or under 3% into the
    window; no mark when on pace (within 2 points), so the mark shows exactly when the words say reserve or deficit."""
    if w["reset_since"] or not w["resets_at"] or not w["minutes"] or not VIEW["pace"]:
        return None, None, None
    length = w["minutes"] * 60.0
    remaining = w["resets_at"] - now
    elapsed = length - remaining
    used = min(max(w["percent"], 0.0), 100.0)
    if remaining <= 0 or elapsed <= 0 or 100.0 * elapsed / length < 3 or used >= 100:
        return None, None, None
    expected = 100.0 * elapsed / length
    gap = expected - used
    if abs(gap) <= 2:
        mark, colour, words = None, None, ["On pace"]
    else:
        mark, colour = round(100.0 - expected, 1), "fine" if gap > 0 else "alert"
        words = ["%d%% in reserve" % whole(gap) if gap > 0 else "%d%% in deficit" % whole(-gap)]
    rate = used / elapsed
    if used == 0 or (100 - used) / rate >= remaining:
        words.append("Lasts until reset")
        if headroom and gap > 15 and used > 0 and (100 - used) / (rate * remaining) >= 1.5:
            words.append("1.5× headroom")
    else:
        words.append("%s in %s" % ("Projected empty" if w["minutes"] == SESSION else "Runs out", eta((100 - used) / rate)))
    return mark, colour, " · ".join(words)


def figures_text(provider):
    return ", ".join("%s %s" % (w["name"], figure_text(w)) for w in provider["windows"])


CLAUDE_UNKNOWN = "Unknown until your next Claude Code reply."
CODEX_WORDS = {"missing": ("no logs", "Codex didn't answer and has no logs here. Run Codex once."),
               "none": ("no run in 8 days", "No Codex run in 8 days, so both windows have reset."),
               "signed_out": ("signed out", "Codex is signed out here. Run `codex login` in a terminal.")}
OWN_WORDS = {"signing_in": ("signing in", "Waiting for you to sign in to Codex in your browser, with the account to add."),
             "signed_out": ("not signed in", "Not signed in yet: sign in with the account to add.")}
OWN_QUIET = ("unavailable", "Codex didn't answer for this account. Sign in again.")
OWN_FAILED = ("sign-in failed", "Codex's sign-in stopped without signing in: %s")
SAME = "This is the same account as one above: remove it, then add the other one."
GEMINI_WORDS = ("limit unknown", "Gemini keeps no limit on this Mac, and asking Google needs your sign-in token, which "
                                  "Pilot never reads.")
FOOTNOTE = "Codex's numbers come from Codex itself. Pilot reads no sign-in tokens."


def codex_words(codex):
    if codex["own"] and codex["state"] == "failed":
        return OWN_FAILED[0], OWN_FAILED[1] % codex["failed"]
    if codex["own"]:
        return OWN_WORDS.get(codex["state"], OWN_QUIET)
    return CODEX_WORDS[codex["state"]]


def codex_read(codex, now):
    """When an account's numbers were read: Updated 16:23 (Codex's answer), Last run Tue 22:35 (its logs)."""
    if not codex["read_at"]:
        return "Last run unknown"
    return ("Updated " if codex["source"] == "live" else "Last run ") + stamp(codex["read_at"], now)


def summary_line(data):
    claude = data["claude"]
    parts = ["Claude: " + figures_text(claude) if claude["state"] == "ok" else "Claude unknown"]
    known = [c for c in data["codex"] if c["state"] == "ok"]
    for codex in known:
        parts.append("Codex%s: %s" % (" " + codex["name"] if len(known) > 1 else "", figures_text(codex)))
    return " · ".join(parts)


# Blocks: a section card per provider and account (Surfaces v2), CodexBar's menu


def window_note(w, since, now, headroom=False):
    """What a window's line says under its bar: that it reset, its pace, or that its reset time is unknown; None."""
    if w["reset_since"]:
        return reset_note(w, since)
    return pace(w, now, headroom)[2] or (None if w["resets_at"] else "reset time unknown")


def meter(w, since, now, headroom=False):
    """A window as CodexBar draws it: the share left, draining; the pace mark in its tone and the words; the reset."""
    m = {"type": "meter", "label": w["name"], "percent": round(left(w), 1), "value": figure_text(w)}
    note = window_note(w, since, now, headroom)
    if not w["reset_since"]:
        m["tone"] = tone(w["percent"]) or "fine"
        mark, colour, _ = pace(w, now, headroom)
        if mark is not None:
            m["mark"], m["markTone"] = mark, colour
        if w["resets_at"]:
            m["resetsAt"] = int(w["resets_at"])
    if note:
        m["note"] = note
    return m


def section(title, subtitle, aside, aside_note, blocks):
    """A card as CodexBar heads it: the provider and when it was read on the left, the account and plan on the right."""
    card = {"type": "section", "title": title, "subtitle": subtitle, "aside": aside, "asideNote": aside_note,
            "blocks": blocks}
    return {k: v for k, v in card.items() if v is not None}


def claude_card(claude, now):
    if claude["state"] != "ok":
        return section("Claude", "Unknown", claude.get("who"), claude.get("plan"),
                       [{"type": "markdown", "text": CLAUDE_UNKNOWN}])
    return section("Claude", "Updated " + stamp(claude["read_at"], now), claude.get("who"), claude.get("plan"),
                   [meter(w, "Claude Code reply", now) for w in claude["windows"]])


def reset_credits_text(found, now):
    if not found or found["count"] <= 0:
        return None
    text = "**Limit reset credits:** %d available" % found["count"]
    if found["expires"]:
        text += " · expire " + ", ".join(stamp_ahead(t, now) for t in found["expires"])
    return text


def stamp_ahead(moment, now):
    """A day ahead, short: 29 Oct 19:35 (with the year when it is not this one)."""
    day = time.localtime(moment)
    return time.strftime("%-d %b %H:%M" if day.tm_year == time.localtime(now).tm_year else "%-d %b %Y %H:%M", day)


def account_buttons(codex, page):
    """A Pilot account's buttons: sign in (or open the sign-in page) and remove; on a page only once it answers."""
    home, actions = codex["own"], []
    if codex["state"] == "signing_in" and codex.get("link"):
        actions.append({"type": "open", "url": codex["link"], "title": "Open sign-in page"})
    elif codex["state"] != "signing_in" and (codex["state"] != "ok" or codex.get("same")):
        actions.append({"type": "run", "command": "add-account", "context": {"home": home}, "title": "Sign in…"})
    if page or codex["state"] != "ok" or codex.get("same"):
        actions.append({"type": "run", "command": "remove-account", "context": {"home": home}, "title": "Remove",
                        "ask": {"confirm": "Remove this Codex account from Pilot? Codex signs it out on this Mac."},
                        "destructive": True})
    return [{"type": "buttons", "actions": actions}] if actions else []


def redeem_button(codex):
    """Redeem reset, on an account Codex says holds a limit reset credit: one is spent only after the confirm, whose
    question fits the popover's two lines."""
    found = codex.get("reset_credits")
    if not found or found["count"] <= 0 or not codex.get("path"):
        return []
    ask = "Reset Codex's limits for %s now? It spends 1 of your %d reset credit%s." % (
        codex["name"], found["count"], "" if found["count"] == 1 else "s")
    return [{"type": "buttons", "actions": [{"type": "run", "command": "redeem-reset", "context": {"home": codex["path"]},
                                             "title": "Redeem reset…", "ask": {"confirm": ask}}]}]


def codex_card(codex, now, page=False):
    own = codex.get("own")
    if codex["state"] != "ok":
        words, text = codex_words(codex)
        blocks = [{"type": "markdown", "text": text}] + (account_buttons(codex, page) if own else [])
        return section("Codex", words[0].upper() + words[1:], codex["name"], None, blocks)
    blocks = [meter(w, codex["since"], now, headroom=True) for w in codex["windows"]]
    credits = reset_credits_text(codex.get("reset_credits"), now)
    if credits:
        blocks.append({"type": "markdown", "text": credits})
        blocks += redeem_button(codex)
    if codex["credits"] is not None:
        blocks.append({"type": "stats", "items": [{"label": "Credits", "value": codex["credits"]}]})
    if own and codex.get("same"):
        blocks.append({"type": "markdown", "text": SAME})
    if own:
        blocks += account_buttons(codex, page)
    return section("Codex", codex_read(codex, now), codex["name"], codex.get("plan"), blocks)


def show_gemini(data):
    """Gemini only once its CLI is on PATH, and only while the setting shows it."""
    return VIEW["gemini"] and data["gemini"] == "installed"


def gemini_card():
    words, text = GEMINI_WORDS
    return section("Gemini", words[0].upper() + words[1:], None, None, [{"type": "markdown", "text": text}])


def cards(data, page=False):
    now = data["now"]
    out = [claude_card(data["claude"], now)] + [codex_card(c, now, page) for c in data["codex"]]
    return out + [gemini_card()] if show_gemini(data) else out


# The calm popover (Pilot Q138, design A): the same cards with their words cut. Pace words, emails, credit expiry and
# status words go on hover; an account with nothing to show is one quiet line; the status pages, dashboards and Add
# Codex account are one row of links beside Open page; the footnote stays on the page. Sent only to a Pilot that draws
# note and links blocks.

STALE = 30 * 60  # a read older than this says when it was read under its card's title


def draws_calm(run):
    """Whether this Pilot draws the calm popover: its run message's `pilot.blocks` names note and links; an older Pilot
    names neither, and gets the cards with their words."""
    pilot = run.get("pilot")
    listed = [k.strip() for k in str(pilot.get("blocks") or "").split(",")] if isinstance(pilot, dict) else []
    return "note" in listed and "links" in listed


def short_name(name):
    """An account as a card's head shows it: an email's name before the @, a folder as it is."""
    return name.split("@")[0] if name and "@" in name else name


def sentence(words):
    return words[0].upper() + words[1:] if words else words


def calm_section(icon, title, subtitle, name, plan, help_words, blocks):
    card = {"type": "section", "icon": icon, "title": title, "subtitle": subtitle, "aside": short_name(name),
            "asideNote": plan, "help": " · ".join(w for w in help_words if w) or None, "blocks": blocks}
    return {k: v for k, v in card.items() if v is not None}


def calm_meter(w, since, now, headroom=False):
    """A meter as meter() draws it, its words on hover in place of its line."""
    m = meter(w, since, now, headroom)
    if "note" in m:
        m["help"] = sentence(m.pop("note"))
    return m


def calm_credits(found, now):
    """Codex's limit reset credits as one note: how many, the next expiry, every expiry on hover."""
    if not found or found["count"] <= 0:
        return None
    note = {"type": "note", "icon": "reset",
            "text": "%d reset credit%s" % (found["count"], "" if found["count"] == 1 else "s")}
    if found["expires"]:
        first = min(found["expires"])
        note["aside"] = "next expires " + time.strftime("%-d %b", time.localtime(first))
        note["help"] = "Expire " + ", ".join(stamp_ahead(t, now) for t in found["expires"])
    return note


def calm_claude(claude, now):
    if claude["state"] != "ok":
        return calm_section("claude", "Claude", "unknown", claude.get("who"), None,
                            [CLAUDE_UNKNOWN, claude.get("who"), claude.get("plan")], [])
    read = "Updated " + stamp(claude["read_at"], now)
    stale = now - claude["read_at"] > STALE
    return calm_section("claude", "Claude", read if stale else None, claude.get("who"), claude.get("plan"),
                        [claude.get("who"), None if stale else read],
                        [calm_meter(w, "Claude Code reply", now) for w in claude["windows"]])


def calm_codex(codex, now):
    own = codex.get("own")
    if codex["state"] != "ok":
        words, text = codex_words(codex)
        if own:
            return calm_section("openai", "Codex", sentence(words), codex["name"], None, [codex["name"]],
                                [{"type": "markdown", "text": text}] + account_buttons(codex, False))
        return calm_section("openai", "Codex", words, codex["name"], None, [text], [])
    blocks = [calm_meter(w, codex["since"], now, headroom=True) for w in codex["windows"]]
    credits = calm_credits(codex.get("reset_credits"), now)
    if credits:
        blocks.append(credits)
        blocks += redeem_button(codex)
    if codex["credits"] is not None:
        blocks.append({"type": "stats", "items": [{"label": "Credits", "value": codex["credits"]}]})
    if own and codex.get("same"):
        blocks.append({"type": "markdown", "text": SAME})
    if own:
        blocks += account_buttons(codex, False)
    read = codex_read(codex, now)
    shown = codex["source"] != "live" or not codex["read_at"] or now - codex["read_at"] > STALE
    return calm_section("openai", "Codex", read if shown else None, codex["name"], codex.get("plan"),
                        [codex["name"], None if shown else read], blocks)


def calm_gemini():
    words, text = GEMINI_WORDS
    return calm_section(None, "Gemini", words, None, None, [text], [])


def calm_cards(data):
    """The cards, then the accounts with nothing to show, a quiet line each."""
    now = data["now"]
    out = [calm_claude(data["claude"], now)] + [calm_codex(c, now) for c in data["codex"]]
    if show_gemini(data):
        out.append(calm_gemini())
    return [c for c in out if c["blocks"]] + [c for c in out if not c["blocks"]]


def calm_links(data):
    """One row under the cards: each status page as its name and a dot (its word when not fine, the rest on hover),
    the usage dashboards behind one icon, Add Codex account."""
    items = []
    for key, title in PROVIDERS:
        status = data["status"].get(key)
        link = {"title": title, "actions": [{"type": "open", "url": STATUS_PAGES[key] + "/", "title": "Open %s status page" % title}]}
        if isinstance(status, dict) and isinstance(status.get("description"), str):
            words = status["description"]
            if status.get("updated"):
                words += " · updated %s ago" % span(data["now"] - status["updated"])
            level = {"minor": "warn", "maintenance": "warn", "major": "alert", "critical": "alert"}.get(status.get("indicator"))
            link["tone"] = level or "fine"
            if level:
                link["word"] = status["indicator"]
            link["help"] = "%s status: %s" % (title, words)
        else:
            link["help"] = "%s status unknown" % title
        items.append(link)
    items.append({"icon": "chart", "help": "Usage dashboards",
                  "actions": [{"type": "open", "url": DASHBOARDS[key], "title": "%s usage dashboard" % title} for key, title in PROVIDERS]})
    items.append({"icon": "plus", "help": "Add Codex account…",
                  "actions": [{"type": "run", "command": "add-account", "title": "Add Codex account…"}]})
    return {"type": "links", "items": items}


def links(data):
    """CodexBar's menu rows under the cards: each status page with its word, the usage dashboards, Add Codex account."""
    items = []
    for key, title in PROVIDERS:
        status = data["status"].get(key)
        row = {"title": "%s status" % title, "subtitle": "unknown",
               "actions": [{"type": "open", "url": STATUS_PAGES[key] + "/", "title": "Open status page"}]}
        if isinstance(status, dict) and isinstance(status.get("description"), str):
            row["subtitle"] = status["description"]
            if status.get("updated"):
                row["subtitle"] += " · updated %s ago" % span(data["now"] - status["updated"])
            level = {"minor": "warn", "maintenance": "warn", "major": "alert", "critical": "alert"}.get(status.get("indicator"))
            if level:
                row["badges"] = [{"text": status["indicator"], "tone": level}]
        items.append(row)
    for key, title in PROVIDERS:
        items.append({"title": "%s usage dashboard" % title,
                      "actions": [{"type": "open", "url": DASHBOARDS[key], "title": "Open usage dashboard"}]})
    items.append({"title": "Add Codex account…", "actions": [{"type": "run", "command": "add-account",
                                                              "title": "Add Codex account…"}]})
    return {"type": "list", "items": items}


def token_note(tokens):
    if tokens["state"] != "ok":
        return "No Claude Code logs on this Mac (~/.claude/projects), so no token counts."
    block = tokens["block"]
    words = "Claude Code tokens: %s in the last 7 days, %s in this 5-hour block. They come from Claude Code's own " \
            "logs and aren't your limit." % (short_tokens(tokens["week"]), "none" if block is None else short_tokens(block))
    if not tokens["complete"]:
        words = "Still counting Claude Code's logs, so these grow on the next refresh. " + words
    return words


def bar_line(data):
    """The menu bar, CodexBar's: each provider set to show, its logo and its session left (Claude, Codex's first
    account with numbers), or its most used window's, each in the tone of its most used window; the item's tone the
    most used of them; AI when none is known. (gauges, text, tone)"""
    gauges, used = [], []
    codex = next((c for c in data["codex"] if c["state"] == "ok"), None)
    for icon, name, provider in (("claude", "claude", data["claude"]), ("openai", "codex", codex)):
        if provider and provider["state"] == "ok" and VIEW["barProviders"] in ("both", name):
            windows = provider["windows"]
            w = max(windows, key=shown) if VIEW["barWindow"] == "tightest" else windows[0]
            most = max(shown(x) for x in windows)
            gauges.append({k: v for k, v in (("icon", icon), ("text", percent_text(left(w))), ("tone", tone(most))) if v})
            used.append(most)
    return gauges, ("" if gauges else "AI"), tone(max(used, default=0))


# Commands


def blocks_answer(data, blocks, every=SIGNING_IN_REFRESH):
    """A popover's or page's answer, asked again every `every` s while an account signs in, so it shows as it's done."""
    answer = {"type": "blocks", "blocks": blocks}
    if any(c["state"] == "signing_in" for c in data["codex"]):
        answer["refresh"] = every
    return answer


def popover_blocks(data, run):
    """The popover's blocks: calm for a Pilot that draws them, else the cards with their words and the footnote."""
    if draws_calm(run):
        return calm_cards(data) + [calm_links(data)]
    return cards(data) + [links(data), {"type": "markdown", "text": FOOTNOTE}]


def show_bar(run):
    if run.get("surface") == "popover":
        data = limits(run, ask_until=START + LIVE_WAIT)
        send(blocks_answer(data, popover_blocks(data, run)))
        return
    data = limits(run)
    gauges, text, level = bar_line(data)
    shown = calm_cards(data) + [calm_links(data)] if draws_calm(run) else cards(data) + [links(data)]
    send({"type": "bar", "text": text, "gauges": gauges, "tone": level, "blocks": shown})


def show_page(run):
    # Every 60 s while Home shows: Codex is asked when its answer is past the bar's 120 s, not at every run.
    data = limits(run, ask_until=START + PAGE_WAIT, fresh=LIVE_STALE)
    tokens = claude_tokens(run, data["now"], START + PAGE_SCAN, reuse=TOKENS_FRESH)
    send(blocks_answer(data, cards(data, page=True) + [links(data),
        {"type": "markdown", "text": token_note(tokens) + " " + FOOTNOTE},
        {"type": "buttons", "actions": [{"type": "run", "command": "refresh", "title": "Refresh now", "icon": "refresh"},
                                        {"type": "copy", "text": summary_line(data), "title": "Copy summary"}]}],
        PAGE_SIGNING_IN_REFRESH))


def refresh(run):
    """The page's Refresh now: every Codex account asked again whatever its answer's age, and Claude Code's tokens counted
    again from its logs; the page asks again as the run ends, so it draws what this read."""
    now = time.time()
    data = limits(run, now, ask_until=START + REFRESH_WAIT, fresh=0)
    claude_tokens(run, now, START + REFRESH_WAIT + PAGE_SCAN)
    send({"type": "hud", "text": "AI usage refreshed: %s" % summary_line(data)})


def bar(fraction):
    filled = max(0, min(BAR, int(round(fraction * BAR))))
    return "`%s%s`" % ("▓" * filled, "░" * (BAR - filled))


def windows_markdown(provider, since, now, md, rows, title, headroom=False):
    for w in provider["windows"]:
        reset = "resets " + until(w["resets_at"], now) if w["resets_at"] and not w["reset_since"] else None
        text = " · ".join(p for p in (figure_text(w), reset, window_note(w, since, now, headroom)) if p)
        md.append("- **%s** %s %s" % (w["name"], bar(left(w) / 100.0), text))
        rows.append({"label": "%s %s" % (title, w["name"].lower()), "text": text})


def show_usage(run):
    data = limits(run)
    now, claude = data["now"], data["claude"]
    tokens = claude_tokens(run, now, START + DETAIL_SCAN)
    md, rows = ["## Claude"], []
    if claude["state"] == "ok":
        windows_markdown(claude, "Claude Code reply", now, md, rows, "Claude")
        md += ["", "%s, read %s." % (subtitle(claude.get("who"), claude.get("plan")) or "Claude Code",
                                     stamp(claude["read_at"], now))]
    else:
        md.append(CLAUDE_UNKNOWN)
        rows.append({"label": "Claude", "text": "unknown"})
    for codex in data["codex"]:
        md += ["", "## Codex · %s" % codex["name"]]
        if codex["state"] == "ok":
            windows_markdown(codex, codex["since"], now, md, rows, "Codex", headroom=True)
            credits = reset_credits_text(codex.get("reset_credits"), now)
            if credits:
                md.append("- " + credits)
            if codex["credits"] is not None:
                md.append("- **Credits** %s" % codex["credits"])
                rows.append({"label": "Codex credits", "text": codex["credits"]})
            md += ["", "%s, %s." % (codex.get("plan") or "Codex", codex_read(codex, now).lower())]
        else:
            md.append(codex_words(codex)[1])
    if show_gemini(data):
        words, text = GEMINI_WORDS
        md += ["", "## Gemini", "**%s.** %s" % (words.capitalize(), text)]
    md += ["", "---", "", token_note(tokens), "", FOOTNOTE]
    send({"type": "detail", "markdown": "\n".join(md) + "\n", "metadata": rows, "blocks": detail_cards(data),
          "actions": [{"type": "copy", "text": summary_line(data), "title": "Copy summary"}]})


def detail_cards(data):
    """The page's cards for the detail (Pilot 1.1, ADR 0010 amended 2026-10-30): drawn in place of its markdown, which
    stays for a Pilot that ignores `blocks`. No buttons: a detail runs only its own actions, so Add or Remove would do
    nothing there."""
    return [dict(c, blocks=[b for b in c["blocks"] if b["type"] != "buttons"]) for c in cards(data)]


def subtitle(*parts):
    return " · ".join(p for p in parts if p)


def show_summary(run):
    send({"type": "hud", "text": summary_line(limits(run, ask_until=START + LIVE_WAIT))})


def run_paths(run):
    paths = run.get("paths") or {}
    return paths.get("data"), paths.get("cache")


def chosen_account(run, data_dir):
    """The Pilot account a button named in its context, or None."""
    context = run.get("context") if isinstance(run.get("context"), dict) else {}
    home = context.get("home")
    return home if isinstance(home, str) and home in own_accounts(data_dir) else None


def add_account(run):
    """Takes the account a Sign in button named, else one of Pilot's still not signed in, else makes one, and starts
    Codex's own `codex login` in it, detached, so the browser sign-in may take longer than a command's 30 s; Codex
    opens the sign-in page and writes its login there itself. Waits up to LINK_WAIT s for Codex's link, so the alert
    carries it (a way in when no page opened) or says why Codex stopped."""
    data_dir, cache_dir = run_paths(run)
    if not data_dir or not cache_dir:
        send({"type": "error", "text": "got no data folder to keep the account in"})
        return
    if not shutil.which("codex"):
        send({"type": "hud", "text": "Codex isn't installed on this Mac: install it, then add the account"})
        return
    own = own_accounts(data_dir)
    # A click that seemed to do nothing is clicked again: reuse an account still signing in or never signed in.
    home = chosen_account(run, data_dir) or next((p for p in own if signing_in(cache_dir, p) is not None), None) or next(
        (p for p in own if not os.path.exists(os.path.join(p, "auth.json"))), None)
    if home is None:
        home = os.path.join(data_dir, ACCOUNTS, str(max((int(os.path.basename(p)) for p in own), default=0) + 1))
        os.makedirs(home, mode=0o700, exist_ok=True)
    if signing_in(cache_dir, home) is not None:
        send(sign_in_alert("Already waiting for that sign-in in your browser", login_link(cache_dir, home)))
        return
    unlink_quietly(login_failed(cache_dir, home))
    child = spawn("--login", home, cache_dir)
    if child is None:
        send({"type": "error", "text": "could not start Codex's sign-in"})
        return
    write_json(login_path(cache_dir, home), {"at": time.time(), "pid": child.pid})
    deadline, link = time.monotonic() + LINK_WAIT, None
    while link is None and child.poll() is None and time.monotonic() < deadline:
        time.sleep(0.1)
        link = login_link(cache_dir, home)
    if link is None and child.poll() is not None and not os.path.exists(os.path.join(home, "auth.json")):
        send({"type": "alert", "text": "Codex's sign-in stopped", "sound": "Basso",
              "note": failed_line(cache_dir, home) or "Codex ended without signing in. Try Add Codex account again."})
        return
    send(sign_in_alert("Sign in to Codex in your browser", link))


def sign_in_alert(text, link):
    """The alert a sign-in shows: which account to use, and Codex's sign-in page when its link is known."""
    alert = {"type": "alert", "text": text,
             "note": "Use the account to add: if the browser is signed in to ChatGPT with another one, sign out there "
                     "first. It shows in AI usage once you're in."}
    if link:
        alert["actions"] = [{"type": "open", "url": link, "title": "Open sign-in page"}]
    return alert


def remove_account(run):
    """Stops a sign-in still waiting, has Codex sign the account out (`codex logout`), then deletes its folder."""
    data_dir, cache_dir = run_paths(run)
    home = chosen_account(run, data_dir)
    if home is None or not cache_dir:
        send({"type": "hud", "text": "That Codex account is already gone"})
        return
    marker = read_json(login_path(cache_dir, home))
    if signing_in(cache_dir, home) is not None:
        try:
            os.killpg(marker["pid"], signal.SIGTERM)  # the sign-in runs in its own session: its codex goes too
        except OSError:
            pass
        time.sleep(0.5)
    lock = take_lock(cache_dir, lock_name(home))
    if lock is None:
        send({"type": "hud", "text": "Codex is busy with that account: try again in a moment"})
        return
    try:
        program = shutil.which("codex")
        if program and os.path.exists(os.path.join(home, "auth.json")):
            try:
                subprocess.run([program, "logout"], env=dict(os.environ, CODEX_HOME=home), stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
            except (OSError, subprocess.TimeoutExpired):
                pass
        shutil.rmtree(home, ignore_errors=True)
        unlink_quietly(live_path(cache_dir, home), login_path(cache_dir, home), login_failed(cache_dir, home))
    finally:
        lock.close()
    send({"type": "hud", "text": "Removed the Codex account from Pilot"})


# What each of Codex's consume outcomes means, as Codex's own Redeem reset says it.
REDEEMED = {"reset": "Codex usage reset", "nothingToReset": "Your Codex usage doesn't need a reset right now",
            "noCredit": "That Codex account has no limit reset credits left",
            "alreadyRedeemed": "That reset credit was already used"}


def asked_account(run):
    """The Codex folder a button named, when AI usage asks Codex in it now (codex_accounts' own filter: no other login
    while List other Codex folders is off, no Pilot account signed out or signing in); None for any other."""
    context = run.get("context") if isinstance(run.get("context"), dict) else {}
    home = context.get("home")
    asked = listed_homes(os.path.expanduser("~"), run, (run.get("paths") or {}).get("cache"))[-1]
    return home if isinstance(home, str) and home in asked else None


def redeem_reset(run):
    """Redeem reset (asked first on its button): one limit reset credit spent on the account the button named, through
    Codex's own `account/rateLimitResetCredit/consume`, the backend picking the credit. One idempotency key per press,
    kept in paths.data until Codex says its outcome: a press after one Codex never answered (quiet, an error, or the
    run stopped) retries that attempt with its key. Nothing is spent unless the key reads back from paths.data and the
    account's lock is held (its cache folder). After a reset, or a credit already used, that account is asked again, so
    its card shows it; the page asks again as the run ends."""
    data_dir, cache_dir = run_paths(run)
    if not data_dir or not cache_dir:
        send({"type": "error", "text": "got no %s folder, so nothing was spent" % ("data" if not data_dir else "cache")})
        return
    home = asked_account(run)
    if home is None:
        send({"type": "hud", "text": "That Codex account is no longer in AI usage"})
        return
    if not shutil.which("codex"):
        send({"type": "hud", "text": "Codex isn't installed on this Mac"})
        return
    lock = take_lock(cache_dir, lock_name(home))
    if lock is None:
        send({"type": "hud", "text": "Codex is busy with that account: try again in a moment"})
        return
    answer, outcome, left = {}, None, None
    try:
        unanswered = read_json(redeem_path(data_dir, home))
        key = unanswered["key"] if isinstance(unanswered, dict) and isinstance(unanswered.get("key"), str) else str(uuid.uuid4())
        # Kept before Codex is asked, so a run stopped mid-call retries this attempt too; write_json swallows a failed
        # write, so the key is read back, and a key not on disk spends nothing.
        write_json(redeem_path(data_dir, home), {"key": key, "at": time.time()})
        if (read_json(redeem_path(data_dir, home)) or {}).get("key") != key:
            send({"type": "error", "text": "could not save the reset's key in its data folder, so nothing was spent"})
            return
        answers = codex_rpc(home, [{"id": 2, "method": "account/rateLimitResetCredit/consume",
                                    "params": {"idempotencyKey": key}}], time.monotonic() + REDEEM_WAIT)
        answer = (answers or {}).get(2) or {}
        outcome = (answer.get("result") or {}).get("outcome") if isinstance(answer.get("result"), dict) else None
        if outcome in REDEEMED:
            unlink_quietly(redeem_path(data_dir, home))  # its outcome is known: the next press is a new attempt
        if outcome in ("reset", "alreadyRedeemed"):
            fresh = ask_codex(home, START + 28)
            if fresh:
                write_json(live_path(cache_dir, home), fresh)
                left = (fresh.get("reset_credits") or {}).get("count")
            else:
                unlink_quietly(live_path(cache_dir, home))  # the next look asks Codex again
    finally:
        if lock:
            lock.close()
    if outcome in REDEEMED:
        more = " · %d reset credit%s left" % (left, "" if left == 1 else "s") if left is not None else ""
        send({"type": "hud", "text": REDEEMED[outcome] + more})
    elif isinstance(answer.get("error"), dict):
        send({"type": "alert", "text": "Codex didn't redeem the reset", "sound": "Basso",
              "note": str(answer["error"].get("message") or "Codex gave no reason.")[:200]})
    else:
        send({"type": "alert", "text": "Codex didn't answer about the reset", "sound": "Basso",
              "note": "Redeem reset again retries this same attempt, so it can't spend a second credit."})


def status_read(cache_dir, now):
    """The status pages' last read; one older than 5 minutes goes to a detached refresh."""
    data = read_json(os.path.join(cache_dir, STATUS_FILE)) if cache_dir else None
    data = data if isinstance(data, dict) and number(data.get("at")) is not None else None
    if cache_dir and (data is None or now - data["at"] > STATUS_EVERY):
        write_json(os.path.join(cache_dir, STATUS_FILE), dict(data or {}, at=now))  # claimed: one read per 5 minutes
        spawn("--status", cache_dir)
    return data or {}


def background_status(cache_dir):
    """Reads each status page's api/v2/status.json (Statuspage's shape: status.indicator and description, page's
    updated_at); a page that fails is left out until the next read."""
    from urllib.request import urlopen  # only this background run reaches the network
    signal.alarm(40)
    lock = take_lock(cache_dir, STATUS_LOCK)
    if lock is None:
        return
    try:
        found = {"at": time.time()}
        for key, base in STATUS_PAGES.items():
            try:
                with urlopen(base + "/api/v2/status.json", timeout=10) as answer:
                    data = json.loads(answer.read(262144))
                status, page = data.get("status") or {}, data.get("page") or {}
                found[key] = {"indicator": status.get("indicator"), "description": status.get("description"),
                              "updated": parse_time(page.get("updated_at"))}
            except (OSError, ValueError, AttributeError):
                continue
        write_json(os.path.join(cache_dir, STATUS_FILE), found)
    finally:
        lock.close()


def background_login(codex_home, cache_dir):
    """Runs Codex's own `codex login` in a Pilot account's folder, holding the folder's lock so nothing asks Codex
    there meanwhile; its output (the sign-in link) goes to a log the card reads, removed when it ends."""
    lock = take_lock(cache_dir, lock_name(codex_home))
    if lock is None:
        return
    log = login_log(cache_dir, codex_home)
    try:
        with open(log, "w") as out:
            subprocess.run([shutil.which("codex") or "codex", "login"], env=dict(os.environ, CODEX_HOME=codex_home),
                           stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT, timeout=LOGIN_WAIT)
        why = last_line(log)
    except OSError:
        why = "Codex didn't start"
    except subprocess.TimeoutExpired:
        why = "it waited %d minutes for the browser" % (LOGIN_WAIT // 60)
    finally:
        if not os.path.exists(os.path.join(codex_home, "auth.json")):
            write_json(login_failed(cache_dir, codex_home), {"at": time.time(), "line": why or "Codex ended without a word"})
        unlink_quietly(login_path(cache_dir, codex_home), log, live_path(cache_dir, codex_home))
        lock.close()


def last_line(path):
    """A log's last line with words in it, colour codes and links left out, at most 160 characters."""
    lines = [re.sub(r"\x1b\[[0-9;]*m|https://\S+", "", l).strip() for l in read_log(path).splitlines()]
    lines = [l for l in lines if l]
    return lines[-1][:160] if lines else None


def background_refresh(cache_dir):
    signal.alarm(int(REFRESH_SCAN) + 30)
    lock = take_lock(cache_dir)
    if lock is None:
        return
    try:
        refresh_claude(os.path.expanduser("~"), cache_dir, time.time(), time.monotonic() + REFRESH_SCAN)
    finally:
        lock.close()


def background_codex(cache_dir, homes):
    """Asks Codex for each account the bar found stale; one at a time across runs."""
    signal.alarm(30)
    lock = take_lock(cache_dir, CODEX_LOCK)
    if lock is None:
        return
    try:
        ask_all(cache_dir, homes, time.monotonic() + 20)
    finally:
        lock.close()


COMMANDS = {"usage": show_usage, "summary": show_summary, "page": show_page, "bar": show_bar,
            "add-account": add_account, "remove-account": remove_account, "refresh": refresh, "redeem-reset": redeem_reset}


def main():
    if len(sys.argv) == 3 and sys.argv[1] in ("--refresh", "--status"):
        (background_refresh if sys.argv[1] == "--refresh" else background_status)(sys.argv[2])
        return
    if len(sys.argv) == 4 and sys.argv[1] == "--login":
        background_login(sys.argv[2], sys.argv[3])
        return
    if len(sys.argv) >= 4 and sys.argv[1] == "--codex":
        background_codex(sys.argv[2], sys.argv[3:])
        return
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        send({"type": "error", "text": "got a run message it could not read"})
        return
    configure(run)
    command = COMMANDS.get(run.get("command"))
    if command:
        command(run)
    else:
        send({"type": "error", "text": "has no command %s" % run.get("command")})


if __name__ == "__main__":
    main()
