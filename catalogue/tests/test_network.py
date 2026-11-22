"""Network: the cases of the Tailscale, Ports and SSH hosts tests carried over (each old test's name in its docstring), new
ones for Speedtest (which had none), Overview and Devices. Every network read is a shim with fixture output, in
documentation ranges (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24, RFC 7042's 00:00:5e:00:53 MACs); nothing here sends
a packet: the Devices look (probe, mDNS, resolver) is tested in-process with fakes, and every run seeds a fresh look so
none starts."""
import importlib.util
import json
import os
import struct
import subprocess
import sys
import time
from unittest import mock

from harness import EXTENSIONS, ExtensionTestCase, manifest

_spec = importlib.util.spec_from_file_location("network_main", EXTENSIONS / "network" / "main.py")
network = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(network)

BLOCKS = "stats,meter,list,markdown,buttons,section,chat,input,hero,strip,note,links"
PILOT = {"blocks": BLOCKS}


class NetworkCase(ExtensionTestCase):
    EXTENSION = "network"

    def setUp(self):
        super().setUp()
        # A look ran just now, so no run starts one (it would send packets).
        (self.box.data / "scan.json").write_text(json.dumps({"status": "done", "pid": None, "at": time.time() + 3600}))

    def part(self, name, **kwargs):
        """The page with `name` shown: its nav first (a link per part, this one marked), then that part's blocks."""
        self.run_ext("view", context={"view": name}, **{k: v for k, v in kwargs.items() if k in ("home",)})
        message = self.blocks_message("page", "page", pilot=PILOT, **kwargs)
        nav = message["blocks"][0]
        self.assertEqual(nav["type"], "links")
        self.assertEqual([l["title"] for l in nav["items"]], ["Overview", "Devices", "Tailscale", "Ports", "SSH", "Speedtest"])
        self.assertEqual([l["title"] for l in nav["items"] if l.get("word") == "shown"], [dict(network.VIEWS)[name]])
        self.refresh = message.get("refresh")
        return message["blocks"][1:]


# MARK: - Tailscale (test_tailscale.py)

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
CONNECT = {"type": "run", "command": "tailscale-connect", "title": "Connect"}
DISCONNECT = {"type": "run", "command": "tailscale-disconnect", "title": "Disconnect"}


class TailscaleTests(NetworkCase):
    def answer(self, status=None, code=0, stdout=None):
        """A fake tailscale on PATH: logs its arguments, prints `status` as JSON (or `stdout`) and exits `code`."""
        out = self.box.root / "status.json"
        out.write_text(stdout if stdout is not None else json.dumps(status if status is not None else FIXTURE))
        self.box.shim("tailscale", 'printf "%%s\\n" "tailscale $*" >> "%s"\ncat "%s"\nexit %d' % (self.box.log, out, code))

    def devices(self):
        r = self.run_ext("tailscale")
        self.assertItemShape(r.items)
        return r.items

    def test_lists_this_mac_then_online_then_offline_devices(self):
        """test_tailscale: test_lists_this_mac_then_online_then_offline_devices."""
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
        """test_tailscale: test_return_copies_the_ip_and_the_rest_copy_ipv6_and_name."""
        self.answer()
        pi = self.devices()[1]
        self.assertEqual(pi["actions"][0], {"type": "copy", "text": "192.0.2.2", "title": "Copy IP 192.0.2.2"})
        self.assertEqual([a["text"] for a in pi["actions"][1:]], ["fd7a:115c:a1e0::2", "raspberrypi.tailnet.example"])

    def test_runs_only_status_json(self):
        """test_tailscale: test_runs_only_status_json."""
        self.answer()
        self.devices()
        self.assertEqual(self.box.shim_calls(), ["tailscale status --json"])

    def test_says_plainly_when_tailscale_app_is_not_running(self):
        """test_tailscale: test_says_plainly_when_tailscale_app_is_not_running."""
        self.answer(stdout="failed to connect to local Tailscale service; is Tailscale running?\n", code=1)
        items = self.devices()
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["title"], "Tailscale isn't running")
        self.assertEqual(items[0]["actions"], [CONNECT, {"type": "open", "url": "/Applications/Tailscale.app",
                                                         "title": "Open Tailscale"}])

    def test_a_hung_cli_answers_in_time(self):
        """test_tailscale: test_a_hung_cli_answers_in_time."""
        self.box.shim("tailscale", "sleep 5\ntrue")  # a child, as /usr/local/bin/tailscale has
        r = self.box.run(self.EXTENSION, "tailscale")
        self.assertLess(r.elapsed, 2)
        self.assertEqual(r.items[0]["title"], "Tailscale isn't running")

    def test_stopped_and_signed_out_say_what_to_do(self):
        """test_tailscale: test_stopped_and_signed_out_say_what_to_do."""
        for state, title in (("Stopped", "Tailscale is turned off"), ("NeedsLogin", "Tailscale is signed out")):
            with self.subTest(state=state):
                self.answer(dict(FIXTURE, BackendState=state, Peer=None))
                self.assertEqual(self.devices()[0]["title"], title)

    def test_no_peers_lists_this_mac_alone(self):
        """test_tailscale: test_no_peers_lists_this_mac_alone."""
        self.answer(dict(FIXTURE, Peer=None))
        self.assertEqual([i["title"] for i in self.devices()], ["Studio Mac"])

    def test_page_counts_and_lists_online_then_offline(self):
        """test_tailscale: test_page_counts_and_lists_online_then_offline (now the page's Tailscale part)."""
        self.answer()
        blocks = self.part("tailscale")
        self.assertEqual({s["label"]: s["value"] for s in blocks[0]["items"]}, {"Online": "2", "Offline": "2", "Devices": "4"})
        lists = [(b["title"], [i["title"] for i in b["items"]]) for b in blocks if b["type"] == "list"]
        self.assertEqual(lists, [("Online", ["Studio Mac", "raspberrypi"]), ("Offline", ["gaming-pc", "Pocket"])])
        self.assertEqual(blocks[1], {"type": "buttons", "actions": [DISCONNECT]})
        pocket = blocks[3]["items"][1]
        self.assertEqual(pocket["subtitle"], "iOS · 192.0.2.3 · last seen 2026-01-02")
        self.assertEqual([a["title"] for a in pocket["actions"]],
                         ["Copy IP 192.0.2.3", "Copy IPv6 fd7a:115c:a1e0::3", "Copy name pocket.tailnet.example"])
        self.assertEqual(self.box.shim_calls(), ["tailscale status --json"])

    def test_bar_counts_online_devices_and_its_click_lists_them(self):
        """test_tailscale: test_bar_counts_online_devices_and_its_click_lists_them."""
        self.answer()
        line = self.bar()
        self.assertEqual(line["text"], "🛜 2")
        self.assertNotIn("tone", line)
        popover = self.popover()
        self.assertEqual([b["type"] for b in popover], ["buttons", "list", "list"])
        self.assertEqual(popover[0]["actions"][0]["command"], "tailscale-disconnect")
        self.assertEqual([b["title"] for b in popover[1:]], ["Online", "Offline"])
        self.assertEqual([i["title"] for i in popover[1]["items"]], ["Studio Mac", "raspberrypi"])

    def test_bar_and_page_say_when_tailscale_is_not_running(self):
        """test_tailscale: test_bar_and_page_say_when_tailscale_is_not_running."""
        self.answer(stdout="failed to connect\n", code=1)
        line = self.bar()
        self.assertEqual((line["text"], line["tone"]), ("🛜", "warn"))
        self.assertEqual(line["blocks"][0]["items"][0]["title"], "Tailscale isn't running")
        self.assertEqual(self.part("tailscale")[0]["items"][0]["title"], "Tailscale isn't running")

    def test_not_installed_says_so_and_offers_no_switch(self):
        """New: no tailscale anywhere on PATH."""
        with mock.patch.object(network.shutil, "which", return_value=None), \
                mock.patch.object(network, "TS_CLI", str(self.box.root / "no-tailscale")):
            data, why = network.ts_status()
        self.assertEqual((data, why), (None, network.TS_NOT_INSTALLED))
        self.assertEqual(network.ts_switch(why), [])


class TailscaleSwitchTests(NetworkCase):
    """test_tailscale's TailscaleSwitchTests: Connect and Disconnect (T46) on a fake CLI that keeps a state:
    `status --json` answers only while the fake Tailscale.app runs (the `open` shim starts it), `up` and `down` change
    the state. Nothing reaches the real one."""
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
        """test_tailscale: test_connect_when_off_runs_a_bare_up."""
        self.fake("Stopped")
        r = self.switch("tailscale-connect")
        self.assertEqual(r.of_type("hud")[0]["text"], "Tailscale is on")
        self.assertEqual(self.calls(), ["tailscale status --json", "tailscale up", "tailscale status --json"])
        self.assertEqual(self.state(), "Running")

    def test_disconnect_when_on_runs_down(self):
        """test_tailscale: test_disconnect_when_on_runs_down."""
        self.fake("Running")
        r = self.switch("tailscale-disconnect")
        self.assertEqual(r.of_type("hud")[0]["text"], "Tailscale is off")
        self.assertEqual(self.calls(), ["tailscale status --json", "tailscale down", "tailscale status --json"])
        self.assertEqual(self.state(), "Stopped")

    def test_connect_opens_tailscale_app_first_when_it_is_not_running(self):
        """test_tailscale: test_connect_opens_tailscale_app_first_when_it_is_not_running."""
        self.fake("Stopped", app=False, launches="Stopped")
        r = self.switch("tailscale-connect")
        self.assertEqual(r.of_type("hud")[0]["text"], "Tailscale is on")
        self.assertEqual(self.calls(), ["tailscale status --json", "open -g %s" % self.APP, "tailscale status --json",
                                        "tailscale up", "tailscale status --json"])

    def test_connect_skips_up_when_the_app_comes_up_connected(self):
        """test_tailscale: test_connect_skips_up_when_the_app_comes_up_connected."""
        self.fake("Stopped", app=False, launches="Running")
        r = self.switch("tailscale-connect")
        self.assertEqual(r.of_type("hud")[0]["text"], "Tailscale is on")
        self.assertNotIn("tailscale up", self.calls())

    def test_signed_out_opens_tailscale_to_sign_in_and_never_runs_up(self):
        """test_tailscale: test_signed_out_opens_tailscale_to_sign_in_and_never_runs_up."""
        self.fake("NeedsLogin")
        r = self.switch("tailscale-connect")
        self.assertEqual(r.actions, [{"type": "open", "url": self.APP, "title": "Open Tailscale"}])
        self.assertIn("sign in", r.of_type("hud")[0]["text"])
        self.assertEqual(self.calls(), ["tailscale status --json"])

    def test_an_up_that_wants_a_sign_in_opens_tailscale(self):
        """test_tailscale: test_an_up_that_wants_a_sign_in_opens_tailscale."""
        self.fake("Stopped", up="NeedsLogin")
        r = self.switch("tailscale-connect")
        self.assertEqual(r.actions, [{"type": "open", "url": self.APP, "title": "Open Tailscale"}])

    def test_a_hung_up_is_stopped_in_time_and_its_output_never_shown(self):
        """test_tailscale: test_a_hung_up_is_stopped_in_time_and_its_output_never_shown."""
        self.fake("Stopped", up="hang")
        started = time.monotonic()
        r = self.switch("tailscale-connect")
        self.assertLess(time.monotonic() - started, 28)
        self.assertIn("couldn't connect", r.of_type("error")[0]["text"])

    def test_disconnect_when_already_off_runs_nothing(self):
        """test_tailscale: test_disconnect_when_already_off_runs_nothing."""
        for kwargs in ({"state": "Stopped"}, {"app": False}, {"state": "NeedsLogin"}):
            with self.subTest(**kwargs):
                self.box.log.unlink() if self.box.log.exists() else None
                self.fake(**kwargs)
                r = self.switch("tailscale-disconnect")
                self.assertEqual(r.of_type("hud")[0]["text"], "Tailscale is already off")
                self.assertEqual(self.calls(), ["tailscale status --json"])

    def test_page_bar_and_list_only_read_and_offer_the_right_switch(self):
        """test_tailscale: test_page_bar_and_list_only_read_and_offer_the_right_switch."""
        wanted = {("Running", True): DISCONNECT, ("Stopped", True): CONNECT, ("Stopped", False): CONNECT,
                  ("NeedsLogin", True): {"type": "open", "url": self.APP, "title": "Open Tailscale"}}
        for (state, app), button in wanted.items():
            with self.subTest(state=state, app=app):
                self.box.log.unlink() if self.box.log.exists() else None
                self.fake(state, app=app)
                for blocks in (self.part("tailscale"), self.popover(), self.bar()["blocks"]):
                    buttons = [b for b in blocks if b["type"] == "buttons"]
                    self.assertEqual(buttons, [{"type": "buttons", "actions": [button]}])
                    for action in buttons[0]["actions"]:
                        self.assertActionShape(action)
                self.run_ext("tailscale")
                self.assertEqual(set(self.box.shim_calls()), {"tailscale status --json"})
                self.assertEqual(self.state(), state)

    def test_return_on_a_turned_off_row_connects(self):
        """test_tailscale: test_return_on_a_turned_off_row_connects."""
        self.fake("Stopped")
        item = self.run_ext("tailscale").items[0]
        self.assertEqual(item["title"], "Tailscale is turned off")
        self.assertEqual(item["actions"][0], CONNECT)


# MARK: - Ports (test_ports.py)

LISTENER = """
import signal, socket, sys, time
if sys.argv[1] == "stubborn":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1)
print(s.getsockname()[1], flush=True)
time.sleep(60)
"""


class PortsTests(NetworkCase):
    def listener(self, kind="plain"):
        proc = subprocess.Popen([sys.executable, "-c", LISTENER, kind], stdout=subprocess.PIPE, text=True)
        self.addCleanup(lambda: (proc.poll() is None and proc.kill(), proc.wait(), proc.stdout.close()))
        return proc, int(proc.stdout.readline())

    def row(self, items, pid, port):
        return next((i for i in items if i.get("id") == "%d-%d" % (pid, port)), None)

    def test_lists_a_listening_port_with_its_program_and_actions(self):
        """test_ports: test_lists_a_listening_port_with_its_program_and_actions."""
        proc, port = self.listener()
        r = self.run_ext("kill-port")
        self.assertItemShape(r.items)
        row = self.row(r.items, proc.pid, port)
        self.assertIsNotNone(row, "port %d not listed" % port)
        self.assertEqual(row["title"], "Port %d" % port)
        self.assertIn("pid %d" % proc.pid, row["subtitle"])
        self.assertIn("127.0.0.1", row["subtitle"])
        self.assertEqual([a["type"] for a in row["actions"]], ["run", "run", "open", "copy", "copy"])
        self.assertEqual(row["actions"][0]["context"]["signal"], "TERM")
        self.assertEqual(row["actions"][1]["context"]["signal"], "KILL")
        self.assertEqual(row["actions"][2]["url"], "http://localhost:%d" % port)
        self.assertLess(r.elapsed, 2)

    def test_quit_sends_sigterm_to_the_owner(self):
        """test_ports: test_quit_sends_sigterm_to_the_owner."""
        proc, port = self.listener()
        row = self.row(self.run_ext("kill-port").items, proc.pid, port)
        r = self.run_ext("kill", context=row["actions"][0]["context"])
        self.assertEqual(r.of_type("hud")[0]["text"][:13], "Asked to quit")
        self.assertEqual(proc.wait(timeout=5), -15)

    def test_force_quit_sends_sigkill(self):
        """test_ports: test_force_quit_sends_sigkill."""
        proc, port = self.listener("stubborn")
        row = self.row(self.run_ext("kill-port").items, proc.pid, port)
        r = self.run_ext("kill", context=row["actions"][1]["context"])
        self.assertTrue(r.of_type("hud")[0]["text"].startswith("Force quit"))
        self.assertEqual(proc.wait(timeout=5), -9)

    def test_refuses_pid_one_pilot_and_a_port_no_longer_held(self):
        """test_ports: test_refuses_pid_one_pilot_and_a_port_no_longer_held."""
        cases = [
            ({"pid": 1, "port": 80, "signal": "KILL"}, "will not quit pid 1"),
            ({"pid": 0, "port": 80}, "will not quit pid 0"),
            ({"pid": "12", "port": 80}, "will not quit pid 12"),
            # The program's parent is Pilot when Pilot runs it; here the parent is this test.
            ({"pid": os.getpid(), "port": 80, "signal": "KILL"}, "will not quit Pilot"),
        ]
        for context, text in cases:
            with self.subTest(context):
                self.assertEqual(self.run_ext("kill", context=context).of_type("error"), [{"type": "error", "text": text}])
        proc, port = self.listener()
        r = self.run_ext("kill", context={"pid": proc.pid, "port": port + 1 if port < 65535 else port - 1, "signal": "KILL"})
        self.assertIn("no longer held", r.of_type("error")[0]["text"])
        self.assertIsNone(proc.poll(), "the listener must still run")


# lsof's -F pcn answer for two listeners; its -t check (a quit's) answers nothing, so no pid is ever signalled.
LSOF = r'''case "$*" in *" -t "*) exit 1;; esac
printf 'p4242\ncnode\nn*:3000\nn[::1]:3000\np4343\ncpython3\nn127.0.0.1:8000\n'
'''


class PortsPageTests(NetworkCase):
    """test_ports' PortsPageTests: the page does its job in place (Sven, 2026-10-31): each port a row, Quit asking first
    in it. lsof and ps are shims."""

    def setUp(self):
        super().setUp()
        self.box.shim("lsof", LSOF)
        self.box.shim("ps", "echo /usr/local/bin/node")

    def test_each_port_is_a_row_whose_quits_ask_first(self):
        """test_ports: test_each_port_is_a_row_whose_quits_ask_first; the part asks again every 10 s, as Ports' page did."""
        blocks = self.part("ports")
        self.assertEqual(self.refresh, 10)
        self.assertEqual(len(blocks), 1)
        self.assertEqual(blocks[0]["title"], "Listening · 2 ports")
        rows = blocks[0]["items"]
        self.assertEqual([r["title"] for r in rows], ["Port 3000", "Port 8000"])
        quit_, force = rows[0]["actions"][:2]
        self.assertEqual(quit_["ask"], {"confirm": "Quit node on port 3000?"})
        self.assertTrue(quit_["destructive"] and force["destructive"])
        self.assertEqual(force["context"], {"pid": 4242, "port": 3000, "name": "node", "signal": "KILL"})
        self.assertEqual(rows[0]["inline"], [dict(quit_, icon="xmark")])
        self.assertEqual(rows[0]["subtitle"], "node · pid 4242 · *, [::1]")

    def test_a_quit_from_the_page_checks_the_port_again_before_any_signal(self):
        """test_ports: test_a_quit_from_the_page_checks_the_port_again_before_any_signal."""
        row = self.part("ports")[0]["items"][0]
        r = self.run_ext("kill", context=row["inline"][0]["context"])
        self.assertEqual(r.of_type("error"), [{"type": "error", "text": "port 3000 is no longer held by pid 4242"}])

    def test_nothing_listening_says_so(self):
        """test_ports: test_nothing_listening_says_so."""
        self.box.shim("lsof", "exit 1")
        self.assertEqual(self.part("ports")[0]["items"][0]["title"], "No TCP port is listening")


# MARK: - SSH hosts (test_ssh_hosts.py)

class SSHHostsTests(NetworkCase):
    def setUp(self):
        super().setUp()
        ssh = self.box.home / ".ssh"
        (ssh / "config.d").mkdir(parents=True)
        (ssh / "config").write_text(
            "# mine\n"
            "Include config.d/*\n"
            "Host prod prod-alias\n"
            "    HostName 203.0.113.7\n"
            "    User deploy\n"
            "    Port 2222\n"
            "Host *.internal !bastion\n"
            "    User ops\n"
            "Host mac\n"
            "    HostName=127.0.0.1\n"
            "    User sven\n"
            "Match host prod exec true\n"
            "    User nobody\n"
            "Host *\n"
            "    ServerAliveInterval 30\n")
        (ssh / "config.d" / "work").write_text("Host gitbox\n  HostName git.example.com\n  User git\nHost prod\n  User overridden\n")
        self.box.shim("open")

    def hosts(self):
        r = self.run_ext("ssh-hosts", home=self.box.home)
        self.assertItemShape(r.items)
        return {i["title"]: i for i in r.items}

    def test_lists_named_hosts_from_config_and_includes_never_wildcards(self):
        """test_ssh_hosts: test_lists_named_hosts_from_config_and_includes_never_wildcards."""
        rows = self.hosts()
        self.assertEqual(sorted(rows), ["gitbox", "mac", "prod", "prod-alias"])
        self.assertEqual(rows["prod-alias"]["subtitle"], "deploy@203.0.113.7:2222 · ~/.ssh/config")
        self.assertEqual(rows["mac"]["subtitle"], "sven@127.0.0.1 · ~/.ssh/config", "Key=Value reads too; port 22 left out")
        self.assertEqual(rows["gitbox"]["subtitle"], "git@git.example.com · ~/.ssh/config.d/work")
        self.assertIn("203.0.113.7", rows["prod"]["keywords"])

    def test_first_value_wins_as_in_ssh(self):
        """test_ssh_hosts: test_first_value_wins_as_in_ssh."""
        # config.d/work is included before the main file's own prod block, so its User wins, as ssh reads it.
        self.assertEqual(self.hosts()["prod"]["subtitle"], "overridden@203.0.113.7:2222 · ~/.ssh/config.d/work")

    def test_actions_connect_copy_and_open_config(self):
        """test_ssh_hosts: test_actions_connect_copy_and_open_config."""
        prod = self.hosts()["prod"]
        actions = prod["actions"]
        self.assertEqual([a["type"] for a in actions], ["run", "copy", "open"])
        self.assertEqual(actions[0]["command"], "ssh-connect")
        self.assertEqual(actions[0]["context"], {"host": "prod"})
        self.assertTrue(actions[0]["title"].startswith("Connect in "))
        self.assertEqual(actions[1]["text"], "ssh prod")
        self.assertEqual(os.path.realpath(actions[2]["url"]), os.path.realpath(self.box.home / ".ssh" / "config.d" / "work"))
        for a in actions:
            self.assertActionShape(a)

    def test_connect_opens_ghostty_with_ssh(self):
        """test_ssh_hosts: test_connect_opens_ghostty_with_ssh."""
        ghostty = self.box.root / "Ghostty.app"
        ghostty.mkdir()
        r = self.run_ext("ssh-connect", context={"host": "prod"}, preferences={"terminal": str(ghostty)}, home=self.box.home)
        self.assertEqual(r.of_type("hud"), [{"type": "hud", "text": "ssh prod in Ghostty"}])
        self.assertEqual(self.box.shim_calls(), ["open -na %s --args --command=ssh prod --window-save-state=never" % ghostty])

    def test_connect_in_terminal_writes_a_command_file(self):
        """test_ssh_hosts: test_connect_in_terminal_writes_a_command_file."""
        r = self.run_ext("ssh-connect", context={"host": "gitbox"}, preferences={"terminal": "/nonexistent"}, home=self.box.home)
        calls = self.box.shim_calls()
        if calls[0].startswith("open -na"):  # Ghostty is installed on this Mac, the default wins
            self.assertEqual(r.of_type("hud")[0]["text"], "ssh gitbox in Ghostty")
            return
        script = calls[0].split()[-1]
        self.assertEqual(open(script).read(), "#!/bin/sh\nexec ssh gitbox\n")
        self.assertEqual(r.of_type("hud")[0]["text"], "ssh gitbox in Terminal")

    def test_connect_refuses_a_host_the_config_does_not_name(self):
        """test_ssh_hosts: test_connect_refuses_a_host_the_config_does_not_name."""
        for host in ("evil; rm -rf ~", "nothere", "*.internal", None):
            with self.subTest(host=host):
                r = self.run_ext("ssh-connect", context={"host": host}, home=self.box.home)
                self.assertEqual(len(r.of_type("error")), 1)
        self.assertEqual(self.box.shim_calls(), [])

    def test_no_config_says_how_to_add_one(self):
        """test_ssh_hosts: test_no_config_says_how_to_add_one."""
        empty = self.box.root / "empty-home"
        empty.mkdir()
        r = self.run_ext("ssh-hosts", home=empty)
        self.assertEqual(len(r.items), 1)
        self.assertTrue(r.items[0]["title"].startswith("No hosts in"))
        self.assertNotIn("actions", r.items[0])

    def test_include_loops_and_unreadable_files_do_not_hang(self):
        """test_ssh_hosts: test_include_loops_and_unreadable_files_do_not_hang."""
        ssh = self.box.home / ".ssh"
        (ssh / "config.d" / "loop").write_text("Include ~/.ssh/config\nHost looped\n")
        rows = self.hosts()
        self.assertIn("looped", rows)
        self.assertLess(self.box.run(self.EXTENSION, "ssh-hosts", home=self.box.home).elapsed, 2)

    # The page does its job in place (Sven, 2026-10-31): a box narrows the hosts as Sven types, a click connects.

    def test_the_page_lists_every_host_under_a_live_box_each_connecting_inline(self):
        """test_ssh_hosts: test_the_page_lists_every_host_under_a_live_box_each_connecting_inline."""
        blocks = self.part("ssh", home=self.box.home)
        self.assertEqual(blocks[0]["type"], "input")
        self.assertTrue(blocks[0]["live"])
        self.assertEqual(blocks[0]["action"]["command"], "ssh-filter")
        rows = blocks[1]["items"]
        self.assertEqual(blocks[1]["title"], "Hosts")
        self.assertEqual([r["title"] for r in rows], ["gitbox", "mac", "prod", "prod-alias"])
        self.assertEqual(rows[2]["inline"], [dict(rows[2]["actions"][0], icon="terminal")])
        self.assertEqual(rows[2]["actions"][0]["context"], {"host": "prod"})

    def test_typed_words_narrow_the_page_and_show_all_clears_them(self):
        """test_ssh_hosts: test_typed_words_narrow_the_page_and_show_all_clears_them."""
        self.run_ext("ssh-filter", input="deploy", home=self.box.home)
        blocks = self.part("ssh", home=self.box.home)
        self.assertEqual(blocks[1]["actions"][0]["title"], "Show all hosts")
        self.assertEqual(blocks[2]["title"], "1 host matching “deploy”")
        self.assertEqual([r["title"] for r in blocks[2]["items"]], ["prod-alias"])  # prod's User is overridden
        self.run_ext("ssh-filter", input="nothing-like-it", home=self.box.home)
        self.assertEqual(self.part("ssh", home=self.box.home)[2]["items"][0]["title"], "No host matches “nothing-like-it”")
        self.run_ext("ssh-filter", home=self.box.home)
        self.assertEqual(len(self.part("ssh", home=self.box.home)[1]["items"]), 4)

    def test_a_click_on_the_page_connects_in_place(self):
        """test_ssh_hosts: test_a_click_on_the_page_connects_in_place."""
        ghostty = self.box.root / "Ghostty.app"
        ghostty.mkdir()
        row = self.part("ssh", home=self.box.home, preferences={"terminal": str(ghostty)})[1]["items"][1]
        r = self.run_ext("ssh-connect", context=row["actions"][0]["context"], preferences={"terminal": str(ghostty)},
                         home=self.box.home)
        self.assertEqual(r.of_type("hud"), [{"type": "hud", "text": "ssh mac in Ghostty"}])
        self.assertEqual(self.box.shim_calls(), ["open -na %s --args --command=ssh mac --window-save-state=never" % ghostty])


# MARK: - Speedtest (new: the Speedtest extension had no test file)

RESULT = {"dl_throughput": 200000000, "ul_throughput": 50000000, "base_rtt": 12.5, "dl_responsiveness": 1200,
          "ul_responsiveness": 800, "test_endpoint": "test.example", "interface_name": "en1",
          "start_date": "2026-11-22 10:00:00.000", "end_date": "2026-11-22 10:00:20.000"}
LIVE = ("Downlink: capacity 100.000 Mbps, responsiveness 900 RPM (10 MB, 4 flows) - "
        "Uplink: capacity 0.000 Mbps, responsiveness 0 RPM (0 B, 0 flows)")


class SpeedtestTests(NetworkCase):
    def fake_tool(self, hold=3):
        """A networkQuality that prints one live line, holds `hold` s, then writes the result to its -c path."""
        (self.box.root / "result.json").write_text(json.dumps(RESULT))
        self.box.shim("networkQuality", """printf "%s\\n" "networkQuality $*" >> "{log}"
for a in "$@"; do case "$a" in -c*) out="${{a#-c}}";; esac; done
printf '{live}\\r\\n'
sleep {hold}
cp "{root}/result.json" "$out"
""".format(log=self.box.log, live=LIVE, hold=hold, root=self.box.root))

    def wait_for(self, path, seconds=15):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if path.exists():
                return True
            time.sleep(0.2)
        return False

    def test_no_result_yet_offers_a_run(self):
        r = self.run_ext("speedtest")
        detail = r.detail
        self.assertIn("No test yet", detail["markdown"])
        self.assertEqual(detail["actions"], [{"type": "run", "command": "speedtest-start", "title": "Run speed test"}])
        self.assertEqual((self.box.data / "view.txt").read_text(), "speedtest", "Open page lands on Speedtest")

    def test_a_kept_result_shows_with_copy_and_the_page(self):
        (self.box.data / "speedtest-last.json").write_text(json.dumps(network.result_of(RESULT, time.time())))
        detail = self.run_ext("speedtest").detail
        self.assertTrue(detail["markdown"].startswith("# ↓ 200 Mbps · ↑ 50.0 Mbps"))
        self.assertEqual([a["title"] for a in detail["actions"]], ["Run again", "Copy result", "Open page"])
        self.assertTrue(detail["actions"][1]["text"].startswith("Download 200 Mbps · Upload 50.0 Mbps · Latency 12 ms"))
        self.assertEqual(detail["actions"][2]["url"], "pilot://open?tab=page&extension=network")
        for action in detail["actions"]:
            self.assertActionShape(action)
        self.assertEqual({m["label"]: m["text"] for m in detail["metadata"]}["Server"], "test.example")

    def test_run_starts_detached_counts_live_on_the_page_and_keeps_the_result(self):
        self.fake_tool()
        r = self.run_ext("speedtest-start")
        self.assertLess(r.elapsed, 3, "the test runs detached, never inside Pilot's 30 s")
        self.assertEqual(r.of_type("hud"), [{"type": "hud", "text": "Testing your connection…"}])
        self.assertEqual(r.actions, [{"type": "open", "url": "pilot://open?tab=page&extension=network", "title": "Show the test"}])
        self.assertEqual((self.box.data / "view.txt").read_text(), "speedtest")
        running = None
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and running is None:
            blocks = self.part("speedtest")
            if self.refresh == 2 and blocks[0]["type"] == "hero" and blocks[0]["value"] == "105":
                running = blocks
            time.sleep(0.2)
        self.assertIsNotNone(running, "the page counts the live reading (100 MiB-Mbps = 105 Mbps), asked every 2 s")
        self.assertEqual(running[-1]["actions"][0]["command"], "speedtest-stop")
        self.assertTrue(self.wait_for(self.box.data / "speedtest-last.json"))
        blocks = self.part("speedtest")
        self.assertIsNone(self.refresh)
        self.assertEqual([b["value"] for b in blocks if b["type"] == "hero"], ["200", "50.0"])
        self.assertEqual([a["title"] for a in blocks[-1]["actions"]], ["Run again", "Copy result"])
        calls = [c for c in self.box.shim_calls() if c.startswith("networkQuality")]
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0].startswith("networkQuality -s -v -c"))

    def test_stop_ends_a_running_test(self):
        self.fake_tool(hold=20)
        self.run_ext("speedtest-start")
        job = self.box.data / "speedtest-job.json"
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and json.loads(job.read_text() if job.exists() else "{}").get("pid") is None:
            time.sleep(0.1)
        r = self.run_ext("speedtest-stop")
        self.assertEqual(r.of_type("hud"), [{"type": "hud", "text": "Stopped the speed test"}])
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and json.loads(job.read_text()).get("status") != "stopped":
            time.sleep(0.1)
        self.assertEqual(json.loads(job.read_text())["status"], "stopped")
        self.assertEqual(self.run_ext("speedtest-stop").of_type("hud"), [{"type": "hud", "text": "No speed test is running"}])

    def test_without_hero_the_page_draws_stats(self):
        (self.box.data / "speedtest-last.json").write_text(json.dumps(network.result_of(RESULT, time.time())))
        self.run_ext("view", context={"view": "speedtest"})
        blocks = self.page()  # no pilot.blocks: an older Pilot
        self.assertEqual(blocks[0]["type"], "buttons", "the nav falls back to buttons without links")
        self.assertEqual(blocks[1]["type"], "stats")
        self.assertEqual(blocks[1]["items"][:2], [{"label": "Download", "value": "200 Mbps"}, {"label": "Upload", "value": "50.0 Mbps"}])

    def test_live_lines_and_the_json_read_in_the_extensions_words(self):
        now = network.reading(LIVE)
        self.assertAlmostEqual(now["download"], 104.8576)
        self.assertEqual((now["download_rpm"], now["phase"]), (900, "download"))
        self.assertIsNone(network.reading("Uplink: something else"))
        result = network.result_of(RESULT, 1)
        self.assertEqual((result["download"], result["upload"], result["took"]), (200.0, 50.0, 20))
        self.assertIsNone(network.result_of({"base_rtt": 3}, 1))
        self.assertEqual((network.rating(250), network.rating(500), network.rating(1500)), ("Low", "Medium", "High"))

    def test_the_speedtest_extensions_last_result_shows_until_a_new_one(self):
        root = self.box.root / "ExtensionData"
        (root / "speedtest" / "data").mkdir(parents=True)
        (root / "speedtest" / "data" / "last.json").write_text(json.dumps({"download": 90.0, "upload": 9.0, "at": 1}))
        run = {"paths": {"data": str(root / "network" / "data"), "cache": str(self.box.cache)}}
        paths = network.Paths(run)
        self.assertEqual(network.speed_last(paths)["download"], 90.0)
        (root / "network" / "data").mkdir(parents=True)
        (root / "network" / "data" / "speedtest-last.json").write_text(json.dumps({"download": 300.0, "at": 2}))
        self.assertEqual(network.speed_last(paths)["download"], 300.0)


# MARK: - The local network: fixtures for Overview and Devices

HARDWARE = """
Hardware Port: Ethernet
Device: en0
Ethernet Address: 00:00:5e:00:53:01

Hardware Port: Wi-Fi
Device: en1
Ethernet Address: 00:00:5e:00:53:02
"""
ROUTE = """   route to: default
destination: default
       mask: default
    gateway: 192.0.2.1
  interface: {interface}
      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
"""
DNS = """DNS configuration

resolver #1
  search domain[0] : home
  nameserver[0] : 198.51.100.53
  nameserver[1] : 198.51.100.54
  if_index : 12 (en1)
  reach    : 0x00020002 (Reachable,Directly Reachable Address)

resolver #2
  domain   : local
  options  : mdns

DNS configuration (for scoped queries)

resolver #1
  nameserver[0] : 192.0.2.99
"""


def profile(status="spairport_status_connected", name="Harbour", signal="-58 dBm / -92 dBm"):
    """system_profiler SPAirPortDataType -json, its Wi-Fi interface en1 joined to `name` (None: not joined)."""
    entry = {"_name": "en1", "spairport_status_information": status}
    if name is not None:
        entry["spairport_current_network_information"] = {
            "_name": name, "spairport_network_channel": "36 (5GHz, 80MHz)", "spairport_network_rate": 866,
            "spairport_signal_noise": signal}
    return json.dumps({"SPAirPortDataType": [{"spairport_airport_interfaces": [entry]}]})


ARP = """? (192.0.2.1) at 0:0:5e:0:53:1 on en1 ifscope [ethernet]
? (192.0.2.10) at 0:0:5e:0:53:2 on en1 ifscope permanent [ethernet]
? (192.0.2.20) at 0:0:5e:0:53:20 on en1 ifscope [ethernet]
? (192.0.2.30) at 2:0:5e:0:53:30 on en1 ifscope [ethernet]
? (192.0.2.40) at (incomplete) on en1 ifscope [ethernet]
? (192.0.2.255) at ff:ff:ff:ff:ff:ff on en1 ifscope [ethernet]
? (224.0.0.251) at 1:0:5e:0:0:fb on en1 ifscope permanent [ethernet]
? (198.51.100.9) at 0:0:5e:0:53:99 on en0 ifscope [ethernet]
"""


class LocalNetworkCase(NetworkCase):
    def net(self, interface="en1", wifi_profile=None, airport="You are not associated with an AirPort network.",
            summary="", public="203.0.113.50", arp=ARP, online=True):
        """Shims for every local read: networksetup, system_profiler, route, ipconfig, scutil, arp and curl (the one that
        would leave the Mac; its asks logged)."""
        root = self.box.root / "net"
        root.mkdir(exist_ok=True)
        files = {"hardware": HARDWARE, "route": ROUTE.format(interface=interface) if online else "",
                 "profile": wifi_profile if wifi_profile is not None else profile(), "airport": airport + "\n",
                 "summary": summary, "dns": DNS, "arp": arp}
        for name, text in files.items():
            (root / name).write_text(text)
        self.box.shim("networksetup", 'case "$1" in -listallhardwareports) cat "{r}/hardware";; -getairportnetwork) cat "{r}/airport";; '
                                      '*) exit 1;; esac'.format(r=root))
        self.box.shim("system_profiler", 'cat "%s/profile"' % root)
        self.box.shim("route", '[ -s "{r}/route" ] || {{ echo "route: writing to routing socket: not in table" >&2; exit 1; }}\n'
                               'cat "{r}/route"'.format(r=root))
        self.box.shim("ipconfig", """case "$1 $2 $3" in
  "getifaddr en1 ") echo 192.0.2.10;;
  "getifaddr en0 ") echo 192.0.2.11;;
  "getoption en1 subnet_mask"|"getoption en0 subnet_mask") echo 255.255.255.0;;
  "getsummary en1 ") cat "{r}/summary";;
  *) exit 1;;
esac""".format(r=root))
        self.box.shim("scutil", 'cat "%s/dns"' % root)
        self.box.shim("arp", 'cat "%s/arp"' % root)
        if public:
            self.box.shim("curl", 'printf "%%s\\n" "curl $*" >> "%s"\nprintf "%s"' % (self.box.log, public))
        else:
            self.box.shim("curl", 'printf "%%s\\n" "curl $*" >> "%s"\nexit 28' % self.box.log)

    def curl_calls(self):
        return [c for c in self.box.shim_calls() if c.startswith("curl")]


# MARK: - Overview (new)

class OverviewTests(LocalNetworkCase):
    def overview(self):
        r = self.run_ext("overview")
        self.assertItemShape(r.items)
        self.assertEqual(r.stderr, "")
        return {i["id"]: i for i in r.items}

    def test_wifi_name_and_signal_local_and_public_ip_router_and_dns(self):
        self.net()
        rows = self.overview()
        self.assertEqual(list(rows), ["wifi", "local-ip", "public-ip", "router", "dns"])
        self.assertEqual(rows["wifi"]["title"], "Harbour")
        self.assertEqual(rows["wifi"]["subtitle"], "Wi-Fi · signal strong, -58 dBm · channel 36 (5GHz, 80MHz)")
        self.assertEqual(rows["wifi"]["accessory"], {"text": "strong", "tone": "fine"})
        self.assertEqual(rows["local-ip"]["title"], "192.0.2.10")
        self.assertEqual(rows["local-ip"]["subtitle"], "Local IP · Wi-Fi (en1)")
        self.assertEqual(rows["public-ip"]["title"], "203.0.113.50")
        self.assertEqual(rows["public-ip"]["actions"], [{"type": "copy", "text": "203.0.113.50", "title": "Copy public IP"}])
        self.assertEqual(rows["dns"]["title"], "198.51.100.53, 198.51.100.54", "resolver #1's servers, never a scoped one")

    def test_return_on_the_router_opens_its_admin_page(self):
        self.net()
        router = self.overview()["router"]
        self.assertEqual(router["title"], "192.0.2.1")
        self.assertEqual(router["actions"][0], {"type": "open", "url": "http://192.0.2.1", "title": "Open router admin page"})
        self.assertEqual(router["actions"][1]["text"], "192.0.2.1")

    def test_the_public_ip_is_asked_once_and_kept(self):
        self.net()
        self.overview()
        self.overview()
        calls = self.curl_calls()
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0].endswith("https://api.ipify.org"), calls)
        self.assertIn("-m 0.8", calls[0], "a list must answer in 2 s")

    def test_a_public_ip_that_does_not_answer_says_so_and_is_not_asked_again_at_once(self):
        self.net(public=None)
        self.assertEqual(self.overview()["public-ip"]["title"], "Public IP not known")
        self.overview()
        self.assertEqual(len(self.curl_calls()), 1)

    def test_a_hidden_wifi_name_comes_from_networksetup(self):
        self.net(wifi_profile=profile(name="<redacted>"), airport="Current Wi-Fi Network: Harbour")
        self.assertEqual(self.overview()["wifi"]["title"], "Harbour")

    def test_a_name_macos_hides_everywhere_is_said_plainly(self):
        self.net(wifi_profile=profile(name="<redacted>"), summary="  SSID : <redacted>\n")
        wifi = self.overview()["wifi"]
        self.assertEqual(wifi["title"], "Wi-Fi (macOS hides its name)")
        self.assertNotIn("actions", wifi)

    def test_signal_words_and_tones(self):
        self.assertEqual([network.signal_words(d) for d in (-50, -65, -75, -85)],
                         [("strong", "fine"), ("good", "fine"), ("weak", "warn"), ("very weak", "alert")])
        self.net(wifi_profile=profile(signal="-82 dBm / -95 dBm"))
        self.assertEqual(self.overview()["wifi"]["accessory"], {"text": "very weak", "tone": "alert"})

    def test_on_ethernet_with_wifi_off(self):
        self.net(interface="en0", wifi_profile=profile(status="spairport_status_off", name=None),
                 airport="Wi-Fi power is currently off.")
        rows = self.overview()
        self.assertEqual((rows["wifi"]["title"], rows["wifi"]["subtitle"]), ("Wi-Fi is off", "On Ethernet"))
        self.assertEqual(rows["local-ip"]["subtitle"], "Local IP · Ethernet (en0)")

    def test_offline_asks_nothing_of_the_internet(self):
        self.net(online=False, wifi_profile=profile(name=None))
        rows = self.overview()
        self.assertEqual(rows["local-ip"]["title"], "No local IP")
        self.assertEqual((rows["public-ip"]["title"], rows["public-ip"]["subtitle"]), ("Public IP not known", "This Mac is offline"))
        self.assertEqual(rows["router"]["title"], "No router")
        self.assertEqual(self.curl_calls(), [])

    def test_the_overview_page(self):
        self.net()
        blocks = self.part("overview")
        stats = {s["label"]: s["value"] for s in blocks[0]["items"]}
        self.assertEqual(stats, {"On": "Wi-Fi", "Signal": "-58 dBm", "Link": "866 Mbps", "Devices": "4"})
        self.assertEqual([i["id"] for i in blocks[1]["items"]], ["wifi", "local-ip", "public-ip", "router", "dns"])
        self.assertIn("-m 2.0", self.curl_calls()[0], "a page has 5 s")

    def test_the_overview_page_shows_the_last_speed_test(self):
        self.net()
        (self.box.data / "speedtest-last.json").write_text(json.dumps(network.result_of(RESULT, time.time())))
        stats = {s["label"]: s["value"] for s in self.part("overview")[0]["items"]}
        self.assertEqual(stats["Last speed test"], "↓ 200 ↑ 50.0 Mbps")


# MARK: - Devices (new)

class DevicesTests(LocalNetworkCase):
    def devices(self):
        r = self.run_ext("devices")
        self.assertItemShape(r.items)
        self.assertEqual(r.stderr, "")
        return r.items

    def test_lists_the_arp_tables_devices_router_first_then_this_mac(self):
        self.net()
        (self.box.data / "names.json").write_text(json.dumps({"00:00:5e:00:53:20": {"name": "printer", "at": 1}}))
        items = self.devices()
        self.assertEqual([i["title"] for i in items], ["192.0.2.1", "This Mac", "printer", "192.0.2.30", "Look for more devices"])
        router, me, printer, phone, look = items
        self.assertEqual(router["subtitle"], "192.0.2.1 · 00:00:5e:00:53:01 · router")
        self.assertEqual(router["actions"][0], {"type": "open", "url": "http://192.0.2.1", "title": "Open router admin page"})
        self.assertEqual(me["subtitle"], "192.0.2.10 · 00:00:5e:00:53:02")
        self.assertEqual([a["title"] for a in printer["actions"]], ["Copy IP 192.0.2.20", "Copy MAC", "Copy name"])
        self.assertEqual(phone["subtitle"], "192.0.2.30 · 02:00:5e:00:53:30 · private address")
        self.assertEqual(look["actions"], [{"type": "run", "command": "devices-scan", "title": "Look again", "stay": True}])

    def test_skips_incomplete_broadcast_multicast_and_other_interfaces(self):
        self.net()
        titles = " ".join(i["subtitle"] for i in self.devices()[:-1])
        for absent in ("192.0.2.40", "192.0.2.255", "224.0.0.251", "198.51.100.9"):
            self.assertNotIn(absent, titles)

    def test_a_table_macos_hides_says_where_to_allow_it(self):
        self.net(arp="? (192.0.2.10) at 0:0:5e:0:53:2 on en1 ifscope permanent [ethernet]\n")
        items = self.devices()
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["title"], "macOS keeps this network's devices from Pilot")
        self.assertEqual(items[0]["actions"][0]["url"], network.SETTINGS_LOCAL_NETWORK)
        (self.box.data / "scan.json").write_text(json.dumps({"status": "done", "at": 0}))  # stale: still no look
        self.assertEqual(self.devices()[0]["title"], "macOS keeps this network's devices from Pilot")
        self.assertEqual(json.loads((self.box.data / "scan.json").read_text())["at"], 0)

    def test_the_devices_page(self):
        self.net()
        blocks = self.part("devices")
        self.assertEqual({s["label"]: s["value"] for s in blocks[0]["items"]},
                         {"Devices": "4", "Named": "1", "Network": "Wi-Fi on en1"})
        self.assertEqual(blocks[1], {"type": "buttons", "actions": [{"type": "run", "command": "devices-scan", "title": "Look again"}]})
        self.assertEqual(blocks[2]["title"], "On en1")
        self.assertIsNone(self.refresh)

    def test_not_on_a_network(self):
        self.net(online=False)
        self.assertEqual(self.devices()[0]["title"], "This Mac is not on a network")

    def test_mac_and_private_address(self):
        self.assertEqual(network.mac_text("0:1a:2b:3:4:5"), "00:1a:2b:03:04:05")
        self.assertIsNone(network.mac_text("(incomplete)"))
        self.assertTrue(network.private_mac("02:00:5e:00:53:30"))
        self.assertFalse(network.private_mac("00:00:5e:00:53:30"))

    def test_the_look_wakes_one_slash_24_at_most_and_never_a_public_one(self):
        targets = network.probe_targets("192.168.4.10", "255.255.255.0")
        self.assertEqual(len(targets), 253)
        self.assertNotIn("192.168.4.10", targets)
        self.assertEqual(len(network.probe_targets("10.1.2.3", "255.255.0.0")), 253, "a /16 is cut to its /24")
        self.assertEqual(network.probe_targets("8.8.4.4", "255.255.255.0"), [])

    def test_the_look_saves_names_by_mac_from_mdns_then_the_resolver(self):
        scan = network.Scan({"paths": {"data": str(self.box.data)}})
        probed, asked = [], {}
        arp = [{"ip": "192.0.2.20", "mac": "00:00:5e:00:53:20", "interface": "en1", "own": False},
               {"ip": "192.0.2.30", "mac": "02:00:5e:00:53:30", "interface": "en1", "own": False},
               {"ip": "192.0.2.10", "mac": "00:00:5e:00:53:02", "interface": "en1", "own": True}]

        def mdns(ips):
            asked["mdns"] = list(ips)
            return {"192.0.2.20": "printer"}

        def resolver(ips):
            asked["resolver"] = list(ips)
            return {"192.0.2.30": "pocket"}

        with mock.patch.object(network, "arp_devices", return_value=arp), mock.patch.object(network.time, "sleep"):
            network.scan_work(scan, "en1", "192.0.2.10", "255.255.255.0", probe_=probed.extend, mdns=mdns, resolver=resolver)
        self.assertEqual(len(probed), 253)
        self.assertEqual(asked, {"mdns": ["192.0.2.20", "192.0.2.30"], "resolver": ["192.0.2.30"]})
        names = {mac: v["name"] for mac, v in scan.known().items()}
        self.assertEqual(names, {"00:00:5e:00:53:20": "printer", "02:00:5e:00:53:30": "pocket"})
        self.assertEqual(json.loads((self.box.data / "scan.json").read_text())["status"], "done")

    def test_a_stale_look_starts_one_detached_and_look_again_forces_one(self):
        run = {"paths": {"data": str(self.box.data)}}
        now = {"interface": "en1", "ip": "192.0.2.10", "router": "192.0.2.1", "kind": "Wi-Fi"}
        started = []
        with mock.patch.object(network, "detach", side_effect=lambda work: started.append(work)), \
                mock.patch.object(network, "subnet_mask", return_value="255.255.255.0"):
            self.assertFalse(network.start_scan(run, now), "a look ran just now")
            (self.box.data / "scan.json").write_text(json.dumps({"status": "done", "at": time.time() - 600}))
            self.assertTrue(network.start_scan(run, now))
            self.assertTrue(network.start_scan(run, now, force=True))
        self.assertEqual(len(started), 2)

    def test_mdns_question_and_answer(self):
        query = network.mdns_query("192.0.2.20", 7)
        self.assertEqual(struct.unpack(">HHHHHH", query[:12]), (7, 0, 1, 0, 0, 0))
        self.assertIn(b"\x0220\x012\x010\x03192\x07in-addr\x04arpa\x00", query)
        self.assertEqual(query[-4:], struct.pack(">HH", 12, 1))
        # A reply: the question echoed, then a PTR answer whose name points back at the question (compression).
        answer_name = b"\x07printer\x05local\x00"
        reply = (struct.pack(">HHHHHH", 7, 0x8400, 1, 1, 0, 0) + query[12:]
                 + b"\xc0\x0c" + struct.pack(">HHIH", 12, 1, 120, len(answer_name)) + answer_name)
        self.assertEqual(network.mdns_answer(reply), "printer")
        self.assertIsNone(network.mdns_answer(query), "a question is no answer")
        self.assertIsNone(network.mdns_answer(b"\x00\x01"))


# MARK: - The extension as a whole

class ManifestTests(NetworkCase):
    def test_every_old_command_is_found_by_its_own_name(self):
        shown = {c["title"]: c for c in manifest("network")["commands"] if not c.get("hidden")}
        # Pilot gives a command its extension's title as keywords (Extension.swift, ActionInfo), so "ports" found Ports'
        # Kill port; under Network the word leads its title instead.
        for title in ("Tailscale devices", "Connect Tailscale", "Disconnect Tailscale", "Ports: kill port", "SSH hosts",
                      "Speedtest", "Network overview", "Devices on the network"):
            self.assertIn(title, shown)
        self.assertEqual(manifest("network")["preferences"][0]["name"], "terminal", "SSH hosts' preference, its name kept")

    def test_a_part_the_page_lacks_is_refused(self):
        r = self.run_ext("view", context={"view": "nope"})
        self.assertEqual(r.of_type("error"), [{"type": "error", "text": "has no part nope"}])
        self.assertEqual(network.held_view({"paths": {"data": str(self.box.data)}}), "overview")
