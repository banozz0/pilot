#!/usr/bin/env python3
"""Pilot's lean budgets (SPEC story 142): fails when the app's size, idle RAM, idle CPU or launch time is over budget.

    Scripts/lean-check.py [size] [--app PATH]  the bundle and its main program on disk (anyone; build-app.sh runs it)
    Scripts/lean-check.py idle                 the running Pilot and its file helper, read-only (anyone)
    Scripts/lean-check.py launch [--runs 3]    quits and reopens Pilot (lane 1 only)
    Scripts/lean-check.py all                  size, then launch, then idle (lane 1 only)

Budgets: Scripts/lean-budgets.json (or --budgets FILE). Exit 1 when anything is over, 2 when a reading is missing.
Launch times run from `open` to Pilot's log line: binds the engine's "tap installed", files the file index's first answer;
run 1 is the build's first launch (as cold as it gets without `sudo purge`), the rest are warm relaunches.
Idle waits --settle seconds (default 60, 0 for a Pilot up a while), then reads RAM (footprint) and CPU over
--window seconds, so the helper's startup walk is not counted. Run it with Pilot left alone: nothing open, no menu, nothing typed;
any keyboard or mouse input inside the window (HIDIdleTime) makes the CPU lines missing, since Pilot works on every input.
Pilot's idle RAM is read only before its app window first opens: memory a page took stays counted after the window
closes (malloc keeps what it freed until the Mac runs short), so a Pilot whose window opened since launch is missing.
Idle also counts the WebKit processes serving Pilot's web widgets (ADR 0016, T25): XPC services, not Pilot's children,
found by the process macOS holds responsible for them. Until lean-budgets.json has their keys (widgetsWebIdleMB,
widgetsWebIdleCPUPercent; they change only on Sven's yes) the line is printed with the proposed budget and fails nothing.
"""
import argparse, ctypes, datetime, json, os, re, select, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MARKS = {"binds": ":engine] tap installed", "files": 'files: {"ready":true'}
WAIT = 30  # seconds a launch may take before a missing mark counts as never
MIB = 1 << 20


def du(path):
    """Bytes on disk the way du counts them, as LeanBudgetTests does."""
    if os.path.isfile(path):
        return os.lstat(path).st_blocks * 512
    return sum(os.lstat(os.path.join(d, f)).st_blocks * 512 for d, _, files in os.walk(path) for f in files)


def footprint_mb(pid):
    """phys_footprint, the number Activity Monitor calls Memory: `footprint` prints "Footprint: 27 MB"."""
    out = subprocess.run(["footprint", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"Footprint: ([\d.]+) (KB|MB|GB)", out)
    if not m:
        return None
    return float(m[1]) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[m[2]]


def cpu_seconds(pid):
    """ps's cumulative CPU time, [[dd-]hh:]mm:ss.cc, in seconds."""
    out = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    days, _, clock = out.rpartition("-")
    seconds = 0.0
    for part in clock.split(":"):
        seconds = seconds * 60 + float(part)
    return seconds + int(days or 0) * 86400


def pids():
    """Pilot's pid and its own pilot-files child (a test run's helper is someone else's child)."""
    pilot = subprocess.run(["pgrep", "-x", "Pilot"], capture_output=True, text=True).stdout.split()
    if not pilot:
        return None, None
    helper = subprocess.run(["pgrep", "-P", pilot[0], "-x", "pilot-files"], capture_output=True, text=True).stdout.split()
    return int(pilot[0]), int(helper[0]) if helper else None


# The widgets' WebKit budget proposed from T15's numbers (one page: WebContent 12, GPU 12, Networking 4.7 MB; each
# further page 13 to 22 MB; a shown static page 0.0 % CPU): two pages' worth, and Pilot's own idle CPU line.
PROPOSED_WEB = {"widgetsWebIdleMB": 60, "widgetsWebIdleCPUPercent": 1.5}


def webkit(pilot):
    """The WebKit processes macOS holds Pilot responsible for (WebContent, GPU, Networking), as Activity Monitor groups
    them: responsibility_get_pid_responsible_for_pid, in libSystem; None when it is not there, so the line says MISSING
    rather than reading as no page open."""
    try:
        responsible = ctypes.CDLL(None).responsibility_get_pid_responsible_for_pid
    except AttributeError:
        return None
    responsible.restype, responsible.argtypes = ctypes.c_int, [ctypes.c_int]
    out = subprocess.run(["ps", "-A", "-o", "pid=,comm="], capture_output=True, text=True).stdout
    found = []
    for line in out.splitlines():
        pid, _, comm = line.strip().partition(" ")
        if "com.apple.WebKit." in comm and pid.isdigit() and responsible(int(pid)) == pilot:
            found.append(int(pid))
    return found


def input_idle_seconds():
    """Seconds since the last keyboard, mouse or trackpad input (IOHIDSystem's HIDIdleTime), None when unread."""
    out = subprocess.run(["ioreg", "-c", "IOHIDSystem", "-d", "4"], capture_output=True, text=True).stdout
    m = re.search(r'"HIDIdleTime" = (\d+)', out)
    return int(m[1]) / 1e9 if m else None


def window_opened(pid):
    """When Pilot's app window first opened since this launch ("2026-10-10 19:04:52"), None when it has not."""
    started = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not started:
        return None
    since = datetime.datetime.strptime(" ".join(started.split()), "%a %b %d %H:%M:%S %Y").strftime("%Y-%m-%d %H:%M:%S")
    out = subprocess.run(["/usr/bin/log", "show", "--style", "compact", "--start", since, "--predicate",
                          f'processID == {pid} AND subsystem == "dev.banozz.pilot" AND eventMessage BEGINSWITH "app window open on"'],
                         capture_output=True, text=True).stdout
    return next((line[:19] for line in out.splitlines() if "app window open on" in line), None)


class Report:
    code = 0  # 1 when anything is over budget, else 2 when a reading is missing

    def missing(self, name, why="no reading"):
        self.code = self.code or 2
        print(f"MISSING {name}: {why}")

    def check(self, name, value, budget, unit, proposed=False):
        """`proposed`: a reading with no budget in lean-budgets.json yet, shown with the one proposed, never failing."""
        if proposed:
            shown = "no reading" if value is None else f"{value:.2f} {unit}"
            return print(f"info {name}: {shown} (proposed budget {budget:g} {unit}, not in lean-budgets.json)")
        if value is None:
            return self.missing(name)
        ok = value <= budget
        if not ok:
            self.code = 1
        print(f"{'ok  ' if ok else 'OVER'} {name}: {value:.2f} {unit} (budget {budget:g} {unit})")


def size(budgets, report, app):
    report.check("app on disk", du(app) / MIB if os.path.isdir(app) else None, budgets["appMB"], "MB")
    binary = os.path.join(app, "Contents", "MacOS", "Pilot")
    report.check("main program", du(binary) / MIB if os.path.isfile(binary) else None, budgets["binaryMB"], "MB")


def idle(budgets, report, settle, window):
    time.sleep(settle)
    pilot, helper = pids()
    procs = []
    for name, key, pid in (("Pilot", "pilot", pilot), ("file helper", "helper", helper)):
        if pid:
            procs.append((name, key, pid))
        else:
            report.missing(f"{name} running")
    found = webkit(pilot) if pilot else []
    web = found or []
    before = {pid: cpu_seconds(pid) for pid in [p for _, _, p in procs] + web}
    time.sleep(window)

    # Input inside the window is Pilot's work for that input (the mouse tap, AX focus and move events, the tiler, the
    # top bar), not idle: the CPU lines are missing then, never a number (1.0.3: 5.75 % read while the Mac was in use).
    quiet = input_idle_seconds()
    busy = quiet is None or quiet < window

    def cpu_percent(pid):
        after = cpu_seconds(pid)
        return None if busy or after is None or before.get(pid) is None else (after - before[pid]) / window * 100

    def cpu_check(name, used, budget, proposed=False):
        if busy:
            why = ("no input idle time from ioreg, so input cannot be ruled out" if quiet is None else
                   f"keyboard or mouse input {quiet:.0f} s before the end of the window; rerun with the Mac left alone")
            return print(f"info {name}: no reading, {why}") if proposed else report.missing(name, why)
        report.check(name, used, budget, "%", proposed=proposed)

    opened = window_opened(pilot) if pilot else None
    for name, key, pid in procs:
        used = cpu_percent(pid)
        if pid == pilot and opened:
            report.missing(f"{name} idle RAM", f"the app window opened at {opened}, so relaunch Pilot (lane 1: `all`)")
        else:
            report.check(f"{name} idle RAM", footprint_mb(pid), budgets[f"{key}IdleMB"], "MB")
        cpu_check(f"{name} idle CPU over {window} s", used, budgets[f"{key}IdleCPUPercent"])
    # The widgets' pages, summed: none open reads 0 MB and 0 %.
    rams, cpus = [footprint_mb(pid) for pid in web], [cpu_percent(pid) for pid in web]
    ram, cpu = (None if None in rams else sum(rams)), (None if None in cpus else sum(cpus))
    if found is None:
        return report.missing("widgets' WebKit", "macOS's responsible-process lookup is not there, so its processes cannot be found")
    name = f"widgets' WebKit ({len(web)} process{'' if len(web) == 1 else 'es'})"
    ram_key, cpu_key = "widgetsWebIdleMB", "widgetsWebIdleCPUPercent"
    report.check(f"{name} idle RAM", ram, budgets.get(ram_key, PROPOSED_WEB[ram_key]), "MB", proposed=ram_key not in budgets)
    cpu_check(f"{name} idle CPU over {window} s", cpu, budgets.get(cpu_key, PROPOSED_WEB[cpu_key]), proposed=cpu_key not in budgets)


def quit_pilot():
    subprocess.run(["pkill", "-x", "Pilot"], check=False)
    for _ in range(50):
        if subprocess.run(["pgrep", "-x", "Pilot"], capture_output=True).returncode:
            return
        time.sleep(0.1)
    sys.exit("Pilot did not quit")


def stamp(line):
    # compact style: "2026-10-08 01:37:13.816 Df Pilot[…] …", local time
    return datetime.datetime.strptime(line[:23], "%Y-%m-%d %H:%M:%S.%f").timestamp()


def launch_once(app):
    """Seconds from `open` to each mark, None for a mark that never came."""
    quit_pilot()
    stream = subprocess.Popen(
        ["/usr/bin/log", "stream", "--style", "compact", "--predicate",
         'process == "Pilot" AND subsystem == "dev.banozz.pilot"'],
        stdout=subprocess.PIPE, bufsize=0)  # unbuffered, so select sees every line still unread
    stream.stdout.readline()  # the "Filtering the log data…" header: the stream is live
    start = time.time()
    subprocess.run(["open", "-n", app], check=True)
    seen, deadline = {}, start + WAIT
    # Wait on the pipe, not a poll loop, so the timer adds no wakeups to the launch it times.
    while len(seen) < len(MARKS) and select.select([stream.stdout], [], [], max(0, deadline - time.time()))[0]:
        line = stream.stdout.readline().decode(errors="replace")
        for name, mark in MARKS.items():
            if name not in seen and mark in line:
                seen[name] = stamp(line) - start
    stream.terminate()
    return seen


def launch(budgets, report, app, runs):
    for i in range(runs):
        if i:
            time.sleep(3)  # let the last run settle before this one quits it
        seen = launch_once(app)
        kind = "cold" if i == 0 else "warm"
        report.check(f"{kind} launch to binds", seen.get("binds"), budgets["launchBindsSeconds"], "s")
        report.check(f"{kind} launch to file search", seen.get("files"), budgets["launchFilesSeconds"], "s")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("check", nargs="?", choices=["size", "idle", "launch", "all"], default="size")
    p.add_argument("--app", default=os.path.join(ROOT, "build", "Pilot.app"))
    p.add_argument("--budgets", default=os.path.join(ROOT, "Scripts", "lean-budgets.json"))
    p.add_argument("--runs", type=int, default=3)
    p.add_argument("--settle", type=int, default=60)
    p.add_argument("--window", type=int, default=60)
    a = p.parse_args()
    with open(a.budgets) as f:
        budgets = json.load(f)
    report = Report()
    if a.check in ("all", "size"):
        size(budgets, report, a.app)
    if a.check in ("all", "launch"):
        launch(budgets, report, a.app, a.runs)
    if a.check in ("all", "idle"):
        idle(budgets, report, a.settle, a.window)
    sys.exit(report.code)


if __name__ == "__main__":
    main()
