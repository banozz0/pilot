import json
import os
import subprocess
import time

from harness import ExtensionTestCase

ENV = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t",
           GIT_CONFIG_GLOBAL="/dev/null")


def git(*args, cwd):
    return subprocess.run(["git"] + list(args), cwd=str(cwd), check=True, capture_output=True, text=True, env=ENV).stdout


class GitTests(ExtensionTestCase):
    """Temp repos under ~/code, cloned from one bare "remote": clean, changed, ahead, behind, diverged, and a repo with
    no upstream; `pusher` is a clone outside ~/code that moves the remote on."""
    EXTENSION = "git"

    def setUp(self):
        super().setUp()
        self.addCleanup(self.settle)
        self.code = self.box.home / "code"
        self.code.mkdir()
        self.remote = self.box.root / "remote.git"
        git("init", "-q", "--bare", "-b", "main", str(self.remote), cwd=self.box.root)
        self.pusher = self.clone(self.box.root / "pusher")
        self.commit(self.pusher, "one")
        git("push", "-q", "origin", "main", cwd=self.pusher)
        for name in ("clean", "changed", "ahead", "behind", "diverged"):
            self.clone(self.code / name)
        (self.code / "changed" / "new.txt").write_text("x")
        self.commit(self.code / "ahead", "mine")
        self.commit(self.code / "diverged", "mine too")
        self.commit(self.pusher, "two")
        git("push", "-q", "origin", "main", cwd=self.pusher)
        git("fetch", "-q", cwd=self.code / "behind")
        git("fetch", "-q", cwd=self.code / "diverged")
        local = self.code / "local"
        local.mkdir()
        git("init", "-q", "-b", "main", cwd=local)
        self.commit(local, "alone")

    def clone(self, path):
        git("clone", "-q", str(self.remote), str(path), cwd=self.box.root)
        return path

    def commit(self, repo, name):
        (repo / name).write_text(name)
        git("add", name, cwd=repo)
        git("commit", "-q", "-m", name, cwd=repo)

    def path(self, name):
        return str(self.code / name)

    def rows(self, blocks):
        return {i["title"]: i for b in blocks if b["type"] == "list" for i in b["items"]}

    def fetch_state(self):
        try:
            return json.loads((self.box.cache / "fetch.json").read_text())
        except OSError:
            return {}

    def wait_for_fetch(self, started=True):
        """The fetch state once the fetch a view started has ended; with `started` false, none having started is fine."""
        for _ in range(100):
            state = self.fetch_state()
            if state.get("done", 0) >= state.get("at", 1) or not (started or state):
                return state
            time.sleep(0.1)
        self.fail("the fetch never finished")

    def settle(self):
        """A fetch a view started never writes into a removed sandbox."""
        self.wait_for_fetch(started=False)

    # ---- bar and popover ----

    def test_bar_counts_the_repos_that_need_you_and_never_fetches(self):
        bar = self.bar(home=self.box.home)
        self.assertEqual(bar["text"], "⎇ 4")  # changed, ahead, behind, diverged
        self.assertEqual(bar["tone"], "warn")
        rows = self.rows(bar["blocks"])
        self.assertEqual(set(rows), {"changed", "ahead", "behind", "diverged", "2 clean repos ›"})
        self.assertEqual(self.fetch_state(), {})

    def test_bar_is_hidden_when_every_repo_is_clean(self):
        bar = self.bar(pilot={"repos": str(self.code / "clean")})
        self.assertEqual(bar["text"], "")
        self.assertNotIn("tone", bar)

    def test_popover_rows_open_lazygit_and_carry_badges_inline_buttons_and_every_action_in_actions(self):
        self.box.shim("lazygit")
        rows = self.rows(self.popover(home=self.box.home))
        self.assertEqual(rows["changed"]["subtitle"], "main · 1 changed")
        self.assertEqual(rows["changed"]["badges"], [{"text": "●1", "tone": "warn"}])
        self.assertNotIn("inline", rows["changed"])
        self.assertEqual(rows["ahead"]["badges"], [{"text": "↑1"}])
        self.assertEqual([a["title"] for a in rows["ahead"]["inline"]], ["Push"])
        self.assertEqual(rows["behind"]["subtitle"], "main · 1 behind")
        self.assertEqual([a["title"] for a in rows["behind"]["inline"]], ["Pull"])
        self.assertEqual(rows["behind"]["inline"][0], {"type": "run", "command": "pull", "title": "Pull",
                                                       "icon": "arrow.down", "context": {"path": self.path("behind")}})
        self.assertIn("diverged (1 to push, 1 behind)", rows["diverged"]["subtitle"])
        self.assertEqual([b["tone"] for b in rows["diverged"]["badges"]], ["alert", "alert"])
        self.assertNotIn("inline", rows["diverged"])
        for title in ("changed", "ahead", "behind", "diverged"):
            actions = rows[title]["actions"]
            # A click on the row opens lazygit there; a plain terminal is the next action.
            self.assertEqual(actions[0], {"type": "run", "command": "lazygit", "title": "lazygit",
                                          "context": {"path": self.path(title)}})
            self.assertTrue(actions[1]["title"].startswith("Open in "))
            for button in rows[title].get("inline", []):
                self.assertIn(button, actions, "%s: %s only inline" % (title, button["title"]))
            self.assertEqual([a["title"] for a in actions[-2:]], ["Open in Finder", "Copy path"])

    def test_clean_row_pushes_the_clean_list(self):
        rows = self.rows(self.popover(home=self.box.home))
        self.assertEqual(rows["2 clean repos ›"]["actions"], [{"type": "push", "command": "clean",
                                                                 "title": "Show clean repos"}])
        blocks = self.blocks("clean", "popover", home=self.box.home)
        self.assertEqual(set(self.rows(blocks)), {"clean", "local"})
        self.assertIn("no upstream", self.rows(blocks)["local"]["subtitle"])

    def test_popover_fetches_at_most_every_ten_minutes_and_shows_what_it_found(self):
        self.commit(self.pusher, "three")
        git("push", "-q", "origin", "main", cwd=self.pusher)
        self.assertNotIn("clean", self.rows(self.bar(home=self.box.home)["blocks"]))  # not fetched yet: looks clean
        result = self.run_ext("bar", surface="popover", home=self.box.home)
        answer = result.of_type("blocks")[0]
        self.assertBlocksShape(answer["blocks"])
        self.assertEqual(answer["refresh"], 2)
        self.assertIn("fetching…", answer["blocks"][0]["title"])
        started = self.wait_for_fetch()["at"]
        blocks = self.popover(home=self.box.home)
        self.assertEqual(self.rows(blocks)["clean"]["badges"], [{"text": "↓2"}])
        self.assertIn("fetched just now", blocks[0]["title"])
        self.assertEqual(self.fetch_state()["at"], started)  # opened again inside 10 min: no second fetch
        state = self.fetch_state()
        state["at"] -= 601
        (self.box.cache / "fetch.json").write_text(json.dumps(state))
        self.popover(home=self.box.home)
        self.assertGreater(self.fetch_state()["at"], started)

    def test_fetch_all_fetches_even_when_fresh(self):
        self.popover(home=self.box.home)
        first = self.wait_for_fetch()["at"]
        r = self.run_ext("fetch", home=self.box.home)
        self.assertEqual(r.of_type("hud")[0]["text"], "Fetching 5 repos, 4 at a time")
        self.assertGreater(self.wait_for_fetch()["at"], first)

    # ---- page ----

    def test_page_shows_the_counts_and_the_table(self):
        blocks = self.page(home=self.box.home)
        stats = {s["label"]: s["value"] for s in blocks[0]["items"]}
        self.assertEqual(stats, {"Changed": "1", "To push": "2", "To pull": "2", "Clean": "2"})
        rows = self.rows(blocks)
        self.assertIn("last commit just now", rows["ahead"]["subtitle"])
        self.assertEqual(blocks[-1]["actions"][0]["command"], "fetch")
        self.wait_for_fetch()

    def test_page_finds_any_repo_as_its_box_runs_and_each_row_opens_a_terminal(self):
        blocks = self.page(home=self.box.home)
        box = blocks[1]
        self.assertEqual(box, {"type": "input", "placeholder": "Find a repo by name or branch", "live": True,
                               "action": {"type": "run", "command": "find", "title": "Find"}})
        rows = self.rows(blocks)
        self.assertEqual([(a["command"], a["icon"]) for a in rows["ahead"]["inline"]],
                         [("push", "arrow.up"), ("open-terminal", "terminal")])
        self.assertTrue(rows["ahead"]["inline"][-1]["title"].startswith("Open in "))
        self.assertNotIn("clean", rows, "a clean repo waits behind its row until searched for")

        self.run_ext("find", input="  cle ", home=self.box.home)
        blocks = self.page(home=self.box.home)
        found = [b for b in blocks if b["type"] == "list"][0]
        self.assertTrue(found["title"].startswith("Matching “cle”"), found["title"])
        self.assertEqual([i["title"] for i in found["items"]], ["clean"])
        self.assertEqual(blocks[-1]["actions"][0], {"type": "run", "command": "find", "title": "Show what needs you"})

        self.run_ext("find", input="nothing-like-it", home=self.box.home)
        self.assertIn("matches “nothing-like-it”", self.page(home=self.box.home)[2]["text"])

        self.run_ext("find", home=self.box.home)  # Show what needs you: no text, the search cleared
        self.assertIn("ahead", self.rows(self.page(home=self.box.home)))
        listed = self.run_ext("repos", home=self.box.home).items
        self.assertFalse([a for i in listed for a in i.get("inline", []) if a.get("icon") == "terminal"],
                         "Hyper+Space's rows stay as they were")
        self.wait_for_fetch()

    def test_the_folder_comes_from_pilot_then_the_preference(self):
        other = self.box.root / "elsewhere"
        self.clone(other / "solo")
        (other / "solo" / "x").write_text("x")
        bar = self.bar(pilot={"repos": str(other)}, preferences={"folder": str(self.code)})
        self.assertEqual(set(self.rows(bar["blocks"])), {"solo"})
        bar = self.bar(preferences={"folder": str(other)})
        self.assertEqual(set(self.rows(bar["blocks"])), {"solo"})
        blocks = self.page(pilot={"repos": str(self.box.root / "nope")})
        self.assertIn("No folder", blocks[0]["text"])

    def test_list_command_lists_every_repo_inside_two_seconds(self):
        r = self.run_ext("repos", home=self.box.home)
        self.assertItemShape(r.items)
        self.assertEqual({i["title"] for i in r.items}, {"clean", "changed", "ahead", "behind", "diverged", "local"})
        self.assertLess(r.elapsed, 2)

    def test_a_slow_git_keeps_the_bar_inside_two_seconds_with_the_cached_state(self):
        self.bar(home=self.box.home)
        self.box.shim("git", "sleep 5")
        bar = self.bar(home=self.box.home)
        self.assertEqual(bar["text"], "⎇ 4")

    # ---- pull and push ----

    def test_pull_fast_forwards_and_a_diverged_branch_says_open_lazygit(self):
        r = self.run_ext("pull", context={"path": self.path("behind")})
        self.assertEqual(r.of_type("hud")[0]["text"], "behind pulled")
        self.assertEqual(git("rev-parse", "HEAD", cwd=self.code / "behind"), git("rev-parse", "HEAD", cwd=self.pusher))
        r = self.run_ext("pull", context={"path": self.path("diverged")})
        self.assertEqual(r.of_type("error")[0]["text"], "Diverged: open lazygit")

    def test_pull_finds_a_divergence_only_the_remote_knows(self):
        self.commit(self.code / "clean", "local")  # ahead by one, behind unknown until git pulls
        r = self.run_ext("pull", context={"path": self.path("clean")})
        self.assertEqual(r.of_type("error")[0]["text"], "Diverged: open lazygit")

    def test_push_sends_the_commits_and_a_rejected_push_shows_gits_line(self):
        self.commit(self.pusher, "three")
        git("push", "-q", "origin", "main", cwd=self.pusher)
        r = self.run_ext("push", context={"path": self.path("ahead")})
        line = r.of_type("error")[0]["text"]
        self.assertIn("[rejected]", line)
        git("pull", "-q", "--rebase", cwd=self.code / "ahead")
        r = self.run_ext("push", context={"path": self.path("ahead")})
        self.assertEqual(r.of_type("hud")[0]["text"], "ahead pushed 1 commit")
        self.assertIn("mine", git("log", "--format=%s", "-1", cwd=self.remote))

    def test_push_needs_an_upstream_and_commits(self):
        r = self.run_ext("push", context={"path": self.path("local")})
        self.assertEqual(r.of_type("error")[0]["text"], "local has no upstream branch: set it in lazygit")
        r = self.run_ext("push", context={"path": self.path("clean")})
        self.assertEqual(r.of_type("hud")[0]["text"], "clean has nothing to push")
        r = self.run_ext("push", context={"path": str(self.box.root / "nope")})
        self.assertEqual(r.of_type("error")[0]["text"], "got no repo folder that exists")

    # ---- terminal, lazygit, ⋯ ----

    def test_lazygit_opens_in_pilots_terminal(self):
        self.box.shim("open")
        lazygit = self.box.shim("lazygit")
        repo = self.path("changed")
        r = self.run_ext("lazygit", context={"path": repo}, pilot={"terminal": "com.mitchellh.ghostty"})
        self.assertEqual(r.of_type("hud")[0]["text"], "lazygit on changed")
        self.run_ext("lazygit", context={"path": repo}, pilot={"terminal": "com.apple.Terminal"})
        self.run_ext("open-terminal", context={"path": repo}, pilot={"terminal": "net.kovidgoyal.kitty"})
        self.assertEqual(self.box.shim_calls(), [
            "open -n -b com.mitchellh.ghostty --args --working-directory=%s --window-save-state=never --command=%s"
            % (repo, lazygit),
            "open -a Terminal %s" % (self.box.cache / "lazygit.command"),
            "open -b net.kovidgoyal.kitty %s" % repo])

    def test_more_menu_has_finder_the_github_page_and_copy_path(self):
        git("remote", "add", "github", "git@github.com:someone/local.git", cwd=self.code / "local")
        rows = self.rows(self.blocks("clean", "popover", home=self.box.home, pilot={"terminal": "com.apple.Terminal"}))
        titles = [a["title"] for a in rows["local"]["actions"]]
        self.assertIn("Open in Terminal", titles[:2])  # second when this Mac has lazygit
        self.assertEqual(titles[-3:], ["Open in Finder", "Open on GitHub", "Copy path"])
        self.assertEqual(rows["local"]["actions"][-2]["url"], "https://github.com/someone/local")
