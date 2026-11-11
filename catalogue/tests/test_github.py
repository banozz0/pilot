import fcntl
import json
import os
import subprocess
import time
from datetime import datetime, timezone
from unittest import mock

import harness
from harness import ExtensionTestCase

FAKE_TOKEN = "gho_" + "A1b2C3d4E5f6G7h8I9j0" * 2


def stamp(seconds_ago):
    return datetime.fromtimestamp(time.time() - seconds_ago, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def pr(number, title, repo, checks, branch, waiting_age=3600, draft=False, review=None):
    return {"number": number, "title": title, "url": "https://github.com/%s/pull/%d" % (repo, number),
            "updatedAt": stamp(waiting_age), "isDraft": draft, "headRefName": branch, "reviewDecision": review,
            "repository": {"nameWithOwner": repo},
            "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": checks} if checks else None}}]}}


def graphql():
    """gh's GraphQL answer, each age counted from now: built per test, never at import, so the suite's length
    never ages it."""
    return {"data": {
        "viewer": {"login": "sven", "repositories": {"nodes": [
            {"nameWithOwner": "o/a", "pushedAt": stamp(600)},
            {"nameWithOwner": "x/c", "pushedAt": stamp(86400)},
            {"nameWithOwner": "o/b", "pushedAt": stamp(86400 * 3)},
            {"nameWithOwner": "o/old", "pushedAt": stamp(86400 * 60)}]}},
        "mine": {"nodes": [pr(7, "Add the thing", "o/a", "SUCCESS", "feat/thing", review="APPROVED"),
                           pr(9, "Half done", "x/c", "FAILURE", "wip", waiting_age=86400 * 2, draft=True),
                           {}]},
        "review": {"nodes": [pr(3, "Please look", "o/b", "PENDING", "fix/x", waiting_age=120)]},
        "issues": {"nodes": [{"number": 12, "title": "It breaks", "url": "https://github.com/o/a/issues/12",
                              "updatedAt": stamp(7200), "repository": {"nameWithOwner": "o/a"},
                              "labels": {"nodes": [{"name": "bug"}]}, "comments": {"totalCount": 3}},
                             {"number": 4, "title": "Elsewhere", "url": "https://github.com/x/c/issues/4",
                              "updatedAt": stamp(60), "repository": {"nameWithOwner": "x/c"},
                              "labels": {"nodes": []}, "comments": {"totalCount": 0}}]},
    }}


def wf_run(run_id, workflow_id, name, branch, conclusion, age, status="completed", title="Commit message"):
    return {"id": run_id, "workflow_id": workflow_id, "name": name, "head_branch": branch, "status": status,
            "conclusion": conclusion, "display_title": title, "run_attempt": 1, "updated_at": stamp(age),
            "html_url": "https://github.com/run/%d" % run_id}


def runs():
    """Each repo's workflow runs, each age counted from now: built per test, like graphql()."""
    return {
        # o/a: CI's latest on main failed; Lint's latest passed after an earlier failure.
        "o_a": {"workflow_runs": [wf_run(11, 1, "CI", "main", "failure", 600),
                                  wf_run(12, 2, "Lint", "main", "success", 700),
                                  wf_run(10, 1, "CI", "main", "success", 900),
                                  wf_run(13, 2, "Lint", "main", "failure", 1000)]},
        # o/b: failed, then fixed by a later run, then one still running: nothing to show.
        "o_b": {"workflow_runs": [wf_run(21, 1, "CI", "dev", None, 60, status="in_progress"),
                                  wf_run(20, 1, "CI", "dev", "failure", 600)]},
        # x/c: timed out on a branch, the run named like its workflow.
        "x_c": {"workflow_runs": [wf_run(31, 5, "Nightly", "dev", "timed_out", 7200, title="Nightly")]},
    }


class GithubTests(ExtensionTestCase):
    EXTENSION = "github"

    def setUp(self):
        super().setUp()
        self.addCleanup(self.wait_idle)
        self.fixtures = self.box.root / "gh"
        self.fixtures.mkdir()
        (self.fixtures / "graphql.json").write_text(json.dumps(graphql()))
        for name, body in runs().items():
            (self.fixtures / ("runs_%s.json" % name)).write_text(json.dumps(body))
        self.fake_gh()
        self.box.shim("open")
        self.box.shim("pbcopy")

    def fake_gh(self, graphql=None, rerun=None):
        """A gh that logs every call and answers from the fixtures; it never reaches GitHub."""
        log = 'printf "%%s\\n" "gh $*" >> "%s"\n' % self.box.log
        graphql = graphql or 'cat "%s/graphql.json"' % self.fixtures
        runs = ('r=$(printf %%s "$2" | sed "s#^repos/\\([^/]*\\)/\\([^/]*\\)/.*#\\1_\\2#"); '
                'cat "%s/runs_$r.json" 2>/dev/null || { echo "HTTP 404: Not Found" >&2; exit 1; }' % self.fixtures)
        rerun = rerun or "exit 0"
        self.box.shim("gh", log + 'case "$*" in\n  *graphql*) %s ;;\n  *actions/runs*) %s ;;\n  "run rerun"*) %s ;;\n'
                      '  *) echo "unexpected" >&2; exit 1 ;;\nesac' % (graphql, runs, rerun))

    def lock_held(self):
        try:
            with open(self.box.cache / "refresh.lock", "a") as f:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(f, fcntl.LOCK_UN)
            return False
        except BlockingIOError:
            return True
        except OSError:
            return False

    def run_ext(self, command, **kwargs):
        self.mark = time.time()
        return super().run_ext(command, **kwargs)

    def wait_refresh(self, limit=10):
        """Waits for the detached refresh the last run started to finish and write the cache."""
        end = time.monotonic() + limit
        path = self.box.cache / "github.json"
        while time.monotonic() < end:
            try:
                cache = json.loads(path.read_text())
            except (OSError, ValueError):
                cache = {}
            if cache.get("tried", 0) >= self.mark and not self.lock_held():
                return cache
            time.sleep(0.05)
        self.fail("the background refresh did not finish in %d s" % limit)

    def wait_idle(self):
        """Lets a refresh still running finish, so it never writes into a removed sandbox."""
        end = time.monotonic() + harness.TIMEOUTS["no-view"]
        while self.lock_held() and time.monotonic() < end:
            time.sleep(0.05)

    def items(self, command, **kwargs):
        r = self.run_ext(command, **kwargs)
        self.assertItemShape(r.items)
        self.assertLess(r.elapsed, 2)
        self.assertNotIn(FAKE_TOKEN, r.stdout)
        return r.items

    def warm(self, **kwargs):
        self.items("pull-requests", **kwargs)
        return self.wait_refresh()

    def gh_calls(self):
        return [c for c in self.box.shim_calls() if c.startswith("gh ")]

    def test_first_open_answers_at_once_then_the_background_refresh_fills_the_cache(self):
        items = self.items("pull-requests")
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["title"], "Fetching from GitHub…")
        self.assertEqual(items[0]["actions"], [{"type": "run", "command": "refresh", "title": "Refresh now"}])
        cache = self.wait_refresh()
        self.assertIsNone(cache["error"])
        calls = self.gh_calls()
        self.assertTrue(calls[0].startswith("gh api graphql -f query="))
        self.assertEqual(sorted(c.split("?")[0] for c in calls[1:]),
                         ["gh api repos/o/a/actions/runs", "gh api repos/o/b/actions/runs",
                          "gh api repos/x/c/actions/runs"])  # o/old was last pushed 60 days ago
        self.assertIn("created=%3E%3D", calls[1])

    def test_pull_requests_waiting_on_you_first_then_yours_with_checks(self):
        self.warm()
        items = self.items("pull-requests")
        self.assertEqual([i["title"] for i in items], ["Please look", "Add the thing", "Half done"])
        rows = {i["title"]: i for i in items}
        self.assertEqual(rows["Please look"]["subtitle"], "o/b#3 · checks running · waits on your review · 2 min ago")
        self.assertEqual(rows["Please look"]["icon"], "👀")
        self.assertEqual(rows["Add the thing"]["subtitle"], "o/a#7 · checks passing · approved · 1 h ago")
        self.assertEqual(rows["Add the thing"]["icon"], "✅")
        self.assertEqual(rows["Half done"]["subtitle"], "x/c#9 · checks failing · draft · 2 d ago")
        url = "https://github.com/o/a/pull/7"
        self.assertEqual(rows["Add the thing"]["actions"], [
            {"type": "open", "url": url, "title": "Open on GitHub"},
            {"type": "open", "url": url + "/checks", "title": "Open checks"},
            {"type": "copy", "text": url, "title": "Copy URL"},
            {"type": "copy", "text": "feat/thing", "title": "Copy branch name"}])
        self.assertEqual(len(self.gh_calls()), 4, "a fresh cache asks GitHub nothing")

    def test_page_counts_and_lists_what_needs_you_from_the_cache(self):
        before = self.page()
        self.assertEqual(before[0], {"type": "markdown", "text": "Fetching from GitHub… this page asks again on its own."})
        self.wait_refresh()
        blocks = self.page()
        self.assertEqual(blocks[0]["items"], [
            {"label": "Wait on your review", "value": "1", "tone": "warn"}, {"label": "Your pull requests", "value": "2"},
            {"label": "Failing CI runs", "value": "2", "tone": "alert"}, {"label": "Issues for you", "value": "2"}])
        lists = [(b["title"], [i["title"] for i in b["items"]]) for b in blocks if b["type"] == "list"]
        self.assertEqual([t for t, _ in lists], ["Waiting on your review", "Your pull requests", "Failing CI runs this week",
                                                 "Issues assigned to you"])
        self.assertEqual(lists[0][1], ["Please look"])
        self.assertEqual(blocks[-1], {"type": "buttons", "actions": [{"type": "run", "command": "refresh", "title": "Refresh now"}]})

    def test_page_rows_act_in_place_and_the_page_follows_a_refresh(self):
        self.assertEqual(self.blocks_message("page", "page")["refresh"], 3, "fetching: the page asks again on its own")
        self.wait_refresh()
        answer = self.blocks_message("page", "page")
        self.assertNotIn("refresh", answer, "nothing running: the page keeps its own pace")
        rows = {i["title"]: i for b in answer["blocks"] if b["type"] == "list" for i in b["items"]}
        rerun = rows["Nightly timed out on dev"]["inline"]
        self.assertEqual([(a["command"], a["icon"]) for a in rerun], [("rerun", "refresh")])
        self.assertEqual(rerun[0]["context"], {"repo": "x/c", "id": "31", "workflow": "Nightly"})
        checks = rows["Add the thing"]["inline"]
        self.assertEqual(checks, [{"type": "open", "url": "https://github.com/o/a/pull/7/checks", "title": "Open checks",
                                   "icon": "✅"}])
        self.assertNotIn("inline", rows["It breaks"])  # an issue opens on a click
        r = self.run_ext("rerun", context=rerun[0]["context"])
        self.assertEqual(r.of_type("hud")[0]["text"], "Re-running the failed jobs of Nightly")
        self.assertIn("gh run rerun 31 --failed --repo x/c", self.gh_calls())
        self.assertFalse([i for i in self.items("ci-runs") if "inline" in i], "Hyper+Space's lists stay as they were")

    def test_bar_is_quiet_until_something_needs_you_then_red_ci_first(self):
        self.assertEqual(self.bar()["text"], "", "nothing fetched yet: the item hides")
        self.wait_refresh()
        bar = self.bar()
        self.assertEqual((bar["text"], bar["tone"]), ("CI 2 red", "alert"))
        self.assertEqual([b["title"] for b in bar["blocks"]], ["Failing CI runs", "Waiting on your review"])
        calls = len(self.gh_calls())
        self.bar()
        self.assertEqual(len(self.gh_calls()), calls, "a bar item within ten minutes asks GitHub nothing")

    def test_issues_assigned_to_you(self):
        self.warm()
        items = self.items("issues")
        self.assertEqual([i["title"] for i in items], ["It breaks", "Elsewhere"])
        self.assertEqual(items[0]["subtitle"], "o/a#12 · bug · 3 comments · 2 h ago")
        self.assertEqual(items[0]["actions"][0], {"type": "open", "url": "https://github.com/o/a/issues/12",
                                                  "title": "Open on GitHub"})
        self.assertEqual(items[0]["actions"][2], {"type": "copy", "text": "o/a#12", "title": "Copy reference"})

    def test_ci_runs_show_only_workflows_whose_latest_run_failed(self):
        self.warm()
        items = self.items("ci-runs")
        self.assertEqual([i["title"] for i in items], ["CI failed on main", "Nightly timed out on dev"])
        self.assertEqual(items[0]["subtitle"], "o/a · Commit message · 10 min ago")
        self.assertEqual(items[1]["subtitle"], "x/c · 2 h ago")
        self.assertEqual(items[0]["actions"][0], {"type": "open", "url": "https://github.com/run/11",
                                                  "title": "Open run on GitHub"})
        self.assertEqual(items[0]["actions"][1], {"type": "run", "command": "rerun", "title": "Re-run failed jobs",
                                                  "context": {"repo": "o/a", "id": "11", "workflow": "CI"}})
        self.assertEqual(items[0]["actions"][3]["url"], "https://github.com/o/a/actions")

    def test_the_owner_filter_narrows_every_list(self):
        self.warm()
        prefs = {"only": "o, x/zzz"}
        # PRs and issues narrow at once; the new filter also refreshes, since CI runs were asked for every repo.
        self.assertEqual([i["title"] for i in self.items("pull-requests", preferences=prefs)][:2],
                         ["Please look", "Add the thing"])
        self.wait_refresh()
        self.assertEqual([i["title"] for i in self.items("pull-requests", preferences=prefs)],
                         ["Please look", "Add the thing"])
        self.assertEqual([i["title"] for i in self.items("issues", preferences=prefs)], ["It breaks"])
        runs = [c.split("?")[0] for c in self.gh_calls()[5:]]
        self.assertEqual(sorted(runs), ["gh api repos/o/a/actions/runs", "gh api repos/o/b/actions/runs",
                                        "gh api repos/x/zzz/actions/runs"])
        self.assertEqual([i["title"] for i in self.items("ci-runs", preferences=prefs)], ["CI failed on main"])
        self.assertEqual(self.items("issues", preferences={"only": "nobody"})[0]["title"],
                         "No open issues are assigned to you")

    def test_a_stale_cache_shows_its_rows_and_refreshes_behind_them(self):
        self.warm()
        cache = json.loads((self.box.cache / "github.json").read_text())
        cache["fetched"] = cache["tried"] = time.time() - 600
        (self.box.cache / "github.json").write_text(json.dumps(cache))
        self.fake_gh(graphql='sleep 1; cat "%s/graphql.json"' % self.fixtures)
        items = self.items("pull-requests")
        self.assertEqual(items[0]["title"], "Please look")
        self.assertEqual(items[-1]["title"], "Updated 10 min ago · refreshing")
        # A second open while that refresh runs starts no other one.
        self.items("issues")
        self.wait_refresh()
        self.assertEqual(sum("graphql" in c for c in self.gh_calls()), 2)
        self.assertNotIn("refreshing", self.items("pull-requests")[-1]["title"])

    def test_refresh_command_starts_one(self):
        r = self.run_ext("refresh")
        self.assertIn("Refreshing from GitHub", r.of_type("hud")[0]["text"])
        self.assertIsNone(self.wait_refresh()["error"])

    def test_gh_not_signed_in_is_one_honest_row_and_never_shows_a_token(self):
        self.fake_gh(graphql='echo "token %s is invalid; To get started run: gh auth login" >&2; exit 4' % FAKE_TOKEN)
        self.items("pull-requests")
        self.wait_refresh()
        items = self.items("pull-requests")
        self.assertEqual(items, [{"title": "Could not reach GitHub",
                                  "subtitle": "gh is not signed in: run gh auth login in a terminal", "icon": "⚠️",
                                  "actions": [{"type": "run", "command": "refresh", "title": "Try again"}]}])

    def test_gh_failing_keeps_the_old_rows_and_says_why_without_tokens(self):
        self.warm()
        cache = json.loads((self.box.cache / "github.json").read_text())
        cache["stale"] = True
        (self.box.cache / "github.json").write_text(json.dumps(cache))
        self.fake_gh(graphql='echo "HTTP 502: bad gateway (token %s)" >&2; exit 1' % FAKE_TOKEN)
        self.items("pull-requests")
        self.assertIn("[hidden]", self.wait_refresh()["error"])
        items = self.items("pull-requests")
        self.assertEqual(items[0]["title"], "Please look")
        self.assertEqual(items[-1]["title"], "Could not refresh: gh failed: HTTP 502: bad gateway (token [hidden])")

    def test_gh_missing_is_one_honest_row(self):
        (self.box.shims / "gh").unlink()
        # the real gh lives in /opt/homebrew/bin
        hide = mock.patch.object(harness, "SYSTEM_PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        hide.start()
        self.addCleanup(hide.stop)
        self.items("issues")
        self.wait_refresh()
        items = self.items("issues")
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["subtitle"], "gh is not installed: brew install gh, then gh auth login")

    def test_a_hung_gh_never_holds_the_list_and_the_refresh_stops_at_its_timeout(self):
        self.fake_gh(graphql='sleep 3; cat "%s/graphql.json"' % self.fixtures)
        self.assertEqual(self.items("pull-requests")[0]["title"], "Fetching from GitHub…")
        self.assertEqual(self.items("issues")[0]["title"], "Fetching from GitHub…")
        self.assertIsNone(self.wait_refresh()["error"])
        self.assertEqual(sum("graphql" in c for c in self.gh_calls()), 1, "two opens, one refresh")
        self.fake_gh(graphql="sleep 30")
        # The refresh itself, run as the list starts it, with a 1 s timeout in place of 20.
        program = harness.EXTENSIONS / "github" / "main.py"
        env = {"HOME": str(self.box.home), "PATH": "%s:%s" % (self.box.shims, harness.SYSTEM_PATH),
               "TMPDIR": str(self.box.tmp), "LANG": "en_US.UTF-8"}
        python = os.environ.get("PILOT_EXT_PYTHON") or "python3"
        folder = self.box.root / "cache2"
        started = time.monotonic()
        subprocess.run([python, str(program), "--refresh"], env=env, timeout=10, check=True,
                       input=json.dumps({"cache": str(folder), "only": "", "timeout": 1}).encode())
        self.assertLess(time.monotonic() - started, 4)
        cache = json.loads((folder / "github.json").read_text())
        self.assertEqual(cache["error"], "GitHub did not answer in time")

    def test_rerun_reruns_only_the_failed_jobs_and_marks_the_cache_stale(self):
        self.warm()
        r = self.run_ext("rerun", context={"repo": "o/a", "id": "11", "workflow": "CI"})
        self.assertEqual(r.of_type("hud")[0]["text"], "Re-running the failed jobs of CI")
        self.assertEqual(self.gh_calls()[-1], "gh run rerun 11 --failed --repo o/a")
        self.assertTrue(json.loads((self.box.cache / "github.json").read_text())["stale"])

    def test_rerun_refuses_a_context_that_is_not_one_run(self):
        for context in ({"repo": "o/a", "id": "11 --help"}, {"repo": "o/a; rm", "id": "11"}, {"repo": "o/a", "id": 11},
                        {"repo": "o/a"}, {}):
            r = self.run_ext("rerun", context=context)
            self.assertEqual(r.of_type("error")[0]["text"], "got no CI run to re-run")
        self.assertEqual(self.gh_calls(), [])

    def test_rerun_failing_says_why(self):
        self.fake_gh(rerun='echo "HTTP 403: Must have admin rights to Repository." >&2; exit 1')
        r = self.run_ext("rerun", context={"repo": "o/a", "id": "11"})
        self.assertEqual(r.of_type("error")[0]["text"],
                         "could not re-run it: gh failed: HTTP 403: Must have admin rights to Repository.")
