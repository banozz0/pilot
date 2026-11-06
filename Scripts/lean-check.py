#!/usr/bin/env python3
"""Pilot's lean budgets (SPEC story 142): fails when the app's size, idle RAM, idle CPU or launch time is over budget.

    Scripts/lean-check.py [size] [--app PATH]  the bundle and its main program on disk (anyone; build-app.sh runs it)
    Scripts/lean-check.py idle                 the running Pilot and its file helper, read-only (anyone)
    Scripts/lean-check.py launch [--runs 3]    quits and reopens Pilot (lane 1 only)
    Scripts/lean-check.py menu [--days 7]      Hyper+Space to the menu's first frame, from Pilot's log (anyone)
    Scripts/lean-check.py all                  size, then launch, then idle, then menu (lane 1 only)

Budgets: Scripts/lean-budgets.json (or --budgets FILE). Exit 1 when anything is over, 2 when a reading is missing.
Launch times run from `open` to Pilot's log line "tap installed" (binds); run 1 is the build's first launch (as cold as it
gets without `sudo purge`), the rest are warm relaunches. The file helper starts when Hyper+Space first opens, not at
launch (60a2cdc4), so file search is timed from a first search instead: once binds are up, `launch` runs the bundle's
`pilot files` (a read-only search, which starts the helper as a menu open does) and times it to the helper's ready line.
Idle waits --settle seconds (default 60, 0 for a Pilot up a while), then reads RAM (footprint) and CPU over
--window seconds, so the helper's startup walk is not counted. The file helper is read only while it runs (it stops
10 min after the last file search); when it is not running, idle prints when it last started and how long it took to be
ready, from Pilot's log, and that fails nothing. Run it with Pilot left alone: nothing open, no menu, nothing typed;
any keyboard or mouse input inside the window (HIDIdleTime) makes the CPU lines missing, since Pilot works on every input.
Pilot's idle RAM is read only before its app window first opens: memory a page took stays counted after the window
closes (malloc keeps what it freed until the Mac runs short), so a Pilot whose window opened since launch is missing.
That footprint is the "after use" line instead (Sven Q888): read once the window has opened and closed since launch,
report only, no budget; it says why when it cannot read (no open since launch, or a window still open).
Idle also counts the WebKit processes serving Pilot's web widgets (ADR 0016, T25): XPC services, not Pilot's children,
found by the process macOS holds responsible for them. Until lean-budgets.json has their keys (widgetsWebIdleMB,
widgetsWebIdleCPUPercent; they change only on Sven's yes) the line is printed with the proposed budget and fails nothing.
Ratchet (story 142; Sven Q883, Q893): a budgeted reading at least ratchetMarginPercent (lean-budgets.json; canon default
10) under its budget on two builds in a row lowers that budget to the higher of the two readings plus the margin, written
into lean-budgets.json and printed with its commit line. It never raises one: a rise is Sven's yes. A build is the bundle's
CFBundleVersion (the running Pilot's for idle), so rerunning one build counts once; the last reading per budget per build
is kept in --readings (default build/lean-readings.json). Launch timings count only with --runs 5 or more, as their worst run.
Menu (spec pilot-1.1 T74, Sven Q884): Pilot logs each Hyper+Space press as "menu open: <ms> ms from key down to first
frame, build <n>", from the key-down's own timestamp to the panel's first visible frame, in Sven's own use (agents never
press it). menu reads the last --days of those lines, across relaunches, and prints the p75 (nearest rank) and the count
against Apple's lines: under 100 ms feels instant, over 250 ms is a hang. Under 20 presses it reports only (MISSING once
menuOpenMs is set). From 20, a
missing menuOpenMs is set to that p75 plus ratchetMarginPercent, never above the 100 ms line (canon: a timing budget
never sits above its line), and written into lean-budgets.json; the newest build's p75 is checked against it, and feeds
the ratchet once that build has 20 presses.
"""
import argparse, ctypes, datetime, json, math, os, plistlib, re, select, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINDS = ":engine] tap installed"
FILES_READY = 'files: {"ready":true'
SEARCH = "lean-check"  # a search of at least the menu's minimum length; what it finds is never read
WAIT = 30  # seconds a launch may take before a missing mark counts as never
MIB = 1 << 20
MENU_OPEN = re.compile(r"menu open: (\d+) ms from key down to first frame, build (\S+)")
INSTANT_MS, HANG_MS = 100, 250  # Apple's lines (research note: App performance budgets [9][10])
MENU_PRESSES = 20  # presses before menuOpenMs is set or a build's p75 counts


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


def pilot_since(pid):
    """When Pilot `pid` started, as `log show --start` takes it, None when it is gone."""
    started = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not started:
        return None
    return datetime.datetime.strptime(" ".join(started.split()), "%a %b %d %H:%M:%S %Y").strftime("%Y-%m-%d %H:%M:%S")


def helper_last_ready(pid):
    """The file helper's last start since Pilot `pid` launched, from Pilot's log: (when it started, seconds from its
    start to its ready line, the helper's own read in ms), or None when it has not started since launch."""
    since = pilot_since(pid)
    if not since:
        return None
    out = subprocess.run(["/usr/bin/log", "show", "--style", "compact", "--start", since, "--predicate",
                          f'processID == {pid} AND subsystem == "dev.banozz.pilot" AND eventMessage BEGINSWITH "files: "'],
                         capture_output=True, text=True).stdout
    started, last = None, None
    for line in out.splitlines():
        if "files: helper started" in line:
            started = line
        elif FILES_READY in line and started:
            m = re.search(r'"ms":(\d+)', line)
            last = (started[:19], stamp(line) - stamp(started), int(m[1]) if m else None)
            started = None
    return last


def window_log(pid):
    """Pilot's window lines since this launch, oldest first: (when, "open"), or (when, "closed") once its last window
    closed ("window closed, 0 other windows open")."""
    since = pilot_since(pid)
    if not since:
        return []
    out = subprocess.run(["/usr/bin/log", "show", "--style", "compact", "--start", since, "--predicate",
                          f'processID == {pid} AND subsystem == "dev.banozz.pilot" AND '
                          '(eventMessage BEGINSWITH "app window open on" OR eventMessage BEGINSWITH "window closed, 0 other")'],
                         capture_output=True, text=True).stdout
    return [(line[:19], "closed" if "window closed, " in line else "open") for line in out.splitlines() if "window" in line]


def build_of(app):
    """The bundle's build number (CFBundleVersion), None when unread."""
    try:
        with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
            return plistlib.load(f).get("CFBundleVersion")
    except OSError:
        return None


def running_app(pid):
    """The .app bundle Pilot `pid` runs from, None when it is gone."""
    exe = subprocess.run(["ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return exe.split("/Contents/MacOS/")[0] if "/Contents/MacOS/" in exe else None


class Report:
    code = 0  # 1 when anything is over budget, else 2 when a reading is missing

    def __init__(self, budgets):
        self.budgets = budgets
        self.build = None  # the build the readings come from; None keeps them out of the ratchet
        self.readings = {}  # budget key -> (build, the worst reading this run), what the ratchet weighs

    def missing(self, name, why="no reading"):
        self.code = self.code or 2
        print(f"MISSING {name}: {why}")

    def check(self, name, value, key, unit):
        """`value` against budget `key`; a key with no budget in lean-budgets.json yet is shown with the one proposed
        (PROPOSED_WEB), never failing."""
        budget = self.budgets.get(key, PROPOSED_WEB.get(key))
        if key not in self.budgets:
            shown = "no reading" if value is None else f"{value:.2f} {unit}"
            return print(f"info {name}: {shown} (proposed budget {budget:g} {unit}, not in lean-budgets.json)")
        if value is None:
            return self.missing(name)
        if self.build:
            worst = max(value, self.readings[key][1]) if key in self.readings else value
            self.readings[key] = (self.build, worst)
        ok = value <= budget
        if not ok:
            self.code = 1
        print(f"{'ok  ' if ok else 'OVER'} {name}: {value:.2f} {unit} (budget {budget:g} {unit})")


def write_budgets(path, budgets):
    with open(path, "w") as f:
        json.dump(budgets, f, indent=2)
        f.write("\n")


def ratchet(budgets, report, path, readings_path):
    """Lowers each budget beaten by the margin on two builds in a row (module doc); never raises one."""
    margin = budgets.get("ratchetMarginPercent", 10) / 100
    try:
        with open(readings_path) as f:
            kept = json.load(f)
    except (OSError, ValueError):
        kept = {}
    if not report.readings:
        return
    lowered = {}
    for key, (build, value) in report.readings.items():
        last = [r for r in kept.get(key, []) if r["build"] != build][-1:]
        kept[key] = last + [{"build": build, "value": value}]
        old = budgets[key]
        if len(kept[key]) < 2 or any(r["value"] > old * (1 - margin) for r in kept[key]):
            continue
        worst = max(r["value"] for r in kept[key])
        new = math.ceil(worst * (1 + margin) * 10) / 10
        new = int(new) if new == int(new) else new
        if new < old:
            budgets[key] = lowered[key] = new
            builds = ", ".join(f"{r['value']:.2f} (build {r['build']})" for r in kept[key])
            print(f"ratchet {key}: budget {old:g} -> {new:g}, readings {builds}; commit as "
                  f"\"perf: {key} budget {old:g} → {new:g}\" with both readings")
    os.makedirs(os.path.dirname(os.path.abspath(readings_path)), exist_ok=True)
    with open(readings_path, "w") as f:
        json.dump(kept, f, indent=2)
    if lowered:
        write_budgets(path, budgets)
    else:
        print(f"ratchet: no budget lowered (one needs two builds in a row {margin:.0%} under it)")


def size(report, app):
    report.build = build_of(app)
    report.check("app on disk", du(app) / MIB if os.path.isdir(app) else None, "appMB", "MB")
    binary = os.path.join(app, "Contents", "MacOS", "Pilot")
    report.check("main program", du(binary) / MIB if os.path.isfile(binary) else None, "binaryMB", "MB")


def idle(report, settle, window):
    time.sleep(settle)
    pilot, helper = pids()
    procs = []
    if pilot:
        procs.append(("Pilot", "pilot", pilot))
    else:
        report.missing("Pilot running")
    if helper:
        procs.append(("file helper", "helper", helper))
    elif pilot:
        # Not running is the file helper at rest: it starts on Hyper+Space and stops 10 min after the last file search.
        last = helper_last_ready(pilot)
        seen = ("it has not started since Pilot launched" if last is None else
                f"last started {last[0]}, ready {last[1]:.2f} s later" + (f" (its own read {last[2]} ms)" if last[2] is not None else ""))
        print(f"info file helper: not running, it starts when Hyper+Space opens; {seen}")
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

    def cpu_check(name, used, key):
        if busy:
            why = ("no input idle time from ioreg, so input cannot be ruled out" if quiet is None else
                   f"keyboard or mouse input {quiet:.0f} s before the end of the window; rerun with the Mac left alone")
            return print(f"info {name}: no reading, {why}") if key not in report.budgets else report.missing(name, why)
        report.check(name, used, key, "%")

    windows = window_log(pilot) if pilot else []
    opened = next((when for when, kind in windows if kind == "open"), None)
    report.build = build_of(running_app(pilot)) if pilot else None
    for name, key, pid in procs:
        used = cpu_percent(pid)
        if pid == pilot and opened:
            report.missing(f"{name} idle RAM", f"the app window opened at {opened}, so relaunch Pilot (lane 1: `all`)")
        else:
            report.check(f"{name} idle RAM", footprint_mb(pid), f"{key}IdleMB", "MB")
        cpu_check(f"{name} idle CPU over {window} s", used, f"{key}IdleCPUPercent")
    if pilot:
        # After use (Sven Q888): report only, never a budget or a ratchet.
        if not opened:
            print("info Pilot after-use RAM: no reading, the app window has not opened since Pilot launched")
        elif windows[-1][1] != "closed":
            print(f"info Pilot after-use RAM: no reading, a window opened at {windows[-1][0]} is still open")
        else:
            ram = footprint_mb(pilot)
            print(f"info Pilot after-use RAM: {'no reading from footprint' if ram is None else f'{ram:.2f} MB'} "
                  f"(window closed {windows[-1][0]}; report only, no budget)")
    # The widgets' pages, summed: none open reads 0 MB and 0 %.
    rams, cpus = [footprint_mb(pid) for pid in web], [cpu_percent(pid) for pid in web]
    ram, cpu = (None if None in rams else sum(rams)), (None if None in cpus else sum(cpus))
    if found is None:
        return report.missing("widgets' WebKit", "macOS's responsible-process lookup is not there, so its processes cannot be found")
    name = f"widgets' WebKit ({len(web)} process{'' if len(web) == 1 else 'es'})"
    report.check(f"{name} idle RAM", ram, "widgetsWebIdleMB", "MB")
    cpu_check(f"{name} idle CPU over {window} s", cpu, "widgetsWebIdleCPUPercent")


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
    """Seconds from `open` to binds, and from a first file search to the helper's ready line; a mark that never came is
    left out."""
    quit_pilot()
    stream = subprocess.Popen(
        ["/usr/bin/log", "stream", "--style", "compact", "--predicate",
         'process == "Pilot" AND subsystem == "dev.banozz.pilot"'],
        stdout=subprocess.PIPE, bufsize=0)  # unbuffered, so select sees every line still unread
    stream.stdout.readline()  # the "Filtering the log data…" header: the stream is live
    start = time.time()
    subprocess.run(["open", "-n", app], check=True)
    seen = {}

    def wait(mark, since):
        """Seconds from `since` to `mark`'s line, None when it does not come in WAIT. Waits on the pipe, not a poll
        loop, so the timer adds no wakeups to what it times."""
        deadline = since + WAIT
        while select.select([stream.stdout], [], [], max(0, deadline - time.time()))[0]:
            line = stream.stdout.readline().decode(errors="replace")
            if mark in line:
                return stamp(line) - since
        return None

    seen["binds"] = wait(BINDS, start)
    if seen["binds"] is not None:
        # The relaunched Pilot has no helper until a search or a menu open starts one, so this is its cold start.
        # The tap arms before Pilot's command socket listens, so the first asks can be refused: ask again until one
        # is taken, and time from the ask that was. The search waits for the helper, so it runs beside the stream.
        cli, deadline = os.path.join(app, "Contents", "Helpers", "pilot"), time.time() + WAIT
        while time.time() < deadline:
            asked = time.time()
            search = subprocess.Popen([cli, "files", SEARCH], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                search.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                break  # taken: it is waiting on the helper
            if search.returncode == 0:
                break
            seen["files why"] = search.stderr.read().decode(errors="replace").strip()[:120]
            time.sleep(0.2)
        seen["files"] = wait(FILES_READY, asked)
        try:
            search.wait(timeout=WAIT)
        except subprocess.TimeoutExpired:
            search.kill()
    stream.terminate()
    return {name: value for name, value in seen.items() if value is not None}


def launch(report, app, runs):
    report.build = build_of(app) if runs >= 5 else None  # the ratchet weighs a timing only from 5 runs or more (canon)
    for i in range(runs):
        if i:
            time.sleep(3)  # let the last run settle before this one quits it
        seen = launch_once(app)
        kind = "cold" if i == 0 else "warm"
        report.check(f"{kind} launch to binds", seen.get("binds"), "launchBindsSeconds", "s")
        name = f"{kind} launch, first file search to ready"
        if seen.get("files") is None and seen.get("files why"):
            report.missing(name, f"pilot files was refused: {seen['files why']}")
        else:
            report.check(name, seen.get("files"), "launchFilesSeconds", "s")


def menu_presses(text):
    """The menu timings in `log show` compact lines, oldest first: (when, ms, build)."""
    return [(line[:19], int(m[1]), m[2]) for line in text.splitlines() if (m := MENU_OPEN.search(line))]


def p75(values):
    """Nearest rank, as Core Web Vitals reads it: the time 3 presses in 4 are at or under."""
    ordered = sorted(values)
    return ordered[math.ceil(0.75 * len(ordered)) - 1]


def menu(report, budgets_path, days):
    name = "Hyper+Space to first frame"
    out = subprocess.run(["/usr/bin/log", "show", "--style", "compact", "--last", f"{days}d", "--predicate",
                          'process == "Pilot" AND subsystem == "dev.banozz.pilot" AND eventMessage BEGINSWITH "menu open: "'],
                         capture_output=True, text=True).stdout
    presses = menu_presses(out)
    # Report only until menuOpenMs is set; after that a missing reading is reported missing, never passed (canon).
    short = (lambda why: report.missing(name, why)) if "menuOpenMs" in report.budgets else (lambda why: print(f"info {name}: {why}"))
    if not presses:
        return short(f"no presses logged in the last {days} days (Pilot logs each press from spec pilot-1.1 T74 on)")
    ms = [m for _, m, _ in presses]
    overall = p75(ms)
    print(f"info {name}: p75 {overall} ms over {len(ms)} presses since {presses[0][0]}; {sum(m < INSTANT_MS for m in ms)} "
          f"under {INSTANT_MS} ms (Apple: instant), {sum(m > HANG_MS for m in ms)} over {HANG_MS} ms (a hang)")
    if len(ms) < MENU_PRESSES:
        return short(f"{len(ms)} presses, {MENU_PRESSES} needed for a p75 against menuOpenMs")
    if "menuOpenMs" not in report.budgets:
        margin = report.budgets.get("ratchetMarginPercent", 10) / 100
        report.budgets["menuOpenMs"] = min(math.ceil(overall * (1 + margin)), INSTANT_MS)
        write_budgets(budgets_path, report.budgets)
        print(f"budget menuOpenMs set to {report.budgets['menuOpenMs']} ms: p75 {overall} ms over {len(ms)} presses plus "
              f"{margin:.0%}, at most {INSTANT_MS}; commit as \"perf: menuOpenMs budget {report.budgets['menuOpenMs']}\"")
    build = presses[-1][2]
    mine = [m for _, m, b in presses if b == build]
    report.build = build if len(mine) >= MENU_PRESSES else None  # the ratchet weighs a build's p75 from 20 presses
    report.check(f"{name}, p75 of build {build}'s {len(mine)} presses", p75(mine), "menuOpenMs", "ms")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("check", nargs="?", choices=["size", "idle", "launch", "menu", "all"], default="size")
    p.add_argument("--app", default=os.path.join(ROOT, "build", "Pilot.app"))
    p.add_argument("--budgets", default=os.path.join(ROOT, "Scripts", "lean-budgets.json"))
    p.add_argument("--runs", type=int, default=3)
    p.add_argument("--settle", type=int, default=60)
    p.add_argument("--window", type=int, default=60)
    p.add_argument("--days", type=int, default=7)
    p.add_argument("--readings", default=os.path.join(ROOT, "build", "lean-readings.json"))
    a = p.parse_args()
    with open(a.budgets) as f:
        budgets = json.load(f)
    report = Report(budgets)
    if a.check in ("all", "size"):
        size(report, a.app)
    if a.check in ("all", "launch"):
        launch(report, a.app, a.runs)
    if a.check in ("all", "idle"):
        idle(report, a.settle, a.window)
    if a.check in ("all", "menu"):
        menu(report, a.budgets, a.days)
    ratchet(budgets, report, a.budgets, a.readings)
    sys.exit(report.code)


if __name__ == "__main__":
    main()
