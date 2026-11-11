#!/usr/bin/env python3
"""GitHub for Pilot: pull requests, issues and failing CI runs that need Sven, through the signed-in `gh` CLI.

GitHub takes seconds to answer and Pilot stops a list at 2 s, so every list answers at once from paths.cache/github.json
and, when that is older than FRESH seconds, starts `main.py --refresh` as a detached child (its own session, output to
nowhere) that asks GitHub and replaces the cache atomically. A lock file held with flock for the child's life keeps two
refreshes from overlapping, and the child stops itself after its timeout. The refresh makes one GraphQL call (your
repos, your open PRs, PRs waiting on your review, issues assigned to you) and one `gh api` call per repo pushed in the
last REPO_DAYS days (narrowed by the owner filter) for its recent Actions runs. PRs and issues are stored unfiltered
and filtered as a list is drawn; a changed filter counts as stale, so the runs are asked again for it. gh's own sign-in is used and never read; its error lines are shown with anything token-shaped hidden.
"""
import fcntl
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

CACHE = "github.json"
LOCK = "refresh.lock"
FRESH = 120
REFRESH_TIMEOUT = 20
RERUN_TIMEOUT = 25
REPO_DAYS = 14
RUN_DAYS = 7
MAX_REPOS = 12
RUNS_PER_REPO = 30
FAILED = {"failure", "timed_out", "startup_failure"}
REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
TOKEN_SHAPE = re.compile(r"(gh[pousr]_|github_pat_)[A-Za-z0-9_]+")
QUERY = """
query {
  viewer {
    login
    repositories(first: 40, orderBy: {field: PUSHED_AT, direction: DESC}, isArchived: false,
                 ownerAffiliations: [OWNER, ORGANIZATION_MEMBER, COLLABORATOR]) { nodes { nameWithOwner pushedAt } }
  }
  mine: search(type: ISSUE, first: 50, query: "is:pr is:open author:@me archived:false sort:updated-desc") { nodes { ...pr } }
  review: search(type: ISSUE, first: 50, query: "is:pr is:open review-requested:@me archived:false sort:updated-desc") { nodes { ...pr } }
  issues: search(type: ISSUE, first: 50, query: "is:issue is:open assignee:@me archived:false sort:updated-desc") {
    nodes { ... on Issue { number title url updatedAt repository { nameWithOwner } labels(first: 4) { nodes { name } } comments { totalCount } } }
  }
}
fragment pr on PullRequest {
  number title url updatedAt isDraft headRefName reviewDecision repository { nameWithOwner }
  commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
}
"""


class Failure(Exception):
    pass


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


# ---- cache and the background refresh ----

def cache_dir(run):
    return (run.get("paths") or {}).get("cache") or os.path.join(os.environ.get("TMPDIR", "/tmp"), "pilot-github")


def load(folder):
    try:
        with open(os.path.join(folder, CACHE), encoding="utf-8") as f:
            cache = json.load(f)
        return cache if isinstance(cache, dict) else {}
    except (OSError, ValueError):
        return {}


def save(folder, cache):
    path = os.path.join(folder, CACHE)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cache, f)
    os.replace(tmp, path)


def refreshing(folder):
    """True while a refresh holds the lock."""
    try:
        with open(os.path.join(folder, LOCK), "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(f, fcntl.LOCK_UN)
        return False
    except BlockingIOError:
        return True
    except OSError:
        return False


def start_refresh(folder, only):
    """Starts a detached refresh unless one runs; True when one runs now. Settings go on its stdin, never in ps."""
    if refreshing(folder):
        return True
    try:
        child = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--refresh"], stdin=subprocess.PIPE,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True,
                                 start_new_session=True, cwd=os.path.dirname(os.path.abspath(__file__)))
        child.stdin.write(json.dumps({"cache": folder, "only": only, "timeout": REFRESH_TIMEOUT}).encode())
        child.stdin.close()
    except OSError:
        return False
    return True


def refresh_main():
    """The detached child: takes the lock or leaves, asks GitHub, writes the cache, and is gone by its timeout."""
    try:
        request = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return
    folder, only = request.get("cache"), request.get("only") or ""
    timeout = float(request.get("timeout") or REFRESH_TIMEOUT)
    if not isinstance(folder, str) or not folder:
        return
    os.makedirs(folder, exist_ok=True)
    lock = open(os.path.join(folder, LOCK), "a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return  # one runs, or a list was checking the lock this instant; the next open starts one if none ran
    signal.alarm(int(timeout) + 5)  # a backstop; every gh call already stops at the deadline
    cache = load(folder)
    now = time.time()
    try:
        cache.update(fetch(only, time.monotonic() + timeout))
        cache.update({"fetched": now, "only": only, "error": None})
    except Failure as e:
        cache["error"] = str(e)
    cache["tried"] = time.time()
    cache["stale"] = False
    save(folder, cache)


# ---- asking GitHub ----

def hide_tokens(text):
    return TOKEN_SHAPE.sub("[hidden]", text)


def first_line(text, limit=160):
    line = next((l.strip() for l in (text or "").splitlines() if l.strip()), "")
    return hide_tokens(line)[:limit]


def call(arguments, timeout):
    """The stdout of one gh call that exited 0; Failure with a plain reason otherwise. gh runs in its own
    process group, so a timeout stops everything it started and nothing is left holding the pipe."""
    binary = shutil.which("gh")
    if not binary:
        raise Failure("gh is not installed: brew install gh, then gh auth login")
    if timeout <= 0:
        raise Failure("GitHub did not answer in time")
    env = dict(os.environ, GH_PROMPT_DISABLED="1", GH_PAGER="", NO_COLOR="1", GH_NO_UPDATE_NOTIFIER="1")
    try:
        proc = subprocess.Popen([binary] + arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=env, start_new_session=True)
    except OSError as e:
        raise Failure("could not run gh: %s" % e.strerror)
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.communicate()
        raise Failure("GitHub did not answer in time")
    err = err.decode("utf-8", "replace")
    if proc.returncode == 4 or "gh auth login" in err:
        raise Failure("gh is not signed in: run gh auth login in a terminal")
    if proc.returncode != 0:
        raise Failure("gh failed: %s" % (first_line(err) or "exit %d" % proc.returncode))
    return out


def gh(arguments, deadline):
    """gh's stdout parsed as JSON."""
    out = call(arguments, deadline - time.monotonic())
    try:
        return json.loads(out.decode("utf-8", "replace"))
    except ValueError:
        raise Failure("gh answered something that is not JSON")


def nodes(value):
    return [n for n in ((value or {}).get("nodes") or []) if isinstance(n, dict) and n]


def pull(node, waiting):
    commits = nodes(node.get("commits"))
    rollup = ((commits[-1].get("commit") or {}).get("statusCheckRollup") or {}) if commits else {}
    return {"number": node.get("number"), "title": node.get("title") or "", "url": node.get("url"),
            "repo": (node.get("repository") or {}).get("nameWithOwner") or "", "branch": node.get("headRefName"),
            "draft": bool(node.get("isDraft")), "review": node.get("reviewDecision"), "checks": rollup.get("state"),
            "updated": node.get("updatedAt"), "waiting": waiting}


def issue(node):
    return {"number": node.get("number"), "title": node.get("title") or "", "url": node.get("url"),
            "repo": (node.get("repository") or {}).get("nameWithOwner") or "", "updated": node.get("updatedAt"),
            "labels": [l.get("name") for l in nodes(node.get("labels")) if l.get("name")],
            "comments": (node.get("comments") or {}).get("totalCount") or 0}


def stamp_age(stamp, now):
    if not isinstance(stamp, str):
        return None
    try:
        moment = datetime.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    except ValueError:
        return None
    return now - moment.timestamp()


def failing_runs(repo, since, deadline):
    """The runs of `repo` whose latest run for that workflow and branch failed; [] when Actions are off or gone."""
    try:
        answer = gh(["api", "repos/%s/actions/runs?per_page=%d&created=%%3E%%3D%s" % (repo, RUNS_PER_REPO, since)],
                    deadline)
    except Failure:
        return []
    seen, found = set(), []
    for r in (answer or {}).get("workflow_runs") or []:
        key = (r.get("workflow_id"), r.get("head_branch"))
        if key in seen:
            continue
        seen.add(key)
        if r.get("status") == "completed" and r.get("conclusion") in FAILED and isinstance(r.get("id"), int):
            found.append({"id": r["id"], "repo": repo, "workflow": r.get("name") or "workflow",
                          "branch": r.get("head_branch") or "", "title": r.get("display_title") or "",
                          "url": r.get("html_url"), "conclusion": r.get("conclusion"),
                          "updated": r.get("updated_at")})
    return found


def fetch(only, deadline):
    answer = gh(["api", "graphql", "-f", "query=" + QUERY], deadline)
    data = answer.get("data") if isinstance(answer, dict) else None
    if not isinstance(data, dict):
        errors = (answer or {}).get("errors") or [{}]
        raise Failure("GitHub said: %s" % first_line(str(errors[0].get("message") or "no data")))
    review = [pull(n, True) for n in nodes(data.get("review"))]
    urls = {p["url"] for p in review}
    mine = [pull(n, False) for n in nodes(data.get("mine")) if n.get("url") not in urls]
    viewer = data.get("viewer") or {}
    now = time.time()
    ages = [(r.get("nameWithOwner"), stamp_age(r.get("pushedAt"), now)) for r in nodes(viewer.get("repositories"))]
    pushed = [name for name, age in ages if age is not None and age < REPO_DAYS * 86400]
    wanted = rules(only)
    repos = [r for r in pushed if r and REPO.match(r) and matches(r, wanted)]
    known = {r.lower() for r in repos}
    repos += [r for r in wanted if "/" in r and REPO.match(r) and r not in known]
    repos = repos[:MAX_REPOS]
    since = (datetime.now(timezone.utc) - timedelta(days=RUN_DAYS)).strftime("%Y-%m-%d")
    runs = []
    if repos:
        from concurrent.futures import ThreadPoolExecutor  # only the refresh needs it, so lists start faster
        with ThreadPoolExecutor(len(repos)) as pool:
            for found in pool.map(lambda r: failing_runs(r, since, deadline), repos):
                runs += found
    runs.sort(key=lambda r: r.get("updated") or "", reverse=True)
    return {"login": viewer.get("login"), "pulls": review + mine, "issues": [issue(n) for n in nodes(data.get("issues"))],
            "runs": runs}


# ---- the lists ----

def rules(only):
    return [w.strip().lower() for w in re.split(r"[,\s]+", only or "") if w.strip()]


def matches(repo, wanted):
    if not wanted:
        return True
    repo = (repo or "").lower()
    return any(repo == w if "/" in w else repo.split("/", 1)[0] == w for w in wanted)


def ago(seconds):
    if seconds is None:
        return None
    seconds = max(0, seconds)
    if seconds < 60:
        return "just now"
    if seconds < 3600:
        return "%d min ago" % (seconds // 60)
    if seconds < 86400:
        return "%d h ago" % (seconds // 3600)
    return "%d d ago" % (seconds // 86400)


CHECKS = {"SUCCESS": ("checks passing", "✅"), "FAILURE": ("checks failing", "❌"), "ERROR": ("checks failing", "❌"),
          "PENDING": ("checks running", "⏳"), "EXPECTED": ("checks waiting", "⏳")}
REVIEWS = {"APPROVED": "approved", "CHANGES_REQUESTED": "changes requested"}


def pull_items(cache, wanted, now):
    items = []
    for p in cache.get("pulls") or []:
        if not p.get("url") or not matches(p.get("repo"), wanted):
            continue
        checks, icon = CHECKS.get(p.get("checks"), ("no checks", "🔀"))
        parts = ["%s#%s" % (p["repo"], p.get("number")), checks]
        parts.append("waits on your review" if p.get("waiting") else REVIEWS.get(p.get("review")))
        parts += ["draft" if p.get("draft") else None, ago(stamp_age(p.get("updated"), now))]
        actions = [{"type": "open", "url": p["url"], "title": "Open on GitHub"},
                   {"type": "open", "url": p["url"] + "/checks", "title": "Open checks"},
                   {"type": "copy", "text": p["url"], "title": "Copy URL"}]
        if p.get("branch"):
            actions.append({"type": "copy", "text": p["branch"], "title": "Copy branch name"})
        items.append({"id": p["url"], "title": p.get("title") or p["url"], "icon": "👀" if p.get("waiting") else icon,
                      "subtitle": " · ".join(x for x in parts if x),
                      "keywords": " ".join(x for x in (p["repo"], p.get("branch") or "", str(p.get("number")),
                                                        "review" if p.get("waiting") else "mine") if x),
                      "actions": actions})
    return items


def issue_items(cache, wanted, now):
    items = []
    for i in cache.get("issues") or []:
        if not i.get("url") or not matches(i.get("repo"), wanted):
            continue
        reference = "%s#%s" % (i["repo"], i.get("number"))
        comments = i.get("comments") or 0
        parts = [reference, ", ".join(i.get("labels") or []) or None,
                 ("%d comment%s" % (comments, "" if comments == 1 else "s")) if comments else None,
                 ago(stamp_age(i.get("updated"), now))]
        items.append({"id": i["url"], "title": i.get("title") or reference, "icon": "🟢",
                      "subtitle": " · ".join(x for x in parts if x),
                      "keywords": " ".join([i["repo"], str(i.get("number"))] + (i.get("labels") or [])),
                      "actions": [{"type": "open", "url": i["url"], "title": "Open on GitHub"},
                                  {"type": "copy", "text": i["url"], "title": "Copy URL"},
                                  {"type": "copy", "text": reference, "title": "Copy reference"}]})
    return items


def run_items(cache, wanted, now):
    items = []
    for r in cache.get("runs") or []:
        if not r.get("url") or not matches(r.get("repo"), wanted):
            continue
        how = "timed out" if r.get("conclusion") == "timed_out" else "failed"
        title = "%s %s on %s" % (r.get("workflow"), how, r.get("branch")) if r.get("branch") else \
            "%s %s" % (r.get("workflow"), how)
        parts = [r["repo"], r.get("title") if r.get("title") != r.get("workflow") else None,
                 ago(stamp_age(r.get("updated"), now))]
        items.append({"id": str(r.get("id")), "title": title, "icon": "❌",
                      "subtitle": " · ".join(x for x in parts if x),
                      "keywords": " ".join(x for x in (r["repo"], r.get("branch") or "", r.get("workflow") or "") if x),
                      "actions": [{"type": "open", "url": r["url"], "title": "Open run on GitHub"},
                                  {"type": "run", "command": "rerun", "title": "Re-run failed jobs",
                                   "context": {"repo": r["repo"], "id": str(r.get("id")), "workflow": r.get("workflow")}},
                                  {"type": "copy", "text": r["url"], "title": "Copy URL"},
                                  {"type": "open", "url": "https://github.com/%s/actions" % r["repo"],
                                   "title": "Open the repo's Actions"}]})
    return items


SECTIONS = {
    "pull-requests": (pull_items, "No open pull requests of yours, and none wait on your review"),
    "issues": (issue_items, "No open issues are assigned to you"),
    "ci-runs": (run_items, "No failing CI runs in your repos this week"),
}
REFRESH = {"type": "run", "command": "refresh", "title": "Refresh now"}


def current(run, fresh=FRESH):
    """The cache as it is, the owner filter, and whether a refresh runs: one is started when the cache is older than
    `fresh` seconds, marked stale or kept for another filter."""
    folder = cache_dir(run)
    only = only_preference(run)
    cache = load(folder)
    now = time.time()
    last = max(cache.get("fetched") or 0, cache.get("tried") or 0)
    stale = cache.get("stale") or now - last > fresh or (cache.get("fetched") and cache.get("only", "") != only)
    running = start_refresh(folder, only) if stale else refreshing(folder)
    return cache, rules(only), running, now


def show(run, command):
    cache, wanted, running, now = current(run)
    if not cache.get("fetched"):
        if cache.get("error") and not running:
            row = {"title": "Could not reach GitHub", "subtitle": cache["error"], "icon": "⚠️",
                   "actions": [dict(REFRESH, title="Try again")]}
        else:
            row = {"title": "Fetching from GitHub…", "subtitle": "Open this again in a few seconds", "icon": "⏳",
                   "actions": [REFRESH]}
        send({"type": "list", "items": [row]})
        return
    draw, empty = SECTIONS[command]
    items = draw(cache, wanted, now)
    if not items:
        items = [{"title": empty, "subtitle": "Only %s" % ", ".join(wanted) if wanted else "From GitHub, as @%s" %
                  (cache.get("login") or "you"), "icon": "🐙"}]
    seen = "Updated %s" % ago(now - cache["fetched"])
    if running:
        items.append({"title": "%s · refreshing" % seen, "subtitle": "Open this again in a few seconds for the newest",
                      "icon": "⏳"})
    elif cache.get("error"):
        items.append({"title": "Could not refresh: %s" % cache["error"], "subtitle": seen, "icon": "⚠️",
                      "actions": [dict(REFRESH, title="Try again")]})
    send({"type": "list", "items": items})


# ---- surfaces (Pilot story 161): the page and the top-bar item ----

BAR_FRESH = 600  # the bar item asks GitHub at most every ten minutes; the page and lists keep FRESH
PAGE_REFRESHING = 3  # a page asks again this often while a refresh runs


def counts(cache, wanted, now):
    pulls = pull_items(cache, wanted, now)
    waiting = [i for i in pulls if i["icon"] == "👀"]
    return waiting, [i for i in pulls if i["icon"] != "👀"], run_items(cache, wanted, now), issue_items(cache, wanted, now)


def page(run):
    cache, wanted, running, now = current(run)
    if not cache.get("fetched"):
        text = ("Could not reach GitHub: %s" % cache["error"]) if cache.get("error") and not running else \
            "Fetching from GitHub… this page asks again on its own."
        answer = {"type": "blocks", "blocks": [{"type": "markdown", "text": text}, {"type": "buttons", "actions": [REFRESH]}]}
        if running:
            answer["refresh"] = PAGE_REFRESHING
        send(answer)
        return
    waiting, mine, runs, issues = counts(cache, wanted, now)
    blocks = [{"type": "stats", "items": [
        {"label": "Wait on your review", "value": str(len(waiting)), "tone": "warn" if waiting else None},
        {"label": "Your pull requests", "value": str(len(mine))},
        {"label": "Failing CI runs", "value": str(len(runs)), "tone": "alert" if runs else "fine"},
        {"label": "Issues for you", "value": str(len(issues))}]}]
    for title, items in (("Waiting on your review", waiting), ("Your pull requests", mine),
                         ("Failing CI runs this week", runs), ("Issues assigned to you", issues)):
        if items:
            blocks.append({"type": "list", "title": title, "items": [inline(i) for i in items[:20]]})
    if not (waiting or mine or runs or issues):
        blocks.append({"type": "markdown", "text": "Nothing on GitHub needs you: %s." % "; ".join(
            empty for _, empty in SECTIONS.values())})
    note = "Updated %s" % ago(now - cache["fetched"])
    if running:
        note += ", refreshing now"
    elif cache.get("error"):
        note += ". Could not refresh: %s" % cache["error"]
    blocks.append({"type": "markdown", "text": note + "."})
    blocks.append({"type": "buttons", "actions": [REFRESH]})
    answer = {"type": "blocks", "blocks": blocks}
    if running:
        answer["refresh"] = PAGE_REFRESHING  # the newest shows as soon as the refresh lands
    send(answer)


def inline(item):
    """A page row with its doing at its right (Surfaces v2): a failed run's Re-run failed jobs, a pull request's checks;
    each also in its actions, where an older Pilot reaches it through ⋯."""
    wanted = {"rerun": ("refresh", "Re-run failed jobs"), "/checks": ("✅", "Open checks")}
    buttons = []
    for action in item["actions"]:
        key = action.get("command") if action["type"] == "run" else "/checks" if action.get("url", "").endswith("/checks") else None
        if key in wanted:
            buttons.append(dict(action, icon=wanted[key][0]))
    return dict(item, inline=buttons) if buttons else item


def bar(run):
    cache, wanted, _, now = current(run, BAR_FRESH)
    if not cache.get("fetched"):
        send({"type": "bar", "text": ""})
        return
    waiting, _, runs, _ = counts(cache, wanted, now)
    # Quiet unless something needs Sven: red CI first, then reviews waiting.
    text, tone = ("CI %d red" % len(runs), "alert") if runs else (("%d to review" % len(waiting), "warn") if waiting else ("", None))
    blocks = []
    if runs:
        blocks.append({"type": "list", "title": "Failing CI runs", "items": runs[:5]})
    if waiting:
        blocks.append({"type": "list", "title": "Waiting on your review", "items": waiting[:5]})
    send({"type": "bar", "text": text, "tone": tone, "blocks": blocks})


# ---- hidden commands ----

def only_preference(run):
    return ((run.get("preferences") or {}).get("only") or "").strip()


def refresh(run):
    if start_refresh(cache_dir(run), only_preference(run)):
        send({"type": "hud", "text": "Refreshing from GitHub; its page shows the newest in a few seconds"})
    else:
        send({"type": "error", "text": "could not start a refresh"})


def rerun(run):
    context = run.get("context") if isinstance(run.get("context"), dict) else {}
    repo, run_id = context.get("repo"), context.get("id")
    if not (isinstance(repo, str) and REPO.match(repo) and isinstance(run_id, str) and run_id.isdigit()
            and run_id.isascii()):
        send({"type": "error", "text": "got no CI run to re-run"})
        return
    try:
        call(["run", "rerun", run_id, "--failed", "--repo", repo], RERUN_TIMEOUT)
    except Failure as e:
        send({"type": "error", "text": "could not re-run it: %s" % e})
        return
    folder = cache_dir(run)
    cache = load(folder)
    if cache:
        cache["stale"] = True  # the next open asks GitHub again
        try:
            save(folder, cache)
        except OSError:
            pass
    workflow = context.get("workflow") if isinstance(context.get("workflow"), str) else "the run"
    send({"type": "hud", "text": "Re-running the failed jobs of %s" % workflow})


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
    if command in SECTIONS:
        show(run, command)
    elif command == "page":
        page(run)
    elif command == "bar":
        bar(run)
    elif command == "refresh":
        refresh(run)
    elif command == "rerun":
        rerun(run)
    else:
        send({"type": "error", "text": "has no command %s" % command})


if __name__ == "__main__":
    main()
