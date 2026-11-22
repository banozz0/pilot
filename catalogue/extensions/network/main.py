#!/usr/bin/env python3
"""Network for Pilot: one extension for the network (Sven, 2026-11-22), taking over Tailscale, Ports, SSH hosts and
Speedtest, each command found by its own name in Hyper+Space as before, plus an Overview and the Devices on the network.

- Network overview: Wi-Fi's name and signal (system_profiler, networksetup, ipconfig), the local IP, the public IP (one
  HTTPS ask of api.ipify.org through curl, kept 5 min), the router (Return opens its admin page) and the DNS servers.
- Devices on the network: the ARP table, names from a detached look (one empty UDP datagram to the discard port of each
  address of a /24 at most, paced, so the kernel learns who answers; then each device asked its name over unicast mDNS,
  else the system resolver), kept in paths.data. No vendor names: no stdlib way to map a MAC prefix to a maker exists,
  so a MAC only says whether it is a private (randomised) address.
- Tailscale devices, Connect and Disconnect Tailscale: `tailscale status --json`; `tailscale up` and `down` only.
- Kill port: the listening TCP ports (lsof) and quitting the program that holds one, never pid 1, this program or Pilot.
- SSH hosts: the hosts ~/.ssh/config and its Includes name, each opened in a new terminal running `ssh <host>`.
- Speedtest: macOS's own networkQuality against Apple's servers, detached, live on the page.

The page has a row of links to each part (the part shown is kept in paths.data/view.txt); the bar item is Tailscale's.
Names, addresses, IPs and hosts are shown only to you and never logged; stdout carries protocol lines only.
Python 3.9 stdlib only, as macOS's /usr/bin/python3.
"""
import datetime
import glob
import ipaddress
import json
import os
import pty
import random
import re
import select
import shlex
import shutil
import signal
import socket
import struct
import subprocess
import sys
import threading
import time

PAGE = "pilot://open?tab=page&extension=network"
# Each run's one time budget for the local reads (seconds after it starts): under Pilot's 2 s for a list, detail or bar
# line and 5 s for a page or popover, a cold python3's start counted. A read past it answers nothing, so the slow sources
# (system_profiler first) drop out and the cheap ones still show. None: no budget (a detached worker, a no-view command).
BUDGETS = {"list": 1.5, "page": 4.2}
LIST_COMMANDS = {"overview", "devices", "tailscale", "kill-port", "ssh-hosts", "speedtest"}
DEADLINE = None


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
    sys.stdout.flush()


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


def data_dir(run):
    return (run.get("paths") or {}).get("data") or os.path.join(os.environ.get("TMPDIR", "/tmp"), "pilot-network")


def cache_dir(run):
    return (run.get("paths") or {}).get("cache") or data_dir(run)


def left(wait, reserve=0.0):
    """`wait`, cut to the run's budget less `reserve` (kept for the reads after); 0 once it is spent."""
    if DEADLINE is None:
        return wait
    return max(0.0, min(wait, DEADLINE - reserve - time.monotonic()))


def output(args, wait=1.5, reserve=0.0):
    """A command's stdout as text, "" when it is missing, fails or takes longer than `wait` seconds (or the run's
    budget less `reserve`, whichever ends first)."""
    wait = left(wait, reserve)
    if wait < 0.05:
        return ""
    try:
        done = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=wait)
    except (OSError, subprocess.SubprocessError):
        return ""
    return done.stdout if done.returncode == 0 else ""


def drawn(run, kind):
    """Whether this Pilot draws a block `kind` (the run message's pilot.blocks)."""
    pilot = run.get("pilot")
    listed = str(pilot.get("blocks") or "") if isinstance(pilot, dict) else ""
    return kind in [k.strip() for k in listed.split(",")]


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
    global DEADLINE
    DEADLINE = None  # Pilot no longer waits on a detached worker
    null = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(null, fd)
    code = 0
    try:
        work()
    except Exception:  # nowhere to say it: its file says what it could
        code = 1
    os._exit(code)


def ours(pid):
    """Whether `pid` is still this extension's program (a pid reused since is not)."""
    if not isinstance(pid, int) or pid <= 1:
        return False
    try:
        os.kill(pid, 0)
        command = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True, timeout=1).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return os.path.join(os.path.basename(os.path.dirname(os.path.abspath(__file__))), "main.py") in command


def step_action(name, title, context=None, **fields):
    """A run action for one of Network's steps (quit a port's program, connect an SSH host, switch the page's part…):
    the one hidden `step` command, the step named in its context, so Pilot's install question lists one command, not
    seven (1474 of its 1200 characters with each its own)."""
    action = {"type": "run", "command": "step", "title": title, "context": dict(context or {}, step=name)}
    action.update(fields)
    return action


# MARK: - The local network: interfaces, Wi-Fi, router, DNS, public IP

def hardware_ports():
    """{device: port name} from networksetup ("en0": "Wi-Fi")."""
    ports, name = {}, None
    for line in output(["networksetup", "-listallhardwareports"]).splitlines():
        if line.startswith("Hardware Port: "):
            name = line[len("Hardware Port: "):].strip()
        elif line.startswith("Device: ") and name:
            ports[line[len("Device: "):].strip()] = name
    return ports


def default_route():
    """(router, interface) of the default IPv4 route; None for each it lacks."""
    router = interface = None
    for line in output(["route", "-n", "get", "default"]).splitlines():
        key, _, value = line.strip().partition(":")
        if key == "gateway":
            router = value.strip() or None
        elif key == "interface":
            interface = value.strip() or None
    return router, interface


def local_ip(interface):
    value = output(["ipconfig", "getifaddr", interface]).strip() if interface else ""
    return value if valid_ip(value) else None


def subnet_mask(interface):
    value = output(["ipconfig", "getoption", interface, "subnet_mask"]).strip() if interface else ""
    return value if valid_ip(value) else None


def valid_ip(text):
    try:
        ipaddress.ip_address(text)
        return True
    except ValueError:
        return False


def dns_servers():
    """The default resolver's name servers, as `scutil --dns` lists them under resolver #1, in order."""
    servers, inside = [], False
    for line in output(["scutil", "--dns"]).splitlines():
        stripped = line.strip()
        if stripped.startswith("DNS configuration (for scoped"):
            break
        if stripped.startswith("resolver #"):
            if servers:
                break
            inside = stripped == "resolver #1"
        elif inside and stripped.startswith("nameserver["):
            value = stripped.split(":", 1)[1].strip()
            if valid_ip(value) and value not in servers:
                servers.append(value)
    return servers


def signal_words(dbm):
    """A Wi-Fi signal as people read it, with a tone: strong past -60 dBm, good past -70, weak past -80, else very weak."""
    if dbm is None:
        return None, None
    if dbm >= -60:
        return "strong", "fine"
    if dbm >= -70:
        return "good", "fine"
    if dbm >= -80:
        return "weak", "warn"
    return "very weak", "alert"


HIDDEN = "<redacted>"


def wifi(ports=None):
    """Wi-Fi as {"device", "on", "connected", "name", "signal" (dBm), "noise", "channel", "rate"}; None without Wi-Fi.
    system_profiler's answer first; the name, when macOS hides it there, from networksetup or ipconfig."""
    ports = hardware_ports() if ports is None else ports
    device = next((d for d, n in ports.items() if n in ("Wi-Fi", "AirPort")), None)
    if not device:
        return None
    found = {"device": device, "on": True, "connected": False, "name": None, "signal": None, "noise": None,
             "channel": None, "rate": None}
    try:
        profile = json.loads(output(["system_profiler", "SPAirPortDataType", "-json"], wait=3.0, reserve=0.6) or "{}")
    except ValueError:
        profile = {}
    for entry in (profile.get("SPAirPortDataType") or [{}])[0].get("spairport_airport_interfaces") or []:
        if not isinstance(entry, dict) or entry.get("_name") != device:
            continue
        status = entry.get("spairport_status_information") or ""
        found["on"] = status != "spairport_status_off"
        current = entry.get("spairport_current_network_information")
        if isinstance(current, dict):
            found["connected"] = True
            found["name"] = current.get("_name") if current.get("_name") not in (None, "", HIDDEN) else None
            levels = re.findall(r"(-?\d+) dBm", str(current.get("spairport_signal_noise") or ""))
            if levels:
                found["signal"] = int(levels[0])
                found["noise"] = int(levels[1]) if len(levels) > 1 else None
            found["channel"] = str(current.get("spairport_network_channel") or "") or None
            rate = current.get("spairport_network_rate")
            found["rate"] = rate if isinstance(rate, (int, float)) else None
    if not found["name"]:
        said = output(["networksetup", "-getairportnetwork", device], reserve=0.5).strip()
        if said.startswith("Current Wi-Fi Network: "):
            found["name"] = said[len("Current Wi-Fi Network: "):].strip() or None
            found["connected"] = True
        elif "power is currently off" in said:
            found["on"] = False
    if not found["name"] and found["on"]:
        for line in output(["ipconfig", "getsummary", device], reserve=0.4).splitlines():
            key, _, value = line.strip().partition(" : ")
            if key == "SSID" and value.strip() not in ("", HIDDEN):
                found["name"], found["connected"] = value.strip(), True
    return found


PUBLIC_IP = "https://api.ipify.org"
PUBLIC_KEPT = 300  # seconds a public IP is kept; a failed ask is kept a minute
PUBLIC_FAILED_KEPT = 60


def public_ip(run, wait):
    """This network's public IP: the one kept under 5 min ago, else one HTTPS ask (curl, `wait` s at most); None when
    it could not be asked. Kept in paths.cache only."""
    path = os.path.join(cache_dir(run), "public-ip.json")
    kept = read_json(path)
    age = time.time() - kept.get("at", 0) if isinstance(kept.get("at"), (int, float)) else None
    if age is not None and 0 <= age < (PUBLIC_KEPT if kept.get("ip") else PUBLIC_FAILED_KEPT):
        return kept.get("ip")
    wait = left(wait)
    if wait < 0.3:
        return None
    answer = output(["curl", "-s", "-f", "-m", "%.1f" % wait, PUBLIC_IP], wait=wait + 0.2).strip()
    ip = answer if valid_ip(answer) else None
    try:
        write_json(path, {"at": time.time(), "ip": ip})
    except OSError:
        pass
    return ip


def tunnel(interface):
    return bool(interface) and interface.startswith(("utun", "ipsec", "ppp"))


def connection():
    """What the Mac is on now: {"kind" (Wi-Fi, Ethernet…, VPN, or None offline), "interface", "ip", "router", "ports",
    "lan"}; `lan` is the local network's own {"interface", "ip", "router", "kind"}, a hardware port's when the default
    route goes through a tunnel (a VPN, a Tailscale exit node)."""
    router, interface = default_route()
    ports = hardware_ports()
    lan = {"interface": interface, "ip": local_ip(interface), "router": router}
    if tunnel(interface):
        lan = {"interface": None, "ip": None, "router": None}
        for device in ports:
            ip = local_ip(device)
            if ip:
                found = output(["ipconfig", "getoption", device, "router"]).strip()
                lan = {"interface": device, "ip": ip, "router": found if valid_ip(found) else None}
                break
    def kind_of(device):
        name = ports.get(device) or device
        return "Wi-Fi" if name == "AirPort" else name
    lan["kind"] = kind_of(lan["interface"]) if lan["interface"] else None
    kind = ("VPN" if tunnel(interface) else kind_of(interface)) if interface else None
    return {"kind": kind, "interface": interface, "ip": lan["ip"], "router": router, "ports": ports, "lan": lan}


def copy(text, title):
    return {"type": "copy", "text": text, "title": title}


def router_url(router):
    return "http://%s" % (router if ":" not in router else "[%s]" % router)


WIFI_SETTINGS = {"type": "open", "url": "x-apple.systempreferences:com.apple.wifi-settings-extension",
                 "title": "Open Wi-Fi settings"}


def overview_items(run, wait):
    """Wi-Fi, Local IP, Public IP, Router, DNS: a row each."""
    # Cheap local reads first, then Wi-Fi's slow tools, then the one ask that leaves the Mac: when the budget runs
    # out, the last ones drop.
    now = connection()
    servers = dns_servers()
    air = now["wifi"] = wifi(now["ports"])
    items = []
    on = "On %s" % now["kind"] if now["kind"] else "Not connected"
    if air is None:
        items.append({"id": "wifi", "title": "No Wi-Fi on this Mac", "icon": "📶", "subtitle": on})
    elif not air["on"] or not air["connected"]:
        joined = air["on"] and now["kind"] in (None, "Wi-Fi")
        items.append({"id": "wifi", "title": "Wi-Fi is on, not joined" if air["on"] else "Wi-Fi is off", "icon": "📶",
                      "subtitle": "No network joined" if joined else on, "actions": [WIFI_SETTINGS]})
    else:
        words, tone_ = signal_words(air["signal"])
        name = air["name"] or "Wi-Fi (macOS hides its name)"
        parts = ["Wi-Fi"]
        if air["signal"] is not None:
            parts.append("signal %s, %d dBm" % (words, air["signal"]))
        if air["channel"]:
            parts.append("channel %s" % air["channel"])
        item = {"id": "wifi", "title": name, "icon": "📶", "subtitle": " · ".join(parts), "keywords": "wifi wi-fi ssid signal"}
        if tone_:
            item["accessory"] = {"text": words, "tone": tone_}
        if air["name"]:
            item["actions"] = [copy(air["name"], "Copy Wi-Fi name")]
        items.append(item)
    if now["ip"]:
        items.append({"id": "local-ip", "title": now["ip"], "icon": "🏠",
                      "subtitle": "Local IP · %s (%s)" % (now["lan"]["kind"], now["lan"]["interface"]),
                      "keywords": "local ip address lan",
                      "actions": [copy(now["ip"], "Copy local IP")]})
    else:
        items.append({"id": "local-ip", "title": "No local IP", "icon": "🏠", "subtitle": "This Mac is not on a network"})
    ip = public_ip(run, wait) if now["kind"] else None
    if ip:
        items.append({"id": "public-ip", "title": ip, "icon": "🌍", "subtitle": "Public IP, as the internet sees you",
                      "keywords": "public ip address wan external", "actions": [copy(ip, "Copy public IP")]})
    else:
        items.append({"id": "public-ip", "title": "Public IP not known", "icon": "🌍",
                      "subtitle": "api.ipify.org did not answer" if now["kind"] else "This Mac is offline"})
    if now["router"]:
        items.append({"id": "router", "title": now["router"], "icon": "📡",
                      "subtitle": "Router · Return opens its admin page", "keywords": "router gateway admin",
                      "actions": [{"type": "open", "url": router_url(now["router"]), "title": "Open router admin page"},
                                  copy(now["router"], "Copy router address")]})
    else:
        items.append({"id": "router", "title": "No router", "icon": "📡", "subtitle": "No default route"})
    if servers:
        items.append({"id": "dns", "title": ", ".join(servers[:3]) + (" +%d" % (len(servers) - 3) if len(servers) > 3 else ""),
                      "icon": "🧭", "subtitle": "DNS", "keywords": "dns nameserver resolver",
                      "actions": [copy(", ".join(servers), "Copy DNS servers")]})
    else:
        items.append({"id": "dns", "title": "No DNS server", "icon": "🧭", "subtitle": "DNS"})
    return items, now


def overview(run):
    items, _ = overview_items(run, wait=0.8)
    send({"type": "list", "items": items})


def overview_blocks(run):
    items, now = overview_items(run, wait=2.0)
    stats = [{"label": "On", "value": now["kind"] or "Offline", "tone": "fine" if now["kind"] else "alert"}]
    air = now["wifi"]
    if now["kind"] == "Wi-Fi" and air and air["signal"] is not None:
        _, tone_ = signal_words(air["signal"])
        stats.append({"label": "Signal", "value": "%d dBm" % air["signal"], "tone": tone_})
        if air["rate"]:
            stats.append({"label": "Link", "value": "%d Mbps" % air["rate"]})
    known = arp_devices(now["lan"]["interface"]) if now["lan"]["interface"] else []
    if known:
        stats.append({"label": "Devices", "value": str(len(known))})
    last = speed_last(Paths(run))
    if last:
        stats.append({"label": "Last speed test", "value": "↓ %s ↑ %s Mbps" % (mbps(last.get("download")), mbps(last.get("upload")))})
    return [{"type": "stats", "items": stats}, {"type": "list", "title": "Network", "items": items}], None


# MARK: - Devices on the network

ARP_LINE = re.compile(r"^\S+ \(([\d.]+)\) at (\S+) on (\S+)(.*)$")
SCAN_KEPT = 120  # seconds before a Devices view looks again by itself
MOST_PROBED = 256
PROBE_GAP = 0.004  # seconds between two datagrams: about a second for a /24
SETTINGS_LOCAL_NETWORK = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"


def mac_text(raw):
    """arp's "0:1a:2b:3:4:5" as "00:1a:2b:03:04:05"; None when it is not a MAC."""
    parts = raw.lower().split(":")
    if len(parts) != 6 or not all(re.fullmatch(r"[0-9a-f]{1,2}", p) for p in parts):
        return None
    return ":".join(p.zfill(2) for p in parts)


def private_mac(mac):
    """A locally administered (randomised) MAC, as phones use per network: its first byte's second bit."""
    return bool(int(mac.split(":")[0], 16) & 2)


def arp_devices(interface=None):
    """[{"ip", "mac", "interface", "own"}] from `arp -an`: unicast IPv4 neighbours with a MAC, on `interface` when given,
    never multicast, broadcast or incomplete entries."""
    found = []
    for line in output(["arp", "-an"]).splitlines():
        match = ARP_LINE.match(line.strip())
        if not match:
            continue
        ip, raw, on, rest = match.groups()
        mac = mac_text(raw)
        if not mac or mac == "ff:ff:ff:ff:ff:ff" or (interface and on != interface):
            continue
        try:
            address = ipaddress.ip_address(ip)
        except ValueError:
            continue
        if address.is_multicast or address.is_unspecified or ip.endswith(".255"):
            continue
        found.append({"ip": ip, "mac": mac, "interface": on, "own": "permanent" in rest})
    return found


class Scan:
    """The Devices look's files in paths.data: scan.json (when it last ran, whether it runs) and names.json (each
    device's name by MAC, as it last answered)."""

    def __init__(self, run):
        folder = data_dir(run)
        self.state = os.path.join(folder, "scan.json")
        self.names = os.path.join(folder, "names.json")

    def running(self):
        state = read_json(self.state)
        return state.get("status") == "running" and ours(state.get("pid"))

    def stale(self):
        at = read_json(self.state).get("at")
        return not isinstance(at, (int, float)) or time.time() - at > SCAN_KEPT

    def known(self):
        names = read_json(self.names)
        return {mac: v for mac, v in names.items() if isinstance(v, dict) and isinstance(v.get("name"), str)}


def probe_targets(ip, mask):
    """The addresses a look sends to: the interface's subnet, cut to the /24 around `ip` when it is larger, without the
    Mac itself; none off a private, IPv4 network."""
    try:
        network = ipaddress.ip_network("%s/%s" % (ip, mask or "255.255.255.0"), strict=False)
        own = ipaddress.ip_address(ip)
    except ValueError:
        return []
    if not own.is_private or own.is_loopback:
        return []
    if network.num_addresses > MOST_PROBED:
        network = ipaddress.ip_network("%s/24" % ip, strict=False)
    return [str(a) for a in network.hosts() if a != own]


def probe(targets):
    """One empty UDP datagram to the discard port (9) of each address, PROBE_GAP s apart: the kernel asks ARP who holds each
    one, so the devices that are up land in the ARP table. Nothing is read back and no port is scanned."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        for address in targets:
            try:
                sock.sendto(b"", (address, 9))
            except OSError:
                pass
            time.sleep(PROBE_GAP)
    finally:
        sock.close()


def ptr_name(ip):
    return ".".join(reversed(ip.split("."))) + ".in-addr.arpa"


def mdns_query(ip, ident):
    """A DNS question for `ip`'s PTR record, asked straight of the device on port 5353 (unicast mDNS)."""
    question = b"".join(bytes([len(p)]) + p.encode() for p in ptr_name(ip).split(".")) + b"\0"
    return struct.pack(">HHHHHH", ident, 0, 1, 0, 0, 0) + question + struct.pack(">HH", 12, 1)


def read_name(packet, at):
    """A DNS name at `at` in `packet` (compression followed): (name, the offset after it)."""
    labels, after, depth = [], None, 0
    while depth < 20:
        if at >= len(packet):
            raise ValueError("short")
        length = packet[at]
        if length == 0:
            at += 1
            break
        if length & 0xC0 == 0xC0:
            pointer = struct.unpack(">H", packet[at:at + 2])[0] & 0x3FFF
            after = at + 2 if after is None else after
            at, depth = pointer, depth + 1
            continue
        labels.append(packet[at + 1:at + 1 + length].decode("utf-8", "replace"))
        at += 1 + length
    return ".".join(labels), (after if after is not None else at)


def mdns_answer(packet):
    """The PTR answer's name in a DNS reply, without a trailing ".local"; None when there is none."""
    try:
        _, flags, questions, answers = struct.unpack(">HHHH", packet[:8])
        if not flags & 0x8000:
            return None
        at = 12
        for _ in range(questions):
            _, at = read_name(packet, at)
            at += 4
        for _ in range(answers):
            _, at = read_name(packet, at)
            kind, _, _, length = struct.unpack(">HHIH", packet[at:at + 10])
            at += 10
            if kind == 12:
                name, _ = read_name(packet, at)
                return clean_name(name)
            at += length
    except (ValueError, struct.error):
        return None
    return None


def clean_name(name):
    """A host name as a row's title: no trailing dot or ".local", hyphens left as they are; None when blank."""
    name = (name or "").strip().rstrip(".")
    for suffix in (".local", ".lan", ".home", ".localdomain"):
        if name.lower().endswith(suffix):
            name = name[:-len(suffix)]
    return name or None


def mdns_names(ips, wait=1.5):
    """{ip: name} from each device that answers a unicast mDNS PTR question within `wait` s."""
    found = {}
    if not ips:
        return found
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.setblocking(False)
        asked = {}
        for ip in ips:
            ident = random.randint(1, 0xFFFF)
            asked[ip] = ident
            try:
                sock.sendto(mdns_query(ip, ident), (ip, 5353))
            except OSError:
                pass
        deadline = time.monotonic() + wait
        while len(found) < len(asked) and time.monotonic() < deadline:
            ready, _, _ = select.select([sock], [], [], max(0.0, deadline - time.monotonic()))
            if not ready:
                break
            try:
                packet, (sender, _) = sock.recvfrom(4096)
            except OSError:
                continue
            name = mdns_answer(packet) if sender in asked else None
            if name:
                found[sender] = name
    finally:
        sock.close()
    return found


def resolver_names(ips, wait=2.0):
    """{ip: name} from the system resolver (the router's DNS, mDNSResponder), each ask in its own thread, `wait` s in all."""
    found, lock = {}, threading.Lock()

    def ask(ip):
        try:
            name = clean_name(socket.gethostbyaddr(ip)[0])
        except (OSError, UnicodeError):
            return
        if name and name != ip:
            with lock:
                found[ip] = name

    threads = [threading.Thread(target=ask, args=(ip,), daemon=True) for ip in ips]
    for t in threads:
        t.start()
    deadline = time.monotonic() + wait
    for t in threads:
        t.join(max(0.0, deadline - time.monotonic()))
    with lock:
        return dict(found)


def scan_work(scan, interface, ip, mask, probe_=probe, mdns=mdns_names, resolver=resolver_names):
    """The detached look: wake the subnet, then ask each device in the ARP table its name; names.json keeps them by MAC.
    """
    write_json(scan.state, {"status": "running", "pid": os.getpid(), "at": time.time()})
    try:
        probe_(probe_targets(ip, mask))
        time.sleep(1.0)
        devices = [d for d in arp_devices(interface) if not d["own"]]
        ips = [d["ip"] for d in devices]
        names = mdns(ips)
        names.update(resolver([i for i in ips if i not in names]))
        kept = read_json(scan.names)
        for d in devices:
            if d["ip"] in names:
                kept[d["mac"]] = {"name": names[d["ip"]], "ip": d["ip"], "at": time.time()}
        write_json(scan.names, kept)
    finally:
        write_json(scan.state, {"status": "done", "pid": None, "at": time.time()})


def start_scan(run, now=None, force=False):
    """Starts the look detached when it is due (or `force`d) and none runs; whether one runs now."""
    scan = Scan(run)
    if scan.running():
        return True
    if not force and not scan.stale():
        return False
    lan = (now or connection())["lan"]
    if not lan["interface"] or not lan["ip"]:
        return False
    interface, ip, mask = lan["interface"], lan["ip"], subnet_mask(lan["interface"])
    write_json(scan.state, {"status": "running", "pid": None, "at": time.time()})
    detach(lambda: scan_work(scan, interface, ip, mask))
    return True


def device_rows(run, now):
    """The Devices rows (router first, then this Mac, then named ones, then by address), how many carry a name the
    look found, and whether the table may be one macOS hid: the router always answers ARP, so a table holding nobody
    but this Mac (with a router known) is taken as hidden."""
    lan = now["lan"]
    devices = arp_devices(lan["interface"]) if lan["interface"] else []
    if lan["router"] and all(d["own"] for d in devices):
        return [], 0, True
    names = Scan(run).known()
    rows, named = [], 0
    for d in devices:
        own, router, private = d["own"] or d["ip"] == lan["ip"], d["ip"] == lan["router"], private_mac(d["mac"])
        found = None if own else (names.get(d["mac"]) or {}).get("name")
        named += 1 if found else 0
        name = "This Mac" if own else found
        roles = (["router"] if router else []) + (["private address"] if private else [])
        icon = "💻" if own else "📡" if router else "📱" if private else "🔹"
        item = {"id": d["mac"], "title": name or d["ip"], "icon": icon, "subtitle": " · ".join([d["ip"], d["mac"]] + roles),
                "keywords": " ".join(x for x in (d["ip"], d["mac"], name, " ".join(roles)) if x)}
        actions = [{"type": "open", "url": router_url(d["ip"]), "title": "Open router admin page"}] if router else []
        actions += [copy(d["ip"], "Copy IP %s" % d["ip"]), copy(d["mac"], "Copy MAC")]
        if found:
            actions.append(copy(found, "Copy name"))
        item["actions"] = actions
        key = (0 if router else 1 if own else 2 if name else 3, (name or "").lower(), tuple(int(p) for p in d["ip"].split(".")))
        rows.append((key, item))
    rows.sort(key=lambda r: r[0])
    return [item for _, item in rows], named, False


LOOK_AGAIN = step_action("devices-scan", "Look again")
HIDDEN_ROW = {"title": "No devices: macOS may be keeping them from Pilot", "icon": "🔒",
              "subtitle": "Return opens Privacy & Security › Local Network: turn Pilot on there, then look again",
              "actions": [{"type": "open", "url": SETTINGS_LOCAL_NETWORK, "title": "Open Local Network settings"},
                          dict(LOOK_AGAIN, stay=True)]}
NOT_ON_A_NETWORK = {"title": "This Mac is not on a network", "icon": "📡"}
NONE_YET = {"title": "No devices found yet", "icon": "📡", "subtitle": "Looking now; open this again in a moment"}


def devices_found(run):
    """(connection, rows or None off a network, named, hidden, whether a look runs). A look starts when one is due,
    a hidden-looking table too: a cold table fills where macOS lets the look through."""
    now = connection()
    if not now["lan"]["interface"]:
        return now, None, 0, False, False
    rows, named, hidden = device_rows(run, now)
    return now, rows, named, hidden, start_scan(run, now)


def empty_row(rows, hidden, looking):
    """The one row of a Devices view with no devices to list: off a network; macOS hiding them, once a look has finished
    and still found nobody; else none yet, a look running."""
    return NOT_ON_A_NETWORK if rows is None else HIDDEN_ROW if hidden and not looking else NONE_YET


def devices(run):
    _, rows, _, hidden, looking = devices_found(run)
    if rows is None or hidden or not rows:
        return send({"type": "list", "items": [empty_row(rows, hidden, looking)]})
    look = {"title": "Look for more devices", "icon": "🔎", "subtitle": "Wakes the network and asks each device its name",
            "actions": [dict(LOOK_AGAIN, stay=True)]}
    send({"type": "list", "items": rows + [look]})


def devices_blocks(run):
    """The page's Devices: (blocks, refresh), asked every 3 s while a look runs."""
    now, rows, named, hidden, looking = devices_found(run)
    refresh = 3 if looking else None
    if rows is None or hidden or not rows:
        return [{"type": "list", "items": [empty_row(rows, hidden, looking)]}], refresh
    lan = now["lan"]
    stats = {"type": "stats", "items": [{"label": "Devices", "value": str(len(rows))}, {"label": "Named", "value": str(named)},
                                        {"label": "Network", "value": "%s on %s" % (lan["kind"], lan["interface"])}]}
    buttons = {"type": "buttons", "actions": [dict(LOOK_AGAIN, title="Looking…" if looking else "Look again")]}
    return [stats, buttons, {"type": "list", "title": "On %s" % lan["interface"], "items": rows[:MOST_ROWS]}], refresh


def devices_scan(run):
    start_scan(run, force=True)
    send({"type": "hud", "text": "Looking for devices on your network…"})


# MARK: - Tailscale

TS_CLI = "/usr/local/bin/tailscale"
TS_APP = "/Applications/Tailscale.app"
TS_WAIT = {"page": 3.0, "popover": 3.0}  # seconds; Pilot stops a page or popover after 5, a list or bar line after 2
TS_LIST_WAIT = 1.2  # a cold python3 takes some of those 2 s
MOST_ROWS = 50  # Pilot draws 50 rows of a list block at most
TS_SWITCH_WAIT = 25.0  # seconds for all of Connect or Disconnect; Pilot stops a no-view command after 30
TS_LAUNCH_WAIT = 12.0  # of those, for Tailscale.app to start answering once opened
TS_NOT_RUNNING = ("Tailscale isn't running", "Connect opens it and turns it on")
TS_NOT_INSTALLED = ("Tailscale isn't installed", "Install Tailscale.app from tailscale.com, then look again")
TS_OFFLINE_STATES = {
    "Stopped": ("Tailscale is turned off", "Connect turns it on"),
    "NeedsLogin": ("Tailscale is signed out", "Sign in from Tailscale's menu-bar item, then look again"),
    "NeedsMachineAuth": ("This Mac waits for approval", "An admin of your tailnet approves it in the admin console"),
    "Starting": ("Tailscale is starting", "Look again in a moment"),
}


def ts_cli(args, wait):
    """Runs the Tailscale CLI with `args`: (exit code, stdout), code None when it failed to start or was stopped after
    `wait` seconds, "missing" when there is none. stderr is never read: `up` can print a sign-in link there."""
    try:
        # Its own process group: /usr/local/bin/tailscale is a shell script whose child would outlive a plain kill.
        proc = subprocess.Popen([shutil.which("tailscale") or TS_CLI] + args, stdin=subprocess.DEVNULL,
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


def ts_backend(wait=TS_LIST_WAIT):
    """(parsed status or None, state): Tailscale's BackendState, "missing" with no CLI, "down" when it doesn't answer."""
    code, out = ts_cli(["status", "--json"], wait)
    if code == "missing":
        return None, "missing"
    try:
        data = json.loads(out.decode("utf-8", "replace"))
    except ValueError:
        data = None
    if code != 0 or not isinstance(data, dict):
        return None, "down"
    return data, data.get("BackendState")


def ts_status(wait=TS_LIST_WAIT):
    """The parsed `tailscale status --json`, or a (title, subtitle) row saying why there is none."""
    data, state = ts_backend(wait)
    if state == "missing":
        return None, TS_NOT_INSTALLED
    if state == "down":
        return None, TS_NOT_RUNNING
    if state != "Running":
        return None, TS_OFFLINE_STATES.get(state, ("Tailscale isn't connected (%s)" % state, "Open Tailscale.app"))
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


def ts_device_item(node, me, now):
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
            "keywords": " ".join(x for x in ["tailscale", dns, "online" if online else "offline"] + ips if x)}
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


TS_CONNECT = {"type": "run", "command": "tailscale-connect", "title": "Connect"}
TS_DISCONNECT = {"type": "run", "command": "tailscale-disconnect", "title": "Disconnect"}
TS_OPEN = {"type": "open", "url": TS_APP, "title": "Open Tailscale"}


def ts_reason_row(why):
    """A row saying why there are no devices; Return connects when Connect can help (turned off, or the app closed)."""
    can_connect = why in (TS_NOT_RUNNING, TS_OFFLINE_STATES["Stopped"])
    return {"title": why[0], "subtitle": why[1], "icon": "🛜",
            "actions": [TS_CONNECT, TS_OPEN] if can_connect else [TS_OPEN]}


def ts_switch(why):
    """The page's and popover's button: Disconnect while on, Connect while off, Open Tailscale to sign in; none when
    Tailscale isn't installed."""
    if why is None:
        return [{"type": "buttons", "actions": [TS_DISCONNECT]}]
    if why in (TS_NOT_RUNNING, TS_OFFLINE_STATES["Stopped"]):
        return [{"type": "buttons", "actions": [TS_CONNECT]}]
    if why == TS_NOT_INSTALLED:
        return []
    return [{"type": "buttons", "actions": [TS_OPEN]}]


def ts_device_rows(data, now=None):
    """(item, online) per device: this Mac, then the online ones, then the offline ones, each by name."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    rows = []
    if isinstance(data.get("Self"), dict):
        rows.append(ts_device_item(data["Self"], True, now))
    peers = data.get("Peer") if isinstance(data.get("Peer"), dict) else {}
    rows += [ts_device_item(p, False, now) for p in peers.values() if isinstance(p, dict)]
    rows.sort(key=lambda row: row[1])
    return [(item, rank < 2) for item, (rank, _) in rows]


def ts_devices(now=None):
    data, why = ts_status()
    if why:
        return [ts_reason_row(why)]
    return [item for item, _ in ts_device_rows(data, now)] or [{"title": "No devices on your tailnet", "icon": "🛜"}]


def ts_lists(rows, most):
    """An Online list and an Offline list, at most `most` rows in all."""
    online = [item for item, on in rows if on][:most]
    offline = [item for item, on in rows if not on][:max(0, most - len(online))]
    blocks = [{"type": "list", "title": title, "items": items}
              for title, items in (("Online", online), ("Offline", offline)) if items]
    return blocks or [{"type": "list", "items": [{"title": "No devices on your tailnet", "icon": "🛜"}]}]


def tailscale_blocks(run):
    """Counts, then every device, online ones first."""
    data, why = ts_status(TS_WAIT["page"])
    if why:
        return [{"type": "list", "items": [ts_reason_row(why)]}] + ts_switch(why)
    rows = ts_device_rows(data)
    online = sum(1 for _, on in rows if on)
    stats = {"type": "stats", "items": [{"label": "Online", "value": str(online), "tone": "fine"},
                                        {"label": "Offline", "value": str(len(rows) - online)},
                                        {"label": "Devices", "value": str(len(rows))}]}
    return [stats] + ts_switch(None) + ts_lists(rows, MOST_ROWS)


def bar(run):
    """The menu-bar item: 🛜 and how many Tailscale devices are online (🌐 without Tailscale); a click (surface popover)
    shows Network's popover (popover_blocks)."""
    if run.get("surface") == "popover":
        return send({"type": "blocks", "blocks": popover_blocks(run)})
    data, why = ts_status(TS_LIST_WAIT)
    if why == TS_NOT_INSTALLED:
        line = {"type": "bar", "text": "🌐"}
    elif why:
        line = {"type": "bar", "text": "🛜", "tone": "warn"}
    else:
        line = {"type": "bar", "text": "🛜 %d" % sum(1 for _, on in ts_device_rows(data) if on)}
    send(line)


def ts_settle(want, deadline):
    """Asks until Tailscale's state is one of `want` or the deadline passes; the last state seen."""
    while True:
        _, state = ts_backend(min(TS_LIST_WAIT, max(0.1, deadline - time.monotonic())))
        if state in want or time.monotonic() + 0.5 >= deadline:
            return state
        time.sleep(0.5)


def ts_sign_in():
    send({"type": "action", "action": TS_OPEN})
    send({"type": "hud", "text": "Tailscale is signed out: sign in from its menu-bar item"})


def ts_connect(run):
    """Turns Tailscale on: opens Tailscale.app first when it isn't running, then a bare `tailscale up` when it is off."""
    deadline = time.monotonic() + TS_SWITCH_WAIT
    _, state = ts_backend()
    if state == "missing":
        send({"type": "error", "text": "can't connect: Tailscale isn't installed"})
        return
    if state == "down":
        try:
            subprocess.run(["open", "-g", TS_APP], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=5)
        except (OSError, subprocess.SubprocessError):
            pass
        state = ts_settle({"Running", "Stopped", "NeedsLogin", "NeedsMachineAuth"},
                          min(deadline, time.monotonic() + TS_LAUNCH_WAIT))
        if state in ("down", "missing"):
            send({"type": "error", "text": "Tailscale.app didn't start: open it, then connect again"})
            return
    if state == "Starting":
        state = ts_settle({"Running", "Stopped", "NeedsLogin", "NeedsMachineAuth"}, min(deadline, time.monotonic() + 5))
    if state == "Running":
        send({"type": "hud", "text": "Tailscale is on"})
        return
    if state == "NeedsLogin":
        ts_sign_in()
        return
    if state == "NeedsMachineAuth":
        send({"type": "hud", "text": "This Mac waits for an admin of your tailnet to approve it"})
        return
    code, _ = ts_cli(["up"], min(10.0, deadline - time.monotonic()))
    state = ts_settle({"Running", "NeedsLogin"}, min(deadline, time.monotonic() + 5))
    if state == "Running":
        send({"type": "hud", "text": "Tailscale is on"})
    elif state == "NeedsLogin":
        ts_sign_in()
    else:
        why = "it didn't answer" if code is None else "it said no"
        send({"type": "error", "text": "couldn't connect (%s): open Tailscale to see why" % why})


def ts_disconnect(run):
    """Turns Tailscale off with `tailscale down`; already off when the app isn't running or it is signed out."""
    deadline = time.monotonic() + TS_SWITCH_WAIT
    _, state = ts_backend()
    if state not in ("Running", "Starting"):
        send({"type": "hud", "text": "Tailscale is already off"})
        return
    code, _ = ts_cli(["down"], 10.0)
    state = ts_settle({"Stopped", "down"}, min(deadline, time.monotonic() + 5))
    if state in ("Stopped", "down"):
        send({"type": "hud", "text": "Tailscale is off"})
    else:
        why = "it didn't answer" if code is None else "it said no"
        send({"type": "error", "text": "couldn't disconnect (%s): open Tailscale to see why" % why})


# MARK: - Ports

LSOF_TIMEOUT = 1.5
PORTS_REFRESH = 10  # seconds: the Ports part of the page is asked again this often, as Ports' own page was


def lsof(arguments):
    """lsof's field output; lsof exits 1 when nothing matches, which is no rows, not a failure."""
    try:
        done = subprocess.run(["lsof"] + arguments, capture_output=True, text=True, timeout=LSOF_TIMEOUT)
    except FileNotFoundError:
        raise RuntimeError("lsof is not on this Mac")
    except subprocess.TimeoutExpired:
        raise RuntimeError("lsof took too long")
    if done.returncode not in (0, 1):
        raise RuntimeError("lsof failed: %s" % done.stderr.strip()[:120])
    return done.stdout


def listening():
    """{(pid, port): {"pid", "port", "name", "addresses"}} from lsof -F pcn, by port then pid."""
    rows, pid, name = {}, None, ""
    for line in lsof(["-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]).splitlines():
        if not line:
            continue
        tag, value = line[0], line[1:]
        if tag == "p":
            pid, name = int(value), ""
        elif tag == "c":
            name = value
        elif tag == "n" and pid is not None:
            host, _, port = value.rpartition(":")
            if not port.isdigit():
                continue
            row = rows.setdefault((pid, int(port)), {"pid": pid, "port": int(port), "name": name, "addresses": []})
            if host not in row["addresses"]:
                row["addresses"].append(host)
    return [rows[k] for k in sorted(rows, key=lambda k: (k[1], k[0]))]


def port_item(row):
    pid, port, name = row["pid"], row["port"], row["name"] or "unknown"
    context = {"pid": pid, "port": port, "name": name}
    url = "http://localhost:%d" % port
    return {
        "id": "%d-%d" % (pid, port),
        "title": "Port %d" % port,
        "subtitle": "%s · pid %d · %s" % (name, pid, ", ".join(row["addresses"])),
        "icon": "🔌",
        "keywords": "%s %d %d" % (name, pid, port),
        "actions": [
            step_action("kill", "Quit %s" % name, dict(context, signal="TERM")),
            step_action("kill", "Force quit %s" % name, dict(context, signal="KILL")),
            {"type": "open", "url": url, "title": "Open %s" % url},
            {"type": "copy", "text": str(pid), "title": "Copy PID"},
            {"type": "copy", "text": url, "title": "Copy URL"},
        ],
    }


NO_PORT = {"title": "No TCP port is listening", "subtitle": "Nothing of yours holds one", "icon": "🔌"}


def kill_port(run):
    try:
        rows = listening()
    except RuntimeError as e:
        send({"type": "error", "text": str(e)})
        return
    send({"type": "list", "items": [port_item(r) for r in rows] or [NO_PORT]})


def port_page_item(row):
    """A page's row: Hyper+Space's, its two quits asking first in the row, Quit also an inline button."""
    found = port_item(row)
    name = row["name"] or "unknown"
    for action, words in zip(found["actions"][:2], ("Quit %s on port %d?", "Force quit %s on port %d? It loses unsaved work.")):
        action["ask"] = {"confirm": words % (name, row["port"])}
        action["destructive"] = True
    found["inline"] = [dict(found["actions"][0], icon="xmark")]
    return found


def ports_blocks(run):
    try:
        rows = listening()
    except RuntimeError as e:
        return [{"type": "markdown", "text": "Ports: %s." % e}]
    title = "Listening · %d port%s" % (len(rows), "" if len(rows) == 1 else "s")
    return [{"type": "list", "title": title, "items": [port_page_item(r) for r in rows] or [NO_PORT]}]


def process_name(pid):
    done = subprocess.run(["ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True, timeout=1)
    return done.stdout.strip()


def refusal(pid):
    """Why `pid` must not be signalled; None when it may."""
    if type(pid) is not int or pid <= 1:
        return "will not quit pid %s" % pid
    if pid in (os.getpid(), os.getppid()):
        return "will not quit Pilot"
    path = process_name(pid)
    if os.path.basename(path) == "Pilot" or "/Pilot.app/" in path:
        return "will not quit Pilot"
    return None


def kill(run):
    context = run.get("context") if isinstance(run.get("context"), dict) else {}
    pid, port, name = context.get("pid"), context.get("port"), context.get("name") or "the program"
    why = refusal(pid)
    if why:
        send({"type": "error", "text": why})
        return
    if type(port) is not int:
        send({"type": "error", "text": "got no port"})
        return
    try:
        holders = lsof(["-nP", "-t", "-a", "-p", str(pid), "-iTCP:%d" % port, "-sTCP:LISTEN"]).split()
    except RuntimeError as e:
        send({"type": "error", "text": str(e)})
        return
    if str(pid) not in holders:
        send({"type": "error", "text": "port %d is no longer held by pid %d" % (port, pid)})
        return
    force = context.get("signal") == "KILL"
    try:
        os.kill(pid, signal.SIGKILL if force else signal.SIGTERM)
    except ProcessLookupError:
        send({"type": "error", "text": "pid %d has already quit" % pid})
        return
    except PermissionError:
        send({"type": "error", "text": "may not quit pid %d: it is not yours" % pid})
        return
    verb = "Force quit" if force else "Asked to quit:"
    send({"type": "hud", "text": "%s %s (pid %d) on port %d" % (verb, name, pid, port)})


# MARK: - SSH hosts

SSH_CONFIG = "~/.ssh/config"
GHOSTTY = ["/Applications/Ghostty.app", os.path.expanduser("~/Applications/Ghostty.app")]
HOST_NAME = re.compile(r"[A-Za-z0-9._@-]+\Z")
MOST_INCLUDES = 32


def config_words(line):
    """A config line as its keyword (lowercase) and values; `Key=Value` too. None for a blank or comment line."""
    line = line.strip()
    if not line or line.startswith("#"):
        return None
    try:
        parts = shlex.split(line.replace("=", " ", 1) if "=" in line.split(None, 1)[0] else line, comments=True)
    except ValueError:
        return None
    return (parts[0].lower(), parts[1:]) if parts else None


def read_config(path, hosts, seen, depth=0):
    """Adds the hosts `path` names to `hosts` (name → settings, the first value of each setting wins, as in ssh),
    following Include (relative paths from ~/.ssh, globs allowed)."""
    path = os.path.realpath(os.path.expanduser(path))
    if path in seen or len(seen) >= MOST_INCLUDES or depth > 8:
        return
    seen.add(path)
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return
    current = []
    for line in lines:
        parsed = config_words(line)
        if not parsed:
            continue
        key, values = parsed
        if key == "include":
            for pattern in values:
                pattern = os.path.expanduser(pattern)
                if not os.path.isabs(pattern):
                    pattern = os.path.join(os.path.expanduser("~/.ssh"), pattern)
                for included in sorted(glob.glob(pattern)):
                    read_config(included, hosts, seen, depth + 1)
        elif key == "host":
            current = [v for v in values if HOST_NAME.match(v) and not v.startswith("!")]
            for name in current:
                hosts.setdefault(name, {"source": path})
        elif key == "match":
            current = []
        elif key in ("hostname", "user", "port") and values:
            for name in current:
                hosts[name].setdefault(key, values[0])


def ssh_hosts_found():
    found = {}
    read_config(SSH_CONFIG, found, set())
    return found


def tilde(path):
    """`path` from home as ~/…; config paths are real paths, so home is compared as one too."""
    for home in (os.path.expanduser("~"), os.path.realpath(os.path.expanduser("~"))):
        if path.startswith(home + "/"):
            return "~" + path[len(home):]
    return path


def address(settings):
    """"me@192.0.2.10:2222", the parts the config sets; None when it sets none."""
    host = settings.get("hostname")
    if not host:
        return None
    user = settings.get("user")
    port = settings.get("port")
    return "%s%s%s" % (user + "@" if user else "", host, ":" + port if port and port != "22" else "")


def terminal_app(preferences):
    """The chosen app's path, else Ghostty when installed, else Terminal."""
    chosen = preferences.get("terminal")
    if isinstance(chosen, str) and chosen and os.path.isdir(chosen):
        return chosen
    return next((g for g in GHOSTTY if os.path.isdir(g)), "Terminal")


def app_name(app):
    return os.path.basename(app)[:-4] if app.endswith(".app") else app


def host_items(run, words=""):
    """A row per host, its name, address and user holding every word in `words`."""
    found = ssh_hosts_found()
    terminal = app_name(terminal_app(run.get("preferences") or {}))
    items = []
    for name in sorted(found, key=str.lower):
        settings = found[name]
        where = address(settings)
        text = " ".join(x for x in (name, where, settings.get("user")) if x).lower()
        if not all(w in text for w in words.lower().split()):
            continue
        items.append({
            "id": name, "title": name, "icon": "🖥\ufe0f",
            "subtitle": " · ".join(x for x in (where, tilde(settings["source"])) if x),
            "keywords": " ".join(x for x in ("ssh", settings.get("hostname"), settings.get("user")) if x),
            "actions": [
                step_action("ssh-connect", "Connect in %s" % terminal, {"host": name}),
                {"type": "copy", "text": "ssh %s" % name, "title": "Copy ssh %s" % name},
                {"type": "open", "url": settings["source"], "title": "Open %s" % os.path.basename(settings["source"])},
            ]})
    return items


NO_HOSTS = {"title": "No hosts in %s" % SSH_CONFIG, "icon": "🖥\ufe0f",
            "subtitle": "Add a Host block, e.g. Host prod with HostName 203.0.113.7, and it shows here"}


def ssh_hosts(run):
    send({"type": "list", "items": host_items(run) or [NO_HOSTS]})


def filter_path(run):
    folder = data_dir(run)
    os.makedirs(folder, exist_ok=True)
    return os.path.join(folder, "ssh-filter.txt")


def held_filter(run):
    try:
        with open(filter_path(run), encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def ssh_filter(run):
    """The page's box: the words typed, kept for the page; blank (an emptied box, or Show all) clears them."""
    words = (run.get("input") or "").strip()[:200]
    with open(filter_path(run), "w", encoding="utf-8") as f:
        f.write(words)


def ssh_blocks(run):
    words = held_filter(run)
    rows = host_items(run, words)
    for row in rows:
        row["inline"] = [dict(row["actions"][0], icon="terminal")]
    box = {"type": "input", "placeholder": "Filter hosts by name, address or user", "live": True,
           "action": step_action("ssh-filter", "Filter")}
    blocks = [box]
    if words:
        blocks.append({"type": "buttons", "actions": [step_action("ssh-filter", "Show all hosts")]})
        title = "%d host%s matching “%s”" % (len(rows), "" if len(rows) == 1 else "s", words)
        rows = rows or [{"title": "No host matches “%s”" % words, "icon": "🔎"}]
    else:
        title = "Hosts"
        rows = rows or [NO_HOSTS]
    blocks.append({"type": "list", "title": title, "items": rows})
    return blocks


def open_with(arguments):
    done = subprocess.run(["open"] + arguments, capture_output=True, text=True, timeout=10)
    return None if done.returncode == 0 else (done.stderr.strip() or "open failed")[:160]


def ssh_connect(run):
    context = run.get("context") if isinstance(run.get("context"), dict) else {}
    name = context.get("host")
    if not (isinstance(name, str) and HOST_NAME.match(name) and name in ssh_hosts_found()):
        send({"type": "error", "text": "no host %s in %s" % (name, SSH_CONFIG)})
        return
    app = terminal_app(run.get("preferences") or {})
    if app_name(app).lower() == "ghostty":
        failed = open_with(["-na", app, "--args", "--command=ssh " + name, "--window-save-state=never"])
    else:
        cache = cache_dir(run)
        os.makedirs(cache, exist_ok=True)
        script = os.path.join(cache, "ssh-%s.command" % name)
        with open(script, "w", encoding="utf-8") as f:
            f.write("#!/bin/sh\nexec ssh %s\n" % shlex.quote(name))
        os.chmod(script, 0o755)
        app = "Terminal"
        failed = open_with(["-a", app, script])
    if failed:
        send({"type": "error", "text": failed})
        return
    send({"type": "hud", "text": "ssh %s in %s" % (name, app_name(app))})


# MARK: - Speedtest

SPEED_TOOL = "networkQuality"
MEBI = 1.048576  # networkQuality's printed Mbps are 2^20 bits/s; its JSON's are bits/s
SPEED_LIMIT = 120  # a test still running after this long is stopped
READING = re.compile(r"Downlink: capacity ([\d.]+) Mbps, responsiveness (\d+) RPM \(([^,]*), (\d+) flows?\)"
                     r" - Uplink: capacity ([\d.]+) Mbps, responsiveness (\d+) RPM \(([^,]*), (\d+) flows?\)")
ESCAPE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


class Paths:
    def __init__(self, run):
        self.data = data_dir(run)
        self.cache = cache_dir(run)
        self.job = os.path.join(self.data, "speedtest-job.json")
        self.last = os.path.join(self.data, "speedtest-last.json")
        self.out = os.path.join(self.cache, "speedtest-result.json")
        # The Speedtest extension's own last result, kept beside this one's data (ExtensionData/speedtest/data): read,
        # never written, until this extension has one of its own.
        self.before = os.path.join(os.path.dirname(os.path.dirname(self.data)), "speedtest", "data", "last.json")


def speed_last(paths):
    """The last result: this extension's, else the one the Speedtest extension kept."""
    return read_json(paths.last) or read_json(paths.before)


def speed_tool():
    """networkQuality on PATH (Pilot's ends with the system's), else /usr/bin's; None on a Mac without it."""
    return shutil.which(SPEED_TOOL, path=os.environ.get("PATH", "") + os.pathsep + "/usr/bin")


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


def speed_alive(job):
    """Whether the job's worker is still this extension's process (a pid reused since is not)."""
    return job.get("status") == "running" and ours(job.get("pid"))


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


def speed_test(paths, job):
    """The worker: networkQuality on a pty, its readings into the job file as they come, the result into the last file."""
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
    buffer, written, deadline = "", 0.0, time.time() + SPEED_LIMIT
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


def copy_result(result):
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
    if drawn(run, "hero"):
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
        {"type": "buttons", "actions": [step_action("speedtest-stop", "Stop", destructive=True)]}]


def result_blocks(run, result):
    rest = dict(facts(result))
    down = [stat("Latency", rest["Latency"]),
            stat("Responsiveness", rest["Download responsiveness"], tone(result.get("download_rpm")))]
    up = [stat("Responsiveness", rest["Upload responsiveness"], tone(result.get("upload_rpm")))]
    blocks = speed_blocks(run, result.get("download"), result.get("upload"), down, up)
    blocks.append({"type": "stats", "items": [stat(k, rest[k]) for k in ("Server", "Interface", "Tested")]})
    blocks.append({"type": "buttons", "actions": [step_action("speedtest-start", "Run again"), copy_result(result)]})
    return blocks


def speedtest_page(run):
    """The page's Speedtest: the test's readings, asked every 2 s while it runs; else the last result, or a Run button.
    (blocks, refresh)."""
    paths = Paths(run)
    job = read_json(paths.job)
    if speed_alive(job):
        return running_blocks(run, job), 2
    if not speed_tool():
        return [{"type": "markdown", "text": "This Mac has no networkQuality (macOS 12 or later has it)."}], None
    blocks = []
    if job.get("status") == "failed":
        blocks.append({"type": "markdown", "text": "The last test failed: %s" % job.get("error", "")})
    result = speed_last(paths)
    if result:
        blocks += result_blocks(run, result)
    else:
        blocks += [{"type": "markdown", "text": "No test yet. A test takes about 30 s and moves about 1 GB at gigabit speed."},
                   {"type": "buttons", "actions": [step_action("speedtest-start", "Run speed test")]}]
    return blocks, None


def speedtest(run):
    """Hyper+Space: the readings as they stand while a test runs (the page counts them live), else the last result.
    Its page opens on Speedtest from here (Open page, Cmd+Return)."""
    paths = Paths(run)
    keep_view(run, "speedtest")
    job = read_json(paths.job)
    show = {"type": "open", "url": PAGE, "title": "Show live on the page"}
    if speed_alive(job):
        markdown = "# ⚡ Testing…\n\n**Download** %s Mbps · **Upload** %s Mbps" % (
            mbps(job.get("download")), mbps(job.get("upload")) if job.get("phase") == "upload" else "–")
        return send({"type": "detail", "markdown": markdown, "blocks": running_blocks(run, job)[:-1],
                     "actions": [show, step_action("speedtest-stop", "Stop speed test", key="cmd+delete")]})
    result = speed_last(paths)
    if not result:
        text = "# ⚡ Speedtest\n\nNo test yet. Return runs one against Apple's servers (about 30 s), live on its page."
        if job.get("status") == "failed":
            text += "\n\nThe last test failed: %s" % job.get("error", "")
        return send({"type": "detail", "markdown": text, "actions": [step_action("speedtest-start", "Run speed test")]})
    markdown = "# ↓ %s Mbps · ↑ %s Mbps\n\nDownload and upload, %s." % (
        mbps(result.get("download")), mbps(result.get("upload")), when(result.get("at")))
    send({"type": "detail", "markdown": markdown, "blocks": result_blocks(run, result)[:-1],
          "metadata": [{"label": label, "text": value} for label, value in facts(result)],
          "actions": [step_action("speedtest-start", "Run again"), copy_result(result),
                      {"type": "open", "url": PAGE, "title": "Open page", "key": "cmd+o"}]})


def speedtest_start(run):
    paths = Paths(run)
    found = speed_tool()
    if not found:
        return send({"type": "error", "text": "needs macOS's networkQuality (macOS 12 or later)"})
    keep_view(run, "speedtest")
    job = read_json(paths.job)
    if not speed_alive(job):
        detach(lambda: speed_test(paths, {"tool": found}))
        send({"type": "hud", "text": "Testing your connection…"})
    send({"type": "action", "action": {"type": "open", "url": PAGE, "title": "Show the test"}})


def speedtest_stop(run):
    job = read_json(Paths(run).job)
    if not speed_alive(job):
        return send({"type": "hud", "text": "No speed test is running"})
    os.kill(job["pid"], signal.SIGTERM)
    send({"type": "hud", "text": "Stopped the speed test"})


# MARK: - The menu-bar item's popover: Overview's line, then a short section each; Pilot adds Open page last

POPOVER_ROWS = 5  # rows a popover section lists; the page lists them all


def gather(jobs, wait):
    """{name: work()} for each of `jobs`, all run at once in threads; None for one that failed or ran past `wait` s, so
    one slow read (system_profiler, a hung Tailscale) costs the popover only its own section."""
    found = {}

    def one(name, work):
        try:
            found[name] = work()
        except Exception:  # a section that fails says so; the others still show
            found[name] = None

    threads = [threading.Thread(target=one, args=job, daemon=True) for job in jobs.items()]
    for thread in threads:
        thread.start()
    end = time.monotonic() + wait
    for thread in threads:
        thread.join(max(0.0, end - time.monotonic()))
    return {name: found.get(name) for name in jobs}


def popover_connection():
    """connection(), with Wi-Fi read only when the local network is Wi-Fi (system_profiler is the slow read)."""
    now = connection()
    now["wifi"] = wifi(now["ports"]) if now["lan"]["kind"] == "Wi-Fi" else None
    return now


def overview_note(now):
    """One quiet line: what the Mac is on (the Wi-Fi's name and signal), its local IP at the right."""
    if not now or not now["kind"]:
        return {"type": "note", "text": "Not connected" if now else "The network did not answer in time"}
    air = now.get("wifi")
    if air and air["connected"]:
        words, _ = signal_words(air["signal"])
        text = "Wi-Fi %s" % (air["name"] or "(macOS hides its name)") + (" · %s signal" % words if words else "")
    else:
        text = "On %s" % (now["lan"]["kind"] or now["kind"])
    if now["kind"] == "VPN":
        text += " · through a VPN"
    return {"type": "note", "text": text, "aside": now["ip"] or "No local IP"}


def section(title, aside=None, subtitle=None, blocks=()):
    found = {"type": "section", "title": title, "blocks": list(blocks)}
    found.update({k: v for k, v in (("aside", aside), ("subtitle", subtitle)) if v})
    return found


def ts_section(found):
    """Tailscale's online devices and its switch; None when Tailscale isn't installed."""
    if found is None:
        return section("Tailscale", subtitle="Tailscale did not answer in time")
    data, why = found
    if why == TS_NOT_INSTALLED:
        return None
    if why:
        return section("Tailscale", subtitle=why[0], blocks=ts_switch(why))
    online = [item for item, on in ts_device_rows(data) if on]
    rows = online[:POPOVER_ROWS] or [{"title": "No device online", "icon": "🛜"}]
    return section("Tailscale", aside="%d online" % len(online), blocks=[{"type": "list", "items": rows}] + ts_switch(None))


def ports_section(found):
    """The listening ports, each quitting after its ask, as on the page."""
    if found is None:
        return section("Ports", subtitle="lsof did not answer in time")
    if isinstance(found, str):
        return section("Ports", subtitle=found)
    if not found:
        return section("Ports", subtitle=NO_PORT["title"])
    return section("Ports", aside="%d listening" % len(found),
                   blocks=[{"type": "list", "items": [port_page_item(r) for r in found[:POPOVER_ROWS]]}])


def listening_or_why():
    try:
        return listening()
    except RuntimeError as e:
        return str(e)


def speed_section(run):
    """The last result and Run, or Stop while a test runs."""
    paths = Paths(run)
    job = read_json(paths.job)
    if speed_alive(job):
        return section("Speedtest", aside="Testing…",
                       blocks=[{"type": "buttons", "actions": [step_action("speedtest-stop", "Stop", destructive=True)]}])
    if not speed_tool():
        return section("Speedtest", subtitle="This Mac has no networkQuality")
    result = speed_last(paths)
    if not result:
        return section("Speedtest", subtitle="No test yet",
                       blocks=[{"type": "buttons", "actions": [step_action("speedtest-start", "Run speed test")]}])
    return section("Speedtest", aside="%s ↓ · %s ↑ Mbps" % (mbps(result.get("download")), mbps(result.get("upload"))),
                   subtitle="Tested %s" % when(result.get("at")),
                   blocks=[{"type": "buttons", "actions": [step_action("speedtest-start", "Run again")]}])


def ssh_section(run):
    """The SSH hosts, each connecting in the terminal on a click, as on the page."""
    rows = host_items(run)
    if not rows:
        return section("SSH hosts", subtitle=NO_HOSTS["title"])
    for row in rows:
        row["inline"] = [dict(row["actions"][0], icon="terminal")]
    return section("SSH hosts", aside=str(len(rows)), blocks=[{"type": "list", "items": rows[:POPOVER_ROWS]}])


def popover_blocks(run):
    """Overview's line, then Tailscale, Ports, Speedtest and SSH hosts, a short section each, their reads run at once
    within the popover's time."""
    found = gather({"now": popover_connection, "tailscale": lambda: ts_status(TS_WAIT["popover"]),
                    "ports": listening_or_why}, left(4.0, 0.3))
    blocks = [overview_note(found["now"]), ts_section(found["tailscale"]), ports_section(found["ports"]),
              speed_section(run), ssh_section(run)]
    return [b for b in blocks if b]


# MARK: - The page

VIEWS = {"overview": "Overview", "devices": "Devices", "tailscale": "Tailscale", "ports": "Ports", "ssh": "SSH",
         "speedtest": "Speedtest"}
MOST_BLOCKS = 23  # Pilot draws 24 blocks of a page; the nav is one


def view_path(run):
    return os.path.join(data_dir(run), "view.txt")


def held_view(run):
    try:
        with open(view_path(run), encoding="utf-8") as f:
            name = f.read().strip()
    except OSError:
        return "overview"
    return name if name in VIEWS else "overview"


def keep_view(run, name):
    os.makedirs(data_dir(run), exist_ok=True)
    with open(view_path(run), "w", encoding="utf-8") as f:
        f.write(name)


def view(run):
    """A link at the page's top: the part it names shows."""
    context = run.get("context") if isinstance(run.get("context"), dict) else {}
    name = context.get("view")
    if name not in VIEWS:
        return send({"type": "error", "text": "has no part %s" % name})
    keep_view(run, name)


def nav(run, shown):
    """A link per part, the shown one marked; buttons where this Pilot draws no links."""
    actions = [step_action("view", title, {"view": name}) for name, title in VIEWS.items()]
    if not drawn(run, "links"):
        return {"type": "buttons", "actions": actions}
    return {"type": "links", "items": [dict({"title": a["title"], "actions": [a]},
                                            **({"tone": "fine", "word": "shown"} if a["context"]["view"] == shown else {}))
                                       for a in actions]}


# Each part's blocks and how often its page asks again (None: the page's own 60 s).
PARTS = {
    "overview": overview_blocks,
    "devices": devices_blocks,
    "tailscale": lambda run: (tailscale_blocks(run), None),
    "ports": lambda run: (ports_blocks(run), PORTS_REFRESH),
    "ssh": lambda run: (ssh_blocks(run), None),
    "speedtest": speedtest_page,
}


def page(run):
    shown = held_view(run)
    blocks, refresh = PARTS[shown](run)
    message = {"type": "blocks", "blocks": [nav(run, shown)] + blocks[:MOST_BLOCKS]}
    if refresh:
        message["refresh"] = refresh
    send(message)


STEPS = {
    "devices-scan": devices_scan, "kill": kill, "ssh-connect": ssh_connect, "ssh-filter": ssh_filter,
    "speedtest-start": speedtest_start, "speedtest-stop": speedtest_stop, "view": view,
}


def step(run):
    """The hidden command every step's action runs (step_action): the step its context names."""
    context = run.get("context") if isinstance(run.get("context"), dict) else {}
    work = STEPS.get(context.get("step"))
    if work is None:
        return send({"type": "error", "text": "has no step %s" % context.get("step")})
    work(run)


COMMANDS = {
    "overview": overview, "devices": devices,
    "tailscale": lambda run: send({"type": "list", "items": ts_devices()}),
    "tailscale-connect": ts_connect, "tailscale-disconnect": ts_disconnect,
    "kill-port": kill_port, "ssh-hosts": ssh_hosts, "speedtest": speedtest,
    "step": step, "page": page, "bar": bar,
}


def main():
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        send({"type": "error", "text": "got a run message it could not read"})
        return
    global DEADLINE
    surface = run.get("surface")
    if surface in ("page", "popover"):
        DEADLINE = STARTED + BUDGETS["page"]
    elif surface == "bar" or run.get("command") in LIST_COMMANDS:
        DEADLINE = STARTED + BUDGETS["list"]
    command = COMMANDS.get(run.get("command"))
    if command is None:
        send({"type": "error", "text": "has no command %s" % run.get("command")})
        return
    command(run)


if __name__ == "__main__":
    STARTED = time.monotonic()
    main()
