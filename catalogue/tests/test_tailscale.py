import json
import time

from harness import ExtensionTestCase

# A synthetic `tailscale status --json` (Tailscale 1.104 shape, trimmed to the fields read): made-up names, the
# reserved tailnet.example name, documentation IPv4 addresses (192.0.2.0/24) and Tailscale's fd7a:115c:a1e0::/48 range.
# Never a real one: the public repo's guard refuses *.ts.net names and addresses in Tailscale's CGNAT range.
NODE = {"Relay": "fra", "Addrs": None, "Active": False, "ExitNode": False, "ExitNodeOption": False, "Tags": None}
FIXTURE = {
    "Version": "1.104.5", "BackendState": "Running", "TailscaleIPs": ["192.0.2.1", "fd7a:115c:a1e0::1"],
    "MagicDNSSuffix": "tailnet.example",
    "CurrentTailnet": {"Name": "someone@example.com", "MagicDNSSuffix": "tailnet.example", "MagicDNSEnabled": True},
    "Self": dict(NODE, ID="n1", HostName="Studio Mac", DNSName="studio-mac.tailnet.example.", OS="macOS", Online=True,
                 TailscaleIPs=["192.0.2.1", "fd7a:115c:a1e0::1"], LastSeen="0001-01-01T00:00:00Z"),
    "Peer": {
        "nodekey:aa": dict(NODE, ID="n2", HostName="raspberrypi", DNSName="raspberrypi.tailnet.example.", OS="linux",
                           Online=True, ExitNode=True, TailscaleIPs=["192.0.2.2", "fd7a:115c:a1e0::2"],
                           LastSeen="0001-01-01T00:00:00Z"),
        "nodekey:bb": dict(NODE, ID="n3", HostName="Pocket", DNSName="pocket.tailnet.example.", OS="iOS", Online=False,
                           TailscaleIPs=["192.0.2.3", "fd7a:115c:a1e0::3"], LastSeen="2026-01-02T10:00:00Z"),
        "nodekey:cc": dict(NODE, ID="n4", HostName="", DNSName="gaming-pc.tailnet.example.", OS="windows", Online=False,
                           TailscaleIPs=["fd7a:115c:a1e0::4"], LastSeen="0001-01-01T00:00:00Z"),
    },
}


class TailscaleTests(ExtensionTestCase):
    EXTENSION = "tailscale"

    def answer(self, status=None, code=0, stdout=None):
        """A fake tailscale on PATH: logs its arguments, prints `status` as JSON (or `stdout`) and exits `code`."""
        out = self.box.root / "status.json"
        out.write_text(stdout if stdout is not None else json.dumps(status if status is not None else FIXTURE))
        self.box.shim("tailscale", 'printf "%%s\\n" "tailscale $*" >> "%s"\ncat "%s"\nexit %d' % (self.box.log, out, code))

    def devices(self):
        r = self.run_ext("devices")
        self.assertItemShape(r.items)
        return r.items

    def test_lists_this_mac_then_online_then_offline_devices(self):
        self.answer()
        items = self.devices()
        self.assertEqual([i["title"] for i in items], ["Studio Mac", "raspberrypi", "gaming-pc", "Pocket"])
        self.assertEqual([i["icon"] for i in items], ["🟢", "🟢", "⚪", "⚪"])
        self.assertEqual(items[0]["subtitle"], "macOS · 192.0.2.1 · this Mac")
        self.assertEqual(items[1]["subtitle"], "linux · 192.0.2.2 · online, your exit node")
        self.assertEqual(items[2]["subtitle"], "windows · fd7a:115c:a1e0::4 · offline")
        self.assertEqual(items[3]["subtitle"], "iOS · 192.0.2.3 · last seen 2026-01-02")
        self.assertIn("offline", items[3]["keywords"])
        self.assertIn("pocket.tailnet.example", items[3]["keywords"])

    def test_return_copies_the_ip_and_the_rest_copy_ipv6_and_name(self):
        self.answer()
        pi = self.devices()[1]
        self.assertEqual(pi["actions"][0], {"type": "copy", "text": "192.0.2.2", "title": "Copy IP 192.0.2.2"})
        self.assertEqual([a["text"] for a in pi["actions"][1:]], ["fd7a:115c:a1e0::2", "raspberrypi.tailnet.example"])

    def test_runs_only_status_json(self):
        self.answer()
        self.devices()
        self.assertEqual(self.box.shim_calls(), ["tailscale status --json"])

    def test_says_plainly_when_tailscale_app_is_not_running(self):
        self.answer(stdout="failed to connect to local Tailscale service; is Tailscale running?\n", code=1)
        items = self.devices()
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["title"], "Tailscale isn't running")
        self.assertEqual(items[0]["actions"], [{"type": "run", "command": "connect", "title": "Connect"},
                                               {"type": "open", "url": "/Applications/Tailscale.app",
                                                "title": "Open Tailscale"}])

    def test_a_hung_cli_answers_in_time(self):
        self.box.shim("tailscale", "sleep 5\ntrue")  # a child, as /usr/local/bin/tailscale has
        r = self.box.run(self.EXTENSION, "devices")
        self.assertLess(r.elapsed, 2)
        self.assertEqual(r.items[0]["title"], "Tailscale isn't running")

    def test_stopped_and_signed_out_say_what_to_do(self):
        for state, title in (("Stopped", "Tailscale is turned off"), ("NeedsLogin", "Tailscale is signed out")):
            with self.subTest(state=state):
                self.answer(dict(FIXTURE, BackendState=state, Peer=None))
                self.assertEqual(self.devices()[0]["title"], title)

    def test_no_peers_lists_this_mac_alone(self):
        self.answer(dict(FIXTURE, Peer=None))
        self.assertEqual([i["title"] for i in self.devices()], ["Studio Mac"])

    def test_page_counts_and_lists_online_then_offline(self):
        self.answer()
        blocks = self.page()
        self.assertEqual({s["label"]: s["value"] for s in blocks[0]["items"]}, {"Online": "2", "Offline": "2", "Devices": "4"})
        lists = [(b["title"], [i["title"] for i in b["items"]]) for b in blocks if b["type"] == "list"]
        self.assertEqual(lists, [("Online", ["Studio Mac", "raspberrypi"]), ("Offline", ["gaming-pc", "Pocket"])])
        self.assertEqual(blocks[1], {"type": "buttons", "actions": [{"type": "run", "command": "disconnect",
                                                                     "title": "Disconnect"}]})
        pocket = blocks[3]["items"][1]
        self.assertEqual(pocket["subtitle"], "iOS · 192.0.2.3 · last seen 2026-01-02")
        self.assertEqual([a["title"] for a in pocket["actions"]],
                         ["Copy IP 192.0.2.3", "Copy IPv6 fd7a:115c:a1e0::3", "Copy name pocket.tailnet.example"])
        self.assertEqual(self.box.shim_calls(), ["tailscale status --json"])

    def test_bar_counts_online_devices_and_its_click_lists_them(self):
        self.answer()
        line = self.bar()
        self.assertEqual(line["text"], "🛜 2")
        self.assertNotIn("tone", line)
        popover = self.popover()
        self.assertEqual([b["type"] for b in popover], ["buttons", "list", "list"])
        self.assertEqual(popover[0]["actions"][0]["command"], "disconnect")
        self.assertEqual([b["title"] for b in popover[1:]], ["Online", "Offline"])
        self.assertEqual([i["title"] for i in popover[1]["items"]], ["Studio Mac", "raspberrypi"])

    def test_bar_and_page_say_when_tailscale_is_not_running(self):
        self.answer(stdout="failed to connect\n", code=1)
        line = self.bar()
        self.assertEqual((line["text"], line["tone"]), ("🛜", "warn"))
        self.assertEqual(line["blocks"][0]["items"][0]["title"], "Tailscale isn't running")
        self.assertEqual(self.page()[0]["items"][0]["title"], "Tailscale isn't running")


class TailscaleSwitchTests(ExtensionTestCase):
    """Connect and Disconnect (T46) on a fake CLI that keeps a state: `status --json` answers only while the fake
    Tailscale.app runs (the `open` shim starts it), `up` and `down` change the state. Nothing reaches the real one."""
    EXTENSION = "tailscale"
    APP = "/Applications/Tailscale.app"

    def fake(self, state="Running", app=True, launches="Stopped", up="Running"):
        """`state` now; `app` whether Tailscale.app runs; the state it comes up in once opened; what `up` leads to
        (`hang`: it never returns, as one waiting on a sign-in)."""
        root = self.box.root
        (root / "status.json").write_text(json.dumps(dict(FIXTURE, BackendState="__STATE__")))
        (root / "state").write_text(state)
        (root / "launches").write_text(launches)
        (root / "up").write_text(up)
        if app:
            (root / "app").write_text("")
        elif (root / "app").exists():
            (root / "app").unlink()
        self.box.shim("tailscale", """printf "%s\\n" "tailscale $*" >> "{log}"
cd "{root}"
case "$1" in
  status) [ -f app ] || {{ echo "failed to connect to local Tailscale service" >&2; exit 1; }}
          sed "s/__STATE__/$(cat state)/" status.json ;;
  up) [ "$(cat up)" = hang ] && {{ echo "To authenticate, visit: https://login.example.com/a/secret" >&2; sleep 60; }}
      cat up > state ;;
  down) echo Stopped > state ;;
  *) exit 2 ;;
esac""".format(log=self.box.log, root=root))
        self.box.shim("open", 'printf "%%s\\n" "open $*" >> "%s"\ntouch "%s/app"\ncp "%s/launches" "%s/state"'
                      % (self.box.log, root, root, root))

    def state(self):
        return (self.box.root / "state").read_text().strip()

    def switch(self, command):
        r = self.run_ext(command)
        for action in r.actions:
            self.assertActionShape(action)
        self.assertNotIn("secret", r.stdout)
        return r

    def calls(self):
        """The calls, the status asks while it waits folded into one."""
        out = []
        for call in self.box.shim_calls():
            if not (out and call == out[-1] == "tailscale status --json"):
                out.append(call)
        return out

    def test_connect_when_off_runs_a_bare_up(self):
        self.fake("Stopped")
        r = self.switch("connect")
        self.assertEqual(r.of_type("hud")[0]["text"], "Tailscale is on")
        self.assertEqual(self.calls(), ["tailscale status --json", "tailscale up", "tailscale status --json"])
        self.assertEqual(self.state(), "Running")

    def test_disconnect_when_on_runs_down(self):
        self.fake("Running")
        r = self.switch("disconnect")
        self.assertEqual(r.of_type("hud")[0]["text"], "Tailscale is off")
        self.assertEqual(self.calls(), ["tailscale status --json", "tailscale down", "tailscale status --json"])
        self.assertEqual(self.state(), "Stopped")

    def test_connect_opens_tailscale_app_first_when_it_is_not_running(self):
        self.fake("Stopped", app=False, launches="Stopped")
        r = self.switch("connect")
        self.assertEqual(r.of_type("hud")[0]["text"], "Tailscale is on")
        self.assertEqual(self.calls(), ["tailscale status --json", "open -g %s" % self.APP, "tailscale status --json",
                                        "tailscale up", "tailscale status --json"])

    def test_connect_skips_up_when_the_app_comes_up_connected(self):
        self.fake("Stopped", app=False, launches="Running")
        r = self.switch("connect")
        self.assertEqual(r.of_type("hud")[0]["text"], "Tailscale is on")
        self.assertNotIn("tailscale up", self.calls())

    def test_signed_out_opens_tailscale_to_sign_in_and_never_runs_up(self):
        self.fake("NeedsLogin")
        r = self.switch("connect")
        self.assertEqual(r.actions, [{"type": "open", "url": self.APP, "title": "Open Tailscale"}])
        self.assertIn("sign in", r.of_type("hud")[0]["text"])
        self.assertEqual(self.calls(), ["tailscale status --json"])

    def test_an_up_that_wants_a_sign_in_opens_tailscale(self):
        self.fake("Stopped", up="NeedsLogin")
        r = self.switch("connect")
        self.assertEqual(r.actions, [{"type": "open", "url": self.APP, "title": "Open Tailscale"}])

    def test_a_hung_up_is_stopped_in_time_and_its_output_never_shown(self):
        self.fake("Stopped", up="hang")
        started = time.monotonic()
        r = self.switch("connect")
        self.assertLess(time.monotonic() - started, 28)
        self.assertIn("couldn't connect", r.of_type("error")[0]["text"])

    def test_disconnect_when_already_off_runs_nothing(self):
        for kwargs in ({"state": "Stopped"}, {"app": False}, {"state": "NeedsLogin"}):
            with self.subTest(**kwargs):
                self.box.log.unlink() if self.box.log.exists() else None
                self.fake(**kwargs)
                r = self.switch("disconnect")
                self.assertEqual(r.of_type("hud")[0]["text"], "Tailscale is already off")
                self.assertEqual(self.calls(), ["tailscale status --json"])

    def test_page_bar_and_list_only_read_and_offer_the_right_switch(self):
        wanted = {("Running", True): {"type": "run", "command": "disconnect", "title": "Disconnect"},
                  ("Stopped", True): {"type": "run", "command": "connect", "title": "Connect"},
                  ("Stopped", False): {"type": "run", "command": "connect", "title": "Connect"},
                  ("NeedsLogin", True): {"type": "open", "url": self.APP, "title": "Open Tailscale"}}
        for (state, app), button in wanted.items():
            with self.subTest(state=state, app=app):
                self.box.log.unlink() if self.box.log.exists() else None
                self.fake(state, app=app)
                for blocks in (self.page(), self.popover(), self.bar()["blocks"]):
                    buttons = [b for b in blocks if b["type"] == "buttons"]
                    self.assertEqual(buttons, [{"type": "buttons", "actions": [button]}])
                    for action in buttons[0]["actions"]:
                        self.assertActionShape(action)
                self.run_ext("devices")
                self.assertEqual(set(self.box.shim_calls()), {"tailscale status --json"})
                self.assertEqual(self.state(), state)

    def test_return_on_a_turned_off_row_connects(self):
        self.fake("Stopped")
        item = self.run_ext("devices").items[0]
        self.assertEqual(item["title"], "Tailscale is turned off")
        self.assertEqual(item["actions"][0], {"type": "run", "command": "connect", "title": "Connect"})
