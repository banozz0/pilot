import os
import subprocess
import sys

from harness import ExtensionTestCase

LISTENER = """
import signal, socket, sys, time
if sys.argv[1] == "stubborn":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1)
print(s.getsockname()[1], flush=True)
time.sleep(60)
"""


class PortsTests(ExtensionTestCase):
    EXTENSION = "ports"

    def listener(self, kind="plain"):
        proc = subprocess.Popen([sys.executable, "-c", LISTENER, kind], stdout=subprocess.PIPE, text=True)
        self.addCleanup(lambda: (proc.poll() is None and proc.kill(), proc.wait(), proc.stdout.close()))
        return proc, int(proc.stdout.readline())

    def row(self, items, pid, port):
        return next((i for i in items if i.get("id") == "%d-%d" % (pid, port)), None)

    def test_lists_a_listening_port_with_its_program_and_actions(self):
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
        proc, port = self.listener()
        row = self.row(self.run_ext("kill-port").items, proc.pid, port)
        r = self.run_ext("kill", context=row["actions"][0]["context"])
        self.assertEqual(r.of_type("hud")[0]["text"][:13], "Asked to quit")
        self.assertEqual(proc.wait(timeout=5), -15)

    def test_force_quit_sends_sigkill(self):
        proc, port = self.listener("stubborn")
        row = self.row(self.run_ext("kill-port").items, proc.pid, port)
        r = self.run_ext("kill", context=row["actions"][1]["context"])
        self.assertTrue(r.of_type("hud")[0]["text"].startswith("Force quit"))
        self.assertEqual(proc.wait(timeout=5), -9)

    def test_refuses_pid_one_pilot_and_a_port_no_longer_held(self):
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


class PortsPageTests(ExtensionTestCase):
    """The page does its job in place (Sven, 2026-10-31): each port a row, Quit asking first in it. lsof and ps are shims."""
    EXTENSION = "ports"

    def setUp(self):
        super().setUp()
        self.box.shim("lsof", LSOF)
        self.box.shim("ps", "echo /usr/local/bin/node")

    def test_each_port_is_a_row_whose_quits_ask_first(self):
        blocks = self.page()
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
        row = self.page()[0]["items"][0]
        r = self.run_ext("kill", context=row["inline"][0]["context"])
        self.assertEqual(r.of_type("error"), [{"type": "error", "text": "port 3000 is no longer held by pid 4242"}])

    def test_nothing_listening_says_so(self):
        self.box.shim("lsof", "exit 1")
        self.assertEqual(self.page()[0]["items"][0]["title"], "No TCP port is listening")
