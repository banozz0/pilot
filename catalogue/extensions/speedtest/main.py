#!/usr/bin/env python3
"""Speedtest for Pilot: macOS's own /usr/bin/networkQuality, against Apple's servers, never Ookla's CLI or a download.

A test takes about 30 s, longer than Pilot gives any command, so Run speed test starts it detached (a double fork into a
new session, outside the process tree Pilot stops) and opens Speedtest's page. The worker runs networkQuality on a
pseudo-terminal, the only place it prints its readings as it goes ("Downlink: capacity … Mbps, responsiveness … RPM … -
Uplink: …", redrawn several times a second), writes them to paths.data/job.json, and takes the final numbers from the
JSON file `-c<path>` writes. The page asks again every 2 s while a test runs (`refresh`, ADR 0010 Surfaces v2), so the
readings count up there; Hyper+Space's detail shows them as they stand when it opens. paths.data/last.json keeps the last
result, shown by the detail and the page until the next test.

networkQuality's live and summary "Mbps" are 2^20 bits a second and its JSON's throughput bits a second, so the live
readings are scaled by 1.048576 to match the result. It gives download and upload capacity, idle latency (over
TCP/TLS/HTTP, not ICMP) and responsiveness under load; it has no packet loss and no jitter, so neither is shown.
Python 3.9 stdlib only, as macOS's /usr/bin/python3.
"""
import json
import os
import pty
import re
import select
import shutil
import signal
import subprocess
import sys
import time

TOOL = "networkQuality"
MEBI = 1.048576  # networkQuality's printed Mbps are 2^20 bits/s; its JSON's are bits/s
LIMIT = 120  # a test still running after this long is stopped
PAGE = "pilot://open?tab=page&extension=speedtest"
READING = re.compile(r"Downlink: capacity ([\d.]+) Mbps, responsiveness (\d+) RPM \(([^,]*), (\d+) flows?\)"
                     r" - Uplink: capacity ([\d.]+) Mbps, responsiveness (\d+) RPM \(([^,]*), (\d+) flows?\)")
ESCAPE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
    sys.stdout.flush()


# MARK: Files

def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            value = json.load(f)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def write_json(path, value):
    """Whole or not at all: a reader never sees half a file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temp = "%s.%d.tmp" % (path, os.getpid())
    with open(temp, "w", encoding="utf-8") as f:
        json.dump(value, f, ensure_ascii=False)
    os.replace(temp, path)


class Paths:
    def __init__(self, run):
        paths = run.get("paths") or {}
        self.data = paths.get("data") or os.path.expanduser("~/.cache/pilot-speedtest")
        self.cache = paths.get("cache") or self.data
        self.job = os.path.join(self.data, "job.json")
        self.last = os.path.join(self.data, "last.json")
        self.out = os.path.join(self.cache, "result.json")


def tool():
    """networkQuality on PATH (Pilot's ends with the system's), else /usr/bin's; None on a Mac without it."""
    return shutil.which(TOOL, path=os.environ.get("PATH", "") + os.pathsep + "/usr/bin")


# MARK: Words

def mbps(value):
    """A speed in Mbps as people read it: 847, 69.9, 4.21; a dash for none."""
    if value is None:
        return "–"
    return "%.0f" % value if value >= 100 else "%.1f" % value if value >= 10 else "%.2f" % value


def rpm_words(rpm):
    """Responsiveness as networkQuality's summary says it: its RPM and the milliseconds a round trip takes under load."""
    if not rpm:
        return "–"
    return "%d RPM · %.0f ms" % (round(rpm), 60000.0 / rpm)


def rating(rpm):
    """networkQuality's own words for a responsiveness: Low under 300 RPM, Medium under 1000, else High."""
    if not rpm:
        return None
    return "Low" if rpm < 300 else "Medium" if rpm < 1000 else "High"


def tone(rpm):
    return {"Low": "alert", "Medium": "warn", "High": "fine"}.get(rating(rpm))


def when(at):
    return time.strftime("%-d %b %H:%M", time.localtime(at)) if at else "–"


def summary(result):
    """The result as one line to paste."""
    return ("Download %s Mbps · Upload %s Mbps · Latency %s ms · Responsiveness down %s, up %s · %s · %s"
            % (mbps(result.get("download")), mbps(result.get("upload")), "%.0f" % result["latency"] if result.get("latency")
               else "–", rpm_words(result.get("download_rpm")), rpm_words(result.get("upload_rpm")),
               result.get("server") or "Apple", when(result.get("at"))))


# MARK: The test

def detach(work):
    """Runs `work()` in a grandchild in its own session, its stdio on /dev/null, so Pilot's answer ends now and its stop
    of this command's process tree never reaches it. Returns in the caller once the grandchild is on its own."""
    sys.stdout.flush()
    first = os.fork()
    if first:
        os.waitpid(first, 0)
        return
    os.setsid()
    if os.fork():
        os._exit(0)
    null = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(null, fd)
    code = 0
    try:
        work()
    except Exception:  # nowhere to say it: the job file says what it could
        code = 1
    os._exit(code)


def alive(job):
    """Whether the job's worker is still this extension's process (a pid reused since is not)."""
    pid = job.get("pid")
    if job.get("status") != "running" or not isinstance(pid, int):
        return False
    try:
        os.kill(pid, 0)
        command = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True, timeout=1).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return os.path.join(os.path.basename(os.path.dirname(os.path.abspath(__file__))), "main.py") in command


def reading(line):
    """One live line as numbers: each direction's Mbps (as the JSON counts them), RPM and bytes so far; None otherwise."""
    found = READING.search(line)
    if not found:
        return None
    down, down_rpm, down_bytes, _, up, up_rpm, up_bytes, _ = found.groups()
    return {"download": float(down) * MEBI, "download_rpm": int(down_rpm), "download_moved": down_bytes,
            "upload": float(up) * MEBI, "upload_rpm": int(up_rpm), "upload_moved": up_bytes,
            "phase": "upload" if float(up) > 0 or not up_bytes.startswith("0 ") else "download"}


def result_of(found, at):
    """The JSON networkQuality wrote, in the extension's words; None when it holds no throughput."""
    if not isinstance(found.get("dl_throughput"), (int, float)) and not isinstance(found.get("ul_throughput"), (int, float)):
        return None
    def number(key, scale=1.0):
        value = found.get(key)
        return value / scale if isinstance(value, (int, float)) else None
    return {"at": at, "download": number("dl_throughput", 1e6), "upload": number("ul_throughput", 1e6),
            "latency": number("base_rtt"), "download_rpm": number("dl_responsiveness"),
            "upload_rpm": number("ul_responsiveness"), "server": found.get("test_endpoint"),
            "interface": found.get("interface_name"), "took": duration(found)}


def duration(found):
    try:
        start = time.mktime(time.strptime(found["start_date"].split(".")[0], "%Y-%m-%d %H:%M:%S"))
        end = time.mktime(time.strptime(found["end_date"].split(".")[0], "%Y-%m-%d %H:%M:%S"))
        return max(0, end - start)
    except (KeyError, ValueError, AttributeError, TypeError):
        return None


def test(paths, job):
    """The worker: networkQuality on a pty, its readings into the job file as they come, the result into last.json."""
    job.update(pid=os.getpid(), status="running", started=time.time(), phase="connecting")
    write_json(paths.job, job)
    if os.path.exists(paths.out):
        os.remove(paths.out)
    os.makedirs(os.path.dirname(paths.out), exist_ok=True)
    # The flags of the run that showed live lines on a tty (-v: its readings; -c<path>: the JSON, attached).
    main_fd, child_fd = pty.openpty()
    process = subprocess.Popen([job["tool"], "-s", "-v", "-c" + paths.out], stdin=subprocess.DEVNULL, stdout=child_fd,
                               stderr=child_fd, start_new_session=True)
    os.close(child_fd)

    def stop(*_):
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except OSError:
            pass
        job.update(status="stopped", pid=None)
        write_json(paths.job, job)
        os._exit(0)

    signal.signal(signal.SIGTERM, stop)
    buffer, written, deadline = "", 0.0, time.time() + LIMIT
    while time.time() < deadline:
        ready, _, _ = select.select([main_fd], [], [], 1.0)
        if not ready:
            if process.poll() is not None:
                break
            continue
        try:
            chunk = os.read(main_fd, 4096)
        except OSError:  # the pty's end: networkQuality has exited
            break
        if not chunk:
            break
        buffer += ESCAPE.sub("", chunk.decode("utf-8", "replace"))
        parts = re.split(r"[\r\n]", buffer)
        buffer = parts.pop()
        for part in reversed(parts):
            now = reading(part)
            if now:
                job.update(now)
                break
        if time.time() - written > 0.5:
            write_json(paths.job, job)
            written = time.time()
    else:
        stop()
    os.close(main_fd)
    process.wait()
    result = result_of(read_json(paths.out), time.time())
    if result:
        write_json(paths.last, result)
        job.update(status="done", pid=None)
    else:
        job.update(status="failed", pid=None, error="networkQuality stopped (code %s) with no result" % process.returncode)
    write_json(paths.job, job)


# MARK: Views

def run_action(command, title, **fields):
    action = {"type": "run", "command": command, "title": title}
    action.update(fields)
    return action


def copy_action(result):
    return {"type": "copy", "text": summary(result), "title": "Copy result", "key": "cmd+shift+c"}


def facts(result):
    """The rest of a result, as label and value."""
    return [("Latency", "%.0f ms" % result["latency"] if result.get("latency") else "–"),
            ("Download responsiveness", rpm_words(result.get("download_rpm"))),
            ("Upload responsiveness", rpm_words(result.get("upload_rpm"))),
            ("Server", result.get("server") or "–"),
            ("Interface", result.get("interface") or "–"),
            ("Tested", when(result.get("at")))]


def speed_blocks(run, down, up, down_items, up_items, down_place="Download", up_place="Upload"):
    """Download and upload big, each with its own small stats: a hero each where this Pilot draws one, else one stats
    block."""
    drawn = set((((run.get("pilot") or {}).get("blocks")) or "").split(","))
    if "hero" in drawn:
        return [{"type": "hero", "value": mbps(down), "unit": "Mbps", "place": down_place, "items": down_items[:3]},
                {"type": "hero", "value": mbps(up), "unit": "Mbps", "place": up_place, "items": up_items[:3]}]
    return [{"type": "stats", "items": [{"label": "Download", "value": "%s Mbps" % mbps(down)},
                                        {"label": "Upload", "value": "%s Mbps" % mbps(up)}]
             + [dict(i, label="↓ " + i["label"]) for i in down_items[:2]] + [dict(i, label="↑ " + i["label"]) for i in up_items[:2]]}]


def stat(label, value, tone_=None):
    item = {"label": label, "value": value}
    if tone_:
        item["tone"] = tone_
    return item


def running_blocks(run, job):
    uploading = job.get("phase") == "upload"
    testing = "Connecting to Apple's servers" if job.get("phase") == "connecting" else "Testing…"
    down = [stat("Responsiveness", rpm_words(job.get("download_rpm"))), stat("Moved", job.get("download_moved") or "–"),
            stat("Running", "%d s" % (time.time() - job.get("started", time.time())))]
    up = [stat("Responsiveness", rpm_words(job.get("upload_rpm")) if uploading else "–"),
          stat("Moved", job.get("upload_moved") if uploading else "–")]
    return speed_blocks(run, job.get("download"), job.get("upload") if uploading else None, down, up,
                        "Download" if uploading else "Download · " + testing, "Upload · " + testing if uploading else "Upload") + [
        {"type": "buttons", "actions": [run_action("stop", "Stop", destructive=True)]}]


def result_blocks(run, result):
    rest = dict(facts(result))
    down = [stat("Latency", rest["Latency"]),
            stat("Responsiveness", rest["Download responsiveness"], tone(result.get("download_rpm")))]
    up = [stat("Responsiveness", rest["Upload responsiveness"], tone(result.get("upload_rpm")))]
    blocks = speed_blocks(run, result.get("download"), result.get("upload"), down, up)
    blocks.append({"type": "stats", "items": [stat(k, rest[k]) for k in ("Server", "Interface", "Tested")]})
    blocks.append({"type": "buttons", "actions": [run_action("start", "Run again"), copy_action(result)]})
    return blocks


def page(run, paths):
    """The page: the test's readings, asked every 2 s while it runs; else the last result, or a Run button."""
    job = read_json(paths.job)
    if alive(job):
        return send({"type": "blocks", "refresh": 2, "blocks": running_blocks(run, job)})
    if not tool():
        return send({"type": "blocks", "blocks": [{"type": "markdown", "text": "This Mac has no networkQuality (macOS 12 or later has it)."}]})
    blocks = []
    if job.get("status") == "failed":
        blocks.append({"type": "markdown", "text": "The last test failed: %s" % job.get("error", "")})
    result = read_json(paths.last)
    if result:
        blocks += result_blocks(run, result)
    else:
        blocks += [{"type": "markdown", "text": "No test yet. A test takes about 30 s and moves about 1 GB at gigabit speed."},
                   {"type": "buttons", "actions": [run_action("start", "Run speed test")]}]
    send({"type": "blocks", "blocks": blocks})


def detail(run, paths):
    """Hyper+Space: the readings as they stand while a test runs (its page counts them live), else the last result."""
    job = read_json(paths.job)
    show = {"type": "open", "url": PAGE, "title": "Show live on the page"}
    if alive(job):
        markdown = "# ⚡ Testing…\n\n**Download** %s Mbps · **Upload** %s Mbps" % (
            mbps(job.get("download")), mbps(job.get("upload")) if job.get("phase") == "upload" else "–")
        return send({"type": "detail", "markdown": markdown, "blocks": running_blocks(run, job)[:-1],
                     "actions": [show, run_action("stop", "Stop speed test", key="cmd+delete")]})
    result = read_json(paths.last)
    if not result:
        text = "# ⚡ Speedtest\n\nNo test yet. Return runs one against Apple's servers (about 30 s), live on its page."
        if job.get("status") == "failed":
            text += "\n\nThe last test failed: %s" % job.get("error", "")
        return send({"type": "detail", "markdown": text, "actions": [run_action("start", "Run speed test")]})
    markdown = "# ↓ %s Mbps · ↑ %s Mbps\n\nDownload and upload, %s." % (
        mbps(result.get("download")), mbps(result.get("upload")), when(result.get("at")))
    send({"type": "detail", "markdown": markdown, "blocks": result_blocks(run, result)[:-1],
          "metadata": [{"label": label, "text": value} for label, value in facts(result)],
          "actions": [run_action("start", "Run again"), copy_action(result),
                      {"type": "open", "url": PAGE, "title": "Open page", "key": "cmd+o"}]})


# MARK: Commands

def start(paths):
    found = tool()
    if not found:
        return send({"type": "error", "text": "needs macOS's networkQuality (macOS 12 or later)"})
    job = read_json(paths.job)
    if not alive(job):
        detach(lambda: test(paths, {"tool": found}))
        send({"type": "hud", "text": "Testing your connection…"})
    send({"type": "action", "action": {"type": "open", "url": PAGE, "title": "Show the test"}})


def stop(paths):
    job = read_json(paths.job)
    if not alive(job):
        return send({"type": "hud", "text": "No speed test is running"})
    os.kill(job["pid"], signal.SIGTERM)
    send({"type": "hud", "text": "Stopped the speed test"})


def main():
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        send({"type": "error", "text": "got a run message it could not read"})
        return
    paths = Paths(run)
    command = run.get("command")
    if command == "speedtest":
        detail(run, paths)
    elif command == "start":
        start(paths)
    elif command == "stop":
        stop(paths)
    elif command == "page":
        page(run, paths)
    else:
        send({"type": "error", "text": "has no command %s" % command})


if __name__ == "__main__":
    main()
