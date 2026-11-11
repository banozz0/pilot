#!/usr/bin/env python3
"""lazygit for Pilot (the extension id stays git): every repo under the repos folder with its branch, uncommitted changes and commits to push or pull,
in Hyper+Space, a menu-bar item with a popover, and a page (Surfaces v2, Pilot story 165).

State comes from `git --no-optional-locks status --porcelain=v2 --branch`, eight repos at a time under a deadline that
keeps each answer inside Pilot's limits (2 s for the list and the bar, 5 s for the popover and the page); a repo that
does not answer in time shows what paths.cache/status.json last saw. The repos folder is Pilot's (`pilot.repos` in the
run message), else the Repos folder preference.

Fetching asks the remotes, so it runs only when the popover or the page opens and the last fetch started 10 min ago
or more, or on Fetch all; never from the bar command, never on a timer. It runs as `main.py --fetch`, a detached child
(its own session, output to nowhere) fetching four repos at a time, while a lock held with flock keeps two from
overlapping; the view asks again every 2 s until it ends. Pull is `git pull --ff-only`; push runs only when ahead of an
upstream; anything harder (diverged, conflicts, commits) goes to lazygit, which a row opens in Pilot's terminal (Open in
<terminal> when lazygit is not installed).

The page (Sven, 2026-10-31: a page acts in place) adds a box that finds any repo as it is typed, clean ones too (its
`find` run keeps the text in paths.cache/find.json), and a terminal button on each row beside Pull and Push.
"""
import fcntl
import functools
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, wait

MAX_DEPTH = 3
SKIP = {"node_modules", "build", "dist", "target", "DerivedData", "Pods", "venv", "__pycache__"}
WORKERS = 8
BUDGET = {"popover": 3.5, "page": 3.5}  # seconds for git status; anything else (list, bar) gets DEFAULT_BUDGET
DEFAULT_BUDGET = 1.2
FETCH_EVERY = 600
FETCH_AT_ONCE = 4
FETCH_REPO_TIMEOUT = 30
FETCH_TIMEOUT = 180
SYNC_TIMEOUT = 25
FETCHING_REFRESH = 2
STATUS, FETCH_STATE, LOCK = "status.json", "fetch.json", "fetch.lock"
FIND = "find.json"  # the page's search, as its box last ran it
FIND_KEPT = 600  # a search older than this is forgotten, so a page opened later shows what needs you again
GHOSTTY_ID = "com.mitchellh.ghostty"
GHOSTTY = ["/Applications/Ghostty.app", os.path.expanduser("~/Applications/Ghostty.app")]
BUNDLE = re.compile(r"[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+\Z")
TERMINALS = {GHOSTTY_ID: "Ghostty", "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm",
             "net.kovidgoyal.kitty": "kitty", "com.github.wez.wezterm": "WezTerm", "dev.warp.Warp-Stable": "Warp"}
CREDENTIALS = re.compile(r"://[^/@\s]+@")
GIT_ENV = dict(os.environ, GIT_TERMINAL_PROMPT="0")


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


# ---- repos and their state ----

def find_repos(root):
    """Folders holding .git, at most MAX_DEPTH below `root` (or `root` itself); a repo's insides are not searched."""
    if os.path.exists(os.path.join(root, ".git")):
        return [root]
    found = []

    def walk(path, depth):
        try:
            entries = sorted(os.scandir(path), key=lambda e: e.name)
        except OSError:
            return
        for e in entries:
            if e.name.startswith(".") or e.name in SKIP or not e.is_dir(follow_symlinks=False):
                continue
            if os.path.exists(os.path.join(e.path, ".git")):
                found.append(e.path)
            elif depth < MAX_DEPTH:
                walk(e.path, depth + 1)

    walk(root, 1)
    return found


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


@functools.lru_cache(maxsize=None)
def git_dirs(repo):
    """The repo's own git folder and the common one (they differ in a linked worktree)."""
    dot = os.path.join(repo, ".git")
    if os.path.isdir(dot):
        return dot, dot
    line = read(dot).strip()
    own = line[len("gitdir:"):].strip() if line.startswith("gitdir:") else dot
    own = os.path.normpath(os.path.join(repo, own))
    common = read(os.path.join(own, "commondir")).strip()
    return own, os.path.normpath(os.path.join(own, common)) if common else own


@functools.lru_cache(maxsize=None)
def remotes(common):
    """{name: url} from the repo's config."""
    found, section = {}, None
    for raw in read(os.path.join(common, "config")).splitlines():
        line = raw.strip()
        if line.startswith("["):
            section = line[len('[remote "'):-2] if line.startswith('[remote "') and line.endswith('"]') else None
        elif section and line.replace(" ", "").startswith("url="):
            found[section] = line.split("=", 1)[1].strip()
    return found


def web_url(remote):
    """An https page for a git remote: git@host:o/r.git, ssh://git@host/o/r, https://user@host/o/r.git."""
    if not remote:
        return None
    if remote.startswith("git@") and ":" in remote:
        host, path = remote[4:].split(":", 1)
    elif remote.startswith(("ssh://", "https://", "http://", "git://")):
        host, _, path = remote.split("://", 1)[1].partition("/")
        host = host.rsplit("@", 1)[-1].split(":", 1)[0]
    else:
        return None
    path = path.strip("/")
    if path.endswith(".git"):
        path = path[:-4]
    return "https://%s/%s" % (host, path) if host and path else None


def activity(own):
    times = []
    for name in ("index", "HEAD"):
        try:
            times.append(os.stat(os.path.join(own, name)).st_mtime)
        except OSError:
            pass
    return max(times, default=0)


def parse(porcelain):
    """What `status --porcelain=v2 --branch` says: branch, upstream, ahead, behind, changed (entries, untracked too)."""
    state = {"branch": "no branch", "upstream": None, "ahead": 0, "behind": 0, "changed": 0, "gone": False}
    oid, has_ab = "", False
    for line in porcelain.splitlines():
        if line.startswith("# branch.oid "):
            oid = line.split(" ", 2)[2]
        elif line.startswith("# branch.head "):
            state["branch"] = line.split(" ", 2)[2]
        elif line.startswith("# branch.upstream "):
            state["upstream"] = line.split(" ", 2)[2]
        elif line.startswith("# branch.ab "):
            has_ab = True
            for part in line.split()[2:]:
                if part[1:].isdigit():
                    state["ahead" if part[0] == "+" else "behind"] = int(part[1:])
        elif line and not line.startswith("#"):
            state["changed"] += 1
    if state["branch"] == "(detached)":
        state["branch"] = (oid[:7] + " (detached)") if oid and oid != "(initial)" else "detached"
    state["gone"] = bool(state["upstream"]) and not has_ab
    return state


def git(repo, arguments, timeout):
    return subprocess.run(["git", "-C", repo] + arguments, capture_output=True, text=True, timeout=timeout,
                          stdin=subprocess.DEVNULL, env=GIT_ENV)


def status(repo, deadline, last_commit=False):
    """`repo`'s state, with its last commit's time when asked; None when git did not answer by `deadline`."""
    try:
        left = deadline - time.monotonic()
        if left <= 0.05:
            return None
        done = git(repo, ["--no-optional-locks", "status", "--porcelain=v2", "--branch", "--ignore-submodules=dirty"], left)
        if done.returncode != 0:
            return None
        state = parse(done.stdout)
        left = deadline - time.monotonic()
        if last_commit and left > 0.05:
            log = git(repo, ["--no-optional-locks", "log", "-1", "--format=%ct"], left)
            if log.returncode == 0 and log.stdout.strip().isdigit():
                state["committed"] = int(log.stdout.strip())
        return state
    except (subprocess.TimeoutExpired, OSError):
        return None


def statuses(repos, deadline, last_commit=False):
    """{repo: state} for the repos that answered by `deadline`."""
    if not repos:
        return {}
    pool = ThreadPoolExecutor(WORKERS)
    futures = {pool.submit(status, repo, deadline, last_commit): repo for repo in repos}
    wait(futures, timeout=max(0, deadline - time.monotonic()) + 0.2)
    pool.shutdown(wait=False, cancel_futures=True)
    return {futures[f]: f.result() for f in futures if f.done() and not f.cancelled() and f.result() is not None}


def needs_you(state):
    return bool(state and (state["changed"] or state["ahead"] or state["behind"]))


# ---- cache files ----

def cache_dir(run):
    return (run.get("paths") or {}).get("cache") or os.path.join(os.environ.get("TMPDIR", "/tmp"), "pilot-git")


def load(folder, name):
    try:
        with open(os.path.join(folder, name), encoding="utf-8") as f:
            value = json.load(f)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def save(folder, name, value):
    try:
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, name)
        tmp = "%s.%d.tmp" % (path, os.getpid())
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(value, f)
        os.replace(tmp, path)
    except OSError:
        pass


# ---- fetching: on open (at most every FETCH_EVERY s) and on Fetch all, in a detached child ----

def fetching(folder):
    """True while a fetch holds the lock."""
    try:
        with open(os.path.join(folder, LOCK), "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(f, fcntl.LOCK_UN)
        return False
    except BlockingIOError:
        return True
    except OSError:
        return False


def start_fetch(folder, repos, force=False):
    """Starts a detached fetch of `repos` (those with a remote) unless one runs, or, without `force`, the last started
    under FETCH_EVERY s ago. "running" when one ran already, how many repos it fetches when it started one, else None."""
    if fetching(folder):
        return "running"
    state = load(folder, FETCH_STATE)
    if not force and time.time() - (state.get("at") or 0) < FETCH_EVERY:
        return None
    targets = [r for r in repos if remotes(git_dirs(r)[1])]
    if not targets:
        return None
    save(folder, FETCH_STATE, dict(state, at=time.time()))  # counts from the start, so a re-ask never starts a second
    try:
        child = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--fetch"], stdin=subprocess.PIPE,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True,
                                 start_new_session=True, cwd=os.path.dirname(os.path.abspath(__file__)))
        child.stdin.write(json.dumps({"cache": folder, "repos": targets}).encode())
        child.stdin.close()
    except OSError:
        return None
    return len(targets)


def fetch_one(repo):
    """None when fetched, else git's line."""
    try:
        done = git(repo, ["fetch", "--quiet"], FETCH_REPO_TIMEOUT)
    except subprocess.TimeoutExpired:
        return "took over %d s" % FETCH_REPO_TIMEOUT
    except OSError as e:
        return str(e)
    return None if done.returncode == 0 else git_line(done.stderr)


def fetch_main():
    """The detached child: takes the lock or leaves, fetches FETCH_AT_ONCE repos at a time, writes what failed."""
    try:
        request = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return
    folder, repos = request.get("cache"), request.get("repos")
    if not (isinstance(folder, str) and folder and isinstance(repos, list)):
        return
    os.makedirs(folder, exist_ok=True)
    lock = open(os.path.join(folder, LOCK), "a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return
    signal.alarm(FETCH_TIMEOUT)  # a backstop; each fetch already stops at FETCH_REPO_TIMEOUT
    repos = [r for r in repos if isinstance(r, str) and os.path.isdir(r)]
    with ThreadPoolExecutor(FETCH_AT_ONCE) as pool:
        failed = {os.path.basename(r): e for r, e in zip(repos, pool.map(fetch_one, repos)) if e}
    state = load(folder, FETCH_STATE)
    save(folder, FETCH_STATE, dict(state, done=time.time(), failed=failed))


# ---- drawing ----

def tilde(path):
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path == home or path.startswith(home + "/") else path


def ago(seconds):
    seconds = max(0, int(seconds))
    if seconds < 60:
        return "just now"
    for size, unit in ((86400, "d"), (3600, "h"), (60, "min")):
        if seconds >= size:
            return "%d %s" % (seconds // size, unit)


def plural(n, word):
    return "%d %s%s" % (n, word, "" if n == 1 else "s")


def from_pilot(run, key):
    """One of Pilot's defaults in the run message (Surfaces v2: repos, terminal); None when it sent none."""
    value = run.get("pilot").get(key) if isinstance(run.get("pilot"), dict) else None
    return value if isinstance(value, str) and value else None


def terminal(run):
    """(open's arguments naming the app, its name, whether it is Ghostty): Pilot's terminal (a bundle id, or an app's
    path), else Ghostty when installed, else Terminal."""
    chosen = from_pilot(run, "terminal")
    if isinstance(chosen, str) and chosen.startswith("/") and os.path.isdir(chosen):
        name = os.path.basename(chosen.rstrip("/"))
        name = name[:-4] if name.endswith(".app") else name
        return ["-a", chosen], name, name.lower() == "ghostty"
    if isinstance(chosen, str) and BUNDLE.match(chosen):
        return ["-b", chosen], TERMINALS.get(chosen, chosen.rsplit(".", 1)[-1]), chosen == GHOSTTY_ID
    ghostty = next((g for g in GHOSTTY if os.path.isdir(g)), None)
    return (["-a", ghostty], "Ghostty", True) if ghostty else (["-a", "Terminal"], "Terminal", False)


def summary(state, page=False, now=None):
    """'main · 3 changed · 2 to push', or the branch and clean."""
    if state is None:
        return "git did not answer"
    parts = [state["branch"]]
    if state["changed"]:
        parts.append("%d changed" % state["changed"])
    if state["ahead"] and state["behind"]:
        parts.append("diverged (%d to push, %d behind)" % (state["ahead"], state["behind"]))
    elif state["ahead"]:
        parts.append("%d to push" % state["ahead"])
    elif state["behind"]:
        parts.append("%d behind" % state["behind"])
    if state["gone"]:
        parts.append("upstream gone")
    elif not state["upstream"] and "detached" not in state["branch"]:
        parts.append("no upstream")
    if len(parts) == 1:
        parts.append("clean")
    if page and state.get("committed") and now:
        parts.append("last commit %s" % ago(now - state["committed"]))
    return " · ".join(parts)


def row(repo, root, state, terminal_name, lazygit, page=False, now=None):
    """One repo as a list item: a click opens lazygit there (its terminal when lazygit is not installed); badges and
    inline Pull and Push (Surfaces v2), and every action in `actions` too, so an older Pilot reaches them through ⋯."""
    name = os.path.relpath(repo, root) if repo != root else os.path.basename(repo)
    context = {"path": repo}
    diverged = bool(state and state["ahead"] and state["behind"])
    synced = bool(state and state["upstream"] and not state["gone"] and not diverged)
    pull = {"type": "run", "command": "pull", "title": "Pull", "icon": "arrow.down", "context": context}
    push = {"type": "run", "command": "push", "title": "Push", "icon": "arrow.up", "context": context}
    inline = []
    if synced and state["behind"]:
        inline.append(pull)
    if synced and state["ahead"]:
        inline.append(push)
    badges = []
    if state:
        sync_tone = {"tone": "alert"} if diverged else {}
        if state["changed"]:
            badges.append({"text": "●%d" % state["changed"], "tone": "warn"})
        if state["ahead"]:
            badges.append(dict({"text": "↑%d" % state["ahead"]}, **sync_tone))
        if state["behind"]:
            badges.append(dict({"text": "↓%d" % state["behind"]}, **sync_tone))
    found = remotes(git_dirs(repo)[1])
    url = web_url(found.get("origin") or next(iter(found.values()), None))
    shell = {"type": "run", "command": "open-terminal", "title": "Open in %s" % terminal_name, "context": context}
    actions = [{"type": "run", "command": "lazygit", "title": "lazygit", "context": context}, shell] if lazygit else [shell]
    actions += inline
    actions.append({"type": "open", "url": repo, "title": "Open in Finder"})
    if url:
        host = url.split("/")[2]
        actions.append({"type": "open", "url": url, "title": "Open on %s" % ("GitHub" if host == "github.com" else host)})
    actions.append({"type": "copy", "text": repo, "title": "Copy path"})
    item = {"id": repo, "title": name, "subtitle": summary(state, page, now), "icon": "✏️" if needs_you(state) else "🌿",
            "keywords": "%s %s" % (state["branch"] if state else "", os.path.basename(repo)), "actions": actions}
    if badges:
        item["badges"] = badges
    if inline:
        item["inline"] = inline
    return item


def repos_root(run):
    """Pilot's Repos folder, else the Repos folder preference, else ~/code."""
    chosen = from_pilot(run, "repos") or (run.get("preferences") or {}).get("folder") or "~/code"
    return os.path.abspath(os.path.expanduser(chosen))


class View:
    """The repos under Pilot's folder and their state, read for one surface."""

    def __init__(self, run, started, surface=None):
        self.root = repos_root(run)
        self.exists = os.path.isdir(self.root)
        self.repos = sorted(find_repos(self.root), key=lambda r: -activity(git_dirs(r)[0])) if self.exists else []
        self.folder = cache_dir(run)
        self.now = time.time()
        self.page = surface == "page"
        cache = load(self.folder, STATUS)
        fresh = statuses(self.repos, started + BUDGET.get(surface, DEFAULT_BUDGET), last_commit=self.page)
        self.states = {r: fresh.get(r) or cache.get(r) for r in self.repos}
        kept = {r: s for r, s in self.states.items() if s}
        if kept != cache:
            save(self.folder, STATUS, kept)
        _, self.terminal_name, _ = terminal(run)
        self.lazygit = shutil.which("lazygit") is not None
        self.attention = [r for r in self.repos if needs_you(self.states[r])]
        self.unread = [r for r in self.repos if self.states[r] is None]
        self.clean = [r for r in self.repos if self.states[r] and not needs_you(self.states[r])]

    def row(self, repo):
        item = row(repo, self.root, self.states[repo], self.terminal_name, self.lazygit, self.page, self.now)
        if self.page:  # its terminal at its right too, three buttons at most
            shell = next(a for a in item["actions"] if a.get("command") == "open-terminal")
            item["inline"] = (item.get("inline") or [])[:2] + [dict(shell, icon="terminal")]
        return item

    def search(self):
        """The page's search when its box ran in the last FIND_KEPT s; "" for none."""
        found = load(self.folder, FIND)
        words = found.get("q") if isinstance(found.get("q"), str) else ""
        return words if words and self.now - (found.get("at") or 0) < FIND_KEPT else ""

    def matching(self, words):
        """Every repo whose path from the folder or branch holds each word, needing you first."""
        def text(r):
            state = self.states[r] or {}
            return ("%s %s" % (os.path.relpath(r, self.root), state.get("branch", ""))).lower()
        hits = [r for r in self.repos if all(w in text(r) for w in words.lower().split())]
        return sorted(hits, key=lambda r: not needs_you(self.states[r]))

    def fetch_note(self, running):
        if running:
            return "fetching…"
        state = load(self.folder, FETCH_STATE)
        if not state.get("at"):
            return "not fetched yet"
        note = "fetched %s" % ago(self.now - state["at"])
        note += "" if note.endswith("just now") else " ago"
        failed = state.get("failed") or {}
        if failed and (state.get("done") or 0) >= state["at"]:
            note += " · %s could not fetch" % plural(len(failed), "repo")
        return note

    def blocks(self, running=False, stats=False):
        """The popover's or page's blocks: what needs you, a row for the clean ones, Fetch all."""
        if not self.exists:
            return [{"type": "markdown", "text": "No folder %s. Set Repos in Pilot's Defaults › Folders." % tilde(self.root)}]
        if not self.repos:
            return [{"type": "markdown", "text": "No git repos in %s." % tilde(self.root)}]
        blocks = []
        if stats:
            s = [self.states[r] for r in self.repos if self.states[r]]
            changed = sum(1 for x in s if x["changed"])
            blocks.append({"type": "stats", "items": [
                dict({"label": "Changed", "value": str(changed)}, **({"tone": "warn"} if changed else {})),
                {"label": "To push", "value": str(sum(1 for x in s if x["ahead"]))},
                {"label": "To pull", "value": str(sum(1 for x in s if x["behind"]))},
                {"label": "Clean", "value": str(len(self.clean)), "tone": "fine"}]})
        words = self.search() if self.page else ""
        if self.page:
            blocks.append({"type": "input", "placeholder": "Find a repo by name or branch", "live": True,
                           "action": {"type": "run", "command": "find", "title": "Find"}})
        if words:
            hits = [self.row(r) for r in self.matching(words)][:50]
            blocks.append({"type": "list", "title": "Matching “%s” · %s" % (words, self.fetch_note(running)), "items": hits}
                          if hits else {"type": "markdown", "text": "No repo in %s matches “%s”." % (tilde(self.root), words)})
            blocks.append({"type": "buttons", "actions": [{"type": "run", "command": "find", "title": "Show what needs you"},
                                                          {"type": "run", "command": "fetch", "title": "Fetch all",
                                                           "icon": "refresh"}]})
            return blocks
        items = [self.row(r) for r in self.attention + self.unread][:49]
        if self.clean:
            items.append({"title": "%s ›" % plural(len(self.clean), "clean repo"), "icon": "🌿",
                          "actions": [{"type": "push", "command": "clean", "title": "Show clean repos"}]})
        blocks.append({"type": "list", "title": "%s · %s" % (tilde(self.root), self.fetch_note(running)), "items": items})
        blocks.append({"type": "buttons", "actions": [{"type": "run", "command": "fetch", "title": "Fetch all",
                                                       "icon": "refresh"}]})
        return blocks


# ---- surfaces ----

def answer_blocks(view, stats):
    running = bool(view.repos) and start_fetch(view.folder, view.repos) is not None
    message = {"type": "blocks", "blocks": view.blocks(running, stats)}
    if running:
        message["refresh"] = FETCHING_REFRESH
    send(message)


def bar(run, started):
    """The bar item: a branch mark and how many repos need you, hidden when none; the popover (same command, surface
    popover) also fetches when the last fetch is 10 min old."""
    surface = run.get("surface")
    view = View(run, started, surface)
    if surface == "popover":
        answer_blocks(view, stats=False)
        return
    count = len(view.attention)
    if not count:
        send({"type": "bar", "text": ""})
        return
    send({"type": "bar", "text": "⎇ %d" % count, "tone": "warn", "blocks": view.blocks(fetching(view.folder))})


def page(run, started):
    answer_blocks(View(run, started, "page"), stats=True)


def find(run):
    """The page box's run: keeps its text, trimmed (blank clears it), for the page's next ask."""
    words = run.get("input") if isinstance(run.get("input"), str) else ""
    save(cache_dir(run), FIND, {"q": " ".join(words.split())[:100], "at": time.time()})


def clean(run, started):
    view = View(run, started, run.get("surface") or "popover")
    if not run.get("surface"):
        send({"type": "hud", "text": "%s in %s" % (plural(len(view.clean), "clean repo"), tilde(view.root))})
        return
    items = [view.row(r) for r in view.clean][:50]
    send({"type": "blocks", "blocks": [{"type": "list", "title": "Clean repos", "items": items}] if items else
          [{"type": "markdown", "text": "No clean repos."}]})


def list_repos(run, started):
    view = View(run, started)
    if not view.exists:
        send({"type": "error", "text": "has no folder %s: set Repos in Pilot's Defaults › Folders" % tilde(view.root)})
        return
    items = [view.row(r) for r in view.repos]
    if not items:
        items = [{"title": "No git repos in %s" % tilde(view.root), "subtitle": "Set Repos in Pilot's Defaults › Folders"}]
    send({"type": "list", "items": items})


# ---- hidden commands ----

def git_line(stderr):
    """git's own line for a failure: a rejected ref first, then an error or fatal line, else its last; credentials in a
    URL hidden."""
    lines = [l.strip() for l in (stderr or "").splitlines() if l.strip()]
    pick = next((l for l in lines if "[rejected]" in l or "[remote rejected]" in l), None) \
        or next((l for l in lines if l.startswith(("error:", "fatal:"))), None) \
        or (lines[-1] if lines else "git failed")
    return CREDENTIALS.sub("://", pick)[:200]


def repo_of(run):
    context = run.get("context") if isinstance(run.get("context"), dict) else {}
    repo = context.get("path")
    if isinstance(repo, str) and os.path.isdir(repo) and os.path.exists(os.path.join(repo, ".git")):
        return repo
    send({"type": "error", "text": "got no repo folder that exists"})
    return None


def checked(repo):
    """The repo's state for a pull or a push, or None after sending why it cannot."""
    state = status(repo, time.monotonic() + 5)
    name = os.path.basename(repo)
    if state is None:
        send({"type": "error", "text": "git did not answer in %s" % name})
    elif not state["upstream"] or state["gone"]:
        send({"type": "error", "text": "%s has no upstream branch: set it in lazygit" % name})
    elif state["ahead"] and state["behind"]:
        send({"type": "error", "text": "Diverged: open lazygit"})
    else:
        return state
    return None


def sync(repo, arguments):
    """git's answer to a pull or push, or None after sending the error."""
    try:
        done = git(repo, arguments, SYNC_TIMEOUT)
    except subprocess.TimeoutExpired:
        send({"type": "error", "text": "git %s took over %d s: try lazygit" % (arguments[0], SYNC_TIMEOUT)})
        return None
    except OSError as e:
        send({"type": "error", "text": str(e)[:200]})
        return None
    if done.returncode != 0:
        text = done.stderr or done.stdout
        diverged = "Not possible to fast-forward" in text or "diverge" in text
        send({"type": "error", "text": "Diverged: open lazygit" if diverged else git_line(text)})
        return None
    return done


def pull(run):
    repo = repo_of(run)
    state = repo and checked(repo)
    if not state:
        return
    done = sync(repo, ["pull", "--ff-only"])
    if done:
        quiet = "Already up to date" in done.stdout or "Already up-to-date" in done.stdout
        send({"type": "hud", "text": "%s %s" % (os.path.basename(repo), "is up to date" if quiet else "pulled")})


def push(run):
    repo = repo_of(run)
    state = repo and checked(repo)
    if not state:
        return
    if not state["ahead"]:
        send({"type": "hud", "text": "%s has nothing to push" % os.path.basename(repo)})
        return
    if sync(repo, ["push"]):
        send({"type": "hud", "text": "%s pushed %s" % (os.path.basename(repo), plural(state["ahead"], "commit"))})


def fetch_all(run):
    root = repos_root(run)
    repos = find_repos(root) if os.path.isdir(root) else []
    if not repos:
        send({"type": "error", "text": "has no git repos in %s" % tilde(root)})
        return
    started = start_fetch(cache_dir(run), repos, force=True)
    if started == "running":
        send({"type": "hud", "text": "Already fetching"})
    elif started:
        send({"type": "hud", "text": "Fetching %s, %d at a time" % (plural(started, "repo"), FETCH_AT_ONCE)})
    else:
        send({"type": "hud", "text": "No repo here has a remote to fetch"})


def open_with(arguments):
    done = subprocess.run(["open"] + arguments, capture_output=True, text=True, timeout=10)
    return None if done.returncode == 0 else (done.stderr.strip() or "open failed")[:160]


def launch(run, command=None):
    """Opens a terminal window in the repo the context names, running `command` (a path) when given: Ghostty as a new
    window there; another terminal by opening the folder, or for a command a .command file Terminal runs. The window
    belongs to the terminal, never to this program. Returns (repo, app name), or None after sending the error."""
    repo = repo_of(run)
    if not repo:
        return None
    app, name, ghostty = terminal(run)
    if ghostty:
        arguments = ["-n"] + app + ["--args", "--working-directory=" + repo, "--window-save-state=never"]
        failed = open_with(arguments + (["--command=" + command] if command else []))
    elif command:
        os.makedirs(cache_dir(run), exist_ok=True)
        script = os.path.join(cache_dir(run), "%s.command" % os.path.basename(command))
        with open(script, "w", encoding="utf-8") as f:
            f.write("#!/bin/sh\ncd %s && exec %s\n" % (shlex.quote(repo), shlex.quote(command)))
        os.chmod(script, 0o755)
        name = "Terminal"
        failed = open_with(["-a", name, script])
    else:
        failed = open_with(app + [repo])
    if failed:
        send({"type": "error", "text": failed})
        return None
    return repo, name


def open_terminal(run):
    opened = launch(run)
    if opened:
        send({"type": "hud", "text": "%s in %s" % (os.path.basename(opened[0]), opened[1])})


def lazygit(run):
    binary = shutil.which("lazygit")
    if not binary:
        send({"type": "error", "text": "lazygit is not installed: brew install lazygit"})
        return
    opened = launch(run, binary)
    if opened:
        send({"type": "hud", "text": "lazygit on %s" % os.path.basename(opened[0])})


def main():
    if sys.argv[1:] == ["--fetch"]:
        fetch_main()
        return
    started = time.monotonic()
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        send({"type": "error", "text": "got a run message it could not read"})
        return
    command = run.get("command")
    if command == "repos":
        list_repos(run, started)
    elif command == "bar":
        bar(run, started)
    elif command == "page":
        page(run, started)
    elif command == "clean":
        clean(run, started)
    elif command == "find":
        find(run)
    elif command == "fetch":
        fetch_all(run)
    elif command == "pull":
        pull(run)
    elif command == "push":
        push(run)
    elif command == "open-terminal":
        open_terminal(run)
    elif command == "lazygit":
        lazygit(run)
    else:
        send({"type": "error", "text": "has no command %s" % command})


if __name__ == "__main__":
    main()
