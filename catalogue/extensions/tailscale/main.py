#!/usr/bin/env python3
"""Tailscale for Pilot: every device on your tailnet with its OS, Tailscale IP and online state; Return copies the IP.
Its page lists them online first with counts, and its menu-bar item shows how many are online, its click lists them.
Connect and Disconnect (Pilot 1.1, T46) turn Tailscale on and off from the page, the menu-bar item and Hyper+Space.

The page, the bar item and the device list only read: they run `tailscale status --json` and nothing else. Connect runs a
bare `tailscale up`, which only sets Tailscale to running and changes no other setting; when Tailscale.app isn't running it
opens the app first. Disconnect runs `tailscale down`. Neither ever signs in: a signed-out Tailscale is opened for you to
sign in there, and the CLI's own output (which can hold a sign-in link) is never read, shown or kept. The CLI is the one
Tailscale.app installs at /usr/local/bin/tailscale (or one on PATH); it only answers while Tailscale.app runs, and a failed,
slow or unreadable answer becomes one plain row saying Tailscale isn't running. Device names and IPs are shown only to you,
never logged.
"""
import datetime
import json
import os
import shutil
import signal
import subprocess
import sys
import time

CLI = "/usr/local/bin/tailscale"
APP = "/Applications/Tailscale.app"
WAIT = {"page": 3.0, "popover": 3.0}  # seconds; Pilot stops a page or popover after 5, a list or bar line after 2
LIST_WAIT = 1.2  # a cold python3 takes some of those 2 s
MOST_ROWS = 50  # Pilot draws 50 rows of a list block at most
SWITCH_WAIT = 25.0  # seconds for all of Connect or Disconnect; Pilot stops a no-view command after 30
LAUNCH_WAIT = 12.0  # of those, for Tailscale.app to start answering once opened
NOT_RUNNING = ("Tailscale isn't running", "Connect opens it and turns it on")
NOT_INSTALLED = ("Tailscale isn't installed", "Install Tailscale.app from tailscale.com, then look again")
OFFLINE_STATES = {
    "Stopped": ("Tailscale is turned off", "Connect turns it on"),
    "NeedsLogin": ("Tailscale is signed out", "Sign in from Tailscale's menu-bar item, then look again"),
    "NeedsMachineAuth": ("This Mac waits for approval", "An admin of your tailnet approves it in the admin console"),
    "Starting": ("Tailscale is starting", "Look again in a moment"),
}


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


def cli(args, wait):
    """Runs the Tailscale CLI with `args`: (exit code, stdout), code None when it is missing, failed to start or was
    stopped after `wait` seconds. stderr is never read: `up` can print a sign-in link there."""
    try:
        # Its own process group: /usr/local/bin/tailscale is a shell script whose child would outlive a plain kill.
        proc = subprocess.Popen([shutil.which("tailscale") or CLI] + args, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
    except FileNotFoundError:
        return "missing", b""
    except OSError:
        return None, b""
    try:
        out, _ = proc.communicate(timeout=max(0.1, wait))
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.communicate()
        return None, b""
    return proc.returncode, out


def backend(wait=LIST_WAIT):
    """(parsed status or None, state): Tailscale's BackendState, "missing" with no CLI, "down" when it doesn't answer."""
    code, out = cli(["status", "--json"], wait)
    if code == "missing":
        return None, "missing"
    try:
        data = json.loads(out.decode("utf-8", "replace"))
    except ValueError:
        data = None
    if code != 0 or not isinstance(data, dict):
        return None, "down"
    return data, data.get("BackendState")


def status(wait=LIST_WAIT):
    """The parsed `tailscale status --json`, or a (title, subtitle) row saying why there is none."""
    data, state = backend(wait)
    if state == "missing":
        return None, NOT_INSTALLED
    if state == "down":
        return None, NOT_RUNNING
    if state != "Running":
        return None, OFFLINE_STATES.get(state, ("Tailscale isn't connected (%s)" % state, "Open Tailscale.app"))
    return data, None


def ipv4(ips):
    return next((ip for ip in ips if "." in ip), None)


def ipv6(ips):
    return next((ip for ip in ips if ":" in ip), None)


def ago(stamp, now):
    """"last seen 5 min ago" from an RFC 3339 time; a date past a week; None when Tailscale never saw it (year 1)."""
    try:
        seen = datetime.datetime.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)
    except (TypeError, ValueError):
        return None
    if seen.year < 2000:
        return None
    minutes = int((now - seen).total_seconds() // 60)
    if minutes < 1:
        return "last seen just now"
    if minutes < 60:
        return "last seen %d min ago" % minutes
    if minutes < 24 * 60:
        return "last seen %d h ago" % (minutes // 60)
    if minutes < 7 * 24 * 60:
        return "last seen %d d ago" % (minutes // (24 * 60))
    return "last seen %s" % seen.strftime("%Y-%m-%d")


def device_item(node, me, now):
    name = node.get("HostName") or (node.get("DNSName") or "").split(".")[0] or "unnamed device"
    dns = (node.get("DNSName") or "").rstrip(".")
    ips = [ip for ip in node.get("TailscaleIPs") or [] if isinstance(ip, str)]
    v4, v6 = ipv4(ips), ipv6(ips)
    online = bool(node.get("Online")) or me
    state = "this Mac" if me else "online" if online else (ago(node.get("LastSeen"), now) or "offline")
    if node.get("ExitNode"):
        state += ", your exit node"
    item = {"id": node.get("ID") or dns or name, "title": name, "icon": "🟢" if online else "⚪",
            "subtitle": " · ".join(x for x in (node.get("OS"), v4 or v6, state) if x),
            "keywords": " ".join(x for x in [dns, "online" if online else "offline"] + ips if x)}
    actions = []
    if v4 or v6:
        actions.append({"type": "copy", "text": v4 or v6, "title": "Copy IP %s" % (v4 or v6)})
    if v4 and v6:
        actions.append({"type": "copy", "text": v6, "title": "Copy IPv6 %s" % v6})
    if dns:
        actions.append({"type": "copy", "text": dns, "title": "Copy name %s" % dns})
    if actions:
        item["actions"] = actions
    return item, (0 if me else 1 if online else 2, name.lower())


CONNECT = {"type": "run", "command": "connect", "title": "Connect"}
DISCONNECT = {"type": "run", "command": "disconnect", "title": "Disconnect"}
OPEN = {"type": "open", "url": APP, "title": "Open Tailscale"}


def reason_row(why):
    """A row saying why there are no devices; Return connects when Connect can help (turned off, or the app closed)."""
    can_connect = why in (NOT_RUNNING, OFFLINE_STATES["Stopped"])
    return {"title": why[0], "subtitle": why[1], "icon": "🛜",
            "actions": [CONNECT, OPEN] if can_connect else [OPEN]}


def switch(why):
    """The page's and popover's button: Disconnect while on, Connect while off, Open Tailscale to sign in; none when
    Tailscale isn't installed."""
    if why is None:
        return [{"type": "buttons", "actions": [DISCONNECT]}]
    if why in (NOT_RUNNING, OFFLINE_STATES["Stopped"]):
        return [{"type": "buttons", "actions": [CONNECT]}]
    if why == NOT_INSTALLED:
        return []
    return [{"type": "buttons", "actions": [OPEN]}]


def device_rows(data, now=None):
    """(item, online) per device: this Mac, then the online ones, then the offline ones, each by name."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    rows = []
    if isinstance(data.get("Self"), dict):
        rows.append(device_item(data["Self"], True, now))
    peers = data.get("Peer") if isinstance(data.get("Peer"), dict) else {}
    rows += [device_item(p, False, now) for p in peers.values() if isinstance(p, dict)]
    rows.sort(key=lambda row: row[1])
    return [(item, rank < 2) for item, (rank, _) in rows]


def devices(now=None):
    data, why = status()
    if why:
        return [reason_row(why)]
    return [item for item, _ in device_rows(data, now)] or [{"title": "No devices on your tailnet", "icon": "🛜"}]


def lists(rows, most):
    """An Online list and an Offline list, at most `most` rows in all."""
    online = [item for item, on in rows if on][:most]
    offline = [item for item, on in rows if not on][:max(0, most - len(online))]
    blocks = [{"type": "list", "title": title, "items": items}
              for title, items in (("Online", online), ("Offline", offline)) if items]
    return blocks or [{"type": "list", "items": [{"title": "No devices on your tailnet", "icon": "🛜"}]}]


def page(run):
    """Counts, then every device, online ones first."""
    data, why = status(WAIT["page"])
    if why:
        send({"type": "blocks", "blocks": [{"type": "list", "items": [reason_row(why)]}] + switch(why)})
        return
    rows = device_rows(data)
    online = sum(1 for _, on in rows if on)
    stats = {"type": "stats", "items": [{"label": "Online", "value": str(online), "tone": "fine"},
                                        {"label": "Offline", "value": str(len(rows) - online)},
                                        {"label": "Devices", "value": str(len(rows))}]}
    send({"type": "blocks", "blocks": [stats] + switch(None) + lists(rows, MOST_ROWS)})


def bar(run):
    """🛜 and how many devices are online, this Mac counted; a click (surface popover) lists them."""
    popover = run.get("surface") == "popover"
    data, why = status(WAIT["popover"] if popover else LIST_WAIT)
    if why:
        blocks = [{"type": "list", "items": [reason_row(why)]}] + switch(why)
        line = {"type": "bar", "text": "🛜", "tone": "warn", "blocks": blocks}
    else:
        rows = device_rows(data)
        blocks = switch(None) + lists(rows, MOST_ROWS)
        line = {"type": "bar", "text": "🛜 %d" % sum(1 for _, on in rows if on), "blocks": blocks}
    send({"type": "blocks", "blocks": blocks} if popover else line)


def settle(want, deadline):
    """Asks until Tailscale's state is one of `want` or the deadline passes; the last state seen."""
    while True:
        _, state = backend(min(LIST_WAIT, max(0.1, deadline - time.monotonic())))
        if state in want or time.monotonic() + 0.5 >= deadline:
            return state
        time.sleep(0.5)


def sign_in():
    send({"type": "action", "action": OPEN})
    send({"type": "hud", "text": "Tailscale is signed out: sign in from its menu-bar item"})


def connect(run):
    """Turns Tailscale on: opens Tailscale.app first when it isn't running, then a bare `tailscale up` when it is off."""
    deadline = time.monotonic() + SWITCH_WAIT
    _, state = backend()
    if state == "missing":
        send({"type": "error", "text": "can't connect: Tailscale isn't installed"})
        return
    if state == "down":
        try:
            subprocess.run(["open", "-g", APP], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=5)
        except (OSError, subprocess.SubprocessError):
            pass
        state = settle({"Running", "Stopped", "NeedsLogin", "NeedsMachineAuth"},
                       min(deadline, time.monotonic() + LAUNCH_WAIT))
        if state in ("down", "missing"):
            send({"type": "error", "text": "Tailscale.app didn't start: open it, then connect again"})
            return
    if state == "Starting":
        state = settle({"Running", "Stopped", "NeedsLogin", "NeedsMachineAuth"}, min(deadline, time.monotonic() + 5))
    if state == "Running":
        send({"type": "hud", "text": "Tailscale is on"})
        return
    if state == "NeedsLogin":
        sign_in()
        return
    if state == "NeedsMachineAuth":
        send({"type": "hud", "text": "This Mac waits for an admin of your tailnet to approve it"})
        return
    code, _ = cli(["up"], min(10.0, deadline - time.monotonic()))
    state = settle({"Running", "NeedsLogin"}, min(deadline, time.monotonic() + 5))
    if state == "Running":
        send({"type": "hud", "text": "Tailscale is on"})
    elif state == "NeedsLogin":
        sign_in()
    else:
        why = "it didn't answer" if code is None else "it said no"
        send({"type": "error", "text": "couldn't connect (%s): open Tailscale to see why" % why})


def disconnect(run):
    """Turns Tailscale off with `tailscale down`; already off when the app isn't running or it is signed out."""
    deadline = time.monotonic() + SWITCH_WAIT
    _, state = backend()
    if state not in ("Running", "Starting"):
        send({"type": "hud", "text": "Tailscale is already off"})
        return
    code, _ = cli(["down"], 10.0)
    state = settle({"Stopped", "down"}, min(deadline, time.monotonic() + 5))
    if state in ("Stopped", "down"):
        send({"type": "hud", "text": "Tailscale is off"})
    else:
        why = "it didn't answer" if code is None else "it said no"
        send({"type": "error", "text": "couldn't disconnect (%s): open Tailscale to see why" % why})


def main():
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        send({"type": "error", "text": "got a run message it could not read"})
        return
    command = run.get("command")
    if command == "devices":
        send({"type": "list", "items": devices()})
    elif command in ("page", "bar"):
        (page if command == "page" else bar)(run)
    elif command in ("connect", "disconnect"):
        (connect if command == "connect" else disconnect)(run)
    else:
        send({"type": "error", "text": "has no command %s" % run.get("command")})


if __name__ == "__main__":
    main()
